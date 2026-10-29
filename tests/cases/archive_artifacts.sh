#!/usr/bin/env bash
#
# lib/archive_artifacts.sh is the copy taken BEFORE a prune destroys a
# worktree. Its exit code gates a destructive action — gantry:prune-worktrees
# drops a path from the removal list when this script fails — so the codes are
# the contract, not the output:
#
#   0  everything copied, OR there was nothing to copy (a worktree holding no
#      artifacts must stay prunable)
#   1  at least one copy failed
#   2  usage or environment
#
# $HOME is pointed under $CASE_TMP throughout, so nothing here writes into the
# developer's real ~/.claude/sessions/.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

ARCHIVE="$GANTRY_ROOT/lib/archive_artifacts.sh"
FAKE_HOME="$CASE_TMP/home"
mkdir -p "$FAKE_HOME"

run_archive() {  # run_archive <worktree> <branch> <sha> — sets AR_OUT, AR_RC
  AR_OUT="$(HOME="$FAKE_HOME" bash "$ARCHIVE" "$@" 2>&1)"
  AR_RC=$?
  return 0
}

archive_path_of() { printf '%s\n' "$1" | sed -n 's/^ARCHIVE=//p' | head -1; }

repo="$(mkrepo archive-repo)"
wt="$(mkworktree "$repo" lane feat/the-lane)"

# --- nothing to archive is a SUCCESS ----------------------------------------

run_archive "$wt" feat/the-lane deadbeefcafe
assert_rc 0 "$AR_RC" "a worktree holding no artifacts exits 0"
assert_contains "$AR_OUT" "ARCHIVE=-" "and says there was nothing to archive"

# --- the happy path ---------------------------------------------------------

mkdir -p "$wt/.claude/artifacts"
printf '# handover\n\n- one deferred finding\n' >"$wt/handover.md"
printf -- '---\nstatus: reviewed\n---\n' >"$wt/task.md"
printf 'gate transcript\n' >"$wt/.claude/artifacts/gate-1.log"

run_archive "$wt" feat/the-lane 1234567890abcdef
assert_rc 0 "$AR_RC" "a worktree holding artifacts exits 0"
dest="$(archive_path_of "$AR_OUT")"
assert_contains "$AR_OUT" "COPIED=handover.md" "the handover is named as copied"
assert_contains "$AR_OUT" "COPIED=task.md" "task.md is named as copied"
assert_contains "$AR_OUT" "COPIED=.claude/artifacts/" "the artifacts directory is named as copied"

case "$dest" in
  "$FAKE_HOME"/.claude/sessions/*/worktrees/*-feat-the-lane-12345678)
    _pass "the archive lands at <sessions>/worktrees/<date>-<branch-slug>-<sha8>" ;;
  *)
    _fail "unexpected archive path: $dest" ;;
esac

assert_path_present "$dest/handover.md" "the handover is on disk in the archive"
assert_path_present "$dest/.claude/artifacts/gate-1.log" "the gate transcript came with it"
if diff -q "$wt/handover.md" "$dest/handover.md" >/dev/null 2>&1; then
  _pass "the archived handover is byte-identical"
else
  _fail "the archived handover differs from the original"
fi

# Outside the repo is the whole point: a prune of the worktree must not reach it.
case "$dest" in
  "$repo"/*) _fail "the archive is inside the repository" ;;
  *)         _pass "the archive is outside the repository" ;;
esac

# --- a re-run over an existing archive ---------------------------------------

run_archive "$wt" feat/the-lane 1234567890abcdef
assert_rc 0 "$AR_RC" "a second run over the same tip exits 0 — the directory is reused"
if [ "$(archive_path_of "$AR_OUT")" = "$dest" ]; then
  _pass "and lands on the same path, by design: <sha8> distinguishes tips, not prunes"
else
  _fail "the second run chose a different path"
fi

# --- a detached worktree ------------------------------------------------------
#
# detect_candidates.sh emits `-` for a detached worktree's branch, and
# `slugify -` is the empty string — so without a fallback the archive directory
# would be named `<date>--<sha8>`.

run_archive "$wt" - 99887766deadbeef
assert_rc 0 "$AR_RC" "a detached worktree archives"
case "$(archive_path_of "$AR_OUT")" in
  *-detached-99887766) _pass "a '-' branch falls back to 'detached', not an empty slug" ;;
  *)                   _fail "unexpected detached archive path: $(archive_path_of "$AR_OUT")" ;;
esac

# --- a destination that cannot be written ------------------------------------
#
# The directory is pre-created read-only, so `mkdir -p` succeeds (it already
# exists) and the COPIES are what fail — which is the case the exit code has to
# distinguish, and the failure has to name the file.

ro_home="$CASE_TMP/home-ro"
ro_dest="$ro_home/.claude/sessions/$(printf '%s' "$repo" | sed 's#/#-#g')/worktrees/$(date +%F)-feat-the-lane-aaaaaaaa"
mkdir -p "$ro_dest"
chmod 500 "$ro_dest"
AR_OUT="$(HOME="$ro_home" bash "$ARCHIVE" "$wt" feat/the-lane aaaaaaaa11112222 2>&1)"
AR_RC=$?
if [ "$AR_RC" -eq 1 ]; then
  _pass "a failed copy is exit 1 — prune must not remove the worktree (rc 1)"
  assert_contains "$AR_OUT" "handover.md" "and the failure names the file that could not be copied"
else
  # Running as root defeats the mode bits; say so rather than passing vacuously.
  _fail "expected rc 1 from an unwritable destination, got $AR_RC (running as root?)"
fi
chmod 700 "$ro_dest"

# --- usage and environment ---------------------------------------------------

run_archive "$wt" feat/the-lane
assert_rc 2 "$AR_RC" "a missing argument is exit 2"

run_archive "$CASE_TMP/no-such-worktree" feat/the-lane abcdef12
assert_rc 2 "$AR_RC" "an unreadable worktree is exit 2, not a silent success"

plain="$(mkdir_plain outside-git)"
printf '# handover\n' >"$plain/handover.md"
run_archive "$plain" some-branch abcdef12
assert_rc 2 "$AR_RC" "a directory outside any git repository is exit 2"

finish
