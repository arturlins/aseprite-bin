#!/usr/bin/env bash
#
# Resolves which Aseprite tag to build.
#
# Usage: resolve-version.sh [requested-version]
#
#   With no argument, resolves the latest published release (the GitHub API
#   already excludes drafts and prereleases). With an argument, normalizes and
#   validates it, then confirms the tag really exists upstream.
#
# Prints the resolved tag (e.g. "v1.3.18.1") to stdout.
#
# Environment:
#   ASEPRITE_REPO  upstream repo, default "aseprite/aseprite"
#   GITHUB_TOKEN   optional, only used to authenticate API calls
#
set -euo pipefail

REPO="${ASEPRITE_REPO:-aseprite/aseprite}"
API="https://api.github.com/repos/$REPO"
VERSION_RE='^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$'

api() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sfL -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
  else
    curl -sfL -H "Accept: application/vnd.github+json" "$1"
  fi
}

version="${1:-}"

if [ -z "$version" ]; then
  if ! json="$(api "$API/releases/latest")"; then
    echo "error: could not query the latest release of $REPO" >&2
    exit 1
  fi
  # `|| true` prevents `pipefail` + `set -e` from killing the script right
  # here if `grep` finds no match (e.g. a 200 response with an unexpected
  # body shape) -- the emptiness check right below must stay reachable so
  # the error is reported on stderr instead of the script dying silently.
  version="$(printf '%s' "$json" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
    || true)"
  if [ -z "$version" ]; then
    echo "error: no tag_name in the latest release of $REPO" >&2
    exit 1
  fi
fi

case "$version" in
  v*) ;;
  *) version="v$version" ;;
esac

# Validate BEFORE the tag is ever interpolated into a URL or a git command.
# `[[ =~ ]]` matches the whole string ($VERSION_RE left unquoted so it is
# treated as a regex, not a literal) -- unlike `grep`, which matches
# line-by-line, so a multi-line value can't sneak a valid-looking first line
# past this check and reach the URL interpolation below.
if ! [[ "$version" =~ $VERSION_RE ]]; then
  echo "error: invalid version '$version' (expected e.g. v1.3.18.1 or v1.3.18-beta1)" >&2
  exit 1
fi

if ! api "$API/git/ref/tags/$version" >/dev/null; then
  echo "error: tag '$version' does not exist in $REPO" >&2
  exit 1
fi

printf '%s\n' "$version"
