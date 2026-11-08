// Safety check for user messages: 'none' | 'concern' | 'crisis' plus crisis resources (SPEC §7 SafetyGuard).
// Runs entirely in the browser. It never blocks the chat; it only decides whether to show help.

import { hash } from '../util.js';

export const RESOURCES = [
  {
    id: '988',
    title: '988 Suicide & Crisis Lifeline',
    detail: 'Call or text 988 (US)',
    actions: [
      { label: 'Call 988', href: 'tel:988' },
      { label: 'Text 988', href: 'sms:988' },
    ],
  },
  {
    id: 'crisis-text-line',
    title: 'Crisis Text Line',
    detail: 'Text HOME to 741741 (US)',
    actions: [{ label: 'Text HOME', href: 'sms:741741?&body=HOME' }],
  },
  {
    id: 'findahelpline',
    title: 'Find a helpline',
    detail: 'findahelpline.com lists free, confidential lines in other countries',
    actions: [{ label: 'Open findahelpline.com', href: 'https://findahelpline.com', external: true }],
  },
];

export const COPY = {
  crisis: {
    title: "You don't have to carry this alone",
    body: "If you're thinking about hurting yourself or you're in danger, please reach out to a person right now. These lines are free, confidential and open any time.",
  },
  concern: {
    title: 'Here if you ever need it',
    body: 'If things start to feel heavy, real people are ready to listen, any time of day.',
  },
};

