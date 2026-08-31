# Handover — fix/agent-env-claims-cite-source

Deferred from *Make sub-agents source their environment claims, and stop them narrowing the
caller's evidence*. The change itself is complete and the gate is green; these are findings it did
not absorb.

## An agreement check that all three agents still carry the rule

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

## `docs/ARCHITECTURE.md` says "Four agents ship" above a table of three

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

## The rule does not reach a repo that overrides an agent

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

---

# Handover — fix/verify-sees-untracked-files

Deferred from *Make verify.sh enumerate untracked files, so the gate sees what the run just wrote*.
The change itself is complete and the gate is green; these are findings it did not absorb.

## The explorer still emits line-number citations, and now the gate catches them locally

**What it is.** `agents/gantry-explorer.md` instructs the explorer to return `path:line`
references, and `skills/plan/SKILL.md` step 3 tells the author to paste that summary into
`task.md`'s *Affected areas*. `task.md` is untracked when `implement` runs the gate, and this change
puts untracked markdown inside the citation check. So on any gantry-on-gantry run where `plan`
dispatches the explorer and the explorer cites a markdown file, `scripts/verify.sh` now goes red —
and because `.claude/gates.sh` execs `verify.sh`, the readiness hook blocks the Stop until the
author strips the numbers by hand.

**Why it was deferred.** It is a change to the *producer*, in two files this task's contract never
names — the task covers `scripts/verify.sh`'s enumeration and nothing about what the checks look
for. It also would not take effect for the next lane: a skill or agent edited in a worktree is not
the copy the running plugin loads, so the fix only lands on release.

**What was already established.** This is not a regression, and that matters for how urgently it is
treated. Before this change the same `task.md` passed locally and failed **CI** — a red pull
request, which is how the previous lane discovered it and stripped the citations by hand. The check
now fires minutes earlier, at the cheapest possible moment, which is the entire point of the ticket.
The rule itself is not in question either: line-number citations rot on the first edit, which is why
`verify.sh` has forbidden them since before this change. What is wrong is that one part of the
pipeline is documented to produce exactly what another part is documented to reject. The unattended
driver can recover on its own — the remedy is editing `task.md`, which it can do inside its two fix
attempts — so this degrades a run rather than deadlocking it.

**Next action.** In `agents/gantry-explorer.md`, change the instruction that citations carry a line
number to say that a markdown path must be cited by path alone. Non-markdown paths can keep their
line numbers: `verify.sh`'s check is `\.md:[0-9]+`, so `lib/run_gates.sh:40` was never at issue.
Then add one sentence to `skills/plan/SKILL.md` step 3 saying to strip trailing line numbers from
markdown paths when pasting into *Affected areas*, because the explorer is not the only thing whose
output lands there.

## `verify.sh` runs `rm` and `cp` against absolute paths when `mktemp -d` fails

**What it is.** In `scripts/verify.sh`'s `detect_stage.sh` fixture block, `fixdir="$(mktemp -d)"` is
unguarded. When `mktemp` fails, `$fixdir` is the empty string and the block goes on to run
`rm -f "$fixdir/task.md"` and `cp … "$fixdir/task.md"` — that is, against `/task.md` — and
`git init -q .` runs in the repository itself rather than in a fixture.

**Why it was deferred.** Pre-existing, unrelated to the enumeration change, and revealed by this
work only incidentally. Fixing a latent bug in a file because the diff happens to touch that file is
how a reviewable change stops being one.

**What was already established.** Observed directly, not theorised: running the gate inside this
session's sandbox made `mktemp -d` fail with `Operation not permitted`, and the transcript then
shows `error: could not lock config file …/.git/config` from the stray `git init`, followed by
around twenty `/task.md: Operation not permitted` lines and roughly a dozen spurious `FAIL`
assertions. Nothing was damaged, because the same sandbox denied the writes — on a machine where
those paths are writable it would not have been so tidy. A second lane on this repo independently
hit the same thing and confirmed the rule: run `verify.sh` unsandboxed, and do not change it to
accommodate the sandbox.

**Next action.** Add `[ -n "$fixdir" ] || { bad "could not create the fixture repo"; exit 2; }`
immediately after the `mktemp -d`, before the `trap` that would otherwise `rm -rf ""`.

## `scripts/secret-scan.sh` scans tracked files only, and the reasoning behind that is now partly stale

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

---

# Handover — fix/detector-inherited-task-and-plan-order

Deferred from *Report an inherited task as inherited, stop calling the hook armed, and write Out of
scope after the code study*. The change itself is complete and the gate is green; these are
findings it did not absorb.

## `PHASE:` and `NEXT:` still read an inherited task as already shipped

