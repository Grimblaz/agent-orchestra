# Design: Tool Support

## Summary

copilot-orchestra targets **GitHub Copilot in VS Code** as its sole supported tool.
The system previously shipped a Claude Code (Anthropic CLI) compatibility layer —
`CLAUDE.md` project-context files and `.claude/commands/*.md` slash commands — but
this layer was removed in issue #175. Every agent, skill, and instruction file is
authored entirely as GitHub Copilot artifacts.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Tool target | GitHub Copilot only (Claude Code support removed) | `CLAUDE.md` and `.github/copilot-instructions.md` duplicated all project context; dual-maintenance overhead with no net user benefit. Copilot-only focus removed ~831 lines of redundant scaffolding and reduces template complexity. |
| D2 | Historical references in `skills-framework.md` | Retained | `.claude/skills/` migration notes document the prior migration path; removing them would erase useful context for contributors reading git history. These are clearly historical notes, not active configuration. |
| D3 | "Claude Opus" model references | Retained in `setup.prompt.md`, `README.md`, `CUSTOMIZATION.md` | These refer to the Claude Opus AI model available through VS Code Copilot — not the Claude Code CLI. They are model recommendations, not tool compatibility declarations. |

---

## What Was Removed

The following files were deleted entirely as part of issue #175:

- `.claude/commands/implement.md`
- `.claude/commands/review.md`
- `.claude/commands/setup.md`
- `.claude/commands/start-issue.md`
- `CLAUDE.md` (repo root)
- `examples/nodejs-typescript/CLAUDE.md`
- `examples/python/CLAUDE.md`
- `examples/spring-boot-microservice/CLAUDE.md`

---

## What Was Edited

Active references to Claude Code were removed from the following files:

| Category | Files | Change |
|----------|-------|--------|
| Agent files | `Code-Conductor.agent.md`, `Code-Critic.agent.md`, `Issue-Planner.agent.md`, `Solution-Designer.agent.md` | Removed `CLAUDE.md` from evidence source lists; removed "Claude Code does not run this step" parenthetical |
| Design docs | `code-review.md`, `customer-experience-gate.md`, `experience-owner.md`, `hub-mode-ux.md` | Removed `CLAUDE.md` and `.claude/commands/` rows from "Files Changed" tables; removed Claude Code workflow notes |
| User docs | `README.md`, `CUSTOMIZATION.md` | Removed "Claude Code Support" sections, directory tree entries, and file mapping tables |

---

## Scope

The Claude Code removal affected only the **CLI compatibility and project-context duplication layer**:

- All `.github/agents/*.agent.md` files remain fully Copilot-native and unchanged in their role.
- All `.github/skills/*/SKILL.md` files are unchanged — skills were never Claude Code-specific.
- All `.github/instructions/*.instructions.md` files are unchanged.
- The pipeline architecture (Experience-Owner → Solution-Designer → Issue-Planner → Code-Conductor → subagents) is identical.

No workflow capability was lost. Claude Code was a read-only consumer of the same workflow documentation that Copilot agents already produce; removing its compatibility layer does not change what the system does.
