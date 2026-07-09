# Pester 5→6 Migration

**Date**: 2026-07-09
**Issue**: #818 — CI: migrate Pester test suite to 6.x (pinned to 5.x as interim)
**Purpose**: Unpin `.github/workflows/pester.yml` from the Pester 5.x hold-pin to a 6.x major-version window, port every test file that relied on Pester 5's removed mock fall-through behavior, and add a standing guard so the fall-through anti-pattern cannot silently regress.

---

## Problem

Pester 6 changed unmatched-`Mock` behavior: when a `Mock <cmd> -ParameterFilter {...}` is active and a call matches no filter, Pester 6 **throws** instead of Pester 5's silent fall-through to the underlying command. `.github/workflows/pester.yml` originally installed Pester with `-MinimumVersion 5.0.0` and no ceiling, which auto-resolved to 6.0.0 as soon as it shipped and turned the `pester` CI check red on every open PR (PR #815 CI triage).

The deeper issue is not just breakage — it is honesty. Several tests in this repo relied on Pester 5's fall-through to pass: a test defines a `global:<cmd>` catch-all function, layers a narrow `Mock <cmd> -ParameterFilter {...}` on top, and the assertion the author believes ran (the narrow, filtered path) never actually ran because the filter was dead — the call fell through to the catch-all and the test still went green by coincidence. The confirmed instance: `code-review-deferral-integration.Tests.ps1`'s "integrated routed:defer path" test had a filter `{ $args[0] -eq 'issue' }` that never bound, because `gh` is a mocked function whose remaining args land in `$RemainingArgs`, not the automatic `$args`. `pester ✓` did not mean what contributors believed it meant.

PR #815 shipped an interim `-MaximumVersion 5.999.999` hold-pin to restore green CI. This document records the migration that replaces that hold with a durable fix: port the suite, unpin to a 6.x window, and add a guard that makes the honesty property a standing, machine-checked contract rather than a one-time cleanup.

