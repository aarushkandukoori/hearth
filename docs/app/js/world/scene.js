// A group scene at one place (#/town/:locationId): whoever is there now, plus anyone you invite, talks with
// you and with each other. The director picks who answers (at most 2 per line); "Let them talk" plays 4
// lines of banter. Each place keeps one scene conversation in IndexedDB.

import { h, avatar, attachImage, artURL, isMissingArt, modal, toast, menu, confirm, emptyState, richText } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { messageRow, typingDots } from '../ui/messages.js';
import { openModelDialog } from '../ui/model-dialog.js';
import { world, allCharacters, getCharacter, getLocation, settings, userName, whereNow, subscribe } from '../data.js';
import { makeMessage, textOf, extraOf, conversationSummaries, getConversation, saveConversation, deleteConversation } from '../chats.js';
import { engine } from '../engine/engine.js';
import { composeScene, asksForPicture, MAX_MESSAGE_CHARS } from '../brain/prompts.js';
import { cleanReply, streamingPreview } from '../brain/parse.js';
import { assess, RESOURCES, COPY, caringReply, isRefusal } from '../brain/safety.js';
import { dayPart, whoIsAt, locationOf, nextSpeakers, banterOrder, namedIn } from '../brain/director.js';
import { extractFacts, remember } from '../brain/memory.js';
import * as voice from '../media/voice.js';
import { pictureFor } from '../media/photos.js';
import { navigate, canGoBack } from '../router.js';
import { uid, capitalize, prefersReducedMotion, sleep } from '../util.js';
import { recentEventTexts } from './news.js';
import { PART_INFO } from './town.js';
import { listNames } from './map.js';

const theName = (loc) => loc.name.replace(/^The\s/, 'the ');
const SAFETY_RANK = { none: 0, concern: 1, crisis: 2 };

/** When the current part of the day ends (guests you invite stay until then). */
export function partEndsAt(date = new Date()) {
  const at = (hour, addDays = 0) => new Date(date.getFullYear(), date.getMonth(), date.getDate() + addDays, hour).getTime();
  const hr = date.getHours();
  if (hr >= 5 && hr < 11) return at(11);
  if (hr >= 11 && hr < 17) return at(17);
  if (hr >= 17 && hr < 22) return at(22);
  return hr >= 22 ? at(5, 1) : at(5);
}

/** Who is in the scene now: residents scheduled here this part of the day, then guests who haven't left. */
export function presentAt(loc, conv, now = new Date()) {
  const out = whoIsAt(loc.id, dayPart(now), allCharacters());
  for (const g of conv.guests || []) {
    if (!(g.until > now.getTime()) || out.some((c) => c.id === g.id)) continue;
    const c = getCharacter(g.id);
    if (c) out.push(c);
  }
  return out;
}

async function findScene(locationID) {
  const found = (await conversationSummaries()).find((c) => c.kind === 'scene' && c.locationID === locationID);
  return (found && (await getConversation(found.id))) || null;
}

function newScene(loc) {
  const now = Date.now();
  return {
    id: uid(), kind: 'scene', locationID: loc.id, participantIDs: [], title: loc.name,
    guests: [], lastAddressedID: null, messages: [], createdAt: now, updatedAt: now,
  };
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = h('textarea', { style: { position: 'fixed', opacity: '0' } }, text);
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch { /* nothing else to try */ }
    ta.remove();
  }
}

