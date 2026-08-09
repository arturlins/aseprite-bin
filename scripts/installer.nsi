; Aseprite Windows installer.
;
; Packages the already-assembled portable folder
; (dist/aseprite-<version>-windows-x64) into a Program Files / per-user
; installer with an optional Start Menu shortcut (always), an optional
; desktop shortcut, and an optional .aseprite/.ase file association.
;
; Required command-line defines, set by build.cmd:
;   /DVERSION=v1.3.18.1        full tag, used in registry/uninstall strings
;   /DVERSION_NUMBER=1.3.18.1  no leading "v", used as DisplayVersion
;   /DSRCDIR=<absolute path>   the portable folder to package
;   /DOUTFILE=<absolute path>  where to write the generated installer .exe
;
; Install scope (all users vs. current user only) is a runtime choice made on
; the custom page below, not baked in here. "All users" self-elevates via
; ExecShell "runas" only when needed, instead of forcing UAC on every launch.
; This hand-rolled approach avoids the third-party UAC.dll plugin that
; MultiUser.nsh's AdminOrUser mode would otherwise require -- see the design
; doc for why that trade-off was made.

!ifndef VERSION
  !error "VERSION not defined -- pass /DVERSION=vX.Y.Z to makensis"
!endif
!ifndef VERSION_NUMBER
  !error "VERSION_NUMBER not defined -- pass /DVERSION_NUMBER=X.Y.Z to makensis"
!endif
!ifndef SRCDIR
  !error "SRCDIR not defined -- pass /DSRCDIR=<path> to makensis"
!endif
!ifndef OUTFILE
  !error "OUTFILE not defined -- pass /DOUTFILE=<path> to makensis"
!endif

Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"
!include "FileFunc.nsh"
!include "WinMessages.nsh"

Name "Aseprite"
OutFile "${OUTFILE}"

; Starts unelevated always -- see PageScope/PageScopeLeave below for when and
; how this re-launches itself elevated.
RequestExecutionLevel user

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Aseprite"
!define MUI_ABORTWARNING

Var Scope                 ; "all" or "user", decided on the scope page
Var ScopeAllUsersRadio
Var ScopeCurrentUserRadio

; --- installer pages --------------------------------------------------------

!insertmacro MUI_PAGE_WELCOME

Page custom PageScope PageScopeLeave

!insertmacro MUI_PAGE_DIRECTORY

!define MUI_COMPONENTSPAGE_SMALLDESC
!insertmacro MUI_PAGE_COMPONENTS

!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_RUN "$INSTDIR\aseprite.exe"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; --- scope page --------------------------------------------------------------

Function PageScope
  ; The elevated relaunch (see PageScopeLeave) passes /ALLUSERS so the new,
  ; already-elevated process skips straight past this page instead of asking
  ; the same question twice.
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/ALLUSERS" $R1
  ${IfNot} ${Errors}
    StrCpy $Scope "all"
    SetShellVarContext all
    StrCpy $INSTDIR "$PROGRAMFILES64\Aseprite"
    Abort ; skip showing this page
  ${EndIf}

  !insertmacro MUI_HEADER_TEXT "Choose Install Scope" "Who should be able to run Aseprite?"

  nsDialogs::Create 1018
  Pop $0

  ${NSD_CreateRadioButton} 0 20u 100% 12u "Install for all users (requires administrator rights)"
  Pop $ScopeAllUsersRadio
  ${NSD_SetState} $ScopeAllUsersRadio ${BST_CHECKED}

  ${NSD_CreateRadioButton} 0 40u 100% 12u "Install for me only (no administrator rights required)"
  Pop $ScopeCurrentUserRadio

  nsDialogs::Show
FunctionEnd

; Reliable elevation check: try to write a throwaway file into Program Files.
; UserInfo::GetAccountType reports whether the *account* belongs to the
; Administrators group, not whether *this process* is actually elevated, so a
; non-elevated admin account can make it wrongly report "Admin".
Function IsElevated
  ClearErrors
  FileOpen $0 "$PROGRAMFILES64\aseprite-setup-write-test.tmp" w
  ${If} ${Errors}
    Push "0"
  ${Else}
    FileClose $0
    Delete "$PROGRAMFILES64\aseprite-setup-write-test.tmp"
    Push "1"
  ${EndIf}
FunctionEnd

Function PageScopeLeave
  ${NSD_GetState} $ScopeAllUsersRadio $0
  ${If} $0 == ${BST_CHECKED}
    StrCpy $Scope "all"
  ${Else}
    StrCpy $Scope "user"
  ${EndIf}

  ${If} $Scope == "all"
    Call IsElevated
    Pop $0
    ${If} $0 == "0"
      ClearErrors
      ExecShell "runas" "$EXEPATH" "/ALLUSERS"
      ${If} ${Errors}
        MessageBox MB_OK|MB_ICONEXCLAMATION \
          "Administrator rights are required to install for all users.$\r$\n$\r$\nRestart the installer and either accept the elevation prompt, or choose 'Install for me only' instead."
      ${EndIf}
      Quit
    ${EndIf}
    SetShellVarContext all
    StrCpy $INSTDIR "$PROGRAMFILES64\Aseprite"
  ${Else}
    SetShellVarContext current
    StrCpy $INSTDIR "$LOCALAPPDATA\Programs\Aseprite"
  ${EndIf}
