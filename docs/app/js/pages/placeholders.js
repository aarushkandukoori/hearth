// Stand-in pages for #/town and #/create until the Town and Create modules register their own
// routes (registerRoute with the same pattern replaces these). Also the 404 page.

import { h, avatar, emptyState } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { world, allCharacters, whereNow } from '../data.js';
import { dayPart, whoIsAt } from '../brain/director.js';
import { capitalize } from '../util.js';

export function renderTownPlaceholder(ctx) {
  ctx.setTitle('Town');
  const w = world();
  const part = dayPart();
  const people = allCharacters();
  const places = (w?.locations || []).map((loc) => {
    const here = whoIsAt(loc.id, part, people);
    return h('article', { class: 'place-card', style: { '--pa': loc.art?.colors?.[0] || '#2A211B', '--pb': loc.art?.colors?.[1] || '#FF8A4C' } },
      h('div', { class: 'place-top' }, h('span', { class: 'place-emoji', 'aria-hidden': 'true' }, loc.emoji || loc.art?.emoji || '🏮'),
        h('div', {}, h('h2', { class: 'place-name' }, loc.name), h('p', { class: 'place-blurb' }, loc.blurb))),
      here.length
        ? h('ul', { class: 'place-people' }, here.map((c) => h('li', {},
          h('a', { class: 'place-person', href: `#/c/${encodeURIComponent(c.id)}` }, avatar(c, { size: 32 }),
            h('span', {}, h('strong', {}, c.name), h('span', { class: 'muted' }, ` ${whereNow(c)?.activity || ''}`))))))
        : h('p', { class: 'muted place-empty' }, 'Quiet right now.'));
  });
  return h('div', { class: 'page town-placeholder' },
    h('header', { class: 'page-head' },
      h('h1', { class: 'page-title serif' }, w?.name || 'Lantern Bay'),
      h('p', { class: 'page-sub' }, `${capitalize(part)} in town. ${w?.tagline || ''}`)),
    h('div', { class: 'place-grid' }, places));
}

export function renderCreatePlaceholder(ctx) {
  ctx.setTitle('Create');
  return h('div', { class: 'page narrow' }, emptyState({
    iconName: 'plus',
    title: 'Make a character',
    body: 'Soon you will be able to make your own resident here, and they will move into town. Everything you make stays in this browser.',
    action: h('a', { class: 'btn btn-secondary', href: '#/' }, icon('compass', { size: 18 }), 'Back to Discover'),
  }));
}

export function renderNotFound(ctx) {
  ctx.setTitle('Not found');
  return h('div', { class: 'page narrow' }, emptyState({
    iconName: 'map', title: 'This path leads nowhere',
    body: "The page you're looking for isn't in town.",
    action: h('a', { class: 'btn btn-secondary', href: '#/' }, 'Back to Discover'),
  }));
}
