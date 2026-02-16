<!-- markdownlint-disable-file -->

# Research Notes: Migrate Skills to .github/skills/ (Issue #19)

## Research Executed

### File Analysis

- `.claude/skills/` — 8 skill directories + 1 README, 21 total files (confirmed via file_search)
- `.github/skills/` — **does not exist yet** (ENOENT)
- `.github/copilot-instructions.md` — **does not exist** in template (user-created file)
- `.claude/` directory contains only `skills/` subdirectory

### Code Search Results

- `".claude/skills"` — **57 matches** across the repo (all file paths and lines documented below)
- `"tdd-workflow"` — **19 matches** across the repo (all documented below)
- `.copilot-tracking-archive/` — 3 matches for `.claude/skills`, 1 match for `tdd-workflow`

### Project Conventions

- Standards referenced: Design document at `Documents/Design/issue-19-migrate-skills.md`
- Instructions followed: `.github/instructions/tracking-format.instructions.md`, `.github/instructions/post-pr-review.instructions.md`

---

## Key Discoveries

### 1. Current Skills Inventory

#### Complete File Tree (21 files)

```
.claude/skills/
├── README.md
├── brainstorming/
│   └── SKILL.md
├── frontend-design/
│   └── SKILL.md
├── skill-creator/
│   └── SKILL.md
├── software-architecture/
│   └── SKILL.md
├── systematic-debugging/
│   ├── SKILL.md
│   └── debugging-phases.md
├── tdd-workflow/
│   ├── SKILL.md
│   ├── references/
│   │   ├── anti-patterns.md
│   │   ├── commands.md
│   │   ├── quality-gates.md
│   │   └── test-patterns.md
│   ├── templates/
│   │   ├── describe-block.md
│   │   └── test-file.md
│   └── workflows/
│       ├── make-tests-pass.md
│       ├── refactor-safely.md
│       ├── validate-coverage.md
│       └── write-tests-first.md
├── ui-testing/
│   ├── SKILL.md
│   └── testing-patterns.md
└── verification-before-completion/
    └── SKILL.md
```

#### Skill Frontmatter Summary

| Skill | `name` | `description` |
| --- | --- | --- |
| brainstorming | `brainstorming` | Structured Socratic questioning for exploring ideas and solutions. Use when exploring new features, evaluating approaches, or need to think through complex decisions. |
| frontend-design | `frontend-design` | Guide for creating distinctive UI designs that avoid generic templates. Use when designing new UI components, screens, or evaluating designs for uniqueness and purpose. |
| skill-creator | `skill-creator` | Guide for creating new skills in this system with proper frontmatter format. Use when adding new skills, updating skill templates, or reviewing skill structure. |
| software-architecture | `software-architecture` | Clean Architecture, SOLID principles, and architectural decision guidance. Use when designing systems, evaluating architecture, making structural decisions, or reviewing for maintainability. |
| systematic-debugging | `systematic-debugging` | 4-phase debugging process (Observe, Hypothesize, Test, Fix) for complex issues. Use when debugging fails, investigating flaky tests, tracking root causes, or facing mysterious bugs. |
| tdd-workflow | `tdd-workflow` | Test-Driven Development process knowledge, quality standards, and workflow guidance |
| ui-testing | `ui-testing` | Resilient React component testing strategies focusing on user behavior. Use when writing or reviewing UI tests, fixing flaky tests, or establishing testing patterns. |
| verification-before-completion | `verification-before-completion` | Evidence-based verification checklist before marking work complete. Use before PRs, releases, marking tickets done, or any "I'm finished" declaration. |

---

### 2. Complete Reference Audit: `.claude/skills` (57 matches)

#### Agent Files (27 matches in 12 agents)

