#!/usr/bin/env bash
#
# lib/journal_append.sh and lib/ensure_excluded.sh — the two scripts that let an
# orchestrator journal, and exclude its artifacts, without putting a command
# substitution or a compound command in its own argv. A worktree-isolated
# session refuses those, and the observed workaround was a lane that called
# `date` once and estimated the rest of its timestamps: an accurate event
# ordering with a fictional clock. So the assertions that matter most here are
# not "did it write JSON" but "could a caller have chosen the timestamp" and
# "does the line land in the right tree".
#
# The exclusion half is the same story from the other side: six lanes sharing
# one .git/info/exclude, where a read-then-append double-appends. Two sequential
# runs cannot fail a lock that never locks, so there is a real concurrent case
# below.
#
# This case defines its own runners rather than adding to tests/lib.sh, so that
# it cannot collide with parallel work on that file.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

JOURNAL_APPEND="$GANTRY_ROOT/lib/journal_append.sh"
ENSURE_EXCLUDED="$GANTRY_ROOT/lib/ensure_excluded.sh"

if ! command -v jq >/dev/null 2>&1; then
  # A skipped case is a false green; see tests/lib.sh's header.
  _fail "jq is required by these scripts and by scripts/verify.sh, but is not installed"
  finish
fi

# The suite runs with cwd at the repo root and ensure_excluded.sh defaults to
# the exclude file git resolves from cwd — which from a worktree is the MAIN
# repository's. A forgotten --file would corrupt the very file this change
# repairs, so take a fingerprint now and check it at the end.
REAL_EXCLUDE="$(git rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null || printf '')"
REAL_EXCLUDE_BEFORE=''
[ -f "$REAL_EXCLUDE" ] && REAL_EXCLUDE_BEFORE="$(cksum < "$REAL_EXCLUDE")"

# run_journal [args...] — sets J_OUT and J_RC.
run_journal() {
  J_OUT="$(bash "$JOURNAL_APPEND" "$@" 2>&1)"
  J_RC=$?
  return 0
}

# run_exclude [args...] — sets E_OUT and E_RC.
run_exclude() {
  E_OUT="$(bash "$ENSURE_EXCLUDED" "$@" 2>&1)"
  E_RC=$?
  return 0
}

assert_eq() {  # assert_eq <expected> <actual> <label>
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 — expected '$1', got '$2'"; fi
}

jqf() {  # jqf <file> <filter> — the filter applied to the file's first line
  head -1 "$1" | jq -r "$2" 2>/dev/null
}

J="$CASE_TMP/journal.jsonl"

# --- one line, valid JSON, the documented fields ------------------------------

run_journal --task T --event stage --from plan --to implement --file "$J"
assert_rc 0 "$J_RC" "a stage event is accepted"
assert_eq 1 "$(wc -l < "$J" | tr -d ' ')" "exactly one line is appended"
if jq -e . "$J" >/dev/null 2>&1; then
  _pass "jq -e . accepts the line"
else
  _fail "jq -e . rejects the line"
fi
assert_eq stage     "$(jqf "$J" .event)" "event survives"
assert_eq plan      "$(jqf "$J" .from)"  "from survives"
assert_eq implement "$(jqf "$J" .to)"    "to survives"
assert_eq T         "$(jqf "$J" .task)"  "task survives"

# --- append-only --------------------------------------------------------------
#
# The guarantee is structural — the script has no rewrite path at all — but the
# regression this protects against is someone adding one.

first_line_before="$(head -1 "$J")"
run_journal --task T --event stage --to review --file "$J"
assert_eq 2 "$(wc -l < "$J" | tr -d ' ')" "a second call appends rather than rewrites"
assert_eq "$first_line_before" "$(head -1 "$J")" "and leaves the first line byte-identical"

# --- the timestamp is the script's, not the caller's ---------------------------
#
# Compared as STRINGS. ISO-8601 UTC at second precision sorts lexicographically
# in chronological order, so this needs neither GNU `date -d` nor BSD
# `date -j -f` — which are mutually exclusive, and the BSD form parses local
# time, so a developer outside UTC would see a parsed comparison fail by their
# whole offset.

TS_FILE="$CASE_TMP/ts.jsonl"
before="$(date -u +%FT%TZ)"
run_journal --task T --event stage --to implement --file "$TS_FILE"
after="$(date -u +%FT%TZ)"
ts="$(jqf "$TS_FILE" .ts)"

