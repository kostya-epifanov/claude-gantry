---
id: 2026-08-31-ship-discloses-what-was-not-proven
title: Make the draft PR body disclose what the run did not prove
project: claude-gantry
branch: feat/ship-discloses-what-was-not-proven
mode: unattended          # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

For an unattended run, the draft pull request body is the entire interface to the reviewer.
Nobody watched the run; nobody will re-derive it. Whatever the body says is what the change is
taken to be. Three things it must say are, today, unsayable — not because a driver forgets them
but because nothing in the chain computes them.

**A change to the plugin's own files is not exercised by the run that makes it.** Phase skills
execute from the installed plugin cache, not from the worktree being edited. A measured case in
this repo: the lane that produced an earlier pull request edited `skills/ship/SKILL.md` to add a
review stage and a `--reviewed` flag, then invoked `/gantry:ship --reviewed`, which ran the *old*
ship — no review stage, and the flag silently ignored. The headline feature of that change was
never once executed by the run that shipped it, and the run reported success. Nothing was lying;
nothing was looking. The disclosure has to be computed from the diff, not remembered.

**Nothing reads the prose ship writes.** `grill` reads `task.md` and `plan.md`. `review` reads the
diff. The commit message and the pull request body are composed last, by the context most invested
in the result, and no phase reads either. One lane in this batch published two false mechanism
claims in a pull request body — an assertion about what armed the readiness hook, and an assertion
about where the detector sourced one of its output lines. Both were wrong, both were caught by a
human peer rather than by any phase, and correcting them cost three commits and two rewrites of the
body.

**`human_only` is decorative.** `task.md` carries a `human_only` list under *How to verify* — the
checks no automated gate can make. It appears in the task template, in the worked example, and in
this repo's own `task.md`, and nowhere else: no script parses it, no skill reads it, no journal
event carries it. The batch's sharpest case is a lane wiring a privileged gate to a chat-based
approval transport whose acceptance test needs a phone, a bot, and a fifteen-minute wait. That test
has never been observed passing. The gate went green anyway, and a driver that silently skipped the
disclosure would produce a run indistinguishable from one that made it.

All three are **disclosures, not refusals**. Nothing here blocks a push, fails a gate, or withholds
a pull request. The goal is that a reviewer opening a draft can see what the run did not establish,
without having been in the run.

## Acceptance criteria

### Untested-plugin-change disclosure

- [ ] When the diff against the base touches `skills/`, `lib/`, `hooks/` or `agents/` **and** the
      repository being worked on carries `.claude-plugin/plugin.json`, ship's report and the pull
      request body both name the plugin version that actually executed.
- [ ] The disclosure distinguishes two classes of changed path, because they are untested in
      different senses and one blanket sentence is false for one of them: `skills/` and `agents/`
      are loaded by the harness and genuinely did not run this session, while `lib/` and `hooks/`
      are executed from the worktree by the repo's own test suite but not as the running plugin's
      copy.
- [ ] The disclosure is suppressed, rather than stated, when the executing plugin root and the
      repository root are the same tree — the `--plugin-dir` shape, in which the edited skills
      **did** execute. Claiming otherwise would be the false mechanism claim this change exists to
      prevent.
- [ ] The executing version is resolved from a command, not a guess. Where it cannot be resolved,
      the body says the executing version could not be determined — the disclosure is never omitted
      and never invented.
- [ ] In a repository with no `.claude-plugin/plugin.json`, the check is inert: an ordinary target
      repository that happens to have a `lib/` directory produces no such disclosure.
- [ ] `skills/ship/SKILL.md` names the command that supplies the disclosure's inputs. Ship's own
      `scripts/detect_state.sh` reads git state and never reads `task.md`, so the step that needs
      `task.md` says which script it runs.

### Ship re-reads its own prose

- [ ] `skills/ship/SKILL.md` has an explicit re-read step positioned before `gh pr create` that
      covers the composed title, the body **and** the commit subject.
