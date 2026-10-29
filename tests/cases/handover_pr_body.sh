#!/usr/bin/env bash
#
# The two decisions behind ship's PR-body refresh, each behind an exit code or a
# one-word answer so the acceptance criteria about them are testable rather than
# a model's reading of prose.
#
#   lib/handover_body_state.sh  — is this body carrying the current handover?
#   lib/splice_pr_section.sh    — replace ONE section, change nothing else.
#
# The splice is the one destructive act in the refresh: it rewrites prose a
# human may have edited on GitHub after the pull request opened. So the cases
# that matter most here are the ones about NOT changing things — an ambiguous
# heading changes nothing, a heading inside a fence is not a heading, and every
# byte outside the replaced section survives.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

STATE="$GANTRY_ROOT/lib/handover_body_state.sh"
SPLICE="$GANTRY_ROOT/lib/splice_pr_section.sh"
CHECK_BODY="$GANTRY_ROOT/scripts/check_pr_body.sh"
HEADING='Deliberately not done'

W="$CASE_TMP/bodies"
mkdir -p "$W"

assert_eq() {  # assert_eq <got> <want> <label>
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 — got '$1', want '$2'"; fi
}

state_of() {  # state_of <body> <handover>
  bash "$STATE" "$1" "$2" 2>/dev/null
}

printf -- '- a finding nobody fixed\n' >"$W/handover.md"
MARKER="$(bash "$STATE" --marker "$W/handover.md")"
case "$MARKER" in
  '<!-- gantry:handover sha256='*' -->') _pass "--marker prints an HTML comment carrying the digest" ;;
  *)                                     _fail "unexpected marker: $MARKER" ;;
esac

{
  printf '## %s\n\n' "$HEADING"
  printf '%s\n\n' "$MARKER"
  printf -- '- a finding nobody fixed — out of scope, see task.md\n'
} >"$W/section.md"

# --- the four states ---------------------------------------------------------

{
  printf '# What this change is for\n\nPreamble on one long line.\n\n'
  printf '## %s\n\nOld, pre-marker text.\n\n' "$HEADING"
  printf '## Not proven by this run\n\nThe human-only checks.\n'
} >"$W/stale-body.md"

assert_eq "$(state_of "$W/stale-body.md" "$W/handover.md")" STALE \
  "a body with the heading but no marker is STALE — it is rewritten once, then converges"

printf '# Just a title\n\nNo handover section at all.\n' >"$W/missing-body.md"
assert_eq "$(state_of "$W/missing-body.md" "$W/handover.md")" MISSING \
  "a body with no handover heading is MISSING"

assert_eq "$(state_of "$W/stale-body.md" "$W/no-such-handover.md")" NO-HANDOVER \
  "no handover file at all is NO-HANDOVER — there is nothing to refresh"

bash "$SPLICE" "$W/stale-body.md" "$W/section.md" "$HEADING" >"$W/spliced.md"
assert_rc 0 "$?" "a splice over a present heading succeeds"
assert_eq "$(state_of "$W/spliced.md" "$W/handover.md")" CURRENT \
  "the spliced body is CURRENT — the second ship run makes no edit"

printf -- '- a finding nobody fixed\n- and a second one\n' >"$W/handover.md"
assert_eq "$(state_of "$W/spliced.md" "$W/handover.md")" STALE \
  "editing handover.md makes the same body STALE again"

# A hand-edit INSIDE the section must not read as stale: the digest is of the
# handover file, not of the body.
printf -- '- a finding nobody fixed\n' >"$W/handover.md"
printf 'A reviewer added this sentence by hand on GitHub.\n' >>"$W/spliced.md"
assert_eq "$(state_of "$W/spliced.md" "$W/handover.md")" CURRENT \
  "a hand-edit to the body does not make it stale while handover.md is unchanged"

# --- a marker inside a fence is not a marker --------------------------------
#
# This repository DOCUMENTS the marker, so a pull request body explaining the
# mechanism is the likely place to quote one — and the scan stops at its first
# hit. A wrong digest quoted above the real section used to pin the body to
# STALE forever, so every ship run re-spliced and `gh pr edit`ed, clobbering any
# hand-edit inside the section each time; a right one quoted above a genuinely
# stale section used to read CURRENT and suppress the refresh entirely.

