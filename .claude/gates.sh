#!/usr/bin/env bash
#
# .claude/gates.sh — gantry's gate for gantry.
#
# When this file exists it IS the gate: run_gates.sh executes it and uses its
# exit code verbatim, skipping ecosystem auto-detection entirely. See
# examples/gates.sh for the copy a target repo starts from.
#
# There is nothing to reimplement here. scripts/verify.sh is already this
# repo's whole check suite, and .github/workflows/validate.yml runs exactly
# that script — so a green gate locally means a green CI run, and this file is
# a pointer rather than a second source of truth.
#
# Why it exists at all: without it, `run_gates.sh --strict` finds no ecosystem
# to detect (this repo is markdown and shell, with no package manifest) and
# reports NO-GATES, which under --strict is exit 3 — an unattended run then
# refuses to push. gantry shipped a gate it did not apply to itself, so every
# gantry run *on gantry* had to either drop --strict or supply this file by
# hand. Committing it closes that gap and arms the readiness hook here too.
#
#   exit 0  green    exit 1+  red    exit 2  the gate could not run

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
exec bash scripts/verify.sh
