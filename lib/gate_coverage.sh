#!/usr/bin/env bash
# gate_coverage.sh — did the gate read anything the change touched?
#
# Reads a lib/run_gates.sh transcript, compares the roots it reports against the
# paths this change modifies, and prints an overlap verdict. Run it; don't
# reimplement it.
#
#   bash gate_coverage.sh --transcript <file> [--base <ref>] [--include-run-artifacts]
#
# Output, one per line. The three counts are integers, not path lists:
#   COVERAGE-ROOTS: <space-separated roots, or UNDECLARED, or NONE>
#   CHANGED:  <count of paths considered>
#   EXCLUDED: <count of run-artifact paths skipped>
#   COVERED:  <count of paths matching a root>
#   VERDICT:  overlap | no-overlap | undeclared | no-checks | no-changes | unknown
#   NOTE:     the caveat below, so a captured stdout carries it too
#
# THIS IS A HEURISTIC AND THE NUMBERS ARE NOT A PROOF. A root is the directory a
# check was RUN IN, never the set of files it READ, and it errs in both
# directions: a pytest suite rooted at bot/ may import from the repo root, so
# real coverage can exceed what is reported; and a check that ran at the repo
# root "covers" every path here while possibly reading almost none of them, so
# reported coverage can wildly exceed the real thing. Mapping a check to the
# files it reads is per-ecosystem and imprecise, which is exactly why this
# script reports and never refuses.
#
# WHY IT REPORTS RATHER THAN REFUSES. A gate that passes while reading none of
# the changed paths exits 0 like any other. Making that a failure would fire on
# every legitimate documentation-only change and needs an override design first.
# So nothing here returns non-zero on low overlap: exit 0 = a verdict was
# produced, exit 2 = this script could not run. The gate's own exit code is
# untouched and remains the contract.
#
# READING THE NUMBERS. When VERDICT is `undeclared`, `unknown` or `no-checks`,
# COVERED is 0 because nothing could be ATTRIBUTED — not because nothing was
# covered. Check VERDICT before reading the counts.
#
# LIMITS. Roots are matched by path prefix and carried in space-delimited
# strings (bash 3.2 has no associative arrays), so a root or path containing a
# space or a comma corrupts the comparison. No such path occurs in this repo.

set -uo pipefail

TRANSCRIPT=""
BASE=""
INCLUDE_ARTIFACTS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --transcript) TRANSCRIPT="${2:-}"; shift 2 || exit 2 ;;
    --base)       BASE="${2:-}"; shift 2 || exit 2 ;;
    --include-run-artifacts) INCLUDE_ARTIFACTS=1; shift ;;
    *) echo "gate_coverage: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TRANSCRIPT" ] || { echo "gate_coverage: --transcript is required" >&2; exit 2; }

# Absolute BEFORE the chdir below, or a relative path is validated against the
# caller's cwd and then read from the repo root — the file opens for the guard
# and not for the parse, and the script reports `unknown` as though the gate had
# died. That is the same launch-dir-versus-worktree-root confusion the readiness
# hook was already bitten by, and the caller passing a relative log path is the
# normal case, not an odd one.
case "$TRANSCRIPT" in
  /*) ;;
  *) TRANSCRIPT="$PWD/$TRANSCRIPT" ;;
esac

[ -f "$TRANSCRIPT" ] || { echo "gate_coverage: no such transcript: $TRANSCRIPT" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "gate_coverage: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

emit() {  # emit <roots> <changed> <excluded> <covered> <verdict>
  echo "COVERAGE-ROOTS: $1"
  echo "CHANGED: $2"
  echo "EXCLUDED: $3"
  echo "COVERED: $4"
  echo "VERDICT: $5"
  echo "NOTE: heuristic — a root is the directory a check ran in, not the set of files it read."
}

# --- 1. Roots, from the transcript's one summary line -------------------------
# Parsed from a single place on purpose: the per-check COVERAGE lines are the
# audit trail, the summary is the contract.
roots_field="$(sed -n 's/^== coverage roots=\([^ ]*\).*/\1/p' "$TRANSCRIPT" | tail -1)"

