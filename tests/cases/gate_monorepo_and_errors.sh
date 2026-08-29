#!/usr/bin/env bash
#
# The subproject scan is why a monorepo with app/pubspec.yaml and
# landing/package.json is covered rather than silently green. A skipped
# subproject is a false green, and a false green is the exact failure the scan
# exists to prevent — so it is worth a fixture rather than a comment.
#
# The two error codes are here too. Exit 2 means the gate could not run — a
# broken environment, not a failed check — and callers must not spend a fix
# attempt trying to repair a test suite that never executed.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# --- a failing check in a subproject fails the whole gate --------------------
# The root itself declares nothing; only app/ does. Without the scan this repo
# would report NO-GATES and pass.
mono="$(mkrepo monorepo)"
mkdir -p "$mono/app"
printf '{\n  "name": "app",\n  "scripts": { "test": "exit 1" }\n}\n' >"$mono/app/package.json"

stub_cmd npm 1

run_gate "$mono"
assert_rc 1 "$GATE_RC" "a failing subproject check makes the whole gate red"
assert_contains "$GATE_OUT" "app" "the transcript names the failing subproject"
assert_not_contains "$GATE_OUT" "NO-GATES" "the subproject was found, not missed"

# --- outside a git repo, the gate cannot run ---------------------------------
# Not a red check — a broken environment. Callers route on this differently,
# so it must not collapse into 1.
plain="$(mkdir_plain not_a_repo)"
GATE_OUT="$(cd "$plain" && bash "$RUN_GATES" 2>&1)"
GATE_RC=$?
assert_rc 2 "$GATE_RC" "outside a git repo the gate exits 2, not 1"
assert_contains "$GATE_OUT" "not in a git repo" "and says why"

# --- a bad invocation is also a 2 --------------------------------------------
repo="$(mkrepo bad_args)"
run_gate "$repo" --nope
assert_rc 2 "$GATE_RC" "an unknown argument exits 2"

finish
