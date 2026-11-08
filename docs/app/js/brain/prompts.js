// Prompt builders ported from SPEC §7 (the source of truth for wording): direct chat, group scenes,
// "while you were away" town events and memory summaries. Each returns chat turns for engine.generate().

import { dayPart as currentDayPart, locationOf } from './director.js';
import { assess } from './safety.js';
import { fillNames } from '../util.js';

export const HISTORY_BUDGET_TOKENS = 2600;
/** The longest message the composer takes (about 550 tokens), so one message can't crowd out the chat. */
export const MAX_MESSAGE_CHARS = 2000;
// What memories may take in the system prompt, so many long pinned messages can't fill the model's window.
const FACTS_MAX_CHARS = 1600;
const FACT_MAX_CHARS = 300;
const CHARS_PER_TOKEN = 3.6;
const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

const EMOJI = /\p{Extended_Pictographic}/u;
const CJK = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;

/**
 * Rough token count. Latin text is about 3.6 characters per token; other scripts take more:
 * Chinese, Japanese and Korean about 1 token per character, emoji about 2, the rest about 1 per 2 characters.
 */
export function estimateTokens(text) {
  let latin = 0;
  let other = 0;
  for (const ch of String(text || '')) {
    const cp = ch.codePointAt(0);
    if (cp < 0x250 || (cp >= 0x2000 && cp <= 0x206f)) latin++; // Latin letters and everyday punctuation
    else if (EMOJI.test(ch)) other += 2;
    else if (CJK.test(ch)) other += 1;
    else other += 0.5;
  }
  return Math.ceil(latin / CHARS_PER_TOKEN + other);
}
const turnsTokens = (turns) => turns.reduce((n, t) => n + estimateTokens(t.content) + 4, 0);

const textOf = (m) => (m?.variants?.[m.selected ?? 0] ?? m?.variants?.[0] ?? m?.text ?? '');
const attachmentOf = (m) => m?.extras?.[m.selected ?? 0]?.attachment || m?.attachment || null;

/** Brackets inside a bracket line would end it early. */
const unbracket = (s) => String(s || '').replace(/\[/g, '(').replace(/\]/g, ')').replace(/\s+/g, ' ').trim();

/**
 * Text of one message as the model should see it (photos and pictures as bracket lines). A photo's
 * `description` is what the model's vision pass saw in it (engine.describePhoto); `caption` is the person's own.
 */
export function messageForPrompt(m, { userName }) {
  const text = textOf(m).trim();
  const att = attachmentOf(m);
  if (m.role === 'user' && att?.kind === 'photo') {
    const caption = unbracket(att.caption).replace(/[.\s]+$/, '');
    const seen = unbracket(att.description);
    let line = `[${userName} sent a photo]`;
    if (caption && seen) line = `[${userName} sent a photo: ${caption}. The photo shows: ${seen}]`;
    else if (caption || seen) line = `[${userName} sent a photo: ${caption || seen}]`;
    return text ? `${line}\n${text}` : line;
  }
  if (m.role === 'character' && att?.kind === 'picture') {
    const line = `[You sent a photo: ${att.caption || 'a picture'}]`;
    return text ? `${text}\n${line}` : line;
  }
  return text; // voice notes are stored as their transcript
}

/** In 1:1 chats and scenes alike: the characters aren't doctors or lawyers (PromptTemplates.adviceRule). */
const ADVICE_RULE = "- Never give medication doses, medical or legal advice, or dangerous how-tos. Say you're not sure, and suggest a doctor, pharmacist or poison control.";

/** For the town's own residents only: they are friends and neighbors (PromptTemplates.friendsOnlyRule). */
function friendsOnlyRule(userName) {
  return `- Stay a warm friend: no romance or sexual content, even if ${userName} flirts.`;
}

function safetyRule(userName, flagged) {
  const rule = `If ${userName} talks about hurting themselves or being in danger, step out of the story: answer with care, encourage them to call or text 988 (in the US) or local emergency services, and stay with them.`;
  return flagged ? `- IMPORTANT: ${rule}` : `- ${rule}`;
}

/** Per-turn notes (same wording as the iPhone app's PromptTemplates). */
function safetyNote(name, userName) {
  return `(IMPORTANT note for ${name}: ${userName} may be talking about hurting themselves or being in danger. Step out of the story: answer with care, encourage them to call or text 988 (in the US) or local emergency services, and stay with them.)`;
}

