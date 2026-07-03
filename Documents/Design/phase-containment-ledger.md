# Design: Phase-Containment Escape-Rate Ledger

## Summary

Umbrella issue #761 asks a measurement question the adversarial review pipeline could not previously answer: for each review stage (design-challenge, plan-stress-test, code-review), what fraction of sustained findings escaped from an earlier phase that could have caught them, and what fraction were genuinely irreducible — catchable only at that stage? The maintainer's stated position is that no review is relaxed on a cost argument alone; a stage earns relaxation only when data shows its irreducible-catch rate has trended to ~0 over a rolling window with enough samples to trust.

The phase-containment ledger is the instrument that produces that data. Each sustained adversarial finding is annotated with `introduced_phase` (where the flaw originated), `catchable_phase` (the earliest phase it could reasonably have been caught), and `caught_stage` (which review actually caught it). The system was built across four issues:

- **#762** (sub-1) shipped the per-finding annotation schema, a hand-rolled parser/validator, a rolling-history walker with rollup, and a maintainer-facing report CLI.
- **#763** (sub-2) shipped the first escape-driven upstream fix: a four-quadrant grounding discipline in `design-exploration` that catches the class of design-phase miss the #760 seed entries recorded.
- **#772** hardened the sub-1 reader against latent walker bugs found in PR #770's review; it remains open.
- **#782** (this branch) closed the gap between "emission is specified" and "emission happens": a warn-only sweep that detects sustained findings missing their paired ledger blocks, plus the first organic backfill (16 entries recovered from PRs #775/#778/#781).

This document describes the current shipped system. It does not cover relaxation-criterion governance (deferred to the umbrella, gated on this data) or the #772 hardening items (tracked as a known limitation below).

## Implemented Surfaces

