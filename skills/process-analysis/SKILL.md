---

name: process-analysis
description: "Reusable retrospective and process-analysis methodology for workflow reviews. Use when analyzing execution timelines, plan adherence, documentation conflicts, workflow efficiency, or skill-usage gaps after work completes. DO NOT USE FOR: CE Gate Track 2 defect triage format that is contract-owned by Process-Review.agent.md, or live implementation debugging before root-cause evidence exists (use systematic-debugging)"
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes retrospective evidence can be gathered from repo history, session artifacts, and validation output. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Process Analysis

Reusable methodology for retrospective workflow reviews and continuous process improvement.

## When to Use

- After completing a feature or PR and reviewing how the workflow executed
- When the workflow feels inefficient, confusing, or interruption-heavy
- Before starting complex multi-phase work and validating that the process guidance still fits
- During periodic health checks across multiple completed PRs or review cycles
- When auditing whether the right skills, routing choices, and guardrails were used

## Purpose

Analyze how the workflow executed, not just what was built. Gather evidence, compare intended versus actual execution, identify the root cause of process defects, and produce actionable recommendations that improve future runs.

## Analysis Workflow

### 1. Execution Timeline Review

Gather enough evidence to reconstruct the order of work:

```powershell
# Review recent commits and their sequence
git log --oneline --decorate -20  # history — no built-in tool equivalent

# Check current branch changes
git diff main...HEAD --stat  # cross-branch diff — no built-in tool equivalent

# Review file modification times
Get-ChildItem -Recurse -File | Where-Object {$_.LastWriteTime -gt (Get-Date).AddDays(-7)} | Sort-Object LastWriteTime  # file modification timestamps — no built-in tool equivalent
```

Analyze:

- Chronological order of file changes
- Frequency of agent switches
- Time between test creation and implementation
- Validation command execution timing

### 2. Plan Adherence Check

Compare:

- Plan tasks versus actual commits and artifacts
- Intended phases versus actual execution order
- Agent assignments versus conversation history
- Success criteria versus final validation evidence

Questions:

- Were phases completed in order?
- Did the correct agents handle each phase?
- Were validation commands run at the intended boundaries?
- Were quality gates met before the workflow advanced?

### 3. Documentation Consistency Audit

Scan for:

- Use `grep_search` with query `plan-tracking` and `includePattern: "**/*.md"` to find references to plan-tracking concepts
- Use `grep_search` with query `implementation-workflow` to find implementation-workflow references
- Use `grep_search` with query `OBSOLETE|DEPRECATED` (set `isRegexp: true`) and `includePattern: "**/*.md"` to identify stale content markers

Verify:

- Agent cross-references are valid
- Instructions do not conflict
- Templates match actual usage patterns
- Examples are current and accurate

### 4. Workflow Efficiency Assessment

Metrics:

- **Handoff Count**: fewer handoffs with clear purpose is better
- **Rework Cycles**: rework indicates process gaps
- **Validation Failures**: late failures indicate missing gates
- **Documentation Lookups**: excessive lookup suggests unclear guidance
- **Prompt Frequency**: count of decision prompts per PR or review cycle
- **Prompt Timing**: proportion of prompts occurring late-stage versus early-stage
- **Escalation Packet Completeness**: proportion including summary, evidence, impact, acceptance criteria, scope, and a recommendation
- **Adversarial Pipeline Completion**: prosecution, defense, and judge stages completed per review cycle

Scoring, on a 0-10 scale:

- **Adherence**: how well the plan was followed
- **Efficiency**: how streamlined the workflow was
- **Quality**: whether standards were maintained throughout
- **Clarity**: whether roles and responsibilities were clear

### 5. Terminal Stall Audit

Purpose: detect command stalls, waiting loops, and missing timeout or escalation handling that slow workflow execution.

Review:

- Terminal commands that ran without meaningful output for extended periods
- Repeated retries of the same command without a new hypothesis
- Missing timeout boundaries for long-running checks
- Delayed escalation when commands blocked progress

Evidence sources:

- Terminal transcript timestamps and last-command history
- Command duration patterns across similar tasks
- Notes in changes or review files indicating blocked execution

Recommendations:

- Add explicit timeout and retry guidance to process instructions
- Define escalation points when a command exceeds expected runtime
- Require brief stall notes in process artifacts for future diagnosis

### 6. Root Cause Analysis

For each deviation, ask:

1. What happened?
2. Why did it happen?
3. Was guidance clear?
4. Was guidance followed?
5. How can recurrence be prevented?

Common root causes:

