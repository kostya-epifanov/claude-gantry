#!/usr/bin/env bash
#
# readiness-gate.sh — gantry's Stop/SubagentStop readiness hook.
#
# WHAT THIS IS. Registered for both `Stop` and `SubagentStop` by the plugin's
# `hooks/hooks.json` (matcher "*"). It moves the readiness-gate guarantee out
# of the prompt and into the harness: on a session/subagent stop it runs the
# repo's gate and decides, out of band, whether the run may call itself done.
# A prompt-level rule is a request the model can talk itself past; this is a
# refusal it cannot decline. Set GANTRY_READINESS_GATE=off to disable.
#
# `SubagentStop` + matcher "*" means EVERY subagent's stop runs this — but the
# gate is only armed while `task.md` says `status: implementing` (see FIRING
# CONDITION below), and no gantry sub-agent runs inside that window:
# `gantry:implement` dispatches nobody, and the explorer, critic and reviewer
# run while status is `planning`/`planned`/`implemented`. Don't widen the
# matcher casually — a read-only subagent blocked with exit 2 cannot fix
# anything; it can only return the block to whoever dispatched it.
#
# THIS SCRIPT HOLDS NO STATE. No attempt counter, no lock, no per-task keying,
# no fail-open matrix, no `mark_task_blocked`, no escalation. It reads stdin,
# checks three conditions, runs one script, and exits 0 or 2. That is the
# whole thing. (A first version of this file was 473 lines of counter/lock
# machinery; two review rounds found 24 defects in it, criticals in both, the
# second round's criticals *introduced by the first round's fixes* — a
# stale-lock steal that hot-spun under SIGKILL and a classification bug that
# read `.claude/gates.sh`'s exit 2 as "unrunnable" and waved a broken
# environment through forever. The fix was to delete the state, not patch it
# again. See docs/METHOD.md, "What we deleted.")
#
# THE ATTEMPT CAP AND STATUS:BLOCKED TRANSITION LIVE IN THE ORCHESTRATOR, not
# here (`gantry:auto-unattended` stage 4, already journaled). This hook does not write
# task.md. Ever.
#
# FIRING CONDITION, evaluated in this order, each failure logging one `skip`
# line to gate-hook.log with its reason and exiting 0:
#   1. `stop_hook_active` is true in the payload (this stop was itself caused
#      by a previous block from this hook — see LOOP TERMINATION below). A jq
#      failure while parsing this field is treated the SAME as true — see
#      JQ FAILURE MODES below; this is not optional.
#   2. `task.md` exists at ROOT.
#   3. `.claude/gates.sh` exists at ROOT.
#   4. `task.md`'s frontmatter `status:` is exactly `implementing`, after
#      trimming trailing whitespace/CR, a trailing `# comment`, and one layer
#      of surrounding quotes (tolerates a `---\r` fence, a CRLF file, a
#      leading blank line or UTF-8 BOM before the fence, `status: "value"`,
#      and `status: value # note` — and, if the frontmatter block never
#      closes with a second `---`, treats the file as having no status at
#      all rather than scanning into the body).
# Everything outside this window is inert: exit 0, no checks run, no
# perceptible delay. The trigger is a file the model can write (`task.md`'s
# `status:`), so "the model cannot bypass it" is approximately, not exactly,
# true — see docs/METHOD.md, "The honest limit". The mitigation is that EVERY invocation,
# fire or skip, appends one line to gate-hook.log, so a bypass is visible in
# the audit trail rather than silent.
#
# LOOP TERMINATION IS `stop_hook_active`. When true (or unreadable — see
# below), this hook exits 0 and defers, unconditionally. This hook therefore
# blocks a given stop AT MOST ONCE — it is the orchestrator's stage-6 retry
# cap that bounds the overall fix loop, not a counter in here. Do not add one
# "to improve" this.
#
# ONLY EXIT 2 BLOCKS A STOP HOOK. Exit 0 is success; exit 2 is a *blocking*
# error whose stderr is fed back to the model; any OTHER non-zero exit is
# non-blocking and the stop proceeds regardless. Every exit in this file is
# therefore 0 or 2 — grep for `exit ` before changing anything.
#
# GATE EXIT CODE: 0 = green, ANYTHING ELSE = red. A `.claude/gates.sh` that
# exits 2 because its runner is missing is NOT special-cased as
# "unrunnable"; a broken environment is a red gate, full stop. Treating exit 2
# as a distinct non-blocking class is exactly the bug the second review round
# found (a broken environment blocked once, then exited 0 forever with the
# suite never running). Environment breakage failing red is the safe
# direction: "the gate could not prove the tree is good." The one exception is
# our OWN wiring: if `run_gates.sh` itself is missing or unreadable, that is a
# broken install of this hook, not a repo the hook can gate — it now fails
# red (exit 2) too, same reasoning, bounded the same way by `stop_hook_active`.
#
# JQ FAILURE MODES. jq's `//` only substitutes on a present-but-null field; it
# does nothing when jq itself fails to run or to parse (absent binary, PATH
# stripped in the hook's environment, malformed payload) — the command
# substitution just captures empty stdout. For `payload_cwd`, `hook_event`,
# and the green-path `systemMessage`, an empty/failed jq degrades harmlessly
# (ROOT falls back, the event name defaults to "unknown", the PASS message is
# skipped in favour of a plain stderr line). For `stop_hook_active` it does
# NOT degrade harmlessly: empty is indistinguishable from "false", so a jq
# failure on the very stop our own block caused would re-run the gate and
# block again — an unbounded loop with no second terminator. That single read
# checks jq's own exit status and treats failure as "assume active, defer".
#
# TIMEOUT. This hook does not wrap `run_gates.sh` in an internal timeout.
# `timeout(1)`/`gtimeout(1)` are absent on many hosts (macOS without
# coreutils, for one), so
# there is nothing trivial to wrap it with, and building a portable
# timeout-with-cleanup is exactly the kind of machinery this rewrite is
# removing. Residual hazard: a hung gate hangs the hook up to the harness's
# own 300s hook timeout (declared in `hooks/hooks.json`); if the harness kills this
# process, no exit 2 is produced and the stop proceeds un-gated, un-logged.
# Not handled here; flagged, not silently accepted.
#
# ARTIFACT CONTRACT:
#   .claude/artifacts/gate-<timestamp>-<pid>.log — run_gates.sh stdout+stderr,
#                                                   verbatim, for THIS run only
#   .claude/artifacts/gate-hook.log              — one line per invocation,
#                                                   including every skip
# If neither a real artifacts-dir path nor `mktemp` can produce a usable log
# path, the gate still runs (output goes to /dev/null so the redirect itself
# never fails and `rc` is still the real result) and the verdict says plainly
# that no artifact exists — it never claims a path that isn't there.
# The hook's own stdout/stderr carry a one-line verdict and a path ONLY —
# never a line of captured check output.
#
# JSON. The one JSON line this script ever emits (the green-path
# systemMessage) is built with `jq --arg`, which escapes
# backslash/quote/newline/tab/C0-control correctly on its own — no hand-rolled
# json_escape here. If jq is not on PATH at all, that single call is skipped
# in favour of the same message on stderr, so a missing jq degrades to a
# plain-text line instead of a raw "jq: command not found" reaching the
# transcript.
#
set -uo pipefail

