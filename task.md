---
id: 2026-09-02-rename-grill-to-plan-grill
title: Rename the /gantry:grill skill to /gantry:plan-grill
project: claude-gantry
branch: refactor/rename-grill-to-plan-grill
mode: unattended          # semi-auto | auto | unattended — which mode is driving
status: shipped             # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

The critique phase is invoked as `/gantry:grill`. The name says what it does to a plan but not
what it operates on, and it sorts nowhere near `/gantry:plan` in a skill listing even though it is
the second half of planning — it reads `task.md` and `plan.md`, revises `plan.md`, and produces
nothing else. Renaming it to `/gantry:plan-grill` puts it next to the phase it belongs to and makes
the pairing legible at the point where a user picks a command.

The rename is deliberately scoped to the **command string**. gantry's phase vocabulary is a
separate namespace that is written to disk and parsed back: `lib/detect_stage.sh` derives
`PHASE=grill` from `status: grilled`, `hooks/readiness-gate.sh` carries its own copy of the status
parser, and `lib/journal_append.sh` writes `--phase grill` into every journal line. Those tokens
appear in every `task.md` a user already has on disk and in the journal of every run already
recorded.

One correction to that reasoning, found by the critique and carried here rather than quietly
dropped: `lib/journal_append.sh` does **not** validate `--phase` against an enum. It enumerates
`--event` and `--result`; `--phase` is only required to be present, and is then passed through to
`jq` as free text. A corrupted `--phase plan-grill` would be written silently rather than
refused. The boundary decision stands on its other two legs — the `case "$STATUS"` map in
`lib/detect_stage.sh`, and the `task.md` files already on disk — but this change has less of a
safety net than it first appeared, which is why the guard below is written over the diff rather
than over a list of files.
Renaming them would invalidate that data for no gain, so the command moves and the state stays.

The consequence is intentional and worth stating plainly: after this change the command is
`/gantry:plan-grill` while the phase it drives is still called `grill`. That asymmetry is the price
of not breaking on-disk state, and it is documented rather than smoothed over.

This is a **breaking change** for anyone who types the old command or scripts it. gantry has no
alias mechanism, so `/gantry:grill` simply stops resolving.

## Acceptance criteria

**The rename landed.**

- [x] `skills/plan-grill/SKILL.md` exists and `skills/grill/` does not.
- [x] That file's frontmatter `name:` is `plan-grill`, matching its directory — the identity
      `scripts/verify.sh` asserts for every skill.
- [x] Its body heading is `# gantry:plan-grill`, and its `description:` quotes
      `"/gantry:plan-grill"`.
- [x] `lib/detect_stage.sh` carries the new string, asserted **positively**:
      `grep -n 'NEXT="/gantry:plan-grill"' lib/detect_stage.sh` finds it. The completeness grep
      below only proves the old string is gone, so a typo like `plan-gril` would pass it, pass
      `scripts/verify.sh`, and pass the suite — nothing under `tests/` asserts `NEXT` at all.

**It is complete.**

- [x] The completeness sweep in *How to verify* prints nothing. It excludes `CHANGELOG.md`,
      `handover.md`, `task.md` and `plan.md` — the four files whose subject *is* the rename, which
      quote the old name on purpose — and every other file must be clean.

      The task framed this as "`CHANGELOG.md` only". That cannot hold: gantry commits `task.md` and
      `plan.md` with the branch, and a contract for a rename necessarily quotes the name being
      renamed. The exclusion is path-anchored rather than written as `--exclude=task.md`, which
      matches basenames and would silently also excuse `examples/task.md` and
      `skills/plan/templates/task.md`.

**The state vocabulary survived it.** A file-level guard is not available here, which is the
critique's main structural finding. Seven files this change legitimately edits *also* contain
`grilled` or `--phase grill`; and two of the files a naive guard would name contain no `grill`
string at all, so asserting they were not touched cannot fail. Worse, three of the ways this could
go wrong are silent — the hook is inert for any status that is not exactly `implementing`, the
journal does not validate `--phase`, and `detect_stage.sh` routes an unrecognised status to the
same phase `grilled` produces. So the guard is token-level, over the whole diff:

