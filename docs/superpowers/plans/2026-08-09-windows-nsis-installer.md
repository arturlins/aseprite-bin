# Instalador Windows via NSIS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Acrescentar um instalador NSIS (`dist\aseprite-<versao>-windows-x64-setup.exe`) ao build Windows, ao lado da pasta portátil já existente, com escolha de escopo em tempo de execução (todos os usuários vs. só o usuário atual, com auto-elevação sob demanda), atalhos e associação de `.aseprite`/`.ase` opcionais.

**Architecture:** Um script NSIS novo (`scripts/installer.nsi`) consome a pasta portátil já montada pelo `build.cmd` como fonte — nenhuma recompilação nem recópia duplicada. `build.cmd` ganha um guard de ferramenta e um bloco de empacotamento no fim; `build-windows.yml` ganha um step de instalação do NSIS e um segundo artifact. Linux e macOS ficam intocados.

**Tech Stack:** NSIS 3.x (Modern UI 2, nsDialogs, FileFunc), batch (`build.cmd`), GitHub Actions (Chocolatey), bash para os testes (`tests/*.test.sh`).

**Spec:** `docs/superpowers/specs/2026-08-09-windows-nsis-installer-design.md`

## Global Constraints

- **Plataforma do script novo:** Windows apenas. `scripts/installer.nsi` só é compilado e só roda de verdade em `build.cmd` / `build-windows.yml`.
- **Linux e macOS intocados.** Nenhum arquivo fora dos listados em File Structure muda.
- **Sem plugins NSIS de terceiro.** Só o que já vem em `choco install nsis` (Modern UI 2, nsDialogs, FileFunc, UserInfo) — decisão do design para evitar fixar por hash mais uma dependência externa, igual à postura já adotada no macOS com `dmgbuild`.
- **Escopo de instalação é escolha em tempo de execução**, pré-selecionado em "todos os usuários". Nunca força UAC só por abrir o instalador (`RequestExecutionLevel user`).
- **Pasta de instalação sem número de versão:** `Aseprite` — `%ProgramFiles%\Aseprite` (todos os usuários) ou `%LocalAppData%\Programs\Aseprite` (só o usuário atual).
- **Atalho de Desktop:** opcional, **desmarcado** por padrão. **Associação de arquivo:** opcional, **marcada** por padrão. **Menu Iniciar:** sempre criado, não é opcional.
- **`aseprite.ini` (marcador portátil) nunca é copiado pelo instalador.** A versão instalada usa `%APPDATA%`.
- **Upgrade:** `RMDir /r` em `$INSTDIR\data` antes de copiar os arquivos novos, para não deixar arquivo órfão de versão antiga.
- **Nomes de artifact:** `aseprite-<versao>-windows-x64` (portátil, inalterado) e `aseprite-<versao>-windows-x64-setup` (novo, instalador).
- **Sem assinatura de código.** Mesma postura já adotada para o `.dmg` do macOS (sem notarização).
- **Idioma da interface do instalador:** inglês, igual ao restante do material voltado ao usuário (README, `READ ME FIRST.txt` do macOS). **Idioma dos testes:** português, para casar com a suíte já existente.
- **Convenção de teste:** bash puro, sem framework, contadores `pass`/`fail`, linhas `ok   - <nome>` / `FAIL - <nome>`, `[ "$fail" -eq 0 ]` na última linha — mesmo formato de `tests/make-dmg.test.sh`.
- **A suíte de testes roda sem dependências externas** (invariante já declarada no README: `bash tests/run-all.sh`). `makensis` não é assumido instalado — os testes deste plano cobrem a estrutura do `.nsi` via grep, não uma compilação real.

---

## File Structure

| Arquivo | Responsabilidade |
|---|---|
| `scripts/installer.nsi` | **Criar.** Script NSIS completo: escolha de escopo com auto-elevação, instalação, atalhos, associação de arquivo, entrada de Add/Remove Programs, desinstalador. |
| `tests/make-installer.test.sh` | **Criar.** Cobre a estrutura do `.nsi` via grep e a consistência dos `/D` defines entre `installer.nsi` e `build.cmd`. Roda em qualquer plataforma, sem `makensis`. |
| `build.cmd` | **Modificar.** Guard de `makensis.exe` junto aos outros guards de ferramenta; bloco de empacotamento do instalador no final. |
| `.github/workflows/build-windows.yml` | **Modificar.** Step `choco install nsis`; corrige o `path` do upload existente (hoje pegaria o `.exe` novo também, quebrando a separação em dois artifacts); novo step de upload do instalador. |
| `README.md` | **Modificar.** Tabela "What you get", seção Windows (instalador ao lado do portátil), pré-requisito opcional de NSIS local. |

