---
name: skill
description: Create a new skill in the gantry plugin — scaffolds SKILL.md, validates it, documents it, and commits. Use when the user types "/gantry:skill" with a skill name, or asks to create, add, or scaffold a new skill.
argument-hint: [skill-name]
---

# gantry:skill

Scaffold a skill, validate it, prove it registered, document it, commit it.

`/gantry:skill deploy` → a skill invoked as `/gantry:deploy`.

## Where this writes

Resolve `$GANTRY` from **this file's own location**, never a hardcoded path — the plugin lives at
a different path under every install shape. Then read which shape you are in, because it decides
where the new skill goes:

- **`$GANTRY` resolves under `~/.claude/plugins/`** — this is an *installed* copy. Treat it as
  read-only: editing it works until the next `plugin update` silently discards your changes.
  Scaffold a standalone skill at `~/.claude/skills/<name>/SKILL.md` instead (it loads next session
  as `<name>@skills-dir`), and **say plainly that this is what you did and why**.
- **`$GANTRY` resolves inside a git checkout you can write to** — you are developing gantry
  itself. Scaffold at `$GANTRY/skills/<name>/SKILL.md`.

```
$GANTRY/
├── .claude-plugin/plugin.json     # name: gantry → the /gantry: namespace
└── skills/<name>/SKILL.md         # → /gantry:<name>
```

## Steps

### 1. Parse the name

`$ARGUMENTS` is the skill name, used verbatim as the directory under `$GANTRY/skills/` and therefore
as the command after `gantry:`. Validate: lowercase letters/digits separated by single hyphens, ≤64
chars, not containing `claude` or `anthropic` (reserved). No `gantry-` prefix — the plugin supplies
the namespace. If no argument was given, ask what the skill should be called.

If `$GANTRY/skills/<name>` already exists, stop and ask whether to edit the existing skill instead.

### 2. Harvest the intent before asking for it

If this session already contains the workflow being captured — the user says "turn this into a
skill" after working through something — read it out of the conversation first: the steps taken,
the tools used, the corrections the user made, the formats involved. Ask only about what's missing.

Skills are worth writing for procedures you keep re-explaining. A skill that documents an imagined
requirement is worse than no skill, because it costs context in every session that loads it.

### 3. Settle what determines the frontmatter

Four questions, in order of leverage:

1. **What should it do?**
2. **When should it trigger** — what would the user actually type?
3. **Who invokes it?** Both (default), you only (`disable-model-invocation: true`), or Claude only
   (`user-invocable: false`).
4. **Does it have side effects?** Writes, commits, deploys, sends, or relocates the session → gate
   it to manual invocation.

Read [references/authoring.md](references/authoring.md) before writing — it has the field table,
the description rules, the body budget, and the anti-patterns.

### 4. Write SKILL.md

Into `$GANTRY/skills/<name>/SKILL.md`. Keep the body under 500 lines; it stays in context for the
whole session once loaded. Push detail into `references/` and deterministic work into `scripts/`.

### 5. Validate — a loop, not a one-shot

Two checks, covering different things. `claude plugin validate` reads the manifest and never looks
at a skill's frontmatter; `validate_skill.py` does the opposite.

```bash
claude plugin validate "$GANTRY" --strict
uv run "$GANTRY/skills/skill/scripts/validate_skill.py" "$GANTRY/skills/<name>"
```

Fix and re-run until both are clean. Errors are real; warnings are judgment calls worth a look.

Both commands fail under the Bash sandbox — `uv`'s cache and the repo both sit outside the
writable paths, giving `Operation not permitted`. That's a sandbox restriction, not a broken
command; retry per the usual rules for a sandbox-caused failure.

### 6. Check what it costs

```bash
claude plugin details gantry@claude-gantry   # id depends on install shape; `claude plugin list` confirms
```

The **always-on** column is what every session pays just to know the skill exists — roughly the
description. **On-invoke** is the body, paid each time it fires. If a new skill adds meaningful
always-on weight, that's the prompt to reconsider step 3.

The projection does **not** account for `disable-model-invocation` (measured: identical always-on
with and without it), so for a gated skill — whose description is meant to stay out of the listing
entirely — treat the always-on figure as an upper bound rather than what you actually pay.

### 7. Prove it registered

Live change detection covers `SKILL.md` **text only** — a brand-new skill directory inside a
plugin isn't picked up. Run `/reload-plugins`, then confirm:

```bash
claude plugin details gantry@claude-gantry   # <name> appears under Skills
```

Report whether `/gantry:<name>` is actually invocable. A skill that exists but doesn't load is the
failure mode worth catching here, and it's invisible unless you look.

### 8. Document it

Developing gantry itself: add a row to the table in `docs/SKILLS.md` and to the skills table in
`README.md` — the invocation and what it does. A standalone skill has no table to update; skip
this and say so.

### 9. Evals, when they'd pay

For skills whose output is objectively checkable, the harness is built in:

```bash
claude plugin eval gantry@claude-gantry --case '<name>*' --ablation with-without
```

That runs each case against the plugin *and* a no-plugin baseline, reporting the delta — so you
learn whether the skill helps, not just that it fires. `claude plugin eval init` authors a suite
interactively. Skip it for subjective work; offer, don't insist.

### 10. Commit

Only when the plugin root is a git checkout you own: stage just the new skill and the docs you
touched. Concise imperative message, **no `Co-Authored-By` trailer and no time annotations** —
gantry's house style. Ask before pushing. If you scaffolded into an installed plugin cache there
is nothing to commit — say so rather than inventing a repo.

## Report

The command (`/gantry:<name>`), the file path, validator results, its always-on and on-invoke cost,
whether it loaded, and the commit. Say plainly if anything is unverified.
