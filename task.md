---
id: 2026-08-31-agent-env-claims-cite-source
title: Make sub-agents source their environment claims, and stop them narrowing the caller's evidence
project: claude-gantry
branch: fix/agent-env-claims-cite-source
mode: unattended          # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

Two sub-agent runs returned confidently false statements about the machine they were running
on. Both were load-bearing — acting on either would have changed the outcome — and neither was
caught by anything in the pipeline.

**The critic case.** A critic asserted that two paths did not exist on the box, and concluded
from that that a hazard it had just found — sixteen probes each polling a real approvals
directory for 900 seconds — would not reproduce there. Both paths existed. The finding was
right and its severity was understated; untreated, the suite would have polled for hours on
that machine.

**The explorer case.** An explorer claimed that a particular log file never contains a
`decision=fire verdict=PASS` line, and explicitly instructed the driver not to grep for it. The
claim was false — the readiness gate emits exactly that line. The explorer had sampled 26 lines
that happened to all be skips and generalised from them. Trusting it would have built a feature
against the wrong file, satisfying its acceptance criteria while measuring nothing.

Both errors were caught only because the claim happened to contradict something the lane had
already read for itself. That is luck, not a check. And note which errors these were: **a wrong
fact attached to a real finding is more dangerous than a wrong finding**, because the finding's
credibility carries the error past scrutiny — nobody re-checks the premise of a conclusion they
have already accepted.

The second case has a shape of its own on top of the false claim. Telling the caller *not* to
run a command is not reporting; it is deciding what evidence the caller is allowed to have. A
sub-agent that narrows its caller's evidence has stopped being a scout and started being an
authority, and it is exactly the move that nearly built the feature against the wrong file.

The goal is to put a sourcing rule into the return contracts of the three agents in the roster:
an environment claim names the command behind it, a negative claim names the command *and the
scope it covered*, a generalisation from a sample says that it is one and how large — and an
explorer never tells the caller what to skip.

**This is prose, and prose is the weak instrument here.** GANTRY-5 records four models reading
a clear written rule and all four ignoring it. This change is a mitigation, not enforcement:
nothing in the pipeline can check that a claim was sourced, and a sub-agent that ignores the
rule fails exactly the way the two observed cases failed. That limitation is written into the
change itself, per the house style rule that a check which can false-green must say so where
someone will read it.

## Acceptance criteria

- [ ] `agents/gantry-explorer.md`, `agents/gantry-critic.md` and `agents/gantry-reviewer.md`
      each state that a claim about the filesystem, the environment, or what a file does or
      does not contain must name what established it — **phrased in terms of the tools that
      agent actually holds.** `gantry-reviewer` has `Bash` and so names a command; the other two
      have only `Read`, `Grep` and `Glob`, so they name a search, and are told explicitly not to
      write a claim as though they had run a shell. An invented command is worse than an
      unsourced claim, because it reads as evidence.
- [ ] Each of the three states the negative-claim clause: a claim that something does not exist
      or that a file never contains something carries what established it **and the scope it
      covered**.
- [ ] Each of the three states the sample clause: a claim generalised from a sample is labelled
      as a sample, with its size.
- [ ] `agents/gantry-explorer.md` carries an explicit prohibition on instructing the caller what
      not to check, named as its own failure and distinct from the sourcing rule.
- [ ] In `agents/gantry-critic.md` the rule is folded into the existing "say plainly which
      findings you checked against the code and which you are inferring" clause rather than
      added as a separate paragraph beside it, and names the trap that a wrong fact attached to
      a real finding is more dangerous than a wrong finding.
- [ ] The `description:` frontmatter field of every file under `agents/` is byte-identical to
      its value at `c220ab6`, and every `name:`, `tools:` and `model:` field is unchanged too.
- [ ] `bash scripts/context_budget.sh` exits 0.
- [ ] `bash scripts/verify.sh` exits 0.
- [ ] The limitation — prose, a mitigation rather than enforcement — is stated **inside the
      section of each agent file that states the rule**, not in a footnote elsewhere in the file
      and not only in the pull request.
- [ ] `docs/METHOD.md`'s delegation section no longer ends on the un-caveated claim that the
      paragraph a sub-agent returns is what the orchestrator needed; it carries the two failures,
      the fact that the mitigation is unenforced prose, and the gap where a target repo overrides
      a role with its own agent file.

## How to verify

```bash
bash scripts/verify.sh          # the gate: lint, manifest, frontmatter, links, secrets, tests
bash scripts/context_budget.sh  # the always-on description budget
git diff c220ab6 -- agents/ | grep -E '^[-+](description|name|tools|model):'   # must print nothing
```

