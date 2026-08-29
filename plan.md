# plan.md — fold review into ship, and gate the plan stage on settled forks

Two independent changes over the same file set. Steps 1–5 are item 1.3; steps 6–13 are item 2.5.
They can be read and reviewed separately; nothing in one depends on the other.

Revised after the grill pass. See **Grilled** at the end for what changed and why.

## The three decisions worth stating up front

**Where ship's review sits, and why it is not after the push.** Ship's flow is
commit → push → PR. The review stage goes **after the commit and before the push**, so anything it
fixes is corrected before a single byte leaves the machine. That is still "between commit and PR",
and it is the position that makes a fix cheap. Ship's stage detector routes callers straight into
the middle of the flow, so the review stage must be reachable from the `push` and `pr` entry
points too, not only from `commit` — and because it can create a commit, the push stage must not
decide from the detector read that happened before it.

**Why ship passes `--fix` when `skills/review` forbids it.** `skills/review` refuses `--fix` on
purpose: its triage step weighs each finding against `task.md`'s *Out of scope*, and `--fix` would
apply findings the contract excludes. That reasoning does not transfer to ship, and the two never
both run — the `--reviewed` guard guarantees it. Ship's review stage exists for the caller who
typed `/gantry:ship` on a small change with no contract on disk and no triage step to protect; for
them, "apply what a reviewer found, then re-prove it with the gate" is strictly better than no
review. Ship's prose says this out loud, and `skills/review` gains a sentence pointing at it, so
the two do not read as an accidental contradiction.

**What "settled" means, and where it is decided.** A fork is settled when its entry under
*Open questions* is a checked list item. That is a machine-checkable fact, so `lib/detect_stage.sh`
computes it once and every phase routes off the same answer — the same split the script already
uses for `GATES` and `HOOK`. The precondition is then enforced at **every transition that could
dispatch an implementer**, not at one point, because grill can open a fork that plan never had.

---

## Item 1.3 — a review stage inside ship

### Step 1 — Frontmatter and flags

In `skills/ship/SKILL.md`:

- `allowed-tools`: add `Skill`. Invoking `/code-review` requires it; ship currently has
  `Bash, Read` only. Do **not** add `Write`/`Edit` — ship still records nothing.
- `argument-hint`: add `[--reviewed]`.
- `description`: name the review stage and the flag. It is already the longest description in the
  repo, so keep the addition to one clause.
- Body: a `--reviewed` paragraph beside the existing `--no-pr` / `--base` / `--draft` ones.

**Check:** run `bash scripts/verify.sh` **immediately**, before any other step —
`claude plugin validate skills --strict` runs inside it, and a description it rejects must surface
now rather than under nine later steps.

### Step 2 — Insert the review stage and renumber

New **`### 3. Review the change`** between the current stage 2 (Commit) and stage 3 (Push).
Renumber Push → 4, Open the PR → 5, Done → 6, and fix every cross-reference to a stage number:
the `--no-pr` paragraph names "stage 4", the detector routing list names stages by number, and
stage 4's own text points at "step 5". Read the whole file after renumbering; the numbers are
referenced from prose the headings do not contain.

The stage body:

1. **Skip, and say so, if** `--no-pr` was given, or `--reviewed` was given. Nothing else — see
   step 3 for why the `status:` on disk is deliberately *not* consulted.
2. Otherwise invoke `/code-review <level> --fix` scoped to the branch diff, naming an effort level
   so two runs are comparable — `skills/review` makes the same point about an unnamed level
   reusing whatever was typed last.
3. If the invocation errors, `/code-review` is unavailable: report it **with the cause** and carry
   on to the push. Review is advice; a missing reviewer never blocks a ship.
4. **If `--fix` changed nothing, stop here** — no commit, no gate re-run. This is the common case
   and it must stay cheap.
5. If it did change something: commit those edits as their own follow-up commit, so the review's
   changes are legible separately from the change under review.