**Ordem:** Task 1 é autocontida (script + teste + integração no `build.cmd`, testável sem depender do workflow). Task 2 depende da Task 1 (usa o `dist\*.exe` que ela passa a produzir). Task 3 depende das duas anteriores (documenta o resultado final).

---

### Task 1: `scripts/installer.nsi` e integração no `build.cmd`

**Files:**
- Create: `scripts/installer.nsi`
- Test: `tests/make-installer.test.sh`
- Modify: `build.cmd:37-45` (guard) e `build.cmd:159-160` (empacotamento)

**Interfaces:**
- Consumes: a pasta portátil já montada em `build.cmd` (`%OUTDIR%` = `dist\aseprite-%ASEPRITE_VERSION%-windows-x64`, contendo `aseprite.exe`, `data\`, `docs\`), e a variável `%ASEPRITE_VERSION_NUMBER%` já calculada em `build.cmd` (versão sem o `v`).
- Produces: `dist\aseprite-<versao>-windows-x64-setup.exe`. Uso via `makensis /DVERSION=<tag> /DVERSION_NUMBER=<sem-v> /DSRCDIR=<pasta-portatil-absoluta> /DOUTFILE=<caminho-de-saida-absoluto> scripts\installer.nsi`. As quatro defines são obrigatórias — o script aborta a compilação com `!error` se qualquer uma faltar.

**Contexto para quem implementa:** o repositório oficial do Aseprite não traz nenhum instalador NSIS pronto (é um pedido em aberto, [aseprite/aseprite#322](https://github.com/aseprite/aseprite/issues/322)) — este script é escrito do zero, sem nada para adaptar do upstream.

A escolha de escopo (todos os usuários vs. só o usuário atual) é decidida em tempo de execução numa página customizada (`nsDialogs`), não fixada em `RequestExecutionLevel`. O detalhe que mais importa aqui: **`UserInfo::GetAccountType` não é confiável para saber se o processo está elevado** — ele reporta se a *conta* pertence ao grupo Administradores, não se o *processo atual* está rodando elevado, e uma conta admin sem UAC elevado ainda reporta "Admin". Por isso o script testa elevação de um jeito mais direto: tenta escrever um arquivo de teste em `$PROGRAMFILES64` e vê se funciona (função `IsElevated`). Se "todos os usuários" foi escolhido e o teste falhar, o instalador se relança sozinho elevado via `ExecShell "runas"`, passando `/ALLUSERS` na linha de comando para a instância elevada pular a tela de escolha; a instância original fecha com `Quit`.

O registro usa `SHCTX` em vez de `HKLM`/`HKCU` fixos — é um pseudo-root nativo do NSIS (não precisa de `MultiUser.nsh`) que resolve para `HKEY_LOCAL_MACHINE` ou `HKEY_CURRENT_USER` de acordo com o último `SetShellVarContext all`/`current` chamado. O mesmo `SetShellVarContext` também já resolve `$SMPROGRAMS`/`$DESKTOP` para a pasta certa (todos os usuários vs. usuário atual) automaticamente — não precisa de lógica extra para isso.

O desinstalador não descobre o escopo pelo caminho de instalação (o usuário pode ter customizado a pasta na tela de diretório) — ele lê de volta um valor `InstallScope` gravado no registro pela própria instalação, primeiro em `HKLM`, depois em `HKCU`. Só um dos dois vai ter a chave, então não há ambiguidade.

- [ ] **Step 1: Escrever a suíte de testes que falha**

Crie `tests/make-installer.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/installer.nsi
# Run: bash tests/make-installer.test.sh
#
# Compiling the script for real requires makensis, a Windows-only external
# tool this suite does not assume is installed (mirrors how make-dmg.test.sh
# cannot invoke dmgbuild). What these tests cover instead: every structural
# piece the design relies on is actually present in the script, and the
# command-line defines build.cmd passes match the ones the script requires --
# a name changed on one side only would otherwise fail deep inside a CI run
# with "!error" or a silent wrong value, not here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NSI="$ROOT/scripts/installer.nsi"
BUILD_CMD="$ROOT/build.cmd"

pass=0
fail=0

check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "1" ]; then
    pass=$((pass + 1))
    printf 'ok   - %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n       %s\n' "$name" "$detail"
  fi
}

