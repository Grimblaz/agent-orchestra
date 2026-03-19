# Design: Skills Framework

## Summary

The skills framework provides domain-specific knowledge modules loaded on demand by agents from `.github/skills/`. Skills use a `SKILL.md` format with YAML frontmatter and supply procedural guidance, quality standards, and example patterns — but no orchestration logic. The current inventory contains 14 skills.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Migration target | `.github/skills/` (from `.claude/skills/`) | VS Code 1.108 introduced Agent Skills with `.github/skills/` as the standard location (`chat.useAgentSkills` setting); clean break from the legacy path |
| D2 | Content sync strategy | Cherry-pick improvements from upstream (Organizations-of-Elos) | Most OoE skills became project-specific (game design references, hardcoded npm commands); the template versions are deliberately generic with `[CUSTOMIZE]` markers — wholesale replacement would make the template stack-specific |
| D3 | `webapp-testing` addition | Include | Playwright E2E testing is broadly applicable across web projects; content is generic enough for a template |
| D4 | `test-driven-development` rename | Rename from `tdd-workflow` | More descriptive name; matches OoE convention; aligns with standard terminology |
| D5 | `property-based-testing` addition | Include | Incremental rollout policy for randomized property verification alongside example-based tests |

---

## Skill Inventory (14 Skills)

| Skill | Directory | Purpose |
|-------|-----------|---------|
| `brainstorming` | `.github/skills/brainstorming/` | Structured Socratic questioning for exploring ideas and solutions |
| `frontend-design` | `.github/skills/frontend-design/` | Guide for creating distinctive UI designs that avoid generic templates |
| `parallel-execution` | `.github/skills/parallel-execution/` | Build-test orchestration protocol for choosing and running parallel or serial implementation lanes |
| `property-based-testing` | `.github/skills/property-based-testing/` | Incremental rollout policy for property-based testing that preserves readable example-based tests |
| `skill-creator` | `.github/skills/skill-creator/` | Guide for creating new skills in this system with proper frontmatter format |
| `software-architecture` | `.github/skills/software-architecture/` | Clean Architecture, SOLID principles, and architectural decision guidance |
| `systematic-debugging` | `.github/skills/systematic-debugging/` | 4-phase debugging process (Observe, Hypothesize, Test, Fix) for complex issues |
| `test-driven-development` | `.github/skills/test-driven-development/` | Test-Driven Development workflow guidance, quality standards, and practical patterns |
| `ui-testing` | `.github/skills/ui-testing/` | Resilient React component testing strategies focusing on user behavior |
| `verification-before-completion` | `.github/skills/verification-before-completion/` | Evidence-based verification checklist before marking work complete |
| `webapp-testing` | `.github/skills/webapp-testing/` | Playwright end-to-end testing guidance for web apps, with practical patterns and setup steps |
| `browser-canvas-testing` | `.github/skills/browser-canvas-testing/` | VS Code native browser tool behavior for canvas-based games (Phaser 3, etc.) |
| `code-review-intake` | `.github/skills/code-review-intake/` | Deterministic GitHub review intake workflow with ledger-based judgment |
| `post-pr-review` | `.github/skills/post-pr-review/` | Post-merge checklist for archiving, documentation, versioning, and release tagging |

---

## Cherry-Pick Strategy

| Skill | What was cherry-picked from upstream |
|-------|--------------------------------------|
| `skill-creator` | `.github/skills/` paths; VS Code 1.108 `chat.useAgentSkills` discovery info; "Minimal vs Full Skill" pattern; frontmatter validation table |
| `verification-before-completion` | "Iron Law" framing; "Rationalization Prevention" table; "Red Flags — STOP" patterns (genericized, not project-specific) |
| `test-driven-development` | Renamed from `tdd-workflow`; "Iron Law of TDD"; quality hierarchy table; verification checklist; anti-pattern references; `[CUSTOMIZE]` commands preserved |
| `brainstorming` | No content changes — template version already appropriate for a general template |
| `software-architecture` | No content changes — generic Clean Architecture/SOLID guidance preserved |
| `ui-testing`, `systematic-debugging`, `frontend-design` | Path references updated only |

---

## Skill File Format

Every skill lives at `.github/skills/{skill-name}/SKILL.md` with required YAML frontmatter:

```yaml
---
name: skill-name
description: One-sentence description shown in VS Code picker
---
```

Supporting files (e.g., `patterns.md`, `playwright-setup.md`) may live alongside `SKILL.md` in the same directory. Skills provide knowledge and procedural guidance — they must NOT contain agent orchestration logic.

---

## Files Changed

| Action | File |
|--------|------|
| Moved | `.claude/skills/*` → `.github/skills/*` |
| Renamed | `.github/skills/tdd-workflow/` → `.github/skills/test-driven-development/` |
| Created | `.github/skills/webapp-testing/SKILL.md` |
| Created | `.github/skills/webapp-testing/patterns.md` |
| Created | `.github/skills/webapp-testing/playwright-setup.md` |
| Deleted | `.claude/` directory |
| Updated | Agent definitions — `.claude/skills/` → `.github/skills/` path references |
| Updated | `README.md`, `CUSTOMIZATION.md`, `CONTRIBUTING.md` — path + skill table |
| Updated | `.github/scripts/validate-architecture.ps1` — path reference |
| Updated | `.github/skills/README.md` — full rewrite |

---

## Acceptance Criteria

- `grep -r ".claude/skills" . --exclude-dir=Documents` returns zero results (excluding git history and this design doc)
- Each `SKILL.md` has valid frontmatter with `name` and `description`
- `validate-architecture.ps1` checks `.github/skills` path
- VS Code skill discovery works with `chat.useAgentSkills` enabled
- 14 skills present and correctly named
