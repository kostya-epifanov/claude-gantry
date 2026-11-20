#!/usr/bin/env bash
#
# lib/risk_floor.sh decides which review lenses a diff fires and the floor each
# sets on the PR's risk level. The PR body's `## Guarded changes` list is its
# output, so a wrong answer here is an unguarded change nobody is told to read.
# The four properties the contract names are asserted first (base ref wins,
# prefix + exact keys, max floor, silence on an untouched diff), then the edges.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

RF="$GANTRY_ROOT/lib/risk_floor.sh"

# rf <repo> <args...> — sets RF_OUT and RF_RC. Called directly, never inside a
# command substitution, so both variables survive.
rf() {
  local repo="$1"; shift
  RF_OUT="$(cd "$repo" && bash "$RF" "$@" 2>/dev/null)"
  RF_RC=$?
  return 0
}

gitc() { git -C "$1" -c user.email=test@example.invalid -c user.name=test "${@:2}"; }

LENS='---
name: security
description: test lens
floors:
  ".claude/": critical
  "bin/": medium
  setup.sh: high   # an unquoted key and a trailing comment
defer: never
---
Check the judge. Check what runs after merge.'

# A repo whose base (master) carries the lens, with a feature branch checked out.
repo="$(mkrepo rf)"
git -C "$repo" branch -m master >/dev/null 2>&1
mkdir -p "$repo/.claude/review-lenses" "$repo/bin" "$repo/sub"
printf '%s\n' "$LENS" > "$repo/.claude/review-lenses/security.md"
printf 'x\n' > "$repo/bin/tool"
printf 'x\n' > "$repo/setup.sh"
printf 'x\n' > "$repo/setup.sh.bak"
printf 'x\n' > "$repo/sub/setup.sh"
commit_all "$repo" "lens and guarded files"
git -C "$repo" checkout -q -b feat/x >/dev/null 2>&1

# --- 4. an untouched diff prints nothing --------------------------------------------
rf "$repo" master
assert_rc 0 "$RF_RC" "a clean tree against its base"
[ -z "$RF_OUT" ] && _pass "a clean tree prints nothing" || _fail "a clean tree printed: $RF_OUT"

printf 'y\n' >> "$repo/README"
rf "$repo" master
[ -z "$RF_OUT" ] && _pass "a diff touching no lens key prints nothing" \
  || _fail "an unguarded diff printed: $RF_OUT"
assert_rc 0 "$RF_RC" "an unguarded diff is still exit 0"

# --- 2. prefix and exact keys ----------------------------------------------------------
printf 'y\n' >> "$repo/bin/tool"
rf "$repo" master
assert_contains "$RF_OUT" "LENS:security" "a prefix key (bin/) fires the lens"
assert_contains "$RF_OUT" "FILE:bin/tool medium" "the matched file is listed with its key's level"
assert_contains "$RF_OUT" "FLOOR:medium" "one medium file sets a medium floor"
assert_contains "$RF_OUT" "DEFER:never" "defer: never is carried through"
assert_contains "$RF_OUT" "END" "the block is terminated"

printf 'y\n' >> "$repo/sub/setup.sh"
printf 'y\n' >> "$repo/setup.sh.bak"
rf "$repo" master
assert_not_contains "$RF_OUT" "sub/setup.sh" "an exact key does not match the same name in a subdirectory"
assert_not_contains "$RF_OUT" "setup.sh.bak" "an exact key does not match a longer name"

printf 'y\n' >> "$repo/setup.sh"
rf "$repo" master
assert_contains "$RF_OUT" "FILE:setup.sh high" "an exact key matches exactly that path"

# --- 3. the max floor --------------------------------------------------------------------
assert_contains "$RF_OUT" "FLOOR:high" "medium + high → the floor is high"
mkdir -p "$repo/.claude/hooks"
printf 'z\n' > "$repo/.claude/hooks/h.sh"
rf "$repo" master
assert_contains "$RF_OUT" "FLOOR:critical" "an UNTRACKED file under a critical prefix raises the floor to critical"
assert_contains "$RF_OUT" "FILE:.claude/hooks/h.sh critical" "untracked files count"

# Committed changes count too: the diff is against the merge-base, not the index.
commit_all "$repo" "commit everything"
rf "$repo" master
assert_contains "$RF_OUT" "FLOOR:critical" "committed changes count"

