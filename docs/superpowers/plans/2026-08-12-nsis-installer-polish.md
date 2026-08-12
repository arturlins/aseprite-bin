# Instalador NSIS — Ícone, Upgrade Robusto e Escudo UAC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three polish issues found in real-world use of `scripts/installer.nsi`: the generic NSIS icon on `setup.exe`/`uninstall.exe`, upgrades that only wipe `data\` instead of fully removing the previous version, and a scope-choice page that doesn't visually signal which option triggers UAC.

**Architecture:** All three changes live inside the existing single-file NSIS script (`scripts/installer.nsi`) plus one new `/D` define wired through `build.cmd`. No new scripts, no new external tools, no third-party NSIS plugins — same posture the original installer design already committed to (hand-rolled elevation via `ExecShell "runas"`, no `UAC.dll`).

**Tech Stack:** NSIS (Modern UI 2, nsDialogs, LogicLib), Windows batch (`build.cmd`), bash test suite (`tests/*.test.sh`, static `grep`-based assertions — `makensis` is a Windows-only tool the suite does not assume is installed).

## Global Constraints

- No third-party NSIS plugins (e.g. `UAC.dll`) — only what ships with a plain `choco install nsis`. Source: [2026-08-12-nsis-installer-polish-design.md](../specs/2026-08-12-nsis-installer-polish-design.md), reaffirming the constraint from the original installer design.
- No binaries or generated assets committed to this repository — the installer icon is sourced from the `aseprite/` tree `build.cmd` already clones per build, not generated or checked in here.
- Any `ExecWait` on a generated NSIS uninstaller MUST use `_?=<path>` — without it, `ExecWait` returns before the removal has actually finished (the uninstaller copies itself to `%TEMP%` and relaunches).
- User settings must keep surviving upgrades: the installed build already uses `%APPDATA%` (never `aseprite.ini`), and the uninstaller never touches `%APPDATA%` — none of these changes may alter that.
- Elevation is still never requested just to open the installer (`RequestExecutionLevel user` stays as-is) — only ever via explicit `ExecShell "runas"` relaunches, same as today.
- `bash tests/run-all.sh` must pass after every task, including the pre-existing suites (`resolve-version`, `make-icns`, `make-dmg`, `make-installer`).
- Linux and macOS scripts/workflows are out of scope — untouched.

## File Structure

Only three files change, no new files:

- `scripts/installer.nsi` — gets the icon defines, the same-scope and cross-scope upgrade-cleanup logic, the `/CLEANUPALLUSERS` relaunch marker, and the UAC shield button logic. All four tasks land in this one file, in different functions/sections.
- `build.cmd` — one new `/DICONFILE=` define added to the existing `makensis` invocation (Task 1 only).
- `tests/make-installer.test.sh` — new static `grep` assertions added incrementally, one batch per task, following the file's existing `check()`/`has()` pattern.

---

### Task 1: Setup/uninstaller icon

**Files:**
- Modify: `scripts/installer.nsi:30-32` (add `ICONFILE` guard next to the existing `OUTFILE` guard), `scripts/installer.nsi:49-50` (add `MUI_ICON`/`MUI_UNICON` next to `MUI_ABORTWARNING`)
- Modify: `build.cmd:178` (add `/DICONFILE=` to the `makensis` call)
- Test: `tests/make-installer.test.sh`

**Interfaces:**
- Consumes: nothing (first task, no dependency on other tasks)
- Produces: the `ICONFILE` `/D` define contract that `build.cmd` and `installer.nsi` now both rely on — later tasks don't touch this, but any future change to how the installer is invoked must keep passing it.

- [ ] **Step 1: Add the failing test assertions**

Open `tests/make-installer.test.sh`. Change the existing define loop (currently `for define in VERSION VERSION_NUMBER SRCDIR OUTFILE; do`, around line 45) to include the new define:

```bash
for define in VERSION VERSION_NUMBER SRCDIR OUTFILE ICONFILE; do
```