if [ "$ts" \> "$before" ] || [ "$ts" = "$before" ]; then
  _pass "ts is at or after a clock reading taken just before the call"
else
  _fail "ts ($ts) predates the call (before=$before)"
fi
if [ "$ts" \< "$after" ] || [ "$ts" = "$after" ]; then
  _pass "ts is at or before a clock reading taken just after the call"
else
  _fail "ts ($ts) postdates the call (after=$after)"
fi

# The half that actually carries the guarantee: "close to now" is also true of a
# caller-supplied `now`, so the refusal is what makes the timestamp trustworthy.
TS_REFUSE="$CASE_TMP/ts-refused.jsonl"
run_journal --task T --event stage --to implement --ts 2020-01-01T00:00:00Z --file "$TS_REFUSE"
assert_rc 2 "$J_RC" "--ts is refused rather than ignored"
assert_contains "$J_OUT" "--ts is not accepted" "and the refusal says why"
assert_path_absent "$TS_REFUSE" "a refused call appends nothing"

# --- escaping ------------------------------------------------------------------
#
# The reason the object is built by jq rather than by a printf template.

ESC="$CASE_TMP/escaped.jsonl"
tricky='he said "no"
and then a newline'
run_journal --task T --event phase --phase review --result ok --summary "$tricky" --file "$ESC"
assert_rc 0 "$J_RC" "a summary containing a quote and a newline is accepted"
assert_eq 1 "$(wc -l < "$ESC" | tr -d ' ')" "and still occupies exactly one line"
assert_eq "$tricky" "$(jq -r .summary "$ESC")" "and round-trips byte-for-byte through jq -r"

# --- the five shapes ------------------------------------------------------------

SHAPES="$CASE_TMP/shapes.jsonl"

run_journal --task T --event stage --to contract --mode unattended --file "$SHAPES"
assert_eq null "$(jqf "$SHAPES" '.from')" "stage with no --from emits a JSON null"
if [ "$(jqf "$SHAPES" '.from|type')" = "null" ]; then
  _pass "and it is a null, not the string \"null\""
else
  _fail "from is not a JSON null"
fi

rm -f "$SHAPES"
run_journal --task T --event phase --phase plan --result ok --file "$SHAPES"
assert_eq "[]" "$(jq -c .agents "$SHAPES")" "phase with no --agent emits agents: []"

rm -f "$SHAPES"
run_journal --task T --event phase --phase grill --result ok \
  --agent gantry-critic --agent second-critic --file "$SHAPES"
assert_eq 'gantry-critic second-critic' "$(jq -r '.agents|join(" ")' "$SHAPES")" \
  "two --agent flags become an array in order"

rm -f "$SHAPES"
run_journal --task T --event gate --result fail --exit 1 --attempt 2 \
  --check lint --check test --file "$SHAPES"
assert_rc 0 "$J_RC" "a gate event is accepted"
if [ "$(jqf "$SHAPES" '.exit|type')" = "number" ] && [ "$(jqf "$SHAPES" '.attempt|type')" = "number" ]; then
  _pass "exit and attempt are JSON numbers, not strings"
else
  _fail "exit/attempt are not numbers"
fi
assert_eq 'lint test' "$(jq -r '.checks|join(" ")' "$SHAPES")" "checks becomes an array"

rm -f "$SHAPES"
run_journal --task T --event decision --stage plan \
  --question 'proceed?' --answer 'proceed, reuse the handler' --file "$SHAPES"
assert_rc 0 "$J_RC" "a decision event is accepted"
assert_eq 'proceed, reuse the handler' "$(jqf "$SHAPES" .answer)" "and carries the answer"

rm -f "$SHAPES"
run_journal --task T --event escalation --stage plan --reason open-fork \
  --detail 'Postgres or SQLite?' --detail 'and who migrates?' --status blocked --file "$SHAPES"
assert_rc 0 "$J_RC" "an escalation event is accepted"
# The key is `detail`, singular, where its siblings are plural. An implementer
# applying "add an s" breaks the documented shape, and only this catches it.
assert_eq 'Postgres or SQLite?' "$(jq -r '.detail[0]' "$SHAPES")" \
  "escalation carries detail (singular) as an array"

# --- the shape is enforced, not merely transcribed -------------------------------
#
# Without these, "emitted with the fields its shape specifies" is true only of
# the exact calls made above.

