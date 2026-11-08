// Create or edit a character (#/create, #/create/:id, and #/create?edit=<id> from the profile page).
// Avatar (your picture, shrunk in the browser, or an emoji on a color), the basics, a "Definition" section,
// a voice, a live preview, Character Card import / export and delete. Everything stays in this browser.

import { h, avatar, characterCard, richText, toast, confirm, emptyState, chip } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { world, getCharacter, getLocation, saveUserCharacter, deleteUserCharacter, settings, userName } from '../data.js';
import { downscaleImage } from '../media/photos.js';
import * as voice from '../media/voice.js';
import { navigate } from '../router.js';
import { uid, fillNames, debounce, pick } from '../util.js';
import { CardError, cardFromPNG, cardToDraft, characterToCard, slug } from './cards.js';

const EMOJIS = ['🦊', '🦦', '🐢', '🦔', '🐼', '🐈', '🐕', '🦉', '🐻', '🐰', '🐨', '🦝', '🦌', '🐧', '🪿', '🐸',
  '🐙', '🐳', '🦄', '🐲', '🤖', '👻', '🌻', '🍄', '🌙', '⭐', '🔥', '🎸', '📚', '☕', '🧁', '🪴'];
const SWATCHES = [
  { name: 'Ember', colors: ['#3A2A20', '#FF8A4C'] }, { name: 'Sea', colors: ['#243E42', '#40A1B0'] },
  { name: 'Garden', colors: ['#2F3C2A', '#689857'] }, { name: 'Honey', colors: ['#48441E', '#C4B52B'] },
  { name: 'Market', colors: ['#3A1C2A', '#E8735F'] }, { name: 'Plum', colors: ['#302244', '#6D39B7'] },
  { name: 'Night', colors: ['#141B33', '#5D7FD6'] }, { name: 'Rose', colors: ['#471F29', '#C12F53'] },
  { name: 'Moss', colors: ['#254131', '#45AB6F'] }, { name: 'Driftwood', colors: ['#4A3022', '#D9A066'] },
];
const DEFAULT_GREETING = "Hi {{user}}! It's nice to meet you.";
const MAX_CATEGORIES = 3;

function blankDraft() {
  const swatch = pick(SWATCHES);
  return {
    name: '', species: '', tagline: '', bio: '', greeting: '', altGreetings: [], personality: '', speakingStyle: '',
    scenario: '', exampleDialogue: '', categories: [], tags: [], homeLocationID: null, creator: '@you',
    voice: { pitch: 1, rate: 0.5 }, avatar: { emoji: pick(EMOJIS), colors: swatch.colors.slice(), dataURL: null },
  };
}

/** A form draft from a saved character (or an imported card draft). */
function draftFrom(c) {
  const base = blankDraft();
  const colors = Array.isArray(c.avatar?.colors) && c.avatar.colors.length >= 2 ? c.avatar.colors.slice(0, 2) : base.avatar.colors;
  return {
    ...base,
    name: c.name || '', species: c.species || '', tagline: c.tagline || '', bio: c.bio || '',
    greeting: c.greeting || '', altGreetings: Array.isArray(c.altGreetings) ? c.altGreetings.slice() : [],
    personality: c.personality || '', speakingStyle: c.speakingStyle || '', scenario: c.scenario || '',
    exampleDialogue: c.exampleDialogue || '', tags: Array.isArray(c.tags) ? c.tags.slice() : [],
    categories: (Array.isArray(c.categories) ? c.categories : []).filter((id) => world()?.categories?.some((x) => x.id === id)).slice(0, MAX_CATEGORIES),
    homeLocationID: c.homeLocationID && getLocation(c.homeLocationID) ? c.homeLocationID : null,
    creator: c.creator || '@you',
    voice: { pitch: 1, rate: 0.5, ...(c.voice || {}) },
    avatar: { emoji: c.avatar?.emoji || base.avatar.emoji, colors, dataURL: c.avatar?.dataURL || null },
    accentHex: c.accentHex || null,
  };
}

