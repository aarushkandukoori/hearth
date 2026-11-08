// Chats (#/chats): every conversation in this browser, newest first, grouped by day.
// Search (#/search?q=): find characters by name, species, tagline, tags or category.

import { h, avatar, characterCard, emptyState, menu, confirm, toast } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { allCharacters, getCharacter, getLocation, world } from '../data.js';
import { conversationSummaries, previewText, conversationHref, deleteConversation } from '../chats.js';
import { relativeTime, dayGroup } from '../util.js';
import { navigate } from '../router.js';

function locationAvatar(loc) {
  return h('span', { class: 'avatar circle', style: { width: '44px', height: '44px', '--av-a': loc?.art?.colors?.[0] || '#2A211B', '--av-b': loc?.art?.colors?.[1] || '#6FB7C9' } },
    h('span', { class: 'avatar-emoji', 'aria-hidden': 'true' }, loc?.emoji || loc?.art?.emoji || '🏮'));
}

export async function renderChats(ctx) {
  ctx.setTitle('Chats');
  const convs = (await conversationSummaries()).filter((c) => c.hasUser);
  if (ctx.signal.aborted) return null;
  const page = h('div', { class: 'page narrow chats-page' },
    h('header', { class: 'page-head' }, h('h1', { class: 'page-title serif' }, 'Chats'),
      h('p', { class: 'page-sub' }, 'Every conversation lives only in this browser.')));
  if (!convs.length) {
    page.append(emptyState({
      iconName: 'message', title: 'No chats yet',
      body: 'Say hello to someone in town. Your conversations will show up here.',
      action: h('a', { class: 'btn btn-primary', href: '#/' }, 'Find someone to talk to'),
    }));
    return page;
  }
  const list = h('ul', { class: 'chat-list' });
  let group = null;
  for (const conv of convs) {
    const g = dayGroup(conv.updatedAt);
    if (g !== group) { group = g; list.append(h('li', { class: 'list-group' }, g)); }
    const isScene = conv.kind === 'scene';
    const c = isScene ? null : getCharacter(conv.characterID);
    const loc = isScene ? getLocation(conv.locationID) : null;
    const title = isScene ? (conv.title || loc?.name || 'Group chat') : (c?.name || 'Someone who left town');
    const more = h('button', { class: 'icon-btn sm', type: 'button', 'aria-label': `More for ${title}`, 'aria-haspopup': 'menu' }, icon('more'));
    more.addEventListener('click', (e) => {
      e.preventDefault();
      menu(more, [
        { label: 'Open', icon: 'message', onClick: () => navigate(conversationHref(conv)) },
        ...(c ? [{ label: 'View profile', icon: 'user', onClick: () => navigate(`#/c/${encodeURIComponent(c.id)}`) }] : []),
        { separator: true },
        {
          label: 'Delete chat', icon: 'trash', danger: true,
          onClick: async () => {
            if (!(await confirm({ title: 'Delete this chat?', message: "It will be removed from this browser, along with what was learned from it. This can't be undone.", confirmLabel: 'Delete chat' }))) return;
            await deleteConversation(conv.id);
            row.remove();
            toast('Chat deleted.');
          },
        },
      ]);
    });
    const row = h('li', { class: 'chat-row' },
      h('a', { class: 'chat-link', href: conversationHref(conv) },
        isScene ? locationAvatar(loc) : avatar(c, { size: 44 }),
        h('span', { class: 'chat-text' },
          h('span', { class: 'chat-top' }, h('span', { class: 'chat-name ellipsis' }, title),
            isScene ? h('span', { class: 'badge sea' }, 'Group') : null,
            h('span', { class: 'chat-time' }, relativeTime(conv.updatedAt))),
          h('span', { class: 'chat-preview ellipsis' }, previewText(conv)))),
      more);
    list.append(row);
  }
  page.append(list);
  return page;
}

function matches(c, q) {
  const cats = (world()?.categories || []).filter((x) => (c.categories || []).includes(x.id)).map((x) => x.title);
  const hay = [c.name, c.species, c.tagline, c.bio, c.creator, ...(c.tags || []), ...cats].filter(Boolean).join(' ').toLowerCase();
  return q.toLowerCase().split(/\s+/).filter(Boolean).every((w) => hay.includes(w.replace(/^#/, '')));
}

export function renderSearch(ctx) {
  const q0 = (ctx.query.q || '').trim();
  ctx.setTitle('Search');
  const input = h('input', { class: 'input search-input', type: 'search', value: q0, placeholder: 'Search characters, like "baker" or "books"', 'aria-label': 'Search characters', enterkeyhint: 'search', autocomplete: 'off' });
  const count = h('p', { class: 'result-count', 'aria-live': 'polite' });
  const results = h('div', { class: 'search-results' });
  const all = allCharacters();
  const paint = (q) => {
    const found = q ? all.filter((c) => matches(c, q)) : all;
    count.textContent = q ? `${found.length} ${found.length === 1 ? 'match' : 'matches'} for "${q}"` : 'Everyone in town';
    results.replaceChildren(found.length
      ? h('div', { class: 'card-grid' }, found.map((c) => characterCard(c)))
      : emptyState({
        iconName: 'search', title: 'Nobody by that name yet',
        body: 'Try a different word, or make a character of your own.',
        action: h('a', { class: 'btn btn-secondary', href: '#/create' }, icon('plus', { size: 18 }), 'Create a character'),
      }));
  };
  let timer = null;
  input.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      const q = input.value.trim();
      paint(q);
      navigate(`#/search${q ? `?q=${encodeURIComponent(q)}` : ''}`, { silent: true });
    }, 180);
  });
  ctx.signal.addEventListener('abort', () => clearTimeout(timer));
  paint(q0);
  const page = h('div', { class: 'page search-page' },
    h('header', { class: 'page-head' },
      h('h1', { class: 'page-title serif' }, 'Search'),
      h('form', { class: 'search-box', role: 'search', onSubmit: (e) => { e.preventDefault(); input.blur(); } }, icon('search', { size: 18 }), input)),
    count, results);
  const typingElsewhere = document.activeElement instanceof HTMLInputElement || document.activeElement instanceof HTMLTextAreaElement;
  if (!typingElsewhere && !matchMedia('(pointer: coarse)').matches) {
    requestAnimationFrame(() => { input.focus(); input.setSelectionRange(input.value.length, input.value.length); });
  }
  return page;
}
