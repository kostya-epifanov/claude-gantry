---
name: preserve
description: Writes a session handoff document capturing what exists only in the conversation — decisions and why they were made, alternatives rejected and on what grounds, what exploration established including dead ends, open threads, and the exact next action. Use when the user types "/gantry:preserve", or asks to "save the session", "write this down before we lose it", "preserve context", "hand off", or "checkpoint what we know" — and before a compaction, a break, or handing work to another session. Records the reasoning git cannot show, rather than the state git already has.
argument-hint: [label]
allowed-tools: Bash, Read, Write, Edit
---

# gantry:preserve

Write down what would be lost if this session ended right now.

`git status` and `git log` answer "where are we" — branch, sync, uncommitted files. All of that
is recomputable, and stale within minutes. This skill captures the opposite: *why* a decision was
made, which alternative was rejected and on what grounds, what exploration established, and what
the next concrete action is. None of that is in the repo, and re-deriving it costs a session's
worth of work — or worse, the next session silently contradicts it.

The output is a markdown file. The file is the deliverable; the chat summary is not.

**Only the model knows when context is about to be lost**, so this is model-invocable. Reach for it
unprompted when a substantial session is approaching compaction, or when meaningful reasoning has
accumulated that the repo doesn't hold — not routinely, and not after a one-step task.

## Steps

### 1. Resolve the path

```bash
bash "$GANTRY/skills/preserve/scripts/doc_path.sh" "$ARGUMENTS"
```

`$GANTRY` is this skill's plugin root — resolve it from this file's own location, the way `status`
and `skill` do, never a hardcoded path.

It prints `DOC` (the path), `EXISTS` (whether a doc for today's slug is already there), and
`RECENT` (other handoff docs for this repo, newest first). Two decisions are baked into it, so
don't re-derive them:

- **Path is `~/.claude/sessions/<repo-path-slug>/<YYYY-MM-DD>-<slug>.md`**, slug = the `[label]`
  argument or the current branch. Same day + same slug ⇒ same file, which is what makes re-running
  update rather than litter.
- **Outside the repo, deliberately.** A worktree-isolated session cannot write to the main
  checkout at all; worktrees get pruned, so a note stored in one dies with it; and nothing outside
  the repo can be swept into a commit by `git add -A`. The repo slug keys off the **main** repo,
  so every worktree of a repo files into one directory, beside that repo's auto-memory. To share a
  note deliberately, copy it into the repo and commit it.

Use the printed `DOC` path verbatim — don't reconstruct it.

### 2. If a document already exists, read it first

`EXISTS=yes` → **Read it before writing.** You are updating, not regenerating. Preserve every
decision and finding already recorded (they may come from context you no longer have); add what's
new; rewrite only "Where we are" and "Next action", which describe the present. Move anything from
Open threads that has since been resolved into Decisions or Findings.

If `RECENT` lists a doc that's clearly the same thread of work under a different slug, skim it so
you don't re-record what it already holds.

### 3. Gather from the conversation, not the repo

The source material is **this conversation**: what was tried, what the user corrected, what got
ruled out, what a search proved absent. Scan back through it deliberately — the earliest decisions
are the ones most likely to have scrolled out of easy reach and are often the load-bearing ones.

Do not go re-read the codebase to pad the document. If a fact is in the code, the next session can
read the code.

### 4. Write the document

```markdown
# <short title> — <YYYY-MM-DD>

Branch `<branch>`. <One line: what this session set out to do.>

## Where we are
<A sentence or two: the current task and its actual state. "Skill written and validated,
not yet committed" — not "in progress".>

## Decisions made, and why
- **<Decision>** — <the reasoning>. Rejected: <alternative> because <grounds>.

## Findings
- <What exploration established, with the identifier that makes it actionable.>
- <Negative findings especially: "X looks like it does Y, but doesn't — it actually Z.">

## Open threads
- <Question asked but unanswered, or work started and not finished.>

## Next action
<One concrete step, specific enough to act on with no memory of this conversation.>
```

Rules that decide whether this is worth anything:

- **Name things concretely.** `src/parse.rs:index_line` and the exact command, not "the parser" or
  "the validation step". A cold reader cannot resolve your pronouns.
- **Every decision carries its why.** A decision without its reasoning gets re-litigated by the
  next session; that is the single most expensive failure this document prevents. Where an
  alternative was seriously considered, name it and say what killed it.
- **Record only what actually happened.** Never infer a decision that was never made, and never
  invent a rationale for a choice that was arbitrary — say "arbitrary, revisit if it matters".
  Anything still unresolved goes under **Open threads**; do not quietly resolve it in the write-up.
- **Negative findings are the highest-value lines in the file.** "The config looks like it's read
  at startup but isn't" is exactly what a fresh session burns an hour rediscovering.
- **Don't duplicate what git already reports.** No sync state, no uncommitted-file lists, no commit
  dumps — it goes stale immediately and git recomputes it on demand. One line of git context, at most.
- **Don't summarize the codebase or replay the transcript.** Both are available elsewhere.
- **Omit an empty section** rather than padding it. A short honest document beats a long one.

### 5. Cold-start check before you finish

Read the file back and answer honestly: **could a session with no memory of this conversation pick
up from this file alone?** Specifically — is the next action executable without asking a question,
and does every decision explain itself? Fix what fails; that check is the whole point.

If the session genuinely holds nothing worth preserving, say so and write nothing. An empty
document is worse than none — it reads as "nothing happened here" to the next session.

## Report

The **full path** to the document, on its own line so it's easy to open or hand off. Whether it was
created or updated, and a one-line note of what it covers. Nothing more — the file is the artifact.
