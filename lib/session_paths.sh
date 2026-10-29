#!/usr/bin/env bash
# session_paths.sh — one definition of where gantry writes OUTSIDE the repo.
#
# Sourced, not executed. Two callers today: skills/preserve/scripts/doc_path.sh
# (session handoff documents) and lib/archive_artifacts.sh (the copy of a
# worktree's chain artifacts taken before a prune destroys them). Both land
# under ~/.claude/sessions/<repo-slug>/, and they must agree on that path or a
# repo's notes and its archives drift into two unrelated trees.
#
# The slug mirrors Claude Code's own project-dir convention — the absolute path
# with "/" replaced by "-" — so a repo's gantry output sits beside its
# auto-memory.
#
# THIS FILE SETS NO SHELL OPTIONS, deliberately. doc_path.sh runs under
# `set -uo pipefail` WITHOUT `-e`, because it prints its labeled lines even when
# a step fails. A sourced file that opened with `set -euo pipefail` would turn
# `-e` on inside that caller, and its `mkdir -p "$DIR"` would then exit the
# script before a single line was printed. Function definitions only: no `set`,
# no top-level work.

# slugify <text> — a filesystem-safe fragment, or the empty string when the
# text carries nothing usable (`slugify -` is empty, which is what a detached
# worktree's branch field yields). Callers supply their own fallback, because
# there is no single right one: doc_path.sh wants `session`,
# archive_artifacts.sh wants `detached`.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' \
    | cut -c1-48
}

# repo_slug <abs-path> — the per-repo directory name.
repo_slug() {
  printf '%s' "$1" | sed 's#/#-#g'
}

# sessions_dir <main-repo-root> — the directory everything for that repo goes
# under. Not created here; whoever writes into it creates it.
sessions_dir() {
  printf '%s' "$HOME/.claude/sessions/$(repo_slug "$1")"
}
