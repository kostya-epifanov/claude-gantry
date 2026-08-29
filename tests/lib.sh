#!/usr/bin/env bash
#
# tests/lib.sh — fixture builders and assertions, sourced by every case.
#
# WHY THIS IS SMALL. The thing under test is a shell script whose exit code is
# the entire contract (see docs/METHOD.md, "The contract is an integer"), so a
# test is: build a throwaway repo, run the script, compare one integer. No
# framework, no mocking, no harness emulation.
#
# ISOLATION. Every case gets one temp root ($CASE_TMP) and removes it on exit.
# Fixture repos are built inside it with `git init` plus inline
# `-c user.email` / `-c user.name`, so a case never reads or writes the
# developer's global git config.
#
# TOOLCHAIN INDEPENDENCE. Cases that need run_gates.sh to detect an ecosystem
# use `stub_cmd` to put a fake `npm` (or similar) on PATH rather than depending
# on a real toolchain. A gate test that silently skips because `node` is
# missing is a false green — precisely the failure this suite exists to catch.
#
# PORTABILITY. bash 3.2 (the macOS system bash) — no associative arrays, no
# `mapfile`, no `${var^^}`. And no absolute paths from the developer's machine
# may appear in these files: scripts/secret-scan.sh scans tracked files for
# `/Users/<name>` and friends. Always build paths from `mktemp -d`.

set -uo pipefail

TESTS_DIR="${TESTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
GANTRY_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

RUN_GATES="$GANTRY_ROOT/lib/run_gates.sh"
HOOK="$GANTRY_ROOT/hooks/readiness-gate.sh"
DETECT_STAGE="$GANTRY_ROOT/lib/detect_stage.sh"

FAILURES=0

# One temp root per case; `pwd -P` because macOS hands out /var/folders paths
# that are symlinks to /private/var, and `git rev-parse --show-toplevel`
# returns the physical form. Comparing the two would fail for the wrong reason.
CASE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gantry-test.XXXXXX")"
CASE_TMP="$(cd "$CASE_TMP" && pwd -P)"

_cleanup() {
  if [ -n "${CASE_TMP:-}" ] && [ -d "$CASE_TMP" ]; then
    rm -rf "$CASE_TMP"
  fi
  return 0
}
trap _cleanup EXIT

# --- assertions --------------------------------------------------------------

_pass() { printf '    ok    %s\n' "$1"; }
_fail() { printf '    FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

assert_rc() {  # assert_rc <expected> <actual> <label>
  if [ "$1" = "$2" ]; then
    _pass "$3 (rc $2)"
  else
    _fail "$3 — expected rc $1, got $2"
  fi
}

assert_contains() {  # assert_contains <haystack> <needle> <label>
  case "$1" in
    *"$2"*) _pass "$3" ;;
    *)      _fail "$3 — output missing: $2" ;;
  esac
}

assert_not_contains() {  # assert_not_contains <haystack> <needle> <label>
  case "$1" in
    *"$2"*) _fail "$3 — output unexpectedly contains: $2" ;;
    *)      _pass "$3" ;;
  esac
}

assert_path_present() {  # assert_path_present <path> <label>
  if [ -e "$1" ]; then _pass "$2"; else _fail "$2 — missing: $1"; fi
}

assert_path_absent() {  # assert_path_absent <path> <label>
  if [ ! -e "$1" ]; then _pass "$2"; else _fail "$2 — unexpectedly exists: $1"; fi
}

assert_file_contains() {  # assert_file_contains <file> <extended-regex> <label>
  if [ ! -f "$1" ]; then
    _fail "$3 — no such file: $1"
  elif grep -qE "$2" "$1"; then
    _pass "$3"
  else
    _fail "$3 — no line matching /$2/ in $1"
  fi
}

assert_file_lacks() {  # assert_file_lacks <file> <extended-regex> <label>
  if [ ! -f "$1" ]; then
    _pass "$3"
  elif grep -qE "$2" "$1"; then
    _fail "$3 — unexpected line matching /$2/ in $1"
  else
    _pass "$3"
  fi
}

finish() {
  if [ "$FAILURES" -gt 0 ]; then exit 1; fi
  exit 0
}

# --- fixtures ----------------------------------------------------------------

# mkrepo [name] — a throwaway git repo with one commit. Echoes its path.
mkrepo() {
  local name="${1:-repo}"
  local d="$CASE_TMP/$name"
  mkdir -p "$d"
  git -C "$d" init -q >/dev/null 2>&1
  printf 'seed\n' >"$d/README"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=test@example.invalid -c user.name=test \
    commit -qm seed >/dev/null 2>&1
  printf '%s' "$d"
}

