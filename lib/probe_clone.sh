#!/usr/bin/env bash
# probe_clone.sh — a throwaway clone of the worktree under review, for probes.
#
#   probe_clone.sh create [--base <ref>]   print PROBE_DIR:<abs path of the clone>
#   probe_clone.sh remove <clone path>     delete the clone and its temp directory
#
# WHY THIS EXISTS. A review sub-agent sometimes runs a probe — a test, a script, a git
# experiment. Run in the real worktree, a command that gets past a guard (BASE-392) can change
# the lane's files and its shared .git. A probe run in a clone cannot: the clone has its own
# object store (--no-hardlinks, never --shared, so nothing is linked back to the source),
# and no remote pointing home. Reading files in the real worktree is unchanged.
#
# WHAT THE CLONE HOLDS: the worktree's HEAD, plus the uncommitted tracked changes (including
# deletions and mode bits) and every untracked, non-ignored file. Not the chain's artifacts
# (they are git-excluded), not gitignored build output, not submodule contents.
#
# --base <ref> writes that ref's commit into the clone under the same name, so a probe
# that names <BASE> (usually origin/master) still resolves after the remote is dropped.
#
# There is NO fallback. When the copy cannot be made, `create` prints `PROBE:unavailable
# <reason>` and exits 3, and the caller records reduced coverage; it must never probe the
# real worktree instead. Old clones a killed review leaked are swept on every `create`.
#
# Exit: 0 ok · 2 usage / not a repo / refused removal · 3 the clone could not be made.
set -uo pipefail

PREFIX="gantry-probe."
MARKER=".gantry-probe"

die() { printf 'probe_clone: %s\n' "$1" >&2; exit 2; }

unavailable() {  # unavailable <reason> — clean up and exit 3
  [ -n "${WORK:-}" ] && [ -f "$WORK/$MARKER" ] && rm -rf "$WORK"
  printf 'PROBE:unavailable %s\n' "$1"
  exit 3
}

cmd_remove() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || die "usage: probe_clone.sh remove <clone path>"
  local dir="$1" parent
  case "$dir" in
    /*) ;;
    *) die "refusing to remove a relative path: $dir" ;;
  esac
  [ -e "$dir" ] || [ -e "$(dirname "$dir")/$MARKER" ] || exit 0
  parent="$(dirname "$dir")"
  case "$(basename "$parent")" in
    "$PREFIX"*) ;;
    *) die "refusing to remove $dir: not inside a $PREFIX* directory" ;;
  esac
  [ -f "$parent/$MARKER" ] || die "refusing to remove $dir: no $MARKER marker in $parent"
  rm -rf "$parent"
  exit 0
}

cmd_create() {
  local base=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) [ "$#" -ge 2 ] && [ -n "$2" ] || die "--base needs a ref"; base="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
  local root tmp
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "could not resolve the repository root"
  cd "$root" || die "could not enter $root"
  git rev-parse --quiet --verify 'HEAD^{commit}' >/dev/null 2>&1 || unavailable "the repository has no commit to clone"

  tmp="${TMPDIR:-/tmp}"
  [ -d "$tmp" ] && [ -w "$tmp" ] || unavailable "temp directory is not writable: $tmp"

  # Sweep clones a killed review left behind (a day or older); each is a full copy of the objects.
  # Only a directory carrying our marker is ours: a shared TMPDIR may hold a stranger's match.
  local old
  while IFS= read -r -d '' old; do
    [ -f "$old/$MARKER" ] && rm -rf "$old"
  done < <(find "$tmp" -maxdepth 1 -type d -name "$PREFIX*" -mtime +0 -print0 2>/dev/null)

  WORK="$(mktemp -d "${tmp%/}/${PREFIX}XXXXXX" 2>/dev/null)" || { WORK=""; unavailable "could not make a temp directory in $tmp"; }
  : > "$WORK/$MARKER" 2>/dev/null || { rmdir "$WORK" 2>/dev/null; WORK=""; unavailable "could not write the marker"; }
  local real
  real="$(cd "$WORK" && pwd -P)" && [ -n "$real" ] || unavailable "could not resolve the temp directory $WORK"
  WORK="$real"
  local clone="$WORK/clone"

  git clone --local --no-hardlinks -q "$root" "$clone" >/dev/null 2>&1 \
    || unavailable "git clone --local --no-hardlinks failed"
  [ "$(git -C "$clone" rev-parse HEAD 2>/dev/null)" = "$(git rev-parse HEAD)" ] \
    || unavailable "the clone's HEAD is not the reviewed HEAD"

  # No remote: a stray fetch or push has nowhere to go but the clone. Dropped BEFORE the base is
  # recorded, because removing a remote deletes every refs/remotes/<remote>/* ref with it.
  git -C "$clone" remote remove origin >/dev/null 2>&1

  if [ -n "$base" ]; then
    local sha
    sha="$(git rev-parse --verify "$base^{commit}" 2>/dev/null)" || unavailable "base does not resolve: $base"
    # The commit must exist in the clone's own store before a ref can name it; a base not
    # reachable from HEAD is fetched from the source by path (there is no remote any more).
    git -C "$clone" cat-file -e "$sha^{commit}" 2>/dev/null \
      || git -C "$clone" fetch -q --no-tags "$root" "$sha" >/dev/null 2>&1 \
      || unavailable "the base commit could not be copied: $base"
    case "$base" in
      refs/*) git -C "$clone" update-ref "$base" "$sha" >/dev/null 2>&1 || unavailable "could not record $base" ;;
      *) git -C "$clone" update-ref "refs/remotes/$base" "$sha" >/dev/null 2>&1 \
           || git -C "$clone" update-ref "refs/heads/$base" "$sha" >/dev/null 2>&1 \
           || unavailable "could not record $base" ;;
    esac
  fi

  # Uncommitted tracked changes. Flags are pinned so a user's diff.* / color.* config cannot
  # change what `git apply` reads; an empty diff is skipped (apply rejects empty input).
  local patch="$WORK/tracked.patch"
  git diff --binary --no-color --no-ext-diff --no-textconv --no-renames \
      --src-prefix=a/ --dst-prefix=b/ HEAD > "$patch" 2>/dev/null \
    || unavailable "git diff failed"
  if [ -s "$patch" ]; then
    git -C "$clone" apply --binary "$patch" >/dev/null 2>&1 || unavailable "the uncommitted changes did not apply"
  fi
  rm -f "$patch"

  # Untracked, non-ignored files. tar keeps modes and symlinks and is on every platform.
  local list="$WORK/untracked.list"
  git ls-files -z --others --exclude-standard > "$list" 2>/dev/null || unavailable "could not list untracked files"
  if [ -s "$list" ]; then
    tar -cf - --null -T "$list" 2>/dev/null | tar -xf - -C "$clone" 2>/dev/null \
      || unavailable "the untracked files did not copy"
  fi
  rm -f "$list"

  printf 'PROBE_DIR:%s\n' "$clone"
  exit 0
}

[ "$#" -ge 1 ] || die "usage: probe_clone.sh create [--base <ref>] | remove <clone path>"
sub="$1"; shift
WORK=""
case "$sub" in
  create) cmd_create "$@" ;;
  remove) cmd_remove "$@" ;;
  *) die "unknown subcommand: $sub" ;;
esac
