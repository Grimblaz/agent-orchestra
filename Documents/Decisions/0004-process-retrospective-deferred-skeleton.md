# ADR-0004: Process-Retrospective Port — Deferred-Skeleton Pattern

**Date**: 2026-05-03
**Status**: Accepted
**Context**: Issue #443 (sub-C of frame umbrella #425) — reify `process-review` and make a decision on `process-retrospective`.

## Context

The `process-retrospective` port was identified in the frame audit as visible in only 1 of 4 audited PRs (PR #286 only). The V2 canonical port list carried it as `tbd-decision-pending` with no adapter declared, awaiting a decision in sub-issue #11 (#436, bundled into #443): lift to first-class port, fold into `post-pr`, or retire the practice.

Three options were evaluated:

1. **Retire the practice** — remove the port from the port list entirely. Clean, but loses audit continuity for the one PR that ran it, and forecloses the option without a design for what the retrospective would look like if formalized.
2. **Fold into `post-pr`** — merge the retrospective step into the post-PR cleanup port. Simpler ledger, but loses the distinct customer question ("did we reflect on this cycle?") and makes it harder to split out later if the practice gains traction.
3. **Formalize as a deferred-trigger-conditional port with a skeleton** — declare the port, author the skill skeleton and explicit-skip adapter, and defer the trigger predicate and live work adapter to a dedicated future issue (#348). The port produces `not-applicable` credits until #348 ships.

## Decision

Option 3 — formalize as a deferred-trigger-conditional port using the **deferred-skeleton pattern** (frame D14).

The port is declared in `frame/ports/process-retrospective.yaml` with:
- `applies: trigger-conditional`
- `status: formalized-skeleton-deferred-to-348`
- `trigger-status: deferred`
- `trigger-deferred-to: '#348'`
- `trigger-deferred-since: '2026-05-03'`

The skill skeleton at `skills/process-retrospective/SKILL.md` uses `applies-when: never` — the new deterministic-false DSL identifier added in `frame-predicate-core.ps1`. All ports with `applies-when: never` produce `not-applicable` credits via `Build-DeferredPortCreditRow` and are excluded from the coverage denominator.

## Rationale

- **Audit continuity**: the port name persists in the ledger as `not-applicable` (with the `DEFERRED(#NNN):` prefix), making it trivially detectable and replaceable when #348 ships.
- **No false coverage credit**: `applies-when: never` guarantees the port never fires spuriously. The deferred pattern is deterministic — no judgment call at credit-emission time.
- **Migration path is self-describing**: the `^DEFERRED\(#\d+\):` prefix on evidence strings is the migration-detection contract. When #348 introduces a live `Build-ProcessRetrospectiveCreditRow`, a one-time fixture migration detects all `DEFERRED(#348):` rows and replaces them.
- **Cost of deferral is bounded**: the 90-day tripwire in `frame-credit-ledger.ps1` warns (never blocks) if the port remains deferred longer than 90 days — from `trigger-deferred-since: 2026-05-03`, the first warning fires around 2026-08-01 if #348 has not shipped by then.

## Consequences

- `process-retrospective` emits `not-applicable` on every PR while deferred, contributing zero to the coverage denominator.
- The coverage dashboard treats `trigger-status: deferred` rows as excluded until the status flips to `live`.
- Issue #348 inherits the **#443 ↔ #348 split contract**: stable artifacts (port YAML, SKILL.md skeleton header, explicit-skip adapter) are owned by #443 and must not be rewritten; scaffolding artifacts (trigger predicate, `applies-when` body, live work adapter, `Build-ProcessRetrospectiveCreditRow`) are owned by #348.
- Blocking-mode activation for sub-issue #13 must document how `trigger-status: deferred` rows are handled in the enforcement policy (excluded from the 95% coverage denominator per D14).

## Alternatives Rejected

| Option | Rejection reason |
|---|---|
| Retire the practice | Loses audit continuity; forecloses a practice that has observable precedent (#286). |
| Fold into `post-pr` | Loses the distinct customer question; harder to separate if the practice is later formalized with its own trigger and evidence contract. |
| Pick a trigger now and ship the live adapter in #443 | No producer for retrospective notes exists in the repo; #348 was already scoped to consume them. Authoring the trigger predicate and live `Build-ProcessRetrospectiveCreditRow` in #443 would bloat the scope, is blocked by the same absence of a producer, and risks over-constraining #348's design before the practice has more audit data. |

## Captured Input Artifact

The only audited PR with a real `## Process Retrospective` section is **PR #286** (Add per-category Fix Effectiveness measurement to the review aggregation pipeline). The Step 11 retrospective from that PR is captured here verbatim as the primary input artifact for #348's adapter author — it is the sole concrete precedent for what a process-retrospective credit represents.

**Source**: [PR #286](https://github.com/Grimblaz/agent-orchestra/pull/286) — `## Process Retrospective (Step 11)` section in the PR body.  
**Snapshot date**: 2026-05-03

> ### Slowdowns
> 1. **VS Code lockup** mid-session required full restart and smart resume from session memory
> 2. **MF1 (Critical)**: `--json number, mergedAt` — PowerShell's comma operator silently creates an array argument. Mock tests couldn't catch this because they don't validate argument format against real `gh` CLI. Discovered only by adversarial prosecution.
>
> ### Late-Failing Checks
> - None. All regressions caught at Tier 1. The 24 pre-existing test failures are on main and predate this PR.
>
> ### Workflow Guardrail Improvement
> - **Requires-gh live argument format tests** (MF4 pattern): Any new `gh` CLI integration should include a `requires-gh` live test that validates argument syntax against the real CLI, since mock-based tests cannot detect PowerShell argument-expansion bugs like the comma-operator issue in MF1. This pattern is now established in the test file and should be replicated for future gh integrations.

**S5 verification note**: To confirm this appendix is durable, a future maintainer can run `gh pr view 286 --repo Grimblaz/agent-orchestra --json body --jq '.body'` and compare the `## Process Retrospective (Step 11)` section against the verbatim quote above. If the live content diverges materially from the snapshot (e.g., the PR body was edited), flag it as a follow-up to #348 rather than failing the CE Gate.
