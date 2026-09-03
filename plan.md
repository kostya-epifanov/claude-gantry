# plan.md — make ship's review deliberate, make review a thin wrapper

Two changes that look separate and are not. Removing ship's review stage only pays off if
`gantry:review` is worth invoking deliberately, and `gantry:review` can only become a thin,
tier-selectable wrapper once it stops having to explain why ship's copy of it behaves differently.
The whole `--fix` asymmetry that dominates both files today exists because two skills both ran
reviews under different rules. One of them stops.

Six decisions are settled and recorded in `task.md`'s *Open questions*. Three shape the steps below
more than the rest. **`--reviewed` is removed outright**, so the drivers change in this same commit
or they break. **The slot mechanism is not being built.** And **read-only means the code**: a bare
review still writes `task.md`'s status and still hands deferrals to `gantry:handover`, because the
status is what `detect_stage.sh` reads to know the chain has moved on.

## The shape of the work

This is a prose repo. Most of the files below are documentation, and the "implementation" is that
the SKILL.md files say the right thing precisely enough that a model executing them does the right
thing. Two consequences run through every step:

- **Almost nothing here is mechanically provable, but the part that is, is worth having.** Step 6
  wires two static sweeps into `scripts/verify.sh` — ship's SKILL.md contains no `/code-review`
  invocation, and `--reviewed` appears nowhere. That catches the regression that actually matters.
  Everything else is established by reading.
- **The context budget constrains wording**: 467 characters of headroom across all descriptions,
  with ship's and review's both being rewritten. Grilling put a number on it — ship sheds roughly
  110 characters of review clauses and needs perhaps 150 back, review perhaps 100 — so net ~+150
  against 467. Real, but not the tightest thing here, and `verify.sh` already runs the check.

## Steps

### 1. Strip the review stage out of `skills/ship/SKILL.md`

Remove stage 3 (*Review the change*) and renumber the stages that follow it. Then follow the
references — a removed stage that other paragraphs still point at is worse than one left alone:

- the `description:` frontmatter, which carries both "reviews them with /code-review unless the
  review is skipped" and "or `--reviewed` to skip the review";
- the `--reviewed` flag paragraph, deleted along with its entry in `argument-hint`;
- the `--no-pr` paragraph, which trades on "the one path where ship's own review is skipped and
  something still leaves the machine" — with no review stage, `--no-pr` is just commit-and-push;
- stage 1's routing table (`push` → "skip to stage 3", `pr` → "the review still has somewhere
  useful to land", `done` → "nothing left to review");
- the re-detect exception — see step 2, which is where it moves rather than dies;
- the Report section's review line and its `/code-review`-unavailable clause;
- the `gh missing`/`unauth` recovery advice that tells the user to re-run with `--reviewed`.

**Keep one paragraph the stage currently owns**: the explanation that skill frontmatter *restricts*
what is permitted while a skill is active, which is why ship carries `Write`/`Edit` despite writing
no artifact itself. Deleting it with the stage leaves ship's `allowed-tools` looking over-broad to
the next reader, and `--review-fix` becomes a silent no-op the moment someone trims it on that
reasoning. Move it to the new flags in step 2.

**Check:** renumbering is the trap here. The file refers to stages by number in roughly fourteen
places outside the headings — including `--no-pr`'s "skip stages 3 and 5" and two references to
"stage 5's disclosure checks", which after a one-place shift would route `--no-pr` straight past
the disclosure checks the file calls the whole point. Grep the body for stage numbers and read each
hit; "the headings are contiguous" is not the check.

### 2. Add `--review` and `--review-fix` to ship

Documented beside `--no-pr`, `--draft` and `--base`, in the same register: what it does, when to
reach for it, what it costs.

**The tier rides on the flag**: `--review=<tier>` and `--review-fix=<tier>`, bare forms meaning
`high`, mapped to `/gantry:review --tier <tier>` and `/gantry:review --tier <tier> --fix`. Ship
does not validate the tier — it forwards, and review owns the valid-value list, so the two skills
cannot grow copies that drift. Say what a rejected tier does to the run: review halts, ship has
already committed, and nothing has been pushed. That is a recoverable state, but only if the report
says so plainly.