if [ ! -f "$NSI" ]; then
  check "scripts/installer.nsi existe" 0 "arquivo nao encontrado"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
check "scripts/installer.nsi existe" 1

has() {
  grep -qF "$1" "$NSI"
}

# --- required command-line defines, and that build.cmd supplies all of them -

for define in VERSION VERSION_NUMBER SRCDIR OUTFILE; do
  if grep -q "!ifndef $define" "$NSI"; then
    check "installer.nsi exige /D$define" 1
  else
    check "installer.nsi exige /D$define" 0 "!ifndef $define nao encontrado"
  fi

  if grep -q "/D$define=" "$BUILD_CMD"; then
    check "build.cmd passa /D$define" 1
  else
    check "build.cmd passa /D$define" 0 "/D$define= nao encontrado em build.cmd"
  fi
done

# --- dual-scope install: never forces elevation, self-elevates on demand ----

has "RequestExecutionLevel user" \
  && check "instalador nunca forca UAC so por abrir" 1 \
  || check "instalador nunca forca UAC so por abrir" 0 "RequestExecutionLevel user nao encontrado"

has '$PROGRAMFILES64\Aseprite' \
  && check "escopo 'todos os usuarios' aponta para Program Files" 1 \
  || check "escopo 'todos os usuarios' aponta para Program Files" 0 "caminho nao encontrado"

has '$LOCALAPPDATA\Programs\Aseprite' \
  && check "escopo 'so para mim' aponta para LocalAppData" 1 \
  || check "escopo 'so para mim' aponta para LocalAppData" 0 "caminho nao encontrado"

has 'ExecShell "runas"' \
  && check "auto-elevacao usa ExecShell runas" 1 \
  || check "auto-elevacao usa ExecShell runas" 0 "ExecShell \"runas\" nao encontrado"

has "SHCTX" \
  && check "registro usa SHCTX (resolve HKLM/HKCU pelo escopo)" 1 \
  || check "registro usa SHCTX (resolve HKLM/HKCU pelo escopo)" 0 "SHCTX nao encontrado"

# --- optional components: desktop shortcut off, file association on --------

grep -q 'Section "Desktop shortcut" SecDesktop' "$NSI" \
  && check "secao de atalho de desktop existe" 1 \
  || check "secao de atalho de desktop existe" 0 "secao nao encontrada"

grep -q 'SectionSetFlags ${SecDesktop} 0' "$NSI" \
  && check "atalho de desktop desmarcado por padrao" 1 \
  || check "atalho de desktop desmarcado por padrao" 0 'SectionSetFlags ${SecDesktop} 0 nao encontrado'

grep -q 'Section "Associate .aseprite and .ase files with Aseprite" SecFileAssoc' "$NSI" \
  && check "secao de associacao de arquivo existe" 1 \
  || check "secao de associacao de arquivo existe" 0 "secao nao encontrada"

has '"Software\Classes\.aseprite"' \
  && check "associa a extensao .aseprite" 1 \
  || check "associa a extensao .aseprite" 0 "chave .aseprite nao encontrada"

has '"Software\Classes\.ase"' \
  && check "associa a extensao .ase" 1 \
  || check "associa a extensao .ase" 0 "chave .ase nao encontrada"

# --- upgrade hygiene and portable/installed separation ----------------------

has 'RMDir /r "$INSTDIR\data"' \
  && check "limpa data\\ antes de copiar (evita arquivo orfao apos upgrade)" 1 \
  || check "limpa data\\ antes de copiar (evita arquivo orfao apos upgrade)" 0 "RMDir /r do data nao encontrado"

if grep -q "aseprite.ini" "$NSI"; then
  check "nao copia aseprite.ini (versao instalada nao e portatil)" 0 \
    "installer.nsi menciona aseprite.ini -- nao deveria copiar o marcador portatil"
