#!/usr/bin/env bash
#
# A gate that runs and passes while reading none of the paths a change touches
# exits 0 exactly like one that proved something. lib/run_gates.sh now names the
# directories its checks ran in, and lib/gate_coverage.sh compares those against
# the changed paths.
#
# The load-bearing assertion in this file is case 4's `rc 0`. The whole point is
# that low overlap is REPORTED and never REFUSED — so the case asserts both that
# the verdict is `no-overlap` and that the gate still exits 0 under --strict. If
# someone later turns the heuristic into a refusal, that assertion is what
# fails. It passes before this change and after, deliberately: it is a
# regression net for a refusal nobody has added, not a demonstration of new
# behaviour.
#
# Coverage is a HEURISTIC — a root is the directory a check ran in, not the set
# of files it read — so these cases pin the reporting, never an accuracy claim.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# A stub npm keeps this independent of any real toolchain; without it a machine
# with no node skips every JS gate and the cases pass for the wrong reason.
stub_cmd npm 0

# run_cov <repo> [args...] — sets COV_OUT and COV_RC.
# shellcheck disable=SC2034
run_cov() {
  local repo="$1"; shift
  COV_OUT="$(cd "$repo" && bash "$GANTRY_ROOT/lib/gate_coverage.sh" "$@" 2>&1)"
  COV_RC=$?
  return 0
}

# pkg <dir> <test-script> — a package.json declaring one "test" script.
pkg() {
  mkdir -p "$1"
  printf '{\n  "name": "x",\n  "scripts": { "test": "%s" }\n}\n' "$2" >"$1/package.json"
}

# --- 1. the auto-detect path names every directory a check ran in ------------
mono="$(mkrepo mono)"
pkg "$mono" "exit 0"
pkg "$mono/sub" "exit 0"

run_gate "$mono"
assert_rc 0 "$GATE_RC" "the monorepo fixture is green"
assert_contains "$GATE_OUT" "COVERAGE root=. check=js:test" "the root check names its root"
assert_contains "$GATE_OUT" "COVERAGE root=sub check=sub:js:test" "the subproject check names its own"
assert_contains "$GATE_OUT" "== coverage roots=.,sub" "the summary lists both distinct roots"
assert_contains "$GATE_OUT" "heuristic=" "and labels itself a heuristic"

# --- 2. a repo-owned gate is UNDECLARED, not zero and not everything ---------
# The honest report for an opaque gate. Asserting the two things it must NOT
# say is what makes this case able to fail: a regression that collapsed
# undeclared onto either sentinel would otherwise pass.
owned="$(mkrepo owned)"
write_gates "$owned" 0

run_gate "$owned"
assert_rc 0 "$GATE_RC" "the repo-owned gate's exit code is still the result"
assert_contains "$GATE_OUT" "== coverage roots=UNDECLARED" "coverage is reported as undeclared"
assert_not_contains "$GATE_OUT" "roots=NONE" "undeclared is not collapsed onto zero roots"
assert_not_contains "$GATE_OUT" "root=." "undeclared is not collapsed onto every root"

printf '%s\n' "$GATE_OUT" >"$CASE_TMP/owned.log"
run_cov "$owned" --transcript "$CASE_TMP/owned.log"
assert_contains "$COV_OUT" "VERDICT: undeclared" "the comparison reports undeclared too"

# --- 3. nothing detectable reports NONE, and the exit codes are unchanged ----
bare="$(mkrepo bare)"

run_gate "$bare"
assert_rc 0 "$GATE_RC" "no detectable checks still passes when supervised"
assert_contains "$GATE_OUT" "== coverage roots=NONE" "and reports no coverage roots"

run_gate "$bare" --strict
assert_rc 3 "$GATE_RC" "and is still exit 3 under --strict"
assert_contains "$GATE_OUT" "== coverage roots=NONE" "which also carries a summary line"

printf '%s\n' "$GATE_OUT" >"$CASE_TMP/bare.log"
run_cov "$bare" --transcript "$CASE_TMP/bare.log"
assert_contains "$COV_OUT" "VERDICT: no-checks" "the comparison reports no-checks"

# --- 4. THE LOAD-BEARING CASE: green, no overlap, and still exit 0 -----------
# A gate rooted in a subdirectory against a change that touches nothing under
# it. This is the scenario the whole feature exists to make visible.
away="$(mkrepo away)"
pkg "$away/bot" "exit 0"
commit_all "$away" "add the bot subproject"

run_gate "$away" --strict
assert_rc 0 "$GATE_RC" "a subdirectory gate is green under --strict"
assert_contains "$GATE_OUT" "COVERAGE root=bot" "and reports the subdirectory as its root"
printf '%s\n' "$GATE_OUT" >"$CASE_TMP/away.log"

