# `journal.jsonl` — conventions

The append-only event log of one orchestrator run. It lives at the **root of the task's
worktree**, beside `task.md` and `plan.md`, and makes a run auditable after the fact: what
stage the run reached, what each phase reported and which sub-agents it dispatched, and how the
gate decided.

**There is no writer engine, and there will not be one.** The orchestrator appends a line with
`>>` at each transition. That is the whole implementation — deliberately, per
gantry stays thin glue over native primitives.

```bash
printf '%s\n' "$(jq -nc --arg ts "$(date -u +%FT%TZ)" ... )" >> journal.jsonl
```

Any producer that emits one JSON object per line is conformant. `jq -nc` is the convenient
way to get valid escaping; a careful `printf` is acceptable for fixed strings.

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
{"ts":"2026-08-16T09:52:10Z","task":"2026-08-16-contact-form","event":"gate","result":"fail","exit":1,"attempt":1,"checks":["lint","test"],"coverage":{"roots":["app"],"verdict":"no-overlap","changed":3,"covered":0,"heuristic":true},"artifacts":[".claude/artifacts/gate-1.log"]}
```

- `result` — `pass` | `fail` | `no-gates`, mirroring the gate script's exit code
  (`0` / `1`+ / `3` under `--strict`).
- `exit` — the literal exit code, so the log survives a change in vocabulary.
- `attempt` — 1-based; increments on each unattended fix-and-retry.
- `coverage` — what the gate actually read, from `lib/gate_coverage.sh` via the implement phase's
  report. See below; omit the key entirely on a run that predates it rather than inventing one.
- `artifacts` — paths to captured output. Paths, not logs: the journal stays skimmable.

#### `coverage` — what the gate read, and why it is not a proof

A gate that runs and passes while reading none of the paths the diff touches exits `0` exactly
like one that proved something, so `result: pass` alone cannot distinguish them. This object is
what makes the difference legible after the fact.

- `roots` — the root-relative directories checks actually ran in, **always an array** so a
  parser never handles a string-or-array. It is empty when `verdict` is `undeclared`,
  `no-checks` or `unknown`.
- `verdict` — mirrors `lib/gate_coverage.sh` exactly: `overlap` · `no-overlap` · `undeclared` ·
  `no-checks` · `no-changes` · `unknown`. A green gate with `no-overlap` is
  **green-but-uncovered** — genuinely green, and not evidence about this diff.
- `changed` / `covered` — path counts. The orchestrator's own artifacts (`task.md`, `plan.md`,
  `handover.md`, `journal.jsonl`, `.claude/artifacts/`) are excluded from `changed`, so the
  number means source paths.
- `heuristic` — always `true`, and it is there to be read. **A root is the directory a check was
  run in, never the set of files it read**, and it errs in both directions: a suite rooted in a
  subdirectory may import from the repo root, and a check that ran at the root counts as
  covering everything while possibly reading almost none of it. When `verdict` is `undeclared`,
  `unknown` or `no-checks`, `covered: 0` means nothing could be *attributed* — not that nothing
  was covered.

Nothing reads this field to decide anything. It is reported, never enforced: low overlap is not
a refusal and does not change an exit code. A reader who mistakes this number for a proof is the
failure the field exists to prevent, so the caveat travels with the data rather than living only
here.

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

`escalation` was reserved-but-unemitted until `gantry:auto-unattended` gained the open-fork stop;
it is now a real event with the shape above. Its `reason` field is the extension point — a new kind
of stop adds a `reason` value rather than a new event type.

## Not committed

`journal.jsonl` is a **run artifact, not a deliverable.** `task.md` and `plan.md` travel into
the PR — they are the human-facing contract a reviewer wants. The journal does not: a
per-run log in every PR is review noise and conflicts on every rebase. It stays in the
worktree, next to the run it describes, for whoever is reading that run back. The
orchestrator excludes it via `.git/info/exclude`.
