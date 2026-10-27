#!/usr/bin/env bash
#
# order_queue.sh — plan a merge order for a set of branches, PR heads or SHAs,
# and say which of them conflict, BEFORE anything is merged.
#
# WHY THIS IS A SCRIPT. Deciding an order is arithmetic over git facts —
# ancestry, changed files, conflicts — and every one of those facts has an exact
# command behind it. A model asked to "work out a sensible order" produces an
# order nobody can check; this produces the same order twice and prints the
# evidence. /gantry:integrate shows the output at its one checkpoint, so the
# queue a human approves is the queue that runs.
#
# READ-ONLY, in the sense that matters: it creates no commit, moves no ref,
# touches no index and no working tree. `git merge-tree --write-tree` does write
# tree and blob objects into the object store — that is what makes a conflict
# check possible without a worktree — and those are unreachable objects a later
# `git gc` removes. tests/cases/integrate_order.sh asserts refs and the reachable
# commit count are unchanged across a run.
#
# Run with:
#   bash order_queue.sh --base <name> [--after <child>:<parent>]
#                       [--created <label>:<epoch>] <label>=<ref> [...]
#
#   --base <name>   branch NAME (not a ref): resolved to origin/<name> when that
#                   remote-tracking ref exists, else the local branch. Same rule
#                   as lib/detect_stage.sh's inherited_base_rev(), so the base a
#                   queue is planned against and the base a PR targets cannot
#                   disagree.
#   --after C:P     assert C is stacked on P even when ancestry does not show it
#                   (a parent force-pushed after the child was cut). Repeatable.
#   --created L:E   use E (unix epoch) as L's age instead of reading it from the
#                   commits — /gantry:integrate passes the PR's createdAt, so a
#                   rebased old PR is not treated as young. Repeatable.
#   <label>=<ref>   an item. <label> is what the queue and the merge commit call
#                   it (a PR number, or any name); <ref> is anything rev-parse
#                   resolves.
#
# stdout — labeled lines, in this order:
#   BASE:<name> <resolved-ref> <sha>
#   STACK:<child> after <parent>
#   ITEM:<label> <sha> files=<n> lines=<n> age=<epoch>
#   SKIP:<label> already-in-base
#   SKIP:<label> conflicts-with-base <file,...>
#   SKIP:<label> parent-skipped:<parent>
#   CONFLICT:<a> <b> <file,...>        pairwise, would conflict when merged
#   OVERLAP:<a> <b> <file,...>         pairwise, same files touched
#   QUEUE:<i> <label> <sha> isolated|overlapping|stacked
#   PREDICTED_CONFLICTS:<n>
#
# THE ORDER, and why it is this one:
#   1. a stacked parent before its child — merging the child first would drag
#      the parent in under the child's name, and the parent's own row would then
#      be a lie;
#   2. then items that overlap nothing, because they cannot fail for a reason
#      that belongs to another item;
#   3. then the smallest overlapping item, so the first conflict is resolved
#      against the least other work;
#   4. then the oldest, so a PR that has waited goes first;
#   5. then the label, so the answer is deterministic.
#
# Exit codes: 0 = queue planned · 2 = usage, not a repo, an unresolvable ref, or
# a merge-tree that failed for a reason other than a conflict.
set -uo pipefail

die() { printf 'order_queue: %s\n' "$1" >&2; exit 2; }

BASE_NAME=""
N=0
NAFTER=0
NCREATED=0

