# Design: Migrate Skills to .github/skills/

**Issue**: #19
**Date**: 2026-02-16
**Status**: Design Complete

## Summary

Migrate the skills framework from `.claude/skills/` to `.github/skills/` to align with VS Code 1.108's official Agent Skills standard (`chat.useAgentSkills` setting). Cherry-pick quality improvements from the upstream Organizations-of-Elos project while keeping template-generic content.

## Background

- **VS Code 1.108** (December 2025) introduced Agent Skills with `.github/skills/` as the standard location
- **Organizations-of-Elos** has already migrated and evolved skills since the template extraction
- This template still uses `.claude/skills/` with skills from the original extraction

## Design Decisions

### Decision 1: Content Sync Strategy — Cherry-Pick Improvements

**Chosen**: Bring over structural and quality improvements from OoE while keeping the template's generic `[CUSTOMIZE]` markers. Do NOT replace template content wholesale with OoE content.

**Rationale**: Most OoE skills have become project-specific (game design references, hardcoded npm commands). The template versions are deliberately generic. Wholesale replacement would make the template stack-specific.

**What to cherry-pick per skill**:

| Skill | Cherry-pick targets |
| --- | --- |
| `skill-creator` | `.github/skills/` paths, VS Code 1.108 `chat.useAgentSkills` discovery info, "Minimal vs Full Skill" pattern, frontmatter validation table |
| `verification-before-completion` | "Iron Law" framing, "Rationalization Prevention" table, "Red Flags - STOP" patterns (genericized, not npm-specific) |
| `test-driven-development` | Rename from `tdd-workflow`. Bring over "Iron Law of TDD", quality hierarchy table, verification checklist, anti-pattern references. Keep `[CUSTOMIZE]` commands. |
| `brainstorming` | No content changes — template version is already more appropriate for a general template |
| `software-architecture` | No content changes — template version has generic Clean Architecture/SOLID guidance |
| `ui-testing` | Path references only |
| `systematic-debugging` | Path references only |
| `frontend-design` | Path references only |

### Decision 2: Include webapp-testing — Yes

**Chosen**: Add `webapp-testing` skill from OoE (SKILL.md, patterns.md, playwright-setup.md).

**Rationale**: Playwright E2E testing is broadly applicable across web projects. The content is generic enough for a template. Expands the skill count to 9 which covers more common workflows.

### Decision 3: Rename tdd-workflow to test-driven-development — Yes

**Chosen**: Rename `tdd-workflow/` to `test-driven-development/`.

**Rationale**: More descriptive name, matches OoE convention, aligns with standard terminology.

## Implementation Scope

### Files to Create/Move

| Action | From | To |
| --- | --- | --- |
| Move | `.claude/skills/*` | `.github/skills/*` |
| Rename | `.github/skills/tdd-workflow/` | `.github/skills/test-driven-development/` |
| Create | N/A | `.github/skills/webapp-testing/SKILL.md` |
| Create | N/A | `.github/skills/webapp-testing/patterns.md` |
| Create | N/A | `.github/skills/webapp-testing/playwright-setup.md` |
| Delete | `.claude/` directory | (after move) |

### Files Requiring Reference Updates

All references to `.claude/skills/` must be updated to `.github/skills/`:

**Agent definitions** (~6 files):

- `Code-Critic.agent.md` — 3 references
- `Code-Conductor.agent.md` — 1 reference
- `Code-Smith.agent.md` — 3 references
- `Issue-Designer.agent.md` — 2 references

**Documentation**:

- `README.md` — ~10 references (structure diagram, skill table, VS Code version note, customization table)
- `CUSTOMIZATION.md` — 3 references
- `CONTRIBUTING.md` — skill section references

**Examples**:

- `examples/spring-boot-microservice/README.md` — 1 reference
- `examples/spring-boot-microservice/copilot-instructions.md` — 2 references

**Scripts**:

- `.github/scripts/validate-architecture.ps1` — 1 reference

**Skills README**:

- `.github/skills/README.md` — full rewrite (new path, updated skill table)

### Content Updates

Skills requiring content cherry-picks:

1. `skill-creator/SKILL.md` — update paths, add VS Code 1.108 discovery info
2. `verification-before-completion/SKILL.md` — add Iron Law, Rationalization Prevention patterns
3. `test-driven-development/SKILL.md` — rename + restructure with Iron Law of TDD

## Edge Cases

- **Archived tracking files** in `.copilot-tracking-archive/` contain historical `.claude/skills/` references — update for accuracy but low priority
- **VS Code backwards compatibility**: VS Code 1.108 still supports `.claude/skills/` but we make a clean break as the canonical template
- **`tdd-workflow` references**: Besides path changes, the skill name in agent instructions and docs changes to `test-driven-development`

## Verification Approach

No automated tests needed (documentation/config restructure). Manual verification:

1. `grep -r "\.claude/skills" .` returns zero results (excluding git history)
2. `validate-architecture.ps1` checks `.github/skills` path
3. Each SKILL.md has valid `---` frontmatter with `name` and `description`
4. VS Code skill discovery works with `chat.useAgentSkills` enabled
