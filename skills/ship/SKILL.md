---
name: ship
description: Advances the current branch one clean step closer to a merged PR, doing only what isn't done yet — commits outstanding changes, pushes to the upstream, opens a pull request, and once the PR exists and is up to date, reports its status and waits. Idempotent — it detects the stage and picks up from there, so it's safe to run repeatedly. Pass --no-pr to stop after the push without opening a PR, --draft to open the PR as a draft, or --review / --review-fix to run gantry:review before the push. Use when the user types "/gantry:ship", or asks to ship, to commit and push, to open a PR for this branch, or to "get this out for review". Refuses to run on the repo's default branch.
argument-hint: [--no-pr] [--draft] [--review[=<tier>]] [--review-fix[=<tier>]] [--review-model <alias>] [--review-effort <level>] [--base <branch>]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion, SendMessage
---

# gantry:ship

Move the current branch to the next stage on the path **commit → push → open PR → wait**, doing
only the stages that aren't done yet. Run it once and it advances as far as it can in one go; run
it again later and it picks up wherever the branch now sits.

Typing `/gantry:ship` **is** the go-ahead to commit, push, and open the PR — don't ask for
confirmation stage by stage. Do still stop on the guards below (default branch, diverged branch,
nothing to ship). This skill runs in any repo, so follow *that* repo's conventions, not gantry's.

**Ship does not review.** There is no review stage on the path above, and a bare `/gantry:ship`
never invokes `/code-review` or `gantry:review`. A review is slow, expensive and worth choosing, so
it is something you ask for by flag — see *Review, only when you asked for it* below.

**`--no-pr`**: if `$ARGUMENTS` contains `--no-pr`, run commit → push only. Skip stage 4 entirely and
treat the push as the finish line — after pushing, go straight to the report and note the PR was
intentionally not opened. This is the mode `/gantry:auto --no-pr` passes through. **One thing
survives the skip:** stage 4's disclosure checks. The push still happens, so a `--no-pr` run that
changed the plugin's own files, or shipped a task with unproven acceptance criteria, still has to
say so — in the report, since there is no body to say it in.

**`--review`** / **`--review-fix`**: run `gantry:review` before the push, in a fresh headless child
session. `--review` reviews and reports without touching the code; `--review-fix` also runs a
second child that applies the findings triage kept. Both take an optional tier —
`--review=<tier>`, `--review-fix=<tier>` — and the bare forms mean `high`. **`--review-model
<alias>`** and **`--review-effort <level>`** reach the child as `--model` and `--effort`; with
neither, it inherits the user's defaults. See the section below, which is where the whole behaviour
lives.

**`--base <branch>`**: if `$ARGUMENTS` names a base branch, pass it straight through to the
detector (below) so it overrides base detection, and open the PR against it. Use it when the repo
integrates somewhere other than what detection would pick. An override that names a branch which
doesn't exist is ignored (the detector warns and auto-detects); a malformed `--base` with no value
is a usage error (the detector exits non-zero). `/gantry:auto --base <branch>` passes through.

**`--draft`**: open the pull request as a draft (`gh pr create --draft`). Use it when nobody has
reviewed the change live — which is why `/gantry:auto-unattended` always passes it. A draft doesn't
request reviewers, so it says "this is finished but unwatched" rather than "please look now". It
only affects stage 4; with `--no-pr` it does nothing.

## Steps

### 1. Detect the stage

`$GANTRY` is this skill's plugin root — resolve it from this file's own location, the same way the
other gantry skills do, rather than hardcoding a path.

```bash
bash "$GANTRY/skills/ship/scripts/detect_state.sh"                 # normal
bash "$GANTRY/skills/ship/scripts/detect_state.sh" --base <branch> # when --base was given
```

One read-only pass. It prints `BRANCH`, `BASE` (the PR base = repo default branch), `UPSTREAM`,
`AHEAD`/`BEHIND` vs upstream, `AHEAD_OF_BASE` (commits not yet in base), `DIRTY`, `ON_DEFAULT`,
`GH` (`ok`/`missing`/`unauth`), `PR` (`none`, or number + url + state + mergeable + reviewDecision),
and a final `STAGE:` — the entry point. Route on `STAGE`:

- `not-a-repo` / `detached` → nothing to ship; say so and stop.
- `on-default` → the branch **is** the base; you can't open a PR against itself. Stop and suggest
  starting a branch first (e.g. `/gantry:worktree <name>`). Don't commit onto the default branch.
- `behind` → the branch has diverged from its upstream (ahead **and** behind). Stop; tell the user
  to integrate first (`git pull --rebase`) and re-run. Never force-push to resolve this.
- `no-diff` → clean and pushed but no commits over `BASE` — there's nothing to open a PR for. Report
  and stop.
- `commit` → go to stage 2, then flow on through push and PR.
- `push` → skip to stage 3 — **through** the review section below, if a review flag was given.
- `pr` → skip to stage 4. The branch is already pushed; the PR has not been opened. A review flag
  still runs first — see *Review, only when you asked for it*, which says what `pr` does.
