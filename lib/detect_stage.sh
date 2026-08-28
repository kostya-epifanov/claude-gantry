#!/usr/bin/env bash
# detect_stage.sh — read-only snapshot of where a task sits on the gantry chain
# (plan -> grill -> implement -> review -> ship), for every phase skill.
#
# Why this exists: the phase skills are individually invocable, so you can drop
# out of the chain, edit by hand, and come back. That means no phase may infer
# where it is from the conversation — a fresh session, a subagent, and a
# resumed one must all reach the same answer. They reach it here.
#
# Read-only: runs `git` queries and reads two files. Modifies nothing.
# Run with: bash detect_stage.sh   (from anywhere inside the target repo/worktree)
#
# stdout — labeled lines, then one PHASE line:
#   ROOT:<path>                repo/worktree root; artifacts are read from here
#   BRANCH:<name>              or  DETACHED
#   TASK:present|absent        task.md at ROOT
#   PLAN:present|absent        plan.md at ROOT
#   HANDOVER:present|absent    handover.md at ROOT
#   STATUS:<value>|none        task.md frontmatter status:
#   GATES:present|absent       .claude/gates.sh — the readiness hook's opt-in
#   HOOK:armed|inert           GATES present AND STATUS is exactly implementing
#   DIRTY:clean                or  DIRTY:staged=<n> unstaged=<n> untracked=<n>
#   NEXT:<command>             the phase skill that advances from here
#   PHASE:<plan|grill|implement|review|ship|done|blocked|not-a-repo>
#
# PHASE is derived from STATUS when task.md carries a known one, and inferred
# from which artifacts exist when it does not — a hand-written task.md with no
# status, or none at all, still resolves rather than erroring.
set -uo pipefail

[ $# -eq 0 ] || { echo "detect_stage: takes no arguments" >&2; exit 2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "PHASE:not-a-repo"; exit 0; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$ROOT" ] || { echo "PHASE:not-a-repo"; exit 0; }
echo "ROOT:$ROOT"

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
if [ -z "$BRANCH" ]; then echo "DETACHED"; else echo "BRANCH:$BRANCH"; fi

# --- frontmatter status (task.md's leading --- block only) ------------------
# KEPT BYTE-IDENTICAL to frontmatter_status() in hooks/readiness-gate.sh. The
# hook decides whether to BLOCK a stop on this field; this script decides which
# phase to report. If the two ever disagreed, a run could look "implementing"
# to one and not the other, and the gate would silently stop arming. They are
# duplicated rather than sourced so the hook keeps no runtime dependency it
# could fail to resolve — and scripts/verify.sh diffs the two copies, so the
# duplication cannot drift unnoticed.
frontmatter_status() {
  local f="$1"
  [ -f "$f" ] || return 0
  # Strip a leading UTF-8 BOM before awk ever sees the file (byte-literal
  # match via ANSI-C quoting, portable across BSD/GNU sed — no \xNN escape
  # syntax needed). LC_ALL=C keeps this a byte match regardless of locale.
  local bom
  bom=$'\xef\xbb\xbf'
  local raw
  raw="$(LC_ALL=C sed "1s/^${bom}//" "$f" 2>/dev/null | awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      sub(/\r$/, "", s)
      return s
    }
    !started {
      if ($0 ~ /^[[:space:]]*\r?$/) { next }        # skip leading blank lines
      started = 1
      if ($0 ~ /^---[[:space:]]*\r?$/) { infm = 1; next }
      exit                                          # no frontmatter block at all
    }
    infm && $0 ~ /^---[[:space:]]*\r?$/ { closed = 1; exit }
    infm && !done && $0 ~ /^status:/ {
      val = $0
      sub(/^status:[[:space:]]*/, "", val)
      sub(/[[:space:]]+#.*$/, "", val)              # trailing "# comment"
      result = trim(val)
      done = 1
    }
    # Print only if the frontmatter block actually closed — an unterminated
    # fence must not fall through into scanning the body for a status: line.
    END { if (closed && done) print result }
  ' 2>/dev/null)"
  # Strip one layer of surrounding matching quotes (single or double).
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  printf '%s' "$raw"
}

# --- artifacts --------------------------------------------------------------
present_or_absent() { [ -f "$1" ] && echo present || echo absent; }

TASK="$(present_or_absent "$ROOT/task.md")"
PLAN="$(present_or_absent "$ROOT/plan.md")"
HANDOVER="$(present_or_absent "$ROOT/handover.md")"
GATES="$(present_or_absent "$ROOT/.claude/gates.sh")"
echo "TASK:$TASK"
echo "PLAN:$PLAN"
echo "HANDOVER:$HANDOVER"

STATUS="$(frontmatter_status "$ROOT/task.md")"
echo "STATUS:${STATUS:-none}"
echo "GATES:$GATES"

# The hook's firing condition, reported so a skill can say plainly whether the
# gate is actually enforced on this run rather than implying that it is.
if [ "$GATES" = present ] && [ "$STATUS" = implementing ]; then
  echo "HOOK:armed"
else
  echo "HOOK:inert"
fi

# --- working-tree state -----------------------------------------------------
STAGED=0; UNSTAGED=0; UNTRACKED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  x="${line:0:1}"; y="${line:1:1}"
  if [ "$x$y" = "??" ]; then UNTRACKED=$((UNTRACKED+1)); continue; fi
  [ "$x" != " " ] && STAGED=$((STAGED+1))
  [ "$y" != " " ] && UNSTAGED=$((UNSTAGED+1))
done < <(git status --porcelain 2>/dev/null)
DIRTY_TOTAL=$((STAGED+UNSTAGED+UNTRACKED))
if [ "$DIRTY_TOTAL" -eq 0 ]; then echo "DIRTY:clean"; else echo "DIRTY:staged=$STAGED unstaged=$UNSTAGED untracked=$UNTRACKED"; fi

# --- decide the phase -------------------------------------------------------
# Known status wins: it is what the phase skills write, and it survives a
# session boundary. Fall back to artifact inference only when it is missing or
# unrecognised, so a hand-written or half-edited task.md still lands somewhere
# sensible instead of erroring.
case "$STATUS" in
  planning)     PHASE=plan ;;
  planned)      PHASE=grill ;;
  grilled)      PHASE=implement ;;
  implementing) PHASE=implement ;;   # resume: the gate has not gone green yet
  implemented)  PHASE=review ;;
  reviewed)     PHASE=ship ;;
  shipped)      PHASE="done" ;;
  blocked)      PHASE=blocked ;;
  *)
    if [ "$PLAN" = present ]; then
      # A plan exists but nothing recorded a status — assume it has not been
      # carried out. Re-implementing is recoverable; skipping is not.
      PHASE=implement
    else
      PHASE=plan
    fi
    ;;
esac

case "$PHASE" in
  plan)      NEXT="/gantry:plan" ;;
  grill)     NEXT="/gantry:grill" ;;
  implement) NEXT="/gantry:implement" ;;
  review)    NEXT="/gantry:review" ;;
  ship)      NEXT="/gantry:ship" ;;
  "done")    NEXT="none — already shipped" ;;
  blocked)   NEXT="none — task.md says blocked; read it before continuing" ;;
  *)         NEXT="/gantry:plan" ;;
esac

echo "NEXT:$NEXT"
echo "PHASE:$PHASE"
