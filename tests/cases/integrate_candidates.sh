#!/usr/bin/env bash
#
# list_candidates.sh decides which open pull requests /gantry:integrate will
# merge, and the whole point is that every PR it leaves out carries a reason a
# human can argue with at the checkpoint. That decision is a classifier over
# `gh`'s JSON, so it is tested as one: a fixture file in, labeled lines out, no
# network and no gh.
#
# The two rules worth the fixture are the ones that are easy to get backwards:
#
#   - CI:none is NOT ci-failing and NOT passing. An empty rollup means the PR's
#     own checks never ran; the gate over the combined tree is the check that
#     matters, so the PR stays a candidate and the class is carried through.
#   - A stacked PR whose parent is not coming along is skipped FOR THAT REASON,
#     not as "wrong base" — including a grandchild. It is the reason a reader
#     can act on.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

LIST="$GANTRY_ROOT/skills/integrate/scripts/list_candidates.sh"
FIX="$CASE_TMP/prs.json"
CALLED="$CASE_TMP/gh-was-called"

# A gh that records being run. Stripping gh from PATH is not an option — on a CI
# runner it shares a directory with git, bash and python3 — so instead it is
# replaced with something that leaves evidence, and the assertion is that no
# evidence appears.
mkdir -p "$CASE_TMP/bin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "called" > "%s"\n' "$CALLED"
  printf 'exit 97\n'
} >"$CASE_TMP/bin/gh"
chmod +x "$CASE_TMP/bin/gh"
PATH="$CASE_TMP/bin:$PATH"
export PATH

cat >"$FIX" <<'JSON'
[
  {"number":1,"title":"One, ready","url":"https://x/1","isDraft":false,
   "baseRefName":"master","headRefName":"feat/one","headRefOid":"aaa1",
   "mergeable":"MERGEABLE","reviewDecision":"APPROVED","labels":[],
   "createdAt":"2026-09-01T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}],
   "body":"## What this change is for\n\nthe contract.\n\n## Risk\nRisk level: high"},

  {"number":2,"title":"Two, changes requested","url":"https://x/2","isDraft":false,
   "baseRefName":"master","headRefName":"feat/two","headRefOid":"aaa2",
   "mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","labels":[],
   "createdAt":"2026-09-01T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":3,"title":"Three, labelled WIP","url":"https://x/3","isDraft":false,
   "baseRefName":"master","headRefName":"feat/three","headRefOid":"aaa3",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[{"name":"WIP"}],
   "createdAt":"2026-09-01T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":4,"title":"Four, red CI","url":"https://x/4","isDraft":false,
   "baseRefName":"master","headRefName":"fix/four","headRefOid":"aaa4",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-01T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"FAILURE"},
                        {"__typename":"CheckRun","name":"other","status":"COMPLETED","conclusion":"SUCCESS"}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":5,"title":"Five, CI still running","url":"https://x/5","isDraft":false,
   "baseRefName":"master","headRefName":"feat/five","headRefOid":"aaa5",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-01T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"QUEUED","conclusion":null}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":6,"title":"Six, no checks at all","url":"https://x/6","isDraft":false,
   "baseRefName":"master","headRefName":"feat/six","headRefOid":"aaa6",
   "mergeable":"UNKNOWN","reviewDecision":"","labels":[],
   "createdAt":"2026-09-01T10:00:00Z",
   "statusCheckRollup":[],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":7,"title":"Seven, a draft","url":"https://x/7","isDraft":true,
   "baseRefName":"master","headRefName":"feat/seven","headRefOid":"aaa7",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[{"name":"enhancement"}],
   "createdAt":"2026-09-02T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"SKIPPED"}],
   "body":"## What this change is for\n\nthe contract.\n\n## Risk\nRisk level: high"},

  {"number":8,"title":"Eight, stacked on one","url":"https://x/8","isDraft":true,
   "baseRefName":"feat/one","headRefName":"feat/eight","headRefOid":"aaa8",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-03T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":9,"title":"Nine, stacked on the red one","url":"https://x/9","isDraft":false,
   "baseRefName":"fix/four","headRefName":"feat/nine","headRefOid":"aaa9",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-03T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":10,"title":"Ten, stacked on nine","url":"https://x/10","isDraft":false,
   "baseRefName":"feat/nine","headRefName":"feat/ten","headRefOid":"aaa10",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-03T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":11,"title":"Eleven, another base entirely","url":"https://x/11","isDraft":false,
   "baseRefName":"release/1.x","headRefName":"feat/eleven","headRefOid":"aaa11",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-03T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"SUCCESS"}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":12,"title":"An integration PR","url":"https://x/12","isDraft":false,
   "baseRefName":"master","headRefName":"integration/2026-09-14","headRefOid":"aaa12",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-14T10:00:00Z",
   "statusCheckRollup":[],
   "body":"integration"},

  {"number":13,"title":"Thirteen, a red commit status","url":"https://x/13","isDraft":false,
   "baseRefName":"master","headRefName":"feat/thirteen","headRefOid":"aaa13",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-03T10:00:00Z",
   "statusCheckRollup":[{"__typename":"StatusContext","context":"ci/external","state":"ERROR"}],
   "body":"plain body\n\n## Risk\nRisk level: low"},

  {"number":14,"title":"Fourteen, from a fork's own master, and red","url":"https://x/14",
   "isDraft":false,
   "baseRefName":"master","headRefName":"master","headRefOid":"aaa14",
   "mergeable":"MERGEABLE","reviewDecision":"","labels":[],
   "createdAt":"2026-09-04T10:00:00Z",
   "statusCheckRollup":[{"__typename":"CheckRun","name":"verify","status":"COMPLETED","conclusion":"FAILURE"}],
   "body":"plain body\n\n## Risk\nRisk level: low"}
]
JSON

