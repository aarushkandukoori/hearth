// Chat (#/chat/:characterId and #/chat/:characterId/:conversationId, where 'new' starts fresh).
// Streams replies, swipes between alternates on the last reply, 1-4 star rating, edit/delete/pin/copy,
// play aloud, photos (downscaled, never uploaded), voice notes, pictures, and a gentle safety card.

import { h, avatar, richText, modal, toast, menu, confirm, emptyState, whereText } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { messageRow, typingDots } from '../ui/messages.js';
import { openModelDialog, noWebGPUText } from '../ui/model-dialog.js';
import { getCharacter, world, settings, userName, subscribe, whereNow } from '../data.js';
import {
  makeMessage, textOf, extraOf, setExtra, newDirectConversation, getConversation, latestConversation,
  conversationsFor, saveConversation, deleteConversation, previewText,
} from '../chats.js';
import { getAll } from '../store.js';
import { engine } from '../engine/engine.js';
import { composeDirect, composeMemory, asksForPicture, MAX_MESSAGE_CHARS } from '../brain/prompts.js';
import { cleanReply, streamingPreview, parseFacts } from '../brain/parse.js';
import { assess, RESOURCES, COPY, caringReply, isRefusal } from '../brain/safety.js';
import { extractFacts, remember, factsFor, pinFact, unpinFact } from '../brain/memory.js';
import * as voice from '../media/voice.js';
import { downscaleImage, pictureFor } from '../media/photos.js';
import { navigate, canGoBack } from '../router.js';
import { relativeTime, sleep } from '../util.js';

const DEMO_BANNER_KEY = 'hearth.demoBannerHidden';
const SAFETY_RANK = { none: 0, concern: 1, crisis: 2 };

/** What the safety check reads for a user message: its text plus a photo caption. */
const safetyText = (m) => `${textOf(m)} ${extraOf(m).attachment?.caption || ''}`;