function download(filename, text) {
  const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
  const a = h('a', { href: url, download: filename });
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

function dataURLToBlob(url) {
  const [head, body] = url.split(',');
  const bin = atob(body);
  return new Blob([Uint8Array.from(bin, (ch) => ch.charCodeAt(0))], { type: head.match(/^data:([^;]+)/)?.[1] || 'image/png' });
}

/** The first emoji (or character) someone typed. */
function firstGlyph(text) {
  const t = String(text || '').trim();
  if (!t) return '';
  if (typeof Intl !== 'undefined' && Intl.Segmenter) return [...new Intl.Segmenter().segment(t)][0]?.segment || '';
  return Array.from(t)[0];
}

function cannotEdit(ctx, c) {
  ctx.setTitle(c ? c.name : 'Not found');
  return h('div', { class: 'page narrow' }, emptyState({
    iconName: c ? 'lock' : 'users',
    title: c ? `${c.name} belongs to Lantern Bay` : "We couldn't find that character",
    body: c ? "The town's residents can't be changed here, but you can make a character of your own." : 'They may have been deleted from this browser.',
    action: h('div', { class: 'row wrap', style: { justifyContent: 'center' } },
      h('a', { class: 'btn btn-primary', href: '#/create' }, icon('plus', { size: 18 }), 'Create a character'),
      c ? h('a', { class: 'btn btn-secondary', href: `#/c/${encodeURIComponent(c.id)}` }, 'View profile') : null),
  }));
}

export function renderCreate(ctx) {
  const editID = ctx.params.id || ctx.query.edit || null;
  const editing = editID ? getCharacter(editID) : null;
  if (editID && (!editing || editing.isBuiltIn)) return cannotEdit(ctx, editing);
  // The name stays out of the tab title (and so out of synced browser history).
  ctx.setTitle(editing ? 'Edit character' : 'Create a character');

  const id = editing?.id || `u-${uid()}`;
  let draft = editing ? draftFrom(editing) : blankDraft();
  let saving = false;
  const controls = {};   // key -> { control, sync, error }
  const w = world();

  /** The character as it would be saved right now. */
  function buildCharacter() {
    const d = draft;
    const colors = d.avatar.colors?.length >= 2 ? d.avatar.colors.slice(0, 2) : SWATCHES[0].colors;
    const v = { pitch: Number(d.voice.pitch) || 1, rate: Number(d.voice.rate) || 0.5 };
    if (d.voice.preferredVoiceNames?.length) { v.preferredVoiceNames = d.voice.preferredVoiceNames.slice(0, 1); v.locale = d.voice.locale; }
    if (d.voice.gender) v.gender = d.voice.gender;
    return {
      id,
      name: d.name.trim().replace(/\s+/g, ' '),
      species: d.species.trim() || null,
      tagline: d.tagline.trim(),
      bio: d.bio.trim(),
      greeting: d.greeting.trim() || DEFAULT_GREETING,
      altGreetings: d.altGreetings.map((g) => g.trim()).filter(Boolean),
      personality: d.personality.trim(),
      speakingStyle: d.speakingStyle.trim(),
      scenario: d.scenario.trim() || null,
      exampleDialogue: d.exampleDialogue.trim() || null,
      categories: d.categories.slice(0, MAX_CATEGORIES),
      tags: d.tags.slice(0, 12),
      avatar: { emoji: d.avatar.emoji || null, colors, ...(d.avatar.dataURL ? { dataURL: d.avatar.dataURL } : {}) },
      accentHex: colors[1],
      voice: v,
      media: editing?.media || { voiceNoteChance: 0.12, photoChance: 0.08, photoIdeas: [] },
      homeLocationID: d.homeLocationID || null,
      schedule: [],
      relationships: [],
      creator: d.creator || '@you',
      createdAt: editing?.createdAt || Date.now(),
      updatedAt: Date.now(),
    };
  }

  // ---- Fields --------------------------------------------------------------------------------
  /** A text input or textarea bound to draft[key]. `get`/`set` convert lists (tags, other greetings). */
  function textField(key, { label, max, rows = 0, placeholder = '', hint = null, required = false, get = null, set = null }) {
    const fid = `cr-${key}`;
    const control = rows
      ? h('textarea', { class: 'textarea', id: fid, rows: String(rows), maxlength: String(max), placeholder })
      : h('input', { class: 'input', id: fid, type: 'text', maxlength: String(max), placeholder, autocomplete: 'off', spellcheck: key === 'name' ? 'false' : null });
    const count = h('span', { class: 'cr-count', 'aria-hidden': 'true' });
    const error = h('p', { class: 'form-error', id: `${fid}-err`, role: 'alert', hidden: true });
    const describedBy = [hint ? `${fid}-hint` : null, `${fid}-err`].filter(Boolean).join(' ');
    control.setAttribute('aria-describedby', describedBy);
    const sync = () => {
      control.value = get ? get(draft[key]) : (draft[key] || '');
      count.textContent = `${control.value.length}/${max}`;
    };
    control.addEventListener('input', () => {
      draft[key] = set ? set(control.value) : control.value;
      count.textContent = `${control.value.length}/${max}`;
      if (!error.hidden) { error.hidden = true; control.removeAttribute('aria-invalid'); }
      changed();
    });
    controls[key] = { control, sync, error };
    sync();
    return h('div', { class: 'field cr-field' },
      h('div', { class: 'cr-label-row' },
        h('label', { class: 'field-label', for: fid }, label, required ? h('span', { class: 'cr-req' }, ' (required)') : null),
        count),
      control,
      hint ? h('p', { class: 'field-hint', id: `${fid}-hint` }, hint) : null,
      error);
  }

  // Avatar: your picture, or an emoji on a color.
  const avatarBox = h('div', { class: 'cr-avatar-preview' });
  const fileInput = h('input', { type: 'file', accept: 'image/*', class: 'sr-only', tabindex: '-1', 'aria-hidden': 'true' });
  const uploadBtn = h('button', { class: 'btn btn-secondary btn-sm', type: 'button', onClick: () => fileInput.click() }, icon('image', { size: 16 }), 'Upload a picture');
  const removePicBtn = h('button', { class: 'btn btn-ghost btn-sm', type: 'button' }, icon('x', { size: 16 }), 'Remove picture');
  const emojiGrid = h('div', { class: 'cr-emojis', role: 'group', 'aria-label': 'Emoji' });
  const emojiInput = h('input', { class: 'input cr-emoji-input', type: 'text', maxlength: '16', placeholder: 'Or type one', 'aria-label': 'Type an emoji', autocomplete: 'off' });
  const swatchRow = h('div', { class: 'cr-swatches', role: 'group', 'aria-label': 'Color' });

  function paintAvatar() {
    const c = buildCharacter();
    avatarBox.replaceChildren(avatar(c, { size: 112, shape: 'rounded', alt: c.name ? `${c.name}'s picture` : 'Avatar preview' }));
    removePicBtn.hidden = !draft.avatar.dataURL;
    uploadBtn.lastChild.textContent = draft.avatar.dataURL ? 'Change picture' : 'Upload a picture';
    emojiGrid.replaceChildren(...EMOJIS.map((e) => h('button', {
      type: 'button', class: 'cr-emoji', 'aria-pressed': draft.avatar.emoji === e ? 'true' : 'false', 'aria-label': `Use ${e}`,
      onClick: () => { draft.avatar.emoji = e; emojiInput.value = ''; paintAvatar(); changed(); },
    }, e)));
    swatchRow.replaceChildren(...SWATCHES.map((s) => h('button', {
      type: 'button', class: 'cr-swatch', title: s.name, 'aria-label': s.name,
      'aria-pressed': draft.avatar.colors?.[1] === s.colors[1] ? 'true' : 'false',
      style: { '--sa': s.colors[0], '--sb': s.colors[1] },
      onClick: () => { draft.avatar.colors = s.colors.slice(); paintAvatar(); changed(); },
    })));
  }

  fileInput.addEventListener('change', async () => {
    const file = fileInput.files?.[0];
    fileInput.value = '';
    if (!file) return;
    try {
      const { dataURL } = await downscaleImage(file, { maxSide: 512, quality: 0.86 });
      draft.avatar.dataURL = dataURL;
      paintAvatar();
      changed();
    } catch (err) {
      toast(err?.message || "That picture couldn't be opened.", { tone: 'danger' });
    }
  });
  removePicBtn.addEventListener('click', () => { draft.avatar.dataURL = null; paintAvatar(); changed(); });
  emojiInput.addEventListener('input', () => {
    const g = firstGlyph(emojiInput.value);
    if (!g) return;
    draft.avatar.emoji = g;
    paintAvatar();
    changed();
  });

  const avatarSection = h('section', { class: 'cr-card cr-avatar', 'aria-labelledby': 'cr-avatar-h' },
    h('h2', { class: 'cr-h', id: 'cr-avatar-h' }, 'Picture'),
    h('div', { class: 'cr-avatar-row' },
      avatarBox,
      h('div', { class: 'cr-avatar-controls' },
        h('div', { class: 'row wrap' }, uploadBtn, removePicBtn, fileInput),
        h('p', { class: 'field-hint' }, 'Pictures are shrunk and kept only in this browser. Without one, the emoji and color below are used.'))),
    h('div', { class: 'cr-sub' }, h('span', { class: 'field-label' }, 'Emoji'), emojiGrid, emojiInput),
    h('div', { class: 'cr-sub' }, h('span', { class: 'field-label' }, 'Color'), swatchRow));

  // Categories and home.
  const catRow = h('div', { class: 'cr-chips', role: 'group', 'aria-labelledby': 'cr-cat-label' });
  function paintCategories() {
    catRow.replaceChildren(...(w?.categories || []).map((cat) => chip({
      label: cat.title, emoji: cat.emoji, active: draft.categories.includes(cat.id),
      onClick: () => {
        if (draft.categories.includes(cat.id)) draft.categories = draft.categories.filter((x) => x !== cat.id);
        else if (draft.categories.length >= MAX_CATEGORIES) { toast(`Pick up to ${MAX_CATEGORIES} categories.`); return; }
        else draft.categories = [...draft.categories, cat.id];
        paintCategories();
        changed();
      },
    })));
  }
  const homeSelect = h('select', { class: 'select', id: 'cr-home', 'aria-describedby': 'cr-home-hint' },
    h('option', { value: '' }, 'Not in town (just chats)'),
    ...(w?.locations || []).map((l) => h('option', { value: l.id }, `${l.emoji || '📍'} ${l.name}`)));
  homeSelect.addEventListener('change', () => { draft.homeLocationID = homeSelect.value || null; changed(); });

  // Voice.
  const voiceSelect = h('select', { class: 'select', id: 'cr-voice', 'aria-describedby': 'cr-voice-hint' });
  const pitch = h('input', { type: 'range', class: 'cr-range', id: 'cr-pitch', min: '0.6', max: '1.6', step: '0.05' });
  const rate = h('input', { type: 'range', class: 'cr-range', id: 'cr-rate', min: '0.3', max: '0.8', step: '0.02' });
  const pitchOut = h('output', { class: 'cr-range-out', for: 'cr-pitch' });
  const rateOut = h('output', { class: 'cr-range-out', for: 'cr-rate' });
  const sampleBtn = h('button', { class: 'btn btn-secondary btn-sm', type: 'button' }, icon('play', { size: 16 }), 'Hear a sample');
  const voiceHint = h('p', { class: 'field-hint', id: 'cr-voice-hint' });

  function paintVoice() {
    const voices = voice.localVoices();
    const wanted = (draft.voice.preferredVoiceNames?.[0] || '').toLowerCase();
    const lang = (draft.voice.locale || '').toLowerCase();
    const current = wanted ? voices.find((v) => v.name.toLowerCase() === wanted && (!lang || v.lang?.toLowerCase() === lang))
      || voices.find((v) => v.name.toLowerCase().includes(wanted)) : null;
    voiceSelect.replaceChildren(
      h('option', { value: '' }, 'Automatic (picked for them)'),
      ...voices.map((v) => h('option', { value: v.voiceURI }, `${v.name} (${v.lang})`)));
    voiceSelect.value = current ? current.voiceURI : '';
    pitch.value = String(draft.voice.pitch ?? 1);
    rate.value = String(draft.voice.rate ?? 0.5);
    pitchOut.textContent = `${Number(pitch.value).toFixed(2)}x`;
    rateOut.textContent = `${(Number(rate.value) * 2).toFixed(2)}x`;
    const none = voices.length === 0;
    [voiceSelect, pitch, rate, sampleBtn].forEach((el) => { el.disabled = none; });
    voiceHint.textContent = none
      ? 'This browser has no on-device voices, so voice notes show as text. Online voices are skipped on purpose: they send the words to a server.'
      : settings().voiceURI
        ? 'Only voices installed on this device are used. Your Settings use one voice for everyone, so chats will use that one.'
        : 'Only voices installed on this device are used, so nothing you hear is sent to a server.';
  }
  voiceSelect.addEventListener('change', () => {
    const v = voice.localVoices().find((x) => x.voiceURI === voiceSelect.value);
    if (v) { draft.voice.preferredVoiceNames = [v.name]; draft.voice.locale = v.lang; } else { delete draft.voice.preferredVoiceNames; delete draft.voice.locale; }
    changed();
  });
  pitch.addEventListener('input', () => { draft.voice.pitch = Number(pitch.value); pitchOut.textContent = `${Number(pitch.value).toFixed(2)}x`; changed(); });
  rate.addEventListener('input', () => { draft.voice.rate = Number(rate.value); rateOut.textContent = `${(Number(rate.value) * 2).toFixed(2)}x`; changed(); });
  sampleBtn.addEventListener('click', () => {
    const c = buildCharacter();
    const line = fillNames(draft.greeting.trim() || `Hi, I'm ${c.name || 'new here'}. It's nice to meet you.`, { user: userName(), char: c.name || 'me' });
    const res = voice.speak(line, c, { voiceURI: '' });
    res.done.then((why) => { if (why === 'unavailable') toast("There's no voice on this device that can read this aloud."); });
  });
  voice.loadVoices().then(() => { if (!ctx.signal.aborted) paintVoice(); });

  // ---- Preview -----------------------------------------------------------------------------------
  const previewCard = h('div', { class: 'cr-preview-card' });
  const previewChat = h('div', { class: 'cr-preview-chat' });
  function paintPreview() {
    const c = buildCharacter();
    if (!c.name) c.name = 'Your character';
    const home = c.homeLocationID ? getLocation(c.homeLocationID) : null;
    const card = characterCard(c, { meta: home ? `Lives at ${home.name.replace(/^The\s/, 'the ')}` : 'Private, in this browser' });
    const still = h('div', { class: `${card.className} cr-card-still`, style: card.getAttribute('style') || '' });
    still.append(...card.childNodes);
    previewCard.replaceChildren(still);
    const greeting = fillNames(c.greeting, { user: userName(), char: c.name });
    previewChat.replaceChildren(
      h('div', { class: 'msg msg-char' },
        h('span', { class: 'msg-avatar' }, avatar(c, { size: 36 })),
        h('div', { class: 'msg-main' },
          h('div', { class: 'msg-head' }, h('span', { class: 'msg-name' }, c.name)),
          richText(greeting, { className: 'rich msg-text' }))),
      h('p', { class: 'chat-disclosure' }, 'Hearth characters are AI. What they say is made up.'));
  }
  const repaint = debounce(() => { paintPreview(); paintAvatarOnly(); }, 90);
  function paintAvatarOnly() {
    avatarBox.replaceChildren(avatar(buildCharacter(), { size: 112, shape: 'rounded', alt: 'Avatar preview' }));
  }
  function changed() { repaint(); }

  // ---- Form --------------------------------------------------------------------------------------
  const nameField = textField('name', { label: 'Name', max: 40, placeholder: 'e.g. Marlow', required: true });
  const form = h('form', { class: 'cr-form', novalidate: true, onSubmit: (e) => { e.preventDefault(); save(); } },
    avatarSection,
    h('section', { class: 'cr-card', 'aria-labelledby': 'cr-basics-h' },
      h('h2', { class: 'cr-h', id: 'cr-basics-h' }, 'The basics'),
      nameField,
      textField('species', { label: 'What kind of creature', max: 40, placeholder: 'e.g. sea otter, little robot, moth', hint: 'Optional. Lantern Bay is a town of animal folk, but anyone can visit.' }),
      textField('tagline', { label: 'Tagline', max: 90, placeholder: 'One line people see on their card', hint: 'Shown on cards in Discover.' }),
      textField('bio', { label: 'Description', max: 600, rows: 3, placeholder: 'How would they introduce themselves?', hint: 'Shown on their profile.' }),
      textField('greeting', { label: 'Greeting', max: 1200, rows: 3, placeholder: DEFAULT_GREETING, hint: 'The first message of every new chat. {{user}} becomes your name. Leave it empty for a simple hello.' }),
      textField('personality', { label: 'Personality', max: 2000, rows: 5, placeholder: 'Who are they? What do they love, worry about, remember? How do they treat a friend?', hint: 'The heart of the character. They read this before every reply.' })),
    h('section', { class: 'cr-card', 'aria-labelledby': 'cr-town-h' },
      h('h2', { class: 'cr-h', id: 'cr-town-h' }, 'In town'),
      h('div', { class: 'field cr-field' }, h('span', { class: 'field-label', id: 'cr-cat-label' }, `Categories (up to ${MAX_CATEGORIES})`), catRow),
      h('div', { class: 'field cr-field' },
        h('label', { class: 'field-label', for: 'cr-home' }, 'Where they spend their days'),
        homeSelect,
        h('p', { class: 'field-hint', id: 'cr-home-hint' }, 'Pick a place and they move into Lantern Bay: they show up on the town map there and join the group conversations.'))),
    h('section', { class: 'cr-card', 'aria-labelledby': 'cr-voice-h' },
      h('h2', { class: 'cr-h', id: 'cr-voice-h' }, 'Voice'),
      h('div', { class: 'field cr-field' }, h('label', { class: 'field-label', for: 'cr-voice' }, 'Voice for voice notes'), voiceSelect, voiceHint),
      h('div', { class: 'cr-ranges' },
        h('div', { class: 'cr-range-field' }, h('label', { class: 'field-label', for: 'cr-pitch' }, 'Pitch'), pitch, pitchOut),
        h('div', { class: 'cr-range-field' }, h('label', { class: 'field-label', for: 'cr-rate' }, 'Speed'), rate, rateOut)),
      h('div', { class: 'row' }, sampleBtn)),
    h('details', { class: 'cr-card cr-advanced' },
      h('summary', { class: 'cr-summary' },
        h('span', { class: 'cr-summary-row' },
          h('span', { class: 'cr-h' }, 'Definition'), h('span', { class: 'badge' }, 'Advanced'),
          h('span', { class: 'grow' }), h('span', { class: 'cr-summary-chev', 'aria-hidden': 'true' }, icon('chevron-down', { size: 18 })))),
      h('div', { class: 'cr-advanced-body' },
        textField('speakingStyle', { label: 'How they talk', max: 600, rows: 3, placeholder: 'e.g. Short, warm sentences. Says "oh!" when excited. Uses an emoji now and then.' }),
        textField('exampleDialogue', { label: 'Example dialogue', max: 2000, rows: 6, placeholder: '{{user}}: I had a long day.\n{{char}}: Oh no. Sit, sit. Want to tell me about it?', hint: 'A few lines showing how they talk. One line each, starting with {{user}}: or {{char}}:.' }),
        textField('altGreetings', {
          label: 'Other greetings', max: 2400, rows: 4, placeholder: 'Leave a blank line between greetings.',
          hint: 'New chats can start with any of these instead. Separate them with a blank line.',
          get: (list) => (list || []).join('\n\n'), set: (text) => text.split(/\n\s*\n/).map((s) => s.trim()).filter(Boolean),
        }),
        textField('scenario', { label: 'Scenario', max: 600, rows: 2, placeholder: 'Where you usually find them, and what is going on.' }),
        textField('tags', {
          label: 'Tags', max: 160, placeholder: 'cozy, good listener, books', hint: 'Separated by commas. They help search find this character.',
          get: (list) => (list || []).join(', '), set: (text) => text.split(',').map((t) => t.trim()).filter(Boolean),
        }))),
    h('p', { class: 'cr-private' }, icon('lock', { size: 16 }),
      h('span', {}, h('strong', {}, 'Private. '), 'This character lives only in this browser. Nothing is uploaded, and nobody else can see them.')));

  // ---- Actions -----------------------------------------------------------------------------------
  const saveBtn = h('button', { class: 'btn btn-primary', type: 'submit' }, icon('check', { size: 18 }), editing ? 'Save changes' : 'Create character');
  const cancelBtn = h('a', { class: 'btn btn-ghost', href: editing ? `#/c/${encodeURIComponent(id)}` : '#/' }, 'Cancel');
  form.append(h('div', { class: 'cr-bar' }, cancelBtn, saveBtn));

  async function save() {
    if (saving) return;
    const c = buildCharacter();
    if (!c.name) {
      const { control, error } = controls.name;
      error.textContent = 'Give your character a name.';
      error.hidden = false;
      control.setAttribute('aria-invalid', 'true');
      control.focus();
      control.scrollIntoView({ block: 'center' });
      return;
    }
    saving = true;
    saveBtn.disabled = true;
    try {
      await saveUserCharacter(c);
      if (editing) {
        toast('Saved.', { tone: 'success' });
        navigate(`#/c/${encodeURIComponent(id)}`);
      } else {
        toast(`${c.name} is ready to chat.`, { tone: 'success' });
        navigate(`#/chat/${encodeURIComponent(id)}`);
      }
    } catch {
      toast("Couldn't save just now. Check that this browser allows storage, then try again.", { tone: 'danger', duration: 4500 });
      saving = false;
      saveBtn.disabled = false;
    }
  }

  async function remove() {
    const ok = await confirm({
      title: `Delete ${editing.name}?`,
      message: 'This removes the character from this browser. Your chats with them stay in Chats until you delete them.',
      confirmLabel: 'Delete character',
    });
    if (!ok) return;
    await deleteUserCharacter(id);
    toast(`${editing.name} was deleted.`);
    navigate('#/', { replace: true });
  }

  function exportCard() {
    const c = buildCharacter();
    if (!c.name) { toast('Give your character a name first.'); controls.name.control.focus(); return; }
    download(`${slug(c.name)}.json`, JSON.stringify(characterToCard(c), null, 2));
    toast('Character card saved to your downloads.', { tone: 'success' });
  }

  // Import: a Character Card V2/V3 as .json, or a .png with the card inside. It fills the form; nothing is saved yet.
  const importInput = h('input', { type: 'file', accept: '.json,.png,application/json,image/png', class: 'sr-only', tabindex: '-1', 'aria-hidden': 'true' });
  importInput.addEventListener('change', async () => {
    const file = importInput.files?.[0];
    importInput.value = '';
    if (!file) return;
    try {
      if (file.size > 25 * 1024 * 1024) throw new CardError('That file is too big to be a character card.');
      const isPNG = file.type === 'image/png' || /\.png$/i.test(file.name);
      let card;
      if (isPNG) card = await cardFromPNG(await file.arrayBuffer());
      else {
        try { card = JSON.parse(await file.text()); } catch { throw new CardError("That file isn't a character card (it isn't valid JSON)."); }
      }
      const { draft: imported, shortened } = cardToDraft(card);
      let picture = imported.avatar.dataURL;
      if (isPNG) picture = (await downscaleImage(file, { maxSide: 512, quality: 0.86 })).dataURL;
      else if (picture && picture.length > 300000) picture = (await downscaleImage(dataURLToBlob(picture), { maxSide: 512, quality: 0.86 })).dataURL;
      draft = draftFrom({ ...imported, avatar: { ...imported.avatar, dataURL: picture } });
      if (!imported.avatar.emoji) draft.avatar.emoji = '✨';
      refreshForm();
      toast(`Imported ${draft.name}. Check the details, then create.${shortened.length ? ' A few long parts were shortened to fit a small model.' : ''}`, { tone: 'success', duration: 5200 });
    } catch (err) {
      toast(err instanceof CardError ? err.message : "That card couldn't be read.", { tone: 'danger', duration: 4200 });
    }
  });

  function refreshForm() {
    for (const { sync } of Object.values(controls)) sync();
    homeSelect.value = draft.homeLocationID || '';
    paintCategories();
    paintAvatar();
    paintVoice();
    paintPreview();
  }

  const headActions = h('div', { class: 'cr-head-actions' });
  if (!editing) {
    headActions.append(h('button', { class: 'btn btn-secondary btn-sm', type: 'button', title: 'Character Card V2 or V3, as .json or .png', onClick: () => importInput.click() },
      icon('upload', { size: 16 }), 'Import a card'), importInput);
  }
  headActions.append(h('button', { class: 'btn btn-ghost btn-sm', type: 'button', onClick: exportCard, title: 'Download as a Character Card V2 (.json)' },
    icon('download', { size: 16 }), 'Export card'));
  if (editing) {
    headActions.append(h('button', { class: 'btn btn-ghost btn-sm cr-delete', type: 'button', onClick: remove }, icon('trash', { size: 16 }), 'Delete'));
  }

  const page = h('div', { class: 'page create-page' },
    h('header', { class: 'page-head cr-head' },
      h('div', {},
        h('h1', { class: 'page-title serif' }, editing ? `Edit ${editing.name}` : 'Create a character'),
        h('p', { class: 'page-sub' }, editing ? 'Changes apply to new replies right away.' : 'Make a friend of your own. They can chat one on one, and if you like, move into Lantern Bay.')),
      headActions),
    h('div', { class: 'cr-grid' },
      form,
      h('aside', { class: 'cr-preview', 'aria-label': 'Preview' },
        h('div', { class: 'cr-preview-inner' },
          h('h2', { class: 'cr-preview-h' }, 'Preview'),
          previewCard,
          h('p', { class: 'cr-preview-label' }, 'First message'),
          previewChat))));

  ctx.signal.addEventListener('abort', () => { repaint.cancel(); voice.stopSpeaking(); });
  refreshForm();
  return page;
}
