---
id: 2026-08-31-detector-inherited-task-and-plan-order
title: Report an inherited task as inherited, stop calling the hook armed, and write Out of scope after the code study
project: claude-gantry
branch: fix/detector-inherited-task-and-plan-order
mode: unattended          # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

Three defects, all of the same kind: `lib/detect_stage.sh` and `skills/plan/SKILL.md` state
things they have not established. Two are the detector overstating what it knows; the third is
the plan skill instructing a section to be written before the knowledge that section needs
exists. They are shipped together because they are one pass over the detector and the phase that
reads it first.

**1 — a merged task reads as a task in flight.** gantry commits `task.md` and `plan.md` with
every pull request, so they are in the tree on `master`. A worktree freshly branched from
`master` therefore already contains the *previous* merged task's contract, and the detector
reports `TASK:present STATUS:shipped PHASE:done`. `skills/plan/SKILL.md` step 1 routes
`TASK:present` as "a task is already under way — never clobber either file… ask whether to
revise the existing plan"; with no human present it says to revise rather than replace. So an
unattended run opening on a clean branch is instructed to revise a merged, unrelated contract.

This is not hypothetical and it is not rare — it is every unattended run on this repo. Four
parallel lanes hit it and all four correctly disobeyed the rule and superseded the files anyway.
That is the finding: a rule that is right to ignore four times out of four enforces nothing. The
same argument put the fork check into the detector rather than into prose. The fix is to make
the distinction a fact the script establishes, not a judgement each run re-makes: a `task.md`
that is byte-identical to the copy at the merge-base with the base branch **and** carries a
terminal status is inherited from a merged task, and a clean start is the correct route for it.

The failure mode that matters here is asymmetric, so the detection is deliberately asymmetric
too. Reading a live task as inherited destroys work that cannot be recovered. Reading an
inherited task as present costs one supersede. Every condition the detector cannot establish —
no merge-base, no upstream, no resolvable base branch, a detached HEAD, any git error — must
therefore land on `present`, never on `inherited`.

**2 — `HOOK:armed` claims something the script cannot see.** The detector computes its `HOOK:`
line from the `GATES:` and `STATUS:` values alone. Those are the readiness hook's *firing
conditions*: whether it would block a stop **if it is installed**. Whether it is installed is a
question about hook registration, and the script has no handle on that at all. `armed` reads as
"the gate is enforced on this run", which is exactly the claim it is not entitled to make — and
the consumers repeat the claim, so an unattended run can report enforcement it did not have.

There is a second, related wrong belief in circulation, and the docs should close it: three
lanes grepped `settings.json` for a hook registration, found none, and published "no hook is
registered". That is wrong. `hooks/hooks.json` registers the readiness gate at **plugin** level,
so a config grep cannot see it and cannot support that conclusion in either direction. `/plugin`
can. The hook's audit log answers the narrower question of whether it *ran*, and only once the
repo has opted in — before that the hook exits without creating the log at all, so an empty log
there is what a correctly registered hook produces.

**3 — Out of scope is written before the knowledge it needs.** `skills/plan/SKILL.md` step 2
instructs *Out of scope* to be written "from the task and the conversation, before studying
code", and step 3 is the code study. Out of scope is precisely the section that requires code
knowledge — knowing what a change touches is what tells you what it deliberately will not touch
— and it is load-bearing downstream: `gantry:review` triages every finding against it, and
`gantry:handover` defers on it. A section written from the task description alone, then never
revisited, is guesswork that later phases treat as a contract.

## Acceptance criteria

### 1 — TASK:inherited

- [ ] `lib/detect_stage.sh` emits `TASK:inherited` when, and only when, all of these hold:
      `task.md` exists at `ROOT`; its frontmatter `status:` is exactly `shipped`; `HEAD` is on a
      branch; a base branch resolves to an existing rev; `git merge-base HEAD <base>` succeeds;
      and `<merge-base>:task.md` exists with bytes identical to the file on disk.
- [ ] The rule above appears in the script's header comment block, stating every condition that
      degrades to `present`.
- [ ] A branch cut from a base branch, carrying the base's committed `task.md` unmodified at
      `status: shipped`, reports `TASK:inherited`.
- [ ] The same branch, after `task.md` is modified, reports `TASK:present`.
- [ ] The same bytes carrying a non-terminal status (for example `planning`) report
      `TASK:present`.
- [ ] A repository that is otherwise a positive case but has no resolvable base branch reports
      `TASK:present`.
- [ ] A detached `HEAD` reports `TASK:present`.
- [ ] In each of those five states the detector exits 0 and emits exactly one `TASK:` line.
- [ ] `skills/plan/SKILL.md` step 1 routes `TASK:inherited` to a clean start: write both files
      fresh, no asking, no revising. The `TASK:present` route is unchanged.
- [ ] Every other consumer that routes on `TASK:present` either handles `inherited` too or is
      recorded in the plan as correctly unaffected.

