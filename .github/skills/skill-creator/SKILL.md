---
name: skill-creator
description: Guide for creating new skills in this system with proper frontmatter format. Use when adding new skills, updating skill templates, or reviewing skill structure. DO NOT USE FOR: general agent or instruction file customization (use agent-customization skill) or modifying existing skill logic/content.
---

# Skill Creator

Guide for creating new skills with proper structure and VS Code 1.108+ compatible frontmatter.

## When to Use

- Creating a new skill for the project
- Reviewing existing skills for compliance
- Updating skill templates
- Onboarding contributors to skill creation

## Built-in Creation Commands (VS Code 1.110+)

> If you are on VS Code 1.108 or 1.109, skip this section and proceed directly to [Required Frontmatter Format](#required-frontmatter-format) below.

VS Code 1.110 ships built-in slash commands for scaffolding customization files:

- `/create-skill` — generates a new skill file
- `/create-agent` — generates a new `.agent.md` file
- `/create-prompt` — generates a new `.prompt.md` file
- `/create-instruction` — generates a new `.instructions.md` file

**Recommended workflow**: Use the built-in `/create-skill` (or equivalent) to generate the initial scaffold, then apply this skill to validate and refine the output against project conventions:

- Kebab-case `name` in frontmatter (e.g., `my-skill`, not `MySkill`)
- `description` must include usage triggers ("Use when ..." phrasing) for discoverability
- Directory structure: `.github/skills/{skill-name}/SKILL.md`
- Required frontmatter fields: `name` and `description` only — no unsupported fields

## Required Frontmatter Format

```markdown
---
name: skill-name-kebab-case
description: What the skill does AND when to use it. This description triggers skill discovery in chat.
---
```

**Important**:

- `name` and `description` are the only supported frontmatter fields
- No `allowed-tools` or other fields—they will be ignored
- Description should include usage triggers for discoverability

## Directory Structure

```
.github/skills/
└── {skill-name}/
    ├── SKILL.md          # Required: Main skill file with frontmatter
    ├── reference.md      # Optional: Detailed reference material
    ├── templates.md      # Optional: Code/document templates
    └── examples/         # Optional: Example files
        └── ...
```

## Discovery in VS Code (1.108+)

- Skill discovery in chat is available in VS Code 1.108+
- Ensure agent skills are enabled via `chat.useAgentSkills`
- Discovery quality depends on clear trigger phrasing in `description` (for example: "Use when ...")

## Minimal vs Full Skill Pattern

Use the smallest structure that solves the need:

- **Minimal Skill**: Single `SKILL.md` with frontmatter, "When to Use," and concise process/checklist
- **Full Skill**: `SKILL.md` plus supporting references/templates/examples when topic depth or reuse requires it

Start minimal, then split into supporting files only when the core document becomes hard to navigate.

## Skill Template

```markdown
---
name: {skill-name}
description: {What it does}. Use when {trigger conditions}. DO NOT USE FOR: {scenarios where adjacent skills are better} (use {other-skill}).
---

# {Skill Title}

Brief overview of the skill's purpose.

## When to Use

- Bullet list of situations
- That trigger this skill
- Be specific for discoverability

## Core Content

Main guidance, principles, or process.

### Subsections as Needed

Organize by user goals, not by internal structure.

## Project-Specific Configuration

[CUSTOMIZE] Add project-specific details:

- Configuration files to modify
- Team conventions to follow
- Tools and paths used

## Quick Reference

| Item        | Description       |
| ----------- | ----------------- |
| Key concept | Brief explanation |

## See Also

- [Related supporting file](./related-file.md)
- External reference links
```

## Description Quality Checklist

Before finalizing a skill's `description:` field, verify:

1. **Length target**: ≤60 words total (positive triggers + negative signals combined)
2. **Positive triggers**: includes "Use when..." with 2–3 specific, distinct scenarios — not generic summary language
3. **Negative signals**: includes "DO NOT USE FOR:..." with at least one adjacent skill pointer, e.g. `(use {other-skill})`
4. **Collision check**: before finalizing, grep existing SKILL.md files for overlapping trigger words and add explicit "DO NOT USE FOR" signals to **both** sides of any conflict:
   ```powershell
   Select-String -Path ".github/skills/*/SKILL.md" -Pattern "your-trigger-word" | Select-Object Path, Line
   ```

## Writing Guidelines

### Description Field (Critical for Discovery)

The description determines when the skill appears in suggestions.

**Good descriptions**:

```yaml
description: 4-phase debugging process for complex issues. Use when debugging failures, investigating flaky tests, or tracking root causes. DO NOT USE FOR: writing new tests (use test-driven-development), React component test patterns (use ui-testing), or E2E test setup (use webapp-testing).

description: Resilient React component testing strategies focusing on user behavior. Use when writing or reviewing component-level React tests, fixing flaky tests, or establishing React testing patterns. DO NOT USE FOR: Playwright E2E tests (use webapp-testing), canvas game interaction (use browser-canvas-testing), TDD workflow (use test-driven-development), or debugging failures (use systematic-debugging).
```

**Bad descriptions**:

```yaml
description: Debugging guide.  # Too vague, poor discoverability

description: This skill helps with testing things.  # Unclear scope
```

### Frontmatter Validation

| Field         | Required | Rule                                  | Validation Guidance                                                               |
| ------------- | -------- | ------------------------------------- | --------------------------------------------------------------------------------- |
| `name`        | Yes      | kebab-case                            | Use lowercase words separated by hyphens (for example: `test-driven-development`) |
| `description` | Yes      | Include what it does + usage triggers + negative signals | Include "Use when ..." for positive triggers and "DO NOT USE FOR: ... (use {skill})" for at least one negative signal |
| Other fields  | No       | Unsupported                           | Do not add extra fields (for example `allowed-tools`) because they are ignored    |

### Content Principles

1. **Be actionable**: Provide steps, not just concepts
2. **Use `[CUSTOMIZE]` markers**: For project-specific placeholders
3. **Keep SKILL.md concise**: Route to supporting files for details
4. **Template-generic language**: No repo-specific references
5. **Include "When to Use"**: Explicit trigger conditions

### Customization Markers

Use `[CUSTOMIZE]` for sections that need project adaptation:

```markdown
## Project Configuration

[CUSTOMIZE] Add your project's specific:

- File paths and locations
- Naming conventions
- Team-specific practices
```

## Skill Sizing Guidelines

| Size   | SKILL.md Lines | Supporting Files | Use Case                    |
| ------ | -------------- | ---------------- | --------------------------- |
| Small  | 50-100         | 0                | Simple process or checklist |
| Medium | 100-200        | 0-1              | Standard methodology        |
| Large  | 150-250        | 1-3              | Complex topic with patterns |

**Rule**: If SKILL.md exceeds 300 lines, split into supporting files.

## Validation Checklist

Before committing a new skill:

- [ ] Frontmatter has only `name` and `description`
- [ ] `name` is kebab-case
- [ ] `description` includes usage triggers
- [ ] "When to Use" section is present
- [ ] `[CUSTOMIZE]` markers for project-specific content
- [ ] No hardcoded paths or repo-specific references
- [ ] Supporting files are referenced from SKILL.md
- [ ] Content is actionable, not just conceptual

## Example: Complete Skill

```markdown
---
name: code-review
description: Structured code review process with security and maintainability focus. Use when reviewing PRs, conducting code audits, or establishing review standards. DO NOT USE FOR: line-by-line debugging assistance (use systematic-debugging) or writing test cases from scratch (use test-driven-development).
---

# Code Review Skill

Systematic approach to reviewing code changes.

## When to Use

- Reviewing pull requests
- Conducting security audits
- Establishing team review standards
- Self-review before submitting PRs

## Review Process

### 1. Understand Context

- Read PR description and linked issues
- Understand the goal before reading code

### 2. High-Level Review

- Does the approach make sense?
- Are there architectural concerns?

### 3. Detailed Review

- Security: Input validation, auth, data exposure
- Correctness: Edge cases, error handling
- Maintainability: Readability, naming, complexity

### 4. Provide Feedback

- Be specific and actionable
- Suggest alternatives, don't just criticize
- Distinguish blocking vs. non-blocking

## Project Standards

[CUSTOMIZE] Add your team's review requirements:

- Required reviewers by area
- Review checklist items
- Auto-merge criteria
```
