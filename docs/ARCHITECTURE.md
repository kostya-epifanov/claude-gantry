# Architecture

How the pieces fit. For *why* they are shaped this way, see [METHOD.md](METHOD.md); for per-skill
detail, [SKILLS.md](SKILLS.md).

## Component map

Everything is auto-discovered from the plugin root — no path declarations in `plugin.json`.

```
gantry/
├── .claude-plugin/
│   ├── plugin.json          name: gantry  → the /gantry: namespace
│   └── marketplace.json     name: claude-gantry, one plugin, source "./"
├── skills/<name>/SKILL.md   → /gantry:<name>          (13)
│   ├── references/          long-form detail, read on demand
│   ├── scripts/             skill-local deterministic work, run not read
│   └── templates/           the task.md fallback
├── lib/                     shared runtime scripts     (8)
│   ├── run_gates.sh         the one hard gate
│   ├── gate_coverage.sh     what the gate actually read — reported, never enforced
│   ├── detect_stage.sh      where a task sits on the chain
│   ├── journal_append.sh    argv → one journal.jsonl line
│   ├── lead_reply.sh        a lead's reply → one accepted token, or rejected
│   ├── ensure_excluded.sh   idempotent, race-free .git/info/exclude writes
│   ├── run_phase_headless.sh  a phase in a fresh `claude -p` child → labeled lines + exit code
│   └── diff_fingerprint.sh  one token for the diff, so review.md can be tied to it
├── agents/gantry-*.md       → the delegation roster    (3)
├── hooks/hooks.json         → Stop + SubagentStop      (2)
└── examples/gates.sh        a starter repo-owned gate
```

`lib/` exists because these scripts are shared by several skills *and* by the hook. Putting the
gate under the skill that happened to run it first (`skills/auto/scripts/`, as in v0.1) made the
path a lie as soon as ownership moved.

`gate_coverage.sh` sits beside the gate rather than inside it, and the split is the point.
`run_gates.sh` emits *where* its checks ran; `gate_coverage.sh` compares that against the changed
paths and returns a verdict. Only the caller holds both the verdict and the exit code, so only
the caller can name **green-but-uncovered** — a gate that passed while reading none of the paths
the diff touched. The comparison is a **heuristic** (a root is the directory a check ran in, not
the files it read) and is therefore reported and never enforced: it changes no exit code and adds
no refusal.

`journal_append.sh` and `ensure_excluded.sh` exist for a narrower reason: a worktree-isolated
session refuses a command it cannot verify stays inside the worktree — no substitutions, no
compound structure — so an orchestrator cannot build a JSON line or do a read-then-append in its
own argv. Moving that into a script is the only way to keep the caller's command flat.

`lead_reply.sh` is the same move made for a different hazard. Under `gantry:auto --lead`, a lead's
reply is relayed text, and the option labels are often quoted from a plan. So both reach the script
as files the caller wrote with its Write tool, never as argv. Only flags go on the command line.
The script's exit code, not the model's reading of the reply, decides whether the reply answered
anything.

`run_phase_headless.sh` is the newest and the only one that starts a model: it launches one
phase in a fresh headless child session, sets the child's tool boundary from the command line, and
turns the child's JSON result plus what it left on disk into labeled lines and an exit code. See
*Headless phases* below. `diff_fingerprint.sh` exists for it: `review.md` has to say which diff it
describes, and a pipe in a skill's argv is a command a worktree-isolated session refuses.

None of them is a framework; all eight take flags in and return a contract.

A skill body enters the conversation when it fires and **stays there for the rest of the session**.
That is why detail lives in `references/` (loaded only when the skill says to read it) and why
deterministic work lives in `scripts/` (run, never pasted). The always-on cost is roughly the
frontmatter `description` of each skill; `claude plugin details gantry@claude-gantry` prints both
columns.

## Who invokes whom

There is **one** chain of phases, and three ways to run it. The drivers do not contain a pipeline;
they dispatch the same phase skills a human would type.

```mermaid
flowchart TB
  subgraph drivers ["the two drivers — dispatch only, no phase logic"]
    A["gantry:auto — pauses twice"]
    U["gantry:auto-unattended — never pauses, draft PR"]
  end
  subgraph chain ["the phase skills — one procedure, whoever runs it"]
    P["gantry:plan → task.md + plan.md"] --> GR["gantry:plan-grill → a fresh critic"]
    GR --> I["gantry:implement → owns the gate"]
    I --> RV["gantry:review → report, fix with --fix, hand over"]
  end
  W["gantry:worktree — branch, worktree, parent fetch"] --> P
  H["gantry:handover → handover.md"]
  S["gantry:ship — commit, push, PR"]
  A --> W
  U --> W
  You["you, typing them"] --> W
  RV -- "deferred" --> H --> S
  RV -- "clean" --> S
```