- `done` → skip to stage 5. The PR already exists.

A review flag is the one thing these skips must not jump over: the section that describes it sits
between stages 2 and 3, and it carries its own entry-point table for exactly this reason.

Completing one stage lands you at the top of the next, so once you enter at the routed stage,
continue straight down without re-detecting — **with one exception: `--review-fix` can create a
commit, and if it does, you must re-run the script before continuing.** That exception belongs to
the review section below, which says when it applies.

### 2. Commit

Look before writing the message: `git status` and `git diff` (or `git diff --staged`).

- **Respect intentional staging.** If anything is already staged, commit exactly what's staged.
  Otherwise stage everything with `git add -A` and commit that.
- **One coherent change.** If the outstanding work is clearly several unrelated changes, don't bury
  them in one "ship" commit — pause and ask how to split it. A quick, coherent diff needs no such
  pause. If `task.md`'s frontmatter names a `lead:`, put this question to the lead instead, as a
  `fork`, following `$GANTRY/skills/auto/references/lead.md`.
- **Message**: a concise imperative subject, plus a short body if the change warrants it. Match the
  repo's recent `git log` style, including whether it uses commit trailers — some repos do, some
  (like gantry) deliberately don't. Follow the ambient convention.
- **Re-read the subject before committing it**, under the same rule stage 4 applies to the PR body:
  *a claim about how something works either cites the file that establishes it, or it does not go
  in the subject.* This is the **only** point at which the subject is free to fix. After stage 3 it
  is on the remote, and stage 3 does not rewrite history to correct prose.

```bash
git commit -m "<subject>"        # add -m for a body paragraph if warranted
```

### Review, only when you asked for it

**Not a stage.** It has no number because it is not on the path: with neither flag given, nothing
in this section runs and nothing invokes a reviewer. That is the default, and it is deliberate.

- **`--review`** → launch `gantry:review` in a fresh headless child. It reviews, verifies its
  findings, triages them against `task.md`, records what is in scope to fix in `review.md`, and
  reports. It does not touch the code under review.
- **`--review-fix`** → the same, and then — when the detector says `REVIEW:pending` — a second
  headless child runs `gantry:review --fix`, which applies what `review.md` lists and re-runs the
  gate over its own edits.

**Headless, through the launcher, never in this session.** Since 0.7.0 there is one place a review
runs when an entry point asks for it, and it is `lib/run_phase_headless.sh` — the same launcher the
drivers use — so the reviewer is a child that has read nothing but the skill, the artifacts and
the diff, rather than the context that just wrote the commit. Do not invoke `/gantry:review`
yourself. Run each launch with the Bash tool's `run_in_background` and wait for the completion
notification; do not poll:

```bash
bash "$GANTRY/lib/run_phase_headless.sh" --phase review --root <ROOT> --tier <tier>
bash "$GANTRY/lib/run_phase_headless.sh" --phase review-fix --root <ROOT>      # --review-fix, on REVIEW:pending
```

