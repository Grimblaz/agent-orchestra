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

---

## Scored Adversarial Review System

*Implemented in issue #96.*

### Change Summary

Replaced the rebuttal-based adversarial review pipeline with a structured Prosecution → Defense → Judge system applied at four workflow stages. Added three new Code-Critic modes (defense, CE prosecution, proxy prosecution). Converted Code-Review-Response to single-shot judgment with confidence scoring.

---

### Decision Log

| # | Decision | Choice | Rationale |
|---|----------|--------|----------|
| D11 | Defense mechanism | Code-Critic with `"Use defense review perspectives"` marker | Same agent with different persona is simpler than a new "Code-Defender" agent; avoids agent proliferation |
| D12 | CE prosecution executor | Code-Critic (separate pass after Code-Conductor exercises scenarios) | Separation of execution (Code-Conductor) and review (Code-Critic) avoids the fox-guarding-henhouse problem of Code-Conductor evaluating its own CE work |
| D13 | Rebuttal rounds | Removed; replaced by single defense pass + judge | Defense pass gives prosecution a structured adversarial challenge; single-shot judge with async user scoring replaces unlimited rebuttal rounds |
| D14 | Per-pass counter-review (3×) | Not used; single defense pass | 3× defense overhead for marginal benefit; merged prosecution ledger gives defense full context in one pass |
| D15 | Judge convergence | Single-shot; user scoring (+1/-1) provides async correction | Sample sizes too small for mid-cycle calibration; visibility first, then build learning pipeline |
| D16 | Opt-out for lightweight issues | Not supported | Quality is non-negotiable — full pipeline always runs |
| D17 | `review_loop_budget` | Removed from plan format | No longer needed; pipeline stages are fixed (3 prosecution + 1 defense + 1 judge) |
| D18 | Mode conflict resolution | Priority order: defense > CE > proxy > design > code | Most-specific mode wins; avoids ambiguous multi-marker prompts |
| D19 | Judge-only CRR separation | Code-Review-Response stops at judgment — no fix delegation | Conductor is the orchestrator; CRR doing delegation created conflicting responsibility chains |
| D20 | Post-judgment routing in Conductor | All post-judgment fix routing logic lives in Code-Conductor | Single responsibility: CRR judges, Conductor executes. Gaps addressed: AC cross-check, effort estimation, auto-tracking, GitHub response posting |

---

### Scoring Model