# --- kill switch -------------------------------------------------------------
# This hook installs with the plugin and Claude Code offers no way to accept a
# plugin but decline its hooks. In practice it is inert unless you have armed
# it (see FIRING CONDITION), but an explicit off switch costs four lines and
# removes the only fair objection to shipping it registered.
if [ "${GANTRY_READINESS_GATE:-on}" = "off" ]; then exit 0; fi

payload="$(cat)"

# --- parse just enough of the payload to decide and to log against ----------
payload_cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"

# hook_event: jq's `//` never fires on a parse failure (empty/unparseable
# stdin), only on a present-but-null field — so on parse failure this used to
# silently log `event=` instead of naming an event. Default in the shell,
# after jq, so every failure mode lands on "unknown".
hook_event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
hook_event="${hook_event:-unknown}"

# --- resolve ROOT: $CLAUDE_PROJECT_DIR, falling back to the payload's cwd ---
ROOT="${CLAUDE_PROJECT_DIR:-$payload_cwd}"

if [ -z "$ROOT" ]; then
  # Nothing to gate, nowhere to log. This is not one of the firing-order
  # skips below (there is no repo to even test them against); it is a bare
  # inert exit.
  printf 'readiness-gate: cannot resolve ROOT from $CLAUDE_PROJECT_DIR or payload cwd — exiting inert (exit 0)\n' >&2
  exit 0
fi

# --- artifacts dir + the durable audit log -----------------------------------
ARTIFACTS="$ROOT/.claude/artifacts"
HOOKLOG=""
if mkdir -p "$ARTIFACTS" 2>/dev/null && [ -w "$ARTIFACTS" ]; then
  HOOKLOG="$ARTIFACTS/gate-hook.log"
else
  # Cannot create the audit trail. Still behave correctly — one clean stderr
  # line, then follow the green/red rule on the gate's actual result. Do not
  # fail open just because logging is unavailable.
  printf 'readiness-gate: cannot create or write %s — audit log disabled, gate still enforced\n' "$ARTIFACTS" >&2
fi

log_line() {  # log_line <fire|skip> <verdict> <exit> <reason>
  [ -n "$HOOKLOG" ] || return 0
  printf 'ts=%s event=%s decision=%s verdict=%s exit=%s stop_hook_active=%s reason=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hook_event" "$1" "$2" "$3" "${stop_hook_active:-}" "$4" \
    >>"$HOOKLOG" 2>/dev/null
}

