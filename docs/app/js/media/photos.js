// Photos: the user's pictures are shrunk in the browser (which also drops location and camera data)
// and kept only in IndexedDB. When the model is loaded, it describes each one in a sentence or two (a
// smaller copy goes through its vision tower, in this tab), and characters read that description.
// Pictures from characters use the best-matching bundled art or a postcard.

import { artURL, isMissingArt } from '../ui/components.js';

/** Reads an image File, downscales it and returns { dataURL, width, height } as JPEG. */
export async function downscaleImage(file, { maxSide = 1280, quality = 0.84 } = {}) {
  if (!file || !/^image\//.test(file.type || 'image/')) throw new Error("That file isn't a picture.");
  let source;
  let width;
  let height;
  try {
    source = await createImageBitmap(file, { imageOrientation: 'from-image' });
    width = source.width;
    height = source.height;
  } catch {
    source = await new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const img = new Image();
      img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("This picture couldn't be opened.")); };
      img.src = url;
    });
    width = source.naturalWidth;
    height = source.naturalHeight;
  }
  const scale = Math.min(1, maxSide / Math.max(width, height));
  const w = Math.max(1, Math.round(width * scale));
  const h = Math.max(1, Math.round(height * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, w, h);
  ctx.drawImage(source, 0, 0, w, h);
  if (typeof source.close === 'function') source.close();
  return { dataURL: canvas.toDataURL('image/jpeg', quality), width: w, height: h };
}

/**
 * Width and height for the model's vision pass: multiples of 32 px (its 16 px patches, merged 2 by 2) with
 * at most `maxPatches` patches. Pie's vision tower takes at most 512 patch rows (max_forward_tokens) in one
 * pass and can't split a picture across passes, so a photo keeps about 440 patches, as on the iPhone
 * (PieEngine.captionJPEG): 320 x 320 (400 patches) when square, 384 x 288 (432) at 4:3.
 */
export function visionSize(width, height, maxPatches = 440) {
  let scale = Math.min(1, Math.sqrt((maxPatches * 256) / Math.max(1, width * height)));
  for (;;) {
    const w = Math.max(32, Math.floor((width * scale) / 32) * 32);
    const h = Math.max(32, Math.floor((height * scale) / 32) * 32);
    if ((w / 16) * (h / 16) <= maxPatches || (w === 32 && h === 32)) return { width: w, height: h };
    scale *= 0.95;
  }
}

/**
 * The photo as the model's vision pass reads it: a small JPEG (see visionSize), as base64 without the
 * data: prefix. Small keeps the pass quick; it never leaves the browser either way.
 */
export async function photoForModel(dataURL, { quality = 0.85 } = {}) {
  const img = new Image();
  img.src = dataURL;
  await img.decode();
  const size = visionSize(img.naturalWidth, img.naturalHeight);
  const canvas = document.createElement('canvas');
  canvas.width = size.width;
  canvas.height = size.height;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL('image/jpeg', quality).split(',')[1];
}

const STOP = new Set('the and with from that this there their into onto over under near just some very a an of on in at to for my your our its is it was by little'.split(' '));
const words = (s) => (String(s || '').toLowerCase().match(/[a-z]{3,}/g) || []).filter((w) => !STOP.has(w));
const stem = (w) => w.replace(/(?:ies|es|s)$/, '');

const EMOJI_HINTS = [
  [/sunset|sunrise|dusk|dawn/, '🌅'], [/sea|ocean|wave|tide|harbou?r|beach|shore/, '🌊'], [/tea|kettle|mug/, '🫖'],
  [/coffee|latte/, '☕'], [/bread|loaf|bak|croissant|scone|roll/, '🥐'], [/cake|pie|tart/, '🍰'], [/flower|bloom|blossom|rose/, '🌸'],
  [/garden|plant|leaf|herb|moss/, '🌿'], [/book|librar|page|chart/, '📚'], [/boat|sail|ship|dock/, '⛵'], [/lighthouse|lamp|lantern/, '🏮'],
  [/moon|night/, '🌙'], [/star/, '✨'], [/rain|storm|cloud/, '🌧️'], [/snow|frost/, '❄️'], [/autumn|fall leaves/, '🍂'],
  [/shell|pebble|stone/, '🐚'], [/gull|bird|heron|owl/, '🕊️'], [/fish/, '🐟'], [/cat|kitten/, '🐈'], [/dog|puppy/, '🐕'],
  [/sun|sunny|morning/, '☀️'], [/music|song|guitar|fiddle/, '🎶'], [/paint|drawing|sketch/, '🎨'], [/market|stall|fruit|apple/, '🍎'],
];

function emojiFor(caption) {
  const c = String(caption || '').toLowerCase();
  return EMOJI_HINTS.find(([re]) => re.test(c))?.[1] || '📷';
}

/**
 * The picture to show for a character's "[photo: caption]".
 * Returns { src (bundled art URL or null), postcard: { emoji, colors } } - the postcard is the fallback.
 */
export function pictureFor(caption, { world = null, character = null, locationID = null } = {}) {
  const want = new Set(words(caption).map(stem));
  const candidates = [];
  for (const l of world?.locations || []) {
    const asset = l.art?.asset || `loc-${l.id}`;
    const keys = [...words(l.id.replace(/-/g, ' ')), ...words(l.name)];
    const soft = words(l.blurb);
    candidates.push({ asset, keys, soft, emoji: l.art?.emoji || l.emoji, colors: l.art?.colors, bonus: l.id === locationID ? 0.5 : 0 });
  }
  for (const c of world?.characters || []) {
    const asset = c.avatar?.asset || `char-${c.id}`;
    candidates.push({ asset, keys: [...words(c.name), ...words(c.species)], soft: [], emoji: c.avatar?.emoji, colors: c.avatar?.colors, bonus: 0 });
  }
  let best = null;
  for (const cand of candidates) {
    let score = 0;
    for (const k of cand.keys) if (want.has(stem(k))) score += 1;
    for (const k of cand.soft) if (want.has(stem(k))) score += 0.4;
    if (score > 0) score += cand.bonus;
    if (score > 0 && (!best || score > best.score)) best = { ...cand, score };
  }
  const src = best && best.score >= 1 && !isMissingArt(artURL(best.asset)) ? artURL(best.asset) : null;
  const colors = (best?.colors?.length >= 2 ? best.colors : null) || character?.avatar?.colors || ['#3A2A20', '#F6C177'];
  return { src, postcard: { emoji: emojiFor(caption) !== '📷' ? emojiFor(caption) : (best?.emoji || '📷'), colors: colors.slice(0, 2) } };
}
