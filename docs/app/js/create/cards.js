// Character Card import and export (the V1/V2/V3 format many character sites and apps share).
// Reads card JSON and PNG text chunks ("chara" for V2, "ccv3" for V3). Pure functions, no DOM, no network.

/** An error whose message is safe and friendly to show to the user. */
export class CardError extends Error {}

const PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
const LIMITS = { name: 40, species: 40, tagline: 90, bio: 600, greeting: 1200, personality: 2000, speakingStyle: 600, scenario: 600, exampleDialogue: 2000, tags: 12 };

const latin1 = (bytes) => Array.from(bytes, (b) => String.fromCharCode(b)).join('');
const utf8 = (bytes) => new TextDecoder('utf-8').decode(bytes);

async function inflate(bytes) {
  if (typeof DecompressionStream !== 'function') throw new CardError("This browser can't open compressed cards.");
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** Text chunks of a PNG (tEXt, zTXt and iTXt) as { keyword: text }, keywords lowercased. */
export async function pngTextChunks(buffer) {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  if (bytes.length < 8 || PNG_SIGNATURE.some((b, i) => bytes[i] !== b)) throw new CardError("That picture isn't a PNG file.");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = {};
  let pos = 8;
  while (pos + 12 <= bytes.length) {
    const length = view.getUint32(pos);
    const type = latin1(bytes.subarray(pos + 4, pos + 8));
    const start = pos + 8;
    const end = start + length;
    if (end + 4 > bytes.length) break; // truncated file: keep what we have
    const data = bytes.subarray(start, end);
    const zero = data.indexOf(0);
    if (zero > 0 && (type === 'tEXt' || type === 'zTXt' || type === 'iTXt')) {
      const key = latin1(data.subarray(0, zero)).toLowerCase();
      try {
        if (type === 'tEXt') {
          out[key] = latin1(data.subarray(zero + 1));
        } else if (type === 'zTXt') {
          out[key] = latin1(await inflate(data.subarray(zero + 2)));
        } else {
          const compressed = data[zero + 1] === 1;
          const langEnd = data.indexOf(0, zero + 3);
          const transEnd = langEnd < 0 ? -1 : data.indexOf(0, langEnd + 1);
          if (transEnd >= 0) {
            const text = data.subarray(transEnd + 1);
            out[key] = utf8(compressed ? await inflate(text) : text);
          }
        }
      } catch (err) {
        if (err instanceof CardError) throw err;
        // A damaged chunk: skip it and keep reading.
      }
    }
    if (type === 'IEND') break;
    pos = end + 4; // skip the CRC
  }
  return out;
}

/** The JSON inside a card chunk: base64 of UTF-8 JSON (a few tools store plain JSON). */
export function decodeCardText(text) {
  const t = String(text || '').trim();
  try {
    if (t.startsWith('{')) return JSON.parse(t);
    const bin = atob(t.replace(/\s+/g, ''));
    return JSON.parse(utf8(Uint8Array.from(bin, (ch) => ch.charCodeAt(0))));
  } catch {
    throw new CardError('The card inside that picture is damaged.');
  }
}

/** The card JSON from a PNG's chunks (V3 "ccv3" wins over V2 "chara"). */
export async function cardFromPNG(buffer) {
  const chunks = await pngTextChunks(buffer);
  const raw = chunks.ccv3 || chunks.chara;
  if (!raw) throw new CardError("That picture doesn't have a character card inside.");
  return decodeCardText(raw);
}

const str = (v) => (typeof v === 'string' ? v : v == null ? '' : String(v));
const tidy = (s) => str(s).replace(/\r\n?/g, '\n').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();

/** Cuts text to `max` characters, at a sentence or word end when possible. */
export function shorten(text, max) {
  const t = tidy(text);
  if (t.length <= max) return t;
  const cut = t.slice(0, max);
  const sentence = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('! '), cut.lastIndexOf('? '), cut.lastIndexOf('\n'));
  if (sentence > max * 0.6) return cut.slice(0, sentence + 1).trim();
  const space = cut.lastIndexOf(' ');
  return `${(space > max * 0.6 ? cut.slice(0, space) : cut).trim()}...`;
}

/** First sentence, for a tagline. */
function firstSentence(text, max) {
  const t = tidy(text).split('\n')[0] || '';
  const m = t.match(/^.{8,}?[.!?](?=\s|$)/);
  return shorten(m ? m[0] : t, max);
}

/** Tavern macros: {{char}} / <BOT> become the name; {{user}} / <USER> stay {{user}} (filled in at chat time). */
function macros(text, name) {
  return str(text)
    .replace(/\{\{\s*char\s*\}\}|<\s*bot\s*>/gi, name)
    .replace(/<\s*user\s*>/gi, '{{user}}');
}

const ok = (v) => (Array.isArray(v) ? v : []);

/**
 * Maps a Character Card (V1 flat, V2 or V3) to a Hearth draft character.
 * Returns { draft, shortened } where `shortened` lists fields cut down to fit a small model.
 */
