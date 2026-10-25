#!/usr/bin/env bash
# run_phase_headless.sh — run one gantry phase in a FRESH headless child session
# and say, with an exit code, whether the phase actually happened.
# Run with:
#   bash run_phase_headless.sh --phase review|review-fix --root <worktree> \
#       [--tier <t>] [--model <alias>] [--effort <level>] [--max-turns <n>] \
#       [--plugin-dir <path>] [--timeout <seconds>]
#
# WHY THIS EXISTS. The drivers used to invoke /gantry:review in their own
# session, so the diff was reviewed by the model that wrote it, with everything
# it was thinking while writing it still in context — the weakest possible
# reviewer, by default. This script launches `claude -p "/gantry:review …"` in
# the worktree instead: a child that has read nothing but the skill text, the
# artifacts on disk, and the diff. The phase skill still carries the procedure;
# only WHERE it runs changes. docs/ARCHITECTURE.md § "Headless phases".
#
# THE TOOL BOUNDARY IS THE HARNESS'S, NOT PROSE. The child runs under
# `--permission-mode dontAsk --permission-prompts none`, where everything that
# would prompt is denied, plus an explicit allowlist:
#
#   review      Edit(<artifact>) and Edit(//<root>/<artifact>) for review.md, handover.md,
#               task.md, plus Skill(gantry:handover), plus the Bash rules
#   review-fix  acceptEdits (the fix step must edit code) + Skill(gantry:handover) + the Bash rules
#
# The Bash rules name four gantry scripts — the gate, the exclusion writer, the
# stage detector and the diff fingerprint — and each is emitted TWICE, in the
# unquoted and the double-quoted path form, because a rule matches the literal
# command text and a skill may write either (probed: `Bash(bash <abs>:*)` let
# `bash <abs>` through and denied `bash "<abs>"`). Nothing else Bash is allowed
# beyond what print mode permits by default (read-only git was; shell writes
# were not). `Edit(<file>)` rules govern the Write tool too, and only match
# inside a trusted project directory — a scratch directory outside one denies
# every file write whatever the rule says.
#
# DENIALS ARE REPORTED, NEVER FATAL ON THEIR OWN. A permission denial does not
# set `is_error`; the child carries on half-blind and still reports `success`.
# So every denial is printed as a DENIED: line for the driver to relay, and what
# IS fatal is the artifact check: a `review` child must leave review.md and a
# `reviewed` or `blocked` status; a `review-fix` child must end review.md with an `applied:`
# line. A child that returned success without that is a failed phase.
#
# THE OUTPUT ORDER IS FIXED and the result block comes LAST, delimited, so a
# result that happens to quote this script's own vocabulary ("SESSION:",
# "REASON:") cannot be mistaken for it by a reader that stops at the first match:
#
#   SESSION:<id>          MODEL:<modelUsage keys>   EFFORT:<value or inherit>
#   TURNS:<n>             SUBTYPE:<subtype>         COST_USD:<n>
#   DENIALS:<n>           DENIED:<tool> <command or path>   (one per denial)
#   GATE_EXIT:<n>         (review-fix only, from review.md's `applied:` line)
#   RESULT_FILE:<path>
#   NOTE:<one line>       (zero or more: the model nobody pinned, the detach,
#                          an attach to a child an earlier launcher left running)
#   REASON:<one line>         (on failure only)
#   RESULT_BEGIN … RESULT_END
#
# A field that could not be read prints `-`.
#
# Exit codes:
#   0  claude exited 0, subtype success, is_error false, terminal_reason
#      completed, AND the phase's artifact is on disk
#   1  the JSON or the artifact check says the phase failed (max_turns included)
#   2  usage, or the environment (no jq, no claude, --root not a worktree)
#   3  claude exited non-zero, or wrote no parseable JSON
set -uo pipefail

GANTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf 'run_phase_headless: %s\n' "$1" >&2; exit 2; }

