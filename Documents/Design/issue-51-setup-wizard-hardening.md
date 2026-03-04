# Design: Setup Wizard First-Run Hardening

**Issue**: #51
**Date**: 2026-03-03
**Status**: Finalized

## Summary

Hardened the 6-phase setup wizard (`/setup`) for first-run scenarios on empty workspaces and
non-template repos. Adds Phase 0 workspace pre-flight checks, opt-in Phase 2 tech-stack guidance,
and aligned documentation across `README.md` and `CUSTOMIZATION.md`.

## Context

Issue #51 was opened after the setup wizard failed for a user in two ways:

1. **Empty workspace crash** — VS Code's Workspace context provider crashes on zero-file
   workspaces (`Cannot read properties of undefined (reading 'fileName')`). This is a VS Code
   runtime bug triggered by the automatic workspace context inclusion in chat.

2. **Phase 0 stall** — `setup.prompt.md` used `mode: ask` frontmatter, which restricts tool
   access. Phase 0 needs terminal commands (`code --version`, etc.) and Phase 5 needs file
   creation tools — neither is available in Ask mode.

This PR applies the frontmatter fix (`mode: ask` → `agent: agent`) and completes all remaining
hardening work.

## Design Decisions

### 1. Frontmatter: `agent: agent`

**Decision**: Change `mode: ask` to `agent: agent`.

**Rationale**: VS Code 1.109+ deprecated the `mode` frontmatter key; the linter confirms:
"The 'mode' attribute has been deprecated. Please rename it to 'agent'." The value was also
changed from `ask` to `agent` because Ask mode has no tool access, which is required for:

- Phase 0: running terminal commands (`code --version`, `pwsh --version`, etc.)
- Phase 0 pre-flight: listing workspace files and creating `README.md`
- Phase 5: creating `.gitignore`, `.vscode/` files, and `Documents/` structure

The prior rejection of `agent: ask` (issue #20) was about a different concern — agent-mode
prompt files that bypass the interactive slash-command flow. `agent: agent` is the correct
VS Code 1.109+ syntax for a prompt file that needs tool access.

### 2. Phase 0 Pre-flight Checks

**Decision**: Add three new pre-flight checks as the first Phase 0 actions:

- **Check 0**: Display working directory and confirm before any file creation
- **Check 1**: If workspace has zero user-visible files (excluding `.git/`), create `README.md`
  placeholder and inform the user
- **Check 2**: If `.github/agents/` contains 10+ `.agent.md` files, warn that this may be the
  workflow-template repo itself

**Rationale**: The empty-workspace crash (Failure 1) is a VS Code upstream bug. The correct mitigation
is to ensure the workspace has at least one file before the context provider runs. Automating this
in Phase 0 is preferable to requiring users to do it manually.

The working-directory confirmation (Check 0) gates file creation to prevent silent `README.md`
creation in the wrong repo. The wrong-workspace heuristic (Check 2) uses 10+ agent files as a
reliable signal — the template ships 13 agents; target projects rarely have 10+ at setup time.

### 3. Phase 2 Opt-In Tech Stack Guidance

**Decision**: Add "*(or say 'not sure' for help choosing)*" hint to Q3, Q4, Q5 question text,
with LLM-side `> *Not sure?*` guidance blocks that trigger a clarify → reason → recommend flow.

**Rationale**: New users starting fresh projects (e.g., an NFL management sim) may not know
what tech stack to pick. The flow is opt-in: experienced users answer directly. The LLM
contextualizes recommendations using the project description from Q2.

### 4. Documentation Alignment

**Decision**: Update all three surfaces (setup.prompt.md, README.md, CUSTOMIZATION.md) to
describe Phase 0's empty-workspace auto-handling and recommend Claude Opus.

**Rationale**: Users discover `/setup` from either docs or the prompt file. Both must reflect
the same behavior. Notes telling users to "create a README.md first" were removed — Phase 0
handles this automatically.

## Files Changed

| File | Change |
|------|--------|
| `.github/prompts/setup.prompt.md` | Phase 0 pre-flight checks; "Not sure?" hints; Opus callout; Gen section README update |
| `README.md` | Empty-workspace note; Opus recommendation |
| `CUSTOMIZATION.md` | Empty-workspace note; Opus recommendation; Phase 0 table row update |
