// IndexedDB storage for everything the user makes: database "hearth" with one object store per kind.
// Falls back to an in-memory store (with `store.persistent === false`) when IndexedDB is blocked.

const DB_NAME = 'hearth';
const DB_VERSION = 1;
export const STORES = ['characters', 'conversations', 'memories', 'events', 'settings'];

let dbPromise = null;
let memory = null; // Map<store, Map<id, value>> when IndexedDB is unavailable

/** True when data survives a reload (IndexedDB works). */
export let persistent = true;

function openDB() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve) => {
    let req;
    try {
      req = indexedDB.open(DB_NAME, DB_VERSION);
    } catch {
      resolve(null);
      return;
    }
    req.onupgradeneeded = () => {
      const db = req.result;
      for (const name of STORES) {
        if (!db.objectStoreNames.contains(name)) db.createObjectStore(name, { keyPath: 'id' });
      }
    };
    req.onsuccess = () => {
      const db = req.result;
      db.onversionchange = () => db.close();
      resolve(db);
    };
    req.onerror = () => resolve(null);
    req.onblocked = () => resolve(null);
  }).then((db) => {
    if (!db) {
      persistent = false;
      memory = new Map(STORES.map((s) => [s, new Map()]));
    }
    return db;
  });
  return dbPromise;
}

function checkStore(store) {
  if (!STORES.includes(store)) throw new Error(`Unknown store "${store}"`);
}

/** Runs one request in a transaction and resolves with its result. */
async function run(store, mode, makeRequest) {
  const db = await openDB();
  if (!db) return null;
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, mode);
    const req = makeRequest(tx.objectStore(store));
    let result;
    req.onsuccess = () => { result = req.result; };
    tx.oncomplete = () => resolve(result);
    tx.onerror = () => reject(tx.error || req.error);
    tx.onabort = () => reject(tx.error || new Error('Transaction aborted'));
  });
}

/** Deep copy so callers never share objects with the in-memory fallback. */
const clone = (v) => (v == null ? v : structuredClone(v));

export async function getAll(store) {
  checkStore(store);
  const db = await openDB();
  if (!db) return [...memory.get(store).values()].map(clone);
  return (await run(store, 'readonly', (s) => s.getAll())) || [];
}

export async function get(store, id) {
  checkStore(store);
  const db = await openDB();
  if (!db) return clone(memory.get(store).get(id));
  return (await run(store, 'readonly', (s) => s.get(id))) ?? undefined;
}

/** Inserts or replaces `value` (must have an `id`). Resolves with the value. */
export async function put(store, value) {
  checkStore(store);
  if (!value || value.id == null) throw new Error('put() needs a value with an id');
  const db = await openDB();
  if (!db) { memory.get(store).set(value.id, clone(value)); return value; }
  await run(store, 'readwrite', (s) => s.put(value));
  return value;
}

export async function del(store, id) {
  checkStore(store);
  const db = await openDB();
  if (!db) { memory.get(store).delete(id); return; }
  await run(store, 'readwrite', (s) => s.delete(id));
}

