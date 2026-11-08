// "Load the real model" dialog: honest consent copy, download/load progress, and friendly errors.
// The download is the only network use in Hearth: model files from Hugging Face, the runtime from GitHub.

import { h, modal, toast } from './components.js';
import { icon } from './icons.js';
import { engine } from '../engine/engine.js';
import { updateSettings, settings } from '../data.js';
import { formatBytes } from '../util.js';

/** Plain explanation shown when WebGPU is missing. */
export function noWebGPUText() {
  return "This browser can't run the model yet, because it needs WebGPU. Try a recent Chrome or Edge on a computer, or Safari on a Mac or iPhone with the latest system. On iPhone, the Hearth app runs it natively.";
}

async function storageLine() {
  try {
    const est = await navigator.storage?.estimate?.();
    if (!est?.quota) return null;
    const free = est.quota - (est.usage || 0);
    return `Free space this site can use: about ${formatBytes(free)}.`;
  } catch {
    return null;
  }
}

/**
 * Opens the dialog. Resolves true when the model is ready, false if the user closed it first.
 * Loading keeps going in the background if the dialog is hidden.
 */
export async function openModelDialog({ modelId = settings().modelId || engine.modelId } = {}) {
  const info = engine.modelInfo(modelId);
  const gpu = await engine.isWebGPUAvailable();

  if (!gpu) {
    modal({
      title: 'The real model needs WebGPU',
      body: h('div', { class: 'stack' },
        h('p', { class: 'text-2' }, noWebGPUText()),
        h('p', { class: 'text-2' }, 'You can keep chatting with demo replies. They are simple canned lines, clearly marked.')),
      actions: [{ label: 'Got it', variant: 'primary', autofocus: true }],
    });
    return false;
  }

  return new Promise((resolve) => {
    let started = false; // a download/load is running (from here or from startup)
    let busy = false;    // this dialog's button is waiting on it
    let unsub = null;
    const bar = h('div', { class: 'progress', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-valuenow': '0', 'aria-label': 'Model download' }, h('span'));
    const status = h('p', { class: 'progress-text', 'aria-live': 'polite' }, '');
    const progressBox = h('div', { class: 'progress-box', hidden: true }, bar, status,
      h('p', { class: 'field-hint' }, 'You can close this window and keep chatting with demo replies while it finishes.'));
    const errorBox = h('p', { class: 'form-error', role: 'alert', hidden: true });
    const space = h('p', { class: 'field-hint' });
    storageLine().then((t) => { if (t) space.textContent = t; });

    const body = h('div', { class: 'stack model-dialog' },
      h('div', { class: 'model-hero' },
        h('span', { class: 'model-hero-icon' }, icon('chip', { size: 26 })),
        h('div', {}, h('strong', {}, `${info.name} (${info.detail})`), h('span', { class: 'muted' }, `${info.sizeLabel}, downloaded once`))),
      h('p', { class: 'text-2' }, `${info.name} runs right here in your browser, on your own graphics chip. The first time, your browser downloads ${info.sizeLabel}: the model files from Hugging Face and the model runtime from GitHub.`),
      h('ul', { class: 'promise-list' },
        h('li', {}, icon('lock', { size: 16 }), 'Your chats never leave this browser. Nothing you type is sent anywhere.'),
        h('li', {}, icon('download', { size: 16 }), "After this one download, it loads from this browser's cache instead of downloading again."),
        h('li', {}, icon('trash', { size: 16 }), 'You can delete the download any time in Settings.')),
      space,
      h('p', { class: 'field-hint' }, 'Built with Llama. Llama 3.2 is licensed under the ',
        h('a', { class: 'link', href: 'https://www.llama.com/llama3_2/license/', target: '_blank', rel: 'noopener noreferrer' }, 'Llama 3.2 Community License'),
        ', Copyright © Meta Platforms, Inc. All Rights Reserved.'),
      progressBox, errorBox);

    const paint = (s) => {
      if (s.status === 'loading' && s.progress) {
        progressBox.hidden = false;
        const pct = Math.round((s.progress.fraction || 0) * 100);
        bar.style.setProperty('--value', `${pct}%`);
        bar.setAttribute('aria-valuenow', String(pct));
        status.textContent = s.progress.phase === 'download'
          ? `Downloading, ${pct}%${s.progress.mb ? ` (${Math.round(s.progress.mb)} MB so far)` : ''}`
          : s.progress.phase === 'load' ? `Loading from this device, ${pct}%` : `Getting the model ready, ${pct}%`;
      }
    };

    const handle = modal({
      title: 'Load the real model',
      body,
      className: 'model-modal',
      actions: [
        { label: 'Not now', variant: 'ghost' },
        {
          label: 'Download and load', variant: 'primary', autofocus: true, id: 'model-go',
          onClick: async (dlg) => {
            if (busy) return false;
            busy = true;
            started = true;
            errorBox.hidden = true;
            const go = dlg.el.querySelector('#model-go');
            if (go) { go.textContent = 'Working...'; }
            unsub = engine.subscribe(paint);
            paint(engine.snapshot());
            try {
              await engine.init({ modelId });
              await updateSettings({ modelOptIn: true, modelId });
              toast(`${info.name} is ready. Replies now come from the model on this device.`, { tone: 'success', duration: 4200 });
              unsub?.();
              resolve(true);
              return true;
            } catch (err) {
              started = false;
              busy = false;
              unsub?.();
              errorBox.textContent = err?.message || 'The model could not start.';
              errorBox.hidden = false;
              progressBox.hidden = true;
              if (go) go.textContent = 'Try again';
              return false;
            }
          },
        },
      ],
      onClose: (reason) => {
        if (reason !== 'action') {
          unsub?.();
          if (started) toast('Still loading in the background. Demo replies until it is ready.');
          resolve(false);
        }
      },
    });
    if (engine.status === 'loading') { started = true; unsub = engine.subscribe(paint); paint(engine.snapshot()); }
    return handle;
  });
}