else
  check "nao copia aseprite.ini (versao instalada nao e portatil)" 1
fi

# --- uninstaller: scope resolved from the registry, not guessed from a path -

grep -q 'Section "Uninstall"' "$NSI" \
  && check "desinstalador existe" 1 \
  || check "desinstalador existe" 0 'Section "Uninstall" nao encontrada'

has "InstallScope" \
  && check "escopo gravado no registro para o desinstalador ler de volta" 1 \
  || check "escopo gravado no registro para o desinstalador ler de volta" 0 "InstallScope nao encontrado"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Rodar os testes para confirmar que falham**

Run: `bash tests/make-installer.test.sh`
Expected: a primeira asserção falha (`scripts/installer.nsi existe`), status 1, saída terminando em `1 passed, 1 failed` (o script sai cedo assim que o arquivo não é encontrado).

- [ ] **Step 3: Escrever `scripts/installer.nsi`**

```nsis
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
```

- [ ] **Step 4: Adicionar o guard de `makensis.exe` no `build.cmd`**

Em `build.cmd`, localize (linhas 37-48):

```batch
if exist "%ProgramFiles%\7-Zip\7z.exe" (
  set SZIP="%ProgramFiles%\7-Zip\7z.exe"
) else (
  where /q 7za.exe || (
    echo ERROR: 7-Zip installation or "7za.exe" not found
    exit /b 1
  )
  set SZIP=7za.exe
)


rem *** Visual Studio environment ***
```

Substitua por:

```batch
if exist "%ProgramFiles%\7-Zip\7z.exe" (
  set SZIP="%ProgramFiles%\7-Zip\7z.exe"
) else (
  where /q 7za.exe || (
    echo ERROR: 7-Zip installation or "7za.exe" not found
    exit /b 1
  )
  set SZIP=7za.exe
)

if exist "%ProgramFiles(x86)%\NSIS\makensis.exe" (
  set MAKENSIS="%ProgramFiles(x86)%\NSIS\makensis.exe"
) else (
  where /q makensis.exe || (
    echo ERROR: NSIS "makensis.exe" not found
    echo Install it from https://nsis.sourceforge.io/ or run "choco install nsis"
    exit /b 1
  )
  set MAKENSIS=makensis.exe
)


rem *** Visual Studio environment ***
```

Checar cedo (antes de compilar) em vez de só na hora de empacotar é o mesmo padrão já usado para `git.exe` e `7z.exe` logo acima.

- [ ] **Step 5: Adicionar o empacotamento do instalador no final do `build.cmd`**

Localize (linhas 157-160):

```batch
xcopy /E /Q /Y build\bin\data %OUTDIR%\data\ || echo failed to copy data && exit /b 1
xcopy /E /Q /Y aseprite\docs %OUTDIR%\docs\ || echo failed to copy docs && exit /b 1

echo Done: %OUTDIR%
```

Substitua por:

```batch
xcopy /E /Q /Y build\bin\data %OUTDIR%\data\ || echo failed to copy data && exit /b 1
xcopy /E /Q /Y aseprite\docs %OUTDIR%\docs\ || echo failed to copy docs && exit /b 1

echo Done: %OUTDIR%


rem *** installer (NSIS) ***

set SETUPFILE=dist\aseprite-%ASEPRITE_VERSION%-windows-x64-setup.exe
%MAKENSIS% /DVERSION=%ASEPRITE_VERSION% /DVERSION_NUMBER=%ASEPRITE_VERSION_NUMBER% /DSRCDIR=%CD%\%OUTDIR% /DOUTFILE=%CD%\%SETUPFILE% scripts\installer.nsi || echo failed to build installer && exit /b 1

echo Done: %SETUPFILE%
```

`%OUTDIR%` e `%ASEPRITE_VERSION_NUMBER%` já existem no escopo (definidos mais acima no mesmo script, nas linhas 77 e 153).

- [ ] **Step 6: Rodar os testes para confirmar que passam**

Run: `bash tests/make-installer.test.sh`
Expected: `19 passed, 0 failed`, exit 0.

- [ ] **Step 7: Rodar a suíte completa**

Run: `bash tests/run-all.sh`
Expected: todas as suítes passam, última linha `all suites passed`, exit 0.

- [ ] **Step 8: Revisar que o restante do `build.cmd` não mudou de comportamento**

