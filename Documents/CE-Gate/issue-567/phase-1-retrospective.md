# Issue #567 Phase 1 Retrospective

Date: 2026-05-15
Branch: `feature/issue-567-default-plugin-experience`
Scope: Phase 1 natural-language intent routing directive, config, resolver, tests, review fixes, and CE Gate evidence.

## Summary

Phase 1 landed the intended prose/config/test enforcement for natural-language intent routing. The workflow followed the planned sequence: RED routing tests, `nl_intent_routing` config and resolver support, `/raw` command shells, platform directive documentation, adversarial review, post-review fixes, and CE Gate evidence capture.

CE Gate passed with intent match: partial. That partial result is expected for Phase 1 because live runtime enforcement through a Claude `UserPromptSubmit` hook and Copilot custom default chat mode is explicitly deferred to Phase 2.

## What Went Well

- The two-phase boundary held. Phase 1 shipped directive/config/test coverage without pretending the runtime hook existed.
- The test-first path created useful pressure early: routing table shape, command resolution, collision fixtures, raw-signal behavior, and scope wording were all covered before completion.
- The single-source routing table in `skills/routing-tables/assets/routing-config.json` made review findings concrete and fixable.
- Adversarial review materially improved the result. It caught Copilot command-surface drift, the Pattern lookup exact-match defect, raw-signal collision risk, and malformed regex guard behavior before CE Gate closure.
- CE artifacts were honest about their boundary: directive and resolver evidence passed, while live runtime transcript capture remained inconclusive by design.

## What Surprised Us

- Copilot command-surface drift was easier to introduce than expected because Claude and Copilot expose overlapping but non-identical command names.
- The Pattern lookup exact-match defect showed that a table can be structurally valid while still failing the lookup mode Phase 2 will need.
- Raw opt-out phrases needed explicit no-route protection; otherwise natural-language routing and raw-mode activation can collide.
- The malformed regex guard needed to be treated as a first-class safety path, not just a malformed fixture edge case.

## Methodology And Process Gaps

No new broad methodology gap was found. The existing process caught the important defects through RED tests, adversarial review, post-fix review, and CE replay.

Narrow process observations:

- Cross-platform command parity needs direct test pressure whenever a shared routing table carries per-platform command columns.
- Collision fixtures should include opt-out and control phrases, not only overlapping positive intents.
- CE Gate language should keep distinguishing directive/config evidence from live runtime capture when a phase intentionally defers hooks or default-entry changes.

Process-Review calibration check on 2026-05-15 found no systemic patterns meeting the guardrail-proposal threshold. No local gotcha file was present, so there were no upstream gotcha candidates to process.

## Phase 2 Handoff Notes

Phase 2 follow-up issue #569 is the handoff issue for this work. Duplicate issue #568 was closed as a duplicate. Issue #567 is not blocked on creating another Phase 2 issue; Phase 2 work should proceed through #569.

Phase 2 should cover:

- Claude `UserPromptSubmit` runtime hook for top-level natural-language intent routing.
- Copilot custom default chat mode or equivalent default-entry mechanism.
- Runtime state for conversation-local `/raw`, including natural-language raw signals and explicit slash-command clearing.
- Use of `nl_intent_routing` as the source of truth rather than duplicating command mappings.
- Live transcript capture for the scenarios that Phase 1 marked INCONCLUSIVE.

Promotion criteria from D1 to include verbatim in the Phase 2 issue:

1. CE-Gate capture shows directive-following degraded behavior on 2+ scenarios across two captures.
2. Two distinct user-reported mis-routing reports land in a quarter.
3. Maintainer manually promotes at scheduled review.

## Recommended Follow-Ups

- Track Phase 2 implementation in #569. AC10's Phase 2 follow-up issue is already filed, so no additional Phase 2 issue is needed for #567 closure.
- No new methodology documentation issue is recommended from this retrospective.
- No new process guardrail issue is recommended. The current test/review/CE ladder caught the Phase 1 failures, and the remaining customer risk is the intentionally deferred runtime enforcement work.
