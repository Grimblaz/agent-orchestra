---
description: Invoke UI-Iterator inline -- screenshot-driven visual polish loop.
argument-hint: "[component or page name]"
---

# /polish

Run the UI-Iterator role inline in this conversation for the provided component or page.

## Pre-flight (session-startup + paired-body load)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, 7b, and 9 (paired body for Step 9: `agents/UI-Iterator.agent.md`).

### Step 9 — Paired-body halt-on-fail

Resolve and read `agents/UI-Iterator.agent.md` before adopting the role. Use the D1 plugin-cache-first body resolution sequence: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `agents/UI-Iterator.agent.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/UI-Iterator.agent.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `agents/UI-Iterator.agent.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`. If every candidate load fails, emit exactly: `⚠️ Shared-body load failed for agents/UI-Iterator.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` The remediation command is `claude plugin install agent-orchestra@agent-orchestra`.

## Inline execution

Use the resolved `agents/UI-Iterator.agent.md` shared body and adopt that role for the rest of this conversation. Follow all methodology sections, including `## Browser Tools Reference`. If neither Chrome MCP nor Claude_Preview is available, emit the locked CE6 literal below and then offer manual screenshot paste so the conversation can continue in the final fallback mode.

```text
⚠️ UI-Iterator browser tools unavailable.

Primary path — Claude-in-Chrome MCP:
  1. Install the Claude Chrome extension and connect it to this Claude Code session.
  2. Re-run /polish.

Fallback path — Claude_Preview MCP:
  1. Run mcp__Claude_Preview__preview_start against your dev server URL (e.g. http://localhost:3000).
  2. Re-run /polish.

Final fallback — manual screenshot paste:
  Paste a screenshot of the current state and the agent will proceed with manual iteration. Note: this loses the verify-after-edit cycle that automated polish provides.
```

ARGUMENTS: $ARGUMENTS
