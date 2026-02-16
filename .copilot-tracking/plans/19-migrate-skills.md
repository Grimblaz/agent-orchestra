---
status: ready
issue_id: "19"
created: 2026-02-16
visual_verification: false
review_loop_budget: 2
---

<!-- markdownlint-disable MD036 -->

# Plan: Migrate Skills to .github/skills/

Migrate the skills framework from `.claude/skills/` to `.github/skills/` to align with VS Code 1.108 Agent Skills standard (`chat.useAgentSkills`). Cherry-pick quality improvements from Organizations-of-Elos (Iron Law patterns, VS Code 1.108 discovery info, frontmatter validation). Add `webapp-testing` Playwright skill. Rename `tdd-workflow` → `test-driven-development`. Update all 57 references across 26 files. Design doc: `Documents/Design/issue-19-migrate-skills.md`. Key decisions: cherry-pick over wholesale sync (keeps template generic); include webapp-testing (broadly applicable); rename to test-driven-development (clearer, matches OoE).

## Steps

### Step 1 — Move skills directory and rename TDD skill

**Execution Mode: serial**

**Requirement Contract:**

- AC: All 8 skill directories + README.md moved from `.claude/skills/` to `.github/skills/` using `git mv` (preserves history). `tdd-workflow/` renamed to `test-driven-development/`. `.claude/` directory removed.
- Invariants: No content changes — pure file operations.
- Non-goals: Don't update any references yet; don't modify skill content.

**Actions:**

1. `git mv .claude/skills/ .github/skills/` — moves entire skills tree, preserving git history
2. `git mv .github/skills/tdd-workflow/ .github/skills/test-driven-development/` — rename
3. Remove empty `.claude/` directory (`Remove-Item .claude -Recurse -Force`)
4. Verify: `Test-Path .github/skills/brainstorming/SKILL.md` and other skills exist; `.claude/` does not exist

**Validation:** `git status` shows renames. `Get-ChildItem .github/skills/` lists all 8 skills + README. `Test-Path .claude` returns `$false`.

**Commit:** `feat(#19): Step 1 - Move skills from .claude/skills/ to .github/skills/`

---

### Step 2 — Update `.claude/skills` → `.github/skills` references in agent definitions

**Execution Mode: serial**

**Requirement Contract:**

- AC: All 27 `.claude/skills` references across 13 agent files updated to `.github/skills`. The 1 `tdd-workflow` reference in `Test-Writer.agent.md` also updated to `test-driven-development`.
- Invariants: Only path strings change — no behavioral/instruction changes to agents.
- Non-goals: Don't touch documentation, examples, or scripts.

**Files (13 agents, 27 path replacements + 1 name rename):**

- `.github/agents/Code-Critic.agent.md` — L280, L388, L392 (3 replacements)
- `.github/agents/Code-Conductor.agent.md` — L90 (1 replacement)
- `.github/agents/Code-Smith.agent.md` — L200, L215, L219, L224 (4 replacements)
- `.github/agents/Issue-Designer.agent.md` — L60, L61 (2 replacements)
- `.github/agents/Test-Writer.agent.md` — L121, L278, L282, L286, L291 (5 replacements; L278 also `tdd-workflow` → `test-driven-development`)
- `.github/agents/Specification.agent.md` — L161, L165 (2 replacements)
- `.github/agents/UI-Iterator.agent.md` — L124 (1 replacement)
- `.github/agents/Refactor-Specialist.agent.md` — L147, L240, L244 (3 replacements)
- `.github/agents/Research-Agent.agent.md` — L420 (1 replacement)
- `.github/agents/Process-Review.agent.md` — L554 (1 replacement)
- `.github/agents/Plan-Architect.agent.md` — L393, L397 (2 replacements)
- `.github/agents/Janitor.agent.md` — L364 (1 replacement)
- `.github/agents/Code-Review-Response.agent.md` — L413 (1 replacement)

**Validation:** `grep -r "\.claude/skills" .github/agents/` returns zero results. `grep -r "tdd-workflow" .github/agents/` returns zero results.

**Commit:** `feat(#19): Step 2 - Update skill path references in all agent definitions`

---

### Step 3 — Update references in documentation, examples, and scripts

**Execution Mode: serial**

**Requirement Contract:**