The **drivers** own three things and nothing else: which mode is running, when to pause, and which
phase skill runs next. Everything a phase actually *does* lives in the phase skill, which is why the
three ways of running cannot drift into three pipelines.

`integrate` starts where `ship` stops. Run several lanes and the result is several pull requests,
each checked only against the base it was cut from, so nothing has yet checked them *together*. It
merges the ready ones into one `integration/<date>` branch, one at a time with the gate after each
merge, and opens a single pull request. It reuses `ship`'s `detect_state.sh` for the base and the
PR's status, `worktree` for the lane, the reviewer role for the resolutions, and `handover` for
findings that belong to a source PR's author — the same rule as the drivers: orchestrate the
existing skills, own only what is new. What is new is three scripts and the merge order they
compute.

`sync` closes the loop the other way: it returns you to the base branch, then hands off to
`prune-worktrees` to remove the lanes the merge just made redundant. `preserve` sits outside the
pipeline entirely — it records the conversation, not the repo.

## Skills carry the procedure, agents carry the boundary

The roster and the phase skills answer different questions, and keeping them separate is what makes
delegation trustworthy:

- **A skill says what to do.** One body, read identically whether a human typed the command or a
  sub-agent was told to invoke it.
- **An agent says what the runner is *able* to do.** `gantry-explorer` cannot write because it has
  no `Write` tool. `gantry-reviewer` cannot commit for the same reason. No prompt overrides that.

So a driver **invokes** `/gantry:plan` — rather than restating the planning procedure into a
prompt, which is how two copies of a procedure start disagreeing. Delegation happens one level
down, inside the phase, where the sub-job is narrow enough for a tool boundary to mean something:
`plan` dispatches the explorer when the surface warrants it, `plan-grill` always dispatches a fresh
critic, `review` dispatches an independent reviewer.

**That split is what lets every shipped agent be read-only.** A phase has to write — `task.md`,
`plan.md`, the code itself — so wrapping a phase in an agent means either a writable agent (the
boundary is gone) or a phase that cannot do its job. Keeping the phases in the caller's context —
or in a child session the driver launches, see *Headless phases* — and the agents on the sub-jobs
gets both: the writing is visible where it happens, and every roster agent is one a prompt cannot
talk into changing the tree.

One consequence worth stating, because it is easy to get backwards: a skill's `allowed-tools`
**restricts** what is permitted while the skill is active — it does not grant. A driver therefore
carries `Agent` not because it dispatches phases, but because the phases it invokes dispatch their
own agents, and a tool the driver has not allowed is one the phase cannot reach.

Drawn out, with the two checkpoints `auto` adds and where each phase's sub-job goes:

```mermaid
flowchart TD
  E["/gantry:auto<br/>/gantry:auto-unattended"] --> W["gantry:worktree"]
  subgraph D ["the driver invokes each phase skill in turn"]
    P["/gantry:plan"] --> G["/gantry:plan-grill"]
    G --> I["/gantry:implement"]
    I --> GATE{"gate<br/>--strict when unattended"}
    GATE -- "red" --> I
    GATE -- "green" --> R["/gantry:review"]
  end
  subgraph AG ["each phase delegates its sub-job to a read-only agent"]
    EX(["gantry-explorer"])
    C(["gantry-critic"])
    RV(["gantry-reviewer"])
  end
  P -. "when the surface is wide" .-> EX
  G -. "always" .-> C
  R -. "if /code-review is absent" .-> RV
  W --> P
  G -.- K1{{"auto pauses here:<br/>confirm the plan"}}
  R -.- K2{{"auto pauses here:<br/>confirm the PR"}}
  R --> S["gantry:ship"]
  S --> A(["auto → ready PR"])
  S --> U(["auto-unattended → draft PR"])
```

## Headless phases

**The problem.** A driver invokes every phase in its own session, so by the time review runs that
session holds the plan, the critique and the whole implementation. In the one `auto` run on disk,
`/code-review` started at 187k tokens of context and ran inline, with `Bash` and `Edit`,
dispatching no sub-agent: the diff was reviewed by the model that wrote it, with everything it was
thinking while writing it still in context. That is the weakest possible reviewer, and it was the
default. Review is also the phase that gains most from inheriting none of that.

