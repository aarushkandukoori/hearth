// Reusable UI pieces: h() element builder, avatar(), characterCard(), modal(), toast(), menu(),
// confirm() and a few small controls. Everything builds real DOM nodes (no innerHTML with user text).

import { icon } from './icons.js';
import { siteURL, hash } from '../util.js';
import { whereNow } from '../data.js';
import { ART_THUMBS } from '../art-thumbs.js';

/**
 * h('button', { class: 'btn', onClick: fn, 'aria-label': 'Send' }, 'Send')
 * attrs: class/className, style (object or string, '--vars' ok), dataset, on<Event> handlers,
 * ref (called with the element), boolean attributes (true -> present, false/null -> absent).
 * children: strings, numbers, Nodes, arrays, null/false (skipped).
 */
export function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [key, value] of Object.entries(attrs)) {
      if (value == null || value === false) continue;
      if (key === 'class' || key === 'className') el.className = value;
      else if (key === 'style') {
        if (typeof value === 'string') el.style.cssText = value;
        else for (const [k, v] of Object.entries(value)) {
          if (v == null) continue;
          if (k.startsWith('--')) el.style.setProperty(k, v);
          else el.style[k] = v;
        }
      } else if (key === 'dataset') Object.assign(el.dataset, value);
      else if (key === 'ref' && typeof value === 'function') value(el);
      else if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2).toLowerCase(), value);
      else if (key === 'value' && 'value' in el) el.value = value;
      else if (key === 'checked' || key === 'selected' || key === 'disabled') el[key] = !!value;
      else if (value === true) el.setAttribute(key, '');
      else el.setAttribute(key, String(value));
    }
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const child of children) {
    if (child == null || child === false || child === true) continue;
    if (Array.isArray(child)) append(el, child);
    else if (child instanceof Node) el.appendChild(child);
    else el.appendChild(document.createTextNode(String(child)));
  }
}

/** Removes all children (and returns the element). */
export function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }

/** Adds a stylesheet once. Resolves when it has loaded (or failed). */
export function loadStyle(href) {
  const url = new URL(href, document.baseURI).href;
  const existing = [...document.querySelectorAll('link[rel="stylesheet"]')].find((l) => l.href === url);
  if (existing) return Promise.resolve(existing);
  return new Promise((resolve) => {
    const link = h('link', { rel: 'stylesheet', href: url });
    link.addEventListener('load', () => resolve(link), { once: true });
    link.addEventListener('error', () => resolve(link), { once: true });
    document.head.appendChild(link);
  });
}

// ---- Avatars and art ---------------------------------------------------------------------------

const missingArt = new Set();   // image URLs that failed once this session (skip them next time)

/** URL of bundled art by asset name, e.g. artURL('char-juno'): the small web copy when there is one. */
export function artURL(asset) {
  if (ART_THUMBS.has(asset)) return new URL(`../../img/art/${asset}.jpg`, import.meta.url).href;
  return fullArtURL(asset);
}

/** The full-size art (docs/assets/art/<asset>.jpg). */
export function fullArtURL(asset) { return siteURL(`assets/art/${asset}.jpg`); }

export function isMissingArt(url) { return missingArt.has(url); }
export function markMissingArt(url) { missingArt.add(url); }

const FALLBACK_GRADIENTS = [
  ['#3A2A20', '#FF8A4C'], ['#2B3A4A', '#6FB7C9'], ['#2E3A2F', '#7FB69B'],
  ['#4A2E1F', '#F6C177'], ['#3A2433', '#E5675B'], ['#2E2A4A', '#B9AEA2'],
];

/** How to draw a character's avatar: { src, emoji, colors, initial }. */
export function avatarSource(c) {
  const a = c?.avatar || {};
  let src = null;
  if (a.dataURL) src = a.dataURL;
  else if (a.file && /^(?:data|blob):/.test(a.file)) src = a.file;
  else if (a.asset) src = artURL(a.asset);
  else if (c?.isBuiltIn && c.id) src = artURL(`char-${c.id}`);
  if (src && missingArt.has(src)) src = null;
  let colors = Array.isArray(a.colors) && a.colors.length >= 2 ? a.colors.slice(0, 2) : null;
  if (!colors && c?.accentHex) colors = ['#2A211B', c.accentHex];
  if (!colors) colors = FALLBACK_GRADIENTS[hash(c?.id || c?.name || '') % FALLBACK_GRADIENTS.length];
  return { src, emoji: a.emoji || null, colors, initial: (c?.name || '?').trim().charAt(0).toUpperCase() || '?' };
}