BAD="$CASE_TMP/bad.jsonl"

run_journal --task T --event nonsense --to x --file "$BAD"
assert_rc 2 "$J_RC" "an unknown --event is refused"

run_journal --event stage --to x --file "$BAD"
assert_rc 2 "$J_RC" "a missing --task is refused"

run_journal --task T --event stage --file "$BAD"
assert_rc 2 "$J_RC" "an event missing a required field is refused"

run_journal --task T --event stage --to x --question 'nope' --file "$BAD"
assert_rc 2 "$J_RC" "a flag that belongs to another event is refused"

run_journal --task T --event gate --result pass --exit notanumber --file "$BAD"
assert_rc 2 "$J_RC" "a non-integer --exit is refused"

run_journal --task T --event stage --to x --file
assert_rc 2 "$J_RC" "a flag with no value is refused"

assert_path_absent "$BAD" "no refused call appended anything"

# --- the default path is the tree the call is made from ---------------------------
#
# The defect class tests/cases/hook_worktree_root.sh exists for. A call made
# from the launch checkout instead of the worktree would put every parallel
# lane's events into the main repository's journal, where the shared exclude
# then hides them — and nothing else here would notice.

wt_repo="$(mkrepo journal_default_path)"
wt="$(mkworktree "$wt_repo" lane_a)"
( cd "$wt" && bash "$JOURNAL_APPEND" --task T --event stage --to implement ) >/dev/null 2>&1
assert_path_present "$wt/journal.jsonl" "with no --file, the line lands at the worktree root"
assert_path_absent  "$wt_repo/journal.jsonl" "and not in the main checkout"

# --- ensure_excluded.sh ------------------------------------------------------------

EX="$CASE_TMP/exclude"
printf '# a comment\nunrelated-entry\n' > "$EX"

run_exclude --file "$EX" journal.jsonl .claude/artifacts/
assert_rc 0 "$E_RC" "the first exclusion write succeeds"
assert_contains "$E_OUT" "journal.jsonl" "and reports what it added"

run_exclude --file "$EX" journal.jsonl .claude/artifacts/
assert_rc 0 "$E_RC" "and running it again succeeds"
assert_eq '' "$E_OUT" "saying nothing the second time, because it added nothing"

assert_eq 1 "$(grep -c '^journal\.jsonl$' "$EX")"        "journal.jsonl appears exactly once after two runs"
assert_eq 1 "$(grep -c '^\.claude/artifacts/$' "$EX")"   ".claude/artifacts/ appears exactly once after two runs"
assert_eq 1 "$(grep -c '^unrelated-entry$' "$EX")"       "an unrelated entry is left alone"
assert_file_contains "$EX" '^# a comment$'               "and so is a comment"

# A pattern that is a substring of an existing entry must still be added — an
# unanchored grep -q would decide it was already present.
run_exclude --file "$EX" artifacts
assert_eq 1 "$(grep -c '^artifacts$' "$EX")" "a pattern that is a substring of another entry is still added"
assert_eq 1 "$(grep -c '^\.claude/artifacts/$' "$EX")" "and the entry containing it is untouched"

# Repair: a file a previous racing writer already corrupted.
DUP="$CASE_TMP/exclude-dup"
printf 'journal.jsonl\n# keep\njournal.jsonl\nkeep-me\njournal.jsonl\n' > "$DUP"
run_exclude --file "$DUP" journal.jsonl
assert_rc 0 "$E_RC" "a file with pre-existing duplicates is accepted"
assert_eq 1 "$(grep -c '^journal\.jsonl$' "$DUP")" "existing duplicates are collapsed to one"
assert_eq 1 "$(grep -c '^keep-me$' "$DUP")"        "unrelated lines survive the repair"
assert_file_contains "$DUP" '^# keep$'             "and so do comments"

# --- concurrency -------------------------------------------------------------------
#
# THE WRITERS MUST ASK FOR DIFFERENT PATTERNS. Eight lanes all requesting the
# same two patterns proves nothing: each writer rewrites through a temp file,
# de-duplicating as it copies, and renames atomically — so no interleaving can
# leave a duplicate whether the lock works or not. That assertion passes with
# the lock deleted outright.
#
# What the lock actually prevents is a LOST UPDATE: two lanes read the same
# original, each adds its own pattern, and the second rename erases the first's.
# That is the real interleaving in gantry — skills/worktree writes
# `**/.claude/worktrees/` to the shared exclude file while auto-unattended
# stage 1 writes journal.jsonl and .claude/artifacts/ to it — and it is only
# visible when the writers want different things.

