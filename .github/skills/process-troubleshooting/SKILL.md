---
name: process-troubleshooting
description: Five-scenario workflow troubleshooting guide for diagnosing and fixing common orchestration failure patterns. Use when diagnosing premature implementation, agent confusion, validation gaps, documentation conflicts, or terminal stalls during a workflow session. DO NOT USE FOR: general code review (use code-review-intake), debugging application code (use systematic-debugging), or post-merge cleanup (use post-pr-review).
---

# Process Troubleshooting

Diagnostic workflows for common orchestration failure patterns.

## When to Use

- Code was created before tests existed
- Multiple agents handled the same phase or overlapping roles
- Quality gate failures were discovered late in the workflow
- Contradictory instructions are causing confusion
- An agent is blocked by a long-running or hung terminal command

## Scenario 1: Premature Implementation

**Symptoms**: Code created before tests, implementations in test-writer mode

**Analysis**:

- Check git log: Were `.ts` files created before `.test.ts` files?
- Review plan: Did phase headers show test-writer → code-smith order?
- Check conversation: Was TDD flow mentioned?

**Recommendations**:

- Add explicit RED state validation
- Strengthen test-writer → code-smith handoff
- Create TDD checklist for issue-planner

## Scenario 2: Agent Confusion

**Symptoms**: Multiple agents handling same phase, role overlap

**Analysis**:

- Review agent descriptions: Are boundaries clear?
- Check plan: Were agent assignments explicit?
- Examine handoffs: Were handoff buttons used?

**Recommendations**:

- Clarify agent responsibilities
- Add phase-to-agent mapping table
- Create decision tree for agent selection

## Scenario 3: Validation Gaps

**Symptoms**: Quality gate failures discovered late, rework needed

**Analysis**:

- Check when tests were run: After each task or only at end?
- Review phase completion: Were validation commands listed?
- Examine changes file: Were validation results recorded?

**Recommendations**:

- Add validation checklist to plan-tracking
- Require validation output in changes file
- Create pre-handoff validation step

## Scenario 4: Documentation Conflicts

**Symptoms**: Contradictory instructions, confusion about standards

**Analysis**:

- Search for duplicate topics in workspace docs: Use `grep_search` with query `subject` and `includePattern: "**/*.md"`. For session memory, use the `memory` tool (`view /memories/session/` then read individual files) to check for overlapping topics.
- Check file ages: Which is canonical?
- Review references: Which files link to which?

**Recommendations**:

- Consolidate redundant files
- Establish clear hierarchy (primary vs reference)
- Add cross-reference validation

## Scenario 5: Terminal Stall During Workflow

**Symptoms**: Agent appears blocked by long-running or hung terminal commands

**Analysis**:

- Check terminal history for repeated commands with no output progress
- Review whether timeout boundaries were set or adjusted
- Verify whether escalation happened after repeated stalls

**Recommendations**:

- Add timeout defaults and retry limits in workflow instructions
- Introduce a "stall triage" checklist before rerunning commands
- Require fallback path documentation when terminal automation is unavailable

## Gotchas

| Trigger | Gotcha | Fix |
| ------- | ------ | --- |
| Diagnosing premature implementation without checking git log dates | Incorrectly attributes cause to agent confusion rather than sequencing failure | Check `git log --diff-filter=A --name-only` to verify creation order |
| Treating contradictory instructions as a single-file problem | Root cause may span multiple agents and instruction files | Search workspace-wide before proposing consolidation |
| Fixing terminal stalls by rerunning the same command | Repeated retries accumulate output buffer and mask the underlying block | Switch to `isBackground: true` and check output with `get_terminal_output` |
| Assuming agent confusion caused a validation gap | May have been missing validation commands in the plan, not role overlap | Check the plan file: were validation steps present and ordered correctly? |
| Applying scenario fixes without updating the plan for next time | Same pattern recurs on next issue | Route systemic improvements to the plan template or instruction file via Process-Review |