/** The same gentle resources card the 1:1 chat shows. */
function safetyCard(level, onHide) {
  const copy = COPY[level] || COPY.concern;
  return h('section', { class: `safety-card ${level}`, role: level === 'crisis' ? 'alert' : 'status', 'aria-labelledby': 'scene-safety-title' },
    h('div', { class: 'safety-head' },
      h('span', { class: 'safety-icon', 'aria-hidden': 'true' }, icon('lifebuoy', { size: 20 })),
      h('h2', { id: 'scene-safety-title' }, copy.title),
      h('button', { class: 'icon-btn sm', type: 'button', 'aria-label': 'Hide this', onClick: onHide }, icon('x'))),
    h('p', {}, copy.body),
    h('ul', { class: 'safety-list' }, RESOURCES.map((r) => h('li', {},
      h('div', { class: 'safety-res' }, h('strong', {}, r.title), h('span', {}, r.detail)),
      h('div', { class: 'safety-actions' }, r.actions.map((a) => h('a', {
        class: 'btn btn-secondary btn-sm', href: a.href,
        target: a.external ? '_blank' : null, rel: a.external ? 'noopener noreferrer' : null,
      }, a.label)))))),
    h('p', { class: 'safety-foot' }, 'If you are in immediate danger, call your local emergency number.'));
}

function notFound(ctx) {
  ctx.setTitle('Not found');
  return h('div', { class: 'page narrow' }, emptyState({
    iconName: 'map', title: "That place isn't on the map",
    body: 'It may have been a different town. Lantern Bay has plenty of other spots to visit.',
    action: h('a', { class: 'btn btn-secondary', href: '#/town' }, 'Back to the map'),
  }));
}

