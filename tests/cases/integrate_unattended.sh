#!/usr/bin/env bash
#
# /gantry:integrate --unattended (BASE-429) is a markdown skill, so what can be proven without a
# paid run is structural: the flag is documented, every place the supervised skill asks a person
# has a named rule for the unattended mode, the unattended publish is a draft and never "ready",
# and the supervised publish command is untouched.
#
# The expensive failure is a missed ask: an unattended run that reaches an AskUserQuestion nobody
# answers hangs the routine. So the key check counts every ask in the skill and its references and
# requires each one to name the unattended rule that replaces it.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

SKILL="$GANTRY_ROOT/skills/integrate/SKILL.md"
LOOP="$GANTRY_ROOT/skills/integrate/references/merge-loop.md"
BODY="$GANTRY_ROOT/skills/integrate/references/pr-body.md"
DOCS="$GANTRY_ROOT/docs/SKILLS.md"

assert_path_present "$SKILL" "the skill body exists"

# --- the flag is documented where a caller looks ---------------------------------------------
assert_file_contains "$SKILL" '^argument-hint:.*--unattended' "argument-hint offers --unattended"
assert_file_contains "$SKILL" '^## Unattended mode' "the skill has an Unattended mode section"
assert_file_contains "$DOCS" '[-][-]unattended' "docs/SKILLS.md documents --unattended"
assert_file_lacks "$DOCS" 'There is no `--unattended` flag' "the old 'no flag' claim is gone from docs/SKILLS.md"
assert_file_lacks "$SKILL" 'There is no `--unattended` flag' "the old 'no flag' claim is gone from the skill"

# --- the section: carve it out by heading, so every scan below names what it scanned ---------
section="$CASE_TMP/section.md"
awk '/^## Unattended mode/ { on = 1; print; next } on && /^## / { exit } on { print }' "$SKILL" >"$section"
if [ -s "$section" ]; then _pass "carved out the Unattended mode section"; else _fail "Unattended mode section is empty"; fi

# One table row per ask. These are the rule names the stages cite.
for rule in lane queue parent base-moved no-gates conflict published-reset finish-merge rewritten lens-error pr; do
  assert_file_contains "$section" "^\| \`$rule\` \|" "rule table has a row for \`$rule\`"
done

# --- no ask is left without a rule ------------------------------------------------------------
# scan_asks <file> — every line naming AskUserQuestion that does not also say how --unattended
# answers it. The frontmatter tool list and the Unattended section itself are not asks.
scan_asks() {
  awk '
    /^allowed-tools:/ { next }
    /^## Unattended mode/ { skip = 1; next }
    skip && /^## / { skip = 0 }
    skip { next }
    /AskUserQuestion/ && $0 !~ /--unattended/ { printf "%d: %s\n", NR, $0 }
  ' "$1"
}

ask_count=0
for f in "$SKILL" "$LOOP"; do
  n="$(grep -c 'AskUserQuestion' "$f")"
  ask_count=$((ask_count + n))
  found="$(scan_asks "$f")"
  if [ -z "$found" ]; then
    _pass "every AskUserQuestion in $(basename "$f") names its --unattended rule"
  else
    _fail "an ask in $(basename "$f") has no --unattended rule"
    printf '%s\n' "$found"
  fi
done
# 5 in SKILL.md (frontmatter, lane, queue, no-gates, pr) + 2 in merge-loop.md. Fewer means the
# scanner is reading nothing; more means a new ask arrived and must get a rule first.
if [ "$ask_count" -ge 7 ]; then
  _pass "the ask scan covered $ask_count mentions"
else
  _fail "expected at least 7 AskUserQuestion mentions to scan, found $ask_count"
fi

# The control: the scanner must be able to fail.
probe="$CASE_TMP/probe.md"
printf '**AskUserQuestion**: a new ask with no rule\n' >"$probe"
found="$(scan_asks "$probe")"
assert_contains "$found" "new ask" "an ask with no --unattended rule is caught"
printf '**AskUserQuestion** (under `--unattended`, rule `x`): covered\n' >"$probe"
found="$(scan_asks "$probe")"
if [ -z "$found" ]; then _pass "an ask that names its rule passes"; else _fail "false positive: $found"; fi

# merge-loop.md carries three asks' rules.
for rule in finish-merge conflict published-reset rewritten; do
  assert_file_contains "$LOOP" "rule \`$rule\`" "merge-loop.md names rule \`$rule\`"
done

# --- publishing: draft only in the unattended command, never ready ----------------------------
# Only fenced lines are commands; the prose says "never gh pr ready" and has to be able to.
fenced="$CASE_TMP/fenced.txt"
awk '/^[[:space:]]*(```|~~~)/ { infence = !infence; next } infence { print }' "$SKILL" "$LOOP" >"$fenced"

creates="$(grep -c '^gh pr create ' "$fenced")"
drafts="$(grep -c '^gh pr create --draft ' "$fenced")"
if [ "$creates" -eq 2 ] && [ "$drafts" -eq 1 ]; then
  _pass "two gh pr create commands: one plain (supervised), one --draft (unattended)"
else
  _fail "expected exactly one plain and one --draft gh pr create, found $creates total and $drafts draft"
fi
assert_file_lacks "$fenced" 'gh pr ready' "no fenced command marks a PR ready"
assert_file_lacks "$fenced" 'gh pr merge' "no fenced command merges a PR"
assert_file_contains "$SKILL" '[-][-]draft' "the skill mentions --draft"

# The supervised command must be byte-for-byte what it was: no --draft sneaked into it.
plain="$(grep '^gh pr create --base' "$fenced")"
assert_not_contains "$plain" "--draft" "the supervised gh pr create is untouched"

# --- the PR body and the caller's signal ------------------------------------------------------
assert_file_contains "$BODY" 'Under `--unattended`' "pr-body.md says what an unattended body carries"
assert_file_contains "$BODY" 'not unverified' "pr-body.md keeps the draft-means-unwatched line"
assert_file_contains "$section" 'UNATTENDED: stopped' "the stop signal for a caller is defined"
assert_file_contains "$section" 'UNATTENDED: published draft' "the publish signal for a caller is defined"

finish
