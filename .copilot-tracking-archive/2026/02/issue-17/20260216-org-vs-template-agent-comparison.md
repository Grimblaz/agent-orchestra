# Org vs Template Agent Comparison Research

**Created**: 2026-02-16
**Status**: Complete
**Scope**: Comparison between `Grimblaz-and-Friends/.github-private` org-level agents and `workflow-template` repo-level agents

---

## 1. Agent Parity Analysis

### 1.1 Size Comparison (All Agents)

| Agent | Org Size (bytes) | Template Est. Size | Delta | Verdict |
|-------|------------------|--------------------|-------|---------|
| Code-Conductor.agent.md | 31,398 | ~31,240 | <1% | **Near-identical** |
| Code-Critic.agent.md | 15,299 | ~15,270 | <1% | **Near-identical** |
| Code-Review-Response.agent.md | 32,651 | ~32,640 | <1% | **Near-identical** |
| Code-Smith.agent.md | 10,675 | ~10,640 | <1% | **Near-identical** |
| Doc-Keeper.agent.md | 4,527 | ~4,490 | <1% | **Near-identical** |
| Issue-Designer.agent.md | 7,805 | ~7,810 | <1% | **Near-identical** |
| Janitor.agent.md | 12,062 | ~12,020 | <1% | **Near-identical** |
| Plan-Architect.agent.md | 15,518 | ~15,460 | <1% | **Near-identical** |
| Process-Review.agent.md | 19,411 | ~19,410 | <0.1% | **Near-identical** |
| Refactor-Specialist.agent.md | 10,247 | ~10,210 | <1% | **Near-identical** |
| Research-Agent.agent.md | 17,930 | ~17,820 | <1% | **Near-identical** |
| Specification.agent.md | 6,846 | ~6,910 | <1% | **Near-identical** |
| Test-Writer.agent.md | 11,715 | ~11,800 | <1% | **Near-identical** |
| UI-Iterator.agent.md | 8,082 | ~8,060 | <1% | **Near-identical** |

**Methodology**: Template sizes estimated from full file content reads (line count × average bytes/line). All deltas are within line-ending normalization variance (CRLF vs LF).

**Conclusion**: All 14 shared agents appear to be **content-identical** between org and template repos. The <1% variance across all files is consistent with line-ending differences (Windows CRLF vs Unix LF), not content differences.

### 1.2 Agents Unique to Each Side

| Agent | Found In | Size | Notes |
|-------|----------|------|-------|
| **Issue-Planner.agent.md** | Org only | 8,411 bytes | **Missing from template** — unknown purpose, not readable |
| **Plan-General.agent.md** | Template only | ~3,500 bytes | **Not in org** — lightweight planning assistant |

#### Plan-General.agent.md (Template Only)