### 2 — the HOOK: line claims only what it establishes

- [ ] The `HOOK:` line's values no longer contain the word `armed`.
- [ ] The script's header comment states that the line reports the hook's firing conditions and
      that registration is not visible to it.
- [ ] `grep -rn 'HOOK:'` across `skills/`, `docs/`, `README.md` and `tests/` shows no occurrence
      of a value the script no longer emits.
- [ ] Each of these six files, enumerated so the criterion can be shown false, uses the new
      vocabulary where it describes the detector's output: `skills/auto/references/orchestration.md`,
      `skills/auto/SKILL.md`, `skills/auto-unattended/SKILL.md`, `skills/implement/SKILL.md`,
      `docs/SKILLS.md` (two places), `tests/cases/stage_phases.sh`.
- [ ] `hooks/readiness-gate.sh`, `README.md`, `docs/METHOD.md` and `CHANGELOG.md` keep their
      existing `armed`/`inert` wording, because there it describes the hook rather than the
      detector's claim about it.
- [ ] The documentation states plainly that a `settings.json` grep cannot see a
      plugin-registered hook, and names what can.

### 3 — Out of scope follows the code study

- [ ] In `skills/plan/SKILL.md`, the step that writes *Out of scope* comes after the step that
      studies the code.
- [ ] *Out of scope* and *Affected areas* are written in the same step, from what the study
      found.
- [ ] The step that runs first writes the frontmatter, *Context & goal*, *Acceptance criteria*,
      *How to verify*, and *Open questions*.
- [ ] No sentence anywhere in the file still instructs *Out of scope* to be written before
      reading code, including the opening claim near the top of the body.
- [ ] Every step-number cross-reference in the file still resolves to the step it means,
      including the one that sits above the step list.
- [ ] `docs/ARCHITECTURE.md` and `docs/SKILLS.md` no longer describe the superseded ordering, in
      which *Out of scope* was written before any code was read.
- [ ] `skills/review/SKILL.md` and `skills/handover/SKILL.md` were checked against the new
      ordering, and the report states whether either needed to change.

### Across all three

- [ ] `tests/cases/stage_phases.sh` covers the new `TASK:` value and the renamed `HOOK:` value.
- [ ] `CHANGELOG.md` records the renamed and added detector values.
- [ ] Every skill body stays under 500 lines — a convention in `CONTRIBUTING.md`, counted by
      hand, not by a script — and `bash scripts/context_budget.sh` passes, which is a separate
      check on frontmatter description length.
- [ ] `bash tests/run.sh` is green.
- [ ] `bash scripts/verify.sh` is green.

## How to verify

```yaml
verification:
  automated:
    lint: true            # scripts/verify.sh — shellcheck, bash -n, manifests
    tests: true           # bash tests/run.sh, including the new stage_phases cases
  human_only:
    - "Read the detector's header comment block cold and judge whether the inherited rule is
       stated completely enough to reimplement from — including every condition that
       degrades to present. This is a judgement about prose, which is why it is here and
       not among the criteria."
    - "Read skills/plan/SKILL.md straight through and confirm no sentence still says or
       implies that Out of scope is written before the code study."
    - "Confirm on a live run that the renamed HOOK: value matches what the registered hook
       actually does. The detector cannot see registration, which is the whole point of the
       rename, so only a real run can close that loop."
```

Commands, run from the worktree root:

```bash
bash scripts/verify.sh                 # the repo gate; includes tests/run.sh
bash tests/run.sh                      # per-case detail
bash lib/detect_stage.sh               # this worktree: expect TASK:present after supersede
grep -rn 'HOOK:' skills/ docs/ README.md tests/
grep -rni 'armed' skills/ docs/ README.md tests/ lib/
```

The first acceptance criterion for TASK:inherited is checked directly by a throwaway fixture in
`tests/cases/stage_phases.sh` rather than by hand, because it needs a repo with a real
merge-base and this worktree only demonstrates the superseded case.

## Out of scope

- `hooks/readiness-gate.sh`. It is not a consumer of the `HOOK:` line, and its own `arm`
  vocabulary — the audit-log keyword and the FIRING CONDITION prose — is used correctly about
  the hook itself rather than about the detector's claim.
- `frontmatter_status()`. `scripts/verify.sh` diffs it byte-for-byte against the hook's copy, so
  editing it in one place breaks the gate. The new detection is a separate function that shares
  no code with it, exactly as `open_questions_forks()` already does.
- Making the hook register itself, or any change to how it is registered.
- Verifying against a live hook that the renamed value matches what actually fires. That needs a
  human watching a real run — see `handover.md`.
- Deriving `PHASE:` and `NEXT:` from the new `TASK:` value. An inherited task still resolves to
  `done`, which contradicts `TASK:inherited` in the same snapshot — see `handover.md`.
