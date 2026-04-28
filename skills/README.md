# Skills Directory

Skills are **knowledge modules** that extend agent capabilities with domain-specific expertise.

## What Are Skills?

- **Agents** = WHO does the work (behavior/persona)
- **Skills** = WHAT they know (domain knowledge)

Skills are loaded on-demand, not always in context. This improves context efficiency, modularity, and reuse.

## Progressive Disclosure (Router Pattern)

Each skill should use this flow:

1. `SKILL.md` is always loaded first
2. Router asks for intent (intake question)
3. Intent routes to targeted references/workflows
4. Only the needed files are loaded

This keeps prompts concise while preserving depth when needed.

## Available Skills (42)

| Skill | Purpose | Status |
| ----- | ------- | ------ |
| `adversarial-review` | Evidence-first prosecution and defense methodology for review workflows | ✅ Included |
| `bdd-scenarios` | Structured Given/When/Then scenario authoring with ID traceability and CE Gate coverage gap detection | ✅ Included |
| `brainstorming` | Structured Socratic questioning for exploring ideas and solutions | ✅ Included |
| `browser-canvas-testing` | VS Code native browser tool behavior for canvas-based games | ✅ Included |
| `calibration-pipeline` | Calibration and review-pipeline tooling guidance | ✅ Included |
| `code-review-intake` | Deterministic GitHub review intake workflow with ledger-based judgment | ✅ Included |
| `customer-experience` | Reusable customer framing and CE evidence methodology | ✅ Included |
| `design-exploration` | Technical design option comparison and decision-framing workflow | ✅ Included |
| `documentation-finalization` | Documentation cleanup and design-doc maintenance workflow | ✅ Included |
| `frontend-design` | Guide for creating distinctive UI designs that avoid generic templates | ✅ Included |
| `guidance-measurement` | Guidance-complexity measurement tooling and deterministic analysis guidance | ✅ Included |
| `implementation-discipline` | Minimal implementation workflow for plan-driven coding | ✅ Included |
| `parallel-execution` | Build-test orchestration protocol for parallel or serial implementation lanes | ✅ Included |
| `plan-authoring` | Implementation-plan authoring methodology | ✅ Included |
| `plugin-release-hygiene` | Version-bump guardrail and Claude startup drift backstop guidance | ✅ Included |
| `post-pr-review` | Post-merge checklist for archiving, documentation, versioning, and release tagging | ✅ Included |
| `pre-commit-formatting` | Final markdown and whitespace formatting backstop before validation | ✅ Included |
| `process-analysis` | Retrospective and process-analysis methodology for workflow review | ✅ Included |
| `process-troubleshooting` | Five-scenario guide for diagnosing common orchestration failure patterns | ✅ Included |
| `property-based-testing` | Incremental rollout policy for property-based testing | ✅ Included |
| `provenance-gate` | First-contact issue-framing assessment for cold pickups | ✅ Included |
| `refactoring-methodology` | Proportionate refactoring workflow for touched files and nearby debt | ✅ Included |
| `research-methodology` | Evidence-driven technical research and recommendation workflow | ✅ Included |
| `review-judgment` | Single-shot review judgment and scoring methodology | ✅ Included |
| `routing-tables` | Deterministic routing data for specialist dispatch and gate criteria | ✅ Included |
| `safe-operations` | Safe file-operation and issue-creation protocol | ✅ Included |
| `session-memory-contract` | Canonical session-state survival and handoff contract | ✅ Included |
| `session-startup` | Automatic startup cleanup guard for new conversations | ✅ Included |
| `skill-creator` | Guide for creating new skills with proper frontmatter format | ✅ Included |
| `software-architecture` | Clean Architecture, SOLID principles, and architectural decision guidance | ✅ Included |
| `specification-authoring` | Structured authoring guidance for formal specifications | ✅ Included |
| `step-commit` | Discrete validated-step commit workflow for Code-Conductor | ✅ Included |
| `subagent-env-handshake` | Claude subagent environment-handshake contract for tree-grounded claims | ✅ Included |
| `systematic-debugging` | 4-phase debugging process (Observe, Hypothesize, Test, Fix) | ✅ Included |
| `terminal-hygiene` | Terminal and test execution guardrails for Agent Orchestra workflows | ✅ Included |
| `test-driven-development` | TDD workflow guidance, quality standards, and practical patterns | ✅ Included |
| `tracking-format` | Tracking-file frontmatter and local coordination format guidance | ✅ Included |
| `ui-iteration` | Screenshot-driven UI polish workflow | ✅ Included |
| `ui-testing` | Resilient React component testing strategies focusing on user behavior | ✅ Included |
| `validation-methodology` | Staged validation and review methodology for implementation workflows | ✅ Included |
| `verification-before-completion` | Evidence-based verification checklist before marking work complete | ✅ Included |
| `webapp-testing` | Playwright end-to-end testing guidance for web apps | ✅ Included |

## How to Use a Skill

1. Read `skills/{skill-name}/SKILL.md`
2. Answer the intake prompt in that router
3. Load the routed reference/workflow file(s)
4. Execute the selected guidance

### Example: Using test-driven-development

```text
Agent: I need to write tests for a new feature
1. Read skills/test-driven-development/SKILL.md
2. Choose "write" in intake
3. Read skills/test-driven-development/workflows/write-tests-first.md
4. Follow RED-phase workflow
```

### VS Code 1.108+ Discovery

Skills with `name` + `description` in SKILL.md frontmatter are discoverable in VS Code 1.108+ when `chat.useAgentSkills` is enabled.

```yaml
---
name: my-skill
description: What this skill does. Use when {trigger conditions}. DO NOT USE FOR: {negative scenarios} (use {other-skill}).
---
```

## Skill Structure

```text
skill-name/
├── SKILL.md              # Router (always loaded)
├── workflows/            # Step-by-step procedures
├── references/           # Domain knowledge
├── templates/            # Reusable output structures
└── scripts/              # Optional executable helpers
```

## Creating New Skills

Use `skill-creator` for guided creation.

Quick reference:

1. Create `skills/{your-skill-name}/`
2. Add `SKILL.md` with `name` + `description`
3. Add references/workflows/templates as needed
4. Update this README

See `skill-creator/SKILL.md` for detailed guidance and `test-driven-development/` for a complete example.

## Customization

> Skills may include stack-specific examples. Keep conceptual guidance intact and adapt commands/selectors/URLs for your project.
