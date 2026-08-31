# Plan — report an inherited task, stop calling the hook armed, write Out of scope after the study

Contract: `task.md`. Three changes over `lib/detect_stage.sh` and `skills/plan/SKILL.md`, plus the
consumers of the two things being changed: the routers that read the `TASK:` line, and the
readers of the `HOOK:` line.

Each step leaves the gate green on its own, so `bash scripts/verify.sh` can be run after any of
them.

## Decision: rename the HOOK: values rather than detect registration

The task offered two options and asked for one to be chosen here, with the reasoning.

**Chosen: (a) rename to `HOOK:conditions-met` / `HOOK:conditions-unmet`.**

Option (b) — read the plugin root's `hooks/hooks.json` and report actual registration — cannot be
made reliable, and the evidence is in this repository rather than in judgement:

1. The detector resolves the **repo** root (`git rev-parse --show-toplevel`). Registration lives
   in the **plugin** root, which is a different directory the script is given no handle on. The
   only handle available is the script's own path, and that is exactly the handle that lies:
   this repository *is* the plugin source, so a checkout of gantry has `hooks/hooks.json` sitting
   at its own root. Any detection anchored on the script's location would report "registered" for
   every gantry checkout, including ones where the plugin is not installed at all.
2. Even reading the correct `hooks/hooks.json` would not answer the question. The file declares
   the hook; whether it fires depends on the plugin being **enabled in the user's configuration**,
   which the script cannot see. A "yes" derived from the manifest would be a second claim the
   script is not entitled to make — replacing one overstatement with a subtler one.

So the honest move is to stop claiming registration and name what is actually computed: the
firing conditions. That makes the residual — "and the hook must also be installed" — visible to
every reader instead of hidden inside a word.

`conditions-met` / `conditions-unmet` are the values, because they read correctly in the sentence
the consumers actually write: "the hook's firing conditions were met on this run."

### The rule for what the rename touches, and what it does not

The word `armed` is used in this repository for two different things, and only one of them is
wrong. **A claim about the detector's output** — "the detector reports `armed`", "report whether
the hook was armed" — is the overstatement, because the detector cannot see registration. **A
claim about the hook itself** — that a repo has been armed by registering the hook and adding
`.claude/gates.sh`, or that the hook is inert until its conditions hold — is accurate and stays.

By that rule the sweep touches `skills/auto/references/orchestration.md`, `skills/auto/SKILL.md`,
`skills/auto-unattended/SKILL.md`, `skills/implement/SKILL.md`, `docs/SKILLS.md` and
`tests/cases/stage_phases.sh`, and leaves `hooks/readiness-gate.sh`, `README.md`,
`docs/METHOD.md` and `CHANGELOG.md` alone. `docs/METHOD.md` in particular contains no `HOOK:` at
all — its three `armed` uses are the hook describing itself, the same usage `README.md` keeps —
so rewriting them would leave two docs describing one hook in two vocabularies.

## Steps

### 1. Rename the HOOK: values, and update the assertions with them

`lib/detect_stage.sh`: change the two `echo` lines to `HOOK:conditions-met` and
`HOOK:conditions-unmet`, and rewrite the `HOOK:` line in the header comment block and the comment
above the `if` so both say what the line establishes — the hook's firing conditions — and state
plainly that registration is not visible to the script.

`tests/cases/stage_phases.sh` changes **in the same step**, not later: the three `assert_contains`
calls, the section banner above them, the assertion labels (which say "arms"/"disarms"), and the
file's header comment. Splitting these across two steps would leave the suite red in between,
which contradicts this plan's own claim that the gate can be run after each step.

**Check:** `bash tests/run.sh` green; `bash lib/detect_stage.sh` prints `HOOK:conditions-unmet`;
no `armed` left in either file.

### 2. Add TASK:inherited to the detector

Add a `task_is_inherited()` helper beside the existing parsers and switch the `TASK:` line to use
it. It must sit **outside** `frontmatter_status()`, which `scripts/verify.sh` diffs byte-for-byte
against the hook's copy and which must not be touched. `open_questions_forks()` is the precedent:
a self-contained function with its rules written above it.

The rule, which goes into the header comment block as a documented fact:

