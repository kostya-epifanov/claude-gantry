#!/usr/bin/env bash
#
# order_queue.sh plans the merge order BEFORE anything is merged, and the whole
# value of that is in two properties a reader cannot check by eye:
#
#   1. the order is the one the skill claims — stacked parents first, then
#      whatever cannot fail for another item's reason, then the smallest, then
#      the oldest;
#   2. planning the order changes nothing. It is run at the checkpoint, before a
#      human has approved anything, so it must not create a merge commit or move
#      a ref.
#
# Every ordering fixture below is built so that the LABEL order contradicts the
# expected order. Without that, an assertion passes on the alphabetical
# tie-break alone and would keep passing with the criterion it claims to test
# deleted — which is exactly how an ordering test becomes decoration.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

ORDER="$GANTRY_ROOT/skills/integrate/scripts/order_queue.sh"

gitq() { git -C "$1" -c user.email=test@example.invalid -c user.name=test "${@:2}"; }

commit_at() {  # commit_at <repo> <epoch> <message>
  GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" \
    gitq "$1" commit -qm "$3" >/dev/null 2>&1
}

run_order() {  # run_order <repo> <args...> — sets ORDER_OUT and ORDER_RC
  local repo="$1"; shift
  ORDER_OUT="$(cd "$repo" && bash "$ORDER" "$@" 2>&1)"
  ORDER_RC=$?
  return 0
}

# --- the acceptance fixture ---------------------------------------------------
# Three branches: alpha and beta conflict on one line of f; zeta touches nothing
# else. alpha is the LARGER of the conflicting pair, so "smallest overlapping
# first" must put beta ahead of it, against the label order.
ord="$(mkrepo ordering)"
gitq "$ord" branch -m master >/dev/null 2>&1
printf '1\n2\n3\n' >"$ord/f"
gitq "$ord" add -A >/dev/null 2>&1
commit_at "$ord" 1700000000 "seed f"

gitq "$ord" checkout -q -b alpha >/dev/null 2>&1
printf '1\nalpha\n3\nalpha\nalpha\nalpha\n' >"$ord/f"
gitq "$ord" add -A >/dev/null 2>&1
commit_at "$ord" 1700001000 "alpha edits f, and adds three lines"

gitq "$ord" checkout -q master >/dev/null 2>&1
gitq "$ord" checkout -q -b beta >/dev/null 2>&1
printf '1\nbeta\n3\n' >"$ord/f"
gitq "$ord" add -A >/dev/null 2>&1
commit_at "$ord" 1700002000 "beta edits the same line of f"

gitq "$ord" checkout -q master >/dev/null 2>&1
gitq "$ord" checkout -q -b zeta >/dev/null 2>&1
printf 'h\n' >"$ord/h"
gitq "$ord" add -A >/dev/null 2>&1
commit_at "$ord" 1700003000 "zeta adds h"

gitq "$ord" checkout -q master >/dev/null 2>&1

refs_before="$(git -C "$ord" for-each-ref --format='%(refname) %(objectname)')"
commits_before="$(git -C "$ord" rev-list --all --count)"

run_order "$ord" --base master alpha=alpha beta=beta zeta=zeta
assert_rc 0 "$ORDER_RC" "planning an order succeeds"
assert_contains "$ORDER_OUT" "QUEUE:1 zeta" "the item that overlaps nothing goes first"
assert_contains "$ORDER_OUT" "QUEUE:2 beta" "then the smaller of the two that overlap"
assert_contains "$ORDER_OUT" "QUEUE:3 alpha" "then the larger one"
assert_contains "$ORDER_OUT" "CONFLICT:alpha beta f" "the conflict is reported before any merge"
assert_contains "$ORDER_OUT" "OVERLAP:alpha beta f" "and so is the overlap that caused it"
assert_contains "$ORDER_OUT" "PREDICTED_CONFLICTS:1" "one predicted conflict"
assert_not_contains "$ORDER_OUT" "CONFLICT:alpha zeta" "an item touching other files does not conflict"

refs_after="$(git -C "$ord" for-each-ref --format='%(refname) %(objectname)')"
commits_after="$(git -C "$ord" rev-list --all --count)"
if [ "$refs_before" = "$refs_after" ]; then
  _pass "planning moves no ref"
else
  _fail "planning moved a ref"
fi
if [ "$commits_before" = "$commits_after" ]; then
  _pass "planning creates no commit"
else
  _fail "planning created a commit"
fi

