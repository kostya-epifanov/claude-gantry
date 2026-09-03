# Handover — integration/v0.4-batch

The work this release deliberately does not do. Six lanes ran in parallel, each wrote its own
`handover.md`, and this file is those four files merged — one section per finding, grouped by the
lane that found it, with nothing dropped except what the integration went on to fix.

**Two findings are gone from this file because they were closed rather than deferred.** Lanes C and
E both recorded `scripts/verify.sh`'s unguarded `mktemp -d` — the one that made the fixture block
run `rm -f /task.md` and `git init` in the repository itself. Each deferred it correctly, as
outside its own contract; the integration's contract is the release, so it is fixed here and
recorded in `CHANGELOG.md` under *Fixed*. The same is true of `gantry-explorer`'s markdown line-number
citations, which lane C recorded and which became a local gate failure the moment C's own change
merged.

Everything below is still open.

## Lane B — `fix/detector-inherited-task-and-plan-order`
### `PHASE:` and `NEXT:` still read an inherited task as already shipped

**What it is.** `lib/detect_stage.sh` now reports `TASK:inherited` for the previous, merged
contract that arrives in every freshly branched worktree — but that same `task.md` carries
`status: shipped`, and `PHASE` is derived from `STATUS` alone. So the detector emits
`TASK:inherited` and `PHASE:done NEXT:none — already shipped` in one snapshot, which is
self-contradicting on its face.

It matters because `TASK:` is not what the other phases route on. `skills/plan/SKILL.md` is the
only consumer taught the new value; `skills/implement/SKILL.md`, `skills/review/SKILL.md` and
`skills/plan-grill/SKILL.md` all route on `PHASE`/`STATUS`. Run any of them directly on a
freshly-branched worktree — without going through `plan` first — and they are still told the work
is finished.

**Why it was deferred.** Out of the contract, which is scoped to the `TASK:` line and the plan
phase. Deriving `PHASE` from the new value changes how `implement`, `review` and `ship` route,
which is a behavioural change to four skills and wants its own plan and its own critique. It is
also partly self-limiting: the drivers reach `plan` first, `plan` supersedes the file, and from
that point the snapshot is correct.

**What was already established.** The `PHASE` derivation is a single `case "$STATUS"` in
`lib/detect_stage.sh`; `TASK` is not consulted anywhere in it, and this change deliberately did not
start consulting it. A grep for `TASK:` across `skills/`, `docs/`, `hooks/`, `lib/` and `tests/`
found four routers in total: `plan` (updated), `handover` (updated to accept both values),
`auto-unattended`'s never-clobber rule (updated), and `review`, which branches only on
`TASK:absent` and therefore treats `inherited` exactly as it treats `present` — correct today, and
checked rather than assumed.

**Next action.** Decide the one question first, because the code is trivial either way: should
`PHASE` report `plan` when `TASK:inherited`, or should `PHASE` keep reporting what `STATUS` says
and the *consumers* learn to check `TASK:` themselves? The first is one line in the `case` and
changes what four skills do; the second is four edits and leaves the detector honest. Write that
choice down before touching either.
### `plan.md` is inherited on exactly the same terms and gets no third value

**What it is.** `plan.md` is committed with every PR for the same reason `task.md` is, so a
freshly branched worktree inherits both. Only `task.md` gained a third value. `PLAN:present` is
therefore true on a clean branch in the same misleading way `TASK:present` was, and
`skills/plan-grill/SKILL.md` routes `PLAN:present` to "continue, whatever `STATUS` says" — so
`/gantry:plan-grill` run before `/gantry:plan` on a clean branch will dispatch a critic against the
*previous* merged plan and return findings about work that already shipped.

**Why it was deferred.** The contract covers `task.md`. It is also not a straight copy of the
`task.md` rule: `plan.md` has no frontmatter and no `status:`, so the terminal-status condition —
which is half of what makes the `task.md` detection safe — has no equivalent. A `plan.md`
byte-identical to the merge-base copy is weaker evidence on its own, and deciding what would make
it strong enough is a design question, not an implementation one.

**What was already established.** `open_questions_forks()` and the new `task_is_inherited()` are
both self-contained functions that share no code with `frontmatter_status()`, which is the
constraint any addition here has to respect — `scripts/verify.sh` diffs that one function
byte-for-byte against `hooks/readiness-gate.sh`'s copy, so it must not be touched. A `plan.md`
check would follow the same shape and could reuse `inherited_base_rev()` as-is.

