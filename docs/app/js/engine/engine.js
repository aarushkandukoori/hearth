// The one place the app asks for text. Uses the real on-device model (run by Pie, see pie.js) when it is
// loaded and clearly-labeled demo replies otherwise. One generation runs at a time; others wait their turn.

import * as demo from './demo.js';

export const DEFAULT_MODEL_ID = 'qwen3.5-0.8b-vision';

export const MODELS = [
  {
    id: 'qwen3.5-0.8b-vision',
    name: 'Qwen3.5 0.8B',
    detail: 'with vision, run by Pie in this tab',
    sizeLabel: '648 MB',          // 648,146,918 bytes: the weights, 4-bit, with the vision tower
    note: 'Writes the replies, and describes photos you send.',
  },
];

const listeners = new Set();
const state = {
  status: 'idle',          // 'idle' | 'loading' | 'ready' | 'demo' | 'error'
  modelId: DEFAULT_MODEL_ID,
  loadedModelId: null,
  progress: null,          // { fraction 0..1, phase: 'download'|'load'|'prepare', mb, text }
  error: null,             // friendly message when status === 'error'
  webgpu: null,            // null until checked, then true/false: this browser can run the model
};

let adapter = null;        // pie.js, imported only when needed
let chain = Promise.resolve();
let current = null;        // { cancel() } for the running generation
let initPromise = null;

const getAdapter = async () => (adapter ||= await import('./pie.js'));

/** The loaded model is gone: the graphics chip reset, Pie's worker stopped, or it was never loaded. */
const isModelLost = (err) => /DeviceLost|device (?:was|is) lost|not loaded|shut down|pie worker/i.test(`${err?.name || ''} ${err?.message || err || ''}`);

function update(patch) {
  Object.assign(state, patch);
  const snap = snapshot();
  for (const fn of listeners) {
    try { fn(snap); } catch { /* a broken listener must not stop the others */ }
  }
}

function snapshot() { return { ...state, progress: state.progress ? { ...state.progress } : null }; }

function friendlyError(err) {
  const msg = `${err?.name || ''} ${err?.message || err || ''}`;
  if (/Suspending|promising|JSPI/i.test(msg)) return 'This browser is missing WebAssembly JSPI, which Pie needs. Chrome or Edge 137 or newer have it.';
  if (/WebGPU|GPU adapter|requestAdapter/i.test(msg)) return "This browser can't use the graphics chip for the model (WebGPU).";
  if (/service ?worker/i.test(msg)) return "This browser blocked the helper Hearth uses to read the model (a service worker). Private windows sometimes do this; try a normal window.";
  if (/quota|QuotaExceeded|NoModificationAllowed|storage/i.test(msg)) return "There isn't enough free storage for the model (648 MB). Free some space and try again.";
  if (/HTTP 404/i.test(msg)) return "The model isn't available to download right now. Try again later.";
  if (/download|network|fetch|range request|content-length/i.test(msg)) return 'The download was interrupted. Check your connection and try again.';
  if (/DeviceLost|device (?:was|is) lost/i.test(msg)) return 'The graphics chip reset while loading. Try again, or close other heavy tabs first.';
  if (/out of memory|OutOfMemory|budget|one sequence|allocation/i.test(msg)) return "The graphics chip doesn't have enough free memory for the model. Close other heavy tabs and try again.";
  return 'The model could not start in this browser.';
}

