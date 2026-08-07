#!/usr/bin/env bash
# Tests for scripts/resolve-version.sh
# Run: bash tests/resolve-version.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-version.sh"

pass=0
fail=0

# Creates a fake `curl` in $1 that mimics the GitHub API.
#   $2 = tag_name returned by /releases/latest ("" makes the call fail)
#   $3 = space-separated list of tags that exist in /git/ref/tags/
make_stub_curl() {
  mkdir -p "$1"
  cat > "$1/curl" <<STUB
#!/usr/bin/env bash
url="\${!#}"
case "\$url" in
  */releases/latest)
    if [ -z "$2" ]; then exit 22; fi
    printf '{"tag_name": "%s", "prerelease": false}\n' "$2"
    ;;
  */git/ref/tags/*)
    tag="\${url##*/}"
    for t in $3; do
      if [ "\$t" = "\$tag" ]; then
        printf '{"ref": "refs/tags/%s"}\n' "\$tag"
        exit 0
      fi
    done
    exit 22
    ;;
  *)
    exit 22
    ;;
esac
STUB
  chmod +x "$1/curl"
}

# run_case <name> <expected_status> <expected_stdout> <latest> <existing_tags> [args...]
run_case() {
  local name="$1" want_status="$2" want_out="$3" latest="$4" existing="$5"
  shift 5

  local tmp
  tmp="$(mktemp -d)"
  make_stub_curl "$tmp/bin" "$latest" "$existing"

  local out status
  out="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" 2>/dev/null)"
  status=$?
  rm -rf "$tmp"

  if [ "$status" = "$want_status" ] && [ "$out" = "$want_out" ]; then
    pass=$((pass + 1))
    printf 'ok   - %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n       want status=%s stdout=%q\n       got  status=%s stdout=%q\n' \
      "$name" "$want_status" "$want_out" "$status" "$out"
  fi
}

ALL_TAGS="v1.3.18.1 v1.3.18 v1.3.18-beta1 v1.2.40"

run_case "sem argumento resolve o ultimo release" \
  0 "v1.3.18.1" "v1.3.18.1" "$ALL_TAGS"

run_case "versao explicita e respeitada" \
  0 "v1.3.18" "v1.3.18.1" "$ALL_TAGS" "v1.3.18"

run_case "versao sem prefixo v e normalizada" \
  0 "v1.2.40" "v1.3.18.1" "$ALL_TAGS" "1.2.40"

run_case "prerelease explicito e aceito" \
  0 "v1.3.18-beta1" "v1.3.18.1" "$ALL_TAGS" "v1.3.18-beta1"

run_case "tag inexistente e rejeitada" \
  1 "" "v1.3.18.1" "$ALL_TAGS" "v9.9.9"

run_case "injecao de comando e rejeitada" \
  1 "" "v1.3.18.1" "$ALL_TAGS" 'v1.3.18; rm -rf /'

run_case "argumento nao-versao e rejeitado" \
  1 "" "v1.3.18.1" "$ALL_TAGS" "main"

run_case "falha da api sem argumento e reportada" \
  1 "" "" "$ALL_TAGS"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
