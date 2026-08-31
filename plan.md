# Plan — make the draft PR body disclose what the run did not prove

Three disclosures, in dependency order: the detector line first, because everything downstream
reads it; then ship, which composes all three into the body; then the journal and the driver, which
record that the disclosure was made; then the by-hand disclosure this change owes its own pull
request. Steps 1 and 2 are testable by the gate. Steps 3 through 7 are prose in skill bodies, which
the gate can only check for shape — that asymmetry is the point of step 9.

## Step 1 — a `human_only` reader in `lib/detect_stage.sh`

**What changes.** A new function, `human_only_state()` — named for what it returns, which is a
state and not the entries — and a new output line `HUMAN_ONLY:present|none|absent` emitted
immediately after `FORKS:`. The header comment block gains a matching entry.

**Where.** `lib/detect_stage.sh`. The function goes after `open_questions_forks()` and before the
`--- artifacts ---` section. The `echo` goes directly below the `FORKS:` echo. `PHASE:` stays the
last line printed.

**The parser, and why it is separate.** `frontmatter_status()` is duplicated byte-for-byte into
`hooks/readiness-gate.sh` and the gate slices both copies out by brace and compares them. Nothing
in this step may touch it. The new reader shares no code with it, exactly as `open_questions_forks()`
already does not.

Rules, to be written into the function's comment block:

- **The key** is a line whose first non-blank content is `human_only:`, at any indentation, looked
  for **anywhere in the file** — not only inside a fence and not only under *How to verify*. Fences
  are **not** invisible to this reader, unlike the fork reader, because the block's canonical home
  *is* inside a fenced `verification:` block; a reader that skipped fences would never find it.
- **Inline content** on the key line itself — the flow form `human_only: ["a check"]` — counts as
  entries unless what follows is empty or an empty collection.
- **Entries** are the following lines whose first non-blank character is `-`, at an indentation
  **greater than or equal to** the key's. Greater-or-equal, not greater: YAML permits a block
  sequence at the same indentation as its key, and requiring deeper indentation would report a
  populated list as `none` — a failure in the one direction this must never fail in.
- **Continuations.** A more-indented line that is not a bullet belongs to the entry above it. That
  is how this repo's own multi-line quoted entries are written.
- **The block ends** at the first non-blank line that is neither a bullet nor a continuation and is
  indented at or less than the key — a sibling YAML key, a closing fence, a heading — or at end of
  file.
- **Multiple occurrences: `present` wins.** The whole file is scanned and the strongest result is
  reported. A `task.md` that quotes the template in prose before carrying its real block must not
  report on the quotation.
- **Values.** `present` when at least one entry is found anywhere; `none` when a key is found but
  no entries; `absent` when no key is found, or there is no `task.md`. `absent` deliberately
  conflates "no file" and "no block" — both mean nothing to disclose, and the already-printed
  `TASK:` line separates them for any reader who cares.

**Every permissive case fails toward `present`.** An unterminated fence does not stop the scan; an
entry that will not parse still counts as an entry; a key outside the expected block is still a key.

**How I will know it worked.** `bash lib/detect_stage.sh` in this worktree prints
`HUMAN_ONLY:present`; `tail -1` of its output is still the `PHASE:` line; `bash scripts/verify.sh`
still reports the duplicated frontmatter parser as identical.

## Step 2 — a test case for the states, and for line order

**What changes.** A new file, `tests/cases/stage_human_only.sh`, discovered by `tests/run.sh`'s
glob with no registration step. **It ends with `finish`** — without that call a case prints `FAIL`
lines, exits 0 anyway, and the suite reports PASS, which would make the regression below assert on
nothing.

**Where.** `tests/cases/`. It sources `tests/lib.sh`, builds a fixture with `mkrepo`, writes
`task.md` bodies with `write_task_raw`, and asserts on `STAGE_OUT` with `assert_contains`.

Cases:

