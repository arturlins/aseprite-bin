#!/usr/bin/env bash
#
# Aseprite build script for Linux x64 and macOS arm64.
#
# ASEPRITE_VERSION must be set (e.g. v1.3.18.1). Run
# "bash scripts/resolve-version.sh" to resolve the latest release.
#
# Produces a .tar.gz inside dist/ — a tarball rather than a plain directory
# because actions/upload-artifact drops the executable bit and symlinks.
#
set -euo pipefail

if [ -z "${ASEPRITE_VERSION:-}" ]; then
  echo "error: ASEPRITE_VERSION is not set (e.g. export ASEPRITE_VERSION=v1.3.18.1)" >&2
  echo "       run \"bash scripts/resolve-version.sh\" to resolve the latest release" >&2
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
if [ ! -d "$SKIA_DIR" ]; then
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
fi

SKIA_LIBRARY_DIR="$SKIA_DIR/out/$SKIA_OUT"
if [ ! -f "$SKIA_LIBRARY_DIR/libskia.a" ]; then
  echo "error: libskia.a not found in $SKIA_LIBRARY_DIR" >&2
  exit 1
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


# --- package ---------------------------------------------------------------

rm -rf dist
mkdir -p dist

TARBALL="dist/aseprite-$VERSION-$OS-$ARCH.tar.gz"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ "$OS" = linux ]; then
  STAGE_DIR="$STAGE/aseprite-$VERSION-$OS-$ARCH"
  mkdir -p "$STAGE_DIR"
  cp build/bin/aseprite "$STAGE_DIR/"
  chmod +x "$STAGE_DIR/aseprite"
  cp -R build/bin/data "$STAGE_DIR/data"
  cp -R aseprite/docs "$STAGE_DIR/docs"
  echo '# This file is here so Aseprite behaves as a portable program' > "$STAGE_DIR/aseprite.ini"
else
  STAGE_DIR="$STAGE/aseprite-$VERSION-$OS-$ARCH"
  mkdir -p "$STAGE_DIR"
  # ditto preserves the bundle structure, symlinks and permissions.
  ditto build/bin/Aseprite.app "$STAGE_DIR/Aseprite.app"
  cp -R aseprite/docs "$STAGE_DIR/docs"
fi

tar -czf "$TARBALL" -C "$STAGE" "aseprite-$VERSION-$OS-$ARCH"

echo "Done: $TARBALL"
