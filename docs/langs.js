// Language menu: close it on a click outside or on Escape.
// Without this file the menu still works; it just stays open until clicked again.
document.addEventListener('click', e => {
  const d = document.querySelector('.langs details[open]');
  if (d && !d.contains(e.target)) d.open = false;
});
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape') return;
  const d = document.querySelector('.langs details[open]');
  if (d) {
    d.open = false;
    d.querySelector('summary').focus();
  }
});
