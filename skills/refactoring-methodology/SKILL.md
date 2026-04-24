---
name: refactoring-methodology
description: "Proactive refactoring workflow for touched files and nearby debt. Use when hunting extraction opportunities, evaluating duplication or oversized files, or improving structure without changing intended behavior. DO NOT USE FOR: adversarial defect review (use adversarial-review) or net-new feature implementation (use implementation-discipline)"
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes repository refactors are validated against existing tests and architecture rules. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Refactoring Methodology

Reusable methodology for behavior-preserving structural improvement.

## When to Use

- When recently modified files need a proactive refactoring pass
- When duplication, oversized functions, or structural debt may have been introduced or exposed
- When integration gaps or symmetric mechanical fixes should be checked while the relevant code is already open
- When refactoring decisions need a repeatable analysis and verification flow

## Purpose

Find real maintainability improvements in touched code without widening into speculative rewrites. Refactoring here is an active search for cleaner structure, not a passive approval pass.

## Analysis Workflow

1. Inspect every file modified by the current change unless the plan explicitly marks it out of scope.
2. Check file size, function size, duplication, conditional complexity, and extraction opportunities.
3. Inspect immediate neighbors when the touched file clearly participates in a broader repeated pattern.
4. Check for unused added data or unwired integration points and treat them as incomplete work, not future debt.
5. Before closing, grep for symmetric occurrences when the fix pattern is mechanical and repo-wide.
6. Validate that the refactor preserved behavior and respected project architecture rules.

## Mandatory Checks

### Size And Structure

- Check line count for each modified file
- Flag files above 80% of the configured limit
- Treat functions above roughly 50 lines as extraction candidates
- Split responsibilities when a class or file is becoming multipurpose

### Duplication And Readability

- Extract repeated blocks or repeated control-flow fragments
- Replace copied formulas or validations with delegation to one source of truth
- Rename unclear variables and replace magic numbers with named constants
- Simplify long expressions or nested conditionals when comprehension is suffering

### Testability And Architecture

- Prefer extracting private logic into testable units when behavior stays covered
- Inject dependencies instead of copying behavior into new classes or helpers
- Review layer placement and composition using `software-architecture` before significant extraction

## Integration Gap Rule

If the change adds data, metadata, or configuration that is not consumed where the feature requires it, treat that as incomplete implementation. Fix it now when the integration is local and bounded; only defer when the remaining work truly requires a larger design decision.

## Proactive Hunting Stance

Do not rubber-stamp a touched file as "fine" without inspection.

- Presume the touched code is improvable until checked.
- Hunt for duplication, unclear naming, oversized units, and awkward control flow.
- Apply the Boy Scout Rule within the touched area and its immediate neighbors.
- If no improvements are needed, state what you checked and why.

Success means finding proportionate maintainability improvements when they exist, not refactoring for its own sake.

## Integration Gaps Are Not Tech Debt

If a PR adds data that is not consumed where the feature requires it, treat that as incomplete implementation, not future cleanup.

Examples:

- `supportedRegions` is added but consumers do not filter by it
- `TIER_MULTIPLIERS` exists but the pricing path does not apply it
- priority metadata is added but the scheduler ignores it
- one map gains new entries while symmetric related maps do not

When you find unused new data:

1. Identify where it should be used.
2. Estimate the integration effort.
3. If the fix is local and bounded, include it now.
4. If it is genuinely larger, document why it is large rather than calling it generic tech debt.

## Output Structure

Use a concise analysis with these sections when reporting refactor work:

- `## Refactoring Analysis`
- `### Files Analyzed`
- `### Opportunities Found`
- `### Actions Taken`
- `### Deferred (Out of Scope)`
- `### Verification`

## Verification

- Run the project-configured validation and test commands after refactoring
- Confirm coverage expectations still hold for the affected behavior
- Re-check the modified files for any remaining symmetric mechanical misses

## Conductor Integration

In Code-Conductor workflows, **ALWAYS call Refactor-Specialist after Code-Smith completes.**

Refactor-Specialist will:

1. Analyze all files modified in the PR
2. Hunt proactively for improvement opportunities
3. Report findings (even if no action taken)
4. Make improvements where beneficial

**There is no "skip refactoring" option.** The Refactor-Specialist decides what needs improvement, not the plan or Code-Conductor.

**Flow**: Code-Smith -> Refactor-Specialist -> Code-Critic

**Clarification**: "Avoid broad rewrites" does NOT mean "skip refactoring" - it means keep refactoring proportionate to the PR's intent.

**Proportionate refactoring (good)** means improving code you already touched (or its immediate neighbors) to reduce complexity/duplication without expanding the PR's goal. Examples:

- Extract a small helper / function when the change introduced duplication in the same file
- Rename a confusing local symbol or tighten types in the files already modified
- Simplify a conditional / remove dead code encountered while making the change
- Consolidate duplicated logic within the touched module(s) when it reduces future churn

**Broad rewrite (avoid)** includes scope that changes the "shape" of the system beyond what the PR set out to do, such as:

- Large file moves/renames or sweeping formatting churn across many files
- Sweeping API changes (especially public/shared interfaces) just to "clean things up"
- Re-architecting multiple systems/modules as part of a small feature/bugfix
- Wide refactors that require updating many call sites unrelated to the original change

**Decision rule (guardrail)**: If refactoring would expand beyond the PR's change intent (e.g., many unrelated files, new cross-cutting abstractions, or broad API changes), pause and escalate via `#tool:vscode/askQuestions` with options (including capturing as a `tech-debt` issue for a separate, dedicated PR) and a recommended choice.

## Related Guidance

- Load `software-architecture` before extractions or structural splits
- Load `systematic-debugging` when a refactor exposes a failing behavior and the root cause is unclear

## Gotchas

| Trigger                                        | Gotcha                                                                   | Fix                                                                   |
| ---------------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| Saying "no refactor needed" after a quick skim | Obvious extractions and duplication survive because analysis was shallow | Check file size, duplication, and function complexity before deciding |

| Trigger                                   | Gotcha                                                    | Fix                                                                  |
| ----------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------- |
| Treating unused new data as later cleanup | The PR ships an incomplete feature under a refactor label | Identify the missing integration point and fix it in the same change |