- `task.md` exists at `ROOT`; **and**
- its frontmatter `status:` is exactly `shipped`; **and**
- `HEAD` is on a branch (not detached); **and**
- a base branch resolves to an existing rev; **and**
- `git merge-base HEAD <base-rev>` succeeds; **and**
- `<merge-base>:task.md` exists and its bytes are identical to the file on disk.

Anything else is `present`.

Three details the first draft of this plan got wrong, corrected here because the header comment is
written from this list:

- **The detached-HEAD guard is explicit, not emergent.** Base resolution does not consult whether
  `HEAD` is symbolic — it looks for `develop`, `origin/HEAD`, `main`, `master` — so a detached
  `HEAD` sitting on a commit reachable from `master` would resolve a base, find a merge-base, and
  return `inherited`. The function therefore starts with `git symbolic-ref --quiet --short HEAD`
  and returns non-zero when it yields nothing.
- **The resolved base is a rev, on every leg, preferring the remote-tracking ref.** Resolution
  mirrors `skills/ship/scripts/detect_state.sh` — `develop` unless we are standing on it, then
  `origin/HEAD` if its ref still resolves, then the first of `main`/`master` that exists — but it
  must end by turning the chosen *name* into `origin/<name>` whenever that ref exists, and only
  fall back to the local branch when it does not. `gantry:worktree` bases every worktree on
  `origin/<parent>` and treats fast-forwarding the local ref as a convenience it may skip, so
  merge-basing against a local `master` that lags origin would find an older commit carrying a
  *different* merged `task.md`, the bytes would differ, and the feature would silently never fire
  in the exact workflow it exists for.
- **Ship's final fallback is deliberately not copied.** `detect_state.sh` ends with a literal
  `BASE="main"` so it always has a PR target. Here, nothing resolving means the fact cannot be
  established, and that must degrade to `present`.

Degradation is by construction: the function returns non-zero at the first condition it cannot
establish, and every `git` call inside it is `2>/dev/null` with its status checked. A detached
`HEAD` fails at the symbolic-ref guard; a repository with no `develop`/`origin/HEAD`/`main`/
`master` fails at base resolution; a repository with no commits at all has no refs, so it also
fails at base resolution rather than at `merge-base`, which is never reached; a `task.md` absent
from the merge-base commit fails at `rev-parse`.

The byte comparison is `git cat-file blob <sha> | cmp -s - "$ROOT/task.md"` — a true byte
comparison rather than a re-hash, so no filter or line-ending setting can make two different files
compare equal, and an **absolute** path so the answer does not change when the detector is run
from a subdirectory (its header promises it works from anywhere inside the tree).

**Verification already done.** This logic was exercised as a standalone prototype against ten
throwaway repositories before being written into the script: a fresh branch off `master` with an
untouched `task.md` gave `inherited`; a superseded file, a non-terminal status, a repo with no
resolvable base, a detached `HEAD`, a repo with no commits, a `task.md` deleted from disk, and a
one-byte difference each gave `present`; a linked worktree gave `inherited`; and the script's own
exit status was undisturbed. The fixtures in step 6 pin the same cases in the suite.

**Check:** in this worktree, `bash lib/detect_stage.sh` prints `TASK:present` — the file was
superseded, so this is the negative case, and it is the only one this worktree can demonstrate.

### 3. Route TASK:inherited in the plan skill

In `skills/plan/SKILL.md` step 1, add a `TASK:inherited` bullet above the `TASK:present` one: the
file is a merged task's contract that arrived on the branch, so this is a clean start — write both
files fresh, do not ask, do not revise. Give the reason in one clause; the rule reads as dangerous
without it. Leave the `TASK:present` bullet byte-identical.

**Check:** the step names all three `TASK:` values; the `TASK:present` bullet is unchanged in the
diff.

### 4. Reorder the plan skill's steps

- **Step 2** writes the frontmatter, *Context & goal*, *Acceptance criteria*, *How to verify* and
  *Open questions* — everything the task description and the conversation settle — and says that
  *Out of scope* and *Affected areas* are left for after the study.
