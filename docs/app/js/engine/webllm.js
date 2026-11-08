// WebLLM adapter: loads the vendored library on demand, runs the model in a Web Worker (WebGPU),
// and streams chat completions. Model files come from Hugging Face and the runtime from GitHub, once;
// the browser caches them and nothing about the chat is ever sent anywhere.
//
// Still open: the model records come from WebLLM's prebuiltAppConfig, which points at moving "main"
// branches and has no `integrity` hashes, so the runtime and weights are not pinned yet.

let lib = null;        // the vendored @mlc-ai/web-llm module, imported lazily (it is large)
let worker = null;
let mlc = null;        // WebWorkerMLCEngine
let loadedModelId = null;

export async function loadLibrary() {
  if (!lib) lib = await import('../../vendor/web-llm/index.js');
  return lib;
}

/** { ok, f16, reason } for this browser's WebGPU support. */
export async function gpuInfo() {
  if (typeof navigator === 'undefined' || !('gpu' in navigator) || !navigator.gpu) return { ok: false, f16: false, reason: 'no-webgpu' };
  try {
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) return { ok: false, f16: false, reason: 'no-adapter' };
    return { ok: true, f16: adapter.features.has('shader-f16'), reason: null };
  } catch {
    return { ok: false, f16: false, reason: 'error' };
  }
}

/** GPUs without 16-bit float shaders need the q4f32 build of the same model. */
export async function resolveModelId(modelId) {
  const l = await loadLibrary();
  const info = await gpuInfo();
  if (info.ok && !info.f16 && modelId.includes('q4f16_1')) {
    const alt = modelId.replace('q4f16_1', 'q4f32_1');
    if (l.prebuiltAppConfig.model_list.some((m) => m.model_id === alt)) return alt;
  }
  return modelId;
}

export async function hasModel(modelId) {
  const l = await loadLibrary();
  try {
    return await l.hasModelInCache(await resolveModelId(modelId), l.prebuiltAppConfig);
  } catch {
    return false;
  }
}

/**
 * The worker that runs the model. It starts from a tiny blob: script that imports webllm-worker.js, because
 * a worker made from a blob: URL follows this page's Content-Security-Policy, while one loaded straight
 * from a URL follows only that file's own headers (GitHub Pages sends none). So every download the model
 * makes stays inside the page's connect-src list.
 */
function createWorker() {
  const src = new URL('./webllm-worker.js', import.meta.url).href;
  const wrapper = new Blob([`import ${JSON.stringify(src)};\n`], { type: 'text/javascript' });
  return new Worker(URL.createObjectURL(wrapper), { type: 'module' });
}

/** Downloads (first time) and loads a model into the worker. onProgress gets WebLLM's { progress, text }. */
export async function load(modelId, onProgress) {
  const l = await loadLibrary();
  const id = await resolveModelId(modelId);
  const progress = (report) => { try { onProgress?.(report); } catch { /* UI callback errors stay local */ } };
  if (!worker) worker = createWorker();
  if (!mlc) {
    mlc = await l.CreateWebWorkerMLCEngine(worker, id, {
      appConfig: l.prebuiltAppConfig,
      initProgressCallback: progress,
      logLevel: 'ERROR',
    });
  } else {
    mlc.setInitProgressCallback(progress);
    await mlc.reload(id);
  }
  loadedModelId = id;
  return id;
}

export function loadedModel() { return loadedModelId; }

/** Rebuilds the message list for WebLLM: same roles merged, and the last message always from the user. */
function prepareMessages(turns, assistantPrefix) {
  const messages = [];
  for (const t of turns) {
    const prev = messages[messages.length - 1];
    if (prev && prev.role === t.role && t.role !== 'system') prev.content += `\n\n${t.content}`;
    else messages.push({ role: t.role, content: t.content });
  }
  const speaker = assistantPrefix ? assistantPrefix.replace(/:\s*$/, '').trim() : null;
  const instruction = speaker
    ? `[Reply only as ${speaker}. Write ${speaker}'s next line, one or two sentences, and nothing for anyone else.]`
    : null;
  const last = messages[messages.length - 1];
  if (last?.role === 'user') {
    if (instruction) last.content += `\n\n${instruction}`;
  } else {
    messages.push({ role: 'user', content: instruction || '[Continue.]' });
  }
  return messages;
}