| Role | Earns | Loses | Incentive |
|------|-------|-------|----------|
| **Prosecutor** | +1 minor, +5 medium, +10 significant (per sustained finding) | 0 (unsustained findings don't score) | Find real defects, avoid fabrication |
| **Defense** | Finding's point value (per sustained disproof) | -2× finding's point value (per rejected disproof) | Only challenge what you can prove wrong |
| **Judge** | +1 per correct ruling (user-scored) | -1 per incorrect ruling (user-scored) | Be accurate, not agreeable |

**Severity mapping**:

- `critical` / `high` → significant (10 pts)
- `medium` → medium (5 pts)
- `low` → minor (1 pt)

Prosecutor assigns severity; judge may override.

**Judge confidence**: Each ruling tagged `high` / `medium` / `low` for calibration.

---

### Code-Critic Modes

| Marker in prompt | Mode | Passes | Perspectives |
|-----------------|------|--------|-------------|
| *(none / default)* | Code prosecution | 3 (parallel) | 7 code perspectives |
| `"Use design review perspectives"` | Design/plan prosecution | 1 | 3 design perspectives |
| `"Use defense review perspectives"` | Defense | 1 | Presume innocent; disprove each finding |
| `"Use CE review perspectives"` | CE prosecution | 1 | Functional + Intent + Error States |
| `"Score and represent GitHub review"` | Proxy prosecution | 1 | Validate/score external findings |

---

### Pipeline by Stage

**Code review** (3× prosecution, 1× defense, 1× judge):

```text
Code-Conductor invokes →
  Code-Critic (prosecution, pass 1) ─┐
  Code-Critic (prosecution, pass 2) ─┼→ Merge into deduplicated ledger
  Code-Critic (prosecution, pass 3) ─┘
    → Code-Critic (defense, 1 pass over merged ledger)
      → Code-Review-Response (judge, rules + emits score summary)
        → Score summary → Code-Conductor routes accepted fixes to specialists
```

**Design/plan review** (1× each):

*Issue-Planner (full pipeline)*:

```text
Issue-Planner (or start-issue.md) invokes →
  Code-Critic (prosecution, design perspectives, 1 pass)
    → Code-Critic (defense, 1 pass)
      → Code-Review-Response (judge)
        → Score summary returned
```

*Issue-Designer (prosecution only)*:

```text
Issue-Designer invokes →
  Code-Critic (prosecution, design perspectives, 1 pass)
    → (stops here — no defense or judge step)
```

**CE review**:

```text
Code-Conductor exercises CE scenarios (captures evidence)
  → Code-Critic (CE prosecution, reviews evidence + active adversarial error-state testing)
    → Code-Critic (defense, 1 pass)
      → Code-Review-Response (judge)
        → Score summary → Code-Conductor routes fixes via Track 1/2
```

**GitHub review** (proxy prosecutor):

```text
GitHub comments arrive → Code-Conductor routes →
  Code-Critic (proxy prosecution — validates, scores each GitHub comment)
    → Code-Critic (defense, 1 pass)
      → Code-Review-Response (judge)
        → Score summary → Code-Conductor routes fixes + posts responses to GitHub
```

---

### Defense Mode Specification

**Activation marker**: `"Use defense review perspectives"`

**Persona**: Adversarial defense — presume innocent. Your job is to find why each finding is wrong.

**Input**: Scored findings ledger from prosecution.

**Per-finding process**:

1. Read cited code/evidence independently
2. Attempt to disprove — show the alleged failure mode doesn't apply, evidence is wrong, or severity is overblown
3. Emit verdict: `disproved` (with evidence), `conceded` (finding stands), or `insufficient-to-disprove` (honest uncertainty, 0 points)

**Output format**:

```markdown
## Defense Report

### Finding: {id} — {title}
Prosecution: {severity} ({points} pts) — {brief claim}
Defense verdict: `disproved | conceded | insufficient-to-disprove`
Evidence: {what defense found}
Argument: {why prosecution is wrong, or why defense concedes}

### Score Summary
Findings reviewed: N
Disproved: X  |  Conceded: Y  |  Insufficient: Z
Points claimed: {sum of disproved finding values}
Points at risk: {-2× sum of disproved finding values, if judge rejects}
```

---

### Score Persistence

**PR body** — human-readable score summary table:

```markdown
## Adversarial Review Scores

| Stage | Prosecutor | Defense | Judge (pending) |
|-------|-----------|---------|-----------------|
| Code Review | 23 pts (4 sustained) | 12 pts (2 disproved, 1 rejected: -6) | 6 rulings |
| CE Review | 5 pts (1 sustained) | 0 pts | 1 ruling |
```

**Tracking file** — `.copilot-tracking/review-scores-issue-{ID}.yaml` (gitignored, machine-parsable):

```yaml
issue_id: N
branch: feature/issue-N-slug
review_date: YYYY-MM-DD
stages:
  code_review:
    prosecutor:
      findings_filed: 6
      sustained: 4
      points: 23
    defense:
      challenges_filed: 3
      sustained: 2
      rejected: 1
      points: 12
    judge:
      rulings:
        - id: F1
          prosecution_severity: medium
          prosecution_points: 5
          defense_verdict: conceded
          judge_ruling: sustained
          judge_confidence: high
          user_ruling: null
      user_scored: false
```

**User scoring** (async, non-blocking) — post a GitHub issue comment:

```markdown
## Judge Scoring
- F1: ✅ correct
- F2: ❌ incorrect (defense was right)
- F3: ✅ correct
```

---

### Rejected Alternatives

| Alternative | Why rejected |
|-------------|-------------|
| New "Code-Defender" agent | Same Code-Critic with defense prompt is simpler, avoids agent proliferation |
| Per-pass counter-review (3×) | 3× overhead for marginal benefit; merged ledger gives defense full context |
| Code-Critic exercises CE scenarios directly | Fox-henhouse problem; separation of execution and review is cleaner |
| In-session calibration (mid-cycle score adjustment) | Sample sizes too small for typical PRs |
| Full learning pipeline (day 1) | Visibility first, learn what patterns matter, then build |
| Accessibility + performance CE lenses | Tooling insufficient for reliable evaluation currently |
| Judge + rebuttal rounds (hybrid convergence) | Single-shot judge with user scoring provides async correction without complexity |
| Opt-out for lightweight issues | Quality is non-negotiable — full pipeline always runs |

---

### Files Changed

| File | Change |
|------|--------|
| `.github/agents/Code-Critic.agent.md` | Defense mode, CE prosecution mode, proxy prosecution mode, scoring output; frontmatter handoff updated |
| `.github/agents/Code-Review-Response.agent.md` | Single-shot judge, score summary output format, judge confidence levels, rebuttal management removed |
| `.github/agents/Code-Conductor.agent.md` | Review Reconciliation Loop rewritten (prosecution → defense → judge); CE Gate routes to CE prosecution; GitHub uses proxy prosecution; PR body includes score table; Agent Selection table updated |
| `.github/agents/Issue-Designer.agent.md` | Adversarial Design Challenge context updated (design prosecution, single-pass) |
| `.github/agents/Issue-Planner.agent.md` | Plan template updated (prosecution → defense → judge); `review_loop_budget` removed |
| `.github/agents/Process-Review.agent.md` | Reconciliation loop metrics updated to prosecution/defense/judge terminology |
| `.github/copilot-instructions.md` | Code-Critic Adversarial Review Protocol section updated (5 modes, all pipeline stages) |
| `CLAUDE.md` | Phase 5 description updated |
| `.github/instructions/code-review-intake.instructions.md` | GitHub Review Mode → Proxy Prosecution Pipeline; loop budget → convergence section |
| `.github/skills/code-review-intake/SKILL.md` | Mirror of instructions file changes |
| `.claude/commands/implement.md` | CE Gate cycle reference updated |
| `.claude/commands/review.md` | Adversarial Pipeline section added |
