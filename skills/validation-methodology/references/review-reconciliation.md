# Review Reconciliation Method

This reference owns the reusable review-reconciliation mechanics extracted from Code-Conductor.

See [post-judgment-routing.md](post-judgment-routing.md) for the paired post-judgment re-activation summary and routing index, [review-state-persistence.md](review-state-persistence.md) for the pre-PR review-state contract, and [../../code-review-intake/references/express-lane.md](../../code-review-intake/references/express-lane.md) for the canonical R6 express-lane gate.

## Review Reconciliation Loop

Use the `validation-methodology` skill (`skills/validation-methodology/SKILL.md`) for the reusable review-reconciliation method: pre-review gate, prosecution-depth setup, change-type classification, fixed 3-pass critic mechanics, defense and judgment sequencing, prosecution-depth exclusions, and merged-ledger deduplication rules.

### Pre-Review Gate

Before calling the prosecutor, run the repository validation commands that clear trivial lint, typecheck, or harness failures. The review cycle should spend its budget on substantive defects, not on already-known validation noise.

### Prosecution Depth Setup

Before composing pass prompts:

1. Run `skills/calibration-pipeline/scripts/aggregate-review-scores.ps1` and capture `prosecution_depth:` output.
2. Parse the per-category recommendations into a depth map (`category` -> `full` / `light` / `skip`).
3. Check `override_active:`. If it is `true`, force all categories to `full` and skip further depth logic.
4. Record the depth map for later re-activation checks.
5. Log a brief summary: `Prosecution depth: N full, N light, N skip`.
6. Compose per-pass exclusions:
   - Pass 1 excludes `skip` categories.
   - Passes 2 and 3 exclude both `skip` and `light` categories.
7. Safe fallback: if the aggregate script fails, YAML parsing fails, or the `prosecution_depth:` block is absent from parsed output, treat all categories as `full` and log `Prosecution depth: all full (fallback - {reason})`.

Append this exclusion block to each prosecution pass prompt:

```text
**Prosecution Depth Exclusions (pass {N} of 3)**:
The following categories have been excluded from this pass based on calibration data.
Do NOT generate findings in these categories - they will be discarded.
Excluded: {comma-separated list of excluded categories, or "none"}
```

**Post-fix prosecution exception**: post-fix prosecution always runs at full depth for all categories. Do not compose or apply prosecution-depth exclusions for post-fix passes.

### Critic Pass Protocol

Run exactly 3 independent prosecution passes per review cycle. The pass count is fixed.

- Each pass is an independent invocation, not a duplicate of prior output.
- Coverage variance is expected; separate passes are intended to surface complementary findings.
- Do not skip later passes because an earlier pass already found issues.
- Do not merge the passes into one invocation.

#### Change-Type Classification

Before composing pass prompts, classify the PR change type using `git diff --name-only main..HEAD` and include the classification in each pass prompt:

| Change type          | Condition                                                                     | Active perspectives                                                                                                                                                    |
| -------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `documentation-only` | All changed files are `.md`, `.instructions.md`, `.prompt.md`, or `.agent.md` | Architecture docs-misrepresentation only, Implementation Clarity, Script & Automation doc-audit when shell blocks are present, and the doc-clarity portion of Patterns |
| `mixed`              | Changed files include both source/scripts and docs                            | All perspectives                                                                                                                                                       |
| `code`               | Changed files include source code, scripts, or runtime config                 | All perspectives                                                                                                                                                       |

Evaluate the rows in order. `mixed` takes priority over `code` for source-plus-doc changes.

Include this line in each pass prompt: `Change type: {classification}. Per Code-Critic's 'When to apply' gates, mark out-of-scope perspectives as ⏭️ N/A - do not expand them.`

For `documentation-only` reviews, include only the changed files in the reading list, except for any standing repository rule that always requires an architecture-rules check.

#### Pass Execution And Merge Rules

- Launch all 3 passes in parallel as independent review calls.
- Label each call as adversarial review pass `N of 3` and require `pass: N` tags in the automation-routing fields.
- Merge the findings into one ledger after all passes complete.
- Deduplicate only when two passes report identical evidence at the same file and line.
- Treat different framings of the same evidence as one finding.
- Treat complementary findings from different passes as additive.
- Preserve all `pass: N` tags in the merged ledger.
- When findings are deduplicated, credit the earliest pass.

### Defense And Judgment

After the merged ledger is finalized:

1. Run exactly 1 defense pass against the merged prosecution ledger.
2. Run exactly 1 judge pass against the merged prosecution ledger and defense output.
3. Do not implement accepted fixes until the prosecution, defense, and judgment sequence completes.

If the owning agent supports an express lane for strictly mechanical low-severity findings, partition those findings only after the merged prosecution ledger is available. The owning agent still owns whether express lane exists and how routed findings are dispatched. See [../../code-review-intake/references/express-lane.md](../../code-review-intake/references/express-lane.md).

### Review Completion Gate