Then add two new checks right after that loop's closing `done` (after line 57, before the `# --- dual-scope install` comment):

```bash
has '!define MUI_ICON "${ICONFILE}"' \
  && check "setup.exe usa o icone do Aseprite" 1 \
  || check "setup.exe usa o icone do Aseprite" 0 '!define MUI_ICON "${ICONFILE}" nao encontrado'

has '!define MUI_UNICON "${ICONFILE}"' \
  && check "uninstall.exe usa o icone do Aseprite" 1 \
  || check "uninstall.exe usa o icone do Aseprite" 0 '!define MUI_UNICON "${ICONFILE}" nao encontrado'
```

- [ ] **Step 2: Run the suite and confirm the new checks fail**

Run: `bash tests/make-installer.test.sh`
Expected: these lines appear among the output, and the final tally shows more failures than before:
```
FAIL - installer.nsi exige /DICONFILE
       !ifndef ICONFILE nao encontrado
FAIL - build.cmd passa /DICONFILE
       /DICONFILE= nao encontrado em build.cmd
FAIL - setup.exe usa o icone do Aseprite
       !define MUI_ICON "${ICONFILE}" nao encontrado
FAIL - uninstall.exe usa o icone do Aseprite
       !define MUI_UNICON "${ICONFILE}" nao encontrado
```

- [ ] **Step 3: Add the ICONFILE guard to installer.nsi**

In `scripts/installer.nsi`, right after the existing `OUTFILE` guard (ends at line 32 with the matching `!endif`), add:

```nsis
!ifndef ICONFILE
  !error "ICONFILE not defined -- pass /DICONFILE=<path> to makensis"
!endif
```

- [ ] **Step 4: Add the icon defines**

In `scripts/installer.nsi`, right after `!define MUI_ABORTWARNING` (line 50), add:

```nsis
!define MUI_ICON "${ICONFILE}"
!define MUI_UNICON "${ICONFILE}"
```

- [ ] **Step 5: Pass the define from build.cmd**

In `build.cmd`, the `makensis` invocation is a single line (line 178):

```bat
%MAKENSIS% /WX /DVERSION=%ASEPRITE_VERSION% /DVERSION_NUMBER=%ASEPRITE_VERSION_NUMBER% "/DSRCDIR=%CD%\%OUTDIR%" "/DOUTFILE=%CD%\%SETUPFILE%" scripts\installer.nsi || echo failed to build installer && exit /b 1
```

Add `"/DICONFILE=%CD%\aseprite\data\icons\ase.ico"` to it, right after the `/DOUTFILE` argument:

```bat
%MAKENSIS% /WX /DVERSION=%ASEPRITE_VERSION% /DVERSION_NUMBER=%ASEPRITE_VERSION_NUMBER% "/DSRCDIR=%CD%\%OUTDIR%" "/DOUTFILE=%CD%\%SETUPFILE%" "/DICONFILE=%CD%\aseprite\data\icons\ase.ico" scripts\installer.nsi || echo failed to build installer && exit /b 1
```