6. Then, and only then, re-run `bash "$GANTRY/lib/run_gates.sh"` and treat the exit code exactly as
   `implement` does. **Red stops the ship** — no push, no PR. Exit `2` is a broken environment;
   exit `3` is `NO-GATES`, non-fatal here because ship is not the strict-mode gate owner.
7. Because this stage may have created a commit, **re-run `detect_state.sh` before continuing.**
   Ship's step 1 says to continue 2 → 3 → 4 without re-detecting; that guidance predates a stage
   that can commit, and following it here would open a PR against a remote branch that does not
   contain the review's fix.
8. Record, for the report: whether the review ran, and what changed — file count from
   `git status`, not an invented finding tally (see step 4).

Ship's prose must **not** repeat the "before a byte leaves the machine" rationale in the `--no-pr`
paragraph: under `--no-pr` the push still happens and the review is skipped, which is what the
contract asks for but reads as a contradiction next to that sentence.

**Check:** the numbers run 1–6 with no gaps, and no paragraph refers to a stage by a number it no
longer has.

### Step 3 — The double-review guard is the flag alone

`skills/auto/SKILL.md` and `skills/auto-unattended/SKILL.md` both pass `--reviewed` when they
invoke ship, with one sentence saying why: the chain already reviewed, and reviewing twice would
let `--fix` apply findings `/gantry:review` deliberately deferred.

**The `status:` on disk is not part of the guard**, and ship's prose should say so in one clause.
Both drivers set `status: shipped` *before* invoking ship, for an unrelated reason — so on the
driver path a status test would be satisfied by something that is not a review, while `--reviewed`
does the real work. On the manual path it is worse than useless: a task left at `reviewed` from an
earlier run, then edited further and shipped again, would skip review of genuinely unreviewed code.
An explicit flag is the signal that is written down; a status is inferred.

**Check:** `grep -n 'gantry:ship' skills/auto/SKILL.md skills/auto-unattended/SKILL.md` shows
`--reviewed` on both.

### Step 4 — Report only what is verifiable

Nothing in this repo establishes that `/code-review` returns a machine-readable findings tally, or
that a findings count and an applied count are separable when `--fix` is passed. Ship reports what
it can actually observe: whether the review ran, and how many files `--fix` touched. A fabricated
count is worse than no count. `task.md`'s criterion is rewritten to match.

### Step 5 — Cross-reference from `skills/review`

One sentence in `skills/review/SKILL.md` where it forbids `--fix`, noting that `gantry:ship` does
pass `--fix` for the no-contract case and that the two are mutually exclusive via `--reviewed`.
Without it the next reader files the ship stage as a bug.

Also note in ship's report guidance: when a run stops after the push but before the PR (the
documented `GH:missing` / `unauth` case), the report must tell the user to re-run with
`--reviewed`, or the re-run reviews and edits an already-pushed branch a second time. Ship cannot
write, so it cannot remember; saying so is the honest fix.

---

## Item 2.5 — an open fork blocks the plan stage

### Step 6 — Make "settled" machine-checkable

`lib/detect_stage.sh` gains one reported line, `FORKS:`, with **four** values:

| Value | Meaning |
|---|---|
| `absent` | no `task.md` at `ROOT` |
| `unknown` | `task.md` exists but has no *Open questions* heading |
| `open` | the section holds at least one list item that is not checked |
| `none` | the section holds no list items, or every one is checked |

`unknown` exists because `lib/detect_stage.sh` explicitly supports a hand-written `task.md`.
Collapsing that case into `none` would let a mistyped heading silently disable the whole guarantee;
collapsing it into `open` would permanently block every hand-written task with no documented
remedy. Reporting it as its own value lets every consumer warn rather than guess.

Parser rules, written into the script's header comment because ambiguity is the whole of this
function's risk:

- **Heading**: an ATX heading at any level whose text is exactly `Open questions`, matched
  case-insensitively, trailing whitespace allowed.
- **Section end**: the next ATX heading at any level, or end of file. In this repo's own `task.md`
  the section is last, so EOF must terminate it.
