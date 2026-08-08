#!/usr/bin/env bash
# Tests for scripts/make-dmg.sh
# Run: bash tests/make-dmg.test.sh
#
# Everything make-dmg.sh does after its preconditions pass -- creating a venv,
# running dmgbuild, mounting the result -- is macOS-only and cannot run here.
# What these tests pin down is the guard rail in front of all that: the script
# must refuse, loudly and before doing any work, when handed something it
# cannot package. The real coverage of the packaging itself is the
# mount-and-assert block at the end of the script, which runs on every build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/make-dmg.sh"

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

# Builds a fake Aseprite.app in $1. $2 = "no-icon" leaves out the .icns that
# make-icns.sh is supposed to have put there.
make_fake_app() {
  local app="$1" variant="${2:-}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  printf 'fake binary\n' > "$app/Contents/MacOS/aseprite"
  [ "$variant" = "no-icon" ] || printf 'fake icns\n' > "$app/Contents/Resources/Aseprite.icns"
}

# run_precondition <name> <expected_status> <want_stderr:yes|no> [args...]
# Asserts on status and on whether anything was written to stderr. A status
# code alone cannot tell a script that explained its refusal apart from one
# that died silently.
run_precondition() {
  local name="$1" want_status="$2" want_stderr="$3"
  shift 3

  local err status
  err="$(bash "$SCRIPT" "$@" 2>&1 >/dev/null)"
  status=$?

  local ok=1 detail=""
  if [ "$status" != "$want_status" ]; then
    ok=0; detail="want status=$want_status got=$status"
  elif [ "$want_stderr" = "yes" ] && [ -z "$err" ]; then
    ok=0; detail="esperava mensagem em stderr, veio vazio"
  elif [ "$want_stderr" = "no" ] && [ -n "$err" ]; then
    ok=0; detail="esperava stderr vazio, veio: $err"
  fi
  check "$name" "$ok" "$detail"
}

run_precondition "sem argumentos aborta" 1 yes
run_precondition "argumentos de menos abortam" 1 yes "/nope/Aseprite.app"
run_precondition "argumentos demais abortam" 1 yes \
  "/nope/Aseprite.app" "v1.3.18.1" "out.dmg" "extra"

tmp="$(mktemp -d)"
run_precondition "app inexistente aborta" 1 yes \
  "$tmp/missing/Aseprite.app" "v1.3.18.1" "$tmp/out.dmg"

# The .icns is what make-icns.sh is responsible for. If packaging ran anyway,
# the user would get a DMG whose app has no icon and whose volume has no icon
# -- silently, which is the failure mode this whole change exists to remove.
make_fake_app "$tmp/no-icon/Aseprite.app" "no-icon"
run_precondition "app sem Aseprite.icns aborta" 1 yes \
  "$tmp/no-icon/Aseprite.app" "v1.3.18.1" "$tmp/out.dmg"

# HFS+ caps volume names at 27 characters. Nothing the version regex allows
# gets near that today, but a silently truncated volume name would be a
# baffling thing to debug, so the script checks instead of hoping.
make_fake_app "$tmp/ok/Aseprite.app"
run_precondition "nome de volume longo demais aborta" 1 yes \
  "$tmp/ok/Aseprite.app" "v1.3.18.1-this-version-string-is-far-too-long" "$tmp/out.dmg"

[ ! -f "$tmp/out.dmg" ] \
  && check "nenhuma pre-condicao falha deixa dmg pela metade" 1 \
  || check "nenhuma pre-condicao falha deixa dmg pela metade" 0 "out.dmg foi criado"
rm -rf "$tmp"

# --- the settings file must not drift from the script -----------------------
#
# dmg-settings.py reads its paths from the environment. If a name is changed
# on one side only, dmgbuild dies with a KeyError deep inside a CI run instead
# of here.
SETTINGS="$ROOT/scripts/dmg-settings.py"
for var in DMG_APP_PATH DMG_README_PATH DMG_VOLUME_ICON; do
  if grep -q "$var" "$SETTINGS" && grep -q "$var" "$SCRIPT"; then
    check "$var e usado nos dois lados" 1
  else
    check "$var e usado nos dois lados" 0 "ausente em dmg-settings.py ou em make-dmg.sh"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
