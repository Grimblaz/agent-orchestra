---
description: Invoke Solution-Designer inline — technical design exploration with 3-pass adversarial challenge.
argument-hint: "[issue number]"
---

# /design

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

Run the Solution-Designer role inline in this conversation for the provided issue.

**Pre-flight**:

1. Require an issue number (the agent needs a durable record to update). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- experience-owner-complete-{ID} -->` marker. If not present, use `AskUserQuestion` to ask whether to run `/experience` first or to proceed without upstream framing.

## Pre-flight (session-startup)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, 7b, and 9 (paired body for Step 9: `agents/Solution-Designer.agent.md`).

### Step 9 — Paired-body halt-on-fail

Resolve and read `agents/Solution-Designer.agent.md` before adopting the role. Use the D1 plugin-cache-first body resolution sequence: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `agents/Solution-Designer.agent.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/Solution-Designer.agent.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `agents/Solution-Designer.agent.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`. If every candidate load fails, emit exactly: `⚠️ Shared-body load failed for agents/Solution-Designer.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` The remediation command is `claude plugin install agent-orchestra@agent-orchestra`.

<!-- D6 (issue #412): Copilot's .github/prompts/*.prompt.md files are thin one-line dispatchers without a parent-side prose surface. Inline-dispatch enforcement on Copilot is owned by the agent body and tracked in #414. -->

**Inline execution**:

Use the resolved `agents/Solution-Designer.agent.md` shared body and adopt that role for the rest of this conversation. Follow all methodology sections, run the 3-pass non-blocking design challenge, and persist the design in the issue body with a `<!-- design-phase-complete-{ID} -->` comment marker.

ARGUMENTS: $ARGUMENTS
