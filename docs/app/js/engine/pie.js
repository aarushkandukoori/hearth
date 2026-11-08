// Pie adapter: Hearth's model runs on Pie (github.com/pie-project/pie), Yale's programmable LLM serving
// system, right in this tab. Pie's browser runtime (vendor/pie, @pie-project/server-web 0.6.4) runs its
// engine in its own Web Worker on the graphics chip (WebGPU). Every reply, and every description of a photo
// the person sends, is one launch of Hearth's inferlet (pie/hearth.wasm, source in /inferlet): it renders
// the chat with the model's own template, samples on the device and streams the reply back piece by piece.
//
// The model is downloaded once into this browser's private file system for this site (OPFS), where Pie
// looks for it on every start. Nothing about the chat is ever sent anywhere. Pie keeps the pages the
// inferlet checkpoints on the graphics chip between replies while there is room, so the next reply in a chat
// usually maps the earlier turns back in (stats.reusedTokens). Pie's browser runtime has no host or disk KV
// tier (server-web 0.6.4), so after a reload, or when graphics memory runs short, it reads the chat again.

const SITE = new URL('../../../', import.meta.url); // the site's root folder (docs/)
const LOCAL_DEV = SITE.pathname === '/' && ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);

export const MODEL = Object.freeze({
  id: 'qwen3.5-0.8b-vision',
  // GitHub Pages: 48 MiB pieces in the hearth-model repo, on this site's web address (tools/split-model.mjs);
  // ../../sw.js joins them for Pie. tools/serve.mjs: the whole file under /models/.
  url: LOCAL_DEV
    ? new URL('models/qwen3.5-0.8b-vision.wgpu.zt', SITE).href
    : new URL('../hearth-model/qwen3.5-0.8b-vision.wgpu.zt', SITE).href,
  bytes: 648146918, // Qwen3.5 0.8B with its vision tower, Pie deployment qwen35-d0.8b-vision-u4g64-kv-bf16
});

// One sequence of up to 4,096 tokens: Hearth's prompts stay under about 2,600 (brain/prompts.js).
const CONFIG = { max_forward_tokens: 512, max_forward_requests: 4, max_model_len: 4096, max_state_slots: 8, device_kv_budget: '512MiB' };
const INFERLET_URL = new URL('../../pie/hearth.wasm', import.meta.url).href;

let pie = null;     // { server, client, program } once booted
let current = null; // the launch streaming now: { proc, cancelled, stop }

// ---- The downloaded model (OPFS) ------------------------------------------------------------------------

// Pie (vendor/pie/worker.mjs) keeps a model in the private file system under `${url}|${size}|${etag}`, with
// every character outside [a-zA-Z0-9._-] turned into "_", and boots from that file when it is complete. Hearth
// downloads into the same file itself, once, before starting Pie: left alone, Pie reads the file in ranges to
// boot and then fetches the whole file again to fill that cache. If Pie ever names it differently, it still
// works, but downloads twice (load() warns in the console).
const fileName = (size, etag) => `${MODEL.url}|${size}|${etag}`.replace(/[^a-zA-Z0-9._-]/g, '_');
const filePrefix = () => fileName('', '').slice(0, -1); // "<url>_", how every copy of this model's file starts

async function storageDir() {
  try { return (await navigator.storage?.getDirectory?.()) ?? null; } catch { return null; }
}

/** Files of this model in the private file system: [{ name, complete }]. */
async function modelFiles(dir) {
  const out = [];
  if (!dir) return out;
  const start = filePrefix();
  for await (const [name, handle] of dir.entries()) {
    if (handle.kind !== 'file' || !name.startsWith(start)) continue;
    const want = Number(name.slice(start.length).match(/^\d+/)?.[0] || 0);
    let size = -1;
    try { size = (await handle.getFile()).size; } catch { /* still being written */ }
    out.push({ name, complete: want > 0 && size === want });
  }
  return out;
}

