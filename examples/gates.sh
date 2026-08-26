#!/usr/bin/env bash
#
# .claude/gates.sh — copy this to your repo root as .claude/gates.sh.
#
# When this file exists, it IS the gate: gantry runs it and uses its exit code
# verbatim, skipping all ecosystem auto-detection. That is the point — this is
# how you make gantry run your real CI instead of guessing at it.
#
# THE CONTRACT (this is all gantry cares about):
#   exit 0     green — the tree is provably good, work may ship
#   exit 1+    red   — a check failed; nothing gets uploaded or opened as a PR
#   exit 2     reserved for "the gate could not run" (bad env, missing tool)
#
# Two rules worth internalising:
#   1. A tree you cannot prove is not a pass. If you have no tests yet, it is
#      more honest to exit non-zero than to exit 0 and call it green.
#   2. Run every check; do not stop at the first failure. One red check
#      masking three others wastes a whole fix cycle.
#
# Creating this file also ARMS gantry's readiness hook, which re-runs it on
# Stop and blocks the stop when it is red. Add .claude/artifacts/ to your
# .gitignore — the hook writes its logs there.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

rc=0
run() {
  printf '\n==> %s\n' "$*"
  "$@" || rc=1        # record the failure, keep going
}

# --- replace everything below with your project's real checks --------------

# Node
# run npm run lint
# run npm run typecheck
# run npm test -- --run

# Python
# run uv run ruff check .
# run uv run pytest -q

# Go
# run go vet ./...
# run go test ./...

# Rust
# run cargo clippy -- -D warnings
# run cargo test

# --- an unprovable tree is not a pass --------------------------------------
# Delete this once you have real checks above.
printf '\n==> no checks configured in .claude/gates.sh\n' >&2
exit 2

exit "$rc"
