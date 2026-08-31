#!/usr/bin/env bash
#
# scripts/verify.sh must inspect files that exist but are not yet committed.
#
# WHY THIS EXISTS. Every enumeration in verify.sh used to be a bare
# `git ls-files`, which lists tracked files only. That made the gate blind to
# exactly the files a gantry run produces: `implement` runs the gate while
# task.md and plan.md are still untracked, `ship` commits them minutes later,
# and CI runs the same script with them tracked. A line-number citation pasted
# into task.md — which is the form the explorer hands you — passed here and
# failed there. This case is the assertion that it no longer does.
#
# WHY IT RUNS THE WHOLE SCRIPT. verify.sh's exit code is nearly useless as a
# signal in a fixture: a throwaway repo has no plugin manifests, no skills/ and
# no suite, so it exits non-zero whatever this change does. The differential is
# a named check's own line of output — failed in condition A, clean in
# condition B, on the same fixture.
#
# WHY THE FIXTURE LIVES UNDER $CASE_TMP. verify.sh cds to `git rev-parse
# --show-toplevel` and then runs `bash tests/run.sh`. A fixture built inside the
# gantry repo would resolve to the gantry root and recurse without bound. Under
# the temp root it resolves to the fixture, finds no tests/run.sh, and exits 127
# — one `bad` line, no recursion. This is the most expensive case in the suite
# for that reason: two full verify.sh runs, each with its own nested fixture.
#
# WHY docs/notes.md AND ok.sh ARE COMMITTED AND NEVER REMOVED. Both are
# load-bearing rather than scenery:
#   - `grep` prints filenames only when given more than one operand. With the
#     file under test as the fixture's sole markdown file the output reads
#     `1:...` rather than `task.md:1:...`, and the assertion that the check
#     NAMES the offender would fail against the fixed script.
#   - Two of verify.sh's checks pipe into `xargs -0`. BSD xargs skips the
#     utility on empty input; GNU xargs — what CI runs — invokes it with no
#     operand, leaving `grep` reading standard input. An empty enumeration would
#     hang the suite there. One committed file on each side keeps both lists
#     non-empty in every condition.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

VERIFY="$GANTRY_ROOT/scripts/verify.sh"

# run_verify <repo> — sets VERIFY_OUT and VERIFY_RC.
# shellcheck disable=SC2034
run_verify() {
  VERIFY_OUT="$(cd "$1" && bash "$VERIFY" 2>&1)"
  VERIFY_RC=$?
  return 0
}

repo="$(mkrepo cites)"

mkdir -p "$repo/docs"
printf 'Notes, carrying no citation of any kind.\n' >"$repo/docs/notes.md"
printf '#!/usr/bin/env bash\necho ok\n'             >"$repo/ok.sh"
printf '.claude/artifacts/\n'                       >"$repo/.gitignore"
commit_all "$repo" "fixture: one tracked md, one tracked sh, one ignore rule"

# The second exclusion mechanism. The .gitignore above is tracked and survives a
# fresh checkout; this one is per-clone. The drivers write both, so assert both.
#
# mkdir -p first: `git init` normally creates info/exclude from the default
# template, but a machine with init.templateDir set to a template that omits
# info/ would fail this redirect. Nothing here runs under `set -e`, so the case
# would carry on with scratch.md un-excluded and fail the assertion below with a
# message blaming --exclude-standard for a missing directory.
mkdir -p "$repo/.git/info"
printf 'scratch.md\n' >"$repo/.git/info/exclude"

# --- condition A: untracked offenders present --------------------------------

printf '# task\n\nSee docs/notes.md:55 for the detail.\n'    >"$repo/task.md"
printf '#!/usr/bin/env bash\nif true\n'                      >"$repo/broken.sh"
printf '# scratch\n\nSee docs/notes.md:55 for the detail.\n' >"$repo/scratch.md"
mkdir -p "$repo/.claude/artifacts"
printf '# log\n\nSee docs/notes.md:55 for the detail.\n'     >"$repo/.claude/artifacts/gate.md"

run_verify "$repo"

# The acceptance criterion. Both assertions are false against the pre-change
# script, which reports this check as `ok none` because task.md is untracked.
assert_contains "$VERIFY_OUT" 'FAIL  line-number citations found' \
  "an untracked .md carrying a citation fails the citation check"
assert_contains "$VERIFY_OUT" 'task.md:3:' \
  "and the check names the untracked file, at the line the citation is on"

# The syntax-side sites, fed by the same helper. `bash -n` is bash, so this
# holds on any machine the suite runs on — unlike an assertion on shellcheck.
assert_contains "$VERIFY_OUT" 'FAIL  broken.sh' \
  "an untracked .sh with a syntax error fails the shell-syntax check"
assert_contains "$VERIFY_OUT" 'ok    ok.sh' \
  "a valid tracked .sh still passes, so the check did not simply break"

# --exclude-standard, asserted rather than assumed — once per mechanism. If
# either regressed, the run's own journal and gate transcripts would be swept.
assert_not_contains "$VERIFY_OUT" 'scratch.md' \
  "a path in .git/info/exclude is not enumerated"
assert_not_contains "$VERIFY_OUT" 'gate.md' \
  "a path ignored by the tracked .gitignore is not enumerated"

assert_contains "$VERIFY_OUT" 'verify: FAIL' \
  "and the run as a whole is red"

# --- condition B: the offenders removed --------------------------------------
#
# Proves the case is testing the citation and the syntax error rather than the
# mere existence of an untracked file. The excluded copies stay on disk.

rm -f "$repo/task.md" "$repo/broken.sh"
run_verify "$repo"

assert_not_contains "$VERIFY_OUT" 'FAIL  line-number citations found' \
  "with the citation gone, the citation check reports clean"
assert_not_contains "$VERIFY_OUT" 'FAIL  broken.sh' \
  "with the broken script gone, the shell-syntax check reports clean"

finish
