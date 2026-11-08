// The illustrated Lantern Bay map: sea, coast, hills and roads drawn in SVG, little houses, trees and
// boats on top, the town art as a soft backdrop, and one pin per place showing who is there.
// Places use the normalized location.map x/y (0..1) from the world file.

import { h, avatar, attachImage, artURL } from '../ui/components.js';
import { whoIsAt } from '../brain/director.js';

// Places sit inside an inset frame so pins near the edges keep their labels on the map.
// world.css uses the same numbers (8% and 9%) to place pins and decorations.
const PAD_X = 8;
const PAD_Y = 9;
const X = (u) => PAD_X + u * (100 - 2 * PAD_X);
const Y = (v) => PAD_Y + v * (100 - 2 * PAD_Y);
const r2 = (n) => Number(n.toFixed(2));

// Terrain in the same 0..1 space as the places (values outside 0..1 run off the edge of the map).
const COAST = [[-0.2, -0.2], [1.2, -0.2], [1.2, 0.5], [1.06, 0.55], [0.98, 0.6], [0.93, 0.64], [0.96, 0.71],
  [0.93, 0.79], [0.86, 0.82], [0.8, 0.78], [0.76, 0.71], [0.68, 0.72], [0.62, 0.77], [0.56, 0.79], [0.46, 0.79],
  [0.4, 0.75], [0.32, 0.74], [0.25, 0.72], [0.19, 0.7], [0.12, 0.7], [0.07, 0.66], [0.05, 0.59], [0.06, 0.52],
  [0.02, 0.47], [-0.2, 0.45]];
const HILLS = [
  [[0.0, 0.06], [0.14, -0.03], [0.34, -0.02], [0.45, 0.12], [0.42, 0.3], [0.26, 0.37], [0.08, 0.33], [-0.03, 0.2]],
  [[0.5, -0.06], [0.72, -0.12], [0.95, -0.06], [1.08, 0.08], [1.02, 0.24], [0.84, 0.27], [0.64, 0.24], [0.52, 0.12]],
];
const ROADS = [
  [[0.52, 0.8], [0.51, 0.7], [0.5, 0.6], [0.51, 0.5], [0.52, 0.4]],           // Main Street, harbor to the square
  [[0.52, 0.4], [0.42, 0.34], [0.32, 0.3], [0.24, 0.22]],                     // up to the greenhouse
  [[0.52, 0.4], [0.58, 0.3], [0.64, 0.2], [0.72, 0.1]],                       // the hill path to the observatory
  [[0.52, 0.4], [0.64, 0.4], [0.74, 0.37], [0.82, 0.36]],                     // to the arcade
  [[0.15, 0.58], [0.26, 0.64], [0.4, 0.62], [0.5, 0.64]],                     // the boardwalk
  [[0.51, 0.6], [0.62, 0.6], [0.72, 0.64], [0.8, 0.68], [0.86, 0.72]],        // the coast road to the lighthouse
];
const FERRY = [[0.53, 0.95], [0.68, 1.0], [0.86, 1.04], [1.04, 1.06]];

// Little drawings on top of the terrain: [shape, u, v].
const DECOS = [
  ['plaza', 0.52, 0.4],
  ['pine', 0.05, 0.1], ['pine', 0.16, 0.05], ['pine', 0.1, 0.3], ['round', 0.35, 0.05], ['pine', 0.41, 0.25],
  ['round', 0.57, 0.04], ['pine', 0.88, 0.12], ['pine', 0.95, 0.25], ['round', 0.62, 0.2], ['round', 0.02, 0.38],
  ['round', 0.94, 0.46], ['pine', 0.3, 0.16],
  ['house', 0.33, 0.43], ['house', 0.42, 0.48], ['house', 0.6, 0.5], ['house', 0.68, 0.53], ['house', 0.27, 0.5],
  ['house', 0.75, 0.47], ['house', 0.62, 0.68],
  ['lamp', 0.505, 0.71], ['lamp', 0.5, 0.54], ['lamp', 0.3, 0.635], ['lamp', 0.67, 0.6], ['lamp', 0.66, 0.4], ['lamp', 0.38, 0.33],
  ['boat', 0.66, 0.9], ['boat', 0.36, 0.92], ['wave', 0.12, 0.84], ['wave', 0.24, 0.98], ['wave', 0.78, 0.99],
  ['wave', 1.03, 0.65], ['wave', 0.99, 0.92], ['wave', 0.01, 0.78],
  ['rock', 0.03, 0.69], ['rock', 0.1, 0.76], ['rock', 0.97, 0.8], ['rock', 0.91, 0.86],
  ['island', 1.03, 1.06], ['compass', -0.02, 0.98],
];

