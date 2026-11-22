---
name: review
description: Get an independent review of the diff, verify every finding against the repo, then triage what survives against the task contract — handing what's out of scope to /gantry:handover rather than quietly widening the change. Read-only unless you pass --fix, which applies the findings triage keeps. Pass --tier medium|high|xhigh|max to set the depth (default high). Use when the user types "/gantry:review", or asks to review the diff, check the changes, or get a second opinion before shipping.
argument-hint: [--tier <medium|high|xhigh|max>] [--fix] [--headless]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion, SendMessage
---

# gantry:review

Review the change, then do something about it. The reviewing half is worth little without the
triage half: a list of findings nobody acted on is not a review, it is a receipt.

**Read-only by default.** With no `--fix`, this skill makes **no change to the code under review**.
It still writes gantry's own artifacts — `task.md`'s status, always; `review.md`, the findings that
are in scope to fix, always; and `handover.md` when something is deferred — because those are the
chain's bookkeeping rather than the change. `--fix` is what licenses it to edit the code.

**`--tier <medium|high|xhigh|max>`**, default `high`. The depth of the `/code-review` run in step 2.
See that step for what the values mean and which are refused.

**`--headless`**: this run is a child session nobody is watching — the drivers launch it through
`lib/run_phase_headless.sh`, and `gantry:ship --review` does too. The one thing it changes is
step 4: a finding whose triage is honestly ambiguous is **deferred** rather than asked about,
whatever `mode:` says and whether or not `task.md` names a `lead:`. A print-mode child exits when it
ends its turn, so it cannot wait for an answer; a deferred finding is written down and recoverable.

The same rule governs step 2. `/code-review` runs its finder agents in the background and their
completion notices do reach a print-mode child — but **nothing else of it runs in the background**:
there is no forked verification session, and no notice is coming after the last finder has
reported. The dedup and verification `/code-review` describes are yours to do, in this turn, as
soon as `ListAgents` shows no live finder. Twice in the review A/B a headless child wrote "I'll wait
for the verification notification", ended its turn, and the session was over with nothing on disk.
So: end a turn only while `ListAgents` lists an agent you are waiting on; never to wait for anything
else, and never with `ScheduleWakeup`, which does not fire in print mode.

**A headless child leaves the worktree as it was found.** Your finder sub-agents share the
worktree with you: a file they create, delete or modify while they run is *their* side effect, not
the lane's. Note `git status --short` at the start of step 1; only that and the diff are
pre-existing. Never report or escalate a change after that which traces to your own agents. And
write nothing but the chain's artifacts (plus, under `--fix`, the fixes `review.md` lists): use
the harness's scratchpad directory for a throwaway script if one is provided, otherwise create no
file at all. Remove only a file you created yourself; touch nothing else.

**`--fix` is stage-aware.** When `review.md` already lists findings from a review that finished,
`--fix` **applies them** and does not review again — see step 1. That split is what lets a driver
run the review in one child session and the fix in another.

## Steps

### 1. Detect the stage and get the diff

**Calling gantry's scripts in a headless child.** Under `--headless` the launcher hands you the
absolute path to `lib/` in the prompt, and the tool boundary matches the **literal text** of a Bash
command. So call a script as the whole command and nothing else — `bash /abs/path/lib/x.sh` — with
no `cd` in front of it, no `VAR=…` assignment in front of it, and the path written out rather than
routed through `$GANTRY`. A compound command is denied however correct the path inside it resolves
to, and the denial is not fatal, so you will carry on half-blind unless you notice. If a script is
denied, **say which one in your report and leave its output out** — never substitute a value the
script was supposed to compute. A `review.md` whose `diff:` line holds anything but
`diff_fingerprint.sh`'s token is one `--fix` will refuse as stale.

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

- `PHASE:not-a-repo` → stop.
- `STATUS:implementing` → **stop, in every mode.** The implementation has not finished: the gate
  has not gone green on it, and reviewing a tree `implement` has not proved is reviewing the wrong
  thing. Name `/gantry:implement`.
- `TASK:absent` → warn: with no contract there is nothing to check the change *against*, so the
  review is against general quality only. Continue; say so in the report.
- `TASK:inherited` → **treat it as `absent`, not as `present`.** The `task.md` on disk is the
  previous, merged task's contract — a freshly branched worktree is born holding it — so its
  acceptance criteria and *Out of scope* describe a different change. Reviewing this diff against
  them triages findings by the wrong boundary. Warn as above and say which it was.