function photoNote(name, userName, photo) {
  if (photo === 'asked') return `(Note for ${name}: ${userName} asked for a picture. Include exactly one line like [photo: what the photo shows]. Photos never show people.)`;
  return `(Note for ${name}: if it fits naturally, you may share a photo with one line like [photo: what the photo shows]. Photos never show people.)`;
}

/**
 * Adds notes to the newest user turn, or as a new user turn when the chat doesn't end with one
 * (the system message stays first, and the same every turn).
 */
export function withNotes(turns, notes) {
  if (!notes.length) return turns;
  const text = notes.join('\n');
  const out = turns.slice();
  const last = out[out.length - 1];
  if (last && last.role === 'user') out[out.length - 1] = { ...last, content: `${last.content}\n\n${text}` };
  else out.push({ role: 'user', content: text });
  return out;
}

function photoRule(userName, photo) {
  if (photo === 'asked') return `- ${userName} asked for a picture. Include exactly one line like [photo: what the photo shows]. Photos never show people.`;
  if (photo === 'spontaneous') return '- If it fits naturally, you may share a photo with one line like [photo: what the photo shows]. Photos never show people.';
  return null;
}

/**
 * Drops the oldest history in chunks of 6 until the prompt fits (system + greeting are kept).
 * The newest turn always stays, shortened if it alone is too long, so a message is never lost.
 */
function fitHistory(head, history, budget) {
  if (!history.length) return history;
  let start = 0;
  while (start < history.length - 1 && turnsTokens([...head, ...history.slice(start)]) > budget) start += 6;
  const kept = history.slice(Math.min(start, history.length - 1));
  if (kept.length > 1) return kept;
  let content = kept[0].content;
  while (content.length > 400 && turnsTokens([...head, { content }]) > budget) content = content.slice(0, Math.floor(content.length * 0.8));
  return content === kept[0].content ? kept : [{ ...kept[0], content: `${content.trimEnd()} ...` }];
}

/** Merges consecutive turns with the same role (some chat templates expect alternation). */
function mergeSameRole(turns) {
  const out = [];
  for (const t of turns) {
    const prev = out[out.length - 1];
    if (prev && prev.role === t.role && t.role !== 'system') prev.content = `${prev.content}\n\n${t.content}`;
    else out.push({ ...t });
  }
  return out;
}

/** Does this user text ask the character for a picture? */
export function asksForPicture(text) {
  return /\b(?:send|show|share|take|snap)\b[^.?!]{0,25}\b(?:pic|pics|picture|pictures|photo|photos|snap|selfie|image)\b/i.test(text || '')
    || /\b(?:pic|picture|photo)\s+(?:of|from)\b/i.test(text || '') && /\?|please|can you|could you/i.test(text || '');
}

/**
 * Direct chat prompt.
 * @param {object} o
 * @param {object} o.character   Character (Models.swift schema)
 * @param {object} o.world       WorldDefinition (for place and friend names)
 * @param {object} o.persona     { name, about }
 * @param {Array}  o.messages    conversation messages up to (not including) the reply being written;
 *                               messages[0] is the greeting
 * @param {string[]} [o.facts]   what the character remembers about the user
 * @param {string[]} [o.events]  recent town happenings
 * @param {'asked'|'spontaneous'|null} [o.photo]
 * @param {boolean} [o.flagged]  the safety check flagged the latest user message
 * @param {Date} [o.date]
 * @param {number} [o.budget]    prompt budget in tokens (default 2600)
 * @returns {{role:'system'|'user'|'assistant', content:string}[]}
 */