const SHAPES = {
  plaza: '',
  lamp: '',
  pine: '<svg viewBox="0 0 20 26"><path class="d-leaf" d="M10 1l7 11h-3.5l5 8H1.5l5-8H3z"/><rect class="d-trunk" x="8.6" y="20" width="2.8" height="5" rx="1"/></svg>',
  round: '<svg viewBox="0 0 22 24"><circle class="d-leaf" cx="11" cy="9.5" r="8.5"/><circle class="d-leaf-hi" cx="8" cy="7" r="3.4"/><rect class="d-trunk" x="9.6" y="16" width="2.8" height="7" rx="1"/></svg>',
  house: '<svg viewBox="0 0 24 22"><path class="d-roof" d="M1.5 10.5L12 2.2l10.5 8.3z"/><rect class="d-wall" x="4.2" y="10" width="15.6" height="10.8" rx="1"/><rect class="d-window" x="7" y="12.6" width="3.8" height="3.8" rx=".6"/><rect class="d-door" x="13.4" y="13.6" width="3.6" height="7.2" rx=".6"/></svg>',
  boat: '<svg viewBox="0 0 26 22"><path class="d-sail" d="M12.6 1.5v13.5H4.5z"/><path class="d-sail2" d="M14.2 4.5v10.5h6.5z"/><path class="d-hull" d="M1.5 16h23l-3.6 4.6H5.1z"/></svg>',
  wave: '<svg viewBox="0 0 28 8"><path class="d-wave" d="M1 5.5c3-4 6-4 9 0s6 4 9 0 6-4 8-1"/></svg>',
  rock: '<svg viewBox="0 0 22 14"><path class="d-rock" d="M2 12.5c0-4 3-8.2 7-9.2s9.2.2 11 5.2c.6 1.8 0 4-1 4z"/><path class="d-rock-hi" d="M6 7.5c1-2 2.6-3 4.6-3.3"/></svg>',
  island: '<svg viewBox="0 0 64 34"><ellipse class="d-foam" cx="32" cy="27" rx="30" ry="6.5"/><ellipse class="d-sand" cx="32" cy="25.5" rx="24" ry="5.5"/><path class="d-isle" d="M14 25c4-6 12-9 20-8.5S48 21 50 25z"/><path class="d-palm" d="M33 18c.5-4 1.5-8 3.5-11"/><path class="d-leaf" d="M36.5 7c-4-2-8-1.5-10 1 3-.5 6 0 10-1zm0 0c3-3 7-3.5 9.5-2-3 .3-6.2 1-9.5 2zm0 0c1.5 3 1.5 6 .5 8.5-.8-3-1-5.5-.5-8.5z"/></svg>',
  compass: '<svg viewBox="0 0 40 40"><circle class="d-compass" cx="20" cy="20" r="15"/><path class="d-needle-n" d="M20 6l4 14h-8z"/><path class="d-needle-s" d="M20 34l-4-14h8z"/><text class="d-n" x="20" y="4.6" text-anchor="middle">N</text></svg>',
};

