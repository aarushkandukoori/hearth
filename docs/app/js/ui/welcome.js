// First visit: a short welcome with an 18+ confirmation and a name, stored only in this browser.

import { h, modal } from './components.js';
import { icon, hearthMark } from './icons.js';
import { updateSettings, settings } from '../data.js';

/** Resolves once the user has confirmed they are 18 or older. */
export function ensureWelcome() {
  const s = settings();
  if (s.onboardingDone && s.confirmedAdult) return Promise.resolve();
  return new Promise((resolve) => {
    const nameInput = h('input', { class: 'input', id: 'welcome-name', type: 'text', maxlength: '40', placeholder: 'A first name or nickname', autocomplete: 'nickname', value: s.persona?.name || '' });
    const adult = h('input', { type: 'checkbox', id: 'welcome-adult' });
    const error = h('p', { class: 'form-error', role: 'alert', hidden: true }, 'Please confirm you are 18 or older to come in.');
    const body = h('div', { class: 'welcome' },
      h('div', { class: 'welcome-mark' }, hearthMark(56)),
      h('h2', { class: 'welcome-title serif', id: 'welcome-title' }, 'Welcome to Hearth'),
      h('p', { class: 'welcome-sub' }, 'A little town of friends that lives on your device.'),
      h('ul', { class: 'promise-list' },
        h('li', {}, icon('lock', { size: 16 }), 'No account. Your chats stay in this browser.'),
        h('li', {}, icon('heart', { size: 16 }), 'The residents are kind AI characters. What they say is made up.'),
        h('li', {}, icon('globe', { size: 16 }), 'Nothing you type is sent to a server.')),
      h('div', { class: 'field' }, h('label', { class: 'field-label', for: 'welcome-name' }, 'What should they call you?'), nameInput),
      h('label', { class: 'check', for: 'welcome-adult' }, adult, h('span', {}, "I'm 18 or older")),
      error);
    const go = async () => {
      if (!adult.checked) { error.hidden = false; adult.focus(); return false; }
      await updateSettings({ onboardingDone: true, confirmedAdult: true, persona: { name: nameInput.value.trim() } });
      resolve();
      return true;
    };
    nameInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); adult.focus(); } });
    adult.addEventListener('change', () => { if (adult.checked) error.hidden = true; });
    modal({
      body, dismissible: false, size: 'sm', className: 'welcome-modal', labelledBy: 'welcome-title',
      actions: [{ label: 'Come in', variant: 'primary', onClick: go }],
    });
  });
}