**Grant the tools.** Ship's `allowed-tools` is currently `Bash, Read, Write, Edit, Grep, Glob,
Skill`. `gantry:review` needs `Agent` (its sub-agent fallback when `/code-review` is unavailable)
and `AskUserQuestion` (its triage round). Both must be added, or `--review` degrades to
self-review, and the ambiguous-finding round cannot run at all.

**Say where the review sits at every entry point.** This is what the old stage got for free by
always running, and it is the easiest thing to lose. Ship routes five ways, and "between the commit
and the push" only describes one of them:

- `commit` — the ordinary path: review between the commit and the push.
- `push` — nothing to commit, review before the push.
- `pr` — **already pushed.** There is no push to be "between". Either the review runs and any fixes
  it makes are committed and pushed before the PR is opened, or an explicitly requested review
  silently does not happen. Say which; the second is not acceptable for a flag someone typed.
- `done` / `no-diff` — say plainly that the flag does nothing here and why.

**Re-detect after either flag, not just `--review-fix`.** Both can move the tree: `--review-fix`
through its fixes, and `--review` through `handover.md`, which a read-only review still writes.
Everything downstream branches on `AHEAD` and `DIRTY`, so a read taken before the review pushes the
wrong thing or nothing at all.

**A blocking review stops the ship.** The old stage let a review be advisory because it always ran
and a missing reviewer must never block. A review someone explicitly asked for is different.

**Check:** `argument-hint` lists every flag; the prose names what happens on a failing review, on a
rejected tier, and at each of the five entry stages.

### 3. Rework `skills/review/SKILL.md` into the wrapper

Four changes, in the order they matter.

**Delete the `--fix` apologetics.** The paragraph beginning *"`gantry:ship` **does** pass `--fix`,
and that is not a contradiction"* describes a world with two reviewers in it. Removing it is most
of what makes this skill thin.

**Add `--tier <medium|high|xhigh|max>`, default `high`**, passed to `/code-review` in place of the
hardcoded `high`. Reject an out-of-set value by name rather than defaulting — a silent fallback
when someone typed `--tier maxx` buys nothing and hides the typo, and worse, an errored invocation
is exactly what this skill reads as "`/code-review` is unavailable", so a typo would silently
downgrade the run to a sub-agent. **`ultra` is refused by name**, keeping the reason the skill
already gives: it is billed and user-triggered. The existing prohibition stays, now as a case the
validator names rather than a loose warning.

**Fix the word "tier".** It currently names the three review *sources* — `/code-review`, sub-agent,
self-review — here, in `docs/SKILLS.md`, in both drivers, and in the unattended journal's "which
tier ran" summary. With `--tier` meaning effort, those two senses collide in the one line that is
supposed to record how independent the review was. Rename the source ranking (to *sources*, or
*fallbacks*) everywhere it appears, and keep `--tier` for effort. The ranking itself stays — the
fallback to `gantry-reviewer` and the disclosed self-review are correct and unaffected.

**Split reporting from writing.** Default becomes read-only *with respect to the code under
review*. It still writes `task.md`'s status — always, `--fix` or not, because that is the chain's
memory and `detect_stage.sh` is its only reader — and it still invokes `gantry:handover` for
deferrals. What `--fix` gates is the address-now edits and the gate re-run that must follow them.
`--fix` is still never passed through to `/code-review`; triage decides what the change absorbs,
which is the one piece of this skill that was always right.

**Check:** the skill reads as dispatch → verify → triage → act; the read-only default is stated
where a skimming reader hits it, and says explicitly what it does and does not cover.

### 4. Make verification a step, not an aside

Today the skill says *"check the findings against the repo yourself before acting"* — one clause
inside the source-ranking discussion, scoped to acting. It becomes its own numbered step between
getting the review and triaging it, and its scope widens: **a finding is verified before it is
reported, not only before it is fixed.** Read-only mode makes this load-bearing in a way it was
not before, since in that mode the report is the entire output and an unverified finding is the
whole of what the caller receives.

Concretely: each finding gets checked against the file it names before it counts as a finding. What
does not survive is dropped and counted, never listed. This folds into the existing "Drop" bucket
rather than inventing a parallel vocabulary — the difference is that dropping now happens before
the report, so the report cannot carry a claim nobody checked.

**Check:** the report's tally distinguishes findings that arrived from findings that survived.

### 5. Make the callers and docs agree

`--reviewed` being removed rather than deprecated makes this non-optional: the drivers pass a flag
that will no longer exist. Two edits per driver, not one — the review-phase paragraph matters more
than the ship invocation:

- `skills/auto/SKILL.md` and `skills/auto-unattended/SKILL.md` — **(a)** the `gantry:ship
  --reviewed` invocations and the "not optional here" justifications; the chain still must not
  double-review, so the drivers now call ship with no review flag at all, and *that* is the reason
  to state. **(b)** the review-phase paragraphs, which invoke `/gantry:review` bare and then
  describe it fixing in-scope findings, re-running the gate, and possibly setting `status:
  blocked`. Under the read-only default those descriptions become false and the chains stop
  applying findings. The drivers must pass `--fix`, and the paragraphs must say so.
- `skills/auto/references/orchestration.md` — flag table and ship delegation notes.
- `skills/auto-unattended/references/delegation.md` — the gate table's claim about ship's review
  stage changing the tree, and the journal's "which tier ran" summary (see step 3's rename).
- `README.md` — the `/gantry:ship` table row, and the `/gantry:review` row, which promises "fix
  what's in scope, hand over what isn't" as unconditional. **Leave the mermaid `if /code-review is
  absent` edge alone**: it runs from `/gantry:review` to `gantry-reviewer` and describes review's
  own fallback, which survives this change. The ship **node** is a separate matter and does go
  stale — it is labelled "commit, review, push, PR" and must lose the review. Both mermaid blocks
  carry such a node; so does `docs/ARCHITECTURE.md`.
- `docs/SKILLS.md` — **both** reference blocks. The ship block (argument line, the
  `--fix`-between-commit-and-push paragraph, the gate-recheck note) *and* the review block, whose
  argument line shows no flags, describes fixing and gate re-running as unconditional, and lists
  its invocations and scripts.
- `docs/ARCHITECTURE.md` — the "skipped entirely by `--no-pr` or `--reviewed`" note, the resume
  advice, and the surrounding paragraph that explains the whole re-detect fall-through rule in
  terms of "the review stage", which is now conditional on a flag.

**Check:** the scoped sweep from step 6 passes.

### 6. Wire the two sweeps into `scripts/verify.sh`

Decided during grilling, and cheap: the file already has this exact construction in its "no
leftovers from the extraction" check — a `repo_files` enumeration piped to `grep -InE`, failing the
build on any match.

1. `skills/ship/SKILL.md` contains no `/code-review` invocation.
2. `--reviewed` appears nowhere.

Both need the pathspec-exclusion idiom the existing check already uses, for `task.md`, `plan.md`
and `CHANGELOG.md` — the first two name the flag legitimately as this task's own artifacts, and the
changelog documents `ship --reviewed` as a shipped 0.3.x feature. **Rewriting that entry to satisfy
a grep would falsify the release record**; exclude the file instead.

**Check:** both sweeps fail before the change and pass after. Verify the first half — a check that
was never seen to fail is not known to work.

### 7. Changelog, version, and the gate

A `0.4.1` entry in `CHANGELOG.md` in the file's existing voice, and the matching version in
`.claude-plugin/plugin.json` (the only `version` field in the tree). The entry must say plainly
that this is a **breaking change** for anyone who typed `/gantry:ship` expecting a review, and that
`--reviewed` is gone. Add a new entry; do not edit the historical ones.

```bash
bash scripts/context_budget.sh    # diagnose the budget on its own
bash scripts/verify.sh            # everything CI runs, including the above
```

The budget check runs inside `verify.sh` already; running it alone first is a diagnostics
convenience, not extra coverage — its failure is the one whose remedy is rewriting two frontmatter
descriptions rather than fixing a bug, and it is easier to read on its own than buried among
fifteen headings.

**Check:** `verify.sh` exits 0.

## Test strategy

**What gets a test: two static sweeps, added in step 6.** Grilling overturned this section's
original answer. The plan had put all mechanical checking out of scope on the grounds that these
are prose skills — true, but it had missed that `scripts/verify.sh` already contains the exact
construction needed, so the check that catches the regression that matters costs one line each.

**What is still not tested, and why:** no harness executes a SKILL.md. Asserting on which sub-skill
a model actually chose to invoke at runtime needs machinery that does not exist here and would be a
larger project than the change it tested. So the sweeps prove ship's SKILL.md does not *contain* a
`/code-review` invocation; they cannot prove a model executing it does not perform one by other
means. That is a weaker claim, honestly weaker, and it is still the difference between a regression
failing CI and a regression shipping.

**What proves the rest, in descending strength:**

1. `scripts/verify.sh` — the two new sweeps, plus the existing coverage of the ways this change can
   break the plugin mechanically: malformed frontmatter, a dead relative link, a line-number
   citation, a description that busts the ceiling.
2. The stage-number sweep in step 1 and the routing walk in step 2. These catch the likeliest real
   defect: a dangling reference to a stage that no longer exists, or an entry point where an
   explicitly requested review quietly does not run.
3. The four human-only checks in `task.md` — including one specifically on the drivers, because the
   read-only default is the change most likely to regress them silently.

**The remaining gap, stated plainly:** nothing automated will notice if read-only review starts
writing to the code under review, or if the drivers stop passing `--fix`. Both are prose-level
regressions in files no test executes.

## Grilled

Critic: `gantry-critic`, dispatched cold against `task.md` and `plan.md`. 6 blocking, 7 worth
fixing, 4 noted. What changed:

- **Read-only collides with `handover.md` and the `status:` write** (blocking; two findings). The
  original AC said review "writes no file", but review invokes `gantry:handover`, and its status
  write is what `detect_stage.sh` reads to advance the chain. → Put to the user: read-only now
  means *the code under review*; artifacts are still written. AC reworded, *Out of scope* gained a
  clause, and step 2 gained the consequence — **ship must re-detect after `--review` too**, since
  `handover.md` moves the tree. The original plan asserted the opposite.
- **Both drivers invoke `/gantry:review` bare** (blocking). Under a read-only default the chains
  would stop applying findings and stop re-running the gate, silently. → Step 5 now names the
  review-phase paragraphs as a second edit per driver, and the drivers pass `--fix`. A new AC
  fixes the guarantee.
- **`--review` had no defined slot at three of ship's five entry stages** (blocking). "Between the
  commit and the push" does not describe `STAGE:pr`, where the branch is already pushed. → Step 2
  now enumerates all five.
- **The `--reviewed` sweep could never pass** (blocking). It matched `task.md`, `plan.md` and the
  changelog's own history of the flag. → Scoped to `skills/`, `docs/`, `README.md`, with the
  reason recorded, and step 6 carries the same exclusions.
- **Ship lacks `Agent` and `AskUserQuestion`** (worth fixing, and easy to miss). Review needs both;
  without them `--review` degrades to self-review. → New AC and a step 2 paragraph.
- **The `allowed-tools` rationale would have been deleted with stage 3** (worth fixing). → Step 1
  now explicitly preserves and relocates it.
- **The README edit was half wrong** (worth fixing). The `if /code-review is absent` edge belongs to
  `/gantry:review`, not ship; deleting it would have removed correct documentation. The
  `/gantry:review` table row, which the plan had not listed, is the thing that goes stale. → Step 5
  corrected in both directions.
- **`docs/SKILLS.md`'s review block was unlisted** (worth fixing). → Added.
- **Stage renumbering has ~14 body references** (worth fixing), including two that would route
  `--no-pr` past the disclosure checks. → Step 1's check rewritten; "headings are contiguous" was
  not a check.
- **The `verify.sh` guard is one line, not a project** (worth fixing). → Overturned the test
  strategy; new step 6, and *Out of scope* narrowed to exclude only a SKILL.md-executing harness.
- **"tier" already means the three review sources** (worth fixing). → Step 3 renames the source
  ranking and keeps `--tier` for effort.
- **The contract overstated what was automated** (worth fixing). → *How to verify* now says which
  criteria are mechanical and which are read, and gained two human-only checks.
- **`docs/ARCHITECTURE.md` needs more than the two named clauses** (noted). → Step 5 widened.
- **Ship's `description:` was unlisted** (noted). → Added to step 1.

Left, with reasons:

- **The tier vocabulary `medium|high|xhigh|max` (blocking, overruled).** The critic could only
  check what this repo says, and found `xhigh`/`max` asserted nowhere while `ultra` appears as a
  real value. The set is correct — these are `/code-review`'s effort levels, with `ultra` a
  separate cloud mode. The half of the finding that stands is that the `ultra` prohibition must
  stay coherent with the new validator, and step 3 now handles it by name.
- **A rejected tier halts after ship has committed** (noted). Recoverable, and step 2 now says the
  report must make the state plain. Not worth pre-validating in ship at the cost of two copies of
  the valid-value list.
- **The budget may not be the tightest constraint** (noted). Fair. Step 7 keeps the check but no
  longer bills it as the top risk, and the framing in *The shape of the work* is now quantified.