**Pass `--model` every time**: a child with no `--model` takes the user default from
`settings.json`, not this session's model. Use `--review-model`'s alias when it was given,
otherwise the model this session is running on. Add `--effort <level>` only when `--review-effort`
was given, and `--plugin-dir "$GANTRY"` when `$GANTRY` is not under
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/` (a checkout, not an install). Then read the
launcher's lines: exit `1` or `3` → the review did not happen; stop with its `REASON:` line, **no
push, no PR**. Exit `2` → a broken environment (no `jq`, no `claude`); stop and say so. On exit
`0`, run `bash "$GANTRY/lib/detect_stage.sh"`: `STATUS:blocked` → the review found the change
unsafe; stop. Under `--review-fix`, `REVIEW:pending` → launch the fix child and read its
`GATE_EXIT:`; `REVIEW:clean` → nothing to apply, say so. Carry every `DENIED:` line and both
`SESSION:` ids into the report.

**The tier rides on the flag.** `--review=<tier>` and `--review-fix=<tier>` are forwarded to the
launcher as `--tier <tier>`; the bare forms mean `high`. **Do not validate the tier here.**
`gantry:review` owns the valid-value list and rejects anything outside it — duplicating that list
is how two skills come to disagree about it. If the child rejects the value it stops without
dispatching anything, the launcher exits non-zero with its reason, and by then stage 2 has already
committed: nothing has been pushed, the commit stands, and the run is resumed by fixing the flag
and running ship again. Say exactly that in the report rather than leaving the state to be guessed
at.

**Where it runs, at each entry point.** "Before the push" only describes one of them, and an
explicitly requested review must never silently not happen:

- `commit` → after stage 2's commit, before stage 3's push.
- `push` → nothing to commit; run it before stage 3's push.
- `pr` → **the branch is already pushed.** Run the review anyway; if it commits anything, push that
  before opening the PR, so the PR is never opened over a tip older than the review that informed
  it. This is the entry point where doing nothing would be a silent failure.
- `done` → the PR is already open. Say the flag had no effect and why; do not review a change that
  has already been published as though it could still change the outcome here.
- `no-diff` / the other guards → the run stops before this section is reached.

**The gate belongs to the review, and a red one stops the ship.** The fix child re-runs
`lib/run_gates.sh` over its own fixes and records the result in `review.md`'s `applied:` line,
which the launcher reads back as `GATE_EXIT:` — ship runs no gate of its own, so take the exit
code from that line and treat a non-zero one as terminal: **no push, no PR**. A fix made after
the gate went green is unproven code, and `--review-fix` is the only path on which ship could carry
unproven code to a remote. Report the exit code and what failed.

**And note what a `0` does not prove.** Under `--review-fix` the review runs `run_gates.sh`
*without* `--strict` on the supervised path, so a repo where no checks are detected exits `0` —
the `NO-GATES` notice — rather than the `3` that `--strict` would give. In that repo the review's
edits are pushed **unproven**: nothing ran over them. Say so in the report instead of reporting a
green gate. "The gate passed" and "there was no gate" are not the same result, and this is still
the one path that can push code no check has seen.

If the review changed files, commit them on their own — separately from stage 2's commit, so the
review's edits stay legible as review edits rather than folded into the change being reviewed.
That is `--review-fix`, and only it:

```bash
git add -A && git commit -m "Apply review findings"            # --review-fix
```

**A bare `--review` has nothing to commit.** The only files a read-only review writes are
`review.md`, `handover.md` and `task.md`'s status, and all three are excluded
(`docs/ARCHITECTURE.md` § *The artifact contract*) — so `git add -A` would stage nothing and the
commit would fail on an empty index. Do not run one. What it deferred still reaches the reviewer,
through stage 4's body rather than through the diff.

**Then re-detect — after `--review-fix`, and after the commit it caused rather than before it.**
Everything downstream branches on `AHEAD` and `DIRTY`, so a read taken before the fixes, or before
the commit they caused, would push the wrong thing, or nothing at all. After a bare `--review` the
tree is where stage 2 left it and the original read still holds.

```bash
bash "$GANTRY/skills/ship/scripts/detect_state.sh"     # again, after --review-fix and its commit
```

**A review you asked for can stop the ship.** If `gantry:review` reports the change unsafe to ship
— it sets `status: blocked` for exactly this — stop: no push, no PR. This is a deliberate
difference from a missing reviewer, which never blocks anything: you asked for this review, so its
verdict counts. Report what it found.

**Why this skill's `allowed-tools` is as wide as it is.** Frontmatter *restricts* what is permitted
while the skill is active, so an invoked sub-skill cannot use a tool this one has not allowed.
The review no longer runs inside this session — its tools are the child's, set by the launcher —
so none of this list is what lets a review edit. `Write` is still needed for the pull-request body
file in stage 4 and for the lead reply file under `references/lead.md`; `AskUserQuestion` for
stage 2's split question and `SendMessage` for its lead form; `Edit`, `Agent`, `Grep` and `Glob`
stay so that a sub-skill ship invokes is not silently narrowed. Do not trim it.

### 3. Push

```bash
git push -u origin HEAD     # when UPSTREAM was NONE (first push of this branch)
git push                    # when an upstream already exists and AHEAD > 0
```

Take `UPSTREAM` and `AHEAD` from the **most recent** detector read — a review flag may have
committed since the first one.

If the push is rejected because the remote moved, stop and report it — let the user integrate
(`git pull --rebase`) rather than force-pushing.

### 4. Open the PR

**First, branch on `PR` from the detector read.** A PR that already exists cannot be opened again,
and this stage's only fenced commands are `gh pr create`, which fails outright against one:

- **`PR:none`** → compose and create, as the rest of this stage describes.
- **anything else** (a PR already exists) → skip straight to *Refresh the handover and QA sections* below,
  then continue to stage 5. Nothing here is composed or created.

That second route is not hypothetical. `detect_state.sh` routes a dirty tree to `commit` and an
ahead branch to `push` **whether or not a PR exists**, and stage 1 says to continue straight down
without re-detecting — so "write the handover, make one more commit, run `/gantry:ship`" arrives
here with the PR already open. It is also exactly the path on which a handover most needs to reach
the body.

Skip this stage entirely if `--no-pr` was given — the push was the finish line. Go straight to the
**Report** (not stage 5, which reads a PR that doesn't exist) and note the PR was intentionally not
opened. **Run the contract step and both disclosure checks below anyway** and put their answers in
the report; the push already happened, so skipping them would mean shipping the plugin's own
change, or a task with unproven acceptance criteria, or a branch whose contract now lives only in
an uncommitted file, with nothing anywhere saying so.

Otherwise, only when `BASE` differs from `BRANCH` and there are commits over `BASE` (the detector's
`no-diff` guard already caught the empty case). If `GH` was `missing` or `unauth`, the commit and push still
happened — report that, print the manual `gh pr create` command, and stop. That path composes no
body file, so the printed command uses `--fill`, never `--body-file`: a path to a file this run
never wrote either fails or, worse, sends a body some earlier run left behind.

Compose from the branch's commits rather than a bare `--fill`. Title = the change in one line;
body = a short what/why, bulleting the commits when there are several.

**The tracker id goes first.** When the detector says `TASK:present` — never on `inherited`, whose
`task.md` is a previous task's — run `bash "$GANTRY/lib/task_id.sh" --task-file task.md`. If its
`ID:` line is not `-`, the title is `<ID>: <the change in one line>` (`BASE-71: integrate updates
the docs`), and the first line under `## What this change is for` is `Tracker: <ID>`, followed by a
blank line. That is what lets Linear's GitHub integration, and its equivalents, link the PR to the
issue. Nothing else in the body changes, and on `ID:-` — a date-slug id, or no id line — neither
does the title. Exit `2` here means the file could not be read — run it from the worktree root,
where the detector found `task.md` — and is not a reason to invent a prefix.

