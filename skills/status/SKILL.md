---
name: status
description: Gives a concise "where are we" orientation snapshot — current worktree vs main repo, git branch and sync state, what's in flight (recent commits and uncommitted changes), any plans on record, and where we are in the process. Use when the user types "/gantry:status", or asks "where are we", "what are we working on", "what's the state", "catch me up", or "recap" — especially at the start or resumption of a session.
argument-hint: [focus]
allowed-tools: Bash, Read
---

# gantry:status

Answer "where are we?" in one short, scannable report. Read-only — never commit, push, or edit.

With a `<focus>` arg, still gather everything but weight the report toward it.

## Steps

1. **Gather git facts.** Resolve `$GANTRY` (this skill's plugin root) from this file's location — as the `skill`/`prune-worktrees` skills do — then run one read-only pass:

   ```bash
   bash "$GANTRY/skills/status/scripts/snapshot.sh"
   ```

   It prints: `LOCATION` (worktree/main, branch), `SYNC` (ahead/behind), `WORKING TREE` (clean or dirty counts + short status), `RECENT COMMITS`, `COMMITS ON <branch> SINCE <base>` (feature branches only), `PLAN / DOC FILES`. `NOT_A_GIT_REPO` → say so and stop.

2. **Pull in plans.** The snapshot lists plan files but doesn't read them. Skim any it surfaced, check project memory (`~/.claude/projects/<slug>/memory/MEMORY.md`) — verify its claims against the live repo — and fold in any plan or task list from this session.

3. **Infer process state** from what's in flight: branch + commits-since-base → what it's *for*; uncommitted changes → what's mid-edit; ahead/behind + clean/dirty → commit/push/PR next; this session's actions → the immediate task.

## Report (plain text, tight)

Lead with a one-line answer, then a short block. Omit a line rather than pad it.

- **Where** — worktree/main, branch, path. Flag if the branch differs from what the user expects, or if sitting on `main`/`master`.
- **Sync** — clean or N dirty; ahead/behind. One line.
- **In flight** — synthesized in a sentence or two, not a raw commit dump.
- **Plans** — the plan on record, or plainly "none found". Don't invent one.
- **Next** — the single most likely next step.

Orientation, not an audit. If a `<focus>` was given, expand that part and compress the rest. If nothing's in flight and there's no plan, say exactly that in two lines.
