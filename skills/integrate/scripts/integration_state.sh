#!/usr/bin/env bash
#
# integration_state.sh — where an integration lane stands, read from git alone.
#
# WHY THIS EXISTS. /gantry:integrate is re-runnable, and a re-run is usually a
# different session: the first one may have been compacted, interrupted, or run
# yesterday. So "which PRs are already in" cannot be remembered — it has to be
# derived. Ancestry answers it exactly: a PR is integrated when its head is an
# ancestor of the lane's HEAD, whatever anybody recalls.
#
# Two states exist because a merge alone is not the whole step. The loop merges,
# then proves the tree with the gate; between those two it writes
# `refs/integrate/<lane-branch>/pre/<label>` (the pre-merge commit, so the merge
# can be undone) and deletes it once the gate is green. A leftover one on a merge
# that IS in the tree therefore means the run died with its gate unproven —
# `unverified`, which must not be read as done. A leftover one on a merge that is
# NOT in the tree is a `STRAY_PRE:` line instead: nothing to prove, a ref to
# delete. An unconcluded merge (MERGE_HEAD present) is the earliest version of the
# same accident.
#
# THE REFS ARE LANE-SCOPED, and that is not tidiness. git keeps `refs/` in the
# COMMON git directory, shared by every linked worktree — the same trap
# lib/ensure_excluded.sh documents for `info/` — and two integration lanes at once
# is a supported state (the skill offers to start a second one, and suffixes its
# name). Unscoped, lane B's state read would find lane A's pre ref, gate its own
# tree, call it green and delete the only undo ref lane A had.
#
# Read-only: git queries only. Run from inside the integration worktree.
#
# Run with:
#   bash integration_state.sh --base <name> <label>=<ref> [...]
#
#   --base <name>   branch NAME, resolved to origin/<name> when that exists, else
#                   the local branch — the rule lib/detect_stage.sh uses.
#   <label>=<ref>   the same labels the merge loop used (a PR number, or a name).
#
# stdout — labeled lines:
#   BRANCH:<name>|DETACHED
#   HEAD:<sha>
#   BASE:<name> <resolved-ref> <sha>
#   REMOTE:<sha>|none                 origin/<branch>, i.e. what is published
#   BASE_BEHIND:<n>                   commits in base that the lane lacks
#   MERGE_IN_PROGRESS:no|yes <sha>
#   STATE:<label> integrated <sha>
#   STATE:<label> unverified <sha>    merged, gate never went green
#   STATE:<label> stale <merged-sha> <sha>       new commits since its merge
#   STATE:<label> rewritten <merged-sha> <sha>   force-pushed since its merge
#   STATE:<label> pending <sha>
#   STRAY_PRE:<label> <sha>           a pre-merge ref for a merge that is not in
#                                     the tree — delete it, do not gate anything
#   NEXT:finish-merge|verify|merge-base|merge-items|nothing
#
# On a DETACHED head the pre-merge refs cannot be located (they are named after
# the lane's branch), so `unverified` and `STRAY_PRE:` are never reported there.
# Everything else still is.
#
# THE MERGE RECORD. The loop writes `integrate: merge <token> — <title>`, where
# <token> is `#<label>` for an all-digit label and `<label>` otherwise. The newest
# first-parent merge in <base>..HEAD with that subject is the record, and its
# second parent is the sha that was merged. That is what tells `stale` (the PR
# grew) from `rewritten` (the PR's history was replaced) — and `rewritten` is the
# one a re-run must not merge blindly, because the old commits are already in and
# the new ones are a different telling of them.
#
# Exit codes: 0 = state reported · 2 = usage, not a repo, an unresolvable ref.
set -uo pipefail

die() { printf 'integration_state: %s\n' "$1" >&2; exit 2; }

BASE_NAME=""
N=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base)   [ $# -ge 2 ] || die "--base needs a branch name"; BASE_NAME="$2"; shift 2 ;;
    --base=*) BASE_NAME="${1#--base=}"; shift ;;
    -*)       die "unknown argument: $1" ;;
    *)
      case "$1" in
        *=*) : ;;
        *)   die "item must be <label>=<ref>: $1" ;;
      esac
      # A label becomes a ref path component (refs/integrate/pre/<label>) and a
      # merge-commit token, so it is restricted here rather than producing an
      # unusable ref later.
      case "${1%%=*}" in
        *[!A-Za-z0-9._-]*|"") die "label must be [A-Za-z0-9._-]+: ${1%%=*}" ;;
      esac
      LAB[$N]="${1%%=*}"
      REF[$N]="${1#*=}"
      N=$((N + 1))
      shift ;;
  esac
done

[ -n "$BASE_NAME" ] || die "--base <branch-name> is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"

GITDIR="$(git rev-parse --git-dir 2>/dev/null)"
[ -n "$GITDIR" ] || die "cannot resolve the git directory"

BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"
if [ -n "$BRANCH" ]; then echo "BRANCH:$BRANCH"; else echo "BRANCH:DETACHED"; fi

