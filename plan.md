# plan.md — rename `/gantry:grill` to `/gantry:plan-grill`

A mechanical rename with one sharp edge: the string `grill` is two things in this repo. It is the
command (`/gantry:grill`, `skills/grill/`) and it is the phase/state token (`PHASE=grill`,
`status: grilled`, `--phase grill`). The first moves, the second must not. Every step below is
written so that the difference is checked rather than eyeballed.

The order matters in one place only: the directory move happens before the prose sweep, so that
`scripts/verify.sh`'s name-matches-directory assertion is satisfied by the same commit that the
prose describes.

## Step 1 — Move the skill directory

`git mv skills/grill skills/plan-grill`.

`git mv` rather than a copy-and-delete, so the history follows the file — acceptance asks for
`git log --follow` to work, and a delete-plus-add loses the SKILL.md's provenance.

**Check:** `git status --short` shows `R  skills/grill/SKILL.md -> skills/plan-grill/SKILL.md`.

## Step 2 — Fix the skill's own identity

Inside `skills/plan-grill/SKILL.md`:

- `name: grill` -> `name: plan-grill`
- `description:` — the one quoted command, `"/gantry:grill"` -> `"/gantry:plan-grill"`. Nothing
  else in the description changes; it is always-on context and every character is paid per session.
- `# gantry:grill` -> `# gantry:plan-grill`
- the body's self-reference, "typed `/gantry:grill` directly" -> `/gantry:plan-grill`.

**Check:** `sed -n 's/^name:[[:space:]]*//p'` on the file prints `plan-grill`, which is what
`verify.sh` compares against the directory basename. `bash scripts/context_budget.sh` exits 0.

## Step 3 — Fix the one executable reference

`lib/detect_stage.sh` has a `case` arm emitting `NEXT="/gantry:grill"`. Change that arm and nothing
else in the file. Twenty lines above it is `planned) PHASE=grill ;;` — that is the state half and
is explicitly out of scope.

**Check:** `grep -n 'NEXT="/gantry:plan-grill"' lib/detect_stage.sh` finds the new string, and the
diff for the file is a one-line change containing no line matching `PHASE=`.

Asserting the new string positively is the point. Running the detector here does **not** exercise
the changed arm: `/gantry:implement` sets `status: implementing` before touching a file, so the
detector reports `PHASE:implement` and never reaches the `grill)` arm. And nothing under `tests/`
asserts `NEXT` at all — `tests/cases/stage_phases.sh` asserts `PHASE:` only. A typo in the new
string would otherwise pass the completeness grep, `scripts/verify.sh`, and the whole suite.

## Step 4 — Sweep the prose

**Twenty-four** remaining literal references — `/gantry:grill`, `gantry:grill`, or `skills/grill/`
— across README, the three docs, the critic agent, five skills and `handover.md`, plus a
**twenty-fifth** edit that is a bare word. Do not treat the count as the checklist; the
completeness grep is. Three of these want a decision rather than a substitution:

- `docs/SKILLS.md`'s context-cost table row `| grill | ~90 |` — the twenty-fifth edit, and the one
  bare word that moves. That table is keyed by skill directory name, not by phase: its other rows
  are `worktree`, `preserve`, `sync`, none of which is a phase. The key becomes `plan-grill`. The
  `~90` figure stands; five characters do not move it.
- `skills/auto-unattended/references/delegation.md` has a table row whose *key* is the phase
  (`grill`) and whose *cell* names the command (`/gantry:grill`). The cell changes, the key does
  not. This is the boundary rule in miniature and the likeliest place to over-apply the rename.
- `skills/auto/references/orchestration.md` has the same phase-keyed table, but — unlike
  `delegation.md` — **no command appears in any of its cells**, so that row is not edited at all.
  Its one real reference is elsewhere in the file: a chain inside a code fence,
  `/gantry:worktree → /gantry:plan → /gantry:grill → …`. Every element there carries the
  `/gantry:` prefix, which makes it a chain of *commands* rather than the bare-word phase listing
  that `task.md` puts out of scope. It changes.