- **Step 3** stays the code study and the explorer dispatch.
- **A new step 4** writes *Out of scope* and *Affected areas* together from what the study found,
  with one sentence on why: what a change touches is what tells you what it deliberately will not
  touch, and both `gantry:review` and `gantry:handover` read *Out of scope* as a boundary rather
  than a draft.
- Later steps renumber: "Ask what is still open" becomes 5 (it already is), "Record the status"
  becomes 7.

The cross-references to fix are these three, and the inventory in the first draft was wrong about
them:

- The line in step 2 reading "Leave **Affected areas** empty for step 3" must become step 4 **and**
  change meaning — it is no longer a note about one section being deferred but about two.
- The line in the *Ask, don't assume* prose above the steps reading "step 6 will not mark it so"
  points at the status step, which becomes step 7. It sits above the step list, so it is easy to
  miss when only the numbered body is scanned.
- The line in step 5 reading "the forks from step 2" is **unaffected** — the forks are still
  written in step 2.

Current step 6 contains no step-number reference at all.

The opening claim near the top of the body — "Write them **before reading much code**" — is
qualified rather than deleted. The intent it protects is real: the contract's goal and criteria
must not be written to fit what the code turned out to make easy. The qualification is that this
applies to intent and criteria, while the two sections that require code knowledge follow the
study.

Chosen over marking those sections provisional and revisiting them: a provisional section still
reads as authoritative to the phases downstream.

**Check:** no sentence instructs *Out of scope* to be written before the study; step numbers are
contiguous; every cross-reference resolves; the body stays under 500 lines.

### 5. Teach the other two routers about the third value

Adding a value to `TASK:` breaks every consumer that routes on `present` and does nothing
otherwise. A full grep finds three routers besides the plan skill:

- **`skills/handover/SKILL.md`** — its `TASK:present` bullet says to read `task.md`'s *Out of
  scope* first. On `TASK:inherited` that bullet silently stops matching and the read is skipped
  with no warning. The bullet must cover both values.
- **`skills/auto-unattended/SKILL.md` stage 2** — "**Never clobber an existing `task.md`**: under
  `--here` a task already in flight means stop and report, not overwrite." Left as written, an
  unattended run on a freshly branched worktree gets "clean start, write both fresh" from the
  plan skill and "never clobber, stop and report" from the driver that invoked it — two live
  instructions in direct contradiction, in the one mode the contract names as the failing case.
  The rule must be narrowed to a task that is genuinely in flight, which is now a fact the
  detector reports rather than a judgement.
- **`skills/review/SKILL.md`** routes only on `TASK:absent` and treats everything else as a
  contract, so a third value degrades exactly as `present` does today. No change; recorded here so
  the next reader does not have to re-derive it.

**Check:** `grep -rn 'TASK:' skills/` shows no bullet that names `present` without also handling
`inherited`, except `review`'s `absent`-only branch.

### 6. Extend the test case

In `tests/cases/stage_phases.sh`, in the existing idiom (`mkrepo`, `write_task`, `write_gates`,
`run_stage`, `assert_contains`), add fixtures for:

- a repo with a base branch, a committed `task.md` at `status: shipped`, and a feature branch cut
  from it → `TASK:inherited`;
- the same repo after the file is modified on the branch → `TASK:present`;
- the same bytes but `status: planning` → `TASK:present`;
- a repo with no resolvable base branch → `TASK:present`;
- a detached `HEAD` → `TASK:present`.

Two traps the first draft walked into:

- **The fixtures must name their branches explicitly** (`git init -b`, or `git branch -m` after
  the fact). `mkrepo` inherits the developer's `init.defaultBranch`; a machine set to `trunk`
  would resolve no base and fail the positive assertion for a reason unrelated to the change.
- **The "no resolvable base" fixture must otherwise be a *positive* case** — a committed,
  byte-identical, `shipped` `task.md` — with only the base made unresolvable. Built from a bare
  `mkrepo`, `<merge-base>:task.md` would not exist either, so the assertion would pass whether or
  not the degradation logic is there at all. That is a false green on the one asymmetry the whole
  design rests on.

No new helper is added to `tests/lib.sh`: this setup is used by one case, and a helper used once
is indirection rather than reuse.

