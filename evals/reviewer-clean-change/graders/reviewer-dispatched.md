---
type: tool_used
tool: Agent
input_match: gantry-reviewer
weight: 1
arm: with-only
---

A plugin-fired indicator, not part of the score. `arm: with-only` keeps it out of the baseline arm, where no `gantry-reviewer` exists to dispatch and a failing grader would put a constant into the delta.

The prompt is agent-neutral on purpose, so the plugin arm is free to review inline instead of delegating. This grader is how that shows up as a number rather than as a hunch.
