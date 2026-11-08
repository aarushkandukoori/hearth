// Voice notes and "play aloud" with the browser's speech synthesis, using ONLY voices that run on
// this device (voice.localService). Remote voices would send the text to a server, so they are skipped.

import { hash, seeded, clamp } from '../util.js';

const NOVELTY = ['Albert', 'Bad News', 'Bahh', 'Bells', 'Boing', 'Bubbles', 'Cellos', 'Good News', 'Jester', 'Organ',
  'Superstar', 'Trinoids', 'Whisper', 'Wobble', 'Zarvox', 'Eddy', 'Flo', 'Grandma', 'Grandpa', 'Reed', 'Rocko',
  'Sandy', 'Shelley', 'Fred', 'Junior', 'Ralph', 'Kathy', 'Deranged', 'Hysterical', 'Princess'];
const FEMALE = ['samantha', 'victoria', 'karen', 'moira', 'tessa', 'fiona', 'veena', 'allison', 'ava', 'susan', 'zoe',
  'kate', 'serena', 'nicky', 'joelle', 'zira', 'hazel', 'catherine', 'female', 'amelie', 'anna', 'alice', 'ellen', 'sara', 'joana', 'paulina', 'monica', 'melina', 'yuna', 'ting-ting', 'mei-jia', 'kyoko', 'lekha'];
const MALE = ['daniel', 'alex', 'tom', 'oliver', 'aaron', 'arthur', 'rishi', 'gordon', 'lee', 'evan', 'nathan', 'david',
  'mark', 'george', 'james', 'male', 'thomas', 'jorge', 'diego', 'juan', 'luca', 'xander', 'maged', 'yuri'];

let voiceList = [];
let loading = null;

const synth = () => (typeof window !== 'undefined' && 'speechSynthesis' in window ? window.speechSynthesis : null);

/** Resolves with the device's voices (they arrive asynchronously in some browsers). */
export function loadVoices() {
  const s = synth();
  if (!s) return Promise.resolve([]);
  if (loading) return loading;
  loading = new Promise((resolve) => {
    const take = () => { voiceList = s.getVoices() || []; return voiceList; };
    if (take().length) { resolve(voiceList); return; }
    const done = () => { s.removeEventListener?.('voiceschanged', done); resolve(take()); };
    s.addEventListener?.('voiceschanged', done);
    setTimeout(done, 1500);
  });
  return loading;
}

function isNovelty(v) {
  return NOVELTY.some((n) => v.name === n || v.name.startsWith(`${n} `));
}

function genderOf(v) {
  const n = v.name.toLowerCase();
  if (FEMALE.some((x) => n.includes(x))) return 'female';
  if (MALE.some((x) => n.includes(x))) return 'male';
  return 'neutral';
}

const quality = (v) => (/premium/i.test(v.name) ? 2 : /enhanced/i.test(v.name) ? 1 : 0);

/** Local, non-novelty voices; the user's language first, better quality first. */
export function localVoices() {
  const lang = (typeof navigator !== 'undefined' && navigator.language ? navigator.language : 'en-US').slice(0, 2).toLowerCase();
  return voiceList
    .filter((v) => v.localService && !isNovelty(v))
    .sort((a, b) => {
      const la = a.lang?.toLowerCase().startsWith(lang) ? 0 : 1;
      const lb = b.lang?.toLowerCase().startsWith(lang) ? 0 : 1;
      return la - lb || quality(b) - quality(a) || a.name.localeCompare(b.name);
    });
}

export function hasLocalVoice() { return localVoices().length > 0; }