- [ ] The commit subject is additionally checked where it is written, before the push, because the
      re-read before `gh pr create` happens after the push and history is not rewritten to fix a
      subject. The skill states that remedy — a subject already pushed is corrected in the body,
      never by force-pushing.
- [ ] That step names the specific failure it exists for — an unsourced claim about how something
      works — rather than asking generically for accuracy. The rule it states is that a mechanism
      claim either cites the file that establishes it or does not go in the body.
- [ ] `skills/review/SKILL.md` is unchanged by this task, and the reason review was not extended
      instead is written down in `skills/ship/SKILL.md` where the next reader will find it.

### `human_only` becomes a fact

- [ ] `bash lib/detect_stage.sh` prints a new labeled line reporting whether the `human_only` block
      is non-empty, for each of three inputs: a `task.md` with a populated list, one with an empty
      list, and one with no such block at all.
- [ ] The new line is documented in the header comment block of `lib/detect_stage.sh` alongside the
      other output lines, and no existing output line is renamed or reordered.
- [ ] `frontmatter_status()` in `lib/detect_stage.sh` stays byte-identical to the copy in
      `hooks/readiness-gate.sh`, and the divergence check in `scripts/verify.sh` passes.
- [ ] The reader for the new line is a separate function from `frontmatter_status()`, its rules are
      written down in a comment, and every permissive case is permissive in the direction of
      reporting the block as present.
- [ ] A pull request body composed for a task with a non-empty `human_only` list carries a fixed
      heading and the entries verbatim, and `skills/ship/SKILL.md` states that the heading's
      absence is itself meaningful.
- [ ] One source of truth is named for the entries. The detector line decides **whether** the
      heading is emitted; `task.md` supplies the **text**. Where the two disagree, the skill says
      to emit the heading and record that the block could not be read.
- [ ] A `task.md` freshly written from the task template reports `none`, not `present`. A heading
      that appears on every pull request quoting placeholder prose destroys the property that its
      absence is meaningful.
- [ ] The pull request body says plainly what draft status does not mean — draft means unwatched,
      not unverified — whenever `--draft` was passed, independent of whether the `human_only`
      heading is present.
- [ ] The journal reference documents an event recording that a run shipped with unproven
      acceptance criteria, and the unattended driver appends it from what ship reported rather than
      re-deriving or inventing it.

### Gate and house style

- [ ] A test case covers the three `human_only` states, ends by calling `finish` (without it a case
      prints failures and still exits 0, so the suite reports PASS), and asserts that the detector's
      **last** line still begins `PHASE:` — a substring assertion alone cannot catch a new line
      appended in the wrong place.
- [ ] `bash scripts/context_budget.sh` exits 0. Note that it counts frontmatter `description:`
      characters only; the 500-line body rule is house style enforced by no script, so it is
      checked with `wc -l` and reported as such rather than claimed as a gate result.
- [ ] Every skill body stays under 500 lines, verified by `wc -l`.
- [ ] `bash tests/run.sh` and `bash scripts/verify.sh` both exit 0.

## How to verify

```yaml
verification:
  automated:
    lint: true              # bash -n + shellcheck, via scripts/verify.sh
    tests: true             # tests/run.sh, invoked by scripts/verify.sh
  human_only:
    - "Read the composed pull request body for this very change: it must itself carry the
       untested-plugin-change disclosure, because the ship that opens it is the installed
       plugin and not this worktree. A body that omits it has failed its own acceptance
       criteria in the most visible way available."
    - "Read the re-read step in ship end to end and judge whether a driver mid-run, already
       invested in the result, would actually strike a claim on reading it. A checklist that
       reads as encouragement rather than as a rule will be complied with and change nothing."
```

```bash
bash scripts/verify.sh                       # the gate; must exit 0
bash tests/run.sh human_only                 # the three states of the new detector line
bash lib/detect_stage.sh | tail -1           # must still be the PHASE: line
git diff --stat master... -- skills/review   # must be empty (three-dot: the merge base)
wc -l skills/*/SKILL.md                      # house style, checked by no script
```

## Out of scope