printf -- '- a finding nobody fixed\n' >"$W/handover.md"
CUR="$(bash "$STATE" --marker "$W/handover.md")"

{
  printf '# Summary\n\nShip leaves a line like this in the body:\n\n'
  printf '```\n<!-- gantry:handover sha256=deadbeef1234 -->\n```\n\n'
  printf '## %s\n\n%s\n\n- a finding nobody fixed\n' "$HEADING" "$CUR"
} >"$W/fenced-wrong-marker.md"
assert_eq "$(state_of "$W/fenced-wrong-marker.md" "$W/handover.md")" CURRENT \
  "a WRONG marker quoted in a fence does not mask the real one below it"

{
  printf '# Summary\n\nShip leaves a line like this in the body:\n\n'
  printf '```\n%s\n```\n\n' "$CUR"
  printf '## %s\n\nA section with no marker at all.\n' "$HEADING"
} >"$W/fenced-right-marker.md"
assert_eq "$(state_of "$W/fenced-right-marker.md" "$W/handover.md")" STALE \
  "and a RIGHT marker quoted in a fence does not make an unmarked section CURRENT"

# --- the splice leaves everything else alone --------------------------------

assert_file_contains "$W/spliced.md" '^Preamble on one long line\.$' \
  "the preamble above the section survived"
assert_file_contains "$W/spliced.md" '^## Not proven by this run$' \
  "the section below it survived"
assert_file_contains "$W/spliced.md" '^The human-only checks\.$' \
  "including its contents"
assert_file_lacks "$W/spliced.md" 'Old, pre-marker text' \
  "and the replaced section's old text is gone"

# --- an ambiguous heading changes nothing -----------------------------------

{
  printf '## %s\n\nfirst\n\n' "$HEADING"
  printf '## %s\n\nsecond\n' "$HEADING"
} >"$W/dup-body.md"
DUP_OUT="$(bash "$SPLICE" "$W/dup-body.md" "$W/section.md" "$HEADING" 2>/dev/null)"
DUP_RC=$?
assert_rc 1 "$DUP_RC" "two matching headings is a refusal, not a guess"
if [ -z "$DUP_OUT" ]; then
  _pass "and nothing is printed — a caller cannot write a half-spliced body"
else
  _fail "an ambiguous heading printed output"
fi

# --- a heading inside a fence is not a heading ------------------------------

