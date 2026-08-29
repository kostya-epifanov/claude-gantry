#!/usr/bin/env bash
#
# tests/run.sh — runs every case in cases/, one section each, and exits
# non-zero if any assertion failed.
#
# The suite exists because gantry's whole claim is that a guarantee belongs in
# a script's exit code rather than in prose (docs/METHOD.md). Two scripts carry
# that guarantee — lib/run_gates.sh and hooks/readiness-gate.sh — and prose is
# the only thing that had ever checked them.
#
# Each case is a standalone script: `bash tests/cases/<name>.sh` runs it alone.
# scripts/verify.sh runs this file, so a green local verify still means a green
# CI run.
#
# Usage: bash tests/run.sh [name-substring ...]

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
export TESTS_DIR

total=0
failed=0
failed_names=""

selects_case() {  # selects_case <name> — no filters means run everything
  [ "$#" -eq 1 ] && return 0
  local name="$1"; shift
  local f
  for f in "$@"; do
    case "$name" in *"$f"*) return 0 ;; esac
  done
  return 1
}

for case_file in "$TESTS_DIR"/cases/*.sh; do
  [ -f "$case_file" ] || continue
  name="$(basename "$case_file" .sh)"
  selects_case "$name" "$@" || continue

  total=$((total + 1))
  printf '\n== %s ==\n' "$name"
  if bash "$case_file"; then
    :
  else
    failed=$((failed + 1))
    failed_names="$failed_names $name"
  fi
done

printf '\n%s\n' "-----------------------------------------"
if [ "$total" -eq 0 ]; then
  echo "tests: no cases matched"
  exit 1
fi
if [ "$failed" -eq 0 ]; then
  printf 'tests: PASS (%s cases)\n' "$total"
  exit 0
fi
printf 'tests: FAIL (%s of %s cases)\n' "$failed" "$total"
printf '  failed:%s\n' "$failed_names"
exit 1
