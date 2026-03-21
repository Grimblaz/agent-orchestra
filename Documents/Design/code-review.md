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

**Gap found**: 29 stale `ask_questions` references across agent bodies, instructions, and skills. Code-Review-Response was missing the tool declaration in frontmatter entirely despite 11 body references. Code-Conductor and Solution-Designer had no frontmatter declaration despite 24 and multiple body references respectively.

**Changes**:

| File | Change |
|------|--------|
| `.github/agents/Code-Conductor.agent.md` | Added `vscode/askQuestions` as first entry in tools frontmatter; replaced all 24 bare references; added `## Context Management for Long Sessions` section with `/compact` guidance |
| `.github/agents/Solution-Designer.agent.md` | Added `"vscode/askQuestions"` to tools frontmatter; added `## Questioning Policy (Mandatory)` section with zero-tolerance pattern |
| `.github/agents/Code-Review-Response.agent.md` | Added `"vscode/askQuestions"` as first entry in tools frontmatter |
| `.github/instructions/code-review-intake.instructions.md` | 1 reference replaced |
| `.github/skills/parallel-execution/SKILL.md` | 1 reference replaced |
| `.github/prompts/setup.prompt.md` | 3 references replaced |
| `.github/skills/skill-creator/SKILL.md` | Added `## Built-in Creation Commands (VS Code 1.110+)` section: `/create-skill`, `/create-agent`, `/create-prompt`, `/create-instruction`; fallback blockquote for 1.108–1.109 users |
| `CUSTOMIZATION.md` | Added Agent Debug Panel documentation (available since VS Code 1.110, supersedes earlier Diagnostics chat action) |

**Deferred**: `#tool:` prefix standardization (Issue-Planner/Solution-Designer use `#tool:vscode/askQuestions`; Code-Conductor/Code-Review-Response use plain backtick). Both styles work; unification is a separate incremental improvement.

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
| D8 | Pass count for design review | 3-pass parallel (2 standard design + 1 product-alignment) | Matches the coverage-variance rationale for code review; adds an explicit product/experience/planned-work alignment lens per issue #131 |
| D9 | Review perspectives | 3 (Feasibility & Risk, Scope & Completeness, Integration & Impact) | Covers the three most common plan failure modes without overlap |
| D10 | Blocking behavior | Non-blocking (caller decides) | Code-Critic has no veto over design decisions; findings inform, not gate |
| D11 | Callers | Solution-Designer, Issue-Planner, Claude Code via start-issue.md | All three entry points to the planning phase need the same quality gate |

### Design Review Mode Behavior

- **Trigger**: Prompt contains the literal string `"Use design review perspectives"`
- **Output format**: `## Design Challenge Report` with three perspective sections (§D1, §D2, §D3) and a Summary
- **Finding format**: Same as code review (Issue / Concern / Nit with severity, confidence, failure_mode)
- **Scope**: Designs and implementation plans only — not code diffs
- **Read-only**: Same constraint as code review mode; no files are modified

### Caller Responsibility

Each caller decides how to handle the challenge report:

- **Solution-Designer**: incorporate / dismiss / escalate for user decision (with `vscode/askQuestions` gate before writing to GitHub if any item is escalated)
- **Issue-Planner**: incorporate / dismiss / escalate for user decision; append `**Plan Stress-Test**` summary block to plan
- **Claude Code (start-issue.md)**: follow Issue-Planner.agent.md Phase 4 guidance

### Vocabulary Standardization

