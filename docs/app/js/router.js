// Hash router (#/path?query). Routes are registered by pattern so other modules can add or replace them:
//   registerRoute('/town/:locationId', (ctx) => node)
// render(ctx) gets { params, query, path, outlet, signal, setTitle } and returns a Node (or fills outlet).
// ctx.signal aborts when the user leaves the route, which is the place to clean up timers and listeners.

export { registerNav } from './nav.js';

const routes = [];
const listeners = new Set();
let outletEl = null;
let started = false;
let current = null;      // { path, query, params, route, controller }
let renderCount = 0;
// How many Hearth pages deep this history entry is (1 = the first one), kept in history.state so it
// survives Back, Forward and reloads. "Back" only uses history.back() when the entry before is Hearth's.
let depth = 0;

function compile(pattern) {
  const parts = pattern.replace(/^#/, '').split('/').filter(Boolean);
  return {
    parts,
    statics: parts.filter((p) => !p.startsWith(':') && p !== '*').length,
    wildcard: parts[parts.length - 1] === '*',
  };
}

function match(route, segments) {
  const { parts, wildcard } = route.compiled;
  if (wildcard ? segments.length < parts.length - 1 : segments.length !== parts.length) return null;
  const params = {};
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    if (p === '*') { params.rest = segments.slice(i).join('/'); return params; }
    const seg = segments[i];
    if (p.startsWith(':')) {
      try { params[p.slice(1)] = decodeURIComponent(seg); } catch { params[p.slice(1)] = seg; }
    } else if (p !== seg) return null;
  }
  return params;
}

/** Adds a route, or replaces one with the same pattern (re-renders if it is showing). */
export function registerRoute(pattern, render, { title = null } = {}) {
  const normalized = `/${compile(pattern).parts.join('/')}`;
  const existing = routes.find((r) => r.pattern === normalized);
  const entry = { pattern: normalized, render, title, compiled: compile(normalized) };
  if (existing) Object.assign(existing, entry);
  else routes.push(entry);
  if (started && current?.route?.pattern === normalized) rerender();
}

/** Parses the current location.hash into { path, query, segments }. */
export function parseHash(hash = location.hash) {
  const raw = hash.replace(/^#/, '') || '/';
  const [pathPart, queryPart = ''] = raw.split('?');
  const path = `/${pathPart.split('/').filter(Boolean).join('/')}`;
  const query = Object.fromEntries(new URLSearchParams(queryPart));
  return { path, query, segments: path.split('/').filter(Boolean) };
}

function resolve(segments) {
  let best = null;
  for (const route of routes) {
    const params = match(route, segments);
    if (!params) continue;
    const score = route.compiled.statics * 10 + route.compiled.parts.length - (route.compiled.wildcard ? 5 : 0);
    if (!best || score > best.score) best = { route, params, score };
  }
  return best;
}

/** Goes to an href like '#/c/juno'. replace: no new history entry. silent: change the URL only. */
export function navigate(href, { replace = false, silent = false } = {}) {
  const hash = href.startsWith('#') ? href : `#${href.startsWith('/') ? '' : '/'}${href}`;
  if (silent) {
    history.replaceState(history.state, '', hash); // replaceState never fires hashchange
    if (current) current.path = parseHash(hash).path;
    for (const fn of listeners) fn({ ...currentRoute() });
    return;
  }
  if (replace) {
    history.replaceState(history.state, '', hash);
    rerender();
  } else if (location.hash === hash) {
    rerender();
  } else {
    location.hash = hash;
  }
}

/** True when the previous history entry is a page of this app (so history.back() stays in Hearth). */
export function canGoBack() { return depth > 1; }

/** Reads this entry's depth, or gives a new entry the next one (replaced entries keep theirs). */
function trackDepth() {
  const saved = history.state?.hearthDepth;
  if (Number.isInteger(saved) && saved > 0) {
    depth = saved;
    return;
  }
  depth += 1;
  try { history.replaceState({ ...(history.state || {}), hearthDepth: depth }, ''); } catch { /* state blocked */ }
}

/**
 * After a page change, focus moves to the new page's heading so keyboard and screen reader users land
 * on it and hear its name. Focus stays put while typing in a field outside the page (the sidebar search).
 */
function focusPage(outlet) {
  const active = document.activeElement;
  const typing = active && active !== document.body && !outlet.contains(active) && active.matches?.('input, textarea, select, [contenteditable="true"]');
  if (typing) return;
  const heading = outlet.querySelector('h1');
  if (heading && !heading.hasAttribute('tabindex')) heading.setAttribute('tabindex', '-1');
  (heading || outlet).focus({ preventScroll: true });
}

export function currentRoute() {
  return current ? { path: current.path, query: current.query, params: current.params, pattern: current.route?.pattern } : parseHash();
}

/** Called with the route info after every render. Returns an unsubscribe function. */
export function onRoute(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function setTitle(title) {
  document.title = title ? `${title} - Hearth` : 'Hearth - A little town of friends';
}

export async function rerender() {
  if (!outletEl) return;
  const { path, query, segments } = parseHash();
  const found = resolve(segments) || resolve(['__notfound']);
  current?.controller?.abort();
  const controller = new AbortController();
  const ticket = ++renderCount;
  const firstRender = ticket === 1;
  trackDepth();
  current = { path, query, params: found?.params || {}, route: found?.route || null, controller };
  document.documentElement.dataset.route = found?.route ? (found.route.compiled.parts[0] || 'home') : 'notfound';
  setTitle(found?.route?.title || null);

  const outlet = outletEl;
  outlet.setAttribute('aria-busy', 'true');
  const ctx = { params: current.params, query, path, outlet, signal: controller.signal, setTitle };
  try {
    const result = found ? await found.route.render(ctx) : null;
    if (ticket !== renderCount) return; // a newer navigation won
    if (result instanceof Node) {
      outlet.replaceChildren(result);
    }
    window.scrollTo(0, 0);
    if (!firstRender) focusPage(outlet);
  } catch (err) {
    if (ticket !== renderCount) return;
    console.error('[hearth] page failed to render:', err?.name || 'Error');
    const box = document.createElement('div');
    box.className = 'page-error';
    const h = document.createElement('h1');
    h.textContent = 'Something went wrong on this page.';
    const p = document.createElement('p');
    p.textContent = 'Your chats are safe. Try going back to Discover.';
    const a = document.createElement('a');
    a.className = 'btn btn-secondary';
    a.href = '#/';
    a.textContent = 'Back to Discover';
    box.append(h, p, a);
    outlet.replaceChildren(box);
  } finally {
    if (ticket === renderCount) {
      outlet.removeAttribute('aria-busy');
      for (const fn of listeners) fn({ ...currentRoute() });
    }
  }
}

/** Starts listening to hash changes and renders the first page into `outlet`. */
export function start(outlet) {
  outletEl = outlet;
  if (started) return rerender();
  started = true;
  window.addEventListener('hashchange', () => rerender());
  return rerender();
}
