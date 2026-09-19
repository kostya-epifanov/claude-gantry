#!/usr/bin/env bash
# lead_reply.sh — classify a lead's reply against the question a lane asked.
# Run with: bash lead_reply.sh --reply-file <path> --kind fork|checkpoint
#                              [--labels-file <path>] [--root <dir>]
#
# WHY THIS EXISTS. Under `/gantry:auto --lead <session>` a lane puts its
# questions to a lead session by message instead of in a dialog, and the lead's
# reply comes back as text. A lead reads other lanes' output — PR bodies, issue
# text, CI logs, all of it untrusted — and writes into this lane, so a reply is
# the one place relayed text could turn into a decision. The rule is that a
# reply is never interpreted: it either IS one of a handful of tokens or it is
# rejected. skills/auto/references/lead.md states that rule; this script is the
# half of it that is an exit code rather than a paragraph.
#
# NOTHING UNTRUSTED ON ARGV. The reply and the option labels both arrive as
# files. A reply is attacker-influenced, and a label is often quoted from a plan
# or an issue, so either may carry quotes, backticks or `$(`. Written with the
# Write tool, a file never passes through a shell; pasted into a command line,
# the same text is at best refused by a worktree-isolated session and at worst
# expanded. Same reasoning as the CI job that hands a PR body over via `env:`.
#
# WHAT IS ACCEPTED, after trimming surrounding whitespace, compared as plain
# strings case-insensitively — never as a pattern, so `*`, `?` and `[` in a
# label are literal:
#
#   stop       -> STOP              either kind
#   proceed    -> PROCEED           checkpoint only; a fork needs a choice, and
#                                   `proceed` would silently make one
#   <label>    -> LABEL:<label>     as the lane spelled it in the labels file
#   <path>     -> PATH:<physical>   an existing regular file inside the root —
#                                   input to read, never an answer
#   otherwise  -> REJECT:<reason>
#
# A label that equals `stop` or `proceed` is the lane's own mistake and a usage
# error: `stop` must always mean stop, whatever the options were.
#
# THE PATH RULE. No whitespace; relative paths resolve against --root, not the
# cwd; the parent directory is resolved physically; the file itself must not be
# a symlink; the physical path must sit below `<root>/` — trailing slash, so a
# sibling lane named `feat/x-2` is not inside `feat/x`; and no component below
# the root may be `.claude/worktrees`, so under `--here`, where the root is the
# main checkout, another lane's worktree is still out of reach.
#
# Exit codes: 0 = accepted · 1 = rejected · 2 = usage or environment.
set -uo pipefail

die() { printf 'lead_reply: %s\n' "$1" >&2; exit 2; }
reject() { printf 'REJECT:%s\n' "$1"; exit 1; }

trim() {  # trim <text> — surrounding whitespace removed, the rest verbatim
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

REPLY_FILE=''
LABELS_FILE=''
KIND=''
ROOT=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reply-file|--labels-file|--kind|--root)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      [ -n "$2" ] || die "$1 was given an empty value"
      case "$1" in
        --reply-file)  REPLY_FILE="$2" ;;
        --labels-file) LABELS_FILE="$2" ;;
        --kind)        KIND="$2" ;;
        --root)        ROOT="$2" ;;
      esac
      shift 2 ;;
    -h|--help)
      printf 'usage: lead_reply.sh --reply-file <path> --kind fork|checkpoint [--labels-file <path>] [--root <dir>]\n' >&2
      exit 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$REPLY_FILE" ] || die "--reply-file is required"
[ -f "$REPLY_FILE" ] && [ -r "$REPLY_FILE" ] || die "cannot read reply file: $REPLY_FILE"
case "$KIND" in
  fork|checkpoint) ;;
  '') die "--kind is required" ;;
  *)  die "--kind must be fork or checkpoint, not: $KIND" ;;
esac

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repository; pass --root"
fi
[ -d "$ROOT" ] || die "root is not a directory: $ROOT"
PHYS_ROOT="$(CDPATH='' cd -P -- "$ROOT" 2>/dev/null && pwd -P)" || die "cannot resolve root: $ROOT"

