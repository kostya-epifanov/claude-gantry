#!/usr/bin/env bash
# detect_stage.sh — read-only snapshot of where a task sits on the gantry chain
# (plan -> critique -> grill -> implement -> review -> ship), for every phase skill.
#
# Why this exists: the phase skills are individually invocable, so you can drop
# out of the chain, edit by hand, and come back. That means no phase may infer
# where it is from the conversation — a fresh session, a subagent, and a
# resumed one must all reach the same answer. They reach it here.
#
# Read-only: runs `git` queries and reads two files. Modifies nothing.
# Run with: bash detect_stage.sh   (from anywhere inside the target repo/worktree)
#
# stdout — labeled lines, then one PHASE line:
#   ROOT:<path>                repo/worktree root; artifacts are read from here
#   BRANCH:<name>              or  DETACHED
#   TASK:present|absent|inherited
#                              task.md at ROOT. `inherited` means it is the PREVIOUS task's
#                              contract, merged and carried in on the branch, rather than one
#                              in flight — see task_is_inherited() for the exact rule and for
#                              why every uncertain case degrades to `present`.
#   PLAN:present|absent        plan.md at ROOT
#   HANDOVER:present|absent    handover.md at ROOT
#   REVIEW:absent|pending|applied|clean
#                              review.md at ROOT — the findings gantry:review recorded as in
#                              scope to fix, and whether the fix step still has work to do.
#                              See review_state() for the rules.
#   QA:absent|exercised|unrunnable|no-agent|no-scenarios|unknown
#                              qa.md at ROOT — what gantry:qa recorded about the task's e2e
#                              scenarios. `absent` is no file; the rest is the file's
#                              `outcome:` line. See qa_state() for the rules.
#   STATUS:<value>|none        task.md frontmatter status:
#   FORKS:open|none|unknown|absent
#                              whether task.md's "Open questions" section still holds a fork
#                              nobody has decided. See open_questions_forks() for the rules.
#   HUMAN_ONLY:present|none|absent
#                              whether task.md's `human_only` block — the acceptance checks no
#                              automated gate can make — holds any entries. See
#                              human_only_state() for the rules.
#   E2E:present|none|absent    whether task.md's `e2e.scenarios` block — the scenarios
#                              gantry:qa runs against the built app — holds any entries.
#                              See e2e_state() for the rules.
#   GATES:present|absent       .claude/gates.sh — the readiness hook's opt-in
#   QA_ROLE:present|absent     .claude/agents/qa.md — the repo's qa agent, gantry:qa's opt-in.
#                              There is no default; absent is the normal case.
#   QA_ENV:present|absent      .claude/qa-env.sh — the script that builds and boots the app
#   HOOK:conditions-met|conditions-unmet
#                              whether the readiness hook's FIRING CONDITIONS hold — GATES
#                              present AND STATUS exactly implementing. It is not a claim
#                              that the hook will fire: registration is invisible here. See
#                              the comment above the check for why that is not detectable.
#   DIRTY:clean                or  DIRTY:staged=<n> unstaged=<n> untracked=<n>
#   NEXT:<command>             the phase skill that advances from here
#   PHASE:<plan|critique|grill|implement|review|ship|done|blocked|not-a-repo>
#
# PHASE is derived from STATUS when task.md carries a known one, and inferred
# from which artifacts exist when it does not — a hand-written task.md with no
# status, or none at all, still resolves rather than erroring.
set -uo pipefail

