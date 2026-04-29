---
description: Invoke UI-Iterator inline -- screenshot-driven visual polish loop.
argument-hint: "[component or page name]"
---

# /polish

Run the UI-Iterator role inline in this conversation for the provided component or page.

## Pre-flight (session-startup + paired-body load)

### Step 4 — Run-once marker (D2 fail-open)

The automatic startup guard records `/memories/session/session-startup-check-complete.md` after the first automatic startup check. SMC-07 governs this run-once startup-check marker. Claude Code inline currently lacks a session-memory write surface (SMC-07); the run-once marker is a no-op on this surface. The check still proceeds; the user-friction window is bounded to the first inline command of each new session because the SessionStart hook only injects `additionalContext` on session start.

### Step 6 — Cleanup confirmation

When the SessionStart hook injects `additionalContext`, present that context and ask via `AskUserQuestion` whether to continue with cleanup using these exact option labels:

1. `Yes — run cleanup`
2. `No — skip for now`

If `additionalContext` is absent, emit a single line saying `no stale state detected` and continue.

### Step 7b — Drift check

Before checking drift, run `claude plugin marketplace update` (5-second timeout); if it fails or times out, emit `marketplace freshness check failed — using cached view` and continue with the cached view. When a local-path marketplace registration is classified as a non-git local directory or a dirty/detached tree, suppress that freshness emit because the existing local-path classification surfaces remediation.

On Claude Code, run the plugin drift check after the cleanup path completes. If the installed plugin is behind the marketplace version, emit the update summary and ask via `AskUserQuestion` with these exact option labels:

1. `Stop — I'll restart now`
2. `Continue — run under old code`

If Claude is running headless and cannot ask a structured question, emit the update result inline and continue.

### Step 9 — Paired-body halt-on-fail

Read `agents/ui-iterator.md` before adopting the role. If that load fails, emit exactly: `⚠️ Shared-body load failed for agents/ui-iterator.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.`

## Inline execution

Read `agents/ui-iterator.md` and adopt that role for the rest of this conversation. Follow all methodology sections, including `## Browser Tools Reference`. If neither Chrome MCP nor Claude_Preview is available, emit the locked CE6 literal below and then offer manual screenshot paste so the conversation can continue in the final fallback mode.

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
