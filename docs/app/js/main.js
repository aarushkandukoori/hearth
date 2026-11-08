// Entry point: open storage, load the world and settings, draw the shell, register the core routes,
// pull in the optional Town and Create modules, start the router, welcome first-time visitors and
// finally settle the engine (demo replies, or the cached on-device model if the user chose it).

import { getTheme } from './theme.js';
import { mountShell } from './shell.js';
import { registerRoute, start, rerender, currentRoute } from './router.js';
import { registerNav } from './nav.js';
import { loadWorld, loadSettings, reloadUserCharacters, settings, subscribe } from './data.js';
import { ready as storeReady, requestPersistence } from './store.js';
import { engine } from './engine/engine.js';
import { ensureWelcome } from './ui/welcome.js';
import { h, loadStyle } from './ui/components.js';
import { loadVoices } from './media/voice.js';
import { renderDiscover } from './pages/discover.js';
import { renderProfile } from './pages/profile.js';
import { renderChat } from './pages/chat.js';
import { renderChats, renderSearch } from './pages/chats.js';
import { renderSettings } from './pages/settings.js';
import { renderTownPlaceholder, renderCreatePlaceholder, renderNotFound } from './pages/placeholders.js';

// Optional feature modules. Each one registers its own routes and nav entries when imported;
// its stylesheet is added only when the module exists.
const OPTIONAL_MODULES = [
  { js: './world/index.js', css: '../css/world.css' },
  { js: './create/index.js', css: '../css/create.css' },
];

function registerCore() {
  registerRoute('/', renderDiscover, { title: 'Discover' });
  registerRoute('/c/:id', renderProfile);
  registerRoute('/chat/:characterId', renderChat);
  registerRoute('/chat/:characterId/:conversationId', renderChat);
  registerRoute('/chats', renderChats, { title: 'Chats' });
  registerRoute('/search', renderSearch, { title: 'Search' });
  registerRoute('/settings', renderSettings, { title: 'Settings' });
  registerRoute('/town', renderTownPlaceholder, { title: 'Town' });
  registerRoute('/create', renderCreatePlaceholder, { title: 'Create' });
  registerRoute('/__notfound', renderNotFound);

  registerNav({
    id: 'discover', label: 'Discover', icon: 'compass', href: '#/', order: 10,
    match: (p) => p === '/' || p.startsWith('/c/') || p === '/search',
  });
  registerNav({ id: 'town', label: 'Town', icon: 'map', href: '#/town', order: 20, match: (p) => p.startsWith('/town') });
}

async function loadOptionalModules() {
  await Promise.all(OPTIONAL_MODULES.map(async (m) => {
    try {
      await import(m.js);
      await loadStyle(new URL(m.css, import.meta.url).href);
    } catch {
      // Not installed yet: the placeholder routes stay.
    }
  }));
}

function fatal(main, message) {
  main.replaceChildren(h('div', { class: 'page narrow' },
    h('div', { class: 'empty' },
      h('h1', { class: 'empty-title' }, 'Hearth could not open'),
      h('p', { class: 'empty-body' }, message),
      h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => location.reload() }, 'Try again'))));
}

async function boot() {
  const root = document.getElementById('app');
  document.getElementById('splash')?.remove();
  void getTheme();
  const main = mountShell(root);
  registerCore();

  await storeReady();
  await loadSettings();
  try {
    await loadWorld();
  } catch (err) {
    fatal(main, err?.message || "Lantern Bay couldn't be loaded.");
    return;
  }
  await reloadUserCharacters();
  await loadOptionalModules();
  await start(main);

  const nameBefore = settings().persona?.name || '';
  await ensureWelcome();
  if ((settings().persona?.name || '') !== nameBefore && currentRoute().path === '/') rerender();
  // Ask the browser to keep chats instead of clearing them on its own (Settings shows the answer).
  requestPersistence();

  loadVoices();
  const s = settings();
  engine.boot({ modelId: s.modelId, autoLoad: !!s.modelOptIn });
  subscribe('settings', (next) => { if (next?.modelId && next.modelId !== engine.modelId && engine.status !== 'loading') engine.setModel(next.modelId); });
}

boot().catch((err) => {
  console.error('[hearth] startup failed:', err?.name || 'Error');
  const main = document.getElementById('main');
  if (main) fatal(main, 'Something went wrong while starting. Reloading usually fixes it.');
});
