# `journal.jsonl` — conventions

The append-only event log of one orchestrator run. It lives at the **root of the task's
worktree**, beside `task.md` and `plan.md`, and makes a run auditable after the fact: what
stage the run reached, what each phase reported and which sub-agents it dispatched, and how the
gate decided.

## How to append

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from plan --to implement --mode unattended
```

Flags in, one line out, appended to `journal.jsonl` at the root of the tree you run it from.
`--file <path>` overrides that.

**Trying it out? Pass `--file`.** The default is a live run's audit trail, so a probe invocation
lands a synthetic event in the record of whatever run owns that worktree — the same class of
damage as the invented timestamps below, and just as invisible to a later reader. This has already
happened once, to a reviewer checking the script's behaviour.

**Why a script rather than the obvious one-liner.** The idiom here used to be a `printf` appending
a command substitution that wrapped `jq -nc`, with a second, nested substitution supplying
`date -u +%FT%TZ` as the timestamp.
A worktree-isolated session **refuses to run that**: the harness cannot verify that a compound
command full of substitutions stays inside the worktree, so it declines the call. Five of six
lanes in one parallel batch hit it.

The retries were not the damage. One lane worked around the refusal by calling `date -u` once and
hand-writing the rest of its timestamps as estimates — an accurate event ordering with a fictional
clock, and nothing downstream could tell. So the substitution moved inside the script, where it is
ordinary shell, and **`ts` is not a parameter**: `--ts` is refused rather than ignored, because a
caller who passed one and saw no error would believe it took effect.

**Runtime values are substituted by you, not by the shell.** Every command below is run in a fresh
shell, so a literal `--exit "$RC"` would expand to empty and be refused. `<like-this>` marks a
placeholder: write the value you actually observed.

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --to contract --mode unattended
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase plan --result ok --agent gantry-explorer --summary <one or two sentences> --artifact task.md --artifact plan.md
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event gate --result fail --exit <literal exit code> --attempt 1 --check lint --check test
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event decision --stage plan --question <the question> --answer <what was decided>
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event escalation --stage plan --reason open-fork --detail <the fork, verbatim> --status blocked
```

Omit `--from` on the first `stage` line of a run and it emits `"from":null`, which is the
documented shape. The script validates per event: a field its shape does not carry, or a required
one left out, is exit 2 and nothing is written.

**There is still no writer engine, and there will not be one.** That rule refuses a *log
framework* — rotation, readers, query tools, a schema that has to be migrated. It does not refuse
a twenty-line argv-to-JSON shim, which is the same shape `lib/run_gates.sh` and
`lib/detect_stage.sh` already have: arguments in, a contract out, no state. The append is still one
`>>` and the file is still plain JSON Lines. If you are reading this while deciding whether
`journal_append.sh` violates the rule: it does not, and this paragraph is here so the question
only has to be answered once.

Any producer that emits one JSON object per line is conformant. The helper is the convenient path,
not a new requirement — `jq -nc` by hand is still fine, and a careful `printf` is acceptable for
fixed strings.

## Envelope

Every line is a complete JSON object on one line, with these fields:

| Field | Type | Meaning |
|---|---|---|
| `ts` | string | ISO-8601 UTC, second precision — `2026-08-16T09:41:07Z`. |
| `task` | string | The `id` from `task.md` frontmatter. Ties the line to its contract. |
| `event` | string | One of the shapes below. |

Lines are **appended, never rewritten**. Correcting the record means appending a later line,
not editing an earlier one — an edited log is not evidence.

## Event shapes

### `stage` — a stage transition

```json
{"ts":"2026-08-16T09:41:07Z","task":"2026-08-16-contact-form","event":"stage","from":"plan","to":"implement","mode":"supervised"}
```

`from` is `null` on the first line of a run (entering the first stage). Stage names match the
orchestrator's own: `contract`, `plan`, `grill`, `implement`, `gate`, `review`, `ship`.

### `phase` — a phase skill returned

```json
{"ts":"2026-08-16T09:44:22Z","task":"2026-08-16-contact-form","event":"phase","phase":"plan","agents":["gantry-explorer"],"result":"ok","summary":"Four steps; the form posts to the existing /api/contact handler.","artifacts":["task.md","plan.md"]}
```

