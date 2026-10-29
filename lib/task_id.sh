#!/usr/bin/env bash
# task_id.sh — find the tracker id a run carries, and the branch it was told to use.
# Run with: bash task_id.sh [--args-file <path>] [--task-file <path>]
#
# WHY THIS EXISTS. When a task comes from a tracker — Linear `BASE-71`, a GitHub
# issue, a Jira key — that id wants to be the spine of the run: in the branch
# and worktree name, in `task.md`'s `id:`, on the journal's `task` field, and at
# the front of the PR title so the tracker links the PR to the issue. The
# drivers read their own flags as prose, and prose is the wrong place for the
# one piece that has to be exact, so the id and the explicit branch come from
# here and the rest of the argument string stays the driver's to read.
# skills/auto/references/orchestration.md § "Deriving the branch name" states
# the rule; this script is the half of it that is an exit code.
#
# NOTHING UNTRUSTED ON ARGV. The argument string arrives as a file, the same way
# lib/lead_reply.sh takes a reply: a task description may carry quotes,
# backticks or `$(`, which a worktree-isolated session refuses on a command
# line and a shell might expand. Written with the Write tool, a file never
# passes through a shell.
#
# SOURCES, first hit wins:
#
#   1. `--task <id>`, given before the task text.
#   2. The first token of the task text — skipping the drivers' own flags and
#      their values — with one trailing `:` tolerated: `BASE-71 fix the docs`,
#      `--no-pr BASE-71: fix the docs`.
#   3. The first tracker URL in the string: a GitHub issue becomes `GH-<n>`,
#      a Linear issue and a Jira `/browse/` link give their key. The key stops
#      at `/`, `?`, `#` or whitespace, so a copied link with a title slug or a
#      comment anchor still works.
#   4. The `id:` line of `--task-file` — a re-run in the lane, or `ship`
#      composing the PR — when its value is a tracker id. A date-slug id is
#      reported as no id. The file is never looked up in the cwd: at stage 1 a
#      driver runs from the main checkout, and a `task.md` left there belongs
#      to some other task.
#
# A tracker id is `[A-Z][A-Z0-9_]*-[0-9]+`, at most 32 characters, kept exactly
# as written. The key is uppercase on purpose: `utf-8`, `covid-19` and
# `sha-256` are ordinary words in a task description, not issues.
#
# FLAGS COME FIRST. `--task` and `--branch` are read as flags only in the run
# of flags BEFORE the first word of the task; from that word on, every token is
# task text, so "explain why --branch wins over --here" keeps all its words and
# names no branch. A task description for this very repo names these flags in
# prose all the time, and a script with no context must not act on them. A
# `--branch` or `--task` the driver meant as a flag but typed after the task is
# still in `TEXT:`, where the driver can see it.
#
# OUTPUT, always these four lines:
#
#   ID:<id>          or ID:-           the tracker id, or none
#   SOURCE:<which>   or SOURCE:-       flag | text | url | task.md
#   BRANCH:<name>    or BRANCH:-       the `--branch` value, verbatim
#   TEXT:<string>                      the argument string on one line, with
#                                      `--task <id>`, `--branch <name>` and a
#                                      leading id removed; every other flag
#                                      left in place for the driver to read
#
# Exit codes: 0 = parsed (a missing id is not an error) · 2 = usage, an
# unreadable file, or a leading `--task`/`--branch` that is repeated or has a
# missing or bad value.
set -uo pipefail
# The id pattern is ASCII by definition; a locale must not widen `[A-Z]`.
export LC_ALL=C

die() { printf 'task_id: %s\n' "$1" >&2; exit 2; }

ID_RE='^[A-Z][A-Z0-9_]*-[0-9]+$'
ID_MAX=32
# Each URL is anchored at both ends of the part that matters: the host may be
# preceded only by a scheme or a word boundary, and the key or number ends at
# `/`, `?`, `#`, whitespace or the end, so `issues/71abc` is not issue 71 and
# `notgithub.com` is not GitHub.
URL_END='(/|[?#]|[[:space:]]|$)'
URL_GITHUB="(^|[^A-Za-z0-9.-])github\.com/[^/[:space:]]+/[^/[:space:]]+/issues/([0-9]+)$URL_END"
URL_LINEAR="(^|[^A-Za-z0-9.-])linear\.app/[^/[:space:]]+/issue/([A-Z][A-Z0-9_]*-[0-9]+)$URL_END"
URL_JIRA="(^|[^A-Za-z0-9.-])[^[:space:]]*/browse/([A-Z][A-Z0-9_]*-[0-9]+)$URL_END"

is_id() {  # is_id <token>
  [ "${#1}" -le "$ID_MAX" ] && [[ "$1" =~ $ID_RE ]]
}