| File | Line | Content |
| --- | --- | --- |
| `.github/agents/Code-Critic.agent.md` | L280 | `- [ ] UI tests query by \`aria-label\`/behavior, NOT DOM structure (see \`.claude/skills/ui-testing/SKILL.md\`)` |
| `.github/agents/Code-Critic.agent.md` | L388 | `- Load \`.claude/skills/software-architecture/SKILL.md\` for project architecture rules and SOLID principles` |
| `.github/agents/Code-Critic.agent.md` | L392 | `- Load \`.claude/skills/verification-before-completion/SKILL.md\` for evidence-based verification` |
| `.github/agents/Code-Conductor.agent.md` | L90 | `4. **Check Skills**: Skills in \`.claude/skills/\` may provide relevant guidance for specialists` |
| `.github/agents/Issue-Designer.agent.md` | L60 | `- **Domain rules and terminology**: load the project-relevant skill from \`.claude/skills/\` when available` |
| `.github/agents/Issue-Designer.agent.md` | L61 | `- **Design trade-offs**: \`.claude/skills/brainstorming/SKILL.md\`` |
| `.github/agents/UI-Iterator.agent.md` | L124 | `- Load \`.claude/skills/frontend-design/SKILL.md\` for distinctive UI guidelines` |
| `.github/agents/Test-Writer.agent.md` | L121 | `- **ALWAYS load \`.claude/skills/ui-testing/SKILL.md\` before writing UI tests**` |
| `.github/agents/Test-Writer.agent.md` | L278 | `- Load \`.claude/skills/tdd-workflow/SKILL.md\` for red-green-refactor process` |
| `.github/agents/Test-Writer.agent.md` | L282 | `- Load \`.claude/skills/ui-testing/SKILL.md\` for Testing Library patterns and query strategies` |
| `.github/agents/Test-Writer.agent.md` | L286 | `- Load \`.claude/skills/systematic-debugging/SKILL.md\` before attempting fixes` |
| `.github/agents/Test-Writer.agent.md` | L291 | `- Reference \`.claude/skills/verification-before-completion/SKILL.md\`` |
| `.github/agents/Specification.agent.md` | L161 | `- Load project-relevant domain skills from \`.claude/skills/\` when available` |
| `.github/agents/Specification.agent.md` | L165 | `- Load \`.claude/skills/software-architecture/SKILL.md\` and follow \`.github/architecture-rules.md\` for architecture and layer placement` |
| `.github/agents/Research-Agent.agent.md` | L420 | `- Load \`.claude/skills/brainstorming/SKILL.md\` for structured Socratic questioning` |
| `.github/agents/Refactor-Specialist.agent.md` | L147 | `**🔧 Before any extraction/split**: Load \`.claude/skills/software-architecture/SKILL.md\` and apply full architecture review:` |
| `.github/agents/Refactor-Specialist.agent.md` | L240 | `- Load \`.claude/skills/software-architecture/SKILL.md\` for Clean Architecture guidance` |
| `.github/agents/Refactor-Specialist.agent.md` | L244 | `- Load \`.claude/skills/systematic-debugging/SKILL.md\` for root cause investigation` |
| `.github/agents/Process-Review.agent.md` | L554 | `- Reference \`.claude/skills/verification-before-completion/SKILL.md\` for evidence-based checks` |
| `.github/agents/Plan-Architect.agent.md` | L393 | `- Load \`.claude/skills/brainstorming/SKILL.md\` for structured Socratic questioning` |
| `.github/agents/Plan-Architect.agent.md` | L397 | `- Load \`.claude/skills/software-architecture/SKILL.md\` for Clean Architecture guidance` |
| `.github/agents/Janitor.agent.md` | L364 | `- Reference \`.claude/skills/verification-before-completion/SKILL.md\` for evidence-based verification` |
| `.github/agents/Code-Smith.agent.md` | L200 | `**🔧 When extracting code**: Load \`.claude/skills/software-architecture/SKILL.md\` and apply full architecture review` |
| `.github/agents/Code-Smith.agent.md` | L215 | `- Load \`.claude/skills/software-architecture/SKILL.md\` for Clean Architecture and layer rules` |
| `.github/agents/Code-Smith.agent.md` | L219 | `- Load \`.claude/skills/systematic-debugging/SKILL.md\` for structured 4-phase debugging` |
| `.github/agents/Code-Smith.agent.md` | L224 | `- Reference \`.claude/skills/frontend-design/SKILL.md\` for aesthetic guidance` |
| `.github/agents/Code-Review-Response.agent.md` | L413 | `- Reference \`.claude/skills/systematic-debugging/SKILL.md\` approach` |

