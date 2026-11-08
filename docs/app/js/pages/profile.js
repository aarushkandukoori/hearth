// Character profile (#/c/:id): big avatar, name, tagline, creator, bio, where they are right now and
// their day, friends in town (links), what they remember about you, and Chat / Start a new chat.

import { h, avatar, richText, emptyState, confirm, toast } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { getCharacter, getLocation, world, settings, deleteUserCharacter } from '../data.js';
import { DAY_PARTS, dayPart, locationOf } from '../brain/director.js';
import { factRecordsFor, forget } from '../brain/memory.js';
import { conversationsFor } from '../chats.js';
import { capitalize } from '../util.js';
import { navigate } from '../router.js';

const PART_LABEL = { morning: 'Morning', afternoon: 'Afternoon', evening: 'Evening', night: 'Night' };

function scheduleCard(c) {
  const now = dayPart();
  const rows = DAY_PARTS.map((part) => {
    const slot = locationOf(c, part, world());
    if (!slot) return null;
    const loc = slot.location || getLocation(slot.locationID);
    const current = part === now;
    return h('li', { class: `sched-row${current ? ' now' : ''}`, 'aria-current': current ? 'time' : null },
      h('span', { class: 'sched-part' }, PART_LABEL[part], current ? h('span', { class: 'badge accent' }, 'Now') : null),
      h('span', { class: 'sched-place' }, loc?.emoji ? h('span', { class: 'sched-emoji', 'aria-hidden': 'true' }, loc.emoji) : null, loc?.name || 'Out and about'),
      h('span', { class: 'sched-activity' }, capitalize(slot.activity)));
  }).filter(Boolean);
  if (!rows.length) return null;
  const here = locationOf(c, now, world());
  const loc = here?.location;
  return h('section', { class: 'prof-section', 'aria-labelledby': 'prof-now' },
    h('h2', { class: 'prof-h', id: 'prof-now' }, 'Right now'),
    loc ? h('a', { class: 'now-card', href: '#/town', style: { '--na': loc.art?.colors?.[0] || '#2A211B', '--nb': loc.art?.colors?.[1] || '#FF8A4C' } },
      h('span', { class: 'now-emoji', 'aria-hidden': 'true' }, loc.emoji || loc.art?.emoji || '📍'),
      h('span', { class: 'now-text' },
        h('strong', {}, `${c.name} is at ${loc.name.replace(/^The\s/, 'the ')}`),
        h('span', {}, `${capitalize(here.activity)}. ${loc.blurb || ''}`.trim())),
      icon('chevron-right', { size: 18 })) : null,
    h('ol', { class: 'sched' }, rows));
}

function friendsCard(c) {
  const rels = (c.relationships || []).map((r) => ({ r, other: getCharacter(r.characterID) })).filter((x) => x.other);
  if (!rels.length) return null;
  return h('section', { class: 'prof-section', 'aria-labelledby': 'prof-friends' },
    h('h2', { class: 'prof-h', id: 'prof-friends' }, 'Friends in town'),
    h('ul', { class: 'rel-list' }, rels.map(({ r, other }) => h('li', {},
      h('a', { class: 'rel-row', href: `#/c/${encodeURIComponent(other.id)}` },
        avatar(other, { size: 44 }),
        h('span', { class: 'rel-text' },
          h('span', { class: 'rel-name' }, other.name, h('span', { class: 'rel-kind' }, r.kind)),
          h('span', { class: 'rel-note' }, r.note)),
        icon('chevron-right', { size: 18 }))))));
}

async function memoryCard(c, signal) {
  const facts = (await factRecordsFor(c.id, { gossip: settings().townGossip })).filter((f) => f.characterID === c.id);
  if (signal.aborted) return null;
  const list = h('ul', { class: 'mem-list' });
  const section = h('section', { class: 'prof-section', 'aria-labelledby': 'prof-mem' },
    h('h2', { class: 'prof-h', id: 'prof-mem' }, `What ${c.name} remembers about you`),
    h('p', { class: 'prof-note' }, 'Kept only in this browser. Remove anything you would rather they forget.'),
    list);
  const paint = (rows) => {
    if (!rows.length) {
      list.replaceChildren(h('li', { class: 'mem-empty' }, 'Nothing yet. Pin a message in a chat, or just talk, and things you share can stick.'));
      return;
    }
    list.replaceChildren(...rows.map((f) => h('li', { class: 'mem-row' },
      h('span', { class: 'mem-icon', 'aria-hidden': 'true' }, icon(f.source === 'pinned' ? 'pin' : 'sparkle', { size: 15 })),
      h('span', { class: 'mem-text' }, f.text),
      h('button', {
        class: 'icon-btn sm', type: 'button', 'aria-label': `Forget: ${f.text}`,
        onClick: async () => { await forget(f.id); rows = rows.filter((x) => x.id !== f.id); paint(rows); toast(`${c.name} forgot that.`); },
      }, icon('x')))));
  };
  paint(facts);
  return section;
}

