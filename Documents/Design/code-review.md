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

**Example scan guidance**:

Use `grep_search` with the old-pattern as `query` and `includePattern` matching the target files (e.g., `**/*.md`). Confirm result count is 0. Use `file_search` with the same glob to confirm at least 1 file was examined — a 0-match from 0 files indicates a misconfigured glob.

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
- Quick-validate: Plan-Architect refs = 0, Janitor refs = 0, agent count = 14

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
| D11 | Callers | Solution-Designer, Issue-Planner | Both entry points to the planning phase need the same quality gate |

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
| D21 | Post-fix prosecution pass | Full pipeline (3 prosecution + defense + judge), diff-scoped, triggered by Critical/High or control-flow fix, loop budget 1 | Catches fix-introduced defects missed by one-shot review; full pipeline maintains adversarial principle; tight scope keeps cost proportionate. **Superseded by D36** (1+1 post-fix prosecution). |

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
| *(none / default)* | Code prosecution | 3 (parallel) | 6 code perspectives |
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
          → [if triggered] Post-fix targeted prosecution (1+1 passes, diff-scoped; if pass 1 finds issues → defense → judge; otherwise ends)
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
| `.github/instructions/code-review-intake.instructions.md` | GitHub Review Mode → Proxy Prosecution Pipeline; loop budget → convergence section |
| `.github/skills/code-review-intake/SKILL.md` | Mirror of instructions file changes |
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
| D23 | Category taxonomy | Code-Critic's 6 prosecution perspectives (7 category taxonomy values) | 7-to-6 mapping after #212 (`documentation-audit` and `script-automation` share §6 Script & Automation); `n/a` for CE/design/proxy modes |
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
- `systemic_fix_type` values (per finding): `instruction | skill | agent-prompt | plan-template | none` — what kind of guardrail would prevent this defect class; filled by Code-Critic at prosecution time; defaults to `none` when absent

