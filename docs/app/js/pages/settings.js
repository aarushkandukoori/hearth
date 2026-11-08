// Settings (#/settings): you (persona), the model (download / delete), voice, pictures, theme,
// town gossip, export / import, "Delete everything", and a plain "what is stored where" section.

import { h, toast, confirm, switchControl, segmented } from '../ui/components.js';
import { icon } from '../ui/icons.js';
import { settings, updateSettings, loadSettings, reloadUserCharacters, emit } from '../data.js';
import { engine, MODELS } from '../engine/engine.js';
import { openModelDialog, noWebGPUText } from '../ui/model-dialog.js';
import * as store from '../store.js';
import * as voice from '../media/voice.js';
import { getTheme, setTheme, onThemeChange } from '../theme.js';
import { RESOURCES } from '../brain/safety.js';
import { debounce, formatBytes } from '../util.js';

function section(id, title, iconName, ...children) {
  return h('section', { class: 'set-section', id: `set-${id}`, 'aria-labelledby': `set-${id}-h` },
    h('h2', { class: 'set-h', id: `set-${id}-h` }, h('span', { class: 'set-h-icon', 'aria-hidden': 'true' }, icon(iconName, { size: 18 })), title),
    ...children);
}

function row(label, hint, control) {
  return h('div', { class: 'set-row' },
    h('div', { class: 'set-row-text' }, h('div', { class: 'set-row-label' }, label), hint ? h('div', { class: 'set-row-hint' }, hint) : null),
    control);
}

function savedNote() {
  const el = h('span', { class: 'saved-note', 'aria-live': 'polite' });
  let t = null;
  return {
    el,
    flash() {
      el.textContent = 'Saved';
      el.classList.add('show');
      clearTimeout(t);
      t = setTimeout(() => el.classList.remove('show'), 1400);
    },
  };
}

function youSection() {
  const s = settings();
  const note = savedNote();
  const nameInput = h('input', { class: 'input', id: 'set-name', type: 'text', maxlength: '40', value: s.persona?.name || '', placeholder: 'What should they call you?', autocomplete: 'nickname' });
  const about = h('textarea', { class: 'textarea', id: 'set-about', maxlength: '600', rows: '4', placeholder: 'A few things you would like characters to know. For example: I work nights, I have a cat named Pepper, and I am learning to bake.' });
  about.value = s.persona?.about || '';
  const save = debounce(async () => {
    await updateSettings({ persona: { name: nameInput.value.trim(), about: about.value.trim() } });
    note.flash();
  }, 450);
  nameInput.addEventListener('input', save);
  about.addEventListener('input', save);
  nameInput.addEventListener('blur', () => save.flush());
  about.addEventListener('blur', () => save.flush());
  return section('you', 'You', 'user',
    h('div', { class: 'field' }, h('label', { class: 'field-label', for: 'set-name' }, 'Your name'), nameInput),
    h('div', { class: 'field' },
      h('label', { class: 'field-label', for: 'set-about' }, 'About you'),
      about,
      h('div', { class: 'field-hint row' }, h('span', { class: 'grow' }, 'Characters read this before every reply. It never leaves this browser.'), note.el)));
}

