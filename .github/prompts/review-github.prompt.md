---
agent: Code-Conductor
description: "Run GitHub review intake through Code-Conductor, including proxy prosecution for PR review reconciliation."
argument-hint: "[optional PR number; auto-resolves active PR or asks]"
---

<!-- Read: agents/Code-Review-Response.agent.md -->

# /review-github

Run the Code-Conductor GitHub review intake path for: {{input}}

Resolve the target PR from the supplied input when present; otherwise use the active branch PR when available. If no PR can be resolved, ask the user for the PR number instead of falling through to local code review.

Enter GitHub review intake mode, reconcile existing GitHub review comments, and run proxy prosecution through `skills/code-review-intake/SKILL.md` and the Code-Conductor review reconciliation loop.
