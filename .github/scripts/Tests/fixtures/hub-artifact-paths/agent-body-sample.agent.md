---
name: SampleAgent
description: "Fixture for hub-artifact-paths extraction grammar tests — agent body scope"
---

# Sample Agent Body

This file contains backtick-fenced path references that the extraction grammar
must recognise, along with excluded patterns that must NOT appear in the inventory.

## Path references (should be extracted)

Load the shared body from `agents/Code-Smith.agent.md` before beginning role work.
Methodology lives in `skills/plan-authoring/SKILL.md` and is loaded at dispatch time.
The orchestration entry point is `commands/orchestrate.md`.
Cross-skill reference: `skills/session-startup/SKILL.md`.
Platform routing: `agents/Code-Conductor.agent.md`.

## Excluded patterns (must NOT be extracted)

Marker template comment: <!-- experience-owner-complete-{ID} -->
Tool-name backtick: `Read`
Another tool name: `gh`
URL: https://github.com/Grimblaz/agent-orchestra
CLI flag: --%
Short tool: `Bash`
Another tool: `Write`