- **Reloading skills from the worktree mid-session.** The cheap disclosure is the whole of this
  task. Making the edited skills actually execute may not be supported by the harness at all.
- **Blocking, refusing, or failing anything** on any of these three conditions. They are
  disclosures. No push is withheld, no gate turns red, no pull request is refused.
- **Any change to the triage behaviour of `/gantry:review`, or to its prohibition on `--fix`.**
  That skill is untouched.
- **Post-hoc editing of an already-open pull request body.** The disclosure is composed before the
  pull request is opened or it does not exist.
- **A new reviewing sub-agent.** The prose re-read is a checklist the driver applies, not a
  dispatch.
- **`frontmatter_status()` in either copy.** It is diffed byte-for-byte by the gate; the new reader
  is a separate function.
- **`scripts/verify.sh`'s unguarded fixture directory**, which review surfaced: a pre-existing bug
  in code this change does not touch, where a failed `mktemp` makes part of the suite pass for the
  wrong reason. Deferred to `handover.md`.

## Affected areas

- `skills/ship/SKILL.md` — the three composition-time changes land here: the plugin-version
  disclosure and the fixed unproven-criteria heading in stage 5, and the prose re-read step
  immediately before `gh pr create`. Currently 230 lines against a 500-line ceiling, so there is
  room, but the additions must be tight. Stage 5 is short and the commit message is written back in
  stage 2, so the re-read step has to reach backwards to the subject composed there.
- `lib/detect_stage.sh` — a new reader function and a new output line. Two hazards. The first is
  `frontmatter_status()`, duplicated verbatim into `hooks/readiness-gate.sh` and compared by slicing
  the function body out of both files; the slice is brace-delimited, so even the shape of its
  opening and closing lines is load-bearing. The new reader must not touch it — the existing
  `open_questions_forks()` is the precedent for a wholly separate parser. The second is that the
  header comment block documents the output contract and ends by promising `PHASE` is the final
  line, so the new line goes before it.
- `skills/auto-unattended/references/journal.md` — five event shapes are documented, and the file
  explicitly prefers a new `event` value over overloading an existing one. A sixth shape is added.
- `skills/auto-unattended/SKILL.md` — the driver appends the new event at ship, and its report
  section gains the disclosure.
- `tests/cases/` — cases are standalone scripts sourcing `tests/lib.sh`, which supplies the fixture
  repo and the assertion helpers; `tests/run.sh` globs the directory, so a new file is discovered
  with no registration step.
- `scripts/verify.sh` — already carries an inline fixture suite pinning the `FORKS:` parser's
  behaviour. Whether the new cases live there or in `tests/cases/` is a placement decision, not a
  behavioural one.
- **Risk, and it is the interesting one:** the phase skills executing this run come from the
  installed plugin cache, not from this worktree. Every edit made here is inert for the duration of
  the run that makes it. This task cannot test its own output end to end, and the disclosure it
  adds is precisely the disclosure it will have to make about itself — by hand, because the ship
  that opens the pull request will not have the step that writes it.

## Open questions

- [x] Vocabulary and cardinality of the new detector line — settled: `HUMAN_ONLY:present|none|absent`,
      three values rather than the four `FORKS:` uses. `FORKS:` needs its fourth value because a
      missing section and a missing file lead to different actions; here both mean "nothing to
      disclose", and the already-printed `TASK:` line distinguishes them for any reader who cares.
- [x] Where the new line is emitted — settled: immediately after `FORKS:`, which groups the two
      readers of `task.md` body sections together. No existing line is renamed or reordered, and
      `PHASE` stays last as the header comment promises.
- [x] How the new journal event is named — settled: a new `event` value rather than a field on an
      existing one, which is what the journal reference's own extension guidance calls for, with a
      `kind` field as the extension point in the way `escalation` uses `reason`.
- [x] Whether to extend `/gantry:review` to read the composed prose instead of having ship re-read
      it — settled: ship re-reads. Review runs against the diff before ship has composed anything,
      so extending it means either running it twice or moving it after composition. The reasoning is
      recorded in the skill so a later reader does not undo it.