**Do not hard-wrap the body.** GitHub renders a pull request body in *comment* mode, where a single
newline inside a paragraph becomes a `<br>` — so a body wrapped at a column, the way this and most
repositories wrap their markdown files, arrives as a ragged column broken mid-sentence. Write each
paragraph, each list item and each table row on **one line** however long it runs, and let the
browser wrap it. Blank lines still separate blocks, and fenced code is still line-for-line.

This is the opposite of the rule for the **commit message** in stage 2, and deliberately so: a
commit message is read in a terminal that does not wrap it for you, so it stays wrapped. Two
renderers, two rules, and the body is the one the reviewer reads.

`scripts/check_pr_body.sh` decides this rather than judgement — it runs over the finished body file
under *Open it* below, the last thing before `gh pr create`, and you fix what it names.

For an unattended run the body is the **entire** interface to the reviewer — nobody watched the
run and nobody will re-derive it — so the checks below run before the body is composed, and the
re-read runs after it.

#### The contract, which the diff does not carry

`task.md`, `plan.md`, `handover.md` and `qa.md` are **not committed** (`docs/ARCHITECTURE.md` §
*The artifact contract*), so unlike in 0.4.x they are not in the diff and a reviewer cannot open
them from the pull request. **The body is now the only channel they have**, which makes this step
load-bearing rather than a nicety: skip it and the reviewer gets a diff with no statement of what
it was meant to do.

Read what exists at `ROOT` — the detector already reported which do:

```bash
bash "$GANTRY/lib/detect_stage.sh"      # TASK: / PLAN: / HANDOVER: / QA: lines
```

- **`TASK:present`** → the body carries a `## What this change is for` heading, and under it
  the `Tracker: <ID>` line when stage 4 found a tracker id, then `task.md`'s **Goal** and
  **Acceptance criteria** — quoted, not re-summarised. A summary written
  here is a second source of truth that can drift from the contract the work was actually done
  against, which is the entire failure this heading exists to prevent. On `TASK:inherited` the file
  is the *previous* task's contract: do **not** quote it, and say the branch shipped without one.
- **`task.md`'s `## Decisions` section holds entries** → a `## Decisions made` heading, carrying
  each one: the question, what was chosen, and **why**. This is `/gantry:grill`'s record of the
  conversation that settled the approach, and it is the only place that reasoning reaches a
  reviewer — the critique's own log lives in `plan.md`, which this body does not quote. Carry
  through anything grill marked **decided by recommendation, unconfirmed**: a decision the owner
  did not actually confirm is exactly what a reviewer should see flagged.

  **Entries, not the heading.** The task template ships this section with instructional prose in it,
  so a `task.md` freshly copied from the template *has* the heading and no decisions. Read it the
  way `lib/detect_stage.sh` reads *Open questions*: list items count, prose and fenced examples do
  not. Keying on the heading would quote the template's own guidance into the body as if it were
  this change's reasoning. A run with no entries — every `gantry:auto-unattended` run, since grill
  never ran — gets the heading and one line saying no grill conversation ran, per the absent rule
  below. And on **`TASK:inherited`** quote nothing here, for the same reason as the contract above:
  the decisions on disk belong to the previous, merged task.
- **`HANDOVER:present`** → a `## Deliberately not done` heading carrying `handover.md`'s items, one
  line each with its reason. This is what `/gantry:review` deferred; a reviewer who cannot see it
  re-reports every finding the run already triaged. **Put the marker line under the heading**, so a
  later run can tell whether the body is still current:

  ```bash
  bash "$GANTRY/lib/handover_body_state.sh" --marker handover.md
  ```

  It prints one HTML comment carrying a digest of `handover.md` — invisible in GitHub's rendering,
  and the whole basis of the refresh below. A body born without it is rewritten once on the next
  run; one born with it is left alone until `handover.md` changes.
