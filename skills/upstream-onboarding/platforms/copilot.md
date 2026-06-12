# Platform — Copilot (VS Code)

The `upstream-onboarding` skill uses the `#tool:vscode/askQuestions` tool for structured questions.

## Brief rendering

Render the brief (or the resume variant snapshot) as inline markdown text in the conversation before any role-specific work begins. No tool call is needed for the brief or snapshot itself. On same-agent resume, skip standards check tool calls, rendering only the inline snapshot.

## Standards check — raising a concern

When a standards concern is found, present it using `#tool:vscode/askQuestions` with:

- The finding as the question body: include (1) the named anchor (skill path), (2) the verbatim quoted text that violates the standard, and (3) the corrected approach.
- Two or three options:
  1. The corrective approach (recommended)
  2. Proceed as-is with the inherited content
  3. (Optional) A middle path if one exists

Mark the corrective approach as recommended.

**Example invocation pattern**:

```text
#tool:vscode/askQuestions({
  questions: [{
    question: "Standards check — single prescription concern:\n\nAnchor: `skills/design-exploration/SKILL.md` — Options-with-trade-offs rule\n\nQuoted text: \"We will implement this using approach X.\"\n\nThis documents only one approach. Corrected: present at least two alternatives with trade-offs before recommending.\n\nHow should we proceed?",
    options: [
      { value: "rewrite", displayValue: "Add alternatives and trade-offs (Recommended)" },
      { value: "proceed", displayValue: "Proceed with current single-option design" }
    ]
  }]
})
```

## When no concern fires

Emit inline: `Standards check: none flagged` — no tool call required.

## Judgment principle reminder

Raise concerns based on certainty × risk. There is no numeric cap. Multiple simultaneous concerns may be batched into a single `#tool:vscode/askQuestions` call with multiple questions, or raised sequentially if each requires the previous answer to proceed.

## Drift scan — script path resolution

When invoking `get-issue-drift.ps1` from a Copilot session, resolve the script path from the installed `agent-orchestra` plugin cache (the VS Code `agentPlugins/.../agent-orchestra` cache path under the active product profile), then:

```powershell
pwsh -NoProfile -NonInteractive -File "<plugin-root>/skills/upstream-onboarding/scripts/get-issue-drift.ps1" -IssueNumber {ID}
```

If the plugin cache path cannot be resolved, emit `couldn't check: script not found`.
