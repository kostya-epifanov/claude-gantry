#!/usr/bin/env bash
# ensure_excluded.sh — make each pattern appear EXACTLY ONCE in the git exclude
# file, safely when several worktrees do it at the same time.
# Run with: bash ensure_excluded.sh [--file <path>] <pattern> [<pattern>...]
#
# WHY THIS EXISTS. The orchestrator used to append its exclusions with a
# read-then-append:
#
#     grep -q X .git/info/exclude || echo X >> .git/info/exclude
#
# Six parallel worktree lanes interleave the read and the write, and one lane
# was observed leaving double-appended entries. The compound form is also a
# shape a worktree-isolated session refuses to run at all, so the fix has to be
# a single command with no substitution in the caller's argv — that is, a
# script.
#
# WHY NOT THE WORKTREE'S OWN GIT DIR. A linked worktree does have its own git
# directory, so `$(git rev-parse --git-dir)/info/exclude` looks like a way to
# give each lane a private file and dodge the race entirely. It is not: git maps
# `info/` into the COMMON directory, so that path is one git never reads.
# Verified — `git rev-parse --git-path info/exclude` from inside a linked
# worktree resolves to the main repository's file, and a pattern written to the
# per-worktree path leaves `git status` still reporting the file as untracked.
# Hence this script asks git for the path rather than constructing one, and
# solves the race with a lock instead of with isolation.
#
# Existing duplicates of the patterns it manages are collapsed, so a file a
# previous racing writer already corrupted is repaired rather than preserved.
# Lines it was not asked about are left exactly as found, in their original
# order.
#
# LIMITS. The lock relies on two things POSIX does not guarantee: `sleep` taking
# a fractional argument, and `find -mmin` for the staleness probe. Both hold on
# GNU coreutils, BSD/macOS and busybox, but they are verified here only on
# Darwin — CI exercises the Linux side through the stale-lock assertion in
# tests/cases/journal_append.sh, so a regression surfaces there rather than
# silently disabling the break. `mkdir` itself, which is the actual mutual
# exclusion, is POSIX-atomic everywhere.
#
# Exit codes: 0 = each pattern present exactly once · 2 = usage or environment
# · 130/143 = interrupted or terminated, having written nothing.
set -uo pipefail

die() { printf 'ensure_excluded: %s\n' "$1" >&2; exit 2; }