HEAD_SHA="$(git rev-parse --verify --quiet HEAD 2>/dev/null)"
[ -n "$HEAD_SHA" ] || die "HEAD does not resolve to a commit"
echo "HEAD:$HEAD_SHA"

if git show-ref --verify --quiet "refs/remotes/origin/$BASE_NAME"; then
  BASE_REF="origin/$BASE_NAME"
elif git show-ref --verify --quiet "refs/heads/$BASE_NAME"; then
  BASE_REF="$BASE_NAME"
else
  die "base '$BASE_NAME' not found on origin or locally"
fi
BASE_SHA="$(git rev-parse --verify --quiet "$BASE_REF^{commit}" 2>/dev/null)"
[ -n "$BASE_SHA" ] || die "base '$BASE_REF' does not resolve to a commit"
printf 'BASE:%s %s %s\n' "$BASE_NAME" "$BASE_REF" "$BASE_SHA"

REMOTE=none
if [ -n "$BRANCH" ] && git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  REMOTE="$(git rev-parse --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null)"
  REMOTE="${REMOTE:-none}"
fi
echo "REMOTE:$REMOTE"

BEHIND="$(git rev-list --count "$HEAD_SHA..$BASE_SHA" 2>/dev/null)"
echo "BASE_BEHIND:${BEHIND:-0}"

MERGING=no
if [ -f "$GITDIR/MERGE_HEAD" ]; then
  MERGING="$(git rev-parse --verify --quiet MERGE_HEAD 2>/dev/null)"
  printf 'MERGE_IN_PROGRESS:yes %s\n' "${MERGING:-unknown}"
  MERGING=yes
else
  echo "MERGE_IN_PROGRESS:no"
fi

# --- per item ---------------------------------------------------------------
UNVERIFIED=0
PENDING=0

i=0
while [ "$i" -lt "$N" ]; do
  sha="$(git rev-parse --verify --quiet "${REF[$i]}^{commit}" 2>/dev/null)"
  [ -n "$sha" ] || die "cannot resolve ref for ${LAB[$i]}: ${REF[$i]}"
  label="${LAB[$i]}"

  case "$label" in
    *[!0-9]*) token="$label" ;;
    *)        token="#$label" ;;
  esac

  # The merge record: newest first-parent merge whose subject is exactly the
  # loop's, matched on the full "<token> — " prefix so `#2` cannot match `#21`.
  merged="$(git log --first-parent --merges --format='%P%x09%s' "$BASE_SHA..$HEAD_SHA" 2>/dev/null \
    | awk -v want="integrate: merge $token " '
        { tab = index($0, "\t"); parents = substr($0, 1, tab - 1); subj = substr($0, tab + 1) }
        index(subj, want) == 1 { split(parents, p, " "); if (p[2] != "") { print p[2]; exit } }')"

  pre=""
  if [ -n "$BRANCH" ]; then
    pre="$(git rev-parse --verify --quiet "refs/integrate/$BRANCH/pre/$label" 2>/dev/null)"
  fi

  if git merge-base --is-ancestor "$sha" "$HEAD_SHA" 2>/dev/null; then
    if [ -n "$pre" ]; then
      printf 'STATE:%s unverified %s\n' "$label" "$sha"
      UNVERIFIED=$((UNVERIFIED + 1))
    else
      printf 'STATE:%s integrated %s\n' "$label" "$sha"
    fi
  elif [ -n "$merged" ]; then
    if git merge-base --is-ancestor "$merged" "$sha" 2>/dev/null; then
      printf 'STATE:%s stale %s %s\n' "$label" "$merged" "$sha"
    else
      printf 'STATE:%s rewritten %s %s\n' "$label" "$merged" "$sha"
    fi
    PENDING=$((PENDING + 1))
  else
    printf 'STATE:%s pending %s\n' "$label" "$sha"
    PENDING=$((PENDING + 1))
  fi

  # A pre-merge ref for something that is NOT in the tree is a different accident
  # from an unproven merge: the run died between writing the ref and completing
  # the merge, or a skip left it behind. It is reported separately because the
  # remedy is to delete it, not to gate anything.
  if [ -n "$pre" ] && ! git merge-base --is-ancestor "$sha" "$HEAD_SHA" 2>/dev/null; then
    printf 'STRAY_PRE:%s %s\n' "$label" "$pre"
  fi
  i=$((i + 1))
done

# Priority, and it is the order a resume has to act in: conclude a half-done
# merge, then prove a merge whose gate never ran, then take the base, then merge
# what is left. Anything else risks gating a tree that is mid-merge, or merging
# on top of an unproven commit.
if [ "$MERGING" = yes ]; then
  echo "NEXT:finish-merge"
elif [ "$UNVERIFIED" -gt 0 ]; then
  echo "NEXT:verify"
elif [ "${BEHIND:-0}" -gt 0 ]; then
  echo "NEXT:merge-base"
elif [ "$PENDING" -gt 0 ]; then
  echo "NEXT:merge-items"
else
  echo "NEXT:nothing"
fi
exit 0
