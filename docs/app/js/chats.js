// Conversations and messages: the shapes stored in IndexedDB ("conversations") and helpers to
// create, find, save and link them. Direct chats belong to one character; scenes to a location.
//
// conversation = { id, kind: 'direct'|'scene', characterID?, locationID?, participantIDs: [],
//                  title?, messages: [], createdAt, updatedAt }
// message      = { id, role: 'user'|'character'|'narrator', speakerID, createdAt,
//                  variants: [text...], selected, extras: [{ attachment?, rating?, stats? } per variant],
//                  pinned }
// attachment   = { kind: 'photo'|'picture'|'voice', dataURL?, src?, caption?, duration?, waveform?, postcard? }

import * as store from './store.js';
import { uid, fillNames } from './util.js';
import { emit, subscribe } from './data.js';
import { forgetConversation } from './brain/memory.js';

export function makeMessage({ role, speakerID = null, text = '', variants = null, attachment = null }) {
  const vs = variants && variants.length ? variants.slice() : [text];
  return {
    id: uid(),
    role,
    speakerID,
    createdAt: Date.now(),
    variants: vs,
    selected: 0,
    extras: vs.map((_, i) => (i === 0 && attachment ? { attachment } : {})),
    pinned: false,
  };
}

export const textOf = (m) => (m?.variants?.[m.selected ?? 0] ?? m?.variants?.[0] ?? '');
export const extraOf = (m) => m?.extras?.[m.selected ?? 0] || {};
export const attachmentOf = (m) => extraOf(m).attachment || null;

/** Updates the selected variant's extras in place. */
export function setExtra(m, patch) {
  if (!Array.isArray(m.extras)) m.extras = [];
  const i = m.selected ?? 0;
  m.extras[i] = { ...(m.extras[i] || {}), ...patch };
}

/** A fresh, unsaved direct chat that starts with the character's greeting (alt greetings = swipes). */
export function newDirectConversation(character, { userName = 'Friend' } = {}) {
  const fill = (s) => fillNames(s, { user: userName, char: character.name });
  const greetings = [character.greeting, ...(character.altGreetings || [])].filter(Boolean).map(fill);
  const now = Date.now();
  return {
    id: uid(),
    kind: 'direct',
    characterID: character.id,
    participantIDs: [character.id],
    title: null,
    messages: greetings.length ? [makeMessage({ role: 'character', speakerID: character.id, variants: greetings })] : [],
    createdAt: now,
    updatedAt: now,
  };
}

export async function getConversation(id) { return store.get('conversations', id); }

/** Every conversation with all its messages (and photos). Lists should use conversationSummaries(). */
export async function allConversations() {
  const rows = await store.getAll('conversations');
  return rows.sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
}

// ---- Summaries --------------------------------------------------------------------------------
// Lists (sidebar, Discover, Chats, history) only need a line per chat, not every message and photo,
// so the summaries are read once and then kept current by saveConversation() and deleteConversation().
// summary = { id, kind, characterID, locationID, title, createdAt, updatedAt, hasUser, count, preview }

let summaries = null;        // Map<id, summary> once read
const changes = new Map();   // saves and deletes made while the first read is still running

function summaryOf(conv) {
  const messages = Array.isArray(conv.messages) ? conv.messages : [];
  return {
    id: conv.id, kind: conv.kind, characterID: conv.characterID ?? null, locationID: conv.locationID ?? null,
    title: conv.title ?? null, createdAt: conv.createdAt, updatedAt: conv.updatedAt,
    hasUser: messages.some((m) => m?.role === 'user'), count: messages.length, preview: previewText(conv),
  };
}

function noteChange(id, summary) {
  const target = summaries || changes;
  if (summary) target.set(id, summary); else if (summaries) summaries.delete(id); else changes.set(id, null);
}

/** Summaries of every conversation, newest first. */
export async function conversationSummaries() {
  if (!summaries) {
    const map = new Map((await store.getAll('conversations')).map((c) => [c.id, summaryOf(c)]));
    if (!summaries) {
      for (const [id, s] of changes) { if (s) map.set(id, s); else map.delete(id); }
      changes.clear();
      summaries = map;
    }
  }
  return [...summaries.values()].sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
}

// An import replaces rows wholesale (it emits null): read the summaries again next time.
subscribe('conversations', (payload) => { if (payload == null) { summaries = null; changes.clear(); } });

/** Direct chats with one character (summaries), newest first. */
export async function conversationsFor(characterID) {
  return (await conversationSummaries()).filter((c) => c.kind === 'direct' && c.characterID === characterID);
}

export async function latestConversation(characterID) {
  const latest = (await conversationsFor(characterID))[0];
  return (latest && (await getConversation(latest.id))) || null;
}

/** Saves (and bumps updatedAt unless `touch` is false). */
export async function saveConversation(conv, { touch = true } = {}) {
  if (touch) conv.updatedAt = Date.now();
  await store.put('conversations', conv);
  noteChange(conv.id, summaryOf(conv));
  emit('conversations', conv);
  return conv;
}

/** Deletes a conversation and what was learned in it (its facts and pinned messages). */
export async function deleteConversation(id) {
  await store.del('conversations', id);
  noteChange(id, null);
  await forgetConversation(id);
  emit('conversations', { id, deleted: true });
}

/** Most recent direct chats (summaries), one per character. */
export async function recentCharacterChats(limit = 12) {
  const seen = new Set();
  const out = [];
  for (const c of await conversationSummaries()) {
    if (c.kind !== 'direct' || seen.has(c.characterID) || !c.hasUser) continue;
    seen.add(c.characterID);
    out.push(c);
    if (out.length >= limit) break;
  }
  return out;
}

/** One-line preview of the last message ("You: ..." for the user's). Takes a conversation or a summary. */
export function previewText(conv) {
  if (!Array.isArray(conv?.messages)) return conv?.preview || '';
  const last = [...conv.messages].reverse().find((m) => m?.role !== 'narrator');
  if (!last) return '';
  const att = attachmentOf(last);
  let text = textOf(last).replace(/\*[^*\n]+\*/g, '').replace(/\s+/g, ' ').trim();
  if (!text && att?.kind === 'photo') text = 'Sent a photo';
  if (!text && att?.kind === 'picture') text = 'Sent a picture';
  if (att?.kind === 'voice') text = `Voice note: ${text}`;
  return last.role === 'user' ? `You: ${text}` : text;
}

const hrefMakers = {
  direct: (c) => `#/chat/${encodeURIComponent(c.characterID)}/${encodeURIComponent(c.id)}`,
  scene: (c) => `#/town/${encodeURIComponent(c.locationID || '')}`,
};

/** Lets another module decide where a conversation kind opens, e.g. setConversationHref('scene', fn). */
export function setConversationHref(kind, fn) { hrefMakers[kind] = fn; }

export function conversationHref(conv) {
  const make = hrefMakers[conv?.kind];
  return make ? make(conv) : '#/chats';
}