**What moves.** Where the phase runs, not what it does. Since 0.7.0 the two drivers and
`gantry:ship --review` launch review as a fresh `claude -p "/gantry:review --headless …"` child in
the worktree, through `lib/run_phase_headless.sh`, and read its results from disk. The phase skill
is unchanged in procedure; it gained `--headless` (defer an ambiguous finding instead of asking —
a print-mode child exits when it ends its turn, so it cannot wait for a reply), a findings file,
and a stage-aware `--fix`. Fixing is a **second child**: `gantry:review --fix` sees `REVIEW:pending`
and applies what `review.md` lists instead of reviewing again, then re-runs the gate.

**The boundary is an allowlist on the child, not an agent definition.** The roster's agents are
read-only by tool list, and a review child needs to write three artifacts, so the same trick does
not apply. Instead the launcher runs the review child under `--permission-mode dontAsk
--permission-prompts none`, where everything that would prompt is denied, plus `--allowedTools`
naming exactly `Edit(review.md)`, `Edit(handover.md)`, `Edit(task.md)` and Bash rules for four
read-only gantry scripts: `run_gates.sh`, `ensure_excluded.sh`, `detect_stage.sh` and
`diff_fingerprint.sh`. The forms were probed on CLI 2.1.270: an `Edit(<file>)` rule governs the
Write tool too, and a Bash rule matches the literal command, so each script's rule is emitted
twice — `Bash(bash <abs>/lib/x.sh:*)` and `Bash(bash "<abs>/lib/x.sh":*)` — because a skill may
write either and single quotes matched neither. The fix child runs under `acceptEdits` with the
same Bash rules and no `Edit(` rule. Neither child gets `--disallowedTools`, `--lead`, or
`--dangerously-skip-permissions`. Code stays untouchable by the harness, not by prose.

**What the orchestrator's context holds afterwards.** The launcher's labeled lines — `SESSION:`,
`MODEL:`, `EFFORT:`, `TURNS:`, `SUBTYPE:`, `COST_USD:`, `DENIALS:` and one `DENIED:` per denial,
`GATE_EXIT:` after the fix child, `RESULT_FILE:`, `REASON:` on failure, and the child's result text
inside `RESULT_BEGIN … RESULT_END`, last — plus `review.md` and `task.md`'s status, read from disk.
Not the child's transcript: a human who wants it runs `claude --resume <session id>`, and the id is
in the report and in the journal's `phase` event.

**Why the exit code is decided on disk.** A permission denial does not set `is_error`; the child
carries on half-blind and still reports `success`. So denials are printed and never fatal on their
own, and what *is* fatal is the artifact check: after `review`, `review.md` must exist and
`task.md` must say `reviewed` or `blocked`; after `review-fix`, `review.md` must end with an
`applied:` line. `0` means the child completed *and* the phase left what it promises; `1` is a
phase that failed by its JSON or by that check (`max_turns` included); `3` is `claude` itself
failing or writing nothing parseable; `2` is usage or environment.

**Why review is first.** It is the phase that gains the most from a clean context and risks the
least: it writes only artifacts, and the fix step that does write code is gated by the same script
`implement` uses. `implement` would be next — the gain is smaller (it has no author bias to shed)
and the boundary is wider (it must write code) — and `plan-grill` already gets its independence
from the critic's own tool list.

**Limits, stated.** The child runs under print-mode permission defaults, so anything outside the
allowlist that would prompt is denied — tests, Python, shell writes — and a review that needed one
of those is reported with its `DENIED:` lines rather than silently weaker. There is no lead round
trip from a child. `review.md` carries no `session:` line, because a child cannot read its own id;
the launcher prints it. Whether gantry's own `Stop` hook fires inside a `-p` child is unverified —
and it is inert in both children by status anyway, since the hook arms only on `implementing` and
`gantry:review` refuses that status. And `review.md` is tied to a diff by `lib/diff_fingerprint.sh`:
the fix step refuses when the branch or the token no longer matches, so stale findings are never
applied to a tree that moved.

## ship is a stage machine

`ship` is idempotent because it does not track where it is; it **detects** where it is, every
time. `scripts/detect_state.sh` is read-only and emits a single `STAGE:` line; the skill acts on
that and falls through the rest without re-detecting.