/**
 * <span class="avatar"> with a gradient + emoji (or initial) fallback underneath an optional image.
 * shape: 'circle' | 'rounded'.
 */
export function avatar(c, { size = 40, shape = 'circle', className = '', alt = '' } = {}) {
  const s = avatarSource(c);
  const el = h('span', {
    class: `avatar ${shape} ${className}`.trim(),
    style: { width: `${size}px`, height: `${size}px`, '--av-a': s.colors[0], '--av-b': s.colors[1], '--av-size': `${size}px` },
  }, h('span', { class: s.emoji ? 'avatar-emoji' : 'avatar-initial', 'aria-hidden': 'true' }, s.emoji || s.initial));
  if (s.src) attachImage(el, s.src, { alt, size });
  return el;
}

/** Puts an <img> over a fallback; on error the image is removed and remembered as missing. */
export function attachImage(container, src, { alt = '', size = null, className = '' } = {}) {
  const img = h('img', {
    src, alt, class: className || null, loading: 'lazy', decoding: 'async', draggable: 'false',
    width: size || null, height: size || null,
  });
  img.addEventListener('load', () => container.classList.add('has-img'), { once: true });
  img.addEventListener('error', () => { missingArt.add(src); img.remove(); container.classList.remove('has-img'); }, { once: true });
  container.appendChild(img);
  return img;
}

/** "at the Lighthouse now" for a character, or '' when they have no schedule. */
export function whereText(c) {
  const w = whereNow(c);
  if (!w?.location) return '';
  return `at ${w.location.name.replace(/^The\s/, 'the ')} now`;
}

/**
 * Character card linking to the profile (or `href`).
 * variant: 'grid' (horizontal card), 'compact' (small row card).
 */
export function characterCard(c, { href = null, variant = 'grid', meta = null } = {}) {
  const where = meta ?? whereText(c);
  const size = variant === 'compact' ? 56 : 92;
  return h('a', {
    class: `ccard ccard-${variant}`,
    href: href || `#/c/${encodeURIComponent(c.id)}`,
    'aria-label': `${c.name}. ${c.tagline || ''}`,
    style: { '--card-accent': c.accentHex || 'var(--accent)' },
  },
  avatar(c, { size, shape: 'rounded' }),
  h('div', { class: 'ccard-body' },
    h('div', { class: 'ccard-name ellipsis' }, c.name),
    h('div', { class: 'ccard-by ellipsis' }, `By ${c.creator || '@lanternbay'}`),
    c.tagline ? h('p', { class: `ccard-tagline ${variant === 'compact' ? 'clamp-2' : 'clamp-3'}` }, c.tagline) : null,
    where ? h('div', { class: 'ccard-meta' }, icon('map-pin', { size: 14 }), h('span', { class: 'ellipsis' }, where)) : null));
}

/** Text with *actions* in italics and **bold**, keeping line breaks. Safe: text nodes only. */
export function richText(text, { className = 'rich' } = {}) {
  const wrap = h('div', { class: className });
  const paragraphs = String(text || '').split(/\n{2,}/);
  for (const para of paragraphs) {
    const p = h('p');
    const lines = para.split('\n');
    lines.forEach((line, i) => {
      if (i > 0) p.appendChild(document.createElement('br'));
      const re = /(\*\*[^*\n]+\*\*|\*[^*\n]+\*)/g;
      let last = 0;
      let m;
      while ((m = re.exec(line))) {
        if (m.index > last) p.appendChild(document.createTextNode(line.slice(last, m.index)));
        const token = m[0];
        if (token.startsWith('**')) p.appendChild(h('strong', {}, token.slice(2, -2)));
        else p.appendChild(h('em', { class: 'act' }, token.slice(1, -1)));
        last = m.index + token.length;
      }
      if (last < line.length) p.appendChild(document.createTextNode(line.slice(last)));
    });
    wrap.appendChild(p);
  }
  return wrap;
}

