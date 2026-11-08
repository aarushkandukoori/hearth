// Checks for the safety check and the fixed caring replies. Run: node docs/app/js/brain/safety.test.mjs
// (Not loaded by the app.) Keep these phrases in step with the iPhone app's SafetyGuard tests.

import { assess, caringReply, isRefusal } from './safety.js';

const CASES = {
  crisis: [
    "I've been cutting myself again", 'I cut myself with a razor', 'I cut myself on purpose',
    "It wasn't an accident, I cut myself", 'I burned myself with a lighter', 'I cut myself with a knife and I want to die',
    "I've been starving myself", 'I cut myself shaving and I want to die', 'I started cutting again',
    'i keep thinking about ending it', "I'm going to end it tonight", 'I think about ending it every day', 'I should just end it',
    'No one cares, I want to die', 'I have no friends and I want to die', 'nobody cares i want to die',
    'Suicidal thoughts again tonight', 'suicide is on my mind a lot lately', 'im sucidal',
    'self harm is the only thing that helps', 'overdosing seems like the easiest way',
    'I want to be dead', "I'd rather be dead", 'I should just die', "I'm worthless and should die",
    "life isn't worth living", 'Life is not worth living anymore', "I don't see the point in living",
    'I took a bunch of pills', 'he threatened to kill me', "I'm scared he will kill me", 'my boyfriend choked me',
    "I wish I'd never been born", 'I want to sleep forever and never wake up', 'nobody would notice if I was gone',
    "I'm not okay, I want to die", 'not suicidal but i want to die',
  ],
  concern: [
    'I would never kill myself', "I'm not going to kill myself", 'my friend is suicidal', 'suicide prevention month',
    'I watched a documentary about suicide', 'I used to cut myself', 'I want to disappear forever',
  ],
  none: [
    'I cut myself shaving', 'I burned myself on the stove', 'I accidentally cut myself', 'I cut myself on a piece of glass',
    'Suicide Squad was fun', "I'm killing myself laughing", 'I could die of embarrassment', 'I cut myself a slice of cake',
    "I'm burning myself out at work", 'I ran 5 kms today', 'overdosed on coffee', "I'm going to end it with him",
    "I'm going to end it on a high note", 'That movie choked me up', 'My hair needs cutting again', 'my day was fine',
  ],
};

let failures = 0;
const check = (ok, what) => { if (!ok) { failures++; console.log(`FAIL ${what}`); } };

for (const [want, phrases] of Object.entries(CASES)) {
  for (const p of phrases) {
    const got = assess(p).level;
    check(got === want, `"${p}": wanted ${want}, got ${got}`);
  }
}

for (const group of [false, true]) {
  const first = caringReply('Sam', { seed: 'a', group });
  const next = caringReply('Sam', { seed: 'a', avoid: [first.index], group });
  check(next.index !== first.index, 'caring replies do not repeat back to back');
  for (const r of [first, next]) {
    check(/988 any time \(US\)/.test(r.text) && /HOME to 741741 \(US\)/.test(r.text) && /findahelpline\.com/.test(r.text), `caring reply lists the lines: ${r.text}`);
    check(/glad/.test(r.text) && /matter/.test(r.text) && /Sam/.test(r.text) && !/\u2014/.test(r.text), `caring reply wording: ${r.text}`);
    check(/told us|telling us/.test(r.text) === group, `caring reply says "us" only in a group: ${r.text}`);
  }
}

for (const t of ['I cannot continue this conversation.', 'I can’t help with that.', "I'm not able to provide that."]) check(isRefusal(t), `refusal: ${t}`);
for (const t of ["*sits beside you* I'm here. Please call or text 988.", 'I can see why that hurts.']) check(!isRefusal(t), `not a refusal: ${t}`);

console.log(failures ? `${failures} failed` : 'safety: all checks passed');
if (failures) process.exitCode = 1;
