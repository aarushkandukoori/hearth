// The app frame: left sidebar (collapsible on desktop, slide-over drawer on phones), the phone top bar
// and the <main> outlet. Nav entries come from nav.js so other modules can add their own.

import { h, clear, avatar, attachImage } from './ui/components.js';
import { icon, hearthMark } from './ui/icons.js';
import { navItems, onNavChange } from './nav.js';
import { navigate, onRoute, currentRoute } from './router.js';
import { recentCharacterChats } from './chats.js';
import { getCharacter, subscribe } from './data.js';
import { toggleTheme, effectiveTheme, onThemeChange } from './theme.js';
import { engine } from './engine/engine.js';
import { dayGroup, siteURL, debounce } from './util.js';

const els = {};
const DESKTOP = matchMedia('(min-width: 900px)');

function logo({ size = 30 } = {}) {
  const box = h('span', { class: 'logo-mark', style: { width: `${size}px`, height: `${size}px` } }, hearthMark(size));
  const img = attachImage(box, siteURL('assets/brand/logo.svg'), { alt: '', size });
  img.loading = 'eager';
  return box;
}

function brand() {
  return h('a', { class: 'brand', href: '#/', 'aria-label': 'Hearth, go to Discover' },
    logo(), h('span', { class: 'brand-name serif' }, 'Hearth'));
}

function setCollapsed(on, { remember = true } = {}) {
  document.documentElement.classList.toggle('sidebar-collapsed', on);
  if (remember) {
    try { localStorage.setItem('hearth.sidebar', on ? 'collapsed' : 'open'); } catch { /* ignore */ }
  }
  els.collapse?.setAttribute('aria-label', on ? 'Expand sidebar' : 'Collapse sidebar');
  els.collapse?.setAttribute('aria-expanded', on ? 'false' : 'true');
}

export function openDrawer() {
  if (DESKTOP.matches) return;
  document.documentElement.classList.add('drawer-open');
  els.sidebar.inert = false;
  els.menuBtn?.setAttribute('aria-expanded', 'true');
  requestAnimationFrame(() => els.sidebar.querySelector('a, button, input')?.focus({ preventScroll: true }));
}

export function closeDrawer({ focusMenu = false } = {}) {
  const wasOpen = document.documentElement.classList.contains('drawer-open');
  document.documentElement.classList.remove('drawer-open');
  els.menuBtn?.setAttribute('aria-expanded', 'false');
  syncDrawerInert();
  if (wasOpen && focusMenu) els.menuBtn?.focus();
}

/** On phones the closed drawer must not be reachable by keyboard or screen readers. */
function syncDrawerInert() {
  if (!els.sidebar) return;
  els.sidebar.inert = !DESKTOP.matches && !document.documentElement.classList.contains('drawer-open');
}