// ---- Small controls ----------------------------------------------------------------------------

export function chip({ label, emoji = null, active = false, onClick, ariaControls = null }) {
  return h('button', {
    class: `chip${active ? ' active' : ''}`, type: 'button', 'aria-pressed': active ? 'true' : 'false',
    'aria-controls': ariaControls, onClick,
  }, emoji ? h('span', { class: 'chip-emoji', 'aria-hidden': 'true' }, emoji) : null, label);
}

export function sectionHeader(title, { subtitle = null, actions = [], id = null } = {}) {
  return h('div', { class: 'section-head' },
    h('div', { class: 'section-titles' },
      h('h2', { class: 'section-title', id }, title),
      subtitle ? h('p', { class: 'section-sub' }, subtitle) : null),
    actions.length ? h('div', { class: 'section-actions' }, actions) : null);
}

export function emptyState({ iconName = 'sparkle', title, body = null, action = null }) {
  return h('div', { class: 'empty' },
    h('div', { class: 'empty-icon' }, icon(iconName, { size: 26 })),
    h('h3', { class: 'empty-title' }, title),
    body ? h('p', { class: 'empty-body' }, body) : null,
    action);
}

/** <label class="switch"> wrapping a checkbox. */
export function switchControl({ checked = false, onChange, label }) {
  const input = h('input', { type: 'checkbox', checked, 'aria-label': label, onChange: (e) => onChange?.(e.target.checked) });
  return h('label', { class: 'switch' }, input, h('span'));
}

/** Segmented buttons: options [{ value, label, icon }]. */
export function segmented(options, value, onChange, { label = '' } = {}) {
  const group = h('div', { class: 'segmented', role: 'group', 'aria-label': label });
  const render = (current) => {
    clear(group);
    for (const o of options) {
      group.appendChild(h('button', {
        type: 'button', 'aria-pressed': o.value === current ? 'true' : 'false',
        onClick: () => { render(o.value); onChange?.(o.value); },
      }, o.icon ? icon(o.icon, { size: 16 }) : null, o.label));
    }
  };
  render(value);
  return group;
}

// ---- Modal -------------------------------------------------------------------------------------

const modalStack = [];
let modalCount = 0;

function setBackgroundInert(on) {
  const app = document.getElementById('app');
  if (app) app.inert = on;
}

/**
 * Opens a dialog. Returns { el, body, close }.
 * actions: [{ label, variant: 'primary'|'secondary'|'ghost'|'danger', onClick(handle), autofocus }]
 * An action's onClick may return false (or a Promise of false) to keep the dialog open.
 */
