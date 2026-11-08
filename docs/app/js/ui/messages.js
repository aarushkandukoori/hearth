// Message pieces shared by 1:1 chats and group scenes: character/user rows, voice note bubbles,
// picture cards (bundled art or a drawn postcard), user photos and the typing indicator.

import { h, avatar, richText, attachImage } from './components.js';
import { icon } from './icons.js';
import { formatDuration } from '../util.js';
import * as voice from '../media/voice.js';
import { textOf, attachmentOf } from '../chats.js';

/** Three bouncing dots. */
export function typingDots(label = 'Typing') {
  return h('span', { class: 'typing', role: 'status', 'aria-label': label }, h('i'), h('i'), h('i'));
}

/** A character's picture: bundled art when it matched, else a postcard drawn with CSS. */
export function pictureCard(att) {
  const colors = att.postcard?.colors || ['#3A2A20', '#F6C177'];
  const card = h('figure', { class: 'picture-card' });
  const frame = h('div', { class: 'picture-frame', style: { '--pc-a': colors[0], '--pc-b': colors[1] } },
    h('span', { class: 'postcard-emoji', 'aria-hidden': 'true' }, att.postcard?.emoji || '📷'),
    h('span', { class: 'postcard-stamp', 'aria-hidden': 'true' }, 'Lantern Bay'));
  if (att.src) attachImage(frame, att.src, { alt: att.caption || 'A picture' });
  else frame.setAttribute('role', 'img');
  if (!att.src) frame.setAttribute('aria-label', att.caption ? `Postcard: ${att.caption}` : 'Postcard');
  card.append(frame);
  if (att.caption) card.append(h('figcaption', {}, att.caption));
  return card;
}

/** A photo the user sent (stored as a downscaled data URL), with what the model saw in it, if it looked. */
export function photoThumb(att) {
  const fig = h('figure', { class: 'photo-thumb' });
  const about = att.caption || att.description;
  if (att.dataURL) fig.append(h('img', { src: att.dataURL, alt: about ? `Your photo: ${about}` : 'Your photo', decoding: 'async' }));
  if (att.caption || att.description) {
    fig.append(h('figcaption', {},
      att.caption || null,
      att.description ? h('span', { class: 'photo-seen' }, `Seen as: ${att.description}`) : null));
  }
  return fig;
}

/**
 * Voice note bubble: play/pause, 32-bar waveform with progress, duration, transcript toggle.
 * Falls back to plain text when this device has no local voice.
 */
export function voiceNote(att, { character, text, voiceURI = '' }) {
  const transcript = text || att.caption || '';
  if (!voice.hasLocalVoice()) return richText(transcript, { className: 'rich msg-text' });
  const bars = att.waveform?.length ? att.waveform : voice.waveformFor(transcript);
  const duration = att.duration || voice.estimateDuration(transcript, character);
  const playBtn = h('button', { class: 'vn-play', type: 'button', 'aria-label': 'Play voice note' }, icon('play', { size: 18 }));
  const barEls = bars.map((b) => h('i', { style: { '--b': b } }));
  const wave = h('div', { class: 'vn-wave', 'aria-hidden': 'true' }, barEls);
  const time = h('span', { class: 'vn-time' }, formatDuration(duration));
  const textEl = richText(transcript, { className: 'rich vn-transcript' });
  textEl.hidden = true;
  const toggle = h('button', { class: 'vn-toggle', type: 'button', 'aria-expanded': 'false' }, icon('text', { size: 15 }), 'Transcript');
  toggle.addEventListener('click', () => {
    textEl.hidden = !textEl.hidden;
    toggle.setAttribute('aria-expanded', textEl.hidden ? 'false' : 'true');
  });
  const root = h('div', { class: 'voice-note' },
    h('div', { class: 'vn-row' }, playBtn, wave, time), h('div', { class: 'vn-foot' }, toggle), textEl);
  let playing = null;
  const setProgress = (p) => barEls.forEach((el, i) => el.classList.toggle('on', p > 0 && i / barEls.length <= p));
  const reset = () => {
    playing = null;
    root.classList.remove('playing');
    playBtn.replaceChildren(icon('play', { size: 18 }));
    playBtn.setAttribute('aria-label', 'Play voice note');
    time.textContent = formatDuration(duration);
  };
  playBtn.addEventListener('click', () => {
    if (playing) { playing.stop(); reset(); setProgress(0); return; }
    root.classList.add('playing');
    playBtn.replaceChildren(icon('pause', { size: 18 }));
    playBtn.setAttribute('aria-label', 'Pause voice note');
    playing = voice.speak(transcript, character, {
      voiceURI,
      onProgress: (p) => { setProgress(p); time.textContent = formatDuration(duration * p); },
      onEnd: () => { reset(); setTimeout(() => setProgress(0), 600); },
    });
  });
  setProgress(0);
  return root;
}

/** The body of a message: text, voice note, picture or photo (plus text). */
export function messageBody(message, { character, voiceURI = '' } = {}) {
  const text = textOf(message);
  const att = attachmentOf(message);
  const parts = [];
  if (att?.kind === 'voice') return voiceNote(att, { character, text, voiceURI });
  if (att?.kind === 'photo') parts.push(photoThumb(att));
  if (text.trim()) parts.push(richText(text, { className: 'rich msg-text' }));
  if (att?.kind === 'picture') parts.push(pictureCard(att));
  return h('div', { class: 'msg-body' }, parts);
}

/**
 * One message row.
 * Character rows: avatar + name + body (no heavy bubble). User rows: right-aligned surface bubble.
 * `tools` (a Node) is placed under the body (swipe arrows, rating), `menuButton` beside it.
 */
export function messageRow(message, { character = null, isUser = false, tools = null, menuButton = null, badge = null, voiceURI = '' } = {}) {
  if (isUser) {
    return h('div', { class: 'msg msg-user', dataset: { id: message.id } },
      h('div', { class: 'msg-user-wrap' },
        menuButton ? h('div', { class: 'msg-menu' }, menuButton) : null,
        h('div', { class: 'msg-bubble' }, messageBody(message, {}))),
      tools);
  }
  return h('div', { class: 'msg msg-char', dataset: { id: message.id } },
    h('a', { class: 'msg-avatar', href: character ? `#/c/${encodeURIComponent(character.id)}` : null, tabindex: '-1', 'aria-hidden': 'true' },
      avatar(character, { size: 36 })),
    h('div', { class: 'msg-main' },
      h('div', { class: 'msg-head' },
        h('span', { class: 'msg-name' }, character?.name || 'Someone'),
        badge,
        message.pinned ? h('span', { class: 'msg-pin', title: 'Pinned to memory' }, icon('pin', { size: 13 })) : null,
        menuButton ? h('div', { class: 'msg-menu' }, menuButton) : null),
      messageBody(message, { character, voiceURI }),
      tools));
}
