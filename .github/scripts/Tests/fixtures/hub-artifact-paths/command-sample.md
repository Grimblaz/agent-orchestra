---
model: inherit
effort: inherit
---

# Sample Command File

Fixture for hub-artifact-paths extraction grammar tests — command scope
(simulating `commands/*.md`).

## Body dispatch

This command dispatches the Issue-Planner. Load `agents/Issue-Planner.agent.md`
and follow its methodology.

For credit emission, consult `skills/frame-credit-emission/SKILL.md`.

## Excluded patterns (must NOT be extracted)

Tool-name backtick: `read_file`
Another excluded token: `AskUserQuestion`
Marker template: <!-- design-issue-{ID} -->
