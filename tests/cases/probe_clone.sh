#!/usr/bin/env bash
#
# lib/probe_clone.sh makes the throwaway clone a review's probes run in. What has to hold:
# the clone carries the reviewed tree (HEAD, uncommitted edits, deletions, modes, untracked
# files), shares nothing writable with the source, resolves <BASE>, is removed whole, and
# when it cannot be made the script says so and exits 3 — it never hands back the real path.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

PC="$GANTRY_ROOT/lib/probe_clone.sh"
GITC=(git -c user.email=test@example.invalid -c user.name=test)

export TMPDIR="$CASE_TMP/tmp"
mkdir -p "$TMPDIR"

# create <repo> [args] — sets PC_OUT, PC_RC, PC_DIR (the clone path, or empty).
create() {
  local repo="$1"; shift
  PC_OUT="$(cd "$repo" && bash "$PC" create "$@" 2>/dev/null)"
  PC_RC=$?
  PC_DIR="$(printf '%s\n' "$PC_OUT" | sed -n 's/^PROBE_DIR://p')"
  return 0
}

bash -n "$PC" && _pass "probe_clone.sh parses" || _fail "probe_clone.sh does not parse"
grep -q -- '--no-hardlinks' "$PC" && _pass "clones with --no-hardlinks" || _fail "no --no-hardlinks"
[ "$(grep -v '^ *#' "$PC" | grep -c -- '--shared')" = 0 ] && _pass "never --shared" || _fail "uses --shared"

# --- a repo with a mix of changes ----------------------------------------------------
repo="$(mkrepo src)"
git -C "$repo" branch -m master >/dev/null 2>&1
printf '#!/bin/sh\necho hi\n' > "$repo/run.sh"
printf 'gone\n' > "$repo/doomed.txt"
printf 'ignored.log\n' > "$repo/.gitignore"
commit_all "$repo" "base"
head_sha="$(git -C "$repo" rev-parse HEAD)"

printf 'edited\n' > "$repo/README"
rm "$repo/doomed.txt"
chmod +x "$repo/run.sh"
printf 'fresh\n' > "$repo/new.txt"
mkdir -p "$repo/sub"; printf 'deep\n' > "$repo/sub/deep.txt"
printf 'noise\n' > "$repo/ignored.log"
printf 'status: x\n' > "$repo/task.md"
printf '/task.md\n' >> "$repo/.git/info/exclude"