# Diagnostics the driver must be able to relay — which model the child really
# took, whether it was detached, whether this run attached to an earlier child.
# They are stdout, in the labeled block, because a driver reads the launcher's
# output as one merged stream and the block is what it knows how to read.
NOTES=()
note() { NOTES[${#NOTES[@]}]="$1"; }

usage() {
  cat >&2 <<'USAGE'
run_phase_headless.sh --phase review|review-fix --root <worktree>
                      [--tier <medium|high|xhigh|max>] [--model <alias>] [--effort <level>]
                      [--max-turns <n>] [--plugin-dir <path>] [--timeout <seconds>]
USAGE
  exit 2
}

PHASE='' ROOT='' TIER='' MODEL='' EFFORT='' MAX_TURNS=80 PLUGIN_DIR='' TIMEOUT=7200

need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase)      need_value "$1" "$#"; PHASE="$2";      shift 2 ;;
    --root)       need_value "$1" "$#"; ROOT="$2";       shift 2 ;;
    --tier)       need_value "$1" "$#"; TIER="$2";       shift 2 ;;
    --model)      need_value "$1" "$#"; MODEL="$2";      shift 2 ;;
    --effort)     need_value "$1" "$#"; EFFORT="$2";     shift 2 ;;
    --max-turns)  need_value "$1" "$#"; MAX_TURNS="$2";  shift 2 ;;
    --plugin-dir) need_value "$1" "$#"; PLUGIN_DIR="$2"; shift 2 ;;
    --timeout)    need_value "$1" "$#"; TIMEOUT="$2";    shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PHASE" ] || die "--phase is required (review or review-fix)"
case "$PHASE" in
  review|review-fix) ;;
  *) die "unknown phase: $PHASE (expected review or review-fix)" ;;
esac
[ -n "$ROOT" ] || die "--root is required"
[ -d "$ROOT" ] || die "--root is not a directory: $ROOT"
ROOT="$(cd "$ROOT" && git rev-parse --show-toplevel 2>/dev/null)" \
  || die "--root is not inside a git worktree"
[ -n "$ROOT" ] || die "--root is not inside a git worktree"
case "$MAX_TURNS" in
  ''|*[!0-9]*) die "--max-turns must be a positive integer, got: $MAX_TURNS" ;;
esac
case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a positive integer of seconds, got: $TIMEOUT" ;;
esac
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be greater than zero"

if [ -n "$PLUGIN_DIR" ]; then
  [ -d "$PLUGIN_DIR" ] || die "--plugin-dir is not a directory: $PLUGIN_DIR"
  PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
fi

# A CHILD WITH NO --model DOES NOT INHERIT THE DRIVER'S. It inherits the user
# default from settings.json, which is a different thing and was a different
# thing in practice: in the review A/B of 2026-10-24 a driver pinned to Sonnet
# launched its review children on Opus, because a `/model` command in an
# unrelated pane had saved that default minutes earlier. The arms of the
# experiment then differed by model without anyone asking for it. The caller is
# the only one who knows which model the phase should run on, so say loudly
# when nobody said. MODEL: in the output reports what actually ran.
[ -n "$MODEL" ] || note 'no --model given: the child takes the user default from settings.json, NOT the model of whoever launched it'

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

# `claude` on PATH first, then the executable the running harness reports. The
# order matters for the fixture suite, which puts a fake `claude` on PATH while
# the real one is still named by CLAUDE_CODE_EXECPATH.
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE_BIN" ] && [ -n "${CLAUDE_CODE_EXECPATH:-}" ] && [ -x "${CLAUDE_CODE_EXECPATH}" ]; then
  CLAUDE_BIN="$CLAUDE_CODE_EXECPATH"
fi
[ -n "$CLAUDE_BIN" ] || die "no claude on PATH and no executable CLAUDE_CODE_EXECPATH"

# --- the worktree -------------------------------------------------------------

cd "$ROOT" || die "could not enter $ROOT"

# The four artifacts and the result directory, excluded before the child can
# write any of them — gantry:ship stages with `git add -A` when nothing is
# staged, so an unexcluded review.md would be committed into the pull request.
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md .claude/artifacts/ >/dev/null \
  || die "could not assert the artifact exclusions"

OUT_DIR="$ROOT/.claude/artifacts/headless"
mkdir -p "$OUT_DIR" || die "could not create $OUT_DIR"
RESULT_FILE="$OUT_DIR/$PHASE.json"
ERR_FILE="$OUT_DIR/$PHASE.err"
DONE_FILE="$OUT_DIR/$PHASE.done"
PID_FILE="$OUT_DIR/$PHASE.pid"
RC_FILE="$OUT_DIR/$PHASE.rc"

# ATTACH RATHER THAN RELAUNCH. The child outlives this script (see the detach
# note below), so a launcher that was killed while the child ran leaves a live
# pid and no .done. Re-running the same command then has to wait for THAT child:
# a second review over the same diff would cost a full review and overwrite the
# first one's artifact mid-write.
ATTACH=0
if [ ! -e "$DONE_FILE" ] && [ -s "$PID_FILE" ] \
   && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
  ATTACH=1
