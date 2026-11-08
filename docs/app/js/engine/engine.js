// The one place the app asks for text. Uses the real on-device model (WebLLM) when it is loaded and
// clearly-labeled demo replies otherwise. One generation runs at a time; others wait their turn.

import * as demo from './demo.js';

export const DEFAULT_MODEL_ID = 'Llama-3.2-1B-Instruct-q4f16_1-MLC';

export const MODELS = [
  {
    id: 'Llama-3.2-1B-Instruct-q4f16_1-MLC',
    name: 'Hearth Lite',
    detail: 'Llama 3.2 1B',
    sizeLabel: 'about 700 MB',   // 695 MB of weights + runtime (measured: 711 MB in Cache Storage)
    note: 'Quick and light. A good start on most computers.',
  },
  {
    id: 'Llama-3.2-3B-Instruct-q4f16_1-MLC',
    name: 'Hearth Standard',
    detail: 'Llama 3.2 3B',
    sizeLabel: 'about 1.8 GB',   // 1,807 MB of weights
    note: 'Warmer, more thoughtful replies. Needs a stronger graphics chip.',
  },
];

const listeners = new Set();
const state = {
  status: 'idle',          // 'idle' | 'loading' | 'ready' | 'demo' | 'error'
  modelId: DEFAULT_MODEL_ID,
  loadedModelId: null,
  progress: null,          // { fraction 0..1, phase: 'download'|'load'|'prepare', text }
  error: null,             // friendly message when status === 'error'
  webgpu: null,            // null until checked, then true/false
};

let adapter = null;        // webllm.js module, imported only when needed
let chain = Promise.resolve();
let current = null;        // { cancel() } for the running generation
let initPromise = null;

const getAdapter = async () => (adapter ||= await import('./webllm.js'));

/** The MODELS id for a loaded build (GPUs without 16-bit shaders load the q4f32 build of the same model). */
const choiceOf = (loadedId) => (loadedId ? loadedId.replace('q4f32_1', 'q4f16_1') : null);

/** The loaded model is gone: the graphics chip reset (WebLLM then unloads it) or it was never loaded. */
const isModelLost = (err) => /ModelNotLoaded|DeviceLost|device (?:was|is) lost|not loaded/i.test(`${err?.name || ''} ${err?.message || err || ''}`);

function update(patch) {
  Object.assign(state, patch);
  const snap = snapshot();
  for (const fn of listeners) {
    try { fn(snap); } catch { /* a broken listener must not stop the others */ }
  }
}

function snapshot() { return { ...state, progress: state.progress ? { ...state.progress } : null }; }

/** Friendly reading of WebLLM's progress report. */
function readProgress(report) {
  const text = String(report?.text || '');
  const fraction = Math.max(0, Math.min(1, Number(report?.progress) || 0));
  let phase = 'prepare';
  if (/fetching/i.test(text)) phase = 'download';
  else if (/loading model from cache/i.test(text)) phase = 'load';
  const mb = Number(text.match(/(\d+(?:\.\d+)?)\s*MB fetched/i)?.[1] || 0);
  return { fraction, phase, mb, text };
}

function friendlyError(err) {
  const name = err?.name || '';
  const msg = String(err?.message || err || '');
  if (/ShaderF16|shader-f16/i.test(name + msg)) return "This graphics chip can't run this model build.";
  if (/WebGPU|GPU adapter|requestAdapter/i.test(name + msg)) return "This browser can't use the graphics chip for the model (WebGPU).";
  if (/quota|storage|QuotaExceeded/i.test(name + msg)) return "There isn't enough free storage for the model. Free some space and try again.";
  if (/network|fetch|Failed to fetch|NetworkError/i.test(name + msg)) return 'The download was interrupted. Check your connection and try again; it picks up where it left off.';
  if (/DeviceLost|device was lost/i.test(name + msg)) return 'The graphics chip reset while loading. Try again, or close other heavy tabs first.';
  return 'The model could not start in this browser.';
}

