# Issue #57 — VS Code 1.110 Compatibility: askQuestions Audit

## Overview

Audit and update all agent files, instructions, and skills to use the correct VS Code 1.110 tool name `vscode/askQuestions` (replacing stale `ask_questions` references) and to declare the tool explicitly in frontmatter where needed.

## Problem Statement

VS Code 1.110 renamed the questioning tool from `ask_questions` to `vscode/askQuestions`. When agents reference a tool name that does not match the declared frontmatter entry, the tool may not be available at runtime. Additionally:

- Issue-Designer had no enforcement section for the Questioning Policy
- Code-Review-Response was missing the tool declaration in frontmatter entirely
- 29 stale `ask_questions` references remained across agent bodies, instructions, and skills
- VS Code 1.110 introduced `/create-*` slash commands not documented in skill-creator
- VS Code 1.110 added an Agent Debug Panel not documented in CUSTOMIZATION.md

## Design Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | Standardize all body references to `vscode/askQuestions` everywhere | Ensures runtime alignment; eliminates confusion between old and new name |
| D2 | Add full Questioning Policy enforcement section to Issue-Designer | Issue-Designer is highly interactive; weak enforcement caused silent failures |
| D3 | Explicitly declare `vscode/askQuestions` in Code-Review-Response frontmatter | Missing declaration despite 11 body references — critical gap |
| D4 | `Documents/Design/` files frozen — no changes | Historical design records; stale references inside are acceptable |

## Changes Made

### Agent Files

- **`.github/agents/Issue-Designer.agent.md`** — Added `"vscode/askQuestions"` to tools frontmatter; added `## Questioning Policy (Mandatory)` section before Stage 1 modeled on Code-Conductor's zero-tolerance pattern; strengthened Collaboration Pattern step 3 with Hard rule.
- **`.github/agents/Code-Review-Response.agent.md`** — Added `"vscode/askQuestions"` as first entry in tools frontmatter. Body already had 11 correct references.
- **`.github/agents/Code-Conductor.agent.md`** — Added `vscode/askQuestions` as first entry in tools frontmatter (critical fix — was undeclared despite 24 body references); replaced all 24 bare `ask_questions` references; grammar fix ("a `vscode/askQuestions`"); added `## Context Management for Long Sessions` section before `## Handoff to User` with `/compact` guidance.

### Instructions & Skills

- **`.github/instructions/code-review-intake.instructions.md`** — 1 reference replaced.
- **`.github/skills/parallel-execution/SKILL.md`** — 1 reference replaced.
- **`.github/prompts/setup.prompt.md`** — 3 references replaced.
- **`.github/skills/skill-creator/SKILL.md`** — Added `## Built-in Creation Commands (VS Code 1.110+)` section listing `/create-skill`, `/create-agent`, `/create-prompt`, `/create-instruction`; added fallback blockquote for 1.108–1.109 users.

### Documentation

- **`CUSTOMIZATION.md`** — Added Agent Debug Panel documentation to Troubleshooting section (available since VS Code 1.110, supersedes earlier Diagnostics chat action).

## Deferred Items

| Item | Reason |
|------|--------|
| `#tool:` prefix standardization across agents | Pre-existing style divergence (Issue-Planner/Issue-Designer use `#tool:vscode/askQuestions`; Code-Conductor/Code-Review-Response use plain backtick). Both styles work; unification is a separate incremental improvement. |

## Validation

- Bare `` `ask_questions` `` references in `.github/`: **0**
- Quick-validate: Plan-Architect refs = 0, Janitor refs = 0
- Agent count: 13 (unchanged)
- All 4 agents using `vscode/askQuestions` in body now declare it in frontmatter ✅
