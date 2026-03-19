---
applyTo: "**"
---

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

**Design/plan review** (3× prosecution, 1× defense, 1× judge): full pipeline invoked by Issue-Planner or via start-issue.md. Issue-Designer runs all 3 prosecution passes but stops after prosecution (non-blocking, no defense or judge step).

**CE review**: Code-Conductor exercises scenarios and captures evidence; Code-Critic then reviews adversarially (CE prosecution → defense → judge).

**GitHub review**: proxy prosecution (Code-Critic validates/scores each GitHub comment) → defense → judge.

**Post-fix review** (after accepted fixes are applied): 3× prosecution (diff-scoped), 1× defense, 1× judge — triggered by Critical/High fix or control-flow modification. Loop budget: 1.

**Code-Critic modes** — activated by marker in the prompt:

- _(none)_ — code prosecution (3 passes)
- `"Use design review perspectives"` — design/plan prosecution (2 passes; runs as passes 1–2 of design review)
- `"Use product-alignment perspectives"` — product-alignment prosecution (1 pass; runs as pass 3 of design review)
- `"Use defense review perspectives"` — defense
- `"Use CE review perspectives"` — CE prosecution
- `"Score and represent GitHub review"` — proxy prosecution

## Session Startup Check

At the start of every new conversation, **before responding to the user's first message**, run the session-cleanup detector:

### Step 1 — Check prerequisites

Resolve the root path: use `$env:COPILOT_ORCHESTRA_ROOT` if set; otherwise fall back to `$env:WORKFLOW_TEMPLATE_ROOT`. If neither is set, skip the entire check silently and continue with the user's request.

### Step 2 — Run the detector

```powershell
$copilotRoot = if ($env:COPILOT_ORCHESTRA_ROOT) { $env:COPILOT_ORCHESTRA_ROOT } else { $env:WORKFLOW_TEMPLATE_ROOT }
pwsh -NoProfile -NonInteractive -File "$copilotRoot/.github/scripts/session-cleanup-detector.ps1"
```

### Step 3 — Parse output

- Output is `{}` → continue silently, no prompt
- Output contains `hookSpecificOutput` → stale state found; proceed to Step 4

### Step 4 — Prompt the user

Present the `additionalContext` field from the output to the user using `#tool:vscode/askQuestions` with two options: "Yes — run cleanup" and "No — skip for now".

### Step 5 — Run cleanup (only if confirmed)

Execute the PowerShell code block from `additionalContext` in the terminal. Report what was cleaned up when complete.

Continue with the user's original request regardless of whether cleanup was run, skipped, or declined.

> **Silent skip conditions**: Skip the entire check when neither `$env:COPILOT_ORCHESTRA_ROOT` nor `$env:WORKFLOW_TEMPLATE_ROOT` is set, `pwsh` is not available, or the script produces non-JSON output. See `.github/instructions/session-startup.instructions.md` for full edge case details.

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

After editing any `.md` files, run the Markdown auto-formatter before committing:

```powershell
markdownlint-cli2 --fix "**/*.md"
```

Then run the structural checks:

```powershell
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules" } | Select-String "Plan-Architect").Count  # should be 0
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules" } | Select-String "Janitor").Count  # should be 0
(Get-ChildItem -Path .github -Recurse -Filter "*.md" | Where-Object { $_.Name -notmatch "copilot-instructions|architecture-rules|setup\.prompt" } | Select-String "workflow-template").Count  # should be 0
(Get-ChildItem .github/skills/*/SKILL.md | Where-Object { (Select-String -Path $_ -Pattern '^description:.*Use (when|before)') -eq $null }).Count  # should be 0
(Get-ChildItem .github/skills/*/SKILL.md | Where-Object { (Select-String -Path $_ -Pattern '^description:.*DO NOT USE FOR:') -eq $null }).Count  # should be 0
```