- a populated list inside a fenced `verification:` block → `present`
- **a block sequence at the same indentation as its key** → `present` (the blocking case above)
- the flow form `human_only: ["a check"]` → `present`
- the key with an empty list → `none`
- `human_only: []` → `none`
- a `task.md` with no such key → `absent`; no `task.md` at all → `absent`
- the block last in the file, terminated by end of file → `present`
- a sibling key at the key's indentation ends the block → `none` when the list was empty
- a prose mention earlier in the file plus a real block later → `present`
- multi-line quoted entries, the shape this repo's own `task.md` uses → `present`
- the task template copied verbatim → **`none`** (see step 5)

Plus one assertion that is not about `human_only` at all: **the last line of `STAGE_OUT` begins
`PHASE:`.** `assert_contains` is a substring test over the whole output, so it would pass equally
for a line appended after `PHASE:` — which would break the header's promise and the criterion that
no line is reordered.

**How I will know it worked.** `bash tests/cases/stage_human_only.sh` exits 0, and exits non-zero
when the new `echo` is deleted from the detector.

## Step 3 — the executing-plugin disclosure in ship

**What changes.** A new block in stage 5 of `skills/ship/SKILL.md`, before the body is composed.

**Where.** `skills/ship/SKILL.md`, stage 5.

**Three gate conditions, all cheap, all commands.**

1. **Is the repo a plugin?** `.claude-plugin/plugin.json` at the repo root. If absent the whole
   check is inert — this is what keeps an ordinary target repo with a `lib/` directory from
   producing a nonsense disclosure.
2. **Did the plugin's own behaviour change?** `git diff --name-only <base>...` shows a path under
   `skills/`, `lib/`, `hooks/` or `agents/`.
3. **Is the executing plugin root the same tree as the repo?** Compare the resolved real paths. If
   they are the same — the `--plugin-dir` shape, which `CONTRIBUTING.md` documents as the way to
   test a change locally — then **the edited skills did execute**, and the disclosure is
   *suppressed*, not stated. Emitting "untested by this run" there would itself be the false
   mechanism claim step 6 exists to strike.

**Two classes of changed path, because one sentence is false for one of them.** This is the
correction that matters most:

- `skills/` and `agents/` are **loaded by the harness from the installed plugin**. Edits to them did
  not execute this session at all.
- `lib/` and `hooks/` are **executed from the worktree by the repo's own suite** — `tests/lib.sh`
  points at the worktree's copies, so `bash tests/run.sh` runs the edited scripts. They were
  exercised; what did not happen is that the *running plugin's* copies were the edited ones.

A body that says "untested by this run" about a `lib/` change is wrong, and this very change edits
`lib/detect_stage.sh`.

**Resolving what executed.** From a command, never a guess. The skill's own location gives the
running plugin root; the user-level installed-plugins record maps an install path to a version and
a commit. Three outcomes, all of which the skill names:

- the root matches an installed cache entry → name that version and commit;
- the root resolves but matches no recorded install → say which root executed and that it
  corresponds to no recorded version;
- nothing resolves → **"could not determine the executing plugin version"**, verbatim. A legitimate
  disclosure, never omitted and never replaced by a guess.

**`--no-pr` does not skip this.** Stage 5 is skipped wholesale under `--no-pr`, but the push still
happens, so the checks run anyway and the **report** carries them. Otherwise a `--no-pr` run pushes
a change to `skills/` and `lib/` with no disclosure anywhere.

## Step 4 — the fixed heading, and what draft does not mean

**What changes.** Stage 5 of `skills/ship/SKILL.md` composes a fixed heading into the body.

**Where the input comes from — the gap the plan previously had.** Ship's stage 1 runs
`skills/ship/scripts/detect_state.sh`, which reads git state and **never reads `task.md`**. So the
step names its own command explicitly: `bash "$GANTRY/lib/detect_stage.sh"`, read for `HUMAN_ONLY:`.
Without this the rule can never fire and nothing would reveal that.

**The rule.** On `HUMAN_ONLY:present` the body carries a heading of exactly `## Not proven by this
run`, and under it the entries from `task.md` verbatim. The heading is fixed so its **absence** is
information: a reader who knows it exists can tell "nothing to disclose" from "nobody wrote it
down".

**One source of truth, and what to do when the two disagree.** The detector line decides *whether*
the heading is emitted; `task.md` supplies the *text*, because the entries are multi-line and one
labeled line per value is the detector's whole output contract. If the detector says `present` and
no quotable entries can be found, **emit the heading anyway** and say the block could not be read.
Failing toward the disclosure is the point.

