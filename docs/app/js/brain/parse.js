// Turns raw model output into what the app shows: clean replies, photo requests, town events, facts.
// Rules from SPEC §7 ("Reply cleanup", away events, memory).

import { escapeRegExp } from '../util.js';

const PHOTO_RE = /\[\s*(?:photo|picture|image|pic)\s*:\s*([^\]\n]{1,240})\]/gi;
const PHOTO_OPEN_RE = /\[\s*(?:photo|picture|image|pic)\s*:[^\]\n]*$/i; // unfinished tag at the very end

/** Removes [photo: ...] tags. Returns { text, photo } where photo is the first caption or null. */
export function extractPhoto(text) {
  let photo = null;
  let out = String(text || '').replace(PHOTO_RE, (_, caption) => {
    if (!photo) photo = caption.trim().replace(/[.\s]+$/, '');
    return '';
  });
  out = out.replace(PHOTO_OPEN_RE, '');
  out = out.split('\n').map((l) => l.replace(/[ \t]+$/, '')).join('\n');
  return { text: out.replace(/\n{3,}/g, '\n\n').trim(), photo: photo || null };
}

/** A leading "Name:" or "**Name:**" label (a single * after it starts an *action* and is kept). */
const labelRe = (name) => new RegExp(`^\\s*(?:\\*\\*)?\\s*${escapeRegExp(name)}\\s*(?:\\*\\*)?\\s*:\\s*(?:\\*\\*(?=\\s))?\\s*`, 'i');

/** Cuts back to the last finished sentence (used only when the reply hit maxTokens). */
function dropDangling(text) {
  const t = text.trim();
  if (/[.!?…"'”’*)\]~]$/.test(t)) return t;
  const m = t.match(/^[\s\S]*[.!?…](?:["'”’*)\]]*)(?=\s|$)/);
  return m && m[0].length >= 12 ? m[0].trim() : t;
}

/**
 * Cleans one reply. Options: name (the speaker), userName, otherNames (other characters in a scene),
 * cutByLength (true when generation stopped at maxTokens). Returns { text, photo }.
 */
export function cleanReply(raw, { name = '', userName = '', otherNames = [], cutByLength = false } = {}) {
  let t = String(raw || '');
  t = t.replace(/<\|[^|>]{1,40}\|>/g, '');          // stray special tokens
  t = t.replace(/^\s*(?:assistant|model)\s*\n/i, '');
  t = t.trim();

  // Drop a leading "Name:" (also "**Name:**").
  if (name) {
    t = t.replace(labelRe(name), '').trim();
  }

  // Cut where the model starts writing someone else's line.
  const cutNames = [userName, 'You', 'User', ...otherNames].filter(Boolean);
  for (const n of cutNames) {
    const re = new RegExp(`(^|\\n)[ \\t]*\\**${escapeRegExp(n)}\\**[ \\t]*:`, 'i');
    const m = re.exec(t);
    if (!m) continue;
    if (m.index > 0) t = t.slice(0, m.index);
    else t = t.slice(m[0].length); // reply opened with someone else's label: drop just the label
  }

  const photo = extractPhoto(t);
  t = photo.text.replace(/\n{3,}/g, '\n\n').trim();
  if (cutByLength) t = dropDangling(t);
  return { text: t, photo: photo.photo };
}

/** What to show while a reply is still streaming (no labels, no half-written photo tags). */
export function streamingPreview(raw, { name = '' } = {}) {
  let t = String(raw || '').replace(/<\|[^|>]{1,40}\|>/g, '');
  if (name) {
    const label = `${name}:`.toLowerCase();
    const head = t.trim().toLowerCase();
    if (head.length <= label.length && label.startsWith(head)) return ''; // label still arriving
    t = t.replace(labelRe(name), '');
  }
  t = t.replace(PHOTO_RE, '');
  t = t.replace(/\[[^\]\n]*$/, ''); // hide a [tag] that is still being written
  return t.replace(/\n{3,}/g, '\n\n').trimStart();
}

/** "- " lines from a model answer (also accepts "* ", "• " and "1. "). */
function bulletLines(text) {
  return String(text || '')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => /^(?:[-*•]|\d+[.)])\s+/.test(l))
    .map((l) => l.replace(/^(?:[-*•]|\d+[.)])\s+/, '').trim())
    .filter(Boolean);
}

const isNone = (s) => /^(?:none|nothing(?: new)?|n\/a|no new facts?)\.?$/i.test(s.trim());

/**
 * Away-events answer -> [{ text, characterIDs, locationID }].
 * `world` gives the residents and places to detect by name.
 */
export function parseEvents(text, world, { max = 3, characters = null } = {}) {
  const cast = characters || world?.characters || [];
  const places = world?.locations || [];
  const out = [];
  for (const line of bulletLines(text)) {
    if (isNone(line)) continue;
    const clean = line.replace(/^["“]|["”]$/g, '').trim();
    if (clean.split(/\s+/).length > 40) continue;
    const characterIDs = cast
      .filter((c) => new RegExp(`(^|[^\\p{L}])${escapeRegExp(c.name)}(?![\\p{L}])`, 'iu').test(clean))
      .map((c) => c.id);
    // The place mentioned first wins ("dinner at the harbor, then the lighthouse" -> harbor).
    let place = null;
    let at = Infinity;
    for (const l of places) {
      const i = clean.toLowerCase().indexOf(l.name.replace(/^the\s+/i, '').toLowerCase());
      if (i >= 0 && i < at) { at = i; place = l; }
    }
    out.push({ text: clean, characterIDs, locationID: place ? place.id : null });
    if (out.length >= max) break;
  }
  return out;
}

/** Memory answer -> up to 3 short facts (drops "none"). */
export function parseFacts(text, { max = 3 } = {}) {
  const out = [];
  for (const line of bulletLines(text)) {
    if (isNone(line)) continue;
    const fact = line.replace(/^["“]|["”]$/g, '').replace(/\s+/g, ' ').replace(/\.$/, '').trim();
    if (!fact || fact.split(' ').length > 20) continue;
    out.push(fact);
    if (out.length >= max) break;
  }
  return out;
}