- **`QA:`, whatever its value** → a heading of **exactly** `## Exercised by this run`, fixed for
  the same reason *Not proven by this run* below is: a reader who knows it exists can tell "the
  scenarios were run" from "nobody ran them". On `QA:exercised`, quote `qa.md`'s `## Scenarios`
  lines **verbatim** — each scenario, whether it was `declared` or `derived`, its verdict and the
  observation — and its `tools:` line, so the reader knows what observed them; if the file ends
  with an `applied:` line, say that a fix landed after the review. On any other value, one line
  and no scenarios: `absent` → `/gantry:qa` did not run on this tree; `no-agent` → the repo has no
  `.claude/agents/qa.md`; `unrunnable` and `no-scenarios` → `qa.md`'s `reason:` line verbatim;
  `unknown` → `qa.md` exists but its `outcome:` could not be read. Every value but `exercised`
  also feeds the *Not proven* heading below, when the task declared scenarios. When `qa.md`
  exists, **put its marker line under the heading**, as for the handover, so a later `/gantry:qa`
  run is noticed by the refresh below:

  ```bash
  bash "$GANTRY/lib/handover_body_state.sh" --section qa --marker qa.md
  ```
- **`PLAN:present`** → not quoted. `plan.md` is how the work got done, not what it promised, and it
  is usually long. Name it as available in the worktree and leave it there.
- Any of them **absent** → say so in one line under the relevant heading rather than omitting the
  heading. A branch shipped with no contract is a fact about the run, and a missing heading is
  indistinguishable from nobody writing one.

The `--no-pr` path has no body to put this in. Say the same thing in the report instead, under the
rule that already governs that path's disclosures.

#### What this run did not prove

All three are **disclosures**. None withholds the PR, fails the gate, or blocks the push.

**1. Acceptance criteria no gate could check.** Ship's own `detect_state.sh` reads git state and
never opens `task.md`, so the answer comes from the other detector:

```bash
bash "$GANTRY/lib/detect_stage.sh"      # read the HUMAN_ONLY: and E2E: lines
```

On `HUMAN_ONLY:present` the body carries a heading of **exactly** `## Not proven by this run`, and
under it the entries from `task.md`'s `human_only` block **verbatim**.

**2. Declared e2e scenarios nobody ran.** On `E2E:present` with `QA:` anything but `exercised`,
the same heading carries the entries of `task.md`'s `e2e.scenarios` block **verbatim** — name,
goal, steps — with one line in front saying why they were not run: the `reason:` line from `qa.md`
when there is one, else that `/gantry:qa` did not run. The contract promised these checks and the
run did not keep them; a reviewer who pulls the branch to tap through the feature is doing what
this line tells them is still undone. On `QA:exercised` the scenarios are under *Exercised by this
run* above, verdicts included, and nothing about them goes here — a scenario that ran and
**failed** is a failure the body reports under that heading, not an unproven claim.

One source of truth for each half: the detector decides **whether** the heading appears, `task.md`
supplies the **text**. The entries are multi-line and one labeled line per value is the detector's
whole output contract, so it cannot carry them. If the detector says `present` and you cannot find
quotable entries, **emit the heading anyway** and say the block could not be read — failing toward
the disclosure is the point.

The heading is fixed so that its **absence** is itself information: a reader who knows it exists
can tell "there was nothing to disclose" from "nobody wrote it down". A disclosure that appears
only when someone remembers to write it is not a disclosure.

**One heading, not one per signal.** Anything else a phase reports as shipped-but-unproven belongs
under it too — a gate that went green over code no check actually covered is the next such signal,
and it arrives from `/gantry:implement`'s report rather than from anything ship computes. Add what
the phases reported; do not invent a signal no phase gave you, and do not open a second heading for
it. A reviewer scans for one heading or none. (*Exercised by this run* is not a second copy of
this one: it holds what **was** checked, and a reader needs the two kept apart.)

**When `--draft` was passed**, the body also says plainly what draft status does *not* mean:
**draft means unwatched, not unverified.** Include it whether or not the heading above appeared —
`--draft` is the condition, not `HUMAN_ONLY:` or `E2E:`. Left unsaid, a reviewer reads "draft" as
unfinished work and takes the gaps as expected rather than as unchecked.

**3. Whether the plugin's own change was exercised.** Three conditions, all commands:

1. The repo carries `.claude-plugin/plugin.json` at its root. If not, **the whole check is inert** —
   an ordinary target repo that happens to have a `lib/` directory must not produce a disclosure
   about plugin versions.
2. `git diff --name-only <BASE>...` shows a path under `skills/`, `lib/`, `hooks/` or `agents/`.
3. `$GANTRY` and the repo root are **not** the same tree (compare resolved real paths). When they
   are — the `--plugin-dir` shape `CONTRIBUTING.md` documents for testing a change locally — the
   edited skills **did** execute, and the disclosure is **suppressed rather than stated**. Saying
   "untested" there would be precisely the false mechanism claim the next step exists to strike.

When all three hold, name the version that actually executed, and be exact about what was and was
not exercised — **one sentence is wrong for half of these paths**:

- `skills/` and `agents/` are loaded by the harness from the installed plugin. Edits to them did
  **not** execute this session at all. This is the measured case: a run edited `skills/ship`, then
  invoked ship, which ran the *old* copy — the change's headline feature was never exercised by the
  run that shipped it, and the run reported success.
