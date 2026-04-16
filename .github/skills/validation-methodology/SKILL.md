---
name: validation-methodology
description: Reusable validation and review methodology for staged validation, failure triage, and prosecution-depth setup. Use when running validation ladders, triaging failures, or executing adversarial review passes. DO NOT USE FOR: CE Gate orchestration, specialist dispatch ownership, or step execution flow (keep those in Code-Conductor).
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; assumes the owning agent already controls routing, step order, and specialist handoffs. -->

# Validation Methodology

Reusable validation and review methodology for agents that need a staged validation ladder and evidence-based adversarial review mechanics without taking ownership of orchestration boundaries.

## When to Use

- When an agent needs a graduated validation sequence from cheap automated checks to independent review
- When validation failures need a consistent triage rule before re-delegation
- When a review cycle needs prosecution-depth setup, multi-pass review mechanics, and deduplication rules
- When an agent needs reusable review heuristics but must keep specialist routing and CE Gate ownership in the agent

## Purpose

Run validation in increasing-cost tiers, classify failures before rework, and drive review reconciliation with consistent prosecution-depth setup and fixed multi-pass mechanics. The owning agent still decides who speaks next, when CE Gate runs, and how accepted fixes are routed.

## Validation Ladder

Validation runs in this graduated 4-tier order:

1. **Tier 1 — Build & Validate**: run quick-validate commands, lint/typecheck, and the full test suite together when practical so all failures are visible before fixing. Prefer lint/typecheck before tests when the project supports it. For migration-type issues, also run the migration completeness scan required by the owning workflow. Projects with slow test suites can override in `copilot-instructions.md` by adding `<!-- slow-test-suite: true -->`, which splits Tier 1 into: (a) quick-validate, lint/typecheck, and targeted tests, then (b) the full test suite.
2. **Tier 2 — Structural validation**: run project architecture or structural validation commands defined by the repository.
3. **Tier 3 — Strength validation**: run configured coverage, robustness, or deeper confidence checks defined by the repository.
4. **Tier 4 — Independent review lane**: run the adversarial review cycle after the lower tiers pass. The owning agent keeps any CE Gate orchestration, post-fix routing, and specialist-dispatch authority that follows this tier.

Do not skip ahead when an earlier tier fails. Resolve failures at the current tier before advancing.

## Failure Triage Rule

When a validation tier fails, classify first, then route:

- `code defect` → route to the implementation specialist with failing evidence
- `test defect` → route to the testing specialist with failure analysis
- `harness/env defect` → route to the responsible tooling or environment path
- `rc-divergence` → run one dedicated correction cycle outside the main convergence budget: dispatch implementation first with the divergent acceptance-criteria items, re-run Tier 1, re-evaluate all acceptance-criteria items, then dispatch testing only if divergence persists and the assertions must be re-derived from the Requirement Contract rather than the corrected implementation

Always include the failure evidence, attempted diagnosis, and the next action in the handoff prompt. Avoid blind retries.

## Review Reconciliation Method

Use this method for code-review phases where independent prosecution, defense, and judgment need to converge on an evidence-based outcome.

### Pre-Review Gate

Before calling the prosecutor, run the repository validation commands that clear trivial lint, typecheck, or harness failures. The review cycle should spend its budget on substantive defects, not on already-known validation noise.

### Prosecution Depth Setup

Before composing pass prompts:

1. Run `.github/scripts/aggregate-review-scores.ps1` and capture `prosecution_depth:` output.
2. Parse the per-category recommendations into a depth map (`category` → `full` / `light` / `skip`).
3. Check `override_active:`. If it is `true`, force all categories to `full` and skip further depth logic.
4. Record the depth map for later re-activation checks.
5. Log a brief summary: `Prosecution depth: N full, N light, N skip`.
6. Compose per-pass exclusions:
   - Pass 1 excludes `skip` categories.
   - Passes 2 and 3 exclude both `skip` and `light` categories.
7. Safe fallback: if the aggregate script fails, YAML parsing fails, or the `prosecution_depth:` block is absent from parsed output, treat all categories as `full` and log `Prosecution depth: all full (fallback — {reason})`.

Append this exclusion block to each prosecution pass prompt:

```text
**Prosecution Depth Exclusions (pass {N} of 3)**:
The following categories have been excluded from this pass based on calibration data.
Do NOT generate findings in these categories — they will be discarded.
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

Include this line in each pass prompt: `Change type: {classification}. Per Code-Critic's 'When to apply' gates, mark out-of-scope perspectives as ⏭️ N/A — do not expand them.`

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

If the owning agent supports an express lane for strictly mechanical low-severity findings, partition those findings only after the merged prosecution ledger is available. The owning agent still owns whether express lane exists and how routed findings are dispatched.

### Reusable Review Heuristics

- Complete the full prosecution to defense to judgment cycle before fix routing.
- Avoid blind retries; carry forward the failure evidence and current hypothesis with each re-delegation.
- Preserve the change-type classification and any prosecution-depth exclusions in every prosecution prompt.
- Keep merged-ledger deduplication evidence-based: same evidence at the same file and line collapses; materially different evidence remains additive.

## Boundaries

This skill does not decide:

- which agent speaks next
- when a step begins or ends
- how accepted findings are routed to specialists
- whether express-lane routing is available or how it dispatches
- when CE Gate orchestration or PR creation runs
- when review-mode entry, post-fix prosecution entry, or post-judgment follow-up occurs
- whether durable handoff state is written
- whether calibration or other write-back side effects occur

Keep those decisions in the owning agent.

## Gotchas

| Trigger                                                                                | Gotcha                                                                                                | Fix                                                                                                                                                                    |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Copying specialist routing, CE Gate ownership, or step-order decisions into this skill | The skill stops being reusable methodology and starts stealing orchestration authority from the agent | Keep routing, step execution flow, durable handoff ownership, and CE Gate orchestration in the owning agent; move only reusable validation and review method text here |