#### Documentation Files (18 matches)

| File | Line | Content |
| --- | --- | --- |
| `README.md` | L28 | `> **Requirements**: VS Code 1.107+ recommended for automatic skill discovery from \`.claude/skills/\`.` |
| `README.md` | L53 | `\| Medium \| \`.claude/skills/\` \| Add domain-specific skills \| Recommended \|` |
| `README.md` | L63 | `- [ ] Optionally add project-specific skills to \`.claude/skills/\`` |
| `README.md` | L135 | `Reusable skill definitions in \`.claude/skills/\`:` |
| `README.md` | L148 | `> **VS Code 1.107+**: Skills are auto-discovered from \`.claude/skills/\` via the \`description\` frontmatter field.` |
| `README.md` | L186 | `.claude/skills/          # Reusable skill definitions (8 skills)` |
| `README.md` | L218 | `Skills are domain-specific knowledge packages in \`.claude/skills/\`. They provide:` |
| `README.md` | L242 | `\| \`.claude/skills/your-domain/\` \| Domain-specific patterns, examples, best practices \| As needed \|` |
| `CUSTOMIZATION.md` | L74 | `Create skills in \`.claude/skills/\` for domain-specific knowledge.` |
| `CUSTOMIZATION.md` | L85 | `.claude/skills/` |
| `CUSTOMIZATION.md` | L214 | `- Check skill is in the \`.claude/skills/\` directory` |

#### Skills README (6 matches)

| File | Line | Content |
| --- | --- | --- |
| `.claude/skills/README.md` | L41 | `1. **Load the router**: Read \`.claude/skills/{skill-name}/SKILL.md\`` |
| `.claude/skills/README.md` | L50 | `1. Read .claude/skills/tdd-workflow/SKILL.md` |
| `.claude/skills/README.md` | L52 | `3. Read .claude/skills/tdd-workflow/workflows/write-tests-first.md` |
| `.claude/skills/README.md` | L91 | `1. Create directory: \`.claude/skills/{your-skill-name}/\`` |

#### Skill Content Files (1 match)

| File | Line | Content |
| --- | --- | --- |
| `.claude/skills/skill-creator/SKILL.md` | L34 | `.claude/skills/` (in directory structure example) |

#### Example Files (3 matches)

| File | Line | Content |
| --- | --- | --- |
| `examples/spring-boot-microservice/copilot-instructions.md` | L84 | `- Follow TDD workflow from \`.claude/skills/tdd-workflow/\`` |
| `examples/spring-boot-microservice/copilot-instructions.md` | L122 | `- [TDD Workflow](../../.claude/skills/tdd-workflow/SKILL.md)` |
| `examples/spring-boot-microservice/README.md` | L101 | `- [TDD Workflow Skill](../../.claude/skills/tdd-workflow/)` |

#### Scripts (1 match)

| File | Line | Content |
| --- | --- | --- |
| `.github/scripts/validate-architecture.ps1` | L66 | `".claude/skills"` |

#### Archive Files (3 matches)

| File | Line | Content |
| --- | --- | --- |
| `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` | L68 | `\| \`.claude/skills/\` \| ❌ Not present \| ✅ 8 skills, 21 files \| **Template-only feature** \|` |
| `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` | L98 | `### 3.1 Skills Framework (\`.claude/skills/\`)` |
| `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` | L221 | `├── .claude/skills/             ← 8 skills (21 files) — TEMPLATE ONLY` |

#### Design Document (7 matches — not counted in update scope, informational only)

| File | Line | Content |
| --- | --- | --- |
| `Documents/Design/issue-19-migrate-skills.md` | L9 | Summary paragraph |
| `Documents/Design/issue-19-migrate-skills.md` | L15 | Background paragraph |
| `Documents/Design/issue-19-migrate-skills.md` | L56 | File move table |
| `Documents/Design/issue-19-migrate-skills.md` | L65 | Reference update heading |
| `Documents/Design/issue-19-migrate-skills.md` | L103 | Edge cases section |
| `Documents/Design/issue-19-migrate-skills.md` | L104 | VS Code compatibility note |
| `Documents/Design/issue-19-migrate-skills.md` | L111 | Verification grep command |