- A third value for `PLAN:`. `plan.md` is inherited on the same terms and has no `status:` to
  corroborate byte-identity — see `handover.md`.
- The `FORKS:` parser and `open_questions_forks()`.
- The section order in `skills/plan/templates/task.md` and `examples/task.md`. The two are diffed
  against each other by the gate; the change here is to when the plan skill *fills* sections, not
  to the order they appear in the file.
- Linting acceptance criteria, or any other new check.
- `README.md`'s "arming" prose and `CHANGELOG.md`'s historical entries. The first describes
  registering the hook and adding `.claude/gates.sh`, which is genuinely arming; the second
  records what the values were at the time, which is what a changelog is for.

## Affected areas

**`lib/detect_stage.sh`** — both changes land here. The header comment block documents the output
contract line by line and is where the inherited rule and the corrected `HOOK:` description
belong. `frontmatter_status()` is off limits (see Out of scope). `open_questions_forks()` is the
precedent to follow: a self-contained function with its rules written above it, sharing no code
with the frontmatter parser. The `TASK:` line comes from `present_or_absent()`, a two-value
helper also used for `PLAN:`, `HANDOVER:` and `GATES:` — so the third value needs its own path
rather than a change to that helper, or the other three lines would grow a value they cannot
have.

**Base-branch resolution** — already solved once, in `skills/ship/scripts/detect_state.sh`:
`develop` unless we are standing on it, then `origin/HEAD` if the remote-tracking ref still
resolves, then the first of `main`/`master` that exists. That order is the one to mirror, with
one deliberate divergence: ship ends with a literal `main` fallback so it always has something to
target, and the detector must not — an unresolvable base is precisely a case that has to degrade
to `present`. The risk is copying the fallback along with the rest.

**`skills/plan/SKILL.md`** — step 1 holds the `TASK:` routing; step 2 writes the contract
sections; step 3 is the code study; steps 5 and 6 refer to earlier steps by number, so a
renumbering has to carry them. The claim that the files are written "before reading much code"
sits near the top of the body, above the steps, and is the sentence that would otherwise
contradict the new order.

**Consumers of the `HOOK:` line** — a full sweep found nine places that name the values or
describe them to a reader: the detector's own header and two `echo`s; three assertions and a
header comment in `tests/cases/stage_phases.sh`; the contract sentence in
`skills/auto/references/orchestration.md`; and the report instructions in `skills/auto/SKILL.md`,
`skills/auto-unattended/SKILL.md`, `skills/implement/SKILL.md` and `docs/SKILLS.md`, plus two
descriptive lines in `docs/METHOD.md`. `docs/ARCHITECTURE.md` was expected to be among them and
is not — it contains no occurrence of either. `tests/cases/hook_inert_unless_armed.sh` asserts on
the hook's exit code and on whether the gate ran, never on the detector's string, so its name is
the only thing in it that mentions the old vocabulary.

**`tests/cases/stage_phases.sh` and `tests/lib.sh`** — cases are standalone scripts that source
the shared library and assert with `assert_contains` over `run_stage`'s captured output. The
helpers cover a repo with one commit (`mkrepo`), a `task.md` at a given status (`write_task`), a
gate file (`write_gates`), a linked worktree (`mkworktree`) and a commit (`commit_all`). Nothing
builds a second branch or a merge-base, so the inherited fixture needs plain `git` commands in
the case itself. The risk to watch: `mkrepo` produces a repo whose initial branch is a local
`main` or `master`, which **does** resolve as a base even with no remote — so the
"no resolvable base" fixture has to be built deliberately rather than assumed from the absence of
a remote.

**`scripts/verify.sh`** — the gate. Three of its checks bear on this change: the byte-for-byte
diff of `frontmatter_status()` against the hook's copy, the diff of `examples/task.md` against
the plan skill's template, and the context budget over skill and agent descriptions. It also
builds its own throwaway repo for the `FORKS:` fixtures with no commits and no remote, which the
new detection must survive without erroring.

## Open questions

- [x] Rename the `HOOK:` values, or teach the detector to detect registration? — Decided:
      rename. The requester set the rule ("if detection cannot be made reliable, rename, do not
      ship a second thing that overstates") and the code settles it: the detector resolves the
      repo root while the registration lives in the plugin root, and this repository is itself
      the plugin source — a checkout of gantry has `hooks/hooks.json` at its own root, so any
      detection anchored on the script's location would report "registered" for every gantry
      checkout while still saying nothing about whether the plugin is enabled in the user's
      config, which is the fact that actually decides whether the hook fires. Detection cannot
      be made reliable; the rename is the honest option and it makes the residual visible.
      Recorded in the plan with this reasoning.
- [x] Which statuses count as terminal for the inherited test? — Decided: `shipped` only, at
      first. It is the status a merged `task.md` actually carries, and the narrowest rule that
      degrades to `present` on everything else. Widening it later is safe; a wide rule that
      swallows `blocked` or `reviewed` is not.
