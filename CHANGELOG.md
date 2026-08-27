# Changelog

## 0.1.0 — unreleased

First public release. A faithful extraction of a workflow that had been running privately, made
portable and packaged as a Claude Code plugin.

**Added**
- Seven skills: `auto`, `factory`, `ship`, `worktree`, `sync`, `prune-worktrees`, `preserve`.
- A four-agent roster (`gantry-explorer`, `gantry-planner`, `gantry-implementer`,
  `gantry-verifier`), shipped with the plugin so `factory` works with no setup.
- The readiness hook, registered on `Stop` and `SubagentStop`, inert until armed by a
  `.claude/gates.sh` plus a `task.md` at `status: implementing`. Kill switch:
  `GANTRY_READINESS_GATE=off`.
- `docs/METHOD.md`, `docs/ARCHITECTURE.md`, `docs/SKILLS.md`, and `examples/gates.sh`.

**Changed from the private original**
- `factory` no longer stops when a repo has no `.claude/agents/`. Roster resolution is now per
  role, repo first, falling back to the shipped agents.
- The readiness hook resolves `run_gates.sh` by self-location rather than two hardcoded paths.
- `sync`'s external profile lookup is documented as an optional integration you can implement
  yourself, rather than as a dependency.

**Known limitations** — see `docs/METHOD.md` § "Where this is wrong". In short: the hook's arming
condition is a file the model can write; `gantry-verifier` ships but is not dispatched; and
auto-detection can report `NO-GATES` on a repo whose real checks it cannot see.