/**
 * Streams one reply. Resolves with { text, stats }. Text still includes any "Name:" label;
 * the caller cleans it with brain/parse.js cleanReply().
 */
export async function generate({ turns, assistantPrefix = null, maxTokens = 256, stop = [], sampling = {} }, onToken) {
  if (!mlc || !loadedModelId) throw new Error('The model is not loaded.');
  const messages = prepareMessages(turns, assistantPrefix);
  const started = performance.now();
  let firstAt = 0;
  let text = '';
  let usage = null;
  let finish = null;
  const request = {
    stream: true,
    stream_options: { include_usage: true },
    messages,
    temperature: sampling.temperature ?? 0.8,
    top_p: sampling.topP ?? 0.95,
    max_tokens: maxTokens,
    repetition_penalty: sampling.repeatPenalty ?? 1.1,
  };
  if (stop?.length) request.stop = stop.slice(0, 16);
  if (Number.isInteger(sampling.seed)) request.seed = sampling.seed;
  const chunks = await mlc.chat.completions.create(request);
  for await (const chunk of chunks) {
    const choice = chunk.choices?.[0];
    const delta = choice?.delta?.content || '';
    if (delta) {
      if (!firstAt) firstAt = performance.now();
      text += delta;
      onToken?.(delta, text);
    }
    if (choice?.finish_reason) finish = choice.finish_reason;
    if (chunk.usage) usage = chunk.usage;
  }
  const extra = usage?.extra || {};
  return {
    text,
    stats: {
      engine: `webllm:${loadedModelId}`,
      promptTokens: usage?.prompt_tokens ?? 0,
      generatedTokens: usage?.completion_tokens ?? 0,
      timeToFirstToken: extra.time_to_first_token_s ?? (firstAt ? (firstAt - started) / 1000 : 0),
      prefillTokensPerSecond: extra.prefill_tokens_per_s ?? 0,
      decodeTokensPerSecond: extra.decode_tokens_per_s ?? 0,
      stoppedBy: finish === 'length' ? 'length' : finish === 'abort' ? 'cancelled' : finish === 'stop' ? 'eos' : (finish || 'eos'),
    },
  };
}

export function interrupt() {
  try { mlc?.interruptGenerate(); } catch { /* nothing running */ }
}

/** Frees GPU memory (the cached download stays). */
export async function unload() {
  if (!mlc) return;
  try { await mlc.unload(); } catch { /* already unloaded */ }
  loadedModelId = null;
}

/**
 * Deletes a model's downloaded files (both the f16 and f32 builds) straight from Cache Storage.
 * (WebLLM's deleteModelAllInfoInCache re-downloads the file list to find the shards, which would touch
 * the network for a model that was never downloaded, so this walks the "webllm/*" caches instead.)
 */
export async function deleteModel(modelId) {
  const l = await loadLibrary();
  const ids = new Set([modelId, modelId.replace('q4f16_1', 'q4f32_1')]);
  for (const id of ids) {
    const record = l.prebuiltAppConfig.model_list.find((m) => m.model_id === id);
    if (!record) continue;
    if (loadedModelId === id) await unload();
    const base = `${record.model.replace(/\/+$/, '')}/`;
    for (const name of await caches.keys()) {
      if (!name.startsWith('webllm/')) continue;
      const cache = await caches.open(name);
      for (const req of await cache.keys()) {
        if (req.url.startsWith(base) || req.url === record.model_lib) await cache.delete(req);
      }
    }
  }
}
