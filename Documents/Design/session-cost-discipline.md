# Design: Session-Cost Discipline

**Domain**: Long-context agent session behavior — dispatch, editing, batching, and payload handling
**Status**: Current
**Implemented in**: Issue #474 (umbrella #476)

---

## Purpose

This document records why Agent Orchestra added a small set of behavioral
rules for long-context agent sessions and why they live where they live. It is
not the operational contract and does not restate the four rules.

The operational source of truth is
[skills/terminal-hygiene/SKILL.md](../../skills/terminal-hygiene/SKILL.md)
§ Session-Cost Discipline. That section owns the exact rule text, the
GitHub-body freshness-check mechanics, the batching carve-out, and the
extract-don't-dump exception for read-modify-write payloads.

## Problem

The first fully-measured orchestrated session (PR #857, 2026-07-16) cost
$473.24 across roughly 2,500 API calls. Cache-read tokens (~470M) were the
largest line item — around 97% of the spend was the orchestrating session
re-carrying its own accumulated transcript on every call, not thinking or
code. Four habits inflate either the number of calls or the volume each call
re-carries:

1. Dispatching a subagent for a diagnostic the parent could run directly in
   two or fewer tool calls.
2. Rewriting a whole file or GitHub issue/PR body through a temporary copy
   when a targeted in-place edit (or a single composed write) would do.
3. Issuing independent tool calls one at a time instead of batching them —
   each avoidable sequential call re-reads the whole session context.
4. Dumping a full structured payload (API response, JSON file, log) into
   context when only a few fields were needed, where every later call in the
   session re-carries the dump's cost.

Prior orchestrations (issue #429) already showed instances of habits 1 and 2
in isolation; #487's PR #857 measurement was the first session with
end-to-end cost data connecting all four habits to a single dollar figure and
motivated fixing them together rather than piecemeal.

This is a distinct domain from the repo's other cost-adjacent design docs:
[copilot-cost-collection.md](copilot-cost-collection.md) and
[cost-walker-coverage.md](cost-walker-coverage.md) both cover how session cost
is *measured and attributed* after the fact (the OTel capture pipeline, the
Cost Pattern PR comment, cross-platform walker coverage). Session-Cost
Discipline instead covers *behavioral rules agents follow during a session*
to keep the measured number lower. Neither existing doc mentions dispatch,
editing, or batching behavior, so no existing domain covered this material.

## Options Considered

| Option | Summary | Decision |
| --- | --- | --- |
| A | One authoritative section in an already-loaded skill (`terminal-hygiene`), with a pointer bullet in Code-Conductor and section-scoped load references in the three upstream bodies. | Selected |
| B | Duplicate the rules into each deliverable-named home (`customer-experience`, `design-exploration`, `documentation-finalization`, plus the Conductor body). | Rejected |
| C | A new dedicated skill (e.g. `session-cost-discipline`) with its own load directives everywhere. | Rejected |
| D | Grow the cost-pattern telemetry schema with new producers (tmp-file write counts, total API-call counts) so all four rules get quantitative verification. | Rejected |

## Why Option A Won

Option A keeps the rule text in exactly one place that all long-context
sessions already load, so drift can only happen in one file. `terminal-hygiene`
was already loaded, unscoped, by nine agent bodies (Code-Conductor, Code-Critic,
Code-Smith, Doc-Keeper, Process-Review, Refactor-Specialist, Specification,
Test-Writer, UI-Iterator) before this issue, so adding the section there cost
no new load wiring for those consumers. The three upstream bodies
(Experience-Owner, Solution-Designer, Issue-Planner) did not previously load
`terminal-hygiene` at all, so they each gained one **section-scoped** load
reference — scoped to keep upstream sessions from carrying the full
terminal-execution skill for the roughly 35 lines that actually apply to them.

Option B (deliverable-named duplication) was the issue's original literal
deliverable list, but three independent copies of the same rule text drift
independently and each would need its own structural test lock — the
consolidation the issue itself deferred to design phase. Option C (a new
skill) adds registration and load-directive overhead with no benefit over a
section in a skill every long-context session already touches. Option D
(growing telemetry) was rejected because new telemetry code is exactly what
the issue's Out of Scope list excludes, and the cost-pattern schema has no
existing producer for tmp-file writes or per-rule call classification.

## Rule Homes (pointer-only, not restated)

- **Authoritative text**: `skills/terminal-hygiene/SKILL.md` § Session-Cost
  Discipline — all four rules.
- **Code-Conductor** (`agents/Code-Conductor.agent.md`): a pure-pointer bullet
  in `## Ownership Principles` naming the section, plus an existing
  scoped terminal-hygiene load reference in its `## Process` section.
  Conductor carries no restated rule text.
- **Upstream bodies** (`agents/Experience-Owner.agent.md`,
  `agents/Solution-Designer.agent.md`, `agents/Issue-Planner.agent.md`): each
  loads `skills/terminal-hygiene/SKILL.md` § Session-Cost Discipline by name
  in its process/skill-loading sequence.
- **Review**: Code-Critic already loads `terminal-hygiene` unscoped, so no
  new reference was needed. Code-Review-Response (the judge) is explicitly
  out of scope — a single-shot bounded ruling is not a long-context session.
- **Doc-Keeper**: satisfied by consolidation with no additional edit —
  `agents/Doc-Keeper.agent.md` already loads `terminal-hygiene`.

## Why Pointer, Not Restatement (implementation-review correction)

The Code-Conductor Ownership Principles bullet was originally drafted as a
restatement of rule 1's operative text ("never dispatch a subagent for a
check the parent could do..."), duplicated from the skill section rather than
pointing at it. Adversarial code review sustained this as finding M14/F1 and
the bullet was corrected to a pure pointer before merge. The corrected
contract test
(`.github/scripts/Tests/session-cost-discipline-contract.Tests.ps1`, check
(c)) asserts the Conductor bullet names "Session-Cost Discipline" but does
**not** contain the operative rule-1 phrase, so a future editor cannot
silently reintroduce a restatement without failing CI.

The rationale generalizes: a bullet that restates operative text creates a
second copy that can drift from the skill section (wording, scope, or
exceptions changing in one place and not the other) while looking authoritative
in both places. A pointer bullet cannot drift, because it carries no rule
text to drift — only a name and a location.

## Rot Prevention: CI-Registered Contract Test

`session-cost-discipline-contract.Tests.ps1` is the mechanism that keeps the
rules from silently rotting away. It asserts, all scoped to extracted section
bodies rather than flat-file matches (to avoid false-GREENs against
pre-existing `batch`/`subagent` vocabulary elsewhere in these files):

- The `## Session-Cost Discipline` H2 heading exists in the skill.
- Each of the four rules' distinctive phrases exists inside that section body.
- The Code-Conductor `## Ownership Principles` bullet is a pure pointer (see
  above).
- Each of the four agent bodies join-references "Session-Cost Discipline" by
  name, decomposed per file so each has an independently meetable check.
- The skill's frontmatter `description:` names session-cost discipline for
  discoverability.

The test uses anchored literal assertions with non-capturing groups and no
order-dependent gap-chain regexes — deliberately different from the
gap-chain style used elsewhere (e.g. `branch-authority-gate-contract.Tests.ps1`),
because the regex-timeout concern that motivates gap-chain guarding does not
apply to these hardcoded, non-backtracking literals. It is registered in the
`.github/workflows/pester.yml` allowlist, so a missing or drifted rule fails a
PR rather than only a local run.

## Verification Approach

Verification is deliberately narrowed to metrics the cost-pattern telemetry
already produces, rather than growing telemetry scope to chase full
coverage:

- **Quantitative**: USD-per-PR (the Cost Pattern headline figure), cache-read
  tokens (`totals.tokens.cache_read`), and per-port dispatch counts, compared
  against the PR #857 baseline ($473.24 / ~470M cache-read tokens).
- **Qualitative**: rules 1 (parent-side diagnostics) and 2 (targeted edits)
  have no producer in the cost-pattern schema for tmp-file write counts or
  dispatch-necessity classification, so they are verified by transcript
  spot-check on the next orchestrated session rather than by a metric.
- **Explicitly not verification metrics**: total API-call count and tmp-file
  write counts — no schema producer exists for either, and adding one would
  be new telemetry code, which this issue's scope excludes.

The comparison is directional and work-size-confounded: the next measured PR
will differ in scope and fix-cycle count from PR #857, so a lower or higher
number is evidence, not proof. The 30–50% session-cost-reduction figure from
the #476 measurement comment is a hypothesis to test against the next
measured orchestrated PR, not an assumed outcome — a no-improvement result
counts against the hypothesis rather than being explained away.

## Rejected Alternatives

- **Literal deliverable homes** (duplicating rule 2 into
  `customer-experience`, `design-exploration`, and
  `documentation-finalization`): rejected — three independently-drifting
  copies each needing separate test locks, against the issue's own
  single-home intent.
- **New micro-skill**: rejected — heavier registration and load-directive
  surface than one section in an already-loaded skill, for no added benefit.
- **Verbatim issue rule-2 wording** for GitHub bodies: rejected — mechanically
  wrong (no partial-edit API for issue/PR bodies) and would have pushed
  agents toward `gh view` round-trips that OEM-mangle non-ASCII content on
  Windows.
- **Growing telemetry for per-rule producers** (call counts, tmp-write
  counts): rejected — new telemetry code is exactly what the issue's
  Out of Scope list excludes; qualitative spot-check covers rules 1–2 instead.

## Related Mechanism: Two-Layer Research Delegation (#691)

Issue #691 (same umbrella #476) shipped a companion mechanism, not a
substitute. This document's subject (#474) keeps a session's own reads lean
once a read stays inline (extract-don't-dump, batching, targeted edits,
parent-side diagnostics). #691's Two-Layer Research Delegation instead routes
upstream sessions' fan-out repo reads to a separate cheap fresh-context
`Explore` subagent dispatch, so the expensive session never carries the read
at all — a different mechanism (delegation vs. in-session discipline) under
the same cost-reduction umbrella. The two compound rather than substitute for
each other: per the issue's own framing, "#474 owns the stay-in-session
discipline... together they are the behavioral share of the estimated 30-50%
reduction."

Issue #691's cost claim is deferred-measurement, not yet confirmed by a
post-change measured PR. Per #691's own D6 design decision ("S3 measurement
contract"), verification compares upstream-phase absolute dollars — using
the per-phase attribution rows `.github/scripts/lib/cost-attribution.ps1`
already produces — against the PR #857 baseline this document already
cites, rather than upstream share of total PR cost, which is confounded by
implementation/review size variance across PRs.

Canonical rule text: `skills/research-methodology/SKILL.md` § Two-Layer
Research Delegation.

## Related Sources

- [skills/terminal-hygiene/SKILL.md](../../skills/terminal-hygiene/SKILL.md)
  § Session-Cost Discipline — canonical operational rule text
- [skills/research-methodology/SKILL.md](../../skills/research-methodology/SKILL.md)
  § Two-Layer Research Delegation — companion delegation mechanism, same
  umbrella #476, measurement deferred
- [agents/Code-Conductor.agent.md](../../agents/Code-Conductor.agent.md) —
  Ownership Principles pointer bullet
- [.github/scripts/Tests/session-cost-discipline-contract.Tests.ps1](../../.github/scripts/Tests/session-cost-discipline-contract.Tests.ps1) —
  CI-registered contract test
- [copilot-cost-collection.md](copilot-cost-collection.md) — cross-platform
  cost telemetry capture (measurement, not behavior)
- [cost-walker-coverage.md](cost-walker-coverage.md) — Claude-side issue-aware
  attribution coverage (measurement, not behavior)

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](../../HOW-IT-WORKS.md#vocab).
