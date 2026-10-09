#!/usr/bin/env bash
#
# /gantry:integrate has a docs stage between the merge loop and the review:
# after the last merge it checks the combined tree against the docs the repo
# keeps, puts any fix in one `integrate: docs` commit, gates it, and tells the
# reviewer and the PR body about it. The stage is prose, and nothing in this
# repository executes a SKILL.md — so what CAN be checked is the structure the
# task depends on: that the stage sits where it is meant to, that its commands
# are the commands the design calls for, and that every surface that has to
# mention it does.
#
# WHY COLUMN ZERO. A fenced command is written at the start of its line; a
# prose mention of the same command is backticked, mid-sentence, or indented
# under a list marker. Anchoring each pattern at column zero is how this case
# tells "the stage runs this" from "the stage talks about this" without a
# second fence parser. Column zero alone does not prove a fence is there —
# that proof lives in integrate_flat_commands.sh, which owns the only fence
# parser and checks that every column-zero command in this stage is inside
# one. This case asserts WHICH commands; that one asserts they are fenced and
# flat.
#
# WHY REGIONS. The phrase `no docs change needed` appears in the docs stage
# itself, so a whole-file grep would pass even if the report stage dropped it.
# Every assertion below is made against the region it belongs to, cut by
# heading, not against the file.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

SKILL="$GANTRY_ROOT/skills/integrate/SKILL.md"
PR_BODY="$GANTRY_ROOT/skills/integrate/references/pr-body.md"
MERGE_LOOP="$GANTRY_ROOT/skills/integrate/references/merge-loop.md"
SKILLS_DOC="$GANTRY_ROOT/docs/SKILLS.md"

assert_path_present "$SKILL" "the skill body exists"
assert_path_present "$PR_BODY" "the pr-body reference exists"
assert_path_present "$MERGE_LOOP" "the merge-loop reference exists"

# heading_line <title-prefix> — the line number of `## Stage N — <title-prefix>…`
heading_line() {
  grep -n "^## Stage [0-9]* — $1" "$SKILL" | head -1 | cut -d: -f1
}

# next_heading_after <line> — the next `## Stage` heading after <line>, or EOF
next_heading_after() {
  local n
  n="$(awk -v start="$1" 'NR > start && /^## Stage/ { print NR; exit }' "$SKILL")"
  if [ -z "$n" ]; then n="$(wc -l <"$SKILL" | tr -d ' ')"; fi
  printf '%s' "$n"
}

merge_line="$(heading_line 'The merge loop')"
docs_line="$(heading_line 'Docs')"
review_line="$(heading_line 'Review')"
report_line="$(heading_line 'Report')"

if [ -n "$docs_line" ]; then
  _pass "the docs stage heading exists"
else
  _fail "no '## Stage N — Docs' heading in skills/integrate/SKILL.md"
fi

if [ -n "$merge_line" ] && [ -n "$docs_line" ] && [ "$merge_line" -lt "$docs_line" ]; then
  _pass "the docs stage comes after the merge loop"
else
  _fail "the docs stage must follow the merge loop (merge at ${merge_line:-?}, docs at ${docs_line:-?})"
fi

if [ -n "$docs_line" ] && [ -n "$review_line" ] && [ "$docs_line" -lt "$review_line" ]; then
  _pass "the docs stage comes before the review"
else
  _fail "the docs stage must precede the review (docs at ${docs_line:-?}, review at ${review_line:-?})"
fi

# Stage numbers must be unique and contiguous: a renumber that left two
# stages sharing a number would make every "stage N" reference ambiguous.
numbers="$(grep -o '^## Stage [0-9]*' "$SKILL" | awk '{ print $3 }' | tr '\n' ' ')"
expected="$(seq 0 11 | tr '\n' ' ')"
if [ "$numbers" = "$expected" ]; then
  _pass "stage numbers run 0..11 with no gap or duplicate"
else
  _fail "stage numbers are '$numbers', expected '$expected'"
fi

# --- the docs region --------------------------------------------------------

