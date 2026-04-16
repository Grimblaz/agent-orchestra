---

name: customer-experience
description: Reusable customer framing and CE evidence methodology. Use when turning issue scope into customer journeys, drafting functional plus intent scenarios, or capturing CE Gate evidence against design intent. DO NOT USE FOR: GitHub setup, completion-marker ownership, or adversarial CE prosecution and judgment (keep those in Experience-Owner.agent.md)
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Copilot Orchestra; assumes pipeline-entry agents retain GitHub ownership, trigger routing, and completion-marker responsibilities. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Customer Experience

Reusable methodology for framing work in customer language upstream and capturing customer-experience evidence downstream.

## When to Use

- When a feature needs a customer-facing problem statement before design begins
- When customer journeys, segments, or success language need to be clarified
- When CE Gate scenarios must include both functional behavior and design-intent checks
- When downstream validation needs evidence tied back to named customer outcomes and design intent

## Purpose

Keep customer framing and CE validation consistent across issues. Upstream, translate scope into customer problems, journeys, scenarios, and surface coverage. Downstream, exercise the delegated customer scenarios, verify named design decisions where evidence allows, and return a structured evidence summary without turning evidence capture into prosecution.

## Upstream Framing

### 1. Customer Problem Statement

Describe the problem in customer language:

- What is unsatisfactory in the current experience
- What a good outcome feels like from the customer's perspective
- Which user segments are affected and where their needs differ

### 2. User Journeys

Map the journey change in three views:

- Current journey, including workarounds or friction
- Target journey after the feature ships
- Edge journeys for distinct segments, contexts, or failure paths

### 3. Scenario Drafting

Draft 2-4 customer-perspective scenarios:

- Functional scenarios confirm the feature works end to end
- Intent scenarios confirm the experience communicates the intended value or clarity

When BDD is enabled, use the `bdd-scenarios` skill for G/W/T formatting, scenario IDs, and `[auto]` or `[manual]` classification. When BDD is not enabled, keep the scenarios in concise natural language.

### 4. Named Decisions and Design Intent

Prepare customer-facing framing for named decisions so later technical decisions can still be verified in user-outcome terms. Capture a short design-intent summary that states what experience the feature should create, not how it is implemented.

### 5. Surface and Readiness Assessment

Identify the customer-facing surface and how CE Gate work should exercise it:

- Web UI: browser tools or Playwright fallback
- REST or GraphQL API: terminal HTTP invocation
- CLI or SDK: terminal command or representative invocation
- Batch or pipeline: representative input data run
- None: explicitly record why CE Gate is not applicable

If the work spans multiple distinct customer surfaces, keep coverage separate by journey meaning. A manual fallback must still enumerate every distinct surface group and mark uncovered groups explicitly instead of inheriting coverage from exercised siblings.

## Question Preparation

When customer framing requires user input, prepare 2-3 concrete options with one recommended path, full trade-off reasoning for the recommendation, and short trade-off summaries for the alternatives. The agent still owns the mandatory `#tool:vscode/askQuestions` policy and any invocation-specific approval behavior.

## Downstream CE Evidence Capture

### 1. Load the Evaluation Inputs

Before exercising scenarios, collect:

- CE Gate scenarios that were delegated for this run
- Named decisions or design-intent statements that should be observable from the surface
- Surface type and tool availability notes
- Any required-service annotations or environment prerequisites

### 2. Exercise Delegated Scenarios

For each delegated scenario:

1. Exercise it with the appropriate tool for the surface
2. Capture evidence such as screenshots, output, or response bodies
3. Record `PASS`, `FAIL`, or `INCONCLUSIVE` with the supporting evidence reference

When BDD is enabled, keep the scenario ID with the result so downstream CE review can tie evidence back to the same scenario contract.

### 3. Verify Named Decisions

For each named decision or intended experience:

- `VERIFIED` when evidence clearly shows it was honored
- `NOT VERIFIED` when available evidence cannot confirm it
- `VIOLATED` when evidence contradicts it

### 4. Exploratory Validation

After the scripted scenarios, navigate the experience freely and look for friction, confusion, or outcome gaps that the scripted checks did not cover. Treat this as discovery, not prosecution.

### 5. Evidence Summary

Return a structured summary containing:

- Scenario-by-scenario results
- Named-decision verification results
- Exploratory observations
- References to captured screenshots or outputs

Keep the summary evidence-only. Do not score findings, recommend fixes, or collapse into prosecution language.

## Related Guidance

- Load `bdd-scenarios` when scenario IDs, G/W/T formatting, or runner classification are needed
- Load `browser-canvas-testing` when a CE scenario depends on canvas interaction in browser tools
- Load `webapp-testing` when the work shifts from exploratory CE evidence to browser E2E automation design

## Gotchas

| Trigger                                        | Gotcha                                                                | Fix                                                                    |
| ---------------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Only functional scenarios are drafted upstream | CE Gate can prove correctness while missing design-intent regressions | Always include at least one intent scenario alongside functional checks |

| Trigger                                   | Gotcha                                                      | Fix                                                         |
| ----------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------- |
| Multi-surface work falls back to one path | Unexercised surfaces look covered even when no evidence exists | Enumerate each surface group and mark uncovered ones explicitly |