**Test strategy.** The detector's new behaviour gets fixtures because it is a pure function of a
repository's state, cheap to pin, and because the failure it guards against — reading a live task
as inherited — destroys work and would otherwise only surface when someone lost some. The prose
changes get no test: `scripts/verify.sh` already enforces what is mechanically checkable about a
skill file, and asserting on the wording of a step pins the sentence rather than the behaviour.

### 7. Update the readers of the renamed line

Per the rule above:

- `skills/auto/references/orchestration.md` — the sentence documenting the two values, and enough
  of its paragraph that it no longer reads as a statement that the gate was enforced.
- `skills/auto/SKILL.md`, `skills/auto-unattended/SKILL.md`, `skills/implement/SKILL.md` — the
  report instructions that say "armed or inert". Each keeps its point: a run whose conditions were
  unmet, or whose hook was never registered, was self-policed.
- `docs/SKILLS.md` — **two** places, not one: the plan-phase report line that says "armed or
  inert", and a second line further down that says only "whether the hook was armed". The second
  survives a `grep` for `HOOK:` and is the kind of consumer a value-shaped search misses.

**Check:** `grep -rn 'HOOK:' skills/ docs/ README.md tests/` shows no old value, and
`grep -rni 'arm' skills/ docs/ tests/` leaves only hits that are claims about the hook itself.

### 8. Correct the docs that describe the old plan ordering

- `docs/ARCHITECTURE.md` states that `task.md` is filled in two passes, with out-of-scope written
  "*before any code is read*" and only *Affected areas* deferred. That is exactly the rule change 3
  reverses; left alone, the architecture doc and the skill would contradict each other and both
  the acceptance criteria and the gate would still go green, because the criterion is scoped to
  the skill file.
- `docs/SKILLS.md`'s plan-phase entry lists out-of-scope among what is written first, and states
  the skill "**Refuses:** to clobber an existing `task.md` or `plan.md` — it offers to revise
  instead", which stops being true for `TASK:inherited`. Both lines change.

**Check:** no document still describes the two-pass split with out-of-scope in the first pass, and
none describes a refusal the skill no longer performs.

### 9. Document what a config grep cannot see

Where the hook's registration is described — `README.md`'s readiness-hook section and
`docs/METHOD.md` — state plainly that the hook is registered at **plugin** level through the
plugin's own `hooks/hooks.json`, so grepping `settings.json` finds nothing and proves nothing, and
name what does show whether it ran: the hook's own audit log.

This is the half of the change that stops the next reader reaching the wrong conclusion, and it is
why the rename alone would not have been enough. It is the one edit `docs/METHOD.md` gets.

### 10. Add a CHANGELOG entry

The detector's output contract gains a value and loses two. `CHANGELOG.md` already records the
previous fix to this same line, so the precedent is set; nothing enforces it, which is exactly why
it needs to be a step rather than a habit.

### 11. Run the gate

`bash scripts/verify.sh`, which runs `bash tests/run.sh`. Green is the exit condition.

## Left alone, deliberately

Recorded because each looks like an oversight otherwise. The first two go to `handover.md`.

- **`PHASE:` and `NEXT:` still read an inherited task as `done`.** An inherited `task.md` carries
  `status: shipped`, so the snapshot says `TASK:inherited` and `PHASE:done NEXT:none — already
  shipped` in the same breath. Every phase skill except `plan` routes on `PHASE`/`STATUS` rather
  than `TASK`, so they are all still told the work is finished. Deriving `PHASE` from the new
  value is a change to how `implement`, `review` and `ship` route, well outside a contract scoped
  to the `TASK:` line and the plan phase — and the drivers reach `plan` first, which supersedes
  the file and makes the snapshot correct from then on. Deferred, not missed.
- **`plan.md` is inherited on exactly the same terms and gets no third value.** `PLAN:present` on
  a freshly branched worktree still routes `/gantry:grill` to "continue, whatever `STATUS` says",
  so grilling before planning attacks the previous merged plan. The contract covers `task.md`
  only. Deferred.
- **Standing on the base branch itself now yields `inherited`.** With `HEAD` on `master` and the
  committed `task.md` unmodified, the merge-base is `HEAD` and the test reduces to "the file is
  unmodified". That answer is correct — a shipped contract on the mainline *is* inherited — and
  the plan skill separately warns about planning on the default branch. No change.