Run: `git diff build.cmd`
Expected: as únicas mudanças são o bloco de guard (Step 4) e o bloco de empacotamento (Step 5), inseridos — nada mais foi reindentado ou alterado.

- [ ] **Step 9: Commit**

```bash
git add scripts/installer.nsi tests/make-installer.test.sh build.cmd
git commit -m "feat: adicionar instalador NSIS ao build Windows

Empacota a pasta portatil ja montada num instalador que copia para
Program Files ou LocalAppData, dependendo de uma escolha de escopo em
tempo de execucao -- nao forca elevacao UAC so por abrir, e so se
autoeleva quando 'todos os usuarios' e escolhido e o processo ainda
nao esta elevado (ExecShell runas), sem depender do plugin UAC.dll de
terceiro que MultiUser.nsh precisaria para o mesmo efeito.

UserInfo::GetAccountType nao foi usado para detectar elevacao: ele
reporta associacao de grupo da conta, nao o estado real do processo, e
uma conta admin sem UAC elevado ainda reportaria 'Admin'. A checagem
real e uma tentativa de escrita em Program Files.

O desinstalador le o escopo de volta do registro (InstallScope) em vez
de adivinhar pelo caminho, ja que o usuario pode redirecionar a pasta
de instalacao na tela de diretorio.

Os testes cobrem a estrutura do .nsi via grep e a consistencia dos /D
defines entre installer.nsi e build.cmd -- makensis nao e assumido
instalado, mantendo a suite rodavel sem dependencias externas."
```

---

### Task 2: Publicar o instalador no workflow

**Files:**
- Modify: `.github/workflows/build-windows.yml`

**Interfaces:**
- Consumes: `dist\aseprite-<versao>-windows-x64-setup.exe` produzido pela Task 1.
- Produces: dois artifacts no run do Actions — `aseprite-<versao>-windows-x64` (só a pasta portátil) e `aseprite-<versao>-windows-x64-setup` (só o instalador).

**Contexto para quem implementa:** o step de upload existente hoje usa `path: dist`, que pega a pasta `dist` inteira. Depois da Task 1, `dist` passa a conter **tanto** a pasta portátil **quanto** o novo `.exe` do instalador — se o `path` não for restringido, os dois formatos caem dentro do mesmo artifact, quebrando a decisão de tê-los separados. Por isso o `path` do step existente também muda, não só o novo step sendo adicionado.

- [ ] **Step 1: Instalar o NSIS e separar os dois artifacts**

Em `.github/workflows/build-windows.yml`, localize:

```yaml
      - name: Build
        shell: cmd
        run: call build.cmd
        env:
          ASEPRITE_VERSION: ${{ steps.resolve.outputs.version }}

      - name: Upload artifact
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: aseprite-${{ steps.resolve.outputs.version }}-windows-x64
          path: dist
          if-no-files-found: error
          retention-days: 7
```

Substitua por:

```yaml
      - name: Install NSIS
        run: choco install nsis --no-progress -y

      - name: Build
        shell: cmd
        run: call build.cmd
        env:
          ASEPRITE_VERSION: ${{ steps.resolve.outputs.version }}

      - name: Upload portable artifact
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: aseprite-${{ steps.resolve.outputs.version }}-windows-x64
          path: dist/aseprite-*-windows-x64
          if-no-files-found: error
          retention-days: 7

      - name: Upload installer artifact
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: aseprite-${{ steps.resolve.outputs.version }}-windows-x64-setup
          path: dist/*.exe
          if-no-files-found: error
          retention-days: 7
```

O padrão `dist/aseprite-*-windows-x64` só bate com a pasta portátil (termina exatamente em `windows-x64`, não em `windows-x64-setup.exe`); `dist/*.exe` só bate com o instalador. `if-no-files-found: error` em ambos continua sendo a rede de segurança: se qualquer um dos dois não for gerado, o job falha em vez de publicar um artifact vazio.

- [ ] **Step 2: Validar o YAML**

Run: `python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build-windows.yml')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-windows.yml
git commit -m "feat: publicar o instalador NSIS como segundo artifact do build Windows

O step de upload existente usava path: dist, que agora pegaria tanto a
pasta portatil quanto o novo instalador no mesmo artifact -- corrigido
para dist/aseprite-*-windows-x64, e um segundo step publica dist/*.exe
separadamente."
```