Fire this gate immediately before PR creation and on any post-review resume path that intends to continue toward PR creation.

> **Survival**: `SMC-05` covers the pre-PR `/memories/session/review-state-{ID}.md` lookup as `within-worktree` state. `SMC-06` covers post-PR resume as `durable` review comment or PR-body metrics first, with session memory last.

- Pre-PR lookup reads `/memories/session/review-state-{ID}.md` only.
- Post-PR resume lookup may read, in order: the durable review comment, `<!-- pipeline-metrics -->`, then session memory.
- The caller owns criteria construction for `Test-GateCriteria -Gate review_completion`. Build `Criteria` from the three stage booleans only. `review_mode` is label-only metadata and is not part of the criteria.
- The caller also owns the missing-stage list. Build it from the `false` stage booleans in stage order: prosecution, defense, judgment.
- On failure, emit the exact string `❌ Review pipeline incomplete — {missing stages}`.
- Default recovery is automatic re-entry into the missing stage or stages. Use `askQuestions` only when automatic re-entry is infeasible because required context, ledgers, or user-choice input is missing.

### GitHub Review Intake & Judgment

For `github review` / `review github` / `cr review`, follow `skills/code-review-intake/SKILL.md`. GitHub intake uses proxy prosecution: Code-Critic validates and scores each GitHub comment, then defense -> judge pipeline runs as normal.

### Non-GitHub Review Mode

For local/internal reviews, run the same pipeline: 3 prosecution passes (parallel) -> merge ledger -> 1 defense pass -> 1 judge pass (Code-Review-Response).

#### Short-Trigger Routing

If the user gives `github review` / `review github` / `cr review`, run GitHub intake first (resolve PR from active context when omitted), then route into the same Review Reconciliation Loop.

### Improvement-First Decision Rule (Mandatory)

During judgment and execution planning:

- If a proposed change is a clear improvement, do it.
- If improvement is uncertain or the change is not an improvement, reject it.
- Out-of-scope/non-blocking improvements should still be done when small.
- If an out-of-scope/non-blocking improvement is significant (>1 day), create a follow-up issue automatically and continue with in-scope fixes.

### Post-Judgment Fix Routing

After Code-Review-Response emits the judgment and score summary, route accepted fixes per the following rules:

#### AC Cross-Check Gate

Before treating any DEFERRED-SIGNIFICANT or REJECT categorization as final, read the parent issue's acceptance criteria (`gh issue view {N} --json body`). If no parent issue exists (e.g., standalone GitHub review PR), skip this gate. If the finding relates to an explicit AC item, reclassify as ✅ ACCEPT regardless of effort estimate. Acceptance criteria violations cannot be deferred or rejected - they are incomplete features.

#### Effort Estimation Checklist (Cross-Reference)

Default to <1 day. Only defer if ALL of these apply: 5+ files, new subsystem design, unknown patterns, non-incremental testing. Quick checklist - any of these alone means <1 day: adding data to existing maps/constants, integrating data added in this PR, adding a field + consumers, modifying 1-3 functions in 1-3 files, adding validation/filtering, fixing a single-system design flaw. (Authoritative source: Code-Review-Response Effort Estimation section.)

#### Auto-Tracking

For DEFERRED-SIGNIFICANT items, create a GitHub tracking issue automatically - no user approval required. Include PR link, review comment reference, and acceptance target in the issue body.

Before creating the tracking issue, apply the prevention-analysis advisory from `skills/safe-operations/SKILL.md` §2d.

#### Batch Specialist Dispatch (R4)

Before dispatching any findings to specialists, complete **all** routing decisions first (express-lane partition from the prosecutor pass + judge rulings). Then dispatch in a single batch per specialist agent:

1. **Collect**: Gather all accepted findings into two queues - express-lane findings (partitioned before defense) and judge-accepted findings (from Code-Review-Response ruling). Do not dispatch either queue until both are finalized.
2. **Group by agent**: Using the Agent Selection table, map each finding to its specialist. Group all findings for the same agent into one list.
3. **Dispatch**: Make one `runSubagent` call per unique specialist agent, passing all that agent's findings together. Order findings within each call by finding ID (ascending). Each finding must be individually described with its evidence, file reference, and line reference in the prompt - do not summarize or merge finding descriptions.
4. **Exception**: If two findings for the same agent require contradictory fix approaches (e.g., one requires adding a guard clause, another requires removing the same guard), split them into separate calls and document the rationale.

This replaces the default pattern of one call per finding.

#### GitHub Response Posting

When the review originated from GitHub (proxy prosecution pipeline), Code-Conductor posts concise responses to GitHub review comments with final disposition and score evidence after routing accepted fixes to specialists.

### Post-Fix Targeted Prosecution Pass

**Recursion guard**: This step is never triggered by another post-fix prosecution - only by a main review cycle (code review or GitHub intake proxy prosecution). It applies after both: the main 3-pass code review fix routing and GitHub review accepted-fix routing (proxy prosecution path). This is an absolute rule, not an edge case.