- `STATUS:planned` / `grilled` → nothing has been implemented yet. If the tree is clean there is
  nothing to review — say so and name `NEXT`. If it is dirty, someone worked by hand; review that,
  and say that is what happened.

**Then read `REVIEW:`.** It is what decides what `--fix` means on this run:

- `--fix` + `REVIEW:pending` + `STATUS:reviewed` → **apply mode.** A review already ran, finished,
  and recorded what is in scope to fix. Skip steps 2–4 and 6 and go to step 5, which starts by
  checking that `review.md` describes *this* diff.
- `--fix` + `REVIEW:pending` + any other status → **stop.** A findings file without a `reviewed`
  status means the review that wrote it did not finish (it died after writing the file and before
  writing the status). Name `/gantry:review` so it runs again from the start.
- `--fix` + `REVIEW:applied` or `REVIEW:clean` → nothing is pending. Say so — the file is either
  already applied or records that there was nothing to apply — and name `/gantry:ship`. Stop.
- `--fix` + `REVIEW:absent` → the ordinary path: review, then fix, in this run.
- no `--fix`, any `REVIEW:` value → review. An existing `review.md` is a previous review's and is
  **overwritten** in step 4b; this run supersedes it.

Then get the diff. **The tree is usually uncommitted at this point** — `gantry:ship` commits, and
it has not run yet — so a three-dot range against the base is empty and will make an unreviewed
change look clean:

```bash
git diff <BASE>            # committed + working-tree changes vs the base
git status --short         # untracked files the diff above cannot show
```

`<BASE>` is the branch this one will merge into, resolved the way `gantry:ship` resolves it:
`develop` when it exists, else the branch `origin/HEAD` points at, else `main` or `master` —
preferring the `origin/` ref whenever one exists. Say which it was; `review.md` records it.

Read the untracked files too. A new file nobody reviewed is the easiest place for a defect to hide.

### 2a. Make the probe clone

A **probe** is any command that executes code or git experiments to check a claim — the repo's tests,
a script, a build, a `git` command that writes. Reviewers sometimes run them, and in the real
worktree a command that slips past a guard can change the lane's files and its shared `.git`. So
every probe runs in a **throwaway clone** instead, and nothing else about reading changes: reviewers
still read files, `git diff`, `git status` and `git log` in the real worktree.

Make it once, before the first dispatch, with the `<BASE>` step 1 resolved (and, in a headless
child, as the whole command, as step 1 says):

```bash
bash "$GANTRY/lib/probe_clone.sh" create --base <BASE>
```

- Exit `0` prints `PROBE_DIR:<path>`. The clone is made with `git clone --local --no-hardlinks`
  (never `--shared`), carries the reviewed HEAD plus the uncommitted and untracked changes, has no
  remote, and resolves `<BASE>` to the same commit. Give that path to **every sub-agent** you
  dispatch in 2 and 2b, tell it that all its probes run there — with the clone as the working
  directory (`cd <clone> && …` or `git -C <clone> …`) — and nowhere else, that the clone is
  shared with the other reviewers (so nobody moves a HEAD or cleans it), and that it holds no
  gitignored artefacts, so a build or test that fails for want of dependencies is an environment fact,
  not a finding.
- **Any other outcome means no clone**: exit `3` (`PROBE:unavailable <reason>`), exit `2` (a usage
  error — an empty or unknown argument, or not inside a repo), any other non-zero exit, output with
  no `PROBE_DIR:` line, or the command denied. **Record reduced
  coverage** — a `Probe coverage: reduced coverage — <reason>` line in `review.md`'s header and in
  the report — and tell every sub-agent to run **no probe at all** and to read only. **Never fall back
  to probing in the real worktree**, whatever the reason and however much a probe would help.
- A reviewer that reports a probe it could not run in the clone (a compound command a headless
  boundary denied, for instance) is also reduced coverage, written the same way.

The scripts this skill and the chain run themselves — `detect_stage.sh`, `risk_floor.sh`,
`diff_fingerprint.sh`, `review_fresh.sh`, step 1's `git diff` / `git status`, and step 5's gate on
the fixed tree — are not probes and run in the real worktree. Apply mode (`--fix` with
`REVIEW:pending`) skips steps 2–4 and makes no clone.