# Arguments land straight in arrays rather than in space-joined strings: a label
# is arbitrary text, and re-splitting it later would break on a space and glob
# on a `*`.
while [ $# -gt 0 ]; do
  case "$1" in
    --base)      [ $# -ge 2 ] || die "--base needs a branch name"; BASE_NAME="$2"; shift 2 ;;
    --base=*)    BASE_NAME="${1#--base=}"; shift ;;
    --after)     [ $# -ge 2 ] || die "--after needs <child>:<parent>"
                 AFTER[$NAFTER]="$2"; NAFTER=$((NAFTER + 1)); shift 2 ;;
    --after=*)   AFTER[$NAFTER]="${1#--after=}"; NAFTER=$((NAFTER + 1)); shift ;;
    --created)   [ $# -ge 2 ] || die "--created needs <label>:<epoch>"
                 CREATED[$NCREATED]="$2"; NCREATED=$((NCREATED + 1)); shift 2 ;;
    --created=*) CREATED[$NCREATED]="${1#--created=}"; NCREATED=$((NCREATED + 1)); shift ;;
    -*)          die "unknown argument: $1" ;;
    *)
      case "$1" in
        *=*) : ;;
        *)   die "item must be <label>=<ref>: $1" ;;
      esac
      # A label becomes a ref path component (refs/integrate/pre/<label>) and a
      # merge-commit token downstream, so it is restricted here rather than
      # producing an unusable ref in the merge loop.
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
[ "$N" -gt 0 ] || die "no items given"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/order_queue.XXXXXX" 2>/dev/null)"
[ -n "$TMP" ] && [ -d "$TMP" ] || die "could not create a temp directory"
trap 'rm -rf "$TMP"' EXIT

# --- base -------------------------------------------------------------------
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

# --- items ------------------------------------------------------------------
# Parallel indexed arrays, not associative ones: tests/lib.sh pins bash 3.2.
i=0
while [ "$i" -lt "$N" ]; do
  sha="$(git rev-parse --verify --quiet "${REF[$i]}^{commit}" 2>/dev/null)"
  [ -n "$sha" ] || die "cannot resolve ref for ${LAB[$i]}: ${REF[$i]}"
  SHA[$i]="$sha"
  SKIP[$i]=""
  PARENT[$i]=-1
  i=$((i + 1))
done

# A duplicate label, or two labels on the same commit, makes the queue and the
# merge record ambiguous — and a same-commit pair is also a stack-edge cycle
# (each is an ancestor of the other), which no topological sort can drain.
i=0
while [ "$i" -lt "$N" ]; do
  j=$((i + 1))
  while [ "$j" -lt "$N" ]; do
    [ "${LAB[$i]}" = "${LAB[$j]}" ] && die "duplicate label: ${LAB[$i]}"
    [ "${SHA[$i]}" = "${SHA[$j]}" ] && \
      die "${LAB[$i]} and ${LAB[$j]} are the same commit: ${SHA[$i]}"
    j=$((j + 1))
  done
  i=$((i + 1))
done

index_of() {  # index_of <label> — prints the index, or nothing
  local k=0
  while [ "$k" -lt "$N" ]; do
    if [ "${LAB[$k]}" = "$1" ]; then printf '%s' "$k"; return 0; fi
    k=$((k + 1))
  done
  return 1
}

# --- already in base --------------------------------------------------------
i=0
while [ "$i" -lt "$N" ]; do
  if git merge-base --is-ancestor "${SHA[$i]}" "$BASE_SHA" 2>/dev/null; then
    SKIP[$i]="already-in-base"
  fi
  i=$((i + 1))
done

