# Issue #567 CE Gate Replay Summary

Date: 2026-05-14
Surface: CLI / chat-command directive surface
Evidence type: Focused Pester and resolver replay

## Commands Run

- `Invoke-Pester -Path .github/scripts/Tests/nl-intent-routing.Tests.ps1,.github/scripts/Tests/intent-routing-collisions.Tests.ps1,.github/scripts/Tests/intent-routing-scope.Tests.ps1 -Output Minimal`
- `Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern` against collision, raw-signal, no-match, and should-route phrases.

## Focused Validation Results

- Targeted Pester: PASS, 18 tests passed across the three focused routing files.
- D11 collision replay: PASS, 0 route fires out of 15 collision phrases; budget was `floor(15 * 0.10) = 1`.
- Raw-signal replay: PASS, all configured raw signals resolved to no-route.
- False-negative mini-fixture: PASS, 6/6 should-route phrases resolved through `Invoke-RoutingLookup`, for a 100% hit rate against the required 80% threshold.
- No-match spot check: PASS, `explain what this code does` resolved to no-route.

## Should-Route Mini-Fixture

| Phrase | Intent | Claude command | Copilot command | Result |
| --- | --- | --- | --- | --- |
| `please review this code` | `review-local` | `/orchestra:review` | `/review` | PASS |
| `review my PR` | `review-pr-github` | `/review-github` | `/review-github` | PASS |
| `create a plan for issue 567` | `plan` | `/plan` | `/plan` | PASS |
| `technical design for issue 567` | `design` | `/design` | `/design` | PASS |
| `orchestrate issue 567` | `orchestrate` | `/orchestrate` | `/orchestrate` | PASS |
| `polish the ui` | `polish` | `/polish` | `/polish` | PASS |

## Spot Checks

| Phrase | Resolver result | Result |
| --- | --- | --- |
| `explain what this code does` | no route | PASS |
| `just answer normally` | no route | PASS |
| `orchestrate issue 567` | `orchestrate`, Claude `/orchestrate`, Copilot `/orchestrate` | PASS |
| `review my PR` | `review-pr-github`, Claude `/review-github`, Copilot `/review-github` | PASS |
| `technical design for issue 567` | `design`, Claude `/design`, Copilot `/design` | PASS |
| `create a plan for issue 567` | `plan`, Claude `/plan`, Copilot `/plan` | PASS |

## Scenario Rollup

| Scenario | Phase 1 result | Live runtime result | Evidence |
| --- | --- | --- | --- |
| S1 Functional | PASS | INCONCLUSIVE | Directive text plus resolver should-route checks name slash commands verbatim. |
| S2 Functional | PASS | INCONCLUSIVE | `/raw` command/prompt guidance plus raw-signal resolver no-route checks. |
| S4 Intent | PASS | INCONCLUSIVE | Claude and Copilot guidance consistently names slash commands and marks `@-mention` as not recommended. |
| D3 scope | PASS | INCONCLUSIVE | Scope is documented in both platform Intent Routing sections; no runtime hook is shipped. |
| D6 tier hint | PASS | INCONCLUSIVE | Claude `/orchestrate` frontmatter is `sonnet` + `medium`; both directives include the tier-hint wording. |
| D5 instruct-and-wait | PASS | INCONCLUSIVE | Both directives require `Please run /X to continue` and stop for explicit handoff commands. |
| D8 no-match | PASS | INCONCLUSIVE | Resolver returns no route for `explain what this code does`; both directives include the discoverability tip. |
| D8 ambiguous-match | PASS | INCONCLUSIVE | Both directives require text-only disambiguation naming slash-command candidates. |
| D11 collision fixture | PASS | Not applicable | Resolver replay produced 0/15 route fires, within budget 1. |
| False-negative replay | PASS | Not applicable | Should-route replay produced 6/6 route hits, exceeding the 80% threshold. |

## Named-Decision Verification

- D1 two-phase rollout: VERIFIED. Evidence validates Phase 1 only; Phase 2 runtime hook/custom chat mode remains deferred.
- D3 scoped routing: VERIFIED by platform directive text.
- D5 instruct-and-wait: VERIFIED by platform directive text.
- D6 tier hint: VERIFIED by platform directive text and Claude `/orchestrate` frontmatter.
- D7 raw mode: VERIFIED by `/raw` command/prompt files and raw-signal resolver behavior.
- D8 no-match/ambiguous-match: VERIFIED by platform directive text and no-match resolver spot check.
- D10 source of truth: VERIFIED by resolver replay against `nl_intent_routing` in `skills/routing-tables/assets/routing-config.json`.
- D11 collision budget: VERIFIED by fixture replay.

## Exploratory Observations

- The directives are aligned on default plugin processes, slash-command naming, `/raw` opt-out, scoped routing, no-match hints, and Phase 2 deferral.
- Copilot-specific null-command rows are documented; the directive says not to synthesize Copilot commands for those rows.
- The remaining customer-risk is adherence risk, not resolver/config drift: without the Phase 2 runtime hook/custom chat mode, the live chat experience can still depend on model behavior following the prose directives.

## Recommended CE Gate Marker

✅ CE Gate passed — intent match: partial

Rationale: Phase 1 directive, config, and resolver evidence is strong and focused checks pass. Intent match is partial rather than strong because live Claude/Copilot transcript capture is unavailable and the runtime hook/custom chat mode is explicitly deferred to Phase 2.