**When to run** - Mandatory when any of the following apply after all specialists apply all accepted main-review findings:

Load `skills/routing-tables/SKILL.md` and use `Test-GateCriteria -Gate post_fix_trigger -Criteria @{ ... }` against the canonical trigger conditions in `skills/routing-tables/assets/gate-criteria.json`. Preserve the same OR semantics: accepted `critical` or `high` findings can trigger immediately from the main-review judge output, while control-flow-trigger evaluation still happens only after Tier 1 re-validation and diff scoping.

Skip if no findings were accepted and applied (post-judgment: all REJECT or DEFERRED-SIGNIFICANT, no fixes applied).

**Evaluation ordering**: Condition 1 (severity) is evaluable immediately from the main-review judge output. Condition 2 (control flow) requires the fix diff and is evaluated after Diff scoping below - if condition 1 does not trigger alone, proceed through Tier 1 re-validation and Diff scoping before making the final skip decision.

**Tier 1 re-validation** - After specialists apply fixes, re-run Tier 1 validation (build + lint/typecheck + tests). If Tier 1 fails, route the failure via the Failure Triage Rule and resolve it before proceeding.

**Diff scoping prerequisite** - Before running the diff recipe, verify the git state: the original implementation MUST be committed (verify with `get_changed_files` (filter `sourceControlState: ['staged', 'unstaged']`) - only specialist fix files should appear as modified). When `auto_commit_enabled` is `true` and all step commits succeeded (no steps annotated `(uncommitted)`), step commits satisfy this prerequisite automatically - skip the manual-commit instruction. When `auto_commit_enabled` is `true` but uncommitted implementation changes are present (steps annotated `(uncommitted)` that were not resolved by D13 reconciliation), treat as the `false` case - instruct the user to commit before proceeding. When `auto_commit_enabled` is `false` (opt-out) and uncommitted implementation changes are present, instruct the user to commit them before proceeding.

**Diff scoping** - After Tier 1 passes and the prerequisite is verified, compute the fix diff: `git diff HEAD -- {files touched by specialists}` (ref-specific file-scoped diff - get_changed_files cannot target specific files or provide diff hunks) isolates the review-fix changes (HEAD points to the pre-fix commit; only uncommitted specialist fix changes are captured). Pass those files and hunks in each prosecution prompt. Code-Critic runs in normal code prosecution mode (no marker) with the constrained input. Include the original PR change-type classification in each post-fix prosecution prompt (same requirement as main review pass prompts).

**Prosecution scope constraint** - Post-fix prosecution evaluates fix-introduced regressions and direct side effects only. Findings unrelated to the fix diff changes (pre-existing style issues, optimization opportunities in untouched code, general code quality concerns in surrounding area) must be classified as DEFERRED-SIGNIFICANT regardless of severity. The out-of-diff AC exception is preserved: if a finding outside the diff maps to an explicit acceptance criterion item, the AC Cross-Check Gate applies.

**Pipeline (R2)** - 1 prosecution pass (diff-scoped). If pass 1 produces >=1 finding, run 1 conditional follow-up pass. Merge the 1-or-2-pass results into a deduplicated ledger -> 1 defense pass -> 1 judge pass (Code-Review-Response). If pass 1 finds nothing, post-fix review is complete - skip defense, judge, and routing, and proceed directly to the CE Gate. Express lane (R6) applies to post-fix prosecution findings after the 1-or-2-pass merge.

**Routing** - Route accepted findings to specialists per the Agent Selection table. Loop budget: 1 fix-revalidate cycle. If further issues remain after one cycle, they converge through the standard terminal state (DEFERRED-SIGNIFICANT -> auto-tracking issue). If the post-fix judge accepts zero findings (all DEFERRED-SIGNIFICANT or REJECTED), no specialist routing occurs; proceed directly to the CE Gate.

**Out-of-diff findings** - If prosecution surfaces a finding outside the fix diff, classify as DEFERRED-SIGNIFICANT (auto-tracking applies). Exception: if the finding maps to an explicit acceptance criterion item, the AC Cross-Check Gate takes precedence - reclassify as ACCEPT and route to the appropriate specialist.

**Interruption budget** - Post-fix review is a separate review cycle with its own budget (max 1 non-blocking decision prompt).

**PR body** - Include a "Post-fix Review" row in the Adversarial Review Scores table (`⏭️ N/A` if not triggered). Record `postfix_triggered` in Pipeline Metrics.

**Completion** - After routing completes, or the post-fix judge accepts zero findings (no routing occurred), or the overall skip rule applies - proceed to the CE Gate (see Customer Experience Gate section).

## Reusable Review Heuristics

- Complete the full prosecution to defense to judgment cycle before fix routing.
- Avoid blind retries; carry forward the failure evidence and current hypothesis with each re-delegation.
- Preserve the change-type classification and any prosecution-depth exclusions in every prosecution prompt.
- Keep merged-ledger deduplication evidence-based: same evidence at the same file and line collapses; materially different evidence remains additive.