- Unclear agent boundaries
- Missing validation checkpoints
- Conflicting instructions
- Incomplete examples or templates
- Role confusion between coordination and implementation

### 7. Report Construction

Use a concise structure that keeps findings actionable:

- **Executive Summary**: period analyzed, overall assessment, key finding, priority recommendation
- **Deviations Detected**: category, evidence, impact, severity
- **Workflow Efficiency Metrics**: adherence, efficiency, quality, clarity, overall health
- **Documentation Issues**: conflicts, orphaned files, guidance gaps, broken references
- **Improvement Recommendations**: high, medium, and low priority changes
- **Action Items**: concrete follow-up tasks with target files or workflow boundaries

### 8. Scenario Routing

For detailed scenario analysis, load `process-troubleshooting`.

Symptom-keyword routing:

- **Code before tests, implementations in test-writer mode** -> Premature Implementation
- **Multiple agents handling the same phase, role overlap** -> Agent Confusion
- **Quality gate failures discovered late, rework needed** -> Validation Gaps
- **Contradictory instructions or unclear standards** -> Documentation Conflicts
- **Agent blocked by long-running or hung terminal commands** -> Terminal Stall

### 9. Skill Usage Audit

When reviewing a completed workflow, audit whether applicable skills were actually invoked.

Checklist:

1. List the agents called during the workflow.
2. List the skills explicitly mentioned in delegation prompts or local instructions.
3. Compare that set with the skills that should have applied to each phase.
4. Record any gaps where a useful skill was available but not instructed.

Skill mapping reference:

| Skill                            | When Applicable                                                                                       |
| -------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `brainstorming`                  | Exploring features, unclear requirements, or design trade-offs                                        |
| `browser-canvas-testing`         | Canvas element interaction, game objects, clickElement failures                                       |
| `code-review-intake`             | GitHub review comments, Code-Critic reconciliation, intake mode                                       |
| `frontend-design`                | Designing UI components, screens, or evaluating distinctiveness                                       |
| `parallel-execution`             | Coordinating parallel implementation lanes, convergence gates                                         |
| `post-pr-review`                 | Post-merge cleanup, tracking archival, docs, strategic assessment                                     |
| `process-troubleshooting`        | Diagnosing premature implementation, agent confusion, validation gaps, doc conflicts, terminal stalls |
| `property-based-testing`         | Randomized testing, input ranges, invariant verification                                              |
| `skill-creator`                  | Adding new skills, updating templates, reviewing skill structure                                      |
| `software-architecture`          | Layer boundaries, dependency flow, ADR-level decisions                                                |
| `systematic-debugging`           | Debugging failures, flaky tests, tracking root causes                                                 |
| `test-driven-development`        | Writing tests first, red-green-refactor, quality gates                                                |
| `ui-testing`                     | Component-level React tests, flaky test fixes, React patterns                                         |
| `verification-before-completion` | Before PRs, releases, or any completion declaration                                                   |
| `webapp-testing`                 | Browser-based E2E coverage, test stability, CI execution                                              |

Output format:

```markdown
## Skill Usage Audit

| Phase | Agent          | Skills Instructed         | Should Have Used          | Gap? |
| ----- | -------------- | ------------------------- | ------------------------- | ---- |
| 1     | Research-Agent | None                      | `brainstorming`           | ⚠️   |
| 2     | Test-Writer    | `test-driven-development` | `test-driven-development` | ✅   |
```

### 10. Integration Timing and Artifacts

Timing:

- After feature completion to analyze the workflow end-to-end
- Before sprint or milestone planning to review recurring patterns
- During periods of confusion to stop and analyze the current process state
- As a periodic health check across recent work

Artifacts:

- Review report in `.copilot-tracking/reviews/{date}-process-review.md`
- Action items added to backlog or planning follow-ups
- Documentation or instruction updates delegated to the owning implementation agent

## Related Guidance

- Load `process-troubleshooting` for detailed failure-pattern diagnosis
- Load `verification-before-completion` when the review needs to check whether completion evidence was sufficient
- Load `systematic-debugging` when the problem is a live failure path rather than a retrospective process defect

## Gotchas

| Trigger                                               | Gotcha                                                               | Fix                                                                          |
| ----------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Reviewing a workflow from memory instead of artifacts | The analysis becomes opinion-heavy and misses the actual defect path | Reconstruct the timeline from plans, commits, terminal evidence, and outputs |

| Trigger                                                   | Gotcha                                                               | Fix                                                                  |
| --------------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Treating a skill gap as proof that the skill was required | The audit becomes a box-checking exercise instead of a judgment call | Compare the missed skill against the actual phase needs and evidence |