```mermaid
stateDiagram-v2
  [*] --> detect
  detect --> notarepo: not a git repo
  detect --> detached: detached HEAD
  detect --> ondefault: sitting on the mainline
  detect --> commitst: uncommitted changes
  detect --> pushst: ahead of upstream
  detect --> prst: pushed, no PR yet
  detect --> behind: remote moved
  detect --> nodiff: nothing to ship
  detect --> done: PR open and current
  commitst --> pushst
  pushst --> prst
  prst --> done
  notarepo --> [*]: refuse
  detached --> [*]: refuse
  ondefault --> [*]: refuse
  behind --> [*]: stop, never rewrite history
  nodiff --> [*]
  done --> [*]
```

Running `/gantry:ship` twice is safe: the second run detects `done` and reports. Three states are
hard refusals — the repo's default branch, a detached HEAD, and a diverged branch. gantry never
rewrites remote history on your behalf.

**The review stage is not on this diagram, on purpose.** Every node above stands for a value
`detect_state.sh` can emit — the node *ids* are mermaid-safe spellings, so `commitst`, `pushst` and
`prst` are the states the script reports as `commit`, `push` and `pr` (likewise `notarepo`,
`ondefault` and `nodiff` for `not-a-repo`, `on-default` and `no-diff`). `review` is not among them:
it is not an entry point, it is not on the default path at all, and it runs only when `--review`
or `--review-fix` asks for it. Drawing it in would claim a `STAGE` that does not exist. What it
does change is the fall-through rule above it: `--review-fix` can move the tree through the fixes
it applies, so the skill **re-detects** afterwards rather than deciding the push from the original
read. A bare `--review` cannot, since 0.5.0: the only files it writes are `handover.md` and
`task.md`'s status, and the artifact contract below excludes both. A run that stops between a
review and the PR (`gh` missing, say) is safe to resume with a bare re-run: ship reviews only when
asked, so re-running without a review flag will not review the branch twice.

## The artifact contract

Every mode writes artifacts at the **worktree root** — not just the delegated one, as in v0.1.
**None of them are committed.** Who owns each, and how it reaches a reader, is the whole protocol:

| Artifact | Written by | Committed | How a reader gets it |
|---|---|---|---|
| `task.md` | `gantry:plan` (Affected areas pasted from the explorer) | no — `.git/info/exclude` | `gantry:ship` quotes the contract into the PR body |
| `plan.md` | `gantry:plan`, revised by `gantry:plan-grill` | no — same exclusion | the human who approves it reads it in the worktree |
| `handover.md` | `gantry:handover`, when review defers something | no — same exclusion | `gantry:ship` quotes it into the PR body |
| `review.md` | `gantry:review` — the findings in scope to fix, with the diff's fingerprint | no — same exclusion | the fix step reads it; never quoted; `lib/detect_stage.sh` reports it as `REVIEW:` |
| `journal.jsonl` | `gantry:auto-unattended`, append-only | no — same exclusion | a run artifact, not a deliverable |
| gate logs | the gate script | no — same exclusion | evidence, kept out of the diff |

**Why none of them are committed.** They are the chain's working state, not the change. Committing
them put a file at the repo root of every target repo that nothing ever deleted, so each merged PR
left the *previous* task's contract sitting in the base branch — which is what `TASK:inherited`
below exists to detect, a mechanism whose whole cost was paid to undo a decision made here. Two
lanes running at once collided on paths that had nothing to do with either change, and gantry's own
repository published three of its dogfooding artifacts to everyone who installed the plugin.

The exclusion goes in **`.git/info/exclude`**, never `.gitignore`: the latter is tracked, so
writing to it would itself be a diff in the user's pull request. `lib/ensure_excluded.sh` asserts
the patterns — `/task.md`, `/plan.md`, `/handover.md`, `/review.md`, each anchored so a project's
own nested `task.md` is untouched — and is idempotent, so every phase that writes one may assert
them first. `scripts/verify.sh` holds the set at four: a call under `skills/` that names `/task.md`
without `/review.md`, or the reverse, is a red check, so the next artifact fails CI rather than
drifting in one call site at a time.
gantry's own repository additionally lists them in its `.gitignore`, because there it is the target
repo and a fresh clone should be safe before any gantry command has run.

**What a reviewer loses, and where it went.** The contract used to reach the reviewer by riding
along in the diff. It now reaches them through the pull request body, which `gantry:ship` composes
— see *Stage 4* in `skills/ship/SKILL.md`. That is a strictly better channel for it: the body is
read, the root-level file was scrolled past, and an unattended run already treated the body as the
entire interface to the reviewer.