Both Solution-Designer and Issue-Planner use a three-way disposition for challenge findings:

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
| D11a | Defense mechanism | Code-Critic with `"Use defense review perspectives"` marker | Same agent with different persona is simpler than a new "Code-Defender" agent; avoids agent proliferation |
| D12 | CE prosecution executor | Code-Critic (separate pass after Code-Conductor exercises scenarios) | Separation of execution (Code-Conductor) and review (Code-Critic) avoids the fox-guarding-henhouse problem of Code-Conductor evaluating its own CE work |
| D13 | Rebuttal rounds | Removed; replaced by single defense pass + judge | Defense pass gives prosecution a structured adversarial challenge; single-shot judge with async user scoring replaces unlimited rebuttal rounds |
| D14 | Per-pass counter-review (3×) | Not used; single defense pass | 3× defense overhead for marginal benefit; merged prosecution ledger gives defense full context in one pass |
| D15 | Judge convergence | Single-shot; user scoring (+1/-1) provides async correction | Sample sizes too small for mid-cycle calibration; visibility first, then build learning pipeline |
| D16 | Opt-out for lightweight issues | Not supported | Quality is non-negotiable — full pipeline always runs |
| D17 | `review_loop_budget` | Removed from plan format | No longer needed; pipeline stages are fixed (3 prosecution + 1 defense + 1 judge) |
| D18 | Mode conflict resolution | Priority order: defense > CE > proxy > product-alignment > design > code | Most-specific mode wins; avoids ambiguous multi-marker prompts |
| D19 | Judge-only CRR separation | Code-Review-Response stops at judgment — no fix delegation | Conductor is the orchestrator; CRR doing delegation created conflicting responsibility chains |
| D20 | Post-judgment routing in Conductor | All post-judgment fix routing logic lives in Code-Conductor | Single responsibility: CRR judges, Conductor executes. Gaps addressed: AC cross-check, effort estimation, auto-tracking, GitHub response posting |
| D21 | Post-fix prosecution pass | Full pipeline (3 prosecution + defense + judge), diff-scoped, triggered by Critical/High or control-flow fix, loop budget 1 | Catches fix-introduced defects missed by one-shot review; full pipeline maintains adversarial principle; tight scope keeps cost proportionate |

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
| `"Use design review perspectives"` | Design/plan prosecution | 2 (parallel) | 3 design perspectives (passes 1–2) |
| `"Use product-alignment perspectives"` | Product-alignment prosecution | 1 | 3 product-alignment perspectives (pass 3) |
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
          → [if triggered] Post-fix targeted prosecution (3× diff-scoped passes → defense → judge)
              → Code-Conductor routes post-fix accepted findings (loop budget: 1)
```

**Design/plan review** (3× prosecution):

*Issue-Planner (full pipeline)*:

```text
Issue-Planner (or start-issue.md) invokes →
  Code-Critic (prosecution, design perspectives, pass 1) ─┐
  Code-Critic (prosecution, design perspectives, pass 2) ─┼→ Merge into deduplicated ledger
  Code-Critic (prosecution, product-alignment, pass 3)  ─┘
    → Code-Critic (defense, 1 pass over merged ledger)
      → Code-Review-Response (judge)
        → Score summary returned
```

*Solution-Designer (prosecution only)*:

```text
Solution-Designer invokes →
  Code-Critic (prosecution, design perspectives, pass 1) ─┐
  Code-Critic (prosecution, design perspectives, pass 2) ─┼→ Merge into deduplicated ledger
  Code-Critic (prosecution, product-alignment, pass 3)  ─┘
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

> **Finding-level score summary** (Code-Review-Response output): The per-finding score table now includes a `Pass` column showing which prosecution pass originated each finding. Populated from `pass: N` tags in the prosecution ledger. Non-code-prosecution modes (CE review, proxy prosecution) emit `—` in the Pass column. Design/plan review populates from `pass: N` tags in the prosecution ledger (same as code prosecution).

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

### Pipeline Metrics (PR body)

In addition to the human-readable score table and the tracking-file YAML, Code-Conductor includes a machine-parseable pipeline metrics block in the PR body. This block is a hidden HTML comment containing flat YAML:

```markdown
<!-- pipeline-metrics
prosecution_findings: N          # post-dedup total; equals pass_1_findings+pass_2_findings+pass_3_findings
pass_1_findings: N               # findings credited to pass 1
pass_2_findings: N               # findings credited to pass 2
pass_3_findings: N               # findings credited to pass 3
defense_disproved: N             # findings successfully disproved by defense
judge_accepted: N                # findings ruled ✅ Sustained by judge
judge_rejected: N                # findings ruled ❌ Defense sustained by judge
judge_deferred: N                # findings ruled 📋 DEFERRED-SIGNIFICANT
ce_gate_result: passed|skipped|not-applicable
ce_gate_intent: strong|partial|weak|n/a
ce_gate_defects_found: N         # (n/a when CE Gate not applicable)
rework_cycles: N                 # code review fix loops only (not CE Gate loops)
-->
```

**Purpose**: Enables cross-PR analytics (e.g., per-pass marginal yield: does pass 3 justify its cost?). Invisible in rendered Markdown. Parseable via `Select-String -Pattern "pipeline-metrics"`.