This works because `build.cmd` never deletes the `aseprite\` clone before this point — the packaging step runs right after the build, with `aseprite\data\icons\ase.ico` (the same `.ico` Aseprite's own `resources_win32.rc` embeds into `aseprite.exe`) still on disk.

- [ ] **Step 6: Run the suite and confirm everything passes**

Run: `bash tests/make-installer.test.sh`
Expected: `0 failed` in the final tally, including the four new checks now showing `ok`.

Also run the full suite to make sure nothing else broke: `bash tests/run-all.sh`
Expected: `all suites passed`

- [ ] **Step 7: Commit**

```bash
git add scripts/installer.nsi build.cmd tests/make-installer.test.sh
git commit -m "feat: usar o icone do Aseprite no setup.exe e uninstall.exe gerados"
```

---

### Task 2: Upgrade robustness — remove the previous same-scope installation before installing

**Files:**
- Modify: `scripts/installer.nsi:173-184` (`Section "-core" SecCore`, the part before `SetOutPath "$INSTDIR"` and the existing `data\` wipe)
- Test: `tests/make-installer.test.sh`

**Interfaces:**
- Consumes: `${UNINST_KEY}` (already defined at `scripts/installer.nsi:49`), `SHCTX` (already resolved by `PageScopeLeave` before `SecCore` runs), `$Scope` (`Var Scope`, already declared)
- Produces: the "remove previous install for the current scope's hive before copying files" block at the top of `SecCore`, which Task 4 extends with the cross-scope variant right after it.

- [ ] **Step 1: Add the failing test assertions**

In `tests/make-installer.test.sh`, add these checks in the `# --- upgrade hygiene ---` section (right before the existing `RMDir /r "$INSTDIR\data"` check, around line 105):

```bash
has 'ReadRegStr $0 SHCTX "${UNINST_KEY}" "InstallLocation"' \
  && check "upgrade le a instalacao anterior do mesmo escopo no registro" 1 \
  || check "upgrade le a instalacao anterior do mesmo escopo no registro" 0 "ReadRegStr SHCTX InstallLocation nao encontrado"

has '"$0\uninstall.exe" /S _?=$0' \
  && check "upgrade desinstala a versao anterior por completo antes de copiar (espera terminar de verdade)" 1 \
  || check "upgrade desinstala a versao anterior por completo antes de copiar (espera terminar de verdade)" 0 '"$0\uninstall.exe" /S _?=$0 nao encontrado'
```

- [ ] **Step 2: Run the suite and confirm the new checks fail**

Run: `bash tests/make-installer.test.sh`
Expected:
```
FAIL - upgrade le a instalacao anterior do mesmo escopo no registro
       ReadRegStr SHCTX InstallLocation nao encontrado
FAIL - upgrade desinstala a versao anterior por completo antes de copiar (espera terminar de verdade)
       "$0\uninstall.exe" /S _?=$0 nao encontrado
```

- [ ] **Step 3: Add the same-scope cleanup block**

In `scripts/installer.nsi`, `Section "-core" SecCore` currently starts with:

```nsis
Section "-core" SecCore
  SetOutPath "$INSTDIR"

  ; Wipe data\ before copying fresh files ...
  ${If} ${FileExists} "$INSTDIR\aseprite.exe"
    RMDir /r "$INSTDIR\data"
  ${EndIf}
```

Insert a new block before `SetOutPath "$INSTDIR"`:

```nsis
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
```

(The rest of `SecCore` — `File "${SRCDIR}\aseprite.exe"` onward — is unchanged.)

- [ ] **Step 4: Run the suite and confirm everything passes**

Run: `bash tests/make-installer.test.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/installer.nsi tests/make-installer.test.sh
git commit -m "feat: desinstalar a versao anterior por completo antes de um upgrade no mesmo escopo"
```

---

### Task 3: UAC shield icon on the scope page's Next button

**Files:**
- Modify: `scripts/installer.nsi:49-51` (add `BCM_SETSHIELD` define), `scripts/installer.nsi:84-121` (`Function PageScope`), `scripts/installer.nsi:139-165` (`Function PageScopeLeave`)
- Test: `tests/make-installer.test.sh`

