---
type: llm
weight: 2
---

The first seeded defect. The fixture's `task.md` requires that `prune.sh --dry-run <dir>` print the lines it would otherwise print and remove nothing. No step of the fixture's `plan.md` implements a dry-run flag, parses one, or mentions one: step 2 changes the argument list to `<dir> [days] [keep]` and leaves the loop body — which calls `rm -f` unconditionally — alone. The plan cannot satisfy that criterion, and its test strategy does not test it either.

PASS only if the response reports that the dry-run acceptance criterion is not addressed by any step of the plan. Naming it as "unaddressed", "missing work", "no step implements it" or "the plan does not satisfy this criterion" all count.

FAIL if the response never mentions the dry-run criterion, or mentions it only as something the plan handles. Reporting the other seeded defect instead does not satisfy this grader; the two are graded apart on purpose so partial credit is visible.
