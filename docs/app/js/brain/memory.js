// What characters remember about the user: cheap regex facts, dedupe, and the "memories" store.
// Facts never leave the browser. Max 40 per character; shareable facts travel only when town gossip is on.

import { getAll, put, del } from '../store.js';
import { uid } from '../util.js';
import { assess } from './safety.js';

export const MAX_FACTS_PER_CHARACTER = 40;
const PIN_MAX_CHARS = 400;

const RELATIONS = [
  'best friend', 'dog', 'cat', 'puppy', 'kitten', 'bird', 'parrot', 'rabbit', 'bunny', 'hamster', 'fish', 'horse',
  'sister', 'brother', 'mom', 'mother', 'mum', 'dad', 'father', 'son', 'daughter', 'wife', 'husband', 'partner',
  'girlfriend', 'boyfriend', 'fiance', 'fiancee', 'friend', 'roommate', 'grandma', 'grandmother', 'grandpa',
  'grandfather', 'aunt', 'uncle', 'cousin', 'niece', 'nephew', 'neighbor', 'neighbour', 'boss', 'coworker', 'kid', 'baby',
];
const REL = RELATIONS.join('|');
const NOT_A_NAME = /^(?:not|a|an|the|kind|actually|just|really|very|so|sick|tired|here|back|sorry|fine|okay|ok|going|trying)$/i;
const VAGUE_LIKE = /^(?:it|that|this|you|when|how|the way|to think|being|him|her|them|us|me)\b/i;

const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const tidy = (s) => s.trim().replace(/\s+(?:too|a lot|so much|very much|lol|haha)$/i, '').replace(/[\s,;:]+$/, '');

/** True when the safety check flags this text at any level (MemoryKeeper on iPhone). */
const isSensitive = (text) => assess(String(text || '')).level !== 'none';

/**
 * Reads a stored fact as if the person said it ("Wants to die" -> "I want to die", "Their partner hits them"
 * -> "my partner hits me"), because the safety check reads first person. Only used to check safety.
 * Same rules as MemoryKeeper.firstPerson on iPhone.
 */
