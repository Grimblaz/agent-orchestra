# First-Contact Provenance Gate

> **Reference only**: The operational provenance gate trigger is inline in `.github/copilot-instructions.md` (Section: "First-Contact Provenance Gate"). This file documents the full assessment protocol, edge cases, and rationale. Agents should follow the inline trigger; use this file for the detailed assessment procedure.

## Purpose

When a pipeline agent picks up an existing GitHub issue without an upstream handoff in the current session (cold pickup), this gate ensures the agent critically evaluates the issue's framing before executing blindly. Issues authored externally, carried over from prior sessions, or created by other contributors may contain misdiagnosed root causes, inappropriate solution mechanisms, or inaccurate scope descriptions. The gate prevents wasted implementation effort by surfacing these problems to the developer before the pipeline commits resources to execution.

## When to Apply

The gate applies when the `copilot-instructions.md` trigger detects a cold pickup — all of the following conditions are true:

- No warm-handoff session memory exists for the issue (`plan-issue-{ID}`, `design-issue-{ID}`, `experience-owner-complete-{ID}`, `design-phase-complete-{ID}`)
- No prior `<!-- first-contact-assessed-{ID} -->` marker is found in the issue's GitHub comments
- The agent is user-invocable (not a subagent dispatched by Code-Conductor)
- An issue ID is present in the user's request

## Three-Question Assessment Protocol

This is the core of the gate. For each question, the agent reads the issue body and evaluates substance — not presentation quality. A well-written but wrong issue still fails.

### Question 1 — Root Cause vs. Symptom

Does the issue identify an actual root cause, or does it describe a symptom and assume a cause?

**Evaluation criteria:**

- Does the stated problem trace to a specific mechanism failure, or is it a behavioral observation?
- If the issue says "X doesn't work" — does it explain WHY X doesn't work?
- Red flag: the issue describes what the user sees happening but attributes it to the wrong system component

**Assessment output:** `Root cause identified` / `Symptom only — root cause unclear` / `Misattributed root cause`

### Question 2 — Mechanism Fitness

Is the proposed solution mechanism appropriate for this project's architecture and conventions?

**Evaluation criteria — project-aware:**

- Read the repo's `copilot-instructions.md` and `architecture-rules.md` (or equivalent) to understand project conventions
- Does the proposed mechanism align with how this project solves similar problems?
- Does it introduce unnecessary complexity or new patterns where existing patterns would work?
- Does it violate stated architectural constraints?

**Assessment output:** `Mechanism fits` / `Mechanism questionable — {reason}` / `Mechanism conflicts with project conventions`

### Question 3 — Scope Accuracy

Does the scope (files to change, systems affected, acceptance criteria) match the actual problem?

**Evaluation criteria:**

- Are the listed files/systems the right ones for the identified root cause?
- Is the scope too narrow (misses affected areas) or too broad (includes unrelated changes)?
- Do the acceptance criteria actually verify the root cause is fixed, or do they verify something adjacent?

**Assessment output:** `Scope accurate` / `Scope incomplete — {missing areas}` / `Scope misaligned — {reason}`

## Developer Gate

After completing the three-question assessment, present results to the developer via `#tool:vscode/askQuestions` with three options:

1. **"I wrote this / I'm fully briefed"** — Developer confirms provenance. Proceed immediately. This is the fast-path for warm pickups that weren't detected by session memory — e.g., the developer authored the issue in a prior session.
2. **"Assessment looks right — proceed with caution"** — Developer acknowledges the assessment. Agent proceeds but flags any assessment concerns during implementation.
3. **"Needs rework — stop here"** — Developer wants to revise the issue before execution. Agent stops and summarizes the assessment findings for the developer to address.

Present the three-question assessment summary alongside the options so the developer can make an informed choice.

## Marker Posting

After the developer responds (any option except "Needs rework — stop here"), post the provenance gate marker as a GitHub issue comment:

```text
<!-- first-contact-assessed-{ID} -->
```

This prevents the gate from re-firing on subsequent invocations for the same issue. The marker is a gate-passed marker (skip-on-re-invocation dedup), distinct from phase completion markers like `<!-- experience-owner-complete-{ID} -->`.

Use `mcp_github_add_issue_comment` to post the marker. If the MCP tool is unavailable or the API call fails, fail open — record the assessment result in session memory instead and proceed. The gate's value is in the assessment, not the marker persistence.

## Edge Cases

### Brand-new self-authored issue

The gate fires even on brand-new issues the developer just wrote. This is intentional — the gate catches issues that were well-written but based on incorrect assumptions. The single-click "I wrote this / I'm fully briefed" option makes this a zero-friction dismissal for genuinely well-understood issues.

### Re-invocation in the same session

If `<!-- first-contact-assessed-{ID} -->` is found in issue comments during the trigger's marker check (Step 3 in `copilot-instructions.md`), the gate is skipped entirely. No assessment runs, no `askQuestions` call.

### Warm handoff within current session

If session memory contains warm-handoff markers (`plan-issue-{ID}`, `design-issue-{ID}`, `experience-owner-complete-{ID}`, `design-phase-complete-{ID}`), the trigger in `copilot-instructions.md` skips the gate. These markers indicate upstream pipeline phases already ran in this session — the issue framing was already validated.

### Fail-open on errors

- **MCP tool unavailable**: Skip the marker check in Step 3 of the trigger. Proceed with inline assessment. If marker posting fails after assessment, record in session memory instead.
- **API errors**: Same fail-open behavior. The gate's value is the critical evaluation, not the persistence mechanism.
- **Session memory inaccessible**: Proceed with assessment (cannot check warm-handoff markers, so assume cold pickup). Better to over-assess than to skip.

### Multi-issue bundles

When Code-Conductor processes multiple issues in a bundle (`@code-conductor issues #A #B #C`), the gate fires per unique issue ID. Each issue gets its own assessment and its own marker.

## Known Limitations

### Plugin distribution gap

Consumer repos using Copilot Orchestra as a plugin (copied agent files without the full `.github/instructions/` directory) will not have `provenance-gate.instructions.md`. The trigger in `copilot-instructions.md` includes inline minimal guidance as a fallback, but the full three-question protocol requires this file. This is a known limitation shared with other instruction files (e.g., `session-startup.instructions.md`).

### No behavioral enforcement

This gate is delivered as markdown instructions — prose-enforced by LLM agents, not programmatically enforced. An agent may skip or abbreviate the assessment. The contract test in `handoff-persistence-contract.Tests.ps1` validates that the trigger wording exists in `copilot-instructions.md`, but cannot enforce runtime behavior. This is consistent with all other pipeline gates in this system.

### Assessment quality varies by model

The three-question assessment relies on LLM judgment. Different models (and different context window states) may produce varying assessment depth. The gate is designed to surface the questions to the developer rather than auto-gate — the developer's judgment on the `askQuestions` response is the ultimate authority.
