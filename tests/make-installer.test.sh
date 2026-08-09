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