**Source 1 is not covered.** `/code-review` starts its own finders from a bare command, and this
skill has no brief to hand them a clone path through. Say so in the report whenever source 1 ran:
the clone covers source 2, the lens reviewers and `gantry-reviewer`, and says nothing about a
finder `/code-review` starts.

### 2. Get an independent review

Three **sources**, in order of independence. **Say which one ran** — they are not equivalent, and
the report must not imply more independence than the run had. (These are sources, not "tiers":
`--tier` is the effort level passed to source 1, and conflating the two makes the report ambiguous
about the thing it exists to record.)

1. **`/code-review`** — purpose-built, and it already knows this harness. **Invoke it; do not
   survey for it first.** It ships with Claude Code, so present is the default assumption and an
   invocation that errors is the only evidence that it is absent. Falling through *because you did
   not check* is the failure this ordering exists to prevent: source 2 reads like a review in the
   report, so a silent downgrade costs the better reviewer and leaves no trace.

   Name the effort level explicitly — with none given it reuses whatever was typed last in the
   session, which makes two runs of this phase incomparable for a reason that has nothing to do
   with the diff:

   ```
   /code-review <tier>          # <tier> = --tier's value, default high
   ```

   **Validate `--tier` before dispatching**, and this skill is the only place that does — `gantry:ship`
   and the headless launcher forward a tier here unvalidated rather than keeping a second copy of
   the list that could drift out of step with this one.

   - `medium` · `high` · `xhigh` · `max` → pass it through.
   - `ultra` → **refuse by name.** It is billed and user-triggered, and `gantry:auto-unattended` has
     nobody present to authorise it. Say that is why, rather than reporting it as an invalid value.
   - anything else → **stop and name the valid values.** Dispatch nothing. Do not fall back to
     `high`: an errored invocation is exactly what step 2 reads as "`/code-review` is unavailable",
     so a typo'd tier would silently downgrade the whole run to source 2.

   Do **not** pass `--fix`. It applies every finding, and steps 3 and 4 below are the whole reason
   this skill decides which findings the change is allowed to absorb. This holds whether or not
   *this* skill was given `--fix` — that flag licenses the edits **this skill** makes after triage,
   never a blanket application upstream of it.
2. **A review sub-agent** (Agent tool): the repo's `.claude/agents/reviewer.md` if it defines one,
   otherwise `gantry-reviewer`. Give it the worktree path, the base branch, and `task.md`'s path —
   let it read the diff itself. Ask for correctness defects first, then reuse and simplification,
   each with a concrete failure or a concrete saving.
   Give it the probe clone path from step 2a (or the instruction to run no probe).
   Tell it that when a guard blocks a command it stops and reports, and never rebuilds, splits or
   encodes the command. A guard block it reports is not a finding about the diff and not an
   address-now item: see *Guard blocks* below.
3. **Self-review**, only if neither is available, and **disclose it**. You reviewing your own
   change is the weakest source by a wide margin; the value of saying so is that the reader can
   weigh it correctly.

**Sub-agents and the model.** When the prompt that launched you carries a line `Sub-agent model:
pass model: <alias>` (`lib/run_phase_headless.sh` writes it when `--model` is a bare alias —
`sonnet`, `opus`, `haiku` or `fable`), pass that alias as the `model` argument of every Agent
dispatch in this skill (source 2 and the lens reviewers in 2b), so a review pinned to a model runs
on it. No such line: pass no `model` and let the agent's own setting stand; never guess one, and
never read your environment for it. `/code-review`'s own finders cannot be given one here and follow
`CLAUDE_CODE_SUBAGENT_MODEL`, which the launcher exports, alone.

### 2b. Run the review lenses the diff fires

A **review lens** is a file the *target* repo keeps at `.claude/review-lenses/<name>.md`: a
frontmatter naming the paths that need a careful read before merge, each with a risk floor, and a
prompt body saying what to check there and the repo's threat model:

```
---
name: security
description: one line
floors:
  ".claude/": critical
  "bin/": medium
  "setup.sh": high
defer: never
---
<what this lens checks, and the repo's threat model>
```

A `floors` key ending in `/` is a directory prefix; any other key is an exact repo-root-relative
path. The keys are also the trigger: a lens fires when the diff touches any of them. Levels are
ordered `low < medium < high < critical`. A repo with no lenses fires none, and this step costs one
command.