/** True when the model is downloaded and complete in this browser. */
export async function hasModel() {
  return (await modelFiles(await storageDir())).some((f) => f.complete);
}

/** Size, ETag and file list of the published model: pieces with a manifest, or one file. */
async function describe() {
  const manifest = LOCAL_DEV ? null
    : await fetch(`${MODEL.url}.json`, { cache: 'no-cache' }).then((r) => (r.ok ? r.json() : null), () => null);
  if (manifest) {
    // sw.js answers Pie's HEAD request with this same size and ETag.
    const parts = Array.from({ length: manifest.pieces }, (_, i) => `${MODEL.url}.${String(i).padStart(2, '0')}`);
    return { size: manifest.size, etag: `"${manifest.sha256}"`, parts };
  }
  const head = await fetch(MODEL.url, { method: 'HEAD', cache: 'no-cache' });
  if (!head.ok) throw new Error(`The model download failed (HTTP ${head.status}).`);
  return { size: Number(head.headers.get('content-length') || 0), etag: head.headers.get('etag') ?? '', parts: [MODEL.url] };
}

/** Downloads the model into `name`, one part after another. A failed download leaves nothing behind. */
async function download(dir, name, { size, parts }, onBytes) {
  const handle = await dir.getFileHandle(name, { create: true });
  const writable = await handle.createWritable();
  let got = 0;
  try {
    for (const url of parts) {
      const response = await fetch(url);
      if (!response.ok || !response.body) throw new Error(`The model download failed (HTTP ${response.status}).`);
      const reader = response.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        await writable.write(value);
        got += value.length;
        onBytes(got, size);
      }
    }
    if (got !== size) throw new Error(`The model download was cut short (${got} of ${size} bytes).`);
    await writable.close();
  } catch (err) {
    await writable.abort().catch(() => {});
    await dir.removeEntry(name).catch(() => {});
    throw err;
  }
}

/**
 * GitHub Pages: registers ../../sw.js, which answers Pie's requests for the model from its pieces. Its scope
 * is the app/ folder, which holds Pie's worker, so it must be running before Pie starts that worker.
 */
async function startServiceWorker() {
  if (!('serviceWorker' in navigator)) throw new Error('This browser has no service workers.');
  const reg = await navigator.serviceWorker.register(new URL('../../sw.js', import.meta.url).href);
  if (reg.active) return;
  const sw = reg.installing || reg.waiting;
  await new Promise((resolve, reject) => {
    const check = () => {
      if (sw.state === 'activated') resolve();
      else if (sw.state === 'redundant') reject(new Error('The service worker could not start.'));
    };
    sw.addEventListener('statechange', check);
    check();
  });
}

// ---- Boot -------------------------------------------------------------------------------------------------

/**
 * Downloads the model the first time, then boots Pie with it and installs Hearth's inferlet.
 * onProgress gets { phase: 'download'|'load'|'prepare', fraction 0..1, mb? }.
 */
