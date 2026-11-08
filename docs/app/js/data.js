// App data in memory: the Lantern Bay world (docs/world/lantern-bay.json), the user's own characters
// and settings (IndexedDB), plus a tiny event hub so views refresh when something changes.

import * as store from './store.js';
import { createEmitter, siteURL } from './util.js';
import { dayPart, locationOf } from './brain/director.js';

const hub = createEmitter();
let worldDef = null;
let userCharacters = [];
let currentSettings = null;

export const DEFAULT_SETTINGS = {
  id: 'app',
  persona: { name: '', about: '' },
  onboardingDone: false,
  confirmedAdult: false,
  modelId: 'Llama-3.2-1B-Instruct-q4f16_1-MLC',
  modelOptIn: false,       // the user chose to download the real model; load it on later visits
  voiceNotesEnabled: true,
  picturesEnabled: true,   // characters may send pictures (bundled art or postcards)
  voiceURI: '',            // '' = automatic (a different local voice per character)
  townGossip: false,       // off until the person turns it on in Settings
  showStats: false,
  lastAwayEventsAt: null,
};

/** Fills defaults for fields a world file might leave out (mirrors Models.swift defaults). */
function normalizeCharacter(c, builtIn) {
  return {
    altGreetings: [],
    categories: [],
    tags: [],
    schedule: [],
    relationships: [],
    creator: builtIn ? '@lanternbay' : '@you',
    ...c,
    avatar: { ...(c.avatar || {}) },
    voice: { pitch: 1, rate: 0.5, ...(c.voice || {}) },
    media: { voiceNoteChance: 0.1, photoChance: 0.08, photoIdeas: [], ...(c.media || {}) },
    isBuiltIn: builtIn,
  };
}

function normalizeWorld(w) {
  return {
    id: w.id || 'lantern-bay',
    name: w.name || 'Lantern Bay',
    tagline: w.tagline || '',
    lore: w.lore || '',
    categories: Array.isArray(w.categories) ? w.categories : [],
    locations: Array.isArray(w.locations) ? w.locations : [],
    characters: (Array.isArray(w.characters) ? w.characters : []).map((c) => normalizeCharacter(c, true)),
    starterEvents: Array.isArray(w.starterEvents) ? w.starterEvents : [],
  };
}

/** Loads the world file. Throws a friendly Error if it can't be read. */
export async function loadWorld() {
  let res;
  try {
    res = await fetch(siteURL('world/lantern-bay.json'), { cache: 'no-cache' });
  } catch {
    throw new Error("Couldn't reach Lantern Bay. Check that the site files are all here.");
  }
  if (!res.ok) throw new Error("Couldn't load Lantern Bay (world/lantern-bay.json).");
  try {
    worldDef = normalizeWorld(await res.json());
  } catch {
    throw new Error('The Lantern Bay file is damaged.');
  }
  hub.emit('world', worldDef);
  return worldDef;
}

export function world() { return worldDef; }

/** Built-in residents first, then characters the user made (newest first). */
export function allCharacters() {
  return [...(worldDef?.characters || []), ...userCharacters];
}

export function builtInCharacters() { return worldDef?.characters || []; }
export function userMadeCharacters() { return userCharacters.slice(); }

export function getCharacter(id) {
  return allCharacters().find((c) => c.id === id) || null;
}

export function getLocation(id) {
  return worldDef?.locations?.find((l) => l.id === id) || null;
}

/** Where a character is right now: { locationID, activity, location } or null. */
export function whereNow(character, date = new Date()) {
  return locationOf(character, dayPart(date), worldDef);
}

/** Re-reads user-made characters from IndexedDB (call after creating/editing one). */
export async function reloadUserCharacters() {
  const rows = await store.getAll('characters');
  userCharacters = rows
    .map((c) => normalizeCharacter(c, false))
    .sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
  hub.emit('characters', allCharacters());
  return userCharacters;
}

/** Saves a user-made character and refreshes everything that lists characters. */
export async function saveUserCharacter(character) {
  const c = { createdAt: Date.now(), ...character, isBuiltIn: false };
  await store.put('characters', c);
  await reloadUserCharacters();
  return getCharacter(c.id);
}

export async function deleteUserCharacter(id) {
  await store.del('characters', id);
  await reloadUserCharacters();
}

export async function loadSettings() {
  const saved = await store.get('settings', 'app');
  currentSettings = {
    ...DEFAULT_SETTINGS,
    ...(saved || {}),
    persona: { ...DEFAULT_SETTINGS.persona, ...(saved?.persona || {}) },
  };
  return currentSettings;
}

export function settings() { return currentSettings || { ...DEFAULT_SETTINGS }; }

/** The name characters use for the user. */
export function userName() { return settings().persona?.name?.trim() || 'Friend'; }

/** Shallow-merges a patch (persona is merged one level deeper) and saves. */
export async function updateSettings(patch) {
  const base = settings();
  const next = { ...base, ...patch, id: 'app' };
  if (patch.persona) next.persona = { ...base.persona, ...patch.persona };
  currentSettings = next;
  await store.put('settings', next);
  hub.emit('settings', next);
  return next;
}

/** Topics: 'world', 'characters', 'settings', 'conversations', 'memories', 'events'. */
export function subscribe(topic, fn) { return hub.on(topic, fn); }
export function emit(topic, payload) { hub.emit(topic, payload); }