export function modal({ title = '', body = null, actions = [], dismissible = true, className = '', size = 'md', onClose = null, describedBy = null, labelledBy = null } = {}) {
  const id = `modal-${++modalCount}`;
  const previous = document.activeElement;
  const overlay = h('div', { class: 'modal-overlay' });
  const bodyEl = h('div', { class: 'modal-body' }, body);
  const actionsEl = actions.length ? h('div', { class: 'modal-actions' }) : null;
  const dialog = h('div', {
    class: `modal modal-${size} ${className}`.trim(), role: 'dialog', 'aria-modal': 'true',
    'aria-labelledby': title ? `${id}-title` : labelledBy, 'aria-describedby': describedBy, tabindex: '-1',
  },
  title || dismissible ? h('div', { class: 'modal-head' },
    title ? h('h2', { class: 'modal-title', id: `${id}-title` }, title) : h('span'),
    dismissible ? h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Close', onClick: () => close() }, icon('x')) : null) : null,
  bodyEl, actionsEl);

  let closed = false;
  const handle = { el: dialog, body: bodyEl, close, overlay };

  function close(reason = 'close') {
    if (closed) return;
    closed = true;
    document.removeEventListener('keydown', onKey, true);
    const idx = modalStack.indexOf(handle);
    if (idx >= 0) modalStack.splice(idx, 1);
    const below = modalStack[modalStack.length - 1];
    if (below) below.overlay.inert = false;
    else setBackgroundInert(false);
    overlay.classList.add('closing');
    const done = () => overlay.remove();
    overlay.addEventListener('animationend', done, { once: true });
    setTimeout(done, 260);
    if (previous && typeof previous.focus === 'function' && document.contains(previous)) previous.focus({ preventScroll: true });
    onClose?.(reason);
  }

  for (const a of actions) {
    const btn = h('button', {
      type: 'button', class: `btn btn-${a.variant || 'secondary'}`, disabled: !!a.disabled, id: a.id || null,
      onClick: async () => {
        if (!a.onClick) return close('action');
        btn.disabled = true;
        try {
          const keep = await a.onClick(handle);
          if (keep !== false) close('action');
        } finally {
          if (!closed) btn.disabled = false;
        }
      },
    }, a.label);
    if (a.autofocus) btn.dataset.autofocus = '1';
    actionsEl.appendChild(btn);
  }

  function onKey(e) {
    if (modalStack[modalStack.length - 1] !== handle) return;
    if (e.key === 'Escape' && dismissible) { e.preventDefault(); e.stopPropagation(); close('escape'); }
    if (e.key === 'Tab') trapTab(e, dialog);
  }

  overlay.addEventListener('pointerdown', (e) => { if (e.target === overlay && dismissible) close('backdrop'); });
  overlay.appendChild(dialog);
  const below = modalStack[modalStack.length - 1];
  if (below) below.overlay.inert = true;
  else setBackgroundInert(true);
  modalStack.push(handle);
  document.body.appendChild(overlay);
  document.addEventListener('keydown', onKey, true);
  requestAnimationFrame(() => {
    const target = dialog.querySelector('[data-autofocus], [autofocus]')
      || dialog.querySelector('input, textarea, select')
      || dialog;
    target.focus({ preventScroll: true });
  });
  return handle;
}

function focusables(root) {
  return [...root.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])')]
    .filter((el) => el.offsetParent !== null || el === document.activeElement);
}

function trapTab(e, root) {
  const items = focusables(root);
  if (!items.length) { e.preventDefault(); root.focus(); return; }
  const first = items[0];
  const last = items[items.length - 1];
  if (e.shiftKey && (document.activeElement === first || document.activeElement === root)) { e.preventDefault(); last.focus(); }
  else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
}

/**
 * Yes/no dialog. Resolves true when confirmed.
 * With `checkbox: { label, checked }`, the box's final state is written back to checkbox.checked.
 */
export function confirm({ title, message = '', confirmLabel = 'Delete', cancelLabel = 'Cancel', danger = true, checkbox = null } = {}) {
  return new Promise((resolve) => {
    let result = false;
    const box = checkbox ? h('input', { type: 'checkbox', checked: !!checkbox.checked }) : null;
    const body = h('div', { class: 'stack' },
      message ? h('p', { class: 'text-2' }, message) : null,
      box ? h('label', { class: 'check' }, box, h('span', {}, checkbox.label)) : null);
    modal({
      title, body, size: 'sm',
      actions: [
        { label: cancelLabel, variant: 'ghost' },
        {
          label: confirmLabel, variant: danger ? 'danger' : 'primary', autofocus: !danger,
          onClick: () => { result = true; if (box) checkbox.checked = box.checked; },
        },
      ],
      onClose: () => resolve(result),
    });
  });
}

// ---- Toast -------------------------------------------------------------------------------------

let toastHost = null;