**Next action.** Settle whether byte-identity alone is sufficient evidence for `plan.md` given
there is no status to corroborate it. If it is, `PLAN:inherited` is a five-line function reusing
`inherited_base_rev()`; if it is not, the honest answer may be to leave `plan.md` alone and instead
have `grill` refuse when `TASK:inherited`, which is one bullet in `skills/plan-grill/SKILL.md` and needs
no new detection at all.
### The renamed `HOOK:` value has not been checked against a live hook

**What it is.** `HOOK:` now reports `conditions-met`/`conditions-unmet`, and the whole point of the
rename is that the detector *cannot* see whether the hook is registered. Nothing in this change
verifies that the renamed value lines up with what a registered hook actually does on a real run,
because nothing in this repository can: the fixtures drive `hooks/readiness-gate.sh` directly
rather than through the harness that registers it.

**Why it was deferred.** It needs a human watching a real session — it is unautomatable here by
construction, and it is recorded in `task.md`'s *How to verify* as a human-only check rather than
as an acceptance criterion for that reason.

**What was already established.** The firing conditions themselves are pinned by
`tests/cases/hook_inert_unless_armed.sh`, `hook_arms_and_blocks.sh` and `hook_worktree_root.sh`,
all of which assert on the hook's exit code and on whether the gate ran — never on the detector's
string, which is why none of them needed changing. So the *conditions* are tested; what is untested
is that the detector's report of them matches the hook's behaviour in a live run.

**Next action.** On the next real unattended run in a repo with `.claude/gates.sh`, at the moment
`task.md` says `status: implementing`, run `bash lib/detect_stage.sh` and then check
`.claude/artifacts/gate-hook.log` for an entry from the same stop. Matching `conditions-met` with a
log line closes it; `conditions-met` with no log line means the hook is not registered in that
environment, which is exactly the gap the rename exists to make visible.

## Lane C — `fix/verify-sees-untracked-files`
### `scripts/secret-scan.sh` scans tracked files only, and the reasoning behind that is now partly stale

**What it is.** `secret-scan.sh` enumerates with a bare `git ls-files`, and its header justifies
this: "untracked scratch is not being published." For ordinary scratch that is right. It is not
right for the files a gantry run writes — `task.md`, `plan.md`, `handover.md` are untracked when the
gate runs and committed by `ship` minutes later, so a secret pasted into one of them is invisible to
the local publish gate and is caught only by CI, after the push. That is the same green-local
/red-CI shape this change closed in `verify.sh`.

**Why it was deferred.** The task's contract excludes it, and deliberately: unlike `verify.sh`'s
enumeration, this one is a written, reasoned decision rather than an oversight, and reversing it is
a judgement about the publish gate's scope rather than a bug fix.

**What was already established.** The risk of simply copying this change across is concrete and was
the reason for not doing it blind. `secret-scan.sh`'s S2 patterns include `/Users/[a-z0-9]` and
personal identifiers; the moment untracked files are in scope, any scratch file holding an absolute
home-directory path trips the publish gate. `verify.sh` could absorb its newly-visible files because
its checks are narrow; `secret-scan.sh`'s are deliberately broad, and broad patterns over
unreviewed scratch is a false-positive engine.

**Next action.** Decide the scope question first, because it determines whether there is any work at
all: should the publish gate cover what *this run is about to publish* (`task.md`, `plan.md`,
`handover.md`) rather than everything untracked? If yes, the narrow change is to add those three
paths explicitly to `files()` in `scripts/secret-scan.sh` rather than switching it to
`--others --exclude-standard`, which keeps the header's reasoning intact and closes the actual hole.

## Lane F — `fix/agent-env-claims-cite-source`
### An agreement check that all three agents still carry the rule

**What it is.** `scripts/verify.sh` has no assertion that the sourcing rule is present in
`agents/gantry-explorer.md`, `agents/gantry-critic.md` and `agents/gantry-reviewer.md`. The rule is
phrased differently in each file on purpose — the explorer and critic cite *searches* because they
have only `Read`, `Grep` and `Glob`; the reviewer cites *commands* because it also has `Bash` — so
there is no single string to grep for, and a later editor trimming one agent can drop the
negative-scope clause or the sample clause from one of the three without anything noticing.

