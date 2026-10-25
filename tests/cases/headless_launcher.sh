#!/usr/bin/env bash
#
# lib/run_phase_headless.sh launches a phase in a fresh `claude -p` child and
# turns what came back into an exit code. Everything the driver then relies on
# is argv it never sees and a JSON file it never reads, so this case replaces
# `claude` with a fake that RECORDS ITS ARGV NUL-DELIMITED — exact elements, so
# a quoting mistake in the launcher (a rule split in two, a prompt split on its
# spaces) fails here rather than as a silent permission denial in a child.
#
# The fake also writes the artifacts a real child would, as told, because the
# launcher's exit code is decided by what is on disk rather than by what the
# child said. A child that reports success and leaves no review.md is the
# failure that check exists for.
#
# tests/lib.sh's stub_cmd only writes an exit code, so this case writes its own
# fake, the way journal_append.sh defines its own runners.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

LAUNCHER="$GANTRY_ROOT/lib/run_phase_headless.sh"

if ! command -v jq >/dev/null 2>&1; then
  _fail "jq is required by the launcher, but is not installed"
  finish
fi

# --- the fake claude ---------------------------------------------------------------

FAKE_BIN="$CASE_TMP/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env bash
# Records argv NUL-delimited, the cwd, one env var, and whether a stale .done
# was still present when it started; writes artifacts as told; prints the
# canned JSON; exits as told.
printf '%s\0' "$@" > "$FAKE_CLAUDE_ARGV"
printf '%s\n' "$PWD" > "$FAKE_CLAUDE_CWD"
printf '%s\n' "${CLAUDE_CODE_FORCE_SESSION_PERSISTENCE:-unset}" > "$FAKE_CLAUDE_ENV"
printf '%s\n' "${CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP:-unset}" > "$FAKE_CLAUDE_REAP"
printf '%s\n' "$$:$(ps -o sid= -p $$ 2>/dev/null | tr -d ' '):$PPID" > "$FAKE_CLAUDE_SID"
if [ -e .claude/artifacts/headless/review.done ]; then echo present; else echo absent; fi > "$FAKE_CLAUDE_DONE_SEEN"
case "${FAKE_CLAUDE_WRITES:-none}" in
  review)
    printf '# Review\nbranch: b\n\n## Address now\n- `a.sh:3` — wrong.\n' > review.md
    printf -- '---\nstatus: reviewed\n---\n' > task.md ;;
  review-blocked)
    printf '# Review\n\n## Address now\nNone.\n' > review.md
    printf -- '---\nstatus: blocked\n---\n' > task.md ;;
  status-only)
    printf -- '---\nstatus: reviewed\n---\n' > task.md ;;
  review-only)
    printf '# Review\n\n## Address now\n- x\n' > review.md ;;
  applied)
    printf 'applied: 2026-10-22T00:00:00Z gate=0\n' >> review.md ;;
  applied-red)
    printf 'applied: 2026-10-22T00:00:00Z gate=1\n' >> review.md ;;
  applied-mid)
    printf 'applied: 2026-10-22T00:00:00Z gate=0\n- `b.sh:1` — a finding written after it.\n' >> review.md ;;
  none) ;;
esac
[ -n "${FAKE_CLAUDE_STDERR:-}" ] && printf '%s\n' "$FAKE_CLAUDE_STDERR" >&2
printf '%s' "${FAKE_CLAUDE_JSON:-}"
exit "${FAKE_CLAUDE_RC:-0}"
FAKE
chmod +x "$FAKE_BIN/claude"
PATH="$FAKE_BIN:$PATH"; export PATH

export FAKE_CLAUDE_ARGV="$CASE_TMP/argv"
export FAKE_CLAUDE_CWD="$CASE_TMP/cwd"
export FAKE_CLAUDE_ENV="$CASE_TMP/env"
export FAKE_CLAUDE_DONE_SEEN="$CASE_TMP/done-seen"
export FAKE_CLAUDE_REAP="$CASE_TMP/reap"
export FAKE_CLAUDE_SID="$CASE_TMP/sid"

SUCCESS_JSON='{"session_id":"sess-1","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":7,"total_cost_usd":0.5,"modelUsage":{"claude-sonnet-5":{"inputTokens":1}},"permission_denials":[],"result":"Reviewed.\nSESSION: this is the child quoting the vocabulary\nREASON: not a launcher line"}'

