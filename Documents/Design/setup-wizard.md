# Design: Setup Wizard

## Summary

The `/setup` prompt (`setup.prompt.md`) is a 6-phase interactive wizard that configures a new or existing repository for Copilot Orchestra. It generates scaffolding files directly, asks before overwriting, and guards against re-runs on already-configured repos. The wizard is safe to re-run at any time; skip gates at each phase prevent redundant work.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Setup approach | Wizard generates scaffolding files directly | Users get a working repo state after a single prompt run; no manual copy-paste |
| D2 | Frontmatter key | `agent: agent` | VS Code 1.109+ deprecated the `mode` key. `mode: ask` was also wrong in value — Ask mode has no tool access, and Phase 0 (terminal commands) and Phase 5 (file creation) both require tools |
| D3 | Phase structure | 6 phases with skip gates at Phases 1–5 (Phase 4 conditional) | Phases can be re-run safely; experienced users skip phases they've already completed |
| D4 | Shared workflow safety guidance | `safe-operations` skill (`.github/skills/safe-operations/SKILL.md`) extracted from Countdown-Clash patterns | Single source of truth for file-operation and issue-creation rules; delivered through skills rather than a shared hub instruction path |
| D5 | browser-tools.instructions.md | Per-project generated file, not shipped in template | Browser tool config is project-specific; non-web projects get no irrelevant instructions |
| D6 | Phase 5d default | VS Code 1.110+ native browser tools primary; Playwright MCP optional | Reduces friction for new users to zero — just enable `workbench.browser.enableChatTools`; no MCP server required |

---

## Phase Structure

| Phase | Name | Focus | Skip Gate |
|-------|------|-------|-----------|
| 0 | Prerequisites Check | Pre-flight checks + tool version detection | None — always runs |
| 1 | User Setup | Set `COPILOT_ORCHESTRA_ROOT` env var (machine-level) | Already set to a valid path |
| 2 | Project Basics | Generate `.github/copilot-instructions.md` | File already exists (keep or regenerate) |
| 3 | Architecture & Conventions | Generate `.github/architecture-rules.md` | File already exists (keep or regenerate) |
| 4 | Commands | Collect build / run / test / lint commands | All of Phases 2, 3, and 5 are skipped |
| 5 | Project Scaffolding | Generate `.gitignore`, `.vscode/`, `Documents/` files | User opts out of scaffolding |

### Phase 0 Pre-Flight Checks

Three checks run before any file creation:

- **Check 0**: Display working directory and confirm before any file creation — gates all subsequent file writes to prevent silent creation in the wrong repo.
- **Check 1**: If workspace has zero user-visible files (excluding `.git/`), create a `README.md` placeholder automatically. Workaround for VS Code's workspace context provider crash on empty workspaces (`Cannot read properties of undefined (reading 'fileName')`).
- **Check 2**: If `.github/agents/` contains 10+ `.agent.md` files, warn that this may be the copilot-orchestra repo itself (heuristic: the template ships 14 agents; target projects rarely have 10+ at setup time).

Phase 0 also runs `code --version`, `pwsh --version`, `git --version`, and `gh --version` to detect prerequisites automatically.

### Phase 5 Sub-Steps

| Sub-step | Output |
|----------|--------|
| 5a | `.gitignore` additions |
| 5b | `.vscode/settings.json` |
| 5c | `.vscode/extensions.json` |
| 5d | `.github/instructions/browser-tools.instructions.md` (web projects only); configures native browser tools as primary, Playwright MCP as optional |
| 5e | `Documents/` directory structure |

---

## `safe-operations` Skill

Originally introduced as an instruction file, then migrated to `.github/skills/safe-operations/SKILL.md`. It contains two sections:

1. **File Operation Rules** — correct tools by operation, FORBIDDEN PowerShell write commands (Set-Content, Out-File, Add-Content, New-Item -Value, echo redirect, .NET static IO methods), read-only operation preferences.
2. **Issue Creation Rules** — improvement-first decision rule (< 1 day: in-PR; > 1 day: create follow-up issue), priority label requirement for every `gh issue create` call.

For clone-based setups, it is loaded from `.github/skills/` via `chat.agentSkillsLocations`. For plugin users, it ships with the plugin because it is a skill.

---

## Files Changed

| File | Change |
|------|--------|
| `.github/prompts/setup.prompt.md` | Rewritten 81 → 345+ lines; 2-stage → 6-phase wizard; `agent: agent` frontmatter; Phase 0 pre-flight checks; opt-in tech stack guidance in Phase 2; Opus recommendation |
| `.github/skills/safe-operations/SKILL.md` | Current home of the file-op + issue-creation rules (migrated from the former instruction file) |
| `.github/copilot-instructions.md` | Instruction count 3 → 4; PowerShell replaces POSIX commands |
| `README.md` | Quick Start updated to reflect 6-phase wizard; empty-workspace note; Opus recommendation |
| `CUSTOMIZATION.md` | Phase table; hook tip; scaffolding section; empty-workspace note |

---

## Acceptance Criteria

- Clone → agent within 2 min, no file creation needed
- Default config files functional out of box (real project context ships with template)
- Clear path for new users to configure their project via `/setup`
- Phase 0 pre-flight prevents wrong-workspace file creation
- Empty workspace auto-handled — no manual `README.md` required before running `/setup`
- `agent: agent` frontmatter gives Phase 0 and Phase 5 full tool access