**Interfaces:**
- Consumes: `$ScopeAllUsersRadio` / `$ScopeCurrentUserRadio` (already declared `Var`s), `${NSD_OnClick}` (from `nsDialogs.nsh`, already `!include`d)
- Produces: `Function UpdateScopeShield` (no params, no return — reads `$ScopeAllUsersRadio`'s state and toggles the shield), which both radio buttons' click handlers call and which `PageScope` calls once to set the initial state. `PageScopeLeave` calls the same shield-off `SendMessage` inline (not through the function, since it always turns it off unconditionally) — Task 4 must keep that line intact when it adds the cross-scope branch inside `PageScopeLeave`'s `${Else}` block.

- [ ] **Step 1: Add the failing test assertions**

In `tests/make-installer.test.sh`, add a new section after the `# --- dual-scope install ---` block (after line 79, before `# --- optional components ---`):

```bash
# --- UAC shield on the scope page's Next button -----------------------------

has "!define BCM_SETSHIELD 0x0000160C" \
  && check "define nativo BCM_SETSHIELD (sem plugin UAC.dll de terceiro)" 1 \
  || check "define nativo BCM_SETSHIELD (sem plugin UAC.dll de terceiro)" 0 "BCM_SETSHIELD nao encontrado"

has "GetDlgItem \$0 \$HWNDPARENT 1" \
  && check "pega o botao Next do wizard para aplicar o escudo" 1 \
  || check "pega o botao Next do wizard para aplicar o escudo" 0 "GetDlgItem \$0 \$HWNDPARENT 1 nao encontrado"

has "Function UpdateScopeShield" \
  && check "funcao UpdateScopeShield existe" 1 \
  || check "funcao UpdateScopeShield existe" 0 "Function UpdateScopeShield nao encontrada"

has "\${NSD_OnClick} \$ScopeAllUsersRadio UpdateScopeShield" \
  && check "escudo atualiza ao clicar no radio 'todos os usuarios'" 1 \
  || check "escudo atualiza ao clicar no radio 'todos os usuarios'" 0 "NSD_OnClick ScopeAllUsersRadio UpdateScopeShield nao encontrado"

has "\${NSD_OnClick} \$ScopeCurrentUserRadio UpdateScopeShield" \
  && check "escudo atualiza ao clicar no radio 'so para mim'" 1 \
  || check "escudo atualiza ao clicar no radio 'so para mim'" 0 "NSD_OnClick ScopeCurrentUserRadio UpdateScopeShield nao encontrado"
```

Note: the `has()` helper does `grep -qF "$1" "$NSI"` — the backslash-escaped `\$` inside the double-quoted bash strings above is required so bash passes a literal `$` through to `grep -F`, matching the literal NSIS `$0`/`${NSD_OnClick}` text in the file (NSIS's `$`/`${}` syntax, not bash variable expansion).

- [ ] **Step 2: Run the suite and confirm the new checks fail**

Run: `bash tests/make-installer.test.sh`
Expected: all five new checks report `FAIL`.

- [ ] **Step 3: Add the BCM_SETSHIELD define**

In `scripts/installer.nsi`, right after the `MUI_ICON`/`MUI_UNICON` defines added in Task 1 (which sit right after `!define MUI_ABORTWARNING`), add:

```nsis
!define BCM_SETSHIELD 0x0000160C
```

- [ ] **Step 4: Add the UpdateScopeShield function**

In `scripts/installer.nsi`, add this new function right after `Function PageScope` ends (after its `FunctionEnd`, before `Function IsElevated`):

```nsis
; The wizard's Next/Install/Finish button is a single control owned by the
; parent frame ($HWNDPARENT), shared across every page -- not recreated per
; page. Control ID 1 is that button in every MUI2 page. Toggling the shield
; here only affects it while this function is called; PageScopeLeave turns
; it back off before moving on so it doesn't stay glued to Next on later,
; unrelated pages (Directory, Components, Install).
Function UpdateScopeShield
  GetDlgItem $0 $HWNDPARENT 1
  ${NSD_GetState} $ScopeAllUsersRadio $1
  ${If} $1 == ${BST_CHECKED}
    SendMessage $0 ${BCM_SETSHIELD} 0 1
  ${Else}
    SendMessage $0 ${BCM_SETSHIELD} 0 0
  ${EndIf}
FunctionEnd
```

- [ ] **Step 5: Wire the radio buttons and initial state in PageScope**

In `scripts/installer.nsi`, `Function PageScope` currently creates the two radios like this (near the end of the function, before `nsDialogs::Show`):

```nsis
  ${NSD_CreateRadioButton} 0 20u 100% 12u "Install for all users (requires administrator rights)"
  Pop $ScopeAllUsersRadio
  ${NSD_SetState} $ScopeAllUsersRadio ${BST_CHECKED}

  ${NSD_CreateRadioButton} 0 40u 100% 12u "Install for me only (no administrator rights required)"
  Pop $ScopeCurrentUserRadio

  nsDialogs::Show
```

Change it to:

```nsis
  ${NSD_CreateRadioButton} 0 20u 100% 12u "Install for all users (requires administrator rights)"
  Pop $ScopeAllUsersRadio
  ${NSD_SetState} $ScopeAllUsersRadio ${BST_CHECKED}
  ${NSD_OnClick} $ScopeAllUsersRadio UpdateScopeShield

  ${NSD_CreateRadioButton} 0 40u 100% 12u "Install for me only (no administrator rights required)"
  Pop $ScopeCurrentUserRadio
  ${NSD_OnClick} $ScopeCurrentUserRadio UpdateScopeShield

  Call UpdateScopeShield ; initial state: "all users" is preselected above

  nsDialogs::Show
```

- [ ] **Step 6: Turn the shield off in PageScopeLeave**

In `scripts/installer.nsi`, `Function PageScopeLeave` currently starts with:

```nsis
Function PageScopeLeave
  ${NSD_GetState} $ScopeAllUsersRadio $0
  ${If} $0 == ${BST_CHECKED}
    StrCpy $Scope "all"
  ${Else}
    StrCpy $Scope "user"
  ${EndIf}

  ${If} $Scope == "all"
```

Add the shield-off call between the scope decision and the `${If} $Scope == "all"` branch:

```nsis
Function PageScopeLeave
  ${NSD_GetState} $ScopeAllUsersRadio $0
  ${If} $0 == ${BST_CHECKED}
    StrCpy $Scope "all"
  ${Else}
    StrCpy $Scope "user"
  ${EndIf}

  ; The Next button belongs to the wizard frame, not this page -- turn the
  ; shield back off before moving on so it doesn't stay glued to Next on
  ; every later page.
  GetDlgItem $0 $HWNDPARENT 1
  SendMessage $0 ${BCM_SETSHIELD} 0 0

  ${If} $Scope == "all"
```

(The rest of `PageScopeLeave` is unchanged for this task — Task 4 edits inside the `${Else}` branch further down.)

- [ ] **Step 7: Run the suite and confirm everything passes**

Run: `bash tests/make-installer.test.sh`
Expected: `0 failed`.

- [ ] **Step 8: Commit**

```bash
git add scripts/installer.nsi tests/make-installer.test.sh
git commit -m "feat: mostrar o escudo do UAC no botao Next quando 'todos os usuarios' esta selecionado"
```

---

### Task 4: Upgrade robustness — cross-scope cleanup (`/CLEANUPALLUSERS`)

**Files:**
- Modify: `scripts/installer.nsi` — `Function PageScope` (add the `/CLEANUPALLUSERS` branch), `Function PageScopeLeave` (add HKLM-residue detection inside the `${Else}` branch), `Section "-core" SecCore` (add the cross-scope removal block after Task 2's same-scope block)
- Test: `tests/make-installer.test.sh`

**Interfaces:**
- Consumes: Task 2's same-scope cleanup block in `SecCore` (this task's cross-scope block is inserted directly after it), Task 3's `PageScope`/`PageScopeLeave` structure (the `/ALLUSERS` branch pattern this task mirrors, and the shield-off line this task's new code runs after)
- Produces: the `/CLEANUPALLUSERS` command-line marker — nothing downstream depends on it beyond this task, it's a self-contained relaunch signal.

- [ ] **Step 1: Add the failing test assertions**

In `tests/make-installer.test.sh`, add a new section after the UAC-shield block added in Task 3, before `# --- optional components ---`:

```bash
# --- upgrade cross-scope cleanup ---------------------------------------------

has "/CLEANUPALLUSERS" \
  && check "upgrade cross-scope usa uma marca de relancamento propria (/CLEANUPALLUSERS)" 1 \
  || check "upgrade cross-scope usa uma marca de relancamento propria (/CLEANUPALLUSERS)" 0 "/CLEANUPALLUSERS nao encontrado"

has 'ReadRegStr $0 HKLM "${UNINST_KEY}" "InstallLocation"' \
  && check "detecta uma instalacao 'todos os usuarios' orfa ao escolher 'so para mim'" 1 \
  || check "detecta uma instalacao 'todos os usuarios' orfa ao escolher 'so para mim'" 0 'ReadRegStr $0 HKLM "${UNINST_KEY}" "InstallLocation" nao encontrado'

has 'ReadRegStr $1 HKCU "${UNINST_KEY}" "InstallLocation"' \
  && check "remove residuo 'so para mim' ao instalar 'todos os usuarios' (sem elevacao extra)" 1 \
  || check "remove residuo 'so para mim' ao instalar 'todos os usuarios' (sem elevacao extra)" 0 'ReadRegStr $1 HKCU "${UNINST_KEY}" "InstallLocation" nao encontrado'

has 'ReadRegStr $1 HKLM "${UNINST_KEY}" "InstallLocation"' \
  && check "remove residuo 'todos os usuarios' ao instalar 'so para mim' (ja elevado)" 1 \
  || check "remove residuo 'todos os usuarios' ao instalar 'so para mim' (ja elevado)" 0 'ReadRegStr $1 HKLM "${UNINST_KEY}" "InstallLocation" nao encontrado'
```

- [ ] **Step 2: Run the suite and confirm the new checks fail**

Run: `bash tests/make-installer.test.sh`
Expected: all four new checks report `FAIL`.

- [ ] **Step 3: Add the /CLEANUPALLUSERS branch to PageScope**

In `scripts/installer.nsi`, `Function PageScope` currently handles `/ALLUSERS` like this (as of Task 1/3, unchanged in this area):

```nsis
Function PageScope
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/ALLUSERS" $R1
  ${IfNot} ${Errors}
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
```

Insert a second parameter check between the `${EndIf}` that closes the `/ALLUSERS` block and the `!insertmacro MUI_HEADER_TEXT` line:

```nsis
    Abort ; skip showing this page
  ${EndIf}

  ; /CLEANUPALLUSERS is the same idea as /ALLUSERS above, for the opposite
  ; case: the chosen scope stays "user", the elevated relaunch is only so
  ; SecCore can remove a leftover all-users installation before continuing.
  ClearErrors
  ${GetOptions} $R0 "/CLEANUPALLUSERS" $R1
  ${IfNot} ${Errors}
    Call IsElevated
    Pop $0
    ${If} $0 == "0"
      MessageBox MB_OK|MB_ICONEXCLAMATION \
        "Administrator rights are required to remove the existing all-users installation before continuing.$\r$\n$\r$\nRestart the installer and accept the elevation prompt, or uninstall the existing Aseprite installation manually first."
      Quit
    ${EndIf}
    StrCpy $Scope "user"
    SetShellVarContext current
    StrCpy $INSTDIR "$LOCALAPPDATA\Programs\Aseprite"
    Abort ; skip showing this page -- the choice was already made pre-relaunch
  ${EndIf}

  !insertmacro MUI_HEADER_TEXT "Choose Install Scope" "Who should be able to run Aseprite?"
```

- [ ] **Step 4: Detect the HKLM residue and relaunch in PageScopeLeave**

In `scripts/installer.nsi`, `Function PageScopeLeave`'s `${Else}` branch (the "user" scope path, added/confirmed in Task 3) currently reads:

```nsis
  ${Else}
    SetShellVarContext current
    StrCpy $INSTDIR "$LOCALAPPDATA\Programs\Aseprite"
  ${EndIf}
FunctionEnd
```

Change it to check for a stray all-users install first:

```nsis
  ${Else}
    ; If a previous all-users installation is on record, removing it needs
    ; elevation even though this run's own scope doesn't -- relaunch with a
    ; marker that keeps $Scope "user" instead of forcing "all".
    ReadRegStr $0 HKLM "${UNINST_KEY}" "InstallLocation"
    ${If} $0 != ""
    ${AndIf} ${FileExists} "$0\uninstall.exe"
      Call IsElevated
      Pop $1
      ${If} $1 == "0"
        ClearErrors
        ExecShell "runas" "$EXEPATH" "/CLEANUPALLUSERS"
        ${If} ${Errors}
          MessageBox MB_OK|MB_ICONEXCLAMATION \
            "Administrator rights are required to remove the existing all-users installation before continuing.$\r$\n$\r$\nRestart the installer and accept the elevation prompt, or uninstall the existing Aseprite installation manually first."
        ${EndIf}
        Quit
      ${EndIf}
    ${EndIf}
    SetShellVarContext current
    StrCpy $INSTDIR "$LOCALAPPDATA\Programs\Aseprite"
  ${EndIf}
FunctionEnd
```

- [ ] **Step 5: Add the cross-scope removal block to SecCore**

In `scripts/installer.nsi`, `Section "-core" SecCore` currently has (after Task 2) the same-scope cleanup block followed directly by `SetOutPath "$INSTDIR"`:

```nsis
    DetailPrint "Removing previous installation..."
    ExecWait '"$0\uninstall.exe" /S _?=$0'
  ${EndIf}

  SetOutPath "$INSTDIR"
```

Insert the cross-scope block between them:

```nsis
    DetailPrint "Removing previous installation..."
    ExecWait '"$0\uninstall.exe" /S _?=$0'
  ${EndIf}

  ; Cross-scope upgrade: also clean up a stray installation in the OTHER
  ; hive, if any. HKCU never needs elevation to remove. HKLM does, and was
  ; already secured back in PageScopeLeave via the /CLEANUPALLUSERS relaunch
  ; before this section ever runs.
  ${If} $Scope == "all"
    ReadRegStr $1 HKCU "${UNINST_KEY}" "InstallLocation"
    ${If} $1 != ""
    ${AndIf} ${FileExists} "$1\uninstall.exe"
      DetailPrint "Removing previous per-user installation..."
      ExecWait '"$1\uninstall.exe" /S _?=$1'
    ${EndIf}
  ${Else}
    ReadRegStr $1 HKLM "${UNINST_KEY}" "InstallLocation"
    ${If} $1 != ""
    ${AndIf} ${FileExists} "$1\uninstall.exe"
      DetailPrint "Removing previous all-users installation..."
      ExecWait '"$1\uninstall.exe" /S _?=$1'
    ${EndIf}
  ${EndIf}

  SetOutPath "$INSTDIR"
```

- [ ] **Step 6: Run the suite and confirm everything passes**

Run: `bash tests/make-installer.test.sh`
Expected: `0 failed`.

Also run the full suite one more time: `bash tests/run-all.sh`
Expected: `all suites passed`

- [ ] **Step 7: Commit**

```bash
git add scripts/installer.nsi tests/make-installer.test.sh
git commit -m "feat: remover instalacao orfa de outro escopo durante upgrade, elevando so quando necessario"
```

---

### Task 5: Manual validation on a real Windows machine

This task has no automated test — `makensis` compilation and installer *behavior* (UAC prompts, shield rendering, registry state, actual file removal) aren't things the static `grep`-based suite can verify, by design (see the original installer design doc's testing section). **This step is for the user (Artur) to run interactively, not something to delegate to a subagent** — it involves real UAC consent prompts and clicking through a GUI wizard on a live Windows machine.

