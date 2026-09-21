---
type: tool_used
tool: Agent
input_match: gantry-critic
weight: 1
arm: with-only
---

A plugin-fired indicator, not part of the score. `arm: with-only` keeps it out of the baseline arm, where no `gantry-critic` exists to dispatch and a failing grader would put a constant into the delta.

The prompt is agent-neutral on purpose, so the plugin arm is free to critique inline instead of delegating. This grader is how that shows up as a number rather than as a hunch.
