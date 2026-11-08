// Town module: registers the Lantern Bay map (#/town) and group scenes (#/town/:locationId), keeps the
// Town sidebar entry's dot in sync with unseen town news, and makes a news batch when one is due.

import { registerRoute, onRoute, currentRoute } from '../router.js';
import { registerNav, onNavChange } from '../nav.js';
import { subscribe } from '../data.js';
import { engine } from '../engine/engine.js';
import { renderTown } from './town.js';
import { renderScene } from './scene.js';
import { refreshNews, unseenCount, isDue } from './news.js';

const MAP_ICON = '<path d="M9 4L3.5 6.3v13.4L9 17.5l6 2.5 5.5-2.3V4.3L15 6.5 9 4z"/><path d="M9 4v13.5M15 6.5V20"/>';
const townIcon = (dot) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${MAP_ICON}${dot ? '<circle class="nav-dot" cx="19.4" cy="4.8" r="3.6"/>' : ''}</svg>`;

let dotShown = null;
let unseen = 0;

function labelLink() {
  const link = document.querySelector('.sb-nav a[href="#/town"]');
  if (link) link.setAttribute('aria-label', unseen > 0 ? `Town, ${unseen} new happening${unseen === 1 ? '' : 's'}` : 'Town');
}

/** Shows the dot (sidebar, and the phone menu button via html.town-news) while there is unseen news. */
async function syncDot() {
  try {
    unseen = currentRoute().path.startsWith('/town') ? 0 : await unseenCount();
  } catch {
    unseen = 0;
  }
  const dot = unseen > 0;
  document.documentElement.classList.toggle('town-news', dot);
  if (dot !== dotShown) {
    dotShown = dot;
    registerNav({ id: 'town', label: 'Town', icon: townIcon(dot), href: '#/town', order: 20, match: (p) => p.startsWith('/town') });
  }
  labelLink();
}

/** Makes a batch of town news once the engine has settled (demo, ready or error) and 6 hours have passed. */
function newsIfDue() {
  const s = engine.status;
  if ((s === 'demo' || s === 'ready' || s === 'error') && isDue()) refreshNews().catch(() => {});
}

registerRoute('/town', renderTown, { title: 'Town' });
registerRoute('/town/:locationId', renderScene, { title: 'Town' });

onRoute(() => { syncDot(); newsIfDue(); });
onNavChange(() => labelLink());
subscribe('events', () => { syncDot(); });
engine.subscribe(() => newsIfDue());
syncDot();
