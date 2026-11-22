#!/usr/bin/env bash
# heavy_slot.sh — a box-wide counting lock around one heavy command.
# Run with: bash heavy_slot.sh -- <command> [args...]
#
# WHY THIS EXISTS. A gate is the heaviest thing a lane does: a JS build, a test
# suite, a repo's own Postgres. On a small box several lanes gate at once — the
# in-run gate, herdr lane gates, integration gates — and on 2026-11-15 two
# Next.js builds plus a gate's Postgres took an 8 GB box out of memory. Every
# one of those goes through lib/run_gates.sh, which re-execs itself through this
# wrapper, so this is the one place a box-wide limit can live.
#
# WHAT IT DOES. Takes one of N slots, exports GANTRY_HEAVY_SLOT_HELD, runs the
# command in the foreground, releases the slot, and exits with the command's
# exit code VERBATIM — it never adds a code of its own to a command that ran.
# While every slot is busy it waits, polling once a second, and says what it is
# waiting for when the wait starts and every 60 s after. On acquiring it always
# prints one fixed line for the transcript (and so the run journal) to read:
#
#   == heavy-slot: acquired slot=<i> slots=<N> waited=<s>s ==
#
# NESTED GATES SKIP. GANTRY_HEAVY_SLOT_HELD is inherited by everything the
# command starts, and run_gates.sh does not come back here while it is set.
# Without that, gantry's own gate (.claude/gates.sh → scripts/verify.sh → tests
# that call run_gates.sh) would wait forever on the slot its outer run holds.
#
# KNOBS.
#   GANTRY_HEAVY_SLOTS     how many heavy commands may run at once (default 1).
#                          0 disables the lock. A non-count is noted and read as 1.
#   GANTRY_HEAVY_SLOT_DIR  where the slot files live (default
#                          /tmp/gantry-heavy-slots-<uid>). Deliberately not
#                          $TMPDIR: a sandboxed session can carry a per-session
#                          TMPDIR, which would make the lock per-session and
#                          silently not box-wide.
#
# THE SLOT. File `slot.<i>` in that directory, created with bash's own `set -C`
# (noclobber, O_CREAT|O_EXCL) — not `mkdir`, which is not exclusive under the
# uutils coreutils on GitHub runners (see lib/ensure_excluded.sh). The holder's
# line `<pid> <epoch> <dir>` is written in the same redirection that creates it.
#
# LIVENESS, NOT AGE. A gate legitimately holds a slot for many minutes, so a
# slot is dead only when its PID is gone. An empty or unparseable slot is the
# instant between create and write, and counts as live until it is a minute
# old. Stealing a dead slot goes through `slot.<i>.breaking`, itself taken with
# noclobber, and re-checks liveness inside it, so two waiters never remove each
# other's fresh slot. The breaker is held for an instant, so it IS broken by age.
#
# FAIL OPEN. If the directory cannot be created or written, the command runs
# unlocked with a note. This lock protects memory, not correctness; a /tmp
# problem must not turn every gate into a broken-environment exit.
#
# LIMITS. Box-wide only among processes that share this /tmp and PID namespace:
# a private /tmp makes the lock per-sandbox (point GANTRY_HEAVY_SLOT_DIR at a
# shared path), and a holder in another PID namespace looks dead and is stolen.
# A dead holder whose PID was reused keeps its slot until that process exits.
# There is no wait timeout; a caller's own timeout includes any wait.
# bash 3.2 compatible.
#
# A signal while the command runs is not trapped: it acts at once, as it did on
# run_gates.sh before this wrapper, and the slot it leaves behind is reclaimed
# by liveness.
#
# Exit codes: the command's own · 2 = usage · 130/143 = interrupted while waiting.
set -uo pipefail

note() { printf '== heavy-slot: %s ==\n' "$1"; }

[ "${1:-}" = "--" ] && shift
if [ "$#" -eq 0 ]; then
  printf 'usage: heavy_slot.sh -- <command> [args...]\n' >&2
  exit 2
fi

SLOTS="${GANTRY_HEAVY_SLOTS:-1}"
case "$SLOTS" in
  ''|*[!0-9]*) note "GANTRY_HEAVY_SLOTS='$SLOTS' is not a count; using 1"; SLOTS=1 ;;
