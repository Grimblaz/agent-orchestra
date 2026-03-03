---
applyTo: "**"
---

# Project: Copilot Workflow Template

## Overview

Multi-agent workflow system for GitHub Copilot. Provides specialized agents, skills, instruction files, and prompt templates that orchestrate AI-assisted software development.

## Technology Stack

- **Language**: Markdown (agent definitions, skills, instructions, documentation)
- **Framework**: VS Code Custom Agents (`.agent.md` format with YAML frontmatter)
- **Build Tool**: None (no compiled code)
- **Testing**: Manual verification, grep-based validation

## Architecture

Pipeline-based agent orchestration:

```text
Issue → @Issue-Designer → @Issue-Planner → @Code-Conductor → PR
                                                ↓
                              Code-Smith, Test-Writer, Refactor-Specialist,
                              Doc-Keeper, Research-Agent, Process-Review,
                              Specification, UI-Iterator
```

- **User-facing agents** (5): Issue-Designer, Issue-Planner, Code-Conductor, Code-Critic, Code-Review-Response
- **Internal agents** (8): Called automatically by Code-Conductor as subagents (`user-invokable: false`)
- **Skills** (11): Loaded on demand by agents from `.github/skills/`
- **Instructions** (4): Shared rules loaded by agents from `.github/instructions/`

## Key Conventions

- Agent files use `.agent.md` extension with YAML frontmatter (`name`, `description`, `tools`, `handoffs`, `user-invokable`)
- Skills use `SKILL.md` with `name` and `description` frontmatter in `.github/skills/{skill-name}/`
- Instruction files use `.instructions.md` extension in `.github/instructions/`
- Design documents go in `Documents/Design/`, decision records in `Documents/Decisions/`
- No auto-commit behavior in any agent — users commit manually
- Plans are posted as structured issue comments (authoritative for cloud agent handoffs)
- Design content goes in the GitHub issue body (Issue-Designer outputs there)
- `Documents/Design/` files are committed with the implementation PR by Code-Conductor
- CE Gate uses `ce_gate: true` plan metadata and a `[CE GATE]` step for customer-experience verification

## Agent Workflow Settings

```yaml
critic_passes: 3
```

This repo uses 3 independent Code-Critic passes per review cycle. Each pass surfaces complementary findings; they are not duplicates.

## Build & Run

No build step. This is a configuration/documentation template.

### Commands

```bash
# Validate no broken references
grep -r "Plan-Architect" .github/ --include="*.md" | grep -v "copilot-instructions.md" | grep -v "architecture-rules.md" | wc -l  # should be 0

# Check agent count
ls .github/agents/*.agent.md | wc -l  # should be 13
```

## Quick-validate (used by agents before every PR)

```bash
grep -r "Plan-Architect" .github/ --include="*.md" | grep -v "copilot-instructions.md" | grep -v "architecture-rules.md" | wc -l  # 0
grep -r "Janitor" .github/ --include="*.md" | grep -v "copilot-instructions.md" | grep -v "architecture-rules.md" | wc -l  # 0
```
