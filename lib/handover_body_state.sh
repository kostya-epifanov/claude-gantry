#!/usr/bin/env bash
# handover_body_state.sh — is this pull request body carrying the current
# handover?
# Run with: bash handover_body_state.sh [--section qa] <body-file> <handover-file>
#       or: bash handover_body_state.sh [--section qa] --marker <handover-file>
#
# WHY THIS EXISTS. `gantry:ship` composes the PR body once, when it CREATES the
# pull request. A `handover.md` written after that — which is the usual order,
# since `gantry:review` is what produces one — never reaches anybody: the body
# still says no handover exists while the file holds verified findings, and the
# worktree holding the only copy is one merge away from being pruned. Ship can
# now refresh the body, and this answers the question that decides whether it
# needs to.
#
# THE RULE, DELIBERATELY CRUDE. Ship writes an HTML comment carrying a digest of
# `handover.md` under the handover heading — invisible in GitHub's rendering:
#
#     <!-- gantry:handover sha256=<first 12 hex> -->
#
# Both the marker and the heading are looked for OUTSIDE fenced blocks, so a
# body that quotes either in an example does not count as carrying one.
#
#   - marker present and equal         -> CURRENT.  Nothing else is CURRENT.
#   - marker present and different     -> STALE
#   - marker absent, heading present   -> STALE
#   - marker absent, heading absent    -> MISSING
#   - no handover file at all          -> NO-HANDOVER
#
# An earlier design tried to tell a correct older body from a wrong one by
# looking for each handover item's file citation in the body. That was cut:
# skills/handover/SKILL.md guarantees no such structure and explicitly admits
# items that cite no file, so the test was undefinable — and as written it
# refreshed bodies that were already right while leaving the motivating case
# matching no branch at all. The cost of the crude rule is that each pre-marker
# body is rewritten ONCE, which installs the marker and converges. A hand-edit
# INSIDE the section survives every later run as long as `handover.md` has not
# changed, which is the protection that actually matters.
#
# `--marker <handover-file>` prints the marker line for ship to embed, so the
# digest has exactly one definition rather than one per call site.
#
# `--section qa` asks the same question of `qa.md` and the `## Exercised by this
# run` section, with its own marker (`<!-- gantry:qa sha256=… -->`). The case is
# the same shape: `/gantry:qa` re-run after the pull request opened — a repo
# that opted in late, or a `--fix` pass — leaves a body that still reports the
# old outcome, typically "no qa agent" over scenarios that have since passed.
# With no qa.md the answer is NO-QA. The section defaults to `handover`, so
# every existing call keeps its meaning.
#
# stdout: one word — CURRENT | STALE | MISSING | NO-HANDOVER (NO-QA under
# --section qa) — or, under --marker, the marker line.
# Exit codes: 0 = answered · 2 = usage, or no SHA-256 tool on PATH.
set -uo pipefail

die() { printf 'handover_body_state: %s\n' "$1" >&2; exit 2; }

# Ship's heading, fixed. Its absence is information — see skills/ship/SKILL.md,
# which fixes the spelling for the same reason the "Not proven by this run"
# heading is fixed.
HEADING='## Deliberately not done'
MARKER_PREFIX='<!-- gantry:handover sha256='
ABSENT_WORD='NO-HANDOVER'

if [ "${1:-}" = "--section" ]; then
  case "${2:-}" in
    handover) ;;
    qa) HEADING='## Exercised by this run'
        MARKER_PREFIX='<!-- gantry:qa sha256='
        ABSENT_WORD='NO-QA' ;;
    *)  die "--section takes handover or qa" ;;
  esac
  shift 2
fi

