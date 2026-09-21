#!/usr/bin/env bash
#
# scripts/check_evals.sh is the free half of the eval suite's feedback loop:
# `claude plugin eval` has no dry-run, so without this lint the first proof
# that a case is well formed is a paid run that reports a parse error instead
# of a score. A lint nobody tests is a lint that reports clean on a broken
# suite, which is worse than not having one.
#
# Each negative case below breaks exactly one thing in a suite that is
# otherwise valid, so a FAIL names the rule that fired rather than the fixture.
# Three of them are load-bearing rather than thorough:
#
#   - `results/` beside the cases must PASS. The paid run writes there; a lint
#     that walked into it would turn the gate red the first time anyone
#     produced the evidence the suite exists to produce.
#   - no `evals/` at all must be exit 0. verify.sh collapses 1 and 2 into one
#     FAIL, and tests/cases/verify_untracked.sh runs the whole of verify.sh in
#     a fixture repo that has no suite.
#   - a `change.diff` that has drifted from the tree beside it must FAIL. A
#     reviewer case whose diff does not match its files scores a CORRECT
#     finding ("this diff does not apply") as a miss, and nothing else in the
#     suite would ever say so.
#
# The last two assertions are regressions on the wiring rather than on the
# script: without them the verify.sh section and the .gitignore rule can both
# be deleted with the suite still green.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

CHECK="$GANTRY_ROOT/scripts/check_evals.sh"

check() {  # check <dir> -> sets OUT and RC
  OUT="$(bash "$CHECK" "$1" 2>&1)"; RC=$?
}

# mksuite <name> — a suite holding one valid case, "good". Echoes its path.
mksuite() {
  local s="$CASE_TMP/$1"
  rm -rf "$s"
  mkdir -p "$s/good/graders" "$s/good/fixture-good"
  cat >"$s/good/case.yaml" <<'YAML'
schema_version: "1.1"
name: good
tags: [demo]
context:
  add_dirs: [fixture-good]
execution:
  max_turns: 8
  timeout_seconds: 300
  allowed_tools: [Read, Glob, Grep]
YAML
  printf 'Read the fixture and report what is wrong with it.\n' >"$s/good/prompt.md"
  cat >"$s/good/graders/criteria.md" <<'MD'
---
type: llm
weight: 1
---

PASS if the response names the defect in the fixture.
MD
  printf 'a fixture file\n' >"$s/good/fixture-good/note.txt"
  printf '%s' "$s"
}

# --- the shape the suite is meant to have ------------------------------------

good="$(mksuite good)"
check "$good"
assert_rc 0 "$RC" "a well-formed case passes"

# The real suite in this repository, through the same script. If eval-0's own
# cases stop satisfying the lint that gates them, this is where it shows.
if [ -d "$GANTRY_ROOT/evals" ]; then
  check "$GANTRY_ROOT/evals"
  assert_rc 0 "$RC" "this repository's own eval suite passes"
fi

# --- one broken thing per case -----------------------------------------------

s="$(mksuite nobound)"
sed -i.bak '/timeout_seconds/d' "$s/good/case.yaml" && rm -f "$s/good/case.yaml.bak"
check "$s"
assert_rc 1 "$RC" "a case with no timeout_seconds fails"
assert_contains "$OUT" "timeout_seconds" "and says which bound is missing"

s="$(mksuite noturns)"
sed -i.bak '/max_turns/d' "$s/good/case.yaml" && rm -f "$s/good/case.yaml.bak"
check "$s"
assert_rc 1 "$RC" "a case with no max_turns fails"

s="$(mksuite bashtool)"
sed -i.bak 's/allowed_tools: \[Read, Glob, Grep\]/allowed_tools: [Read, Glob, Bash]/' \
  "$s/good/case.yaml" && rm -f "$s/good/case.yaml.bak"
check "$s"
assert_rc 1 "$RC" "a case asking for Bash fails — it would need --allow-tools"
assert_contains "$OUT" "Bash" "and names the tool"

s="$(mksuite notools)"
sed -i.bak '/allowed_tools/d' "$s/good/case.yaml" && rm -f "$s/good/case.yaml.bak"
check "$s"
assert_rc 1 "$RC" "a case that declares no allowed_tools at all fails"

s="$(mksuite scaffold)"
printf '  scaffold_script: setup.sh\n' >>"$s/good/case.yaml"
check "$s"
assert_rc 1 "$RC" "a case declaring scaffold_script fails — the suite must run without --scaffold"
assert_contains "$OUT" "scaffold_script" "and names it"

s="$(mksuite notype)"
printf -- '---\nweight: 1\n---\n\nPASS if it is good.\n' >"$s/good/graders/criteria.md"
check "$s"
assert_rc 1 "$RC" "a grader with no type: fails"

s="$(mksuite badtype)"
printf -- '---\ntype: vibes\n---\n\nPASS if it is good.\n' >"$s/good/graders/criteria.md"
check "$s"
assert_rc 1 "$RC" "a grader with an unknown type fails"

s="$(mksuite emptyllm)"
printf -- '---\ntype: llm\nweight: 1\n---\n\n' >"$s/good/graders/criteria.md"
check "$s"
assert_rc 1 "$RC" "an llm grader with no criteria fails"

s="$(mksuite nofrontmatter)"
printf 'PASS if the response names the defect.\n' >"$s/good/graders/criteria.md"
check "$s"
assert_rc 1 "$RC" "a grader file with no frontmatter fails — the harness ignores it silently"

s="$(mksuite nograders)"
rm -rf "$s/good/graders"
check "$s"
assert_rc 1 "$RC" "a case with no graders/ fails"

