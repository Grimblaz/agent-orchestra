---
name: provenance-gate
description: "First-contact issue-framing assessment for cold pickups. Use when a user-invocable agent receives an existing GitHub issue without a warm handoff, needs the two-stage provenance gate, or must record the first-contact-assessed marker. DO NOT USE FOR: post-merge review cleanup (use post-pr-review) or implementation debugging after work has already started (use systematic-debugging)."
---

# Provenance Gate

Cold-pickup assessment protocol for existing GitHub issues.

## When to Use

- When a user-invocable agent receives a request that references an existing GitHub issue
- When no warm-handoff markers show the issue was already validated in the current session
- When the issue needs a root-cause, mechanism-fit, and scope-accuracy assessment before execution
- When the gate result must be deduplicated with `first-contact-assessed-{ID}`

## Purpose

When a pipeline agent picks up an existing GitHub issue without an upstream handoff in the current session, this gate forces a brief two-stage check before execution. It catches misdiagnosed root causes, poor mechanism choices, and scope mistakes before the pipeline commits effort to the wrong implementation path while keeping the warm-author path low friction.

## Trigger Conditions

Apply the gate only on a cold pickup.

- An issue ID is present in the user's request
- The agent is user-invocable, not a subagent
- No warm-handoff markers exist for the issue: no current-session `plan-issue-{ID}` or `design-issue-{ID}` handoff artifacts, and no durable GitHub handoff comments `<!-- plan-issue-{ID} -->`, `<!-- design-issue-{ID} -->`, `<!-- experience-owner-complete-{ID} -->`, or `<!-- design-phase-complete-{ID} -->`
- No prior assessment state already resolves the gate through a durable GitHub marker or a pending recovery path

## Trigger Flow

### Step 1 — Extract issue ID

Parse the user's request for a GitHub issue reference such as `#N` or `issue N`. If no issue ID is determinable, skip the entire gate silently and continue with the user's request.

### Step 2 — Check warm-handoff markers

Check the current session for `plan-issue-{ID}` or `design-issue-{ID}` handoff artifacts. Also check GitHub issue comments for the durable warm-handoff markers `<!-- plan-issue-{ID} -->`, `<!-- design-issue-{ID} -->`, `<!-- experience-owner-complete-{ID} -->`, or `<!-- design-phase-complete-{ID} -->`. If any are present, skip the gate silently because the issue framing was already validated.

### Step 3 — Check prior assessment marker or pending recovery

Check GitHub issue comments for `<!-- first-contact-assessed-{ID} -->`. That HTML token is the only skip-check anchor.

- If the GitHub marker is present, skip the gate silently.
- Also check whether a local fallback payload exists for this issue.
- If the GitHub marker is missing but the local payload exists, do not skip silently. This means a prior offline run still needs recovery. When online posting is available, tell the developer recovery is active, reconstruct the two-line GitHub marker from that payload, post it, and then continue without re-running the assessment.
- If neither exists, continue to step 4.
- If MCP tools are unavailable or the API call fails while checking GitHub, fail open: tell the developer offline mode is active, do not treat the local payload as a skip marker, and continue with the assessment now. The local payload remains only a later recovery input.

### Step 4 — Self-filter subagents

Skip the gate silently for agents with `user-invocable: false` in frontmatter. Subagents dispatched by Code-Conductor already operate within an assessed session context.

### Step 5 — Stage 1 self-classification

Present the stage-1 self-classification question before any assessment text.

- If the developer chooses `I wrote this / I'm fully briefed`, treat that as the fast path and proceed without showing the assessment summary.
- If the developer chooses `I'm picking this up cold`, continue to the cold path in step 6.
- If the developer chooses `Stop — needs rework first`, halt immediately and do not post `<!-- first-contact-assessed-{ID} -->`.

### Step 6 — Cold-path assessment

Only when the developer chooses `I'm picking this up cold`, read the issue body, run the three-question assessment protocol below, and summarize the result. Then present the cold-only stage-2 decision.

