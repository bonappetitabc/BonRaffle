Unicode true
!include "MUI2.nsh"

!define APP_NAME "Bon Raffle"
!define APP_VERSION "2.2.26"
!define APP_SOURCE "..\..\outputs\BonRaffle-WinUI-${APP_VERSION}"
!define APP_ICON "..\bonraffle_winui\Assets\AppIcon.ico"
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"

Name "${APP_NAME}"
OutFile "..\..\outputs\Bon-Raffle-Setup-${APP_VERSION}.exe"
InstallDir "$PROGRAMFILES32\Bon Raffle"
InstallDirRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show
BrandingText "Bon Raffle"

VIProductVersion "2.2.26.0"
VIAddVersionKey /LANG=1049 "ProductName" "Bon Raffle"
VIAddVersionKey /LANG=1049 "FileDescription" "Bon Raffle — проведение розыгрышей"
VIAddVersionKey /LANG=1049 "CompanyName" "bonappetit.abc"
VIAddVersionKey /LANG=1049 "LegalCopyright" "© 2026 bonappetit.abc"
VIAddVersionKey /LANG=1049 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1049 "Comments" "Установщик приложения для проведения розыгрышей"
VIAddVersionKey /LANG=1049 "FileVersion" "${APP_VERSION}"

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\Bon Raffle.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Запустить Bon Raffle"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"

Section "Установить Bon Raffle" MainSection
    SectionIn RO
    SetShellVarContext all
    SetOutPath "$INSTDIR"
    File /r /x *.pdb "${APP_SOURCE}\*"
    WriteUninstaller "$INSTDIR\Uninstall.exe"

    CreateShortCut "$SMPROGRAMS\Bon Raffle.lnk" "$INSTDIR\Bon Raffle.exe"
    Delete "$DESKTOP\Bon Raffle.lnk"

    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "DisplayName" "Bon Raffle"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "DisplayVersion" "${APP_VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "Publisher" "bonappetit.abc"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "DisplayIcon" "$INSTDIR\Bon Raffle.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "InstallLocation" "$INSTDIR"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle" "NoRepair" 1
SectionEnd

Section "Ярлык на рабочем столе" DesktopShortcut
    SetShellVarContext all
    CreateShortCut "$DESKTOP\Bon Raffle.lnk" "$INSTDIR\Bon Raffle.exe"
SectionEnd

Section "Uninstall"
    SetShellVarContext all
    Delete "$SMPROGRAMS\Bon Raffle.lnk"
    Delete "$DESKTOP\Bon Raffle.lnk"
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\BonRaffle"
    !include "UninstallFiles.nsh"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"
SectionEnd
