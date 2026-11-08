// Town news ("While you were away"): a new batch of up to 3 small happenings every 6 hours.
// The model on this device writes them when it is loaded; otherwise they come from the world's starter events.

import { getAll, put, del } from '../store.js';
import { world, builtInCharacters, userMadeCharacters, settings, updateSettings, emit } from '../data.js';
import { engine } from '../engine/engine.js';
import { composeAwayEvents } from '../brain/prompts.js';
import { parseEvents } from '../brain/parse.js';
import { uid, seeded, shuffled } from '../util.js';

export const BATCH_EVERY_MS = 6 * 60 * 60 * 1000;
const BATCH_SIZE = 3;
const KEEP = 30;            // older events are dropped

let running = null;         // the batch being made right now (one at a time)

/** Who can show up in the news: the built-in cast plus your characters who live in town. */
export function newsCast() {
  return [...builtInCharacters(), ...userMadeCharacters().filter((c) => c.homeLocationID)];
}

/** Every stored event, newest first. */
export async function allEvents() {
  const rows = await getAll('events');
  return rows.sort((a, b) => (b.date || 0) - (a.date || 0));
}

export async function unseenCount() {
  return (await getAll('events')).filter((e) => !e.seen).length;
}

/** Texts for prompts: the 3 newest events, or the first starter events before there are any. */
export async function recentEventTexts() {
  try {
    const rows = (await allEvents()).slice(0, 3);
    if (rows.length) return rows.map((e) => e.text);
  } catch { /* no events yet */ }
  return (world()?.starterEvents || []).slice(0, 2);
}

/** True when the last batch is 6 or more hours old (or there never was one). */
export function isDue(now = Date.now()) {
  const last = Number(settings().lastAwayEventsAt) || 0;
  return !last || last > now || now - last >= BATCH_EVERY_MS;
}

async function fromModel(cast) {
  const turns = composeAwayEvents({ world: world(), characters: cast, n: BATCH_SIZE });
  const { text } = await engine.generate({
    key: 'town-news', turns, maxTokens: 220,
    sampling: { temperature: 0.9, topP: 0.95, repeatPenalty: 1.1, seed: Math.floor(Math.random() * 2 ** 31) },
  });
  return parseEvents(text, world(), { max: BATCH_SIZE, characters: cast })
    .filter((e) => e.text.split(/\s+/).length >= 4);
}

/** Three starter events, the ones used longest ago first, so the notebook cycles. */
function fromStarters(cast, existing) {
  const all = world()?.starterEvents || [];
  if (!all.length) return [];
  const lastUsed = new Map();
  for (const e of existing) if (!lastUsed.has(e.text)) lastUsed.set(e.text, e.date || 0);
  const order = shuffled(all, seeded(Date.now())).sort((a, b) => (lastUsed.get(a) || 0) - (lastUsed.get(b) || 0));
  const lines = order.slice(0, BATCH_SIZE).map((t) => `- ${t}`).join('\n');
  return parseEvents(lines, world(), { max: BATCH_SIZE, characters: cast });
}

/**
 * Makes a new batch when one is due and the engine has settled (demo, ready or error).
 * Resolves with the new event rows ([] when nothing was made).
 */
export function refreshNews({ force = false } = {}) {
  if (running) return running;
  if (!world() || (!force && !isDue())) return Promise.resolve([]);
  const status = engine.status;
  if (status === 'idle' || status === 'loading') return Promise.resolve([]);
  running = (async () => {
    const cast = newsCast();
    const existing = await allEvents();
    let fresh = [];
    let source = 'notebook';
    if (status === 'ready') {
      try {
        fresh = await fromModel(cast);
        source = 'model';
      } catch {
        fresh = [];
      }
    }
    if (!fresh.length) {
      fresh = fromStarters(cast, existing);
      source = 'notebook';
    }
    const now = Date.now();
    const rows = fresh.map((e, i) => ({
      id: uid(), date: now - i * 1000, text: e.text, characterIDs: e.characterIDs, locationID: e.locationID, seen: false, source,
    }));
    for (const row of rows) await put('events', row);
    for (const old of [...rows, ...existing].slice(KEEP)) await del('events', old.id);
    await updateSettings({ lastAwayEventsAt: now });
    emit('events', rows);
    return rows;
  })().finally(() => { running = null; });
  return running;
}

/** True while a batch is being written. */
export function isRefreshing() { return running !== null; }

/** Marks every event as seen. Resolves with how many changed. */
export async function markAllSeen() {
  const rows = (await getAll('events')).filter((e) => !e.seen);
  for (const row of rows) await put('events', { ...row, seen: true });
  if (rows.length) emit('events', null);
  return rows.length;
}