---

### Task 3: Atualizar o README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: os dois artifacts definidos na Task 2.
- Produces: nada consumido por outra task.

**Contexto para quem implementa:** o README já está em inglês, para público leigo (reescrita anterior, Task 5 do plano `2026-08-08-macos-dmg-packaging.md`). Este update segue o mesmo padrão: nenhum termo novo (UAC, Program Files, registro) aparece sem explicação de uma linha.

- [ ] **Step 1: Atualizar a linha do Windows na tabela "What you get"**

Localize:

```markdown
| `Build (Windows)` | `windows-2025` | a folder with `aseprite.exe`, `data/` and `docs/` |
```

Substitua por:

```markdown
| `Build (Windows)` | `windows-2025` | a folder with `aseprite.exe`, `data/` and `docs/`, or an installer that sets it up for you |
```

- [ ] **Step 2: Expandir a seção Windows**

Localize:

```markdown
### Windows

The artifact is a `.zip` containing the folder
`aseprite-v1.3.18.1-windows-x64`. Unzip it anywhere you like and run:

    aseprite-v1.3.18.1-windows-x64\aseprite.exe

The included `aseprite.ini` makes the program portable, keeping its settings in
that same folder instead of in your user profile. Move the folder and your
settings come along.
```

Substitua por:

```markdown
### Windows

The Windows workflow produces **two separate downloads**, so you only get the
one you actually want: `aseprite-<version>-windows-x64` (portable) and
`aseprite-<version>-windows-x64-setup` (installer).

**Portable.** The artifact is a `.zip` containing the folder
`aseprite-v1.3.18.1-windows-x64`. Unzip it anywhere you like and run:

    aseprite-v1.3.18.1-windows-x64\aseprite.exe

The included `aseprite.ini` makes the program portable, keeping its settings in
that same folder instead of in your user profile. Move the folder and your
settings come along.

**Installer.** The artifact is a `.zip` containing a single `.exe`. Run it and
you'll be asked:

- **Install for all users** or **install for me only.** The first needs
  administrator rights and installs to `C:\Program Files\Aseprite`; the second
  needs no special rights and installs to your own user profile instead. Pick
  the second if you're on a computer where you don't have administrator
  access — for example, a work computer managed by an organization.
- Whether to add a **desktop shortcut** (off by default — a Start Menu
  shortcut is always created) and whether to **open `.aseprite`/`.ase` files
  with Aseprite** by double-clicking them (on by default).

The installed copy keeps its settings in your Windows user profile rather than
next to the program, and adds an entry to Windows' "Add or remove programs" so
you can uninstall it the normal way.
```

- [ ] **Step 3: Documentar o NSIS como pré-requisito opcional local**

Localize:

```markdown
**Windows** — needs Visual Studio with "Desktop development with C++", Git,
7-Zip and CMake:

    set ASEPRITE_VERSION=v1.3.18.1
    build.cmd
```

Substitua por:

```markdown
**Windows** — needs Visual Studio with "Desktop development with C++", Git,
7-Zip and CMake. [NSIS][] is optional — install it too if you also want
`build.cmd` to produce the installer, not just the portable folder:

    set ASEPRITE_VERSION=v1.3.18.1
    build.cmd
```

- [ ] **Step 4: Adicionar a referência do link**

Localize:

```markdown
[dmgbuild]: https://github.com/dmgbuild/dmgbuild
```

Substitua por:

```markdown
[dmgbuild]: https://github.com/dmgbuild/dmgbuild
[NSIS]: https://nsis.sourceforge.io/
```

- [ ] **Step 5: Conferir que nenhuma promessa desatualizada sobrou**

