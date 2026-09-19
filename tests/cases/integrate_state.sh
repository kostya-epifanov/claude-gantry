#!/usr/bin/env bash
#
# integration_state.sh is what makes /gantry:integrate re-runnable: a second run
# is usually a second session, so "which PRs are already in" has to be derived
# from git rather than remembered. Ancestry gives that exactly.
#
# The cases that matter are the ones where a run DIED rather than finished. A
# merge whose gate never went green, and an unconcluded merge, both look
# finished to an ancestry check alone — and reading either as done means the
# next run merges on top of an unproven or half-applied tree. Those two, plus
# telling a grown PR (`stale`) from a force-pushed one (`rewritten`), are the
# reason this script exists rather than one `git merge-base --is-ancestor`.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

STATE="$GANTRY_ROOT/skills/integrate/scripts/integration_state.sh"

gitq() { git -C "$1" -c user.email=test@example.invalid -c user.name=test "${@:2}"; }

run_state() {  # run_state <repo> <args...> — sets STATE_OUT and STATE_RC
  local repo="$1"; shift
  STATE_OUT="$(cd "$repo" && bash "$STATE" "$@" 2>&1)"
  STATE_RC=$?
  return 0
}

repo="$(mkrepo lane)"
gitq "$repo" branch -m master >/dev/null 2>&1

# Two PR branches off master, and the lane itself.
gitq "$repo" checkout -q -b pr21 >/dev/null 2>&1
printf 'a\n' >"$repo/a"
gitq "$repo" add -A >/dev/null 2>&1
gitq "$repo" commit -qm "pr21 work" >/dev/null 2>&1

gitq "$repo" checkout -q master >/dev/null 2>&1
gitq "$repo" checkout -q -b pr22 >/dev/null 2>&1
printf 'b\n' >"$repo/b"
gitq "$repo" add -A >/dev/null 2>&1
gitq "$repo" commit -qm "pr22 work" >/dev/null 2>&1

gitq "$repo" checkout -q master >/dev/null 2>&1
gitq "$repo" checkout -q -b integration/fixture >/dev/null 2>&1

run_state "$repo" --base master 21=pr21 22=pr22
assert_rc 0 "$STATE_RC" "a fresh lane reports cleanly"
assert_contains "$STATE_OUT" "BRANCH:integration/fixture" "the lane's branch"
assert_contains "$STATE_OUT" "STATE:21 pending" "nothing merged yet is pending"
assert_contains "$STATE_OUT" "REMOTE:none" "an unpushed lane has no remote tip"
assert_contains "$STATE_OUT" "NEXT:merge-items" "so the next move is to merge them"

# The merge the loop makes, with the subject the state script reads back.
gitq "$repo" merge --no-ff -m "integrate: merge #21 — pr21 work" pr21 >/dev/null 2>&1
run_state "$repo" --base master 21=pr21 22=pr22
assert_contains "$STATE_OUT" "STATE:21 integrated" "a merged head is integrated"
assert_contains "$STATE_OUT" "STATE:22 pending" "the other one is still pending"

# A subject that is a PREFIX of another label's must not match it: #2 is not #21.
run_state "$repo" --base master 2=pr22
assert_contains "$STATE_OUT" "STATE:2 pending" "#2 does not match the record for #21"

# The PR grew after it was merged: its head is no longer an ancestor, but what
# was merged still is, so this is a re-merge rather than a fresh one.
gitq "$repo" checkout -q pr21 >/dev/null 2>&1
printf 'a2\n' >>"$repo/a"
gitq "$repo" add -A >/dev/null 2>&1
gitq "$repo" commit -qm "pr21 grows" >/dev/null 2>&1
gitq "$repo" checkout -q integration/fixture >/dev/null 2>&1
run_state "$repo" --base master 21=pr21
assert_contains "$STATE_OUT" "STATE:21 stale" "new commits since the merge read as stale"

# The PR was force-pushed: the commits that were merged are not in its history
# at all any more, so merging the new head blindly would double the change.
gitq "$repo" checkout -q -b pr21rewritten master >/dev/null 2>&1
printf 'a-rewritten\n' >"$repo/a"
gitq "$repo" add -A >/dev/null 2>&1
gitq "$repo" commit -qm "pr21, retold" >/dev/null 2>&1
gitq "$repo" checkout -q integration/fixture >/dev/null 2>&1
run_state "$repo" --base master 21=pr21rewritten
assert_contains "$STATE_OUT" "STATE:21 rewritten" "a replaced history reads as rewritten"

# A leftover pre-merge ref on a merge that IS in the tree: the loop sets the ref
# before merging and deletes it once the gate is green, so its presence means the
# gate never confirmed this merge. Ancestry alone would call this integrated and
# move on with a red tree.
#
# The ref is named after the lane's branch, because refs/ lives in the git dir
# every worktree shares — two lanes on one refs/integrate/pre/21 would each
# delete the other's only undo ref.
gitq "$repo" update-ref refs/integrate/integration/fixture/pre/22 master >/dev/null 2>&1
gitq "$repo" merge --no-ff -m "integrate: merge #22 — pr22 work" pr22 >/dev/null 2>&1
run_state "$repo" --base master 22=pr22
assert_contains "$STATE_OUT" "STATE:22 unverified" "a leftover pre-merge ref means unproven"
assert_contains "$STATE_OUT" "NEXT:verify" "and verifying it comes before anything else"
assert_not_contains "$STATE_OUT" "STATE:22 integrated" "it is not reported as done as well"