function renderNav() {
  const { path } = currentRoute();
  clear(els.nav);
  for (const item of navItems()) {
    const active = item.match ? item.match(path) : (item.href === '#/' ? path === '/' : path.startsWith(item.href.replace(/^#/, '')));
    els.nav.appendChild(h('a', {
      class: `sb-link${active ? ' active' : ''}`, href: item.href, 'aria-current': active ? 'page' : null, title: item.label,
    }, icon(item.icon, { size: 20 }), h('span', { class: 'sb-text' }, item.label)));
  }
}

async function renderRecents() {
  const list = els.recents;
  const chats = await recentCharacterChats(14);
  const { path } = currentRoute();
  const activeID = path.startsWith('/chat/') ? decodeURIComponent(path.split('/')[2] || '') : null;
  clear(list);
  els.recentsWrap.hidden = chats.length === 0;
  let group = null;
  for (const conv of chats) {
    const c = getCharacter(conv.characterID);
    if (!c) continue;
    const g = dayGroup(conv.updatedAt);
    if (g !== group) {
      group = g;
      list.appendChild(h('li', { class: 'sb-group', 'aria-hidden': 'true' }, g));
    }
    const active = activeID === c.id;
    list.appendChild(h('li', {},
      h('a', {
        class: `sb-recent${active ? ' active' : ''}`, href: `#/chat/${encodeURIComponent(c.id)}`,
        'aria-current': active ? 'page' : null, title: c.name,
      }, avatar(c, { size: 28 }), h('span', { class: 'sb-text ellipsis' }, c.name))));
  }
}

function renderEngineLine(s = engine.snapshot()) {
  const line = els.engineLine;
  if (!line) return;
  let dot = 'demo';
  let text = 'Demo replies';
  if (s.status === 'ready') { dot = 'ready'; text = 'Model on this device'; }
  else if (s.status === 'loading') {
    dot = 'loading';
    const pct = Math.round((s.progress?.fraction || 0) * 100);
    text = s.progress?.phase === 'download' ? `Downloading model ${pct}%` : `Waking the model ${pct}%`;
  } else if (s.status === 'error') { dot = 'error'; text = 'Model needs attention'; }
  line.replaceChildren(h('span', { class: `dot dot-${dot}`, 'aria-hidden': 'true' }), h('span', { class: 'sb-text ellipsis' }, text));
  line.title = text;
}

function themeButton() {
  const btn = h('button', { class: 'icon-btn sb-theme', type: 'button' });
  const paint = () => {
    const light = effectiveTheme() === 'light';
    btn.replaceChildren(icon(light ? 'moon' : 'sun'));
    btn.setAttribute('aria-label', light ? 'Switch to dark theme' : 'Switch to light theme');
    btn.title = light ? 'Dark theme' : 'Light theme';
  };
  btn.addEventListener('click', () => toggleTheme());
  onThemeChange(paint);
  paint();
  return btn;
}

/** Builds the shell inside `root` and returns the <main> element pages render into. */
export function mountShell(root) {
  els.menuBtn = h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Open menu', 'aria-controls': 'sidebar', 'aria-expanded': 'false', onClick: openDrawer }, icon('menu'));
  const topbar = h('header', { class: 'topbar' },
    els.menuBtn,
    brand(),
    h('div', { class: 'grow' }),
    h('a', { class: 'icon-btn', href: '#/search', 'aria-label': 'Search' }, icon('search')),
    h('a', { class: 'icon-btn topbar-create', href: '#/create', 'aria-label': 'Create a character' }, icon('plus')));

  els.collapse = h('button', { class: 'icon-btn sb-collapse', type: 'button', 'aria-controls': 'sidebar', onClick: () => setCollapsed(!document.documentElement.classList.contains('sidebar-collapsed')) }, icon('sidebar'));
  const closeBtn = h('button', { class: 'icon-btn sb-close', type: 'button', 'aria-label': 'Close menu', onClick: () => closeDrawer({ focusMenu: true }) }, icon('x'));

  els.search = h('input', { class: 'sb-search-input', type: 'search', name: 'q', placeholder: 'Search characters', 'aria-label': 'Search characters', autocomplete: 'off', enterkeyhint: 'search' });
  const liveSearch = debounce((q) => {
    if (currentRoute().path === '/search') navigate(`#/search?q=${encodeURIComponent(q)}`, { replace: true });
  }, 250);
  els.search.addEventListener('input', () => liveSearch(els.search.value.trim()));
  const searchForm = h('form', {
    class: 'sb-search', role: 'search',
    onSubmit: (e) => { e.preventDefault(); liveSearch.cancel(); navigate(`#/search?q=${encodeURIComponent(els.search.value.trim())}`); },
  }, icon('search', { size: 18 }), els.search);
  const searchRail = h('button', {
    class: 'sb-link sb-search-rail', type: 'button', title: 'Search', 'aria-label': 'Search',
    onClick: () => { setCollapsed(false); requestAnimationFrame(() => els.search.focus()); },
  }, icon('search', { size: 20 }));

  els.nav = h('nav', { class: 'sb-nav', 'aria-label': 'Main' });
  els.recents = h('ul', { class: 'sb-recents' });
  els.recentsWrap = h('div', { class: 'sb-section', hidden: true },
    h('div', { class: 'sb-label' }, h('span', { class: 'sb-text' }, 'Recent chats'), h('a', { class: 'sb-viewall', href: '#/chats' }, 'View all')),
    els.recents);
  els.engineLine = h('a', { class: 'sb-engine', href: '#/settings?section=model' });

  els.sidebar = h('aside', { class: 'sidebar', id: 'sidebar', 'aria-label': 'Sidebar' },
    h('div', { class: 'sb-top' }, brand(), els.collapse, closeBtn),
    h('a', { class: 'sb-create', href: '#/create', title: 'Create' }, icon('plus', { size: 20 }), h('span', { class: 'sb-text' }, 'Create')),
    els.nav,
    searchForm,
    searchRail,
    h('div', { class: 'sb-scroll' }, els.recentsWrap),
    h('div', { class: 'sb-bottom' },
      h('a', { class: 'sb-iphone', href: 'iphone/', title: 'Get the iPhone app' },
        h('span', { class: 'sb-iphone-icon' }, icon('phone', { size: 18 })),
        h('span', { class: 'sb-text' }, h('strong', {}, 'Get the iPhone app'), h('small', {}, 'Private, works offline'))),
      els.engineLine,
      h('div', { class: 'sb-row' },
        els.settingsLink = h('a', { class: 'sb-link sb-settings', href: '#/settings', title: 'Settings' }, icon('settings', { size: 20 }), h('span', { class: 'sb-text' }, 'Settings')),
        themeButton())));

  const scrim = h('div', { class: 'scrim', 'aria-hidden': 'true', onClick: () => closeDrawer({ focusMenu: true }) });
  const main = h('main', { id: 'main', class: 'main', tabindex: '-1' });

  root.append(
    h('a', { class: 'skip-link', href: '#main', onClick: (e) => { e.preventDefault(); main.focus(); } }, 'Skip to content'),
    topbar, els.sidebar, scrim, main);

  setCollapsed(document.documentElement.classList.contains('sidebar-collapsed'), { remember: false });
  syncDrawerInert();
  DESKTOP.addEventListener('change', () => { closeDrawer(); syncDrawerInert(); });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && document.documentElement.classList.contains('drawer-open')) closeDrawer({ focusMenu: true });
  });

  onNavChange(renderNav);
  onRoute((r) => {
    renderNav();
    const onSettings = r.path === '/settings';
    els.settingsLink.classList.toggle('active', onSettings);
    if (onSettings) els.settingsLink.setAttribute('aria-current', 'page'); else els.settingsLink.removeAttribute('aria-current');
    renderRecents();
    closeDrawer();
    if (r.path !== '/search') els.search.value = '';
    else if (document.activeElement !== els.search) els.search.value = r.query?.q || '';
  });
  subscribe('conversations', debounce(renderRecents, 120));
  subscribe('characters', () => renderRecents());
  engine.subscribe(renderEngineLine);
  renderNav();
  renderEngineLine();
  return main;
}