else
  # An earlier run's files go FIRST, so a stale .done can never be read as this
  # run's by a driver resuming after a lost completion notification.
  rm -f "$RESULT_FILE" "$ERR_FILE" "$DONE_FILE" "$PID_FILE" "$RC_FILE"
fi

BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
# A slash in --name is accepted by the CLI today; sanitise anyway so a future
# tightening cannot fail every launch.
SAFE_BRANCH="$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9._-' '-')"
[ -n "$SAFE_BRANCH" ] || SAFE_BRANCH=branch

# --- the prompt and the boundary -----------------------------------------------

case "$PHASE" in
  review)     PROMPT="/gantry:review --headless --tier ${TIER:-high}" ;;
  review-fix) PROMPT="/gantry:review --fix --headless" ;;
esac

# The rules name the plugin root the CHILD will resolve: the --plugin-dir when
# one is forwarded (it wins over an install), else this script's own root.
RULE_ROOT="${PLUGIN_DIR:-$GANTRY}"
RULES=()
for script in run_gates.sh ensure_excluded.sh detect_stage.sh diff_fingerprint.sh; do
  RULES[${#RULES[@]}]="Bash(bash $RULE_ROOT/lib/$script:*)"
  RULES[${#RULES[@]}]="Bash(bash \"$RULE_ROOT/lib/$script\":*)"
done

CMD=("$CLAUDE_BIN" -p "$PROMPT" --output-format json --name "gantry-$PHASE-$SAFE_BRANCH"
     --permission-prompts none --max-turns "$MAX_TURNS")
[ -n "$MODEL" ]      && CMD[${#CMD[@]}]="--model"      && CMD[${#CMD[@]}]="$MODEL"
[ -n "$EFFORT" ]     && CMD[${#CMD[@]}]="--effort"     && CMD[${#CMD[@]}]="$EFFORT"
[ -n "$PLUGIN_DIR" ] && CMD[${#CMD[@]}]="--plugin-dir" && CMD[${#CMD[@]}]="$PLUGIN_DIR"
case "$PHASE" in
  review)
    CMD[${#CMD[@]}]="--permission-mode"; CMD[${#CMD[@]}]="dontAsk"
    # --allowedTools is variadic, so it goes LAST: everything after it is a rule.
    CMD[${#CMD[@]}]="--allowedTools"
    # Each artifact twice: the relative form resolves against the child's CURRENT working
    # directory, and a `cd` inside one Bash call persists — a child that had wandered into a
    # sub-package was denied `Write <root>/review.md` with the relative rule alone (observed in
    # the review A/B, 2026-10-23). The `//<abs>` form matches wherever the shell ended up.
    for artifact in review.md handover.md task.md; do
      CMD[${#CMD[@]}]="Edit($artifact)"
      CMD[${#CMD[@]}]="Edit(//$ROOT/$artifact)"
    done
    # The skill invokes gantry:handover for deferred findings; under dontAsk a plugin skill
    # is denied without a rule (the built-in /code-review is not), and the child then writes
    # handover.md by hand. Probed: this rule lets the Skill tool through.
    CMD[${#CMD[@]}]="Skill(gantry:handover)"
    ;;
  review-fix)
    CMD[${#CMD[@]}]="--permission-mode"; CMD[${#CMD[@]}]="acceptEdits"
    CMD[${#CMD[@]}]="--allowedTools"
    CMD[${#CMD[@]}]="Skill(gantry:handover)"
    ;;
esac
for r in "${RULES[@]}"; do CMD[${#CMD[@]}]="$r"; done

# --- run --------------------------------------------------------------------------
#
# stdin is /dev/null: a headless child must never wait on a terminal that is
# not there. The .done marker is touched LAST, after both files are complete.
#
# THE CHILD IS DETACHED, AND THAT IS NOT AN OPTIMISATION. A driver runs this
# script as a backgrounded Bash task, and a Claude Code session registers a
# `memoryPressure` handler over its own background tasks: when the runtime
# raises the event, every running task of that session is marked killed with
# the message "stopped because the system is running low on memory". The event
# comes from the runtime inside one session process, so it fires regardless of
# how much memory the HOST has free — measured in the review A/B of 2026-10-24
# at 0.6, 0.8, 0.9, 1.1 and 2.9 GiB free, against one survivor at 1.6 GiB. One
# lane lost six review children in a row; another, identical, lost none. Only
# the headless topology is exposed: an in-session review has no background task
# to reap.
#
# The session's own variable (CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP) is
# read in the DRIVER's process, which a skill cannot set. So the child is put in
# a session of its own with setsid, where the reaper's signals cannot reach it,
# and a small wrapper — not this script — records the exit code and touches
# .done. If this script is reaped, the review carries on and the next run of the
# same command attaches to it. The variable is still set for the child, so a
# nested background task of its own is not reaped either.
#
# Without setsid (not Linux, or a stripped image) the child runs inline, as
# before, and the launcher says so on stderr: the phase still works, it is just
# exposed again.

SETSID="$(command -v setsid 2>/dev/null || true)"
WRAP='CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1 \
      "$@" </dev/null >"$RPH_RESULT" 2>"$RPH_ERR"; rc=$?; \
      printf %s "$rc" >"$RPH_RC"; : >"$RPH_DONE"'

CRC=0
TIMED_OUT=0
if [ "$ATTACH" -eq 1 ]; then
  note "attached to the $PHASE child already running as pid $(cat "$PID_FILE"); no second child was launched"
elif [ -n "$SETSID" ]; then
  "$SETSID" env \
    RPH_RESULT="$RESULT_FILE" RPH_ERR="$ERR_FILE" \
    RPH_RC="$RC_FILE" RPH_DONE="$DONE_FILE" \
    bash -c "$WRAP" rph "${CMD[@]}" &
  printf '%s\n' "$!" > "$PID_FILE"
  note "$PHASE child detached with setsid as pid $(cat "$PID_FILE"): a session of its own, so no caller's memory-pressure reaper can reach it"
else
  note "no setsid on PATH: the $PHASE child runs inline and IS exposed to the caller session's memory-pressure reaper"
  CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1 \
    "${CMD[@]}" </dev/null >"$RESULT_FILE" 2>"$ERR_FILE"
  printf %s "$?" > "$RC_FILE"
  : > "$DONE_FILE"
fi

# Wait on the marker rather than on the process: the child is in another session
# and, after an attach, was never this shell's to wait for. Tight at first so the
# fixture suite does not pay a second per case, then slow enough to be free.
if [ ! -e "$DONE_FILE" ]; then
  deadline=$(( $(date +%s) + TIMEOUT ))
  spins=0
  while [ ! -e "$DONE_FILE" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      TIMED_OUT=1
      if [ -s "$PID_FILE" ]; then
        # The group, but ONLY when that pid leads it: a child launched with
        # setsid leads its own group and the whole review subtree has to go,
        # while a pid that is just a member of somebody else's group must
        # cost that group nothing. Then the pid itself either way.
        stop_pid="$(tr -dc '0-9' < "$PID_FILE")"
        if [ -n "$stop_pid" ]; then
          stop_pgid="$(ps -o pgid= -p "$stop_pid" 2>/dev/null | tr -dc '0-9')"
          [ -n "$stop_pgid" ] && [ "$stop_pgid" = "$stop_pid" ] \
            && kill -TERM "-$stop_pgid" 2>/dev/null
          kill -TERM "$stop_pid" 2>/dev/null || true
        fi
      fi
      break
    fi
    spins=$(( spins + 1 ))
    if [ "$spins" -le 25 ]; then sleep 0.2; else sleep 2; fi
  done
fi

if [ "$TIMED_OUT" -eq 1 ]; then
  CRC=124
elif [ -s "$RC_FILE" ]; then
  CRC="$(tr -dc '0-9' < "$RC_FILE")"
  [ -n "$CRC" ] || CRC=0
fi

# --- read the result ------------------------------------------------------------

SESSION='-' MODEL_USED='-' TURNS='-' SUBTYPE='-' COST='-' IS_ERROR='-' TERMINAL='-'
DENIAL_COUNT=0
DENIED_LINES=''
RESULT_TEXT=''
PARSED=0

if [ -s "$RESULT_FILE" ] && jq -e 'type == "object"' "$RESULT_FILE" >/dev/null 2>&1; then
  PARSED=1
  jqr() { jq -r "$1" "$RESULT_FILE" 2>/dev/null; }
  SESSION="$(jqr '.session_id // "-"')"
  MODEL_USED="$(jqr '(.modelUsage // {}) | keys | if length == 0 then "-" else join(",") end')"
  TURNS="$(jqr '.num_turns // "-"')"
  SUBTYPE="$(jqr '.subtype // "-"')"
  COST="$(jqr '.total_cost_usd // "-"')"
  # Not `// "-"`: jq's alternative operator treats false as absent.
  IS_ERROR="$(jqr 'if has("is_error") then (.is_error | tostring) else "-" end')"
  TERMINAL="$(jqr '.terminal_reason // "-"')"
  DENIAL_COUNT="$(jqr '(.permission_denials // []) | length')"
  # One line per denial, the command or path flattened onto it: a multi-line
  # command must not break the one-line-per-field contract.
  DENIED_LINES="$(jqr '(.permission_denials // [])[]
    | "DENIED:" + (.tool_name // "?") + " "
      + ((.tool_input.command // .tool_input.file_path // .tool_input.path // "")
         | tostring | gsub("\n"; " "))')"
  RESULT_TEXT="$(jqr '.result // ""')"
fi

# --- verify the artifact ----------------------------------------------------------
#
# The exit code is decided by what is on disk, not by what the child said.

ARTIFACT_OK=1
ARTIFACT_REASON=''
GATE_EXIT='-'
case "$PHASE" in
  review)
    if [ ! -f "$ROOT/review.md" ]; then
      ARTIFACT_OK=0; ARTIFACT_REASON="the child left no review.md at the worktree root"
    else
      STATUS="$(bash "$GANTRY/lib/detect_stage.sh" 2>/dev/null | sed -n 's/^STATUS://p')"
      case "$STATUS" in
        reviewed|blocked) ;;
        *) ARTIFACT_OK=0; ARTIFACT_REASON="task.md status is '${STATUS:-none}', not reviewed or blocked" ;;
      esac
    fi
    ;;
  review-fix)
    if [ ! -f "$ROOT/review.md" ]; then
      ARTIFACT_OK=0; ARTIFACT_REASON="no review.md at the worktree root to apply"
    else
      # The rule lib/detect_stage.sh's review_state() applies: only the last
      # non-blank line counts, so the launcher and the detector cannot disagree
      # about whether the fix step ran.
      applied="$(awk 'NF { l = $0 } END { sub(/\r$/, "", l); sub(/^[[:space:]]+/, "", l); print l }' "$ROOT/review.md" 2>/dev/null)"
      case "$applied" in applied:*) ;; *) applied='' ;; esac
      if [ -z "$applied" ]; then
        ARTIFACT_OK=0; ARTIFACT_REASON="review.md does not end with an applied: line"
      else
        GATE_EXIT="$(printf '%s' "$applied" | sed -n 's/.*gate=\([0-9][0-9]*\).*/\1/p')"
        [ -n "$GATE_EXIT" ] || GATE_EXIT='-'
      fi
    fi
    ;;
esac

# --- decide --------------------------------------------------------------------------

RC=0
REASON=''
if [ "$TIMED_OUT" -eq 1 ]; then
  RC=1
  REASON="the $PHASE child did not finish within ${TIMEOUT}s and was stopped"
elif [ "$CRC" -ne 0 ]; then
  RC=3
  first_err="$(sed -n '1p' "$ERR_FILE" 2>/dev/null | tr -d '\r')"
  REASON="claude exited $CRC${first_err:+: $first_err}"
elif [ "$PARSED" -eq 0 ]; then
  RC=3
  first_err="$(sed -n '1p' "$ERR_FILE" 2>/dev/null | tr -d '\r')"
  REASON="claude wrote no parseable JSON result${first_err:+: $first_err}"
elif [ "$SUBTYPE" != success ] || [ "$IS_ERROR" != false ] || [ "$TERMINAL" != completed ]; then
  RC=1
  REASON="the child did not complete: subtype=$SUBTYPE is_error=$IS_ERROR terminal_reason=$TERMINAL"
elif [ "$ARTIFACT_OK" -eq 0 ]; then
  RC=1
  REASON="the child reported success but $ARTIFACT_REASON"
fi

# --- print --------------------------------------------------------------------------

printf 'SESSION:%s\n'  "$SESSION"
printf 'MODEL:%s\n'    "$MODEL_USED"
printf 'EFFORT:%s\n'   "${EFFORT:-inherit}"
printf 'TURNS:%s\n'    "$TURNS"
printf 'SUBTYPE:%s\n'  "$SUBTYPE"
printf 'COST_USD:%s\n' "$COST"
printf 'DENIALS:%s\n'  "$DENIAL_COUNT"
[ -n "$DENIED_LINES" ] && printf '%s\n' "$DENIED_LINES"
[ "$PHASE" = review-fix ] && printf 'GATE_EXIT:%s\n' "$GATE_EXIT"
printf 'RESULT_FILE:%s\n' "$RESULT_FILE"
for n in ${NOTES[@]+"${NOTES[@]}"}; do printf 'NOTE:%s\n' "$n"; done
[ -n "$REASON" ] && printf 'REASON:%s\n' "$REASON"
printf 'RESULT_BEGIN\n%s\nRESULT_END\n' "$RESULT_TEXT"

exit "$RC"
