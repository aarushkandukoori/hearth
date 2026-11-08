// Theme choice: 'system' (follow the device), 'light' or 'dark'. Saved in localStorage only
// (it is needed before IndexedDB opens, to avoid a flash). boot-theme.js applies it on first paint.

const KEY = 'hearth.theme';
const listeners = new Set();
const media = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: light)') : null;

export function getTheme() {
  try {
    const v = localStorage.getItem(KEY);
    return v === 'light' || v === 'dark' ? v : 'system';
  } catch {
    return 'system';
  }
}

/** The theme actually showing right now: 'light' or 'dark'. */
export function effectiveTheme() {
  const t = getTheme();
  if (t !== 'system') return t;
  return media?.matches ? 'light' : 'dark';
}

function apply() {
  const t = getTheme();
  const root = document.documentElement;
  if (t === 'system') delete root.dataset.theme;
  else root.dataset.theme = t;
  const color = effectiveTheme() === 'light' ? '#FBF7F2' : '#141110';
  document.querySelectorAll('meta[name="theme-color"]').forEach((m) => m.setAttribute('content', color));
  for (const fn of listeners) fn(t, effectiveTheme());
}

export function setTheme(t) {
  try {
    if (t === 'light' || t === 'dark') localStorage.setItem(KEY, t);
    else localStorage.removeItem(KEY);
  } catch { /* private mode: the choice lasts until reload */
    if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
  }
  apply();
}

/** Flips between light and dark (leaving 'system'). */
export function toggleTheme() { setTheme(effectiveTheme() === 'light' ? 'dark' : 'light'); }

export function onThemeChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

media?.addEventListener?.('change', () => { if (getTheme() === 'system') apply(); });
apply();