function notFound(ctx) {
  ctx.setTitle('Not found');
  return h('div', { class: 'page narrow' }, emptyState({
    iconName: 'message', title: "This chat isn't here",
    body: 'The character may have been deleted from this browser.',
    action: h('a', { class: 'btn btn-secondary', href: '#/' }, 'Back to Discover'),
  }));
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

/** Recent happenings for the prompt: newest saved town events, else the world's starter events. */
async function recentEvents() {
  try {
    const rows = (await getAll('events')).sort((a, b) => (b.date || 0) - (a.date || 0)).slice(0, 3);
    if (rows.length) return rows.map((e) => e.text);
  } catch { /* no events yet */ }
  return (world()?.starterEvents || []).slice(0, 2);
}

function safetyCard(level, onHide) {
  const copy = COPY[level] || COPY.concern;
  return h('section', { class: `safety-card ${level}`, role: level === 'crisis' ? 'alert' : 'status', 'aria-labelledby': 'safety-title' },
    h('div', { class: 'safety-head' },
      h('span', { class: 'safety-icon', 'aria-hidden': 'true' }, icon('lifebuoy', { size: 20 })),
      h('h2', { id: 'safety-title' }, copy.title),
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

export async function renderChat(ctx) {
  const c = getCharacter(ctx.params.characterId);
  if (!c) return notFound(ctx);
  // Names of characters you made stay out of the tab title (and so out of synced browser history).
  ctx.setTitle(c.isBuiltIn ? `Chat with ${c.name}` : 'Chat');

  const name = () => userName();
  let conv = null;
  const wanted = ctx.params.conversationId;
  if (wanted && wanted !== 'new') {
    const found = await getConversation(wanted);
    if (found && found.characterID === c.id) conv = found;
  }
  if (!conv && wanted !== 'new') conv = await latestConversation(c.id);
  if (!conv) conv = newDirectConversation(c, { userName: name() });
  if (ctx.signal.aborted) return null;
  let saved = !!(await getConversation(conv.id));

  let generating = false;
  let streamingID = null;
  let pendingPhoto = null;     // { dataURL, caption }
  let safetyLevel = 'none';    // highest level shown this visit; the card only ever gets more urgent
  let flaggedThisVisit = false; // a message in this visit was flagged: no voice notes or surprise pictures from now on
  let editingID = null;
  let deleted = false;         // this chat was deleted, so nothing may save it again
  let promptContext = null;    // [facts, events], read once per visit so the prompt stays the same

  // ---- Layout ----------------------------------------------------------------------------------
  // The list is rebuilt on every change, so screen readers hear new replies through `announcer` instead.
  const list = h('div', { class: 'chat-list-msgs', role: 'region', 'aria-label': `Conversation with ${c.name}` });
  const announcer = h('div', { class: 'sr-only', 'aria-live': 'polite' });
  const scroller = h('div', { class: 'chat-scroll' },
    h('div', { class: 'chat-inner' },
      h('div', { class: 'chat-intro' },
        avatar(c, { size: 72, shape: 'rounded' }),
        h('h1', { class: 'chat-intro-name' }, c.name),
        c.tagline ? h('p', { class: 'chat-intro-tag' }, c.tagline) : null,
        h('p', { class: 'chat-intro-by' }, `By ${c.creator || '@lanternbay'}`)),
      list));

  const engineSlot = h('div', { class: 'chat-engine' });
  const menuBtn = h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Chat options', 'aria-haspopup': 'menu' }, icon('more'));
  const backBtn = h('button', {
    class: 'icon-btn chat-back', type: 'button', 'aria-label': 'Back',
    onClick: () => (canGoBack() ? history.back() : navigate('#/')),
  }, icon('arrow-left'));

  const where = h('span', { class: 'chat-head-where' });
  const header = h('header', { class: 'chat-header' },
    backBtn,
    h('a', { class: 'chat-head-who', href: `#/c/${encodeURIComponent(c.id)}`, 'aria-label': `${c.name}, view profile` },
      avatar(c, { size: 38 }),
      h('span', { class: 'chat-head-text' },
        h('span', { class: 'chat-head-name' }, c.name),
        h('span', { class: 'chat-head-by' }, `By ${c.creator || '@lanternbay'}`, where))),
    h('div', { class: 'grow' }),
    engineSlot,
    menuBtn);

  const safetySlot = h('div', { class: 'safety-slot' });
  const bannerSlot = h('div', { class: 'banner-slot' });
  const previewSlot = h('div', { class: 'attach-slot' });
  const fileInput = h('input', { type: 'file', accept: 'image/*', class: 'sr-only', tabindex: '-1', 'aria-hidden': 'true' });
  const attachBtn = h('button', { class: 'icon-btn composer-attach', type: 'button', 'aria-label': 'Attach a photo', title: 'Attach a photo' }, icon('image'));
  const input = h('textarea', {
    class: 'composer-input', rows: '1', placeholder: `Message ${c.name}...`, 'aria-label': `Message ${c.name}`,
    enterkeyhint: 'send', autocomplete: 'off', maxlength: String(MAX_MESSAGE_CHARS),
  });
  const sendBtn = h('button', { class: 'composer-send', type: 'button', 'aria-label': 'Send' }, icon('arrow-up', { size: 20 }));
  const composer = h('form', { class: 'composer', onSubmit: (e) => { e.preventDefault(); send(); } },
    attachBtn, input, sendBtn, fileInput);
  const bottom = h('div', { class: 'chat-bottom' },
    h('div', { class: 'chat-bottom-inner' },
      safetySlot, bannerSlot, previewSlot, composer,
      h('p', { class: 'chat-disclosure' }, 'Hearth characters are AI. What they say is made up.')));

  const page = h('div', { class: 'chat-page', style: { '--accent-char': c.accentHex || 'var(--accent)' } }, header, scroller, bottom, announcer);

  // ---- Helpers ---------------------------------------------------------------------------------
  const nearBottom = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 140;
  const scrollToEnd = (smooth = false) => {
    scroller.scrollTo({ top: scroller.scrollHeight, behavior: smooth && !matchMedia('(prefers-reduced-motion: reduce)').matches ? 'smooth' : 'auto' });
  };
  const hasUserMessage = () => conv.messages.some((m) => m.role === 'user');

  async function persist({ touch = true } = {}) {
    if (deleted || !hasUserMessage()) return;
    await saveConversation(conv, { touch });
    if (!saved) {
      saved = true;
      navigate(`#/chat/${encodeURIComponent(c.id)}/${encodeURIComponent(conv.id)}`, { silent: true });
    }
  }

  function paintWhere() {
    const w = whereText(c);
    where.textContent = w ? ` · ${w}` : '';
  }

  // ---- Message rendering -----------------------------------------------------------------------
  function tools(m, index) {
    const isLast = index === conv.messages.length - 1 && m.role === 'character';
    if (!isLast || generating) return null;
    const count = m.variants.length;
    // data-focus names each control so paint() can give it focus back after rebuilding the row.
    const prev = h('button', { class: 'icon-btn sm', type: 'button', 'aria-label': 'Previous reply', disabled: m.selected <= 0, dataset: { focus: 'prev' }, onClick: () => selectVariant(m, m.selected - 1) }, icon('chevron-left'));
    const next = h('button', {
      class: 'icon-btn sm', type: 'button', dataset: { focus: 'next' },
      'aria-label': m.selected >= count - 1 ? 'Write another reply' : 'Next reply',
      title: m.selected >= count - 1 ? 'Write another reply' : 'Next reply',
      onClick: () => (m.selected >= count - 1 ? regenerate(m) : selectVariant(m, m.selected + 1)),
    }, icon('chevron-right'));
    const rating = extraOf(m).rating || 0;
    const stars = h('div', { class: 'stars', role: 'group', 'aria-label': 'Rate this reply' },
      [1, 2, 3, 4].map((n) => h('button', {
        class: `star${n <= rating ? ' on' : ''}`, type: 'button', 'aria-label': `${n} star${n > 1 ? 's' : ''}`, 'aria-pressed': n === rating ? 'true' : 'false',
        title: 'Ratings stay on this device', dataset: { focus: `star-${n}` },
        onClick: () => rate(m, n),
      }, icon(n <= rating ? 'star-fill' : 'star', { size: 17 }))));
    return h('div', { class: 'msg-tools' },
      stars,
      h('div', { class: 'grow' }),
      h('button', { class: 'icon-btn sm', type: 'button', 'aria-label': 'Regenerate reply', title: 'Regenerate', dataset: { focus: 'regen' }, onClick: () => regenerate(m) }, icon('refresh')),
      h('div', { class: 'swipe' }, prev, h('span', { class: 'swipe-count' }, `${m.selected + 1}/${count}`), next));
  }

  function messageMenu(m, index) {
    const btn = h('button', { class: 'icon-btn sm msg-more', type: 'button', 'aria-label': 'Message options', 'aria-haspopup': 'menu', dataset: { focus: 'menu' } }, icon('more'));
    btn.addEventListener('click', () => {
      const isChar = m.role === 'character';
      const isGreeting = index === 0 && isChar;
      const isLast = index === conv.messages.length - 1;
      const text = textOf(m);
      menu(btn, [
        { label: 'Copy', icon: 'copy', onClick: async () => { await copyText(text); toast('Copied.'); } },
        isChar ? { label: 'Play aloud', icon: 'volume', disabled: !voice.hasLocalVoice() || !text.trim(), onClick: () => playAloud(m) } : null,
        isChar ? (m.pinned
          ? { label: 'Unpin from memory', icon: 'pin', onClick: () => togglePin(m) }
          : { label: 'Pin to memory', icon: 'pin', onClick: () => togglePin(m) }) : null,
        isChar && isLast && !generating ? { label: 'Regenerate', icon: 'refresh', onClick: () => regenerate(m) } : null,
        { label: 'Edit', icon: 'edit', disabled: generating, onClick: () => startEdit(m) },
        isGreeting ? null : { separator: true },
        isGreeting ? null : { label: 'Delete', icon: 'trash', danger: true, disabled: generating, onClick: () => removeMessage(m) },
      ], { label: 'Message options' });
    });
    return btn;
  }

  function editor(m) {
    const ta = h('textarea', { class: 'edit-input', rows: '3', 'aria-label': 'Edit message', maxlength: String(MAX_MESSAGE_CHARS) });
    ta.value = textOf(m);
    const save = async () => {
      const v = ta.value.trim();
      if (!v && !extraOf(m).attachment) return;
      const before = textOf(m);
      m.variants[m.selected] = v;
      const att = extraOf(m).attachment;
      if (att?.kind === 'voice') setExtra(m, { attachment: { ...att, caption: v } });
      if (m.pinned && v !== before) {
        // The memory follows the edit.
        await unpinFact(c.id, before, { messageID: m.id });
        if (v) await pinFact(c.id, v, { messageID: m.id, conversationID: conv.id });
        else m.pinned = false;
        promptContext = null;
      }
      editingID = null;
      await persist({ touch: false });
      paint();
    };
    const cancel = () => { editingID = null; paint(); };
    ta.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); save(); }
      if (e.key === 'Escape') { e.preventDefault(); cancel(); }
    });
    requestAnimationFrame(() => { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); autoGrow(ta, 240); });
    ta.addEventListener('input', () => autoGrow(ta, 240));
    return h('div', { class: 'edit-box' }, ta,
      h('div', { class: 'edit-actions' },
        h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onClick: cancel }, 'Cancel'),
        h('button', { class: 'btn btn-primary btn-sm', type: 'button', onClick: save }, 'Save')));
  }

  function rowFor(m, index) {
    const isUser = m.role === 'user';
    const isStreaming = m.id === streamingID;
    const demoBadge = !isUser && extraOf(m).demo ? h('span', { class: 'badge demo-badge', title: 'A canned demo reply, not the model' }, 'Demo') : null;
    const row = messageRow(m, {
      character: isUser ? null : c,
      isUser,
      tools: isStreaming ? null : tools(m, index),
      menuButton: isStreaming || editingID ? null : messageMenu(m, index),
      badge: demoBadge,
      voiceURI: settings().voiceURI,
    });
    if (editingID === m.id) {
      // Swap only the text (or voice note) for the editor, so photos and pictures stay in view.
      const target = row.querySelector('.msg-text, .voice-note');
      const box = editor(m);
      if (target) target.replaceWith(box);
      else (row.querySelector('.msg-body') || row.querySelector(isUser ? '.msg-bubble' : '.msg-main'))?.prepend(box);
      row.classList.add('editing');
    }
    if (isStreaming) {
      row.classList.add('streaming');
      row.setAttribute('aria-busy', 'true');
      const body = row.querySelector('.msg-body, .voice-note, .rich');
      const live = h('div', { class: 'msg-body stream-body' });
      if (body) body.replaceWith(live);
      row.__live = live;
    }
    return row;
  }

  // Rows are rebuilt on every paint; only messages that are new since the last paint animate in.
  const shownIDs = new Set();
  let firstPaint = true;

  /** `focus`: { id, key } of a control to focus after the rebuild (otherwise the focused one keeps focus). */
  function paint({ keepScroll = false, focus = null } = {}) {
    const stick = keepScroll ? false : nearBottom();
    const active = list.contains(document.activeElement) ? document.activeElement : null;
    const want = focus || (active?.dataset.focus ? { id: active.closest('[data-id]')?.dataset.id, key: active.dataset.focus } : null);
    list.replaceChildren(...conv.messages.map((m, i) => {
      const row = rowFor(m, i);
      if (!firstPaint && !shownIDs.has(m.id)) row.classList.add('enter');
      shownIDs.add(m.id);
      return row;
    }));
    firstPaint = false;
    if (streamingID) updateStream(null);
    if (want?.id) {
      // The rows are new, so keyboard focus goes back to the same control on the same message.
      const row = list.querySelector(`[data-id="${CSS.escape(want.id)}"]`);
      (row?.querySelector(`[data-focus="${want.key}"]:not(:disabled)`) || row?.querySelector('[data-focus]:not(:disabled)'))?.focus({ preventScroll: true });
    }
    if (stick) scrollToEnd();
  }

  let streamState = { text: '', voice: false, looking: false };
  function updateStream(full) {
    if (full != null) streamState.text = full;
    const row = list.querySelector(`[data-id="${CSS.escape(streamingID || '')}"]`);
    const live = row?.__live;
    if (!live) return;
    const stick = nearBottom();
    if (streamState.looking) {
      live.replaceChildren(h('span', { class: 'recording' }, icon('image', { size: 16 }), `${c.name} is looking at your photo`, typingDots('Looking')));
    } else if (streamState.voice) {
      live.replaceChildren(h('span', { class: 'recording' }, icon('wave', { size: 16 }), `${c.name} is recording a voice note`, typingDots('Recording')));
    } else {
      const preview = streamingPreview(streamState.text, { name: c.name });
      live.replaceChildren(preview.trim() ? richText(preview, { className: 'rich msg-text' }) : typingDots(`${c.name} is typing`));
    }
    if (stick) scrollToEnd();
  }

  // ---- Actions ---------------------------------------------------------------------------------
  function selectVariant(m, i) {
    m.selected = Math.max(0, Math.min(i, m.variants.length - 1));
    persist({ touch: false });
    paint({ keepScroll: true });
    announcer.textContent = `Reply ${m.selected + 1} of ${m.variants.length}: ${textOf(m).replace(/\*/g, '')}`;
  }

  function rate(m, n) {
    const current = extraOf(m).rating || 0;
    setExtra(m, { rating: current === n ? null : n });
    persist({ touch: false });
    paint({ keepScroll: true });
    if (current !== n) toast(`Rated ${n} star${n > 1 ? 's' : ''}. Ratings stay on this device.`, { duration: 1800 });
  }

  function playAloud(m) {
    const res = voice.speak(textOf(m), c, { voiceURI: settings().voiceURI });
    res.done.then((why) => { if (why === 'unavailable') toast("There's no voice on this device that can read this aloud."); });
  }

  async function togglePin(m) {
    const text = textOf(m).trim();
    if (!text) return;
    if (m.pinned) {
      await unpinFact(c.id, text, { messageID: m.id });
      m.pinned = false;
      toast('Unpinned.');
    } else {
      await pinFact(c.id, text, { messageID: m.id, conversationID: conv.id });
      m.pinned = true;
      toast(`Pinned. ${c.name} will keep this in mind.`, { tone: 'success' });
    }
    promptContext = null; // the next reply reads the memories again
    await persist({ touch: false });
    paint({ keepScroll: true, focus: { id: m.id, key: 'menu' } });
  }

  function startEdit(m) { editingID = m.id; paint({ keepScroll: true }); }

  async function removeMessage(m) {
    const ok = await confirm({ title: 'Delete this message?', message: "It will be removed from this chat. This can't be undone.", confirmLabel: 'Delete' });
    if (!ok) return;
    conv.messages = conv.messages.filter((x) => x.id !== m.id);
    if (m.pinned) {
      await unpinFact(c.id, textOf(m), { messageID: m.id });
      promptContext = null;
    }
    if (hasUserMessage()) await persist({ touch: false });
    else if (saved && !deleted) { await saveConversation(conv, { touch: false }); }
    paint({ keepScroll: true });
  }

  function setBusy(on) {
    generating = on;
    sendBtn.classList.toggle('stop', on);
    sendBtn.replaceChildren(icon(on ? 'stop' : 'arrow-up', { size: on ? 16 : 20 }));
    sendBtn.setAttribute('aria-label', on ? 'Stop' : 'Send');
    syncSend();
  }

  function syncSend() {
    sendBtn.disabled = !generating && !input.value.trim() && !pendingPhoto;
  }

  /** Memory facts and town news, read once per visit (SPEC §7) so the prompt starts the same way each turn. */
  async function contextForPrompt() {
    if (!promptContext) promptContext = await Promise.all([factsFor(c.id, { gossip: settings().townGossip }), recentEvents()]);
    return promptContext;
  }

  /**
   * The fixed caring reply for a flagged message. It skips the one used by the reply just before and by
   * the alternate being replaced, so the same words never come back to back.
   */
  function caringFor(m, history) {
    const prev = [...history].reverse().find((x) => x.role === 'character');
    const avoid = [m.extras?.[m.variants.length - 2]?.caring, extraOf(prev).caring].filter(Number.isInteger);
    return caringReply(name(), { seed: `${conv.id}|${m.id}|${m.variants.length}`, avoid });
  }

  /** Writes a reply as a new message, or as a new alternate of `target`. */
  async function reply({ target = null } = {}) {
    const userNow = name();
    let m = target;
    let upto;
    if (m) {
      upto = conv.messages.indexOf(m);
      m.variants.push('');
      if (!Array.isArray(m.extras)) m.extras = [];
      m.extras[m.variants.length - 1] = {};
      m.selected = m.variants.length - 1;
    } else {
      m = makeMessage({ role: 'character', speakerID: c.id, text: '' });
      upto = conv.messages.length;
      conv.messages.push(m);
    }
    const history = conv.messages.slice(0, upto);
    const lastUser = [...history].reverse().find((x) => x.role === 'user');
    const lastUserText = lastUser ? textOf(lastUser) : '';
    // Checked on the message being answered, so a regenerated reply (even after a reload) is careful too.
    const level = lastUser ? assess(safetyText(lastUser)).level : 'none';
    const flagged = level !== 'none';
    if (flagged) flaggedThisVisit = true;
    // A crisis message never goes to the model, which can answer it with a cold refusal, and demo replies
    // can't read the room: both get a fixed caring reply with the crisis lines (the help card shows too).
    const caring = level === 'crisis' || (flagged && engine.isDemo);
    const s = settings();
    const asked = asksForPicture(lastUserText);
    // Never a picture in answer to a flagged message, and for the rest of that visit only ones the person
    // asks for (the model can copy a "[photo: ...]" line from the history on its own).
    const pictures = s.picturesEnabled !== false && !flagged && (asked || !flaggedThisVisit);
    const photo = !pictures ? null : asked ? 'asked' : (Math.random() < (c.media?.photoChance ?? 0) ? 'spontaneous' : null);
    // Voice notes only after the first exchange (never in place of the greeting), and after a worrying
    // message replies stay as text to read right away, for the rest of the visit.
    const asVoice = !flaggedThisVisit && photo !== 'asked' && s.voiceNotesEnabled && voice.hasLocalVoice()
      && upto > 1 && Math.random() < (c.media?.voiceNoteChance ?? 0);
    streamingID = m.id;
    streamState = { text: '', voice: asVoice, looking: false };
    setBusy(true);
    paint();
    scrollToEnd(true);

    let result = { text: '', stats: { engine: 'demo', stoppedBy: 'error' } };
    if (caring) {
      await sleep(500); // a moment of "typing" first
    } else if (await seePhoto(lastUser) === 'stopped') {
      result = { text: '', stats: { engine: 'pie', stoppedBy: 'cancelled' } };
    } else {
      try {
        const [facts, events] = await contextForPrompt();
        const turns = composeDirect({
          character: c, world: world(), persona: { name: userNow, about: s.persona?.about || '' },
          messages: history, facts, events, photo, flagged,
        });
        result = await engine.generate({
          key: `conv-${conv.id}`, turns, maxTokens: streamState.voice ? 110 : 220, // voice notes stay short
          stop: [`\n${userNow}:`, '\nYou:'],
          sampling: { temperature: 0.8, topP: 0.95, repeatPenalty: 1.1, seed: Math.floor(Math.random() * 2 ** 31) },
        }, (_delta, full) => updateStream(full));
      } catch (err) {
        console.error('[hearth] reply failed:', err?.name || 'Error');
        if (!flagged) toast("Couldn't write a reply just now. Try again in a moment.", { tone: 'danger' });
      }
    }

    let cleaned = cleanReply(result.text, { name: c.name, userName: userNow, cutByLength: result.stats?.stoppedBy === 'length' });
    let caringIndex = null;
    // A flagged message always gets an answer with care: the fixed reply when the model wasn't asked,
    // refused ("I can't continue this conversation") or failed.
    if (caring || (flagged && (isRefusal(cleaned.text) || result.stats?.stoppedBy === 'error'))) {
      const fixed = caringFor(m, history);
      cleaned = { text: fixed.text, photo: null };
      caringIndex = fixed.index;
      result = { text: fixed.text, stats: { engine: 'safety', stoppedBy: 'eos' } };
    }
    if (!pictures) cleaned = { ...cleaned, photo: null }; // e.g. a flagged turn: the picture is dropped
    const cancelledEmpty = !cleaned.text && !cleaned.photo;
    if (cancelledEmpty) {
      // Nothing usable came back: drop the empty reply or alternate.
      if (target) { m.variants.pop(); m.extras.pop(); m.selected = m.variants.length - 1; }
      else conv.messages = conv.messages.filter((x) => x.id !== m.id);
    } else {
      m.variants[m.selected] = cleaned.text;
      const extra = { stats: result.stats, demo: result.stats?.engine === 'demo' };
      if (caringIndex != null) extra.caring = caringIndex;
      if (cleaned.photo) {
        const pic = pictureFor(cleaned.photo, { world: world(), character: c, locationID: whereNow(c)?.locationID || null });
        extra.attachment = { kind: 'picture', caption: cleaned.photo, src: pic.src, postcard: pic.postcard };
      } else if (streamState.voice && cleaned.text) {
        extra.attachment = {
          kind: 'voice', caption: cleaned.text,
          duration: Number(voice.estimateDuration(cleaned.text, c).toFixed(1)),
          waveform: voice.waveformFor(cleaned.text),
        };
      }
      m.extras[m.selected] = extra;
    }
    streamingID = null;
    setBusy(false);
    await persist();
    paint();
    if (!cancelledEmpty) {
      const kind = m.extras[m.selected]?.attachment?.kind;
      const said = cleaned.text.replace(/\*/g, '');
      announcer.textContent = `${c.name}${kind === 'voice' ? ' sent a voice note' : kind === 'picture' ? ' sent a picture' : ''}: ${said}`;
    }
    if (!matchMedia('(pointer: coarse)').matches) input.focus({ preventScroll: true });
    maybeSummarize();
  }

  /**
   * A photo the person just sent is described once by the model's vision pass (in this tab), and the
   * character reads that description. Returns 'stopped' when the person stopped it.
   */
  async function seePhoto(m) {
    const att = m ? extraOf(m).attachment : null;
    if (att?.kind !== 'photo' || !att.dataURL || att.description || engine.status !== 'ready') return null;
    streamState.looking = true;
    updateStream(null);
    const description = await engine.describePhoto(att.dataURL);
    streamState.looking = false;
    updateStream(null);
    if (description === null) return 'stopped';
    if (description && !deleted) {
      setExtra(m, { attachment: { ...att, description } });
      await persist({ touch: false });
      paint({ keepScroll: true });
    }
    return null;
  }

  function regenerate(m) {
    if (generating) return;
    reply({ target: m });
  }

  let summarizing = false;
  async function maybeSummarize() {
    if (summarizing || deleted || engine.status !== 'ready') return;
    const userCount = conv.messages.filter((m) => m.role === 'user').length;
    if (userCount === 0 || userCount % 12 !== 0) return;
    summarizing = true;
    setTimeout(async () => {
      try {
        if (generating || deleted) return;
        const turns = composeMemory({ character: c, persona: { name: name() }, messages: conv.messages });
        const { text } = await engine.generate({ key: `mem-${conv.id}`, turns, maxTokens: 120, sampling: { temperature: 0.3 } });
        const facts = parseFacts(text);
        if (facts.length && !deleted) await remember(c.id, facts, { source: 'summary', shareable: settings().townGossip, conversationID: conv.id });
      } catch { /* best effort */ } finally {
        summarizing = false;
      }
    }, 1500);
  }

  async function send() {
    if (generating) { engine.cancel(); return; }
    const text = input.value.trim();
    const photo = pendingPhoto;
    if (!text && !photo) return;
    input.value = '';
    autoGrow(input);
    pendingPhoto = null;
    paintPreview();
    const msg = makeMessage({
      role: 'user', text,
      attachment: photo ? { kind: 'photo', dataURL: photo.dataURL, caption: photo.caption?.trim() || '' } : null,
    });
    conv.messages.push(msg);
    try {
      await persist();
    } catch (err) {
      // Not saved (storage full or closed): give the message back instead of losing it.
      console.error('[hearth] saving the chat failed:', err?.name || 'Error');
      conv.messages = conv.messages.filter((x) => x.id !== msg.id);
      input.value = text;
      autoGrow(input);
      pendingPhoto = photo;
      paintPreview();
      syncSend();
      toast(/quota/i.test(`${err?.name} ${err?.message}`)
        ? "Couldn't save that message: this browser is out of storage space for Hearth."
        : "Couldn't save that message. Try again in a moment.", { tone: 'danger' });
      return;
    }
    paint();
    scrollToEnd(true);

    const level = assess(safetyText(msg)).level;
    raiseSafety(level);
    // Nothing is learned from a flagged message (memory.js checks again), so it can't come up later or
    // travel to other residents through town gossip.
    if (level === 'none') {
      const facts = extractFacts(text);
      if (facts.length) remember(c.id, facts, { source: 'auto', shareable: settings().townGossip, conversationID: conv.id }).catch(() => {});
    } else {
      flaggedThisVisit = true;
    }
    await reply();
  }

  /** Shows the help card; a later message can make it more urgent, never less (until it is hidden). */
  function raiseSafety(level) {
    if (SAFETY_RANK[level] <= SAFETY_RANK[safetyLevel]) return;
    safetyLevel = level;
    safetySlot.replaceChildren(safetyCard(level, () => { safetyLevel = 'none'; safetySlot.replaceChildren(); }));
  }

  /** "Get support" in the chat menu: shows the help card again (it stays as urgent as it already was). */
  function showSupport() {
    raiseSafety('concern');
    safetySlot.querySelector('.safety-card')?.scrollIntoView({ block: 'nearest' });
  }

  // ---- Composer --------------------------------------------------------------------------------
  function autoGrow(el, max = 200) {
    el.style.height = 'auto';
    el.style.height = `${Math.min(max, el.scrollHeight)}px`;
  }

  input.addEventListener('input', () => { autoGrow(input); syncSend(); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
    if (e.key === 'Escape' && generating) { e.preventDefault(); engine.cancel(); }
  });
  input.addEventListener('paste', (e) => {
    const file = [...(e.clipboardData?.files || [])].find((f) => f.type.startsWith('image/'));
    if (file) { e.preventDefault(); takePhoto(file); }
  });
  sendBtn.addEventListener('click', (e) => { e.preventDefault(); send(); });
  attachBtn.addEventListener('click', () => fileInput.click());
  fileInput.addEventListener('change', () => {
    const file = fileInput.files?.[0];
    fileInput.value = '';
    if (file) takePhoto(file);
  });

  async function takePhoto(file) {
    try {
      const { dataURL } = await downscaleImage(file);
      pendingPhoto = { dataURL, caption: '' };
      paintPreview();
      syncSend();
      requestAnimationFrame(() => previewSlot.querySelector('input')?.focus());
    } catch (err) {
      toast(err?.message || "That picture couldn't be opened.", { tone: 'danger' });
    }
  }

  function paintPreview() {
    if (!pendingPhoto) { previewSlot.replaceChildren(); return; }
    // With the model loaded, its vision pass describes the photo; demo replies only have the person's words.
    const sees = engine.status === 'ready';
    const caption = h('input', {
      class: 'input attach-caption', type: 'text', maxlength: '160',
      placeholder: sees ? 'Add a caption (optional)' : `Describe it for ${c.name} (optional)`,
      'aria-label': sees ? `Caption for ${c.name}` : `Describe the photo for ${c.name}`, value: pendingPhoto.caption,
    });
    caption.addEventListener('input', () => { if (pendingPhoto) pendingPhoto.caption = caption.value; });
    caption.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); send(); } });
    previewSlot.replaceChildren(h('div', { class: 'attach-preview' },
      h('img', { src: pendingPhoto.dataURL, alt: 'Photo to send' }),
      h('div', { class: 'attach-meta' },
        caption,
        h('p', { class: 'field-hint' }, icon('lock', { size: 13 }), sees
          ? `The model in this tab describes it for ${c.name}. The photo stays on this device.`
          : `With demo replies ${c.name} can't see pictures, so a few words help. The photo stays on this device.`)),
      h('button', { class: 'icon-btn sm', type: 'button', 'aria-label': 'Remove photo', onClick: () => { pendingPhoto = null; paintPreview(); syncSend(); } }, icon('x'))));
  }

  // ---- Engine status (header pill + demo banner) ------------------------------------------------
  let gpuOK = null;
  engine.isWebGPUAvailable().then((ok) => { gpuOK = ok; paintEngine(engine.snapshot()); });
  function paintEngine(s) {
    if (s.status === 'ready') {
      engineSlot.replaceChildren(h('a', { class: 'engine-pill ready', href: '#/settings?section=model', title: 'Replies come from the model running on this device' },
        h('span', { class: 'dot dot-ready', 'aria-hidden': 'true' }), 'On this device'));
      bannerSlot.replaceChildren();
      return;
    }
    if (s.status === 'loading') {
      const pct = Math.round((s.progress?.fraction || 0) * 100);
      engineSlot.replaceChildren(h('button', { class: 'engine-pill loading', type: 'button', onClick: () => openModelDialog() },
        h('span', { class: 'dot dot-loading', 'aria-hidden': 'true' }), `Loading ${pct}%`));
    } else {
      engineSlot.replaceChildren(h('button', { class: 'engine-pill demo', type: 'button', onClick: () => openModelDialog(), title: 'Replies are canned demo lines' },
        h('span', { class: 'dot dot-demo', 'aria-hidden': 'true' }), 'Demo replies'));
    }
    let hidden = false;
    try { hidden = sessionStorage.getItem(DEMO_BANNER_KEY) === '1'; } catch { /* ignore */ }
    if (hidden) { bannerSlot.replaceChildren(); return; }
    const info = engine.modelInfo(settings().modelId);
    const hide = h('button', {
      class: 'icon-btn sm', type: 'button', 'aria-label': 'Hide this note',
      onClick: () => { try { sessionStorage.setItem(DEMO_BANNER_KEY, '1'); } catch { /* ignore */ } bannerSlot.replaceChildren(); },
    }, icon('x'));
    let text;
    let action = null;
    if (s.status === 'loading') {
      text = h('span', { class: 'banner-text' }, h('strong', {}, 'Demo replies'), ` while ${info.name} loads (${Math.round((s.progress?.fraction || 0) * 100)}%).`);
    } else if (s.status === 'error') {
      text = h('span', { class: 'banner-text' }, h('strong', {}, 'Demo replies. '), s.error || 'The model could not start.');
      action = h('button', { class: 'btn btn-secondary btn-sm banner-action', type: 'button', onClick: () => openModelDialog() }, 'Try again');
    } else if (gpuOK === false) {
      text = h('span', { class: 'banner-text' }, h('strong', {}, 'Demo replies. '), "This browser can't run the model (it needs WebGPU).");
      action = h('button', {
        class: 'btn btn-secondary btn-sm banner-action', type: 'button',
        onClick: () => modal({ title: 'About the model', body: h('p', { class: 'text-2' }, noWebGPUText()), actions: [{ label: 'OK', variant: 'primary', autofocus: true }] }),
      }, 'Learn more');
    } else {
      text = h('span', { class: 'banner-text' }, h('strong', {}, 'Demo replies'), ' are simple canned lines.');
      action = h('button', { class: 'btn btn-primary btn-sm banner-action', type: 'button', onClick: () => openModelDialog() },
        icon('download', { size: 16 }), `Load the real model (${info.sizeLabel}, one time)`);
    }
    bannerSlot.replaceChildren(h('div', { class: `demo-banner ${s.status}` },
      h('span', { class: 'banner-icon', 'aria-hidden': 'true' }, icon('sparkle', { size: 18 })), text, action, hide));
  }
  const unsubEngine = engine.subscribe(paintEngine);
  paintEngine(engine.snapshot());

  // ---- Header menu -----------------------------------------------------------------------------
  menuBtn.addEventListener('click', () => {
    menu(menuBtn, [
      { label: 'New chat', icon: 'plus', onClick: () => navigate(`#/chat/${encodeURIComponent(c.id)}/new`) },
      { label: 'Chat history', icon: 'history', onClick: () => openHistory() },
      { label: 'View profile', icon: 'user', onClick: () => navigate(`#/c/${encodeURIComponent(c.id)}`) },
      { label: 'Get support', icon: 'lifebuoy', onClick: () => showSupport() },
      { separator: true },
      { label: 'Delete this chat', icon: 'trash', danger: true, disabled: !saved || generating, onClick: () => deleteThisChat() },
    ], { label: 'Chat options' });
  });

  /** The open chat is being deleted: stop any reply and never save it again. */
  function forgetThisChat() {
    deleted = true;
    if (generating) engine.cancel();
  }

  async function openHistory() {
    const chats = (await conversationsFor(c.id)).filter((x) => x.hasUser);
    const listEl = h('ul', { class: 'history-list' });
    const paintHistory = (rows) => {
      if (!rows.length) { listEl.replaceChildren(h('li', { class: 'mem-empty' }, `No saved chats with ${c.name} yet.`)); return; }
      listEl.replaceChildren(...rows.map((x) => {
        const del = h('button', { class: 'icon-btn sm', type: 'button', 'aria-label': 'Delete this chat' }, icon('trash'));
        del.addEventListener('click', async () => {
          if (!(await confirm({ title: 'Delete this chat?', message: `It will be removed from this browser, along with what ${c.name} learned from it. This can't be undone.`, confirmLabel: 'Delete chat' }))) return;
          if (x.id === conv.id) forgetThisChat();
          await deleteConversation(x.id);
          rows = rows.filter((r) => r.id !== x.id);
          paintHistory(rows);
          if (x.id === conv.id) { handle.close(); navigate(`#/chat/${encodeURIComponent(c.id)}/new`, { replace: true }); }
        });
        const count = x.count;
        return h('li', { class: `history-row${x.id === conv.id ? ' current' : ''}` },
          h('a', { class: 'history-link', href: `#/chat/${encodeURIComponent(c.id)}/${encodeURIComponent(x.id)}`, onClick: () => handle.close() },
            h('span', { class: 'history-top' }, h('strong', {}, relativeTime(x.updatedAt)), h('span', { class: 'muted' }, `${count} message${count === 1 ? '' : 's'}`),
              x.id === conv.id ? h('span', { class: 'badge accent' }, 'Open now') : null),
            h('span', { class: 'history-preview ellipsis' }, previewText(x))),
          del);
      }));
    };
    paintHistory(chats);
    const handle = modal({
      title: `Chats with ${c.name}`, body: listEl, size: 'md',
      actions: [{ label: 'Start a new chat', variant: 'primary', onClick: () => navigate(`#/chat/${encodeURIComponent(c.id)}/new`) }],
    });
  }

  async function deleteThisChat() {
    const ok = await confirm({ title: 'Delete this chat?', message: `Your conversation with ${c.name}, and what ${c.name} learned from it, will be removed from this browser. This can't be undone.`, confirmLabel: 'Delete chat' });
    if (!ok) return;
    forgetThisChat();
    await deleteConversation(conv.id);
    toast('Chat deleted.');
    navigate(`#/chat/${encodeURIComponent(c.id)}/new`, { replace: true });
  }

  // ---- Cleanup ---------------------------------------------------------------------------------
  const unsubSettings = subscribe('settings', () => { input.placeholder = `Message ${c.name}...`; });
  ctx.signal.addEventListener('abort', () => {
    if (generating) engine.cancel();
    voice.stopSpeaking();
    unsubEngine();
    unsubSettings();
  });

  // Voices can arrive after the first paint; voice notes show as text until then.
  voice.loadVoices().then(() => {
    if (!ctx.signal.aborted && !editingID && conv.messages.some((m) => extraOf(m).attachment?.kind === 'voice')) paint({ keepScroll: true });
  });

  // Coming back to a chat whose newest message was a worrying one brings the help card back.
  const lastSaid = [...conv.messages].reverse().find((m) => m.role === 'user');
  if (lastSaid) {
    const level = assess(safetyText(lastSaid)).level;
    if (level !== 'none') flaggedThisVisit = true;
    raiseSafety(level);
  }

  paintWhere();
  paint();
  syncSend();
  requestAnimationFrame(() => {
    scrollToEnd();
    if (!matchMedia('(pointer: coarse)').matches) input.focus({ preventScroll: true });
  });
  return page;
}
