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

## Extending

New event types are fine — keep the envelope, add a shape here, and prefer a new `event`
value over overloading an existing one. One is designed but not yet emitted: `escalation`,
for a blocked task handed to whatever notifies you. Nothing in gantry emits it; the shape is
reserved so an integration does not have to invent one.

## Not committed

`journal.jsonl` is a **run artifact, not a deliverable.** `task.md` and `plan.md` travel into
the PR — they are the human-facing contract a reviewer wants. The journal does not: a
per-run log in every PR is review noise and conflicts on every rebase. It stays in the
worktree, next to the run it describes, for whoever is reading that run back. The
orchestrator excludes it via `.git/info/exclude`.