export const engine = {
  models: MODELS,

  get status() { return state.status; },
  /** The model picked to load next (it can differ from the one that is loaded right now). */
  get modelId() { return state.modelId; },
  get loadedModelId() { return state.loadedModelId; },
  /** The MODELS id writing replies right now, or null when replies are demo lines. */
  get inUseModelId() { return state.status === 'ready' ? choiceOf(state.loadedModelId) : null; },
  get progress() { return state.progress ? { ...state.progress } : null; },
  get error() { return state.error; },
  /** True when replies come from the demo engine. */
  get isDemo() { return state.status !== 'ready'; },
  get busy() { return current !== null; },
  snapshot,

  /** Calls fn(snapshot) on every change. Returns an unsubscribe function. */
  subscribe(fn) {
    listeners.add(fn);
    return () => listeners.delete(fn);
  },

  /** Resolves true when this browser can run the model (WebGPU adapter available). */
  async isWebGPUAvailable() {
    if (state.webgpu === null) {
      let ok = false;
      try {
        if (typeof navigator !== 'undefined' && navigator.gpu) ok = !!(await navigator.gpu.requestAdapter());
      } catch { ok = false; }
      update({ webgpu: ok });
    }
    return state.webgpu;
  },

  modelInfo(id = state.modelId) { return MODELS.find((m) => m.id === id) || MODELS[0]; },

  /** Picks a model without loading it. */
  setModel(modelId) {
    if (MODELS.some((m) => m.id === modelId)) update({ modelId });
  },

  /**
   * Startup: settle on 'demo', or quietly load the model when the user opted in earlier
   * and its files are already cached (no surprise downloads).
   */
  async boot({ modelId = DEFAULT_MODEL_ID, autoLoad = false } = {}) {
    this.setModel(modelId);
    if (!autoLoad || !(await this.isWebGPUAvailable())) {
      if (state.status === 'idle') update({ status: 'demo' });
      return state.status;
    }
    try {
      const a = await getAdapter();
      // The chosen model first; if it was never downloaded, one that was (the last one used, say).
      const ids = [state.modelId, ...MODELS.map((m) => m.id).filter((id) => id !== state.modelId)];
      for (const id of ids) {
        if (await a.hasModel(id)) {
          this.init({ modelId: id }).catch(() => {});
          return 'loading';
        }
      }
    } catch { /* fall through to demo */ }
    if (state.status === 'idle') update({ status: 'demo' });
    return state.status;
  },

  /** Downloads (first time) and loads a model. Resolves when ready; rejects with a friendly Error. */
  init({ modelId = state.modelId, onProgress } = {}) {
    if (initPromise) return initPromise;
    if (state.status === 'ready' && state.loadedModelId === modelId) return Promise.resolve();
    this.setModel(modelId);
    update({ status: 'loading', error: null, progress: { fraction: 0, phase: 'prepare', mb: 0, text: '' } });
    initPromise = (async () => {
      try {
        if (!(await this.isWebGPUAvailable())) throw new Error('WebGPU is not available');
        const a = await getAdapter();
        if (navigator.storage?.persist) navigator.storage.persist().catch(() => {});
        await chain.catch(() => {}); // let a running reply finish first
        const loaded = await a.load(modelId, (report) => {
          const p = readProgress(report);
          update({ progress: p });
          onProgress?.(p);
        });
        update({ status: 'ready', loadedModelId: loaded, progress: { fraction: 1, phase: 'prepare', mb: 0, text: '' } });
      } catch (err) {
        update({ status: 'error', error: friendlyError(err), progress: null });
        throw new Error(friendlyError(err));
      } finally {
        initPromise = null;
      }
    })();
    return initPromise;
  },

  /**
   * Generates one reply.
   * request: { key, turns, assistantPrefix, maxTokens, stop, sampling }
   * onToken(delta, fullTextSoFar) is called as text streams in.
   * Resolves with { text, stats }; stats.engine is 'demo' or 'webllm:<model>'.
   */
  generate(request, onToken) {
    const run = async () => {
      let cancelled = false;
      const useReal = state.status === 'ready';
      current = {
        cancel: async () => {
          cancelled = true;
          if (useReal) (await getAdapter()).interrupt();
        },
      };
      try {
        if (useReal) {
          try {
            return await (await getAdapter()).generate(request, onToken);
          } catch (err) {
            if (cancelled) return { text: '', stats: { engine: 'webllm', stoppedBy: 'cancelled' } };
            if (!isModelLost(err)) throw err;
            // Every later reply would fail too: say so (Settings and the chat offer to load it again)
            // and answer this one with labeled demo replies.
            update({ status: 'error', loadedModelId: null, progress: null, error: 'The graphics chip reset and the model stopped. Load it again to keep using it.' });
          }
        }
        return await demo.generate(request, onToken, () => cancelled);
      } finally {
        current = null;
      }
    };
    const result = chain.then(run, run);
    chain = result.catch(() => {});
    return result;
  },

  /** Stops the reply that is streaming right now. */
  cancel() { current?.cancel(); },

  async isCached(modelId = state.modelId) {
    if (!(await this.isWebGPUAvailable())) return false;
    try { return await (await getAdapter()).hasModel(modelId); } catch { return false; }
  },

  /** Deletes a model's downloaded files. Falls back to demo replies if it was the loaded one. */
  async deleteModel(modelId = state.modelId) {
    const a = await getAdapter();
    const wasLoaded = choiceOf(state.loadedModelId) === modelId;
    await a.deleteModel(modelId);
    if (wasLoaded) update({ status: 'demo', loadedModelId: null, progress: null });
  },

  /**
   * Deletes Hearth's downloaded model files (used by "Delete everything"). Only these models' files go:
   * other sites on the same web address may keep WebLLM files of their own.
   */
  async deleteAllModels() {
    try {
      const a = await getAdapter();
      await a.unload();
      for (const m of MODELS) await a.deleteModel(m.id);
    } catch { /* Cache Storage blocked: nothing was saved there either */ }
    update({ status: 'demo', loadedModelId: null, progress: null });
  },
};
