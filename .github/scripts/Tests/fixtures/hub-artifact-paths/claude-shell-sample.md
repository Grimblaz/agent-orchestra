---
name: code-smith
description: "Fixture for hub-artifact-paths extraction grammar tests — Claude shell scope"
model: inherit
effort: inherit
# D4: routine implementation; inherits dispatcher
---

# Code-Smith Claude Shell

This fixture simulates a Claude-native subagent shell file.

## Body resolution

Resolve and load `agents/code-smith.md` from the plugin cache.
The paired test-writer shell is at `agents/test-writer.md`.

## Excluded patterns (must NOT be extracted)

Predicate DSL token: provides: [implement-test]
Tool name backtick: `Grep`
Another tool: `Edit`
Marker template: <!-- plan-issue-{ID} -->