s="$(mksuite emptygraders)"
rm -f "$s/good"/graders/*.md
check "$s"
assert_rc 1 "$RC" "a graders/ directory with no .md files fails"

s="$(mksuite namemismatch)"
sed -i.bak 's/^name: good$/name: elsewhere/' "$s/good/case.yaml" && rm -f "$s/good/case.yaml.bak"
check "$s"
assert_rc 1 "$RC" "a name that is not the directory fails — --case filters by it"
assert_contains "$OUT" "elsewhere" "and shows what it says instead"

s="$(mksuite missingdir)"
rm -rf "$s/good/fixture-good"
check "$s"
assert_rc 1 "$RC" "an add_dirs entry that does not exist fails"
assert_contains "$OUT" "fixture-good" "and names the entry"

s="$(mksuite noprompt)"
rm -f "$s/good/prompt.md"
check "$s"
assert_rc 1 "$RC" "a case with no prompt at all fails"

s="$(mksuite emptyprompt)"
printf '\n' >"$s/good/prompt.md"
check "$s"
assert_rc 1 "$RC" "a prompt.md with no body fails"

s="$(mksuite notacase)"
mkdir -p "$s/stray"
printf 'notes\n' >"$s/stray/README.txt"
check "$s"
assert_rc 1 "$RC" "a directory that is neither case.yaml nor prompt.md fails"

s="$(mksuite badversion)"
sed -i.bak 's/^schema_version: "1.1"$/schema_version: "9.0"/' "$s/good/case.yaml" \
  && rm -f "$s/good/case.yaml.bak"
check "$s"
assert_rc 1 "$RC" "a schema_version this lint does not know fails"

# --- change.diff against the tree beside it ----------------------------------

# The fixture has moved on since the diff was taken: the line the diff expects
# to find ("two") is now "drifted", so reversing it cannot apply.
s="$(mksuite driftdiff)"
printf 'one\ndrifted\nthree\n' >"$s/good/fixture-good/note.txt"
cat >"$s/good/fixture-good/change.diff" <<'DIFF'
diff --git a/note.txt b/note.txt
index 1111111..2222222 100644
--- a/note.txt
+++ b/note.txt
@@ -1,3 +1,3 @@
 one
-TWO
+two
 three
DIFF
check "$s"
assert_rc 1 "$RC" "a change.diff that does not match the tree beside it fails"
assert_contains "$OUT" "change.diff" "and names the diff"

# The mirror image: the same diff against the tree it was actually taken from.
# The fixture ships the POST-change text, so reversing the diff is what has to
# apply — which is the direction the lint checks and the direction that proves
# the fixture and the diff still describe one change.
s="$(mksuite gooddiff)"
printf 'one\ntwo\nthree\n' >"$s/good/fixture-good/note.txt"
cat >"$s/good/fixture-good/change.diff" <<'DIFF'
diff --git a/note.txt b/note.txt
index 1111111..2222222 100644
--- a/note.txt
+++ b/note.txt
@@ -1,3 +1,3 @@
 one
-TWO
+two
 three
DIFF
check "$s"
assert_rc 0 "$RC" "a change.diff that reverse-applies cleanly passes"

# The same drift, but with the suite inside a git repository — which is where
# the real one lives. There `git apply` resolves the diff's paths from the
# repository root and skips them all with exit 0, so a lint that only ever ran
# against /tmp fixtures passed every drifted diff in this repo.
repo="$(mkrepo inrepo)"
cp -R "$CASE_TMP/driftdiff" "$repo/evals"
check "$repo/evals"
assert_rc 1 "$RC" "a drifted change.diff fails inside a git repository too"

# --- valid YAML the flat reader must still read -------------------------------

s="$(mksuite comments)"
sed -i.bak 's/^  allowed_tools: \[Read, Glob, Grep\]$/  allowed_tools: [Read, Glob, Grep]  # ungated only/; s/^name: good$/name: good  # matches the dir/' \
  "$s/good/case.yaml" && rm -f "$s/good/case.yaml.bak"
check "$s"
assert_rc 0 "$RC" "trailing # comments in case.yaml are ignored, not read as values"

# --- the directories discovery skips ------------------------------------------

s="$(mksuite withresults)"
mkdir -p "$s/results/2026-09-20T00-00-00"
printf '{"cases": []}\n' >"$s/results/2026-09-20T00-00-00/aggregate-result.json"
printf 'not a case\n' >"$s/results/stray.md"
mkdir -p "$s/mocks/github"
printf -- '---\ntype: fixed\n---\n\ncanned\n' >"$s/mocks/github/list_issues.md"
check "$s"
assert_rc 0 "$RC" "a populated results/ and mocks/ beside good cases still passes"

# --- no suite at all ----------------------------------------------------------

repo="$(mkrepo nosuite)"
OUT="$(cd "$repo" && bash "$CHECK" 2>&1)"; RC=$?
assert_rc 0 "$RC" "a repository with no evals/ is exit 0, not a defect"
assert_contains "$OUT" "no eval suite" "and says so"

OUT="$(bash "$CHECK" "$CASE_TMP/nope" 2>&1)"; RC=$?
assert_rc 2 "$RC" "an explicit directory that does not exist is a usage error"

OUT="$(bash "$CHECK" one two 2>&1)"; RC=$?
assert_rc 2 "$RC" "more than one argument is a usage error"

# --- the wiring, which is deletable without these ------------------------------

assert_file_contains "$GANTRY_ROOT/scripts/verify.sh" 'check_evals\.sh' \
  "scripts/verify.sh invokes the lint"

if git -C "$GANTRY_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$GANTRY_ROOT" check-ignore -q evals/results/aggregate-result.json; then
    _pass "evals/results/ is ignored in this repository"
  else
    _fail "evals/results/ is ignored in this repository — a paid run would dirty the tree"
  fi
fi

finish
