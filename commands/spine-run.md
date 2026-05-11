---
agent: Spine-Runner
description: "Run Spine-Runner against an issue with a persisted v2 frame-spine plan."
argument-hint: "Issue number"
# inherit — Spine-Runner is a minimal walker; subagent dispatches inherit dispatcher tier
# for cost-comparison parity with Code-Conductor (D7).
model: inherit
effort: inherit
---

# /spine-run

<!-- scope: claude-only -->

Run the Spine-Runner role for the supplied issue or plan reference. The command frontmatter dispatches to `Spine-Runner`, whose Claude shell resolves and loads `agents/Spine-Runner.agent.md` before role work.

ARGUMENTS: $ARGUMENTS