OUT="$(bash "$LIST" --base master --json "$FIX" 2>&1)"
RC=$?
assert_rc 0 "$RC" "discovery over the fixture succeeds"
assert_path_absent "$CALLED" "gh was never called when --json was given"

assert_contains "$OUT" "CANDIDATES:1 5 6 7 8" "the ready PRs, drafts and stacked children included"
assert_contains "$OUT" "SKIPPED:2 3 4 9 10 13 14" "and every other PR carries a reason"

# A pull request from a fork's own `master` arrives with headRefName "master" —
# no owner prefix — so a naive stacked check would make every PR targeting master
# a child of it, and this one is red. Nothing else in the fixture would catch that:
# the whole run would collapse to CANDIDATES:none with a nonsense reason.
assert_not_contains "$OUT" "stacked-parent-not-selected:14" \
  "a PR targeting the base is never stacked on a fork branch named after the base"
fourteen="$(printf '%s\n' "$OUT" | awk '/^PR:14$/ {p = 1} p; /^END$/ && p {exit}')"
assert_contains "$fourteen" "STACKED_ON:none" "the fork PR itself is not stacked on anything"
assert_contains "$fourteen" "VERDICT:skip ci-failing" "and is skipped for its own red check"

assert_contains "$OUT" "VERDICT:skip changes-requested" "changes requested is a skip"
assert_contains "$OUT" "VERDICT:skip label:WIP" "a blocking label is a skip, matched case-insensitively"
assert_contains "$OUT" "VERDICT:skip ci-failing" "a failing check is a skip"
assert_contains "$OUT" "VERDICT:skip stacked-parent-not-selected:4" "a child of a skipped PR goes with it"
assert_contains "$OUT" "VERDICT:skip stacked-parent-not-selected:9" "and so does the grandchild"

assert_contains "$OUT" "CI:pending" "a check still running is pending, not failing"
assert_contains "$OUT" "CI:none" "an empty rollup is none, not passing"
assert_contains "$OUT" "CI:passing" "a completed successful check is passing"
assert_contains "$OUT" "DRAFT:yes" "drafts are reported as drafts"
assert_contains "$OUT" "STACKED_ON:1" "the stack relation is reported"
assert_contains "$OUT" "CONTRACT:gantry" "a gantry PR body is recognised as a contract"
assert_contains "$OUT" "CONTRACT:none" "and a plain one is not"
assert_contains "$OUT" "INTEGRATION_PR:12 integration/2026-09-14 master" \
  "an existing integration PR is reported so a re-run can find it"
assert_not_contains "$OUT" "PR:12
TITLE:" "but it is never itself a candidate"
assert_not_contains "$OUT" "PR:11" "a PR on another base is not discovered at all"

# A PR with no checks is a candidate — but it must not be reported as though it
# had passed any. This is the pair of assertions that keeps those two apart.
six="$(printf '%s\n' "$OUT" | awk '/^PR:6$/ {p = 1} p; /^END$/ && p {exit}')"
assert_contains "$six" "CI:none" "PR 6 has no checks"
assert_contains "$six" "VERDICT:candidate" "and is still a candidate"

# --- an explicit list overrides discovery -------------------------------------
OUT="$(bash "$LIST" --base master --json "$FIX" 1 99 2>&1)"
assert_contains "$OUT" "CANDIDATES:1" "an explicit list takes only what it names"
assert_contains "$OUT" "VERDICT:skip not-open" "a number that is not an open PR is reported"
assert_contains "$OUT" "SKIPPED:99" "and counted as skipped rather than dropped"