**What draft does not mean.** Whenever `--draft` was passed, the body says plainly: **draft means
unwatched, not unverified.** This is conditioned on `--draft`, *not* on the heading — a draft with
no `human_only` entries still needs it, and a ready PR that happens to have entries does not.

The executing-plugin sentence from step 3 lands under the same heading. It is the same kind of
claim, and one heading is easier to look for than two.

## Step 5 — stop the template from making the heading meaningless

**What changes.** The `human_only` placeholder in `skills/plan/templates/task.md` becomes a YAML
comment, and `examples/task.md` gets the identical edit — `scripts/verify.sh` diffs the two and
they must stay byte-identical.

**Why.** The template ships a live entry. Every `task.md` written from it would report `present`,
so every gantry pull request would carry the heading with placeholder prose under it — which
destroys precisely the property step 4 is built on. The fork checkbox has the same problem and the
template already solves it by fencing the example; that trick is unavailable here, because this
block's canonical home *is* a fence and the reader must see into fences to find it. A comment is
the equivalent move.

**How I will know it worked.** The template copied verbatim into a fixture reports `none`, pinned
by step 2's case.

## Step 6 — ship re-reads its own prose

**What changes.** A re-read step in `skills/ship/SKILL.md`, in **two** places, because one of the
three artifacts is already on the remote by the time the other two exist.

**The rule**, stated once and concretely:

> A claim about **how something works** either cites the file that establishes it, or it does not
> go in the body.

Anything unsupported is **struck, not softened**. "Appears to" is still an assertion nobody
verified.

**Where, and why two places.** Ship's order is commit (2) → review (3) → **push (4)** → open PR (5).

- **The commit subject is checked in stage 2, where it is written** — before anything is pushed,
  when `git commit --amend` is free.
- **The title, body and the subject as shipped are re-read in stage 5**, immediately before
  `gh pr create`. A subject found faulty *there* is already on the remote, and stage 4 forbids
  force-pushing to fix a remote-side problem; the stated remedy is to correct it in the body, never
  by rewriting history.

This is a checklist the driver applies in its own context, not a dispatched sub-agent.

**Why review was not extended instead — recorded in the skill.** `/gantry:review` runs against the
diff, before ship has composed a title, a body or a commit message. Extending its scope means either
running it a second time after composition or moving it after composition, and both cost more than
the check is worth. The reasoning goes in the skill body so a later reader does not undo it.
`skills/review/SKILL.md` is not touched.

## Step 7 — the journal event and the driver

**What changes.** A sixth event shape in `skills/auto-unattended/references/journal.md`, and the
line in `skills/auto-unattended/SKILL.md` that appends it.

**The shape.** A new `event` value rather than a field on an existing one — the file's own extension
guidance prefers that — carrying a `kind` field as its extension point the way `escalation` carries
`reason`, so the executing-plugin and unproven-criteria disclosures are two values rather than two
event types.

**Where the driver gets its facts.** From **ship's report**, which steps 3 and 4 now require to
carry both disclosures. Not re-derived, and never invented: this is an append-only log that the
project describes as evidence.

## Step 8 — this change's own disclosure, by hand

**What changes.** Nothing in the repo. This step exists so the work is assigned rather than merely
observed.

The ship that opens this pull request is the installed plugin, which does not have steps 3, 4 or 6.
So the executing-plugin disclosure, the `## Not proven by this run` heading, and this `task.md`'s
`human_only` entries are written into the body **by hand**, and the body says that is what was done.
Under the two classes from step 3: the `skills/` changes did not execute; the `lib/` change *was*
executed by `tests/run.sh`, and the body says so rather than overclaiming.

## Step 9 — the gate, and the honest limit

Run `bash scripts/verify.sh`. It is `.claude/gates.sh`, so it is the gate, and it includes
`bash tests/run.sh`.

**What the gate does not prove, stated here so it is not discovered later.** Steps 3 through 8
change skill bodies and documentation. The gate proves they parse, that frontmatter validates, that
no link rots, that the frontmatter parser has not drifted, that the template and its example agree,
and that the detector change works — which is real, and is the whole of steps 1, 2 and 5.

