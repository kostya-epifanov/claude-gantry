# The readiness hook

The operational reference for `hooks/readiness-gate.sh`: what it writes, how to tell whether it is
registered and whether it ran, its one honest limit, and how it got to its current shape. The
[README](../README.md) has the short version; [METHOD.md](METHOD.md) has the argument for why the
gate had to leave the prompt; [ARCHITECTURE.md](ARCHITECTURE.md#the-readiness-hook) has the three
implementation details that are easy to get wrong.

## What it is

`lib/run_gates.sh` is a rule the chain follows. The hook is what makes it a rule the model cannot
skip. It is registered for `Stop` and `SubagentStop` with matcher `*` in the plugin's own
`hooks/hooks.json`, with a 300-second timeout. When the model tries to end its turn, the hook
re-runs the gate out of band and blocks the stop with exit 2 while the tree is red. It holds no
state: no attempt counter, no lock, nothing written to `task.md`. The retry cap and the
`status: blocked` transition live in the orchestrator.

## When it fires

Only when all three hold:

1. `task.md` exists at the repo root, **and**
2. `.claude/gates.sh` exists at the repo root, **and**
3. `task.md`'s frontmatter says exactly `status: implementing`.

None of those appear by accident. **Creating `.claude/gates.sh` is the opt-in.** Outside that window
the hook parses stdin, makes two file tests, and exits 0 with no perceptible delay.

The window is deliberately narrow. `/gantry:implement` sets `status: implementing` before it
touches a file, and every other status (`planning`, `planned`, `grilled`, `implemented`,
`reviewed`, `shipped`, `blocked`) leaves the hook inert. That matters for `SubagentStop`: the
matcher is `*`, so every sub-agent's stop runs the hook, but no gantry sub-agent runs inside the
window. `implement` dispatches nobody, and the explorer, critic and reviewer run under other
statuses. Widening the matcher is the easiest way to make the hook fire constantly and get switched
off, and a read-only sub-agent blocked with exit 2 cannot fix anything anyway.

The repo root is the worktree the session is actually in, resolved from the payload's `cwd` with
`git rev-parse --show-toplevel`. `$CLAUDE_PROJECT_DIR` is only a fallback, because it stays pinned
to the checkout the session launched from, and under `/gantry:worktree` that is the wrong tree.

## What it writes

**Only once the repo has opted in.** A repo with no `task.md` or no `.claude/gates.sh` is left
completely alone: no directory, no log line, nothing. The two file tests run before anything is
written, and they run before `stop_hook_active` is read, which is safe because a repo that never
runs the gate can never produce the block a later stop would be caused by.

Once both files exist, every invocation appends one line to `.claude/artifacts/gate-hook.log`,
fire or skip, with its reason. A fire writes two lines, an `arm` line before the gate starts and an
outcome line after it ends, plus the gate's full output to
`.claude/artifacts/gate-<timestamp>-<pid>.log`. `/gantry:implement` asserts `.claude/artifacts/`
into `.git/info/exclude` each time it runs the gate, so none of that reaches your diff. Add it to
your `.gitignore` only if you arm the hook without going through `implement`.

If the artifacts directory cannot be created, the gate still runs and is still enforced; the
verdict says plainly that no artifact exists. Logging being unavailable is never a reason to fail
open.

## How to tell whether it is registered

**Grepping `settings.json` will not find it.** gantry registers the hook at *plugin* level, in the
plugin's own `hooks/hooks.json`, so a search of your project or user settings finds nothing and
proves nothing: it is neither evidence that the hook is absent nor that it is present. More than one
run has grepped project settings, found nothing, and published "no hook is registered", a
conclusion the search cannot support in either direction.

What does settle it is `/plugin`, which shows whether gantry is installed and enabled.

`lib/detect_stage.sh` cannot settle it either. Its `HOOK:` line reports `conditions-met` or
`conditions-unmet`, which is the firing conditions above and nothing more. The detector resolves the
repo root and can see `.claude/gates.sh` and `task.md`'s status; registration lives in the plugin
root, which it has no handle on. So `conditions-met` means "this run would have been enforced if
the hook is installed", one step short of "this run was enforced", and the phase reports read it
exactly that way. The value used to be `armed`, and was renamed because `armed` claimed the step it
could not see.

## How to tell whether it ran

`.claude/artifacts/gate-hook.log` answers this, but only in a repo that has already opted in. With
`task.md` and `.claude/gates.sh` both present, every invocation appends a line, so an empty log
after a stop means the hook did not run.

**Before the opt-in it proves nothing.** The hook tests for those two files first and exits without
creating `.claude/artifacts/` at all, so a missing log there is the designed behaviour of a
registered hook, not evidence of an absent one. `GANTRY_READINESS_GATE=off` and an unresolvable
root are two more silent exits. That un-opted-in repo is exactly the one a reader checking this
usually has.

## The honest limit

The trigger is `task.md`'s `status:`. That is a file the model can write. A model that set
`status: blocked` early would disarm its own gate, and nothing in the design prevents that. So
*"the model cannot bypass the gate"* is approximately, not exactly, true.

The mitigation is the audit trail above: a bypass is not prevented, it is made visible after the
fact. For a tool whose whole point is that you can trust what it reports, a log you can grep is
worth more than a stronger claim that cannot be backed.

One more path is worth knowing. The hook wraps `run_gates.sh` in no timeout, because a portable
timeout-with-cleanup is the kind of machinery this script exists not to have. A gate that hangs
therefore hangs the hook until the harness kills it at the 300-second limit, and a killed hook
produces no exit 2: the stop proceeds un-gated. That is the one remaining path where the guarantee
silently fails, which is why the `arm` line is written before the gate starts. **An `arm` line with
no matching outcome is the signature of a stop that was never gated.**

## Exit codes

Every exit in the file is 0 or 2, on purpose. Only exit 2 blocks a `Stop` hook; exit 1 is a
non-blocking hook error that fails open, which is why the script never uses `set -e`. A gate exit of
2 ("could not run") is red here, not exempt: from where the hook stands, a gate that could not run
has not proved the tree good. A missing or unreadable `run_gates.sh` is a broken install of the
hook's own wiring and fails red too. Loop termination is `stop_hook_active` alone: the harness sets
it true on a stop that was itself caused by a previous block, and the hook defers unconditionally
when it is true, or when parsing it fails. ARCHITECTURE.md covers why each of those is shaped that
way.

## Turning it off

```
export GANTRY_READINESS_GATE=off
```

Claude Code offers no way to accept a plugin but decline its hooks, so the switch exists to remove
the only fair objection to shipping the hook registered.

## How it got here

- **v0.1** shipped the hook, but only the delegated pipeline wrote a `task.md`, so under the
  headline skill the gate was never actually enforced. The guard was real; nothing had switched it
  on.
- **v0.2** made every mode write `task.md`, so the hook arms in all three. The firing condition
  itself did not change.
- **v0.3** fixed three things. The hook resolved its root from `$CLAUDE_PROJECT_DIR` and so read
  the main checkout's `task.md` on every worktree run, skipping forever on gantry's own default
  workflow. It logged only after the gate returned, so the one path where a stop proceeds un-gated
  left no trace. And it created `.claude/artifacts/` in every repo you opened, before checking
  whether the repo had anything to do with gantry.
- **v0.4** renamed the detector's `HOOK:armed` to `HOOK:conditions-met`, for the reason above.

The first version of this file was 473 lines: an attempt counter, a lock file, per-task keying, a
fail-open matrix, an escalation path. Two review rounds found 24 defects in it, and the second
round's criticals were introduced by the first round's fixes. The fix was deleting the state, not a
third patch. [METHOD.md](METHOD.md#what-we-deleted) tells that story.