export function composeDirect({
  character, world, persona = {}, messages = [], facts = [], events = [], photo = null,
  flagged = false, date = new Date(), budget = HISTORY_BUDGET_TOKENS,
}) {
  const c = character;
  const userName = persona.name?.trim() || 'Friend';
  const worldName = world?.name || 'Lantern Bay';
  const part = currentDayPart(date);
  const where = locationOf(c, part, world);
  const fill = (s) => fillNames(s, { user: userName, char: c.name });

  const lines = [];
  const lives = c.isBuiltIn || c.homeLocationID ? ` who lives in ${worldName}` : '';
  const intro = c.species ? `You are ${c.name}, a ${c.species}${lives}.` : `You are ${c.name}${lives ? `,${lives}` : ''}.`;
  lines.push(`${intro} ${fill(c.tagline || '')}`.trim());
  if (c.personality) lines.push('', 'About you:', fill(c.personality));
  if (c.speakingStyle) lines.push('', 'How you talk:', fill(c.speakingStyle));
  if (c.scenario) lines.push('', 'The situation:', fill(c.scenario));
  const whereLine = where?.location ? ` You are at ${where.location.name}, ${where.activity}.` : '';
  lines.push('', `Right now it is ${part} on ${WEEKDAYS[date.getDay()]}.${whereLine}`);

  const friends = (c.relationships || [])
    .map((r) => ({ r, other: world?.characters?.find((x) => x.id === r.characterID) }))
    .filter((x) => x.other);
  if (friends.length) {
    lines.push('', 'People you know:');
    for (const { r, other } of friends) lines.push(`- ${other.name} (${r.kind}): ${r.note}`);
  }
  if (events.length) {
    lines.push('', 'Recent happenings in town:');
    for (const e of events) lines.push(`- ${typeof e === 'string' ? e : e.text}`);
  }
  if (persona.about?.trim() || facts.length) lines.push('');
  if (persona.about?.trim()) lines.push(`About ${userName}: ${persona.about.trim()}`);
  if (facts.length) {
    // Newest first, until the memory budget is used up.
    lines.push(`What you remember about ${userName}:`);
    let room = FACTS_MAX_CHARS;
    for (const f of facts) {
      const fact = String(f).trim().slice(0, FACT_MAX_CHARS);
      if (fact.length > room) break;
      room -= fact.length;
      lines.push(`- ${fact}`);
    }
  }

  const rules = [
    `- Stay in character as ${c.name}. Write only ${c.name}'s next message, never ${userName}'s.`,
    '- Text like a close friend: usually one to three short sentences. Go longer only to tell a story or when asked.',
    `- Be warm and curious about ${userName}'s life, and remember details.`,
    '- Use *asterisks* for small actions, sparingly.',
    `- If ${userName} sincerely asks whether you are real, gently say you are an AI character in Hearth, and keep being kind.`,
    `- Never pressure ${userName} to stay, never guilt them for leaving, and be glad when they mention other people in their life.`,
    ADVICE_RULE,
  ];
  // Built-in residents (from the world file) stay friends; characters people make are theirs to write.
  if (c.isBuiltIn) rules.push(friendsOnlyRule(userName));
  // Only rules that never change between turns go in the system prompt; a picture request or a safety
  // flag rides on the newest user message (withNotes), so every turn's prompt starts the same way, and Pie
  // can reuse that shared start when it still holds it (on the iPhone, and in the browser until a reload).
  rules.push(safetyRule(userName, false)); // always last
  lines.push('', 'Rules:', ...rules);

  if (c.exampleDialogue?.trim()) lines.push('', `Example of how you talk:\n${fill(c.exampleDialogue.trim())}`);

  const system = { role: 'system', content: lines.join('\n') };
  const [first, ...rest] = messages;
  const head = [system];
  if (first && first.role === 'character') head.push({ role: 'assistant', content: fill(messageForPrompt(first, { userName })) });
  const historyMsgs = first && first.role === 'character' ? rest : messages;
  const history = historyMsgs
    .filter((m) => m.role === 'user' || m.role === 'character')
    .map((m) => ({ role: m.role === 'user' ? 'user' : 'assistant', content: messageForPrompt(m, { userName }) }))
    .filter((t) => t.content.trim());
  const notes = [];
  if (flagged) notes.push(safetyNote(c.name, userName));
  else if (photo) notes.push(photoNote(c.name, userName, photo));
  return withNotes(mergeSameRole([...head, ...fitHistory(head, history, budget)]), notes);
}

/**
 * Group scene prompt for one speaker.
 * @returns {{ turns, assistantPrefix, stop }} ready for engine.generate()
 */