Which lenses fire is **not your judgement** — it is arithmetic over git, done by a script, with the
same `<BASE>` step 1 resolved (the `origin/` ref when one exists):

```bash
bash "$GANTRY/lib/risk_floor.sh" <BASE>
```

It prints one block per lens that fired — `LENS:<name>`, `FLOOR:<level>`, `DEFER:never` when the
lens says so, one `FILE:<path> <level>` per matched file, `END` — then any `LENS_IN_DIFF:` lines
(below), and nothing at all when no lens fired and no lens file is in the diff. **Lens files are read from the base ref** (`git show <BASE>:.claude/review-lenses/…`), never
from the worktree, so a diff that adds or edits a lens does not get to judge itself with the new
text. The script reports that case as a `LENS_IN_DIFF:<path> <level>` line — the strictest level
any base lens assigns that path — or as `LENS_IN_DIFF:<path> critical no-base-lens` when no base lens
covers it (including a base with no lens at all). The lens file is guarded on its own, whether or
not any lens fired. Record each one as a line under `review.md`'s `## Risk` (there may be no
`## Lens:` section to put it in) — a plain line, not a bullet, after `Risk level:` (and after
`Lenses:` when present) and before `Blast radius:`, as the `## Risk` template in step 4b shows:
`Lens file in diff: <path> — <level>, judged by the base's lenses, not by itself`, or for
`no-base-lens`, `Lens file in diff: <path> — critical, no-base-lens: no lens at the base covers it,
so nothing judged it`. Never say a `no-base-lens` file was judged by the base's version.

**Exit `2`, or the command denied, is not "no lens fired".** It means a lens is malformed, the base
did not resolve, or the script could not run — and an unevaluated lens is exactly a guarded path
nobody read. Write it into `review.md`'s `## Risk` as `Lenses: could not be evaluated — <reason>`,
carry on with the rest of the review, and say so in the report. Ship discloses it under *Not proven
by this run*.

**For each lens that fired, dispatch one sub-agent with a fresh context** (Agent tool): the repo's
`.claude/agents/reviewer.md` if it defines one, otherwise `gantry-reviewer` — the same role source
2 uses, with the lens as its brief instead of a general one. Dispatch them in parallel. Give each:

- the lens body, which the script prints from the base ref:

  ```bash
  bash "$GANTRY/lib/risk_floor.sh" --body <name> <BASE>
  ```

- the worktree path, `<BASE>`, and `task.md`'s path — it reads the diff itself;
- the `FILE:` lines that fired the lens;
- the probe clone path from step 2a, or the instruction to run no probe.

Ask it for findings against the lens, each with the file, the line and the concrete failure, and
for **one "what to look at" note per matched file**: the specific lines and what a reader should
check in them. A file the lens matched but found nothing in still gets a note — "touched only the
comment block" tells the reader something.

Give each lens sub-agent the same guard rule as source 2: stop and report a blocked command, never
rebuild, split or encode it.

**Lenses run in addition to source 1, never instead of it.** `/code-review` (or the fallback) still
reviews the whole diff; a lens reads only its own paths, with its own threat model. Lens findings go
through step 3's verification exactly like any other.

### Guard blocks

A reviewer, from any source, may report that a guard blocked a command, or that it tried to get around
one. Treat it the same way whichever source it came from. This skill never retries the blocked command
itself, never rebuilds it, and never asks a sub-agent to try again by another route. A block is not a
finding about the diff and names no file in it, so it never goes under `## Address now`: that section
flips `REVIEW:pending` with nothing to fix. An attempt to get around a guard is a finding about the
review itself: step 3 does not drop it for naming no file, and it is kept out of `## Address now` but
always written down. Put every block and every attempt in the report, and add one `Guard blocks:` line
to `review.md`'s header, after `tallies:`, naming the command and the block message (or the attempt).
Leave the line out when nothing was blocked or attempted. If the reviewer reports that a workaround got
through, set `status: blocked` and hand over: a guard was defeated during this review.

### 3. Verify every finding before it counts as one

Steps 3, 4 and 6 are also the triage `gantry:qa` applies to a scenario that failed — it invokes
them by reference rather than carrying a copy, so a change here changes both phases.