Read the three agent files and confirm the rule reads as an instruction a model can follow —
what to write, not merely what to believe. Confirm the limitation is stated where the rule is,
not filed somewhere a reader of the rule would never reach.

## Out of scope

- **Any phase skill.** `skills/plan`, `skills/grill` and `skills/review` are untouched. The rule
  belongs with the agent making the claim, and those files are being edited by other lanes in
  this batch.
- **Any enforcement mechanism** — no linting of agent output, no new script, no test. Detecting
  an unsourced *claim* is impossible from outside the model, which is the limitation the change
  admits rather than papers over. Note that a weaker check *is* possible and is still excluded:
  an agreement check asserting all three bodies carry the rule, of the shape `verify.sh` already
  applies to the duplicated frontmatter parser. The grill surfaced it; it is deferred to
  `handover.md` with its shape written out, not dismissed.
- **Changing any agent's `model:` or `tools:`.** The tool boundary is not what failed here.
- **The `description:` fields.** They are paid in every session and the budget script enforces
  that; the rule goes in the body, which costs nothing until the agent is dispatched.
- **Retro-fixing the two observed runs.** They are the evidence, not the work.
- **Correcting `docs/ARCHITECTURE.md`'s "Four agents ship" above a table of three** — pre-existing
  residue from the verifier deletion, unrelated to this change. See `handover.md`.
- **Closing the repo-override gap**, where a target repo's own `.claude/agents/<role>.md` replaces
  a shipped agent and its contract. Disclosed in `docs/METHOD.md`, not addressed. See
  `handover.md`.

## Affected areas

Four files: the three under `agents/`, read directly at `c220ab6` rather than via an explorer —
the surface is named in the task and is short — plus `docs/METHOD.md`, added at grill.

- `agents/gantry-explorer.md` — has a `## What you return (the contract)` section ending in a
  "never dump whole files" rule and a "say so plainly and name what's missing" fallback. The
  sourcing rule extends that section. There is no existing statement about environment claims,
  and nothing anywhere in the file about what the caller should or should not check — the
  prohibition is genuinely new.
- `agents/gantry-critic.md` — its contract section already ends with "say plainly which of your
  findings you checked against the code and which you are inferring from the artifacts alone".
  That clause is the nearest existing hook and the right place to extend: it is already about
  the provenance of a claim, so the sourcing rule belongs inside it rather than beside it.
  Separately, the file has a `## What makes a finding real` section built around severity and
  concrete consequence — the observed critic failure was a *correct* finding with a false
  premise, which that section does not currently reach.
- `agents/gantry-reviewer.md` — its contract section already ends with "one line on what you
  checked and what you did not", which is the mirror of the critic's clause and the same place
  the rule attaches. It is the only agent with `Bash`, so it is the one most able to comply and
  the one whose unsourced claims would be least excusable.

- `docs/METHOD.md` — its delegation section ends "A sub-agent reads 10,000 lines and returns a
  paragraph. The paragraph is what the orchestrator needed", with no caveat. That is exactly the
  claim the two incidents falsify, so it is where the long-form limitation belongs.
  `docs/ARCHITECTURE.md` and `docs/SKILLS.md` mention the three agents only by tools, model and
  dispatch condition — not by return contract — so neither goes stale from this change.

Risks and gotchas:

- `scripts/context_budget.sh` sums the characters of the single-line `description:` field of
  every `skills/*/SKILL.md` and `agents/*.md` against a ceiling of 6250. Body text is not
  counted, so the change is free against that budget **provided** no `description:` line is
  touched and no file loses its single-line `description:`.
- `scripts/verify.sh` compares each agent's `name:` against its filename unconditionally, but its
  only *real* frontmatter validation is `claude plugin validate agents --strict`, which runs only
  inside `if command -v claude`. On this machine the CLI is present — `command -v claude` resolves
  to a path under `~/.local/bin` when run unsandboxed — and that check ran and passed; it is
  skipped wherever the CLI is missing, which `scripts/context_budget.sh`'s header says includes CI
  runners. Where it is skipped, a broken `---` fence passes the gate and the agent silently fails
  to load — so the guarantee this change leans on is "no frontmatter line changed at all", shown
  by a diff grep rather than inferred.
- `scripts/verify.sh` also fails on any tracked markdown matching `\.md:[0-9]+`. This change
  writes example commands into markdown, so an illustrative citation with a line number in it
  turns the gate red for a reason unrelated to the change.
- Every added word is paid in the dispatched agent's context. Three files, so the same rule is
  written three times; it should be short enough that repeating it is cheap and phrased for the
  role each time rather than pasted identically.

## Open questions

None. The task specifies the rule, the three files, the placement in each, and the caveat that
has to travel with it.