**Category values** (Code-Critic's 7 category taxonomy values — 6 prosecution perspectives post-#212; `documentation-audit` and `script-automation` share a single §6 Script & Automation perspective): `architecture | security | performance | pattern | implementation-clarity | script-automation | documentation-audit`; `n/a` for CE, design, and proxy prosecution findings.

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

CE Gate planning note: when a script emits a new output block in more than one conditional path, the plan requires at least one CE Gate scenario for each path where the block appears. Each scenario's acceptance criterion must specify the expected behavior of every consuming agent in that path, not merely output format. The motivating example is the issue #213 `aggregate-review-scores.ps1` to Process-Review normal-path versus early-exit or `insufficient_data` path split. If the block appears in only one conditional path, this rule is out of scope.

### Health Report Mode (Issue #259)

Passing `-HealthReport` to `aggregate-review-scores.ps1` (or `Invoke-AggregateReviewScores -HealthReport`) switches output from YAML to a 5-section Markdown report:

| Section | Content |
|---------|---------|
| **Pipeline Health** | Overall statistics: total findings, sustain rate, effective sample size |
| **Category Hotspots** | Top categories by effective count; per-category Trend column shows `—` (per-category temporal split via `OlderCategoryRates` deferred per D-264-10 scope boundary; per-category `wTotal`/`wAccepted` data is now available in `$prContributions.categories` from Phase 3 enrichment) |
| **Prosecution Depth** | Per-category table with `Depth` column (`full` / `light` / `skip`) for each of `$knownCategories` |
| **D10 Alerts** | Categories with `light` or `skip` depth, sorted by effective count |
| **Systemic Pattern Alerts** | Systemic patterns meeting threshold, sorted by sustained count |
| **Fix Effectiveness** | Per-fix sustain rate comparison — before/after split windows with improved/unchanged/worsened indicators, insufficient-data and no-before-data edge cases, awaiting-merge placeholder |

`-HealthReport` is **read-only**: all three write-back paths (calibration file write, `guidance-complexity.json`, `write-calibration-entry.ps1`) are skipped. Add `-OutputPath <file>` to write the report to a file instead of stdout; if the write fails, the script falls back to stdout.

**Process-Review §4.7** passes `-HealthReport -OutputPath $healthReportTempFile` in its Step 0 and displays the file in Step 5.

**Category alias normalization** (also Issue #259): `$accumulateFinding` now normalizes `simplicity → implementation-clarity` *and* `documentation → documentation-audit` before accumulation. Both aliases are accepted from older pipeline-metrics blocks and mapped to the canonical 7-category taxonomy before Hotspots and Prosecution Depth are computed.

**Lateral-completeness check** (Issue #266): Code-Critic §6 Principle 2 now includes a lateral-completeness sub-bullet — when a PR adds or extends a normalization block, reviewers must scan the full `$known*` canonical set, not just the value being added.

### Fix Effectiveness (Issue #264 — Phase 3)

Per-fix sustain rate comparison using before/after split windows. Two private helpers in `aggregate-review-scores-core.ps1`:

- **`Measure-WindowCategoryTotals`** — Sums per-category `wTotal`/`wAccepted` across a `$prContributions` window (subset of PRs). Used by `Measure-FixEffectiveness` for before/after accumulation.
- **`Measure-FixEffectiveness`** — Pure function (no side effects, no `gh` calls, no file writes). Groups `proposals_emitted` by `pattern_key`, partitions `$prContributions` into before/after windows around each fix's `fix_merged_at`, and computes sustain rate delta with a 5% deadzone (D-264-9). Returns a `Results` array (per-fix entries with `indicator` values: `improved` / `unchanged` / `worsened` / `insufficient data` / `no before data`) and an `AwaitingMergeCount`. Stacked fixes for the same `pattern_key` use bounded windows — each fix's after-window is capped at the next fix's `fix_merged_at` (D-264-6).

**Per-category enrichment** (D-264-10): The `$accumulateFinding` lambda enriches each `$prContributions` entry with a `categories` hashtable mapping category → `{ wTotal; wAccepted }`. This enrichment is scoped to Fix Effectiveness only — `Category Hotspots` continues using aggregate-level data.

**Merge-date discovery loop** (D-264-6, D-264-11): Runs during normal (non-`-HealthReport`) execution, after PR accumulation and before Fix Effectiveness computation. For each `proposals_emitted` entry with `fix_issue_number` but no `fix_merged_at`:

1. Builds a search query: `closes #N OR fixes #N OR resolves #N`
2. Calls `gh pr list --repo $Repo --state merged --search $query --json 'number,mergedAt' --sort updated --limit 5`
3. Picks the entry with the latest `mergedAt` and writes `fix_merged_at` back to the proposal
4. Sets `$fixMergedAtChanged = $true` to trigger calibration file write-back

On subsequent runs, entries with `fix_merged_at` already populated are cache hits — no `gh` call is made. Failures are non-fatal (logged via `Write-Warning`, entry skipped).

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
| `.github/agents/Code-Review-Response.agent.md` | Added `<!-- judge-rulings -->` structured YAML block requirement; added `Pass` column to score summary table template; added `id` field to finding schema; split example into code-prosecution and non-code-prosecution variants |

---

## Implementation Notes

**Issue #132 — Built-in-tool-first enforcement (2026-03)**: Code-Critic §6 (Script & Automation) doc-audit sub-gate includes a check that flags workflow markdown prescribing terminal commands for read-only operations when a built-in VS Code tool equivalent exists. The doc-audit "When to apply" trigger covers inline terminal command guidance (backtick-quoted commands in prose) in addition to fenced shell blocks. *(Note: originally §7 Documentation Script Audit — merged into §6 as doc-audit sub-gate in #212.)*

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
- Quick-validate: Plan-Architect refs = 0, Janitor refs = 0, agent count = 14

---

## Persistent Review Calibration Data Storage

**Issue**: #141 | **Depends on**: #97 (Cross-Session Learning Pipeline)

### Summary

Adds a local calibration cache (`.copilot-tracking/calibration/review-data.json`) that supplements PR-body pipeline-metrics parsing. Schema versioned at `calibration_version: 1`; top-level fields are extensible for downstream tooling.

### Decision Log

| # | Decision | Choice | Rationale |
|---|----------|--------|----------|
| D34 | Calibration timestamp field | `created_at` at write time (pre-merge, not `merged_at`) | The aggregate script sources `mergedAt` from GitHub API for decay weighting. Local calibration entries support downstream issues via extensible top-level schema; per-finding data quality depends on pipeline-metrics v2 adoption. |

### Acceptance Criteria (from issue #141)

- `write-calibration-entry.ps1` writes entries to `.copilot-tracking/calibration/review-data.json` using `created_at` timestamp
- `backfill-calibration.ps1` backfills from existing merged PR history
- `aggregate-review-scores.ps1` accepts optional `-CalibrationFile` parameter (default: `.copilot-tracking/calibration/review-data.json`)
- Quick-validate: Plan-Architect refs = 0, Janitor refs = 0, agent count = 14

---

## PowerShell Review Guardrails

**Issues**: #163, #164, #165 | **Root cause**: PR #161 defect escape — `aggregate-review-scores.ps1` shipped with two PowerShell-specific bugs that three prosecution passes failed to catch: (1) `.Clone()` called on `OrderedDictionary` (which lacks the method, unlike `Hashtable`/`ArrayList`), and (2) bare `return @(...)` collapsing single-element arrays to scalars before JSON serialization.

### Changes

Three targeted additions to close the process gaps that allowed these defects through:

1. **Code-Critic §6 — Two new PowerShell checklist items** (`Code-Critic.agent.md`):
   - **.NET method accessibility**: Flag `.Clone()` on `[ordered]@{}` or ambiguously-typed dictionary variables; recommend `ConvertTo-Json | ConvertFrom-Json -AsHashtable` deep-copy idiom.
   - **Collection-return semantics**: Verify functions returning `@(...)` that may be serialized use `return , @(...)` (unary comma) or `Write-Output -NoEnumerate` to preserve array identity.

2. **Code-Smith item 4 — Single-element array round-trip verification** (`Code-Smith.agent.md`): Extended the serialized output correctness rule to require verifying that single-element writes preserve array type, not just that the JSON document is parseable. Added PowerShell idiom hint (`return , @(...)` / `Write-Output -NoEnumerate`).

3. **copilot-instructions.md — Pester test command**: Added `pwsh -NoProfile -NonInteractive -Command "Invoke-Pester .github/scripts/Tests/ -Output Minimal"` to the validation commands section and updated the Testing line in the Technology Stack.

---

## Token Budget Optimization

**Source**: Issue #180, informed by PR #111 session (Grimblaz-and-Friends/Windgust-Questbook) data — 23 subagent calls, 2 rate-limit failures, ~25–35% estimated token waste.

**Preamble re-pay cost model**: Every `runSubagent` call creates a fresh context window. The subagent re-ingests its full agent definition (often 800+ lines), all loaded skills and instructions, tool definitions, and file context — a fixed floor cost of 15K–25K+ input tokens before any actual task work begins. This makes call-count reduction the highest-leverage optimization: each avoided call saves the preamble cost in full.

### D35 — Express Lane Gate (R6)

**Decision**: After prosecution merges and deduplicates the ledger, partition findings matching all six mechanical criteria (severity is `low`, strictly mechanical fix type, no logic changes, no test cascade, not stored ID/DB schema, scope ≤1 file) into an express lane that bypasses defense and judge and routes directly to the specialist.

**Rationale**: A 1-point string casing fix does not benefit from a defense pass or a judge arbitration. The compound 6-criteria gate mitigates severity under-rating risk — all criteria must hold simultaneously, making false eligibility rare. Estimated savings: 30K–75K+ tokens per express-laned item (2 avoided subagent calls × preamble cost). Session-level call reduction varies by scenario: 20–30% when most or all findings are express-laned; proportionally lower in partial express-lane sessions (observed: ~22% in a 2-of-4 express-lane scenario).

**Scope restriction**: Standard code review prosecution and diff-scoped post-fix targeted prosecution only — not proxy prosecution (GitHub intake), CE prosecution, or design review.

### D36 — 1+1 Post-Fix Prosecution (R2)

**Decision**: Replace 3 parallel post-fix prosecution passes with 1 pass + 1 conditional follow-up (only if pass 1 finds ≥1 finding). If pass 1 finds nothing, post-fix review is complete — skip defense, judge, and routing.

**Rationale**: In the PR #111 session, pass 2 of post-fix prosecution returned "no findings — clean" (pure waste). A clean pass 1 is strong evidence of a clean fix, given that the post-fix scope is diff-scoped (small, targeted). The conditional follow-up preserves defect detection when pass 1 does surface something. Estimated savings: 30K–50K+ tokens per clean post-fix cycle.

### D37 — Batch Specialist Dispatch (R4)

**Decision**: Collect all routing decisions (express-lane partition + judge rulings) before dispatching to specialists. Group findings by assigned specialist agent and make one `runSubagent` call per unique specialist, passing all that agent's findings together.

**Rationale**: Multiple sequential calls to the same specialist each re-incur the preamble cost. Grouping eliminates N−1 preamble re-pays per agent. Two-phase collection (finalize all routing decisions before any dispatching) ensures no findings are dispatched before all routing choices are final. Estimated savings: 15K–25K+ tokens per avoided call. Exception: contradictory-approach findings for the same agent split into separate calls.

### D38 — Rate Limit Backoff (R5)

**Decision**: Implement exponential backoff (2^attempt × 30s: attempt 1 = 60s, attempt 2 = 120s) before retrying rate-limited subagent calls. After 2 consecutive failures for the same call, defer remaining work to the next session — save state to session memory, never silently drop findings.

**Rationale**: In the PR #111 session, 2 rate-limited retries consumed prompt tokens with zero output (pure waste). Exponential backoff gives the rate-limit window time to reset without hammering the API. Sonnet→Opus fallback is considered before entering backoff because Anthropic models have separate per-model TPM limits. Deferred-not-dropped ensures quality — no findings are silently lost to rate limiting.

---

## Review Kaizen Sub A: Root Cause Tagging

**Issue**: #149

### Decision Log

| # | Decision | Choice | Rationale |
|---|----------|--------|------------|
| D39 | `systemic_fix_type` root cause tagging | Code-Critic tags each prosecution finding with one of: `instruction`, `skill`, `agent-prompt`, `plan-template`, `none` — what kind of guardrail would prevent this defect class | Enables manual and automated (future Sub C) pattern recognition across PRs without requiring full root cause analysis at review time; backward-compatible (field optional, defaults to `none`) |

---

## Review Kaizen Sub B: Prosecution Adaptive Depth

**Issue**: #150 | **Depends on**: #141 (Persistent Review Calibration Data Storage), #97 (Cross-Session Learning Pipeline)

### Summary

Adjusts prosecution perspective depth per category based on calibration data (sustained finding rates), reducing review effort on categories that consistently produce low-value findings while maintaining full scrutiny where it matters. The 3-pass prosecution protocol remains fixed; what changes is the set of active perspectives within each pass.

### Decision Log

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D40 | Depth computation location | Inline in `aggregate-review-scores.ps1` | Script already computes per-category `sustain_rate` and `effective_count`; applying thresholds in the same loop gives a single source of truth and keeps the logic Pester-testable |
| D41 | Re-activation write path | Extend `write-calibration-entry.ps1` with `-ReactivationEventJson` | Reuses existing atomic write infrastructure (temp + rename); single file I/O path for `review-data.json`; consistent with #141 extensible design |
| D42 | Perspective exclusion mechanism | Explicit exclusion instruction appended to each Code-Critic pass prompt | No Code-Critic agent file changes needed; compatible with existing change-type classification (both filters apply independently) |
| D43 | Prosecution Depth Summary placement | Conversation brief + full table in PR body | Brief inline note ("Prosecution depth: N full, N light, N skip") for real-time awareness; full table in PR body for durable record |
| D44 | Override and config location | Top-level keys in `review-data.json` | `prosecution_depth_override` (optional string) and `time_decay_days` (optional int, default 90) as sibling keys to `entries`; consistent with #141 extensible design |
| D45 | PR counting for re-activation expiry | Max merged PR number from GitHub API | Aggregate script already fetches merged PRs; store `triggered_at_pr` and `expires_at_pr` (= triggered + 5); no new state required |
| D46 | Post-fix prosecution depth | Always full depth | Post-fix is diff-scoped and safety-critical; applying depth exclusions would undermine its purpose |
| D47 | CE/proxy prosecution category mapping | Code-Conductor infers category via keyword heuristics | CE/proxy findings use `category: n/a`; keyword mapping (e.g., "injection" → security, "N+1" → performance) is the least-overhead approach; ambiguous findings re-activate all potentially matching categories |
| D48 | Time-decay state tracking | `prosecution_depth_state` key in `review-data.json` | Aggregate script records `skip_first_observed_at` per category; clears on exit from skip; comparison against `time_decay_days` drives auto-restore |

### Prosecution Adaptive Depth

#### Depth Levels

| Depth | Behavior | Condition |
|-------|----------|-----------|
| `full` | Category included in all 3 passes | Default; or insufficient data; or re-activated |
| `light` | Category included in pass 1 only; excluded from passes 2–3 | `sustain_rate < 0.15` AND `effective_count ≥ 20` |
| `skip` | Category excluded from all 3 passes | `sustain_rate < 0.05` AND `effective_count ≥ 30` |

#### Threshold Priority Chain (7 Steps)

Applied per category, in order:

1. `prosecution_depth_override: "full"` in calibration file → force `full` for all categories
2. Active re-activation event (`expires_at_pr > maxMergedPrNumber`) → `full`, `re_activated: true`
3. Time-decay: category in `skip` for more than `time_decay_days` (default 90) → `light`, `re_activated: true`; write synthetic re-activation event expiring at `maxMergedPrNumber + 50`
4. `effective_count < 20` → `full` (insufficient data)
5. `sustain_rate < 0.05` AND `effective_count ≥ 30` → `skip`
6. `sustain_rate < 0.15` AND `effective_count ≥ 20` → `light`
7. Default → `full`

#### Re-Activation Triggers

A `light` or `skip` category reverts to `full` for the next 5 merged PRs when:

| Trigger source | Mechanism |
|---------------|-----------|
| `code_prosecution` | Sustained finding in that category during main review |
| `ce_prosecution` | CE Gate finding maps to that category (keyword heuristics) |
| `github_proxy` | Proxy prosecution finding maps to that category |
| `time_decay` | Automatic 50-PR window after `time_decay_days` elapsed in skip |

Re-activation events are written to `re_activation_events` in `review-data.json` via `write-calibration-entry.ps1 -ReactivationEventJson`.

### Implementation

#### Scripts

- **`aggregate-review-scores.ps1`**: Emits a `prosecution_depth:` YAML block (after `by_review_stage:`) with `override_active` flag and per-category fields (`recommendation`, `sustain_rate`, `effective_count`, `sufficient_data`, `re_activated`). Writes `prosecution_depth_state` and time-decay synthetic re-activation events to the calibration file when state changes (atomic write; only when calibration file exists).
- **`write-calibration-entry.ps1`**: Accepts optional `-ReactivationEventJson` parameter. Writes re-activation events to `re_activation_events` array with dedup by `category + triggered_at_pr`. `-EntryJson` and `-ReactivationEventJson` may be used together or independently (at least one required).

#### Code-Conductor Orchestration

**Prosecution Depth Setup** (runs before `### Critic Pass Protocol`):

1. Run `aggregate-review-scores.ps1`; capture `prosecution_depth:` section
2. Build depth map (category → `full`/`light`/`skip`); record for post-judgment use
3. Emit conversation brief: `"Prosecution depth: N full, N light, N skip"`
4. Compose per-pass exclusions: pass 1 excludes `skip`; passes 2–3 exclude `skip` AND `light`
5. Append exclusion section to each Code-Critic pass prompt
6. Safe fallback: script failure or YAML parse failure → all categories `full`

**Post-judgment re-activation detection**: After the judge pass, check each sustained finding's `category` against the recorded depth map; write a re-activation event for any finding whose category was `light` or `skip` (`trigger_source: code_prosecution`).

**CE/proxy re-activation**: Map `category: n/a` findings to prosecution categories via keyword heuristics; write re-activation events with `trigger_source: ce_prosecution` or `github_proxy`.

**Post-fix prosecution**: Always runs at full depth; exclusion instructions are never composed or applied.

### Transparency Artifacts

**Conversation brief** (emitted before prosecution starts):

```text
Prosecution depth: 5 full, 1 light, 1 skip
```

**PR body — Prosecution Depth Summary table**:

```markdown
## Prosecution Depth Summary

| Category | Depth | Rationale |
|----------|-------|-----------|
| architecture | full | — |
| security | light | sustain rate 0.12 / 22 effective findings |
| performance | full | — |
| pattern | skip | sustain rate 0.03 / 35 effective findings |
| implementation-clarity | full | — |
| script-automation | full | insufficient data (8 effective) |
| documentation-audit | full | — |
```

Re-activated categories show their `trigger_source` in the Rationale column.

**Pipeline metrics addition**:

```yaml
prosecution_depth_light: [security]
prosecution_depth_skip: [pattern]
prosecution_depth_override: false
prosecution_depth_reactivations: 0
```

### Calibration Data Schema (relevant keys)

```json
{
  "prosecution_depth_override": null,
  "time_decay_days": 90,
  "prosecution_depth_state": {
    "pattern": { "skip_first_observed_at": "2026-03-15T00:00:00Z" }
  },
  "re_activation_events": [
    {
      "category": "security",
      "triggered_at_pr": 85,
      "expires_at_pr": 90,
      "trigger_source": "ce_prosecution",
      "created_at": "2026-03-20T14:30:00Z"
    }
  ]
}
```

`trigger_source` allowed values: `code_prosecution | ce_prosecution | github_proxy | time_decay | manual_override`

> **Note**: `trigger_source` values are not runtime-validated by `write-calibration-entry.ps1`. All callers are responsible for emitting a canonical value. Test fixtures must use canonical values to avoid propagating stale names as documentation.

---

## Review Kaizen Sub C: Guardrail Proposal Pipeline & Kaizen Metric

**Issue**: #151 | **Parent**: #148 (Review Kaizen) | **Depends on**: #149 (Sub A), #150 (Sub B), #141 (calibration storage), #136 (upstream lifecycle)

### Summary

Extends `aggregate-review-scores.ps1` to aggregate sustained findings by `systemic_fix_type` × category, compute a kaizen effectiveness metric, and emit structured YAML for Process-Review §4.9 to interpret into concrete guardrail proposals. Adds cross-calibration deduplication to prevent re-emitting the same proposal in consecutive calibration runs.

### Decision Log

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D49 | Root cause analysis split | Script aggregates `systemic_fix_type` × category patterns; Process-Review §4.9 interprets into guardrail proposals | Script is good at counting (deterministic, Pester-testable); agent is good at reasoning (identifies specific guardrails by reading target files). Follows existing §4.7 pattern. |
| D50 | Aggregation threshold | ≥2 sustained findings with same `systemic_fix_type` × category across ≥2 PRs | Simple; matches prosecution_depth's hardcoded thresholds. Configurable later if needed. |
| D51 | Script output format | Inline `systemic_patterns:` section in existing YAML output (after `prosecution_depth:`), followed by `kaizen_metric:` | Single invocation; consistent with existing output; Process-Review already parses this output. |
| D52 | Kaizen metric location | Script computes and emits as `kaizen_metric:` in YAML output | Deterministic, Pester-testable; script already has prosecution_depth data (`categories_at_skip` / `categories_at_light`). |
| D53 | Upstream flow integration | §4.9 has own inline upstream mechanics (same patterns as §4.8, `[Systemic Fix]` format) | §4.8 (gotchas) runs only during full retrospective; root cause analysis runs during calibration (all modes). §4.9 must be self-contained. |
| D54 | Approval UX | Code-Conductor orchestrates proposal application through normal change flow | Process-Review is advisory only; Code-Conductor handles all change orchestration. User reviews proposals in calibration report, then applies via normal flow. |
| D-263-1 | §2d gate ordering | §2d consolidation check runs first (before calibration dedup and GitHub search) | safe-operations.instructions.md §2d contract mandates this order |
| D-263-2 | D10 ceiling advisory | Advisory only (included in issue body) rather than hard rejection | Matches D2/D8 convention — ceiling exceeding alone should not block proposals |
| D-263-3 | Consolidation-candidate action | Return `consolidation-candidate` to caller rather than auto-consolidating | Preserves §2d advisory character — semantic judgment belongs to Process-Review, not the script |
| D-263-4 | Classification heuristic | Keyword heuristic on `ProposedChange` text for agent-prompt level classification | More accurate than `PatternKey` alone; `ProposedChange` contains the specific guardrail description |
| D-263-5 | Result contract | Structured hashtable with 9 named fields | Enables programmatic handling of all action outcomes (created/skipped/consolidated/error) |
| D-263-6 | No dot-source of aggregate lib | CII-prefix copies of shared helpers | Prevents scope pollution across dot-sourced files in test and production contexts |
| D-263-7 | Field preservation | Unknown fields in `proposals_emitted` entries preserved during write-back | Forward compatibility for future schema additions |

### Script Extension: `systemic_patterns:` Output

New section emitted after `prosecution_depth:` in YAML output. Aggregates `systemic_fix_type` × category across local calibration findings with `judge_ruling: sustained` and `category ≠ n/a` (D49: accumulation is restricted to the local-calibration path; v2 PR-body and local-calibration paths union-merge as complementary data sources):

```yaml
  systemic_patterns:
    instruction:
      security:
        count: 3
        sustained_count: 2
        distinct_prs: 2
        meets_threshold: true
        evidence:
          - pr: 78, finding: F3
          - pr: 82, finding: F1
        previously_proposed: false
    skill:
      pattern:
        count: 2
        sustained_count: 2
        distinct_prs: 2
        meets_threshold: true
        evidence:
          - pr: 85, finding: F2
          - pr: 90, finding: F4
        previously_proposed: true
    agent-prompt: {}
    plan-template: {}
```

Threshold: `meets_threshold: true` when `sustained_count ≥ 2` AND `distinct_prs ≥ 2`. `category: n/a` findings are excluded (proxy/CE prosecution).

### Script Extension: `kaizen_metric:` Output

New section emitted after `systemic_patterns:` in YAML output:

```yaml
  kaizen_metric:
    categories_with_sufficient_data: 5
    categories_at_skip_depth: 1
    categories_at_light_depth: 1
    kaizen_rate: 0.40
    patterns_meeting_threshold: 3
    patterns_previously_proposed: 1
```

- `kaizen_rate` = (skip + light categories) / categories with sufficient data. 0.00 when no sufficient-data categories exist.
- Uses prosecution depth as a proxy for guardrail effectiveness — see Known Limitations.

### Cross-Calibration Deduplication: `proposals_emitted`

The aggregation script persists emitted proposals to prevent re-proposing the same pattern in consecutive calibration runs. Stored in the calibration JSON alongside `entries` and `prosecution_depth_state`:

```json
{
  "entries": [...],
  "proposals_emitted": [
    {
      "pattern_key": "instruction:security",
      "evidence_prs": [78, 82],
      "first_emitted_at": "2026-03-25T12:00:00Z"
    }
  ]
}
```

Pattern marked `previously_proposed: true` when `pattern_key` AND `evidence_prs` match an existing entry. New evidence PRs produce a non-match — generating a fresh proposal. Write-back uses the same atomic `tmp + validate + rename` pattern as `prosecution_depth_state`.

### Process-Review §4.9 Integration

§4.9 runs after §4.7 in all Process-Review calibration modes. For each pattern where `meets_threshold: true` and `previously_proposed: false`, §4.9:

1. Reads finding evidence from calibration data / PR bodies
2. Searches the target file by `systemic_fix_type` (instruction → `.github/instructions/`, skill → `.github/skills/`, agent-prompt → `.github/agents/`, plan-template → Issue-Planner plan style guide)
3. Drafts a specific proposed guardrail change

All proposals are advisory only — Code-Conductor applies approved proposals through normal change orchestration (Doc-Keeper for instructions/skills, Code-Smith for agent prompts).

### Upstream `[Systemic Fix]` Issue Format

When `systemic_fix_type` targets copilot-orchestra shared files, §4.9 creates an upstream issue after auth check and dedup search (`"[Systemic Fix] {category} [{systemic_fix_type}]" in:title`):

```markdown
Title: [Systemic Fix] {category} [{systemic_fix_type}]: {brief description}
Labels: enhancement, priority: medium

## Systemic Fix Proposal

- **Category**: {category}
- **Systemic fix type**: {systemic_fix_type}
- **Pattern**: {description of recurring defect pattern}
- **Target file**: {file in copilot-orchestra}
- **Proposed change**: {specific rule or strengthening}
- **Evidence**: {N} sustained findings across {N} PRs in downstream repo
- **Source**: Discovered via calibration analysis in {downstream-repo}
```

### Automated Issue Creation: `create-improvement-issue.ps1`

Dedicated script for creating `[Systemic Fix]` GitHub issues from Process-Review §4.9 root cause analysis output. Follows the `write-calibration-entry.ps1` pattern: a thin CLI wrapper at `.github/scripts/create-improvement-issue.ps1` delegates to `Invoke-CreateImprovementIssue` in `.github/scripts/lib/create-improvement-issue-core.ps1`.

#### Parameters

9 mandatory parameters (`-PatternKey`, `-EvidencePrs`, `-FirstEmittedAt`, `-FixTypeLevel`, `-TargetFile`, `-ProposedChange`, `-SystemicFixType`, `-Repo`, `-UpstreamPreflightPassed`) plus 6 optional (`-CalibrationPath`, `-ComplexityJsonPath`, `-GhCliPath` (default `'gh'`), `-FixTypeOverride`, `-Labels` (default `@('priority: medium')`), `-SkipConsolidation` — `[switch]` Bypasses Gate 1 (§2d consolidation check); used by Process-Review when re-invoking after semantic judgment).

#### Result Contract (D-263-5)

Returns a structured hashtable:

```powershell
@{
    ExitCode            = 0 | 1
    Action              = 'created' | 'skipped-dedup' | 'consolidation-candidate' | 'error'
    Output              = '...'
    Error               = $null | '...'
    IssueNumber         = $null | 42
    ConsolidationTarget = $null | 38              # int — issue number, or $null if no candidate found
    ClassifiedLevel     = $null | 4          # int — rule-table default for SystemicFixType
    SuggestedLevel      = $null | 1          # int — keyword-heuristic suggestion
    CeilingAdvisory     = $null | '...'
}
```

#### 7-Gate Pipeline

Gates execute in order; each gate can short-circuit with a non-`created` action:

1. **§2d consolidation-candidate check** — `Search-CIIConsolidationCandidate` queries open `[Systemic Fix]` issues via `gh issue list` (WITHOUT `--search`). Returns `consolidation-candidate` to caller for semantic judgment rather than auto-consolidating (D-263-3). Ordered first per safe-operations.instructions.md §2d contract (D-263-1).
2. **Calibration dedup** — `Test-CIIPatternKeyExists` checks `proposals_emitted` for matching `pattern_key` with a non-null `fix_issue_number` (presence-only check). If both match, returns skipped-dedup; if `fix_issue_number` is absent or null, proceeds to Gate 3 (backward compatibility for pre-linkage entries). Future enhancement: check whether the linked issue is closed and re-propose if so.
3. **GitHub search dedup** — `Search-CIIGitHubDedup` queries via `gh issue list` WITH `--search` for title-based dedup.
4. **D10 ceiling advisory** — `Get-CIICeilingAdvisory` reads pre-computed JSON from the `-ComplexityJsonPath` parameter (produced by §4.7 Step 0's `measure-guidance-complexity.ps1` invocation) and inspects `.agent.md` files at level ≥ 4. Advisory only — included in issue body but does not block creation (D-263-2).
5. **Classification** — `Get-CIIClassifiedLevel` applies a rule table mapping `SystemicFixType` to level, then a keyword heuristic on `ProposedChange` text for agent-prompt detection (D-263-4).
6. **Issue creation** — `gh issue create` via the injected `-GhCliPath`.
7. **Calibration linkage** — `Update-CIICalibrationLinkage` writes `fix_issue_number` back to `proposals_emitted` using atomic `tmp + validate + rename`. Unknown fields in pre-existing entries are preserved (D-263-7).

#### CII Helper Prefix Convention (D-263-6)

All private helpers use the `CII` prefix (e.g., `Get-CIIFlexProperty`, `Test-CIIPatternKeyExists`, `Search-CIIConsolidationCandidate`). Shared helpers like `Get-FlexProperty` are copied as CII-prefixed versions rather than dot-sourcing `aggregate-review-scores-core.ps1`, avoiding scope pollution across dot-sourced files.

#### `pattern_key` Delimiter Contract

`pattern_key` values use the format `{systemic_fix_type}:{category}` with a single `:` delimiter — produced by `aggregate-review-scores.ps1` (e.g., `instruction:security`) and consumed by `create-improvement-issue-core.ps1`. The consumer helper `Get-CIICategory` splits on the first `:` only (`-split ':', 2`) so that future extensions to either segment cannot break extraction. Producer and consumer must use single `:` as the delimiter.

#### Delegation Boundary

Process-Review §4.9 Step 4 delegates to `create-improvement-issue.ps1` rather than calling `gh issue create` directly. §4.9 constructs parameters from its root cause analysis output (Steps 1–3) and handles four action results:

- `consolidation-candidate` — semantic judgment (§4.9 decides whether to consolidate or create new)
- `skipped-dedup` — log only
- `created` — include issue URL in calibration report
- `error` — log and leave for retry

### Approval UX

1. Process-Review emits guardrail proposals in calibration report (advisory only)
2. User reviews proposals and directs Code-Conductor to apply accepted ones:
   - **< 1 day effort**: Address in current PR via Doc-Keeper / Code-Smith
   - **> 1 day effort**: Create follow-up GitHub issue via safe-operations
3. Upstream proposals (`upstream: true`): §4.9 creates issue directly; user can defer for manual transfer

### Known Limitations

- **Kaizen rate is a proxy**: Reduced prosecution depth correlates with (but is not identical to) "guardrails were applied." Explicit guardrail-application tracking and pre/post rate comparison are future enhancements.
- **No `guardrails_applied_total` tracking**: v1 uses depth-based proxy only.
- **Proposal actionability depends on LLM reasoning**: Advisory system; all threshold-met proposals require human review regardless of quality.

### Acceptance Criteria (from issue #151)

- `systemic_patterns:` section emitted after `prosecution_depth:` in script output
- `kaizen_metric:` section emitted after `systemic_patterns:`
- `category: n/a` findings excluded from systemic pattern aggregation
- `proposals_emitted` array written to calibration JSON for threshold-met proposals; preserved across runs
- Process-Review §4.9 added as documented — advisory only, 3-step guardrail identification, upstream `[Systemic Fix]` format
- Pester tests cover systemic pattern accumulation, kaizen metric computation, and `proposals_emitted` write-back

### Files Changed

| File | Change |
|------|--------|
| `.github/scripts/aggregate-review-scores.ps1` | Added `systemic_patterns:` and `kaizen_metric:` YAML output; `proposals_emitted` write-back; `Test-PatternProposed` helper |
| `.github/scripts/Tests/aggregate-review-scores.Tests.ps1` | 16 new Pester tests across 3 contexts (systemic patterns, kaizen metric, proposals write-back) |
| `.github/agents/Process-Review.agent.md` | Added §4.9 section; updated §4.7 integration note and subagent invocation note |
| `Documents/Design/code-review.md` | This section |