RACE="$CASE_TMP/exclude-race"
: > "$RACE"
i=0
while [ "$i" -lt 8 ]; do
  bash "$ENSURE_EXCLUDED" --file "$RACE" "pat-$i" >/dev/null 2>&1 &
  i=$((i + 1))
done
wait

survived=0
i=0
while [ "$i" -lt 8 ]; do
  if grep -qxF "pat-$i" "$RACE"; then survived=$((survived + 1)); fi
  i=$((i + 1))
done
assert_eq 8 "$survived" "8 concurrent writers with distinct patterns all survive (no lost update)"

# And the duplicate property still holds when they all want the same thing.
SAME="$CASE_TMP/exclude-race-same"
: > "$SAME"
i=0
while [ "$i" -lt 8 ]; do
  bash "$ENSURE_EXCLUDED" --file "$SAME" journal.jsonl .claude/artifacts/ >/dev/null 2>&1 &
  i=$((i + 1))
done
wait
assert_eq 1 "$(grep -c '^journal\.jsonl$' "$SAME")"      "8 concurrent writers leave one journal.jsonl"
assert_eq 1 "$(grep -c '^\.claude/artifacts/$' "$SAME")" "8 concurrent writers leave one .claude/artifacts/"

# A lock left behind by a killed lane must not wedge every later run.
STALE="$CASE_TMP/exclude-stale"
: > "$STALE"
mkdir -p "$STALE.lock"
touch -t 200001010000 "$STALE.lock"
run_exclude --file "$STALE" journal.jsonl
assert_rc 0 "$E_RC" "a stale lock is broken rather than wedging the run"
assert_eq 1 "$(grep -c '^journal\.jsonl$' "$STALE")" "and the pattern is still written exactly once"

run_exclude --file "$CASE_TMP/nope"
assert_rc 2 "$E_RC" "calling it with no pattern is a usage error"

# --- the documentation matches the script -------------------------------------------
#
# A wrong flag name in the docs ships green and fails only in a headless run —
# which is precisely the failure this change exists to remove. This check lives
# here rather than in scripts/verify.sh because parallel work owns that file.

# Each documented command is RUN, not merely scanned for known flag names. A
# name-membership check passes `--ts` (a real case branch, whose body is a
# refusal) and passes `--event stage … --question X` (a real flag, wrong event) —
# both exit 2 in practice. Executing the line is the only check that tracks the
# script's actual contract as it grows.

DOCLINE="$CASE_TMP/docline.jsonl"
docs_ok=1
docs_seen=0
for doc in "$GANTRY_ROOT/skills/auto-unattended/SKILL.md" \
           "$GANTRY_ROOT/skills/auto-unattended/references/journal.md"; do
  [ -f "$doc" ] || continue
  # Only real invocations: a line that starts with `bash`, not prose that
  # happens to name the script.
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    docs_seen=$((docs_seen + 1))
    args="${cmd#*journal_append.sh\"}"
    # <...> marks a value the caller substitutes. --exit needs an integer;
    # everything else takes a single opaque token.
    args="$(printf '%s' "$args" | sed -e 's/<literal exit code>/0/' -e 's/<[^>]*>/PLACEHOLDER/g')"
    rm -f "$DOCLINE"
    # shellcheck disable=SC2086
    set -- $args
    if ! bash "$JOURNAL_APPEND" "$@" --file "$DOCLINE" >/dev/null 2>&1; then
      _fail "$(basename "$doc") documents a command the script refuses: $args"
      docs_ok=0
    fi
  done <<EOF
$(grep -hE '^[[:space:]]*bash .*journal_append\.sh' "$doc")
EOF
done

if [ "$docs_seen" -eq 0 ]; then
  _fail "found no documented journal_append.sh invocations to check — the extraction broke"
elif [ "$docs_ok" -eq 1 ]; then
  _pass "all $docs_seen documented journal_append.sh commands are accepted by the script"
fi

# --- the case did not touch the real exclude file --------------------------------------

if [ -n "$REAL_EXCLUDE_BEFORE" ]; then
  assert_eq "$REAL_EXCLUDE_BEFORE" "$(cksum < "$REAL_EXCLUDE")" \
    "the repository's own .git/info/exclude was not modified by this case"
fi

finish
