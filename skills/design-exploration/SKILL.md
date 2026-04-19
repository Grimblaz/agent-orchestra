---

name: design-exploration
description: "Reusable technical design exploration methodology. Use when researching design options, grounding UI changes in the current experience, or converging trade-offs into one recommended design direction. DO NOT USE FOR: GitHub issue update ownership, adversarial design challenge orchestration, or approval-policy enforcement (keep those in Solution-Designer.agent.md)"
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes Solution-Designer retains GitHub issue ownership, adversarial challenge orchestration, and completion gating. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Design Exploration

Reusable methodology for exploring design options before planning or implementation.

## When to Use

- When a feature needs technical design exploration before planning
- When design choices need trade-off analysis instead of a single prescription
- When UI changes should be grounded in the current experience rather than assumptions
- When design decisions need a durable rationale and rejected alternatives

## Purpose

Explore the design in conversation first, then prepare a durable record once the direction is clear. The goal is to surface viable options, converge on one recommended path, and prepare enough detail for planning without drifting into implementation.

## Exploration Workflow

### 1. Gather the Current Context

Review the issue body, customer framing, design documents, decisions, and architecture constraints that shape the problem. Focus on what is already known, what is ambiguous, and what must be decided before planning can begin.

### 2. Load Adjacent Guidance

Pull in supporting guidance only when it changes the decision quality:

- `brainstorming` for option generation and trade-off exploration
- `research-methodology` for evidence-heavy technical research
- `frontend-design` when the design changes a user-facing visual surface
- Browser tool instructions when seeing the current app would materially improve the design discussion

### 3. Inspect the Current Experience When Useful

For UI work, prefer seeing the current state before proposing changes:

1. Verify the local preview or app entry point is available
2. Open the relevant screen or route
3. Capture screenshots or read the page structure when layout details matter
4. Use those observations to ground the design conversation

Skip this when the work is backend-only or the current experience is already well understood from local evidence.

### 4. Compare Options

Develop 2-3 viable options with explicit pros and cons for each. Recommend one option based on project goals, constraints, maintenance cost, and user impact. Rejected options should remain concise but explicit enough to explain later why they were not chosen.

### 5. Prepare Decision Questions

When user input is needed, prepare concise options with:

- One recommended path with full rationale and trade-offs
- Alternatives with brief summaries of why they are weaker or riskier
- Enough context that the agent can ask for a decision without relying on transcript archaeology

The agent still owns the mandatory structured-question policy (see `platforms/` for the Copilot and Claude Code invocation) and approval behavior.

### 6. Describe the Complete Design

Before finalizing, prepare a full-picture summary covering:

- What is being built and why
- What users will see or do differently
- Which systems, screens, or touchpoints are involved
- Edge cases, conflicts, or unusual flows that need explicit handling

### 7. Decide the Testing Scope

Choose the smallest testing mix that proves the design:

- Unit tests for single-system behavior or internal refactors
- Integration tests when behavior spans systems or boundaries
- E2E coverage when the user-facing journey itself is the change

Name the specific integration and E2E scenarios that should exist, not just the test category.

### 8. Prepare the Durable Design Payload

Once decisions are settled, prepare the material the agent will persist:

- Design decisions with rationale
- Acceptance criteria
- Testing scope and named scenarios
- Rejected alternatives with brief rationale

The agent remains responsible for the actual GitHub issue update and completion marker.

## Related Guidance

- Load `software-architecture` when the design changes dependency direction or layer boundaries
- Load `brainstorming` when the design space is still open-ended and constraints are loose
- Load `frontend-design` when the design depends on visual or interaction quality

## Gotchas

| Trigger                                   | Gotcha                                                            | Fix                                                              |
| ----------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------- |
| The design jumps straight to one solution | Trade-offs stay hidden and planning inherits untested assumptions | Present 2-3 viable options before converging on a recommendation |

| Trigger                                     | Gotcha                                                                | Fix                                                       |
| ------------------------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------- |
| Decisions are documented before convergence | The durable record freezes ambiguity and forces planning rework later | Discuss first, then document only the confirmed direction |

---

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