This is not the impossible check. Detecting whether a claim an agent *made* was sourced cannot be
done from outside the model, and this task rules it out for that reason. Detecting whether the
rule is still *present in a file* is mechanical, and this repo already does exactly that kind of
check twice: the `frontmatter_status()` drift check between `hooks/readiness-gate.sh` and
`lib/detect_stage.sh`, and the parity check between `examples/task.md` and the plan template.

**Why it was deferred.** `task.md`'s *Out of scope* excludes any enforcement mechanism, lint, or
new script. That exclusion came from the ticket, not from this plan, so it is not this change's to
overturn. The finding came from the grill and is recorded rather than dropped.

**What was already established.** The three clauses are present in all three files today, verified
by reading each file and by matching the phrases across line breaks — note that a plain
line-oriented `grep` gives a false negative here, because the sentences wrap. The naive check
(`grep -c "names the command that established it"`) returns 0 for `agents/gantry-critic.md` purely
because the phrase spans a newline; `tr '\n' ' ' < agents/gantry-critic.md | grep -o ...` finds it.
A check written the obvious way would false-green in the opposite direction — it would report the
rule missing when it is there — so whoever writes this needs to normalise whitespace first. That
is the dead end worth not repeating.

**Next action.** Add a `head2 "the sourcing rule is present in every agent"` block to
`scripts/verify.sh` that, for each file in `agents/*.md`, squeezes newlines to spaces and asserts
the presence of three things: a sourcing sentence, the negative-claim scope clause, and the sample
clause. Decide deliberately whether to assert the "nothing enforces this" caveat too — it is the
clause most likely to be trimmed as boilerplate, and the one whose loss matters most.
### `docs/ARCHITECTURE.md` says "Four agents ship" above a table of three

**What it is.** The `## The agent roster` section opens "Four agents ship, and **every one of them
is read-only**", and the table beneath it lists three: `gantry-explorer`, `gantry-critic`,
`gantry-reviewer`. `agents/` contains exactly those three files.

**Why it was deferred.** Pre-existing and unrelated to this change — it is residue from the
`gantry-verifier` deletion described later in the same document, which the 0.3.0 notes record.
This branch does not touch `docs/ARCHITECTURE.md`, and widening a prose change to sweep up an
unrelated prose defect is how a focused diff stops being reviewable.

**What was already established.** The count is the only thing wrong; the table itself is accurate,
and the paragraphs around it that explain why there is no planner, implementer or verifier agent
are all consistent with three.

**Next action.** Change "Four agents ship" to "Three agents ship" in `docs/ARCHITECTURE.md`. It is
a one-word fix and needs no plan; it wants a separate commit only so it is not buried in this one.
### The rule does not reach a repo that overrides an agent

**What it is.** Role resolution is per role, repo first: a target repo defining
`.claude/agents/critic.md` gets that file dispatched instead of `gantry-critic`, contract and all.
Such a repo receives none of the sourcing rule, and nothing tells the driver the guarantee lapsed
— the run reports a critic ran, which is true and no longer means what it meant.

**Why it was deferred.** Closing it means either a phase skill checking the resolved agent for the
rule (an enforcement mechanism, excluded by the contract, and it would also be the same
false-greenable string match as above) or documenting the requirement for repo authors, which is a
docs decision about a public extension point rather than part of this fix.

**What was already established.** The gap is now written down where a reader auditing the roster's
guarantees will meet it — `docs/METHOD.md`, in the passage this change added after the delegation
argument. So it is disclosed; it is not addressed.

**Next action.** Decide whether an overriding repo is expected to carry gantry's agent contract.
If yes, say so in `docs/ARCHITECTURE.md` beside the "resolution is per role, repo first"
paragraph, and give repo authors the three clauses to paste. If no, say that too — an override is
then explicitly a repo taking full responsibility for its own agent's return contract.

## Lane D — `feat/gate-coverage-report`

Lane D wrote no `handover.md`. Its one deferral was named in its task contract rather than
discovered, and it is recorded here so the release does not read as though the ticket were closed.

### Coverage is reported and never refused, and the refusal was the third of the ticket's three fixes

**What it is.** `GANTRY-8` asked for three things. Two shipped: `run_gates.sh` emits the roots its
checks ran in, and `implement` compares them against the diff and names a green-but-uncovered run.
The third — refusing to push under `--strict` when a green gate covered none of the changed paths —
is explicitly excluded from the task's scope and is not in this release.