# Portability: GNU coreutils has sha256sum, macOS has shasum, and openssl is
# the fallback where neither is. Resolved HERE, at the top level, so a machine
# with none of the three exits 2 (the check could not run) — inside a function
# called from a command substitution, `die` would exit only the subshell and the
# script would carry on with an empty digest, i.e. a quiet STALE that rewrites
# the body on every run.
if   command -v sha256sum >/dev/null 2>&1; then SHA_TOOL=sha256sum
elif command -v shasum    >/dev/null 2>&1; then SHA_TOOL=shasum
elif command -v openssl   >/dev/null 2>&1; then SHA_TOOL=openssl
else die "no sha256sum, shasum or openssl on PATH"
fi

digest_of() {  # digest_of <file> — first 12 hex of its SHA-256, or nothing
  local f="$1" out=''
  case "$SHA_TOOL" in
    sha256sum) out="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" ;;
    shasum)    out="$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1)" ;;
    openssl)   out="$(openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}')" ;;
  esac
  printf '%s' "$out" | cut -c1-12
}

if [ "${1:-}" = "--marker" ]; then
  [ "$#" -eq 2 ] || die "usage: handover_body_state.sh --marker <handover-file>"
  [ -f "$2" ] || die "no such handover file: $2"
  MARK="$(digest_of "$2")"
  [ -n "$MARK" ] || die "could not digest $2"
  printf '%s%s -->\n' "$MARKER_PREFIX" "$MARK"
  exit 0
fi

[ "$#" -eq 2 ] || die "usage: handover_body_state.sh <body-file> <handover-file>"
BODY_FILE="$1"
HANDOVER_FILE="$2"

if [ ! -f "$HANDOVER_FILE" ]; then
  echo "$ABSENT_WORD"
  exit 0
fi

[ -f "$BODY_FILE" ] || die "no such body file: $BODY_FILE"

WANT="$(digest_of "$HANDOVER_FILE")"
[ -n "$WANT" ] || die "could not digest $HANDOVER_FILE"

# CR is stripped before anything is matched, for the same reason
# lib/splice_pr_section.sh strips it: a body that came back with CRLF would
# otherwise never match the marker and would be rewritten on every run.
BODY="$(tr -d '\r' <"$BODY_FILE")"

# Found with index(), not a regex: the marker is a literal string carrying `<`,
# `!`, `-` and `=`, and building a pattern out of it would mean escaping it
# correctly in two languages.
#
# FENCED LINES ARE SKIPPED, exactly as the heading scan below skips them, and
# for a sharper reason than symmetry: this repository DOCUMENTS the marker, so a
# pull request body explaining the mechanism is the likely place to quote one.
# A quoted marker above the real section wins otherwise, because the scan stops
# at the first hit — a wrong digest in a fence pins the body to STALE, and ship
# then re-splices and `gh pr edit`s on every run, clobbering any hand-edit
# inside the section each time; a right one pins it to CURRENT and suppresses
# the refresh this file exists to trigger.
GOT="$(printf '%s\n' "$BODY" | awk -v p="$MARKER_PREFIX" '
  { l = $0; sub(/[ \t]+$/, "", l)
    if (l ~ /^ {0,3}(```|~~~)/) { infence = !infence; next }
    if (infence) next
    i = index($0, p)
    if (i) { rest = substr($0, i + length(p))
             if (match(rest, /^[0-9a-f]+/)) { print substr(rest, 1, RLENGTH); exit } } }
')"

if [ -n "$GOT" ]; then
  if [ "$GOT" = "$WANT" ]; then echo "CURRENT"; else echo "STALE"; fi
  exit 0
fi

# No marker. Whether the heading is there decides STALE (a body written before
# this check existed, or hand-written) from MISSING (no handover section at all).
# Matched outside fenced blocks, so a body quoting the heading in an example
# does not count as carrying one.
if printf '%s\n' "$BODY" | awk -v h="$HEADING" '
  { l = $0; sub(/[ \t]+$/, "", l)
    if (l ~ /^ {0,3}(```|~~~)/) { infence = !infence; next }
    if (!infence && l == h) { found = 1 } }
  END { exit (found ? 0 : 1) }
'; then
  echo "STALE"
else
  echo "MISSING"
fi
