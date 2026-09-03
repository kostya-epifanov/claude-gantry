# Contributing

## Before you open anything

Run the checks:

```bash
bash scripts/verify.sh
```

That is lint, manifest validation, frontmatter validation, link checking, and the secret scan. CI
runs the same script, so a green local run means a green CI run.

**The converse does not hold, and that is deliberate.** `verify.sh` enumerates tracked files *and*
untracked ones that no ignore rule covers, because the files a gantry run writes — `task.md`,
`plan.md`, a new `lib/*.sh` — are still untracked when the gate runs and tracked by the time CI sees
them. Checking only what is committed made the gate blind to exactly those files. The price is that
a **red** local run can be caused by something CI will never see: an untracked virtualenv, a
scratch directory, a stray copy of a file. The remedy is the ordinary git one — add the path to
`.gitignore` if it concerns everyone, or to `.git/info/exclude` if it is only yours. Do not narrow
the enumeration in `verify.sh`; that restores the blind spot.

One caveat on that, worth knowing before you debug a disagreement: `--exclude-standard` also honours
your global `core.excludesFile`, which nobody else has. Two contributors can therefore enumerate
different file sets from the same tree. It cannot cause a green-here-red-in-CI split — a globally
ignored file never reaches CI either — but it can explain why a check fires for one of you and not
the other.

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
- **Commits:** concise imperative subject, no time annotations.

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
