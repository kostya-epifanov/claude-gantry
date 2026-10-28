---
name: auto
description: Takes a task from a one-line description all the way to an open pull request on its own branch — creates a worktree, then drives the gantry chain (plan, critique, grill, implement, review, ship) by invoking each phase skill in turn. Supervised: it settles the approach with you in conversation, then pauses once before anything outward-facing. The repo's checks are a hard blocker throughout. Pass --no-pr to stop after the push. Use when the user types "/gantry:auto" with a task, or asks to take a task end to end or to "just do this and open a PR".
argument-hint: "[task] [--task <id>] [--no-pr] [--branch <name>] [--here] [--base <branch>] [--lead <session>] [--review-model <alias>] [--review-effort <level>]"
allowed-tools: Bash, Read, Write, Edit, Skill, Agent, AskUserQuestion, SendMessage
---

# gantry:auto

One command from a task description to an open pull request, supervised. It creates the branch and
worktree, then walks the gantry chain — **plan → plan-critique → grill → implement → review →
ship** — invoking each phase skill in turn.

**It stops for you twice, and they are different kinds of stop.** `grill` is a conversation: it
explains the problem, asks what only you can answer, and its last question is the approval for the
whole plan. Then one `AskUserQuestion` checkpoint in front of the side effects. There is no separate
"confirm the plan" dialog any more — a yes at the end of a conversation is worth more than a yes in
front of a wall of text.

**This skill contains no phase logic.** Planning, grilling, implementing, reviewing, and shipping
each live in their own skill, and this one invokes them — the same commands you would type. That is
deliberate: the same phases run whether you type them yourself, run them here, or run them
unattended, so they cannot drift into three subtly different pipelines.

**You do not dispatch sub-agents; the phases do.** `plan` dispatches the explorer when the surface
warrants it, `plan-critique` always dispatches a fresh critic, `review` dispatches an independent
reviewer. Each of those is scoped to its own sub-job and is read-only by tool list. `Agent` stays
in this skill's `allowed-tools` for that reason and no other: a skill's frontmatter restricts what
is permitted, it does not grant, so a phase cannot dispatch what the driver has not allowed.

For an unattended run to a draft PR, use `gantry:auto-unattended`. To drive it yourself, type the
phase skills in order. To run it as a lane that a lead session steers by message, pass
`--lead <session>`.

## Before you start

Read `references/orchestration.md` — flags, the three modes, how a phase is invoked, where the
checkpoints sit, and how the gate resolves. It is shared with `gantry:auto-unattended` so the two
cannot drift. Under `--lead`, also read `references/lead.md`, the protocol every question in this
run follows instead of `AskUserQuestion`.

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

## Stage 0 — Arguments

`$ARGUMENTS` is one string; read it yourself. Recognise `--no-pr`, `--branch <name>`,
`--task <id>`, `--here` (alias `--on-current`), `--base <branch>`, `--lead <session>`,
`--review-model <alias>` and `--review-effort <level>`; strip them; what remains is the task. The
tracker id and the `--branch` value are not read by eye: write the whole string to a file and run
`lib/task_id.sh` on it, as `references/orchestration.md` § *Deriving the branch name* describes —
its `TEXT:` line is the task with those two removed. On its exit `2` (a `--task` or `--branch` with
a missing or bad value), ask. `--review-model` and `--review-effort` are carried to stage 5's
launcher and nowhere else; with neither, the review child inherits the user's default model and
effort. `--here` and `--branch` are mutually exclusive — `--here` wins. If
no task text remains, ask what the task is. A `--lead` with no session name after it is also a
question, and it goes to the owner: there is no lead to ask yet.

State the task, the mode, and the flags back in one line before doing anything, including the lead
session if there is one.

**Under `--lead`, every question below goes through `references/lead.md` instead of
`AskUserQuestion`.** That includes the questions the phases ask themselves. Each stage names the
question's kind. Nothing else about the run changes.

## Stage 1 — Worktree and branch

Name the branch by `references/orchestration.md` § *Deriving the branch name* — `--branch` verbatim,
else `<type>/<ID>-<slug>` when `lib/task_id.sh` found a tracker id, else `<type>/<slug>` exactly as
before — then **invoke `gantry:worktree`** with it.
Let worktree own branch validation, the parent fetch, and entering the worktree — don't reimplement
any of it. Under `--lead`, tell it the run is under `--lead <session>`, so that its parent question
goes to the lead. `task.md` does not exist yet to say so.

Under `--here`, skip this entirely and run on the current branch. Stop first if HEAD is detached or
you are on the repo's mainline (`origin/HEAD`); `develop` is a valid `--here` target.

## Stage 2 — Plan

