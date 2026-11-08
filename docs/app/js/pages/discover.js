// Discover (#/): welcome, "Continue chatting", "For you", a "Featured" carousel of who's out right now,
// and category chips filtering a grid of every character.

import { h, avatar, characterCard, chip, sectionHeader, emptyState, attachImage, artURL, isMissingArt } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { world, allCharacters, userMadeCharacters, userName, getCharacter, whereNow } from '../data.js';
import { recentCharacterChats, previewText, conversationHref } from '../chats.js';
import { dayPart } from '../brain/director.js';
import { seeded, shuffled, relativeTime, capitalize, hash } from '../util.js';

let activeCategory = 'all'; // kept while the tab is open so coming back keeps the filter

const PART_ICON = { morning: '🌅', afternoon: '☀️', evening: '🌇', night: '🌙' };

/** A row that scrolls sideways, with arrow buttons on wide screens. */
function scroller(items, { label, className = '' }) {
  const track = h('div', { class: `scroller-track no-scrollbar ${className}`.trim(), role: 'list', 'aria-label': label },
    items.map((node) => h('div', { class: 'scroller-item', role: 'listitem' }, node)));
  const step = (dir) => track.scrollBy({ left: dir * Math.max(240, track.clientWidth * 0.8), behavior: 'smooth' });
  const prev = h('button', { class: 'icon-btn scroller-btn', type: 'button', 'aria-label': `Scroll ${label} left`, onClick: () => step(-1) }, icon('chevron-left'));
  const next = h('button', { class: 'icon-btn scroller-btn', type: 'button', 'aria-label': `Scroll ${label} right`, onClick: () => step(1) }, icon('chevron-right'));
  const sync = () => {
    prev.disabled = track.scrollLeft <= 4;
    next.disabled = track.scrollLeft + track.clientWidth >= track.scrollWidth - 4;
  };
  track.addEventListener('scroll', sync, { passive: true });
  requestAnimationFrame(sync);
  new ResizeObserver(sync).observe(track);
  return { track, controls: [prev, next] };
}

function continueCard(conv) {
  const c = getCharacter(conv.characterID);
  if (!c) return null;
  return h('a', { class: 'cont-card', href: conversationHref(conv) },
    avatar(c, { size: 48 }),
    h('div', { class: 'cont-body' },
      h('div', { class: 'cont-top' }, h('span', { class: 'cont-name ellipsis' }, c.name), h('span', { class: 'cont-time' }, relativeTime(conv.updatedAt))),
      h('p', { class: 'cont-preview ellipsis' }, previewText(conv) || c.tagline)));
}

function featuredCard(c) {
  const w = whereNow(c);
  const loc = w?.location;
  const colors = loc?.art?.colors || c.avatar?.colors || ['#2A211B', c.accentHex || '#FF8A4C'];
  const bg = h('div', { class: 'feat-bg', style: { '--fa': colors[0], '--fb': colors[1] || colors[0] } },
    h('span', { class: 'feat-emoji', 'aria-hidden': 'true' }, loc?.art?.emoji || loc?.emoji || c.avatar?.emoji || '✨'));
  const asset = loc?.art?.asset || (loc ? `loc-${loc.id}` : null);
  if (asset && !isMissingArt(artURL(asset))) attachImage(bg, artURL(asset), { alt: '' });
  return h('article', { class: 'feat-card' },
    bg,
    h('div', { class: 'feat-shade' }),
    h('div', { class: 'feat-content' },
      h('div', { class: 'feat-where' }, icon('map-pin', { size: 14 }), loc ? loc.name : 'Lantern Bay'),
      h('div', { class: 'feat-who' },
        avatar(c, { size: 52, shape: 'rounded' }),
        h('div', { class: 'feat-text' },
          h('h3', { class: 'feat-name' }, h('a', { href: `#/c/${encodeURIComponent(c.id)}`, class: 'feat-link' }, c.name)),
          h('p', { class: 'feat-doing clamp-2' }, w ? `${capitalize(w.activity)}.` : c.tagline))),
      h('div', { class: 'feat-actions' },
        h('a', { class: 'btn btn-primary btn-sm', href: `#/chat/${encodeURIComponent(c.id)}` }, icon('message', { size: 16 }), `Chat with ${c.name}`))));
}

function townNow(characters) {
  const w = world();
  const part = dayPart();
  const out = characters.filter((c) => whereNow(c)?.location).slice();
  const rand = seeded(hash(`${new Date().toDateString()}|${new Date().getHours()}`));
  const two = shuffled(out, rand).slice(0, 2);
  const line = two.map((c) => {
    const x = whereNow(c);
    return `${c.name} is ${x.activity} at ${x.location.name.replace(/^The\s/, 'the ')}`;
  }).join('. ');
  return h('a', { class: 'town-now', href: '#/town' },
    h('span', { class: 'town-now-icon', 'aria-hidden': 'true' }, PART_ICON[part]),
    h('span', { class: 'town-now-text' },
      h('strong', {}, `${capitalize(part)} in ${w?.name || 'Lantern Bay'}`),
      h('span', { class: 'clamp-2' }, line ? `${line}.` : (w?.tagline || ''))),
    h('span', { class: 'town-now-go' }, 'Visit the town', icon('chevron-right', { size: 16 })));
}