function modelSection() {
  const wrap = h('div', { class: 'stack' });
  const status = h('div', { class: 'model-status' });
  const choices = h('div', { class: 'model-choices', role: 'radiogroup', 'aria-label': 'Model' });
  const storage = h('p', { class: 'field-hint' });
  wrap.append(status, choices, storage);

  const paintStatus = (snap = engine.snapshot()) => {
    let dot = 'demo';
    let text = 'Demo replies. The real model is not loaded.';
    if (snap.status === 'ready') { dot = 'ready'; text = `Running ${engine.modelInfo(engine.inUseModelId).name} on this device.`; }
    else if (snap.status === 'loading') { dot = 'loading'; text = `Loading, ${Math.round((snap.progress?.fraction || 0) * 100)}%`; }
    else if (snap.status === 'error') { dot = 'error'; text = snap.error || 'The model could not start.'; }
    if (snap.webgpu === false) text = `Demo replies. ${noWebGPUText()}`;
    status.replaceChildren(h('span', { class: `dot dot-${dot}`, 'aria-hidden': 'true' }), h('span', {}, text));
  };

  const paintChoices = async () => {
    const current = settings().modelId || engine.modelId;
    const gpu = await engine.isWebGPUAvailable();
    const cached = {};
    for (const m of MODELS) cached[m.id] = gpu ? await engine.isCached(m.id) : false;
    choices.replaceChildren(...MODELS.map((m) => {
      const selected = m.id === current;
      // The model that writes replies right now, which can differ from the one picked for next time.
      const isLoaded = engine.inUseModelId === m.id;
      const radio = h('input', {
        type: 'radio', name: 'model', value: m.id, checked: selected, id: `model-${m.id}`,
        onChange: async () => {
          await updateSettings({ modelId: m.id });
          engine.setModel(m.id);
          paintChoices();
        },
      });
      const actions = h('div', { class: 'model-actions' });
      if (gpu && !isLoaded) {
        actions.append(h('button', {
          class: 'btn btn-primary btn-sm', type: 'button', disabled: engine.status === 'loading',
          onClick: async () => {
            await updateSettings({ modelId: m.id });
            engine.setModel(m.id);
            await openModelDialog({ modelId: m.id });
            paintChoices();
          },
        }, icon(cached[m.id] ? 'chip' : 'download', { size: 16 }), cached[m.id] ? 'Load' : `Download (${m.sizeLabel})`));
      }
      if (cached[m.id]) {
        actions.append(h('button', {
          class: 'btn btn-ghost btn-sm', type: 'button',
          onClick: async () => {
            const ok = await confirm({ title: `Delete ${m.name}?`, message: `This frees ${m.sizeLabel}. You can download it again later. Chats are not affected.`, confirmLabel: 'Delete download' });
            if (!ok) return;
            await engine.deleteModel(m.id);
            if (settings().modelId === m.id) await updateSettings({ modelOptIn: false });
            toast(`${m.name} was deleted from this browser.`);
            paintChoices();
            paintStorage();
          },
        }, icon('trash', { size: 16 }), 'Delete downloaded model'));
      }
      return h('label', { class: `model-choice${selected ? ' selected' : ''}`, for: `model-${m.id}` },
        radio,
        h('span', { class: 'model-choice-text' },
          h('span', { class: 'model-choice-name' }, `${m.name}`, h('span', { class: 'muted' }, ` · ${m.detail}`),
            isLoaded ? h('span', { class: 'badge accent' }, 'In use') : cached[m.id] ? h('span', { class: 'badge' }, 'Downloaded') : null),
          h('span', { class: 'model-choice-note' }, `${m.note} Download size: ${m.sizeLabel}.`),
          actions));
    }));
  };

  const paintStorage = async () => {
    try {
      const est = await navigator.storage?.estimate?.();
      if (est) storage.textContent = `This site uses about ${formatBytes(est.usage || 0)} on this device${est.quota ? `, out of ${formatBytes(est.quota)} the browser allows` : ''}.`;
    } catch { /* not supported */ }
  };

  let lastInUse = engine.inUseModelId;
  const unsub = engine.subscribe((snap) => {
    paintStatus(snap);
    // A model finished loading or stopped: the "In use" badge and the buttons move with it.
    if (engine.inUseModelId !== lastInUse) { lastInUse = engine.inUseModelId; paintChoices(); }
  });
  paintStatus();
  paintChoices();
  paintStorage();
  const el = section('model', 'Model', 'chip',
    h('p', { class: 'set-intro' }, 'Replies are written by a small language model that runs inside this browser, on your graphics chip. It is downloaded once (model files from Hugging Face, the runtime from GitHub). Your messages are never sent anywhere.'),
    wrap);
  el.__cleanup = unsub;
  return el;
}

