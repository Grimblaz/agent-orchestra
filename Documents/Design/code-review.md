# Design: Code Review Process

## Summary

Two complementary improvements to the code review workflow: (1) an exhaustive-scan requirement for migration-type issues that prevents missed file references, and (2) standardization on `vscode/askQuestions` as the correct VS Code 1.110+ tool name for all agent questioning, with explicit frontmatter declarations.

---

## Design Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Scan guidance placement | `<plan_style_guide>` rules in Issue-Planner | Co-located with plan structure rules where plan authors naturally look; no new workflow phases needed |
| D2 | Final-grep placement | Step 4 PR checklist in Code-Conductor (not Validation Ladder tier) | Scope-completeness check fits alongside existing `git diff --name-status` scope check; Validation Ladder is for build/test/lint quality gates |
| D3 | Migration qualifier phrasing | "migration-type issues only" (not "(when applicable)") | "(when applicable)" was ambiguous — consistent explicit qualifier in both the bullet and the PR body list |
| D4 | Tool name standardization | `vscode/askQuestions` everywhere | Ensures runtime alignment; eliminates confusion between old name (`ask_questions`) and new name |
| D5 | Frontmatter declarations | Explicit `vscode/askQuestions` in every agent that uses it | Missing declaration despite body references was a critical gap — tool may not be available at runtime without declaration |
| D6 | Design docs frozen | No `ask_questions` changes in `Documents/Design/` files | Historical design records; stale references inside are acceptable |

---

## Exhaustive-Scan Requirement

For migration-type issues — pattern replacement, API migration, rename/move across files, or issues with signal phrases like "replace X with Y" or "migrate from A to B" — Step 1 of the plan **MUST** be an exhaustive repo scan producing the authoritative file list. The issue author's file list must not be trusted as complete.

**Root cause**: In issue #39, two instruction files with hardcoded relative paths were missed by the plan and only caught in Code-Critic Pass 3 as a blocker. A single scan before implementation would have caught them.

**Example scan command**:

```powershell
Get-ChildItem -Path "." -Recurse -Include "*.md","*.json","*.ps1" |
    Where-Object { $_.FullName -notmatch "\.copilot-tracking-archive|\.git[\\/]" } |
    Select-String -Pattern "old-pattern"
```

**Two insertion points**:

1. **Issue-Planner** `<plan_style_guide>` — new conditional rule after "Keep scannable": migration issues require an exhaustive scan in Step 1.
2. **Code-Conductor** Step 4 — new "Migration completeness check" bullet between "Scope check" and "Validation evidence": run a final scan for remaining old-form references and confirm count is 0; include scan output as validation evidence in the PR body.

---

## `vscode/askQuestions` Standardization

VS Code 1.110 renamed the questioning tool from `ask_questions` to `vscode/askQuestions`. Agents that reference a tool name not matching their frontmatter declaration may not have the tool available at runtime.

**Gap found**: 29 stale `ask_questions` references across agent bodies, instructions, and skills. Code-Review-Response was missing the tool declaration in frontmatter entirely despite 11 body references. Code-Conductor and Issue-Designer had no frontmatter declaration despite 24 and multiple body references respectively.

**Changes**:

| File | Change |
|------|--------|
| `.github/agents/Code-Conductor.agent.md` | Added `vscode/askQuestions` as first entry in tools frontmatter; replaced all 24 bare references; added `## Context Management for Long Sessions` section with `/compact` guidance |
| `.github/agents/Issue-Designer.agent.md` | Added `"vscode/askQuestions"` to tools frontmatter; added `## Questioning Policy (Mandatory)` section with zero-tolerance pattern |
| `.github/agents/Code-Review-Response.agent.md` | Added `"vscode/askQuestions"` as first entry in tools frontmatter |
| `.github/instructions/code-review-intake.instructions.md` | 1 reference replaced |
| `.github/skills/parallel-execution/SKILL.md` | 1 reference replaced |
| `.github/prompts/setup.prompt.md` | 3 references replaced |
| `.github/skills/skill-creator/SKILL.md` | Added `## Built-in Creation Commands (VS Code 1.110+)` section: `/create-skill`, `/create-agent`, `/create-prompt`, `/create-instruction`; fallback blockquote for 1.108–1.109 users |
| `CUSTOMIZATION.md` | Added Agent Debug Panel documentation (available since VS Code 1.110, supersedes earlier Diagnostics chat action) |

**Deferred**: `#tool:` prefix standardization (Issue-Planner/Issue-Designer use `#tool:vscode/askQuestions`; Code-Conductor/Code-Review-Response use plain backtick). Both styles work; unification is a separate incremental improvement.

---

## Acceptance Criteria

- Bare `` `ask_questions` `` references in `.github/`: 0
- All agents using `vscode/askQuestions` in body declare it in frontmatter
- Issue-Planner `<plan_style_guide>` includes exhaustive-scan rule for migration issues
- Code-Conductor Step 4 includes migration completeness check
- PR body template includes `migration-scan result (migration-type issues only)`
- Quick-validate: Plan-Architect refs = 0, Janitor refs = 0, agent count = 13

---

## Design Review Mode

Added in issue #73. Code-Critic gains a second operating mode triggered by the marker `"Use design review perspectives"`.

### Decision Summary

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D7 | Activation mechanism | Marker string in prompt | Avoids runtime ambiguity; callers always know which mode they're requesting |
| D8 | Pass count for design review | Single-pass only | Design reviews are lightweight quality gates, not adversarial loops; 3-pass would over-index on plans |
| D9 | Review perspectives | 3 (Feasibility & Risk, Scope & Completeness, Integration & Impact) | Covers the three most common plan failure modes without overlap |
| D10 | Blocking behavior | Non-blocking (caller decides) | Code-Critic has no veto over design decisions; findings inform, not gate |
| D11 | Callers | Issue-Designer, Issue-Planner, Claude Code via start-issue.md | All three entry points to the planning phase need the same quality gate |

### Design Review Mode Behavior

- **Trigger**: Prompt contains the literal string `"Use design review perspectives"`
- **Output format**: `## Design Challenge Report` with three perspective sections (§D1, §D2, §D3) and a Summary
- **Finding format**: Same as code review (Issue / Concern / Nit with severity, confidence, failure_mode)
- **Scope**: Designs and implementation plans only — not code diffs
- **Read-only**: Same constraint as code review mode; no files are modified

### Caller Responsibility

Each caller decides how to handle the challenge report:

- **Issue-Designer**: incorporate / dismiss / escalate for user decision (with `vscode/askQuestions` gate before writing to GitHub if any item is escalated)
- **Issue-Planner**: incorporate / dismiss / escalate for user decision; append `**Plan Stress-Test**` summary block to plan
- **Claude Code (start-issue.md)**: follow Issue-Planner.agent.md Phase 4 guidance

### Vocabulary Standardization

Both Issue-Designer and Issue-Planner use a three-way disposition for challenge findings:

1. **incorporate** — refine the design/plan to address the challenge
2. **dismiss** — reject the challenge with documented rationale
3. **escalate for user decision** — surface to user via `vscode/askQuestions` before proceeding
