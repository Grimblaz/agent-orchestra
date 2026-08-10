# Platform — Claude Code

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress engagement gates.

This file specifies no mechanism for surfacing a decision — the agent picks what works per turn. What follows is the content each standards-check question must carry, whatever form it takes.

## Brief rendering

Render the brief (or the resume variant snapshot) as inline markdown text in the conversation before any role-specific work begins. The brief and the snapshot are rendered text, never a question. On same-agent resume, skip the standards check entirely, rendering only the inline snapshot.

## Standards check — raising a concern

When a standards concern is found, present it with:

- The finding as the question body: include (1) the named anchor (skill path), (2) the verbatim quoted text that violates the standard, and (3) the corrected approach.
- Two or three options:
  1. The corrective approach (recommended)
  2. Proceed as-is with the inherited content
  3. (Optional) A middle path if one exists

Mark the corrective approach as `(Recommended)`.

**Worked example**:

```text
Standards check — customer language concern:

Anchor: `skills/customer-experience/SKILL.md` — Customer Language rule

Quoted text: "The system will expose a REST endpoint that accepts..."

This describes a system behavior in implementation terms rather than a customer
goal. Corrected: rewrite as "When a developer connects their tool, they see..."

How should we proceed?
  1. Rewrite in customer language (Recommended) — update the prior phase output before continuing
  2. Proceed with current text — accept inherited content as-is and continue
```

## When no concern fires

Emit inline: `Standards check: none flagged` — nothing is asked.

## Judgment principle reminder

Raise concerns based on certainty × risk. There is no numeric cap. Multiple simultaneous concerns may be batched into a single question (no numeric cap — raise every concern that meets the certainty × risk threshold), or raised sequentially if each requires the previous answer to proceed.

## Drift scan — script path resolution

When invoking `get-issue-drift.ps1` from a Claude Code session, resolve the script path using the same D1 plugin-cache-priority lookup as `skills/session-startup/SKILL.md` Step 3 (repo-clone first for contributors, plugin-cache installPath for consumers):

1. **Repo clone** (contributor CWD is the repo root): `skills/upstream-onboarding/scripts/get-issue-drift.ps1`
2. **Plugin-cache install** (consumer): read `~/.claude/plugins/installed_plugins.json`, find `agent-orchestra@agent-orchestra`'s `installPath`, and use `{installPath}/skills/upstream-onboarding/scripts/get-issue-drift.ps1`.

If both paths fail, emit `couldn't check: script not found` rather than silencing the failure.
