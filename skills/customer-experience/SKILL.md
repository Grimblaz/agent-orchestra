---
name: customer-experience
description: "Reusable customer framing and CE evidence methodology. Use when turning issue scope into customer journeys, drafting functional plus intent scenarios, or capturing CE Gate evidence against design intent. DO NOT USE FOR: GitHub setup, completion-marker ownership, or adversarial CE prosecution and judgment (keep those in Experience-Owner.agent.md)"
---

<!-- platform-assumptions: markdown skill guidance for VS Code custom agents in Agent Orchestra; assumes pipeline-entry agents retain GitHub ownership, trigger routing, and completion-marker responsibilities. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Customer Experience

Reusable entryway for framing work in customer language upstream and capturing customer-experience evidence downstream.

## When to Use

- When a feature needs a customer-facing problem statement before design begins
- When customer journeys, segments, or success language need to be clarified
- When CE Gate scenarios must include both functional behavior and design-intent checks
- When downstream validation needs evidence tied back to named customer outcomes and design intent

## Purpose

Keep customer framing and CE validation consistent across issues. Upstream, translate scope into customer problems, journeys, scenarios, and surface coverage. Downstream, exercise delegated customer scenarios, verify named decisions where evidence allows, and return an evidence-only summary without turning evidence capture into prosecution.

## Upstream Framing At A Glance

1. Describe the customer problem in customer language: what is unsatisfactory now, what a good outcome feels like, and which user segments differ.
2. Map current, target, and edge journeys so design and CE Gate work share the same customer narrative.
3. Draft 2-4 customer-perspective scenarios with at least one intent scenario alongside functional checks. When BDD is enabled, load `bdd-scenarios` for G/W/T formatting, scenario IDs, and `[auto]` or `[manual]` classification.
4. Capture named decisions and a short design-intent summary in user-outcome terms, not implementation terms.
5. Identify the customer-facing surface and CE Gate readiness per surface group. If there is no customer surface, record that explicitly.
6. Run the Hub/Consumer Classification Gate once per issue before adding language- or framework-specific guidance to a hub agent.
7. When user input is required, prepare 2-3 concrete options with one recommendation and concise trade-off reasoning.

## Downstream Evidence Capture At A Glance

1. Load the delegated scenarios, named decisions or design-intent statements, surface notes, and environment prerequisites.
2. Exercise each delegated scenario with the right surface tool and record `PASS`, `FAIL`, or `INCONCLUSIVE` with evidence. Keep scenario IDs when BDD is enabled.
3. Verify named decisions as `VERIFIED`, `NOT VERIFIED`, or `VIOLATED`.
4. Do exploratory validation after scripted checks and treat it as discovery, not prosecution.
5. Return an evidence-only summary with scenario results, named-decision verification, exploratory observations, and evidence references.

## Composite References

- [references/orchestration-protocol.md](references/orchestration-protocol.md): CE Gate orchestration, surface routing, runner dispatch, intent rubric, PR body output, and prosecution-depth reporting.
- [references/defect-response.md](references/defect-response.md): Two-track remediation, graceful degradation, and CE or proxy prosecution re-activation.
- [platforms/copilot.md](platforms/copilot.md): Copilot structured-question invocation.
- [platforms/claude.md](platforms/claude.md): Claude Code structured-question invocation.

## Hub/Consumer Classification Gate

Before finalizing upstream framing, classify whether the issue proposes adding content that primarily manifests in one language's type system, runtime, or framework to a hub agent (any `.agent.md` in `agents/`). Hub agents are language-agnostic - language-specific review rules, prosecution perspectives, and behavioral patterns belong in consumer-repo artifacts:

- **Review rules / pitfalls** -> `examples/{stack}/architecture-rules.md`
- **Stack-specific conventions** -> `examples/{stack}/copilot-instructions.md`
- **Reusable cross-stack skills** -> `skills/{skill-name}/`

If the gate fires, redirect the proposal to the appropriate consumer artifact and reframe the issue accordingly. The user may override with explicit rationale if the proposed content is genuinely language-agnostic.

This gate applies equally to upstream framing (Experience-Owner) and downstream design exploration (Solution-Designer); run it once per issue and carry the result forward.

## Related Guidance

- Load `bdd-scenarios` when scenario IDs, G/W/T formatting, service annotations, or runner classification are needed.
- Load `browser-canvas-testing` when a CE scenario depends on canvas interaction in browser tools.
- Load `webapp-testing` when the work shifts from exploratory CE evidence to browser E2E automation design.

## Gotchas

- Only drafting functional scenarios lets CE Gate prove correctness while missing design-intent regressions. Always include at least one intent scenario.
- Multi-surface work cannot inherit coverage from one exercised path. Enumerate each surface group and mark uncovered ones explicitly.

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