**Check each finding against the file it names, before it is reported and before it is fixed.**
Reviewers, including good ones, report things that are not true — a defect in code the diff does
not contain, a call site that does not exist, a rule this repo does not hold.

This is a step rather than an aside because read-only mode makes it load-bearing. Without `--fix`
the report is the entire output of this phase, so an unverified finding is the whole of what the
caller receives, and it costs them more than it saves. The old placement — one clause telling you
to check findings "before acting" — only covered the case where something was going to be edited.

What does not survive is **dropped**, and counted in the tally rather than listed. A finding that
was checked and found untrue is not a finding; it is noise with a citation.

### 4. Triage what survived

Read `task.md`'s **Out of scope** section first — it is the boundary that makes this decision
something other than taste. Then sort each verified finding:

- **Address now** — a defect in the code this change introduced, or a small clear-cut cleanup
  inside the change's own footprint.
- **Defer** — real, but outside this task: a pre-existing bug the diff merely revealed, a
  refactor the finding would require, anything the contract excludes, anything large enough to
  need its own plan. **Never fix these.** Widening a change to absorb what review turned up is how
  a focused diff becomes an unreviewable one.
- **Drop** — pure style against a convention the repo does not hold. (Findings that were not true
  were already dropped in step 3; say how many fell out at each point, and do not list them all.)

The dividing line is scope, not difficulty. A one-line fix outside the contract still gets
deferred; a genuinely fiddly fix to code this change introduced still gets made.

**A lens that says `defer: never` (its block carries `DEFER:never`) takes the Defer bucket away.**
Its findings are never moved to `handover.md` — not by scope, not by `--headless`, not by an
ambiguous call. Each one is either **Address now** (it is in this change's footprint, so it gets
fixed) or an **open risk**: written under that lens's section in `review.md` as `- Open risk: …`,
which ship carries into the pull request and which raises the PR's risk level one step. An open
risk is the honest form of "not fixed here" for a guarded path — it stays in front of the reader
instead of in a file they will not open. When you ask about an ambiguous one (below), offer
Address now or open risk, never defer.

Where the call is honestly ambiguous, ask — **AskUserQuestion**, one round, with the findings
described in terms of what each costs. If `task.md`'s frontmatter names a `lead:`, put this
question to the lead instead, as a `fork`, following `$GANTRY/skills/auto/references/lead.md`. With
no human present, defer rather than expand: a deferred finding is written down and recoverable, an
unrequested refactor is neither.

**Under `--headless`, defer instead of asking — always**, whatever `mode:` says and even when a
`lead:` is named — **except a `defer: never` finding, which becomes an open risk instead** (above).
The child cannot wait for a reply. Count how many findings went that way; the
report says so, and the driver's PR body shows them from `handover.md`.

### 4b. Record the findings

**Always, on the review path** (not in apply mode). Write `review.md` at the worktree root — with
the Write tool, overwriting whatever is there, because a file left by an earlier review describes
a diff that has since moved. Keep it out of git first; the launcher has already asserted this for
a headless child, and a hand-typed run asserts it now:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md /qa.md
bash "$GANTRY/lib/diff_fingerprint.sh" <BASE>
```

The second command prints the one token that ties this file to this diff. The file:

```
# Review
branch: <branch>
base: <BASE>
diff: <the token diff_fingerprint.sh printed>
source: code-review | gantry-reviewer | self-review
tier: <tier>
tallies: returned=<n> verified=<n> address-now=<n> deferred=<n> dropped=<n>
Guard blocks: <command and block message>   (only when a guard blocked something)
Probe coverage: reduced coverage — <reason>   (only when step 2a made no clone, or a probe could not run in it)

