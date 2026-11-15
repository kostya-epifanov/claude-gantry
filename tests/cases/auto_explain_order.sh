#!/usr/bin/env bash
#
# `gantry:auto --explain` prints an explainer before anything else happens. The step is prose and
# nothing executes a SKILL.md, so what can be checked is placement: the --explain step must sit
# ahead of Stage 1 (which creates the worktree and which --here skips), and the flag must be
# documented where both drivers' flags are. Placement, not wording.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

SKILL="$GANTRY_ROOT/skills/auto/SKILL.md"
UNATTENDED="$GANTRY_ROOT/skills/auto-unattended/SKILL.md"

assert_path_present "$SKILL" "the auto skill exists"

explain_line="$(grep -n -e 'open with a plain-language explainer' "$SKILL" | head -1 | cut -d: -f1)"
stage1_line="$(grep -n '^## Stage 1 ' "$SKILL" | head -1 | cut -d: -f1)"

if [ -n "$explain_line" ] && [ -n "$stage1_line" ] && [ "$explain_line" -lt "$stage1_line" ]; then
  printf '  ok    the --explain step precedes Stage 1 (worktree creation)\n'
else
  printf '  FAIL  the --explain step precedes Stage 1 (explain=%s stage1=%s)\n' "$explain_line" "$stage1_line"
  FAILURES=$((FAILURES + 1))
fi

assert_file_contains "$SKILL" 'also under' "the explainer is stated to run under --here"
assert_file_contains "$SKILL" 'argument-hint:.*--explain' "argument-hint carries --explain"
assert_file_contains "$GANTRY_ROOT/docs/SKILLS.md" '`--explain`' "docs/SKILLS.md documents the flag"
assert_file_lacks "$UNATTENDED" '[-][-]explain' "auto-unattended is untouched by the flag"

finish