- `phase` — `plan` | `grill` | `implement` | `review`.
- `agents` — the sub-agents the phase actually dispatched, resolved names, in order. `[]` when it
  dispatched none (a `plan` that read the code directly, a `review` that used `/code-review`).
  This is the delegation roll-call the final report is checked against, so record what happened,
  not what was expected.
- `result` — `ok` | `failed` | `refused` (the phase stopped rather than improvise).
- `summary` — the phase's **summary**, one or two sentences. Never the raw material it read;
  that is the whole point of the delegation.
- `artifacts` — worktree-relative paths it produced or filled.

### `gate` — a gate decision

```json
{"ts":"2026-08-16T09:52:10Z","task":"2026-08-16-contact-form","event":"gate","result":"fail","exit":1,"attempt":1,"checks":["lint","test"],"artifacts":[".claude/artifacts/gate-1.log"]}
```

- `result` — `pass` | `fail` | `no-gates`, mirroring the gate script's exit code
  (`0` / `1`+ / `3` under `--strict`).
- `exit` — the literal exit code, so the log survives a change in vocabulary.
- `attempt` — 1-based; increments on each unattended fix-and-retry.
- `artifacts` — paths to captured output. Paths, not logs: the journal stays skimmable.

### `decision` — a human answered a supervised checkpoint

```json
{"ts":"2026-08-16T09:48:02Z","task":"2026-08-16-contact-form","event":"decision","stage":"plan","question":"proceed with this plan?","answer":"proceed; use the existing /api/contact handler rather than a new route"}
```

- `stage` — where the checkpoint sat: `plan` (after the plan) or `review` (before ship).
- `question` / `answer` — one line each, in the user's terms. Record what was *decided*, not the
  full option list you rendered.

Emitted only by `gantry:auto`; unattended runs have no checkpoints. This is the least
recoverable line in the file — every other event can be reconstructed from git and the artifacts,
but a human's answer exists nowhere else.

### `escalation` — the run stopped and needs a person

```json
{"ts":"2026-08-16T09:45:31Z","task":"2026-08-16-contact-form","event":"escalation","stage":"plan","reason":"open-fork","detail":["Postgres or SQLite? Changes the migration story and the deploy."],"status":"blocked"}
```

- `stage` — where the run stopped: `plan` or `grill` for an open fork.
- `reason` — why. `open-fork` is the one `gantry:auto-unattended` emits today.
- `detail` — one string per thing needing a decision, in the terms the reader has to answer in.
  For an open fork, the entries from `task.md`'s *Open questions*, verbatim. This is the payload
  that makes the escalation actionable, so it carries the question rather than a count of them.
- `status` — what `task.md` was set to, so the journal and the artifact cannot disagree.

An unattended run that meets an open fork **stops here**: it has nobody to ask, and the only
alternative to stopping is guessing at a decision that would then be indistinguishable from one
somebody made. The line exists so that "why did this run stop" is answerable from the journal
alone, without reopening the worktree.

## Extending

New event types are fine — keep the envelope, add a shape here, and prefer a new `event`
value over overloading an existing one.

Adding one now means **two** edits, not one: the shape here, and the event's row in
`lib/journal_append.sh`, which whitelists the five values above and the fields each carries. That
is deliberate — an unrecognised `--event` is exit 2, so a typo cannot quietly produce a line
nothing can query — but it does mean the script is a second place to look when the schema grows.

`escalation` was reserved-but-unemitted until `gantry:auto-unattended` gained the open-fork stop;
it is now a real event with the shape above. Its `reason` field is the extension point — a new kind
of stop adds a `reason` value rather than a new event type.

## Not committed

`journal.jsonl` is a **run artifact, not a deliverable.** `task.md` and `plan.md` travel into
the PR — they are the human-facing contract a reviewer wants. The journal does not: a
per-run log in every PR is review noise and conflicts on every rebase. It stays in the
worktree, next to the run it describes, for whoever is reading that run back. The
orchestrator excludes it via `.git/info/exclude`, using `lib/ensure_excluded.sh`:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" journal.jsonl .claude/artifacts/
```

That file is **shared by every linked worktree** — git maps `info/` into the common git dir, so a
worktree's own `info/exclude` is a path git never reads, and there is no per-lane copy to write
instead. A plain `grep -q … || echo … >>` therefore races: parallel lanes interleave the read and
the write, and double-appended entries were observed. The script takes a lock, matches whole lines,
and collapses duplicates an earlier racing writer already left, so running it any number of times
from any number of lanes leaves exactly one copy of each pattern.