## Address now
- `<path>:<line>` — <what is wrong>. Failure: <inputs → wrong result>.
```

One bullet per address-now finding, each with the file, the line, what is wrong and the concrete
failure — enough for a fix step in another session to act on without re-reviewing. **No
address-now findings → the section still exists and reads `None.`** on its first line, so the fix
step can tell "reviewed, nothing to apply" from "never reviewed"; `lib/detect_stage.sh` reads that
line as `REVIEW:clean`. An address-now finding that came from a `defer: never` lens starts its
text with `[lens <name>]`, so ship can tell it from the rest if it is never applied.

Then, **on every review, whatever the source and whether or not a lens fired**, the risk
assessment. This session writes it — the review run, never the session that wrote the change:

```
## Risk
Risk level: <low|medium|high|critical>
Lens file in diff: <path> — <level>, …   (one per LENS_IN_DIFF: line; none when there is none)
Blast radius:
- Breaks if wrong: <what fails, for whom, if this change is wrong>
- Live after merge: <yes|no> — <how: what runs it, and when>
- Rollback: <how to undo it, and whether a revert is enough>
```

`Risk level:` is your judgement of the diff, not the floor — ship takes the max of it, every
fired lens's floor and every `LENS_IN_DIFF:` level, so do not inflate it to meet one. `Blast radius:` has **exactly** those three
bullets. When step 2b could not evaluate the lenses, add `Lenses: could not be evaluated — <reason>`
as the line after `Risk level:`, ahead of any `Lens file in diff:` lines. Neither is a bullet, and
both go before `Blast radius:`, so its three bullets stay exactly three.

Then one section per lens that fired, in the order the script printed them:

```
## Lens: <name>
floor: <FLOOR from the script>
- `<path>:<line>` — <finding>. Failure: <inputs → wrong result>.
- Open risk: `<path>:<line>` — <finding left unfixed here, and why>.
### What to look at
- `<path>`: <the lines to read, and what to check in them>
```

Findings first (or `No findings.`), an `- Open risk:` line for each `defer: never` finding that is
not in *Address now*, then `### What to look at` with **one bullet per `FILE:` line the script
printed — every one of them**. When this lens's section exists and the script printed a
`LENS_IN_DIFF:` line, add a line here naming the lens file this diff changed — "judged by the base's
lenses" for a line with a level, "no-base-lens: nothing judged it" for `no-base-lens`. The `## Risk`
line from step 2b is written either way. None of these
sections changes `REVIEW:` — the detector reads only *Address now* and the last line.

No `session:` line, deliberately: a child cannot read its own session id, and the launcher already
reports it from the child's JSON result.

### 5. Fix what you kept — only with `--fix`

**Without `--fix`, make no edit.** Report the address-now findings as what *would* be fixed, and
name `/gantry:review --fix` as the way to apply them. Skip to step 6; there is nothing to re-prove,
because nothing changed.

With `--fix`, first — **in apply mode only** — check that `review.md` describes this tree:

```bash
bash "$GANTRY/lib/review_fresh.sh" --findings
```

It compares `review.md`'s `branch:` with the current branch and its `diff:` with the token
`diff_fingerprint.sh` prints for `base:` now — `--findings` means `diff:` alone, never the `diff=` on
an `applied:` line, so a second `--fix` on a tree already fixed is refused. Exit `0` (`FRESH:yes`)
means apply. **Anything else, stop** — `1` the file describes another branch or a moved diff, `3` there
is no `review.md`, `2` it is malformed: say the file describes a different diff (or a different branch) and name
`/gantry:review` to review the tree as it is now. Applying stale findings to a moved tree is worse
than applying none.

Then make the fixes `review.md` lists — on the ordinary path, the ones step 4 just kept. Read each
file a finding names before editing it; a listed finding that no longer holds is skipped and said
so, never invented into the code. Then **re-run the gate** — a fix made after the gate went green
is unproven code:

```bash
bash "$GANTRY/lib/run_gates.sh"            # supervised
bash "$GANTRY/lib/run_gates.sh" --strict --fast   # unattended — the fast in-run gate, as implement's
```

Same exit-code contract as `/gantry:implement`: `0` green · `1`+ red · `2` could not run · `3`
`NO-GATES` under `--strict`. Red here means your fix broke something — treat it exactly as
`implement` does, capped at 2 attempts unattended, stop supervised.

**Then append one line to `review.md`, last, with the gate's final exit code:**

```
applied: <ISO-8601 UTC date> gate=<exit> mode=<fast|full> seconds=<n> diff=<the token diff_fingerprint.sh prints now, after the fixes>
```

Run `bash "$GANTRY/lib/diff_fingerprint.sh" <BASE>` once more after the gate, for the `diff=`: the
fixes moved the tree, so `diff:` above describes the tree *before* them. `diff=` is what lets
`lib/review_fresh.sh` (and so `gantry:ship`) tell a review whose fixes are applied from one that
describes an older diff. A line without it still reads, falling back to `diff:` — which the fixes
have already moved, so such a review counts as stale.