# --- stop_hook_active: parsed BEFORE the firing-condition checks, with a ----
# strict jq-failure handling (see JQ FAILURE MODES in the header). A jq
# failure here must be treated the same as "true" — assume this stop was
# caused by our own previous block and defer, rather than risk re-running the
# gate and blocking the very stop our block caused.
stop_hook_active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
if [ $? -ne 0 ]; then
  log_line skip - 0 "jq failed parsing stop_hook_active — treating as active, deferring to avoid a block loop"
  exit 0
fi

if [ "$stop_hook_active" = "true" ]; then
  log_line skip - 0 "stop_hook_active=true — this stop was caused by our own previous block, deferring"
  exit 0
fi

# --- frontmatter status (task.md's leading --- block only) ------------------
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

# --- firing condition, in order (§ FIRING CONDITION of the header) ----------
if [ ! -f "$ROOT/task.md" ]; then
  log_line skip - 0 "no task.md at ROOT"
  exit 0
fi

if [ ! -f "$ROOT/.claude/gates.sh" ]; then
  log_line skip - 0 "no .claude/gates.sh at ROOT"
  exit 0
fi

status="$(frontmatter_status "$ROOT/task.md")"
if [ "$status" != "implementing" ]; then
  log_line skip - 0 "status:${status:-<none>}"
  exit 0
fi

# --- resolve run_gates.sh, preflight it, then run it -------------------------
# Self-location first: it holds under every install shape (marketplace cache,
# --plugin-dir, a git checkout, a symlink) and needs no environment. Only then
# ${CLAUDE_PLUGIN_ROOT}, which Claude Code sets for plugin-provided hooks but
# which is empty when this script is run directly, e.g. by a test harness.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_gates="$HOOK_DIR/../lib/run_gates.sh"
if [ ! -f "$run_gates" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  run_gates="${CLAUDE_PLUGIN_ROOT}/lib/run_gates.sh"
fi

if [ ! -f "$run_gates" ] || [ ! -r "$run_gates" ]; then
  # `.claude/gates.sh` already had to exist to reach this point (checked
  # above), so a missing/unreadable run_gates.sh is a broken install of this
  # hook's own wiring, not an ordinary "nothing to gate" case. Every other
  # "cannot prove the tree is good" case in this file fails red; this one now
  # does too, bounded to a single block by stop_hook_active.
  msg="readiness-gate: RED — run_gates.sh not found or unreadable at ${run_gates} (broken hook install) · fix the install, then the next stop re-checks"
  printf '%s\n' "$msg" >&2
  log_line fire RED 2 "run_gates.sh not found or unreadable at $run_gates"
  exit 2
fi

log_missing=0
if [ -n "$HOOKLOG" ]; then
  log="$ARTIFACTS/gate-$(date +%s)-$$.log"
  rel_log="${log#"$ROOT"/}"
else
  log="$(mktemp "${TMPDIR:-/tmp}/readiness-gate.XXXXXX" 2>/dev/null)"
  rel_log="$log"
fi
if [ -z "$log" ]; then
  # Neither the artifacts dir nor mktemp produced a real path. Fall back to
  # /dev/null so the redirect below still succeeds (rc is still the real
  # run_gates.sh result — a green tree must not be reported as red just
  # because we couldn't open a log file) and never claim a path that doesn't
  # exist; the verdict below says plainly that no artifact was captured,
  # distinct from "the gate ran and was red".
  log=/dev/null
  rel_log=""
  log_missing=1
fi

( cd "$ROOT" && bash "$run_gates" ) >"$log" 2>&1
rc=$?

# --- dispatch: 0 = green, anything else = red (see header) -------------------
if [ "$rc" -eq 0 ]; then
  sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"
  sha="${sha:-unknown}"
  if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    sha="${sha}+dirty"
  fi
  if [ "$log_missing" -eq 1 ]; then
    msg="readiness-gate: PASS — run_gates.sh exit 0 at ${sha} · (no artifact — could not create a log file)"
  else
    msg="readiness-gate: PASS — run_gates.sh exit 0 at ${sha} · ${rel_log}"
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg msg "$msg" '{systemMessage:$msg,suppressOutput:false}'
  else
    # No jq: degrade to plain text rather than a raw "command not found"
    # reaching the transcript. No hand-rolled JSON escaping (see header).
    printf '%s\n' "$msg" >&2
  fi
  log_line fire PASS 0 "run_gates.sh rc=0 sha=${sha} log=${rel_log}"
  exit 0
fi

if [ "$log_missing" -eq 1 ]; then
  msg="readiness-gate: RED — run_gates.sh exit ${rc} · (no artifact — could not create a log file, output not captured)"
else
  msg="readiness-gate: RED — run_gates.sh exit ${rc} · ${rel_log}"
fi
printf '%s\n' "$msg" >&2
log_line fire RED 2 "run_gates.sh rc=${rc} log=${rel_log} log_missing=${log_missing}"
exit 2
