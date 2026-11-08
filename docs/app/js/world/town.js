// Town (#/town): the Lantern Bay map with who is where, a time-of-day control to peek at other parts of
// the day, "While you were away" town news, every place with who is there, and the residents and their ties.

import { h, avatar, attachImage, artURL, isMissingArt, emptyState, sectionHeader } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { world, allCharacters, getCharacter, getLocation, subscribe } from '../data.js';
import { DAY_PARTS, dayPart, whoIsAt, locationOf } from '../brain/director.js';
import { relativeTime, capitalize, prefersReducedMotion } from '../util.js';
import { townMap } from './map.js';
import { allEvents, refreshNews, isRefreshing, markAllSeen } from './news.js';

export const PART_INFO = {
  morning: { label: 'Morning', emoji: '🌅' },
  afternoon: { label: 'Afternoon', emoji: '☀️' },
  evening: { label: 'Evening', emoji: '🌇' },
  night: { label: 'Night', emoji: '🌙' },
};

const NEWS_SHOWN = 4;

export const sceneHref = (loc) => `#/town/${encodeURIComponent(loc.id)}`;

/** Everyone who lives in town: the built-in cast plus your characters who have a home here. */
export function residents() {
  return allCharacters().filter((c) => c.isBuiltIn || c.homeLocationID);
}

const theName = (loc) => loc.name.replace(/^The\s/, 'the ');

function placeCard(loc, people, { part, now }) {
  const colors = loc.art?.colors || ['#2A211B', '#FF8A4C'];
  const media = h('div', { class: 'tw-place-media', style: { '--pa': colors[0], '--pb': colors[1] || colors[0] } },
    h('span', { class: 'tw-place-emoji', 'aria-hidden': 'true' }, loc.emoji || loc.art?.emoji || '📍'),
    h('span', { class: `tw-place-count${people.length ? '' : ' quiet'}` }, people.length ? `${people.length} here` : 'Quiet'));
  const asset = loc.art?.asset || `loc-${loc.id}`;
  if (!isMissingArt(artURL(asset))) attachImage(media, artURL(asset), { alt: '' });
  return h('article', { class: 'tw-place', dataset: { loc: loc.id } },
    media,
    h('div', { class: 'tw-place-body' },
      h('h3', { class: 'tw-place-name' }, h('a', { href: sceneHref(loc) }, loc.name)),
      h('p', { class: 'tw-place-blurb clamp-2' }, loc.blurb),
      people.length
        ? h('ul', { class: 'tw-place-people', 'aria-label': now ? 'Here now' : `Here in the ${part}` }, people.map((c) => h('li', {},
          avatar(c, { size: 30 }),
          h('span', { class: 'tw-pp-text' },
            h('strong', {}, c.name),
            h('span', { class: 'tw-pp-doing' }, locationOf(c, part, world())?.activity || '')))))
        : h('p', { class: 'tw-place-empty' }, now ? 'Nobody is here right now. Drop in and invite someone.' : `Quiet in the ${part}.`),
      h('a', { class: `btn ${people.length && now ? 'btn-primary' : 'btn-secondary'} btn-sm tw-place-go`, href: sceneHref(loc) },
        icon('message', { size: 16 }), people.length ? (now ? 'Join them' : 'Visit now') : 'Drop in')));
}

function relationRows(c) {
  const rels = (c.relationships || []).map((r) => ({ r, other: getCharacter(r.characterID) })).filter((x) => x.other);
  if (!rels.length) return h('p', { class: 'tw-res-new' }, 'New in town and still getting to know everyone.');
  return h('ul', { class: 'tw-rel-list', 'aria-label': `${c.name}'s friends` }, rels.map(({ r, other }) => h('li', {},
    h('a', { class: 'tw-rel', href: `#/c/${encodeURIComponent(other.id)}` },
      avatar(other, { size: 32 }),
      h('span', { class: 'tw-rel-text' },
        h('span', { class: 'tw-rel-top' }, h('strong', {}, other.name), h('span', { class: 'tw-rel-kind' }, r.kind)),
        h('span', { class: 'tw-rel-note' }, r.note))))));
}

function residentRow(c, part, onFind) {
  const where = locationOf(c, part, world());
  const id = encodeURIComponent(c.id);
  return h('details', { class: 'tw-res', style: { '--res-accent': c.accentHex || 'var(--accent)' } },
    h('summary', { class: 'tw-res-sum' },
      h('span', { class: 'tw-res-row' },
        avatar(c, { size: 44 }),
        h('span', { class: 'tw-res-text' },
          h('span', { class: 'tw-res-name' }, c.name, c.species ? h('span', { class: 'tw-res-species' }, c.species) : null),
          h('span', { class: 'tw-res-where ellipsis' }, where?.location ? `${where.location.emoji || '📍'} ${where.location.name}` : 'Out and about')),
        h('span', { class: 'tw-res-chev', 'aria-hidden': 'true' }, icon('chevron-down', { size: 18 })))),
    h('div', { class: 'tw-res-body' },
      where ? h('p', { class: 'tw-res-doing' }, `${capitalize(where.activity)}.`) : null,
      relationRows(c),
      h('div', { class: 'tw-res-actions' },
        h('a', { class: 'btn btn-primary btn-sm', href: `#/chat/${id}` }, icon('message', { size: 16 }), 'Chat'),
        h('a', { class: 'btn btn-secondary btn-sm', href: `#/c/${id}` }, icon('user', { size: 16 }), 'Profile'),
        where?.location ? h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onClick: () => onFind(where.locationID) },
          icon('map-pin', { size: 16 }), 'Find on map') : null)));
}