export async function renderScene(ctx) {
  const loc = getLocation(ctx.params.locationId);
  if (!loc) return notFound(ctx);
  ctx.setTitle(loc.name);
  let conv = await findScene(loc.id);
  if (ctx.signal.aborted) return null;
  let saved = !!conv;
  if (!conv) conv = newScene(loc);

  let present = presentAt(loc, conv);
  let generating = false;
  let stopRequested = false;
  let streamingID = null;
  let lastLevel = 'none';      // safety level of the newest line you said; follow-ups stay careful while set
  let safetyLevel = 'none';    // the help card only ever gets more urgent (until it is hidden)
  let flaggedThisVisit = false; // a line in this visit was flagged: only pictures you ask for from now on
  const colors = loc.art?.colors || ['#2A211B', '#FF8A4C'];
  const asset = loc.art?.asset || `loc-${loc.id}`;
  const artSrc = isMissingArt(artURL(asset)) ? null : artURL(asset);

  // ---- Layout ----------------------------------------------------------------------------------
  const thumb = h('span', { class: 'scene-thumb', style: { '--pa': colors[0], '--pb': colors[1] || colors[0] } },
    h('span', { 'aria-hidden': 'true' }, loc.emoji || loc.art?.emoji || '📍'));
  if (artSrc) attachImage(thumb, artSrc, { alt: '' });
  const headSub = h('span', { class: 'chat-head-by' });
  const headPeople = h('div', { class: 'scene-head-people', 'aria-hidden': 'true' });
  const engineSlot = h('div', { class: 'chat-engine' });
  const menuBtn = h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Scene options', 'aria-haspopup': 'menu' }, icon('more'));
  const backBtn = h('button', {
    class: 'icon-btn scene-back', type: 'button', 'aria-label': 'Back to the map', title: 'Back to the map',
    onClick: () => (canGoBack() ? history.back() : navigate('#/town')),
  }, icon('arrow-left'));
  const header = h('header', { class: 'chat-header scene-header' },
    backBtn,
    h('div', { class: 'scene-head-who' }, thumb,
      h('span', { class: 'chat-head-text' }, h('span', { class: 'chat-head-name' }, loc.name), headSub)),
    h('div', { class: 'grow' }),
    headPeople, engineSlot, menuBtn);

  const heroWhen = h('p', { class: 'scene-hero-when' });
  const hero = h('div', { class: 'scene-hero', style: { '--pa': colors[0], '--pb': colors[1] || colors[0] } },
    h('span', { class: 'scene-hero-emoji', 'aria-hidden': 'true' }, loc.emoji || '📍'),
    h('div', { class: 'scene-hero-shade' }),
    h('div', { class: 'scene-hero-text' },
      heroWhen,
      h('h1', { class: 'scene-hero-name serif' }, loc.name),
      loc.ambience ? h('p', { class: 'scene-hero-ambience' }, loc.ambience) : null));
  if (artSrc) attachImage(hero, artSrc, { alt: '' });
  const hereList = h('ul', { class: 'scene-here', 'aria-label': 'Here now' });
  const tip = h('p', { class: 'scene-tip' });

  const list = h('div', { class: 'chat-list-msgs', role: 'region', 'aria-label': `Conversation at ${loc.name}` });
  const announcer = h('div', { class: 'sr-only', 'aria-live': 'polite' });
  const scroller = h('div', { class: 'chat-scroll' },
    h('div', { class: 'chat-inner scene-inner' }, hero, hereList, tip, list));

  const safetySlot = h('div', { class: 'safety-slot' });
  const talkBtn = h('button', { class: 'btn btn-secondary btn-sm', type: 'button' }, icon('users', { size: 16 }), 'Let them talk');
  const inviteBtn = h('button', { class: 'btn btn-ghost btn-sm', type: 'button' }, icon('plus', { size: 16 }), 'Invite someone');
  const input = h('textarea', {
    class: 'composer-input', rows: '1', placeholder: 'Say something to everyone...', 'aria-label': 'Message everyone here',
    enterkeyhint: 'send', autocomplete: 'off', maxlength: String(MAX_MESSAGE_CHARS),
  });
  const sendBtn = h('button', { class: 'composer-send', type: 'button', 'aria-label': 'Send' }, icon('arrow-up', { size: 20 }));
  const composer = h('form', { class: 'composer scene-composer', onSubmit: (e) => { e.preventDefault(); send(); } }, input, sendBtn);
  const bottom = h('div', { class: 'chat-bottom' },
    h('div', { class: 'chat-bottom-inner' },
      safetySlot,
      h('div', { class: 'scene-actions' }, talkBtn, inviteBtn),
      composer,
      h('p', { class: 'chat-disclosure' }, 'Hearth characters are AI. What they say is made up.')));

  const page = h('div', { class: 'chat-page scene-page', style: { '--accent-char': colors[1] || 'var(--accent)' } },
    header, scroller, bottom, announcer);
  // Full-height layout on phones (the top bar hides, like in 1:1 chats) while this page is open.
  document.documentElement.classList.add('scene-open');
  ctx.signal.addEventListener('abort', () => document.documentElement.classList.remove('scene-open'));

  // ---- Helpers ---------------------------------------------------------------------------------
  const nearBottom = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 140;
  const scrollToEnd = (smooth = false) => {
    scroller.scrollTo({ top: scroller.scrollHeight, behavior: smooth && !prefersReducedMotion() ? 'smooth' : 'auto' });
  };

  async function persist({ touch = true } = {}) {
    await saveConversation(conv, { touch });
    saved = true;
  }

  function paintPresent() {
    const part = dayPart();
    headSub.textContent = present.length ? `${present.length} here now` : 'Nobody here right now';
    heroWhen.textContent = `${PART_INFO[part].emoji} ${PART_INFO[part].label} in ${world()?.name || 'Lantern Bay'}`;
    const shown = present.slice(0, 4);
    headPeople.replaceChildren(...shown.map((c) => avatar(c, { size: 28 })));
    if (present.length > shown.length) headPeople.append(h('span', { class: 'scene-head-more' }, `+${present.length - shown.length}`));
    const guestIDs = new Set((conv.guests || []).map((g) => g.id));
    hereList.replaceChildren(...(present.length ? present.map((c) => {
      const slot = locationOf(c, part, world());
      const doing = slot?.locationID === loc.id ? capitalize(slot.activity) : (guestIDs.has(c.id) ? 'Visiting, at your invitation' : 'Stopping by');
      return h('li', {},
        h('a', { class: 'scene-here-row', href: `#/c/${encodeURIComponent(c.id)}` },
          avatar(c, { size: 38 }),
          h('span', { class: 'scene-here-text' }, h('strong', {}, c.name), h('span', {}, doing))));
    }) : [h('li', { class: 'scene-here-empty' }, 'Nobody is here right now. Invite someone to keep you company.')]));
    tip.hidden = conv.messages.length > 0;
    tip.textContent = present.length > 1
      ? `Say hello to ${listNames(present)}. Use a name to talk to someone, or tap "Let them talk" to listen in.`
      : present.length === 1 ? `Say hello to ${present[0].name}, or invite someone else to join you.` : '';
    syncControls();
  }

  function syncControls() {
    talkBtn.disabled = generating || present.length < 2;
    talkBtn.title = present.length < 2 ? 'It takes two to chat. Invite someone first.' : '';
    inviteBtn.disabled = generating;
    sendBtn.disabled = !generating && (!input.value.trim() || present.length === 0);
    input.placeholder = present.length ? 'Say something to everyone...' : 'Invite someone to start talking';
  }

  function setBusy(on) {
    generating = on;
    sendBtn.classList.toggle('stop', on);
    sendBtn.replaceChildren(icon(on ? 'stop' : 'arrow-up', { size: on ? 16 : 20 }));
    sendBtn.setAttribute('aria-label', on ? 'Stop' : 'Send');
    syncControls();
  }

  // ---- Messages --------------------------------------------------------------------------------
  function messageMenu(m, speaker) {
    const btn = h('button', { class: 'icon-btn sm msg-more', type: 'button', 'aria-label': 'Message options', 'aria-haspopup': 'menu', dataset: { focus: 'menu' } }, icon('more'));
    btn.addEventListener('click', () => {
      const text = textOf(m);
      menu(btn, [
        { label: 'Copy', icon: 'copy', onClick: async () => { await copyText(text); toast('Copied.'); } },
        speaker ? {
          label: 'Play aloud', icon: 'volume', disabled: !voice.hasLocalVoice() || !text.trim(),
          onClick: () => voice.speak(text, speaker, { voiceURI: settings().voiceURI }),
        } : null,
        { separator: true },
        { label: 'Delete', icon: 'trash', danger: true, disabled: generating, onClick: () => removeMessage(m) },
      ], { label: 'Message options' });
    });
    return btn;
  }

  async function removeMessage(m) {
    const ok = await confirm({ title: 'Delete this message?', message: "It will be removed from this scene. This can't be undone.", confirmLabel: 'Delete' });
    if (!ok) return;
    conv.messages = conv.messages.filter((x) => x.id !== m.id);
    await persist({ touch: false });
    paint({ keepScroll: true });
  }

  function rowFor(m) {
    if (m.role === 'narrator') return h('div', { class: 'scene-note', dataset: { id: m.id } }, richText(textOf(m), { className: 'rich' }));
    const isUser = m.role === 'user';
    const speaker = isUser ? null : getCharacter(m.speakerID);
    const isStreaming = m.id === streamingID;
    const demo = !isUser && extraOf(m).demo ? h('span', { class: 'badge demo-badge', title: 'A canned demo line, not the model' }, 'Demo') : null;
    const row = messageRow(m, {
      character: speaker, isUser, badge: demo, voiceURI: settings().voiceURI,
      menuButton: isStreaming ? null : messageMenu(m, speaker),
    });
    if (isStreaming) {
      row.classList.add('streaming');
      row.setAttribute('aria-busy', 'true');
      const live = h('div', { class: 'msg-body stream-body' });
      row.querySelector('.msg-body, .voice-note, .rich')?.replaceWith(live);
      row.__live = live;
    }
    return row;
  }

  const shownIDs = new Set();
  let firstPaint = true;
  let streamText = '';
  function paint({ keepScroll = false } = {}) {
    const stick = keepScroll ? false : nearBottom();
    // The rows are rebuilt, so a focused control gets focus back on the same message afterwards.
    const active = list.contains(document.activeElement) ? document.activeElement : null;
    const want = active?.dataset.focus ? { id: active.closest('[data-id]')?.dataset.id, key: active.dataset.focus } : null;
    list.replaceChildren(...conv.messages.map((m) => {
      const row = rowFor(m);
      if (!firstPaint && !shownIDs.has(m.id)) row.classList.add('enter');
      shownIDs.add(m.id);
      return row;
    }));
    firstPaint = false;
    tip.hidden = conv.messages.length > 0;
    if (streamingID) updateStream(null);
    if (want?.id) list.querySelector(`[data-id="${CSS.escape(want.id)}"] [data-focus="${want.key}"]`)?.focus({ preventScroll: true });
    if (stick) scrollToEnd();
  }

  function updateStream(full) {
    if (full != null) streamText = full;
    const row = list.querySelector(`[data-id="${CSS.escape(streamingID || '')}"]`);
    const live = row?.__live;
    if (!live) return;
    const m = conv.messages.find((x) => x.id === streamingID);
    const name = getCharacter(m?.speakerID)?.name || 'Someone';
    const stick = nearBottom();
    const preview = streamingPreview(streamText, { name });
    live.replaceChildren(preview.trim() ? richText(preview, { className: 'rich msg-text' }) : typingDots(`${name} is typing`));
    if (stick) scrollToEnd();
  }

  // ---- Talking ---------------------------------------------------------------------------------
  /** The fixed caring reply, skipping the one said just before so the same words don't come back to back. */
  function caringFor(m, history) {
    const prev = [...history].reverse().find((x) => x.role === 'character');
    return caringReply(userName(), { seed: `${conv.id}|${m.id}`, avoid: [extraOf(prev).caring].filter(Number.isInteger), group: true });
  }

  /**
   * One line from `c`, streamed into a new message. `level`: the safety level of the line being answered.
   * A crisis line never goes to the model (it can answer with a cold refusal) and demo replies can't read
   * the room, so both get a fixed caring reply with the crisis lines.
   */
  async function speakLine(c, { level = 'none' } = {}) {
    const flagged = level !== 'none';
    if (flagged) flaggedThisVisit = true;
    const caring = level === 'crisis' || (flagged && engine.isDemo);
    const m = makeMessage({ role: 'character', speakerID: c.id, text: '' });
    const history = conv.messages.slice();
    conv.messages.push(m);
    if (!conv.participantIDs.includes(c.id)) conv.participantIDs.push(c.id);
    streamingID = m.id;
    streamText = '';
    paint();
    scrollToEnd(true);

    const s = settings();
    const me = userName();
    const others = present.filter((x) => x.id !== c.id);
    // Lines said in the last few turns; one that comes back word for word is written again once.
    const recent = new Set(history.slice(-8).filter((x) => x.role === 'character').map((x) => textOf(x).trim().toLowerCase()));
    let result = { text: '', stats: { engine: 'demo', stoppedBy: 'error' } };
    let cleaned = { text: '', photo: null };
    if (caring) await sleep(500); // a moment of "typing" first
    for (let attempt = 0; attempt < 2 && !caring; attempt++) {
      try {
        const events = await recentEventTexts();
        const { turns, assistantPrefix, stop } = composeScene({
          location: loc, world: world(), present, persona: { name: me, about: s.persona?.about || '' },
          messages: history, events, speaker: c, flagged,
        });
        result = await engine.generate({
          key: `scene-${conv.id}`, turns, assistantPrefix, stop, maxTokens: 120,
          sampling: { temperature: 0.85, topP: 0.95, repeatPenalty: 1.1, seed: Math.floor(Math.random() * 2 ** 31) },
        }, (_delta, full) => updateStream(full));
      } catch (err) {
        console.error('[hearth] scene line failed:', err?.name || 'Error');
        if (!flagged) toast("Couldn't write a line just now. Try again in a moment.", { tone: 'danger' });
        stopRequested = true;
      }
      cleaned = cleanReply(result.text, {
        name: c.name, userName: me, otherNames: others.map((x) => x.name), cutByLength: result.stats?.stoppedBy === 'length',
      });
      const repeated = cleaned.text && recent.has(cleaned.text.trim().toLowerCase());
      if (!repeated || stopRequested || result.stats?.stoppedBy === 'cancelled' || ctx.signal.aborted) break;
      updateStream('');
    }
    // A flagged line always gets an answer with care: the fixed reply when the model wasn't asked,
    // refused ("I can't continue this conversation") or failed.
    let caringIndex = null;
    if (caring || (flagged && (isRefusal(cleaned.text) || result.stats?.stoppedBy === 'error'))) {
      const fixed = caringFor(m, history);
      cleaned = { text: fixed.text, photo: null };
      caringIndex = fixed.index;
      result = { text: fixed.text, stats: { engine: 'safety', stoppedBy: 'eos' } };
    }

    // Never a picture in answer to a flagged line, and for the rest of that visit only ones you ask for
    // (the model can copy a "[photo: ...]" line from the history on its own).
    const lastUser = [...history].reverse().find((x) => x.role === 'user');
    const asked = asksForPicture(lastUser ? textOf(lastUser) : '');
    const pictures = s.picturesEnabled !== false && !flagged && (asked || !flaggedThisVisit);
    if (!pictures) cleaned = { ...cleaned, photo: null };
    if (!cleaned.text && !cleaned.photo) {
      conv.messages = conv.messages.filter((x) => x.id !== m.id);
    } else {
      m.variants[0] = cleaned.text;
      const extra = { stats: result.stats, demo: result.stats?.engine === 'demo' };
      if (caringIndex != null) extra.caring = caringIndex;
      if (cleaned.photo) {
        const pic = pictureFor(cleaned.photo, { world: world(), character: c, locationID: loc.id });
        extra.attachment = { kind: 'picture', caption: cleaned.photo, src: pic.src, postcard: pic.postcard };
      }
      m.extras[0] = extra;
      announcer.textContent = `${c.name}: ${cleaned.text.replace(/\*/g, '')}`;
    }
    if (result.stats?.stoppedBy === 'cancelled') stopRequested = true;
    streamingID = null;
    await persist();
    paint();
  }

  async function runSpeakers(ids, { level = 'none' } = {}) {
    setBusy(true);
    stopRequested = false;
    for (const id of ids) {
      if (stopRequested || ctx.signal.aborted) break;
      const c = present.find((x) => x.id === id) || getCharacter(id);
      if (c) await speakLine(c, { level });
    }
    setBusy(false);
    if (!ctx.signal.aborted && !matchMedia('(pointer: coarse)').matches) input.focus({ preventScroll: true });
  }

  function stop() {
    stopRequested = true;
    engine.cancel();
  }

  async function send() {
    if (generating) { stop(); return; }
    const text = input.value.trim();
    if (!text) return;
    present = presentAt(loc, conv);
    if (!present.length) { paintPresent(); toast('Nobody is here to hear that yet. Invite someone first.'); return; }
    input.value = '';
    autoGrow(input);
    const msg = makeMessage({ role: 'user', text });
    conv.messages.push(msg);
    const named = namedIn(text, present);
    const speakers = nextSpeakers({ text, present, messages: conv.messages, lastAddressedID: conv.lastAddressedID });
    if (named.length) conv.lastAddressedID = named[0].id;
    for (const c of present) if (!conv.participantIDs.includes(c.id)) conv.participantIDs.push(c.id);
    try {
      await persist();
    } catch (err) {
      // Not saved (storage full or closed): give the line back instead of losing it.
      console.error('[hearth] saving the scene failed:', err?.name || 'Error');
      conv.messages = conv.messages.filter((x) => x.id !== msg.id);
      input.value = text;
      autoGrow(input);
      syncControls();
      toast("Couldn't save that message. Try again in a moment.", { tone: 'danger' });
      return;
    }
    paint();
    scrollToEnd(true);

    lastLevel = assess(text).level;
    raiseSafety(lastLevel);
    // Nothing is learned from a flagged line (memory.js checks again), so it can't come up later or
    // travel to other residents through town gossip.
    if (lastLevel === 'none') {
      const facts = extractFacts(text);
      if (facts.length) {
        const share = settings().townGossip;
        Promise.all(present.map((c) => remember(c.id, facts, { source: 'auto', shareable: share, conversationID: conv.id }))).catch(() => {});
      }
    } else {
      flaggedThisVisit = true;
    }
    // After a worrying message only one friend answers, with care, instead of a chatty back-and-forth.
    await runSpeakers(lastLevel !== 'none' ? speakers.slice(0, 1) : speakers, { level: lastLevel });
  }

  /** Shows the help card; a later line can make it more urgent, never less (until it is hidden). */
  function raiseSafety(level) {
    if (SAFETY_RANK[level] <= SAFETY_RANK[safetyLevel]) return;
    safetyLevel = level;
    safetySlot.replaceChildren(safetyCard(level, () => { safetyLevel = 'none'; safetySlot.replaceChildren(); }));
  }

  /** "Get support" in the scene menu: shows the help card again (it stays as urgent as it already was). */
  function showSupport() {
    raiseSafety('concern');
    safetySlot.querySelector('.safety-card')?.scrollIntoView({ block: 'nearest' });
  }

  async function letThemTalk() {
    if (generating) return;
    present = presentAt(loc, conv);
    paintPresent();
    if (present.length < 2) { toast('It takes two to chat. Invite someone first.'); return; }
    // Right after a worrying line there is no banter: one friend checks in, with care.
    const order = banterOrder({ present, messages: conv.messages, count: 4 });
    await runSpeakers(lastLevel !== 'none' ? order.slice(0, 1) : order, { level: lastLevel });
  }

  async function invite(c) {
    if (generating) return;
    const from = whereNow(c);
    const until = partEndsAt();
    conv.guests = [...(conv.guests || []).filter((g) => g.id !== c.id && g.until > Date.now()), { id: c.id, until }];
    const fromText = from?.location && from.locationID !== loc.id ? ` from ${theName(from.location)}` : '';
    conv.messages.push(makeMessage({ role: 'narrator', text: `*${c.name} comes over${fromText} to join you.*` }));
    present = presentAt(loc, conv);
    paintPresent();
    await persist();
    paint();
    scrollToEnd(true);
    await runSpeakers([c.id], { level: lastLevel });
  }

  function openInvite() {
    if (generating) return;
    present = presentAt(loc, conv);
    const here = new Set(present.map((c) => c.id));
    const others = allCharacters().filter((c) => !here.has(c.id));
    let handle = null;
    const rows = others.map((c) => {
      const w = whereNow(c);
      return h('li', {},
        h('button', { class: 'invite-row', type: 'button', onClick: () => { handle?.close(); invite(c); } },
          avatar(c, { size: 42 }),
          h('span', { class: 'invite-text' },
            h('strong', {}, c.name),
            h('span', { class: 'ellipsis' }, w?.location ? `At ${theName(w.location)} now` : (c.tagline || 'Around town'))),
          h('span', { class: 'invite-go' }, 'Invite')));
    });
    handle = modal({
      title: `Invite someone to ${theName(loc)}`,
      size: 'md',
      body: h('div', { class: 'stack' },
        h('p', { class: 'text-2' }, `They'll stay until the ${dayPart()} is over.`),
        rows.length ? h('ul', { class: 'invite-list' }, rows) : h('p', { class: 'muted' }, 'Everyone in town is already here.')),
    });
  }

  async function startOver() {
    const ok = await confirm({
      title: 'Start this scene over?',
      message: `The conversation at ${theName(loc)}, and what everyone learned from it, will be cleared from this browser. This can't be undone.`,
      confirmLabel: 'Start over',
    });
    if (!ok) return;
    if (saved) await deleteConversation(conv.id);
    conv = newScene(loc);
    saved = false;
    lastLevel = 'none';
    safetyLevel = 'none';
    safetySlot.replaceChildren();
    present = presentAt(loc, conv);
    paintPresent();
    paint();
    toast('A fresh start.');
  }

  // ---- Composer, menu and engine status ----------------------------------------------------------
  function autoGrow(el, max = 200) {
    el.style.height = 'auto';
    el.style.height = `${Math.min(max, el.scrollHeight)}px`;
  }
  input.addEventListener('input', () => { autoGrow(input); syncControls(); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
    if (e.key === 'Escape' && generating) { e.preventDefault(); stop(); }
  });
  sendBtn.addEventListener('click', (e) => { e.preventDefault(); send(); });
  talkBtn.addEventListener('click', letThemTalk);
  inviteBtn.addEventListener('click', openInvite);
  menuBtn.addEventListener('click', () => {
    menu(menuBtn, [
      { label: 'Invite someone', icon: 'plus', disabled: generating, onClick: openInvite },
      { label: 'Back to the map', icon: 'map', onClick: () => navigate('#/town') },
      { label: 'Get support', icon: 'lifebuoy', onClick: showSupport },
      { separator: true },
      { label: 'Start over', icon: 'trash', danger: true, disabled: generating || !conv.messages.length, onClick: startOver },
    ], { label: 'Scene options' });
  });

  function paintEngine(s) {
    if (s.status === 'ready') {
      engineSlot.replaceChildren(h('a', { class: 'engine-pill ready', href: '#/settings?section=model', title: 'Lines come from the model running on this device' },
        h('span', { class: 'dot dot-ready', 'aria-hidden': 'true' }), 'On this device'));
    } else if (s.status === 'loading') {
      engineSlot.replaceChildren(h('button', { class: 'engine-pill loading', type: 'button', onClick: () => openModelDialog() },
        h('span', { class: 'dot dot-loading', 'aria-hidden': 'true' }), `Loading ${Math.round((s.progress?.fraction || 0) * 100)}%`));
    } else {
      engineSlot.replaceChildren(h('button', { class: 'engine-pill demo', type: 'button', onClick: () => openModelDialog(), title: 'Lines are canned demo replies' },
        h('span', { class: 'dot dot-demo', 'aria-hidden': 'true' }), 'Demo replies'));
    }
  }
  const unsubEngine = engine.subscribe(paintEngine);
  paintEngine(engine.snapshot());

  // People come and go as the day moves on.
  const tick = setInterval(() => {
    const next = presentAt(loc, conv);
    if (next.map((c) => c.id).join() !== present.map((c) => c.id).join()) { present = next; paintPresent(); }
  }, 30000);
  const unsubChars = subscribe('characters', () => { present = presentAt(loc, conv); paintPresent(); paint({ keepScroll: true }); });

  ctx.signal.addEventListener('abort', () => {
    if (generating) stop();
    voice.stopSpeaking();
    clearInterval(tick);
    unsubEngine();
    unsubChars();
  });

  // Coming back to a scene whose newest line from you was a worrying one: careful follow-ups, card shown.
  const lastSaid = [...conv.messages].reverse().find((m) => m.role === 'user');
  lastLevel = lastSaid ? assess(textOf(lastSaid)).level : 'none';
  if (lastLevel !== 'none') flaggedThisVisit = true;
  raiseSafety(lastLevel);

  paintPresent();
  paint();
  requestAnimationFrame(() => {
    if (conv.messages.length) scrollToEnd();
    if (!matchMedia('(pointer: coarse)').matches) input.focus({ preventScroll: true });
  });
  return page;
}
