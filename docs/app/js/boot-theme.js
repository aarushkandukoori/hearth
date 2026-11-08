// Runs before the stylesheet paints (classic script, no module) so a saved light/dark choice never flashes.
(function () {
  try {
    var t = localStorage.getItem('hearth.theme');
    if (t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t);
    if (localStorage.getItem('hearth.sidebar') === 'collapsed') document.documentElement.classList.add('sidebar-collapsed');
  } catch (e) { /* storage blocked: follow the system theme */ }
})();
