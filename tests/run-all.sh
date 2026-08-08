#!/usr/bin/env bash
# Runs every test suite in this directory.
# Run: bash tests/run-all.sh
set -uo pipefail

cd "$(dirname "$0")"

failed=0
for suite in *.test.sh; do
  printf '== %s\n' "$suite"
  bash "$suite" || failed=$((failed + 1))
  printf '\n'
done

if [ "$failed" -ne 0 ]; then
  printf '%d suite(s) failed\n' "$failed" >&2
  exit 1
fi

printf 'all suites passed\n'
