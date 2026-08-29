# Changelog

## 0.3.0

**The first released version.** 0.1.0 and 0.2.0 were developed in the open but never tagged or
published, so there is no upgrade path from them and nothing to migrate; they are recorded below as
history.

The theme is that the plugin's one claim is now demonstrable rather than argued. gantry says a
guarantee belongs in a script's exit code rather than in prose — and until this release, prose was
the only thing that had ever checked the two scripts carrying that guarantee.

**Added**
- `tests/` — a fixture-repo suite over `lib/run_gates.sh`, `hooks/readiness-gate.sh` and
  `lib/detect_stage.sh`. Ten cases, no framework: build a throwaway repo, run the script, compare
  one integer. Covers the block-on-red dispatch, all three firing conditions against every status
  value, `stop_hook_active` and its jq-failure path, the frontmatter parser's six documented
  tolerances and its rejections, a broken install failing red, the kill switch, gate resolution
  order, the 2-and-3-normalise-to-1 rule, `NO-GATES` lenient versus `--strict`, and a monorepo
  subproject failure. Run with `bash tests/run.sh`; `scripts/verify.sh` runs it too, so CI needs no
  change. Confirmed non-vacuous: changing the hook's red dispatch from `exit 2` to `exit 0` is
  caught by five of the ten cases.
- `scripts/context_budget.sh` — the always-on context cost as an exit code, wired into
  `verify.sh`. It counts description characters as a proxy (stated as one) because the enforced
  check cannot depend on the `claude` CLI that CI runners lack; the CLI remains the authority.
- A CI job on tags asserting the tag matches `plugin.json`'s `version`, so a release and its
  manifest cannot disagree.

**Fixed**
- **The readiness hook logged nothing on the one path where the gate is silently bypassed.** Every
  `log_line` on the firing path ran after `run_gates.sh` returned, while the hook's own header
  documents that a hung gate is killed by the harness at its 300s limit with no `exit 2` produced
  and the stop proceeding un-gated. The single case the audit trail exists for was the single case
  it missed. An `arm` line is now written before the gate starts, so a killed hook leaves a dangling
  `arm` with no outcome. The claims in `README.md` and `docs/METHOD.md` are corrected to match.
- **The readiness hook created `.claude/artifacts/` in every repo you opened.** `mkdir -p` ran
  before any firing condition, and the hook is registered on `Stop` and `SubagentStop` with matcher
  `*` — so installing gantry meant every repository acquired a directory and a skip line per stop,
  once per sub-agent, for a plugin it never opted into. The `task.md` and `.claude/gates.sh` tests
  now run first and a repo failing either exits inert and silent. Ordering them ahead of
  `stop_hook_active` is safe: a repo that never runs the gate cannot produce the block a later stop
  would be caused by.

**Removed**
- **`gantry-verifier`.** It shipped in both prior versions and nothing ever dispatched it, which
  three documents said while defending it as an open question. It was not one: the gate is a script
  so that "did it pass" is an exit code rather than a model's judgment, and an agent that cannot be
  wired in without contradicting that argument is just ~70 always-on tokens per session with no
  caller. The roster is now `gantry-explorer`, `gantry-critic` and `gantry-reviewer`, all read-only.

**Changed**
- Always-on context is **measured** at ~1,464 tokens rather than derived — twelve skills and three
  agents, read from `claude --plugin-dir . plugin details gantry`. v0.2 published ~1,545 scaled from
  v0.1's reading. `README.md` and `docs/SKILLS.md` carry the read figures, and the budget script now
  enforces them.

## 0.2.0 — developed, never released

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
- `.claude/gates.sh` for this repo, execing `scripts/verify.sh`. gantry shipped a hard gate and did
  not apply it to itself: with nothing to auto-detect here, `run_gates.sh --strict` reported
  NO-GATES and refused to push, so an unattended run on gantry had to drop `--strict` or supply the
  file by hand. It also arms the readiness hook on this repo.

- **`ship` reviews before it pushes.** A stage between the commit and the push invokes
  `/code-review --fix` over the branch diff, commits what it applies as its own commit, and
  re-runs the gate over the result — a red gate there stops the push. It exists for the caller who
  types `/gantry:ship` directly on a small change: previously that opened a PR nothing had read.
  Skipped by `--no-pr`, and by the new **`ship --reviewed`**, which both drivers always pass so a
  chain that already ran `/gantry:review` is not reviewed twice.
- **An open fork blocks the plan stage.** `lib/detect_stage.sh` reports a new `FORKS:` line
  (`open` | `none` | `unknown` | `absent`) from `task.md`'s *Open questions*, and the phases route
  on it: `plan` and `grill` will not mark a task ready while a fork is undecided, `auto` puts the
  open forks to you in one `AskUserQuestion` round after plan *and* after grill, and
  `auto-unattended` journals an `escalation`, sets `status: blocked`, and stops. `implement`
  refuses outright when a driver dispatched it, and warns when you typed it yourself.
  `scripts/verify.sh` asserts the parser against fixtures.
- `journal.jsonl`'s `escalation` event, reserved since v0.2's first draft, is now emitted — by the
  unattended open-fork stop.

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
- **An unattended run no longer resolves a design fork by guessing.** It used to record the fork
  under *Open questions* and "take the conservative reading" — but an assumption written into a
  plan is indistinguishable from a decision, and by the time it surfaced there was an
  implementation on top of it. A genuine fork now stops the run and escalates. Judgement calls
  inside a plan still take the conservative reading; the distinction is whether two answers would
  send the work in materially different directions.
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
- **The readiness hook could never arm on a worktree run** — which is gantry's own default
  workflow, and every shape `/gantry:worktree` and the drivers produce. `hooks/readiness-gate.sh`
  took its `ROOT` from `$CLAUDE_PROJECT_DIR`, which stays pinned to the checkout the session
  launched from, while `lib/detect_stage.sh` took it from `git rev-parse --show-toplevel`. The two
  therefore read *different* `task.md` files, so the hook saw whatever status the main checkout was
  left on, skipped, and logged `decision=skip reason=status:shipped` forever. The hook now resolves
  the worktree containing the payload's `cwd` first, falling back to the old chain when there is no
  cwd or it is not in a repo.

  This also fixes `detect_stage.sh`'s `HOOK:` line, which was reporting `armed` on exactly the runs
  where the hook could not fire — the detector resolved to the worktree and saw `implementing`
  while the hook resolved elsewhere and saw something else. That line exists so a skill can say
  whether the gate is really enforced rather than imply it; it was doing the implying. One root,
  one answer, both sides.

  `scripts/verify.sh` now asserts the behaviour: a worktree marked `implementing` over a red gate
  must block, the same worktree marked `shipped` must stay inert, and a payload with no cwd must
  still fall back to `$CLAUDE_PROJECT_DIR`.

**Not done, deliberately** — `auto-unattended` was considered for rebuild on Claude Code's Workflow
tool and rejected for now: workflows are plan-gated, and whether `Stop`/`SubagentStop` hooks fire
for workflow-spawned agents is undocumented. If they don't, the unattended mode loses the
unskippable gate in the one mode where nobody is watching. See `docs/ARCHITECTURE.md` § "Why the
unattended runner isn't a Workflow".

## 0.1.0 — developed, never released

The extraction itself: a workflow that had been running privately, made portable and packaged as a
Claude Code plugin.

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
