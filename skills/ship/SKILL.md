---
name: ship
description: Advances the current branch one clean step closer to a merged PR, doing only what isn't done yet — commits outstanding changes, pushes to the upstream, opens a pull request, and once the PR exists and is up to date, reports its status and waits. Idempotent — it detects the stage and picks up from there, so it's safe to run repeatedly. Pass --no-pr to stop after the push without opening a PR, --draft to open the PR as a draft, or --review / --review-fix to run gantry:review before the push. Use when the user types "/gantry:ship", or asks to ship, to commit and push, to open a PR for this branch, or to "get this out for review". Refuses to run on the repo's default branch.
argument-hint: [--no-pr] [--draft] [--review[=<tier>]] [--review-fix[=<tier>]] [--base <branch>]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion
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

**`--review`** / **`--review-fix`**: invoke `gantry:review` before the push. `--review` reviews and
reports without touching the code; `--review-fix` also applies the findings triage keeps. Both take
an optional tier — `--review=<tier>`, `--review-fix=<tier>` — and the bare forms mean `high`. See
the section below, which is where the whole behaviour lives.

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
continue straight down without re-detecting — **with one exception: a review flag can create a
commit, and if it does, you must re-run the script before continuing.** That exception belongs to
the review section below, which says when it applies.

### 2. Commit

Look before writing the message: `git status` and `git diff` (or `git diff --staged`).

- **Respect intentional staging.** If anything is already staged, commit exactly what's staged.
  Otherwise stage everything with `git add -A` and commit that.
- **One coherent change.** If the outstanding work is clearly several unrelated changes, don't bury
  them in one "ship" commit — pause and ask how to split it. A quick, coherent diff needs no such
  pause.
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

- **`--review`** → invoke `gantry:review`. It reviews, verifies its findings, triages them against
  `task.md` and reports. It does not touch the code under review.
- **`--review-fix`** → invoke `gantry:review --fix`. Same, and it applies the findings triage keeps.

**The tier rides on the flag.** `--review=<tier>` and `--review-fix=<tier>` map to
`/gantry:review --tier <tier>` and `/gantry:review --tier <tier> --fix`; the bare forms mean `high`.
**Do not validate the tier here.** `gantry:review` owns the valid-value list and rejects anything
outside it — duplicating that list is how two skills come to disagree about it. If review rejects
the value it stops without dispatching anything, and by then stage 2 has already committed: nothing
has been pushed, the commit stands, and the run is resumed by fixing the flag and running ship
again. Say exactly that in the report rather than leaving the state to be guessed at.

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

**The gate belongs to the review, and a red one stops the ship.** `gantry:review --fix` re-runs
`lib/run_gates.sh` over its own fixes before it returns — ship runs no gate of its own, so read
the exit code out of review's report and treat a non-zero one as terminal: **no push, no PR**.
A fix made after the gate went green is unproven code, and `--review-fix` is the only path on
which ship could carry unproven code to a remote. Report the exit code and what failed.

**And note what a `0` does not prove.** Under `--review-fix` the review runs `run_gates.sh`
*without* `--strict` on the supervised path, so a repo where no checks are detected exits `0` —
the `NO-GATES` notice — rather than the `3` that `--strict` would give. In that repo the review's
edits are pushed **unproven**: nothing ran over them. Say so in the report instead of reporting a
green gate. "The gate passed" and "there was no gate" are not the same result, and this is still
the one path that can push code no check has seen.

If the review changed files, commit them on their own — separately from stage 2's commit, so the
review's edits stay legible as review edits rather than folded into the change being reviewed.
Name the commit for what it actually holds: `--review-fix` produces applied findings, while a bare
`--review` produces only `handover.md`.

```bash
git add -A && git commit -m "Apply review findings"            # --review-fix
git add -A && git commit -m "Record deferred review findings"  # --review, handover.md only
```

**Then re-detect — after either flag, not just `--review-fix`, and after that commit rather than
before it.** Both flags can move the tree: `--review-fix` through the fixes it applies, and
`--review` through `handover.md`, which a read-only review still writes when it defers something.
Everything downstream branches on `AHEAD` and `DIRTY`, so a read taken before the review — or
taken before the commit the review caused — would push the wrong thing, or nothing at all.

```bash
bash "$GANTRY/skills/ship/scripts/detect_state.sh"     # again, after the review and its commit
```

**A review you asked for can stop the ship.** If `gantry:review` reports the change unsafe to ship
— it sets `status: blocked` for exactly this — stop: no push, no PR. This is a deliberate
difference from a missing reviewer, which never blocks anything: you asked for this review, so its
verdict counts. Report what it found.

