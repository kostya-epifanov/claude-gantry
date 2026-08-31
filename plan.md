# Plan — make sub-agents source their environment claims

Task: `task.md` (`2026-08-31-agent-env-claims-cite-source`).

**Four files change**: the three under `agents/`, plus `docs/METHOD.md`, which carries the
un-caveated delegation claim these two incidents falsify (added at grill — see *Grilled*). No
script changes, no test changes, no skill changes, and no `CHANGELOG.md` entry. Every edit is
body prose; no frontmatter field is touched in any file.

## The rule being added, in one place

The same three clauses go into all three agents, phrased for the role each time rather than
pasted identically:

1. **Source it.** Any claim about the filesystem, the environment, or what a file does or does
   not contain names the command that established it.
2. **Negative claims carry their scope.** "X does not exist", "this file never contains Y" is
   the easiest kind of claim to get wrong and the most expensive to act on, so it names the
   command *and what that command actually covered*.
3. **A sample is labelled as one.** A claim generalised from part of a file, or from some of the
   matches, says it is a sample and how large.

And, in the explorer only, a fourth thing that is not a sourcing rule at all:

4. **Never tell the caller what not to check.** Report what you found; do not narrow the
   evidence available to the caller.

## Steps

### 1. `agents/gantry-explorer.md` — extend the return contract, then add the prohibition

Extend `## What you return (the contract)` with the three sourcing clauses, written for a scout:
its whole output is claims about where things are and what is in them, so the rule is close to
its core job rather than an aside. Anchor it on the negative claim, which is the one that bit —
a `grep` over 26 lines establishes what those 26 lines say, and nothing about the rest.

Then add clause 4 as **its own short section**, not a fourth bullet in the contract. It is a
different kind of failure: the sourcing rule is about the quality of what you report, and this
one is about the boundary of the role. Say what it costs — an explorer that tells the caller to
skip a command has substituted its own confidence for the caller's evidence, and the caller has
no way to notice.

**One trap while writing the examples.** `scripts/verify.sh` fails the gate on any tracked
markdown matching `\.md:[0-9]+` — line-number citations rot on the first edit, so the repo bans
them outright. This change's whole subject is writing example commands into markdown, so an
illustrative "grep for it in that file at line 12" written the obvious way turns the gate red for
a reason that has nothing to do with the change. Write the examples without a line number.

*How I will know it worked:* both pieces read as instructions about what to write, not
statements of principle; the prohibition is findable by someone scanning headings; the
frontmatter block is byte-identical.

### 2. `agents/gantry-critic.md` — fold the rule into the existing provenance clause

The contract already ends with "say plainly which of your findings you checked against the code
and which you are inferring from the artifacts alone". That sentence is already about where a
claim came from, so the sourcing rule belongs *inside* it: rewrite the clause so it covers both
— which findings are code-checked, and, for any claim about the environment, the command behind
it, with the scope for a negative and the size for a sample.

Add the trap in the same place, because it explains why the rule earns its words here
specifically: a wrong fact attached to a real finding is more dangerous than a wrong finding,
since the finding's credibility carries the error past scrutiny. That is what happened — a
correct hazard, understated because its premise about the machine was false.

*How I will know it worked:* the clause is one coherent instruction rather than the old sentence
with a paragraph bolted after it; the trap is stated as the reason, not as decoration.

### 3. `agents/gantry-reviewer.md` — mirror it

Same three clauses, attached to the existing "one line on what you checked and what you did not"
close of its contract, which is the reviewer's version of the critic's provenance clause. Keep
it shorter than the other two: the reviewer has `Bash`, so naming the command it ran is the
cheapest possible compliance and needs less argument.

*How I will know it worked:* the reviewer's version is recognisably the same rule, and the file
does not grow a section the other two lack.

### 4. State the limitation where the rule is, and once at length in `docs/METHOD.md`

In each of the three agent files, **inside the section that states the rule**, one sentence: this
cannot be checked, so it holds only as far as the agent follows it. Do not soften it into "please
try to". CONTRIBUTING.md asks for exactly this — if a check can false-green, say so where someone
will read it — and a mitigation sold as a guarantee is the failure gantry exists to avoid.

Then say it once at length where someone auditing what the roster guarantees will actually look.
That place is `docs/METHOD.md`, not the changelog. Its delegation section currently ends "A
sub-agent reads 10,000 lines and returns a paragraph. The paragraph is what the orchestrator
needed" — which is precisely the claim these two incidents falsify, stated with no caveat. Add a
short passage after it covering three things:

- the two failures, in a clause each, as the evidence;
- that the mitigation is body prose and therefore unenforced — the tool list is the roster's only
  real boundary, and this is not in it;
