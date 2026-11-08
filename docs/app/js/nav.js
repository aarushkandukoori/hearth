// Sidebar navigation registry. Other modules add entries without touching the shell:
//   registerNav({ id: 'town', label: 'Town', icon: 'map', href: '#/town', order: 20 })
// Same id replaces the earlier entry. `icon` is an icon name from ui/icons.js or an '<svg ...>' string.

const items = new Map();
const listeners = new Set();

export function registerNav({ id, label, icon = 'sparkle', href, order = 50, match = null }) {
  if (!id || !label || !href) throw new Error('registerNav needs id, label and href');
  items.set(id, { id, label, icon, href, order, match });
  for (const fn of listeners) fn(navItems());
}

export function unregisterNav(id) {
  if (items.delete(id)) for (const fn of listeners) fn(navItems());
}

/** Entries sorted by order. `match(path)` (optional) decides when an entry is highlighted. */
export function navItems() {
  return [...items.values()].sort((a, b) => a.order - b.order || a.label.localeCompare(b.label));
}

export function onNavChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
