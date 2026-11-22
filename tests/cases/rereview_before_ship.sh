#!/usr/bin/env bash
#
# BASE-487: both drivers re-review once, read-only, at the medium tier, when review.md is stale
# just before ship. The step is prose, so what can be pinned is placement and the rules that keep
# it from recursing or from being unreachable: it sits between QA and ship, it never launches
# review-fix, a killed fix child no longer stops the run, and success is the freshness recheck.
# review_fresh.sh itself is covered by review_fresh.sh.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

for name in auto auto-unattended; do
  skill="$GANTRY_ROOT/skills/$name/SKILL.md"
  qa="$(grep -n '^## Stage 5b ' "$skill" | head -1 | cut -d: -f1)"
  re="$(grep -n '^## Stage 5c — Re-review before ship' "$skill" | head -1 | cut -d: -f1)"
  ship="$(grep -n '^## Stage 6 ' "$skill" | head -1 | cut -d: -f1)"
  if [ -n "$qa" ] && [ -n "$re" ] && [ -n "$ship" ] && [ "$qa" -lt "$re" ] && [ "$re" -lt "$ship" ]; then
    _pass "$name: stage 5c sits between QA and ship"
  else
    _fail "$name: stage 5c placement (qa=$qa re=$re ship=$ship)"
  fi
  body="$(sed -n "${re},${ship}p" "$skill" 2>/dev/null)"
  case "$body" in *'--phase review --root <worktree> --tier medium'*) _pass "$name: launches the medium-tier review child" ;; *) _fail "$name: no medium-tier launch in 5c" ;; esac
  case "$body" in *'review_fresh.sh'*'FRESH:stale'*) _pass "$name: gated on FRESH:stale" ;; *) _fail "$name: 5c does not key on FRESH:stale" ;; esac
  case "$body" in *'Never launch `review-fix`'*) _pass "$name: never applies the re-review's findings" ;; *) _fail "$name: missing the never-review-fix rule" ;; esac
  case "$body" in *'success test'*) _pass "$name: recheck is the success test" ;; *) _fail "$name: missing the recheck rule" ;; esac
  case "$body" in *'unassessed'*) _pass "$name: names the unassessed fallback" ;; *) _fail "$name: missing the unassessed fallback" ;; esac
  assert_file_contains "$skill" 'go on to stage 5c' "$name: a killed fix child continues to 5c, not a stop"
done

finish