# --- stack parents ----------------------------------------------------------
# Explicit --after first: a parent force-pushed after its child was cut is no
# longer an ancestor, and ancestry alone would then miss the relation that
# GitHub still records in the child's base branch.
a=0
while [ "$a" -lt "$NAFTER" ]; do
  pair="${AFTER[$a]}"
  case "$pair" in
    *:*) : ;;
    *)   die "--after must be <child>:<parent>: $pair" ;;
  esac
  c="$(index_of "${pair%%:*}")" || die "--after names an unknown item: ${pair%%:*}"
  p="$(index_of "${pair#*:}")"  || die "--after names an unknown item: ${pair#*:}"
  [ "$c" = "$p" ] && die "--after names the same item twice: $pair"
  PARENT[$c]="$p"
  a=$((a + 1))
done

# Then ancestry: the NEAREST other item that is a proper ancestor, measured by
# distance from base, so a three-deep stack links child->middle, not child->root.
i=0
while [ "$i" -lt "$N" ]; do
  if [ "${PARENT[$i]}" -lt 0 ] && [ -z "${SKIP[$i]}" ]; then
    best=-1; bestdepth=-1
    j=0
    while [ "$j" -lt "$N" ]; do
      if [ "$j" != "$i" ] && [ -z "${SKIP[$j]}" ] \
         && git merge-base --is-ancestor "${SHA[$j]}" "${SHA[$i]}" 2>/dev/null; then
        depth="$(git rev-list --count "$BASE_SHA..${SHA[$j]}" 2>/dev/null)"
        depth="${depth:-0}"
        if [ "$depth" -gt "$bestdepth" ]; then bestdepth="$depth"; best="$j"; fi
      fi
      j=$((j + 1))
    done
    PARENT[$i]="$best"
  fi
  i=$((i + 1))
done

# A cycle can only come from --after (ancestry over distinct commits cannot make
# one, and two labels on the same commit was rejected above). It has to be caught
# here: a topological sort cannot drain a cycle, and every walk of the parent
# chain below would otherwise run forever or, worse, the items would simply never
# be queued — dropped with no QUEUE line and no SKIP line, which is precisely the
# silent omission this script exists to prevent.
i=0
while [ "$i" -lt "$N" ]; do
  p="${PARENT[$i]}"
  steps=0
  while [ "$p" -ge 0 ]; do
    steps=$((steps + 1))
    if [ "$steps" -gt "$N" ]; then
      die "--after describes a cycle, reached from ${LAB[$i]}"
    fi
    p="${PARENT[$p]}"
  done
  i=$((i + 1))
done

i=0
while [ "$i" -lt "$N" ]; do
  p="${PARENT[$i]}"
  if [ "$p" -ge 0 ]; then printf 'STACK:%s after %s\n' "${LAB[$i]}" "${LAB[$p]}"; fi
  i=$((i + 1))
done

# --- own range: files, lines, age -------------------------------------------
# A stacked item is measured against its parent, not against base: its parent's
# changes are merged first, so counting them again would make every child look
# large and overlapping, and would put the smallest real work last.
i=0
while [ "$i" -lt "$N" ]; do
  p="${PARENT[$i]}"
  if [ "$p" -ge 0 ]; then
    start="${SHA[$p]}"
  else
    start="$(git merge-base "$BASE_SHA" "${SHA[$i]}" 2>/dev/null)"
    [ -n "$start" ] || die "no merge base between $BASE_REF and ${LAB[$i]}"
  fi
  git diff --name-only "$start" "${SHA[$i]}" 2>/dev/null | LC_ALL=C sort >"$TMP/f.$i"
  FILES[$i]="$(wc -l <"$TMP/f.$i" | tr -d ' ')"
  # Binary files show "-" in numstat; they carry no line count, and arithmetic
  # on "-" would abort the whole run.
  LINES[$i]="$(git diff --numstat "$start" "${SHA[$i]}" 2>/dev/null \
    | awk '{ a = ($1 == "-" ? 0 : $1); d = ($2 == "-" ? 0 : $2); t += a + d } END { print t + 0 }')"
  age=""
  c=0
  while [ "$c" -lt "$NCREATED" ]; do
    pair="${CREATED[$c]}"
    if [ "${pair%%:*}" = "${LAB[$i]}" ]; then age="${pair#*:}"; fi
    c=$((c + 1))
  done
  if [ -z "$age" ]; then
    age="$(git log --format=%ct --reverse "$start..${SHA[$i]}" 2>/dev/null | head -1)"
  fi
  AGE[$i]="${age:-0}"
  printf 'ITEM:%s %s files=%s lines=%s age=%s\n' \
    "${LAB[$i]}" "${SHA[$i]}" "${FILES[$i]}" "${LINES[$i]}" "${AGE[$i]}"
  i=$((i + 1))
done

# --- conflicts with base ----------------------------------------------------
# merge_tree <a> <b> — writes conflicted paths to $TMP/mt and returns 0 clean,
# 1 conflicted. It dies on anything else: `git merge-tree` exits 1 both for a
# conflict and for a ref it cannot merge at all, so the empty-output case has to
# be told apart from a real conflict rather than reported as one.
merge_tree() {
  git merge-tree --write-tree --name-only --no-messages "$1" "$2" >"$TMP/mt.raw" 2>"$TMP/mt.err"
  local rc=$?
  tail -n +2 "$TMP/mt.raw" | sed '/^$/d' >"$TMP/mt"
  if [ "$rc" -eq 0 ]; then return 0; fi
  if [ "$rc" -eq 1 ] && [ -s "$TMP/mt" ]; then return 1; fi
  die "merge-tree failed for $1 and $2 (exit $rc): $(tr '\n' ' ' <"$TMP/mt.err")"
}

commalist() { tr '\n' ',' <"$1" | sed 's/,$//'; }

i=0
while [ "$i" -lt "$N" ]; do
  if [ -z "${SKIP[$i]}" ] && [ "${PARENT[$i]}" -lt 0 ]; then
    if ! merge_tree "$BASE_SHA" "${SHA[$i]}"; then
      SKIP[$i]="conflicts-with-base $(commalist "$TMP/mt")"
    fi
  fi
  i=$((i + 1))
done

# --- cascade the skips ------------------------------------------------------
# A child carries its parent's commits, so merging it would integrate a parent
# that was skipped — under the child's name, and with the parent's row still
# saying "skipped". Repeat to a fixpoint so grandchildren go too.
changed=1
while [ "$changed" -eq 1 ]; do
  changed=0
  i=0
  while [ "$i" -lt "$N" ]; do
    p="${PARENT[$i]}"
    if [ -z "${SKIP[$i]}" ] && [ "$p" -ge 0 ] && [ -n "${SKIP[$p]}" ]; then
      SKIP[$i]="parent-skipped:${LAB[$p]}"
      changed=1
    fi
    i=$((i + 1))
  done
done

i=0
while [ "$i" -lt "$N" ]; do
  if [ -n "${SKIP[$i]}" ]; then printf 'SKIP:%s %s\n' "${LAB[$i]}" "${SKIP[$i]}"; fi
  i=$((i + 1))
done

# --- the pairwise matrix ----------------------------------------------------
# Stack pairs are excluded: the descendant already contains the ancestor, so the
# merge is trivial and reporting it as "no conflict" would say nothing.
#
# The whole chain, not just the immediate parent. A grandchild's file list is
# measured against its own parent, so a file the grandparent also touched would
# otherwise show up as an OVERLAP between the two — which merge-tree can never
# turn into a conflict, and which would still flip both items out of the
# `isolated` class and reorder the queue for nothing.
in_same_stack() {  # in_same_stack <i> <j>
  local a="$1" b="$2" p
  p="${PARENT[$a]}"
  while [ "$p" -ge 0 ]; do
    [ "$p" = "$b" ] && return 0
    p="${PARENT[$p]}"
  done
  p="${PARENT[$b]}"
  while [ "$p" -ge 0 ]; do
    [ "$p" = "$a" ] && return 0
    p="${PARENT[$p]}"
  done
  return 1
}

CONFLICTS=0
i=0
while [ "$i" -lt "$N" ]; do OV[$i]=0; i=$((i + 1)); done

i=0
while [ "$i" -lt "$N" ]; do
  j=$((i + 1))
  while [ "$j" -lt "$N" ]; do
    if [ -z "${SKIP[$i]}" ] && [ -z "${SKIP[$j]}" ] && ! in_same_stack "$i" "$j"; then
      LC_ALL=C comm -12 "$TMP/f.$i" "$TMP/f.$j" >"$TMP/shared"
      if [ -s "$TMP/shared" ]; then
        OV[$i]=1; OV[$j]=1
        printf 'OVERLAP:%s %s %s\n' "${LAB[$i]}" "${LAB[$j]}" "$(commalist "$TMP/shared")"
      fi
      if ! merge_tree "${SHA[$i]}" "${SHA[$j]}"; then
        CONFLICTS=$((CONFLICTS + 1))
        printf 'CONFLICT:%s %s %s\n' "${LAB[$i]}" "${LAB[$j]}" "$(commalist "$TMP/mt")"
      fi
    fi
    j=$((j + 1))
  done
  i=$((i + 1))
done

# --- the queue --------------------------------------------------------------
# Kahn's algorithm over the stack edges, picking the least available item by
# (overlaps anything, its size when it does, age, label) at each step.
i=0
while [ "$i" -lt "$N" ]; do PLACED[$i]=0; i=$((i + 1)); done

pos=0
remaining=1
while [ "$remaining" -eq 1 ]; do
  remaining=0
  pick=-1
  i=0
  while [ "$i" -lt "$N" ]; do
    if [ -z "${SKIP[$i]}" ] && [ "${PLACED[$i]}" -eq 0 ]; then
      p="${PARENT[$i]}"
      if [ "$p" -lt 0 ] || [ "${PLACED[$p]}" -eq 1 ]; then
        remaining=1
        if [ "$pick" -lt 0 ]; then
          pick="$i"
        else
          # (ov, ov ? lines : 0, age, label), first difference wins.
          a_ov="${OV[$i]}";    b_ov="${OV[$pick]}"
          a_sz=0; b_sz=0
          [ "$a_ov" -eq 1 ] && a_sz="${LINES[$i]}"
          [ "$b_ov" -eq 1 ] && b_sz="${LINES[$pick]}"
          if   [ "$a_ov" -lt "$b_ov" ]; then pick="$i"
          elif [ "$a_ov" -eq "$b_ov" ] && [ "$a_sz" -lt "$b_sz" ]; then pick="$i"
          elif [ "$a_ov" -eq "$b_ov" ] && [ "$a_sz" -eq "$b_sz" ] \
            && [ "${AGE[$i]}" -lt "${AGE[$pick]}" ]; then pick="$i"
          elif [ "$a_ov" -eq "$b_ov" ] && [ "$a_sz" -eq "$b_sz" ] \
            && [ "${AGE[$i]}" -eq "${AGE[$pick]}" ] \
            && [ "${LAB[$i]}" \< "${LAB[$pick]}" ]; then pick="$i"
          fi
        fi
      fi
    fi
    i=$((i + 1))
  done
  if [ "$pick" -ge 0 ]; then
    PLACED[$pick]=1
    pos=$((pos + 1))
    kind=isolated
    [ "${OV[$pick]}" -eq 1 ] && kind=overlapping
    [ "${PARENT[$pick]}" -ge 0 ] && kind=stacked
    printf 'QUEUE:%s %s %s %s\n' "$pos" "${LAB[$pick]}" "${SHA[$pick]}" "$kind"
  else
    remaining=0
  fi
done

# Belt and braces on the cycle guard above: every item is either queued or
# skipped with a reason, and an item that is neither must be an error rather than
# an omission. A dropped item never reaches the checkpoint, the PR body's
# `## Skipped`, or anyone's attention.
i=0
while [ "$i" -lt "$N" ]; do
  if [ -z "${SKIP[$i]}" ] && [ "${PLACED[$i]}" -eq 0 ]; then
    die "${LAB[$i]} could not be queued and was not skipped — the stack edges do not sort"
  fi
  i=$((i + 1))
done

printf 'PREDICTED_CONFLICTS:%s\n' "$CONFLICTS"
exit 0