---

### 3. Complete Reference Audit: `tdd-workflow` (19 matches)

| File | Line | Content |
| --- | --- | --- |
| `README.md` | L139 | `\| **tdd-workflow** \| TDD process knowledge and workflow guidance \|` |
| `README.md` | L188 | `├── tdd-workflow/        # Test-Driven Development` |
| `.github/agents/Test-Writer.agent.md` | L278 | `- Load \`.claude/skills/tdd-workflow/SKILL.md\` for red-green-refactor process` |
| `.claude/skills/tdd-workflow/SKILL.md` | L2 | `name: tdd-workflow` |
| `.claude/skills/README.md` | L30 | `\| \`tdd-workflow\` \| TDD process knowledge…` |
| `.claude/skills/README.md` | L46 | `### Example: Using tdd-workflow` |
| `.claude/skills/README.md` | L50 | `1. Read .claude/skills/tdd-workflow/SKILL.md` |
| `.claude/skills/README.md` | L52 | `3. Read .claude/skills/tdd-workflow/workflows/write-tests-first.md` |
| `.claude/skills/README.md` | L96 | `See \`skill-creator/SKILL.md\` for detailed guidance and \`tdd-workflow/\` for a complete example.` |
| `.claude/skills/README.md` | L100 | `> **Note**: Skills like \`tdd-workflow\` and \`ui-testing\` use specific technology examples` |
| `examples/spring-boot-microservice/README.md` | L101 | `- [TDD Workflow Skill](../../.claude/skills/tdd-workflow/)` |
| `examples/spring-boot-microservice/copilot-instructions.md` | L84 | `- Follow TDD workflow from \`.claude/skills/tdd-workflow/\`` |
| `examples/spring-boot-microservice/copilot-instructions.md` | L122 | `- [TDD Workflow](../../.claude/skills/tdd-workflow/SKILL.md)` |
| `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` | L104 | `\| \`tdd-workflow/\` \| 8 files…` |
| `Documents/Design/issue-19-migrate-skills.md` | L31, L44, L46, L57, L105 | Design document references (informational) |

---

### 4. Agent Definitions — Detailed Skill Reference Sections

#### Code-Critic.agent.md (3 references)

- **L280**: `see .claude/skills/ui-testing/SKILL.md` (Pattern Perspective checklist)
- **L388**: `Load .claude/skills/software-architecture/SKILL.md` (Skills Reference section)
- **L392**: `Load .claude/skills/verification-before-completion/SKILL.md` (Skills Reference section)

#### Code-Conductor.agent.md (1 reference)

- **L90**: `Skills in .claude/skills/ may provide relevant guidance` (Core Workflow section)

#### Code-Smith.agent.md (4 references)

- **L200**: `Load .claude/skills/software-architecture/SKILL.md` (inline extraction tip)
- **L215**: `Load .claude/skills/software-architecture/SKILL.md` (Skills Reference section)
- **L219**: `Load .claude/skills/systematic-debugging/SKILL.md` (Skills Reference section)
- **L224**: `Reference .claude/skills/frontend-design/SKILL.md` (Skills Reference section)

#### Issue-Designer.agent.md (2 references)

- **L60**: `load the project-relevant skill from .claude/skills/` (Load Skills First section)
- **L61**: `.claude/skills/brainstorming/SKILL.md` (Load Skills First section)

#### Test-Writer.agent.md (5 references)

- **L121**: `ALWAYS load .claude/skills/ui-testing/SKILL.md` (UI Component Tests section)
- **L278**: `Load .claude/skills/tdd-workflow/SKILL.md` (Skills Reference — TDD) ← also a `tdd-workflow` rename target
- **L282**: `Load .claude/skills/ui-testing/SKILL.md` (Skills Reference — UI)
- **L286**: `Load .claude/skills/systematic-debugging/SKILL.md` (Skills Reference — Debugging)
- **L291**: `Reference .claude/skills/verification-before-completion/SKILL.md` (Skills Reference — Verification)