- **`hooks/readiness-gate.sh`, `README.md`'s arming prose, `CHANGELOG.md`'s history, and
  `tests/cases/hook_audit_trail.sh`** — all covered by the rule above: claims about the hook, not
  about the detector. `tests/cases/hook_inert_unless_armed.sh` asserts on the hook's exit code and
  on whether the gate ran, never on the detector's string; only its filename carries the old word,
  and renaming a test file to chase a vocabulary change costs more history than it buys.

## Notes for the reviewer

- **What this run did and did not exercise, split by what loads it.** The installed plugin is
  pinned at the merge commit this branch was cut from, and the plugin root is a different tree from
  the repo root, so the *phase skills* that drove this run are the old ones.

  - `skills/` and the docs — harness-loaded from the pinned plugin, so **genuinely unexercised**.
    The reordered plan steps and the `TASK:inherited` routing were not followed by this run; it
    followed the old wording, and the merged contract was superseded by hand against it.
  - `lib/detect_stage.sh` — **executed from this worktree**, and demonstrably so. `tests/lib.sh`
    sets `GANTRY_ROOT` from the case script's own path, so `DETECT_STAGE` resolves to the edited
    file. That was confirmed empirically rather than read off a variable: four mutations of the
    detector each flipped a different assertion to FAIL, which a suite running a pinned copy could
    not have done.

  It is still not running *as the installed plugin*, which is why this run's own snapshot said
  `TASK:present` rather than `TASK:inherited` — the phase skills it obeyed were reading the pinned
  detector. A fix to the detector cannot validate itself in the run that writes it.
- This run hit the bug in step 3 itself: the detector opened it with `TASK:present STATUS:shipped
  PHASE:done`, and the plan skill's current wording instructed revising that merged contract. Both
  files were superseded in place instead.

## Grilled

A fresh `gantry-critic` read `task.md` and `plan.md` cold, with the code, and returned 4 blocking,
9 worth fixing and 8 noted. What changed:

- **`docs/ARCHITECTURE.md` documents the ordering being reversed, and the plan had dismissed the
  file after grepping it for `HOOK:` only** → blocking, verified, new step 8. This would have
  shipped a repo whose architecture doc and plan skill disagree, with the gate green.
- **`skills/auto-unattended/SKILL.md` still says "never clobber an existing `task.md`"** →
  blocking, verified, new step 5. The driver would have kept enforcing the exact defect the task
  exists to remove, in the mode the contract names as the failing case.
- **A detached `HEAD` does not fail base resolution** → blocking. The prototype already carried an
  explicit symbolic-ref guard, but the plan claimed the degradation was emergent, and that claim
  was destined for the header comment a criterion says must be reimplementable from. Step 2 now
  states the guard is explicit and why.
- **Base resolution yielding a bare branch name merge-bases against a possibly-stale local ref** →
  blocking. `gantry:worktree` bases worktrees on `origin/<parent>` and may skip updating the local
  ref, so the feature would have failed silently in its own target workflow while all-local
  fixtures stayed green. Step 2 now requires the resolved base to be a rev preferring
  `origin/<name>` on every leg.
- **The "no resolvable base" fixture would have passed with the logic absent**, and **`mkrepo`
  inherits the developer's `init.defaultBranch`** → both folded into step 6 as named traps.
- **`skills/handover/SKILL.md` routes on `TASK:present` and would silently skip the *Out of scope*
  read** → step 5. `skills/review/SKILL.md` checked and needs no change; recorded so it is not
  re-derived.
- **`docs/SKILLS.md` has two `armed` lines, not one, plus a stale description of the plan phase
  and a refusal that stops being true** → steps 7 and 8.
- **`docs/METHOD.md` is not a consumer of the `HOOK:` line at all** — its `armed` uses describe the
  hook itself, the same usage the plan preserves in `README.md` → dropped from the rename sweep,
  which is why the sweep now has a written rule for telling the two kinds of claim apart. It keeps
  only the step 9 edit.
- **Renaming the values in step 1 while updating the assertions in step 5 leaves the suite red in
  between** → merged into step 1.
