// Hand-drawn 24x24 line icons used across the web app.
// icon('compass') returns an <svg> element; registerIcon() lets other modules add their own.

const NS = 'http://www.w3.org/2000/svg';

// Each icon is a list of [tag, attributes]. A third item `true` means "filled" instead of stroked.
const ICONS = {
  plus: [['path', { d: 'M12 5v14M5 12h14' }]],
  compass: [['circle', { cx: 12, cy: 12, r: 9 }], ['path', { d: 'M15.5 8.5l-2 5-5 2 2-5 5-2z' }]],
  map: [['path', { d: 'M9 4L3.5 6.3v13.4L9 17.5l6 2.5 5.5-2.3V4.3L15 6.5 9 4z' }], ['path', { d: 'M9 4v13.5M15 6.5V20' }]],
  search: [['circle', { cx: 11, cy: 11, r: 6.5 }], ['path', { d: 'M20 20l-4.3-4.3' }]],
  settings: [['path', { d: 'M4 7h9M17 7h3M4 17h4M12 17h8' }], ['circle', { cx: 15, cy: 7, r: 2.2 }], ['circle', { cx: 10, cy: 17, r: 2.2 }]],
  sun: [['circle', { cx: 12, cy: 12, r: 4 }], ['path', { d: 'M12 2.5v2M12 19.5v2M4.6 4.6L6 6M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4L6 18M18 6l1.4-1.4' }]],
  moon: [['path', { d: 'M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z' }]],
  menu: [['path', { d: 'M4 7h16M4 12h16M4 17h16' }]],
  'chevron-left': [['path', { d: 'M15 5.5L8.5 12l6.5 6.5' }]],
  'chevron-right': [['path', { d: 'M9 5.5l6.5 6.5L9 18.5' }]],
  'chevron-down': [['path', { d: 'M6 9l6 6 6-6' }]],
  'arrow-left': [['path', { d: 'M19 12H5M11 6l-6 6 6 6' }]],
  'arrow-up': [['path', { d: 'M12 19V5M6 11l6-6 6 6' }]],
  more: [['circle', { cx: 5.5, cy: 12, r: 1.7 }, true], ['circle', { cx: 12, cy: 12, r: 1.7 }, true], ['circle', { cx: 18.5, cy: 12, r: 1.7 }, true]],
  image: [['rect', { x: 3, y: 4.5, width: 18, height: 15, rx: 3 }], ['circle', { cx: 9, cy: 10, r: 1.8 }], ['path', { d: 'M20.5 15.5l-4.5-4.5-8.5 8.5' }]],
  play: [['path', { d: 'M8 5.5v13l10.5-6.5L8 5.5z' }, true]],
  pause: [['rect', { x: 6.5, y: 5, width: 3.8, height: 14, rx: 1.2 }, true], ['rect', { x: 13.7, y: 5, width: 3.8, height: 14, rx: 1.2 }, true]],
  star: [['path', { d: 'M12 3.8l2.5 5.1 5.6.8-4 3.9.9 5.6-5-2.6-5 2.6.9-5.6-4-3.9 5.6-.8L12 3.8z' }]],
  'star-fill': [['path', { d: 'M12 3.8l2.5 5.1 5.6.8-4 3.9.9 5.6-5-2.6-5 2.6.9-5.6-4-3.9 5.6-.8L12 3.8z' }, true]],
  refresh: [['path', { d: 'M19.5 12a7.5 7.5 0 1 1-2.2-5.3' }], ['path', { d: 'M19.5 4.5v4h-4' }]],
  copy: [['rect', { x: 9, y: 9, width: 11, height: 11, rx: 2.5 }], ['path', { d: 'M15 9V6.5A2.5 2.5 0 0 0 12.5 4h-6A2.5 2.5 0 0 0 4 6.5v6A2.5 2.5 0 0 0 6.5 15H9' }]],
  edit: [['path', { d: 'M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16v4z' }], ['path', { d: 'M13.5 6.5l4 4' }]],
  trash: [['path', { d: 'M4 7h16M9.5 7V4.5h5V7M6 7l1 13h10l1-13M10 11v5.5M14 11v5.5' }]],
  pin: [['path', { d: 'M9 3.5h6l-1 6.5 4 3.5H6l4-3.5-1-6.5zM12 13.5V21' }]],
  volume: [['path', { d: 'M4 9.5v5h3.5L12 18V6L7.5 9.5H4z' }], ['path', { d: 'M15.5 9a4.2 4.2 0 0 1 0 6M18 6.5a7.8 7.8 0 0 1 0 11' }]],
  x: [['path', { d: 'M6 6l12 12M18 6L6 18' }]],
  phone: [['rect', { x: 6.5, y: 2.5, width: 11, height: 19, rx: 2.8 }], ['path', { d: 'M10.5 18.5h3' }]],
  download: [['path', { d: 'M12 4v11M7 10l5 5 5-5M5 20h14' }]],
  upload: [['path', { d: 'M12 20V9M7 14l5-5 5 5M5 4h14' }]],
  shield: [['path', { d: 'M12 3l7.5 3v6c0 4.6-3.1 7.7-7.5 9-4.4-1.3-7.5-4.4-7.5-9V6L12 3z' }], ['path', { d: 'M8.8 12.2l2.2 2.2 4.3-4.6' }]],
  lock: [['rect', { x: 5, y: 10.5, width: 14, height: 10, rx: 2.5 }], ['path', { d: 'M8 10.5V8a4 4 0 0 1 8 0v2.5' }]],
  sparkle: [['path', { d: 'M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1L5 10.5l5.1-1.9L12 3.5z' }], ['path', { d: 'M18.5 16.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7.7-1.8z' }]],
  message: [['path', { d: 'M20 11.5a8 8 0 0 1-11.7 7.1L4 20l1.3-4.1A8 8 0 1 1 20 11.5z' }]],
  clock: [['circle', { cx: 12, cy: 12, r: 8.5 }], ['path', { d: 'M12 7.5V12l3 2' }]],
  'map-pin': [['path', { d: 'M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11z' }], ['circle', { cx: 12, cy: 10, r: 2.3 }]],
  users: [['circle', { cx: 9, cy: 8, r: 3.5 }], ['path', { d: 'M2.5 20a6.5 6.5 0 0 1 13 0M15.5 4.6a3.5 3.5 0 0 1 0 6.8M17.5 14a6.5 6.5 0 0 1 4 6' }]],
  heart: [['path', { d: 'M12 20s-7.5-4.6-9.2-9.4A4.9 4.9 0 0 1 12 6.8a4.9 4.9 0 0 1 9.2 3.8C19.5 15.4 12 20 12 20z' }]],
  sidebar: [['rect', { x: 3, y: 4, width: 18, height: 16, rx: 3 }], ['path', { d: 'M9.5 4v16' }]],
  stop: [['rect', { x: 7, y: 7, width: 10, height: 10, rx: 2 }, true]],
  check: [['path', { d: 'M5 12.5l4.5 4.5L19 7.5' }]],
  history: [['path', { d: 'M4 12a8 8 0 1 0 2.4-5.7' }], ['path', { d: 'M4 4.5V8h3.5M12 8v4.3l3 1.9' }]],
  user: [['circle', { cx: 12, cy: 8.5, r: 4 }], ['path', { d: 'M4.5 20.5a7.5 7.5 0 0 1 15 0' }]],
  info: [['circle', { cx: 12, cy: 12, r: 8.5 }], ['path', { d: 'M12 11v5.5M12 7.8v.2' }]],
  wave: [['path', { d: 'M4 11v2M8 8v8M12 5v14M16 8.5v7M20 10.5v3' }]],
  text: [['path', { d: 'M5 6.5h14M5 12h14M5 17.5h9' }]],
  home: [['path', { d: 'M4 11l8-7 8 7v8.5a1 1 0 0 1-1 1h-4.5v-6h-5v6H5a1 1 0 0 1-1-1V11z' }]],
  globe: [['circle', { cx: 12, cy: 12, r: 8.5 }], ['path', { d: 'M3.5 12h17M12 3.5c2.5 2.6 3.5 5.4 3.5 8.5s-1 5.9-3.5 8.5M12 3.5C9.5 6.1 8.5 8.9 8.5 12s1 5.9 3.5 8.5' }]],
  chip: [['rect', { x: 6.5, y: 6.5, width: 11, height: 11, rx: 2 }], ['path', { d: 'M10 3.5v3M14 3.5v3M10 17.5v3M14 17.5v3M3.5 10h3M3.5 14h3M17.5 10h3M17.5 14h3' }]],
  lifebuoy: [['circle', { cx: 12, cy: 12, r: 8.5 }], ['circle', { cx: 12, cy: 12, r: 3.5 }], ['path', { d: 'M6 6l3.5 3.5M14.5 14.5L18 18M18 6l-3.5 3.5M9.5 14.5L6 18' }]],
  database: [['ellipse', { cx: 12, cy: 6, rx: 7, ry: 2.8 }], ['path', { d: 'M5 6v12c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8V6M5 12c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8' }]],
  palette: [['path', { d: 'M12 3.5a8.5 8.5 0 0 0 0 17c1.2 0 1.8-.8 1.8-1.7 0-1.2-1-1.6-1-2.6 0-1 .8-1.7 1.8-1.7h2.2a3.7 3.7 0 0 0 3.7-3.7C20.5 7 16.7 3.5 12 3.5z' }], ['circle', { cx: 7.8, cy: 11, r: 1.1 }, true], ['circle', { cx: 10.5, cy: 7.3, r: 1.1 }, true], ['circle', { cx: 15, cy: 7.8, r: 1.1 }, true]],
  flame: [['path', { d: 'M12 21c-3.9 0-6.5-2.6-6.5-6.1 0-3.4 2.5-5.2 3.6-8 .4 1.7 1.3 2.9 2.4 3.6.2-2.6 1.4-5 3.4-6.5-.2 2.6.9 4.4 2.2 6 1.2 1.5 1.9 3.1 1.9 4.9 0 3.5-3 6.1-7 6.1z' }]],
  bell: [['path', { d: 'M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15l1.5-2zM10 20.5a2 2 0 0 0 4 0' }]],
};