#### Specification.agent.md (2 references)

- **L161**: `Load project-relevant domain skills from .claude/skills/` (Skills Reference)
- **L165**: `Load .claude/skills/software-architecture/SKILL.md` (Skills Reference)

#### UI-Iterator.agent.md (1 reference)

- **L124**: `Load .claude/skills/frontend-design/SKILL.md` (Skills Reference)

#### Refactor-Specialist.agent.md (3 references)

- **L147**: `Load .claude/skills/software-architecture/SKILL.md` (Before extraction/split)
- **L240**: `Load .claude/skills/software-architecture/SKILL.md` (Skills Reference)
- **L244**: `Load .claude/skills/systematic-debugging/SKILL.md` (Skills Reference)

#### Research-Agent.agent.md (1 reference)

- **L420**: `Load .claude/skills/brainstorming/SKILL.md` (Skills Reference)

#### Process-Review.agent.md (1 reference)

- **L554**: `Reference .claude/skills/verification-before-completion/SKILL.md` (Skills Reference)

#### Plan-Architect.agent.md (2 references)

- **L393**: `Load .claude/skills/brainstorming/SKILL.md` (Skills Reference)
- **L397**: `Load .claude/skills/software-architecture/SKILL.md` (Skills Reference)

#### Janitor.agent.md (1 reference)

- **L364**: `Reference .claude/skills/verification-before-completion/SKILL.md` (Skills Reference)

#### Code-Review-Response.agent.md (1 reference)

- **L413**: `Reference .claude/skills/systematic-debugging/SKILL.md` (Skills Reference)

---

### 5. Documentation Files — Detailed Reference Lines

#### README.md (10 references)

| Line | Context | Update needed |
| --- | --- | --- |
| L28 | VS Code version note: `VS Code 1.107+` + `.claude/skills/` | Update to `1.108+` and `.github/skills/` |
| L53 | Customization table: `.claude/skills/` | → `.github/skills/` |
| L63 | Quick setup checklist: `.claude/skills/` | → `.github/skills/` |
| L135 | Skills section intro: `in .claude/skills/` | → `in .github/skills/` |
| L139 | Skills table: `tdd-workflow` row | → `test-driven-development` |
| L148 | VS Code note: `VS Code 1.107+` + `.claude/skills/` | Update to `1.108+` and `.github/skills/` with `chat.useAgentSkills` |
| L186 | Directory structure: `.claude/skills/` tree | → `.github/skills/` tree, rename tdd-workflow, add webapp-testing |
| L188 | Directory structure: `tdd-workflow/` line | → `test-driven-development/` |
| L218 | Key Concepts: `in .claude/skills/` | → `in .github/skills/` |
| L242 | Customization table: `.claude/skills/your-domain/` | → `.github/skills/your-domain/` |

#### CUSTOMIZATION.md (3 references)

| Line | Context | Update needed |
| --- | --- | --- |
| L74 | `Create skills in .claude/skills/` | → `.github/skills/` |
| L85 | Directory structure: `.claude/skills/` | → `.github/skills/` |
| L214 | Troubleshooting: `Check skill is in the .claude/skills/ directory` | → `.github/skills/` |

#### CONTRIBUTING.md (0 direct `.claude/skills` references)

- L68: `### Skills` section header — no path references, just generic guidance about adding skills
- No updates needed for path migration

#### .claude/skills/README.md (moves to .github/skills/README.md — full rewrite)

- L30, L41, L46, L50, L52, L91, L96, L100: all `.claude/skills/` and `tdd-workflow` references

---

### 6. Example Files

#### examples/spring-boot-microservice/copilot-instructions.md

| Line | Content | Update needed |
| --- | --- | --- |
| L84 | `- Follow TDD workflow from .claude/skills/tdd-workflow/` | → `.github/skills/test-driven-development/` |
| L122 | `- [TDD Workflow](../../.claude/skills/tdd-workflow/SKILL.md)` | → `../../.github/skills/test-driven-development/SKILL.md` |