/** Empties every store. */
export async function clearAll() {
  const db = await openDB();
  if (!db) { for (const m of memory.values()) m.clear(); return; }
  await new Promise((resolve, reject) => {
    const tx = db.transaction(STORES, 'readwrite');
    for (const name of STORES) tx.objectStore(name).clear();
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

/** Everything as one plain object, ready for JSON.stringify. */
export async function exportAll() {
  const data = {};
  for (const name of STORES) data[name] = await getAll(name);
  return {
    app: 'hearth',
    kind: 'web-backup',
    version: 1,
    exportedAt: new Date().toISOString(),
    data,
  };
}

const isObject = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const CHARACTER_LISTS = ['altGreetings', 'categories', 'tags', 'schedule', 'relationships'];
const CHARACTER_OBJECTS = ['avatar', 'voice', 'media'];

/** One stored message, repaired where it can be (or null when it can't be shown). */
function cleanMessage(m) {
  if (!isObject(m) || typeof m.id !== 'string' || !['user', 'character', 'narrator'].includes(m.role)) return null;
  const variants = Array.isArray(m.variants) ? m.variants.filter((v) => typeof v === 'string') : [];
  if (!variants.length) return null;
  const extras = variants.map((_, i) => (isObject(m.extras?.[i]) ? m.extras[i] : {}));
  const selected = Number.isInteger(m.selected) && m.selected >= 0 && m.selected < variants.length ? m.selected : 0;
  return { ...m, variants, extras, selected };
}

/**
 * Checks one backup row before it is saved, so a damaged file can't break the pages that list it.
 * Returns the row (lightly repaired) or null to skip it.
 */
function cleanRow(name, row) {
  if (!isObject(row) || typeof row.id !== 'string' || !row.id) return null;
  if (name === 'conversations') {
    if (!['direct', 'scene'].includes(row.kind) || !Array.isArray(row.messages)) return null;
    return {
      ...row,
      messages: row.messages.map(cleanMessage).filter(Boolean),
      participantIDs: Array.isArray(row.participantIDs) ? row.participantIDs : [],
      ...(row.kind === 'scene' ? { guests: Array.isArray(row.guests) ? row.guests.filter(isObject) : [] } : {}),
    };
  }
  if (name === 'characters') {
    if (typeof row.name !== 'string' || !row.name.trim()) return null;
    const out = { ...row };
    for (const k of CHARACTER_LISTS) if (k in out && !Array.isArray(out[k])) delete out[k];
    for (const k of CHARACTER_OBJECTS) if (k in out && !isObject(out[k])) delete out[k];
    if (out.media && 'photoIdeas' in out.media && !Array.isArray(out.media.photoIdeas)) out.media = { ...out.media, photoIdeas: [] };
    return out;
  }
  if (name === 'memories' || name === 'events') return typeof row.text === 'string' ? row : null;
  if (name === 'settings') {
    if (row.id !== 'app') return null;
    return 'persona' in row && !isObject(row.persona) ? { ...row, persona: {} } : row;
  }
  return row;
}

/**
 * Adds everything from an exportAll() object (or its JSON text). Records with the same id are replaced.
 * Resolves with counts per store (plus `skipped`: damaged rows left out). Throws a friendly Error when
 * the file isn't a Hearth backup.
 */
export async function importAll(json) {
  let obj = json;
  if (typeof json === 'string') {
    try { obj = JSON.parse(json); } catch { throw new Error("That file isn't valid JSON."); }
  }
  if (!obj || obj.app !== 'hearth' || typeof obj.data !== 'object' || obj.data === null) {
    throw new Error("That file doesn't look like a Hearth backup.");
  }
  const counts = { skipped: 0 };
  for (const name of STORES) {
    const rows = Array.isArray(obj.data[name]) ? obj.data[name] : [];
    let n = 0;
    for (const row of rows) {
      const clean = cleanRow(name, row);
      if (clean) { await put(name, clean); n++; } else counts.skipped++;
    }
    counts[name] = n;
  }
  return counts;
}

/**
 * Asks the browser to keep Hearth's data instead of clearing it on its own (Safari otherwise may, after
 * 7 days without a visit). Resolves true when the data is protected. Firefox shows the person a prompt,
 * so this asks only once per browser (loading the model asks again).
 */
export async function requestPersistence() {
  const KEY = 'hearth.persistAsked';
  try {
    if (!navigator.storage?.persist) return false;
    if (await navigator.storage.persisted()) return true;
    if (localStorage.getItem(KEY)) return false;
    localStorage.setItem(KEY, '1');
    return await navigator.storage.persist();
  } catch {
    return false;
  }
}

/** True when the browser has promised to keep this site's data. */
export async function isPersisted() {
  try { return !!(await navigator.storage?.persisted?.()); } catch { return false; }
}

/** Opens the database early (optional). Resolves with true when storage is persistent. */
export async function ready() {
  await openDB();
  return persistent;
}