- **The cross-reference inventory was wrong**: the "step 2" reference in step 5 is unaffected, the
  "step 3" reference in step 2 changes meaning as well as number, and the reference that actually
  needed finding sits *above* the step list → step 4 now names all three.
- **The empty-repo mechanism was stated wrongly** ("fails at `merge-base`"; it fails earlier, at
  base resolution, with no refs to resolve) and **the `cmp` path was relative** → both corrected
  in step 2.
- **No `CHANGELOG.md` entry** → new step 10. **Stale `arms`/`disarms` wording in the test file's
  labels** → folded into step 1.
- **The detector's `PHASE:`/`NEXT:` still say `done`, and `plan.md` is inherited on the same
  terms** → both were real and both are out of contract; moved into an explicit "Left alone"
  section rather than left silent, and carried to handover.

Left as noted, not acted on: the observations about criteria that cannot be shown false. Four of
them were real and `task.md` was tightened in response — the universally-quantified "no input
causes…" became the five states the fixtures actually pin, the duplicate "no upstream" criterion
was merged into "no resolvable base" (nothing in the resolution order consults `@{upstream}`, so
there is no distinct state), and the two that judged prose quality moved to *How to verify* as
human-only checks, where a judgement belongs.

No finding opened a design fork. `FORKS:` stays `none`.

## Reviewed

`/code-review high` was invoked first and **terminated early on an API session limit** (429), so it
produced no findings — a downgrade, not an absence, and recorded as one. A `gantry-reviewer`
sub-agent ran instead: 5 correctness findings, 1 simplification, 1 flakiness. Five addressed, one
declined, one routed to handover.

- **The new "how to check whether the hook is registered" paragraph was false in exactly the case
  a reader is in.** All three copies said an empty `.claude/artifacts/gate-hook.log` shows the hook
  did not run. But `hooks/readiness-gate.sh` tests for `task.md` and `.claude/gates.sh` *before* it
  creates the artifacts directory, so an un-opted-in repo gets no log at all — which is precisely
  the repo someone checking this is usually sitting in. Verified against the hook's source and
  against `tests/cases/hook_audit_trail.sh`, which asserts that an un-armed repo gets no `.claude`
  directory. This was the same shape of error as the one the whole change exists to fix, published
  as the recommended check; the pre-existing sentence in `docs/METHOD.md` had the qualifier and my
  new paragraph had dropped it. Fixed in `README.md`, `docs/METHOD.md` and
  `skills/auto/references/orchestration.md`: `/plugin` answers registration, and the log answers
  "did it run" only inside the arming window.
- **The byte-identity guard had no fixture** — the guard the entire asymmetry argument rests on.
  Every existing case was rejected by an earlier guard, so the comparison could have been deleted
  and the suite would still have passed. Added a fixture that keeps `status: shipped` and changes
  only the body, plus one for a `task.md` the branch introduced. The reviewer could not run the
  mutation to confirm; it was run here, and deleting the comparison does now turn the new
  assertion red.
- **`skills/plan/SKILL.md` said "provably finished and provably unedited" of both files**, but the
  check only ever reads `task.md`. Reworded to say which file was proven, and to stop and ask on a
  `plan.md` that has clearly been worked on.
- **"the code study in step 4"** — the study is step 3. Reworded.
- **The clone fixture depended on `clone.defaultRemoteName`**, global config this suite states it
  does not read. Pinned with `-o origin`.
- **Declined:** collapsing the `rev-parse` + `cat-file` pair into a single `cat-file "$mb:task.md"`.
  The rejection behaviour is identical, so this is a real simplification — but the header comment
  documents "no `task.md` at the merge-base fails the rev-parse" as a distinct degradation path,
  and in a guard whose wrong answer destroys work, an explicit check that can be read off against
  the documented rule is worth one subprocess.
- **Routed to `handover.md`:** the `PHASE:`/`NEXT:` contradiction and the missing `PLAN:` value,
  both of which the plan had already listed under "Left alone" and neither of which had anywhere
  to be recorded outside this branch. The reviewer was right that a changelog pointing at a
  `handover.md` that did not exist was a dangling reference.