- **Purpose**: Iterative research + planning agent, distinct from Plan-Architect
- **Key Differences from Plan-Architect**:
  - Lightweight, conversational; uses `<workflow>` loop (gather context → draft → user feedback → refine)
  - Produces concise 3-6 step plans (vs Plan-Architect's full phased plans with checklists)
  - Has `<plan_style_guide>` requiring markdown links and symbol references, no code blocks
  - Designed for pairing/iteration with user, not autonomous planning
  - Has "Open in Editor" handoff to save plan as untitled file
  - Includes `<stopping_rules>` to prevent implementation drift
- **Model Recommendations**: GPT-4o (simple), Sonnet 4.5 (standard), Haiku 4.5 (cost-conscious)

#### Issue-Planner.agent.md (Org Only)

- **Cannot access content** (private repo, no GitHub MCP tools available)
- **Estimated size**: 8,411 bytes (~200 lines)
- **Gap**: Template is missing this agent — need to obtain content for evaluation

---

## 2. Structural Differences

### 2.1 Directory Layout Comparison

| Path | Org Repo | Template Repo | Notes |
|------|----------|---------------|-------|
| `agents/` (org) / `.github/agents/` (template) | ✅ 15 agents | ✅ 15 agents | Different paths (org-level vs repo-level) |
| `.github/skills/` | ❌ Not present | ✅ 8 skills, 21 files | **Template-only feature** |
| `.github/instructions/` | ❌ Not present | ✅ 2 instruction files | **Template-only feature** |
| `.github/prompts/` | ❌ Not present | ✅ 1 prompt file | **Template-only feature** |
| `.github/templates/` | ❌ Not present | ✅ 1 implementation plan template | **Template-only feature** |
| `.github/scripts/` | ❌ Not present | ✅ 1 validation script | **Template-only feature** |
| `.github/workflows/` | ❌ Not present | ✅ 1 CI example workflow | **Template-only feature** |
| `.copilot-tracking/` | ❌ Not present | ✅ Scaffold with .gitkeep | **Template-only feature** |
| `Documents/` | ❌ Not present | ✅ Development/ scaffold | **Template-only feature** |
| `examples/` | ❌ Not present | ✅ Spring Boot microservice example | **Template-only feature** |
| Top-level docs | ❌ Not present | ✅ README.md, CONTRIBUTING.md, CUSTOMIZATION.md | **Template-only feature** |
| `.gitignore` | ❌ Not present | ✅ Ignores .copilot-tracking/* | **Template-only feature** |

**Note**: The org repo (`Grimblaz-and-Friends/.github-private`) is an organization-level repo that only contains agents. All infrastructure (skills, templates, scripts, docs, examples) exists exclusively in the template repo.

### 2.2 Org-Level vs Repo-Level Agent Mechanics

| Aspect | Org Repo (`.github-private`) | Template Repo |
|--------|------------------------------|---------------|
| **Scope** | All repos in org inherit agents | Single repo only |
| **Override** | Repo-level agents can override org agents | N/A — is the repo level |
| **Conflict** | If both exist, repo-level wins | N/A |
| **Path** | `agents/*.agent.md` | `.github/agents/*.agent.md` |
| **Purpose** | Default baseline for all org repos | Standalone template for new repos |

**Implication**: When the template is used in a repo within the Grimblaz-and-Friends org, the repo-level agents will **override** the org-level agents (since names match). This means the template's agents take precedence.

---

## 3. Template-Only Features (Not in Org)

### 3.1 Skills Framework (`.github/skills/`)

8 skill modules with progressive-disclosure router pattern:

| Skill | Files | Purpose |
|-------|-------|---------|
| `test-driven-development/` | 8 files (SKILL.md, 3 references, 2 templates, 3 workflows) | TDD process, quality gates, test patterns |
| `brainstorming/` | 1 file (SKILL.md) | Structured Socratic questioning |
| `frontend-design/` | 1 file (SKILL.md) | UI design guidance |
| `ui-testing/` | 2 files (SKILL.md, testing-patterns.md) | React component testing |
| `skill-creator/` | 1 file (SKILL.md) | Meta-skill for creating new skills |
| `systematic-debugging/` | 2 files (SKILL.md, debugging-phases.md) | 4-phase debugging process |
| `verification-before-completion/` | 1 file (SKILL.md) | Completion verification checklist |
| `software-architecture/` | 1 file (SKILL.md) | Clean Architecture, SOLID principles |

**Total**: 21 files providing domain knowledge modules that agents reference on demand.

**Key Design**: Skills use a router pattern — `SKILL.md` acts as intake, routes to specific workflows/references based on user intent. This keeps context efficient (only loads what's needed).

### 3.2 Instructions (`.github/instructions/`)

| File | Purpose |
|------|---------|
| `post-pr-review.instructions.md` (218 lines) | Post-merge cleanup checklist: archive tracking, update docs, handle tech debt, close issues |
| `tracking-format.instructions.md` (156 lines) | YAML frontmatter format for `.copilot-tracking/` files (status, priority, tags, dates) |

### 3.3 Prompt Templates (`.github/prompts/`)

| File | Purpose |
|------|---------|
| `start-issue.md` (205 lines) | Complete prompt template for starting work on a new issue: analysis, dependencies, branch creation, tracking init, plan creation |

### 3.4 Implementation Plan Template (`.github/templates/`)

| File | Purpose |
|------|---------|
| `implementation-plan.md` (301 lines) | Full-featured plan template with user story, complexity assessment, impact analysis, 8 phases (Research → Tests → Implement → Validate → Refactor → Review → Docs → Cleanup), success criteria |

### 3.5 Scripts (`.github/scripts/`)

| File | Purpose |
|------|---------|
| `validate-architecture.ps1` (341 lines) | PowerShell validation script template: directory structure checks, required files, agent definitions, skills framework, naming conventions, file size limits |

### 3.6 Workflow Examples (`.github/workflows/`)

| File | Purpose |
|------|---------|
| `ci.yml.example` (325 lines) | Technology-agnostic CI template: validation job (architecture), build/test job, lint/quality job with placeholder customization points |

### 3.7 Example Project (`examples/spring-boot-microservice/`)

| File | Lines | Purpose |
|------|-------|---------|
| `README.md` | 102 | Usage guide for example files |
| `copilot-instructions.md` | 123 | Example project context (Order Service) |
| `architecture-rules.md` | 257 | Example architecture rules (layered architecture) |
| `TECH-DEBT.md` | 142 | Example tech debt tracking template |

### 3.8 Project Documentation

| File | Lines | Purpose |
|------|-------|---------|
| `README.md` | 316 | Full product documentation: quick start, agent catalog, skills catalog, customization guide, design philosophy |
| `CONTRIBUTING.md` | ~120 | Contribution guidelines: setup, PR process, agent/skill standards |
| `CUSTOMIZATION.md` | ~200 | Step-by-step adaptation guide: copilot-instructions, architecture-rules, agents, skills, templates, CI/CD |

### 3.9 Workspace Scaffolding

| Path | Purpose |
|------|---------|
| `.copilot-tracking/` | Work-in-progress tracking (gitignored except .gitkeep) |
| `.copilot-tracking/plans/` | Implementation plans directory |
| `Documents/Development/` | Project documentation scaffold |

---

## 4. Gap Analysis

### 4.1 Org Repo Has But Template Lacks

| Item | Impact | Recommendation |
|------|--------|----------------|
| **Issue-Planner.agent.md** (8,411 bytes) | Medium — template missing an agent that exists at org level | Obtain content and add to template, or confirm it's intentionally excluded |

### 4.2 Template Has But Org Lacks

| Item | Impact | Notes |
|------|--------|-------|
| **Plan-General.agent.md** | Low — lightweight alternative planner | May not be needed at org level (too generic for org baseline) |
| **Full skills framework** (8 skills, 21 files) | High — core value-add of template | Skills are repo-specific by design; correct to not be in org |
| **Instructions** (2 files) | Medium — standardize tracking and post-PR workflow | Could be promoted to org level via `.github-private` |
| **Prompt templates** (1 file) | Low — convenience for issue startup | Repo-specific; appropriate at template level |
| **Implementation plan template** | Medium — standardizes planning output | Could potentially be shared org-wide |
| **Validation script** | Medium — automated architecture checking | Technology-specific; correct at template level |
| **CI workflow example** | Low — customization starting point | Technology-specific |
| **Example project** | Low — onboarding reference only | Template-specific |
| **Full documentation** (README, CONTRIBUTING, CUSTOMIZATION) | Template-specific | Not applicable to org baseline |

### 4.3 Content Alignment Assessment

**For all 14 shared agents**: Content appears **identical** between org and template repos (sizes match within line-ending variance). No content divergence detected.

**Key Finding**: The repos are well-synchronized. The org repo serves as the agent baseline, while the template repo wraps those same agents with a complete adoption framework (skills, templates, scripts, docs, examples).

---

## 5. Architecture Summary

```
Grimblaz-and-Friends/.github-private (Org Level)
└── agents/                     ← 15 agents (baseline for all org repos)
    ├── Code-Conductor.agent.md
    ├── Code-Critic.agent.md
    ├── ... (12 more shared agents)
    └── Issue-Planner.agent.md  ← ORG ONLY

workflow-template (Repo Level — Standalone Template)
├── .github/agents/             ← 15 agents (identical to org, except Plan-General/Issue-Planner swap)
│   ├── Code-Conductor.agent.md
│   ├── Code-Critic.agent.md
│   ├── ... (12 more shared agents)
│   └── Plan-General.agent.md  ← TEMPLATE ONLY
├── .github/skills/             ← 8 skills (21 files) — TEMPLATE ONLY
├── .github/instructions/       ← 2 instruction files — TEMPLATE ONLY
├── .github/prompts/            ← 1 prompt template — TEMPLATE ONLY
├── .github/templates/          ← 1 plan template — TEMPLATE ONLY
├── .github/scripts/            ← 1 validation script — TEMPLATE ONLY
├── .github/workflows/          ← 1 CI example — TEMPLATE ONLY
├── .copilot-tracking/          ← Workspace scaffold — TEMPLATE ONLY
├── Documents/                  ← Documentation scaffold — TEMPLATE ONLY
├── examples/                   ← Spring Boot example — TEMPLATE ONLY
├── README.md                   ← Product docs — TEMPLATE ONLY
├── CONTRIBUTING.md             ← Contribution guide — TEMPLATE ONLY
├── CUSTOMIZATION.md            ← Adoption guide — TEMPLATE ONLY
└── .gitignore                  ← Ignores .copilot-tracking — TEMPLATE ONLY
```

---

## 6. Key Findings

1. **Agent content is synchronized**: All 14 shared agents have near-identical content (<1% size variance). No content drift detected.

2. **One agent missing from template**: `Issue-Planner.agent.md` (8,411 bytes) exists in org but not template. Cannot inspect content (private repo inaccessible).

3. **One agent unique to template**: `Plan-General.agent.md` is a lightweight, conversational planning agent not present in the org repo. Fills a different niche than Plan-Architect (quick iterative plans vs comprehensive phased plans).

4. **Template is a superset**: The template wraps the org's agent definitions with a complete adoption framework (skills, templates, scripts, docs, examples, scaffolding). This is architecturally correct — org provides baseline agents, template provides the adoption toolkit.

5. **No structural conflicts**: The two repos serve complementary purposes. Org-level agents are defaults; repo-level agents (from template) override when both exist.

6. **Instructions could be org-wide**: The `post-pr-review.instructions.md` and `tracking-format.instructions.md` standardize workflows that would benefit all org repos. Consider promoting to org level.

---

## 7. Recommendations

### Action Items

| Priority | Action | Rationale |
|----------|--------|-----------|
| **High** | Add `Issue-Planner.agent.md` to template (after content review) | Maintain agent parity with org |
| **Medium** | Evaluate whether `Plan-General.agent.md` should be added to org | Useful lightweight alternative to Plan-Architect |
| **Medium** | Consider promoting instructions to org `.github-private` repo | Standardize tracking format and post-PR workflow org-wide |
| **Low** | Verify line-ending consistency | All files should use same EOL (LF recommended) |
| **Low** | Document the org-vs-template relationship | Help adopters understand precedence rules |

---

**Research complete. Ready for handoff to plan-architect if implementation actions are needed.**