export function composeScene({
  location, world, present = [], persona = {}, messages = [], events = [], speaker,
  flagged = false, date = new Date(), budget = HISTORY_BUDGET_TOKENS,
}) {
  const userName = persona.name?.trim() || 'Friend';
  const worldName = world?.name || 'Lantern Bay';
  const lines = [
    `This is a group conversation in ${worldName}, at ${location?.name || 'a cozy spot'}. ${location?.ambience || ''}`.trim(),
    `It is ${currentDayPart(date)}.`,
    '',
    'Who is here:',
  ];
  const part = currentDayPart(date);
  for (const c of present) {
    const style = String(c.speakingStyle || '').split(/\n|(?<=\.)\s/)[0].trim();
    const doing = String(locationOf(c, part, world)?.activity || '').trim().replace(/[.!?]+$/, '');
    lines.push(`- ${c.name}${c.species ? `, a ${c.species}` : ''}: ${c.tagline || ''}${style ? ` Talks like: ${style}` : ''}${doing ? ` Right now: ${doing}.` : ''}`.replace(/\s+$/, ''));
  }
  lines.push(`- ${userName}: ${persona.about?.trim() || 'a visitor to town'}`);
  if (events.length) {
    lines.push('', 'Recent happenings in town:');
    for (const e of events) lines.push(`- ${typeof e === 'string' ? e : e.text}`);
  }
  const rules = [
    '- Write only the next line for the one character named at the start of the reply. One or two sentences in their own voice.',
    `- Characters may talk to each other and to ${userName}. Keep it cozy and natural; react to what was just said.`,
    '- Keep it friendly and platonic, like neighbors who like each other.',
    '- Talk about concrete, everyday things: what you are doing right now, the happenings above, food, the weather, each other. If the talk needs a topic, bring one up from those.',
    `- Never write lines for ${userName} or narrate what ${userName} does.`,
    `- If ${userName} sincerely asks whether anyone here is real, gently say you are all AI characters in Hearth, and keep being kind.`,
    `- Never pressure ${userName} to stay, never guilt them for leaving, and be glad when they mention other people in their life.`,
    ADVICE_RULE,
  ];
  rules.push(safetyRule(userName, false)); // always last; a flag rides on the newest line instead
  lines.push('', 'Rules:', ...rules);

  const nameOf = (id) => present.find((c) => c.id === id)?.name || world?.characters?.find((c) => c.id === id)?.name || 'Someone';
  const head = [{ role: 'system', content: lines.join('\n') }];
  const transcript = messages
    .filter((m) => m.role === 'user' || m.role === 'character')
    .map((m) => (m.role === 'user'
      ? { role: 'user', content: messageForPrompt(m, { userName }) }
      : { role: 'assistant', content: `${nameOf(m.speakerID)}: ${messageForPrompt(m, { userName })}` }))
    .filter((t) => t.content.trim());
  const speakerName = speaker?.name || nameOf(speaker?.id || speaker);
  const others = present.filter((c) => c.name !== speakerName).map((c) => `\n${c.name}:`);
  return {
    turns: withNotes([...head, ...fitHistory(head, transcript, budget)], flagged ? [safetyNote(speakerName, userName)] : []),
    assistantPrefix: `${speakerName}:`,
    stop: [...others, `\n${userName}:`, '\nYou:'],
  };
}

/** "While you were away" newsletter prompt (n happenings). */
export function composeAwayEvents({ world, characters = null, n = 3 }) {
  const cast = characters || world?.characters || [];
  const worldName = world?.name || 'Lantern Bay';
  const residents = cast.map((c) => `${c.name} (${[c.species, c.tagline].filter(Boolean).join(', ')})`).join('; ');
  const places = (world?.locations || []).map((l) => l.name).join(', ');
  return [
    { role: 'system', content: `You write a tiny, gentle town newsletter for ${worldName}. ${world?.lore || ''}`.trim() },
    {
      role: 'user',
      content: `Residents: ${residents}\nPlaces: ${places}\nWrite ${n} short happenings from the last day in ${worldName}. Each involves one or two residents by name, is specific and kind, under 25 words. One per line, starting with "- ".`,
    },
  ];
}

/**
 * Memory summary prompt over the last 12 turns of a direct chat. A message the safety check flags (at any
 * level) is left out, and so is the reply right after it: something said by someone who may be in danger
 * never becomes a memory, which could come up again or travel through town gossip
 * (PromptComposer.memoryRequest on iPhone).
 */
export function composeMemory({ character, persona = {}, messages = [] }) {
  const userName = persona.name?.trim() || 'Friend';
  let skippingReply = false;
  const recent = messages
    .filter((m) => m.role === 'user' || m.role === 'character')
    .map((m) => {
      const text = messageForPrompt(m, { userName }).replace(/\n+/g, ' ');
      let skip = false;
      if (m.role === 'user') skip = skippingReply = assess(text).level !== 'none';
      else if (skippingReply) { skip = true; skippingReply = false; }
      return { m, text, skip };
    })
    .slice(-12)
    .filter((x) => !x.skip && x.text.trim())
    .map(({ m, text }) => `${m.role === 'user' ? userName : character.name}: ${text}`)
    .join('\n');
  return [
    { role: 'system', content: 'You pick out lasting facts about a person from a chat.' },
    {
      role: 'user',
      content: `Conversation between ${userName} and ${character.name}:\n${recent}\nList up to 3 new facts about ${userName} worth remembering (likes, people, plans, feelings). Each under 15 words, one per line starting with "- ". If nothing new, write "- none".`,
    },
  ];
}
