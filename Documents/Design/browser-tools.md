# Design: Browser Tools for UI Verification

**Issue**: #55
**Date**: 2026-03-05
**Status**: Finalized
**Branch**: feature/issue-55-native-browser-tools

## Summary

Migrates UI verification, CE Gate scenarios, and UI-Iterator workflows from Playwright MCP as the primary browser automation path to VS Code 1.110+ native browser tools. Playwright MCP is retained as an explicit fallback for users who prefer it or need capabilities not yet available in native tools.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Primary browser tool | VS Code 1.110+ native browser tools (`openBrowserPage`, `screenshotPage`, `clickElement`, `typeInPage`, `readPage`, etc.) | Zero setup for new users; aligns with VS Code platform direction; no MCP server required |
| D2 | Playwright MCP role | Retained as optional fallback | Supports existing users; some capabilities may not yet exist in native tools |
| D3 | Setup wizard default | Native tools primary (via `workbench.browser.enableChatTools`); Playwright MCP offered as optional add-on question | Reduces friction for new users to zero — just enable a setting |
| D4 | Instruction file rename | `browser-mcp.instructions.md` → `browser-tools.instructions.md` | Covers both paths; name no longer implies MCP-only |
| D5 | webapp-testing skill | Out of scope — E2E test automation (Playwright test framework) is distinct from browser-based UI verification | Different tools, different purposes; keeping the skill unchanged avoids confusion |
| D6 | Agent frontmatter | List native browser tools individually (no wildcard); Playwright MCP as commented fallback | Explicit and discoverable; aligns with VS Code built-in tool declaration pattern |
| D7 | Scope expansion | `Issue-Planner.agent.md` added to migration scope (2 Playwright references discovered in exhaustive scan, not listed in original issue) | Migration-type issues require exhaustive scan to catch all references |

---

## Tool Mapping

| Old Playwright MCP Tool | Native Browser Tool |
|------------------------|---------------------|
| `browser_navigate` | `openBrowserPage` |
| `browser_take_screenshot` | `screenshotPage` |
| `browser_snapshot` | `readPage` |
| `browser_click` | `clickElement` |
| `browser_type` | `typeInPage` |
| *(new capability)* | `hoverElement` |
| *(new capability)* | `dragElement` |
| *(new capability)* | `handleDialog` |
| *(new capability)* | `runPlaywrightCode` |

---

## Files Changed

| File | Change |
|------|--------|
| `.github/agents/UI-Iterator.agent.md` | Frontmatter + body: native tools primary, Playwright fallback; section renamed to "Browser Tools Reference" |
| `.github/agents/Code-Conductor.agent.md` | Frontmatter + CE Gate table + graceful degradation |
| `.github/agents/Code-Critic.agent.md` | Frontmatter + body: `browser_take_screenshot`→`screenshotPage`, `browser_click`/`browser_type`→`clickElement`/`typeInPage`; references updated |
| `.github/agents/Code-Review-Response.agent.md` | Frontmatter only |
| `.github/agents/Solution-Designer.agent.md` | Frontmatter + body: View Current App section; CE Gate readiness moved to Experience-Owner.agent.md |
| `.github/agents/Issue-Planner.agent.md` | Body: CE Gate tool reference |
| `.github/prompts/setup.prompt.md` | Phase 5d rework: native tools default, Playwright MCP optional; file renamed |
| `CUSTOMIZATION.md` | Phase 5 table updated |
| `Documents/Design/customer-experience-gate.md` | CE Gate tool table updated |
| `Documents/Design/setup-wizard.md` | Phase 5d updated with native browser tools migration note |
