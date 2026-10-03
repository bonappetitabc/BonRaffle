const platformButtons = document.querySelectorAll('.platform-tab');
const platformImages = document.querySelectorAll('img[data-windows]');

function selectPlatform(platform) {
    const platformName = platform === 'macos' ? 'macOS' : 'Windows';

    for (const tab of platformButtons) {
      const active = tab.dataset.platform === platform;
      tab.classList.toggle('is-active', active);
      tab.setAttribute('aria-pressed', String(active));
    }

    for (const image of platformImages) {
      image.src = image.dataset[platform];
      image.alt = `${image.dataset.label} на ${platformName}`;
    }
}

for (const button of platformButtons) {
  button.addEventListener('click', () => selectPlatform(button.dataset.platform));
}

if (/mac/i.test(navigator.userAgentData?.platform || navigator.platform || '')) {
  selectPlatform('macos');
}
