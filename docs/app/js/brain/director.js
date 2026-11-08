// World director (no model involved): time of day, who is where, and who speaks next in group scenes.
// Same rules as SPEC §7 so the website and the iPhone app behave alike.

import { escapeRegExp } from '../util.js';

export const DAY_PARTS = ['morning', 'afternoon', 'evening', 'night'];

/** 5-11 morning, 11-17 afternoon, 17-22 evening, else night (local time). */
export function dayPart(date = new Date()) {
  const h = date.getHours();
  if (h >= 5 && h < 11) return 'morning';
  if (h >= 11 && h < 17) return 'afternoon';
  if (h >= 17 && h < 22) return 'evening';
  return 'night';
}

/**
 * Where a character is during a part of the day: { locationID, activity, location }.
 * Falls back to their home ("spending time here"). Returns null when they have neither.
 */
export function locationOf(character, part = dayPart(), world = null) {
  if (!character) return null;
  const slot = (character.schedule || []).find((s) => s.part === part)
    || (character.homeLocationID ? { part, locationID: character.homeLocationID, activity: 'spending time here' } : null);
  if (!slot) return null;
  const location = world?.locations?.find((l) => l.id === slot.locationID) || null;
  return { locationID: slot.locationID, activity: slot.activity || 'spending time here', location };
}

/** Characters at a location during a part of the day. */
export function whoIsAt(locationID, part = dayPart(), characters = []) {
  return characters.filter((c) => locationOf(c, part)?.locationID === locationID);
}

/** Characters whose name appears in `text`, in order of first appearance. */
export function namedIn(text, present = []) {
  const found = [];
  for (const c of present) {
    if (!c?.name) continue;
    const re = new RegExp(`(^|[^\\p{L}])${escapeRegExp(c.name)}(?![\\p{L}])`, 'iu');
    const m = re.exec(text || '');
    if (m) found.push({ c, at: m.index });
  }
  return found.sort((a, b) => a.at - b.at).map((f) => f.c);
}

/** Index of the last message spoken by `id` (-1 when they haven't spoken). */
function lastSpoke(id, messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]?.speakerID === id) return i;
  }
  return -1;
}

/** Ids sorted so the one who spoke longest ago (or never) comes first. Ties keep their order. */
export function leastRecent(ids, messages = []) {
  return ids
    .map((id, order) => ({ id, order, at: lastSpoke(id, messages) }))
    .sort((a, b) => a.at - b.at || a.order - b.order)
    .map((x) => x.id);
}

/**
 * Who answers a user line in a scene (max 2 ids):
 * a character named in the text first; otherwise the one the user last addressed;
 * otherwise whoever spoke least recently. Then, with 50% chance, one more different character reacts
 * (always when the user named two of them).
 */
export function nextSpeakers({ text = '', present = [], messages = [], lastAddressedID = null, random = Math.random } = {}) {
  const ids = present.map((c) => c.id);
  if (ids.length === 0) return [];
  const named = namedIn(text, present).map((c) => c.id);
  let first;
  if (named.length) first = named[0];
  else if (lastAddressedID && ids.includes(lastAddressedID)) first = lastAddressedID;
  else first = leastRecent(ids, messages)[0];
  const out = [first];
  if (ids.length > 1) {
    const secondNamed = named.find((id) => id !== first);
    if (secondNamed) out.push(secondNamed);
    else if (random() < 0.5) out.push(leastRecent(ids.filter((id) => id !== first), messages)[0]);
  }
  return out;
}

/** "Let them talk": `count` lines between present characters, never the same speaker twice in a row. */
export function banterOrder({ present = [], messages = [], count = 4, random = Math.random } = {}) {
  const ids = present.map((c) => c.id);
  if (ids.length === 0) return [];
  if (ids.length === 1) return [ids[0]];
  const history = messages.slice();
  let last = [...history].reverse().find((m) => m?.speakerID)?.speakerID || null;
  const order = [];
  for (let i = 0; i < count; i++) {
    const candidates = leastRecent(ids.filter((id) => id !== last), history);
    const next = candidates.length > 1 && random() < 0.3 ? candidates[1] : candidates[0];
    order.push(next);
    history.push({ speakerID: next });
    last = next;
  }
  return order;
}