**What it is.** `lib/detect_stage.sh` now reports `TASK:inherited` for the previous, merged
contract that arrives in every freshly branched worktree — but that same `task.md` carries
`status: shipped`, and `PHASE` is derived from `STATUS` alone. So the detector emits
`TASK:inherited` and `PHASE:done NEXT:none — already shipped` in one snapshot, which is
self-contradicting on its face.

It matters because `TASK:` is not what the other phases route on. `skills/plan/SKILL.md` is the
only consumer taught the new value; `skills/implement/SKILL.md`, `skills/review/SKILL.md` and
`skills/grill/SKILL.md` all route on `PHASE`/`STATUS`. Run any of them directly on a
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

## `plan.md` is inherited on exactly the same terms and gets no third value

**What it is.** `plan.md` is committed with every PR for the same reason `task.md` is, so a
freshly branched worktree inherits both. Only `task.md` gained a third value. `PLAN:present` is
therefore true on a clean branch in the same misleading way `TASK:present` was, and
`skills/grill/SKILL.md` routes `PLAN:present` to "continue, whatever `STATUS` says" — so
`/gantry:grill` run before `/gantry:plan` on a clean branch will dispatch a critic against the
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
have `grill` refuse when `TASK:inherited`, which is one bullet in `skills/grill/SKILL.md` and needs
no new detection at all.

## The renamed `HOOK:` value has not been checked against a live hook

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

---

# Handover — feat/ship-discloses-what-was-not-proven

Deferred from *Make the draft PR body disclose what the run did not prove*. The change itself is
complete and the gate is green; this is the one finding review turned up that the change did not
absorb.

## `scripts/verify.sh`'s inline fixture suite passes for the wrong reason when `mktemp` fails

**What it is.** In `scripts/verify.sh`, the *"detect_stage.sh reads Open questions correctly"*
section builds its fixtures with an unguarded `fixdir="$(mktemp -d)"`. When `mktemp` cannot create
a directory — which happens on this machine under the Bash sandbox, where it fails with
*Operation not permitted* — `fixdir` becomes the empty string and is never checked. Everything
downstream then misbehaves in a specific and misleading way:

- `printf ... > "$fixdir/task.md"` writes to `/task.md`, which fails with a permission error per
  fixture rather than aborting the section;
- `forks_is` runs `(cd "$fixdir" && bash "$LIB")`, and `cd ""` **succeeds** in bash as a no-op — so
  the detector runs against **the real repository**, reading the worktree's own `task.md` instead
  of the fixture that was never written.

The result is not a clean failure. Roughly twenty assertions fail for a reason unrelated to any
change, and — the part that matters — every assertion whose expected value happens to match the
worktree's real `task.md` **passes for the wrong reason**. With this branch's `task.md` reporting
`FORKS:none`, all six `forks_is none` cases pass while testing nothing at all.

`tests/lib.sh` is not affected: it uses `mktemp -d "${TMPDIR:-/tmp}/gantry-test.XXXXXX"`, which
succeeds under the sandbox, and it resolves the result with `pwd -P`.

**Why it was deferred.** It is a pre-existing bug in code this change does not touch —
`scripts/verify.sh`'s fixture block predates this branch, and this task's *Out of scope* is the
disclosure work in ship, the detector and the journal. Fixing a test harness in the same diff that
adds a detector line would widen a focused change into one covering two unrelated subsystems. It is
also not urgent in CI, where `mktemp` is unrestricted and the section behaves correctly.

**What was already established.** Confirmed by direct observation on this branch, not inferred:
`bash scripts/verify.sh` under the sandbox reports `verify: FAIL` with
`mktemp: mkdtemp failed on ...: Operation not permitted` followed by
`error: could not lock config file .../.git/config` (the fixture's `git init` running against the
real repo) and `scripts/verify.sh: line NNN: /task.md: Operation not permitted` per fixture. The
same command run unsandboxed reports `verify: PASS`. The gate results recorded for this task are
all from unsandboxed runs for that reason. `/code-review` independently reached the same diagnosis
from reading the code.

Not established: whether any CI runner has ever hit this. Nothing suggests it has.

**Next action.** In `scripts/verify.sh`, guard the fixture directory the way the section's own
`bad "could not create the fixture repo"` branch already intends to:

```bash
fixdir="$(mktemp -d)" || { bad "could not create a fixture directory"; fixdir=""; }
[ -n "$fixdir" ] && [ -d "$fixdir" ] || { bad "fixture directory unavailable — section skipped"; }
```

and skip the section rather than run it against an empty path. The honest check on the fix is that
`TMPDIR=/nonexistent bash scripts/verify.sh` reports the section as skipped-and-failed rather than
printing `ok` lines. The same guard belongs on the `cd` inside `forks_is`, since `cd ""` silently
succeeding is what turns a broken fixture into a false green.