`handover.md`'s four references are included, per the decision recorded in `task.md`.

**Check:** the completeness grep returns nothing once `CHANGELOG.md`, `handover.md`, `task.md` and
`plan.md` are excluded — those four document the rename and necessarily quote the old name.

Then confirm nothing was over-applied, **token-level over the whole diff, not file-level over a
list**. The file-level form this plan originally carried does not work here and the critique was
right to call it a dead guard: two of the five files it named contain no `grill` string at all, so
asserting they were untouched cannot fail; and seven files this step legitimately edits *also*
carry `grilled` or `--phase grill` — `skills/plan-grill/SKILL.md`, `skills/implement/SKILL.md`
(where the command and the status sit two lines apart), `skills/auto/SKILL.md`,
`skills/auto-unattended/SKILL.md`, `docs/ARCHITECTURE.md`, `docs/SKILLS.md`, and
`skills/auto/references/orchestration.md` — so no file-level rule can protect them. Both of these
must print nothing:

```bash
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
```

And, because `scripts/verify.sh` compares the template pair only to each other, check the pair
against `master` as well as against each other.

## Step 5 — Add the CHANGELOG entry

A new `## Unreleased` section above `## 0.4.0`, with a **Changed** or **Breaking** heading that:

- names the rename in both directions;
- says plainly that `/gantry:grill` stops working and that gantry has no alias mechanism, so this
  is breaking for anyone who typed or scripted it;
- states the asymmetry deliberately left in place — the command is `plan-grill`, the phase and
  status vocabulary is still `grill`/`grilled` — and why: those tokens are on disk in every
  existing `task.md` and in every journal line already written.

Nothing already in the file is edited.

**Check:** `git diff CHANGELOG.md` is pure addition — no `-` lines except the context of the
insertion point.

## Step 6 — Gate

`bash scripts/verify.sh`, expecting exit 0. The checks that matter here, in the order they will
catch a mistake: the skill-name-matches-directory assertion (a half-done step 1 or 2), the
template/example byte-identity (an over-applied step 4), the relative-link resolution and the
`.md:<line>` ban (a botched prose edit), and the context budget.

## Test strategy

**No new tests.** Nothing here is behaviour: the renamed string appears in no conditional, and the
one script that carries it (`lib/detect_stage.sh`) emits it as output text. Adding a test that
asserts `/gantry:plan-grill` appears somewhere would restate the completeness grep and rot at the
next rename.

But the honest version of that argument is narrower than it first looks, and the critique
established why: **the existing suite would not catch a corruption of the state vocabulary
either.** `tests/cases/hook_inert_unless_armed.sh` loops over the status values and asserts only
`rc 0`, and the hook is inert for anything that is not exactly `implementing` — so a corrupted
`plan-grilled` still passes. `tests/cases/journal_append.sh` passes `--phase grill`, and
`lib/journal_append.sh` does not validate that flag — so `--phase plan-grill` also passes. And
`lib/detect_stage.sh` routes an unrecognised status to the same phase `grilled` produces, so a
corrupted status instruction in a skill body is invisible too.

So `tests/cases/stage_phases.sh` passing unchanged is **not** the evidence that the boundary held.
The token-level diff guard in Step 4 is that evidence, and it is the only thing that is. Closing
the underlying gap — making `journal_append.sh` validate `--phase`, and `detect_stage.sh` fail
closed on an unknown status — is a real finding, and a behavioural change to two scripts this task
puts out of scope. It goes to `handover.md`, not into this branch.


## What could still go wrong

The failure this plan is most exposed to is a sweep that is too eager — a `sed` over `\bgrill\b`
rather than over the three literal forms — which would pass a naive grep and break the on-disk
state vocabulary. Step 4's census exists for exactly that: it counts every state token across the
whole tree on both sides and requires the tallies to match, rather than trusting a diff to be read
carefully or a list of files to have been guessed correctly. The file-level guard this section
used to point at was removed as dead; see *Grilled*.

## Grilled