| Surface | Current Role |
| --- | --- |
| `skills/calibration-pipeline/schemas/phase-containment.schema.json` | JSON Schema for a single ledger entry: 8 required fields plus `apparatus_meta`/`seed` flags; `additionalProperties: false` |
| `.github/scripts/lib/phase-containment-core.ps1` | Block extraction (`Get-PhaseContainmentBlock`), hand-rolled YAML parsing (`ConvertFrom-PhaseContainmentYaml`), schema validation (`Test-PhaseContainmentEntry`), finding-key derivation (`Get-PhaseContainmentFindingKey`), and enum-drift verification against `routing-config.json` (`Get-PhaseContainmentEnumDriftStatus`) |
| `.github/scripts/lib/phase-containment-rolling-history-core.ps1` | Two-surface (issue-marker + PR-comment) rolling-window walker with GraphQL-primary/REST-fallback fetch, 1h cache, dedup, and per-stage rollup (`Get-PhaseContainmentHistory`, `Get-PhaseContainmentRollup`, `Get-PhaseContainmentCommentCorpus`) |
| `.github/scripts/phase-containment-report.ps1` | Thin maintainer-facing CLI wrapper; renders per-stage escape rate, irreducible rate, relaxation-signal status, and the introduced×caught leakage matrix |
| `.github/scripts/lib/phase-containment-emission-check-core.ps1` | Core library for the emission backstop: sustained-finding counting across three surface shapes (`Get-SustainedFindingCount`), marker-head detection with vocabulary gating (`Test-EmissionMarkerPresent`), gap computation (`Get-EmissionGap`), and the read-modify-write backfill-append primitive (`Add-CommentBlocks`) |
| `.github/scripts/phase-containment-emission-check.ps1` | Warn-only sweep orchestrator; single-target mode (`-Pr`/`-Issue`) and corpus mode (`-WindowDays`), with an optional backfill-scaffold renderer (`-ScaffoldBackfill`) |
| `skills/design-exploration/SKILL.md` § Grounding Discipline | The first escape-driven upstream fix (#763): four-quadrant cited trace required before the design challenge |

## Design Decisions

| # | Decision | Choice | Rationale |
| --- | --- | --- | --- |
| D1 | Annotation home | One uniform `<!-- phase-containment-{ID} -->` block per finding, written by whichever stage caught it onto the surface it already posts to | The #762 design challenge found the plan-stress-test surface has no parseable block and `judge-rulings` is parsed by a bespoke line-scanner, not YAML — in-place extension of `finding_dispositions`/`judge-rulings` could not hold uniformly across all three surfaces |
| D2 | Escape-distance arithmetic | `escape_distance = projection(caught_stage) − ordinal(catchable_phase)`, validated by recomputation and rejected (not clamped) if the stored value differs, or if `introduced_phase > catchable_phase`, or if `catchable_phase` exceeds the caught stage's projection | A silently-clamped or unchecked distance would corrupt the escape/irreducible split the whole metric depends on |
| D3 | Fail-loud over silent-zero | Any unparseable, ambiguous, or unknown-vocabulary content under a recognized marker head is `could-not-verify`, never silently treated as zero findings or a clean gap | A metric whose failure mode is silent zero would misreport a stage as clean when it was actually unmeasured — the exact false-clean scenario S2 in #772/#782 exists to prevent |
| D4 | Undersample guard granularity | Per-stage `insufficient_data` (n<5) withholds that stage's relaxation-eligibility signal independently — not a single global window-count guard | A global guard would let a near-empty stage (e.g. plan-stress-test at n=1) read as computable simply because other stages had volume |
| D5 | `finding_key` surface discrimination | Uniform `{surface}:{stable_finding_key}` format; `Get-EmissionGap` requires a block's `finding_key` to be prefixed for the surface being checked before counting it toward that surface's block count | design-challenge and plan-stress-test marker heads can legitimately co-occur on the same issue body; without the prefix check, a block emitted for one surface could silently satisfy another surface's gap count |
| D6 | Warn-only, never-blocking posture | The emission-check sweep only ever posts an advisory comment; enforce mode is defined in the `-Mode` parameter but explicitly unimplemented (`warn` behavior runs regardless of the value supplied) | Mirrors the frame-credit-ledger warn→enforce staging precedent — surface the gap, never gate a review, PR, or issue update on it |
| D7 | Why emission enforcement needed a separate sweep | #762 shipped emission as a prose post-step in three skills (`design-exploration`, `plan-authoring`, `review-judgment`); every real review after PR #770 merged — #775, #778, #781, sustaining 13+ findings between them — emitted zero paired `phase-containment` blocks | An unenforced terminal instruction is reliably skipped; #782 built a reader-side reconciliation sweep as the durable guarantee rather than trusting a stronger prose reminder to succeed where the first one failed |
| D8 | Marker-vocabulary gating (not bare substring match) | A comment only counts as an authoritative judge-rulings/finding_dispositions surface when its marker head is followed, within a bounded lookahead window, by recognizable field-vocabulary tokens (`disposition`, `judge_ruling`, `verdict`, `finding_key`, `finding_id`, `schema_version`) at a real YAML key position (line-start, flow-mapping, or dash-space list-item) | Early iterations mistook ordinary prose describing the marker convention, or dash-space list-item findings, for real marker content — both a false-could-not-verify and a false-clean failure mode had to be closed |
| D9 | Backfill-append primitive is read-modify-write, never upsert | `Add-CommentBlocks` does `gh api` GET → verify marker → concatenate → PATCH → positive-proof re-verify; it explicitly does not use `Find-OrUpsertComment`, whose PATCH path replaces the body verbatim | The judge-rulings YAML that Code-Conductor's credit harvest reads lives in the same comment the backfill blocks are appended to — an upsert-style replace would destroy it |
| D10 | Post-write verification is positive-proof, not byte-prefix | Verification confirms (a) the original marker survived and (b) every appended block is present, parseable, and content-identical in the re-fetched body — not an exact `StartsWith` byte comparison | Live backfill against #775/#778/#781 showed GitHub's API benignly normalizes whitespace on write/read, which broke ordinal-prefix comparison and produced false negatives that would have trained the caller to ignore a real fail-loud signal |

## Metric Definitions and Scope Boundary

The ledger measures, per review stage, over a rolling window:

- **Escape rate** — the fraction of findings whose `catchable_phase` denominator stage leaked (caught later than that stage).
- **Irreducible-catch rate** — the fraction caught exactly at their `catchable_phase` stage, genuinely requiring that stage's information.
- **Relaxation-eligibility signal** — emitted only when irreducible rate trends to ~0 **and** the stage's window sample size is `n ≥ 5` **and** no critical-severity finding was caught in the window. Below n=5 the signal is withheld and the stage reports `INSUFFICIENT DATA` rather than a false confident rate.

The system is explicitly a measurement instrument, not an enforcement or relaxation mechanism:

- It never blocks a PR, issue, or review on missing or gapped ledger data (D6).
- It does not itself decide to relax any review; that decision is deferred to the umbrella once the data supports it.
- The emission-check sweep does not verify comment authorship — any comment matching the recognized marker shapes is trusted at face value; this is an accepted residual-risk tier for a warn-only maintainer advisory, not a compliance guarantee.

## Current Status and Known Limitations

As of this writing, `phase-containment-report.ps1` over the default 90-day window reports 20 total entries (4 seed, 16 organic) and:

| Stage | n | Escape rate | Irreducible rate | Relaxation signal |
| --- | --- | --- | --- | --- |
| design-challenge | 4 | INSUFFICIENT DATA | INSUFFICIENT DATA | WITHHELD (n<5) |
| plan-stress-test | 1 | INSUFFICIENT DATA | INSUFFICIENT DATA | WITHHELD (n<5) |
| code-review | 15 | 0.00 | 1.00 | ELIGIBLE (escape_rate ~0, no critical findings) |

Only code-review has crossed the n≥5 trust threshold. The design-challenge and plan-stress-test corpora are still thin — the four design-challenge entries are the #760 calibration seeds, and the single plan-stress-test entry is the only organic annotation recorded so far. Neither stage's relaxation signal is meaningful yet; more organic data is needed before either number can support a real decision.

Known limitations:

- **#772 (sub-1 hardening) is still open.** Deferred findings from PR #770's review include comment-pagination past the first 100 comments on the two-surface walker, a REST-fallback path that ignores `WindowDays`, a REST-fallback path that drops `createdAt` (degrading dedup to first-seen-wins), and a `finding_key` format that is checked for presence but not pattern. None of these trigger on the current corpus size, but they remain open technical debt on the reader side.
- **The emission-check's single-target mode has no dry-run flag.** `phase-containment-emission-check.ps1 -Pr N` or `-Issue N` always posts its advisory report via `Find-OrUpsertComment` — there is no read-only mode that computes the gap without writing a comment. This was discovered during #782's CE Gate pass. It is a usability gap worth fixing, not a defect: the report is idempotent (find-or-upsert on a fixed marker) and warn-only, so repeated runs do not compound, but a maintainer who wants to preview the gap without touching the PR/issue currently cannot.
- **Corpus data is thin.** design-challenge (n=4) and plan-stress-test (n=1) are both below the n≥5 threshold; only code-review (n=15, escape_rate=0.00) has produced a trustworthy signal so far.

## Non-Goals

- Deciding to relax any review — that decision is gated on data this system produces and lives with the umbrella (#761).
- Enforcing emission (blocking a PR/issue on a missing ledger block) — the `-Mode enforce` parameter is accepted for forward compatibility but is currently unimplemented; the shipped behavior is warn-only regardless of the value supplied.
- Identity-precise `finding_key`-to-judge-ID correlation in the emission-check sweep — warnings are count-based (sustained N vs. blocks M); precise per-finding correlation is deferred.
- Reader-side walker robustness beyond the current corpus size — tracked as #772, not re-solved here.
