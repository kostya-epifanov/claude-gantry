# Changelog

## 0.2.0 — unreleased

The pipeline comes apart into phases. v0.1 had two monolithic pipeline skills; v0.2 has one chain
of individually invocable phase skills and two drivers that invoke them. You can now type the
chain yourself, drop out of it to work by hand, and pick it back up.

**Added**
- Five phase skills: `plan`, `grill`, `implement`, `review`, `handover`. Each is invocable on its
  own and resolves its own position from disk rather than from the conversation.
- `grill` — the critique step v0.1 had nothing equivalent to. It **always** dispatches a fresh
  critic sub-agent, in every mode, because a context that wrote a plan cannot grill it.
- `handover` — writes `handover.md` at the worktree root: what a change deliberately left, why, and
  the next action. Committed with the branch, so it reaches the PR. Distinct from `preserve`, which
  records conversation reasoning outside the repo.
- Two agents: `gantry-critic` and `gantry-reviewer`, both read-only.
- `lib/detect_stage.sh` — one read-only reader of "where is this task", shared by every phase.
- `ship --draft`, which `auto-unattended` always passes.

**Changed**
- `factory` is renamed **`auto-unattended`**, and `--autonomous` is gone. A flag that silently
  removes every checkpoint is too easy to append to a command you meant to supervise; typing the
  unattended command is a deliberate act.
- `auto` and `auto-unattended` contain **no phase logic**. They invoke the same skills you would
  type, so the three ways of running cannot drift into three pipelines.
- **Delegation moved one level down.** The drivers no longer wrap each phase in a sub-agent; they
  invoke the phase skill, and the phase dispatches its own scoped agent for the sub-job — `plan` the
  explorer, `grill` the critic, `review` the reviewer. Wrapping a phase in an agent forced a choice
  between a writable agent (no boundary) and a phase that could not write its own artifacts; this
  way every shipped agent is read-only and the writing stays where you can see it.
- `gantry-planner` and `gantry-implementer` are **removed**. They existed to be the sandbox a driver
  dispatched a phase into, and that job no longer exists. The roster is now `gantry-explorer`,
  `gantry-critic`, `gantry-reviewer`, and `gantry-verifier`.
- `journal.jsonl`'s `agent` event becomes **`phase`**, with an `agents` array recording which
  sub-agents the phase actually dispatched. That array is the delegation roll-call the final report
  is checked against.
- **`task.md` and `plan.md` are now written in every mode**, not just the delegated one. This
  closes a real hole: the readiness hook arms on `task.md`, so in v0.1 the hook could never fire
  under `auto` — the headline skill's gate was unenforced. The hook's arming condition is unchanged.
- `run_gates.sh` moved from `skills/auto/scripts/` to `lib/`, now that the gate belongs to
  `implement` rather than `auto`. The hook's resolution was updated to match.
- `task.md`'s `status` vocabulary gains `planning`, `grilled`, `implemented`, and `reviewed`. The
  hook still arms on exactly `implementing` and ignores the rest.
- Always-on context is roughly **a third higher** (~1,157 → ~1,550 tokens, derived rather than
  measured). The phase skills carry deliberately terse descriptions to hold it down.

**Fixed**
- The hook sequence diagram in `docs/METHOD.md` failed to render on GitHub: mermaid treats `;` as a
  statement separator, and one message contained a semicolon. Found by parsing every diagram in the
  repo with mermaid itself — the check that was missing when the previous diagram bug shipped.
- `auto` used `AskUserQuestion` without declaring it in `allowed-tools`.
- `ship` pointed at a `status` skill that had already been removed.
- `scripts/verify.sh` now proves the frontmatter parser duplicated between the hook and
  `detect_stage.sh` has not drifted, and that the task template and its example stay identical.

**Not done, deliberately** — `auto-unattended` was considered for rebuild on Claude Code's Workflow
tool and rejected for now: workflows are plan-gated, and whether `Stop`/`SubagentStop` hooks fire
for workflow-spawned agents is undocumented. If they don't, the unattended mode loses the
unskippable gate in the one mode where nobody is watching. See `docs/ARCHITECTURE.md` § "Why the
unattended runner isn't a Workflow".

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
