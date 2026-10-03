const platformButtons = document.querySelectorAll('.platform-tab');
const mainImage = document.querySelector('.app-window img');
const leftPreview = document.querySelector('.showcase-peek-left');
const rightPreview = document.querySelector('.showcase-peek-right');
const showcaseLabel = document.querySelector('#showcase-label');

const screens = [
  { file: 'countdown', label: 'Отсчёт перед розыгрышем' },
  { file: 'drum-participants', label: 'Розыгрыш участников' },
  { file: 'lists-participants', label: 'Список участников' },
];

let platform = /mac/i.test(navigator.userAgentData?.platform || navigator.platform || '') ? 'macos' : 'windows';
let screenIndex = 1;

function screenAt(index) {
  return screens[(index + screens.length) % screens.length];
}

function screenshotPath(screen) {
  return `screenshots/${screen.file}-${platform}.png`;
}

function renderShowcase() {
  const current = screenAt(screenIndex);
  const previous = screenAt(screenIndex - 1);
  const next = screenAt(screenIndex + 1);
  const platformName = platform === 'macos' ? 'macOS' : 'Windows';

  mainImage.src = screenshotPath(current);
  mainImage.alt = `${current.label} в Bon Raffle на ${platformName}`;
  showcaseLabel.textContent = current.label;

  leftPreview.querySelector('img').src = screenshotPath(previous);
  leftPreview.setAttribute('aria-label', `Показать: ${previous.label}`);
  rightPreview.querySelector('img').src = screenshotPath(next);
  rightPreview.setAttribute('aria-label', `Показать: ${next.label}`);

  for (const button of platformButtons) {
    const active = button.dataset.platform === platform;
    button.classList.toggle('is-active', active);
    button.setAttribute('aria-pressed', String(active));
  }
}

for (const button of platformButtons) {
  button.addEventListener('click', () => {
    platform = button.dataset.platform;
    renderShowcase();
  });
}

leftPreview.addEventListener('click', () => {
  screenIndex = (screenIndex + screens.length - 1) % screens.length;
  renderShowcase();
});

rightPreview.addEventListener('click', () => {
  screenIndex = (screenIndex + 1) % screens.length;
  renderShowcase();
});

for (const button of document.querySelectorAll('.showcase-mobile-controls button')) {
  button.addEventListener('click', () => {
    screenIndex = (screenIndex + (button.dataset.direction === 'next' ? 1 : screens.length - 1)) % screens.length;
    renderShowcase();
  });
}

renderShowcase();