#### examples/spring-boot-microservice/README.md

| Line | Content | Update needed |
| --- | --- | --- |
| L101 | `- [TDD Workflow Skill](../../.claude/skills/tdd-workflow/)` | → `../../.github/skills/test-driven-development/` |

---

### 7. Scripts

#### .github/scripts/validate-architecture.ps1

| Line | Content | Update needed |
| --- | --- | --- |
| L66 | `".claude/skills"` in `$RequiredDirectories` array | → `".github/skills"` |

---

### 8. Archive Files

| File | Line | Content |
| --- | --- | --- |
| `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` | L68 | `.claude/skills/` in comparison table |
| `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` | L98 | `### 3.1 Skills Framework (.claude/skills/)` heading |
| `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` | L104 | `tdd-workflow/` in skill listing table |
| `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` | L221 | `.claude/skills/` in directory tree |

---

### 9. Skills Content Analysis (Cherry-Pick Targets)

#### skill-creator/SKILL.md (170 lines)

**Path references to update**:
- L34: `.claude/skills/` in directory structure example

**Content cherry-pick targets from OoE** (per design doc):
- Update paths from `.claude/skills/` to `.github/skills/`
- Add VS Code 1.108 `chat.useAgentSkills` discovery info
- Add "Minimal vs Full Skill" pattern
- Add frontmatter validation table

#### verification-before-completion/SKILL.md (156 lines)

**No internal path references** — no `.claude/skills` strings in this file.

**Content cherry-pick targets from OoE** (per design doc):
- Add "Iron Law" framing (e.g., "Evidence before claims")
- Add "Rationalization Prevention" table
- Add "Red Flags - STOP" patterns (genericized, not npm-specific)

#### tdd-workflow/SKILL.md (110 lines) → renamed to test-driven-development

**Path references to update**:
- L2: `name: tdd-workflow` → `name: test-driven-development`

**Content cherry-pick targets from OoE** (per design doc):
- Add "Iron Law of TDD" framing
- Add quality hierarchy table improvements
- Add verification checklist
- Add anti-pattern references
- Keep `[CUSTOMIZE]` command markers

---

### 10. Target Directory State

- `.github/skills/` — **does not exist**. Must be created.
- `.github/copilot-instructions.md` — **does not exist** (user-created file, not part of template). No updates needed.

---

## Implementation Summary

### Files to Create/Move

| Action | Source | Destination | Notes |
| --- | --- | --- | --- |
| Move dir | `.claude/skills/brainstorming/` | `.github/skills/brainstorming/` | Path refs only |
| Move dir | `.claude/skills/frontend-design/` | `.github/skills/frontend-design/` | Path refs only |
| Move dir | `.claude/skills/skill-creator/` | `.github/skills/skill-creator/` | Content cherry-pick |
| Move dir | `.claude/skills/software-architecture/` | `.github/skills/software-architecture/` | Path refs only |
| Move dir | `.claude/skills/systematic-debugging/` | `.github/skills/systematic-debugging/` | Path refs only |
| Move dir | `.claude/skills/tdd-workflow/` | `.github/skills/test-driven-development/` | Rename + content cherry-pick |
| Move dir | `.claude/skills/ui-testing/` | `.github/skills/ui-testing/` | Path refs only |
| Move dir | `.claude/skills/verification-before-completion/` | `.github/skills/verification-before-completion/` | Content cherry-pick |
| Move file | `.claude/skills/README.md` | `.github/skills/README.md` | Full rewrite |
| Create | N/A | `.github/skills/webapp-testing/SKILL.md` | New skill from OoE |
| Create | N/A | `.github/skills/webapp-testing/patterns.md` | New skill from OoE |
| Create | N/A | `.github/skills/webapp-testing/playwright-setup.md` | New skill from OoE |
| Delete | `.claude/` directory | N/A | After all moves complete |

### Files Requiring Reference Updates (by category)

