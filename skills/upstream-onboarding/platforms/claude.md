# Platform — Claude Code

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

The `upstream-onboarding` skill uses Claude Code's `AskUserQuestion` tool for structured questions.

## Brief rendering

Render the brief (or the resume variant snapshot) as inline markdown text in the conversation before any role-specific work begins. No tool call is needed for the brief or snapshot itself. On same-agent resume, skip standards check tool calls, rendering only the inline snapshot.

## Standards check — raising a concern

When a standards concern is found, present it using `AskUserQuestion` with:

- The finding as the question body: include (1) the named anchor (skill path), (2) the verbatim quoted text that violates the standard, and (3) the corrected approach.
- Two or three options:
  1. The corrective approach (recommended)
  2. Proceed as-is with the inherited content
  3. (Optional) A middle path if one exists

Mark the corrective approach as `(Recommended)`.

**Example invocation pattern**:

```text
AskUserQuestion({
  questions: [{
    question: "Standards check — customer language concern:\n\nAnchor: `skills/customer-experience/SKILL.md` — Customer Language rule\n\nQuoted text: \"The system will expose a REST endpoint that accepts...\"\n\nThis describes a system behavior in implementation terms rather than a customer goal. Corrected: rewrite as \"When a developer connects their tool, they see...\"\n\nHow should we proceed?",
    header: "Standards check",
    multiSelect: false,
    options: [
      { label: "Rewrite in customer language (Recommended)", description: "Update the prior phase output before continuing" },
      { label: "Proceed with current text", description: "Accept inherited content as-is and continue" }
    ]
  }]
})
```

## When no concern fires

Emit inline: `Standards check: none flagged` — no tool call required.

## Judgment principle reminder

Raise concerns based on certainty × risk. There is no numeric cap. Multiple simultaneous concerns may be batched into a single `AskUserQuestion` call (no numeric cap — raise every concern that meets the certainty × risk threshold), or raised sequentially if each requires the previous answer to proceed.