**Deduplication credit**: When the same finding appears in multiple prosecution passes, the earliest pass gets credit (lowest pass number). `pass_1_findings + pass_2_findings + pass_3_findings = prosecution_findings` (code prosecution and design/plan prosecution; in proxy prosecution, per-pass fields are `n/a`).

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
| Full learning pipeline (day 1) | Visibility first, learn what patterns matter, then build. Superseded by Issue #97 — implemented as cross-session learning pipeline with Process-Review consumer. |
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
| `.github/agents/Solution-Designer.agent.md` | Adversarial Design Challenge context updated (design prosecution, 3-pass parallel) |
| `.github/agents/Issue-Planner.agent.md` | Plan template updated (prosecution → defense → judge); `review_loop_budget` removed |
| `.github/agents/Process-Review.agent.md` | Reconciliation loop metrics updated to prosecution/defense/judge terminology |
| `.github/copilot-instructions.md` | Code-Critic Adversarial Review Protocol section updated (5 modes, all pipeline stages) |
| `CLAUDE.md` | Phase 5 description updated |
| `.github/instructions/code-review-intake.instructions.md` | GitHub Review Mode → Proxy Prosecution Pipeline; loop budget → convergence section |
| `.github/skills/code-review-intake/SKILL.md` | Mirror of instructions file changes |
| `.claude/commands/implement.md` | CE Gate cycle reference updated |
| `.claude/commands/review.md` | Adversarial Pipeline section added |
| `.github/agents/Code-Critic.agent.md` | Added `id` and `pass` fields to automation-routing fields in Finding Categories; added `pass: N` omission notes to proxy prosecution and CE prosecution output descriptions |

---

## Cross-Session Learning Pipeline

**Issue**: #97 | **Depends on**: #96 (Scored Adversarial Review System)

### Summary

Extends the scored adversarial review system to aggregate per-finding data across merged PRs, detect systematic biases in the prosecution→defense→judge pipeline, and surface actionable recommendations via Process-Review. Human applies approved recommendations — no automated prompt rewriting.

**Data flow**:

```text
PR merged → pipeline-metrics in PR body (with per-finding entries)
                    ↓
Process-Review invoked → runs .github/scripts/aggregate-review-scores.ps1
                    ↓
Script: gh pr list → gh pr view (each) → parse pipeline-metrics → compute calibration
                    ↓
Calibration profile → Process-Review identifies patterns → emits recommendations
                    ↓
User reviews → approves/rejects → applies changes to agent files
```

### Decision Log

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D22 | Data source | Enriched `<!-- pipeline-metrics -->` in PR bodies | No repo pollution; data lives with the PR; durable across session resets |
| D23 | Category taxonomy | Code-Critic's 7 prosecution perspectives | 1:1 mapping; no ambiguity; `n/a` for CE/design/proxy modes |
| D24 | Sample size thresholds | 5 effective issues overall; 15 effective findings per category | Balances early value against statistical noise |
| D25 | Storage format | On-demand stdout from aggregation script | Always fresh; no stale files; no repo clutter |
| D26 | Drift handling | Exponential decay λ=0.023 (~30-day half-life), configurable via `-DecayLambda` | Automatic adaptation as prompts evolve; avoids cliff effect of sliding window |
| D27 | Injection mode | Auto-run within Process-Review; skip silently if insufficient data or `gh` unavailable | Zero friction; graceful degradation |
| D28 | Consumer | Process-Review analyzes + recommends; human applies approved changes | No perverse incentives; deliberate improvement; matches visibility-first philosophy |

### Enriched Pipeline-Metrics v2 Format

The `<!-- pipeline-metrics -->` format is extended from 18-field flat YAML (v1) to include a `findings:` array (v2). Format detection: presence of `metrics_version: 2` field.

**New fields**:

- `metrics_version: 2` — format version discriminator
- `findings:` — array with per-finding entries; each entry includes `id`, `category`, `severity`, `points`, `pass`, `defense_verdict`, `judge_ruling`, `judge_confidence`, `review_stage`
- `review_stage` values: `main | postfix | ce | design | proxy`

