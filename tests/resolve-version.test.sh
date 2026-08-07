#!/usr/bin/env bash
# Tests for scripts/resolve-version.sh
# Run: bash tests/resolve-version.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-version.sh"

pass=0
fail=0

# Creates a fake `curl` in $1 that mimics the GitHub API.
#   $2 = tag_name returned by /releases/latest ("" makes the call fail,
#        "__MALFORMED__" returns a 200 body with no tag_name field at all)
#   $3 = space-separated list of tags that exist in /git/ref/tags/
make_stub_curl() {
  mkdir -p "$1"
  local latest_body
  if [ "$2" = "__MALFORMED__" ]; then
    latest_body='{"name": "no tag_name field here"}'
  else
    latest_body="{\"tag_name\": \"$2\", \"prerelease\": false}"
  fi
  cat > "$1/curl" <<STUB
#!/usr/bin/env bash
url="\${!#}"
case "\$url" in
  */releases/latest)
    if [ -z "$2" ]; then exit 22; fi
    printf '%s\n' '$latest_body'
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

# Creates a fake `curl` in $1 where any call to */git/ref/tags/* succeeds
# unconditionally, regardless of what tag is in the URL. Used to isolate the
# version-format validation step from tag-existence checking: with this
# stub, the only thing that can stop a malicious value from reaching stdout
# is the regex validation itself, not an incidental rejection downstream.
make_stub_curl_permissive_tags() {
  mkdir -p "$1"
  cat > "$1/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  */git/ref/tags/*)
    tag="${url##*/}"
    printf '{"ref": "refs/tags/%s"}\n' "$tag"
    ;;
  *)
    exit 22
    ;;
esac
STUB
  chmod +x "$1/curl"
}

# Creates a fake `curl` in $1 that requires an "Authorization: Bearer <token>"
# header on every call, failing the call otherwise. Exists to prove the
# GITHUB_TOKEN branch of api() -- the *only* branch a real CI run ever
# exercises -- actually attaches the header, rather than merely taking a
# different code path. Without this, a typo dropping the header would pass
# every other test and only fail on a real runner.
make_stub_curl_requires_auth() {
  mkdir -p "$1"
  local token="$2" latest="$3" existing="$4"
  cat > "$1/curl" <<STUB
#!/usr/bin/env bash
has_auth=0
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-H" ] && [ "\$arg" = "Authorization: Bearer $token" ]; then
    has_auth=1
  fi
  prev="\$arg"
done
if [ "\$has_auth" != "1" ]; then
  echo "stub: missing Authorization header" >&2
  exit 22
fi
url="\${!#}"
case "\$url" in
  */releases/latest)
    printf '{"tag_name": "%s", "prerelease": false}\n' "$latest"
    ;;
  */git/ref/tags/*)
    tag="\${url##*/}"
    for t in $existing; do
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
# Captures stderr into the global $last_stderr so callers that need to make
# additional assertions about it (see run_case_stderr below) can, without
# every existing call site having to care.
run_case() {
  local name="$1" want_status="$2" want_out="$3" latest="$4" existing="$5"
  shift 5

  local tmp
  tmp="$(mktemp -d)"
  make_stub_curl "$tmp/bin" "$latest" "$existing"

  local out status
  # GITHUB_TOKEN and ASEPRITE_REPO are explicitly cleared (not just left
  # alone) so a developer with GITHUB_TOKEN exported in their shell -- very
  # common -- doesn't silently exercise the authenticated branch of api()
  # here instead of the one these default cases are meant to cover.
  out="$(unset GITHUB_TOKEN ASEPRITE_REPO; PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" 2>"$tmp/stderr")"
  status=$?
  last_stderr="$(cat "$tmp/stderr")"
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

