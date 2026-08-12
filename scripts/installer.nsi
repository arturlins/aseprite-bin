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
!ifndef ICONFILE
  !error "ICONFILE not defined -- pass /DICONFILE=<path> to makensis"
!endif

Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"
!include "FileFunc.nsh"
!include "WinMessages.nsh"

Name "Aseprite ${VERSION}"
OutFile "${OUTFILE}"

; Starts unelevated always -- see PageScope/PageScopeLeave below for when and
; how this re-launches itself elevated.
RequestExecutionLevel user

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Aseprite"
!define MUI_ABORTWARNING
!define MUI_ICON "${ICONFILE}"
!define MUI_UNICON "${ICONFILE}"

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

; Launched via explorer.exe (not the direct path) so Aseprite's first run
; inherits the shell's normal, unelevated token instead of the installer's
; -- otherwise an "all users" install (which runs elevated) would write the
; user's first-run settings into the admin's profile.
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION "RunAseprite"
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
    ; Confirm the relaunch actually landed elevated before trusting the flag
    ; -- someone could pass /ALLUSERS directly on the command line, or the
    ; relaunch could theoretically land here without elevation.
    Call IsElevated
    Pop $0
    ${If} $0 == "0"
      MessageBox MB_OK|MB_ICONEXCLAMATION \
        "Administrator rights are required to install for all users.$\r$\n$\r$\nRestart the installer and either accept the elevation prompt, or choose 'Install for me only' instead."
      Quit
    ${EndIf}
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

Function RunAseprite
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\aseprite.exe"'
FunctionEnd

Section "-core" SecCore
  ; Same-scope upgrade: if a previous installation is on record for this
  ; scope's hive, remove it completely and synchronously before copying the
  ; new files -- more robust than only wiping data\ below, and keeps
  ; shortcuts/registry/file-association state consistent with the new
  ; version instead of layering on top of the old one. _?=$0 stops the
  ; generated uninstaller from copying itself to %TEMP% and relaunching,
  ; which would otherwise make ExecWait return before the removal actually
  ; finished.
  ReadRegStr $0 SHCTX "${UNINST_KEY}" "InstallLocation"
  ${If} $0 != ""
  ${AndIf} ${FileExists} "$0\uninstall.exe"
    DetailPrint "Removing previous installation..."
    ExecWait '"$0\uninstall.exe" /S _?=$0'
  ${EndIf}

  SetOutPath "$INSTDIR"

  ; Wipe data\ before copying fresh files so an upgrade never leaves behind
  ; files a newer Aseprite version no longer ships. Guarded on aseprite.exe
  ; already being present so that redirecting $INSTDIR (via the Directory
  ; page) at an arbitrary, unrelated existing folder never nukes a data\
  ; subdirectory that has nothing to do with Aseprite. Kept as a fallback
  ; even after the full-uninstall pass above, for a stale registry entry
  ; whose uninstall.exe is missing, or an install that predates it.
  ${If} ${FileExists} "$INSTDIR\aseprite.exe"
    RMDir /r "$INSTDIR\data"
  ${EndIf}

  File "${SRCDIR}\aseprite.exe"
  File /r "${SRCDIR}\data"
  File /r "${SRCDIR}\docs"
  ; aseprite.ini is deliberately not copied: that marker is what makes the
  ; portable build keep its settings next to the executable. The installed
  ; copy behaves like a normal Windows program and uses %APPDATA%.

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

; /o: unselected by default. This is the idiomatic NSIS way to default a
; component off -- doing it via .onInit + SectionSetFlags ${SecDesktop} 0
; would forward-reference ${SecDesktop} before the preprocessor has seen
; this Section declaration, which silently resolves to section index 0
; (SecCore, the mandatory core install) instead.
Section /o "Desktop shortcut" SecDesktop
  CreateShortcut "$DESKTOP\Aseprite.lnk" "$INSTDIR\aseprite.exe"
SectionEnd