- that a target repo overriding a role via `.claude/agents/<role>.md` gets its own agent and none
  of this rule, and nothing tells the driver the rule lapsed.

**No `CHANGELOG.md` entry.** The file's top section is `## 0.3.0`, described in its own body as
the first released version, and the repo has never used an `Unreleased` heading — so the entry
would either invent a convention or backdate this change into a shipped release. The record lives
in the PR body and in `docs/METHOD.md` instead.

*How I will know it worked:* a reader who only ever opens one agent file still learns the rule is
unenforced; a reader of METHOD.md's delegation argument is no longer told the returned paragraph
is simply what was needed.

### 5. Run the gate

```bash
bash scripts/context_budget.sh
git diff c220ab6 -- agents/ | grep -E '^[-+](description|name|tools|model):'   # must print nothing
bash scripts/verify.sh
```

The `git diff` grep is the one that proves the budget criterion directly rather than by
inference: `context_budget.sh` passing only shows the total is under the ceiling, which it would
also be if a description got *shorter*, or if a `description:` became a folded scalar whose first
line still matches. Its guard is `[ "$n" -le 1 ]` on the first `description:` match, so it is a
weaker net than "the descriptions are intact"; the grep is what actually shows no description
line moved.

**On whether the YAML is machine-validated — a correction, made under this change's own rule.**
Real frontmatter validation is `claude plugin validate agents --strict`, which `scripts/verify.sh`
runs only inside `if command -v claude`. An earlier draft of this step asserted the CLI was
"absent here", on the strength of `command -v claude` returning rc=1. That claim was false, and
false in precisely the way this change exists to prevent: the command had been run **inside the
Bash sandbox**, which is the scope it actually established. Unsandboxed, `command -v claude`
resolves to a path under `~/.local/bin`, and the gate run below reports
`plugin manifests validate → ok agents`.

So the frontmatter **was** validated on this run, by the CLI, and it passed. What remains true is
narrower: `verify.sh` skips that check wherever the CLI is missing, and `scripts/context_budget.sh`'s
own header states CI runners are such an environment — a claim read from that file, not one this
run verified. Where it is skipped, a broken `---` fence would pass the gate and the agent would
silently fail to load. The `git diff` grep is what makes that moot here: no frontmatter line
changed at all.

*How I will know it worked:* verify green, budget green, the grep silent.

## Test strategy

**No test is added** — but the honest reason is narrower than the first draft of this plan
claimed, and the critique was right to say so.

The strawman version is easy: a test that greps the agent files for the word "command" passes on
any file containing the word, and would be exactly the false-green CONTRIBUTING.md warns about.
Rejecting that proves nothing.

The real candidate is the one this repo already uses twice — an **agreement check**, of the shape
`verify.sh` applies to `frontmatter_status()` across the hook and the detector, and to
`examples/task.md` against the plan template. Applied here it would assert that all three agent
bodies still carry the rule, including the negative-scope and sample clauses. That is not
"detecting an unsourced claim", which is genuinely impossible from outside the model; it detects
the rule's *absence from a file*, which is mechanical. And it guards the likeliest regression
this change has: because the rule is phrased differently in each file on purpose, a later editor
trimming one agent can drop a clause from one of three, and every acceptance criterion here is
satisfied once at merge and never re-checked.

It is not being written here because the task puts any enforcement mechanism, lint, or new script
out of scope, and that exclusion is the ticket's, not this plan's to overturn. **It is deferred
explicitly, to `handover.md`, with the shape above** — so the next person gets a proposal rather
than a rediscovery. Recording it and not writing it is a worse outcome than writing it; silently
dropping it would be worse still.

What *is* checkable is the constraint the change must not violate, and that is already covered:
`scripts/context_budget.sh` (in `scripts/verify.sh`) fails if a `description:` grows past the
ceiling or stops being a single line, and the frontmatter validation in `verify.sh` fails on a
broken block. Step 5's `git diff` grep covers the remaining case — a description that changed
without growing.

The thing this change is actually meant to prevent — a sub-agent stating a false fact about the
machine — is not testable from outside the model at all. That is stated in the change rather
than worked around.

## What this run cannot verify

**The rule is untested by the run that introduces it.** This lane's own explorer and critic
dispatches are governed by the **installed** agent definitions at `c220ab6`, not the ones being
written here. The sourcing rule was applied by hand to this run's sub-agent dispatches instead —
which is not the same thing as the rule working, and goes in the pull request body as such.

**The change largely self-certifies, and that is a known weakness of this run.** `mode:` is
`unattended`, and criteria 1–5 and 8 are judgements about prose, assessed by the context that
wrote the prose. Each step's "how I will know it worked" is a self-assessment. The one
independent read is the `review` phase's reviewer, so **it must be told that the prose criteria
are the substance of the change** rather than left to infer it from a diff of three markdown
files — otherwise the only outside scrutiny goes looking for correctness defects in a change that
has no code in it.