**Invoke `/gantry:plan`** with the task, with `--task <id>` when `lib/task_id.sh` found a tracker
id (so `task.md`'s `id:` is the same id as the branch), and with `--lead <session>` when the run
has one, so plan's own questions go to the lead from its first step.

It writes `task.md` and `plan.md` at the worktree root, and decides for itself whether the surface
needs the explorer. Read both files back from disk before moving on — a plan you remember writing
is not the plan on disk, and every later phase reads the file.

Set `task.md`'s `mode:` to `auto`, so `implement` and `review` resolve the right gate strictness
without being told. Under `--lead`, confirm the frontmatter carries `lead: <session>` and write it
if plan did not. From here on, that line is how every phase knows where to ask.

**Do not settle the forks here.** `plan` records them rather than asking them, and closing them is
`grill`'s job in the next stage — that is the whole point of having a conversation phase. Run
`bash "$GANTRY/lib/detect_stage.sh"`, read `FORKS:`, and simply say how many are waiting, so the
reader knows what the conversation is for. On `FORKS:unknown`, say the section is missing and
continue.

A fork is still never yours to answer. The reason the round moved rather than vanished is that one
priced question inside a brief beats a bare question in front of a plan the user has not been told
the shape of.

## Stage 3 — Grill: the critique, the conversation, and the approval

**Invoke `/gantry:grill`**, with `--lead <session>` when the run has one.

This one stage does what stages 2, 3 and 4 used to do between them. Grill chains
`/gantry:plan-critique` itself when the status is `planned`, so the cold critique still happens on
every supervised run; then it explains the problem, puts the open forks to the user as priced
options, folds the decisions into `task.md`'s `## Decisions` section, and closes with the terminal
question that **is** the plan approval. Read the revised `task.md` and `plan.md` back from disk.

The critique is still delegated, always, in every mode. That is `plan-critique`'s own central rule
and it is not yours to arrange or to skip — and grill is required to name the agent that produced it.

Three outcomes, and only one of them continues:

- **`status: grilled`** → the conversation converged and every fork is closed. Continue to stage 4.
- **`status: critiqued`** → grill did **not** finish. It leaves this status precisely when a fork is
  still open, and there is no later round to catch it: both fork rounds are gone, so `auto` would
  otherwise walk into `/gantry:implement`'s hard refusal a stage later with nothing explaining why.
  **Stop here** and surface the open fork.
- **`status: blocked`** → the dialogue concluded the task itself is wrong. Stop and surface the
  reason; a plan that did not survive its own grilling is a result, not a failure to route around.

Under `--lead`, remove the `lead:` line before stopping on either of the last two (see *Leaving lead
mode* in `references/lead.md`).

**Do not set the status yourself.** Grill owns its terminal status now, and writing `grilled` over a
returned `critiqued` would assert an approval nobody gave.

## Stage 4 — Implement

**Invoke `/gantry:implement`.**

`implement` owns the gate. It sets `status: implementing` before editing (which arms the readiness
hook), carries out the plan, and runs `run_gates.sh`. **Do not run the gate yourself and do not
route around a red one.** If it comes back red or blocked, stop and hand the failure to the user —
supervised mode does not iterate on a red gate. Under `--lead`, remove the `lead:` line before
stopping.

Take from its report: the gate's exit code, and whether the hook's firing conditions were
**met or unmet**. Both go in your final report verbatim.

## Stage 5 — Review

**Do not invoke `/gantry:review` in this session.** Launch it as a fresh headless child through
`lib/run_phase_headless.sh` and read its results back from disk. By now your context holds the
plan, the critique and the whole implementation, so a reviewer that inherits it is the author
reviewing itself — the weakest possible reviewer. The phase skill still carries the procedure; only
*where* it runs changes. `references/orchestration.md` § *Headless phases* has the detail.

1. **Launch the review child** with the Bash tool's `run_in_background`, so the wait is the
   completion notification rather than a foreground call under the ten-minute cap. Do not poll.

   ```bash
   bash "$GANTRY/lib/run_phase_headless.sh" --phase review --root <worktree> --tier high
   ```

   **Pass `--model` every time.** A child with no `--model` does not inherit *your* model — it takes
   the user default from `settings.json`, which is a different thing and was a different thing in
   practice: a driver pinned to Sonnet launched its review children on Opus because a `/model`
   command in an unrelated session had just saved that default. So pass `--review-model`'s alias
   when it was given, and otherwise **the model this session is running on**. Pass
   `--effort <level>` only when `--review-effort` was given. Add `--plugin-dir "$GANTRY"` when `$GANTRY`
   is not under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/` — a checkout rather than an
   install — so the child runs this checkout's skills and not the installed plugin's.

   If this session resumed after the notification was lost, look for
   `.claude/artifacts/headless/review.done` in the worktree before launching again. If it is
   absent, run the same command: the child outlives the launcher, so the launcher finds it by its
   `.pid` and attaches instead of starting a second review. A `NOTE:` line says which happened.

2. **Read the launcher's lines.** Exit `1` or `3` → stop and hand the user its `REASON:` line
   (under `--lead`, remove the `lead:` line first). Exit `2` → a broken environment (no `jq`, no
   `claude`): stop and report it as that, not as a failed review. On exit `0`, run
   `bash "$GANTRY/lib/detect_stage.sh"`: `STATUS:blocked` → the review found the change unsafe to
   ship; stop and surface it, as before. Keep every `DENIED:` line verbatim for the report — a
   denial does not fail the launcher, but a review denied a tool it needed is a weaker review.

3. **Route on `REVIEW:`.**
   - `pending` → launch the fix child the same way, with the same `--model`, `--effort` and
     `--plugin-dir`, and wait for it:

     ```bash
     bash "$GANTRY/lib/run_phase_headless.sh" --phase review-fix --root <worktree>
     ```

     Read `GATE_EXIT:` from its lines and treat it as `implement` treats the gate: non-zero →
     stop and hand the failure to the user. A launcher exit of `1` or `3` → stop with `REASON:`.
   - `clean` → the review found nothing in scope to fix. Say so and launch nothing.
   - `absent` after exit `0` cannot happen — the launcher checks for the file before exiting
     `0`. If it does, say the launcher's contract was broken, and stop.

Take from the children's output, for the report: the source named by `review.md`'s `source:` line
(`code-review`, `gantry-reviewer` or `self-review` — if it fell through to self-review, your report
must say so), both `SESSION:` ids, `MODEL:` and `EFFORT:`, every `DENIED:` line, and `GATE_EXIT:`.

Under `--lead`: a print-mode child cannot ask the lead, so anything `/gantry:review` would have
asked about it deferred instead. It is in `handover.md`, and stage 6's checkpoint shows it.

## Stage 6 — Checkpoint: confirm the side effects

**AskUserQuestion.** The gate is green and the review is in hand. "Commit, push, and open the PR?"

One gate in front of every side effect, since `gantry:ship` won't pause once invoked.

Under `--lead`, this is a `checkpoint` question to the lead. Side effects are within a lead's
authority; privilege is not, and a harness permission prompt that appears during ship waits for
the owner whatever the lead has said.

## Stage 7 — Ship

Set `task.md` to `status: shipped` **first** — ship commits the tree, so a status written
afterwards would miss the commit and leave the chain reading as unshipped. Then **invoke
`gantry:ship`.** It is exactly this tail — idempotent, stage-detecting, and it matches the *target
repo's* commit conventions rather than gantry's. Pass `--no-pr` and `--base` through if they were
given.

**Pass no review flag.** Ship reviews only when asked, and stage 5 already reviewed this change.
Passing `--review` or `--review-fix` here would review the same diff a second time — and under
`--review-fix`, reopen and apply findings `/gantry:review` deliberately deferred to `handover.md`.

`task.md`, `plan.md` and any `handover.md` are **not** committed — they stay in the worktree, and
ship quotes the contract and the handover into the PR body instead. They are still the record of
what was decided and what was left; they just are not part of the diff.

`gantry:auto` opens a **ready-for-review** PR. You were in the room for the review, so it does not
need to arrive as a draft. Under `--lead` the PR is still ready-for-review, and it is still never
merged: a lead may direct the chain as far as an open PR, and merge stays the owner's.

## Stage 8 — Report

The task and the mode. The branch and worktree path. Which sub-agents the phases actually
dispatched — the explorer if `plan` used one, and which critic ran. **The review children**: the
review child's session id and the fix child's (if one ran), the model and effort they ran with —
effort `inherit` when none was passed — the gate exit the fix child recorded, and every permission
denial, verbatim from the launcher's `DENIED:` lines.

**The grill conversation: how many rounds it took, every fork that was put to the user, and what
they decided.** Those are the decisions that shaped the work. They are on disk in `task.md`'s
`## Decisions` section and ship quotes them into the PR body, so unlike the old fork rounds they are
not lost when the round closes — but the report still names them, because the reader of this report
is usually not the reader of that PR. Call out anything grill marked **decided by recommendation,
unconfirmed**: those are the forks the user did not actually confirm, and they are the ones worth a
second look.

What the critique changed. The gate's exit code and whether the readiness hook's firing conditions
were met — which is not the same as the hook having run, since registration is not visible to the
detector. Which review tier ran, plainly named. What was deferred and the `handover.md` path if
there is one. The commit, the push, and the PR URL.

Under `--lead`, also report every question sent to the lead, each reply's classification from
`lib/lead_reply.sh`, and any question that hit the re-ask cap and went to the owner (the run carried
on in lead mode after it). Then remove the
`lead:` line from `task.md`.

Be honest about anything skipped, unverified, or self-reviewed. A report that reads cleaner than the
run went is the one failure this chain cannot catch.