/** Short message at the bottom of the screen. tone: 'default' | 'success' | 'danger'. */
export function toast(message, { tone = 'default', duration = 2800, action = null } = {}) {
  if (!toastHost || !document.body.contains(toastHost)) {
    toastHost = h('div', { class: 'toasts', role: 'status', 'aria-live': 'polite' });
    document.body.appendChild(toastHost);
  }
  const el = h('div', { class: `toast toast-${tone}` },
    tone === 'success' ? icon('check', { size: 18 }) : tone === 'danger' ? icon('info', { size: 18 }) : null,
    h('span', {}, message),
    action ? h('button', { class: 'toast-action', type: 'button', onClick: () => { action.onClick?.(); dismiss(); } }, action.label) : null);
  toastHost.appendChild(el);
  let timer = setTimeout(dismiss, duration);
  el.addEventListener('mouseenter', () => clearTimeout(timer));
  el.addEventListener('mouseleave', () => { timer = setTimeout(dismiss, 1200); });
  function dismiss() {
    clearTimeout(timer);
    el.classList.add('leaving');
    setTimeout(() => el.remove(), 220);
  }
  return { dismiss };
}

// ---- Menu --------------------------------------------------------------------------------------

let openMenu = null;

/**
 * Popover menu anchored to a button.
 * items: [{ label, icon, onClick, danger, disabled } | { separator: true }]
 */
export function menu(anchor, items, { align = 'end', label = 'Options' } = {}) {
  if (openMenu) {
    const wasSame = openMenu.anchor === anchor;
    openMenu.close();
    if (wasSame) return null; // second click on the same button closes it
  }
  const el = h('div', { class: 'menu', role: 'menu', 'aria-label': label });
  for (const item of items) {
    if (!item) continue;
    if (item.separator) { el.appendChild(h('div', { class: 'menu-sep', role: 'separator' })); continue; }
    el.appendChild(h('button', {
      type: 'button', role: 'menuitem', class: `menu-item${item.danger ? ' danger' : ''}`, disabled: !!item.disabled,
      onClick: () => { close(); item.onClick?.(); },
    }, item.icon ? icon(item.icon, { size: 18 }) : h('span', { class: 'menu-spacer' }), h('span', {}, item.label)));
  }
  document.body.appendChild(el);

  const r = anchor.getBoundingClientRect();
  const mw = el.offsetWidth;
  const mh = el.offsetHeight;
  const vw = document.documentElement.clientWidth;
  const vh = window.innerHeight;
  let top = r.bottom + 6;
  if (top + mh > vh - 8 && r.top - mh - 6 > 8) top = r.top - mh - 6;
  let left = align === 'end' ? r.right - mw : r.left;
  left = Math.max(8, Math.min(left, vw - mw - 8));
  top = Math.max(8, Math.min(top, vh - mh - 8));
  el.style.top = `${top}px`;
  el.style.left = `${left}px`;

  anchor.setAttribute('aria-expanded', 'true');
  const buttons = () => [...el.querySelectorAll('.menu-item:not([disabled])')];
  const onKey = (e) => {
    const list = buttons();
    const i = list.indexOf(document.activeElement);
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); anchor.focus(); }
    else if (e.key === 'ArrowDown') { e.preventDefault(); list[(i + 1) % list.length]?.focus(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); list[(i - 1 + list.length) % list.length]?.focus(); }
    else if (e.key === 'Home') { e.preventDefault(); list[0]?.focus(); }
    else if (e.key === 'End') { e.preventDefault(); list[list.length - 1]?.focus(); }
    else if (e.key === 'Tab') close();
  };
  const onDown = (e) => { if (!el.contains(e.target) && !anchor.contains(e.target)) close(); };
  const onScroll = (e) => { if (!el.contains(e.target)) close(); };
  document.addEventListener('keydown', onKey, true);
  document.addEventListener('pointerdown', onDown, true);
  window.addEventListener('resize', close);
  document.addEventListener('scroll', onScroll, true);

  function close() {
    if (!openMenu || openMenu.el !== el) return;
    openMenu = null;
    anchor.setAttribute('aria-expanded', 'false');
    document.removeEventListener('keydown', onKey, true);
    document.removeEventListener('pointerdown', onDown, true);
    window.removeEventListener('resize', close);
    document.removeEventListener('scroll', onScroll, true);
    el.remove();
  }
  openMenu = { el, anchor, close };
  requestAnimationFrame(() => buttons()[0]?.focus({ preventScroll: true }));
  return openMenu;
}

export function closeMenus() { openMenu?.close(); }