- AC: All `.claude/skills` references in `README.md`, `CUSTOMIZATION.md`, example files, and `validate-architecture.ps1` updated. README directory structure diagram updated (rename `tdd-workflow` → `test-driven-development`, add `webapp-testing`, skill count 8 → 9). VS Code version note updated from 1.107 to 1.108 with `chat.useAgentSkills` mention.
- Invariants: No content additions — only path/name corrections and VS Code version bump.
- Non-goals: Don't update skills README (done in Step 5), don't update archive files yet.

**Files and changes:**

`README.md` — 10 path updates + structural changes:

- L28: VS Code version `1.107+` → `1.108+`, `.claude/skills/` → `.github/skills/`, mention `chat.useAgentSkills`
- L53, L63, L135, L218, L242: `.claude/skills/` → `.github/skills/`
- L139: skills table — `tdd-workflow` → `test-driven-development`; add `webapp-testing` row
- L148: VS Code version `1.107+` → `1.108+`, update discovery mechanism to `chat.useAgentSkills`
- L186-188: directory structure — `.claude/skills/` → `.github/skills/`, rename `tdd-workflow/` → `test-driven-development/`, add `webapp-testing/`, update skill count (8 → 9)

`CUSTOMIZATION.md` — 3 path updates:

- L74, L85, L214: `.claude/skills/` → `.github/skills/`

`examples/spring-boot-microservice/copilot-instructions.md` — 2 updates:

- L84: `.claude/skills/tdd-workflow/` → `.github/skills/test-driven-development/`
- L122: `../../.claude/skills/tdd-workflow/SKILL.md` → `../../.github/skills/test-driven-development/SKILL.md`

`examples/spring-boot-microservice/README.md` — 1 update:

- L101: `../../.claude/skills/tdd-workflow/` → `../../.github/skills/test-driven-development/`

`.github/scripts/validate-architecture.ps1` — 1 update:

- L66: `".claude/skills"` → `".github/skills"`

**Validation:** `grep -r "\.claude/skills" README.md CUSTOMIZATION.md examples/ .github/scripts/` returns zero results. Run `.\validate-architecture.ps1` to confirm the script checks `.github/skills`.

**Commit:** `feat(#19): Step 3 - Update skill references in docs, examples, and scripts`

---

### Step 4 — Cherry-pick content improvements into 3 skills

**Execution Mode: serial**

**Requirement Contract:**

- AC: Three skills updated with cherry-picked improvements from OoE. All `[CUSTOMIZE]` markers preserved. No project-specific (npm, game design) content introduced.
- Invariants: Frontmatter `name` and `description` fields remain valid. Supporting files unchanged.
- Non-goals: Don't modify skills that don't need cherry-picks (brainstorming, software-architecture, ui-testing, systematic-debugging, frontend-design).

**4a. `.github/skills/skill-creator/SKILL.md`** — cherry-pick from OoE:

- Update directory structure example from `.claude/skills/` to `.github/skills/`
- Update VS Code discovery reference from 1.107 to 1.108 with `chat.useAgentSkills`
- Add "Minimal Skill" vs "Full Skill" pattern distinction section (small skills = just SKILL.md; large skills = SKILL.md + supporting files with router pattern)
- Add frontmatter validation table (`name`: required, kebab-case; `description`: required, include trigger conditions; other fields: not supported)

**4b. `.github/skills/verification-before-completion/SKILL.md`** — cherry-pick from OoE:

- Upgrade "Core Principle" section to "Iron Law" framing: *"Evidence > claims. Verification > assumption. Working software > 'should work.'"*
- Add "Rationalization Prevention" table after the Iron Law (maps common rationalizations like "Works on my machine" / "Just needs review" / "Simple change" to required actions)
- Add "Red Flags — STOP" section with generic stop-and-investigate patterns (keep patterns generic, not npm-specific)
- Keep all existing `[CUSTOMIZE]` markers and project-specific placeholder sections unchanged

**4c. `.github/skills/test-driven-development/SKILL.md`** (formerly `tdd-workflow`):