trim() {  # trim <text> — surrounding whitespace removed, the rest verbatim
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ARGS_FILE=''
TASK_FILE=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --args-file|--task-file)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      [ -n "$2" ] || die "$1 was given an empty value"
      case "$1" in
        --args-file) ARGS_FILE="$2" ;;
        --task-file) TASK_FILE="$2" ;;
      esac
      shift 2 ;;
    -h|--help)
      printf 'usage: task_id.sh [--args-file <path>] [--task-file <path>]\n' >&2
      exit 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$ARGS_FILE" ] || [ -n "$TASK_FILE" ] || die "one of --args-file or --task-file is required"

ID=''
SOURCE=''
BRANCH=''
FLAG_ID=''
TEXT_ID=''
URL_ID=''
FILE_ID=''
TEXT=''

# --- the argument string ------------------------------------------------------

if [ -n "$ARGS_FILE" ]; then
  [ -f "$ARGS_FILE" ] && [ -r "$ARGS_FILE" ] || die "cannot read args file: $ARGS_FILE"
  # Bash cannot hold a NUL in a variable; refuse rather than truncate.
  [ "$(wc -c < "$ARGS_FILE")" -eq "$(tr -d '\000' < "$ARGS_FILE" | wc -c)" ] \
    || die "the args file contains a NUL byte"

  raw=''
  IFS= read -r -d '' raw < "$ARGS_FILE" || true
  # A CRLF file would leave `\r` glued to the last token of every line.
  raw="${raw//$'\r'/ }"

  # Split on whitespace into words. `set -f` so a `*` in the task text is a
  # word and not a glob; restored right after.
  set -f
  # shellcheck disable=SC2086  # unquoted on purpose: this is the split
  set -- $raw
  set +f

  kept=()
  seen_text=0
  while [ "$#" -gt 0 ]; do
    tok="$1"
    if [ "$seen_text" -eq 0 ]; then
      case "$tok" in
        --task)
          [ "$#" -ge 2 ] || die "--task requires a value"
          case "$2" in --*|'') die "--task requires a value" ;; esac
          [ -z "$FLAG_ID" ] || die "--task was given twice"
          cand="${2%:}"
          is_id "$cand" || die "--task is not a tracker id: $2"
          FLAG_ID="$cand"
          shift 2; continue ;;
        --branch)
          [ "$#" -ge 2 ] || die "--branch requires a value"
          case "$2" in --*|'') die "--branch requires a value" ;; esac
          [ -z "$BRANCH" ] || die "--branch was given twice"
          BRANCH="$2"
          shift 2; continue ;;
        --base|--lead|--review-model|--review-effort)
          # A driver flag with a value: both stay in the text, neither is the id.
          kept[${#kept[@]}]="$tok"
          if [ "$#" -ge 2 ]; then kept[${#kept[@]}]="$2"; shift 2; else shift; fi
          continue ;;
        --*)
          # Any other flag, known (--no-pr, --here, --on-current) or not: kept,
          # not an id candidate, and not assumed to take a value.
          kept[${#kept[@]}]="$tok"
          shift; continue ;;
      esac
      # The first word of the task. From here on everything is text.
      seen_text=1
      cand="${tok%:}"
      if is_id "$cand"; then
        TEXT_ID="$cand"
        shift; continue
      fi
    fi
    kept[${#kept[@]}]="$tok"
    shift
  done

  # Source 3 is read from the whole string, flags included, because a URL is
  # a URL wherever it sits.
  if [[ "$raw" =~ $URL_GITHUB ]]; then
    URL_ID="GH-${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ $URL_LINEAR ]]; then
    URL_ID="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ $URL_JIRA ]]; then
    URL_ID="${BASH_REMATCH[2]}"
  fi
  # The same cap as every other source; a URL is not a way around it.
  if [ -n "$URL_ID" ] && ! is_id "$URL_ID"; then URL_ID=''; fi

  TEXT="${kept[*]+"${kept[*]}"}"
fi

# --- the task file ------------------------------------------------------------

if [ -n "$TASK_FILE" ]; then
  [ -f "$TASK_FILE" ] && [ -r "$TASK_FILE" ] || die "cannot read task file: $TASK_FILE"
  line="$(grep -m1 -E '^id:' "$TASK_FILE" 2>/dev/null || true)"
  if [ -n "$line" ]; then
    val="${line#id:}"
    val="${val%%#*}"
    val="$(trim "$val")"
    if is_id "$val"; then FILE_ID="$val"; fi
  fi
fi

# --- decide --------------------------------------------------------------------

if   [ -n "$FLAG_ID" ]; then ID="$FLAG_ID"; SOURCE=flag
elif [ -n "$TEXT_ID" ]; then ID="$TEXT_ID"; SOURCE=text
elif [ -n "$URL_ID" ];  then ID="$URL_ID";  SOURCE=url
elif [ -n "$FILE_ID" ]; then ID="$FILE_ID"; SOURCE=task.md
fi

printf 'ID:%s\n'     "${ID:--}"
printf 'SOURCE:%s\n' "${SOURCE:--}"
printf 'BRANCH:%s\n' "${BRANCH:--}"
printf 'TEXT:%s\n'   "$TEXT"
exit 0