`mode=` and `seconds=` are copied from the gate transcript's `== gate mode=… seconds=… ==` line
(`mode=`, not `requested=`); the driver journals them, since it never sees this run's output.

That line is how the detector reports `REVIEW:applied` and how the headless launcher reads
`GATE_EXIT:` back for the driver, so it is written on every `--fix` run that applied anything —
including a run whose gate ended red. If the gate ended red after the attempts the mode allows,
also set `task.md` to `status: blocked` and stop: a tree whose fixes broke the checks is unsafe to
ship, and the drivers read that status.

### 6. Hand over what you deferred

If anything was deferred, **invoke `gantry:handover`** and let it write `handover.md`. Pass it the
findings, why each is out of scope, and what the next person should do. Do not write the file
yourself — the handover skill owns its shape, and `/gantry:handover` typed by hand must produce the
same artifact this does.

**This happens with or without `--fix`.** A deferral is a fact about the review, not an edit to the
change, and the drivers journal `handover.md` as this phase's artifact. It is the one file a
read-only run still writes — and since 0.5.0 it is excluded rather than committed, so writing it
moves nothing `gantry:ship` has to re-detect. It reaches the reviewer through the pull request
body, which ship composes.

Nothing deferred → no `handover.md`. An empty handover file is noise in that body.

### 6b. Remove the probe clone

If step 2a made one, remove it now, and on **every** stop before this point as well — a blocked
status, an early return, a failed child:

```bash
bash "$GANTRY/lib/probe_clone.sh" remove <the PROBE_DIR path>
```

It deletes the clone and its temp directory. Nothing was made in apply mode, so nothing is removed.
A review that dies before reaching this leaves a clone behind; the next `create` sweeps any older
than a day.

### 7. Record the status

Set `task.md` frontmatter to `status: reviewed` — **always, `--fix` or not.** The review happened;
that is what the status records. It is also the chain's memory: `lib/detect_stage.sh` reads it to
decide the phase, and is what moves this task on to `ship` — or, while `review.md` still lists
findings, keeps it at the fix step. It is not the only reader —
`hooks/readiness-gate.sh` parses the same field with a copy of the same function, kept
byte-identical by a check in `scripts/verify.sh` — which is another reason not to make this write
conditional. Gating it on `--fix` would strand a
read-only review outside the state machine, leaving the detector to report `/gantry:review` as the
next command against a diff that was just reviewed. In apply mode the status is already `reviewed`
and stays so, unless step 5 set `blocked`. A defeated guard (see *Guard blocks*) is the same: the
`blocked` it set is final, and this step must not overwrite it with `reviewed`.

If review found something that makes the change unsafe to ship at all, set `status: blocked`
instead, hand it over, and say so. Blocking here is cheap; blocking after the merge is not. When
`gantry:ship` invoked this phase through `--review` or `--review-fix`, a `blocked` verdict stops
the ship — no push, no PR.

## Report

Which source ran — named plainly, self-review disclosed as self-review. If source 1 did not run,
say what happened when you invoked it; "unavailable" with no cause is how a downgrade hides. The
**tier** that was passed, and if a tier was refused, which value and why.

**Two tallies, not one:** how many findings came back, and how many survived step 3's verification.
Then how many were addressed, deferred, and dropped — and under `--headless`, how many were
deferred because they would otherwise have been asked about. A run that reports "12 findings" when
5 were untrue has told the reader something false about the diff.

**Probe coverage**: whether the probe clone was made and removed, or `reduced coverage` and why;
that source 1's finders are not covered by it, when source 1 ran.

**Guard blocks**: each command a guard blocked and its message, any attempt to get around one, and
whether a workaround got through (which sets `status: blocked`); or that none occurred.

**The lenses**: which fired (name, floor, matched-file count), or that none did, or that they could
not be evaluated and why; any `LENS_IN_DIFF:` line; the `Risk level:` you wrote; and every open
risk, verbatim.

Whether `--fix` was given, and whether this was apply mode. Without `--fix`, say plainly that
nothing was edited and name what would have been. With it, the gate's exit code. The `review.md`
path and the `REVIEW:` value the detector now reports; the `handover.md` path if one was written.
End by naming the next command: `/gantry:review --fix` while `REVIEW:pending`, else `/gantry:ship`.
