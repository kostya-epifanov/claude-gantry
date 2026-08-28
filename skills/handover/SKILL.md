---
name: handover
description: Write handover.md at the worktree root — the findings this change deliberately did not address, why each is out of scope, what was already tried, and the exact next action. Committed with the branch so it reaches the reviewer. Use when the user types "/gantry:handover", or says work is too big, out of scope, or should be handed off.
argument-hint: [what is being handed over]
allowed-tools: Bash, Read, Write, Edit
---

# gantry:handover

Write down the work this change is **not** doing, so that deciding not to do it is a recorded
decision rather than an omission. The file lands at the worktree root as `handover.md`, is
committed with the branch, and therefore arrives in front of whoever reviews the pull request.

Called by `/gantry:review` for anything it deferred, and useful typed on its own the moment a task
turns out to be bigger than its contract.

## This is not `gantry:preserve`

They write different things for different readers, and confusing them loses one of them:

| | `gantry:handover` | `gantry:preserve` |
|---|---|---|
| Captures | deferred **work** — what was not done | conversation **reasoning** — why what was done, was done that way |
| Written to | `handover.md` in the repo | your session directory, outside the repo |
| Read by | whoever reviews or picks up the PR | the next session, or you after a break |
| Survives | the merge, in the branch's history | the context window |

If what you have is "here is why we chose this design", that is `/gantry:preserve`. If it is "here
is what we found and left alone", it is this skill. Doing both is fine and often right.

## Steps

### 1. Detect the stage

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

- `PHASE:not-a-repo` → stop; there is nowhere to write it.
- **`HANDOVER:present`** → **read it and add to it. Never overwrite.** A second deferral in the same
  branch appends; it does not replace the first. Merge duplicate findings rather than listing them
  twice.
- `TASK:present` → read `task.md`'s *Out of scope*. It usually already contains half of what you
  are about to write, and quoting it is stronger than restating it.

### 2. Write `handover.md`

One section per deferred item, and nothing else. The shape:

```markdown
# Handover — <branch>

Deferred from <task title>. The change itself is complete; these are findings it did not absorb.

## <short name of the finding>

**What it is.** The defect, gap, or opportunity, concretely enough to be found again — name files
and symbols, not areas.

**Why it was deferred.** The actual reason: out of the task's scope, needs its own plan, a
pre-existing bug this change only revealed, or a decision that isn't the author's to make.

**What was already established.** What is known, including what was tried and did not work. This is
the part that stops the next person repeating a dead end.

**Next action.** One concrete thing someone could start on tomorrow. Not "investigate X" — the
specific first step.
```

Three rules for the writing:

- **Concrete over tidy.** A file and a symbol beat a category. Someone will read this cold.
- **Say what you do not know.** A finding you are unsure is real should say so, rather than being
  dressed up or dropped.
- **No apologies and no padding.** Deferring in-scope-adjacent work is normal engineering, not a
  failure to confess. One paragraph per heading is usually enough.

Do not repeat the change's own summary here — that belongs in the commit and the PR body. This file
is only about what is *left*.

### 3. Reflect it in `task.md`, if there is one

Add the deferred items to *Out of scope* in one line each, pointing at `handover.md` for the
detail. The contract and the handover should not disagree about what this task covered.

Leave `status:` alone unless the deferral means the task itself cannot ship — then set
`status: blocked` and say so plainly in the report. Handing work over is normally not a block.

## Report

The `handover.md` path, how many items it now carries, and whether this run appended to an existing
file or created it. If the task is blocked rather than merely narrowed, lead with that.