- [x] The **state-token census** in *How to verify* prints identical output for `master` and for
      the working tree: one line per token, with the same count against each. Every token this
      change must not move is enumerated, and the comparison is over the whole tree rather than
      over a file list, so it is blind to neither a corrupted token in a file that was edited for
      good reason nor one in a file nobody expected to change.

      **Four files are excluded, and the rule behind the list is what matters.** `task.md`,
      `plan.md`, `CHANGELOG.md` and `handover.md` are this change's own documentation: each one
      quotes the old command, or the state tokens, or both, precisely in order to record that the
      first moved and the second did not. Every other file in the tree must be clean. Any check
      here that does not exclude all four will read this change's own prose as the corruption it
      is looking for.

      That was not obvious in advance and both omissions were caught rather than foreseen. Review
      found the census running without `CHANGELOG.md`, where it reported `grilled` 22 against
      master's 21 — a false alarm on the exact vocabulary it exists to protect. Re-running the
      checks after the deferral was written found the same hole for `handover.md`, whose new
      section describes the rename in the same terms. A guard that cries wolf on the change's own
      documentation gets read past, which is the failure mode both fixes are aimed at.

      A first attempt at this guard swept the diff for removed lines matching a state token. It
      does not work, and this run proved it: two lines matched immediately, both legitimate — a
      sentence in `skills/implement/SKILL.md` that contains the word "grilled" *and* the command
      being renamed, and `task.md`'s own `status:` line, whose trailing comment lists the whole
      status vocabulary. A guard that cries wolf on every correct edit gets read past. Counting
      occurrences is falsifiable where matching lines is not.

- [x] No corrupted token is introduced in the other direction: the added-token sweep in
      *How to verify* prints nothing.
- [x] `examples/task.md` and `skills/plan/templates/task.md` are byte-identical to each other
      **and** unchanged against `master`. `scripts/verify.sh` only compares the two to each other,
      so an identical edit to both would pass it — the second half of this is what catches that.

**The record is honest.**

- [x] `CHANGELOG.md` gains one new `Unreleased` entry marking the rename BREAKING; every existing
      entry is unchanged against `master`.

**The gate is green.**

- [x] `bash scripts/verify.sh` exits 0.
- [x] `bash scripts/context_budget.sh` exits 0.


## How to verify

```yaml
verification:
  automated:
    lint: true
    tests: true
  human_only:
    - "Type /gantry:plan-grill in a session with the rebuilt plugin installed, and confirm it
       resolves and dispatches a critic. Claude Code loads skills/ from the INSTALLED plugin, so
       the session that makes this change cannot execute the command it renames. Every criterion
       above is textual or structural; none of them proves the new command actually works."
    - "Confirm /gantry:grill no longer resolves, so the breaking change is real rather than
       assumed."
```

Run, from the worktree root:

```bash
# the rename landed — asserted positively, on the new strings
sed -n 's/^name:[[:space:]]*//p' skills/plan-grill/SKILL.md | head -1     # -> plan-grill
grep -n 'NEXT="/gantry:plan-grill"' lib/detect_stage.sh

# completeness — must print nothing
grep -rn "gantry:grill\|skills/grill" . --include='*.md' --include='*.sh' --include='*.json' \
  | grep -vE '^(\./)?(CHANGELOG|handover|task|plan)\.md:'

# the state vocabulary survived — these two must print IDENTICAL output
git grep -hoE 'grilled|PHASE=grill|--phase grill|--to grill|--from grill' master \
  -- . ':(exclude)task.md' ':(exclude)plan.md' \
  ':(exclude)CHANGELOG.md' ':(exclude)handover.md' | sort | uniq -c
git grep -hoE 'grilled|PHASE=grill|--phase grill|--to grill|--from grill' \
  -- . ':(exclude)task.md' ':(exclude)plan.md' \
  ':(exclude)CHANGELOG.md' ':(exclude)handover.md' | sort | uniq -c

# and nothing corrupted in the other direction — must print nothing
git diff master -- . ':(exclude)task.md' ':(exclude)plan.md' \
  ':(exclude)CHANGELOG.md' ':(exclude)handover.md' \
  | grep '^+' | grep -E 'plan-grilled|PHASE=plan-grill|phase plan-grill'

# the template pair — against each other, and against master
diff examples/task.md skills/plan/templates/task.md
git diff --stat master -- examples/task.md skills/plan/templates/task.md   # must be empty

bash scripts/context_budget.sh
bash scripts/verify.sh
```


## Out of scope

- **The phase and status vocabulary.** `PHASE=grill`, `status: grilled`, and the journal's
  `--phase grill` stay exactly as they are, along with the tests and the hook parser that read
  them. This is the boundary the whole task is drawn around.
