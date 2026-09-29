const desktop = document.querySelector('.desktop');
const caption = document.getElementById('demo-caption');
const captions = { desktop: 'Your wallpaper lives behind your windows and desktop icons.', saver: 'Your video takes over when your Mac is idle.', lock: 'The same view behind your signed-in lock screen.' };
for (const button of document.querySelectorAll('button[data-mode]')) {
  button.addEventListener('click', () => {
    desktop.dataset.mode = button.dataset.mode;
    for (const peer of document.querySelectorAll('button[data-mode]')) {
      const selected = peer === button;
      peer.classList.toggle('selected', selected);
      peer.setAttribute('aria-pressed', String(selected));
    }
    caption.textContent = captions[button.dataset.mode];
  });
}
const motion = document.getElementById('motion-toggle');
function setPaused(paused) {
  desktop.classList.toggle('paused', paused);
  motion.setAttribute('aria-pressed', String(paused));
  motion.textContent = paused ? '▷ Play preview' : 'Ⅱ Pause preview';
}
motion.addEventListener('click', () => setPaused(!desktop.classList.contains('paused')));
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
if (reducedMotion.matches) { setPaused(true); motion.disabled = true; motion.textContent = 'Reduced motion enabled'; }