export const engine = {
  models: MODELS,

  get status() { return state.status; },
  /** The model picked to load next (it can differ from the one that is loaded right now). */
  get modelId() { return state.modelId; },
  get loadedModelId() { return state.loadedModelId; },
  /** The MODELS id writing replies right now, or null when replies are demo lines. */
  get inUseModelId() { return state.status === 'ready' ? state.loadedModelId : null; },
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

  /**
   * Resolves true when this browser can run the model: a WebGPU adapter, and WebAssembly JSPI (Pie's
   * runtime needs both; Chrome and Edge have them from version 137).
   */
  async isWebGPUAvailable() {
    if (state.webgpu === null) {
      let ok = false;
      try {
        const jspi = typeof WebAssembly?.Suspending === 'function' && typeof WebAssembly?.promising === 'function';
        if (jspi && typeof navigator !== 'undefined' && navigator.gpu) ok = !!(await navigator.gpu.requestAdapter());
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
   * and it is already downloaded (no surprise downloads).
   */
  async boot({ modelId = DEFAULT_MODEL_ID, autoLoad = false } = {}) {
    this.setModel(modelId);
    if (!autoLoad || !(await this.isWebGPUAvailable())) {
      if (state.status === 'idle') update({ status: 'demo' });
      return state.status;
    }
    try {
      if (await (await getAdapter()).hasModel()) {
        this.init({ modelId: state.modelId }).catch(() => {});
        return 'loading';
      }
    } catch { /* fall through to demo */ }
    if (state.status === 'idle') update({ status: 'demo' });
    return state.status;
  },

  /** Downloads (first time) and loads the model. Resolves when ready; rejects with a friendly Error. */
  init({ modelId = state.modelId, onProgress } = {}) {
    if (initPromise) return initPromise;
    if (state.status === 'ready' && state.loadedModelId === modelId) return Promise.resolve();
    this.setModel(modelId);
    update({ status: 'loading', error: null, progress: { fraction: 0, phase: 'prepare', mb: 0, text: '' } });
    initPromise = (async () => {
      try {
        if (!(await this.isWebGPUAvailable())) throw new Error('WebGPU or JSPI is not available');
        const a = await getAdapter();
        if (navigator.storage?.persist) navigator.storage.persist().catch(() => {});
        await chain.catch(() => {}); // let a running reply finish first
        const loaded = await a.load((p) => {
          const progress = { fraction: p.fraction, phase: p.phase, mb: p.mb || 0, text: '' };
          update({ progress });
          onProgress?.(progress);
        });
        update({ status: 'ready', loadedModelId: loaded, progress: { fraction: 1, phase: 'prepare', mb: 0, text: '' } });
      } catch (err) {
        console.error('[hearth] the model could not start:', err?.message || err);
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
   * request: { key, turns, assistantPrefix, opener, maxTokens, stop, sampling }
   * onToken(delta, fullTextSoFar) is called as text streams in.
   * Resolves with { text, stats }; stats.engine is 'demo' or 'pie:<model>'.
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
            if (cancelled) return { text: '', stats: { engine: 'pie', stoppedBy: 'cancelled' } };
            if (!isModelLost(err)) throw err;
            // Every later reply would fail too: say so (Settings and the chat offer to load it again)
            // and answer this one with labeled demo replies.
            update({ status: 'error', loadedModelId: null, progress: null, error: 'The graphics chip reset and the model stopped. Load it again to keep using it.' });
            (await getAdapter()).unload().catch(() => {});
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

  /**
   * One or two plain sentences about a photo (a data: URL), from the model's vision tower. Resolves with ''
   * when the model isn't loaded or it failed, and null when it was stopped. Waits its turn like a reply.
   */
  describePhoto(dataURL) {
    const run = async () => {
      if (state.status !== 'ready') return '';
      let cancelled = false;
      current = { cancel: async () => { cancelled = true; (await getAdapter()).interrupt(); } };
      try {
        const [{ photoForModel }, { cleanCaption }] = await Promise.all([import('../media/photos.js'), import('../brain/parse.js')]);
        const { text } = await (await getAdapter()).caption(await photoForModel(dataURL), { maxTokens: 48 });
        return cancelled ? null : cleanCaption(text);
      } catch (err) {
        if (cancelled) return null;
        console.error('[hearth] describing the photo failed:', String(err?.message || err).slice(0, 200));
        return '';
      } finally {
        current = null;
      }
    };
    const result = chain.then(run, run);
    chain = result.catch(() => {});
    return result;
  },

  /** Stops the reply (or photo description) that is running right now. */
  cancel() { current?.cancel(); },

  async isCached(modelId = state.modelId) {
    if (!MODELS.some((m) => m.id === modelId) || !(await this.isWebGPUAvailable())) return false;
    try { return await (await getAdapter()).hasModel(); } catch { return false; }
  },

  /** Deletes the downloaded model. Falls back to demo replies if it was loaded. */
  async deleteModel(modelId = state.modelId) {
    const a = await getAdapter();
    const wasLoaded = state.loadedModelId === modelId;
    await a.deleteModel();
    if (wasLoaded || state.status === 'error') update({ status: 'demo', loadedModelId: null, progress: null, error: null });
  },

  /** Deletes Hearth's downloaded model (used by "Delete everything"). */
  async deleteAllModels() {
    try {
      await (await getAdapter()).deleteModel();
    } catch { /* storage blocked: nothing was saved there either */ }
    update({ status: 'demo', loadedModelId: null, progress: null, error: null });
  },
};