export async function renderProfile(ctx) {
  const c = getCharacter(ctx.params.id);
  if (!c) {
    ctx.setTitle('Not found');
    return h('div', { class: 'page narrow' }, emptyState({
      iconName: 'users', title: "We couldn't find that character",
      body: 'They may have been deleted from this browser.',
      action: h('a', { class: 'btn btn-secondary', href: '#/' }, 'Back to Discover'),
    }));
  }
  // Names of characters you made stay out of the tab title (and so out of synced browser history).
  ctx.setTitle(c.isBuiltIn ? c.name : 'Character');
  const home = c.homeLocationID ? getLocation(c.homeLocationID) : null;
  const chats = await conversationsFor(c.id);
  if (ctx.signal.aborted) return null;

  const facts = [c.species ? capitalize(c.species) : null, home ? `Lives at ${home.name.replace(/^The\s/, 'the ')}` : null,
    chats.length ? `${chats.length} chat${chats.length === 1 ? '' : 's'} with you` : null].filter(Boolean);

  const actions = h('div', { class: 'prof-actions' },
    h('a', { class: 'btn btn-primary btn-lg', href: `#/chat/${encodeURIComponent(c.id)}` }, icon('message', { size: 18 }), 'Chat'),
    h('a', { class: 'btn btn-secondary btn-lg', href: `#/chat/${encodeURIComponent(c.id)}/new` }, icon('plus', { size: 18 }), 'Start a new chat'));
  if (!c.isBuiltIn) {
    actions.append(
      h('a', { class: 'btn btn-ghost', href: `#/create?edit=${encodeURIComponent(c.id)}` }, icon('edit', { size: 18 }), 'Edit'),
      h('button', {
        class: 'btn btn-ghost', type: 'button',
        onClick: async () => {
          const ok = await confirm({ title: `Delete ${c.name}?`, message: 'This removes the character from this browser. Your chats with them stay in Chats until you delete them.', confirmLabel: 'Delete character' });
          if (!ok) return;
          await deleteUserCharacter(c.id);
          toast(`${c.name} was deleted.`);
          navigate('#/');
        },
      }, icon('trash', { size: 18 }), 'Delete'));
  }

  const page = h('div', { class: 'page profile', style: { '--accent-char': c.accentHex || 'var(--accent)' } },
    h('header', { class: 'prof-hero' },
      h('div', { class: 'prof-glow', 'aria-hidden': 'true' }),
      avatar(c, { size: 136, shape: 'rounded', className: 'prof-avatar', alt: c.name }),
      h('h1', { class: 'prof-name serif' }, c.name),
      c.tagline ? h('p', { class: 'prof-tagline' }, c.tagline) : null,
      h('p', { class: 'prof-by' }, `By ${c.creator || '@lanternbay'}`),
      facts.length ? h('p', { class: 'prof-facts' }, facts.join(' · ')) : null,
      actions),
    c.bio ? h('section', { class: 'prof-section', 'aria-labelledby': 'prof-about' },
      h('h2', { class: 'prof-h', id: 'prof-about' }, 'About'), richText(c.bio, { className: 'rich prof-bio' })) : null,
    scheduleCard(c),
    friendsCard(c),
    await memoryCard(c, ctx.signal),
    (c.tags || []).length ? h('section', { class: 'prof-section' },
      h('h2', { class: 'prof-h' }, 'Tags'),
      h('div', { class: 'tag-row' }, c.tags.map((t) => h('a', { class: 'chip', href: `#/search?q=${encodeURIComponent(t)}` }, `#${t}`)))) : null,
    h('p', { class: 'prof-disclosure' }, `${c.name} is an AI character. What they say is made up.`));
  return page;
}
