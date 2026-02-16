# Design: Sync Agent Definitions from Org-Level Repo

**Issue**: #17
**Date**: 2026-02-16
**Status**: Finalized

## Summary

Replace all 15 template agent definitions with their org-level equivalents from `Grimblaz-and-Friends/.github-private`, adding Issue-Planner to replace the previous lightweight planning agent, and adjusting all agents to remain generic and usable by any project — including backend-only projects without Playwright.

## Design Decisions

### 1. Agent File Format ✅

**Decision**: Convert from `` ```chatagent `` code fence wrapping to standard `---` YAML frontmatter.

**Rationale**: The org repo uses standard `---` frontmatter, which is the canonical VS Code Copilot Chat agent format. The `chatagent` fencing was an older convention.

### 2. Issue-Planner Replaces the Legacy Lightweight Planner ✅

**Decision**: Remove the legacy lightweight planning agent and add Issue-Planner.

**Rationale**: Issue-Planner is significantly more sophisticated — handles GitHub branch setup, research subagent discovery, iterative alignment via `askQuestions`, TDD per step, visual verification pipeline, reconciliation loops, and plan persistence. The legacy lightweight planner's functionality is fully subsumed.

### 3. Role Title: "technical lead" ✅

**Decision**: Replace the prior managerial role wording with "technical lead" in Code-Conductor.

**Rationale**: "Technical lead" conveys ownership and accountability without corporate hierarchy connotations. More universally applicable across team structures.

### 4. Playwright/Browser Optionality Strategy ✅

**Decision**: Comment/annotate but don't remove — so UI projects get full value while backend projects have clear signals that these sections don't apply.

**Approach by agent**:

| Agent | Adjustment |
|---|---|
| Code-Conductor | YAML comment on `playwright/*` tool; intro note on Visual Verification Gate section; remove the legacy UI-testing skill row from Skill Mapping; "browser MCP usage guidance" → "(if configured)" |
| Code-Critic | YAML comment on `playwright/*` tool; intro note on Browser-Based Review; `browser-mcp.instructions.md (if present)` in Required Reading |
| Issue-Designer | YAML comment on `playwright/*` tool; strengthen "(Optional)" note on View Current App; `browser-mcp.instructions.md (if present)` |
| Issue-Planner | Conditional framing: "If the project has a UI layer..." for UI detection and visual verification |
| UI-Iterator | Add top-of-body note about UI-only applicability; no other changes (agent is inherently UI-focused) |
| Plan-Architect | No change needed — Phase 5b already says "(if UI work)" |

### 5. Repo-Specific References Genericized ✅

**Decision**: Replace hardcoded tool/framework references with generic equivalents.

| Reference | Change |
|---|---|
| `eslint.config.js` in Code-Review-Response | → "project lint configuration" |
| legacy UI-testing skill entry in Code-Conductor | Remove from Skill Mapping (doesn't exist in template skills dir) |
| `browser-mcp.instructions.md (if present)` references | Ensure optionality is explicit |
| `npm test` in Code-Conductor | Already generic in org version: "for example `npm test` when applicable" |

### 6. MIT License ✅

**Decision**: Add MIT LICENSE file to the repository.

**Rationale**: Permissive, widely understood, minimal burden on users. As copyright holder, the licensor is not bound by their own MIT license when reusing in other projects. Corporate use only requires keeping copyright notice + license text.

### 7. Directory Structure ✅

**Decision**: Add `Documents/Design/` and `Documents/Decisions/` directories (with `.gitkeep`).

**Rationale**: Multiple agents reference these directories for design documents and ADRs. They should exist in the template so the workflow works out of the box.

### 8. Skills Update Deferred ✅

**Decision**: Skills framework update is a separate issue.

**Rationale**: Skills are a distinct concern from agent definitions. The org repo has evolved skills significantly, but mixing that into this PR would expand scope unnecessarily. The updated agents reference skills generically via paths, so they work with whatever skills exist.

### 9. .copilot-tracking Stays Gitignored ✅

**Decision**: Keep `.copilot-tracking/` gitignored in the template.

**Rationale**: For a template repo, transient tracking files shouldn't be committed. The org repo tracks them because it's an active project. This is a deliberate difference between template and project usage.

## Agents Changed (Full List)

All agents wholesale replaced from org versions with adjustments noted above:

1. **Code-Conductor** — major rewrite (Ownership Principles, Questioning Policy, Visual Verification Gate, Validation Ladder, etc.)
2. **Code-Critic** — GitHub Review Intake Mode, Rebuttal Round, severity/confidence routing
3. **Code-Review-Response** — Balanced Execution Posture, GitHub Ledger Rule, Improvement Test
4. **Code-Smith** — Parallel Workflow Contract, Bad Test Detection, Requirements Verification
5. **Doc-Keeper** — streamlined, Documentation Maintenance Responsibilities
6. **Issue-Designer** — askQuestions workflow, End-to-End Description, Testing Scope, Completion Gate
7. **Issue-Planner** (NEW) — replaces the legacy lightweight planning agent
8. **Janitor** — Post-Merge Git Workflow, Knowledge Capture
9. **Plan-Architect** — Issue Reading mandatory, Data+Integration rule, Test Scenario Handling
10. **Process-Review** — Terminal Stall Audit, expanded metrics
11. **Refactor-Specialist** — Integration Gaps rule, Cross-File Duplication
12. **Research-Agent** — File Creation rules, Scope Management
13. **Specification** — Test Automation Strategy section, Dependencies section
14. **Test-Writer** — Parallel Workflow, PBT Policy, defect classification
15. **UI-Iterator** — autonomous Playwright loop with fallback