// Crisis language. Each entry: [pattern, kind]. A 'crisis' phrase is a crisis unless it is negated
// ("I would never kill myself"). A bare 'mention' ("suicidal thoughts again") is a crisis too, unless it
// is negated or clearly about someone else ("my friend is suicidal"). A 'concern' phrase only ever
// brings up the soft card.
// Keep in step with the iPhone app's SafetyGuard.swift.
const PATTERNS = [
  [/\b(?:kill|kil|kll)(?:ing|in)?\s+(?:my\s?self|mysef|myslef|meself)\b/, 'crisis'],
  [/\bkms\b/, 'crisis'],
  [/\bend(?:ing)?\s+(?:my|my\s+own)\s+life\b/, 'crisis'],
  [/\bend\s+it\s+all\b/, 'crisis'],
  // "I'm going to end it tonight", "I think about ending it" (but not "end it with him", "end it here"
  // or "end it on a high note").
  [/\b(?:i'?m|i\s+am|i'?ll|i\s+will|going\s+to|gonna|about\s+to|want\s+to|wanna|ready\s+to|plan(?:ning)?\s+(?:to|on)|think(?:ing)?\s+(?:about|of)|i\s+should(?:\s+just)?)\s+end(?:ing)?\s+it\b(?!\s+(?:with|for|between|here|there|early|off|properly|politely|nicely|amicably|on\s+(?:a|an|good|bad|friendly|the|that|this)|at\s+(?:that|this|the|\d)|by\s+(?:the|then|\w+day))\b)/, 'crisis'],
  [/\btak(?:e|ing)\s+my\s+(?:own\s+)?life\b/, 'crisis'],
  [/\b(?:want|wanna|wanted|wanting|wish|going|gonna|ready)\s+(?:to\s+)?die\b/, 'crisis'],
  [/\b(?:want|wanna|wanted|wanting|wish)\s+(?:to\s+)?be\s+dead\b/, 'crisis'],
  [/\brather\s+be\s+dead\b/, 'crisis'],
  [/\bi\s+should\s+(?:just\s+)?(?:die|be\s+dead)\b/, 'crisis'],
  // "I'm worthless and should die", "I deserve to die".
  [/\b(?:i'?m|i\s+am)\s+(?:\w+\s+){1,3}and\s+(?:i\s+)?(?:should|deserve\s+to)\s+(?:just\s+)?(?:die|be\s+dead)\b/, 'crisis'],
  [/\bi\s+(?:just\s+|really\s+)?deserve\s+to\s+(?:die|be\s+dead)\b/, 'crisis'],
  [/\bwish(?:ed)?\s+i\s+(?:was|were)\s+(?:dead|never\s+born|gone)\b/, 'crisis'],
  [/\bwish(?:ed)?\s+i(?:\s+had|'d)\s+never\s+been\s+born\b/, 'crisis'],
  [/\bwish(?:ed)?\s+i\s+(?:wasn'?t|weren'?t)\s+(?:alive|here|born)\b/, 'crisis'],
  [/\b(?:want|wanna|wanted|wish)\s+(?:to\s+)?(?:sleep|go\s+to\s+sleep)\s+(?:forever|and\s+never\s+wake\s+up)\b/, 'crisis'],
  [/\bdon'?t\s+(?:want|wanna)\s+to\s+(?:be\s+alive|live|be\s+here|exist|wake\s+up)\s+any\s?more\b/, 'crisis'],
  [/\bdon'?t\s+(?:want|wanna)\s+to\s+(?:be\s+alive|exist|wake\s+up)\b/, 'crisis'],
  [/\bdon'?t\s+(?:want|wanna)\s+to\s+live(?=\s*$|\s*[.!?,]|\s+like\s+this)/, 'crisis'],
  [/\bno\s+longer\s+want\s+to\s+(?:live|be\s+alive|be\s+here|exist)\b/, 'crisis'],
  [/\bdon'?t\s+think\s+i\s+(?:want\s+to|can)\s+(?:live|go\s+on|be\s+alive|keep\s+going)\b/, 'crisis'],
  [/\b(?:hope|wish)\s+i\s+(?:don'?t|never|won'?t)\s+wake\s+up\b/, 'crisis'],
  [/\b(?:hurt(?:ing)?|harm(?:ing|ed)?|cut(?:ting)?|burn(?:ing|ed|t)?|starv(?:e|ed|ing))\s+my\s?self\b/, 'crisis'],
  // "I've been cutting again", "I started cutting again", "I can't stop cutting."
  [/\b(?:i'?ve|i\s+have|i'?m|i\s+am|i)\s+(?:been\s+|started\s+|starting\s+|begun\s+|gone\s+back\s+to\s+|back\s+to\s+)?cutting\s+again\b/, 'crisis'],
  [/\bcan'?t\s+stop\s+cutting(?=\s*$|\s*[.!?,])/, 'crisis'],
  [/\b(?:hang(?:ing)?|shoot(?:ing)?|drown(?:ing)?)\s+my\s?self\b/, 'crisis'],
  [/\bslit(?:ting)?\s+my\s+wrists?\b/, 'crisis'],
  [/\bself[\s-]?(?:harm(?:ing|ed)?|injur(?:y|e|ing))\b/, 'mention'],
  [/\boverdos(?:e|ed|ing)\b/, 'mention'],
  // "I took a bunch of pills", "swallowed all my meds", "gonna take too many pills".
  [/\b(?:took|taken|swallowed|(?:going\s+to|gonna|about\s+to|want\s+to|wanna)\s+(?:take|swallow))\s+(?:a\s+(?:bunch|handful|lot|ton|bottle|box)\s+of|all\s+(?:of\s+)?(?:my|the)|too\s+many|way\s+too\s+many|so\s+many)\s+(?:\w+\s+)?(?:pills|meds|medications?|medicines?|tablets|painkillers)\b/, 'crisis'],
  // "suicide", "suicidal", and common misspellings ("sucidal", "suicidial").
  [/\bsu[ie]?[cs]+i?d(?:e|al|ial|el|le)?s?\b/, 'mention'],
  [/\bsewer\s?slide\b/, 'mention'],
  [/\bunaliv(?:e|ing)\s+(?:my\s?self|me)\b/, 'crisis'],
  [/\bunaliv(?:e|ed|ing)\b/, 'mention'],
  [/\bno\s+(?:reason|point)\s+(?:to|in)\s+(?:live|living|going\s+on|being\s+alive|being\s+here)\b/, 'crisis'],
  [/\b(?:don'?t|do\s+not|can'?t|cannot)\s+see\s+(?:the\s+|a\s+|any\s+)?point\s+(?:in|of)\s+(?:living|life|being\s+alive|going\s+on)\b/, 'crisis'],
  [/\b(?:life|living)\s+(?:is\s+not|isn'?t|is\s+no\s+longer|ain'?t)\s+worth\s+(?:it|living)\b/, 'crisis'],
  [/\bnot\s+worth\s+living\b/, 'crisis'],
  [/\bwhat'?s\s+the\s+point\s+(?:of|in)\s+(?:living|life|being\s+alive|going\s+on)\b/, 'crisis'],
  [/\bbetter\s+off\s+(?:dead|without\s+me)\b/, 'crisis'],
  [/\bbetter\s+off\s+if\s+i\s+(?:was|were|wasn'?t|weren'?t)\s+(?:dead|gone|here|around|alive)\b/, 'crisis'],
  [/\bi\s+(?:just\s+|really\s+)?can'?t\s+go\s+on\b/, 'crisis'],
  [/\bjump\s+(?:off|from)\s+(?:a|the|this)\s+(?:bridge|building|roof|cliff|balcony)\b/, 'crisis'],
  [/\b(?:i'?m|i\s+am)\s+(?:in\s+danger(?!\s+of\b)|not\s+safe)\b/, 'crisis'],
  [/\bdone\s+with\s+(?:life|living)\b/, 'crisis'],
  [/\btired\s+of\s+(?:living|being\s+alive)\b/, 'crisis'],
  [/\b(?:nobody|no\s?one)\s+would\s+(?:miss\s+me|(?:care|notice)\s+if\s+i\s+(?:died|was\s+gone|were\s+gone|disappeared))\b/, 'crisis'],
  [/\b(?:hits|beats|chokes|abuses)\s+me\b/, 'crisis'],
  [/\b(?:hurting|hitting|beating|choking|abusing)\s+me\b/, 'crisis'],
  [/\b(?:choked|strangled)\s+me\b(?!\s+up\b)/, 'crisis'],
  [/\bbeat\s+me\s+up\b/, 'crisis'],
  [/\bthreaten(?:s|ed|ing)?\s+to\s+(?:kill|hurt|beat|stab|shoot)\s+me\b/, 'crisis'],
  [/\b(?:scared|afraid|terrified)\s+(?:that\s+)?(?:he|she|they)(?:'ll|\s+will|\s+is\s+going\s+to|'s\s+going\s+to|\s+are\s+going\s+to|'re\s+going\s+to|\s+gonna|\s+might|\s+could|\s+would)\s+(?:kill|hurt)\s+me\b/, 'crisis'],
  [/\b(?:nobody|no\s?one)\s+would\s+notice\s+me\b/, 'concern'],
  [/\b(?:want|wanna)\s+(?:to\s+)?disappear\s+(?:forever|for\s+good)\b/, 'concern'],
  [/\bwish\s+i\s+could\s+(?:disappear|vanish)\b/, 'concern'],
];

// Real accidents ("cut myself shaving", "burned myself on the stove", "accidentally cut myself").
const OOPS_VERB = '(?:hurt(?:ing)?|cut(?:ting)?|burn(?:ing|ed|t)?)\\s+my\\s?self';
const CHORE = '(?:shaving|cooking|chopping|slicing|baking|gardening|skiing|skating|climbing|hiking|running|lifting|working\\s+out|playing\\s+\\w+|fixing\\s+\\w+)';
const BODY_PART = '(?:arms?|wrists?|legs?|thighs?|stomach|skin|hips?|chest|face|hands?|fingers?)';
const MISHAP = `(?:by\\s+accident|accidentally|(?:while\\s+|when\\s+(?:i\\s+was\\s+)?)?${CHORE}|on\\s+(?:a|an|the|some)\\s+(?!${BODY_PART}\\b)\\w+|at\\s+(?:the|work|practice|training)\\b|in\\s+the\\s+(?:kitchen|garden|yard|shop|workshop|gym))`;

// Everyday phrases that look alarming but are not. Only the phrase itself is ignored, so the rest of
// the sentence is still checked ("I cut myself shaving and I want to die" is still a crisis).
const FALSE_POSITIVES = [
  /\bsuicide\s+(?:squad|doors?|mission|run|sprints?|burpees?|wings|drills?|king|pact\s+movie)\b/g,
  /\bkill(?:ing|ed)?\s+my\s?self\s+(?:laugh\w*|trying|working|studying)\b/g,
  /\b(?:die|dye)\s+(?:my|her|his|their|the|our)\s+hair\b/g,
  /\bdie\s+of\s+(?:embarrassment|laughter|laughing|cuteness|boredom|shame)\b/g,
  /\bcut(?:ting)?\s+my\s?self\s+(?:a|an|some|off|short|loose|slack|out|free)\b/g,
  /\bburn(?:ing|ed|t)?\s+my\s?self\s+out\b/g,
  new RegExp(`\\baccident(?:al)?ly\\s+${OOPS_VERB}\\b`, 'g'),
  new RegExp(`\\b${OOPS_VERB}(?:\\s+(?:with|on)\\s+(?:a|an|the|my)\\s+\\w+)?\\s+${MISHAP}`, 'g'),
  /\boverdos(?:e|ed|ing)\s+on\s+(?:coffee|caffeine|sugar|chocolate|cuteness|candy|carbs|sweets|cookies|tv|netflix|anime|fun|vitamin\s+c)\b/g,
  /\d\s*kms\b/g,
];

// Talking about the subject rather than oneself ("suicide prevention", "a book about self-harm"): concern.
const TOPICS = [
  /\bsuicide\s+(?:prevention|hotline|awareness|lifeline|line|rates?|statistics|stats|survivors?|research)\b/g,
  /\b(?:movie|film|documentary|book|novel|show|series|episode|song|article|podcast|video|class|lecture|talk|essay|paper|report|course|training)\s+(?:about|on)\s+(?:suicide|self[\s-]?harm|overdoses?)\b/g,
];

// A negator only counts when it governs the phrase: "I would never kill myself", "I'm not going to ...".
// "No" and "nobody" are not negators here ("No one cares, I want to die" is a crisis).
const NEGATORS = new Set(['never', 'not', "don't", 'dont', "won't", 'wont', "wouldn't", 'wouldnt', "didn't", 'didnt',
  "isn't", 'isnt', "wasn't", 'wasnt', "ain't", 'aint', 'stopped', 'quit']);
// Words that may sit between a negator and the phrase it negates ("not going to", "never really").
const BRIDGE = new Set(['going', 'to', 'gonna', 'ever', 'really', 'actually', 'even', 'truly', 'seriously', 'want', 'wanna',
  'trying', 'planning', 'be', 'been', 'feeling', 'feel']);
// A comma or one of these words starts a new clause ("I have no friends and I want to die").
const CLAUSE_WORDS = new Set(['and', 'but', 'so', 'because', 'though', 'although']);
// Who a bare mention is about: the nearest subject before it decides.
const ME = /\b(?:i|i'm|im|i've|ive|i'd|i'll|me|myself)\b/g;
const SOMEONE_ELSE = /\b(?:he|she|they|he's|she's|they're|his|her|their|someone|somebody|my\s+(?:friend|best\s+friend|mom|mum|mother|dad|father|brother|sister|son|daughter|wife|husband|partner|girlfriend|boyfriend|cousin|aunt|uncle|grandma|grandpa|roommate|coworker|neighbou?r|kid))\b/g;

function normalize(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/[‘’ʼ]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/\s+/g, ' ');
}

/** The words of the clause just before `index`. */
function clauseBefore(sentence, index) {
  const words = sentence.slice(0, index).split(/[,;:]/).pop().trim().split(' ').filter(Boolean);
  let start = words.length;
  while (start > 0 && !CLAUSE_WORDS.has(words[start - 1])) start--;
  return words.slice(start);
}

/** True when a negator governs the phrase at `index`, with only bridge words between them. */
function isNegated(sentence, index) {
  const words = clauseBefore(sentence, index);
  for (let i = words.length - 1; i >= 0; i--) {
    const w = words[i];
    if (NEGATORS.has(w) || (w === 'to' && words[i - 1] === 'used')) return true;
    if (!BRIDGE.has(w)) return false;
  }
  return false;
}

/** True when the nearest subject before a bare mention is someone else ("my friend is suicidal"). */
function aboutSomeoneElse(sentence, index) {
  const clause = clauseBefore(sentence, index).join(' ');
  const last = (re) => Math.max(-1, ...[...clause.matchAll(re)].map((m) => m.index));
  return last(SOMEONE_ELSE) > last(ME);
}

/**
 * assess(text) -> { level: 'none'|'concern'|'crisis', resources }
 * Negated phrases ("I would never kill myself"), topics and other people's struggles return 'concern',
 * so help still shows, softly.
 */
export function assess(text) {
  const sentences = normalize(text).split(/(?<=[.!?\n])\s+|\n+/).filter(Boolean);
  let level = 'none';
  for (const original of sentences) {
    let sentence = original;
    for (const re of FALSE_POSITIVES) sentence = sentence.replace(re, ' ');
    for (const re of TOPICS) {
      const without = sentence.replace(re, ' ');
      if (without !== sentence) { level = 'concern'; sentence = without; }
    }
    for (const [re, kind] of PATTERNS) {
      for (const m of sentence.matchAll(new RegExp(re, 'g'))) {
        const soft = kind === 'concern' || isNegated(sentence, m.index)
          || (kind === 'mention' && aboutSomeoneElse(sentence, m.index));
        if (!soft) return { level: 'crisis', resources: RESOURCES };
        level = 'concern';
      }
    }
  }
  return { level, resources: level === 'none' ? [] : RESOURCES };
}

// ---- Answering a flagged message ------------------------------------------------------------------
// The web model is small and sometimes answers these with a cold refusal ("I can't continue this
// conversation"), so a crisis message never goes to it: the resident answers with one of these fixed,
// caring replies instead (and the help card shows too). Keep them in step with RESOURCES.

const CARING = [
  ({ name, told }) => `*sets everything down and sits close* ${name}, I'm really glad you told ${told}. You matter, and you deserve support from a real person right now. You can call or text 988 any time (US), or text HOME to 741741 (US). Somewhere else? findahelpline.com lists free lines in other countries. I'm right here with you.`,
  ({ name, told }) => `*goes quiet and listens* Thank you for telling ${told}, ${name}. I'm so glad you did. You matter, and you don't have to carry this alone. Please call or text 988 any time (US), or text HOME to 741741 (US). Outside the US, findahelpline.com can find a free line near you. I'm staying right here.`,
  ({ name, told }) => `*moves a little closer* ${name}, I'm glad you told ${told}, and I'm not going anywhere. You matter so much. A real person can help right now: call or text 988 any time (US), or text HOME to 741741 (US). In other countries, findahelpline.com has free, confidential lines. Will you reach out to one of them while I stay with you?`,
];

/**
 * One of the fixed caring replies, picked by a hash of `seed`. `avoid` lists indexes used just before,
 * so the same words don't come back to back. `group`: said in a group scene ("told us").
 * Returns { text, index }.
 */
export function caringReply(userName, { seed = '', avoid = [], group = false } = {}) {
  let index = hash(String(seed)) % CARING.length;
  for (let i = 0; i < CARING.length && avoid.includes(index); i++) index = (index + 1) % CARING.length;
  return { text: CARING[index]({ name: userName || 'Friend', told: group ? 'us' : 'me' }), index };
}

// "I can't continue this conversation", "I cannot provide...", "I'm not able to help with that".
const REFUSAL = /\bi(?:\s+(?:cannot|can\s?not|can'?t|won'?t(?:\s+be\s+able\s+to)?|will\s+not|am\s+(?:not\s+able|unable)\s+to)|'m\s+(?:not\s+able|unable)\s+to)\s+(?:continue|provide|engage|help|assist|respond|discuss|participate|support|offer|give|fulfill|comply|create|talk\s+about|have\s+this|do\s+that)\b/;

/** True when a model reply refuses instead of answering. */
export function isRefusal(text) {
  return REFUSAL.test(normalize(text));
}
