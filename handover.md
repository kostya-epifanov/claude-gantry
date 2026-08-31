# Handover — fix/agent-env-claims-cite-source

Deferred from *Make sub-agents source their environment claims, and stop them narrowing the
caller's evidence*. The change itself is complete and the gate is green; these are findings it did
not absorb.

## An agreement check that all three agents still carry the rule

**What it is.** `scripts/verify.sh` has no assertion that the sourcing rule is present in
`agents/gantry-explorer.md`, `agents/gantry-critic.md` and `agents/gantry-reviewer.md`. The rule is
phrased differently in each file on purpose — the explorer and critic cite *searches* because they
have only `Read`, `Grep` and `Glob`; the reviewer cites *commands* because it also has `Bash` — so
there is no single string to grep for, and a later editor trimming one agent can drop the
negative-scope clause or the sample clause from one of the three without anything noticing.

This is not the impossible check. Detecting whether a claim an agent *made* was sourced cannot be
done from outside the model, and this task rules it out for that reason. Detecting whether the
rule is still *present in a file* is mechanical, and this repo already does exactly that kind of
check twice: the `frontmatter_status()` drift check between `hooks/readiness-gate.sh` and
`lib/detect_stage.sh`, and the parity check between `examples/task.md` and the plan template.

**Why it was deferred.** `task.md`'s *Out of scope* excludes any enforcement mechanism, lint, or
new script. That exclusion came from the ticket, not from this plan, so it is not this change's to
overturn. The finding came from the grill and is recorded rather than dropped.

**What was already established.** The three clauses are present in all three files today, verified
by reading each file and by matching the phrases across line breaks — note that a plain
line-oriented `grep` gives a false negative here, because the sentences wrap. The naive check
(`grep -c "names the command that established it"`) returns 0 for `agents/gantry-critic.md` purely
because the phrase spans a newline; `tr '\n' ' ' < agents/gantry-critic.md | grep -o ...` finds it.
A check written the obvious way would false-green in the opposite direction — it would report the
rule missing when it is there — so whoever writes this needs to normalise whitespace first. That
is the dead end worth not repeating.

**Next action.** Add a `head2 "the sourcing rule is present in every agent"` block to
`scripts/verify.sh` that, for each file in `agents/*.md`, squeezes newlines to spaces and asserts
the presence of three things: a sourcing sentence, the negative-claim scope clause, and the sample
clause. Decide deliberately whether to assert the "nothing enforces this" caveat too — it is the
clause most likely to be trimmed as boilerplate, and the one whose loss matters most.

## `docs/ARCHITECTURE.md` says "Four agents ship" above a table of three

**What it is.** The `## The agent roster` section opens "Four agents ship, and **every one of them
is read-only**", and the table beneath it lists three: `gantry-explorer`, `gantry-critic`,
`gantry-reviewer`. `agents/` contains exactly those three files.

**Why it was deferred.** Pre-existing and unrelated to this change — it is residue from the
`gantry-verifier` deletion described later in the same document, which the 0.3.0 notes record.
This branch does not touch `docs/ARCHITECTURE.md`, and widening a prose change to sweep up an
unrelated prose defect is how a focused diff stops being reviewable.

**What was already established.** The count is the only thing wrong; the table itself is accurate,
and the paragraphs around it that explain why there is no planner, implementer or verifier agent
are all consistent with three.

**Next action.** Change "Four agents ship" to "Three agents ship" in `docs/ARCHITECTURE.md`. It is
a one-word fix and needs no plan; it wants a separate commit only so it is not buried in this one.

## The rule does not reach a repo that overrides an agent

**What it is.** Role resolution is per role, repo first: a target repo defining
`.claude/agents/critic.md` gets that file dispatched instead of `gantry-critic`, contract and all.
Such a repo receives none of the sourcing rule, and nothing tells the driver the guarantee lapsed
— the run reports a critic ran, which is true and no longer means what it meant.

**Why it was deferred.** Closing it means either a phase skill checking the resolved agent for the
rule (an enforcement mechanism, excluded by the contract, and it would also be the same
false-greenable string match as above) or documenting the requirement for repo authors, which is a
docs decision about a public extension point rather than part of this fix.

**What was already established.** The gap is now written down where a reader auditing the roster's
guarantees will meet it — `docs/METHOD.md`, in the passage this change added after the delegation
argument. So it is disclosed; it is not addressed.

**Next action.** Decide whether an overriding repo is expected to carry gantry's agent contract.
If yes, say so in `docs/ARCHITECTURE.md` beside the "resolution is per role, repo first"
paragraph, and give repo authors the three clauses to paste. If no, say that too — an override is
then explicitly a repo taking full responsibility for its own agent's return contract.
