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

## Available Skills (15)

| Skill | Purpose | Status |
| ----- | ------- | ------ |
| `brainstorming` | Structured Socratic questioning for exploring ideas and solutions | ✅ Included |
| `frontend-design` | Guide for creating distinctive UI designs that avoid generic templates | ✅ Included |
| `skill-creator` | Guide for creating new skills with proper frontmatter format | ✅ Included |
| `software-architecture` | Clean Architecture, SOLID principles, and architectural decision guidance | ✅ Included |
| `systematic-debugging` | 4-phase debugging process (Observe, Hypothesize, Test, Fix) | ✅ Included |
| `test-driven-development` | TDD workflow guidance, quality standards, and practical patterns | ✅ Included |
| `ui-testing` | Resilient React component testing strategies focusing on user behavior | ✅ Included |
| `verification-before-completion` | Evidence-based verification checklist before marking work complete | ✅ Included |
| `webapp-testing` | Playwright end-to-end testing guidance for web apps | ✅ Included |
| `parallel-execution` | Build-test orchestration protocol for parallel or serial implementation lanes | ✅ Included |
| `property-based-testing` | Incremental rollout policy for property-based testing | ✅ Included |
| `browser-canvas-testing` | VS Code native browser tool behavior for canvas-based games | ✅ Included |
| `code-review-intake` | Deterministic GitHub review intake workflow with ledger-based judgment | ✅ Included |
| `post-pr-review` | Post-merge checklist for archiving, documentation, versioning, and release tagging | ✅ Included |
| `process-troubleshooting` | Five-scenario guide for diagnosing common orchestration failure patterns | ✅ Included |

## How to Use a Skill

1. Read `.github/skills/{skill-name}/SKILL.md`
2. Answer the intake prompt in that router
3. Load the routed reference/workflow file(s)
4. Execute the selected guidance

### Example: Using test-driven-development

```text
Agent: I need to write tests for a new feature
1. Read .github/skills/test-driven-development/SKILL.md
2. Choose "write" in intake
3. Read .github/skills/test-driven-development/workflows/write-tests-first.md
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

1. Create `.github/skills/{your-skill-name}/`
2. Add `SKILL.md` with `name` + `description`
3. Add references/workflows/templates as needed
4. Update this README

See `skill-creator/SKILL.md` for detailed guidance and `test-driven-development/` for a complete example.

## Customization

> Skills may include stack-specific examples. Keep conceptual guidance intact and adapt commands/selectors/URLs for your project.
