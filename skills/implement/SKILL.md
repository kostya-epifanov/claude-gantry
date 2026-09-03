---
name: implement
description: Carry out plan.md and prove it with the gate — sets task.md to implementing, makes the changes, then runs the repo's checks as a hard blocker that must go green before anything ships. Use when the user types "/gantry:implement", or asks to build, carry out, or execute an approved plan.
argument-hint: ""
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, AskUserQuestion
---

# gantry:implement

Execute `plan.md`, then prove the tree is green. This phase owns the gate — not because running a
script is interesting, but because "implemented" and "passes the checks" are the same claim, and
splitting them lets one be reported without the other.

## Three hard rules

**1. Refuse without a plan.** If there is no `plan.md`, stop and point at `/gantry:plan`.
Implementing from a task description alone is exactly the unplanned work the chain exists to
prevent, and it is not recoverable by looking at the result.

**2. Refuse an open fork when a driver dispatched you.** If `FORKS:open` and `task.md`'s `mode:` is
`auto` or `unattended`, stop. A fork left open under *Open questions* is a decision nobody made,
and carrying on means **you** make it — silently, inside code, hours after it would have cost a
sentence to ask. This is the rule that makes "never dispatch an implementer against an open fork"
true rather than aspirational.

Under `semi-auto` or no mode at all, a human typed the command and can see the answer: **warn,
name the remedy, and continue.** A hand-driven run iterates between phases, so a half-finished
artifact is a normal state there rather than an error, and locking someone out of their own
worktree over a note they left themselves would be the wrong trade.

**3. Set `status: implementing` before touching a single file.** That frontmatter value is what
arms the readiness hook. Set it after the edits and the gate was never enforced on them — you get
the appearance of a guarantee with none of it.

Rules 1 and 2 are refusals to start; this skill's refusal to move past a non-zero gate is the
third, and together they are the only hard refusals in the chain.

## Steps

### 1. Detect the stage

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

Route on what it prints:

- **`PLAN:absent`** → **stop.** Say a plan is required and name `/gantry:plan`. (Hard rule 1.)
- **`FORKS:open`** → read `task.md`'s `mode:` and route on it. (Hard rule 2.)
  - `auto` or `unattended` → **stop.** Name every open entry. A driver is running this, so the
    remedy is the driver's: supervised asks the user, unattended stops the run.
  - `semi-auto` or no `mode:` → **warn** and continue. Say which entries are open and that the
    remedy is to settle each one and mark it `- [x]`.
- `FORKS:unknown` → `task.md` has no *Open questions* heading, so nothing could be checked. Warn
  and continue in either mode.
- `FORKS:absent` → there is no `task.md` at all, though `plan.md` exists. Warn in either mode: this
  change has no contract, so the fork precondition could not be applied and neither can *Out of
  scope* later. Continue.
- `FORKS:none` → nothing is open. Proceed.
- `PHASE:not-a-repo` → stop.
- **`STATUS:planned`** → the plan was never grilled. Warn, name `/gantry:plan-grill` as the cheaper
  path, and continue if the user wants to. A warning, not a refusal.
- `PHASE:implement` → the normal entry, whether from `grilled` or resuming a previous
  `implementing` run. On a resume, read what is already changed (`git status`, `git diff`) before
  adding to it.
- `STATUS:implemented` or later → the work is done. Say so and name `NEXT` rather than redoing it.

Also read the reported **`GATES`** and **`HOOK`** lines. They tell you whether this run is actually
enforced or merely self-policed, and the report at the end must not blur the two.

### 2. Read the artifacts from disk

Read `plan.md` and `task.md` **as files**, now, even if you wrote them a moment ago. They are the
contract; your memory of them is not. In particular, re-read *Out of scope* — it is the boundary
you are working inside.

Take `mode:` from `task.md` frontmatter. It decides the gate's strictness and what a red gate does:
`semi-auto` and `auto` behave as **supervised**; `unattended` behaves as **unattended**.

### 3. Arm the gate

Set `task.md` frontmatter to `status: implementing` **before any edit**. (Hard rule 2.)

### 4. Carry out the plan

Work the steps in order. Keep to the plan; when a step turns out to be wrong — and it sometimes
does, which is the honest reason `grill` exists rather than a promise it never happens:

- **Supervised** → stop and raise it. A plan that survived a critique and still failed contact with
  the code is worth a human's attention, not a silent patch.
- **Unattended** → re-plan that step once, record the change and its reason in `plan.md`, and
  continue. Do not re-plan the same step twice; that is a blocked task, not a plan.

Match the target repo's conventions, not gantry's. Read neighbouring code before adding to it.

### 5. Run the gate

Capture the transcript, because step 5b reads it:

**Run one of these, never both** — they write the same `$log` and the same `rc`, so running the
block as written would let the strict result overwrite the supervised one and send a `NO-GATES`
repo down the exit-`3` row below instead of the exit-`0` one.

```bash
cd "$(git rev-parse --show-toplevel)"                 # pin the cwd; $log is built from it
bash "$GANTRY/lib/ensure_excluded.sh" .claude/artifacts/
log="$PWD/.claude/artifacts/gate-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
mkdir -p "$(dirname "$log")"
```