/** Adds or replaces an icon. `parts` is a list of [tag, attrs, filled?]. */
export function registerIcon(name, parts) { ICONS[name] = parts; }

export function hasIcon(name) { return Object.prototype.hasOwnProperty.call(ICONS, name); }

/**
 * Returns an <svg> element. `name` can be a known icon name or a raw '<svg ...>' string.
 * Icons are decorative (aria-hidden) unless a `title` is given.
 */
export function icon(name, { size = 20, className = '', title = '' } = {}) {
  if (typeof name === 'string' && name.trim().startsWith('<svg')) {
    const tpl = document.createElement('template');
    tpl.innerHTML = name.trim();
    const svg = tpl.content.firstElementChild;
    if (svg) {
      svg.setAttribute('width', size);
      svg.setAttribute('height', size);
      svg.setAttribute('aria-hidden', 'true');
      if (className) svg.setAttribute('class', className);
      return svg;
    }
  }
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.8');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  if (className) svg.setAttribute('class', className);
  if (title) {
    svg.setAttribute('role', 'img');
    const t = document.createElementNS(NS, 'title');
    t.textContent = title;
    svg.appendChild(t);
  } else {
    svg.setAttribute('aria-hidden', 'true');
  }
  for (const [tag, attrs, filled] of ICONS[name] || ICONS.sparkle) {
    const el = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
    if (filled) { el.setAttribute('fill', 'currentColor'); el.setAttribute('stroke', 'none'); }
    svg.appendChild(el);
  }
  return svg;
}

