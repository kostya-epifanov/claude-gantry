# Contributing

## Before you open anything

Run the checks:

```bash
bash scripts/verify.sh
```

That is lint, manifest validation, frontmatter validation, link checking, and the secret scan. CI
runs the same script, so a green local run means a green CI run.

## Adding a skill

A skill is a directory under `skills/` with a `SKILL.md` in it. The `name:` in the frontmatter must
match the directory name — `scripts/verify.sh` checks that. Then:

```bash
claude plugin validate . --strict          # the manifest
claude plugin details gantry@claude-gantry # what it costs every session
```

The `description` is the whole trigger surface and is paid in every session, so write it last, when
you know exactly what the skill does. Document the new skill in `docs/SKILLS.md` and the README
table in the same commit.

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

The suite already does that against fixture repos, and is the fastest way to see a change land:

```bash
bash tests/run.sh                 # every case, one line each
bash tests/run.sh hook_           # just the cases whose name matches
```

Each case is standalone — `bash tests/cases/<name>.sh` runs one on its own. A change to
`lib/run_gates.sh` or `hooks/readiness-gate.sh` should arrive with a case, and the honest check on a
new one is that it fails before your fix and passes after.