function eventItem(e, { isNew }) {
  const people = (e.characterIDs || []).map(getCharacter).filter(Boolean).slice(0, 2);
  const loc = e.locationID ? getLocation(e.locationID) : null;
  return h('li', { class: `tw-event${isNew ? ' new' : ''}` },
    h('div', { class: `tw-event-avatars n${people.length}`, 'aria-hidden': 'true' },
      people.length ? people.map((c) => avatar(c, { size: 34 })) : h('span', { class: 'tw-event-lantern' }, '🏮')),
    h('div', { class: 'tw-event-body' },
      h('p', { class: 'tw-event-text' }, e.text),
      h('div', { class: 'tw-event-meta' },
        loc ? h('a', { class: 'tw-event-place', href: sceneHref(loc) }, `${loc.emoji || '📍'} ${loc.name}`) : null,
        h('span', { class: 'tw-event-time' }, relativeTime(e.date)),
        isNew ? h('span', { class: 'badge accent' }, 'New') : null)));
}

export async function renderTown(ctx) {
  ctx.setTitle('Town');
  const w = world();
  if (!w?.locations?.length) {
    return h('div', { class: 'page narrow' }, emptyState({
      iconName: 'map', title: 'The town is still waking up', body: "Lantern Bay's map couldn't be loaded. Try reloading the page.",
    }));
  }

  let nowPart = dayPart();
  let part = nowPart;
  let showAllNews = false;
  const visitStarted = Date.now() - 5000;
  const newIDs = new Set();   // unseen (or written) during this visit, so the "New" marks survive repaints

  // ---- Header and time of day ------------------------------------------------------------------
  const sub = h('p', { class: 'page-sub tw-sub' });
  const mapHint = h('span');
  const times = h('div', { class: 'tw-times no-scrollbar', role: 'group', 'aria-label': 'Time of day' });
  const badgeText = h('span', { class: 'tmap-badge-text' });
  const backBtn = h('button', { class: 'tmap-badge-back', type: 'button', onClick: () => setPart(nowPart) }, 'Back to now');
  const badge = h('div', { class: 'tmap-badge' }, badgeText, backBtn);
  const map = townMap({ locations: w.locations, characters: allCharacters(), part, nowPart, badge });

  // ---- News --------------------------------------------------------------------------------------
  const newsList = h('ol', { class: 'tw-news-list' });
  const newsMore = h('button', { class: 'btn btn-ghost btn-sm tw-news-more', type: 'button', hidden: true });
  const newsFoot = h('p', { class: 'tw-news-foot' });
  const newsBadge = h('span', { class: 'badge accent', hidden: true });
  const news = h('section', { class: 'tw-news', 'aria-labelledby': 'tw-news-h' },
    h('div', { class: 'tw-news-head' },
      h('span', { class: 'tw-news-icon', 'aria-hidden': 'true' }, icon('bell', { size: 18 })),
      h('h2', { id: 'tw-news-h' }, 'While you were away'),
      newsBadge),
    h('p', { class: 'tw-news-sub' }, 'Little things that happened around town.'),
    newsList, newsMore, newsFoot);

  const placesGrid = h('div', { class: 'tw-places' });
  const placesSub = h('p', { class: 'section-sub' });
  const residentsList = h('div', { class: 'tw-residents' });

  const page = h('div', { class: 'page townpage' },
    h('header', { class: 'tw-head' },
      h('div', { class: 'tw-head-text' }, h('h1', { class: 'page-title serif' }, w.name), sub),
      times),
    h('div', { class: 'tw-top' },
      h('section', { class: 'tw-map', 'aria-label': 'Town map' }, map.el,
        h('p', { class: 'tw-map-hint', 'aria-live': 'polite' }, icon('info', { size: 15 }), mapHint)),
      news),
    h('section', { class: 'tw-section', 'aria-labelledby': 'tw-places-h' },
      h('div', { class: 'section-head' }, h('div', { class: 'section-titles' }, h('h2', { class: 'section-title', id: 'tw-places-h' }, 'Places'), placesSub)),
      placesGrid),
    h('section', { class: 'tw-section', 'aria-labelledby': 'tw-res-h' },
      sectionHeader('Residents', { id: 'tw-res-h', subtitle: 'Everyone who lives in town, and who they are close to' }),
      residentsList));

  // ---- Painting ----------------------------------------------------------------------------------
  function paintTimes() {
    times.replaceChildren(...DAY_PARTS.map((p) => h('button', {
      type: 'button', class: `tw-time${p === part ? ' on' : ''}`, 'aria-pressed': p === part ? 'true' : 'false',
      onClick: () => setPart(p),
    },
    h('span', { class: 'tw-time-emoji', 'aria-hidden': 'true' }, PART_INFO[p].emoji),
    h('span', {}, PART_INFO[p].label),
    p === nowPart ? h('span', { class: 'tw-time-now' }, 'Now') : null)));
  }

  function paintHeader() {
    const peeking = part !== nowPart;
    sub.textContent = `It's ${nowPart} in ${w.name}. ${w.tagline || ''}`.trim();
    const clock = new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    badgeText.textContent = `${PART_INFO[part].emoji} ${PART_INFO[part].label}${peeking ? ' (peeking)' : ` · ${clock}`}`;
    backBtn.hidden = !peeking;
    mapHint.textContent = peeking
      ? `Peeking at the ${part}: this is where everyone will be. Places still open with whoever is there now.`
      : 'Tap a place to step inside. Whoever is there talks with you and with each other.';
    placesSub.textContent = peeking ? `Who will be where in the ${part}` : `Who is where this ${part}`;
  }

  function paintPlaces() {
    const people = allCharacters();
    const now = part === nowPart;
    placesGrid.replaceChildren(...w.locations.map((loc) => placeCard(loc, whoIsAt(loc.id, part, people), { part, now })));
  }

  function findOnMap(locationID) {
    map.el.scrollIntoView({ behavior: prefersReducedMotion() ? 'auto' : 'smooth', block: 'center' });
    map.highlight(locationID);
  }

  function paintResidents() {
    const open = new Set([...residentsList.querySelectorAll('details[open]')].map((d) => d.dataset.id));
    residentsList.replaceChildren(...residents().map((c) => {
      const row = residentRow(c, part, findOnMap);
      row.dataset.id = c.id;
      if (open.has(c.id)) row.open = true;
      return row;
    }));
  }

  function paintNews(events) {
    const unseen = events.filter((e) => newIDs.has(e.id)).length;
    newsBadge.hidden = unseen === 0;
    newsBadge.textContent = `${unseen} new`;
    const items = [];
    if (isRefreshing()) {
      items.push(h('li', { class: 'tw-event loading', role: 'status' },
        h('div', { class: 'tw-event-avatars', 'aria-hidden': 'true' }, h('span', { class: 'tw-event-lantern' }, '🏮')),
        h('div', { class: 'tw-event-body' }, h('p', { class: 'tw-event-text' }, 'Catching up on town news...'),
          h('div', { class: 'skeleton tw-skel' }))));
    }
    const shown = showAllNews ? events : events.slice(0, NEWS_SHOWN);
    items.push(...shown.map((e) => eventItem(e, { isNew: newIDs.has(e.id) })));
    if (!items.length) {
      items.push(h('li', { class: 'tw-news-empty' }, 'Quiet in town so far. Check back in a little while.'));
    }
    newsList.replaceChildren(...items);
    newsMore.hidden = events.length <= NEWS_SHOWN;
    newsMore.textContent = showAllNews ? 'Show less' : `Show all ${events.length}`;
    const newest = events[0];
    newsFoot.textContent = !newest ? ''
      : newest.source === 'model' ? 'Written by the model on this device.'
        : 'From the town notebook. With the model loaded, new ones are written on this device.';
  }

  async function loadNews() {
    let events = [];
    try { events = await allEvents(); } catch { /* storage blocked */ }
    if (ctx.signal.aborted) return;
    for (const e of events) if (!e.seen || (e.date || 0) >= visitStarted) newIDs.add(e.id);
    paintNews(events);
    if (events.some((e) => !e.seen)) markAllSeen().catch(() => {});
  }

  newsMore.addEventListener('click', () => { showAllNews = !showAllNews; loadNews(); });

  function paintAll() {
    paintTimes();
    paintHeader();
    map.update({ part, nowPart, characters: allCharacters() });
    paintPlaces();
    paintResidents();
  }

  function setPart(p) {
    if (!DAY_PARTS.includes(p) || p === part) return;
    part = p;
    paintAll();
  }

  // ---- Live updates ------------------------------------------------------------------------------
  const unsubEvents = subscribe('events', () => loadNews());
  const unsubChars = subscribe('characters', () => paintAll());
  const tick = setInterval(() => {
    const p = dayPart();
    if (p !== nowPart) {
      const following = part === nowPart;
      nowPart = p;
      if (following) part = p;
      paintAll();
    } else {
      paintHeader();
    }
  }, 30000);
  ctx.signal.addEventListener('abort', () => {
    clearInterval(tick);
    unsubEvents();
    unsubChars();
  });

  paintAll();
  const refreshing = refreshNews().catch(() => {});   // a new batch when one is due
  await loadNews();                                    // shows "Catching up" while that batch is written
  refreshing.finally(() => { if (!ctx.signal.aborted) loadNews(); });
  return page;
}
