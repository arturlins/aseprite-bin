#!/usr/bin/env bash
#
# Aseprite build script for Linux x64 and macOS arm64.
#
# ASEPRITE_VERSION must be set (e.g. v1.3.18.1). Run
# "bash scripts/resolve-version.sh" to resolve the latest release.
#
# Produces, inside dist/: a .tar.gz on Linux (a tarball rather than a plain
# directory because actions/upload-artifact drops the executable bit and
# symlinks) and a .dmg on macOS.
#
set -euo pipefail

if [ -z "${ASEPRITE_VERSION:-}" ]; then
  echo "error: ASEPRITE_VERSION is not set (e.g. export ASEPRITE_VERSION=v1.3.18.1)" >&2
  echo "       run \"bash scripts/resolve-version.sh\" to resolve the latest release" >&2
  exit 1
fi

# Re-validate here too: the composite action enforces this format, but this
# script is also documented for direct/local use with a hand-set env var,
# which bypasses the resolver entirely. VERSION_NUMBER below is interpolated
# into a perl s/// replacement (perl-interpolated) and into the Skia/tarball
# URLs and paths, so a bad value must be rejected before any of that happens.
# `[[ =~ ]]` matches the whole string ($VERSION_RE left unquoted so it is
# treated as a regex, not a literal) -- unlike `grep`, which matches
# line-by-line and would let a multi-line value slip a valid-looking first
# line past this check.
VERSION_RE='^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$'
if ! [[ "$ASEPRITE_VERSION" =~ $VERSION_RE ]]; then
  echo "error: invalid ASEPRITE_VERSION '$ASEPRITE_VERSION' (expected e.g. v1.3.18.1 or v1.3.18-beta1)" >&2
  exit 1
fi

VERSION="$ASEPRITE_VERSION"
VERSION_NUMBER="${VERSION#v}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

case "$(uname -s)" in
  Linux)
    OS=linux
    ARCH=x64
    SKIA_OUT=Release-x64
    SKIA_ASSETS="Skia-Linux-Release-x64.zip Skia-Linux-Release-x64-libstdc++.zip"
    ;;
  Darwin)
    OS=macos
    ARCH=arm64
    SKIA_OUT=Release-arm64
    SKIA_ASSETS="Skia-macOS-Release-arm64.zip"
    ;;
  *)
    echo "error: unsupported platform $(uname -s)" >&2
    exit 1
    ;;
esac

echo "Building Aseprite $VERSION for $OS-$ARCH"


# --- toolchain -------------------------------------------------------------

command -v cmake >/dev/null || { echo "error: cmake not found" >&2; exit 1; }
command -v git   >/dev/null || { echo "error: git not found" >&2; exit 1; }
command -v unzip >/dev/null || { echo "error: unzip not found" >&2; exit 1; }
command -v perl  >/dev/null || { echo "error: perl not found" >&2; exit 1; }

if ! command -v ninja >/dev/null; then
  echo "error: ninja not found (apt: ninja-build, brew: ninja)" >&2
  exit 1
fi


# --- shallow clone of the requested tag ------------------------------------

rm -rf aseprite
git clone --quiet --depth 1 --branch "$VERSION" \
  --recurse-submodules --shallow-submodules \
  https://github.com/aseprite/aseprite.git aseprite

# Stamp the real version instead of "1.x-dev". perl is used because GNU sed
# and BSD sed disagree on the syntax of -i.
perl -pi -e "s/\Q1.x-dev\E/$VERSION_NUMBER/g" aseprite/src/ver/CMakeLists.txt

# If upstream ever renames the "1.x-dev" placeholder, the substitution above
# becomes a silent no-op and the build would ship a binary reporting the
# wrong version -- assert it actually applied instead of finding out later.
grep -qF "$VERSION_NUMBER" aseprite/src/ver/CMakeLists.txt || {
  echo "error: version stamp failed -- '$VERSION_NUMBER' not found in aseprite/src/ver/CMakeLists.txt" >&2
  echo "       upstream may have renamed the '1.x-dev' placeholder" >&2
  exit 1
}


# --- skia ------------------------------------------------------------------

if [ -f aseprite/laf/misc/skia-tag.txt ]; then
  SKIA_VERSION="$(tr -d '[:space:]' < aseprite/laf/misc/skia-tag.txt)"
elif [ "${VERSION#*beta}" != "$VERSION" ]; then
  SKIA_VERSION=m124-08a5439a6b
else
  SKIA_VERSION=m102-861e4743af
fi

echo "Using Skia $SKIA_VERSION"

SKIA_DIR="$ROOT/skia-$SKIA_VERSION"
SKIA_LIBRARY_DIR="$SKIA_DIR/out/$SKIA_OUT"