These files are also the chain's memory. `task.md`'s `status:` is the phase marker, and
`lib/detect_stage.sh` is the one place a phase reads it from — so a fresh session, a sub-agent, and
a conversation you dropped out of and came back to all resolve the same phase. (The readiness hook
reads the same field with a byte-identical copy of the parser; see below.) **No phase skill may
infer where it is from the conversation**, because in two of the three modes there isn't one.

That the artifacts now exist in every mode is what fixed the v0.1 hole where the readiness hook —
which arms on `task.md` — could never fire under `gantry:auto`.

`task.md` is filled in **two passes**, and the split is between what the task settles and what only
the code can. First, *before any code is read*: frontmatter, goal, acceptance criteria,
how-to-verify and the open questions. Writing the intent first is what stops the plan from quietly
redefining the task to match what the code turned out to make easy.

Then, after the code study: *Out of scope* **and** *Affected areas*, together. Out of scope moved
into the second pass because it is the section that most needs code knowledge — what a change
touches is exactly what tells you what it deliberately will not touch — and it is load-bearing
downstream, where `gantry:review` triages findings against it and `gantry:handover` quotes it. A
boundary written from the task description alone is a guess that later phases read as a decision.

Its `status` field is the chain's state machine:

```
planning → planned → grilled → implementing → implemented → reviewed → shipped
    ↓                                ↓
 blocked                          blocked
```

`planning → blocked` is the open-fork stop: `plan` and `plan-grill` will not advance a task whose
*Open questions* still holds an undecided fork, and an unattended run journals an `escalation` and
blocks there rather than guessing at the answer. A supervised run resolves the fork with the user
instead and continues, so it never reaches that edge.

**The readiness hook arms on exactly one of those values, `implementing`, and ignores the rest.**
That narrowness is deliberate: the hook must not fire while planning is still under way, and
widening the matcher is the easiest way to make it fire constantly and get switched off. The extra
v0.2 values are additive — the hook's condition is unchanged from v0.1, and `lib/detect_stage.sh`
reuses the hook's own frontmatter parser byte for byte so the two cannot disagree about what
`status:` says. `scripts/verify.sh` diffs the two copies to keep that true.

## The readiness hook

What it writes, how to tell whether it is registered and whether it ran, its honest limit and its
history are in [HOOK.md](HOOK.md). Three things about its implementation are easy to get wrong:

1. **Loop termination is `stop_hook_active`, and nothing else.** The harness sets it true on a stop
   that was itself caused by a previous block. The hook defers unconditionally when it is true — or
   when parsing it fails, which is treated the same as true. That single field is the entire reason
   the hook cannot loop, and there is deliberately no counter anywhere in the file.
2. **Only exit 2 blocks a `Stop` hook.** Exit 0 is success; exit 1 is a non-blocking *hook error*
   that fails open. That is why the script uses `set -uo pipefail` and never `set -e`: under `-e`
   an unexpected failure would exit 1 and silently wave the stop through. Every exit in the file is
   0 or 2, on purpose.
3. **A gate exit of 2 is red here, not "unrunnable."** The inline call in `gantry:implement` treats
   exit 2 as a broken environment that must not consume a fix attempt. The hook does not carry that
   exemption — from where it stands, a gate that could not run has not proved the tree good, and an
   unproved tree does not stop. This asymmetry is intentional; an earlier version that "helpfully"
   classified exit 2 as unrunnable would have waved a broken environment through forever.

## Gate resolution

```
.claude/gates.sh at repo root?  ──yes──▶  it IS the gate; its exit code is the result
                                          (a 2 or 3 from it is reported as 1 —
                                           those two codes are run_gates.sh's own)
          │ no
          ▼
auto-detect per ecosystem, at the repo root AND in each
subproject a bounded depth-limited scan finds
(JS · Dart/Flutter · Python · Cargo · Go · Makefile test)
          │ nothing found
          ▼
print NO-GATES  ──▶ exit 0, or exit 3 under --strict
```

The subproject scan is why a monorepo with `app/pubspec.yaml` and `landing/package.json` is covered
rather than silently green. The scan prunes `node_modules`, `build`, `.dart_tool` and friends.

## The agent roster

Three agents ship, and **every one of them is read-only**. The tool list is the boundary — not an
instruction in the body, a property of the agent. An explorer that has no `Write` tool cannot write,
however it is prompted.