- `lib/` and `hooks/` are executed **from the worktree** by any repo whose suite points at its own
  copies, which gantry's `tests/lib.sh` does. The tests exercised them; what did not happen is that
  the *running plugin's* copies were the edited ones. Calling those "untested" is false.

Resolve the version from a command, never a guess. `$GANTRY` is the running plugin root; the
installed-plugins registry maps an install path to a version and a commit:

```bash
REG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
jq -r --arg root "$GANTRY" '.plugins | to_entries[] as $e | $e.value[]
  | select(.installPath == $root) | "\($e.key) \(.version) \(.gitCommitSha)"' "$REG"
```

**Use `$GANTRY` as given for this lookup** — the registry stores the install path as a literal
string, so a physically-resolved path fails to match whenever any component of it is a symlink
(a symlinked `$HOME` or `CLAUDE_CONFIG_DIR`), and ship would report "no recorded install" for a
plugin that is registered. Real-path resolution belongs to condition 3 above, which is comparing
two trees for identity; it does not belong here, which is comparing a string to a recorded one. If
the literal lookup misses, retry it once against the resolved path before concluding anything.

Three outcomes, and the skill owes the reader whichever one happened:

- it matches a registry entry → name that plugin, version and commit;
- `$GANTRY` resolves but matches no entry → say which root executed and that it corresponds to no
  recorded install;
- nothing resolves → say **"could not determine the executing plugin version"**. That is a
  legitimate and useful disclosure. It is never omitted, and never replaced by a guess.

#### Re-read what you just wrote

The last thing before `gh pr create`, and the only scrutiny this prose will get.
`/gantry:plan-critique` read `task.md` and `plan.md`; `/gantry:review` read the diff, if it was
asked to. **None of them read this title, this body, or the commit subject** — all three are written
last, by the context most invested in the result.

One rule, narrow on purpose:

> **A claim about how something works either cites the file that establishes it, or it does not go
> in the body.**

Not "be accurate", which is advice nobody can fail. **Mechanism claims** are what go wrong. Two
were published in a gantry PR body — that a readiness hook was inert because the repo registered no
`Stop` hook, and that `detect_stage.sh` computed one of its lines from repo settings. Both were
false, both were caught by a human peer rather than by any phase, and the correction cost three
commits and two rewrites of the body.

Check the composed **title**, the composed **body**, and the **commit subject** against `task.md`
and the diff. Anything you cannot point at a file for is **struck, not softened** — "appears to" is
still an assertion nobody verified.

The subject was already checked in stage 2, where amending was free. A problem found with it *here*
is on the remote already, and stage 3 does not rewrite history to correct prose: say so in the body
instead.

**Why this lives here and not in `/gantry:review`.** That phase runs against the diff, before ship
has composed a title, a body or a message — so extending its scope means either running it a second
time after composition or moving it after composition, and both cost more than the check is worth.
It is a checklist you apply in your own context, not a sub-agent to dispatch. Do not "fix" this by
moving it into review.

#### Open it

The body goes to `gh` as a **file inside the worktree**, never inline and never from outside the
checkout. Inline, a real body — backticks, quotes, headings, many lines — does not survive shell
quoting. From `/tmp`, a scratchpad or `$HOME`, `--body-file` is an upload of a file by path from
outside the repository, which a privileged-command gate is right to put in front of a human — and
it then asks once per pull request. A relative path into the git-excluded `.claude/artifacts/` of
the checkout the command runs in is the shape such a gate can tell is the repo's own prose.

`ROOT` is the worktree root `lib/detect_stage.sh` printed in the contract step above. Every
command below uses a **relative** path, so run them from `ROOT`. If the shell is somewhere else, run
`cd "<ROOT>"` as a Bash call **of its own** first. Never chain it — `cd "<ROOT>" && gh pr create …`
names a body file relative to a directory the command itself moved to, which a gate that judges
paths cannot verify, and it asks.

