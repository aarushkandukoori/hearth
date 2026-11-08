// Small shared helpers: ids, hashing, seeded randomness, timing and formatting.
// No DOM work here so brain/ and engine/ modules can use it too.

/** Random id (uses crypto when available). */
export function uid() {
  if (globalThis.crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  return 'id-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
}

/** Stable 32-bit hash of a string (FNV-1a). */
export function hash(str) {
  let h = 0x811c9dc5;
  const s = String(str);
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/** Seeded random number generator (mulberry32). Returns a function giving 0..1. */
export function seeded(seed) {
  let a = (typeof seed === 'number' ? seed : hash(seed)) >>> 0;
  return function next() {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Pick one item with a 0..1 random function. */
export function pick(list, rand = Math.random) {
  if (!list || list.length === 0) return undefined;
  return list[Math.floor(rand() * list.length) % list.length];
}

/** Shuffle a copy of a list with a 0..1 random function. */
export function shuffled(list, rand = Math.random) {
  const out = list.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function clamp(n, lo, hi) { return Math.min(hi, Math.max(lo, n)); }

export function debounce(fn, ms = 250) {
  let timer = null;
  const wrapped = (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
  wrapped.flush = (...args) => { clearTimeout(timer); fn(...args); };
  wrapped.cancel = () => clearTimeout(timer);
  return wrapped;
}

export function escapeRegExp(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

/** "just now", "5 min ago", "Yesterday", "Mon", "Mar 3". */
export function relativeTime(ms, now = Date.now()) {
  if (!ms) return '';
  const diff = Math.max(0, now - ms);
  const min = Math.round(diff / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min} min ago`;
  const d = new Date(ms);
  const today = new Date(now);
  const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
  if (ms >= startOfToday) return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  if (ms >= startOfToday - 86400000) return 'Yesterday';
  if (ms >= startOfToday - 6 * 86400000) return d.toLocaleDateString([], { weekday: 'short' });
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

/** Groups for a recent-chats list. */
export function dayGroup(ms, now = Date.now()) {
  const today = new Date(now);
  const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
  if (ms >= startOfToday) return 'Today';
  if (ms >= startOfToday - 86400000) return 'Yesterday';
  if (ms >= startOfToday - 6 * 86400000) return 'This week';
  return 'Earlier';
}

/** 0:07 style duration. */
export function formatDuration(seconds) {
  const s = Math.max(0, Math.round(seconds || 0));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 MB';
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`;
  if (bytes >= 1e6) return `${Math.round(bytes / 1e6)} MB`;
  return `${Math.max(1, Math.round(bytes / 1e3))} KB`;
}

export function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : ''; }

export function prefersReducedMotion() {
  return typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/** Replace {{user}} / {{char}} placeholders (Character Card style). */
export function fillNames(text, { user, char }) {
  return String(text || '')
    .replace(/\{\{\s*user\s*\}\}/gi, user || 'Friend')
    .replace(/\{\{\s*char\s*\}\}/gi, char || '');
}

/** Tiny publish/subscribe hub. */
export function createEmitter() {
  const map = new Map();
  return {
    on(topic, fn) {
      if (!map.has(topic)) map.set(topic, new Set());
      map.get(topic).add(fn);
      return () => map.get(topic)?.delete(fn);
    },
    emit(topic, payload) {
      for (const fn of map.get(topic) || []) {
        try { fn(payload); } catch (err) { console.error('[hearth] listener failed:', err?.name || 'Error'); }
      }
    },
  };
}

/** The site root (docs/), resolved from this module's own URL so it works on any host or subpath. */
export const SITE_ROOT = new URL('../../', import.meta.url);

/** Absolute URL for a path relative to the site root, e.g. siteURL('assets/art/char-juno.jpg'). */
export function siteURL(path) { return new URL(path, SITE_ROOT).href; }
