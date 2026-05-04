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