function voiceSection() {
  const s = settings();
  const select = h('select', { class: 'select', id: 'set-voice', 'aria-label': 'Voice' });
  const test = h('button', { class: 'btn btn-secondary btn-sm', type: 'button' }, icon('play', { size: 16 }), 'Play a sample');
  const hint = h('p', { class: 'field-hint' });
  const fill = () => {
    const voices = voice.localVoices();
    select.replaceChildren(
      h('option', { value: '' }, 'Automatic (a different voice for each character)'),
      ...voices.map((v) => h('option', { value: v.voiceURI }, `${v.name} (${v.lang})`)));
    select.value = voices.some((v) => v.voiceURI === settings().voiceURI) ? settings().voiceURI : '';
    select.disabled = voices.length === 0;
    test.disabled = voices.length === 0;
    hint.textContent = voices.length
      ? `Only voices installed on this device are used (${voices.length} found), so nothing you hear is sent to a server.`
      : 'No on-device voices were found in this browser, so voice notes show as text. Online voices are skipped on purpose: they send the words to a server.';
  };
  voice.loadVoices().then(fill);
  fill();
  select.addEventListener('change', async () => { await updateSettings({ voiceURI: select.value }); toast('Voice saved.'); });
  test.addEventListener('click', () => {
    voice.speak("Hi there. It's nice to hear from you. The kettle's on whenever you want to talk.", { id: 'sample', name: 'Sample', voice: { pitch: 1, rate: 0.5 } }, { voiceURI: select.value });
  });
  return section('voice', 'Voice and pictures', 'volume',
    row('Voice notes', 'Characters sometimes answer with a short voice note, read by a voice on this device.',
      switchControl({ checked: s.voiceNotesEnabled !== false, label: 'Voice notes', onChange: (v) => updateSettings({ voiceNotesEnabled: v }) })),
    row('Pictures from characters', 'Now and then a character shares a picture of their day (drawn from the town art).',
      switchControl({ checked: s.picturesEnabled !== false, label: 'Pictures from characters', onChange: (v) => updateSettings({ picturesEnabled: v }) })),
    h('div', { class: 'field' }, h('label', { class: 'field-label', for: 'set-voice' }, 'Voice'), h('div', { class: 'row wrap' }, select, test), hint));
}

function appearanceSection() {
  const control = segmented([
    { value: 'system', label: 'System', icon: 'globe' },
    { value: 'light', label: 'Light', icon: 'sun' },
    { value: 'dark', label: 'Dark', icon: 'moon' },
  ], getTheme(), (v) => setTheme(v), { label: 'Theme' });
  const el = section('appearance', 'Appearance', 'palette', row('Theme', 'System follows your device setting.', control));
  el.__cleanup = onThemeChange((t) => {
    control.querySelectorAll('button').forEach((b, i) => b.setAttribute('aria-pressed', ['system', 'light', 'dark'][i] === t ? 'true' : 'false'));
  });
  return el;
}

function townSection() {
  const s = settings();
  return section('town', 'Town', 'map',
    row('Town gossip', 'Things you tell one resident can come up with others, the way news travels in a small town. It starts off, so each conversation stays separate until you turn it on.',
      switchControl({ checked: s.townGossip === true, label: 'Town gossip', onChange: (v) => updateSettings({ townGossip: v }) })));
}

