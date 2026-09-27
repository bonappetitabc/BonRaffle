# Сборка Bon Raffle из исходников

Приложения Windows и macOS собираются отдельно. Готовые проверенные установщики находятся в [Releases](https://github.com/bonappetitabc/BonRaffle/releases). Исходники в репозитории могут быть новее опубликованных сборок.

## Windows

Нужны Windows, .NET SDK 10 и доступ к NuGet для восстановления зависимостей. Проект использует WinUI 3 и Windows App SDK.

В корне репозитория выполните:

```powershell
dotnet publish work/bonraffle_winui/BonRaffle.csproj -c Release -r win-x64 -p:Platform=x64 -p:PublishSingleFile=false
dotnet run --project work/bonraffle_winui_tests/BonRaffle.Tests.csproj -c Release
dotnet run --project work/manual-roster-smoke/ManualRosterSmoke.csproj -c Release
```

Опубликованные файлы появятся в `work/bonraffle_winui/bin/x64/Release/` внутри каталога целевой платформы. Для установщика NSIS используются `work/installer/BonRaffle.nsi` и `work/installer/build_installer.py`; перед выпуском нужно согласовать версию и путь к подготовленным файлам приложения.

## macOS

Нужны macOS 15 или новее и Apple Command Line Tools. Скрипт запускает проверку CSV, собирает приложение для Apple Silicon и Intel и создаёт DMG:

```sh
cd work/bonraffle_macos
zsh ./build_dmg.command
```

Оформление Liquid Glass требует SDK macOS 26 или новее; с более ранним SDK используется совместимый вид. После сборки проверьте приложение на Mac перед публикацией DMG.