{
  printf '# Title\n\nProse.\n\n'
  printf '```\n## %s\n```\n\n' "$HEADING"
  printf 'Tail prose.\n'
} >"$W/fenced-body.md"
bash "$SPLICE" "$W/fenced-body.md" "$W/section.md" "$HEADING" >"$W/fenced-out.md"
assert_rc 0 "$?" "a body whose only match is fenced splices rather than refusing"
assert_file_contains "$W/fenced-out.md" '^```$' "the fence survived"
if [ "$(grep -c "^## $HEADING\$" "$W/fenced-out.md")" = "2" ]; then
  _pass "the fenced heading was left alone and a real section was appended beside it"
else
  _fail "expected the fenced heading plus one appended section"
fi

# --- an absent heading: before the anchor, else appended --------------------

{
  printf '# Title\n\nProse.\n\n'
  printf '## Not proven by this run\n\nThe human-only checks.\n'
} >"$W/anchored.md"
bash "$SPLICE" "$W/anchored.md" "$W/section.md" "$HEADING" >"$W/anchored-out.md"
if awk -v h="## $HEADING" '
  $0 == h { seen = NR }
  $0 == "## Not proven by this run" { anchor = NR }
  END { exit (seen && anchor && seen < anchor) ? 0 : 1 }
' "$W/anchored-out.md"; then
  _pass "an absent heading is inserted BEFORE '## Not proven by this run'"
else
  _fail "the inserted section did not land before the anchor"
fi

bash "$SPLICE" "$W/missing-body.md" "$W/section.md" "$HEADING" >"$W/appended-out.md"
assert_file_contains "$W/appended-out.md" "^## $HEADING\$" \
  "with no anchor either, the section is appended at the end"
assert_file_contains "$W/appended-out.md" '^No handover section at all\.$' \
  "and the original body is still there"

# --- CRLF -------------------------------------------------------------------
#
# scripts/check_pr_body.sh never strips \r, and a "\r" paragraph separator
# classifies as prose — so every following paragraph trips its break test, and
# ship's standing "fix what it names and run it again" would then have a model
# reflow a body it was told to leave byte-identical. Whether GitHub ever returns
# CRLF is unverified; the strip costs one line and removes the hazard either way.

printf '# Title\r\n\r\nPreamble on one long line.\r\n\r\n## %s\r\n\r\nOld.\r\n' "$HEADING" >"$W/crlf.md"
bash "$SPLICE" "$W/crlf.md" "$W/section.md" "$HEADING" >"$W/crlf-out.md"
assert_rc 0 "$?" "a CRLF body splices"
if LC_ALL=C grep -q $'\r' "$W/crlf-out.md"; then
  _fail "the spliced body still carries CR"
else
  _pass "the spliced body is LF-only"
fi
bash "$CHECK_BODY" "$W/crlf-out.md" >/dev/null 2>&1
assert_rc 0 "$?" "and it passes scripts/check_pr_body.sh"

# --- usage ------------------------------------------------------------------

bash "$SPLICE" "$W/stale-body.md" "$W/section.md" >/dev/null 2>&1
assert_rc 2 "$?" "a missing heading argument is exit 2"
bash "$SPLICE" "$W/nope.md" "$W/section.md" "$HEADING" >/dev/null 2>&1
assert_rc 2 "$?" "a missing body file is exit 2"
bash "$STATE" "$W/nope.md" "$W/handover.md" >/dev/null 2>&1
assert_rc 2 "$?" "a state read of a missing body file is exit 2, not a quiet STALE"

# --- the same question, asked of qa.md --------------------------------------
# /gantry:qa re-run after the PR opened left a body saying "no qa agent" over
# scenarios that had since passed. --section qa reads the Exercised section.

printf 'outcome: exercised\n' >"$W/qa.md"
QA_MARKER="$(bash "$STATE" --section qa --marker "$W/qa.md")"
case "$QA_MARKER" in
  '<!-- gantry:qa sha256='*' -->') _pass "--section qa --marker prints a qa marker, not a handover one" ;;
  *)                               _fail "unexpected qa marker: $QA_MARKER" ;;
esac

{
  printf '## Exercised by this run\n\n`/gantry:qa` ran and found no qa agent.\n\n'
  printf '## Not proven by this run\n\nThe human-only checks.\n'
} >"$W/qa-stale-body.md"
assert_eq "$(bash "$STATE" --section qa "$W/qa-stale-body.md" "$W/qa.md" 2>/dev/null)" STALE \
  "an Exercised section with no qa marker is STALE"

{
  printf '## Exercised by this run\n\n%s\n\n- a scenario — pass.\n\n' "$QA_MARKER"
  printf '## Deliberately not done\n\n%s\n\n- a finding\n' "$MARKER"
} >"$W/both-body.md"
assert_eq "$(bash "$STATE" --section qa "$W/both-body.md" "$W/qa.md" 2>/dev/null)" CURRENT \
  "a matching qa marker is CURRENT"
assert_eq "$(state_of "$W/both-body.md" "$W/handover.md")" CURRENT \
  "and the handover marker beside it is still read as the handover's"

printf 'outcome: no-agent\n' >"$W/qa.md"
assert_eq "$(bash "$STATE" --section qa "$W/both-body.md" "$W/qa.md" 2>/dev/null)" STALE \
  "a changed qa.md makes the Exercised section STALE"

printf '# Title\n\nNo exercised section.\n' >"$W/qa-missing-body.md"
assert_eq "$(bash "$STATE" --section qa "$W/qa-missing-body.md" "$W/qa.md" 2>/dev/null)" MISSING \
  "no Exercised heading and no qa marker is MISSING"

assert_eq "$(bash "$STATE" --section qa "$W/both-body.md" "$W/no-such-qa.md" 2>/dev/null)" NO-QA \
  "no qa.md at all is NO-QA"

bash "$STATE" --section review "$W/both-body.md" "$W/qa.md" >/dev/null 2>&1
assert_rc 2 "$?" "an unknown --section is a usage error"

finish