Keep the file out of git, so `git add -A` on a later run can never sweep it into a commit:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md /qa.md .claude/artifacts/
```

Write the final, re-read body with the Write tool to `<ROOT>/.claude/artifacts/pr-body.md`.
Overwrite whatever is there: a file left by an earlier attempt is not this run's body.

```bash
bash "$GANTRY/scripts/check_pr_body.sh" .claude/artifacts/pr-body.md
```

Fix what it names in the file and run it again until it passes. Then open the PR:

```bash
gh pr create --base "<BASE>" --head "<BRANCH>" --title "<title>" --body-file .claude/artifacts/pr-body.md
gh pr create --base "<BASE>" --head "<BRANCH>" --title "<title>" --body-file .claude/artifacts/pr-body.md --draft   # --draft
```

Report the PR URL it prints. Once the PR exists, remove the file — the body now lives on the pull
request, and a stale copy is one a later run could mistake for its own:

```bash
rm -f .claude/artifacts/pr-body.md
```

If `gh pr create` failed, leave the file where it is: it is excluded from git, so it cannot reach a
commit, and the next run composes the body afresh and overwrites it — it is never reused as it
stands, because the branch it described may have moved.

#### Refresh the handover and QA sections of an existing body

**Entered from two places**: stage 4's branch above, when a PR already exists, and stage 5 before
its status read. Not a step inside either — a refresh that lived only on the fully-shipped path
would never run after "write the handover, commit once more, ship", which is the common order.

**Why it exists.** The body is composed once, at `gh pr create`. `handover.md` is usually written
*after* that, because `/gantry:review` is what produces one — and the body then still says no
handover exists while the file holds verified findings. The worktree holding the only copy is one
merge away from being pruned. `qa.md` goes stale the same way: `/gantry:qa` re-run after the PR
opened — a repo that opted in late, a `--fix` pass — leaves a body reporting the old outcome,
typically "no qa agent" over scenarios that have since passed.

**What it may rewrite.** Only the `## Deliberately not done` and `## Exercised by this run`
sections, each only when it is out of date. Every other byte of the body is left alone: a wholesale recompose would overwrite hand-edits
made on GitHub after the PR opened. Skip the whole sub-stage when `--no-pr` was given — there is no
PR to refresh — and when `GH` was `missing` or `unauth`.

Run from `ROOT`, with relative paths, under the same rule as *Open it* above.

1. Make the directory and keep the files out of git. *Open it* does this on the create path; a run
   that entered at stage 5 never reaches it, and an unexcluded body file is one `git add -A` commits
   on the next run — which then reads the worktree as dirty. **`mkdir -p` is not redundant:**
   `ensure_excluded.sh` creates the directory holding the *exclude file*, not this one, and
   everywhere else in this repo the first write into `.claude/artifacts/` is a **Write** tool call,
   which creates parents. Here it is a shell redirect, and stage 5 is reachable in a worktree where
   no phase ever wrote a gate log.

   ```bash
   mkdir -p .claude/artifacts
   bash "$GANTRY/lib/ensure_excluded.sh" journal.jsonl .claude/artifacts/
   ```

2. Fetch the live body. **`-q .body` is not optional** — without it the file receives the JSON
   envelope rather than the body.

   ```bash
   rm -f .claude/artifacts/pr-body-live.md
   gh pr view --json body -q .body > .claude/artifacts/pr-body-live.tmp \
     && mv .claude/artifacts/pr-body-live.tmp .claude/artifacts/pr-body-live.md
   rm -f .claude/artifacts/pr-body-live.tmp
   ```

   **The `.tmp` and the `mv` are the guard, not tidiness.** A plain redirect truncates its target
   before `gh` runs, so a fetch that fails for any reason — auth, network, rate limit — leaves an
   **empty** `pr-body-live.md` behind. An empty body reads as `MISSING` at step 3, and step 4 would
   then "refresh" the pull request by replacing its *entire* body with the handover section alone,
   destroying the contract, the scope and the human-only checks. Writing to `.tmp` and promoting it
   only on success makes a failed fetch an **absent** file, which step 3 rejects instead.

3. Ask whether each section needs refreshing — two questions, one per section:

   ```bash
   bash "$GANTRY/lib/handover_body_state.sh" .claude/artifacts/pr-body-live.md handover.md
   ```

   ```bash
   bash "$GANTRY/lib/handover_body_state.sh" --section qa .claude/artifacts/pr-body-live.md qa.md
   ```

   Each answers for its own section:

   - **`CURRENT`** → the body already carries this file. Leave that section alone.
   - **`NO-HANDOVER`** / **`NO-QA`** → there is no such file. Nothing to refresh in that section.
   - **`STALE`** or **`MISSING`** → that section is refreshed in step 4. `MISSING` means the body
     has no such section at all — for the handover, the PR-opened-before-the-review case.
   - **Exit 2** (no one-word answer) → the state could not be read: step 2's fetch failed and left
     no file, or there is no SHA-256 tool on `PATH`. **Edit nothing**, in either section. Report
     that the body could not be checked and leave the pull request as it is.

   Neither `STALE` nor `MISSING` → **make no edit.** Report that the body is current and skip to
   the end of the sub-stage.