# --- age, and the --created override -----------------------------------------
# Two items that overlap nothing, so only age can separate them. The older one
# is labelled LAST, so the label tie-break would give the opposite answer.
age="$(mkrepo ageing)"
gitq "$age" branch -m master >/dev/null 2>&1
gitq "$age" checkout -q -b aaa >/dev/null 2>&1
printf 'a\n' >"$age/a"
gitq "$age" add -A >/dev/null 2>&1
commit_at "$age" 1700500000 "aaa, the newer"
gitq "$age" checkout -q master >/dev/null 2>&1
gitq "$age" checkout -q -b zzz >/dev/null 2>&1
printf 'z\n' >"$age/z"
gitq "$age" add -A >/dev/null 2>&1
commit_at "$age" 1700100000 "zzz, the older"
gitq "$age" checkout -q master >/dev/null 2>&1

run_order "$age" --base master aaa=aaa zzz=zzz
assert_contains "$ORDER_OUT" "QUEUE:1 zzz" "the older item goes first"
assert_contains "$ORDER_OUT" "age=1700100000" "age comes from the oldest commit in its own range"

run_order "$age" --base master --created aaa:1600000000 aaa=aaa zzz=zzz
assert_contains "$ORDER_OUT" "QUEUE:1 aaa" "--created overrides the age read from commits"

# --- conflicts with base, and the cascade ------------------------------------
# dee was cut before master changed the same line, so it cannot go in at all.
# eff is stacked on dee and eff2 on eff: both have to go with it, or dee's
# commits would be integrated under a child's name while dee's own row says
# it was skipped.
bc="$(mkrepo baseconflict)"
gitq "$bc" branch -m master >/dev/null 2>&1
printf '1\n2\n3\n' >"$bc/f"
gitq "$bc" add -A >/dev/null 2>&1
commit_at "$bc" 1700000000 "seed f"

gitq "$bc" checkout -q -b dee >/dev/null 2>&1
printf '1\ndee\n3\n' >"$bc/f"
gitq "$bc" add -A >/dev/null 2>&1
commit_at "$bc" 1700001000 "dee edits f"

gitq "$bc" checkout -q -b eff >/dev/null 2>&1
printf 'e\n' >"$bc/e"
gitq "$bc" add -A >/dev/null 2>&1
commit_at "$bc" 1700002000 "eff, stacked on dee"

gitq "$bc" checkout -q -b eff2 >/dev/null 2>&1
printf 'e2\n' >"$bc/e2"
gitq "$bc" add -A >/dev/null 2>&1
commit_at "$bc" 1700003000 "eff2, stacked on eff"

gitq "$bc" checkout -q master >/dev/null 2>&1
printf '1\nmaster moved\n3\n' >"$bc/f"
gitq "$bc" add -A >/dev/null 2>&1
commit_at "$bc" 1700004000 "master edits the same line"

# An old commit of master: already in base, so there is nothing to merge.
old="$(git -C "$bc" rev-parse master~1)"

run_order "$bc" --base master dee=dee eff=eff eff2=eff2 "old=$old"
assert_rc 0 "$ORDER_RC" "a fixture with skips still exits 0"
assert_contains "$ORDER_OUT" "SKIP:dee conflicts-with-base f" \
  "an item that cannot be merged into base is skipped, with the file named"
assert_contains "$ORDER_OUT" "SKIP:eff parent-skipped:dee" "its child goes with it"
assert_contains "$ORDER_OUT" "SKIP:eff2 parent-skipped:eff" "and so does its grandchild"
assert_contains "$ORDER_OUT" "SKIP:old already-in-base" "a commit already in base is skipped"
assert_not_contains "$ORDER_OUT" "QUEUE:1" "with everything skipped, the queue is empty"

# --- a stacked child that would otherwise sort first --------------------------
# p and x overlap on f, so both rank as overlapping. k is cut from p and adds
# only k.txt, so by its own range it overlaps nothing and would be picked first.
# The stack edge is the only thing that can stop it.
st="$(mkrepo stacked)"
gitq "$st" branch -m master >/dev/null 2>&1
printf '1\n2\n3\n' >"$st/f"
gitq "$st" add -A >/dev/null 2>&1
commit_at "$st" 1700000000 "seed f"

gitq "$st" checkout -q -b p >/dev/null 2>&1
printf '1\np\n3\n' >"$st/f"
gitq "$st" add -A >/dev/null 2>&1
commit_at "$st" 1700001000 "p edits f"

gitq "$st" checkout -q -b k >/dev/null 2>&1
printf 'k\n' >"$st/k.txt"
gitq "$st" add -A >/dev/null 2>&1
commit_at "$st" 1700002000 "k, stacked on p, touches nothing else"

gitq "$st" checkout -q master >/dev/null 2>&1
gitq "$st" checkout -q -b x >/dev/null 2>&1
printf '1\n2\n3\nx\nx\nx\nx\n' >"$st/f"
gitq "$st" add -A >/dev/null 2>&1
commit_at "$st" 1700003000 "x also touches f, and is larger than p"

