---
applyTo: "**"
---

# Project: Copilot Orchestra

## Overview

Multi-agent workflow system for GitHub Copilot. Provides specialized agents, skills, and prompt templates that orchestrate AI-assisted software development.

## Technology Stack

- **Language**: Markdown (agent definitions, skills, instructions, documentation)
- **Framework**: VS Code Custom Agents (`.agent.md` format with YAML frontmatter)
- **Build Tool**: None (no compiled code)
- **Testing**: Pester (`.github/scripts/Tests/`), plus manual verification and grep-based structural checks
- **BDD Framework (opt-in)**: Structured G/W/T scenarios with scenario ID traceability and CE Gate coverage gap detection. Consumer repos enable by adding a `## BDD Framework` section to their `copilot-instructions.md`. Template ships BDD-disabled; see `.github/skills/bdd-scenarios/SKILL.md` for authoring patterns. **Phase 2 (runner dispatch)**: add `bdd: {framework}` under the heading (recognized values: `cucumber.js`, `behave`, `jest-cucumber`, `cucumber`) to enable Gherkin file generation by Test-Writer and automated runner dispatch at CE Gate time by Code-Conductor.

## Architecture

Pipeline-based agent orchestration:

```text
@Experience-Owner → @Solution-Designer → @Issue-Planner → @Code-Conductor → PR
                                                ↓
                              Code-Smith, Test-Writer, Refactor-Specialist,
                              Doc-Keeper, Research-Agent, Process-Review,
                              Specification
(CE Gate: @Code-Conductor delegates evidence capture to @Experience-Owner)
```

- **User-facing agents** (7): Experience-Owner, Solution-Designer, Issue-Planner, Code-Conductor, Code-Critic, Code-Review-Response, UI-Iterator
- **Internal agents** (7): Called automatically by Code-Conductor as subagents (`user-invocable: false`)
- **Skills** (39): Loaded on demand by agents from `.github/skills/`
- **Instruction files**: Repo-local instruction files remain under `.github/instructions/`, while shared workflow rules load from skills

## Key Conventions

- Agent files use `.agent.md` extension with YAML frontmatter (`name`, `description`, `tools`, `handoffs`, `user-invocable`)
- Skills use `SKILL.md` with `name` and `description` frontmatter in `.github/skills/{skill-name}/`
- Instruction files use `.instructions.md` extension in `.github/instructions/`; shared workflow guidance is migrating to skill-owned `SKILL.md` files
- Design documents go in `Documents/Design/`, decision records in `Documents/Decisions/`
- Code-Conductor auto-commits after each validated step by default (see `## Commit Policy` opt-out in consumer `copilot-instructions.md`); specialist agents do not commit independently
- Plans are saved to session memory (`/memories/session/plan-issue-{ID}.md`), which is the same-session source of truth for implementation handoff
- Design context is cached in session memory (`/memories/session/design-issue-{ID}.md`), reused by Issue-Planner when the current snapshot is still valid and refreshed from the issue body when missing or after current-pass issue/design updates; Solution-Designer still persists design details to the issue body unconditionally during design
- VS Code auto-compacts conversation when context fills; session memory (`/memories/session/`) survives compaction within the same conversation. At D9, if the user explicitly chooses Stop / Pause / resume later, Code-Conductor persists durable GitHub handoff comments with `<!-- plan-issue-{ID} -->` / `<!-- design-issue-{ID} -->`; Continue uses session memory only
- Design content goes in the GitHub issue body (Solution-Designer outputs there)
- `Documents/Design/` files use domain-based naming (`{domain-slug}.md`) and are committed with the implementation PR by Code-Conductor (delegated to Doc-Keeper)
- CE Gate uses `ce_gate: true` plan metadata and a `[CE GATE]` step for customer-experience and design-intent verification

## Code-Critic Adversarial Review Protocol

This repo uses the Code-Critic / Code-Review-Response scored prosecution → defense → judge review protocol.

Load the relevant agent guidance and follow that protocol for code review, design review, CE review, GitHub review, and post-fix review.

## Build & Run

No build step. This is a configuration/documentation template.

### Commands

```powershell
# Run PowerShell script test suite (Pester)
pwsh -NoProfile -NonInteractive -Command "Invoke-Pester .github/scripts/Tests/ -Output Minimal"
# Final-gate full suite: see Terminal & Test Hygiene > `isBackground` Default exception (final-gate full suite). In fixture mode (default), isBackground: false is fine. For live-refresh runs (PESTER_LIVE_GH=1), use isBackground: true + poll with `get_terminal_output` to read results (Pester 5 sends pass/fail output to the terminal buffer, not to file streams — `*>` redirection only captures advisory output such as `Write-Warning`).

# Validate structural checks (broken references, skill frontmatter, complexity, lint)
pwsh -NoProfile -NonInteractive -File .github/scripts/quick-validate.ps1

# Check agent count
(Get-ChildItem .github/agents/*.agent.md).Count  # should be 14
```

### Script Library Convention

Production automation lives either under `.github/scripts/` or under the owning skill's `scripts/` directory, with thin CLI wrappers dot-sourcing companion `*-core.ps1` libraries where applicable. Tests dot-source the core libraries directly and call the function in-process, avoiding per-test `pwsh` child process spawning. Private helpers inside a library embed a short uppercase prefix in the noun segment (`NW`, `WCE`, `SCD`) to avoid name collisions across dot-sourced files (e.g., `Test-NWAllowlistedPath`, `Test-WCEHasProperty`, `Get-SCDDefaultBranch`).

```powershell
# Example: call aggregate-review-scores logic in-process
. .github/skills/calibration-pipeline/scripts/aggregate-review-scores-core.ps1
Invoke-AggregateReviewScores -Repo owner/name
# Example: with mock gh CLI for tests (no live API calls)
# Invoke-AggregateReviewScores -Repo owner/name -GhCliPath $mockGhScript
```

## Safe Operations

When choosing workspace tools, reading or mutating files, or creating follow-up GitHub issues, load the `safe-operations` skill and follow its protocol.

## Quick-validate (used by agents before every PR)

After editing any `.md` files, run the Markdown auto-formatter before committing:

```powershell
markdownlint-cli2 --fix "**/*.md"
```

Then run the structural checks:

```powershell
pwsh -NoProfile -NonInteractive -File .github/scripts/quick-validate.ps1
```

## Terminal & Test Hygiene

> These rules supplement (do not replace) any agent-specific terminal guidance.

During implementation and validation work, load the `terminal-hygiene` skill and follow its protocol.

Use `isBackground: false` / `mode: sync` for commands expected to complete in under 60 seconds.