- Update frontmatter: `name: test-driven-development`, update `description` to include usage trigger conditions
- Add "Iron Law of TDD" principle section: *"No production code without a failing test. No refactoring without green tests."*
- Enhance quality hierarchy table to use generic `[CUSTOMIZE]` tool placeholders instead of hardcoded Java/JUnit/PIT/JaCoCo
- Add verification checklist for each TDD phase (RED: test fails for the right reason; GREEN: minimal code, no gold plating; REFACTOR: tests still green)
- Update Java/Spring Boot note to be a stack-agnostic `[CUSTOMIZE]` guidance block
- Keep all `[CUSTOMIZE]` markers for project-specific test commands section

**Validation:** Each SKILL.md has valid `---` YAML frontmatter with `name` and `description`. `grep -r "\[CUSTOMIZE\]" .github/skills/` confirms markers present in updated files. No npm/Node.js/game-specific references introduced.

**Commit:** `feat(#19): Step 4 - Cherry-pick quality improvements into skill-creator, verification, and TDD skills`

---

### Step 5 — Add webapp-testing skill and rewrite skills README

**Execution Mode: serial**

**Requirement Contract:**

- AC: New `webapp-testing/` skill created with SKILL.md, patterns.md, playwright-setup.md (genericized from OoE). Skills README.md rewritten for `.github/skills/` location with 9-skill table, updated paths, `test-driven-development` name, `webapp-testing` added.
- Invariants: webapp-testing content is generic (no OoE project-specific references). README lists all 9 skills accurately.
- Non-goals: Don't modify any other skills or agent files.

**5a. Create webapp-testing skill (3 files):**

- `.github/skills/webapp-testing/SKILL.md` — frontmatter (`name: webapp-testing`, description with usage triggers), "When to Use" section (writing E2E tests, setting up Playwright, testing user flows, visual regression), core Playwright patterns overview, routing to `patterns.md` and `playwright-setup.md`, `[CUSTOMIZE]` markers for project URLs/selectors/config
- `.github/skills/webapp-testing/patterns.md` — Page Object pattern, test isolation strategies, visual regression testing, accessibility testing patterns, custom fixture patterns, all with `[CUSTOMIZE]` markers
- `.github/skills/webapp-testing/playwright-setup.md` — installation guide, config file template with `[CUSTOMIZE]` markers, project structure, CI integration patterns, browser selection guidance

**5b. Rewrite `.github/skills/README.md`:**

- Update all paths from `.claude/skills/` to `.github/skills/`
- Update skill table to 9 skills (add `webapp-testing`, rename `tdd-workflow` → `test-driven-development`)
- Update "How to Use" example to reference `.github/skills/test-driven-development/`
- Update "Creating New Skills" section with `.github/skills/` paths
- Update VS Code discovery note to reference 1.108 and `chat.useAgentSkills`
- Update customization note

**Validation:** `Get-ChildItem .github/skills/webapp-testing/` shows 3 files. Skills README references all 9 skills. No `.claude/skills` references remain in skills README.

**Commit:** `feat(#19): Step 5 - Add webapp-testing skill and rewrite skills README`

---

### Step 6 — Update archive files and final verification

**Execution Mode: serial**

**Requirement Contract:**

- AC: Archive file references updated (4 replacements). Final grep confirms zero `.claude/skills` results across entire repo (excluding `.git/` and design doc). Zero `tdd-workflow` results (excluding `.git/` and design doc).
- Invariants: Archive content is historical — updates for accuracy only.
- Non-goals: Don't modify design document (it documents the migration decision; old-state references are intentional).

**Files:**

`.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md`:

- L68, L98, L221: `.claude/skills/` → `.github/skills/`
- L104: `tdd-workflow/` → `test-driven-development/`

**Final Verification (run all):**

1. `grep -r "\.claude/skills" . --include="*.md" --include="*.ps1" | grep -v "Design/issue-19"` — zero results
2. `grep -r "tdd-workflow" . --include="*.md" --include="*.ps1" | grep -v "Design/issue-19"` — zero results
3. Run `.\validate-architecture.ps1` — all checks pass
4. Verify all 9 SKILL.md files have valid `---` frontmatter with `name` and `description`
5. `Test-Path .claude` returns `$false`
6. `(Get-ChildItem .github/skills/ -Directory).Count -eq 9` — confirms 9 skill directories

**Commit:** `feat(#19): Step 6 - Update archive references and final verification`

---

### Step 7 — Refactor stage

**Execution Mode: serial**

**Requirement Contract:**