/** The Hearth mark (a little lantern flame inside a rounded square) used when the logo file is missing. */
let markCount = 0;
export function hearthMark(size = 32) {
  const n = ++markCount;
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 64 64');
  svg.setAttribute('width', size);
  svg.setAttribute('height', size);
  svg.setAttribute('aria-hidden', 'true');
  svg.innerHTML = `
    <defs>
      <linearGradient id="hm-bg-${n}" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#FF9A5A"/><stop offset="1" stop-color="#E8682E"/>
      </linearGradient>
      <linearGradient id="hm-flame-${n}" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#FFF4DD"/><stop offset="1" stop-color="#F6C177"/>
      </linearGradient>
    </defs>
    <rect x="2" y="2" width="60" height="60" rx="18" fill="url(#hm-bg-${n})"/>
    <path d="M32 50c-7.2 0-12-4.7-12-11.1 0-6.2 4.6-9.5 6.6-14.6.8 3.1 2.4 5.3 4.4 6.6.4-4.8 2.6-9.1 6.2-11.9-.4 4.8 1.6 8 4 11 2.2 2.7 3.5 5.6 3.5 8.9C44.7 45.3 39.2 50 32 50z" fill="url(#hm-flame-${n})"/>
    <path d="M32 50c-3.3 0-5.6-2.2-5.6-5.1 0-2.8 2-4.3 3-6.6.5 1.6 1.4 2.6 2.4 3.1.3-2.1 1.2-3.7 2.6-4.9-.1 2.1.7 3.4 1.7 4.7.9 1.1 1.4 2.3 1.4 3.6 0 3-2.4 5.2-5.5 5.2z" fill="#E8682E" opacity="0.9"/>
  `;
  return svg;
}