OUT="$(bash "$LIST" --base master --json "$FIX" 8 2>&1)"
assert_contains "$OUT" "VERDICT:skip stacked-parent-not-selected:1" \
  "a listed child whose parent was not listed names the parent, not the base"

OUT="$(bash "$LIST" --base master --json "$FIX" 11 2>&1)"
assert_contains "$OUT" "VERDICT:skip base:release/1.x" \
  "an explicitly listed PR on another base is skipped for its base"

# Asking for an integration PR by number: it IS open, so "not-open" would be a
# false reason handed to whoever typed the number.
OUT="$(bash "$LIST" --base master --json "$FIX" 12 2>&1)"
assert_contains "$OUT" "VERDICT:skip integration-pr" \
  "an integration PR asked for by number says what it is"
assert_not_contains "$OUT" "VERDICT:skip not-open" "and is not reported as closed"
assert_contains "$OUT" "SKIPPED:12" "while still being counted"

# --- ## Risk: no section, no merge ---------------------------------------------
# The integration PR's Risk summary is the max over the PRs it merges, so a PR
# with no assessed level must not be merged into it. Exact heading: a body whose
# only Risk-like heading is `## Risk summary` has no `## Risk`.
RFIX="$CASE_TMP/risk.json"
cat >"$RFIX" <<'JSON'
[
  {"number":31,"title":"assessed","url":"u31","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/r31","headRefOid":"r31","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z","statusCheckRollup":[],
   "body":"## What this change is for\n\nx\n\n## Risk\n<!-- gantry:risk sha256=abc -->\nRisk level: **High**\nBlast radius:\n- Breaks if wrong: y"},
  {"number":32,"title":"pre-0.8 body","url":"u32","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/r32","headRefOid":"r32","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z","statusCheckRollup":[],
   "body":"## What this change is for\n\nno risk section here"},
  {"number":33,"title":"no review ran","url":"u33","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/r33","headRefOid":"r33","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z","statusCheckRollup":[],
   "body":"## Risk\nRisk level: unassessed\n"},
  {"number":34,"title":"summary only","url":"u34","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/r34","headRefOid":"r34","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z","statusCheckRollup":[],
   "body":"## Risk summary\nRisk level: high\n"},
  {"number":35,"title":"fenced example only","url":"u35","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/r35","headRefOid":"r35","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z","statusCheckRollup":[],
   "body":"```\n## Risk\nRisk level: low\n```\n"}
]
JSON
OUT="$(bash "$LIST" --base master --json "$RFIX" 2>&1)"
pr_block() { printf '%s\n' "$OUT" | awk -v want="PR:$1" '$0 == want {p = 1} p; /^END$/ && p {exit}'; }
assert_contains "$(pr_block 31)" "RISK:high" "the level under ## Risk is read, bold and case tolerated"
assert_contains "$(pr_block 31)" "VERDICT:candidate" "and a PR with an assessed level is a candidate"
assert_contains "$(pr_block 32)" "RISK:none" "a body with no ## Risk reports none"
assert_contains "$(pr_block 32)" "VERDICT:skip no-risk-section" "and is skipped, named"
assert_contains "$(pr_block 33)" "VERDICT:skip risk-level:unassessed" "an unassessed level is skipped"
assert_contains "$(pr_block 34)" "VERDICT:skip no-risk-section" "## Risk summary is not ## Risk"
assert_contains "$(pr_block 35)" "VERDICT:skip no-risk-section" "a ## Risk inside a fence does not count"
assert_contains "$OUT" "CANDIDATES:31" "only the assessed PR is a candidate"