/** Catmull-Rom curve through points (in place space), as an SVG path in map space. */
function smooth(points, closed = false) {
  const p = points.map(([u, v]) => [X(u), Y(v)]);
  const n = p.length;
  const at = (i) => (closed ? p[(i + n) % n] : p[Math.max(0, Math.min(n - 1, i))]);
  let d = `M${r2(p[0][0])} ${r2(p[0][1])}`;
  for (let i = 0; i < (closed ? n : n - 1); i++) {
    const [p0, p1, p2, p3] = [at(i - 1), at(i), at(i + 1), at(i + 2)];
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += ` C${r2(c1[0])} ${r2(c1[1])} ${r2(c2[0])} ${r2(c2[1])} ${r2(p2[0])} ${r2(p2[1])}`;
  }
  return closed ? `${d} Z` : d;
}

/** The same outline pulled toward its middle (for contour lines on the hills). */
function shrink(points, k) {
  const cu = points.reduce((s, p) => s + p[0], 0) / points.length;
  const cv = points.reduce((s, p) => s + p[1], 0) / points.length;
  return points.map(([u, v]) => [cu + (u - cu) * k, cv + (v - cv) * k]);
}

/** Builds DOM from a fixed markup string (only numbers and class names go into it, never world text). */
function fromMarkup(markup) {
  const tpl = document.createElement('template');
  tpl.innerHTML = markup.trim();
  return tpl.content;
}

function terrain(locations) {
  const coast = smooth(COAST, true);
  const hills = HILLS.map((pts) => `<path class="tm-hill" d="${smooth(pts, true)}"/>`
    + [0.68, 0.38].map((k) => `<path class="tm-contour" d="${smooth(shrink(pts, k), true)}"/>`).join('')).join('');
  const roads = ROADS.map((r) => smooth(r));
  const glows = locations.map((l) => `<ellipse class="tm-glow" fill="url(#tm-glow)" cx="${r2(X(l.map.x))}" cy="${r2(Y(l.map.y))}" rx="9" ry="9"/>`).join('');
  return fromMarkup(`
    <svg class="tmap-terrain" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true" focusable="false">
      <defs>
        <linearGradient id="tm-sea" x1="0" y1="0" x2="0" y2="1"><stop offset="0" class="tm-sea-a"/><stop offset="1" class="tm-sea-b"/></linearGradient>
        <linearGradient id="tm-land" x1="0" y1="0" x2="0" y2="1"><stop offset="0" class="tm-land-a"/><stop offset="1" class="tm-land-b"/></linearGradient>
        <radialGradient id="tm-glow"><stop offset="0" class="tm-glow-a"/><stop offset="1" class="tm-glow-b"/></radialGradient>
        <radialGradient id="tm-shine"><stop offset="0" class="tm-shine-a"/><stop offset="1" class="tm-shine-b"/></radialGradient>
      </defs>
      <rect class="tm-sea" fill="url(#tm-sea)" width="100" height="100"/>
      <ellipse class="tm-shine" fill="url(#tm-shine)" cx="74" cy="95" rx="34" ry="11"/>
      <ellipse class="tm-pool" cx="${r2(X(0.035))}" cy="${r2(Y(0.62))}" rx="1.4" ry="1.1"/>
      <ellipse class="tm-pool" cx="${r2(X(0.085))}" cy="${r2(Y(0.715))}" rx="1.1" ry="0.9"/>
      <path class="tm-foam" d="${coast}"/>
      <path class="tm-beach" d="${coast}"/>
      <path class="tm-land" fill="url(#tm-land)" d="${coast}"/>
      ${hills}
      ${roads.map((d) => `<path class="tm-road-edge" d="${d}"/>`).join('')}
      ${roads.map((d) => `<path class="tm-road" d="${d}"/>`).join('')}
      <path class="tm-pier" d="M${r2(X(0.52))} ${r2(Y(0.77))}V${r2(Y(0.94))}"/>
      <path class="tm-ferry" d="${smooth(FERRY)}"/>
      ${glows}
    </svg>`);
}

function decorations() {
  const items = DECOS.map(([shape, u, v]) => `<span class="tmap-deco deco-${shape}" style="--x:${u};--y:${v}">${SHAPES[shape] || ''}</span>`);
  const layer = h('div', { class: 'tmap-decos', 'aria-hidden': 'true' });
  layer.append(fromMarkup(items.join('')));
  return layer;
}