**The exclude line is not optional.** This step writes a file into the *target* repo's working
tree, and most target repos have no ignore rule for `.claude/artifacts/`. `gantry:ship` stages with
`git add -A` when nothing is staged, so without the exclusion the gate transcript is committed into
the pull request. `ensure_excluded.sh` is idempotent, so running it on every gate costs nothing.
Under `/gantry:auto-unattended` the driver has already written the same pattern; this is what
covers a standalone `/gantry:implement` and a supervised `/gantry:auto`, neither of which does.

```bash
bash "$GANTRY/lib/run_gates.sh" >"$log" 2>&1; rc=$?            # supervised — this one, or
bash "$GANTRY/lib/run_gates.sh" --strict >"$log" 2>&1; rc=$?   # unattended — this one. Not both.
```

**Redirect, then read `$?` on the same line. Never pipe.** `run_gates.sh ... | tee "$log"` yields
**`tee`'s** exit status, so a red gate reads as `0`, `status: implemented` gets set, and the run
ships a broken tree. That one exit code is this project's entire guarantee; a pipe silently
discards it.

**Run this script; never reimplement its logic inline, and never reason about whether a failure
"counts".** Its exit code is the contract:

| Exit | Meaning | What to do |
|---|---|---|
| `0` | green | continue to step 6 |
| `1`+ | a check failed | **supervised** → stop, show the output, hand it over. **unattended** → read the failure, make a focused fix, re-run. At most **2** fix attempts, then stop with `status: blocked`. |
| `2` | the gate could not run | stop and report in either mode. This is a broken environment, not a failed check — it must **not** consume a fix attempt. |
| `3` | `NO-GATES` under `--strict` | stop and refuse to go further. With nobody watching, code that ran zero checks must not reach a PR. Suggest adding `.claude/gates.sh`. |

Supervised with no gates detected (exit `0` and a `NO-GATES` notice) continues — but the report
must say plainly that this run had **no enforced checks**, which is a weaker result than green.

If a registered readiness hook and this inline run ever disagree, **the hook wins**. Never treat a
green inline run as permission to proceed past a hook that blocked.

### 5b. Ask what the gate actually read

A green gate that ran no check over any path this change touched exits `0` exactly like one that
proved something. That is not a reason to refuse it — it is a reason to stop reporting the two
identically:

```bash
bash "$GANTRY/lib/gate_coverage.sh" --transcript "$log"
```

Route on its `VERDICT`. **All six values have a row; an unmapped verdict is one that gets quietly
reported as ordinary green, which is the failure this step exists to prevent.**

| `VERDICT` | What it means, and what to say |
|---|---|
| `overlap` | The gate ran checks over paths this change touched. Ordinary green. |
| `no-overlap` | **Green-but-uncovered.** Still green, still exit `0`, nothing refused — but no check ran anywhere near the changed paths, so this run is not evidence about them. Report it as its own outcome, never as plain green. |
| `undeclared` | The repo owns its gate (`.claude/gates.sh`) and it does not declare what it covers. Report that it is undeclared; do not guess, and do not read it as either full or zero coverage. |
| `no-checks` | Nothing was detected to run. Pairs with the `NO-GATES` row above; not a new condition. |
| `no-changes` | The gate ran against an unchanged tree. Report it; it is not coverage. |
| `unknown` | The transcript carried no summary line, so the overlap could not be determined. Report exactly that — never as green-with-coverage. |

**This is a heuristic, and every report of it must say so.** A root is the directory a check was
*run in*, not the set of files it *read*. It errs both ways: a suite rooted in a subdirectory may
import from the repo root, and a check that ran at the root counts as covering every path while
possibly reading almost none of them. When `VERDICT` is `undeclared`, `unknown` or `no-checks`,
`COVERED: 0` means nothing could be *attributed*, not that nothing was covered.

**Nothing here changes an exit code or adds a refusal.** A zero-overlap gate still passes, under
`--strict` too. Making low overlap a failure would fire on every legitimate documentation-only
change; it is deliberately left undone.

### 6. Record the status

Only once the gate is green (or `NO-GATES` supervised, disclosed as such), set `task.md` to
`status: implemented`.

If you stopped red, leave it at `implementing` — or set `blocked` when the fix attempts ran out —
and say which. A status that claims more than the gate proved is the one lie this chain cannot
absorb.

## Report

What changed, file by file at a summary level. The gate: which mode it ran in, its exit code
verbatim, and how many fix attempts were used. Whether the readiness hook's firing conditions were
**met or unmet** on this run, taken from `HOOK` — and note what that value does not settle: the
detector cannot see whether the hook is registered, so met conditions mean the gate would have been
enforced *if* it is installed. A run whose conditions were unmet was certainly self-policed, and
saying so is the difference between a guarantee and a claim.

Then the gate's **coverage**, beside the exit code and never folded into it: the `VERDICT`, the
roots, and the changed/covered counts from step 5b, with the word *heuristic* attached. A
`no-overlap` run is reported as **green-but-uncovered** — green, and not evidence about this
diff. These are also the values the orchestrator writes into the journal's `gate` event, so
report them literally rather than in prose.

Any plan step that changed, and why. End by naming the next command: `/gantry:review --fix`.