**Why it was deferred.** A refusal needs an override design first, and the exclusion was a decision
made when the lane was cut rather than a discovery made inside it. Without an override, the refusal
fires on every documentation-only change, and a gate that must be argued past on ordinary work is a
gate people learn to pass with a flag.

**What was already established.** The verdict this would refuse on is a **heuristic**, and the
release says so in every place it is emitted: a root is the directory a check ran in, never the set
of files it read, and it errs in both directions. Turning a number with that property into an exit
code is a larger decision than adding the number was. Separately, gantry cannot exercise the case on
itself — this repo gates through a repo-owned `.claude/gates.sh` whose roots cannot be attributed,
so its own runs report `undeclared`.

**Next action.** Decide the override before the refusal: what a legitimately uncovered change says
to get through, where it says it (`task.md` frontmatter is the obvious candidate, since it is
already the contract), and whether an unattended run may set it for itself — which is the question
that decides whether the refusal means anything at all.

## `refactor/rename-grill-to-plan-grill`
### A corruption of the phase/status vocabulary is silent in three places at once

**What it is.** The rename of `/gantry:grill` to `/gantry:plan-grill` had to leave `PHASE=grill`,
`status: grilled` and the journal's `--phase grill` untouched, because those tokens are written
into every `task.md` already on disk and every journal line already recorded. Establishing that the
boundary held turned out to be harder than expected, for a reason that outlives this task: **nothing
in the repo would have gone red if it had not.**

Three independent gaps line up:

- `lib/journal_append.sh` validates `--event`, and validates `--result` for `phase` and `gate`
  events, but `--phase` is only required to be *present*. Its value is passed through to `jq` as
  free text, so `--phase plan-grill` is written to `journal.jsonl` silently rather than refused.
- `lib/detect_stage.sh`'s status `case` has a catch-all arm that routes an unrecognised status to
  `PHASE=implement` — which is exactly what `grilled` routes to. A mistyped or half-renamed status
  is therefore indistinguishable from a correct one at the detector's output.
- `hooks/readiness-gate.sh` arms on exactly `implementing` and is inert for everything else, so
  `tests/cases/hook_inert_unless_armed.sh` — which loops the whole status vocabulary asserting only
  `rc 0` — passes for a corrupted value just as happily as for a real one.

The consequence is that the status vocabulary is a contract with no enforcement anywhere: it can be
mistyped in a skill body, in a test, or on a command line, and the suite stays green.

**Why it was deferred.** The rename's contract is a command string. Closing any of these is a
behavioural change to a script, and the second one is not small: making `detect_stage.sh` fail
closed on an unknown status changes what `implement`, `review` and `ship` do when they meet one,
which is four skills' routing and wants its own plan and its own critique.

**What was already established.** The three locations above were each read directly and confirmed,
not inferred — the critic checked `journal_append.sh` for a phase enum and found none, and the
catch-all arm and the hook's firing condition were both read in place. The rename branch worked
around the gap with a per-change guard rather than a repo-level one: a **census** that counts every
state token across the whole tree on `master` and on the working tree and requires the two tallies
to match exactly. That guard is recorded in that branch's `task.md` and `plan.md`. It works, and it
is worth knowing why it is not the fix: it is written per change, it has to enumerate the tokens by
hand, and it caught nothing here only because the sweep was already correct. It also failed on its
own first outing by forgetting to exclude `CHANGELOG.md`, which is the kind of mistake a check
living in the repo would not repeat.

Note also that these three gaps are not equally severe. The journal one writes bad data that
nothing downstream can detect. The detector one silently misroutes. The hook one is only a missing
assertion in a test — the hook's own behaviour is correct.

**Next action.** Add a `--phase` enum to `lib/journal_append.sh`, matching the shape of the
existing `--event` enumeration, with `plan | grill | implement | review` as the values. It is
self-contained, it cannot affect routing, and it is the one of the three that is currently writing
unverifiable data into an append-only file the project treats as evidence. Do that first and
separately; then decide the `detect_stage.sh` catch-all on its own terms, because that one is a
routing change to four skills rather than a validation fix.

## `integration/v0.4.1-batch`

Five findings from `/code-review high` over the merged tree. All five are internal to #13's
redesign of `ship` and `review` — none was introduced by the merge, and none can be fixed without
making a design decision that belongs to whoever owns that change. Three other findings from the
same run *were* fixed here, because each was drift that exists only in the merged tree: the
detector's `NEXT` (434f7a8), the drivers' phase-skill list (7cdcaf2), and the deleted no-gate
disclosure (c4cc133).

