# Project: Copilot Orchestra

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
                              Specification
```

- **User-facing agents** (6): Issue-Designer, Issue-Planner, Code-Conductor, Code-Critic, Code-Review-Response, UI-Iterator
- **Internal agents** (7): Called automatically by Code-Conductor as subagents (`user-invokable: false`)
- **Skills** (14): Loaded on demand by agents from `.github/skills/`
- **Instructions** (5): Shared rules loaded by agents from `.github/instructions/`

## Key Conventions

- Agent files use `.agent.md` extension with YAML frontmatter (`name`, `description`, `tools`, `handoffs`, `user-invokable`)
- Skills use `SKILL.md` with `name` and `description` frontmatter in `.github/skills/{skill-name}/`
- Instruction files use `.instructions.md` extension in `.github/instructions/`
- Design documents go in `Documents/Design/`, decision records in `Documents/Decisions/`
- No auto-commit behavior — users commit manually
- Plans are saved as GitHub issue comments with `<!-- plan-issue-{ID} -->` markers (preferred for Claude Code — durable and does not pollute the repo); if a local file is needed, save it inside `.copilot-tracking/` which is already gitignored. Note: GitHub Copilot agents store plans in VS Code session memory at `/memories/session/plan-issue-{ID}.md` — Claude Code has no access to session memory, so the issue comment is the equivalent durable storage.
- Design context is cached as a GitHub issue comment with `<!-- design-issue-{ID} -->` marker (Claude Code equivalent of the session memory design cache used by VS Code Copilot agents); created by Issue-Planner when user opts-in to GitHub persistence (same "Yes" prompt as the plan comment — single prompt creates both). If missing at workflow start, read the issue body directly.
- Design content goes in the GitHub issue body (Issue-Designer outputs there)
- `Documents/Design/` files use domain-based naming (`{domain-slug}.md`) and are committed with the implementation PR
- CE Gate uses `ce_gate: true` plan metadata and a `[CE GATE]` step for customer-experience and design-intent verification

## Workflow for Claude Code

Claude Code is a single-agent system. The multi-agent Copilot pipeline translates to a phased single-agent workflow. Each phase references the corresponding agent file as a role guide — read it for standards and checklists.

1. **Plan** — Research the codebase, draft an implementation plan, stress-test it with a Code-Critic design review, get approval before coding.
   Role guide: `.github/agents/Issue-Planner.agent.md`

2. **Implement** — Execute the plan step by step. Write minimal code (YAGNI). Follow TDD when applicable.
   Role guide: `.github/agents/Code-Smith.agent.md`

3. **Test** — Ensure test coverage. Tests describe WHAT the system does, not HOW. Use Arrange-Act-Assert. Prefer integration tests over unit tests for complex interactions.
   Role guide: `.github/agents/Test-Writer.agent.md`

4. **Refactor** — Review all modified files for extraction opportunities, DRY violations, SOLID violations. Proportionate to the change scope.
   Role guide: `.github/agents/Refactor-Specialist.agent.md`

5. **Review** — Scored adversarial pipeline: prosecution → defense → judge. Code-Critic runs 3 prosecution passes (code review), 1 defense pass, then Code-Review-Response judges with confidence scoring and emits a score summary; Code-Conductor routes accepted findings to specialists. Post-fix review: after accepted fixes are applied, Code-Conductor triggers 3 diff-scoped prosecution passes → defense → judge (for Critical/High fixes or control-flow modifications); loop budget 1. Design/plan reviews use 3-pass parallel prosecution (2 standard design + 1 product-alignment) + defense + judge. CE review: Conductor exercises scenarios, Code-Critic prosecutes adversarially (3 lenses), then defense + judge. GitHub review: proxy prosecution → defense → judge.

   For cross-session calibration: after several merged PRs accumulate, run `pwsh -NonInteractive .github/scripts/aggregate-review-scores.ps1` to compute a time-weighted calibration profile. The script analyzes per-finding data from `<!-- pipeline-metrics -->` PR body blocks, computing sustain rates per prosecution category (architecture, security, performance, pattern, simplicity, script-automation, documentation-audit), defense success rates, and judge confidence calibration. Results are reported by Process-Review as actionable recommendations for improving Code-Critic and Code-Review-Response prompts. Apply approved recommendations manually by editing the relevant agent files.
   Role guide: `.github/agents/Code-Critic.agent.md`

6. **Document** — Update design docs, decision records, CHANGELOG as needed.
   Role guide: `.github/agents/Doc-Keeper.agent.md`

7. **Create PR** — Push branch, create PR with summary, changed files list, validation evidence, and `Closes #{issue}`.