# --- 1. the lens is read from the base ref, never the worktree -------------------------
gitc "$repo" checkout -q -b feat/lens-edit master >/dev/null 2>&1
printf 'y\n' >> "$repo/bin/tool"
sed 's/"bin\/": medium/"bin\/": critical/' "$repo/.claude/review-lenses/security.md" > "$repo/lens.tmp"
mv "$repo/lens.tmp" "$repo/.claude/review-lenses/security.md"
rf "$repo" master
assert_contains "$RF_OUT" "FILE:bin/tool medium" "a lens edited only in the worktree does not change the level"
# The lens file itself sits under `.claude/`, a critical key of the BASE lens — so
# the edit is guarded by the old text, which is the point.
assert_contains "$RF_OUT" "FILE:.claude/review-lenses/security.md critical" "the lens edit is judged by the base lens's own keys"
assert_contains "$RF_OUT" "LENS_IN_DIFF:.claude/review-lenses/security.md" "the edited lens is reported as in the diff"
commit_all "$repo" "commit the lens edit"
rf "$repo" master
assert_contains "$RF_OUT" "FILE:bin/tool medium" "...nor once that edit is committed on the branch"

# A lens that exists only in the worktree is never read.
printf -- '---\nname: extra\nfloors:\n  "README": critical\n---\nbody\n' > "$repo/.claude/review-lenses/extra.md"
printf 'y\n' >> "$repo/README"
rf "$repo" master
assert_not_contains "$RF_OUT" "LENS:extra" "a lens added only in the worktree does not fire"
assert_contains "$RF_OUT" "LENS_IN_DIFF:.claude/review-lenses/extra.md" "...and is reported as in the diff"

# --- the merge-base, not the base tip ----------------------------------------------------
mb="$(mkrepo rf-mb)"
git -C "$mb" branch -m master >/dev/null 2>&1
mkdir -p "$mb/.claude/review-lenses" "$mb/bin"
printf '%s\n' "$LENS" > "$mb/.claude/review-lenses/security.md"
printf 'x\n' > "$mb/bin/tool"
commit_all "$mb" "lens"
git -C "$mb" checkout -q -b feat/y >/dev/null 2>&1
printf 'y\n' >> "$mb/README"
commit_all "$mb" "unguarded change on the branch"
git -C "$mb" checkout -q master >/dev/null 2>&1
printf 'y\n' >> "$mb/bin/tool"
commit_all "$mb" "an earlier PR changed a guarded file on the base"
git -C "$mb" checkout -q feat/y >/dev/null 2>&1
rf "$mb" master
[ -z "$RF_OUT" ] && _pass "a guarded file changed only on the moved base is not this branch's change" \
  || _fail "the base's own change was attributed to the branch: $RF_OUT"

# --- --body ------------------------------------------------------------------------------
rf "$repo" --body security master
assert_rc 0 "$RF_RC" "--body finds the lens by name"
assert_contains "$RF_OUT" "Check the judge." "--body prints the prompt body"
assert_not_contains "$RF_OUT" "floors:" "--body prints no frontmatter"
rf "$repo" --body extra master
assert_rc 2 "$RF_RC" "--body does not read a worktree-only lens"
rf "$repo" --body nope master
assert_rc 2 "$RF_RC" "--body with an unknown name is exit 2"

# --- --commits ---------------------------------------------------------------------------
cm="$(mkrepo rf-commits)"
git -C "$cm" branch -m master >/dev/null 2>&1
mkdir -p "$cm/.claude/review-lenses" "$cm/bin"
printf '%s\n' "$LENS" > "$cm/.claude/review-lenses/security.md"
printf 'one\ntwo\nthree\n' > "$cm/bin/tool"
commit_all "$cm" "lens"
git -C "$cm" checkout -q -b a >/dev/null 2>&1
printf 'one-a\ntwo\nthree\n' > "$cm/bin/tool"
commit_all "$cm" "a edits bin/tool"
git -C "$cm" checkout -q -b b master >/dev/null 2>&1
printf 'one-b\ntwo\nthree\n' > "$cm/bin/tool"
printf 'b\n' > "$cm/notes.txt"
commit_all "$cm" "b edits bin/tool"
git -C "$cm" checkout -q -b lane master >/dev/null 2>&1
gitc "$cm" merge -q --no-ff -m "merge a" a >/dev/null 2>&1
gitc "$cm" merge -q --no-ff -m "merge b" b >/dev/null 2>&1
printf 'one-ab\ntwo\nthree\n' > "$cm/bin/tool"
gitc "$cm" add -A >/dev/null 2>&1
gitc "$cm" commit -qm "merge b (resolved)" >/dev/null 2>&1
conflicted="$(git -C "$cm" rev-parse HEAD)"
clean_merge="$(git -C "$cm" rev-parse HEAD~1)"
printf 'fix\n' > "$cm/README"
commit_all "$cm" "integrate: fix — unguarded"
fix_sha="$(git -C "$cm" rev-parse HEAD)"