gitq "$st" checkout -q master >/dev/null 2>&1

run_order "$st" --base master k=k p=p x=x
assert_contains "$ORDER_OUT" "STACK:k after p" "the stack relation is found from ancestry"
assert_contains "$ORDER_OUT" "QUEUE:1 p" "the stacked parent goes first"
assert_contains "$ORDER_OUT" "QUEUE:2 k" "then its child, before the unrelated overlapping item"
assert_contains "$ORDER_OUT" "QUEUE:3 x" "and the larger overlapping item last"

# The same, with ancestry broken: p is amended after k was cut, which is what a
# force-push to a stacked parent looks like. Only --after can find it then.
gitq "$st" checkout -q p >/dev/null 2>&1
printf '1\np amended\n3\n' >"$st/f"
gitq "$st" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="1700004000 +0000" GIT_COMMITTER_DATE="1700004000 +0000" \
  gitq "$st" commit -q --amend -m "p, force-pushed" >/dev/null 2>&1
gitq "$st" checkout -q master >/dev/null 2>&1

run_order "$st" --base master k=k p=p
assert_not_contains "$ORDER_OUT" "STACK:k after p" "a force-pushed parent is no longer an ancestor"
run_order "$st" --base master --after k:p k=k p=p
assert_contains "$ORDER_OUT" "STACK:k after p" "--after states the relation ancestry lost"
assert_contains "$ORDER_OUT" "QUEUE:1 p" "and the parent still goes first"

# --after comes from GitHub's own stacking data, so a contradictory pair is
# reachable. A cycle cannot be sorted — and the failure to avoid is the silent
# one, where both items simply never appear in the queue and never appear as
# skipped either.
run_order "$st" --base master --after k:p --after p:k k=k p=p
assert_rc 2 "$ORDER_RC" "a stack cycle is a usage error, not a silent omission"
assert_contains "$ORDER_OUT" "cycle" "and it says so"

# A three-deep stack: the grandchild's files are measured against its own parent,
# so a file the grandparent also touched must not be reported as an overlap
# between them — merge-tree can never make that pair conflict, and a spurious
# overlap would flip both out of the isolated class and reorder the queue.
deep="$(mkrepo deepstack)"
gitq "$deep" branch -m master >/dev/null 2>&1
printf '1\n2\n3\n' >"$deep/f"
gitq "$deep" add -A >/dev/null 2>&1
commit_at "$deep" 1700000000 "seed f"
gitq "$deep" checkout -q -b g1 >/dev/null 2>&1
printf 'g1\n2\n3\n' >"$deep/f"
gitq "$deep" add -A >/dev/null 2>&1
commit_at "$deep" 1700001000 "grandparent touches f"
gitq "$deep" checkout -q -b g2 >/dev/null 2>&1
printf 'mid\n' >"$deep/mid"
gitq "$deep" add -A >/dev/null 2>&1
commit_at "$deep" 1700002000 "parent touches mid"
gitq "$deep" checkout -q -b g3 >/dev/null 2>&1
printf 'g1\n2\ng3\n' >"$deep/f"
gitq "$deep" add -A >/dev/null 2>&1
commit_at "$deep" 1700003000 "grandchild touches f again"
gitq "$deep" checkout -q master >/dev/null 2>&1

run_order "$deep" --base master g1=g1 g2=g2 g3=g3
assert_contains "$ORDER_OUT" "STACK:g3 after g2" "the nearest parent wins in a three-deep stack"
assert_contains "$ORDER_OUT" "STACK:g2 after g1" "and the middle links to the root"
assert_not_contains "$ORDER_OUT" "OVERLAP:g1 g3" \
  "a grandparent and grandchild touching one file is not an overlap"
assert_contains "$ORDER_OUT" "QUEUE:1 g1" "the root goes first"
assert_contains "$ORDER_OUT" "QUEUE:3 g3" "and the grandchild last"

# --- usage errors -------------------------------------------------------------
run_order "$ord" --base master alpha=alpha nope=refs/heads/nope
assert_rc 2 "$ORDER_RC" "an unresolvable ref is a usage error"
assert_contains "$ORDER_OUT" "cannot resolve ref for nope" "and it names the item"

run_order "$ord" --base master alpha=alpha same=alpha
assert_rc 2 "$ORDER_RC" "two labels on one commit is a usage error"

run_order "$ord" --base nosuchbase alpha=alpha
assert_rc 2 "$ORDER_RC" "an unresolvable base is a usage error"

run_order "$ord" --base master
assert_rc 2 "$ORDER_RC" "no items is a usage error"

finish