**The YAML frontmatter validation is environment-dependent** — see step 5. It ran and passed on
this machine; it is skipped wherever the `claude` CLI is missing, which `context_budget.sh`'s
header says includes CI runners. The guarantee that does not depend on the environment is "no
frontmatter line changed", shown by a grep.

## Grilled

One critic pass (`gantry-critic`, dispatched cold against the two artifact paths): 1 blocking,
8 worth fixing, 4 noted. What each changed:

- **`CHANGELOG.md` has no `Unreleased` section** *(blocking)* → the changelog entry is dropped
  entirely. The top section is `## 0.3.0`, self-described as the first released version, so an
  entry would either invent a convention the repo has never used or backdate the change into a
  shipped release. The durable record moves to `docs/METHOD.md`, which is the better home anyway.
- **Step 4 edited a fourth file while the preamble said three** → preamble and *Affected areas*
  now name `docs/METHOD.md` explicitly.
- **`verify.sh`'s frontmatter validation is conditional on the `claude` CLI** → step 5 no longer
  claims verify.sh unconditionally catches a broken frontmatter block. The CLI turned out to be
  present on this machine and the check ran and passed; it is skipped wherever the CLI is missing,
  which `context_budget.sh`'s header says includes CI runners. The `git diff` grep is the stated
  environment-independent guarantee. (The critic's "absent here and on CI runners" was half right;
  see the correction at the foot of this file.)
- **`verify.sh` bans `\.md:[0-9]+` in tracked markdown, and this change writes example commands
  into markdown** → step 1 carries the warning, so a plausible example does not turn the gate red
  for an unrelated reason.
- **A repo overriding a role via `.claude/agents/<role>.md` gets none of this rule** → recorded
  in the `docs/METHOD.md` passage. The rule reaches the shipped roster only; nothing tells a
  driver that an override dropped it.
- **`docs/METHOD.md` argues delegation with no caveat** — "A sub-agent reads 10,000 lines and
  returns a paragraph. The paragraph is what the orchestrator needed" is exactly the claim these
  incidents falsify → that passage is now the length-version of the caveat. `ARCHITECTURE.md` and
  `SKILLS.md` describe tools, model and dispatch conditions only, not return contracts, so
  neither goes stale.
- **The test strategy attacked a strawman** → rewritten. The real candidate is an *agreement
  check* of the shape `verify.sh` already applies twice; it is deferred to `handover.md` with its
  shape written out, not dismissed. It is out of scope by the ticket's exclusion of any
  enforcement mechanism, which is not this plan's to overturn.
- **Acceptance criterion 8 was unfalsifiable** ("a place a reader will hit") → tightened in
  `task.md` to require the limitation inside the section that states the rule.
- **The change self-certifies under `mode: unattended`** → named in *What this run cannot verify*,
  with the consequence that the reviewer must be told the prose is the substance.
- **`context_budget.sh` does not fail on a folded-scalar `description:`** *(noted)* → step 5's
  description of the safety net corrected; it is weaker than the first draft claimed.
- **`GANTRY-5` exists nowhere in this repo** *(noted)* → confirmed independently
  (`grep -rn` over `docs`, `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`: no matches). The
  shipped files state the substance — four models read a clear written rule and all four ignored
  it — without citing an identifier a reader of the plugin cannot resolve.
- **`docs/ARCHITECTURE.md` says "Four agents ship" above a table of three** *(noted)* →
  pre-existing, from the `gantry-verifier` deletion, and outside this contract. Deferred to
  `handover.md`.
- **The critic reported the branch as `master`** *(noted)* → **refuted.**
  `git rev-parse --abbrev-ref HEAD` in this worktree returns `fix/agent-env-claims-cite-source`;
  its environment block was a stale snapshot. Worth recording that the critic labelled the claim
  as read from its environment rather than established by a command — which is the rule this
  change adds, working, in the run that adds it.

## Implemented — a correction worth keeping

Step 5 recorded a false environment claim made by this run's own driver, and the correction is
left in place rather than tidied away, because it is the best available evidence about the rule
this change adds.

The claim: "the `claude` CLI is absent here". The basis: `command -v claude` returning rc=1. The
scope that command actually covered: **the Bash sandbox**, not the machine. Unsandboxed the same
command returns a path, and the gate's own `plugin manifests validate` section reports
`ok agents`.

It is the same shape as the critic incident that prompted this ticket — a `~/.local/bin` path
reported absent when it was there — reproduced by the driver writing the fix, three phases after
reading the incident report. Which is the honest measure of how weak prose is here, and the
reason the caveat in `docs/METHOD.md` is stated as flatly as it is.