nparents="$(git -C "$cm" rev-list --parents -n 1 "$conflicted" | awk '{ print NF - 1 }')"
if [ "$nparents" = 2 ]; then
  rf "$cm" --commits master "$conflicted"
  assert_rc 0 "$RF_RC" "--commits on a conflicted merge"
  assert_contains "$RF_OUT" "FILE:bin/tool medium" "a merge's own resolution of a guarded file fires the lens"
  assert_not_contains "$RF_OUT" "notes.txt" "a file the merge took mechanically is not the merge's own line"
else
  _fail "fixture: the conflicted merge was not recorded as a merge (parents: $nparents)"
fi
rf "$cm" --commits master "$fix_sha"
[ -z "$RF_OUT" ] && _pass "--commits on an unguarded fix commit prints nothing" \
  || _fail "--commits on an unguarded fix printed: $RF_OUT"
rf "$cm" --commits master "$fix_sha" "$conflicted"
assert_contains "$RF_OUT" "FLOOR:medium" "--commits takes the union of several commits"
rf "$cm" --commits master deadbeefdeadbeef
assert_rc 2 "$RF_RC" "--commits with a commit that does not resolve is exit 2"
: "$clean_merge"

# --- malformed lenses fail loud, never silently unguarded --------------------------------
bad_lens() {  # bad_lens <name> <lens text> <label>
  local r
  r="$(mkrepo "rf-bad-$1")"
  git -C "$r" branch -m master >/dev/null 2>&1
  mkdir -p "$r/.claude/review-lenses" "$r/bin"
  printf '%s\n' "$2" > "$r/.claude/review-lenses/$1.md"
  commit_all "$r" "bad lens"
  printf 'y\n' > "$r/bin/tool"
  rf "$r" master
  assert_rc 2 "$RF_RC" "$3"
}
bad_lens level  $'---\nname: l\nfloors:\n  "bin/": severe\n---\nb' "an unknown level is exit 2"
bad_lens flow   $'---\nname: l\nfloors: {"bin/": high}\n---\nb' "a flow-style floors map is exit 2"
bad_lens nokeys $'---\nname: l\nfloors:\ndefer: never\n---\nb' "floors: with no keys is exit 2"
bad_lens nofm   $'name: l\nfloors:\n  "bin/": high\n' "a lens with no frontmatter is exit 2"
bad_lens unterm $'---\nname: l\nfloors:\n  "bin/": high\n' "an unterminated frontmatter is exit 2"
bad_lens nofloors $'---\nname: l\n---\nb' "a lens with no floors: key is exit 2"

# Two lens files declaring the same name: exit 2 in every mode, before any output.
dup="$(mkrepo rf-dup)"
git -C "$dup" branch -m master >/dev/null 2>&1
mkdir -p "$dup/.claude/review-lenses" "$dup/bin"
printf -- '---\nname: security\nfloors:\n  "bin/": high\n---\nbody a\n' > "$dup/.claude/review-lenses/a.md"
printf -- '---\nname: security\nfloors:\n  "bin/": medium\n---\nbody b\n' > "$dup/.claude/review-lenses/b.md"
printf 'x\n' > "$dup/bin/tool"
commit_all "$dup" "two lenses, one name"
printf 'y\n' >> "$dup/bin/tool"
rf "$dup" master
assert_rc 2 "$RF_RC" "two lenses with the same name is exit 2"
[ -z "$RF_OUT" ] && _pass "...and prints nothing" || _fail "a duplicate lens name printed: $RF_OUT"
rf "$dup" --body security master
assert_rc 2 "$RF_RC" "--body is exit 2 on a duplicate lens name"
dup_sha="$(git -C "$dup" rev-parse HEAD)"
rf "$dup" --commits master "$dup_sha"
assert_rc 2 "$RF_RC" "--commits is exit 2 on a duplicate lens name"