# run_case_stderr <name> <expected_status> <expected_stdout> <want_stderr:yes|no> <latest> <existing_tags> [args...]
# Like run_case, but also asserts whether stderr is empty ("no") or
# non-empty ("yes"). Exists because a status code alone can't prove an error
# message was actually written -- a script that dies silently and one that
# reports its failure can produce the identical exit code.
run_case_stderr() {
  local name="$1" want_status="$2" want_out="$3" want_stderr="$4" latest="$5" existing="$6"
  shift 6

  run_case "$name" "$want_status" "$want_out" "$latest" "$existing" "$@"
  # run_case already recorded pass/fail for status+stdout and printed its
  # line; this adds a second, independent assertion on top for stderr.
  local stderr_ok=1
  if [ "$want_stderr" = "yes" ] && [ -z "$last_stderr" ]; then stderr_ok=0; fi
  if [ "$want_stderr" = "no" ] && [ -n "$last_stderr" ]; then stderr_ok=0; fi

  if [ "$stderr_ok" = "1" ]; then
    pass=$((pass + 1))
    printf 'ok   - %s (stderr)\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s (stderr)\n       want stderr=%s\n       got  stderr=%q\n' \
      "$name" "$want_stderr" "$last_stderr"
  fi
}

ALL_TAGS="v1.3.18.1 v1.3.18 v1.3.18-beta1 v1.2.40"

run_case "sem argumento resolve o ultimo release" \
  0 "v1.3.18.1" "v1.3.18.1" "$ALL_TAGS"

# The composite action always passes one argument to this script, and it can
# be an empty string (`"${REQUESTED_VERSION}"` when the workflow_dispatch
# input is left blank) -- distinct from the zero-argument case above, and
# the product's real happy path.
run_case "argumento vazio explicito resolve o ultimo release" \
  0 "v1.3.18.1" "v1.3.18.1" "$ALL_TAGS" ""

run_case "versao explicita e respeitada" \
  0 "v1.3.18" "v1.3.18.1" "$ALL_TAGS" "v1.3.18"

# workflow_dispatch's text input does not trim, so a user typing a leading
# space must still resolve correctly instead of failing with a message that
# reads like a bug in this script.
run_case "espaco em branco no argumento e removido" \
  0 "v1.3.18" "v1.3.18.1" "$ALL_TAGS" " v1.3.18"

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

run_case_stderr "api sem tag_name reporta erro em stderr" \
  1 "" "yes" "__MALFORMED__" "$ALL_TAGS"

# Custom case (not run_case): the malicious value needs an embedded literal
# newline, and the tag-existence stub must accept anything so that only the
# format-validation regex stands between the value and stdout -- proving
# Finding 2 (line-by-line `grep` vs. whole-string `[[ =~ ]]`) rather than
# relying on some incidental downstream rejection.
name="versao multi-linha e rejeitada mesmo com tag valida na primeira linha"
tmp="$(mktemp -d)"
make_stub_curl_permissive_tags "$tmp/bin"
malicious="$(printf 'v1.3.18.1\nmalicious-payload-line')"
out="$(unset GITHUB_TOKEN ASEPRITE_REPO; PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$malicious" 2>/dev/null)"
status=$?
rm -rf "$tmp"
if [ "$status" = "1" ] && [ "$out" = "" ]; then
  pass=$((pass + 1))
  printf 'ok   - %s\n' "$name"
else
  fail=$((fail + 1))
  printf 'FAIL - %s\n       want status=1 stdout=""\n       got  status=%s stdout=%q\n' \
    "$name" "$status" "$out"
fi

# Custom case (not run_case): GITHUB_TOKEN is set on purpose here -- this is
# the branch of api() that every real CI run actually takes, and until now
# nothing covered it. A stub that requires the Authorization header to be
# present proves the header is really sent, not just that GITHUB_TOKEN was
# read.
name="GITHUB_TOKEN definido envia o header Authorization"
tmp="$(mktemp -d)"
make_stub_curl_requires_auth "$tmp/bin" "test-token-123" "v1.3.18.1" "$ALL_TAGS"
out="$(PATH="$tmp/bin:$PATH" GITHUB_TOKEN="test-token-123" bash "$SCRIPT" 2>"$tmp/stderr")"
status=$?
stderr_content="$(cat "$tmp/stderr")"
rm -rf "$tmp"
if [ "$status" = "0" ] && [ "$out" = "v1.3.18.1" ]; then
  pass=$((pass + 1))
  printf 'ok   - %s\n' "$name"
else
  fail=$((fail + 1))
  printf 'FAIL - %s\n       want status=0 stdout="v1.3.18.1"\n       got  status=%s stdout=%q stderr=%q\n' \
    "$name" "$status" "$out" "$stderr_content"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