/** The voice a character speaks with: the user's override if set, else a stable pick by character id. */
export function voiceFor(character, { voiceURI = '' } = {}) {
  const all = localVoices();
  if (!all.length) return null;
  if (voiceURI) {
    const chosen = all.find((v) => v.voiceURI === voiceURI);
    if (chosen) return chosen;
  }
  const wantLocale = (character?.voice?.locale || '').toLowerCase();
  const lang = wantLocale ? wantLocale.slice(0, 2) : (all[0].lang || 'en').slice(0, 2).toLowerCase();
  let pool = all.filter((v) => v.lang?.toLowerCase().startsWith(lang));
  if (!pool.length) pool = all;
  const preferred = (character?.voice?.preferredVoiceNames || []).map((n) => n.toLowerCase());
  const named = pool.find((v) => preferred.some((p) => v.name.toLowerCase().includes(p)));
  if (named) return named;
  const gender = character?.voice?.gender;
  if (gender === 'female' || gender === 'male') {
    const g = pool.filter((v) => genderOf(v) === gender);
    if (g.length) pool = g;
  }
  return pool[hash(character?.id || character?.name || '') % pool.length];
}

/** What gets spoken: no *actions*, no [photo] lines, no emoji. */
export function spokenText(text) {
  return String(text || '')
    .replace(/\[[^\]]*\]/g, ' ')
    .replace(/\*[^*\n]+\*/g, ' ')
    .replace(/[\p{Extended_Pictographic}\u{FE0F}]/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
}

const rateFor = (character) => clamp((character?.voice?.rate ?? 0.5) * 2, 0.6, 1.6);
const pitchFor = (character) => clamp(character?.voice?.pitch ?? 1, 0.5, 2);

/** Rough length of a voice note in seconds (about 2.6 words per second at a normal rate). */
export function estimateDuration(text, character) {
  const words = spokenText(text).split(' ').filter(Boolean).length;
  return Math.max(1.5, words / (2.6 * rateFor(character)));
}

/** 32 bar heights (0.18..1) that look like speech, stable for the same text. */
export function waveformFor(text, bars = 32) {
  const rand = seeded(hash(text || 'hearth'));
  const out = [];
  for (let i = 0; i < bars; i++) {
    const envelope = Math.sin((Math.PI * (i + 0.5)) / bars) * 0.55 + 0.45;
    out.push(Number(clamp(envelope * (0.35 + rand() * 0.75), 0.18, 1).toFixed(3)));
  }
  return out;
}

let active = null; // { utterance, stop }

export function stopSpeaking() {
  const s = synth();
  if (active) { const a = active; active = null; a.finish('stopped'); }
  s?.cancel();
}

export function isSpeaking() { return !!active; }

/**
 * Speaks text in the character's voice. Returns { stop, done } where done resolves with
 * 'ended' | 'stopped' | 'unavailable'. onProgress(0..1) is called while speaking.
 */
export function speak(text, character, { voiceURI = '', onStart, onProgress, onEnd } = {}) {
  const s = synth();
  const say = spokenText(text);
  const voice = voiceFor(character, { voiceURI });
  if (!s || !voice || !say) {
    onEnd?.('unavailable');
    return { stop() {}, done: Promise.resolve('unavailable') };
  }
  stopSpeaking();
  const u = new SpeechSynthesisUtterance(say);
  u.voice = voice;
  u.lang = voice.lang;
  u.rate = rateFor(character);
  u.pitch = pitchFor(character);
  const expected = estimateDuration(text, character) * 1000;
  let started = 0;
  let timer = null;
  let finished = false;
  let resolveDone;
  const done = new Promise((r) => { resolveDone = r; });
  const finish = (why) => {
    if (finished) return;
    finished = true;
    clearInterval(timer);
    if (active?.utterance === u) active = null;
    onProgress?.(why === 'ended' ? 1 : 0);
    onEnd?.(why);
    resolveDone(why);
  };
  u.onstart = () => {
    started = performance.now();
    onStart?.();
    timer = setInterval(() => onProgress?.(Math.min(0.97, (performance.now() - started) / expected)), 80);
  };
  u.onboundary = (e) => { if (typeof e.charIndex === 'number' && say.length) onProgress?.(Math.min(0.99, e.charIndex / say.length)); };
  u.onend = () => finish('ended');
  u.onerror = () => finish('stopped');
  active = { utterance: u, finish };
  s.speak(u);
  return { stop: () => { if (active?.utterance === u) stopSpeaking(); }, done };
}