# run_launcher <writes> <json> <rc> [args...] — sets L_OUT and L_RC.
run_launcher() {
  local writes="$1" json="$2" rc="$3"; shift 3
  rm -f "$FAKE_CLAUDE_ARGV" "$FAKE_CLAUDE_CWD" "$FAKE_CLAUDE_ENV" "$FAKE_CLAUDE_DONE_SEEN" \
        "$FAKE_CLAUDE_REAP" "$FAKE_CLAUDE_SID"
  L_OUT="$(FAKE_CLAUDE_WRITES="$writes" FAKE_CLAUDE_JSON="$json" FAKE_CLAUDE_RC="$rc" \
    bash "$LAUNCHER" "$@" 2>&1)"
  L_RC=$?
  return 0
}

# ARGV is loaded from the NUL-delimited file without mapfile (bash 3.2).
load_argv() {
  ARGV=()
  local e
  while IFS= read -r -d '' e; do ARGV[${#ARGV[@]}]="$e"; done < "$FAKE_CLAUDE_ARGV"
}

argv_has() {  # argv_has <exact element> <label>
  local e
  for e in "${ARGV[@]}"; do
    if [ "$e" = "$1" ]; then _pass "$2"; return 0; fi
  done
  _fail "$2 — no argv element equals: $1"
}

argv_lacks() {  # argv_lacks <exact element> <label>
  local e
  for e in "${ARGV[@]}"; do
    if [ "$e" = "$1" ]; then _fail "$2 — argv unexpectedly contains: $1"; return 0; fi
  done
  _pass "$2"
}

argv_lacks_prefix() {  # argv_lacks_prefix <prefix> <label>
  local e
  for e in "${ARGV[@]}"; do
    case "$e" in "$1"*) _fail "$2 — argv element starts with $1: $e"; return 0 ;; esac
  done
  _pass "$2"
}

argv_value_after() {  # argv_value_after <flag> — echoes the next element
  local i=0
  while [ "$i" -lt "${#ARGV[@]}" ]; do
    if [ "${ARGV[$i]}" = "$1" ]; then printf '%s' "${ARGV[$((i + 1))]:-}"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

line_of() {  # line_of <prefix> — the first output line starting with it
  printf '%s\n' "$L_OUT" | grep -m1 "^$1" || true
}

# --- the fixture worktree ---------------------------------------------------------------

repo="$(mkrepo lane)"
git -C "$repo" checkout -q -b feat/headless >/dev/null 2>&1
write_task "$repo" implemented

# --- review: success, exact argv -----------------------------------------------------

run_launcher review "$SUCCESS_JSON" 0 --phase review --root "$repo"
assert_rc 0 "$L_RC" "a review child that completed and left its artifacts is exit 0"
load_argv

assert_contains "$(cat "$FAKE_CLAUDE_CWD")" "$repo" "the child runs in the worktree"
assert_contains "$(cat "$FAKE_CLAUDE_ENV")" "1" "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 reaches the child"

assert_contains "${ARGV[0]}" "-p" "the first element is -p"
argv_has "/gantry:review --headless --tier high" "the prompt is ONE element, --headless and the default tier included"
argv_has "--output-format" "--output-format is passed"
argv_has "json" "and it is json"
argv_has "gantry-review-feat-headless" "--name is gantry-review-<branch> with the slash sanitised"
argv_has "--permission-prompts" "--permission-prompts is passed"
argv_has "none" "and it is none"
argv_has "--permission-mode" "--permission-mode is passed"
argv_has "dontAsk" "and the review child gets dontAsk"
argv_has "--max-turns" "--max-turns is passed"
argv_has "80" "and defaults to 80"
argv_has "--allowedTools" "--allowedTools is passed"
repo_top="$(cd "$repo" && git rev-parse --show-toplevel)"
for a in review.md handover.md task.md; do
  argv_has "Edit($a)" "Edit($a) is one element"
  argv_has "Edit(//$repo_top/$a)" "Edit(//<root>/$a) is one element: the absolute form survives a cd inside the child"
done
argv_has "Skill(gantry:handover)" "Skill(gantry:handover) is one element: the nested plugin skill is allowed under dontAsk"
for s in run_gates.sh ensure_excluded.sh detect_stage.sh diff_fingerprint.sh; do
  argv_has "Bash(bash $GANTRY_ROOT/lib/$s:*)" "the unquoted Bash rule for $s is verbatim"
  argv_has "Bash(bash \"$GANTRY_ROOT/lib/$s\":*)" "the double-quoted Bash rule for $s is verbatim"
done
argv_lacks "--model" "no --model when none was given"
argv_lacks "--effort" "no --effort when none was given"
argv_lacks "--plugin-dir" "no --plugin-dir when none was given"
argv_lacks "--disallowedTools" "no --disallowedTools: the boundary is an allowlist"
argv_lacks "--lead" "no --lead: a print-mode child cannot wait for a reply"
argv_lacks "--dangerously-skip-permissions" "never --dangerously-skip-permissions"

# The last flag must be --allowedTools, because it is variadic and swallows
# everything after it.
last_flag=''
for e in "${ARGV[@]}"; do case "$e" in --*) last_flag="$e" ;; esac; done
if [ "$last_flag" = "--allowedTools" ]; then
  _pass "--allowedTools is the last flag, so no rule is read as a prompt"
else
  _fail "--allowedTools must be the last flag; the last was $last_flag"
fi

# The report lines, in order, with the result block last.
assert_contains "$(line_of SESSION:)"  "SESSION:sess-1"        "SESSION: is the child's session id"
assert_contains "$(line_of MODEL:)"    "MODEL:claude-sonnet-5" "MODEL: is the modelUsage key"
assert_contains "$(line_of EFFORT:)"   "EFFORT:inherit"        "EFFORT: is inherit when none was passed"
assert_contains "$(line_of TURNS:)"    "TURNS:7"               "TURNS: is num_turns"
assert_contains "$(line_of SUBTYPE:)"  "SUBTYPE:success"       "SUBTYPE: is the subtype"
assert_contains "$(line_of COST_USD:)" "COST_USD:0.5"          "COST_USD: is total_cost_usd"
assert_contains "$(line_of DENIALS:)"  "DENIALS:0"             "DENIALS: is the count"
assert_contains "$(line_of RESULT_FILE:)" "$repo/.claude/artifacts/headless/review.json" \
  "RESULT_FILE: names the result under .claude/artifacts/headless/"
assert_not_contains "$(printf '%s\n' "$L_OUT" | sed '/^RESULT_BEGIN$/,$d')" "REASON:" \
  "no REASON: line above the result block on success"
assert_not_contains "$L_OUT" "GATE_EXIT:" "no GATE_EXIT: after a review (only review-fix has one)"

first_line="$(printf '%s\n' "$L_OUT" | sed -n '1p')"
last_line="$(printf '%s\n' "$L_OUT" | sed -n '$p')"
assert_contains "$first_line" "SESSION:" "SESSION: is the first line, nothing before it"
assert_contains "$last_line" "RESULT_END" "RESULT_END is the last line"
between="$(printf '%s\n' "$L_OUT" | sed -n '/^RESULT_BEGIN$/,/^RESULT_END$/p')"
assert_contains "$between" "SESSION: this is the child quoting the vocabulary" \
  "the result text, vocabulary and all, sits inside RESULT_BEGIN … RESULT_END"
# Line order: each label's line number must be below the next's.
order_ok=1
prev=0
for label in SESSION: MODEL: EFFORT: TURNS: SUBTYPE: COST_USD: DENIALS: RESULT_FILE: RESULT_BEGIN; do
  n="$(printf '%s\n' "$L_OUT" | grep -n -m1 "^$label" | cut -d: -f1)"
  [ -n "$n" ] && [ "$n" -gt "$prev" ] || order_ok=0
  prev="${n:-$prev}"
done
[ "$order_ok" -eq 1 ] && _pass "the labeled lines come in the documented order" \
  || _fail "the labeled lines are out of order"

assert_path_present "$repo/.claude/artifacts/headless/review.json" "the child's stdout is kept as review.json"
assert_path_present "$repo/.claude/artifacts/headless/review.err"  "and its stderr as review.err"
assert_path_present "$repo/.claude/artifacts/headless/review.done" "and .done is touched after both"

# The exclusions are asserted before the launch — all four artifacts plus the
# result directory — in the exclude file git actually reads for this repo.
excl="$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)"
for p in /task.md /plan.md /handover.md /review.md .claude/artifacts/; do
  assert_file_contains "$excl" "^$(printf '%s' "$p" | sed 's/[.\/]/\\&/g')\$" "$p is excluded before the child runs"
done

# --- review: the optional flags reach the child, and only when given ---------------------

plugin_copy="$CASE_TMP/plugin-copy"
mkdir -p "$plugin_copy/lib"
write_task "$repo" implemented
run_launcher review "$SUCCESS_JSON" 0 --phase review --root "$repo" \
  --tier medium --model sonnet --effort low --plugin-dir "$plugin_copy" --max-turns 30
assert_rc 0 "$L_RC" "a review with every optional flag is still exit 0"
load_argv
argv_has "/gantry:review --headless --tier medium" "--tier is forwarded unchanged inside the prompt"
argv_has "--model" "--model is passed when given"
assert_contains "$(argv_value_after --model)" "sonnet" "and carries the alias"
argv_has "--effort" "--effort is passed when given"
assert_contains "$(argv_value_after --effort)" "low" "and carries the level"
argv_has "--plugin-dir" "--plugin-dir is forwarded when given"
assert_contains "$(argv_value_after --plugin-dir)" "$plugin_copy" "and names the directory"
assert_contains "$(argv_value_after --max-turns)" "30" "--max-turns is forwarded when given"
assert_contains "$(line_of EFFORT:)" "EFFORT:low" "EFFORT: reports the level that was passed"
argv_has "Bash(bash $plugin_copy/lib/run_gates.sh:*)" \
  "with --plugin-dir the Bash rules name the forwarded plugin, which is the root the child resolves"
argv_lacks "Bash(bash $GANTRY_ROOT/lib/run_gates.sh:*)" "and not the launcher's own root"

# --- review-fix: acceptEdits, no Edit( rule, GATE_EXIT from the applied line --------------

printf '# Review\nbranch: feat/headless\n\n## Address now\n- `a.sh:3` — wrong.\n' > "$repo/review.md"
write_task "$repo" reviewed
run_launcher applied "$SUCCESS_JSON" 0 --phase review-fix --root "$repo"
assert_rc 0 "$L_RC" "a review-fix child that appended applied: is exit 0"
load_argv
argv_has "/gantry:review --fix --headless" "the fix prompt is one element"
argv_has "acceptEdits" "the fix child gets acceptEdits"
argv_lacks "dontAsk" "and not dontAsk"
argv_lacks_prefix "Edit(" "the fix child has no Edit( rule"
argv_has "Skill(gantry:handover)" "the fix child may invoke gantry:handover too"
argv_has "gantry-review-fix-feat-headless" "its --name says review-fix"
for s in run_gates.sh ensure_excluded.sh detect_stage.sh diff_fingerprint.sh; do
  argv_has "Bash(bash $GANTRY_ROOT/lib/$s:*)" "the fix child keeps the unquoted Bash rule for $s"
  argv_has "Bash(bash \"$GANTRY_ROOT/lib/$s\":*)" "and the double-quoted one"
done
assert_contains "$(line_of GATE_EXIT:)" "GATE_EXIT:0" "GATE_EXIT: is parsed from the applied: line"
assert_contains "$(line_of RESULT_FILE:)" "review-fix.json" "the fix result file is named by phase"

printf '# Review\nbranch: feat/headless\n\n## Address now\n- `a.sh:3` — wrong.\n' > "$repo/review.md"
run_launcher applied-red "$SUCCESS_JSON" 0 --phase review-fix --root "$repo"
assert_rc 0 "$L_RC" "a red gate recorded by the fix child is still a phase that ran (exit 0)"
assert_contains "$(line_of GATE_EXIT:)" "GATE_EXIT:1" "and GATE_EXIT: carries the red exit for the driver"

printf '# Review\nbranch: feat/headless\n\n## Address now\n- `a.sh:3` — wrong.\n' > "$repo/review.md"
run_launcher none "$SUCCESS_JSON" 0 --phase review-fix --root "$repo"
assert_rc 1 "$L_RC" "a fix child that reported success but appended no applied: line is exit 1"
assert_contains "$(line_of REASON:)" "applied:" "and REASON: says which line is missing"
assert_contains "$(line_of GATE_EXIT:)" "GATE_EXIT:-" "GATE_EXIT: is - when nothing could be parsed"

# Same rule as lib/detect_stage.sh: only the LAST non-blank line counts. A fix
# child that wrote `applied:` and then kept writing has not ended the file the
# way step 5 says, and the launcher must not read a gate result the detector
# will not.
printf '# Review\nbranch: feat/headless\n\n## Address now\n- `a.sh:3` — wrong.\n' > "$repo/review.md"
run_launcher applied-mid "$SUCCESS_JSON" 0 --phase review-fix --root "$repo"
assert_rc 1 "$L_RC" "an applied: line that is not the last line of review.md is not applied (exit 1)"
assert_contains "$(line_of REASON:)" "applied:" "and REASON: names the missing trailing line"

# --- review: success without the artifact is a failed phase ------------------------------

rm -f "$repo/review.md"
write_task "$repo" implemented
run_launcher status-only "$SUCCESS_JSON" 0 --phase review --root "$repo"
assert_rc 1 "$L_RC" "success with no review.md is exit 1"
assert_contains "$(line_of REASON:)" "no review.md" "and REASON: names the missing artifact"
assert_contains "$(line_of SESSION:)" "SESSION:sess-1" "the session id is still reported on failure"

rm -f "$repo/review.md"
write_task "$repo" implemented
run_launcher review-only "$SUCCESS_JSON" 0 --phase review --root "$repo"
assert_rc 1 "$L_RC" "success with review.md but a status that is not reviewed/blocked is exit 1"
assert_contains "$(line_of REASON:)" "implemented" "and REASON: quotes the status found"

rm -f "$repo/review.md"
write_task "$repo" implemented
run_launcher review-blocked "$SUCCESS_JSON" 0 --phase review --root "$repo"
assert_rc 0 "$L_RC" "a blocked verdict is a review that happened: exit 0"

# --- the JSON says the child did not complete ----------------------------------------------

rm -f "$repo/review.md"
write_task "$repo" implemented
ERR_JSON='{"session_id":"sess-2","subtype":"error_during_execution","is_error":true,"terminal_reason":"completed","num_turns":2,"total_cost_usd":0.1,"modelUsage":{},"permission_denials":[],"result":"boom"}'
run_launcher review "$ERR_JSON" 0 --phase review --root "$repo"
assert_rc 1 "$L_RC" "is_error true is exit 1 even with the artifacts on disk"
assert_contains "$(line_of REASON:)" "is_error=true" "and REASON: says so"
assert_contains "$(line_of MODEL:)" "MODEL:-" "MODEL: is - when modelUsage is empty"

rm -f "$repo/review.md"
write_task "$repo" implemented
MAX_JSON='{"session_id":"sess-3","subtype":"error_max_turns","is_error":false,"terminal_reason":"max_turns","num_turns":80,"total_cost_usd":3,"modelUsage":{},"permission_denials":[],"result":""}'
run_launcher review "$MAX_JSON" 0 --phase review --root "$repo"
assert_rc 1 "$L_RC" "terminal_reason max_turns is exit 1"
assert_contains "$(line_of REASON:)" "max_turns" "and REASON: names it"

# --- claude itself failed ----------------------------------------------------------------

rm -f "$repo/review.md"
write_task "$repo" implemented
L_OUT="$(FAKE_CLAUDE_WRITES=none FAKE_CLAUDE_JSON='' FAKE_CLAUDE_RC=7 FAKE_CLAUDE_STDERR='Not logged in' \
  bash "$LAUNCHER" --phase review --root "$repo" 2>&1)"; L_RC=$?
assert_rc 3 "$L_RC" "claude exiting non-zero is exit 3"
assert_contains "$(line_of REASON:)" "claude exited 7" "and REASON: carries its exit code"
assert_contains "$(line_of REASON:)" "Not logged in" "and the first stderr line"
assert_contains "$(line_of SESSION:)" "SESSION:-" "fields that could not be read print -"

run_launcher none "" 0 --phase review --root "$repo"
assert_rc 3 "$L_RC" "exit 0 with no JSON on stdout is exit 3"
assert_contains "$(line_of REASON:)" "no parseable JSON" "and REASON: says so"

run_launcher none "not json at all" 0 --phase review --root "$repo"
assert_rc 3 "$L_RC" "unparseable stdout is exit 3"

# --- permission denials are reported, never fatal on their own ---------------------------

rm -f "$repo/review.md"
write_task "$repo" implemented
DENY_JSON='{"session_id":"sess-4","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":9,"total_cost_usd":0.7,"modelUsage":{"claude-sonnet-5":{}},"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"python3 -m pytest\n-q"}},{"tool_name":"Edit","tool_input":{"file_path":"/x/calc.py"}}],"result":"done"}'
run_launcher review "$DENY_JSON" 0 --phase review --root "$repo"
assert_rc 0 "$L_RC" "denials alone do not change the exit code"
assert_contains "$(line_of DENIALS:)" "DENIALS:2" "DENIALS: counts them"
assert_contains "$L_OUT" "DENIED:Bash python3 -m pytest -q" \
  "each denial is one DENIED: line, a multi-line command flattened onto it"
assert_contains "$L_OUT" "DENIED:Edit /x/calc.py" "a denied edit names the path"

# --- a stale .done is gone before the child starts ------------------------------------------

rm -f "$repo/review.md"
write_task "$repo" implemented
mkdir -p "$repo/.claude/artifacts/headless"
: > "$repo/.claude/artifacts/headless/review.done"
printf 'stale\n' > "$repo/.claude/artifacts/headless/review.json"
run_launcher review "$SUCCESS_JSON" 0 --phase review --root "$repo"
assert_contains "$(cat "$FAKE_CLAUDE_DONE_SEEN")" "absent" \
  "the previous run's .done was removed before the child was launched"
assert_not_contains "$(cat "$repo/.claude/artifacts/headless/review.json")" "stale" \
  "and the previous run's result file was replaced"

# --- usage and environment are exit 2, and launch nothing ----------------------------------

rm -f "$FAKE_CLAUDE_ARGV"
L_OUT="$(bash "$LAUNCHER" --root "$repo" 2>&1)"; L_RC=$?
assert_rc 2 "$L_RC" "a missing --phase is a usage error"
L_OUT="$(bash "$LAUNCHER" --phase implement --root "$repo" 2>&1)"; L_RC=$?
assert_rc 2 "$L_RC" "an unknown phase is a usage error"
L_OUT="$(bash "$LAUNCHER" --phase review 2>&1)"; L_RC=$?
assert_rc 2 "$L_RC" "a missing --root is a usage error"
plain="$(mkdir_plain notarepo)"
L_OUT="$(bash "$LAUNCHER" --phase review --root "$plain" 2>&1)"; L_RC=$?
assert_rc 2 "$L_RC" "a --root that is not a git worktree is exit 2"
L_OUT="$(bash "$LAUNCHER" --phase review --root "$repo" --max-turns lots 2>&1)"; L_RC=$?
assert_rc 2 "$L_RC" "a non-integer --max-turns is a usage error"
L_OUT="$(bash "$LAUNCHER" --phase review --root "$repo" --plugin-dir "$CASE_TMP/nope" 2>&1)"; L_RC=$?
assert_rc 2 "$L_RC" "a --plugin-dir that does not exist is exit 2"
assert_path_absent "$FAKE_CLAUDE_ARGV" "none of those launched the child"
L_OUT="$(bash "$LAUNCHER" --phase review --root "$repo" --timeout 0 2>&1)"; L_RC=$?
assert_rc 2 "$L_RC" "a --timeout of zero is a usage error"
L_OUT="$(bash "$LAUNCHER" --phase review --root "$repo" --timeout soon 2>&1)"; L_RC=$?
assert_rc 2 "$L_RC" "a non-integer --timeout is a usage error"

# --- the child is detached from the launcher, and says so ---------------------------------
#
# WHY THIS IS A CASE AND NOT A COMMENT. A driver runs the launcher as a
# backgrounded Bash task, and a session reaps its own background tasks on a
# `memoryPressure` event from its runtime — regardless of host memory. One lane
# in the 2026-10-24 review A/B lost six review children that way. The child
# therefore has to be in a session of its own, and the launcher has to say which
# of the two paths it took, because "the review was reaped" and "the review
# found nothing" are not the same outcome and must not read the same.

run_launcher review "$SUCCESS_JSON" 0 --phase review --root "$repo"
assert_rc 0 "$L_RC" "a detached review child that completed is still exit 0"
assert_contains "$(cat "$FAKE_CLAUDE_REAP")" "1" \
  "CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1 reaches the child, so its own background tasks survive too"
if command -v setsid >/dev/null 2>&1; then
  assert_contains "$(printf '%s\n' "$L_OUT" | grep -m1 '^NOTE:.*detached')" "detached" \
    "NOTE: records that the child was detached, so a reader can tell the reaper could not reach it"
  # The child sits under the setsid wrapper, so its sid is the wrapper's pid,
  # not its own. What has to be true is that the sid is not OURS: the launcher
  # and the review must not share a session, or one signal takes both.
  own_sid="$(ps -o sid= -p $$ 2>/dev/null | tr -dc '0-9')"
  child_sid="$(cut -d: -f2 "$FAKE_CLAUDE_SID" | tr -dc '0-9')"
  if [ -z "$own_sid" ] || [ -z "$child_sid" ]; then
    _pass "session ids are not readable on this platform (ps -o sid unsupported); detach not asserted"
  elif [ "$child_sid" != "$own_sid" ]; then
    _pass "the child runs in a session of its own, so a signal to the launcher's session cannot reach it"
  else
    _fail "the child shares the launcher's session $own_sid: the reaper would take it too"
  fi
  assert_path_present "$repo/.claude/artifacts/headless/review.pid" \
    "the child's pid is on disk, so a relaunch can attach instead of reviewing twice"
else
  assert_contains "$(line_of NOTE:)" "no setsid" \
    "with no setsid the launcher says the child is exposed, rather than claiming it is safe"
fi

# --- a relaunch attaches to a live child rather than starting a second review -------------

# A live pid that leads ITS OWN session: the timeout path signals the group of a
# pid that leads one, and this case must not nominate the test suite's group.
setsid sleep 60 >/dev/null 2>&1 &
live_pid=$!
sleep 0.3
printf '%s\n' "$live_pid" > "$repo/.claude/artifacts/headless/review.pid"
rm -f "$repo/.claude/artifacts/headless/review.done" "$FAKE_CLAUDE_ARGV"
L_OUT="$(FAKE_CLAUDE_WRITES=review FAKE_CLAUDE_JSON="$SUCCESS_JSON" FAKE_CLAUDE_RC=0 \
  bash "$LAUNCHER" --phase review --root "$repo" --timeout 1 2>&1)"; L_RC=$?
assert_path_absent "$FAKE_CLAUDE_ARGV" \
  "a live pid with no .done launches no second child: the first review is not paid for twice"
assert_contains "$(printf '%s\n' "$L_OUT" | grep -m1 '^NOTE:.*attached')" "attached" \
  "and NOTE: says it attached to the pid it found"
assert_rc 1 "$L_RC" "the attached wait that never completes is exit 1, not a silent success"
assert_contains "$(printf '%s\n' "$L_OUT" | grep -m1 '^REASON:')" "did not finish within" \
  "and REASON: names the timeout, so a driver reports a review that did not happen"
sleep 0.3
if kill -0 "$live_pid" 2>/dev/null; then
  _fail "the timeout left the attached child running: pid $live_pid"
  kill -TERM "-$live_pid" 2>/dev/null || kill -TERM "$live_pid" 2>/dev/null || true
else
  _pass "the timeout stopped the child it was waiting on, rather than leaving it to bill in the dark"
fi

# A pid that is no longer alive is a stale file, not a child to wait for.
printf '%s\n' "4000000000" > "$repo/.claude/artifacts/headless/review.pid"
rm -f "$repo/.claude/artifacts/headless/review.done"
run_launcher review "$SUCCESS_JSON" 0 --phase review --root "$repo"
assert_rc 0 "$L_RC" "a dead pid in the .pid file does not block the next launch"
assert_path_present "$FAKE_CLAUDE_ARGV" "and the child really was launched"

finish