It proves nothing about steps 3, 4, 6, 7 and 8 beyond shape. In particular
`scripts/context_budget.sh` counts frontmatter `description:` characters **only**; the 500-line body
rule is house style enforced by no script, so it is checked with `wc -l` and reported that way
rather than claimed as a gate result.

## Step 10 — CHANGELOG and the ship documentation

**What changes.** An entry in `CHANGELOG.md`, matching recent repo practice, and a short addition to
the `/gantry:ship` section of `docs/SKILLS.md`, which describes ship's stage machine and would
otherwise silently omit a new user-visible pull-request-body behaviour.

## Test strategy

**Gets a test:** the detector line, in every state plus the shapes that would let it report `none`
for a populated block — the same-indentation sequence above all, which is the case that would have
shipped broken. Plus the line-order assertion. That is the only new behaviour a script can execute.

**Does not get a test, and why:** the prose steps. No harness in this repo composes a pull request
body, and building one to assert on model-authored prose would test the wrong thing — a body
containing the right heading is not a body containing a true disclosure. The acceptance criteria for
those steps are read rather than run, and `task.md`'s `human_only` block records the two readings a
person still has to make.

**The regression that matters:** deleting the new `echo` from `lib/detect_stage.sh` must make
`tests/cases/stage_human_only.sh` exit non-zero. That requires the `finish` call; without it the
case cannot fail.

## Grilled

The critic read `task.md` and `plan.md` cold and returned 18 findings — 5 blocking, 10 worth
fixing, 3 noted. Every blocking finding was folded in; none opened a design fork.

- **The parser's entry rule reported `none` for a populated list** — YAML permits a block sequence
  at the same indentation as its key, and the rule required deeper indentation. This is the exact
  direction the design says it never fails in, and none of the three existing `human_only` blocks
  uses that shape, so no fixture would have caught it → rule changed to greater-or-equal, flow form
  handled, and both shapes pinned by step 2.
- **Ship had no source for `HUMAN_ONLY:`** — ship runs `scripts/detect_state.sh`, which never reads
  `task.md`, so the rule could never have fired and nothing would have revealed it → step 4 now
  names `lib/detect_stage.sh` explicitly.
- **The commit-subject re-read was scheduled after the push** → split across stages 2 and 5, with
  the remedy for an already-pushed subject stated rather than left to a force-push.
- **The `--plugin-dir` shape falsifies the premise** — there the edited skills *do* execute, so the
  disclosure would have lied → step 3 gained a same-tree check that suppresses it.
- **`lib/` and `hooks/` are executed from the worktree by `tests/lib.sh`** — so "untested by this
  run" is false for them, and this change edits `lib/detect_stage.sh` → two classes, phrased
  separately. This was the finding with the sharpest teeth: the plan would have published the very
  claim step 6 exists to strike.
- **The template's live placeholder would put the heading on nearly every PR** → step 5 added,
  comment-out in both template and example.
- **`assert_contains` cannot catch a line appended after `PHASE:`**, and a case without `finish`
  exits 0 however many assertions failed → both added to step 2.
- **`--no-pr` skipped stage 5 and with it the whole disclosure** → step 3 runs the checks anyway and
  the report carries them.
- **"Draft means unwatched" was nested under a conditional heading** → conditioned on `--draft`.
- **Two parsers could disagree about entries** → one source of truth named, disagreement resolved
  toward emitting the heading.
- **The driver had no way to know the disclosure was made** → it reads ship's report.
- **No step owned this change's own by-hand disclosure** → step 8.
- **The gate does not check body line count**, though the plan claimed it did → corrected in step 9
  and in `task.md`; `wc -l` named instead.
- Noted and taken: the three-dot form in the `skills/review` verify command; a `CHANGELOG.md` entry
  and a `docs/SKILLS.md` line (step 10); `human_only_entries()` renamed `human_only_state()` for
  what it actually returns.
- Confirmed clean by the critic, so not re-checked: the insertion point, `extract_fm`'s immunity to
  a new function nearby, test discovery by glob, the `tests/lib.sh` helper signatures, step 7's
  placement, and the absence of any doc enumerating the detector's output lines.