- **Fenced blocks** (``` or `~~~`) inside the section are skipped entirely. Step 12 depends on
  this: the template has to show the convention without emitting a parseable unchecked item.
- **List item**: any line matching a `-`, `*`, or `+` bullet at any indentation, so nested items
  count.
- **Settled**: the item's text begins with a checked box. An unchecked box *or a bare bullet with
  no box* reads as open — a fork someone forgot to mark blocks rather than passing silently, which
  is the entire point of the item.

This is a new function; it does **not** touch `frontmatter_status()`, so the byte-identical-parser
diff `scripts/verify.sh` runs against `hooks/readiness-gate.sh` still holds — its extractor keys on
that function's own opening line and stops at its closing brace. `PHASE` and `NEXT` are unchanged:
the script reports the fact, the skills decide what it means.

**Check:** step 7's assertions, run via `scripts/verify.sh`.

### Step 7 — Test the parser in `scripts/verify.sh`

`scripts/verify.sh` **is** this repo's test harness — it is what CI runs, and it already carries
bespoke behavioural assertions (the parser-drift diff, the template/example parity diff). Step 6 is
the only real code in this change, so it gets committed assertions there, not a scratchpad run at
implementation time. This is not a new test framework and not the `tests/` tree this plan still
rejects.

A new `head2` block builds throwaway `task.md` fixtures in a temp dir, runs `lib/detect_stage.sh`
against each, and asserts the `FORKS:` value:

| Fixture | Expect |
|---|---|
| no `task.md` | `absent` |
| `task.md` with no *Open questions* heading | `unknown` |
| section with one unchecked box | `open` |
| section with one bare bullet, no box | `open` |
| section with only checked boxes | `none` |
| section holding only prose, no bullets | `none` |
| section whose only unchecked box is inside a fenced block | `none` |
| **unchecked boxes in *Acceptance criteria*, settled *Open questions*** | `none` |
| heading present but last in file, EOF-terminated | parsed, not skipped |

The bolded row is the plan's own stated catastrophic failure — a parser that leaks out of its
section blocks every run forever. Without a committed assertion, a later edit that reintroduces it
ships green.

**Check:** `bash scripts/verify.sh` reports the new block, and it fails if the parser is broken on
purpose.

### Step 8 — Define the precondition in `skills/plan`

In `skills/plan/SKILL.md`:

- Rewrite the last paragraph of *Ask, don't assume*. It currently tells a run with no human present
  to "choose the most conservative reading" and continue. Replace: record the fork as an unchecked
  item, leave it open, and **do not claim the plan is dispatchable**.
- The step that records status becomes the precondition: `status: planned` may be set only on
  `FORKS:none`. On `FORKS:open`, leave `status: planning` and report the forks — `planned` is the
  assertion that an implementer may be dispatched, and it is a lie while a fork is open. On
  `FORKS:unknown`, warn and proceed.
- The step that folds answers back in currently says to **clear** resolved forks from the section.
  That contradicts the new convention and must change to "mark them checked, with the decision on
  the line" — a deleted fork is indistinguishable from one never raised, which is exactly what the
  contract's *defines what resolved looks like on the page* exists to rule out.
- Document the checkbox convention where the section is described.
- The Report gains the open-fork count.

**Check:** `grep -n 'conservative' skills/plan/SKILL.md` returns nothing.

### Step 9 — Close the grill hole

`skills/grill/SKILL.md` today sets `status: grilled` unconditionally, and it tells a run with no
human present to "take the conservative reading" for a finding. Two changes:

- A critique finding that is a genuine design **fork** goes into *Open questions* as an unchecked
  item rather than being absorbed by a conservative reading.
- `status: grilled` may only be set on `FORKS:none`. If grill opened a fork, it leaves the status
  alone and reports it.

Without the second half, a fork grill opens flows straight past the drivers' post-plan check into
`implement`, and the unattended run dies mid-chain with no escalation event and no `blocked`
status — the exact failure the escalation path exists to prevent.

**Check:** `grep -n 'Open questions' skills/grill/SKILL.md` finds it.

### Step 10 — `implement` refuses on a dispatch, warns by hand

`skills/implement/SKILL.md` routes off `FORKS:open`:

- **`mode:` is `auto` or `unattended`** — a driver dispatched this. **Refuse.** This is the
  guarantee that an implementer is never dispatched against an open fork.
- **`mode:` is `semi-auto` or absent** — a human typed it. **Warn**, name the remedy (settle the
  entry or check it off), and continue.

The split is deliberate and matches the repo's stated principle that a hand-driven run may iterate
between phases, where "a stale or absent artifact is a normal state rather than an error". A blanket
refusal would lock a user out of `/gantry:implement` over a note they left themselves, with no
documented way back.

This is still a new refusal, so `skills/implement/SKILL.md`'s own *Two hard rules* heading and the
matching claim in `docs/SKILLS.md` must both be corrected rather than left asserting the opposite —
see step 13.

**Check:** the routing list names all four `FORKS:` values.

### Step 11 — Supervised asks; unattended stops

`skills/auto/SKILL.md`, after `/gantry:plan` returns **and again after `/gantry:grill` returns**:
if `FORKS:open`, one **AskUserQuestion** round covering every fork, answers folded into `task.md`
and `plan.md`, entries checked off, then the status advanced. The post-plan round is the cheap
moment; the post-grill round exists because grill can open a fork that plan never had.

`skills/auto-unattended/SKILL.md`, at the same two points: if `FORKS:open`, the run is **blocked**.
Journal an `escalation` event, set `status: blocked`, stop. There is no continuation branch and the
stage text must not offer one.

Both drivers describe their flow as `## Stage N` sections, not tables — neither contains a markdown
table. The new behaviour goes into those stage sections and into the **mode table** in
`skills/auto/references/orchestration.md`, which is the one real table. No tables are invented.

**Check:** `grep -nE 'otherwise|unless' ` over the unattended open-fork paragraph returns nothing —
no conditional continuation survives.

### Step 12 — Template, example, and the journal shape

- `skills/plan/templates/task.md` and `examples/task.md`: rewrite the *Open questions* section to
  state the precondition and the checkbox convention, and to carry the upstream phrasing — *the
  forks the implementer must not resolve alone* — as its one-line description. The heading itself
  stays `## Open questions`; other files point at that name.

  **The convention must be shown inside a fenced block.** A literal unchecked box in the template
  would make every freshly written `task.md` report `FORKS:open`, blocking every unattended run
  forever and prompting the user about a placeholder on every supervised one. Step 6's
  fence-skipping is the other half of this; both halves are required.

  **These two files must stay byte-identical** — `scripts/verify.sh` diffs them. Write one and copy
  it to the other; do not hand-edit twice.
- `skills/auto-unattended/references/journal.md`: the `escalation` event is documented as
  "reserved … nothing in gantry emits it". Something does now. Give it a shape and a worked
  example, and correct that sentence.

**Check:** `diff examples/task.md skills/plan/templates/task.md` is empty, and a `task.md` freshly
copied from the template reports `FORKS:none`.

---

## Step 13 — Documentation, including three invariants this change falsifies

The change contradicts statements the shipped docs currently make. These are not optional polish;
leaving them is shipping documentation that asserts the opposite of the behaviour.

- **`docs/SKILLS.md`** — "Two hard refusals, and only two — both `implement`'s" is falsified by
  step 10. "`ship` does **not** re-check the gate … What stops a red tree reaching a PR is
  `implement` … not `ship`" is falsified by step 2. Also the three-modes table and the
  `gantry:ship` entry that repeats `argument-hint`.
- **`skills/implement/SKILL.md`** — carries the "one of only two hard refusals in the chain" claim
  inline.
- **`skills/auto-unattended/references/delegation.md`** — "The gate is never delegated …
  `gantry:implement` runs it inline" is falsified by step 2's re-run.
- **`skills/auto/references/orchestration.md`** — *Reusing worktree and ship* enumerates the
  pass-throughs ("Pass `--no-pr`, `--base`, and (unattended only) `--draft` through") and must gain
  `--reviewed`. A driver reads this file at the start of every run, so an omission here re-arms the
  double review the guard exists to prevent. Its *Preconditions for unattended* bullet about
  `gantry:plan` describes the conservative-reading behaviour and must be rewritten. Its mode table
  gains the new row.
- **`docs/ARCHITECTURE.md`** — the `status:` state-machine diagram shows `blocked` branching only
  off `implementing`; steps 8 and 11 add `planning → blocked`. The *who invokes whom* diagram gains
  ship's review edge. The **ship state-machine diagram is left alone**: every node in it is a value
  `detect_state.sh` can emit, and the review stage is not an entry point — drawing it in would
  claim a `STAGE` that does not exist. A note under the diagram is the honest form.
- **`skills/ship/scripts/detect_state.sh`** — header comment restates
  `commit → push → open PR → wait`; it becomes `commit → review → push → open PR → wait`. Comment
  only; the `STAGE` vocabulary does not change.
- **`README.md`** — *The chain* section, and the skill table's `gantry:ship` flag list.
- **`CHANGELOG.md`** — `0.2.0` is unreleased, so both items fold into its existing **Added** and
  **Changed** sections rather than opening a new version.
- **`docs/METHOD.md`** — only if it describes ship's flow or the fork rule; leave it alone
  otherwise.

Every relative markdown link must still resolve, and no line-number citation may appear —
`scripts/verify.sh` checks both.

## Step 14 — Run the gate

`bash scripts/verify.sh` must exit 0.

---

## Test strategy

**Step 6 is real code and gets committed assertions** — step 7, inside `scripts/verify.sh`, which
is this repo's harness and what CI runs. Nine fixture cases, including the one that would otherwise
be catastrophic (the parser leaking into *Acceptance criteria*) and the one step 12 depends on
(fenced blocks skipped).

**Everything else is skill prose**, and no test framework is added for it. That is a real limit,
not a claim of coverage: what protects the prose is `scripts/verify.sh`'s existing static checks
(frontmatter/directory agreement, manifest validation, link resolution, template/example parity,
parser-drift diffing), the per-step `grep`/`diff` assertions above, and the two human reads in
`task.md`'s *How to verify*. A change that made ship's review stage read incoherently would pass
every automated check in this repo, and nothing here changes that.

## Risks

- **Renumbering ship's stages breaks a cross-reference.** The numbers are referenced from prose the
  headings do not contain. Step 2's check is a full read, not a grep.
- **The parser leaking out of its section.** *Acceptance criteria* is full of unchecked boxes; a
  parser that matched them would block every run permanently. Step 7's bolded fixture is the
  committed guard.
- **The template emitting a parseable unchecked item.** Would block every unattended run forever.
  Fenced block in step 12, fence-skipping in step 6 — both halves required, and step 12's check
  copies the template and reads the result back.
- **This task's own `task.md` is subject to the rule it introduces.** Its *Open questions* entries
  are checked items already; if that regressed, the implementer this plan dispatches would refuse.

## Grilled

A `gantry-critic` pass returned 20 findings — 6 blocking, 9 worth fixing, 5 noted. What changed:

- **Grill could re-open a fork after the only check** → steps 9 and 11: grill will not set
  `grilled` on an open fork, and both drivers check again after grill, not only after plan.
- **`FORKS` had no value for a `task.md` with no such section** → step 6 gains `unknown`, and the
  parser rules (heading match, section terminator, fences, nesting, bare bullets) are enumerated
  rather than left implicit.
- **The template would have emitted a parseable unchecked item**, blocking every future run → step
  12 fences the convention and step 6 skips fences. Both halves are now required and stated.
- **Neither driver has a stage *table*** — both are `## Stage N` prose → step 11 targets the stage
  sections plus orchestration's mode table, and invents no tables. The matching contract criterion
  was reworded.
- **Three shipped invariants are falsified by this change** (two in `docs/SKILLS.md`, one each in
  `skills/implement/SKILL.md` and `delegation.md`) → step 13 lists all of them.
- **The push stage decided from a pre-review detector read**, so a review commit could be left
  unpushed and the PR opened without it → step 2 item 7 re-detects.
- **The gate re-run was unconditional**, so ship would refuse to push in any repo with a
  pre-existing red suite → step 2 item 4 makes it conditional on `--fix` having changed something.
- **The disk half of the double-review guard was vacuous on the driver path and wrong on the manual
  one** → step 3 drops it; `--reviewed` is the whole guard.
- **A blanket `implement` refusal would lock out the hand-typed path** against the repo's own
  stated principle → step 10 refuses on a dispatch and warns by hand.
- **The no-test argument was sound for the prose and an excuse for the parser** → step 7 adds
  committed assertions to `scripts/verify.sh`, which was already the harness.
- **Four contract criteria were unfalsifiable** → rewritten as checkable in `task.md`.
- Smaller: report only observable counts, not an invented findings tally (step 4); tell the user to
  re-run with `--reviewed` after a degraded stop (step 5); do not repeat the
  "before a byte leaves the machine" rationale under `--no-pr` (step 2); leave the ship
  state-machine diagram alone and annotate it instead (step 13); validate ship's lengthened
  `description` immediately rather than at the end (step 1); correct the *Out of scope* sentence
  that understated what the detector change lets in.

Left deliberately: the plan still adds no test framework for skill prose, and says so above rather
than claiming coverage it does not have.

## Reviewed

`/code-review high` (tier 1, no `--fix` — this phase triages) returned 7 findings. All 7 were
inside this change's own footprint, so all 7 were fixed and none deferred; there is no
`handover.md`.

- **`ship`'s `allowed-tools` omitted `Write`/`Edit`/`Grep`/`Glob`.** The worst of the seven: a
  skill's frontmatter restricts rather than grants, so the new stage's `/code-review --fix` could
  not have applied a single byte — and step 1 of that stage reads "changed nothing" as a clean
  review and pushes. The feature would have shipped as a no-op that reported success. Added the
  tools `skills/review` already carries for the same reason, and said in the body why they are
  there despite ship writing no artifact of its own.
- **The parser failed *open questions closed*** in seven ways — `1. [ ]`, `1) [ ]`, `-[ ]` with no
  space, blockquoted items, and headings with a closing `##` run, a trailing colon, or bold
  wrappers all reported `none`. Every one is an undecided fork reading as settled, which is
  precisely the direction that must never fail. Rewrote the matching to accept ordered markers,
  optional spacing and blockquotes, and to tolerate those heading forms, while still excluding
  horizontal rules. All seven are now committed fixtures.
- **`auto`'s post-grill fork round stranded the status.** Grill leaves `status: planned` when it
  opens a fork, and unlike the post-plan round there is no phase behind stage 3 to repair it — so
  the chain would have reached `implement` claiming the plan was never grilled. Auto now writes
  `grilled` itself after settling.
- **`implement`'s `FORKS:` routing named only two of four values**, so `FORKS:absent` — no
  `task.md` with a `plan.md` present, a reachable state — passed the precondition unchecked.
- **Ship's documented exit `3` was unreachable**: `run_gates.sh` returns 3 only under `--strict`,
  which ship does not pass. In a repo with no detected checks the re-run returns `0` and the
  review's edits are pushed unproven. Replaced the wrong contract with that fact, and required the
  report to distinguish "the gate passed" from "there was no gate".
- **`--no-pr` skips the review but still pushes**, which the contract asks for but ship's own
  description contradicted. Kept the behaviour, fixed the description, and made the skip say
  plainly that it is the one path where something leaves the machine unreviewed.
- **A factual error in `docs/ARCHITECTURE.md`**: mermaid node ids (`commitst`, `prst`) described as
  values `detect_state.sh` emits. They are spellings of `commit` and `pr`; now said that way.