Run: `grep -n "windows-x64" README.md`
Expected: ocorrências na tabela e na nova seção Windows, todas consistentes com os dois artifacts (`...-windows-x64` e `...-windows-x64-setup`) — nenhuma menção antiga de artifact único.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: documentar o instalador NSIS no README"
```

---

## Verificação final (após todas as tasks)

Estes passos não pertencem a nenhuma task porque cruzam todas elas.

- [ ] **Suíte completa passa**

Run: `bash tests/run-all.sh`
Expected: `all suites passed`, exit 0.

- [ ] **Build local completo, nos dois escopos**

Esta é a única verificação que fecha o ciclo — nenhum teste local compila o `.nsi` de verdade. Nesta mesma máquina Windows:

1. `choco install nsis` (ou instalar manualmente), depois `set ASEPRITE_VERSION=v1.3.18.1 && build.cmd` (ou a versão mais recente).
2. Confirmar que `dist\` contém a pasta portátil **e** `aseprite-<versao>-windows-x64-setup.exe`.
3. Rodar o instalador, escolher **"Install for me only"** — confirma que não pede UAC, instala em `%LocalAppData%\Programs\Aseprite`, cria o atalho de Menu Iniciar, abre o Aseprite ao final.
4. Desinstalar por "Add or remove programs" — confirma que a pasta some e que `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Aseprite` some do registro.
5. Rodar o instalador de novo, escolher **"Install for all users"** — confirma que pede UAC, instala em `C:\Program Files\Aseprite`, e que marcar o checkbox de associação de arquivo faz um duplo-clique num `.aseprite` abrir no Aseprite instalado.
6. Marcar o checkbox de atalho de Desktop numa instalação e confirmar que o ícone aparece; deixar desmarcado numa outra e confirmar que não aparece.
7. Desinstalar de novo — confirma que a associação de arquivo e o atalho de Desktop somem junto.
8. Rodar o instalador uma terceira vez sobre uma instalação já existente (mesmo escopo) com uma versão diferente — confirma que não sobra nenhum arquivo da versão anterior em `data\`.

- [ ] **Verificar se `aseprite.exe` já carrega um ícone embutido**

Item em aberto do design: olhar o ícone de `dist\...\aseprite.exe` no Explorer. Se for o ícone genérico de `.exe` (não o do Aseprite), os atalhos e o Add/Remove Programs herdam esse mesmo genérico — cosmético, não bloqueia este plano. Registrar o resultado no spec; se for genérico, gerar um `.ico` próprio (nos moldes do `make-icns.sh` do macOS, a partir de `data/icons/*.png`) fica como um follow-up separado.

---

## Self-review

**Cobertura do spec:**

| Requisito do spec | Task |
|---|---|
| Compila uma vez, empacota duas (reaproveita a pasta portátil) | 1 |
| `choco install nsis` no CI | 2 |
| Dois artifacts separados | 2 |
| Escolha de escopo em tempo de execução, "todos os usuários" pré-selecionado | 1 |
| Auto-elevação sem plugin de terceiro (`ExecShell "runas"` + teste de escrita) | 1 |
| `RequestExecutionLevel user` | 1 |
| Pasta sem número de versão (`Aseprite`) | 1 |
| Limpeza de `data\` no upgrade | 1 |
| `aseprite.ini` não copiado no instalador | 1 (teste inclui asserção negativa) |
| Menu Iniciar sempre, Desktop opcional desmarcado | 1 |
| Associação de `.aseprite`/`.ase` opcional marcada | 1 |
| Add/Remove Programs | 1 |
| Desinstalador detecta o próprio escopo | 1 |
| README documenta os dois formatos | 3 |
| Verificação manual num Windows real | Verificação final |
| Item em aberto do ícone embutido | Verificação final |

**Consistência de nomes entre tasks:**

- `/DVERSION`, `/DVERSION_NUMBER`, `/DSRCDIR`, `/DOUTFILE` — definidos como obrigatórios em `installer.nsi` (Task 1) e passados com esses nomes exatos em `build.cmd` (Task 1); o teste da Task 1 falha se um dos dois lados divergir.
- `dist\aseprite-<versao>-windows-x64-setup.exe` — mesmo caminho usado no `build.cmd` (Task 1, variável `SETUPFILE`) e no `path: dist/*.exe` do workflow (Task 2).
- `SecDesktop`, `SecFileAssoc` — mesmos nomes de seção usados em `.onInit` (default unselected), nas declarações `Section` e nas descrições `MUI_DESCRIPTION_TEXT`, todos dentro da Task 1.
- `InstallScope` — gravado em `SecCore` e lido de volta no `Section "Uninstall"`, ambos na Task 1.
- `Aseprite.Document` — mesmo ProgId usado na instalação e na desinstalação da associação de arquivo, Task 1.