create "$repo" --base master
assert_rc 0 "$PC_RC" "create succeeds on a dirty tree"
case "$PC_DIR" in /*) _pass "PROBE_DIR is an absolute path" ;; *) _fail "PROBE_DIR not absolute: $PC_OUT" ;; esac
[ "$PC_DIR" != "$repo" ] && _pass "the probe dir is not the real worktree" || _fail "probe dir IS the worktree"

[ "$(git -C "$PC_DIR" rev-parse HEAD)" = "$head_sha" ] && _pass "the clone is at the reviewed HEAD" || _fail "clone HEAD differs"
assert_file_contains "$PC_DIR/README" '^edited$' "a tracked edit reached the clone"
assert_path_absent "$PC_DIR/doomed.txt" "a tracked deletion reached the clone"
[ -x "$PC_DIR/run.sh" ] && _pass "an exec-bit change reached the clone" || _fail "exec bit lost"
assert_file_contains "$PC_DIR/new.txt" '^fresh$' "an untracked file reached the clone"
assert_file_contains "$PC_DIR/sub/deep.txt" '^deep$' "an untracked file in a subdirectory reached the clone"
assert_path_absent "$PC_DIR/ignored.log" "a gitignored file did not"
assert_path_absent "$PC_DIR/task.md" "a git-excluded chain artifact did not"

# Isolation: nothing is shared with the source.
assert_path_absent "$PC_DIR/.git/objects/info/alternates" "the clone has no alternates (not --shared)"
obj="$(find "$PC_DIR/.git/objects" -type f -path '*/??/*' | head -1)"
links="$(stat -c %h "$obj" 2>/dev/null || stat -f %l "$obj" 2>/dev/null)"
[ "$links" = 1 ] && _pass "object files are copies, not hardlinks" || _fail "object file has $links links"
[ -z "$(git -C "$PC_DIR" remote)" ] && _pass "the clone has no remote" || _fail "the clone kept a remote"
[ "$(git -C "$PC_DIR" rev-parse refs/remotes/master 2>/dev/null)" = "$head_sha" ] \
  && _pass "--base <ref> resolves in the clone to the same commit" || _fail "--base did not resolve in the clone"

before="$(git -C "$repo" status --porcelain=v1 | sort | tr '\n' '|')"
printf 'probe\n' >> "$PC_DIR/README"
rm -rf "$PC_DIR/sub"
git -C "$PC_DIR" add -A >/dev/null 2>&1
"${GITC[@]}" -C "$PC_DIR" commit -qm probe >/dev/null 2>&1
git -C "$PC_DIR" checkout -q -b scratch >/dev/null 2>&1
after="$(git -C "$repo" status --porcelain=v1 | sort | tr '\n' '|')"
[ "$before" = "$after" ] && _pass "writes and commits in the clone leave the source's status alone" || _fail "source status moved"
[ "$(git -C "$repo" rev-parse HEAD)" = "$head_sha" ] && _pass "the source HEAD did not move" || _fail "source HEAD moved"
assert_file_contains "$repo/README" '^edited$' "the source README is untouched by the clone's write"
assert_path_present "$repo/sub/deep.txt" "the source's file survives a delete in the clone"

work="$(dirname "$PC_DIR")"
bash "$PC" remove "$PC_DIR"; assert_rc 0 "$?" "remove succeeds"
assert_path_absent "$work" "remove deleted the whole temp directory"
assert_path_present "$repo/.git" "the real repo is intact"
bash "$PC" remove "$PC_DIR"; assert_rc 0 "$?" "removing an already-removed clone is fine"

# --- --base origin/<branch>: the usual <BASE>, which the dropped remote must not take with it --
git -C "$repo" update-ref refs/remotes/origin/master "$head_sha"
create "$repo" --base origin/master
assert_rc 0 "$PC_RC" "create --base origin/master succeeds"
[ "$(git -C "$PC_DIR" rev-parse --verify -q origin/master 2>/dev/null)" = "$head_sha" ] \
  && _pass "origin/master resolves in the clone after the remote is dropped" || _fail "origin/master does not resolve in the clone"
[ -z "$(git -C "$PC_DIR" remote)" ] && _pass "and the clone still has no remote" || _fail "the clone kept a remote"
[ -z "$(git -C "$PC_DIR" for-each-ref refs/probe-base)" ] && _pass "no scratch ref is left behind" || _fail "refs/probe-base left in the clone"
bash "$PC" remove "$PC_DIR"

# --- remove refuses what it did not make ---------------------------------------------
mkdir -p "$CASE_TMP/other/clone"
bash "$PC" remove "$CASE_TMP/other/clone" >/dev/null 2>&1; assert_rc 2 "$?" "remove refuses a dir outside a gantry-probe directory"
assert_path_present "$CASE_TMP/other/clone" "and leaves it"
mkdir -p "$CASE_TMP/gantry-probe.nomark/clone"
bash "$PC" remove "$CASE_TMP/gantry-probe.nomark/clone" >/dev/null 2>&1; assert_rc 2 "$?" "remove refuses a gantry-probe dir with no marker"
bash "$PC" remove "$repo" >/dev/null 2>&1; assert_rc 2 "$?" "remove refuses the real worktree"
assert_path_present "$repo/README" "and the real worktree is intact"
bash "$PC" remove relative/path >/dev/null 2>&1; assert_rc 2 "$?" "remove refuses a relative path"

# --- clean tree and untracked-only tree (empty tracked diff) -------------------------
clean="$(mkrepo clean)"
create "$clean"
assert_rc 0 "$PC_RC" "a clean tree clones (no empty-patch failure)"
assert_file_contains "$PC_DIR/README" '^seed$' "and holds the committed file"
bash "$PC" remove "$PC_DIR"

only="$(mkrepo untracked)"
printf 'u\n' > "$only/u.txt"
create "$only"
assert_rc 0 "$PC_RC" "an untracked-only tree clones"
assert_file_contains "$PC_DIR/u.txt" '^u$' "and carries the untracked file"
bash "$PC" remove "$PC_DIR"

# --- user git config cannot change the patch -----------------------------------------
cfg="$(mkrepo cfg)"
printf 'changed\n' > "$cfg/README"
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true \
  GIT_CONFIG_KEY_1=color.ui GIT_CONFIG_VALUE_1=always create "$cfg"
assert_rc 0 "$PC_RC" "diff.noprefix and color.ui=always do not break the patch"
assert_file_contains "$PC_DIR/README" '^changed$' "and the content is right"
bash "$PC" remove "$PC_DIR"

# --- from a linked worktree ----------------------------------------------------------
wt="$(mkworktree "$clean" lane lane/x)"
printf 'lane edit\n' > "$wt/README"
create "$wt"
assert_rc 0 "$PC_RC" "a linked worktree clones"
assert_file_contains "$PC_DIR/README" '^lane edit$' "with the lane's uncommitted edit"
[ "$(git -C "$PC_DIR" rev-parse --abbrev-ref HEAD)" = "lane/x" ] && _pass "on the lane's branch" || _fail "wrong branch in the clone"
bash "$PC" remove "$PC_DIR"

# --- failure: reduced coverage, never the real path ----------------------------------
out="$(cd "$repo" && TMPDIR="$CASE_TMP/does-not-exist" bash "$PC" create 2>/dev/null)"; rc=$?
assert_rc 3 "$rc" "an unusable TMPDIR exits 3"
assert_contains "$out" "PROBE:unavailable" "and says PROBE:unavailable"
assert_not_contains "$out" "PROBE_DIR:" "and prints no PROBE_DIR"
out="$(cd "$repo" && bash "$PC" create --base no-such-ref 2>/dev/null)"; rc=$?
assert_rc 3 "$rc" "an unresolvable --base exits 3"
leaked=""
for d in "$TMPDIR"/gantry-probe.*; do [ -e "$d" ] && leaked="$leaked $d"; done
[ -z "$leaked" ] && _pass "a failed create leaves no temp directory" || _fail "a failed create leaked:$leaked"

out="$(cd "$CASE_TMP" && bash "$PC" create 2>&1)"; rc=$?
assert_rc 2 "$rc" "outside a repo is a usage error"
bash "$PC" bogus >/dev/null 2>&1; assert_rc 2 "$?" "an unknown subcommand is a usage error"

# --- old leaked clones are swept ------------------------------------------------------
mkdir -p "$TMPDIR/gantry-probe.old/clone"; : > "$TMPDIR/gantry-probe.old/.gantry-probe"
touch -d '3 days ago' "$TMPDIR/gantry-probe.old" 2>/dev/null || touch -t 200001010000 "$TMPDIR/gantry-probe.old"
mkdir -p "$TMPDIR/gantry-probe.stranger"; : > "$TMPDIR/gantry-probe.stranger/keep"
touch -d '3 days ago' "$TMPDIR/gantry-probe.stranger" 2>/dev/null || touch -t 200001010000 "$TMPDIR/gantry-probe.stranger"
create "$clean"
assert_path_absent "$TMPDIR/gantry-probe.old" "create sweeps a clone older than a day"
assert_path_present "$TMPDIR/gantry-probe.stranger/keep" "the sweep leaves an old match with no marker alone"
rm -rf "$TMPDIR/gantry-probe.stranger"
bash "$PC" remove "$PC_DIR"

[ "$FAILURES" -eq 0 ]