## Skills (Domain Knowledge)

Read the relevant `SKILL.md` when working in that domain:

| Skill | Path | When to use |
|-------|------|-------------|
| test-driven-development | `.github/skills/test-driven-development/SKILL.md` | Writing tests first, red-green-refactor, or quality gates |
| systematic-debugging | `.github/skills/systematic-debugging/SKILL.md` | Debugging failures, flaky tests, or tracking root causes |
| software-architecture | `.github/skills/software-architecture/SKILL.md` | Layer boundaries, dependency flow, or ADR-level decisions |
| brainstorming | `.github/skills/brainstorming/SKILL.md` | Exploring features, evaluating approaches, or complex decisions |
| frontend-design | `.github/skills/frontend-design/SKILL.md` | Designing new UI components or evaluating for distinctiveness |
| ui-testing | `.github/skills/ui-testing/SKILL.md` | Component-level React tests, flaky test fixes, React patterns |
| webapp-testing | `.github/skills/webapp-testing/SKILL.md` | Browser-based E2E coverage, test stability, CI execution |
| parallel-execution | `.github/skills/parallel-execution/SKILL.md` | Coordinating parallel implementation lanes and convergence gates |
| property-based-testing | `.github/skills/property-based-testing/SKILL.md` | Randomized testing, input range validation, invariant verification |
| verification-before-completion | `.github/skills/verification-before-completion/SKILL.md` | Before PRs, releases, or any completion declaration |
| skill-creator | `.github/skills/skill-creator/SKILL.md` | Adding new skills, updating templates, or reviewing structure |
| browser-canvas-testing | `.github/skills/browser-canvas-testing/SKILL.md` | HTML canvas elements, game objects, or clickElement failures |
| code-review-intake | `.github/skills/code-review-intake/SKILL.md` | Processing GitHub review comments and reconciling findings |
| post-pr-review | `.github/skills/post-pr-review/SKILL.md` | Post-merge cleanup, archiving tracking files, strategic assessment |

## Shared Instructions

Read these instruction files for cross-cutting rules:

- `.github/instructions/safe-operations.instructions.md` — File operation safety rules, issue creation rules (priority labels required)
- `.github/instructions/tracking-format.instructions.md` — YAML frontmatter format for tracking files
- `.github/instructions/code-review-intake.instructions.md` — GitHub review intake protocol (deterministic ledger-based judgment) _(also available as skill: `.github/skills/code-review-intake/SKILL.md`)_
- `.github/instructions/post-pr-review.instructions.md` — Post-merge checklist (archive tracking, update docs, tag releases) _(also available as skill: `.github/skills/post-pr-review/SKILL.md`)_
- `.github/instructions/session-startup.instructions.md` — detailed reference for edge cases and silent skip conditions; the startup check itself is inline in `.github/copilot-instructions.md` "Session Startup Check" section (no action needed in Claude Code — no startup trigger exists)

## Validation Commands

Run via `pwsh -Command "..."` since these are PowerShell:

```powershell
# Auto-format Markdown files (run before structural checks)
markdownlint-cli2 --fix "**/*.md"
```

```powershell
# Validate no broken references to retired agent names
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules" } | Select-String "Plan-Architect").Count  # should be 0
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules" } | Select-String "Janitor").Count  # should be 0
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules|setup\.prompt" } | Select-String "workflow-template").Count  # should be 0
(Get-ChildItem .github/skills/*/SKILL.md | Where-Object { (Select-String -Path $_ -Pattern '^description:.*Use (when|before)') -eq $null }).Count  # should be 0
(Get-ChildItem .github/skills/*/SKILL.md | Where-Object { (Select-String -Path $_ -Pattern '^description:.*DO NOT USE FOR:') -eq $null }).Count  # should be 0

# Check agent count
(Get-ChildItem .github/agents/*.agent.md).Count  # should be 13
```
