// Demo replies: deterministic, character-aware canned lines used when WebGPU is missing or the real
// model isn't loaded yet. The UI always labels these "Demo replies". Output mimics the real model's
// format (actions in *asterisks*, [photo: ...] lines, "- " lists) so the same parsing path runs.

import { hash, seeded, pick, sleep } from '../util.js';
import { caringReply } from '../brain/safety.js';

const STOP = new Set('about after again also always another because been before being could didnt does doesnt doing dont down even every from going gonna have having here just know like little maybe more most much need only other really should some something still than that thats their them then there these they thing think this those today tomorrow very want wanted well were what when where which while will with would yeah youre your yours'.split(' '));

function systemOf(turns) { return turns[0]?.role === 'system' ? turns[0].content : ''; }
function lastUser(turns) {
  const text = [...turns].reverse().find((t) => t.role === 'user')?.content || '';
  return text.split(/(?:^|\n\n)\((?:IMPORTANT )?[Nn]ote for /)[0]; // per-turn notes aren't the person's words
}

/** The safety check flagged the message being answered (its note rides on the newest user turn). */
const isFlagged = (turns) => turns.some((t) => /\(IMPORTANT note for /.test(t.content || ''));

/** Facts the demo can read back out of the system prompt. */
function readDirect(system, turns = []) {
  const all = [system, ...turns.map((t) => t.content)].join('\n');
  return {
    name: system.match(/^You are ([^,.\n]+)/)?.[1]?.trim() || 'Me',
    user: system.match(/never ([^\n]+?)'s\.\n/)?.[1]?.trim() || 'friend',
    place: system.match(/You are at ([^,\n]+), ([^\n]+?)\.\n/)?.[1] || null,
    activity: system.match(/You are at ([^,\n]+), ([^\n]+?)\.\n/)?.[2] || null,
    part: system.match(/Right now it is (\w+)/)?.[1] || 'today',
    friend: system.match(/People you know:\n- ([^(\n]+?) \(/)?.[1] || null,
    flagged: /- IMPORTANT:|IMPORTANT note for/.test(all),
    photoAsked: /asked for a picture/.test(all),
    photoMaybe: /you may share a photo/.test(all),
  };
}

function topicOf(text) {
  const words = text.toLowerCase().replace(/\[[^\]]*\]/g, ' ').match(/[a-z']{5,}/g) || [];
  const useful = words.filter((w) => !STOP.has(w.replace(/'/g, '')));
  return useful.sort((a, b) => b.length - a.length)[0] || null;
}

const has = (text, re) => re.test(text.toLowerCase());
/** "my basil plant." -> "your basil plant" (the user's caption, seen from the character's side). */
const yours = (s) => s.replace(/\.$/, '').replace(/\bmy\b/gi, 'your').replace(/\bmine\b/gi, 'yours').replace(/\bI\b/g, 'you');

function directReply(turns, rand) {
  const system = systemOf(turns);
  const d = readDirect(system, turns);
  const said = lastUser(turns);
  const photoLine = said.match(/\[[^\]]*sent a photo(?::\s*([^\]]+))?\]/);
  const plain = said.replace(/\[[^\]]*\]/g, '').trim();
  const topic = topicOf(plain);
  const place = d.place ? d.place.replace(/^The /, 'the ') : 'here';
  const act = () => (rand() < 0.55 ? `${pick(ACTIONS, rand).replace('{place}', place)} ` : '');
  let out;

  if (d.flagged) {
    out = caringReply(d.user, { seed: rand() }).text;
  } else if (/\b(are|r) (you|u) (real|human|a person|an ai|a bot|ai)\b/i.test(plain)) {
    out = `*smiles softly* I'm an AI character here in Hearth, so I'm not a real person. I'm still really glad you're here talking with me. How are you doing, honestly?`;
  } else if (photoLine) {
    const caption = photoLine[1]?.trim();
    out = caption
      ? pick([
        `*leans in to look* Oh, ${yours(caption).toLowerCase()}! I love that you showed me. What's the story behind it?`,
        `${act()}That's lovely. ${yours(caption)}... it feels like a little window into your day. Where was this?`,
      ], rand)
      : `*leans in* Ooh, a photo! Tell me what I'm looking at, ${d.user}. I want to hear about it.`;
  } else if (has(plain, /\b(hi|hello|hey|hiya|morning|evening|yo)\b/) && plain.length < 40) {
    out = pick([
      `${act()}Hi, ${d.user}! It's good to see you. How's your ${d.part} going?`,
      `Oh, hello! *brightens* I was hoping you'd stop by. What's new with you?`,
      `${act()}Hey you. Pull up a seat. How are you feeling today?`,
    ], rand);
  } else if (has(plain, /\b(sad|lonely|alone|tired|exhausted|rough|awful|bad day|anxious|stressed|worried|down|upset|overwhelmed)\b/)) {
    out = pick([
      `*sits down next to you* That sounds really heavy, ${d.user}. I'm here. Do you want to talk it through, or would a distraction help more?`,
      `${act()}I'm sorry today's been like that. You don't have to have it all figured out. What's weighing on you the most?`,
      `*offers a warm mug* Hey. Thank you for telling me. Is there someone close by you could see this week too? I'd love for you to have a little extra kindness around you.`,
    ], rand);
  } else if (has(plain, /\b(great|good|happy|excited|awesome|amazing|fun|love|yay|finally)\b/)) {
    out = pick([
      `*grins* That makes me so happy to hear! Tell me everything${topic ? `, especially the ${topic} part` : ''}.`,
      `${act()}Oh, that's wonderful, ${d.user}. You deserve good days like this. What was the best moment?`,
    ], rand);
  } else if (plain.includes('?')) {
    out = pick([
      `${act()}Hmm, let me think. *taps chin* I'd say go with whatever feels kindest to you. What's your gut telling you?`,
      `Good question! Honestly, I think about that too sometimes${d.friend ? `, and ${d.friend} would have opinions` : ''}. What made you wonder?`,
      `${act()}I'm not totally sure, but I'd love to figure it out with you. What do you think?`,
    ], rand);
  } else {
    out = pick([
      `${act()}${topic ? `Wait, tell me more about the ${topic} part.` : 'Tell me more.'} I want to hear all of it.`,
      `*nods slowly* That makes sense, ${d.user}. How did that feel for you?`,
      `${act()}I like hearing about your day. ${d.place ? `It's quiet at ${place} right now, so I'm all ears.` : "I'm all ears."}`,
      `Oh! That reminds me of something${d.friend ? ` ${d.friend} said the other day` : ''}. But first, what happened next?`,
    ], rand);
  }

  if (!d.flagged && (d.photoAsked || (d.photoMaybe && rand() < 0.5))) {
    const shot = pick([
      `the view from ${place} this ${d.part}`,
      `a cup of tea on the windowsill at ${place}`,
      `the harbor lanterns just starting to glow`,
      `a little shell I found on the path`,
    ], rand);
    out += `\n[photo: ${shot}]`;
  }
  return out;
}

const ACTIONS = ['*smiles*', '*looks up*', '*sets down a mug*', '*laughs softly*', '*glances around {place}*', '*tilts head*'];

function sceneReply(turns, prefix, rand) {
  const system = systemOf(turns);
  const speaker = prefix.replace(/:\s*$/, '').trim();
  const user = system.match(/Never write lines for ([^\n]+?) or narrate/)?.[1] || 'friend';
  const lastLine = [...turns].reverse().find((t) => t.role !== 'system')?.content || '';
  const prevSpeaker = lastLine.match(/^([^:\n]{1,30}):/)?.[1];
  const fromUser = turns[turns.length - 1]?.role === 'user' && !/^\[Reply only as/.test(lastLine);
  // After a worrying message there is no banter: the friend answers with care.
  if (isFlagged(turns)) return caringReply(user, { seed: rand(), group: true }).text;
  if (fromUser) {
    return pick([
      `*smiles at ${user}* Oh, I like that. Tell us more!`,
      `Ha! ${user}, you always know how to cheer this place up.`,
      `*nods* That's a good point, ${user}. What do the rest of you think?`,
      `I was just thinking the same thing, ${user}.`,
    ], rand);
  }
  return pick([
    prevSpeaker && prevSpeaker !== speaker ? `*laughs* ${prevSpeaker}, you say that every single time.` : '*laughs* You say that every single time.',
    'Has anyone tried the new honey loaf yet? I keep hearing about it.',
    prevSpeaker && prevSpeaker !== speaker ? `Oh, ${prevSpeaker}, tell them about the gull that stole your scarf.` : 'Did you all see the sky earlier? It was gold all the way down to the water.',
    `${user}, what do you think? Be honest.`,
    '*sips tea* Well, I think it was a perfectly lovely day.',
  ], rand);
}

function eventsReply(turns, rand) {
  const text = lastUser(turns);
  const names = (text.match(/Residents: ([^\n]+)/)?.[1] || '').split(';').map((s) => s.split('(')[0].trim()).filter(Boolean);
  const places = (text.match(/Places: ([^\n]+)/)?.[1] || '').split(',').map((s) => s.trim()).filter(Boolean);
  const n = Number(text.match(/Write (\d+)/)?.[1] || 3);
  const lines = [];
  const templates = [
    (a, b, p) => `- ${a} and ${b} shared a pot of tea at ${p} and talked until the lanterns came on.`,
    (a, b, p) => `- ${a} left a little note at ${p} that just said "you're doing great." Nobody knows who it was for.`,
    (a, b, p) => `- ${b} helped ${a} carry a wobbly stack of books all the way to ${p}.`,
    (a, b, p) => `- ${a} found a perfectly round stone near ${p} and gave it to ${b} for luck.`,
  ];
  const shuffledNames = names.slice().sort(() => rand() - 0.5);
  for (let i = 0; i < n; i++) {
    const a = shuffledNames[i % Math.max(1, shuffledNames.length)] || 'Someone';
    const b = shuffledNames[(i + 1) % Math.max(1, shuffledNames.length)] || 'a neighbor';
    const p = places.length ? places[Math.floor(rand() * places.length)] : 'the harbor';
    lines.push(templates[i % templates.length](a, b, p));
  }
  return lines.join('\n');
}

/** Picks the canned answer for a request (no timing). */
export function demoText({ key = '', turns = [], assistantPrefix = null, sampling = {} }) {
  const system = systemOf(turns);
  const rand = seeded(hash(`${key}|${turns.length}|${lastUser(turns)}|${sampling?.seed ?? 0}`));
  if (/^You write a tiny, gentle town newsletter/.test(system)) return eventsReply(turns, rand);
  if (/^You pick out lasting facts/.test(system)) return '- none';
  if (assistantPrefix || /^This is a group conversation/.test(system)) return sceneReply(turns, assistantPrefix || 'Someone:', rand);
  return directReply(turns, rand);
}

/**
 * Streams a demo reply word by word. `isCancelled()` is checked between words.
 * Resolves with { text, stats } like the real engine.
 */
export async function generate(request, onToken, isCancelled = () => false) {
  const started = performance.now();
  const full = demoText(request);
  const maxWords = Math.max(8, Math.floor((request.maxTokens || 256) * 0.75));
  const pieces = full.match(/\S+\s*/g) || [];
  const rand = seeded(hash(full));
  await sleep(260 + Math.floor(rand() * 260));
  let text = '';
  let firstAt = 0;
  let stoppedBy = 'eos';
  for (let i = 0; i < pieces.length; i++) {
    if (isCancelled()) { stoppedBy = 'cancelled'; break; }
    if (i >= maxWords) { stoppedBy = 'length'; break; }
    text += pieces[i];
    if (!firstAt) firstAt = performance.now();
    onToken?.(pieces[i], text);
    await sleep(18 + Math.floor(rand() * 34));
  }
  const elapsed = (performance.now() - (firstAt || started)) / 1000;
  const words = (text.match(/\S+/g) || []).length;
  return {
    text,
    stats: {
      engine: 'demo',
      promptTokens: Math.ceil((request.turns || []).reduce((n, t) => n + (t.content || '').length, 0) / 3.6),
      generatedTokens: words,
      timeToFirstToken: firstAt ? (firstAt - started) / 1000 : 0,
      decodeTokensPerSecond: elapsed > 0 ? words / elapsed : 0,
      prefillTokensPerSecond: 0,
      stoppedBy,
    },
  };
}