**Why this skill's `allowed-tools` is as wide as it is.** Frontmatter *restricts* what is permitted
while the skill is active, so an invoked sub-skill cannot use a tool this one has not allowed.
`Write` and `Edit` are what let `--review-fix` apply a single byte; `Agent` is what lets review fall
back to a sub-agent when `/code-review` is unavailable, instead of silently degrading to
self-review; `AskUserQuestion` is what lets its triage round ask about an ambiguous finding. Ship
writes no artifact of its own, so this list looks over-broad until you know that — do not trim it.
A review that cannot write reports as a clean no-op, which is indistinguishable from a diff with
nothing wrong in it.

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

Skip this stage entirely if `--no-pr` was given — the push was the finish line. Go straight to the
**Report** (not stage 5, which reads a PR that doesn't exist) and note the PR was intentionally not
opened. **Run the two disclosure checks below anyway** and put their answers in the report; the
push already happened, so skipping them would mean shipping the plugin's own change, or a task with
unproven acceptance criteria, with nothing anywhere saying so.

Otherwise, only when `BASE` differs from `BRANCH` and there are commits over `BASE` (the detector's
`no-diff` guard already caught the empty case). If `GH` was `missing` or `unauth`, the commit and push still
happened — report that, print the manual `gh pr create` command, and stop.

Compose from the branch's commits rather than a bare `--fill`. Title = the change in one line;
body = a short what/why, bulleting the commits when there are several.

For an unattended run the body is the **entire** interface to the reviewer — nobody watched the
run and nobody will re-derive it — so the two checks below run before the body is composed, and the
re-read runs after it.

#### What this run did not prove

Both are **disclosures**. Neither withholds the PR, fails the gate, or blocks the push.

**1. Acceptance criteria no gate could check.** Ship's own `detect_state.sh` reads git state and
never opens `task.md`, so the answer comes from the other detector:

```bash
bash "$GANTRY/lib/detect_stage.sh"      # read the HUMAN_ONLY: line
```

On `HUMAN_ONLY:present` the body carries a heading of **exactly** `## Not proven by this run`, and
under it the entries from `task.md`'s `human_only` block **verbatim**.

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
it. A reviewer scans for one heading or none.

**When `--draft` was passed**, the body also says plainly what draft status does *not* mean:
**draft means unwatched, not unverified.** Include it whether or not the heading above appeared —
`--draft` is the condition, not `HUMAN_ONLY:`. Left unsaid, a reviewer reads "draft" as unfinished
work and takes the gaps as expected rather than as unchecked.

**2. Whether the plugin's own change was exercised.** Three conditions, all commands:

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

The last thing before `gh pr create`, and the only scrutiny this prose will get. `grill` read
`task.md` and `plan.md`; `/gantry:review` read the diff, if it was asked to. **None of them read
this title, this body, or the commit subject** — all three are written last, by the context most
invested in the result.

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

```bash
gh pr create --base "<BASE>" --head "<BRANCH>" --title "<title>" --body "<body>"
gh pr create --base "<BASE>" --head "<BRANCH>" --title "<title>" --body "<body>" --draft   # --draft
```

Report the PR URL it prints.

### 5. Done — report and wait

The branch is fully shipped: PR open, nothing left to push. Pull the current status so "wait" is
informed, not blind:

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
whether it was `--review` or `--review-fix`; how many files the fixes touched, if any; and the gate
exit code `gantry:review` reported over those fixes. If no flag was given, say the run was not reviewed —
plainly, as a fact about this run rather than an omission. If `gantry:review` rejected the tier, say
that the commit stands and nothing was pushed. If it blocked the ship, lead with that.

**Both stage 4 disclosures, always — including under `--no-pr`, where the report is the only place
they can land.** Say whether the `human_only` heading was emitted and why (or why not), and what
the executing-plugin check concluded: the version that ran, that the check was inert because the
repo is not a plugin, that it was suppressed because the plugin root and the repo are the same
tree, or that the version could not be determined. The driver journals this from what you report,
so an omission here becomes an omission in an append-only log.

If a guard stopped it (on the default branch, diverged, nothing to ship, gh unavailable), say which
and what the user should do next. **When a run stops after a review but before the PR** — the
`gh missing`/`unauth` case is the common one — a bare re-run is safe: ship reviews only when asked,
so re-running without a review flag will not review the branch a second time.

Be honest about anything skipped or unverified.