### `review` writes `status: reviewed` on a path that can move the task backwards

**What it is.** `skills/review/SKILL.md` step 7 sets `status: reviewed` **always**, and #13 gave it
a new caller: `ship --review` / `--review-fix`. Both drivers set `status: shipped` *before*
invoking ship (`skills/auto/SKILL.md`, `skills/auto-unattended/SKILL.md`), and ship never writes
the field itself. So a human who types `/gantry:ship --review` to resume a run the drivers left at
`shipped` gets the status rewritten backwards to `reviewed`; ship's own instruction to commit
review's edits on their own then commits that regression, and `detect_stage.sh` reads the pushed
branch as still needing `/gantry:ship`.

**Why it was deferred.** The unconditional write is deliberate and well argued in the file — gating
it on `--fix` would strand a read-only review outside the state machine — so the fix is not to make
it conditional. It is to decide whether `reviewed` may ever overwrite a *later* status, which is a
statement about the status ordering that no file currently owns.

**Next action.** Decide whether `skills/review/SKILL.md` step 7 should be "set `reviewed` unless
the current status is already past it", and if so, where the ordering lives — most likely beside
the status map in `lib/detect_stage.sh`, since that is the only place the sequence is written down.

### `review`'s "the tree is usually uncommitted at this point" is false on the new ship path

**What it is.** `skills/review/SKILL.md` step 1 states the tree is usually uncommitted because
`gantry:ship` has not run yet. Under `--review`/`--review-fix` ship *has* run: its stage 2 commits
before the review section is reached. That stale premise combines badly with the rule directly
above it — `STATUS:planned` or `grilled` plus a clean tree means "nothing to review; say so and
name `NEXT`". A `/gantry:ship --review-fix` on a branch whose `task.md` is stale can therefore
report "nothing to review" against a diff that was just committed, and ship reports a review it
never got.

**Why it was deferred.** Rewriting step 1's entry conditions means deciding what review reads when
the tree is clean — the committed diff against the base, presumably — and that is a new behaviour,
not a correction.

**Next action.** Give step 1 a third case for "invoked by ship, tree clean, `AHEAD` non-zero":
review the committed range rather than the working tree.

### The drivers' `allowed-tools` cannot satisfy review's new verification step

**What it is.** #13 made verification its own step in `skills/review/SKILL.md`, and it requires
checking each finding against the file it names. Neither `skills/auto/SKILL.md` nor
`skills/auto-unattended/SKILL.md` lists `Grep` or `Glob` in `allowed-tools`, and both invoke
`/gantry:review --fix`. On this repo's own account of the mechanism — stated in
`skills/ship/SKILL.md`, that frontmatter *restricts* rather than grants — the verification step
cannot search the repo when review runs under a driver.

**Why it was deferred.** #13 widened ship's `allowed-tools` for exactly this reasoning, so the
precedent says widen the drivers too. But the claim rests on the repo's description of the harness
rather than on anything tested here, and a permissions change to the two unattended entry points is
not something to fold into a merge commit.

**Next action.** Confirm the restrict-not-grant behaviour against the harness, then add `Grep,
Glob` to both drivers in one change with ship's rationale quoted.

### `--no-pr` with a review flag has two defensible readings

**What it is.** `skills/ship/SKILL.md` specifies `--no-pr` as "commit → push only", and the review
section's entry-point table never mentions it. The old text said outright that `--no-pr` skipped
the review. So `/gantry:ship --no-pr --review-fix` reads either as "no review" or as "review, then
push" — and the section's own rule that an explicitly requested review must never silently not
happen argues for the second.

**Next action.** One row in the entry-point table, whichever way it is decided.

### `review --tier` refuses `low`, which `/code-review` supports

**What it is.** The allow-list is `medium | high | xhigh | max`, and anything outside it is a hard
stop. `/code-review` documents `low` as a valid level. `/gantry:ship --review=low` — forwarded
unvalidated by design — therefore stops the run after stage 2 has already committed, because the
caller asked for the cheapest review available.

**Next action.** Either add `low` to the list, or refuse it by name with a reason, the way `ultra`
is refused. The silent-downgrade argument for keeping the list strict is unaffected either way.
