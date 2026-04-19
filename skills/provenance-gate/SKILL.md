---
name: provenance-gate
description: First-contact issue-framing assessment for cold pickups. Use when a user-invocable agent receives an existing GitHub issue without a warm handoff, needs the three-question assessment, or must record the first-contact-assessed marker. DO NOT USE FOR: post-merge review cleanup (use post-pr-review) or implementation debugging after work has already started (use systematic-debugging).
---

# Provenance Gate

Cold-pickup assessment protocol for existing GitHub issues.

## When to Use

- When a user-invocable agent receives a request that references an existing GitHub issue
- When no warm-handoff markers show the issue was already validated in the current session
- When the issue needs a root-cause, mechanism-fit, and scope-accuracy assessment before execution
- When the gate result must be deduplicated with `first-contact-assessed-{ID}`

## Purpose

When a pipeline agent picks up an existing GitHub issue without an upstream handoff in the current session, this gate forces a brief assessment before execution. It catches misdiagnosed root causes, poor mechanism choices, and scope mistakes before the pipeline commits effort to the wrong implementation path.

## Trigger Conditions

Apply the gate only on a cold pickup.

- An issue ID is present in the user's request
- The agent is user-invocable, not a subagent
- No warm-handoff markers exist for the issue: no `plan-issue-{ID}` or `design-issue-{ID}` in session memory, and no `<!-- experience-owner-complete-{ID} -->` or `<!-- design-phase-complete-{ID} -->` in GitHub issue comments
- No prior `<!-- first-contact-assessed-{ID} -->` marker is found in GitHub comments or session memory

## Trigger Flow

### Step 1 — Extract issue ID

Parse the user's request for a GitHub issue reference such as `#N` or `issue N`. If no issue ID is determinable, skip the entire gate silently and continue with the user's request.

### Step 2 — Check warm-handoff markers

Check session memory for `plan-issue-{ID}` or `design-issue-{ID}`. Also check GitHub issue comments for `<!-- experience-owner-complete-{ID} -->` or `<!-- design-phase-complete-{ID} -->`. If any are present, skip the gate silently because the issue framing was already validated.

### Step 3 — Check prior assessment marker

Check GitHub issue comments for `<!-- first-contact-assessed-{ID} -->`. Also check session memory at `/memories/session/first-contact-assessed-{ID}.md`. If found in either location, skip the gate silently. If MCP tools are unavailable or the API call fails, fail open: skip the GitHub marker check and proceed with the assessment.

### Step 4 — Self-filter subagents

Skip the gate silently for agents with `user-invocable: false` in frontmatter. Subagents dispatched by Code-Conductor already operate within an assessed session context.

### Step 5 — Run the assessment

Read the issue body and run the three-question assessment protocol below. Judge substance, not writing quality.

### Step 6 — Record the marker

After the developer responds with any option except `Needs rework - stop here`, post this GitHub issue comment marker:

```text
<!-- first-contact-assessed-{ID} -->
```

Use `mcp_github_add_issue_comment` to post the marker. If the MCP tool is unavailable or the API call fails, fail open: record the assessment result in session memory at `/memories/session/first-contact-assessed-{ID}.md` instead and proceed. In multi-issue bundles, the gate fires per unique issue ID.

## Three-Question Assessment Protocol

### Question 1 — Root Cause vs. Symptom

Does the issue identify an actual root cause, or only describe a symptom and assume a cause?

Evaluation criteria:

- Does the stated problem trace to a specific mechanism failure rather than a behavioral observation?
- If the issue says something does not work, does it explain why?
- Watch for misattribution to the wrong system component.

Assessment output: `Root cause identified` / `Symptom only - root cause unclear` / `Misattributed root cause`

### Question 2 — Mechanism Fitness

Is the proposed solution mechanism appropriate for this project's architecture and conventions?

Evaluation criteria:

- Read the repo's `copilot-instructions.md` and `architecture-rules.md` or equivalent project guidance.
- Check whether the proposed mechanism matches how this repo solves similar problems.
- Reject unnecessary complexity or new patterns when existing patterns fit.
- Reject mechanisms that violate stated architecture constraints.

Assessment output: `Mechanism fits` / `Mechanism questionable - {reason}` / `Mechanism conflicts with project conventions`

### Question 3 — Scope Accuracy

Does the issue's scope match the actual problem?

Evaluation criteria:

- Are the listed files, systems, and acceptance criteria aligned to the identified root cause?
- Is the scope too narrow and missing affected areas?
- Is the scope too broad and pulling in unrelated work?
- Do the acceptance criteria prove the root cause is fixed rather than something adjacent?

Assessment output: `Scope accurate` / `Scope incomplete - {missing areas}` / `Scope misaligned - {reason}`

## Developer Gate

After the assessment, present the summary with `#tool:vscode/askQuestions` and these options:

1. `I wrote this / I'm fully briefed`
2. `Assessment looks right - proceed with caution`
3. `Needs rework - stop here`

Interpretation:

- `I wrote this / I'm fully briefed`: fast path, proceed immediately
- `Assessment looks right - proceed with caution`: proceed and carry the concerns forward during implementation
- `Needs rework - stop here`: stop and summarize the findings for the developer to address

## Edge Cases

### Brand-new self-authored issue

The gate still fires. This is intentional because a freshly written issue can still be based on the wrong assumptions. The fast-path option keeps dismissal low-friction.

### Re-invocation in the same session

If `<!-- first-contact-assessed-{ID} -->` is already present during marker checks, skip the gate entirely.

### Warm handoff within current session

If warm-handoff markers exist, skip the gate. Upstream phases already validated the issue framing.

### Fail-open on errors

- MCP tool unavailable: skip the GitHub marker lookup and continue with the assessment
- API errors: continue with the assessment and fall back to session memory for marker recording
- Session memory inaccessible: proceed with the assessment rather than skipping the gate

The gate's value is the critical assessment itself, not perfect persistence behavior.

### Multi-issue bundles

Run the gate once per unique issue ID.

## Gotchas

| Trigger                               | Gotcha                                              | Fix                                                                                         |
| ------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| A well-written issue looks persuasive | Clean prose can still hide a symptom-only diagnosis | Evaluate root cause, mechanism, and scope separately before asking the developer to proceed |

| Trigger                   | Gotcha                                                                   | Fix                                                                               |
| ------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| MCP comment posting fails | Treating marker persistence as mandatory would block the assessment path | Fail open, write `/memories/session/first-contact-assessed-{ID}.md`, and continue |