export async function load(onProgress) {
  if (pie) return MODEL.id;
  let reportedAt = 0;
  const report = (phase, fraction, mb = 0) => {
    const now = performance.now();
    if (phase === 'download' && fraction < 1 && now - reportedAt < 100) return; // a few updates a second
    reportedAt = now;
    try { onProgress?.({ phase, fraction: Math.max(0, Math.min(1, fraction)), mb }); } catch { /* UI callback errors stay local */ }
  };
  report('prepare', 0);
  if (!LOCAL_DEV) await startServiceWorker();

  const dir = await storageDir();
  if (dir) {
    const info = await describe();
    if (!info.size) throw new Error('The model download failed (no size).');
    const name = fileName(info.size, info.etag);
    const files = await modelFiles(dir);
    if (!files.some((f) => f.name === name && f.complete)) {
      if (navigator.storage?.persist) navigator.storage.persist().catch(() => {});
      await download(dir, name, info, (got, total) => report('download', got / total, got / 1e6));
    }
    // Copies of an older model build are no longer used.
    for (const f of files) if (f.name !== name) await dir.removeEntry(f.name).catch(() => {});
  }

  const runtime = await import('../../vendor/pie/pie.mjs');
  // A new worker each time Pie starts (also after a failed start); Pie's own log shows warnings and errors only.
  await runtime.load({ fresh: true, log: 'warn' });
  let source = 'cache';
  let server = null;
  try {
    server = await runtime.Server.start({
      model: MODEL.url,
      config: CONFIG,
      onProgress: (served, total, from) => {
        source = from;
        // From the file downloaded above Pie loads the weights onto the graphics chip ('cache');
        // without a private file system it reads them from the network as it goes.
        if (from === 'cache') report('load', served / total);
        else report('download', served / total, served / 1e6);
      },
    });
    if (dir && source !== 'cache') console.warn('[hearth] Pie read the model from the network although it was downloaded; check fileName() in engine/pie.js against vendor/pie/worker.mjs.');
    report('prepare', 0.9);
    const program = await server.install(INFERLET_URL);
    const client = await server.connect();
    pie = { server, client, program };
  } catch (err) {
    await server?.shutdown().catch(() => {});
    throw err;
  }
  await warmUp();
  report('prepare', 1);
  return MODEL.id;
}

/**
 * A two-token reply right after booting, so the graphics chip builds its programs now (seconds on a first
 * visit, under the loading bar) instead of during the first real reply. The browser keeps them for later visits.
 */
async function warmUp() {
  try {
    await run({ turns: [{ role: 'user', content: 'Hi' }], max_tokens: 2, temperature: 0.8, top_p: 0.95, repeat_penalty: 1.1, stream: false });
  } catch { /* the first real reply builds them instead */ }
}

// ---- Replies and photo descriptions ---------------------------------------------------------------------

/**
 * Launches the inferlet with `input` and reads its events: onPiece(text) for each streamed piece.
 * Resolves with { out (its JSON output, or null when stopped), cancelled }. Only one launch runs at a time.
 */
async function run(input, onPiece) {
  if (!pie) throw new Error('The model is not loaded.');
  const job = { proc: null, cancelled: false, stop: null };
  const stopped = new Promise((resolve) => { job.stop = resolve; });
  current = job;
  try {
    job.proc = await pie.client.launchProcess(pie.program, input);
    if (job.cancelled) job.proc.terminate().catch(() => {});
    while (!job.cancelled) {
      const next = await Promise.race([job.proc.recv(), stopped]);
      if (!next) break;
      const { event, value } = next;
      if (event === 'message') onPiece?.(String(value));
      else if (event === 'return') return { out: JSON.parse(value), cancelled: false };
      else if (event === 'error') throw new Error(String(value));
    }
    return { out: null, cancelled: true };
  } catch (err) {
    if (job.cancelled) return { out: null, cancelled: true };
    throw err;
  } finally {
    if (current === job) current = null;
  }
}

/** `v` when it is a number that passes `ok`, else undefined (the inferlet refuses values out of range). */
const valid = (v, ok) => (typeof v === 'number' && Number.isFinite(v) && ok(v) ? v : undefined);

/**
 * Streams one reply. Request: { turns, assistantPrefix?, opener?, maxTokens, stop, sampling }, where
 * sampling is { temperature, topP, topK?, minP?, repeatPenalty, seed? }. The input fields are the ones
 * inferlet/src/lib.rs reads; topK and minP are sent only when given, so the inferlet's own defaults
 * (top_k 40, min_p 0.05) apply otherwise, the same as on the iPhone.
 * assistantPrefix ("Theo:" in a group scene) is written right after the assistant header and not returned;
 * opener is a fixed start the person does see, so the text returned (and streamed) begins with it.
 * Stopped early, it resolves with the words so far and stats.stoppedBy === 'cancelled'.
 */