function download(filename, text) {
  const blob = new Blob([text], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = h('a', { href: url, download: filename });
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

function dataSection() {
  const fileInput = h('input', { type: 'file', accept: 'application/json,.json', class: 'sr-only', tabindex: '-1', 'aria-hidden': 'true' });
  fileInput.addEventListener('change', async () => {
    const file = fileInput.files?.[0];
    fileInput.value = '';
    if (!file) return;
    try {
      const text = await file.text();
      const ok = await confirm({
        title: 'Import this backup?', message: 'Chats, memories and characters from the file are added to this browser. Anything with the same id is replaced.',
        confirmLabel: 'Import', danger: false,
      });
      if (!ok) return;
      const counts = await store.importAll(text);
      await loadSettings();
      await reloadUserCharacters();
      emit('conversations', null);
      emit('settings', settings());
      const skipped = counts.skipped ? ` ${counts.skipped} damaged ${counts.skipped === 1 ? 'item was' : 'items were'} left out.` : '';
      toast(`Imported ${counts.conversations} chats, ${counts.characters} characters and ${counts.memories} memories.${skipped}`, { tone: 'success', duration: 4000 });
    } catch (err) {
      toast(err?.message || "That backup couldn't be imported.", { tone: 'danger' });
    }
  });
  const exportBtn = h('button', {
    class: 'btn btn-secondary', type: 'button',
    onClick: async () => {
      const data = await store.exportAll();
      download(`hearth-backup-${new Date().toISOString().slice(0, 10)}.json`, JSON.stringify(data, null, 1));
      toast('Backup saved to your downloads.', { tone: 'success' });
    },
  }, icon('download', { size: 18 }), 'Export a backup');
  const importBtn = h('button', { class: 'btn btn-secondary', type: 'button', onClick: () => fileInput.click() }, icon('upload', { size: 18 }), 'Import a backup');
  const wipeBtn = h('button', { class: 'btn btn-danger', type: 'button', onClick: deleteEverything }, icon('trash', { size: 18 }), 'Delete everything');
  // Whether this browser has promised to keep the data (Safari clears unprotected sites after 7 days away).
  const keepNote = h('p', { class: 'field-hint' });
  store.isPersisted().then((kept) => {
    keepNote.textContent = kept
      ? 'This browser has promised to keep Hearth\'s data until you delete it.'
      : 'This browser may clear Hearth\'s data on its own. Safari does this after 7 days of browsing without a visit, unless Hearth is on your Home Screen (Share, then Add to Home Screen) or in your Dock (File, then Add to Dock). That copy keeps its own data, so bring your chats over with a backup. Either way, export a backup now and then.';
  });
  return section('data', 'Your data', 'database',
    h('p', { class: 'set-intro' }, 'A backup is one JSON file with your chats, memories, characters and settings. It is not encrypted, so keep it somewhere private.'),
    h('div', { class: 'row wrap' }, exportBtn, importBtn, fileInput),
    keepNote,
    h('hr'),
    row('Delete everything', 'Removes every chat, memory, character you made and setting from this browser.', wipeBtn));
}

async function deleteEverything() {
  const box = { label: 'Also delete the downloaded model files', checked: true };
  const ok = await confirm({
    title: 'Delete everything?',
    message: "All chats, memories, characters you made and settings will be erased from this browser. This can't be undone.",
    confirmLabel: 'Delete everything', checkbox: box,
  });
  if (!ok) return;
  try {
    await store.clearAll();
    if (box.checked) await engine.deleteAllModels();
    try {
      for (const key of Object.keys(localStorage)) if (key.startsWith('hearth') || key === 'loglevel') localStorage.removeItem(key);
      sessionStorage.clear();
    } catch { /* storage blocked */ }
    toast('Everything was deleted. Starting fresh.', { tone: 'success' });
    setTimeout(() => { location.hash = '#/'; location.reload(); }, 700);
  } catch {
    toast("Some data couldn't be deleted. Try again, or clear this site's data in your browser settings.", { tone: 'danger', duration: 5000 });
  }
}

function privacySection() {
  const item = (iconName, title, body) => h('li', { class: 'privacy-item' },
    h('span', { class: 'privacy-icon', 'aria-hidden': 'true' }, icon(iconName, { size: 18 })),
    h('span', {}, h('strong', {}, title), h('span', { class: 'text-2' }, body)));
  return section('privacy', 'What is stored where', 'shield',
    h('ul', { class: 'privacy-list' },
      item('database', 'Chats, memories, characters and photos', 'In this browser on this device (IndexedDB). Photos are shrunk first, which also strips location data.'),
      item('chip', 'The model', "In this browser's cache for this site, after a one-time download from Hugging Face (model files) and GitHub (runtime)."),
      item('palette', 'Theme and sidebar', 'In this browser (localStorage).'),
      item('globe', 'Sent to a server', 'Nothing. There are no accounts, no analytics, no ads and no cookies. The only network use is that one model download.'),
      item('volume', 'Voices', 'Only voices installed on this device read messages aloud. Online voices are skipped.'),
      // Browsers keep data per web address, and a github.io address is shared by all of its owner's project sites.
      location.hostname.endsWith('.github.io')
        ? item('lock', 'A shared web address', `This web version runs on ${location.hostname}, which also hosts the developer's other projects. Browsers keep data per address, so pages there could read what Hearth stores in this browser. For the most privacy, use the iPhone app.`)
        : null),
    h('p', { class: 'field-hint' }, 'Clearing this site\'s data in your browser also removes everything. ', h('a', { class: 'link', href: 'privacy/' }, 'Read the privacy page')));
}

function helpSection() {
  return section('help', 'If you need help now', 'lifebuoy',
    h('p', { class: 'set-intro' }, 'Hearth characters are AI and can\'t help in an emergency. Real people can, any time:'),
    h('ul', { class: 'help-list' }, RESOURCES.map((r) => h('li', {},
      h('strong', {}, r.title), h('span', { class: 'text-2' }, ` · ${r.detail}`),
      h('span', { class: 'help-actions' }, r.actions.map((a) => h('a', { class: 'link', href: a.href, target: a.external ? '_blank' : null, rel: a.external ? 'noopener noreferrer' : null }, a.label)))))),
    h('p', { class: 'field-hint' }, h('a', { class: 'link', href: 'safety/' }, 'How Hearth handles safety')));
}

function aboutSection() {
  const ext = (href, text) => h('a', { class: 'link', href, target: '_blank', rel: 'noopener noreferrer' }, text);
  return section('about', 'About Hearth', 'flame',
    h('p', { class: 'set-intro' }, 'A little town of friends that lives on your device. Hearth characters are AI. What they say is made up.'),
    h('div', { class: 'row wrap' },
      h('a', { class: 'btn btn-secondary', href: 'iphone/' }, icon('phone', { size: 18 }), 'Get the iPhone app'),
      h('a', { class: 'btn btn-ghost', href: 'privacy/' }, 'Privacy'),
      h('a', { class: 'btn btn-ghost', href: 'safety/' }, 'Safety')),
    h('div', { class: 'credits' },
      h('div', { class: 'set-row-label' }, 'Credits and licenses'),
      h('p', { class: 'field-hint' }, h('strong', {}, 'Built with Llama. '),
        'Llama 3.2 is licensed under the Llama 3.2 Community License, Copyright © Meta Platforms, Inc. All Rights Reserved. ',
        ext('https://www.llama.com/llama3_2/license/', 'License'), ' · ', ext('https://www.llama.com/llama3_2/use-policy', 'Acceptable Use Policy')),
      h('p', { class: 'field-hint' }, 'Runs on WebLLM (Apache 2.0). ', ext('https://github.com/mlc-ai/web-llm/blob/main/LICENSE', 'License'))));
}

export function renderSettings(ctx) {
  ctx.setTitle('Settings');
  const parts = [youSection(), modelSection(), voiceSection(), appearanceSection(), townSection(), dataSection(), privacySection(), helpSection(), aboutSection()];
  const page = h('div', { class: 'page narrow settings-page' },
    h('header', { class: 'page-head' }, h('h1', { class: 'page-title serif' }, 'Settings'),
      h('p', { class: 'page-sub' }, store.persistent ? 'Everything here stays in this browser.' : 'This browser is blocking storage (private window?), so changes last only until you close it.')),
    ...parts);
  ctx.signal.addEventListener('abort', () => parts.forEach((p) => p.__cleanup?.()));
  if (ctx.query.section) {
    requestAnimationFrame(() => document.getElementById(`set-${ctx.query.section}`)?.scrollIntoView({ block: 'start' }));
  }
  return page;
}