Section "Associate .aseprite and .ase files with Aseprite" SecFileAssoc
  ; Back up whatever the extensions were previously bound to (if anything,
  ; and if it isn't already us) so the uninstaller can restore it instead of
  ; leaving the extension completely unassociated.
  ReadRegStr $0 SHCTX "Software\Classes\.aseprite" ""
  ${If} $0 != "Aseprite.Document"
  ${AndIf} $0 != ""
    WriteRegStr SHCTX "Software\Classes\.aseprite" "Aseprite.Document_backup" "$0"
  ${EndIf}
  ReadRegStr $0 SHCTX "Software\Classes\.ase" ""
  ${If} $0 != "Aseprite.Document"
  ${AndIf} $0 != ""
    WriteRegStr SHCTX "Software\Classes\.ase" "Aseprite.Document_backup" "$0"
  ${EndIf}

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

; RequestExecutionLevel user (above) governs the generated uninstaller too --
; NSIS has no separate directive for it. The uninstaller's manifest is
; asInvoker, so Windows will NOT auto-elevate it the way it does unmanifested
; legacy installers. Without this check, uninstalling an "all users" install
; (Program Files, HKLM, common Start Menu) would silently fail every delete
; and registry write while still reporting success. Uninstaller-side code
; lives in the un. namespace, so the installer's IsElevated Function can't be
; called from here -- this inlines an equivalent write-probe.
Function un.onInit
  ReadRegStr $0 HKLM "${UNINST_KEY}" "InstallScope"
  ${If} $0 == "all"
    ClearErrors
    FileOpen $1 "$PROGRAMFILES64\aseprite-setup-write-test.tmp" w
    ${If} ${Errors}
      ; Not elevated -- relaunch this uninstaller elevated and quit this
      ; instance. Relaunch "$INSTDIR\uninstall.exe", not $EXEPATH: by the
      ; time un.onInit runs, NSIS has already copied itself out to a %TEMP%
      ; stub and re-exec'd with _?=$INSTDIR so it can delete its own
      ; directory, so $EXEPATH here is that temp copy. Relaunching $EXEPATH
      ; without forwarding that parameter would make the elevated child
      ; treat the temp folder as $INSTDIR -- it would clean up shortcuts and
      ; the registry (those don't depend on $INSTDIR) but never touch the
      ; real Program Files\Aseprite, leaving it orphaned while still
      ; reporting success. Going through "$INSTDIR\uninstall.exe" instead
      ; re-triggers NSIS's own temp-copy dance correctly on the elevated
      ; side.
      ClearErrors
      ExecShell "runas" "$INSTDIR\uninstall.exe"
      ${If} ${Errors}
        MessageBox MB_OK|MB_ICONEXCLAMATION \
          "Administrator rights are required to uninstall this copy of Aseprite.$\r$\n$\r$\nRestart the uninstaller and accept the elevation prompt."
      ${EndIf}
      Quit
    ${Else}
      FileClose $1
      Delete "$PROGRAMFILES64\aseprite-setup-write-test.tmp"
    ${EndIf}
  ${EndIf}
FunctionEnd

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

  ; Only touch the extension keys if they still point at us -- a later
  ; install of something else claiming .aseprite/.ase should not be clobbered
  ; by an unrelated Aseprite uninstall. If we backed up a prior owner's
  ; value at install time, restore it instead of leaving the extension
  ; completely unassociated.
  ReadRegStr $0 SHCTX "Software\Classes\.aseprite" ""
  ${If} $0 == "Aseprite.Document"
    ReadRegStr $1 SHCTX "Software\Classes\.aseprite" "Aseprite.Document_backup"
    ${If} $1 != ""
      WriteRegStr SHCTX "Software\Classes\.aseprite" "" "$1"
      DeleteRegValue SHCTX "Software\Classes\.aseprite" "Aseprite.Document_backup"
    ${Else}
      DeleteRegKey SHCTX "Software\Classes\.aseprite"
    ${EndIf}
  ${EndIf}
  ReadRegStr $0 SHCTX "Software\Classes\.ase" ""
  ${If} $0 == "Aseprite.Document"
    ReadRegStr $1 SHCTX "Software\Classes\.ase" "Aseprite.Document_backup"
    ${If} $1 != ""
      WriteRegStr SHCTX "Software\Classes\.ase" "" "$1"
      DeleteRegValue SHCTX "Software\Classes\.ase" "Aseprite.Document_backup"
    ${Else}
      DeleteRegKey SHCTX "Software\Classes\.ase"
    ${EndIf}
  ${EndIf}
  DeleteRegKey SHCTX "Software\Classes\Aseprite.Document"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, i 0, i 0)'

  DeleteRegKey SHCTX "${UNINST_KEY}"
SectionEnd