**Agent definitions (12 agents, 27 replacements)**:
1. `Code-Critic.agent.md` — 3 replacements (L280, L388, L392)
2. `Code-Conductor.agent.md` — 1 replacement (L90)
3. `Code-Smith.agent.md` — 4 replacements (L200, L215, L219, L224)
4. `Issue-Designer.agent.md` — 2 replacements (L60, L61)
5. `Test-Writer.agent.md` — 5 replacements (L121, L278, L282, L286, L291) — L278 also needs `tdd-workflow` → `test-driven-development`
6. `Specification.agent.md` — 2 replacements (L161, L165)
7. `UI-Iterator.agent.md` — 1 replacement (L124)
8. `Refactor-Specialist.agent.md` — 3 replacements (L147, L240, L244)
9. `Research-Agent.agent.md` — 1 replacement (L420)
10. `Process-Review.agent.md` — 1 replacement (L554)
11. `Plan-Architect.agent.md` — 2 replacements (L393, L397)
12. `Janitor.agent.md` — 1 replacement (L364)
13. `Code-Review-Response.agent.md` — 1 replacement (L413)

**Documentation (3 files, ~14 replacements)**:
1. `README.md` — 10 replacements (L28, L53, L63, L135, L139, L148, L186-188, L218, L242) + VS Code version bump + tdd-workflow rename + webapp-testing addition to skill table/tree + skill count update (8→9)
2. `CUSTOMIZATION.md` — 3 replacements (L74, L85, L214)
3. `CONTRIBUTING.md` — 0 replacements needed

**Example files (2 files, 3 replacements)**:
1. `examples/spring-boot-microservice/copilot-instructions.md` — 2 replacements (L84, L122)
2. `examples/spring-boot-microservice/README.md` — 1 replacement (L101)

**Scripts (1 file, 1 replacement)**:
1. `.github/scripts/validate-architecture.ps1` — 1 replacement (L66)

**Skills README (1 file, full rewrite)**:
1. `.github/skills/README.md` — rewrite with `.github/skills/` paths, updated skill table (9 skills), `test-driven-development` name, `webapp-testing` added

**Archive files (1 file, 4 updates — low priority)**:
1. `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md` — L68, L98, L104, L221

### Total Update Counts

| Category | Files | Individual replacements |
| --- | --- | --- |
| Agent definitions | 13 | 27 |
| Documentation | 2 | 13 |
| Examples | 2 | 3 |
| Scripts | 1 | 1 |
| Skills README | 1 | Full rewrite |
| Skills content (cherry-pick) | 3 | Content additions |
| New files (webapp-testing) | 3 | New content |
| Archive (low priority) | 1 | 4 |
| **Total** | **~26 files** | **~48+ individual edits** |

---

## Recommended Approach

Per design document `Documents/Design/issue-19-migrate-skills.md`:

1. **Move files first** — git mv `.claude/skills/*` → `.github/skills/*` (preserves git history)
2. **Rename** — `.github/skills/tdd-workflow/` → `.github/skills/test-driven-development/`
3. **Update all references** — systematic find-replace across all 26 files
4. **Cherry-pick content** — update 3 skills with OoE improvements
5. **Create webapp-testing** — new skill with 3 files
6. **Rewrite skills README** — updated paths, skill count, new skill
7. **Delete `.claude/`** — clean removal after verification
8. **Verify** — `grep -r "\.claude/skills" .` returns zero results

## Implementation Guidance

- **Objectives**: Migrate skills to `.github/skills/`, align with VS Code 1.108 standard, cherry-pick OoE improvements, add webapp-testing skill, rename tdd-workflow
- **Key Tasks**: File moves (git mv), 48+ reference updates across 26 files, 3 content cherry-picks, 3 new files, 1 full rewrite, 1 directory deletion
- **Dependencies**: OoE upstream content needed for cherry-picks (skill-creator, verification-before-completion, test-driven-development) and webapp-testing skill content
- **Success Criteria**: Zero `grep -r "\.claude/skills" .` results, validate-architecture.ps1 passes with `.github/skills`, all SKILL.md have valid frontmatter, VS Code skill discovery works with `chat.useAgentSkills`