/** "Juno", "Juno and Theo", "Juno, Theo and Mika". */
export function listNames(people) {
  const names = people.map((c) => c.name);
  if (names.length <= 1) return names.join('');
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

/** "Driftwood Cafe" -> "Cafe", "The Night Market" -> "Market": short labels for small maps. */
function shortName(name) {
  const words = String(name || '').replace(/^The\s+/i, '').split(/\s+/);
  return words[words.length - 1] || name;
}

function pin(loc, people, { part, now }) {
  const shown = people.slice(0, 3);
  const more = people.length - shown.length;
  const when = now ? 'Here now' : `Here in the ${part}`;
  const label = `${loc.name}. ${people.length ? `${when}: ${listNames(people)}.` : (now ? 'Nobody is here right now.' : `Nobody is here in the ${part}.`)}`;
  return h('a', {
    class: `tmap-pin${people.length ? '' : ' empty'}`, href: `#/town/${encodeURIComponent(loc.id)}`,
    'aria-label': label, title: loc.name, dataset: { loc: loc.id },
    style: { '--x': loc.map?.x ?? 0.5, '--y': loc.map?.y ?? 0.5, '--pin': loc.art?.colors?.[1] || '#FF8A4C', zIndex: String(10 + Math.round((loc.map?.y ?? 0.5) * 100)) },
  },
  h('span', { class: 'tmap-pin-marker', 'aria-hidden': 'true' }, h('span', { class: 'tmap-pin-emoji' }, loc.emoji || loc.art?.emoji || '📍')),
  people.length ? h('span', { class: 'tmap-pin-people', 'aria-hidden': 'true' },
    shown.map((c) => avatar(c, { size: 26 })),
    more > 0 ? h('span', { class: 'tmap-pin-more' }, `+${more}`) : null) : null,
  h('span', { class: 'tmap-pin-label', 'aria-hidden': 'true' },
    h('span', { class: 'full' }, loc.name), h('span', { class: 'short' }, shortName(loc.name))));
}

const NIGHTISH = new Set(['evening', 'night']);

/**
 * Creates the map. Returns { el, update({ part, nowPart, characters }), highlight(locationID) }.
 * `characters` are everyone who might be out in town; each pin shows who is at that place during `part`.
 */
export function townMap({ locations = [], characters = [], part, nowPart, badge = null }) {
  const backdrop = h('div', { class: 'tmap-backdrop', 'aria-hidden': 'true' });
  const pins = h('div', { class: 'tmap-pins' });
  const map = h('div', { class: 'tmap', role: 'group' });
  map.append(backdrop, terrain(locations), decorations(), pins);
  if (badge) map.append(badge);
  const frame = h('div', { class: 'tmap-frame' }, map);

  let backdropArt = null;
  function update(next = {}) {
    part = next.part || part;
    nowPart = next.nowPart || nowPart;
    if (next.characters) characters = next.characters;
    map.dataset.part = part;
    map.setAttribute('aria-label', `Map of Lantern Bay${part === nowPart ? ' right now' : `, ${part}`}`);
    const art = NIGHTISH.has(part) ? 'hero-night' : 'hero-town';
    if (art !== backdropArt) {
      backdropArt = art;
      backdrop.replaceChildren();
      backdrop.classList.remove('has-img');
      attachImage(backdrop, artURL(art), { alt: '' });
    }
    const sorted = locations.slice().sort((a, b) => (a.map?.y ?? 0) - (b.map?.y ?? 0));
    pins.replaceChildren(...sorted.map((loc) => pin(loc, whoIsAt(loc.id, part, characters), { part, now: part === nowPart })));
  }

  let flashTimer = null;
  function highlight(locationID) {
    const el = pins.querySelector(`[data-loc="${CSS.escape(locationID)}"]`);
    if (!el) return;
    pins.querySelectorAll('.flash').forEach((p) => p.classList.remove('flash'));
    void el.offsetWidth; // restart the animation
    el.classList.add('flash');
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => el.classList.remove('flash'), 2600);
  }

  update({ part, nowPart });
  return { el: frame, map, update, highlight };
}