function firstPerson(text) {
  let t = String(text || '').replace(/\s+/g, ' ').trim()
    .replace(/\bthemsel(?:f|ves)\b/gi, 'myself').replace(/\btheir\b/gi, 'my').replace(/\bthem\b/gi, 'me')
    .replace(/\bthey(?:'re|\u2019re|\s+are)\b/gi, 'i am').replace(/\bthey\b/gi, 'i')
    .replace(/\bdoesn(?:'|\u2019)?t\b/gi, "don't").replace(/\bdoes\s+not\b/gi, 'do not');
  // Summary facts usually leave out the subject ("Is in danger at home"): put "I" back in front.
  const words = t.split(' ').filter(Boolean);
  if (!words.length) return t;
  const first = words[0].toLowerCase();
  if (['i', "i'm", 'i\u2019m', 'my', 'me', 'myself', "i've", "i'll", "i'd"].includes(first)) return t;
  words[0] = firstPersonVerb(first);
  return `I ${words.join(' ')}`;
}

/** "is" -> "am", "has" -> "have", "wishes" -> "wish", "hurts" -> "hurt" (any other word stays as it is). */
function firstPersonVerb(word) {
  if (word === 'is') return 'am';
  if (word === 'has') return 'have';
  if (word === 'does') return 'do';
  if (/(?:shes|ches|sses|xes|zes)$/.test(word)) return word.slice(0, -2);
  if (word.endsWith('ies') && word.length > 4) return `${word.slice(0, -3)}y`;
  if (word.endsWith('s') && !word.endsWith('ss') && word.length > 3) return word.slice(0, -1);
  return word;
}

/** A stored fact that sounds like someone may be in danger: flagged as written, or a crisis read in first person. */
const isSensitiveFact = (text) => isSensitive(text) || assess(firstPerson(text)).level === 'crisis';

/**
 * Facts from one user message, phrased for the prompt ("Lives in Pittsburgh"). Nothing is learned from a
 * message that may come from someone in danger: it could come up again out of context, or travel to every
 * resident through town gossip.
 */
export function extractFacts(text) {
  if (isSensitive(text)) return [];
  const t = String(text || '').replace(/[‘’]/g, "'");
  const out = [];
  let m;

  if ((m = t.match(/\b(?:my name is|call me|i go by)\s+([A-Za-z][\w'-]{1,24})/i)) && !NOT_A_NAME.test(m[1])) {
    out.push(`Goes by ${cap(m[1])}`);
  }
  if ((m = t.match(/\bi live in\s+([^.,!?;\n]{2,40})/i))) out.push(`Lives in ${tidy(m[1])}`);
  if ((m = t.match(/\bi(?:'m| am) from\s+([^.,!?;\n]{2,40})/i))) out.push(`Is from ${tidy(m[1])}`);
  if ((m = t.match(/\bi work\s+(as an?|as|at|in|for)\s+([^.,!?;\n]{2,40})/i))) {
    out.push(`Works ${m[1].toLowerCase()} ${tidy(m[2])}`);
  }
  const likeRe = /\bi (?:really |absolutely |just |also )?(love|like|enjoy|adore)\s+([^.,!?;\n]{2,40})/gi;
  while ((m = likeRe.exec(t))) {
    const thing = tidy(m[2]);
    if (!thing || VAGUE_LIKE.test(thing)) continue;
    const verb = { love: 'Loves', like: 'Likes', enjoy: 'Enjoys', adore: 'Adores' }[m[1].toLowerCase()];
    out.push(`${verb} ${thing}`);
  }
  const namedRel = new RegExp(`\\b[Mm]y (${REL})(?:'s name is| is named| is called| named| called|,)?\\s+([A-Z][\\w'-]{1,24})`, 'g');
  while ((m = namedRel.exec(t))) {
    if (NOT_A_NAME.test(m[2])) continue;
    out.push(`Has a ${m[1].toLowerCase()} named ${m[2]}`);
  }
  return dedupe(out);
}

/** Lowercase words without punctuation. */
export function normalize(s) {
  return String(s || '').toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, ' ').replace(/\s+/g, ' ').trim();
}

export function jaccard(a, b) {
  const A = new Set(normalize(a).split(' ').filter(Boolean));
  const B = new Set(normalize(b).split(' ').filter(Boolean));
  if (A.size === 0 && B.size === 0) return 1;
  let inter = 0;
  for (const w of A) if (B.has(w)) inter++;
  return inter / (A.size + B.size - inter);
}

/** Same fact? (case-insensitive equal, or Jaccard similarity above 0.6) */
export function isDuplicate(a, b) {
  return normalize(a) === normalize(b) || jaccard(a, b) > 0.6;
}

export function dedupe(facts) {
  const out = [];
  for (const f of facts) if (f && !out.some((o) => isDuplicate(o, f))) out.push(f);
  return out;
}

/** The incoming facts that are not already known (or repeated within `incoming`). */
export function newFacts(existing, incoming) {
  const out = [];
  for (const f of incoming) {
    if (!f) continue;
    if (existing.some((e) => isDuplicate(e, f)) || out.some((o) => isDuplicate(o, f))) continue;
    out.push(f);
  }
  return out;
}

// ---- Stored facts (IndexedDB "memories" store) --------------------------------------------------
// Record: { id, characterID (null = everyone), text, createdAt, source: 'pinned'|'auto'|'summary', shareable,
//           conversationID (the chat it was learned in, so deleting the chat forgets it),
//           messageID (pinned only: the message it came from) }

/**
 * All fact records a character may use: their own, ones for everyone, and shareable ones when gossip is on.
 * A fact that sounds like someone may be in danger never travels to another resident.
 */
export async function factRecordsFor(characterID, { gossip = false } = {}) {
  const all = await getAll('memories');
  return all
    .filter((f) => f.characterID === characterID || f.characterID == null
      || (gossip && f.shareable && !isSensitiveFact(f.text)))
    .sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
}

/** Fact texts for the prompt, newest first (max 40, own facts before gossip). */
export async function factsFor(characterID, opts = {}) {
  const recs = await factRecordsFor(characterID, opts);
  const own = recs.filter((f) => f.characterID === characterID || f.characterID == null);
  const heard = recs.filter((f) => f.characterID !== characterID && f.characterID != null);
  return dedupe([...own, ...heard].map((f) => f.text)).slice(0, MAX_FACTS_PER_CHARACTER);
}

/**
 * Saves new facts for a character (deduped). Returns the records that were added. A fact that sounds like
 * someone may be in danger is skipped (pins go through pinFact and are never shareable).
 */
export async function remember(characterID, texts, { source = 'auto', shareable = false, conversationID = null } = {}) {
  const all = await getAll('memories');
  const mine = all.filter((f) => f.characterID === characterID);
  const safe = texts.map((t) => String(t).trim().slice(0, 240)).filter((t) => t && !isSensitiveFact(t));
  const fresh = newFacts(mine.map((f) => f.text), safe);
  const added = [];
  for (const text of fresh) {
    const rec = { id: uid(), characterID, text, createdAt: Date.now(), source, shareable: !!shareable, conversationID };
    await put('memories', rec);
    added.push(rec);
  }
  // Keep at most 40: drop the oldest non-pinned facts first.
  const after = [...mine, ...added];
  if (after.length > MAX_FACTS_PER_CHARACTER) {
    const removable = after.filter((f) => f.source !== 'pinned').sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
    for (const f of removable.slice(0, after.length - MAX_FACTS_PER_CHARACTER)) await del('memories', f.id);
  }
  return added;
}

/** A pinned memory that came from this message (by id), or that has the same (shortened) text. */
function isPinOf(f, characterID, text, messageID) {
  if (f.characterID !== characterID || f.source !== 'pinned') return false;
  return (messageID && f.messageID === messageID) || normalize(f.text) === normalize(String(text).trim().slice(0, PIN_MAX_CHARS));
}

/** Pins a message as a memory. Returns the record (existing one if already pinned). */
export async function pinFact(characterID, text, { messageID = null, conversationID = null } = {}) {
  const all = await getAll('memories');
  const existing = all.find((f) => isPinOf(f, characterID, text, messageID));
  if (existing) return existing;
  const rec = {
    id: uid(), characterID, text: String(text).trim().slice(0, PIN_MAX_CHARS), createdAt: Date.now(),
    source: 'pinned', shareable: false, messageID, conversationID,
  };
  await put('memories', rec);
  return rec;
}

/** Unpins a message: matched by the message it came from, or (for older pins) by its text. */
export async function unpinFact(characterID, text, { messageID = null } = {}) {
  const all = await getAll('memories');
  for (const f of all) {
    if (isPinOf(f, characterID, text, messageID)) await del('memories', f.id);
  }
}

export async function forget(id) { await del('memories', id); }

/** Forgets everything learned in one conversation (its facts and pinned messages). */
export async function forgetConversation(conversationID) {
  if (!conversationID) return;
  for (const f of await getAll('memories')) {
    if (f.conversationID === conversationID) await del('memories', f.id);
  }
}