# An unscoped ref of the same name is another lane's business, and must not be
# read as this lane's.
gitq "$repo" update-ref -d refs/integrate/integration/fixture/pre/22 >/dev/null 2>&1
gitq "$repo" update-ref refs/integrate/pre/22 master >/dev/null 2>&1
run_state "$repo" --base master 22=pr22
assert_contains "$STATE_OUT" "STATE:22 integrated" "an unscoped pre ref belongs to no lane here"
gitq "$repo" update-ref -d refs/integrate/pre/22 >/dev/null 2>&1

# A pre-merge ref for a merge that never landed is a different accident: there is
# nothing to gate, only a ref to delete. Reporting it as `unverified` would send
# the next run into the fix loop for a merge that is not in the tree.
gitq "$repo" update-ref refs/integrate/integration/fixture/pre/21 master >/dev/null 2>&1
run_state "$repo" --base master 21=pr21rewritten
assert_contains "$STATE_OUT" "STRAY_PRE:21" "a pre ref with nothing merged is reported as stray"
assert_not_contains "$STATE_OUT" "STATE:21 unverified" "and not as an unproven merge"
gitq "$repo" update-ref -d refs/integrate/integration/fixture/pre/21 >/dev/null 2>&1

# Base moved on: that gets merged in before any more PRs.
gitq "$repo" checkout -q master >/dev/null 2>&1
printf 'm\n' >"$repo/m"
gitq "$repo" add -A >/dev/null 2>&1
gitq "$repo" commit -qm "master moves" >/dev/null 2>&1
gitq "$repo" checkout -q integration/fixture >/dev/null 2>&1
run_state "$repo" --base master 22=pr22
assert_contains "$STATE_OUT" "BASE_BEHIND:1" "the lane is one commit behind base"
assert_contains "$STATE_OUT" "NEXT:merge-base" "so base is merged in first"

# A merge left unconcluded — the shape a session that died mid-conflict leaves.
conf="$(mkrepo unconcluded)"
gitq "$conf" branch -m master >/dev/null 2>&1
printf '1\n2\n3\n' >"$conf/f"
gitq "$conf" add -A >/dev/null 2>&1
gitq "$conf" commit -qm "seed f" >/dev/null 2>&1
gitq "$conf" checkout -q -b pr30 >/dev/null 2>&1
printf '1\npr30\n3\n' >"$conf/f"
gitq "$conf" add -A >/dev/null 2>&1
gitq "$conf" commit -qm "pr30 edits f" >/dev/null 2>&1
gitq "$conf" checkout -q master >/dev/null 2>&1
gitq "$conf" checkout -q -b integration/fixture >/dev/null 2>&1
printf '1\nlane\n3\n' >"$conf/f"
gitq "$conf" add -A >/dev/null 2>&1
gitq "$conf" commit -qm "the lane edits f too" >/dev/null 2>&1
gitq "$conf" merge --no-ff pr30 >/dev/null 2>&1      # conflicts, and is left as it is
run_state "$conf" --base master 30=pr30
assert_contains "$STATE_OUT" "MERGE_IN_PROGRESS:yes" "an unconcluded merge is visible"
assert_contains "$STATE_OUT" "NEXT:finish-merge" "and it is the first thing to deal with"

# A base that exists on origin is resolved through origin, not through the local
# branch — the same rule lib/detect_stage.sh uses, and the case that matters
# because a lane is cut from origin/<base> while the local ref may lag.
up="$(mkrepo upstream-base)"
gitq "$up" branch -m master >/dev/null 2>&1
dn="$CASE_TMP/clone"
git clone -q -o origin "$up" "$dn" >/dev/null 2>&1
printf 'moved\n' >"$up/moved"
gitq "$up" add -A >/dev/null 2>&1
gitq "$up" commit -qm "origin/master moves ahead" >/dev/null 2>&1
git -C "$dn" fetch -q origin >/dev/null 2>&1
git -C "$dn" -c user.email=t@e -c user.name=t checkout -q -b integration/fixture master >/dev/null 2>&1
run_state "$dn" --base master 21=master
assert_contains "$STATE_OUT" "BASE:master origin/master" "the base resolves through origin"
assert_contains "$STATE_OUT" "BASE_BEHIND:1" "so the lane is behind the remote base, not the local one"

# --- usage errors -------------------------------------------------------------
run_state "$repo" 21=pr21
assert_rc 2 "$STATE_RC" "a missing --base is a usage error"
run_state "$repo" --base master 21=nosuchref
assert_rc 2 "$STATE_RC" "an unresolvable ref is a usage error"
run_state "$repo" --base master "bad label=pr21"
assert_rc 2 "$STATE_RC" "a label that cannot be a ref component is a usage error"

finish