- AC: Review all changes for consistency. Identify and execute related refactoring (inconsistent skill reference patterns across agents, outdated VS Code version references, skill description quality). Implementers should take on larger refactors here while context is fresh.
- Invariants: All validation still passes. No new features — only quality improvements.
- Non-goals: Don't introduce new skills or change agent behavior.

**Suggested refactor targets:**

- Standardize skill reference format across all 13 agent files (some use "Load", some use "Reference", some use "see" — consider standardizing to a consistent verb)
- Check for any remaining `1.107` VS Code version references anywhere that should be `1.108`
- Verify all 9 skill `description` fields include proper usage triggers for `chat.useAgentSkills` discovery
- Clean up any stale content referencing old skill count or `.claude/` structure
- Review `CONTRIBUTING.md` skills section for accuracy with new paths

**Validation:** Full grep verification pass. `validate-architecture.ps1` passes.

**Commit:** `refactor(#19): Step 7 - Consistency and quality improvements`

---

### Step 8 — Code review (Code-Critic → Code-Review-Response reconciliation)

**Execution Mode: serial**

**Requirement Contract:**

- AC: All changes reviewed by Code-Critic. Code-Review-Response addresses findings. Reconciliation loop completes within budget.
- Loop budget: **2 rebuttal rounds** (appropriate for mixed documentation/config changes; use 1 for pure nit/wording disputes, 3 only for high-risk architectural).
- Deferral: Non-blocking improvements > 1 day marked `DEFERRED-SIGNIFICANT` with follow-up issues created automatically.

**Process:**

1. Code-Critic reviews all changes on `feature/issue-19-migrate-skills` branch against `main`
2. Code-Review-Response triages each finding: `accept` / `rebut` / `defer`
3. Up to 2 rebuttal rounds for disputed findings
4. Mandatory sign-off before PR merge
5. Test-Writer triage (if applicable): classify as `code defect` / `test defect` / `harness/env defect` — unlikely for this issue since no automated tests, but included for process compliance

---

### Step 9 — Documentation finalization (Doc-Keeper)

**Execution Mode: serial**

**Requirement Contract:**

- AC: All documentation accurately reflects the new `.github/skills/` structure. No stale references. Design document status updated.
- Non-goals: Don't change code or skill content — documentation accuracy pass only.

**Actions:**

1. Final accuracy pass on `README.md`, `CUSTOMIZATION.md`, `CONTRIBUTING.md`
2. Verify all internal markdown links resolve correctly (especially cross-references to skills)
3. Update design document: `Status: Design Complete` → `Status: Complete`
4. Ensure skill count references (9 skills) are consistent everywhere

**Commit:** `docs(#19): Step 9 - Documentation finalization`

---

### Step 10 — Post-merge cleanup and retrospective

**Execution Mode: serial**

**Requirement Contract:**

- AC: Tracking files archived per `post-pr-review.instructions.md`. Issue #19 closed with completion comment. Process retrospective completed.

**Process:**

1. Move tracking file to `.copilot-tracking/archived/`
2. Update YAML frontmatter: `status: complete`, add `completed: YYYY-MM-DD`
3. Close issue #19 with summary comment
4. Delete research file `.copilot-tracking/research/20260216-migrate-skills-research.md` (ephemeral)
5. Brief process retrospective: identify slowdowns, late-failing checks, one workflow guardrail improvement

---

## Verification

**End-to-end verification (run after Step 6 and again after final merge):**

1. `grep -r "\.claude/skills" . --include="*.md" --include="*.ps1" | grep -v "Design/issue-19"` — zero results
2. `grep -r "tdd-workflow" . --include="*.md" --include="*.ps1" | grep -v "Design/issue-19"` — zero results
3. `.\validate-architecture.ps1` — all checks pass
4. `Get-ChildItem .github/skills/ -Directory | Select-Object Name` — lists 9 skill directories
5. All 9 SKILL.md files have valid `---` YAML frontmatter with `name` and `description`
6. `Test-Path .claude` returns `$false`

## Decisions

- Cherry-pick improvements over wholesale OoE sync — keeps template generic with `[CUSTOMIZE]` markers
- Include webapp-testing — Playwright E2E testing is broadly applicable
- Rename tdd-workflow → test-driven-development — clearer, matches OoE convention
