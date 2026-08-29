#!/usr/bin/env bash
#
# The hook must gate the worktree the run is happening IN, not the checkout the
# session was launched FROM.
#
# Every other case in this directory runs through lib.sh's run_hook(), which
# sets CLAUDE_PROJECT_DIR and the payload's cwd to the SAME directory. That is
# the shape of an ordinary in-place session, and under it this bug is invisible
# — which is why a harness written to prove the guarantee could pass in full
# while the guarantee never once fired in practice. gantry's own default
# workflow is the shape the harness never built: /gantry:worktree and every
# /gantry:auto-unattended lane run in a worktree under .claude/worktrees/,
# while CLAUDE_PROJECT_DIR still points at the launch checkout.
#
# So this case deliberately makes the two disagree. It is the regression test
# for a hook that read the launch checkout's task.md, found `status: shipped`,
# and skipped on every stop of every unattended run.
#
# lib/detect_stage.sh has always resolved this correctly, via
# `git rev-parse --show-toplevel`. The two scripts share a byte-identical
# frontmatter parser, diffed by scripts/verify.sh so it cannot drift — but they
# read that field out of two different files, which is the same failure the
# diffing exists to prevent, one level up. Assert the behaviour, not the line.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# --- a main checkout at `shipped`, a worktree at `implementing`, red gate -----
main="$(mkrepo main)"
write_gates "$main" 1          # always red: if the hook arms at all, it blocks
write_task "$main" shipped     # the launch checkout is long since done
commit_all "$main" 'gate and task'   # a worktree inherits only what is committed

wt="$(mkworktree "$main" wt lane)"
write_task "$wt" implementing  # the lane is mid-implement, over a red gate

run_hook "$wt" false "$main"
assert_rc 2 "$HOOK_RC" "a worktree at implementing blocks, though the launch checkout says shipped"
assert_gate_ran "$wt" "the gate ran against the worktree"
assert_gate_not_run "$main" "the gate did not run against the launch checkout"

# --- the audit line must land in the worktree, not the launch checkout -------
# Where the log is written is how an operator finds out whether their run was
# gated at all. A line filed under the launch checkout is attributed to the
# wrong run, and with several lanes sharing one launch checkout it cannot be
# attributed to any of them.
assert_path_present "$(hooklog "$wt")" "the audit line is written to the worktree"

# --- the inverse: a worktree that is not implementing stays inert ------------
# Guards against an over-correction that arms on any worktree it can resolve.
write_task "$wt" shipped
run_hook "$wt" false "$main"
assert_rc 0 "$HOOK_RC" "a worktree at shipped stays inert"

# --- the fallback chain is untouched -----------------------------------------
# No cwd in the payload: the hook must still answer from CLAUDE_PROJECT_DIR
# exactly as it did before, or this fix breaks every non-worktree run.
write_task "$main" implementing
# Not run_hook: this case needs a payload with NO cwd key at all, which is the
# one shape the helper cannot build. Capture only the status — assigning the
# output to HOOK_OUT here would leave it genuinely unread, which shellcheck is
# right to flag (the helper's own assignment is read by the calling case).
nocwd_rc=0
printf '{"hook_event_name":"Stop","stop_hook_active":false}' \
  | CLAUDE_PROJECT_DIR="$main" bash "$HOOK" >/dev/null 2>&1 || nocwd_rc=$?
assert_rc 2 "$nocwd_rc" "with no cwd in the payload, the hook still answers from \$CLAUDE_PROJECT_DIR"

# --- a cwd that is not in a repo at all --------------------------------------
# git rev-parse fails here; the hook must fall back rather than die.
plain="$(mkdir_plain outside)"
run_hook "$plain" false "$main"
assert_rc 2 "$HOOK_RC" "a non-repo cwd falls back to \$CLAUDE_PROJECT_DIR"

finish