[ $# -eq 0 ] || { echo "detect_stage: takes no arguments" >&2; exit 2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "PHASE:not-a-repo"; exit 0; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$ROOT" ] || { echo "PHASE:not-a-repo"; exit 0; }
echo "ROOT:$ROOT"

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
if [ -z "$BRANCH" ]; then echo "DETACHED"; else echo "BRANCH:$BRANCH"; fi

# --- frontmatter status (task.md's leading --- block only) ------------------
# KEPT BYTE-IDENTICAL to frontmatter_status() in hooks/readiness-gate.sh. The
# hook decides whether to BLOCK a stop on this field; this script decides which
# phase to report. If the two ever disagreed, a run could look "implementing"
# to one and not the other, and the gate would silently stop arming. They are
# duplicated rather than sourced so the hook keeps no runtime dependency it
# could fail to resolve — and scripts/verify.sh diffs the two copies, so the
# duplication cannot drift unnoticed.
frontmatter_status() {
  local f="$1"
  [ -f "$f" ] || return 0
  # Strip a leading UTF-8 BOM before awk ever sees the file (byte-literal
  # match via ANSI-C quoting, portable across BSD/GNU sed — no \xNN escape
  # syntax needed). LC_ALL=C keeps this a byte match regardless of locale.
  local bom
  bom=$'\xef\xbb\xbf'
  local raw
  raw="$(LC_ALL=C sed "1s/^${bom}//" "$f" 2>/dev/null | awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      sub(/\r$/, "", s)
      return s
    }
    !started {
      if ($0 ~ /^[[:space:]]*\r?$/) { next }        # skip leading blank lines
      started = 1
      if ($0 ~ /^---[[:space:]]*\r?$/) { infm = 1; next }
      exit                                          # no frontmatter block at all
    }
    infm && $0 ~ /^---[[:space:]]*\r?$/ { closed = 1; exit }
    infm && !done && $0 ~ /^status:/ {
      val = $0
      sub(/^status:[[:space:]]*/, "", val)
      sub(/[[:space:]]+#.*$/, "", val)              # trailing "# comment"
      result = trim(val)
      done = 1
    }
    # Print only if the frontmatter block actually closed — an unterminated
    # fence must not fall through into scanning the body for a status: line.
    END { if (closed && done) print result }
  ' 2>/dev/null)"
  # Strip one layer of surrounding matching quotes (single or double).
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  printf '%s' "$raw"
}

# --- open questions (the fork precondition) ---------------------------------
# Reports whether task.md's "Open questions" section still holds a fork nobody
# has decided. A fork left open there is a decision the implementer would end
# up making alone, so the phase skills refuse to advance past it — which means
# this answer has to be a fact rather than a reading, and the rules have to be
# written down rather than inferred:
#
#   heading      an ATX heading at any level whose text is "Open questions",
#                matched case-insensitively and tolerant of a closing "##" run,
#                a trailing colon, and bold/italic wrappers.
#   section end  the next ATX heading at any level, or end of file. In this
#                repo's own task.md the section is last, so EOF must terminate.
#   fences       ``` and ~~~ blocks are invisible everywhere in the file. The
#                task template shows the checkbox convention inside a fence for
#                exactly this reason: a literal unchecked box in the template
#                would otherwise make every freshly written task.md read as
#                open, and block every unattended run forever.
#   list item    a -, * or + bullet OR an ordered "1." / "1)" marker, at any
#                indentation and through any depth of blockquote, with or
#                without a space after the marker. A horizontal rule is not one.
#   settled      the item's text begins with [x] or [X]. An unchecked box, or a
#                bare bullet with no box at all, reads as OPEN — a fork someone
#                forgot to mark blocks rather than passing silently.
#
# Everywhere the rules above are permissive, they are permissive in the
# direction of reporting `open`. Reading a real fork as settled dispatches an
# implementer against a decision nobody made, which is the failure this exists
# to prevent; reading a stray bullet as a fork costs one checkbox. The fixtures
# in scripts/verify.sh pin the cases that used to fail the other way.
#
# Four values, because "task.md exists but has no such section" is a real state
# and must not be guessed at: collapsing it into `none` would let a mistyped
# heading silently disable the whole guarantee, and collapsing it into `open`
# would permanently block every hand-written task.md with no remedy. It gets
# its own value, `unknown`, and every consumer warns rather than assumes.
#
# NOT part of the frontmatter parser below — it shares no code with
# frontmatter_status(), so the byte-for-byte diff scripts/verify.sh runs
# between that function and the hook's copy is unaffected.
open_questions_forks() {
  local f="$1"
  [ -f "$f" ] || { printf 'absent'; return 0; }
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
    }
    BEGIN { insec = 0; fence = ""; found = 0; open = 0 }
    {
      line = $0
      sub(/\r$/, "", line)

      # Fenced blocks are invisible, wherever they appear. Tracked globally so
      # a fence opened before the section cannot leak a heading into it.
      if (line ~ /^[[:space:]]*(```|~~~)/) {
        tok = trim(line); tok = substr(tok, 1, 3)
        if (fence == "") { fence = tok } else if (tok == fence) { fence = "" }
        next
      }
      if (fence != "") next

      # Strip indentation, then any blockquote markers. Both are formatting; a
      # fork does not stop being a fork for being indented or quoted.
      b = line
      sub(/^[[:space:]]+/, "", b)
      while (b ~ /^>/) { sub(/^>[[:space:]]*/, "", b) }

      if (b ~ /^#+([[:space:]]|$)/) {
        h = b
        sub(/^#+[[:space:]]*/, "", h)          # opener
        sub(/[[:space:]]*#+[[:space:]]*$/, "", h)   # optional ATX closer
        h = trim(h)
        sub(/:+$/, "", h)                      # "Open questions:"
        gsub(/^[*_]+/, "", h); gsub(/[*_]+$/, "", h)  # "**Open questions**"
        if (tolower(trim(h)) == "open questions") { insec = 1; found = 1 }
        else { insec = 0 }
        next
      }

      if (!insec) next

      # A horizontal rule is not a list item, however much it looks like one.
      if (b ~ /^[-*_][[:space:]]*[-*_][[:space:]]*[-*_][[:space:]]*$/) next

      # Bulleted or numbered, with or without a space after the marker. The
      # space is optional on purpose: "-[ ] fork" is a typo, not a decision,
      # and reading it as settled is the one direction this must never fail in.
      if (b ~ /^[-*+]/ || b ~ /^[0-9]+[.)]/) {
        t = b
        sub(/^([-*+]|[0-9]+[.)])[[:space:]]*/, "", t)
        if (t !~ /^\[[xX]\]/) { open = 1 }
      }
    }
    END {
      if (!found)   { print "unknown" }
      else if (open) { print "open" }
      else           { print "none" }
    }
  ' "$f" 2>/dev/null
}

# --- human_only (the checks no gate can make) -------------------------------
# Reports whether task.md's `human_only` block holds anything. That block is the
# acceptance criteria a person has to check by hand — the ones no gate can make —
# and it is the input to the fixed "Not proven by this run" heading `gantry:ship`
# puts in a pull request body.
#
# Why this is a printed fact rather than a line of prose telling a driver to look:
# four recorded runs read a clear prose rule and all four ignored it. A disclosure
# that depends on someone remembering to make it is not a disclosure.
#
#   key          a line whose first non-blank content is `human_only:`, at any
#                indentation, ANYWHERE in the file. Unlike open_questions_forks()
#                above, fences are NOT invisible here — the block's canonical home
#                IS a fenced `verification:` block under "How to verify", so a
#                reader that skipped fences would never find it at all.
#   inline       `human_only: ["a check"]` counts as entries. An empty value, or
#                an empty `[]` / `{}`, counts as none.
#   entry        a following line whose first non-blank character is `-`, indented
#                at or DEEPER than the key. At-or-deeper, not deeper: YAML permits
#                a block sequence at the same indentation as its key, and demanding
#                deeper would report a populated list as `none` — a failure in the
#                one direction this must never fail in.
#   continuation a deeper line that is not a bullet belongs to the entry above it.
#                This repo's own entries are multi-line quoted strings.
#   block end    the first non-blank line that is neither of those and is indented
#                at or less than the key — a sibling key, a closing fence, a
#                heading — or end of file.
#   occurrences  the whole file is scanned and the STRONGEST result wins, so a
#                task.md that quotes the template in prose before carrying its own
#                block reports on the block rather than on the quotation.
#
# Three values. `present` is at least one entry, `none` is a key with no entries,
# `absent` is no key at all — or no task.md. `absent` deliberately conflates "no
# file" and "no block": both mean there is nothing to disclose, and the TASK: line
# printed above already separates them for a reader who cares. That is the whole
# reason this needs three values where FORKS: needs four — a missing fork section
# and a missing file lead to different actions, and these two do not.
#
# Everywhere these rules are permissive they are permissive toward `present`. A
# missed disclosure is the failure this exists to prevent; a spurious one costs a
# heading in a pull request body nobody needed. That asymmetry is why an entry
# that will not parse still counts as an entry, why an unterminated fence does not
# stop the scan, and why a key found outside the expected block is still a key.
#
# NOT part of the frontmatter parser above — it shares no code with
# frontmatter_status(), so the byte-for-byte diff scripts/verify.sh runs between
# that function and the hook's copy is unaffected.
human_only_state() {
  local f="$1"
  [ -f "$f" ] || { printf 'absent'; return 0; }
  awk '
    function indent(s) { match(s, /^[ \t]*/); return RLENGTH }
    function trim(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
    }
    BEGIN { best = 0; insec = 0; keyind = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      body = trim(line)

      if (body ~ /^human_only[[:space:]]*:/) {
        keyind = indent(line)
        insec  = 1
        if (best < 1) { best = 1 }
        rest = body
        sub(/^human_only[[:space:]]*:[[:space:]]*/, "", rest)
        rest = trim(rest)
        # Anything but an empty value, a comment, or an empty collection is a
        # populated flow-style list.
        if (rest != "" && rest !~ /^#/ && rest !~ /^(\[[[:space:]]*\]|\{[[:space:]]*\})$/) {
          best = 2
          insec = 0
        }
        next
      }

      if (!insec) { next }
      if (body == "") { next }

      ind = indent(line)

      # A comment is not an entry. This is what lets the task template ship a
      # commented-out placeholder without every task.md written from it
      # reporting `present`.
      if (body ~ /^#/) { next }

      # A horizontal rule is not an entry, however much it looks like one, and
      # it ends the block: the case that matters is a `human_only:` key sitting
      # in frontmatter, where the closing `---` would otherwise read as a
      # bullet. open_questions_forks() above excludes them for the same reason.
      if (body ~ /^[-*_][[:space:]]*[-*_][[:space:]]*[-*_][[:space:]]*$/) {
        insec = 0
        next
      }

      if (body ~ /^-/ && ind >= keyind) { best = 2; next }

      # ANY other content indented deeper than the key counts. Bullets are the
      # conventional shape, not the only valid one: a mapping, or a flow list on
      # the line after the key, are both populated YAML. Reading either as empty
      # would drop the disclosure AND, because a missing heading is defined to
      # mean there was nothing to disclose, affirmatively tell the reviewer so.
      # That is the one-directional failure this line exists to prevent, so
      # anything under the key promotes it rather than bullets alone.
      # (No apostrophes in this block: the awk program is single-quoted.)
      if (ind > keyind) { best = 2; next }

      insec = 0                    # a sibling key, a closing fence, a heading
    }
    END {
      if (best >= 2)      { print "present" }
      else if (best == 1) { print "none" }
      else                { print "absent" }
    }
  ' "$f" 2>/dev/null
}

# --- e2e scenarios (what gantry:qa runs) --------------------------------------
# Reports whether task.md's `e2e.scenarios` block holds anything. Those are the
# scenarios `gantry:qa` runs against the built app, and the input to two fixed
# headings in the pull request body `gantry:ship` composes: a scenario the qa
# phase ran lands under "Exercised by this run", and a declared scenario nobody
# ran lands under "Not proven by this run" — the contract promised it, so the
# body says it was not kept.
#
# Same reasoning as human_only_state() above: a disclosure that depends on a
# reader remembering to look is not a disclosure, so this is a printed fact.
#
#   key          a line whose first non-blank content is `e2e:`, at any
#                indentation, ANYWHERE in the file — fences are not invisible,
#                for the same reason as human_only: the block's canonical home
#                is the fenced `verification:` block under "How to verify".
#   scenarios    a `scenarios:` key indented DEEPER than `e2e:`. An inline
#                `scenarios: [ ... ]` with content counts as entries; an empty
#                `[]` counts as none.
#   entry        a following line whose first non-blank character is `-`,
#                indented at or deeper than the `scenarios:` key — at-or-deeper,
#                because YAML permits a block sequence at its key's indentation.
#                Any other content deeper than the key counts too; bullets are
#                the conventional shape, not the only populated one.
#   comment      a `#` line is not an entry. The task template ships its sample
#                scenario commented out for exactly this reason: a live
#                placeholder would make every task.md written from the template
#                report `present`, and put a scenario called "scenario name"
#                under "Not proven" on every pull request.
#   block end    the first non-blank line indented at or less than the key it
#                belongs to — a sibling key, a closing fence, a heading — or EOF.
#   occurrences  the whole file is scanned and the STRONGEST result wins.
#
# Three values, same shape as HUMAN_ONLY: `present` is at least one entry,
# `none` is an `e2e:` key (with or without `scenarios:`) and no entries, `absent`
# is no `e2e:` key at all — or no task.md. Permissive toward `present`: a
# scenario read as missing drops a disclosure and tells the reviewer, by the
# heading's absence, that there was nothing to disclose.
#
# NOT part of the frontmatter parser — shares no code with frontmatter_status().
e2e_state() {
  local f="$1"
  [ -f "$f" ] || { printf 'absent'; return 0; }
  awk '
    function indent(s) { match(s, /^[ \t]*/); return RLENGTH }
    function trim(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
    }
    # best: 0 = no e2e key, 1 = key with no entries, 2 = entries
    # ine2e: inside the e2e block; insc: inside its scenarios block
    BEGIN { best = 0; ine2e = 0; insc = 0; e2eind = 0; scind = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      body = trim(line)
      if (body == "") { next }
      ind = indent(line)

      if (body ~ /^e2e[[:space:]]*:/) {
        e2eind = ind; ine2e = 1; insc = 0
        if (best < 1) { best = 1 }
        next
      }
      if (!ine2e) { next }

      # A comment is not an entry and does not end anything.
      if (body ~ /^#/) { next }

      # A horizontal rule ends the block: a key in frontmatter would otherwise
      # see the closing --- as a bullet. Same guard as the two parsers above.
      if (body ~ /^[-*_][[:space:]]*[-*_][[:space:]]*[-*_][[:space:]]*$/) {
        ine2e = 0; insc = 0
        next
      }

      # Something at or above the e2e key closes the e2e block — a sibling
      # key (human_only:), a closing fence, a heading.
      if (ind <= e2eind) { ine2e = 0; insc = 0; next }

      if (!insc) {
        if (body ~ /^scenarios[[:space:]]*:/) {
          scind = ind; insc = 1
          rest = body
          sub(/^scenarios[[:space:]]*:[[:space:]]*/, "", rest)
          rest = trim(rest)
          if (rest != "" && rest !~ /^#/ && rest !~ /^(\[[[:space:]]*\]|\{[[:space:]]*\})$/) {
            best = 2
            insc = 0
          }
        }
        # setup: and anything else under e2e: is not a scenario.
        next
      }

      # Inside scenarios: a bullet at or deeper than the key, or any content
      # deeper than it, is an entry. Anything at or above the key closes it.
      if (body ~ /^-/ && ind >= scind) { best = 2; next }
      if (ind > scind) { best = 2; next }
      insc = 0
    }
    END {
      if (best >= 2)      { print "present" }
      else if (best == 1) { print "none" }
      else                { print "absent" }
    }
  ' "$f" 2>/dev/null
}

# --- qa.md (the qa verdict file) ----------------------------------------------
# Reports what gantry:qa recorded. The phase writes qa.md on EVERY run, whatever
# it found, so "qa ran and found no agent" and "qa never ran" are different facts
# here rather than the same silence:
#
#   absent        no qa.md at ROOT. The phase did not run on this tree.
#   exercised     the repo's qa agent ran the scenarios; the body holds one
#                 verdict per scenario (pass, fail, could-not-reach).
#   unrunnable    .claude/qa-env.sh exited non-zero, or an agent exists with no
#                 qa-env.sh beside it. Nobody could check; this is not a fail.
#   no-agent      the repo has no .claude/agents/qa.md. The normal case.
#   no-scenarios  task.md declared none and none could be derived.
#   unknown       a qa.md whose `outcome:` line is missing or out of set.
#
# The value is the first `outcome:` line, trimmed, with one layer of quotes
# stripped. `unknown` is the permissive direction: ship reads anything but
# `exercised` as "the declared scenarios were not kept", so an unreadable file
# produces the disclosure rather than suppressing it.
#
# NOT part of the frontmatter parser — shares no code with frontmatter_status().
qa_state() {
  local f="$1"
  [ -f "$f" ] || { printf 'absent'; return 0; }
  local raw
  raw="$(awk '
    { line = $0; sub(/\r$/, "", line); sub(/^[[:space:]]+/, "", line) }
    line ~ /^outcome[[:space:]]*:/ {
      sub(/^outcome[[:space:]]*:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line; exit
    }
  ' "$f" 2>/dev/null)"
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  case "$raw" in
    exercised|unrunnable|no-agent|no-scenarios) printf '%s' "$raw" ;;
    *) printf 'unknown' ;;
  esac
}

# --- the inherited contract -------------------------------------------------
# TRANSITIONAL, as of 0.5.0. gantry no longer commits task.md or plan.md, so a
# worktree cut from the base branch no longer inherits anything and this check
# cannot fire in a repository that has only ever run 0.5.0 or later.
#
# It is kept, and must not be deleted as dead code, because it is the whole
# migration path. A repository that ran gantry 0.4.x or earlier still carries a
# merged task.md on its base branch, put there by a version that committed it,
# and nothing in this release goes back and removes it — that is the user's
# `git rm` to make. Until they do, every worktree they cut still inherits that
# file, and deleting this check would hand the plan phase exactly the failure
# below in exactly the repositories that used the old behaviour most.
#
# WHY IT WAS NEEDED. Committing task.md and plan.md with every pull request left
# them in the tree on the base branch. A worktree freshly cut from it therefore
# already contained the PREVIOUS, merged task's contract — and a detector that
# only knows `present` tells the plan phase a task is under way, which routes it
# to revise a finished, unrelated contract instead of starting cleanly.
#
# `inherited` is that state, and it is a fact this script establishes rather
# than a judgement each run re-makes. ALL of the following must hold:
#
#   file         task.md exists at ROOT.
#   status       its frontmatter status: is exactly `shipped` — the status a
#                merged task.md actually carries. Deliberately the narrowest
#                terminal set: widening it later is safe, whereas a rule that
#                also swallowed `blocked` or `reviewed` would misread a task
#                that is genuinely in flight and merely paused.
#   attached     HEAD is on a branch. This is checked EXPLICITLY and does not
#                fall out of base resolution: a detached HEAD sitting on a
#                commit reachable from the base still resolves a base and still
#                finds a merge-base, so without this guard it would come back
#                `inherited`.
#   base         a base branch resolves to a rev that exists — the same order
#                gantry:ship uses, so the base a PR targets and the base read
#                here cannot disagree.
#   merge-base   `git merge-base HEAD <base>` succeeds.
#   identical    task.md exists at that merge-base and its bytes are identical
#                to the file on disk. A byte comparison, not a re-hash, so no
#                filter or line-ending setting can make two different files
#                compare equal.
#
# ANYTHING ELSE IS `present`, and the asymmetry is the whole design. Reading a
# live task as inherited routes the plan phase to overwrite work that is not
# recoverable; reading an inherited task as present costs one supersede. So the
# function returns non-zero at the first condition it cannot establish, and
# every git call inside it has its status checked:
#
#   - a detached HEAD                    fails the `attached` guard
#   - no develop/origin-HEAD/main/master fails base resolution
#   - a repository with no commits       has no refs at all, so it also fails
#                                        base resolution — merge-base is never
#                                        reached
#   - no task.md at the merge-base       fails the rev-parse
#   - any git error whatsoever           fails the call it belongs to
#
# One thing worth stating because getting it wrong is silent: the base resolves
# to `origin/<name>` whenever that ref exists, and only to the local branch when
# it does not. gantry:worktree cuts every worktree from `origin/<parent>` and
# treats fast-forwarding the local ref as a convenience it may skip, so
# merge-basing against a local branch that lags origin would land on an older
# commit carrying a DIFFERENT merged task.md — the bytes would differ, and this
# would quietly never fire in the exact workflow it exists for.
#
# NOT part of the frontmatter parser: like open_questions_forks() it shares no
# code with frontmatter_status(), so the byte-for-byte diff scripts/verify.sh
# runs between that function and the hook's copy is unaffected.

# Resolve a rev to merge-base against, or return non-zero. Mirrors the order in
# skills/ship/scripts/detect_state.sh, with one deliberate difference: ship ends
# with a literal `main` fallback so it always has a PR target, and this must not
# — nothing resolving means the fact cannot be established, which is `present`.
inherited_base_rev() {
  local branch="$1" name="" cand c
  # develop, unless we are standing on it (a branch cannot merge-base usefully
  # against itself here, and develop then ships into main/master).
  if [ "$branch" != develop ]; then
    if git show-ref --verify --quiet refs/remotes/origin/develop \
    || git show-ref --verify --quiet refs/heads/develop; then name=develop; fi
  fi
  # origin/HEAD, the remote's declared default — but only if it still resolves;
  # it can name a branch the remote no longer has.
  if [ -z "$name" ]; then
    cand="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    if [ -n "$cand" ] && git show-ref --verify --quiet "refs/remotes/origin/$cand"; then
      name="$cand"
    fi
  fi
  if [ -z "$name" ]; then
    for c in main master; do
      if git show-ref --verify --quiet "refs/remotes/origin/$c" \
      || git show-ref --verify --quiet "refs/heads/$c"; then name="$c"; break; fi
    done
  fi
  [ -n "$name" ] || return 1
  if git show-ref --verify --quiet "refs/remotes/origin/$name"; then
    printf 'origin/%s' "$name"
  else
    printf '%s' "$name"
  fi
}

task_is_inherited() {
  local root="$1" status="$2"
  [ -f "$root/task.md" ] || return 1
  [ "$status" = shipped ] || return 1

  local branch
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  [ -n "$branch" ] || return 1

  local rev mb blob
  rev="$(inherited_base_rev "$branch")" || return 1
  [ -n "$rev" ] || return 1

  mb="$(git merge-base HEAD "$rev" 2>/dev/null)" || return 1
  [ -n "$mb" ] || return 1

  # `<rev>:task.md` with no leading ./ is resolved from the repo root, so this
  # is the same file as "$root/task.md" however deep the caller's cwd is.
  blob="$(git rev-parse --quiet --verify "$mb:task.md" 2>/dev/null)" || return 1
  [ -n "$blob" ] || return 1

  git cat-file blob "$blob" 2>/dev/null | cmp -s - "$root/task.md" || return 1
  return 0
}

# --- review.md (the findings file) ------------------------------------------
# Reports whether review.md — written by gantry:review without --fix, read by
# `gantry:review --fix` in apply mode — still has findings waiting to be applied.
#
#   absent    no review.md at ROOT.
#   applied   the LAST non-blank line starts `applied:`: the fix step ran and
#             appended its gate result. Checked FIRST, so a file that was
#             applied reads as applied however its findings section looks. Only
#             the last line counts — step 5 of the review skill appends it last,
#             and a finding body that happens to begin with `applied:` must not
#             make the file read as applied before any fix ran.
#   clean     under the `## Address now` heading (any level, case-insensitive,
#             tolerant of a trailing colon, an ATX closer and bold wrappers) the
#             first non-blank line is exactly `None` — a trailing period, a
#             bullet marker and bold wrappers tolerated. Not merely a line that
#             starts with it: "None of these are safe to skip: …" is a finding.
#   pending   anything else — INCLUDING a file with no such heading, or one that
#             will not parse at all.
#
# The permissive direction is `pending`, on purpose. A pending file makes the
# fix step look at it, and the fix step then refuses with a reason it can name
# (a mismatched fingerprint, a status that is not `reviewed`). An unparseable
# file read as `clean` would skip the fix step silently, which is the failure
# this value exists to prevent. Same asymmetry as open_questions_forks() above.
#
# NOT part of the frontmatter parser: shares no code with frontmatter_status(),
# so the byte-for-byte diff scripts/verify.sh runs against the hook's copy is
# unaffected.
review_state() {
  local f="$1"
  [ -f "$f" ] || { printf 'absent'; return 0; }
  local last
  last="$(awk 'NF { l = $0 } END { sub(/\r$/, "", l); sub(/^[[:space:]]+/, "", l); print l }' "$f" 2>/dev/null)"
  case "$last" in applied:*) printf 'applied'; return 0 ;; esac
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s
    }
    BEGIN { insec = 0; found = 0; verdict = "pending"; decided = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      b = trim(line)
      if (b ~ /^#+([[:space:]]|$)/) {
        h = b
        sub(/^#+[[:space:]]*/, "", h)
        sub(/[[:space:]]*#+[[:space:]]*$/, "", h)
        h = trim(h)
        sub(/:+$/, "", h)
        gsub(/^[*_]+/, "", h); gsub(/[*_]+$/, "", h)
        if (tolower(trim(h)) == "address now") { insec = 1; found = 1 }
        else { insec = 0 }
        next
      }
      if (!insec || decided) next
      if (b == "") next
      # The first non-blank line under the heading decides. A bullet marker in
      # front of "None" is still "None".
      t = b
      sub(/^([-*+]|[0-9]+[.)])[[:space:]]*/, "", t)
      gsub(/^[*_]+/, "", t); gsub(/[*_]+$/, "", t)
      sub(/\.$/, "", t); gsub(/[*_]+$/, "", t)
      if (tolower(trim(t)) == "none") { verdict = "clean" } else { verdict = "pending" }
      decided = 1
    }
    END { if (!found) print "pending"; else print verdict }
  ' "$f" 2>/dev/null
}

# --- artifacts --------------------------------------------------------------
present_or_absent() { [ -f "$1" ] && echo present || echo absent; }

TASK="$(present_or_absent "$ROOT/task.md")"
PLAN="$(present_or_absent "$ROOT/plan.md")"
HANDOVER="$(present_or_absent "$ROOT/handover.md")"
GATES="$(present_or_absent "$ROOT/.claude/gates.sh")"
QA_ROLE="$(present_or_absent "$ROOT/.claude/agents/qa.md")"
QA_ENV="$(present_or_absent "$ROOT/.claude/qa-env.sh")"

# STATUS is read before the TASK: line is printed, because `inherited` is a fact
# about the status as well as about the bytes. The order of the OUTPUT lines is
# unchanged; only the order in which they are computed moved.
STATUS="$(frontmatter_status "$ROOT/task.md")"

if [ "$TASK" = present ] && task_is_inherited "$ROOT" "$STATUS"; then
  TASK=inherited
fi

REVIEW="$(review_state "$ROOT/review.md")"
QA="$(qa_state "$ROOT/qa.md")"

echo "TASK:$TASK"
echo "PLAN:$PLAN"
echo "HANDOVER:$HANDOVER"
echo "REVIEW:${REVIEW:-pending}"
echo "QA:${QA:-unknown}"
echo "STATUS:${STATUS:-none}"

FORKS="$(open_questions_forks "$ROOT/task.md")"
echo "FORKS:${FORKS:-unknown}"

HUMAN_ONLY="$(human_only_state "$ROOT/task.md")"
echo "HUMAN_ONLY:${HUMAN_ONLY:-absent}"

E2E="$(e2e_state "$ROOT/task.md")"
echo "E2E:${E2E:-absent}"

echo "GATES:$GATES"
echo "QA_ROLE:$QA_ROLE"
echo "QA_ENV:$QA_ENV"

# The hook's firing conditions — and only those. This line used to say `armed`,
# which read as "the gate is enforced on this run" and was a claim this script
# is not entitled to make: it computes the conditions from GATES and STATUS and
# cannot see whether the hook is REGISTERED at all.
#
# Registration is not detectable from here, which is why the honest move was to
# rename rather than to go looking for it. The hook is registered by the
# plugin's own hooks/hooks.json, in the PLUGIN root; this script resolves the
# REPO root and is given no handle on the other. The one handle available — its
# own path — is the one that lies, because gantry's own repository IS the plugin
# source and carries hooks/hooks.json at its root, so any check anchored there
# would report "registered" for every checkout of gantry. And even reading the
# right manifest would not settle it: whether the hook fires also depends on the
# plugin being enabled in the user's configuration, which is likewise invisible.
#
# So the value names the conditions and leaves the residual — "and the hook must
# also be installed" — visible to the reader instead of buried in a word.
if [ "$GATES" = present ] && [ "$STATUS" = implementing ]; then
  echo "HOOK:conditions-met"
else
  echo "HOOK:conditions-unmet"
fi

# --- working-tree state -----------------------------------------------------
STAGED=0; UNSTAGED=0; UNTRACKED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  x="${line:0:1}"; y="${line:1:1}"
  if [ "$x$y" = "??" ]; then UNTRACKED=$((UNTRACKED+1)); continue; fi
  [ "$x" != " " ] && STAGED=$((STAGED+1))
  [ "$y" != " " ] && UNSTAGED=$((UNSTAGED+1))
done < <(git status --porcelain 2>/dev/null)
DIRTY_TOTAL=$((STAGED+UNSTAGED+UNTRACKED))
if [ "$DIRTY_TOTAL" -eq 0 ]; then echo "DIRTY:clean"; else echo "DIRTY:staged=$STAGED unstaged=$UNSTAGED untracked=$UNTRACKED"; fi

# --- decide the phase -------------------------------------------------------
# Known status wins: it is what the phase skills write, and it survives a
# session boundary. Fall back to artifact inference only when it is missing or
# unrecognised, so a hand-written or half-edited task.md still lands somewhere
# sensible instead of erroring.
case "$STATUS" in
  planning)     PHASE=plan ;;
  planned)      PHASE=critique ;;   # a plan nobody has read yet
  critiqued)    PHASE=grill ;;      # a critic read it; no human has agreed to it
  grilled)      PHASE=implement ;;
  implementing) PHASE=implement ;;   # resume: the gate has not gone green yet
  implemented)  PHASE=review ;;
  # A reviewed task whose review.md still lists findings has a fix step to run
  # before it can ship. PHASE and NEXT are derived from the same value below,
  # so they cannot disagree about it.
  reviewed)     if [ "$REVIEW" = pending ]; then PHASE=review; else PHASE=ship; fi ;;
  shipped)      PHASE="done" ;;
  blocked)      PHASE=blocked ;;
  *)
    if [ "$PLAN" = present ]; then
      # A plan exists but nothing recorded a status — assume it has not been
      # carried out. Re-implementing is recoverable; skipping is not.
      PHASE=implement
    else
      PHASE=plan
    fi
    ;;
esac

case "$PHASE" in
  plan)      NEXT="/gantry:plan" ;;
  critique)  NEXT="/gantry:plan-critique" ;;
  grill)     NEXT="/gantry:grill" ;;
  implement) NEXT="/gantry:implement" ;;
  review)
    # A findings file under any status but `reviewed` is a review that died
    # between writing review.md and writing the status. `--fix` refuses that
    # combination and names /gantry:review, so name it here directly rather
    # than suggesting a command the skill will turn away.
    if [ "$REVIEW" = pending ] && [ "$STATUS" != reviewed ]; then NEXT="/gantry:review"
    else NEXT="/gantry:review --fix"; fi ;;
  ship)      NEXT="/gantry:ship" ;;
  "done")    NEXT="none — already shipped" ;;
  blocked)   NEXT="none — task.md says blocked; read it before continuing" ;;
  *)         NEXT="/gantry:plan" ;;
esac

echo "NEXT:$NEXT"
echo "PHASE:$PHASE"