- If the developer chooses `Assessment looks right — proceed`, continue normally.
- If the developer chooses `Proceed but carry concerns forward`, continue and carry the concerns forward explicitly.
- If the developer chooses `Needs rework — stop here`, halt immediately and do not post `<!-- first-contact-assessed-{ID} -->`.

### Step 7 — Record the durable marker

After either non-stop outcome (`I wrote this / I'm fully briefed`, `Assessment looks right — proceed`, or `Proceed but carry concerns forward`), post this two-line GitHub issue comment marker:

```text
<!-- first-contact-assessed-{ID} -->
Provenance gate: fast-path or cold-path assessment completed; human-readable summary only.
```

The HTML token on line 1 remains the only skip-check anchor and the only parser anchor. The second line is human-readable and decorative only.

Use `mcp_github_add_issue_comment` to post the two-line marker. If the MCP tool is unavailable or the API call fails, fail open visibly: tell the developer that offline mode is active, write a structured local payload to `/memories/session/first-contact-assessed-{ID}.md`, and proceed. On the next online invocation, if the GitHub marker is still missing but the local payload exists, reconstruct the GitHub marker from the local payload and post it before continuing. In multi-issue bundles, the gate fires per unique issue ID.

> **Survival**: `SMC-04` governs `first-contact-assessed-{ID}`. The GitHub issue-comment marker is `durable`; the fail-open local payload is `within-conversation` recovery input only. Read precedence remains GitHub marker OR local payload: the marker completes the gate, while a local-only payload must be posted back to GitHub on the next online run before normal continuation.

The local payload is not a second durable skip marker. It is a temporary recovery input only while it remains available in session memory.

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

Use the platform's structured question tool in two stages.

### Stage-1 Self-Classification Labels

```yaml
canonical_option_labels:
  - "I wrote this / I'm fully briefed"
  - "I'm picking this up cold"
  - "Stop — needs rework first"
```

Stage 1 always runs first and happens before any assessment text.

### Stage-2 Cold-Only Assessment Labels

```yaml
canonical_option_labels:
  - "Assessment looks right — proceed"
  - "Proceed but carry concerns forward"
  - "Needs rework — stop here"
```

Stage 2 is cold-only: ask it only if the stage-1 answer was `I'm picking this up cold`.

Interpretation:

- `I wrote this / I'm fully briefed`: fast-path outcome, proceed immediately
- `I'm picking this up cold`: run the assessment and then ask stage 2
- `Stop — needs rework first`: stop, summarize the findings if needed, and post no marker
- `Assessment looks right — proceed`: proceeded outcome
- `Proceed but carry concerns forward`: proceeded with concerns outcome
- `Needs rework — stop here`: stop, summarize the findings, and post no marker

### Offline Fallback Payload Schema

```yaml
issue_id: "{ID}"
outcome: "fast-path | proceeded | proceeded with concerns"
concerns: "[] or a human-readable summary of carried concerns"
sync_to_github_on_next_online_run: true
```

Persisted outcomes must remain `fast-path`, `proceeded`, or `proceeded with concerns`.

Recovery depends on that local payload still being available. If it is gone by the next online invocation, there is nothing to reconstruct and the gate runs again.

## Edge Cases

### Brand-new self-authored issue

The gate still fires. This is intentional because a freshly written issue can still be based on the wrong assumptions. The stage-1 fast-path option keeps dismissal low-friction.

### Re-invocation in the same session

If the line-1 HTML token `<!-- first-contact-assessed-{ID} -->` is already present during marker checks, skip the gate entirely. Do not parse the second line; it is decorative only.

### Warm handoff already recorded

If current-session handoff artifacts or durable GitHub warm-handoff markers already exist, skip the gate. Upstream phases already validated the issue framing.

### Fail-open on errors

- MCP tool unavailable: skip the GitHub marker lookup, tell the developer offline mode is active, and continue with the assessment
- API errors: tell the developer offline mode is active, continue with the assessment, write the structured local payload, and set `sync_to_github_on_next_online_run: true`
- Next online run: if the GitHub marker is missing but the local payload still exists, tell the developer recovery is active, reconstruct and post the two-line GitHub marker before continuing
- Local payload missing on a later online run: recovery is unavailable, so run the gate again instead of silently skipping
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

---

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