4. Compose each stale section and write it with the Write tool:

   - **handover** → the `## Deliberately not done` heading, the marker line from
     `handover_body_state.sh --marker handover.md`, and `handover.md`'s items one line each with
     its reason, exactly as the contract step describes — to
     `<ROOT>/.claude/artifacts/handover-section.md`.
   - **QA** → the `## Exercised by this run` heading, the marker line from
     `handover_body_state.sh --section qa --marker qa.md`, and the content the contract step's
     `QA:` rule gives for `qa.md` as it now stands — to `<ROOT>/.claude/artifacts/qa-section.md`.

   Then splice. One stale section goes straight from the fetched body to `pr-body.md`:

   ```bash
   bash "$GANTRY/lib/splice_pr_section.sh" .claude/artifacts/pr-body-live.md .claude/artifacts/handover-section.md "Deliberately not done" > .claude/artifacts/pr-body.md
   ```

   ```bash
   bash "$GANTRY/lib/splice_pr_section.sh" .claude/artifacts/pr-body-live.md .claude/artifacts/qa-section.md "Exercised by this run" > .claude/artifacts/pr-body.md
   ```

   Both stale → chain them, so the fetched original stays untouched:

   ```bash
   bash "$GANTRY/lib/splice_pr_section.sh" .claude/artifacts/pr-body-live.md .claude/artifacts/handover-section.md "Deliberately not done" > .claude/artifacts/pr-body-handover.md
   ```

   ```bash
   bash "$GANTRY/lib/splice_pr_section.sh" .claude/artifacts/pr-body-handover.md .claude/artifacts/qa-section.md "Exercised by this run" > .claude/artifacts/pr-body.md
   ```

   Each splice replaces its one section, or inserts it before `## Not proven by this run` when the
   body has no such section yet. **A non-zero exit means the heading is ambiguous** — it appears
   more than once — and nothing was written. Do not hand-edit around it: report that the body needs
   a human, and leave the pull request as it is.

   **`## Not proven by this run` is not refreshed.** When QA has moved to `exercised` and the task
   declared scenarios, that section may still list them as not run. Say so in the report, naming
   the line, so a human deletes it; rewriting a third section on a guess is how hand-edits get lost.

5. Check it, send it, clean up — three blocks, because each gates the next. The body goes as a
   **file inside the checkout**, for the reasons *Open it* gives:

   ```bash
   bash "$GANTRY/scripts/check_pr_body.sh" .claude/artifacts/pr-body.md
   ```

   Fix what the check names **in the file** and run it again until it passes. Only the refreshed
   sections are this run's prose; if the check flags lines elsewhere in the body, they came back from
   GitHub that way — fix them too rather than reverting, since `gh pr edit` sends the whole file.
   Then send it:

   ```bash
   gh pr edit --body-file .claude/artifacts/pr-body.md
   ```

   ```bash
   rm -f .claude/artifacts/pr-body.md .claude/artifacts/pr-body-live.md .claude/artifacts/pr-body-handover.md .claude/artifacts/handover-section.md .claude/artifacts/qa-section.md
   ```

   **Clean up only after the edit succeeded** — the same rule the create path states for
   `pr-body.md`. If `gh pr edit` failed, leave the files where they are: they are excluded
   from git so they cannot reach a commit, the fetched original is the only copy of what the body
   said before, and `gh pr edit --body-file .claude/artifacts/pr-body.md` is what a human reruns by
   hand. Report the path rather than deleting the work.

6. Report which sections were refreshed and what each now says, or that the body was already
   current and nothing was edited.

### 5. Done — report and wait

The branch is fully shipped: PR open, nothing left to push.

**First, run *Refresh the handover and QA sections* above — unless stage 4 already routed you through it on
the way here**, in which case it has just run and a second pass would only spend another
`gh pr view` and repeat its report. Then come back here. A handover written after the PR opened
reaches nobody otherwise, and this is the stage a run lands on once there is nothing left to commit
or push — which is exactly when a review has just produced one.

Then pull the current status so "wait" is informed, not blind:

```bash
gh pr view --json url,state,mergeable,reviewDecision,statusCheckRollup
gh pr checks    # CI state, if there are checks
```

Report the PR URL, review decision, mergeability, and check status, and that there's nothing to do
but wait for review/CI. If checks are failing or the PR is blocked, say so plainly — that's the one
thing worth flagging here.

## Report

State what actually happened this run — which stages ran (committed / pushed / opened PR), the
commit subject, the PR URL, **whether the PR is a draft or ready for review**, and the terminal
status.

**Whether a review ran, and it only ran if you asked.** Say which flag was given, at which tier, and
whether it was `--review` or `--review-fix`; the child session ids, the `MODEL:` and `EFFORT:`
lines, and every `DENIED:` line, verbatim from the launcher; how many files the fixes touched, if
any; and the `GATE_EXIT:` the fix child recorded over those fixes. If no flag was given, say the run was not reviewed —
plainly, as a fact about this run rather than an omission. If `gantry:review` rejected the tier, say
that the commit stands and nothing was pushed. If it blocked the ship, lead with that.

**All stage 4 disclosures, always — including under `--no-pr`, where the report is the only place
they can land.** Say whether the *Not proven* heading was emitted and why (or why not) — the
`human_only` entries, the e2e scenarios nobody ran, or both — what *Exercised by this run* carried
(the `QA:` value, and the verdicts on `exercised`), and what
the executing-plugin check concluded: the version that ran, that the check was inert because the
repo is not a plugin, that it was suppressed because the plugin root and the repo are the same
tree, or that the version could not be determined. The driver journals this from what you report,
so an omission here becomes an omission in an append-only log.

If a guard stopped it (on the default branch, diverged, nothing to ship, gh unavailable), say which
and what the user should do next. **When a run stops after a review but before the PR** — the
`gh missing`/`unauth` case is the common one — a bare re-run is safe: ship reviews only when asked,
so re-running without a review flag will not review the branch a second time.

Be honest about anything skipped or unverified.