export async function generate({ turns, assistantPrefix = null, opener = null, maxTokens = 256, stop = [], sampling = {} }, onToken) {
  const input = {
    turns: turns.map((t) => ({ role: t.role, content: String(t.content ?? '') })),
    max_tokens: Number.isInteger(maxTokens) && maxTokens > 0 ? maxTokens : 256,
    stop: (stop || []).filter(Boolean).map(String).slice(0, 16),
    temperature: valid(sampling.temperature, (v) => v >= 0) ?? 0.8,
    top_p: valid(sampling.topP, (v) => v > 0 && v <= 1) ?? 0.95,
    repeat_penalty: valid(sampling.repeatPenalty, (v) => v > 0) ?? 1.1,
  };
  if (Number.isInteger(sampling.topK) && sampling.topK >= 0) input.top_k = sampling.topK;
  const minP = valid(sampling.minP, (v) => v >= 0 && v < 1);
  if (minP !== undefined) input.min_p = minP;
  if (assistantPrefix) input.prefix = assistantPrefix;
  if (opener) input.opener = opener;
  if (Number.isInteger(sampling.seed)) input.seed = sampling.seed >>> 0;
  const lead = opener ? `${opener} ` : '';
  const started = performance.now();
  let firstAt = 0;
  let text = '';
  if (lead) onToken?.(lead, lead);
  const { out, cancelled } = await run(input, (piece) => {
    if (!firstAt) firstAt = performance.now();
    text += piece;
    onToken?.(piece, lead + text);
  });
  const o = out || {};
  return {
    text: lead + (out ? String(o.text ?? '') : text),
    stats: {
      engine: `pie:${MODEL.id}`,
      promptTokens: o.prompt_tokens ?? 0,
      reusedTokens: o.reused_tokens ?? 0,
      generatedTokens: o.generated_tokens ?? 0,
      // Pie's clock (from the inferlet's start) and the page's (from asking), in seconds.
      timeToFirstToken: o.ttft_ms != null ? o.ttft_ms / 1000 : 0,
      wallTimeToFirstToken: firstAt ? (firstAt - started) / 1000 : 0,
      prefillTokensPerSecond: o.prefill_ms > 0 ? (o.prefilled_tokens || 0) / (o.prefill_ms / 1000) : 0,
      decodeTokensPerSecond: o.decode_tokens_per_second ?? 0,
      stoppedBy: cancelled ? 'cancelled' : o.stopped_by === 'max_tokens' ? 'length' : (o.stopped_by || 'eos'),
    },
  };
}

/**
 * One or two plain sentences about a photo, from the model's vision tower.
 * imageBase64: a JPEG or PNG as base64 (no data: prefix). Resolves with { text, stats }; text is '' if stopped.
 */
export async function caption(imageBase64, { maxTokens = 80 } = {}) {
  const started = performance.now();
  const { out, cancelled } = await run({ mode: 'caption', image_b64: imageBase64, max_tokens: maxTokens });
  return {
    text: cancelled ? '' : String(out?.text || '').trim(),
    stats: {
      engine: `pie:${MODEL.id}`,
      promptTokens: out?.prompt_tokens ?? 0,
      generatedTokens: out?.generated_tokens ?? 0,
      timeToFirstToken: out?.ttft_ms != null ? out.ttft_ms / 1000 : 0,
      seconds: (performance.now() - started) / 1000,
      stoppedBy: cancelled ? 'cancelled' : 'eos',
    },
  };
}

/** Stops the reply or description running right now. */
export function interrupt() {
  const job = current;
  if (!job || job.cancelled) return;
  job.cancelled = true;
  job.stop(null);
  job.proc?.terminate().catch(() => {});
}

/** Stops Pie and frees the graphics memory (the downloaded model stays). */
export async function unload() {
  interrupt();
  const p = pie;
  pie = null;
  if (p) await p.server.shutdown().catch(() => {});
}

/** Deletes the downloaded model from this browser. */
export async function deleteModel() {
  await unload();
  const dir = await storageDir();
  for (const f of await modelFiles(dir)) await dir.removeEntry(f.name).catch(() => {});
}
