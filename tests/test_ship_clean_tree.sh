#!/usr/bin/env bash
#
# skills/ship/scripts/assert_clean_tree.sh is what stops ship pushing a branch
# whose commit left files behind. The contract is its exit code, so these are
# real-git fixtures: build a repo, leave something outstanding, compare an integer.
#
# The load-bearing cases: a FAILED `git status` must be rc 2 rather than CLEAN
# (empty output from a failure looks exactly like a clean tree), and the SKILL.md
# structure check, because a bare `grep -c assert_clean_tree` is satisfied by prose
# and would pass with one of the two call sites missing.

# Sourced by its own dirname: this file lives in tests/, not tests/cases/.
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SCRIPT="$GANTRY_ROOT/skills/ship/scripts/assert_clean_tree.sh"
SKILL="$GANTRY_ROOT/skills/ship/SKILL.md"

run_in() {  # run_in <dir> — sets OUT and RC
  OUT="$(cd "$1" && bash "$SCRIPT" 2>/dev/null)"; RC=$?
}

# --- clean ---------------------------------------------------------------------
repo="$(mkrepo clean)"
run_in "$repo"
assert_rc 0 "$RC" "clean tree"
assert_contains "$OUT" "CLEAN" "clean tree says CLEAN"

# --- outstanding changes -------------------------------------------------------
printf 'later edit\n' >>"$repo/README"
run_in "$repo"
assert_rc 1 "$RC" "unstaged edit after the commit"
assert_contains "$OUT" "DIRTY:1" "counts the entry"
assert_contains "$OUT" "PATH: M README" "names the edited path"
git -C "$repo" checkout -q README

printf 'new\n' >"$repo/untracked.txt"
run_in "$repo"
assert_rc 1 "$RC" "untracked file"
assert_contains "$OUT" "PATH:?? untracked.txt" "names the untracked path"
rm -f "$repo/untracked.txt"

mkdir -p "$repo/newdir"
printf 'a\n' >"$repo/newdir/a.txt"; printf 'b\n' >"$repo/newdir/b.txt"
run_in "$repo"
assert_contains "$OUT" "newdir/a.txt" "untracked directory: first file named"
assert_contains "$OUT" "newdir/b.txt" "untracked directory: every file named, not the dir"
rm -rf "$repo/newdir"

printf 'staged\n' >"$repo/staged.txt"
git -C "$repo" add staged.txt
run_in "$repo"
assert_rc 1 "$RC" "staged but uncommitted"
assert_contains "$OUT" "PATH:A  staged.txt" "names the staged path"
git -C "$repo" rm -q -f --cached staged.txt; rm -f "$repo/staged.txt"

printf 'spaced\n' >"$repo/a b.txt"
run_in "$repo"
assert_rc 1 "$RC" "path with a space"
assert_contains "$OUT" "PATH:?? a b.txt" "space path is unquoted"
assert_not_contains "$OUT" '"a b.txt"' "space path carries no git quotes"
rm -f "$repo/a b.txt"

git -C "$repo" mv README MOVED
run_in "$repo"
assert_contains "$OUT" "MOVED (from README)" "rename names both paths"
git -C "$repo" mv MOVED README

# --- excluded files are not outstanding ----------------------------------------
printf 'task.md\n' >>"$repo/.git/info/exclude"
printf 'x\n' >"$repo/task.md"
run_in "$repo"
assert_rc 0 "$RC" "a file in .git/info/exclude is not reported"

# --- environment failures are rc 2, never CLEAN --------------------------------
plain="$(mkdir_plain notrepo)"
run_in "$plain"
assert_rc 2 "$RC" "not a repo"
assert_not_contains "$OUT" "CLEAN" "not a repo is never CLEAN"

# A git whose `status` fails, with a clean tree behind it: empty output + failure.
stubdir="$CASE_TMP/stubbin"; mkdir -p "$stubdir"
real_git="$(command -v git)"
cat >"$stubdir/git" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = status ] && exit 128; done
exec "$real_git" "\$@"
EOF
chmod +x "$stubdir/git"
OUT="$(cd "$repo" && rm -f task.md && PATH="$stubdir:$PATH" bash "$SCRIPT" 2>/dev/null)"; RC=$?
assert_rc 2 "$RC" "git status failing"
assert_not_contains "$OUT" "CLEAN" "a failed git status is never CLEAN"

# --- SKILL.md wiring -----------------------------------------------------------
# Fenced lines only: prose mentions do not count. Line numbers of the fenced
# calls, of the two commits ship makes, and of the first push.
fenced() {  # fenced <regex> — line numbers of matches inside ``` fences
  awk -v re="$1" '/^```/ {f=!f; next} f && $0 ~ re {print NR}' "$SKILL"
}
calls="$(fenced 'assert_clean_tree[.]sh')"
commit1="$(fenced '^git commit -m "<subject>"')"
commit2="$(fenced 'git commit -m "Apply review findings"')"
push1="$(fenced '^git push -u origin HEAD')"
ncalls="$(printf '%s\n' "$calls" | grep -c .)"
[ "$ncalls" -ge 2 ] && _pass "SKILL.md has >=2 fenced assert_clean_tree calls" \
  || _fail "SKILL.md has $ncalls fenced assert_clean_tree calls, want >=2"

has_call_between() {  # has_call_between <from> <to>
  local n
  for n in $calls; do
    [ -n "$1" ] && [ -n "$2" ] && [ "$n" -gt "$1" ] && [ "$n" -lt "$2" ] && return 0
  done
  return 1
}
# Stage 2's commit fence comes before the review section's, which comes before push.
if has_call_between "$commit1" "$commit2"; then
  _pass "a fenced call follows the stage 2 commit, before the review-fix commit"
else _fail "no fenced assert_clean_tree call between the stage 2 commit and the review-fix commit"; fi
if has_call_between "$commit2" "$push1"; then
  _pass "a fenced call follows the review-fix commit, before the push"
else _fail "no fenced assert_clean_tree call between the review-fix commit and the push"; fi

finish