# A non-ASCII path is listed as itself, not C-quoted, so it matches its key.
printf 'x\n' > "$repo/bin/café.sh"
rf "$repo" master
assert_contains "$RF_OUT" "FILE:bin/café.sh medium" "a non-ASCII path under a prefix key fires the lens"
rm -f "$repo/bin/café.sh"

# --- a diff too large for one exec string still fires the lens --------------------------
# Several thousand paths joined exceed the per-string limit of an exec (128 KiB on
# Linux); the matcher used to fail to start, print nothing and exit 0.
big="$(mkrepo rf-big)"
git -C "$big" branch -m master >/dev/null 2>&1
mkdir -p "$big/.claude/review-lenses" "$big/bin" "$big/gen"
printf '%s\n' "$LENS" > "$big/.claude/review-lenses/security.md"
printf 'x\n' > "$big/bin/tool"
commit_all "$big" "lens"
git -C "$big" checkout -q -b feat/big >/dev/null 2>&1
n=0
while [ "$n" -lt 4000 ]; do
  printf '%s\n' "gen/a-rather-long-generated-file-name-to-pad-the-joined-list-$n.txt"
  n=$((n + 1))
done > "$big/list.txt"
( cd "$big" && while IFS= read -r f; do : > "$f"; done < list.txt ) || _fail "fixture: could not create the generated files"
rm -f "$big/list.txt"
printf 'y\n' >> "$big/bin/tool"
joined="$(cd "$big" && git ls-files --others --exclude-standard | wc -c | tr -d ' ')"
[ "$joined" -gt 131072 ] && _pass "fixture: the joined path list is over 128 KiB ($joined bytes)" \
  || _fail "fixture: the path list is only $joined bytes, too small to prove the overflow"
rf "$big" master
assert_rc 0 "$RF_RC" "a diff of thousands of paths is answered"
assert_contains "$RF_OUT" "FILE:bin/tool medium" "a guarded file in a very large diff still fires its lens"
assert_contains "$RF_OUT" "FLOOR:medium" "...and sets the floor"

# A matcher that fails is exit 2 with nothing printed, never "no lens fired". The
# stand-in awk fails whenever it is given -F (only the matcher is) and otherwise
# runs the real awk by absolute path, so it cannot call itself.
real_awk="$(command -v awk)"
shimdir="$CASE_TMP/awk-shim"
mkdir -p "$shimdir"
{
  printf '#!/bin/sh\n'
  printf 'for a in "$@"; do [ "$a" = "-F" ] && exit 127; done\n'
  printf 'exec "%s" "$@"\n' "$real_awk"
} > "$shimdir/awk"
chmod +x "$shimdir/awk"
printf 'y\n' >> "$repo/bin/tool"
RF_OUT="$(cd "$repo" && PATH="$shimdir:$PATH" bash "$RF" master 2>"$CASE_TMP/shim.err")"
RF_RC=$?
assert_rc 2 "$RF_RC" "a matcher that cannot run is exit 2"
[ -z "$RF_OUT" ] && _pass "...and prints nothing" || _fail "a failed matcher printed: $RF_OUT"
assert_contains "$(cat "$CASE_TMP/shim.err")" "the lens matcher failed on lens security" \
  "...and the exit 2 is the matcher's own, not an earlier step's"

# --- no lenses at all, and usage --------------------------------------------------------
plainrepo="$(mkrepo rf-nolens)"
git -C "$plainrepo" branch -m master >/dev/null 2>&1
mkdir -p "$plainrepo/bin"; printf 'x\n' > "$plainrepo/bin/tool"
rf "$plainrepo" master
assert_rc 0 "$RF_RC" "a base with no review-lenses directory"
[ -z "$RF_OUT" ] && _pass "no lenses at the base prints nothing" || _fail "printed with no lenses: $RF_OUT"
RF_OUT="$(cd "$plainrepo" && TMPDIR="$CASE_TMP/no-such-dir" bash "$RF" master 2>/dev/null)"
RF_RC=$?
assert_rc 0 "$RF_RC" "no lenses needs no writable temp directory"

rf "$repo" no-such-base
assert_rc 2 "$RF_RC" "a base that does not resolve is exit 2"
rf "$repo"
assert_rc 2 "$RF_RC" "no arguments is a usage error"
rf "$repo" master extra
assert_rc 2 "$RF_RC" "two positional arguments is a usage error"
outside="$(mkdir_plain rf-plain)"
rf "$outside" master
assert_rc 2 "$RF_RC" "outside a repository is exit 2"

finish