**Files:** none (validation only, no code changes)

**Interfaces:** none

- [ ] **Step 1: Build a real setup.exe**

```bat
set ASEPRITE_VERSION=v1.3.18.2
build.cmd
```

Expected: `Done: dist\aseprite-v1.3.18.2-windows-x64-setup.exe`, no `!error` from the `ICONFILE` guard.

- [ ] **Step 2: Check the icon**

In Explorer, look at `dist\aseprite-v1.3.18.2-windows-x64-setup.exe`.
Expected: it shows the Aseprite icon, not the generic NSIS one.

- [ ] **Step 3: Check the shield and install "all users"**

Run the setup.exe. On the "Choose Install Scope" page, confirm the Next button already shows a UAC shield icon (since "all users" is preselected). Click the "Install for me only" radio and confirm the shield disappears from Next. Click "Install for all users" again and confirm it reappears. Leave "all users" selected and click Next.
Expected: a UAC prompt appears; accepting it continues the install into `Program Files\Aseprite`. After finishing, open Explorer to `Program Files\Aseprite\uninstall.exe` and confirm it shows the Aseprite icon too.

- [ ] **Step 4: Upgrade in place, same scope**

Build a newer version (e.g. `v1.3.18.3` if available, or reuse the same version to simulate a repair install) and run its setup.exe, again choosing "all users".
Expected: the install log (on the Install page) shows a `Removing previous installation...` line before the file copy starts. After finishing, check `Control Panel > Programs and Features` (or Settings > Apps) — only one Aseprite entry should be listed, with the new version number. Open Aseprite and confirm existing settings (e.g. any UI layout changes made before the upgrade) are still there.