FunctionEnd

; --- install sections --------------------------------------------------------

Function .onInit
  ; Desktop shortcut defaults to unselected. File association defaults to
  ; selected -- that is simply a Section's default state, so nothing to do
  ; for it here.
  SectionSetFlags ${SecDesktop} 0
FunctionEnd

Section "-core" SecCore
  SetOutPath "$INSTDIR"

  ; Wipe data\ before copying fresh files so an upgrade never leaves behind
  ; files a newer Aseprite version no longer ships.
  RMDir /r "$INSTDIR\data"

  File "${SRCDIR}\aseprite.exe"
  File /r "${SRCDIR}\data"
  File /r "${SRCDIR}\docs"
  ; NOTE: The portable config marker is intentionally not copied. This allows
  ; the portable version to keep settings next to the executable, while the
  ; installed version behaves like a normal Windows program using %APPDATA%.

  WriteUninstaller "$INSTDIR\uninstall.exe"

  CreateDirectory "$SMPROGRAMS\Aseprite"
  CreateShortcut "$SMPROGRAMS\Aseprite\Aseprite.lnk" "$INSTDIR\aseprite.exe"
  CreateShortcut "$SMPROGRAMS\Aseprite\Uninstall Aseprite.lnk" "$INSTDIR\uninstall.exe"

  WriteRegStr SHCTX "${UNINST_KEY}" "DisplayName" "Aseprite"
  WriteRegStr SHCTX "${UNINST_KEY}" "DisplayVersion" "${VERSION_NUMBER}"
  WriteRegStr SHCTX "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\aseprite.exe"
  WriteRegStr SHCTX "${UNINST_KEY}" "Publisher" "Compiled from source (unofficial build), not Igara Studio S.A."
  WriteRegStr SHCTX "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr SHCTX "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr SHCTX "${UNINST_KEY}" "InstallScope" "$Scope"
  WriteRegDWORD SHCTX "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD SHCTX "${UNINST_KEY}" "NoRepair" 1

  ${GetSize} "$INSTDIR\" "/S=0K" $0 $1 $2
  WriteRegDWORD SHCTX "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

Section "Desktop shortcut" SecDesktop
  CreateShortcut "$DESKTOP\Aseprite.lnk" "$INSTDIR\aseprite.exe"
SectionEnd

Section "Associate .aseprite and .ase files with Aseprite" SecFileAssoc
  WriteRegStr SHCTX "Software\Classes\Aseprite.Document" "" "Aseprite Sprite"
  WriteRegStr SHCTX "Software\Classes\Aseprite.Document\DefaultIcon" "" "$INSTDIR\aseprite.exe,0"
  WriteRegStr SHCTX "Software\Classes\Aseprite.Document\shell\open\command" "" '"$INSTDIR\aseprite.exe" "%1"'
  WriteRegStr SHCTX "Software\Classes\.aseprite" "" "Aseprite.Document"
  WriteRegStr SHCTX "Software\Classes\.ase" "" "Aseprite.Document"

  ; SHCNE_ASSOCCHANGED = 0x08000000, SHCNF_IDLIST = 0. Tells Explorer to pick
  ; up the new association immediately instead of waiting for the next logon.
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, i 0, i 0)'
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "Add an Aseprite shortcut to the desktop."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecFileAssoc} "Open .aseprite and .ase files with Aseprite by double-clicking them."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; --- uninstaller --------------------------------------------------------------

Section "Uninstall"
  ; $INSTDIR is already correct (NSIS points an uninstaller's $INSTDIR at the
  ; folder it is running from). The registry hive to clean up is not, since
  ; the user could have redirected the install elsewhere on the Directory
  ; page -- so scope is read back from InstallScope instead of guessed from a
  ; path. Only one hive will ever have it.
  ReadRegStr $0 HKLM "${UNINST_KEY}" "InstallScope"
  ${If} $0 == "all"
    SetShellVarContext all
  ${Else}
    ReadRegStr $0 HKCU "${UNINST_KEY}" "InstallScope"
    SetShellVarContext current
  ${EndIf}

  Delete "$INSTDIR\aseprite.exe"
  RMDir /r "$INSTDIR\data"
  RMDir /r "$INSTDIR\docs"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\Aseprite\Aseprite.lnk"
  Delete "$SMPROGRAMS\Aseprite\Uninstall Aseprite.lnk"
  RMDir "$SMPROGRAMS\Aseprite"
  Delete "$DESKTOP\Aseprite.lnk"

  ; Only remove the extension keys if they still point at us -- a later
  ; install of something else claiming .aseprite/.ase should not be clobbered
  ; by an unrelated Aseprite uninstall.
  ReadRegStr $0 SHCTX "Software\Classes\.aseprite" ""
  ${If} $0 == "Aseprite.Document"
    DeleteRegKey SHCTX "Software\Classes\.aseprite"
  ${EndIf}
  ReadRegStr $0 SHCTX "Software\Classes\.ase" ""
  ${If} $0 == "Aseprite.Document"
    DeleteRegKey SHCTX "Software\Classes\.ase"
  ${EndIf}
  DeleteRegKey SHCTX "Software\Classes\Aseprite.Document"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, i 0, i 0)'

  DeleteRegKey SHCTX "${UNINST_KEY}"
SectionEnd
