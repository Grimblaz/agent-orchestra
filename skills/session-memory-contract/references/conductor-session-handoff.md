<!-- markdownlint-disable-file MD041 MD003 -->

# Code-Conductor Context Management & Handoff Detail

Extracted from `agents/Code-Conductor.agent.md`. Long-session context-management guidance and the user-handoff escalation patterns for Code-Conductor. Load this reference when recommending compaction or when escalating a decision to the user.

## Context Management for Long Sessions

VS Code 1.110+ auto-compacts conversation context automatically when the context window fills. This can happen silently mid-orchestration — do not wait for the user to notice.

**Context window indicator**: When approaching capacity (the context window indicator in the chat UI shows this to you or the user), proactively compact at a phase boundary rather than letting auto-compaction interrupt mid-step.

**What survives compaction**: Session memory (`/memories/session/`) notes survive compaction automatically. If the plan was persisted as a GitHub issue comment, it is also accessible after compaction.

**Custom `/compact` instructions**: When recommending compaction, generate the command with actual values from the current context — do not use a generic reminder. Fill in this template with real values:

```text
/compact focus on: issue #[ID], step [N] of [M] complete ([brief outcome per step]), branch [branch-name], design intent: [key design intent], open items: [unresolved decisions or blockers]
```

For plans with many completed steps, summarize in 3–5 words per step or list step numbers only (e.g., `steps 1-4: done, step 5: in progress`).

**When to compact**: After completing a major phase (e.g., after all implementation steps complete and before starting the review cycle).

## Handoff to User

Code-Conductor operates autonomously and continues toward merge-ready by default. It pauses only when judgment beyond its authority is required, and every such pause must immediately use `#tool:vscode/askQuestions` to get a decision and continue — never plain-text questions, and never just stop and describe the problem.

PR creation is mandatory before user handoff. Do not return work to the user for PR creation when the agent has authority to create it.

**Escalation pattern**: Present analysis in conversation text → call `#tool:vscode/askQuestions` with concrete options (mark one `recommended`) → incorporate the answer and resume work.

- **Design decisions**: Explain the trade-off in text, then `#tool:vscode/askQuestions` with the options. Mark your recommendation.
- **PR readiness/merge approval**: After PR creation, summarize what was built and tested, then `#tool:vscode/askQuestions`: "Merge-ready", "Needs changes [describe]", "Run additional validation"
- **Clarification needed**: Explain the discrepancy in text, then `#tool:vscode/askQuestions` with your interpretations as options. Mark the one you think is correct.
- **Workflow complete**: Final status with open items. If there are follow-up decisions, `#tool:vscode/askQuestions` with next actions.