# --- CI: the latest run of each check decides --------------------------------
# A re-run is a second entry with the same name. Several of these list the
# entries against time order, so a "last in the list wins" shortcut fails them.
CFIX="$CASE_TMP/ci.json"
cat >"$CFIX" <<'JSON'
[
  {"number":41,"title":"old red then new green","url":"u41","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/c41","headRefOid":"c41","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z",
   "statusCheckRollup":[
     {"__typename":"CheckRun","name":"pr-risk","workflowName":"risk","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-18T10:00:00Z","completedAt":"2026-11-18T10:01:00Z"},
     {"__typename":"CheckRun","name":"pr-risk","workflowName":"risk","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-17T10:00:00Z","completedAt":"2026-11-17T10:01:00Z"}],
   "body":"## Risk\nRisk level: low"},
  {"number":42,"title":"old green then new red","url":"u42","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/c42","headRefOid":"c42","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z",
   "statusCheckRollup":[
     {"__typename":"CheckRun","name":"verify","workflowName":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-18T10:00:00Z","completedAt":"2026-11-18T10:01:00Z"},
     {"__typename":"CheckRun","name":"verify","workflowName":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-17T10:00:00Z","completedAt":"2026-11-17T10:01:00Z"}],
   "body":"## Risk\nRisk level: low"},
  {"number":43,"title":"old red, re-run in flight","url":"u43","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/c43","headRefOid":"c43","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z",
   "statusCheckRollup":[
     {"__typename":"CheckRun","name":"verify","workflowName":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-17T10:00:00Z","completedAt":"2026-11-17T10:01:00Z"},
     {"__typename":"CheckRun","name":"verify","workflowName":"ci","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-11-18T10:00:00Z","completedAt":"0001-01-01T00:00:00Z"}],
   "body":"## Risk\nRisk level: low"},
  {"number":44,"title":"old run still going, new run red","url":"u44","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/c44","headRefOid":"c44","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z",
   "statusCheckRollup":[
     {"__typename":"CheckRun","name":"verify","workflowName":"ci","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-11-17T10:00:00Z","completedAt":"0001-01-01T00:00:00Z"},
     {"__typename":"CheckRun","name":"verify","workflowName":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-18T10:00:00Z","completedAt":"2026-11-18T10:01:00Z"}],
   "body":"## Risk\nRisk level: low"},
  {"number":45,"title":"same name, different workflows","url":"u45","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/c45","headRefOid":"c45","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z",
   "statusCheckRollup":[
     {"__typename":"CheckRun","name":"test","workflowName":"a","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-17T10:00:00Z","completedAt":"2026-11-17T10:01:00Z"},
     {"__typename":"CheckRun","name":"test","workflowName":"b","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-18T10:00:00Z","completedAt":"2026-11-18T10:01:00Z"}],
   "body":"## Risk\nRisk level: low"},
  {"number":46,"title":"held","url":"u46","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/c46","headRefOid":"c46","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[{"name":"Hold"}],"createdAt":"2026-11-01T00:00:00Z","statusCheckRollup":[],
   "body":"## Risk\nRisk level: low"},
  {"number":47,"title":"old red, re-run queued with no timestamps","url":"u47","isDraft":false,"baseRefName":"master",
   "headRefName":"feat/c47","headRefOid":"c47","mergeable":"MERGEABLE","reviewDecision":"",
   "labels":[],"createdAt":"2026-11-01T00:00:00Z",
   "statusCheckRollup":[
     {"__typename":"CheckRun","name":"verify","workflowName":"ci","status":"QUEUED","conclusion":"","startedAt":"0001-01-01T00:00:00Z","completedAt":"0001-01-01T00:00:00Z"},
     {"__typename":"CheckRun","name":"verify","workflowName":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-17T10:00:00Z","completedAt":"2026-11-17T10:01:00Z"}],
   "body":"## Risk\nRisk level: low"}
]
JSON
OUT="$(bash "$LIST" --base master --json "$CFIX" 2>&1)"
assert_contains "$(pr_block 41)" "CI:passing" "an old red run does not outweigh a newer green one, whatever the list order"
assert_contains "$(pr_block 41)" "VERDICT:candidate" "so the PR is a candidate"
assert_contains "$(pr_block 42)" "CI:failing" "a newer red run outweighs an older green one, whatever the list order"
assert_contains "$(pr_block 42)" "VERDICT:skip ci-failing" "and the PR is skipped"
assert_contains "$(pr_block 43)" "CI:pending" "a re-run in flight over an old red is pending"
assert_contains "$(pr_block 44)" "CI:failing" "an old run still going does not hide a newer red"
assert_contains "$(pr_block 45)" "CI:failing" "the same check name in another workflow is a different check: its red is not outvoted"
assert_contains "$(pr_block 46)" "VERDICT:skip label:Hold" "a hold label is a skip, matched case-insensitively"
assert_contains "$(pr_block 47)" "CI:pending" "a queued re-run with no timestamps over an old red is pending, whatever the list order"

# --- usage errors -------------------------------------------------------------
OUT="$(bash "$LIST" --json "$FIX" 2>&1)"; RC=$?
assert_rc 2 "$RC" "a missing --base is a usage error"
OUT="$(bash "$LIST" --base master --json "$CASE_TMP/nope.json" 2>&1)"; RC=$?
assert_rc 2 "$RC" "an unreadable JSON file is a usage error"
printf 'not json' >"$CASE_TMP/bad.json"
OUT="$(bash "$LIST" --base master --json "$CASE_TMP/bad.json" 2>&1)"; RC=$?
assert_rc 2 "$RC" "malformed JSON is a usage error, not an empty candidate list"
assert_not_contains "$OUT" "CANDIDATES:" "and it prints no verdicts at all"

finish