**Category values** (Code-Critic's 7 prosecution perspectives): `architecture | security | performance | pattern | simplicity | script-automation | documentation-audit`; `n/a` for CE, design, and proxy prosecution findings.

### Code-Review-Response Structured Output

CRR now emits a `<!-- judge-rulings -->` YAML block after the Markdown score summary table. Code-Conductor reads this for per-finding data; falls back to parsing the Markdown table if the block is absent.

### Calibration Profile

The aggregation script (`.github/scripts/aggregate-review-scores.ps1`) outputs YAML to stdout with:

- Weighted sustain rates per prosecution category (per-category `sufficient_data: true` when ≥ 15 effective findings)
- Defense block includes `defense_findings_count: N` (raw count), `defense_effective_count: X.X` (decay-weighted), and `defense_sufficient_data: true/false` (threshold: effective_count ≥ 5.0) before `defense_success_rate` and `defense_challenge_rate`
- Judge confidence calibration per level (high/medium/low); each level emits `sufficient_data: true/false` (threshold: effective_count ≥ 5) before `sustain_rate`
- `by_review_stage:` breakdown with canonical keys `main`, `postfix`, `ce`; a `review_stage_untagged: N` field counts findings that were defaulted to `main` due to a missing `review_stage` field in their pipeline-metrics block (early-adoption indicator). `design` and `proxy` findings, if tagged, appear as ad-hoc keys outside the canonical set.
- `bias_direction` (slightly_prosecution | slightly_defense | balanced)
- `insufficient_data: true` when effective_sample_size < 5; `skipped_prs: N` emitted in both the insufficient-data block and the full calibration block (count of PRs skipped due to `gh` errors during processing)

### Process-Review Integration

Process-Review §4.7 runs the aggregation script automatically. Recommendations follow defined signal thresholds:

- Sustain rate < 0.5 → strengthen evidence requirements for that Code-Critic perspective
- Judge high-confidence accuracy < 0.85 → add calibration caveats to CRR
- Defense success rate (`defense_success_rate`) < 10% → this indicates defense is challenging findings but rarely winning (ineffective defense, not passive); consider narrowing defense scope
- Defense challenge rate (`defense_challenge_rate`) < 10% → defense is passively conceding most findings; review defense perspective prompts for passive acceptance bias
- Defense overreach > 30% → add specificity requirements to challenges

All recommendations cite the specific file, section, and suggested change. Process-Review is READ-ONLY — recommendations require human approval before application.

### Known Limitations

- **No ground truth**: Calibration measures self-consistency (sustain rates, confidence calibration), not objective correctness. Ground truth requires user scoring data (async/optional).
- **Passive improvement**: Reviews don't automatically improve — Process-Review recommends, humans apply. Deliberate design — matches the visibility-first philosophy from D15 (Issue #96).
- **Low-volume repo cold start**: New repos need 5+ merged PRs with enriched metrics before calibration runs. This is expected.

### Files Changed (Issue #97)

| File | Change |
|------|--------|
| `.github/agents/Code-Critic.agent.md` | Added `category` field to automation-routing output fields |
| `.github/agents/Code-Conductor.agent.md` | Enriched `<!-- pipeline-metrics -->` with `metrics_version: 2`, `findings:` array, and population instructions; added `pass: N` tagging to prosecution pass prompts; added earliest-pass dedup credit rule; added `### PR Body Pipeline Metrics` section with 12-field metrics template and default value rules |
| `.github/agents/Process-Review.agent.md` | Added §4.7 Calibration Analysis section |
| `.github/scripts/aggregate-review-scores.ps1` | New script — reads merged PRs, computes calibration profile |
| `Documents/Design/code-review.md` | This file — cross-session learning pipeline section |
| `CLAUDE.md` | Phase 5 updated with calibration script note |
| `.github/agents/Code-Review-Response.agent.md` | Added `<!-- judge-rulings -->` structured YAML block requirement; added `Pass` column to score summary table template; added `id` field to finding schema; split example into code-prosecution and non-code-prosecution variants |

---

## Cross-File String Constant Safeguards

*Implemented in issues #121 and #122 (from Issue #97 CE Gate post-mortem).*

### Root Cause

`aggregate-review-scores.ps1` used `'post-fix'` and `'ce-gate'` in `$knownStages` but Code-Conductor's `<!-- pipeline-metrics -->` template defines `postfix` and `ce`. The mismatch was undetected at review time (three prosecution passes missed it) because: (a) Code-Critic §6 fires only for script-containing PRs and has no cross-file constant validation; (b) Issue-Planner's Requirement Contract rules had no requirement to name authoritative source files or enumerate exact allowed values.

### Changes

Three changes across two agent files:

1. **Code-Critic §6 — Cross-file constant consistency check** (`Code-Critic.agent.md`): New 5th checklist item requiring reviewers to verify string constants that enumerate values defined in another file exactly match the canonical values in that authoritative source. Includes a fallback discovery hint for PRs without an explicit plan.

2. **Code-Critic §1 — Docs-only producer check** (`Code-Critic.agent.md`): New checklist item in the §1 Architecture section for docs-only PRs: when a docs-only PR adds, renames, or removes string constant values defined in a template or agent, verify all known consumer scripts enumerate the same values.

3. **Issue-Planner plan_style_guide — Two new Requirement Contract rules** (`Issue-Planner.agent.md`):
   - **Cross-file constants**: bidirectional trigger — fires for plan steps that (a) implement or modify scripts consuming enumerated values, or (b) create or modify files that authoritatively define values consumed by scripts. Requires the RC to name the authoritative source file and list exact values (example format: `` `Allowed values: 'main' | 'postfix' | 'ce'` ``).
   - **Multi-tier statistical output**: when a plan step involves a statistical output schema with multiple independent sub-sections (calibration scripts, metrics aggregators), the Requirement Contract must enumerate each output section requiring a `sufficient_data` gate rather than describing gating as a single aggregate requirement.

### Decision Summary

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D29 | Code-Critic placement (consumer check) | §6 Script & Automation | §6 fires when scripts are in the PR — the most common defect vector (consumer modifying its enum array) |
| D30 | Code-Critic placement (producer check) | §1 Architecture (docs-only path) | §1 fires for all docs-only PRs — covers the symmetric case where a template renames a value without touching any script |
| D31 | Issue-Planner trigger scope | Bidirectional (consumer side + producer side) | One-directional (consumer-only) leaves the producer-rename scenario unguarded; design prosecution (pass 1) caught this gap |
| D32 | Format specification for enum list | Example format in rule (`Allowed values: 'main' \| 'postfix' \| 'ce'`) | Without an example, planners diverge on PowerShell array vs. JSON vs. prose — only exact-match formats make mismatch visible at a glance |
| D33 | Multi-tier rule trigger wording | "involves" (not "produces" or "consumes") | Direction-agnostic — fires for both producer and consumer plan steps; design adversarial prosecution finding F3 caught the "produces"-vs-"involves" gap |

### Acceptance Criteria (from issues #121 and #122)

- Code-Critic §6 includes a 5th checklist item with cross-file constant verification and authoritative-source discovery guidance
- Code-Critic §1 includes a docs-only producer-side check for renamed/added enumerated constants
- Issue-Planner `<plan_style_guide>` includes bidirectional Cross-file constants rule with format example
- Issue-Planner `<plan_style_guide>` includes Multi-tier statistical output rule using "involves"
- Quick-validate: Plan-Architect refs = 0, Janitor refs = 0, agent count = 13

---

## Persistent Review Calibration Data Storage

**Issue**: #141 | **Depends on**: #97 (Cross-Session Learning Pipeline)

### Summary

Adds a local calibration cache (`.copilot-tracking/calibration/review-data.json`) that supplements PR-body pipeline-metrics parsing for VS Code Copilot users. Claude Code continues to use PR body parsing only. Schema versioned at `calibration_version: 1`; top-level fields are extensible for downstream tooling.

### Decision Log

| # | Decision | Choice | Rationale |
|---|----------|--------|----------|
| D34 | Calibration timestamp field | `created_at` at write time (pre-merge, not `merged_at`) | The aggregate script sources `mergedAt` from GitHub API for decay weighting. Local calibration entries support downstream issues via extensible top-level schema; per-finding data quality depends on pipeline-metrics v2 adoption. |

### Acceptance Criteria (from issue #141)

- `write-calibration-entry.ps1` writes entries to `.copilot-tracking/calibration/review-data.json` using `created_at` timestamp
- `backfill-calibration.ps1` backfills from existing merged PR history (VS Code Copilot only)
- `aggregate-review-scores.ps1` accepts optional `-CalibrationFile` parameter (default: `.copilot-tracking/calibration/review-data.json`)
- Claude Code workflow uses PR body parsing only — local calibration cache is a VS Code Copilot optimization
- Quick-validate: Plan-Architect refs = 0, Janitor refs = 0, agent count = 13
