# Design: Claude Browser Tools for UI Verification

**Issue**: #405
**Date**: 2026-04-25
**Status**: Finalized
**Branch**: feature/issue-405-claude-code-phase-5

## Summary

Defines the Claude Code browser-tool stack for UI-Iterator and `/polish` in Phase 5. The preference order is `mcp__Claude_in_Chrome__*` first, `mcp__Claude_Preview__*` second, and manual screenshot paste last. This preserves cross-agent consistency with Experience-Owner's `browser/*` mapping, keeps polish available when the Chrome extension is not connected, and retains the shared body's manual fallback only when both MCP paths are unavailable.

Install and connect notes are part of the design contract. For the primary path, install the Claude Chrome extension and connect it to the active Claude Code session before rerunning `/polish`. For the fallback path, start a local preview session with `mcp__Claude_Preview__preview_start` against the running dev server URL, then rerun `/polish` against that preview surface.

<!-- ce6-literal -->
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
<!-- /ce6-literal -->

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Primary browser surface | `mcp__Claude_in_Chrome__*` | Matches the issue 405 decision and Experience-Owner's existing `browser/*` mapping, so Claude-side polish uses the same preferred surface family instead of introducing a divergent primary path |
| D2 | Fallback browser surface | `mcp__Claude_Preview__*` after `mcp__Claude_Preview__preview_start` against a local dev server URL | Removes the first-use install barrier when the Chrome extension is missing or disconnected, while still giving UI-Iterator an interactive browser surface that supports automated polish |
| D3 | Final fallback | Manual screenshot paste only when both MCP paths are unreachable | Preserves the shared body's existing screenshot-based escape hatch without turning it into the normal path; the verify-after-edit cycle is intentionally degraded only as a last resort |
| D4 | Install/connect guidance | Document both the Claude Chrome extension connection path and the local-preview startup path in the design doc and CE6 literal | The graceful-degradation contract is only useful if the recovery steps are explicit and stable enough to reuse in shells, commands, and parity assertions |
| D5 | CE6 message contract | Preserve the issue-body literal byte-for-byte inside HTML markers | The issue locks this wording for parity testing and customer-experience verification, so the design doc must remain an exact source for the final degraded-path announcement |

---

## Tool Mapping

| Copilot browser surface | Claude-in-Chrome primary | Claude_Preview fallback | Final fallback |
|-------------------------|--------------------------|-------------------------|----------------|
| `browser/openBrowserPage` | `mcp__Claude_in_Chrome__*` page-open or navigation surface | `mcp__Claude_Preview__preview_start` against the local dev server URL to create the preview session | User opens the target page manually, then pastes a screenshot |
| `browser/screenshotPage` | `mcp__Claude_in_Chrome__*` screenshot or capture surface | `mcp__Claude_Preview__*` screenshot or capture surface after `preview_start` | User pastes the current screenshot into chat |
| `browser/clickElement` | `mcp__Claude_in_Chrome__*` click or DOM interaction surface | `mcp__Claude_Preview__*` click or interaction surface after `preview_start` | User performs the interaction manually, then pastes an updated screenshot |
| `browser/typeInPage` | `mcp__Claude_in_Chrome__*` input or form-entry surface | `mcp__Claude_Preview__*` input surface after `preview_start` | User performs the input manually, then pastes an updated screenshot |
| `browser/readPage` | `mcp__Claude_in_Chrome__*` page-read or DOM-inspection surface | `mcp__Claude_Preview__*` page-read surface after `preview_start` | User supplies a screenshot and any needed visible text context manually |
| `browser/hoverElement` | `mcp__Claude_in_Chrome__*` hover-capable interaction surface | `mcp__Claude_Preview__*` hover-capable interaction surface after `preview_start` | User triggers the hover state manually, then pastes a screenshot |
| `browser/dragElement` | `mcp__Claude_in_Chrome__*` drag or pointer-manipulation surface | `mcp__Claude_Preview__*` drag-capable interaction surface after `preview_start` | User performs the drag interaction manually, then pastes a screenshot |
| `browser/handleDialog` | `mcp__Claude_in_Chrome__*` dialog-handling surface | `mcp__Claude_Preview__*` dialog-handling surface after `preview_start` | User dismisses or accepts the dialog manually, then pastes a screenshot |
| `browser/runPlaywrightCode` | `mcp__Claude_in_Chrome__*` advanced browser-automation surface when direct interaction is needed | `mcp__Claude_Preview__*` advanced preview automation surface after `preview_start`, where supported | Manual screenshot paste with descriptive context; no verify-after-edit loop |

---

## Files Changed

| File | Change |
|------|--------|
| `agents/process-review.md` | New Claude shell for Process-Review using the Phase 4 specialist shell pattern |
| `agents/research-agent.md` | New Claude shell for Research-Agent with Claude-specific research tool mapping and persistence notes |
| `agents/specification.md` | New Claude shell for Specification with Claude-safe file-edit guidance for `.copilot-tracking/specs/` |
| `agents/ui-iterator.md` | New Claude shell for UI-Iterator with browser-tool mapping and the locked CE6 literal announcement |
| `commands/polish.md` | New Claude slash command that invokes UI-Iterator via `/polish` |
| `.github/scripts/Tests/specialist-shell-parity.Tests.ps1` | Extended parity coverage for the four new shells, fenced-H2 parsing, and UI-Iterator literal enforcement |
| `Documents/Design/claude-browser-tools.md` | Claude-side browser-tools reference for issue 405, including the preference order, install/connect notes, tool mapping, and CE6 contract |