| Agent | Tools | Model | Dispatched by | Role |
|---|---|---|---|---|
| `gantry-explorer` | Read, Grep, Glob | haiku | `gantry:plan`, when the surface is unfamiliar or wide | read-only scout; produces the text for `task.md`'s Affected areas. Physically cannot write it. |
| `gantry-critic` | Read, Grep, Glob | opus | `gantry:plan-grill`, always | attacks a plan it did not write. Given no planning context, on purpose. Returns findings; the phase triages and revises. |
| `gantry-reviewer` | Read, Grep, Glob, Bash | opus | `gantry:review`, when `/code-review` is unavailable — from inside the headless review child | reads a diff it did not write. Writes nothing — `Bash` is for reading. |

There is deliberately no planner or implementer agent. Writing is what those phases *are*, so an
agent around one is either writable — and then the roster's guarantee is prose again — or unable to
do the job. v0.2 resolved that by keeping the phases in the caller's context and scoping the agents
to the sub-jobs that genuinely only need to read.

**Resolution is per role, repo first**, and the *phase* does it. If the target repo defines
`.claude/agents/<role>.md`, the phase dispatches that; otherwise `gantry-<role>`. A repo that has
tuned one agent to its codebase overrides that one and inherits the rest.

**There is deliberately no verifier agent either.** v0.1 and v0.2 shipped a `gantry-verifier` that
nothing dispatched, defended as available to callers who wanted a scoped read-only check-runner,
with wiring it in recorded as an open question. v0.3 deletes it, because the method had already
settled the question: the gate is a script precisely so that "did it pass" is an exit code rather
than a model's judgment, and an agent that cannot be wired in without contradicting that is not an
open question — it is ~70 always-on tokens per session, in every session, for a component with no
caller.

## Why no skill is model-gated

Claude Code lets a skill set `disable-model-invocation`, keeping its description out of every
session's listing — a real context saving. No gantry skill uses it.

The reason is that a gated skill cannot be invoked *by an agent at all* — only by a human typing
the command. The drivers invoke every phase skill, plus `worktree` and `ship`. Gating any of them
would make the pipeline undelegatable, and an orchestrator that cannot orchestrate is not worth the
tokens it saves. The cost is paid knowingly: roughly the description of each skill, in every
session.

## The one external hook

`sync` resolves the base branch from, in order: an explicit argument, then an **optional external
profile resolver**, then `ship`'s own detection.

The middle tier is the only place gantry reaches outside itself, and it is a **contract, not a
dependency**: gantry ships no resolver and requires none. Absence is the normal case and is never a
warning — the lookup is skipped entirely and detection takes over. It exists for teams that already
keep the base branch in some registry of their own and would rather gantry read it than guess.

To wire yours in, put an executable named `gantry-profile` on `PATH` supporting:

```bash
gantry-profile <project> BASE_BRANCH     # value on stdout
gantry-profile --task-project <task.md>  # resolve the project from frontmatter
```

with exit codes `0` found · `1` known project, field empty · `2` usage/broken · `3` no such
project. The distinction between 1 and 3 matters: both are silent-normal, but only 2 is worth
mentioning in the report.

The project name comes from `$GANTRY_PROJECT` when you set it, otherwise from the second call
above. An empty project name short-circuits the lookup entirely — it is not an error case, and
forcing it through would produce a broken-profile-looking failure for a repo that simply has no
profile.

## Why the unattended runner isn't a Workflow

Claude Code's Workflow tool is, on paper, the right substrate for `gantry:auto-unattended`: a
deterministic orchestration script with `pipeline()`, `parallel()`, and resume-from-cache. Plugins
can ship a `workflows/` directory, and a headless `claude -p` run does wait for a background
workflow rather than exiting under it. It was considered and rejected for v0.2 on two grounds:

- **It is plan-gated.** Workflows need a recent Claude Code and a paid plan, and on some plans must
  be switched on explicitly. gantry is a published plugin; a headline mode that silently fails for a
  share of installs is worse than a plainer one that always works.
- **Hook firing inside a workflow is unverified.** Nothing documents whether `Stop` /
  `SubagentStop` hooks fire for workflow-spawned agents. If they do not, the unattended mode loses
  the unskippable gate — in precisely the mode where nobody is watching. That property is the whole
  point of the plugin and cannot ship on an inference.

So the runner stays on Agent-tool dispatch with on-disk artifacts, which is portable and whose hook
behaviour is observable. Revisit it as an **opt-in second runner**, not a replacement, once two
things have been tested live: whether `agent()` resolves a plugin's own roster agents by name, and
whether `SubagentStop` fires inside a workflow.
