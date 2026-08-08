#!/usr/bin/env bash
#
# Builds Aseprite.icns from the PNG icons the Aseprite source tree ships.
#
# Upstream declares CFBundleIconFile = Aseprite.icns in src/main/osx/Info.plist
# but does not version the .icns itself, and its CMake does not generate one --
# so a bundle built straight from source has no icon at all. The PNGs under
# data/icons/ *are* versioned, and iconutil (part of macOS) turns them into the
# missing file.
#
# Usage: make-icns.sh <aseprite-src-dir> <output.icns>
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: make-icns.sh <aseprite-src-dir> <output.icns>" >&2
  exit 1
fi

SRC="$1"
OUT="$2"

# <canonical iconset name>:<path relative to the Aseprite source tree>.
# The @2x entries are the same artwork at double resolution, which is why
# several sources appear twice. There is no icon_512x512@2x.png (1024px)
# because upstream ships no artwork that large; iconutil accepts a partial
# iconset, and 512 already covers the Dock and Finder at normal sizes.
MAPPING="
icon_16x16.png:data/icons/ase16.png
icon_16x16@2x.png:data/icons/ase32.png
icon_32x32.png:data/icons/ase32.png
icon_32x32@2x.png:data/icons/ase64.png
icon_128x128.png:data/icons/ase128.png
icon_128x128@2x.png:data/icons/ase256.png
icon_256x256.png:data/icons/ase256.png
icon_256x256@2x.png:data/icons/hd/asehd.png
icon_512x512.png:data/icons/hd/asehd.png
"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Aseprite.iconset"
mkdir -p "$ICONSET"

for entry in $MAPPING; do
  name="${entry%%:*}"
  src="${entry#*:}"
  if [ ! -f "$SRC/$src" ]; then
    echo "error: $SRC/$src not found" >&2
    echo "       upstream may have moved or renamed its icon PNGs -- the app" >&2
    echo "       would ship with no icon at all, so this is a hard failure" >&2
    exit 1
  fi
  cp "$SRC/$src" "$ICONSET/$name"
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"

# iconutil has been known to report success while writing nothing when handed
# an iconset it dislikes. The whole point of this script is that the icon is
# actually there, so confirm it rather than trust the exit code.
if [ ! -f "$OUT" ]; then
  echo "error: iconutil reported success but did not produce $OUT" >&2
  exit 1
fi

echo "Icon: $OUT"