# mkdir_plain [name] — a directory that is deliberately NOT a git repo.
mkdir_plain() {
  local d="$CASE_TMP/${1:-plain}"
  mkdir -p "$d"
  printf '%s' "$d"
}

# write_task <repo> <status> — a minimal well-formed task.md.
write_task() {
  printf -- '---\nstatus: %s\n---\n\n# task\n' "$2" >"$1/task.md"
}

# write_task_raw <repo> — task.md read verbatim from stdin, for parser cases.
write_task_raw() {
  cat >"$1/task.md"
}

# write_gates <repo> <exit-code> — a repo-owned gate that exits as told.
write_gates() {
  mkdir -p "$1/.claude"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "repo-gate ran"\n'
    printf 'exit %s\n' "$2"
  } >"$1/.claude/gates.sh"
}

# write_gates_body <repo> — a repo-owned gate whose body is read from stdin.
write_gates_body() {
  mkdir -p "$1/.claude"
  cat >"$1/.claude/gates.sh"
}

# stub_cmd <name> <exit-code> — put a fake executable early on PATH, so a gate
# case can exercise ecosystem detection without depending on a real toolchain.
stub_cmd() {
  local bin="$CASE_TMP/bin"
  mkdir -p "$bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exit %s\n' "$2"
  } >"$bin/$1"
  chmod +x "$bin/$1"
  PATH="$bin:$PATH"
  export PATH
}

# --- invocation --------------------------------------------------------------
#
# These runners set HOOK_OUT/HOOK_RC, GATE_OUT/GATE_RC and STAGE_OUT/STAGE_RC
# for the calling case to assert on. shellcheck cannot see across the `source`
# boundary into the cases, so it reads every one of them as written-never-read.
# shellcheck disable=SC2034

# hook_payload <stop_hook_active> <cwd> — the JSON the harness pipes to a hook.
hook_payload() {
  printf '{"hook_event_name":"Stop","stop_hook_active":%s,"cwd":"%s"}' "$1" "$2"
}

# run_hook <repo> [stop_hook_active] — sets HOOK_OUT and HOOK_RC.
# Runs the plugin's real hook against <repo>, exactly as the harness would.
# shellcheck disable=SC2034
run_hook() {
  local repo="$1" active="${2:-false}"
  HOOK_OUT="$(hook_payload "$active" "$repo" \
    | CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" 2>&1)"
  HOOK_RC=$?
  return 0
}

# run_hook_script <hook-path> <repo> — as above, against a specific copy of the
# hook (used to test a broken install, where lib/run_gates.sh is unreachable).
# CLAUDE_PLUGIN_ROOT is forced empty: the hook falls back to it when
# self-location fails, and inheriting a real one from the ambient environment
# would quietly repair the very breakage under test.
# shellcheck disable=SC2034
run_hook_script() {
  local hook="$1" repo="$2"
  HOOK_OUT="$(hook_payload false "$repo" \
    | CLAUDE_PROJECT_DIR="$repo" CLAUDE_PLUGIN_ROOT='' bash "$hook" 2>&1)"
  HOOK_RC=$?
  return 0
}

# run_gate <repo> [args...] — sets GATE_OUT and GATE_RC.
# shellcheck disable=SC2034
run_gate() {
  local repo="$1"; shift
  GATE_OUT="$(cd "$repo" && bash "$RUN_GATES" "$@" 2>&1)"
  GATE_RC=$?
  return 0
}

# run_stage <repo> — sets STAGE_OUT and STAGE_RC.
# shellcheck disable=SC2034
run_stage() {
  STAGE_OUT="$(cd "$1" && bash "$DETECT_STAGE" 2>&1)"
  STAGE_RC=$?
  return 0
}

# hooklog <repo> — path to the durable audit log.
hooklog() { printf '%s' "$1/.claude/artifacts/gate-hook.log"; }

# The per-run gate transcript is gate-<timestamp>-<pid>.log; the glob is
# anchored on a digit so it cannot match the audit log, gate-hook.log.
_gate_ran() { ls "$1"/.claude/artifacts/gate-[0-9]*.log >/dev/null 2>&1; }

assert_gate_ran() {  # assert_gate_ran <repo> <label>
  if _gate_ran "$1"; then _pass "$2"; else _fail "$2 — no gate transcript written"; fi
}

assert_gate_not_run() {  # assert_gate_not_run <repo> <label>
  if _gate_ran "$1"; then _fail "$2 — a gate transcript exists; the gate ran"; else _pass "$2"; fi
}
