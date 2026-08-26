# Contributing

## Before you open anything

Run the checks:

```bash
bash scripts/verify.sh
```

That is lint, manifest validation, frontmatter validation, link checking, and the secret scan. CI
runs the same script, so a green local run means a green CI run.

## Adding a skill

Use the plugin's own skill for this — it exists precisely so new skills come out consistent:

```
/gantry:skill <name>
```

It scaffolds `skills/<name>/SKILL.md`, validates the frontmatter, measures what the skill adds to
every session's always-on context, proves it actually registered, and reminds you to document it.

## House style

- **Bodies under 500 lines.** A skill body stays in context for the whole session once it fires.
  Long-form detail belongs in `references/`, loaded only when the body says to read it.
- **Scripts, not generated code**, for anything deterministic or repeated. Say explicitly whether
  the model should *run* the script or *read* it — running is almost always right.
- **Descriptions say what it does *and* when to use it.** That sentence is the whole trigger
  surface, and it is what every session pays for.
- **Document the limits.** Every honest caveat in these docs is load-bearing. If a check can
  false-green, say so where someone will read it.
- **Commits:** concise imperative subject, no `Co-Authored-By` trailer, no time annotations.

## Testing a change locally

```bash
claude plugin validate . --strict
claude --plugin-dir .          # load without installing
```

For the gate and hook, exercise them in a throwaway repo rather than a real one — both are
designed to refuse things, and you want to see them refuse.
