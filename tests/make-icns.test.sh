#!/usr/bin/env bash
# Tests for scripts/make-icns.sh
# Run: bash tests/make-icns.test.sh
#
# make-icns.sh only runs for real on macOS, because iconutil is a macOS tool.
# What these tests cover is everything that happens *before* iconutil: the
# mapping from upstream PNG paths to canonical iconset names, and the refusal
# to carry on when upstream moves a file. A stub iconutil on PATH makes both
# reachable from any platform.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/make-icns.sh"

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

# Creates a fake `iconutil` in $1 that mimics `iconutil -c icns <set> -o <out>`.
# It writes, to the file named by $ICONSET_MANIFEST, one sorted
# "<destination name>:<file content>" line per entry in the iconset it was
# handed. Recording content alongside name (not just `ls`) is what lets the
# tests below tell apart "the right nine names are present" from "each name
# was actually built from the right source PNG" -- a bare listing can't, since
# it's identical either way when a mapping edit swaps two sources that were
# both already required elsewhere in the set.
make_stub_iconutil() {
  mkdir -p "$1"
  cat > "$1/iconutil" <<'STUB'
#!/usr/bin/env bash
iconset=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *)  iconset="$1"; shift ;;
  esac
done
[ -n "$iconset" ] || { echo "stub: no iconset argument" >&2; exit 1; }
[ -n "$out" ] || { echo "stub: no -o argument" >&2; exit 1; }
[ -d "$iconset" ] || { echo "stub: iconset $iconset is not a directory" >&2; exit 1; }
if [ -n "${ICONSET_MANIFEST:-}" ]; then
  for f in "$iconset"/*; do
    printf '%s:%s\n' "$(basename "$f")" "$(cat "$f")"
  done | LC_ALL=C sort > "$ICONSET_MANIFEST"
fi
printf 'fake icns payload\n' > "$out"
STUB
  chmod +x "$1/iconutil"
}

# Builds a fake Aseprite source tree in $1 containing every PNG make-icns.sh
# needs. $2, if given, names one PNG to leave out, which is how the
# missing-upstream-file case is set up.
#
# Each fake PNG's content is its own identity (e.g. data/icons/ase16.png
# contains the line "ase16"), not an interchangeable placeholder. That is
# what lets a test tell whether a destination in the iconset was populated
# from the *correct* source PNG rather than merely from *some* PNG that
# happens to exist in the fixture.
make_fake_src() {
  local root="$1" skip="${2:-}"
  mkdir -p "$root/data/icons/hd"
  local f
  for f in ase16.png ase32.png ase64.png ase128.png ase256.png; do
    [ "$f" = "$skip" ] && continue
    printf '%s\n' "${f%.png}" > "$root/data/icons/$f"
  done
  [ "$skip" = "asehd.png" ] || printf 'asehd\n' > "$root/data/icons/hd/asehd.png"
}

# The nine canonical "<destination name>:<source identity>" pairs iconutil
# must be handed, piped through the same `LC_ALL=C sort` the stub uses on its
# manifest so ordering is guaranteed to match on both sides of the comparison
# below rather than relying on a by-hand derivation of sort order.
EXPECTED_ICONSET="$(cat <<'EOF' | LC_ALL=C sort
icon_16x16.png:ase16
icon_16x16@2x.png:ase32
icon_32x32.png:ase32
icon_32x32@2x.png:ase64
icon_128x128.png:ase128
icon_128x128@2x.png:ase256
icon_256x256.png:ase256
icon_256x256@2x.png:asehd
icon_512x512.png:asehd
EOF
)"

# --- the iconset handed to iconutil is exactly the canonical set ------------

tmp="$(mktemp -d)"
make_stub_iconutil "$tmp/bin"
make_fake_src "$tmp/src"
ICONSET_MANIFEST="$tmp/manifest" \
  PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/src" "$tmp/out/Aseprite.icns" >/dev/null 2>&1
status=$?
got="$(cat "$tmp/manifest" 2>/dev/null)"
if [ "$status" = "0" ] && [ "$got" = "$EXPECTED_ICONSET" ]; then
  check "iconset mapeia cada nome canonico ao PNG de origem correto" 1
else
  check "iconset mapeia cada nome canonico ao PNG de origem correto" 0 \
    "$(printf 'status=%s\n       want=%q\n       got =%q' "$status" "$EXPECTED_ICONSET" "$got")"
fi

# The output directory does not exist beforehand on purpose: build.sh points
# this script straight at Aseprite.app/Contents/Resources/, which a bundle
# built from source may not have yet.
if [ -f "$tmp/out/Aseprite.icns" ]; then
  check "cria o diretorio de saida e escreve no caminho pedido" 1
else
  check "cria o diretorio de saida e escreve no caminho pedido" 0 "arquivo nao criado"
fi
rm -rf "$tmp"

# --- a PNG upstream no longer ships is a hard failure -----------------------
#
# This is the regression that matters most. A silently missing icon is exactly
# the bug being fixed here, so it must never come back by omission.

tmp="$(mktemp -d)"
make_stub_iconutil "$tmp/bin"
make_fake_src "$tmp/src" "asehd.png"
err="$(ICONSET_MANIFEST="$tmp/manifest" \
  PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/src" "$tmp/out/Aseprite.icns" 2>&1 >/dev/null)"
status=$?
[ "$status" = "1" ] \
  && check "png ausente no upstream aborta com status 1" 1 \
  || check "png ausente no upstream aborta com status 1" 0 "status=$status"
[ -n "$err" ] \
  && check "png ausente reporta o motivo em stderr" 1 \
  || check "png ausente reporta o motivo em stderr" 0 "stderr vazio"
[ ! -f "$tmp/out/Aseprite.icns" ] \
  && check "png ausente nao deixa icns pela metade" 1 \
  || check "png ausente nao deixa icns pela metade" 0 "arquivo de saida foi criado"
rm -rf "$tmp"

# Same three assertions, but for a PNG missing from the top-level data/icons/
# directory rather than data/icons/hd/ -- the case above only ever exercised
# the hd/ path, leaving the far more common top-level path unproven.

tmp="$(mktemp -d)"
make_stub_iconutil "$tmp/bin"
make_fake_src "$tmp/src" "ase128.png"
err="$(ICONSET_MANIFEST="$tmp/manifest" \
  PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/src" "$tmp/out/Aseprite.icns" 2>&1 >/dev/null)"
status=$?
[ "$status" = "1" ] \
  && check "png ausente em data/icons/ (fora de hd/) aborta com status 1" 1 \
  || check "png ausente em data/icons/ (fora de hd/) aborta com status 1" 0 "status=$status"
[ -n "$err" ] \
  && check "png ausente em data/icons/ (fora de hd/) reporta o motivo em stderr" 1 \
  || check "png ausente em data/icons/ (fora de hd/) reporta o motivo em stderr" 0 "stderr vazio"
[ ! -f "$tmp/out/Aseprite.icns" ] \
  && check "png ausente em data/icons/ (fora de hd/) nao deixa icns pela metade" 1 \
  || check "png ausente em data/icons/ (fora de hd/) nao deixa icns pela metade" 0 "arquivo de saida foi criado"
rm -rf "$tmp"

# --- argument handling ------------------------------------------------------

tmp="$(mktemp -d)"
make_stub_iconutil "$tmp/bin"
err="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" 2>&1 >/dev/null)"
status=$?
[ "$status" = "1" ] && [ -n "$err" ] \
  && check "sem argumentos aborta com uso em stderr" 1 \
  || check "sem argumentos aborta com uso em stderr" 0 "status=$status stderr=$err"

err="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$tmp/src" 2>&1 >/dev/null)"
status=$?
[ "$status" = "1" ] && [ -n "$err" ] \
  && check "um argumento so aborta com uso em stderr" 1 \
  || check "um argumento so aborta com uso em stderr" 0 "status=$status stderr=$err"
rm -rf "$tmp"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
