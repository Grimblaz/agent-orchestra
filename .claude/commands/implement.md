# Implement Plan

Execute an approved implementation plan for the current issue.

## Usage

`/project:implement`

Run this after `/project:start-issue` has created a plan and the user has approved it.

## Locate the Plan

Check these sources in order:
1. GitHub issue comments with a `<!-- plan-issue-{ID} -->` marker
2. A `.copilot-tracking/plan-issue-*.md` file on the current branch
3. If no plan is found, ask the user for the plan location

## Execution Workflow

For each step in the plan:

### 1. Implement

- Read `.github/agents/Code-Smith.agent.md` for implementation standards
- Write minimal code to satisfy requirements (YAGNI)
- Follow TDD when the plan specifies it: write failing test first, then implement
- Search for existing implementations before creating new code — inject, don't duplicate
- If a test appears buggy or tests implementation details: STOP, report the problem, do not try to work around it

### 2. Test

- Read `.github/agents/Test-Writer.agent.md` for testing standards
- Tests describe WHAT the system does, not HOW
- Use Arrange-Act-Assert pattern
- Prefer integration tests over unit tests for complex interactions
- Use `it.each` / parameterized tests for data-driven scenarios
- No `as any` casts in tests

### 3. Validate

Run all validation checks together and report all failures before fixing:
- Quick-validate commands (see `.github/copilot-instructions.md`), lint/typecheck, and the full test suite — run as a combined pass
- Fix all failures, then re-run to confirm
- _(For projects with slow test suites, see `.github/copilot-instructions.md` for the targeted→full split override.)_

### 4. Refactor

After implementation is complete, read `.github/agents/Refactor-Specialist.agent.md` and review all modified files for:
- Extraction opportunities
- DRY violations
- SOLID violations
- Cross-file duplication

### 5. Self-Review

Run `/project:review` or apply the 7 review perspectives from `.github/agents/Code-Critic.agent.md`:
1. Architecture (+ integration wiring + data integration verification)
2. Security
3. Performance
4. Patterns
5. Simplicity
6. Script & automation files (if applicable)
7. Documentation script audit (if applicable)

Address any findings before proceeding.

### 5a. CE Gate (if applicable)

If the plan includes `ce_gate: true` in its frontmatter or a `[CE GATE]` step:
- Identify the customer surface from the plan (Web UI, REST/GraphQL, CLI, SDK, Batch)
- Exercise each scenario described in the `[CE GATE]` step and verify expected behavior
- Evaluate intent match using Code-Critic's CE prosecution perspectives (`"Use CE review perspectives"` — Functional, Intent, Error States) as a self-review checklist against the scenario results. Does the implementation achieve the design intent captured in the plan's `[CE GATE]` step `Design Intent` field (falling back to the issue body only if that field is missing)? Rate as `strong` / `partial` / `weak` and emit the appropriate marker (`✅ CE Gate passed — intent match: {strong|partial|weak}`); if a defect was found and fixed within the loop budget, emit `✅ CE Gate passed after fix — intent match: {strong|partial|weak}` instead. Note: in the multi-agent Copilot workflow, Code-Conductor invokes Code-Critic as a separate agent for this step; the CE perspectives checklist above is the single-agent equivalent.
- Present results to the user and wait for approval before proceeding
- If a defect is found, fix it and re-run the scenario — apply the CE perspectives checklist again (max 2 cycles)

### 6. Document

Read `.github/agents/Doc-Keeper.agent.md` for documentation standards:
- Update `Documents/Design/{domain-slug}.md` if design decisions were made
- Update CHANGELOG if applicable
- Update README if user-facing behavior changed

### 7. Create PR

- Verify all validation passes end-to-end
- Read `.github/instructions/safe-operations.instructions.md` for file operation rules
- Push branch and create PR:
  ```
  gh pr create --title "{concise title}" --body "## Summary\n...\n\n## Validation Evidence\n...\n\nCloses #{issue}"
  ```
  (Replace `main` in any `git diff main...HEAD` comparisons with the project's default branch if different.)
- PR body must include: summary, changed files, validation evidence, and `Closes #{issue}`