docs_region="$CASE_TMP/docs-region.md"
if [ -n "$docs_line" ]; then
  docs_end="$(next_heading_after "$docs_line")"
  sed -n "${docs_line},${docs_end}p" "$SKILL" >"$docs_region"
else
  : >"$docs_region"
fi

assert_file_contains "$docs_region" "^git diff --stat origin/<BASE>\\.\\.HEAD -- '\\*\\.md' docs/ README\\.md CHANGELOG\\.md$" \
  "the docs stage collects doc surfaces with git diff --stat against origin/<BASE>"
assert_file_contains "$docs_region" '^gh pr view <n> --json body$' \
  "the docs stage re-reads each PR contract (a resumed run has no session memory)"
assert_file_contains "$docs_region" '^bash "\$GANTRY/lib/ensure_excluded\.sh" \.claude/artifacts/$' \
  "the docs stage excludes .claude/artifacts/ before committing"
assert_file_contains "$docs_region" '^git add -- ' \
  "the docs stage stages doc paths explicitly"
assert_file_lacks "$docs_region" '^git add -A' \
  "the docs stage never stages with git add -A (it would sweep the hook log in)"
assert_file_contains "$docs_region" '^git commit -m "integrate: docs — ' \
  "the docs stage commits with the integrate: docs subject"
assert_file_contains "$docs_region" '^bash "\$GANTRY/lib/run_gates\.sh" --strict$' \
  "the docs stage runs the gate after the commit"
assert_file_contains "$docs_region" '^git commit -m "integrate: fix docs — ' \
  "a red docs gate gets a separate fix commit"
assert_file_contains "$docs_region" 'no docs change needed' \
  "the docs stage names the no-change outcome"
assert_file_contains "$docs_region" 'where the repo has them' \
  "the docs stage checks surfaces only where the repo keeps them"
assert_file_contains "$docs_region" 'Still red → set `status: blocked`' \
  "a docs gate still red after the fix budget sets status: blocked"
assert_file_contains "$docs_region" 'set it back to$' \
  "a re-run re-arms the hook by setting status: implementing"
# Anchored to the rule text itself: 'source PR' alone also matches the stage's
# opening sentence, and a deleted rule bullet would then still pass.
assert_file_contains "$docs_region" 'Every command is flat' \
  "the docs stage restates the rule: flat commands"
assert_file_contains "$docs_region" 'Never touch a source PR' \
  "the docs stage restates the rule: never touch a source PR's branch"
assert_file_contains "$docs_region" 'Never merge the integration PR' \
  "the docs stage restates the rule: never merge the integration PR"

# --- the review and report regions ------------------------------------------

review_region="$CASE_TMP/review-region.md"
if [ -n "$review_line" ]; then
  review_end="$(next_heading_after "$review_line")"
  sed -n "${review_line},${review_end}p" "$SKILL" >"$review_region"
else
  : >"$review_region"
fi
assert_file_contains "$review_region" 'integrate: docs' \
  "the reviewer is given the docs commit"

report_region="$CASE_TMP/report-region.md"
if [ -n "$report_line" ]; then
  report_end="$(wc -l <"$SKILL" | tr -d ' ')"
  sed -n "${report_line},${report_end}p" "$SKILL" >"$report_region"
else
  : >"$report_region"
fi
assert_file_contains "$report_region" 'no docs change needed' \
  "the report stage carries the docs commit or 'no docs change needed'"

# --- the surfaces outside the skill body -------------------------------------

assert_file_contains "$PR_BODY" '^\*\*`## Docs`\*\*' \
  "pr-body.md lists a ## Docs section"
assert_file_contains "$PR_BODY" 'no docs change needed' \
  "pr-body.md says what ## Docs carries when nothing changed"
assert_file_contains "$MERGE_LOOP" '^\| `nothing` \|.*docs stage' \
  "merge-loop.md routes NEXT:nothing through the docs stage"
assert_file_contains "$SKILLS_DOC" 'integrate: docs' \
  "docs/SKILLS.md describes the docs stage"

finish