- [ ] **Step 5: Cross-scope upgrade**

With the "all users" install from Step 4 still present, run setup.exe again and this time choose "Install for me only". Click Next.
Expected: a UAC prompt appears (this is the `/CLEANUPALLUSERS` relaunch) even though "only for me" doesn't itself need admin rights. Accepting it should show `Removing previous all-users installation...` in the install log, then complete installing into `%LocalAppData%\Programs\Aseprite`. Confirm `Program Files\Aseprite` no longer exists afterward, and that Programs and Features shows a single Aseprite entry.

- [ ] **Step 6: Uninstall cleanly**

Uninstall via Programs and Features (or the Start Menu shortcut).
Expected: no errors, `%LocalAppData%\Programs\Aseprite` (or `Program Files\Aseprite`, whichever scope was last installed) is gone, and the registry key `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Aseprite` (or `HKLM\...`) is gone.

No commit for this task — it's pure verification of work already committed in Tasks 1–4. If any step fails, go back to the relevant task, fix, re-run `bash tests/run-all.sh`, and amend forward with a new commit (not `--amend`) before re-validating.

---

## Self-Review Notes

- **Spec coverage:** Icon (Task 1) ✅, same-scope upgrade cleanup (Task 2) ✅, UAC shield (Task 3) ✅, cross-scope cleanup + `/CLEANUPALLUSERS` (Task 4) ✅, manual validation matching the design's own verification section (Task 5) ✅. The design's "fora de escopo" items (code signing, portable↔installed settings migration, pre-registry-era installs) are correctly not covered by any task.
- **Placeholder scan:** every step shows literal NSIS/bash code, no "add appropriate handling" placeholders.
- **Type/name consistency:** `UpdateScopeShield` (Task 3) is spelled identically everywhere it's referenced (Task 3 steps 4–6, Task 4 does not touch it). `$Scope`, `$ScopeAllUsersRadio`, `$ScopeCurrentUserRadio`, `${UNINST_KEY}`, `SHCTX` are all pre-existing identifiers, used with the same spelling as the current file. The `/CLEANUPALLUSERS` marker string is identical in Task 4's `PageScope` branch, `PageScopeLeave` relaunch, and its test assertion.