esac
SLOTS=$((10#$SLOTS))

if [ "$SLOTS" -eq 0 ]; then
  note "disabled (GANTRY_HEAVY_SLOTS=0); running unlocked"
  GANTRY_HEAVY_SLOT_HELD=disabled; export GANTRY_HEAVY_SLOT_HELD
  exec "$@"
fi

DIR="${GANTRY_HEAVY_SLOT_DIR:-/tmp/gantry-heavy-slots-$(id -u 2>/dev/null || echo 0)}"
# The default path is predictable, so a directory another user planted (or a
# symlink to one) could hold forged slots that look live forever. Use it only
# if it is a real directory we own.
if ! mkdir -p "$DIR" 2>/dev/null || [ -L "$DIR" ] || [ ! -O "$DIR" ] || [ ! -w "$DIR" ]; then
  note "cannot use $DIR (not a writable directory owned by us); running UNLOCKED"
  GANTRY_HEAVY_SLOT_HELD=unlocked; export GANTRY_HEAVY_SLOT_HELD
  exec "$@"
fi

MINE=""

older_than_a_minute() { [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }

slot_alive() {  # slot_alive <file> — 0 if a live holder has it (or it is being written)
  local pid=""
  [ -e "$1" ] || return 1
  read -r pid _ <"$1" 2>/dev/null || true
  case "$pid" in
    ''|*[!0-9]*) older_than_a_minute "$1" && return 1; return 0 ;;
  esac
  kill -0 "$pid" 2>/dev/null && return 0
  # kill -0 also fails on EPERM — a live process that is not ours.
  ps -p "$pid" >/dev/null 2>&1
}

take() {  # take <i> — create slot.<i> with our holder line, only if absent
  ( set -C; printf '%s %s %s\n' "$$" "$(date +%s)" "$PWD" >"$DIR/slot.$1" ) 2>/dev/null
}

break_if_dead() {  # break_if_dead <i> — remove slot.<i> if its holder is gone
  local f="$DIR/slot.$1" b="$DIR/slot.$1.breaking"
  if [ -e "$b" ] && older_than_a_minute "$b"; then rm -f "$b" 2>/dev/null; fi
  ( set -C; : >"$b" ) 2>/dev/null || return 1
  if [ -e "$f" ] && ! slot_alive "$f"; then rm -f "$f" 2>/dev/null; fi
  rm -f "$b" 2>/dev/null
  return 0
}

describe() {  # one " slot<i> pid=… held=…s root=…" per busy slot
  local i=0 pid since root now
  now="$(date +%s)"
  while [ "$i" -lt "$SLOTS" ]; do
    pid=""; since=""; root=""
    if [ -e "$DIR/slot.$i" ]; then
      read -r pid since root <"$DIR/slot.$i" 2>/dev/null || true
      case "$since" in ''|*[!0-9]*) since="$now" ;; esac
      printf ' slot%s pid=%s held=%ss root=%s' "$i" "${pid:-?}" "$((now - since))" "${root:-?}"
    fi
    i=$((i + 1))
  done
}

release() {
  local pid=""
  if [ -n "$MINE" ] && [ -e "$MINE" ]; then
    read -r pid _ <"$MINE" 2>/dev/null || true
    [ "$pid" = "$$" ] && rm -f "$MINE" 2>/dev/null
  fi
  MINE=""
  return 0
}
trap 'release' EXIT
trap 'release; exit 130' INT
trap 'release; exit 143' TERM

SECONDS=0
next_log=0
got=""
while :; do
  i=0
  while [ "$i" -lt "$SLOTS" ]; do
    if take "$i"; then got="$i"; break; fi
    i=$((i + 1))
  done
  [ -n "$got" ] && break

  stole=0
  i=0
  while [ "$i" -lt "$SLOTS" ]; do
    if [ -e "$DIR/slot.$i" ] && ! slot_alive "$DIR/slot.$i"; then
      # Counted only if the slot is really gone: a removal that failed must
      # fall through to the sleep below, not spin.
      break_if_dead "$i"
      [ -e "$DIR/slot.$i" ] || stole=1
    fi
    i=$((i + 1))
  done
  [ "$stole" -eq 1 ] && continue

  if [ "$SECONDS" -ge "$next_log" ]; then
    note "waiting after ${SECONDS}s — $SLOTS/$SLOTS busy:$(describe)"
    next_log=$((SECONDS + 60))
  fi
  sleep 1
done

MINE="$DIR/slot.$got"
note "acquired slot=$got slots=$SLOTS waited=${SECONDS}s"
GANTRY_HEAVY_SLOT_HELD="$MINE"; export GANTRY_HEAVY_SLOT_HELD
# Back to default INT/TERM for the command's run. bash defers a trapped signal
# until the foreground child exits, so keeping the traps would make `kill` on
# the gate (whose PID is ours, since run_gates.sh execs into us) do nothing
# until the gate finished, then report 143 for it. Killed by a signal, we leave
# the slot file behind; its PID is gone, so the next waiter steals it back.
trap - INT TERM
"$@"
rc=$?
release
exit "$rc"