Full history, the customer framing, and the full adversarial-review trail live on [issue #818](https://github.com/Grimblaz/agent-orchestra/issues/818); the `<!-- plan-issue-818 -->` comment carries the approved 7-step plan, Verification Evidence, and Named Decisions.

## Implemented Surface

| File | Role |
| --- | --- |
| `.github/workflows/pester.yml` | Install/Import lines carry the `-MinimumVersion 6.0.0 -MaximumVersion 6.999.999` window (both lines); guard registered in the CI-scoped run list |
| `.github/scripts/Tests/pester-mock-fallthrough-guard.Tests.ps1` | New standing guard — 3-clause contract (D2 below) |
| `.github/scripts/capture-pester6-baseline.ps1` + `.github/scripts/lib/pester6-baseline-core.ps1` | One-time baseline-capture tooling (D3 below) |
| `.github/scripts/compare-pester6-baseline.ps1` + `.github/scripts/lib/pester6-baseline-delta-core.ps1` | One-time acceptance delta-gate tooling (D3 below) |
| 6 ported test files (see D1) | Layered-mock porting idiom applied per-site |
| 2 non-mock discovery fixes (see D1) | Break-class fixes found via baseline diffing |

## Design Decisions

### D1 — Porting idiom: layered Pester-native mocks, per-site not mechanical

Each fall-through-reliant site ports to Pester 6's official idiom: one default (unfiltered) `Mock <cmd>` that reproduces the old catch-all's dispatch logic, plus narrow `-ParameterFilter` mocks layered on top for per-test overrides. The port was deliberately **per-site**, not a mechanical find-replace, because two classes of latent bugs only surface when a human reads what the filter was actually meant to intercept:

1. **Filter predicate narrowing.** A filter like `{ $args[0] -eq 'issue' }` is too broad if it was meant to intercept `issue view --json body` specifically — a broad filter also matches unrelated calls (e.g. `Add-FollowUpIssue`'s `issue create` or its `--json id` node-lookup call) and produces new, different dead-filter bugs even after the syntax is "fixed."
2. **Remaining-args rebinding.** The suite mocks functions whose actual parameter name varies: `$Args` (~55 sites), `$ghArgs` (12 sites), `$RemainingArgs` (4 sites) — not the automatic `$args`, which those functions never populate. Capital `$Args` also shadows the automatic `$args`, so a hardcoded rename manufactures new dead filters instead of fixing the existing ones. Native-command mocks (no wrapping function) keep `$args`.

Two porting tiers applied, driven by the migration-scan's per-file throw-condition classification (whether the code-under-test ever makes a call that would actually miss the filter):

- **Behavior-preserving ports** (2 files: `code-review-deferral-integration.Tests.ps1`, `cost-walker.Tests.ps1`) — the default mock body must reproduce the prior fall-through behavior exactly (fixture delegation, `$LASTEXITCODE` side effects, call-through to the real cmdlet where a test depends on real behavior), because the code-under-test genuinely relies on multiple call shapes hitting the mock.
- **Guard-coherence-only ports** (4 files: `Get-AcTermsFromIssue.Tests.ps1`, `frame-validate.Tests.ps1`, `quick-validate.Tests.ps1`, `cost-walker-copilot.Tests.ps1`) — the code-under-test only ever makes calls that match the existing filter, so no behavior rewrite was needed; these files took only the guard-coherence edit (a default mock, or an allowlist entry) plus sound invoke-pairing.

The same audit also found two **non-mock** break-class bugs via baseline diffing rather than static scan: `create-improvement-issue.Tests.ps1` had a hard Pester-version pin, and `frame-audit-report.Tests.ps1` had a `BeforeAll`/`BeforeDiscovery` timing bug. Several more files received mechanical fixes for empty `-ForEach`/`-TestCases` coverage guards and unpaired `<...>` name tokens.

### D2 — Standing guard: sound invoke-pairing (supersedes the design-phase mechanism)

`.github/scripts/Tests/pester-mock-fallthrough-guard.Tests.ps1` is a new meta-test, modeled on `script-safety-contract.Tests.ps1`'s precedent (AST-based scan — not text/regex over source — a centralized `$allowlist` with per-entry justification, self-exclusion, and falsifiability fixtures), registered in `pester.yml`'s CI-scoped run list. It enforces three clauses:

1. **Fall-through shape.** Any command with ≥1 filtered `Mock -ParameterFilter` and no same-file default (unfiltered) `Mock` is flagged, unless the `(File, Command)` site is allowlisted. This fires regardless of whether a `global:<cmd>` catch-all is present, because ~166 of the repo's 186 test files never run in CI — static coverage is the only signal available for files outside the run list.
2. **Sound invoke-pairing.** This is the load-bearing decision `d-dead-filter-tripwire-v2`, which **supersedes** the design-phase decision `d-dead-filter-tripwire`. The design-phase mechanism required only that a filtered `Mock -ParameterFilter {F}` be paired, somewhere in the same file, with *any* `Should -Invoke` on the same command. Plan stress-test finding M3 proved this unsound: `Should -Invoke` evaluates its *own* filter argument independently of the `Mock`'s filter, so a `Should -Invoke <cmd> -ParameterFilter {F'}` with a *different, correct* filter `F'` passes cleanly even while the `Mock`'s own filter `F` never matched a single call — the dead filter stays dead and undetected. The shipped v2 mechanism requires the pairing to use a **textually identical** (whitespace-normalized) filter and asserts `-Times N` with `N >= 1`: `Mock <cmd> -ParameterFilter {F}` must pair, in the same file, with `Should -Invoke <cmd> -Times N (N>=1) -ParameterFilter {F}` (the same `F`, not a different filter for the same command). Because a dead `Mock` filter matches zero calls, its identically-filtered `Should -Invoke -Times >=1` assertion necessarily fails — the dead filter can no longer hide behind an unrelated, correctly-filtered assertion. The escape hatch is a justified allowlist entry at **per-mock-site** (`File` + `Command`) granularity; one allowlist exempts a site from both clause 1 and clause 2 rather than inventing two exemption mechanisms.
3. **Version-window, fail-loud.** The validated Pester major is derived from `pester.yml`'s `Install-Module` line `-MinimumVersion` floor (single source of truth). Both the `Install-Module` and `Import-Module` lines must carry a `-MaximumVersion` whose major equals that floor, and the floor major must be ≥ 6. If the pin cannot be located or parsed, the guard fails loudly (a named test failure) rather than silently reporting a pass.

**Known non-blocking limitations** (raised in adversarial code review, judge-ruled sustained-but-non-blocking, documented here as known scope for future maintainers rather than fixed in this PR):

- **File-scope, not Pester-scope, grouping.** Clauses 1 and 2 group `Mock`/`Should -Invoke` sites by command name across the *entire file's* AST, not per `Describe`/`Context` block. A file with multiple independent scopes that each mock the same command differently is evaluated as one combined group — the guard cannot distinguish "this scope's filtered mock is dead" from "some other scope in the file happens to have a matching default or pairing."
- **Major-only version-window check.** Clause 3 validates only that the major version component matches across floor/cap and meets the ≥6 floor; it does not re-validate on every 6.x minor/patch release. This is deliberate — see D4's acceptance of intra-major semver drift — but means the guard would not catch a 6.x minor introducing new breaking mock semantics.

### D3 — One-time baseline/delta acceptance-gate tooling (not standing CI)

AC1's "zero new failures under 6.x" acceptance criterion needed to be executable and machine-checked rather than eyeballed, because the full 186-file suite has pre-existing failures owned by #566 that must not be silently absorbed into or laundered through this migration. Two new script pairs, both following the repo's lib+wrapper+Pester-tests Script Library Convention, deliver this:

- **`capture-pester6-baseline.ps1` + `lib/pester6-baseline-core.ps1`** — runs the full suite under an explicit, mandatory `-RequiredVersion` (never "newest installed") and captures **per-test identity** (full `Describe > Context > It` path) plus **failure reason** for every non-passing test. `-ForEach`/`-TestCases` instances whose own name doesn't vary with their case data would otherwise collapse to duplicate identities in the result set — a real bug found and fixed during code review (not present in the original plan) — so the capture tool disambiguates only the colliding groups with a synthetic `[instance N of M]` ordinal suffix, leaving every already-unique identity untouched.
- **`compare-pester6-baseline.ps1` + `lib/pester6-baseline-delta-core.ps1`** — diffs a baseline artifact against a candidate artifact at test-identity level and computes `newFailures` (AC1 violations) and `reasonChanged` (the **#566-laundering guard**: a test that is failing in both the baseline and the candidate, but for a *different reason*, would otherwise silently pass a naive identity-only diff while actually representing a new, unrelated defect masquerading as a pre-existing one). The verdict is PASS iff both sets are empty.

Both tools are **one-time acceptance-evidence tooling for this migration, not standing CI infrastructure** — they are deliberately not registered in `pester.yml` and their output artifacts live under `.tmp/issue-818/`, not `Documents/Design/` (an earlier plan draft proposed committing baseline JSON under `Documents/Design/`; that was corrected before implementation, and the corrected path is documented directly in the wrapper scripts' own parameter docs).

### D4 — Unpin shape: major-version window, not a floor-only unpin

`pester.yml`'s `Install-Module` and `Import-Module` lines both carry `-MinimumVersion 6.0.0 -MaximumVersion 6.999.999`, with a rewritten comment block naming the contract: floor = validated major, cap = next breaking major, both bumped together deliberately on the next major migration. A floor-only unpin (`-MinimumVersion 6.0.0`, no cap) was rejected — it would re-run this exact incident on Pester 7's release day. Intra-major (6.x minor/patch) drift is accepted as ordinary semver trust, consistent with the repo's existing unpinned `powershell-yaml` install; an intra-major re-validation gate was considered and dismissed as over-engineering against this posture.

## Rejected Alternatives

- **Bare invoke-pairing (any `Should -Invoke` on the same command, any filter)** — the design-phase mechanism, proven unsound at plan stress-test (M3) and superseded by D2's identical-filter + `-Times ≥1` requirement.
- **Fold all behavior into `global:` functions with no `Mock` layering** — loses `Should -Invoke` assertion integration, which the sound invoke-pairing rule depends on.
- **Per-subcommand explicit filtered mocks covering every call, no default layer** — verbose, brittle, and still throws on any missed call; the default-mock layer is strictly safer.
- **Docs-only convention or runtime-throw-only guard** — an unenforced convention erodes over time, and a runtime throw never fires in CI for the ~166 files outside the CI-scoped run list; a default mock would silence the throw entirely for those files (the exact gap the escalated finding F3 identified).
- **Full-suite green under 6.x, absorbing #566** — multiplies scope with work unrelated to the Pester migration; delta-neutral acceptance keeps #566 as the pre-existing-failure home.
- **Floor-only unpin** — see D4.
- **Scattered suppression comments for guard exceptions** — no audit chokepoint; the centralized, per-entry-justified `$allowlist` follows the `script-safety-contract.Tests.ps1` precedent instead.

## Verification Evidence

Full 186-file suite, identical counts under both Pester 5.7.1 and 6.0.0 post-port: total=3417, passed=3388, failed=1, skipped=28, discoveryErrors=0. The 1 remaining failure is `credit-input-marker-roundtrip.Tests.ps1`'s pre-existing #566-owned `--paginate` issue, unchanged before and after the migration. CI-scoped 22-file run list: 430/430 green under 6.0.0. The post-port delta gate (D3) verdict is **PASS** — zero new failures, zero reason-changes.

Adversarial code review (standard 5-pass prosecution → defense → judge pipeline) found 15 findings, 7 sustained, 4 requiring fixes before merge: an `-ForEach` identity-collapse gap in the baseline tooling (with a second-round fix after the first attempt proved incomplete for non-parameterized `-ForEach` names — see D3), an unquoted `Start-Process` argument that broke on spaced paths, and 2 missed/introduced unpaired `<...>` name tokens. The remaining 3 sustained findings were documentation nits.

## Source of Truth

This document records the design shipped for issue #818. The implementation source of truth is `.github/workflows/pester.yml`, `.github/scripts/Tests/pester-mock-fallthrough-guard.Tests.ps1`, and the ported test files themselves. Full decision history, the design-phase adversarial challenge (12 sustained findings), and the plan-phase stress-test (17 sustained findings, including the `d-dead-filter-tripwire` → `d-dead-filter-tripwire-v2` supersession) live on [issue #818](https://github.com/Grimblaz/agent-orchestra/issues/818).
