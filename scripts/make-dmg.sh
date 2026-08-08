#!/usr/bin/env bash
#
# Packages a built Aseprite.app into a .dmg the user can drag into
# /Applications.
#
# Replaces a .tar.gz, which forced the user through zip -> tar.gz -> folder ->
# .app with no hint that any of it belonged in /Applications.
#
# Usage: make-dmg.sh <app-path> <version> <output.dmg>
#   e.g. make-dmg.sh build/bin/Aseprite.app v1.3.18.1 dist/aseprite.dmg
#
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "usage: make-dmg.sh <app-path> <version> <output.dmg>" >&2
  exit 1
fi

APP="$1"
VERSION="$2"
OUT="$3"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$APP" ]; then
  echo "error: app bundle not found: $APP" >&2
  exit 1
fi

# The icon is make-icns.sh's job. Packaging without it would hand the user a
# DMG whose app and volume are both iconless -- silently, which is exactly the
# failure this change exists to remove.
ICNS="$APP/Contents/Resources/Aseprite.icns"
if [ ! -f "$ICNS" ]; then
  echo "error: $ICNS not found" >&2
  echo "       run scripts/make-icns.sh against the bundle before packaging" >&2
  exit 1
fi

VERSION_NUMBER="${VERSION#v}"
VOLNAME="Aseprite $VERSION_NUMBER"

# HFS+ caps volume names at 27 characters. Nothing the version regex allows
# gets near that, but a silently truncated volume name is a baffling thing to
# debug, so check rather than hope.
if [ "${#VOLNAME}" -gt 27 ]; then
  echo "error: volume name '$VOLNAME' exceeds the 27-character HFS+ limit" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
MOUNT="$(mktemp -d)"
# Detach unconditionally: this runs on the success path and on every failure
# path, and a still-mounted image would wedge the next build on the same
# runner. Errors are swallowed so a failed detach cannot mask the real error.
cleanup() {
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  rm -rf "$STAGE" "$MOUNT"
}
trap cleanup EXIT


# --- the note that unblocks the user ---------------------------------------
#
# A DMG fixes how the app is installed, not the fact that macOS refuses to run
# it. The binary is ad-hoc signed and not notarized, and Sequoia removed the
# Control-click -> Open shortcut, so without this note a user who successfully
# drags the app into /Applications is still stuck.

README="$STAGE/READ ME FIRST.txt"
cat > "$README" <<EOF
Aseprite $VERSION_NUMBER — how to install


STEP 1 — Copy the app

    Drag the Aseprite icon on the left onto the Applications folder on the
    right. That copies Aseprite onto your Mac.


STEP 2 — Allow it to run

    Open the Terminal app. (Press Command+Space, type "Terminal", press
    Return.) Copy the line below, paste it into the Terminal window, and
    press Return:

        xattr -dr com.apple.quarantine /Applications/Aseprite.app

    It prints nothing at all when it works. That is normal.


STEP 3 — Open Aseprite

    Open your Applications folder and double-click Aseprite.

    You only ever do steps 1 and 2 once per build.


WHY IS STEP 2 NEEDED?

    macOS refuses to open apps that have not been "notarized" by Apple.
    Notarizing requires a paid Apple Developer account, which this build
    does not use — so macOS treats Aseprite as untrusted even though you
    compiled it yourself from the official Aseprite source code.

    The command in step 2 clears that flag, for this one app only.

    Prefer not to use the Terminal? Try to open Aseprite and let macOS block
    it. Then open System Settings, go to Privacy & Security, scroll to the
    bottom, and click "Open Anyway".


LICENSE

    You need an Aseprite license to use this build, and you may not
    redistribute it. https://www.aseprite.org/
EOF


# --- dmgbuild ---------------------------------------------------------------
#
# Installed into a throwaway venv rather than the system Python, which is
# marked externally-managed (PEP 668) on the runner. --require-hashes makes
# the pinned hashes in dmg-requirements.txt binding; --only-binary keeps pip
# on wheels, so no package ever gets to run a build script.

VENV="$ROOT/build/.dmg-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
    --require-hashes --only-binary=:all: \
    -r "$ROOT/scripts/dmg-requirements.txt"
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

DMG_APP_PATH="$APP" \
DMG_README_PATH="$README" \
DMG_VOLUME_ICON="$ICNS" \
  "$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" "$VOLNAME" "$OUT"


# --- verify -----------------------------------------------------------------
#
# This script is macOS-only, so tests/ (which runs anywhere) can only cover its
# preconditions. This block is the real test of the packaging, and it runs on
# every build rather than on demand.

hdiutil attach "$OUT" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null

verify_failed() {
  echo "error: DMG verification failed -- $1" >&2
  exit 1
}

[ -d "$MOUNT/Aseprite.app" ] \
  || verify_failed "Aseprite.app is missing from the image"
[ -L "$MOUNT/Applications" ] \
  || verify_failed "the Applications symlink is missing -- users cannot drag-install"
[ "$(readlink "$MOUNT/Applications")" = "/Applications" ] \
  || verify_failed "Applications points at $(readlink "$MOUNT/Applications"), not /Applications"
[ -f "$MOUNT/Aseprite.app/Contents/Resources/Aseprite.icns" ] \
  || verify_failed "the app bundle inside the image has no icon"
[ -f "$MOUNT/READ ME FIRST.txt" ] \
  || verify_failed "READ ME FIRST.txt is missing -- users would hit Gatekeeper with no way out"

echo "DMG: $OUT"