export function cardToDraft(card) {
  if (!card || typeof card !== 'object' || Array.isArray(card)) throw new CardError("That file doesn't look like a character card.");
  const d = card.data && typeof card.data === 'object' ? card.data : card;
  const name = shorten(str(d.name).replace(/\s+/g, ' '), LIMITS.name);
  if (!name) throw new CardError("This card doesn't have a name in it.");
  const hearth = d.extensions?.hearth && typeof d.extensions.hearth === 'object' ? d.extensions.hearth : null;
  const shortened = [];
  const fit = (field, text) => {
    const full = tidy(text);
    const cut = shorten(full, LIMITS[field]);
    if (cut.length < full.length) shortened.push(field);
    return cut;
  };

  const description = macros(d.description, name);
  const personalityField = macros(d.personality, name);
  // Our own exports carry Hearth's fields; other cards keep the definition in description (+ personality).
  const personality = hearth
    ? fit('personality', personalityField)
    : fit('personality', [description, personalityField].filter((s) => tidy(s)).join('\n\n'));
  const bio = fit('bio', str(description).replace(/\{\{\s*user\s*\}\}/gi, 'you'));
  const example = macros(d.mes_example, name)
    .split('\n').filter((line) => !/^\s*<\s*start\s*>\s*$/i.test(line)).join('\n');
  const tags = ok(d.tags).map((t) => str(t).trim()).filter(Boolean).slice(0, LIMITS.tags);
  const greetings = ok(d.alternate_greetings).map((g) => tidy(macros(g, name))).filter(Boolean).slice(0, 5);
  const creator = str(d.creator).trim().replace(/^@+/, '').replace(/\s+/g, '').slice(0, 30);

  const draft = {
    name,
    species: shorten(hearth?.species || '', LIMITS.species),
    tagline: shorten(hearth?.tagline || firstSentence(d.creator_notes || description, LIMITS.tagline), LIMITS.tagline),
    bio,
    greeting: fit('greeting', macros(d.first_mes, name)),
    altGreetings: greetings.map((g) => shorten(g, LIMITS.greeting)),
    personality,
    speakingStyle: fit('speakingStyle', hearth?.speakingStyle || ''),
    scenario: fit('scenario', macros(d.scenario, name)),
    exampleDialogue: fit('exampleDialogue', example),
    categories: ok(hearth?.categories).map(str),
    tags,
    creator: creator ? `@${creator}` : '@you',
    homeLocationID: hearth?.homeLocationID ? str(hearth.homeLocationID) : null,
    accentHex: /^#[0-9a-f]{6}$/i.test(str(hearth?.accentHex)) ? hearth.accentHex : null,
    voice: hearth?.voice && typeof hearth.voice === 'object' ? { ...hearth.voice } : null,
    avatar: {
      emoji: hearth?.avatar?.emoji ? str(hearth.avatar.emoji).slice(0, 16) : null,
      colors: ok(hearth?.avatar?.colors).filter((c) => /^#[0-9a-f]{6}$/i.test(str(c))).slice(0, 2),
      dataURL: imageDataURL(hearth?.avatar?.dataURL) || iconAsset(d.assets),
    },
  };
  return { draft, shortened };
}

/** Only small inline images are kept (never a link that would load from the network). */
function imageDataURL(v) {
  const s = str(v);
  return /^data:image\/(?:png|jpe?g|webp|gif);base64,[a-z0-9+/=\s]+$/i.test(s) && s.length < 4_000_000 ? s : null;
}

/** V3 cards may embed their main icon as a data: URI. */
function iconAsset(assets) {
  const icon = ok(assets).find((a) => a && a.type === 'icon' && imageDataURL(a.uri));
  return icon ? imageDataURL(icon.uri) : null;
}

/** A Hearth character as a Character Card V2 (Hearth's own fields ride along in extensions.hearth). */
export function characterToCard(c) {
  const example = tidy(c.exampleDialogue);
  const creator = str(c.creator).replace(/^@+/, '');
  return {
    spec: 'chara_card_v2',
    spec_version: '2.0',
    data: {
      name: str(c.name),
      description: str(c.bio),
      personality: str(c.personality),
      scenario: str(c.scenario),
      first_mes: str(c.greeting),
      mes_example: example ? `<START>\n${example}` : '',
      creator_notes: str(c.tagline),
      system_prompt: '',
      post_history_instructions: '',
      alternate_greetings: ok(c.altGreetings).map(str),
      tags: ok(c.tags).map(str),
      creator: creator === 'you' ? '' : creator,
      character_version: '1.0',
      extensions: {
        hearth: {
          version: 1,
          species: str(c.species),
          tagline: str(c.tagline),
          speakingStyle: str(c.speakingStyle),
          categories: ok(c.categories).map(str),
          accentHex: str(c.accentHex),
          voice: c.voice || null,
          homeLocationID: c.homeLocationID || null,
          avatar: { emoji: c.avatar?.emoji || null, colors: ok(c.avatar?.colors), dataURL: imageDataURL(c.avatar?.dataURL) },
        },
      },
    },
  };
}

/** "Juno the Otter!" -> "juno-the-otter" (for file names). */
export function slug(name) {
  return str(name).toLowerCase().normalize('NFKD').replace(/[^\w\s-]/g, '').trim().replace(/[\s_]+/g, '-').slice(0, 40) || 'character';
}