# Gate reuse on the library file, not just the directory: an interrupted
# local download or extraction leaves the directory present but incomplete,
# which would otherwise make every later run skip the download forever.
if [ ! -f "$SKIA_LIBRARY_DIR/libskia.a" ]; then
  mkdir -p "$SKIA_DIR"
  downloaded=""
  for asset in $SKIA_ASSETS; do
    url="https://github.com/aseprite/skia/releases/download/$SKIA_VERSION/$asset"
    echo "Trying $asset"
    if curl -sfL -o "$SKIA_DIR/skia.zip" "$url"; then
      downloaded="$asset"
      break
    fi
  done
  if [ -z "$downloaded" ]; then
    rm -rf "$SKIA_DIR"
    echo "error: no Skia asset found for $SKIA_VERSION on $OS-$ARCH" >&2
    exit 1
  fi
  unzip -q "$SKIA_DIR/skia.zip" -d "$SKIA_DIR"
  rm -f "$SKIA_DIR/skia.zip"

  if [ ! -f "$SKIA_LIBRARY_DIR/libskia.a" ]; then
    echo "error: libskia.a not found in $SKIA_LIBRARY_DIR after download" >&2
    echo "       delete $SKIA_DIR and re-run to force a fresh download" >&2
    exit 1
  fi
fi


# --- configure & build -----------------------------------------------------

rm -rf build

common_args=(
  -G Ninja
  -S aseprite
  -B build
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DENABLE_CCACHE=OFF
  -DLAF_BACKEND=skia
  "-DSKIA_DIR=$SKIA_DIR"
  "-DSKIA_LIBRARY_DIR=$SKIA_LIBRARY_DIR"
  "-DSKIA_LIBRARY=$SKIA_LIBRARY_DIR/libskia.a"
)

if [ "$OS" = linux ]; then
  # The prebuilt Skia is linked against libstdc++, so Aseprite must be too.
  export CC=clang
  export CXX=clang++
  cmake "${common_args[@]}" \
    -DCMAKE_CXX_FLAGS:STRING=-stdlib=libstdc++ \
    -DCMAKE_EXE_LINKER_FLAGS:STRING=-stdlib=libstdc++
else
  # Hoisted into its own assignment (rather than inline in the cmake
  # invocation below) so that a failing "xcrun" is caught by "set -e": a
  # failing command substitution only aborts the script when it is the
  # whole content of a simple command/assignment, not when it sits inside
  # an argument to another command.
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
  cmake "${common_args[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    "-DCMAKE_OSX_SYSROOT=$SDK_PATH" \
    -DPNG_ARM_NEON:STRING=on
fi

ninja -C build aseprite


# --- app icon (macOS) ------------------------------------------------------
#
# Upstream's Info.plist declares CFBundleIconFile = Aseprite.icns but the
# Aseprite repository does not version that file, so a bundle built from
# source has no icon. Belongs here rather than in packaging: the icon is part
# of the app, not of how the app is shipped.

if [ "$OS" = macos ]; then
  ICNS="build/bin/Aseprite.app/Contents/Resources/Aseprite.icns"
  if [ -f "$ICNS" ]; then
    echo "Bundle already ships an icon, keeping upstream's"
  else
    ./scripts/make-icns.sh aseprite "$ICNS"
  fi
fi


# --- package ---------------------------------------------------------------

rm -rf dist
mkdir -p dist

if [ "$OS" = linux ]; then
  TARBALL="dist/aseprite-$VERSION-$OS-$ARCH.tar.gz"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT

  STAGE_DIR="$STAGE/aseprite-$VERSION-$OS-$ARCH"
  mkdir -p "$STAGE_DIR"
  cp build/bin/aseprite "$STAGE_DIR/"
  chmod +x "$STAGE_DIR/aseprite"
  cp -R build/bin/data "$STAGE_DIR/data"
  cp -R aseprite/docs "$STAGE_DIR/docs"
  echo '# This file is here so Aseprite behaves as a portable program' > "$STAGE_DIR/aseprite.ini"

  # A tarball rather than a plain directory because actions/upload-artifact
  # drops the executable bit and symlinks.
  tar -czf "$TARBALL" -C "$STAGE" "aseprite-$VERSION-$OS-$ARCH"

  echo "Done: $TARBALL"
else
  # A .dmg rather than a tarball: the artifact already arrives wrapped in a
  # zip, and asking a user to then unpack a tar.gz and move a bundle by hand
  # was the whole problem. Dragging onto the Applications alias is the
  # install step every Mac user already knows.
  #
  # aseprite/docs is dropped on purpose -- it is the manual, which is
  # available online, and it has no place inside an installer volume.
  DMG="dist/aseprite-$VERSION-$OS-$ARCH.dmg"
  ./scripts/make-dmg.sh build/bin/Aseprite.app "$VERSION" "$DMG"

  echo "Done: $DMG"
fi