FILE=''
FILE_GIVEN=0
PATTERNS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      [ "$#" -ge 2 ] || die "--file requires a value"
      # An explicit empty value must not read as "not given": that would fall
      # through to the default and write to the repository's real shared
      # exclude file while the caller believed it had redirected the write.
      [ -n "$2" ] || die "--file was given an empty value"
      FILE="$2"; FILE_GIVEN=1; shift 2 ;;
    -h|--help)
      printf 'usage: ensure_excluded.sh [--file <path>] <pattern> [<pattern>...]\n' >&2
      exit 2 ;;
    --*) die "unknown argument: $1" ;;
    # An empty pattern would match every blank line in the file and collapse
    # them, silently rewriting lines the caller never asked about — which
    # breaks this script's one promise about unrelated content.
    '') die "an empty pattern is not allowed" ;;
    *) PATTERNS[${#PATTERNS[@]}]="$1"; shift ;;
  esac
done

[ "${#PATTERNS[@]}" -gt 0 ] || die "at least one pattern is required"

if [ "$FILE_GIVEN" -eq 0 ]; then
  # Ask git where the file is. In a linked worktree this correctly yields the
  # main repository's copy; see the note above about why that is the right
  # answer rather than a bug.
  FILE="$(git rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" \
    || die "not inside a git repository; pass --file to say which exclude file to write"
  [ -n "$FILE" ] || die "git could not resolve info/exclude; pass --file"
fi

mkdir -p "$(dirname "$FILE")" || die "could not create the directory holding $FILE"
[ -e "$FILE" ] || : >> "$FILE" || die "could not create $FILE"

# --- lock --------------------------------------------------------------------
#
# `mkdir` is atomic on every POSIX filesystem and, unlike flock, is present on
# stock macOS. The trap is SINGLE-quoted so $LOCK is expanded when the trap
# fires rather than when it is installed (shellcheck SC2064).

LOCK="$FILE.lock"
BREAKER="$FILE.lock.breaking"
TMP="$FILE.tmp.$$"
HELD=0
BREAKER_HELD=0
STALE_MINUTES=1
TRIES=50

release() {
  if [ "$HELD" -eq 1 ]; then rmdir "$LOCK" 2>/dev/null; HELD=0; fi
  if [ "$BREAKER_HELD" -eq 1 ]; then rmdir "$BREAKER" 2>/dev/null; BREAKER_HELD=0; fi
  rm -f "$TMP" 2>/dev/null
}

# The signal handlers EXIT. A handler that only released would let the script
# resume the rewrite *unlocked* and still `mv` over $FILE — a terminated lane
# would free the lock, let a second lane read the pre-rewrite file, and then
# land its own stale copy on top, erasing the other's entry. Releasing while
# still writing is worse than holding.
trap 'release' EXIT
trap 'release; exit 130' INT
trap 'release; exit 143' TERM

# A lane killed between mkdir and rmdir leaves the directory forever. Without a
# break, every later run burns its full budget and falls through to the unlocked
# path — so under exactly the conditions the lock exists for, all lanes would
# proceed unlocked at once and the lost update would return.
break_if_stale() {
  [ -d "$LOCK" ] || return 1
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$STALE_MINUTES" 2>/dev/null)" ] || return 1
  # Only one lane may break a given lock. Two that both saw it as stale would
  # otherwise rmdir each other's *fresh* lock and both believe they held it —
  # the classic break-stale race, which reopens lost updates under precisely
  # the conditions the break exists for.
  mkdir "$BREAKER" 2>/dev/null || return 1
  BREAKER_HELD=1
  # Re-check under the breaker: the holder may have finished while we waited.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$STALE_MINUTES" 2>/dev/null)" ]; then
    printf 'ensure_excluded: breaking a stale lock (%s)\n' "$LOCK" >&2
    rmdir "$LOCK" 2>/dev/null
  fi
  rmdir "$BREAKER" 2>/dev/null
  BREAKER_HELD=0
  return 0
}

acquire() {
  local i=0
  while [ "$i" -lt "$TRIES" ]; do
    if mkdir "$LOCK" 2>/dev/null; then HELD=1; return 0; fi
    # Probed on every failed attempt rather than only after the whole budget:
    # it breaks nothing younger than $STALE_MINUTES either way, so it is no less
    # safe, and a wedged lane recovers in well under a second instead of ten.
    if break_if_stale && mkdir "$LOCK" 2>/dev/null; then HELD=1; return 0; fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

if ! acquire; then
  # Never hang a headless run. A missed exclusion is recoverable; a wedged lane
  # is not — so say so loudly and carry on.
  printf 'ensure_excluded: could not take %s; proceeding unlocked\n' "$LOCK" >&2
fi

# --- rewrite -----------------------------------------------------------------
#
# One pass: copy every line through, dropping a managed pattern after its first
# occurrence, then append the managed patterns that never appeared. Written to a
# temp file and renamed, so a reader never sees a half-written file.
#
# SEEN is a delimited string rather than a set: bash 3.2, the floor tests/lib.sh
# pins, has no associative arrays. Patterns cannot contain a newline (a git
# exclude entry is one line), so a newline is a safe delimiter.

SEEN=''
NL='
'

is_managed() {
  local p
  for p in "${PATTERNS[@]}"; do
    [ "$1" = "$p" ] && return 0
  done
  return 1
}

seen_already() { case "$NL$SEEN" in *"$NL$1$NL"*) return 0 ;; *) return 1 ;; esac; }

: > "$TMP" || die "could not write $TMP"

line=''
while IFS= read -r line || [ -n "$line" ]; do
  if is_managed "$line"; then
    if seen_already "$line"; then
      continue                       # a duplicate a racing writer left behind
    fi
    SEEN="$SEEN$line$NL"
  fi
  printf '%s\n' "$line" >> "$TMP"
done < "$FILE"

added=''
for p in "${PATTERNS[@]}"; do
  if ! seen_already "$p"; then
    printf '%s\n' "$p" >> "$TMP"
    SEEN="$SEEN$p$NL"
    added="$added $p"
  fi
done

mv "$TMP" "$FILE" || die "could not replace $FILE"
release

if [ -n "$added" ]; then
  printf 'ensure_excluded: added to %s:%s\n' "$FILE" "$added"
fi