export async function renderDiscover(ctx) {
  ctx.setTitle('Discover');
  const w = world();
  const characters = allCharacters();
  const name = userName();
  const recents = await recentCharacterChats(10);
  if (ctx.signal.aborted) return null;

  const page = h('div', { class: 'page discover' });

  const hello = h('div', { class: 'disc-hello' },
    h('span', { class: 'hello-avatar', 'aria-hidden': 'true' }, name.charAt(0).toUpperCase()),
    h('div', {},
      h('p', { class: 'hello-sub' }, recents.length ? 'Welcome back,' : `Welcome to ${w?.name || 'Lantern Bay'},`),
      h('h1', { class: 'hello-name serif' }, name)));
  page.append(h('header', { class: 'disc-head' }, hello, characters.length ? townNow(w?.characters || characters) : null));

  if (!characters.length) {
    page.append(emptyState({ iconName: 'users', title: 'Nobody is home yet', body: "The town's residents haven't arrived. Try reloading the page." }));
    return page;
  }

  if (recents.length) {
    const cards = recents.map(continueCard).filter(Boolean);
    const s = scroller(cards, { label: 'Continue chatting', className: 'cont-track' });
    page.append(h('section', { class: 'disc-section', 'aria-labelledby': 'sec-continue' },
      sectionHeader('Continue chatting', { id: 'sec-continue', actions: s.controls }), s.track));
  }

  // For you: residents you haven't talked to yet, in a different order each day.
  const talked = new Set(recents.map((r) => r.characterID));
  const daily = seeded(hash(new Date().toDateString()));
  let forYou = shuffled(characters.filter((c) => !talked.has(c.id)), daily);
  if (forYou.length < 4) forYou = [...forYou, ...shuffled(characters.filter((c) => talked.has(c.id)), daily)];
  forYou = forYou.slice(0, 10);
  const fy = scroller(forYou.map((c) => characterCard(c)), { label: 'For you', className: 'card-track' });
  page.append(h('section', { class: 'disc-section', 'aria-labelledby': 'sec-foryou' },
    sectionHeader('For you', { id: 'sec-foryou', subtitle: 'Neighbors you might like to meet', actions: fy.controls }), fy.track));

  // Featured: who's out and about right now.
  const out = (w?.characters || []).filter((c) => whereNow(c)?.location);
  const featured = shuffled(out.length ? out : characters, seeded(hash(`feat|${new Date().toDateString()}|${dayPart()}`))).slice(0, 6);
  const ft = scroller(featured.map(featuredCard), { label: 'Featured', className: 'feat-track' });
  page.append(h('section', { class: 'disc-section', 'aria-labelledby': 'sec-featured' },
    sectionHeader('Featured', { id: 'sec-featured', subtitle: `Out and about this ${dayPart()}`, actions: ft.controls }), ft.track));

  // Explore: chips + grid.
  const cats = (w?.categories || []).filter((cat) => characters.some((c) => (c.categories || []).includes(cat.id)));
  const mine = userMadeCharacters();
  const grid = h('div', { class: 'card-grid', id: 'explore-grid', 'aria-live': 'polite' });
  const chipsRow = h('div', { class: 'chips no-scrollbar', role: 'toolbar', 'aria-label': 'Categories' });
  const options = [{ id: 'all', title: 'All' }, ...cats, ...(mine.length ? [{ id: 'mine', title: 'Made by you', emoji: '✏️' }] : [])];
  if (!options.some((o) => o.id === activeCategory)) activeCategory = 'all';
  const paint = () => {
    chipsRow.replaceChildren(...options.map((o) => chip({
      label: o.title, emoji: o.emoji || null, active: o.id === activeCategory, ariaControls: 'explore-grid',
      onClick: () => { activeCategory = o.id; paint(); },
    })));
    const list = activeCategory === 'all' ? characters
      : activeCategory === 'mine' ? mine
        : characters.filter((c) => (c.categories || []).includes(activeCategory));
    grid.replaceChildren(...list.map((c) => characterCard(c)));
  };
  paint();
  page.append(h('section', { class: 'disc-section', 'aria-labelledby': 'sec-explore' },
    sectionHeader(`Everyone in ${w?.name || 'town'}`, { id: 'sec-explore' }), chipsRow, grid));

  page.append(h('footer', { class: 'page-foot' },
    h('p', {}, 'Hearth characters are AI. What they say is made up.'),
    h('p', {}, 'Your chats stay in this browser. ', h('a', { class: 'link', href: 'privacy/' }, 'Privacy'), ' · ', h('a', { class: 'link', href: 'safety/' }, 'Safety'))));
  return page;
}
