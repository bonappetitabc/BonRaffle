#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
ROOT="$PWD"
TEST_UPDATES=0
if [[ "${1:-}" == "--test-updates" ]]; then
  TEST_UPDATES=1
elif (( $# > 0 )); then
  print -u2 "Параметр: --test-updates для отдельной тестовой копии обновлений."
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "Запусти эту команду на Mac."
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 "Нужны Apple Command Line Tools: xcode-select --install"
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
print "macOS ${OS_VERSION}; SDK macOS ${SDK_VERSION}."
SWIFT_FLAGS=(-D BON_RAFFLE_NATIVE)
if (( TEST_UPDATES )); then
  SWIFT_FLAGS+=(-D BON_RAFFLE_UPDATE_TEST)
  print "Тест обновлений: отдельное приложение и данные; версия сравнения 2.2.0."
fi
if (( SDK_MAJOR >= 26 )); then
  SWIFT_FLAGS+=(-D HAS_LIQUID_GLASS)
  print "SDK macOS ${SDK_VERSION}: поддержка Liquid Glass добавлена. Эффект работает на macOS 26 и новее."
else
  print "SDK macOS ${SDK_VERSION}: используется совместимое полупрозрачное оформление."
  if (( OS_MAJOR >= 26 )); then
    print -u2 "Для системного Liquid Glass установи Xcode с SDK macOS 26 или новее. Сборка продолжается с совместимым оформлением."
  fi
fi
BUILD="$ROOT/.build-native"
APP="$ROOT/Bon Raffle.app"
if (( TEST_UPDATES )); then
  BUILD="$ROOT/.build-update-test"
  APP="$ROOT/Bon Raffle Update Test.app"
fi
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
export MACOSX_DEPLOYMENT_TARGET=15.0

print "[1/6] Проверка Swift и загрузки CSV..."
xcrun swiftc -frontend -parse "${SWIFT_FLAGS[@]}" \
  "$ROOT/RaffleData.swift" "$ROOT/MaxRosterExporter.swift" "$ROOT/AppUpdates.swift" "$ROOT/BonRaffle.swift"
xcrun swiftc -O -sdk "$SDK" "$ROOT/RaffleData.swift" "$ROOT/AppUpdates.swift" "$ROOT/ImportSelfTest.swift" \
  -o "$BUILD/import-selftest"
"$BUILD/import-selftest"

print "[2/6] Сборка для Apple Silicon..."
xcrun swiftc -O -sdk "$SDK" "${SWIFT_FLAGS[@]}" -target arm64-apple-macosx15.0 \
  "$ROOT/RaffleData.swift" "$ROOT/MaxRosterExporter.swift" "$ROOT/AppUpdates.swift" "$ROOT/BonRaffle.swift" \
  -o "$BUILD/BonRaffle-arm64"

print "[3/6] Сборка для Intel..."
xcrun swiftc -O -sdk "$SDK" "${SWIFT_FLAGS[@]}" -target x86_64-apple-macosx15.0 \
  "$ROOT/RaffleData.swift" "$ROOT/MaxRosterExporter.swift" "$ROOT/AppUpdates.swift" "$ROOT/BonRaffle.swift" \
  -o "$BUILD/BonRaffle-x86_64"

print "[4/6] Создание универсального приложения..."
lipo -create "$BUILD/BonRaffle-arm64" "$BUILD/BonRaffle-x86_64" \
  -output "$APP/Contents/MacOS/BonRaffle"
chmod +x "$APP/Contents/MacOS/BonRaffle"
ditto "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if (( TEST_UPDATES )); then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.bonraffle.updatetest' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Bon Raffle Update Test' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Bon Raffle Update Test' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 2.2.0' "$APP/Contents/Info.plist"
fi
ditto "$ROOT/Resources/background-bon-raffle.png" "$APP/Contents/Resources/background-bon-raffle.png"
ditto "$ROOT/Resources/logo-bon-raffle.png" "$APP/Contents/Resources/logo-bon-raffle.png"
ditto "$ROOT/Resources/avatar-placeholder.png" "$APP/Contents/Resources/avatar-placeholder.png"
ditto "$ROOT/Resources/ApplIcation-bon-raffle.png" "$APP/Contents/Resources/ApplIcation-bon-raffle.png"
ditto "$ROOT/Resources/Demo" "$APP/Contents/Resources/Demo"
ditto "$ROOT/LICENSE.txt" "$APP/Contents/Resources/LICENSE.txt"

ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -s format png -z "$SIZE" "$SIZE" "$ROOT/Resources/ApplIcation-bon-raffle.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  PIXELS=$((SIZE * 2))
  sips -s format png -z "$PIXELS" "$PIXELS" "$ROOT/Resources/ApplIcation-bon-raffle.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/BonRaffle")"
if [[ " $ARCHS " != *" arm64 "* || " $ARCHS " != *" x86_64 "* ]]; then
  print -u2 "Не удалось собрать обе архитектуры: $ARCHS"
  exit 1
fi

print "[5/6] Подготовка образа..."
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bonraffle-dmg.XXXXXX")"
STAGING="$STAGING_ROOT/Bon Raffle"
mkdir -p "$STAGING"
trap 'rm -rf -- "$STAGING_ROOT"' EXIT
ditto "$APP" "$STAGING/${APP:t}"
ln -s /Applications "$STAGING/Applications"

print "[6/6] Создание DMG..."
DMG="$ROOT/BonRaffle-macOS15-plus-2.3.0.dmg"
if (( TEST_UPDATES )); then
  DMG="$ROOT/BonRaffle-macOS-update-test.dmg"
fi
TEMP_DMG="$STAGING_ROOT/BonRaffle.dmg"
diskutil image create from --format UDZO "$STAGING" "$TEMP_DMG"
diskutil image info "$TEMP_DMG" >/dev/null
mv -f -- "$TEMP_DMG" "$DMG"
print "Готово: $DMG"
print "Перетащи приложение из DMG в Applications и проверь запуск."