printf 'edited\n' >>"$away/README"          # a tracked change outside every root
run_cov "$away" --transcript "$CASE_TMP/away.log"
assert_contains "$COV_OUT" "COVERAGE-ROOTS: bot" "the roots come back from the transcript"
assert_contains "$COV_OUT" "CHANGED: 1" "the tracked working-tree change is seen"
assert_contains "$COV_OUT" "COVERED: 0" "and none of it is under a gate root"
assert_contains "$COV_OUT" "VERDICT: no-overlap" "which is green-but-uncovered"

# The assertion this file exists for: reporting it changed no exit code.
run_gate "$away" --strict
assert_rc 0 "$GATE_RC" "zero overlap is REPORTED, never refused — still exit 0 under --strict"

# --- 5. a change inside the root overlaps ------------------------------------
printf 'x\n' >"$away/bot/extra.js"
run_cov "$away" --transcript "$CASE_TMP/away.log"
assert_contains "$COV_OUT" "VERDICT: overlap" "a change under the gate root overlaps"

# --- 6. untracked files count ------------------------------------------------
# The phase that runs this has not committed yet, so a change that exists only
# in the working tree is still a change the gate did or did not cover.
fresh="$(mkrepo fresh)"
pkg "$fresh/bot" "exit 0"
commit_all "$fresh" "add the bot subproject"
run_gate "$fresh" --strict
printf '%s\n' "$GATE_OUT" >"$CASE_TMP/fresh.log"

printf 'new\n' >"$fresh/NOTES.md"           # untracked, outside every root
run_cov "$fresh" --transcript "$CASE_TMP/fresh.log"
assert_contains "$COV_OUT" "CHANGED: 1" "an untracked file is counted"
assert_contains "$COV_OUT" "VERDICT: no-overlap" "and judged against the roots"

# The orchestrator's own bookkeeping is set aside, and the count says so.
printf -- '---\nstatus: implementing\n---\n' >"$fresh/task.md"
printf 'plan\n' >"$fresh/plan.md"
run_cov "$fresh" --transcript "$CASE_TMP/fresh.log"
assert_contains "$COV_OUT" "CHANGED: 1" "task.md and plan.md do not inflate the changed count"
assert_contains "$COV_OUT" "EXCLUDED: 2" "and the exclusion is reported rather than silent"

run_cov "$fresh" --transcript "$CASE_TMP/fresh.log" --include-run-artifacts
assert_contains "$COV_OUT" "CHANGED: 3" "--include-run-artifacts counts them again"

# --- 7. the Makefile fallback reports the root, not the last dir scanned -----
# run() is called once outside gates_in_dir, where COV_DIR still holds whichever
# subproject the scan visited last. Without an explicit reset the root check is
# labelled with a directory it never ran in — the exact mislabelling this whole
# change exists to prevent, one level down.
mk="$(mkrepo makefile_root)"
mkdir -p "$mk/sub"
printf '{\n  "name": "x"\n}\n' >"$mk/sub/package.json"   # a manifest with no scripts
printf 'test:\n\t@true\n' >"$mk/Makefile"
stub_cmd make 0

run_gate "$mk"
assert_rc 0 "$GATE_RC" "the Makefile fallback is green"
assert_contains "$GATE_OUT" "COVERAGE root=. check=make:test" "the root Makefile check is labelled ."
assert_not_contains "$GATE_OUT" "COVERAGE root=sub check=make:test" "not the last directory scanned"

# --- 8. a transcript with no summary fails closed ----------------------------
# A gate that died before reporting is not the same thing as a gate that found
# nothing to check, and collapsing the two would let a broken environment read
# as "nothing needed checking".
printf '== gate: js:test ==\nsomething went wrong\n' >"$CASE_TMP/truncated.log"
run_cov "$bare" --transcript "$CASE_TMP/truncated.log"
assert_contains "$COV_OUT" "VERDICT: unknown" "a transcript with no summary is unknown, not no-checks"

# --- 9. a relative --transcript survives the chdir to the repo root ----------
# The script validates the path in the caller's cwd and parses it after
# cd "$ROOT". Resolve it too late and an existing transcript opens for the guard
# and not for the parse: the run reports `unknown` as though the gate had died.
# The callers pass a relative log path, and a phase invoked from a subdirectory
# is the normal case — this is the launch-dir-versus-worktree-root confusion
# that has bitten this repo before.
rel="$(mkrepo relative_transcript)"
pkg "$rel/bot" "exit 0"
commit_all "$rel" "add the bot subproject"
run_gate "$rel" --strict
printf '%s\n' "$GATE_OUT" >"$rel/bot/local.log"
printf 'x\n' >"$rel/bot/changed.js"

COV_OUT="$(cd "$rel/bot" && bash "$GANTRY_ROOT/lib/gate_coverage.sh" --transcript local.log 2>&1)"
assert_contains "$COV_OUT" "COVERAGE-ROOTS: bot" "a relative transcript is read from the caller's cwd"
assert_not_contains "$COV_OUT" "VERDICT: unknown" "and is not mistaken for a gate that never reported"

finish
