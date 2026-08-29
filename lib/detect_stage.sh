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
#   FORKS:open|none|unknown|absent
#                              whether task.md's "Open questions" section still holds a fork
#                              nobody has decided. See open_questions_forks() for the rules.
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

# --- open questions (the fork precondition) ---------------------------------
# Reports whether task.md's "Open questions" section still holds a fork nobody
# has decided. A fork left open there is a decision the implementer would end
# up making alone, so the phase skills refuse to advance past it — which means
# this answer has to be a fact rather than a reading, and the rules have to be
# written down rather than inferred:
#
#   heading      an ATX heading at any level whose text is "Open questions",
#                matched case-insensitively and tolerant of a closing "##" run,
#                a trailing colon, and bold/italic wrappers.
#   section end  the next ATX heading at any level, or end of file. In this
#                repo's own task.md the section is last, so EOF must terminate.
#   fences       ``` and ~~~ blocks are invisible everywhere in the file. The
#                task template shows the checkbox convention inside a fence for
#                exactly this reason: a literal unchecked box in the template
#                would otherwise make every freshly written task.md read as
#                open, and block every unattended run forever.
#   list item    a -, * or + bullet OR an ordered "1." / "1)" marker, at any
#                indentation and through any depth of blockquote, with or
#                without a space after the marker. A horizontal rule is not one.
#   settled      the item's text begins with [x] or [X]. An unchecked box, or a
#                bare bullet with no box at all, reads as OPEN — a fork someone
#                forgot to mark blocks rather than passing silently.
#
# Everywhere the rules above are permissive, they are permissive in the
# direction of reporting `open`. Reading a real fork as settled dispatches an
# implementer against a decision nobody made, which is the failure this exists
# to prevent; reading a stray bullet as a fork costs one checkbox. The fixtures
# in scripts/verify.sh pin the cases that used to fail the other way.
#
# Four values, because "task.md exists but has no such section" is a real state
# and must not be guessed at: collapsing it into `none` would let a mistyped
# heading silently disable the whole guarantee, and collapsing it into `open`
# would permanently block every hand-written task.md with no remedy. It gets
# its own value, `unknown`, and every consumer warns rather than assumes.
#
# NOT part of the frontmatter parser below — it shares no code with
# frontmatter_status(), so the byte-for-byte diff scripts/verify.sh runs
# between that function and the hook's copy is unaffected.
open_questions_forks() {
  local f="$1"
  [ -f "$f" ] || { printf 'absent'; return 0; }
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
    }
    BEGIN { insec = 0; fence = ""; found = 0; open = 0 }
    {
      line = $0
      sub(/\r$/, "", line)

      # Fenced blocks are invisible, wherever they appear. Tracked globally so
      # a fence opened before the section cannot leak a heading into it.
      if (line ~ /^[[:space:]]*(```|~~~)/) {
        tok = trim(line); tok = substr(tok, 1, 3)
        if (fence == "") { fence = tok } else if (tok == fence) { fence = "" }
        next
      }
      if (fence != "") next

      # Strip indentation, then any blockquote markers. Both are formatting; a
      # fork does not stop being a fork for being indented or quoted.
      b = line
      sub(/^[[:space:]]+/, "", b)
      while (b ~ /^>/) { sub(/^>[[:space:]]*/, "", b) }

      if (b ~ /^#+([[:space:]]|$)/) {
        h = b
        sub(/^#+[[:space:]]*/, "", h)          # opener
        sub(/[[:space:]]*#+[[:space:]]*$/, "", h)   # optional ATX closer
        h = trim(h)
        sub(/:+$/, "", h)                      # "Open questions:"
        gsub(/^[*_]+/, "", h); gsub(/[*_]+$/, "", h)  # "**Open questions**"
        if (tolower(trim(h)) == "open questions") { insec = 1; found = 1 }
        else { insec = 0 }
        next
      }

      if (!insec) next

      # A horizontal rule is not a list item, however much it looks like one.
      if (b ~ /^[-*_][[:space:]]*[-*_][[:space:]]*[-*_][[:space:]]*$/) next

      # Bulleted or numbered, with or without a space after the marker. The
      # space is optional on purpose: "-[ ] fork" is a typo, not a decision,
      # and reading it as settled is the one direction this must never fail in.
      if (b ~ /^[-*+]/ || b ~ /^[0-9]+[.)]/) {
        t = b
        sub(/^([-*+]|[0-9]+[.)])[[:space:]]*/, "", t)
        if (t !~ /^\[[xX]\]/) { open = 1 }
      }
    }
    END {
      if (!found)   { print "unknown" }
      else if (open) { print "open" }
      else           { print "none" }
    }
  ' "$f" 2>/dev/null
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

FORKS="$(open_questions_forks "$ROOT/task.md")"
echo "FORKS:${FORKS:-unknown}"

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