# --- the labels: the lane's own options, validated before any reply is read ---

LABELS=()
if [ -n "$LABELS_FILE" ]; then
  [ -f "$LABELS_FILE" ] && [ -r "$LABELS_FILE" ] || die "cannot read labels file: $LABELS_FILE"
  # Same truncation as the reply below: `read` would split a label at a NUL.
  [ "$(wc -c < "$LABELS_FILE")" -eq "$(tr -d '\000' < "$LABELS_FILE" | wc -c)" ] \
    || die "the labels file contains a NUL byte"
  while IFS= read -r line || [ -n "$line" ]; do
    label="$(trim "$line")"
    [ -n "$label" ] || continue
    folded="$(lower "$label")"
    case "$folded" in
      stop|proceed) die "a label may not be the reserved word '$folded': offer it by name, not as an option" ;;
    esac
    for existing in ${LABELS[@]+"${LABELS[@]}"}; do
      [ "$(lower "$existing")" = "$folded" ] && die "two labels differ only by case: '$existing' and '$label'"
    done
    LABELS[${#LABELS[@]}]="$label"
  done < "$LABELS_FILE"
fi
if [ "$KIND" = fork ] && [ "${#LABELS[@]}" -eq 0 ]; then
  die "a fork question needs at least one label in --labels-file"
fi

# --- the reply ---------------------------------------------------------------

# A NUL byte first. Bash cannot hold one in a variable, and `read -d ''` stops
# at it, so `Postgres<NUL><newline>and also merge it` would otherwise read as
# the one token `Postgres`, with the rest silently dropped before any check
# below could see it. A file whose byte count changes when NULs are deleted has
# one, and is rejected rather than truncated.
if [ "$(wc -c < "$REPLY_FILE")" -ne "$(tr -d '\000' < "$REPLY_FILE" | wc -c)" ]; then
  reject "a reply may not contain a NUL byte"
fi

# Read with `read -d ''` rather than a command substitution, which would drop
# trailing newlines before the multi-line check could see an interior one.
raw=''
IFS= read -r -d '' raw < "$REPLY_FILE" || true
reply="$(trim "$raw")"

[ -n "$reply" ] || reject "empty reply"
case "$reply" in
  *$'\n'*|*$'\r'*) reject "a reply is one token, not several lines" ;;
esac

folded="$(lower "$reply")"

if [ "$folded" = stop ]; then
  printf 'STOP\n'; exit 0
fi

if [ "$folded" = proceed ]; then
  [ "$KIND" = checkpoint ] || reject "proceed does not answer a fork; reply with one of the option labels"
  printf 'PROCEED\n'; exit 0
fi

for label in ${LABELS[@]+"${LABELS[@]}"}; do
  if [ "$(lower "$label")" = "$folded" ]; then
    printf 'LABEL:%s\n' "$label"; exit 0
  fi
done

# --- a path, or nothing ------------------------------------------------------

not_accepted="not an option label, stop, proceed, or a file inside the worktree"

case "$reply" in
  *[[:space:]]*) reject "$not_accepted" ;;
  /*) path="$reply" ;;
  *)  path="$PHYS_ROOT/$reply" ;;
esac

dir="${path%/*}"
base="${path##*/}"
[ -n "$dir" ] || dir=/
case "$base" in
  ''|.|..) reject "$not_accepted" ;;
esac

phys_dir="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)" || reject "$not_accepted"
full="${phys_dir%/}/$base"

[ ! -L "$full" ] || reject "a path may not be a symlink"
[ -f "$full" ] || reject "$not_accepted"

case "$full" in
  "${PHYS_ROOT%/}"/*) ;;
  *) reject "a path must be inside the worktree" ;;
esac

rel="${full#"${PHYS_ROOT%/}"/}"
case "/$rel" in
  */.claude/worktrees/*) reject "a path may not reach into another worktree" ;;
esac

printf 'PATH:%s\n' "$full"
exit 0