- **Bare-word `grill` used as the phase name or as a verb** — prose chain listings
  (`plan, grill, implement, review, ship`), `plugin.json`'s description, "a plan that was never
  grilled". These name the phase, not the command. A chain written with `/gantry:` prefixes is
  the opposite case and **is** in scope — `skills/auto/references/orchestration.md` has one,
  and the slash makes every element of it a command string.
- **A back-compatibility alias.** gantry has no alias mechanism and this task does not invent one.
- **The version bump.** The entry lands under `Unreleased`; choosing the release number is the
  release's job.
- **The deferred findings recorded in `handover.md`.** Their *pointers* follow the rename; the
  findings themselves stay deferred and unaddressed.
- **Closing the gap that makes a state-token corruption silent** — `lib/journal_append.sh` does
  not validate `--phase`, `lib/detect_stage.sh` routes an unknown status to the same phase
  `grilled` produces, and the hook test asserts only `rc 0`. Found while establishing this
  change's own boundary, deferred as a behavioural change to two scripts; written up in
  `handover.md`.
- **Re-measuring the always-on token figure.** The rename moves the character count by five and
  `CEILING` is not approached; the `~90` figure in the docs table is left alone.

## Affected areas

One executable reference, and the rest prose. Nothing here is logic — the command string appears
in no conditional.

- `lib/detect_stage.sh` — the only script that emits the command. One `case` arm sets
  `NEXT="/gantry:grill"`. The `case "$STATUS"` arms above it that set `PHASE=grill` are the state
  half and must not be touched; the two live within twenty lines of each other, which is the main
  hazard in this change.
- `skills/grill/SKILL.md` — the skill itself: directory name, `name:` frontmatter, `description:`,
  the `# gantry:grill` heading, and a self-reference in the body.
- `README.md` — two mermaid nodes and two table rows.
- `docs/SKILLS.md` — its own section heading, the command line beneath it, and the `grill` row in
  the context-cost table, which is keyed by skill directory name rather than by phase.
- `docs/ARCHITECTURE.md` — a mermaid node, the artifacts table, the agent roster table.
- `docs/METHOD.md` — one sentence about always dispatching a fresh sub-agent.
- `agents/gantry-critic.md` — names the skill that dispatches it.
- `skills/plan/SKILL.md` — three references, one of which is the "next command" line the phase
  prints.
- `skills/implement/SKILL.md` — names the cheaper phase to go back to.
- `skills/auto/SKILL.md`, `skills/auto/references/orchestration.md` — the supervised driver.
- `skills/auto-unattended/SKILL.md`, `skills/auto-unattended/references/delegation.md` — the
  unattended driver.
- `handover.md` — four references, discussed under Open questions.
- `CHANGELOG.md` — gains an entry; existing entries are not edited.

**Risks.**

- `scripts/verify.sh` asserts `name:` equals the directory basename, so a half-done rename is red
  rather than silently wrong. It also rejects any `.md:<line>` citation and checks that every
  relative markdown link resolves — both are ways prose edits break. No markdown link currently
  targets `skills/grill/`, so the link check has nothing to catch here.
- `scripts/context_budget.sh` sums `description:` characters against `CEILING=6250`; the tree sits
  at 5783. This change costs five characters. It is not a risk on its own, but `feat/v0.4.1` is in
  flight against the same headroom, so the budget wants re-checking after any merge.

## Open questions

Both entries below were raised by the task and delegated to this phase to settle, not left to a
human — so they are recorded decided, with what settled them.

- [x] Should `handover.md`'s four references follow the rename? — **Yes.** They are actionable
      pointers: they name `skills/grill/SKILL.md` as the file a future implementer edits to fix a
      deferred finding, and one names `/gantry:grill` as the command that misbehaves on a clean
      branch. After the rename that path does not exist, so leaving them makes the next action
      unfollowable. This is not the same as rewriting history — `handover.md` is a live work item,
      not a record of what shipped.
- [x] What happens to `CHANGELOG.md`? — **Existing entries are not touched; one new `Unreleased`
      entry is added.** The 0.4.0 and earlier entries describe what shipped under the old name and
      are accurate as written. The new entry names `/gantry:grill` in order to say it is gone,
      which is why the acceptance grep expects `CHANGELOG.md` to be the one surviving match.
