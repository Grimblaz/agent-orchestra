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
- **Skills** (14): Loaded on demand by agents from `.github/skills/`
- **Instructions** (5): Shared rules loaded by agents from `.github/instructions/`

## Key Conventions

- Agent files use `.agent.md` extension with YAML frontmatter (`name`, `description`, `tools`, `handoffs`, `user-invokable`)
- Skills use `SKILL.md` with `name` and `description` frontmatter in `.github/skills/{skill-name}/`
- Instruction files use `.instructions.md` extension in `.github/instructions/`
- Design documents go in `Documents/Design/`, decision records in `Documents/Decisions/`
- No auto-commit behavior in any agent — users commit manually
- Plans are saved to session memory (`/memories/session/plan-issue-{ID}.md`), optionally persisted as GitHub issue comments
- Design context is cached in session memory (`/memories/session/design-issue-{ID}.md`), created by Issue-Planner alongside the plan — full design content from the issue body, surviving conversation compaction; optionally persisted as a GitHub issue comment with `<!-- design-issue-{ID} -->` marker
- VS Code auto-compacts conversation when context fills; session memory (`/memories/session/`) is the durable store — plans and design context survive compaction automatically (but not session end — use GitHub issue comments for cross-session durability)
- Design content goes in the GitHub issue body (Issue-Designer outputs there)
- `Documents/Design/` files use domain-based naming (`{domain-slug}.md`) and are committed with the implementation PR by Code-Conductor (delegated to Doc-Keeper)
- CE Gate uses `ce_gate: true` plan metadata and a `[CE GATE]` step for customer-experience and design-intent verification

## Code-Critic Adversarial Review Protocol

This repo uses a **scored prosecution → defense → judge pipeline** across all review stages.

**Code review** (3× prosecution, 1× defense, 1× judge):

- 3 independent parallel Code-Critic prosecution passes (hard-coded, not configurable)
- 1 Code-Critic defense pass over the merged findings ledger
- 1 Code-Review-Response judge pass with confidence scoring + score summary

**Design/plan review** (1× prosecution, 1× defense, 1× judge): full pipeline invoked by Issue-Planner or via start-issue.md. Issue-Designer runs prosecution only (non-blocking, no defense or judge step).

**CE review**: Code-Conductor exercises scenarios and captures evidence; Code-Critic then reviews adversarially (CE prosecution → defense → judge).

**GitHub review**: proxy prosecution (Code-Critic validates/scores each GitHub comment) → defense → judge.

**Post-fix review** (after accepted fixes are applied): 3× prosecution (diff-scoped), 1× defense, 1× judge — triggered by Critical/High fix or control-flow modification. Loop budget: 1.

**Code-Critic modes** — activated by marker in the prompt:

- _(none)_ — code prosecution (3 passes)
- `"Use design review perspectives"` — design/plan prosecution (1 pass)
- `"Use defense review perspectives"` — defense
- `"Use CE review perspectives"` — CE prosecution
- `"Score and represent GitHub review"` — proxy prosecution

## Build & Run

No build step. This is a configuration/documentation template.

### Commands

```powershell
# Validate no broken references
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules" } | Select-String "Plan-Architect").Count  # should be 0

# Check agent count
(Get-ChildItem .github/agents/*.agent.md).Count  # should be 13
```

## Quick-validate (used by agents before every PR)

```powershell
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules" } | Select-String "Plan-Architect").Count  # should be 0
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules" } | Select-String "Janitor").Count  # should be 0
```