`gantry-critic`, dispatched cold against `task.md` and `plan.md`. It read the tree itself and
returned ten findings: two blocking, four worth fixing, four noted. It confirmed the central claim
— the command/state sorting — as correct, with no miscategorised occurrence in either direction.
Every finding below was folded in; none was left.

- **Blocking — the guard against this plan's own stated worst case could not detect it.** Step 4's
  file-level "diff must not touch these five files" was partly dead (two of the five contain no
  `grill` string) and partly inapplicable (seven files this change legitimately edits also carry
  `grilled`). → Replaced with a token-level sweep over the whole diff, in both directions. Two
  acceptance criteria that could not be shown false were replaced by it.
- **Blocking — a corruption of the state vocabulary would be silent.** The hook is inert for any
  non-`implementing` status; the journal does not validate `--phase`; the detector routes an
  unknown status to the same phase `grilled` produces. → Recorded in *Test strategy*: the existing
  suite is not the evidence the boundary held, the diff guard is. The underlying gap is deferred
  to `handover.md` as a behavioural change this task puts out of scope.
- **`task.md` asserted something false about the code** — that `lib/journal_append.sh` validates
  `--phase` as an enum. It does not. → Corrected in *Context & goal*, and the correction is what
  motivates the diff-level guard rather than being dropped once it stopped being convenient.
- **Nothing asserted the *new* string was right.** The completeness grep only proves the old
  string is gone; a `plan-gril` typo would pass everything. → Added a positive criterion, and
  Step 3 now says why running the detector here cannot substitute for it.
- **Nothing established that the renamed command resolves.** Claude Code loads `skills/` from the
  *installed* plugin, so this session cannot execute the command it renames. → Two real
  `human_only` entries replace the commented-out placeholder, so the PR states it plainly.
- **The Step 4 miniature was wrong about `orchestration.md`** — that file's phase-keyed table
  names no command, and its real reference is a `/gantry:`-prefixed chain in a code fence. →
  Corrected, and *Out of scope* now distinguishes a bare-word chain listing from a slash-prefixed
  one.
- **The reference count was 23; it is 24, plus one bare-word edit.** → Corrected, with a note not
  to use the count as the checklist.
- **The completeness grep excluded by basename**, which would also have excused `examples/task.md`
  and `skills/plan/templates/task.md`. → Path-anchored instead.
- **"git records the change as a rename" is not falsifiable** — git infers renames from
  similarity, so `cp`+`rm` would satisfy it. → Dropped as a criterion; `git mv` stays as the
  method, checked at Step 1 where the check does work.

## Re-planned during implementation

One step changed on contact with the tree, recorded here rather than silently fixed.

**Step 4's token-level guard, as the grill left it, did not work.** It swept the diff for *removed
lines* matching a state token. Run against the real diff it produced two matches, both legitimate:
a sentence in `skills/implement/SKILL.md` that contains both the word "grilled" and the command
being renamed, and `task.md`'s own `status:` line, whose trailing comment enumerates the entire
status vocabulary. The same run also showed the completeness grep's `^\./` anchor never matching,
because this grep prints paths with no `./` prefix — so the three documenting files were never
actually being excluded, and the check only looked correct because nothing else matched.

Both are now fixed in `task.md` and above: the exclusion is anchored optionally on `./`, and the
state guard is a **census** — count every state token across the whole tree, on `master` and on
the working tree, and require the two tallies to match exactly. That is falsifiable where line
matching was not, and it is blind to neither a corruption inside a legitimately edited file nor
one in a file nobody thought to list.

The census passes: `--from grill` 1, `--phase grill` 2, `--to grill` 1, `PHASE=grill` 1,
`grilled` 19 — identical on both sides.

Those figures are the **final** ones. An earlier revision of this section recorded `grilled` 21,
measured before Step 5 wrote the CHANGELOG entry and before `CHANGELOG.md` was added to the
census's exclusions — stale by the time the branch was done, and stale in the direction that
matters, since *Test strategy* calls this census the only evidence the boundary held. Review
caught both the stale numbers and the missing exclusion.
