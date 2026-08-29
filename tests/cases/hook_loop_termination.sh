#!/usr/bin/env bash
#
# Loop termination is `stop_hook_active`, and nothing else. The harness sets it
# true on a stop that was itself caused by a previous block, and the hook then
# defers unconditionally — which is why it can block a given stop at most once
# and why there is deliberately no counter anywhere in the file.
#
# The jq case is the sharp one. jq's `//` only substitutes on a present-but-null
# field; it does nothing when jq fails to run at all, and the command
# substitution just captures empty stdout. Empty is indistinguishable from
# "false", so a jq failure on the very stop our own block caused would re-run
# the gate and block again — an unbounded loop with no second terminator. That
# read must therefore check jq's exit status and treat failure as "assume
# active, defer".

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# --- stop_hook_active: true defers, even against a red tree ------------------
repo="$(mkrepo active)"
write_task "$repo" implementing
write_gates "$repo" 1

run_hook "$repo" false
assert_rc 2 "$HOOK_RC" "the first stop is blocked"

run_hook "$repo" true
assert_rc 0 "$HOOK_RC" "the stop caused by that block is deferred, not blocked again"
assert_file_contains "$(hooklog "$repo")" "decision=skip.*stop_hook_active=true" \
  "the audit log records the deferral"

# --- a jq failure is treated the same as "active" -----------------------------
# A stub jq that exits non-zero stands in for every way jq can fail to answer:
# absent binary, PATH stripped in the hook's environment, malformed payload.
jq_repo="$(mkrepo jq_failure)"
write_task "$jq_repo" implementing
write_gates "$jq_repo" 1

stub_cmd jq 1

run_hook "$jq_repo" false
assert_rc 0 "$HOOK_RC" "a jq failure defers rather than risking a block loop"
assert_gate_not_run "$jq_repo" "deferring means the gate is not run"

finish
