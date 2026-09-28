#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
zsh ./build_dmg.command --test-updates
APP="$PWD/Bon Raffle Update Test.app"
if [[ ! -d "$APP" ]]; then
  print -u2 "Тестовая копия не создана. Распакуй целиком обновлённый архив Bon Raffle."
  exit 1
fi
open "$APP"
print "Тестовая копия открыта. Настройки → О программе → Проверить обновления."
print "Ожидается macOS 2.2.30. Для обычного выпуска используй zsh ./build_dmg.command."