if [ -z "$roots_field" ]; then
  # Fail closed. A transcript with no summary means the gate died before it
  # could report — never the same thing as "nothing needed checking".
  emit "NONE" 0 0 0 "unknown"
  exit 0
fi

case "$roots_field" in
  UNDECLARED) emit "UNDECLARED" 0 0 0 "undeclared"; exit 0 ;;
  NONE)       emit "NONE" 0 0 0 "no-checks"; exit 0 ;;
esac

roots="$(printf '%s' "$roots_field" | tr ',' ' ')"

# --- 2. The base to diff against ---------------------------------------------
# A ladder, and the last rung is the normal case rather than a fallback: every
# gantry worktree is created with `git worktree add --no-track`, so @{upstream}
# is unset BY DESIGN on every lane, and origin/HEAD is set by clone rather than
# by init so it is absent from every test fixture. Diffing against HEAD then
# means "everything not yet committed", which is exactly the changed set the
# implement phase holds — it runs before anything is committed.
#
# `develop` is tried before origin/HEAD, and it has to be: it is the rung
# skills/ship/scripts/detect_state.sh and lib/detect_stage.sh's inherited_base_rev()
# both try first. In a repo that integrates on develop while origin/HEAD still
# names main, skipping it merge-bases against main instead, and every path
# changed on develop since it last reached main is counted as changed by THIS
# run — the counts stop meaning "paths this change touched", which is the only
# thing they are reported as.
if [ -z "$BASE" ]; then
  if upstream="$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" && [ -n "$upstream" ]; then
    BASE="$(git merge-base HEAD "$upstream" 2>/dev/null)"
  fi
  if [ -z "$BASE" ] && [ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" != develop ]; then
    for ref in refs/remotes/origin/develop refs/heads/develop; do
      if git show-ref --verify --quiet "$ref"; then
        BASE="$(git merge-base HEAD "$ref" 2>/dev/null)"
        [ -n "$BASE" ] && break
      fi
    done
  fi
  if [ -z "$BASE" ] && git symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
    BASE="$(git merge-base HEAD refs/remotes/origin/HEAD 2>/dev/null)"
  fi
  [ -n "$BASE" ] || BASE="HEAD"
fi

# --- 3. The changed paths -----------------------------------------------------
# TWO dots, against the working tree. Three-dot is a commit-to-commit diff that
# ignores the working tree entirely, and this runs before anything is committed
# — it would return the empty set on precisely the changes it exists to judge.
changed_raw="$(
  { git diff --name-only "$BASE" 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sed '/^$/d' | sort -u
)"

# --- 4. Set the orchestrator's own bookkeeping aside --------------------------
# task.md, plan.md, handover.md, the journal and the gate logs are untracked in
# a fresh worktree and sit under no gate root, so counting them would drag every
# run toward "uncovered" and make a reported count read as source files.
is_run_artifact() {
  case "$1" in
    task.md|plan.md|handover.md|journal.jsonl) return 0 ;;
    .claude/artifacts/*) return 0 ;;
    *) return 1 ;;
  esac
}

changed=0
excluded=0
covered=0

while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ "$INCLUDE_ARTIFACTS" -eq 0 ] && is_run_artifact "$path"; then
    excluded=$((excluded + 1))
    continue
  fi
  changed=$((changed + 1))
  for r in $roots; do
    if [ "$r" = "." ]; then covered=$((covered + 1)); break; fi
    case "$path" in "$r"/*) covered=$((covered + 1)); break ;; esac
  done
done <<EOF
$changed_raw
EOF

# --- 5. The verdict -----------------------------------------------------------
if [ "$changed" -eq 0 ]; then
  verdict="no-changes"
elif [ "$covered" -eq 0 ]; then
  verdict="no-overlap"
else
  verdict="overlap"
fi

emit "$roots" "$changed" "$excluded" "$covered" "$verdict"
exit 0
