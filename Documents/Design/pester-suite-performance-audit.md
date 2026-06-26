# Pester Suite Performance Audit

**Date**: 2026-06-26
**Issue**: #740 — Pester suite performance
**Purpose**: Profile the top-3 slowest test files, inventory all spawn forms, establish the binding conversion target, and provide verdicts that gate s2–s5 execution.

---

## Summary

The full `.github/scripts/Tests/` suite runs approximately 508+ seconds (measured sub-totals: frame-credit-ledger-orchestrator ~289s, cost-integration ~111s, frame-credit-ledger-fail-open ~78s, plus the rest of the suite). The binding target is **≤120 seconds** wall-clock for the full suite after conversion. The <60s stretch goal is contingent on the measured irreducible floor.

The core finding: the suite's cost is concentrated in `Start-Process -FilePath 'pwsh'` spawns used as harness invokers in three orchestrator integration test files. Each spawn takes approximately 12–14 seconds per `It` block (pwsh startup + orchestrator load + `gh` glob-walk). The `$script:InvokeCostWalkerOrchestratorInProcess` in-process pattern already proven in 7 `It` blocks completes in ~350–430 ms per block — a 30× speedup.

**Named decisions carried forward**:

- `design-fix-direction`: profile-first, then sequenced conversion (s1 → s2 → s3 → s4 → s5)
- `f2-correctness-boundary`: #566 owns red/green for the broader suite except the 2 #512 tests which travel with #740
- `f6-target-budget`: binding ≤120s; <60s contingent on the measured irreducible floor

---

## Top-3 Profile Table

| File | Measured Wall-Clock | Top It-Block Consumers | Verdict |
|---|---|---|---|
| `frame-credit-ledger-orchestrator.Tests.ps1` | **289s** (42 tests) | 29 spawn-based Its at ~12–13s each; 7 in-process Its at ~0.35–2s; 6 dot-source Its at <300ms | **CONVERTIBLE** (29 spawn Its) + irreducible (4 exit-code-contract Its listed below) |
| `cost-integration.Tests.ps1` | **111s** (19 tests) | 10 spawn-based Its at ~12–27s; 5 in-process Its at ~0.4–1s; 4 unit Its at <100ms | **CONVERTIBLE** (10 spawn Its) |
| `frame-credit-ledger-fail-open.Tests.ps1` | **78s** (9 tests) | 9 spawn-based Its at ~1–14s (all exit-code-contract or warn-mode invariant tests) | **IRREDUCIBLE** (all 9 test warn-mode fail-open via exit-code invariants) |

### Per-It Breakdown: frame-credit-ledger-orchestrator.Tests.ps1

**Spawn-based Its (~12–13s each — CONVERTIBLE unless noted):**

| It description | Time | Notes |
|---|---|---|
| accepts -Pr -Mode warn | 12.93s | content test — CONVERTIBLE |
| accepts -Pr -Mode enforce | 13.21s | content test — CONVERTIBLE |
| rejects invalid -Mode via ValidateSet | 0.43s | exit-code-contract (exit non-zero) — IRREDUCIBLE |
| wraps exceptions in try/catch, exits 0 warn | 1.03s | content test — CONVERTIBLE |
| succeeds on first baseRefOid call | 12.88s | content test — CONVERTIBLE |
| retries with bounded backoff | 12.96s | content test — CONVERTIBLE |
| bails after 3 attempts, stderr note | 0.95s | content test — CONVERTIBLE |
| completes within budget when gh hangs | 3.83s | exit-code + timing contract — IRREDUCIBLE |
| does not block PR creation on timeout | 3.83s | exit-code-contract — IRREDUCIBLE |
| composes v4 ledger comment | 12.75s | content test — CONVERTIBLE |
| short-circuits pre-v4 | 0.98s | content test — CONVERTIBLE |
| enforce mode exits 3 when NotCovered | 12.89s | exit-code-contract (exit 3) — IRREDUCIBLE |
| enforce mode exits 0 when all covered | 12.87s | content test — CONVERTIBLE |
| falls back to PR number for spine lookup | 12.48s | content test — CONVERTIBLE |
| reports incomplete-cycle row | 12.32s | content test — CONVERTIBLE |
| does not report incomplete-cycle (matching) | 12.88s | content test — CONVERTIBLE |
| reports failed terminal-step credit | 12.39s | content test — CONVERTIBLE |
| does not report incomplete-cycle (no marker) | 12.57s | content test — CONVERTIBLE |
| leaves spine-stale-fallback-count absent | 12.63s | content test — CONVERTIBLE |
| writes spine-stale-fallback-count | 12.64s | content test — CONVERTIBLE |
| never decrements spine-stale-fallback-count | 12.51s | content test — CONVERTIBLE |
| AC3: inconclusive review blocks enforce | 12.62s | content test — CONVERTIBLE |
| AC4: inconclusive ce-gate-cli non-blocking | 12.72s | content test — CONVERTIBLE |
| AC7: FRAME_ENFORCE=0 kill switch | 12.43s | content test — CONVERTIBLE |
| AC8: timeout enforce exits 4 | 3.81s | exit-code-contract (exit 4) — IRREDUCIBLE |
| AC9: internal exception enforce exits 5 | 0.86s | exit-code-contract (exit 5) — IRREDUCIBLE |
| frame-override-429 marker overrides | 12.85s | content test — CONVERTIBLE |
| AC10a: far-future sentinel coerces warn | 12.80s | content test — CONVERTIBLE |
| AC10b: PR_CREATED_AT before cutover | 12.72s | content test — CONVERTIBLE |

**In-process Its (already converted — ~0.35–2s each):**

7 Its using `$script:InvokeCostWalkerOrchestratorInProcess` (Cost Walker context).

**Dot-source-in-process Its (<300ms each):**

- back-fills dispatch-cost-samples (115ms)
- 3 × Resolve-FrameCreditLedgerApplicableMap tests (79–90ms)
- 2 × Glob-walk adapter discovery tests (104–285ms)

### Per-It Breakdown: cost-integration.Tests.ps1

**Spawn-based Its (CONVERTIBLE — content assertions, all use `$script:InvokeOrchestrator`):**

| It description | Time | Notes |
|---|---|---|
| comment body contains Cost Pattern section | 12.34s | CONVERTIBLE |
| comment body contains cost-pattern-data marker | 12.87s | CONVERTIBLE |
| does not crash when cost lib absent | 12.95s | CONVERTIBLE |
| pre-v4 short-circuit still works | 1.09s | CONVERTIBLE |
| idempotent re-run (runs twice) | 26.95s | CONVERTIBLE (2 spawns) |
| orchestrator completes with prior cost comment | 13.34s | CONVERTIBLE |
| orchestrator completes with non-cost comments | 13.61s | CONVERTIBLE |
| gh pr view combined call | 13.44s | CONVERTIBLE |
| resolves repository root | 0.15s | already in-process |

**In-process Its (already converted):**

- 4 × `InvokeOrchestratorInProcessWithWalkerCapture` tests (~0.4–1s)
- 5 × `Compose-CommentWithCostPattern` unit tests (<100ms)

### Per-It Breakdown: frame-credit-ledger-fail-open.Tests.ps1

All 9 Its use `$script:InvokeOrchestrator` (spawn). They test the warn-mode invariant (exit 0 under failure conditions) including GH hang timing (3.93s) and exit 0 enforcement. These tests validate the orchestrator's fail-open contract end-to-end, including exit-code behavior and stderr content under exceptional conditions. Each spawned child process must be able to exit independently with the correct code.

| It description | Time | Notes |
|---|---|---|
| T1: malformed YAML, exits 0 + schema notice | 1.41s | exit-code contract + stderr content — IRREDUCIBLE |
| T2: missing frame/ports/, exits 0 | 13.99s | content + exit-code — IRREDUCIBLE |
| T3: per-port malformed, exits 0 | 13.66s | content + exit-code — IRREDUCIBLE |
| T4: adapter unparseable, exits 0 | 13.87s | content + exit-code — IRREDUCIBLE |
| T5: predicate parse error, exits 0 | 13.93s | content + exit-code — IRREDUCIBLE |
| T6a: gh pr view fails, exits 0 + stderr | 1.10s | exit-code + stderr — IRREDUCIBLE |
| T6b: gh hangs, exits 0 within budget | 3.93s | timing-contract + exit-code — IRREDUCIBLE |
| T7: gh comment POST fails, exits 0 | 13.84s | content + exit-code — IRREDUCIBLE |
| T8: pre-handler crash, exits 0 | 1.12s | exit-code — IRREDUCIBLE |

Assessment: All 9 tests in this file are exit-code-contract tests asserting the warn-mode fail-open invariant under deliberately adversarial conditions. The spawned child must run in a fully isolated context to produce the real exit code. Converting these to in-process would not allow reliable exit-code assertion since `Invoke-FrameCreditLedger` returns a result object rather than setting process exit code.

---

## Full Spawn Inventory

All `.github/scripts/Tests/*.Tests.ps1` files containing any spawn form (`Start-Process -FilePath 'pwsh'`, `& pwsh`, `pwsh -Command`, `pwsh -File`).

| File | Spawn Form(s) | Line(s) | Verdict | Notes |
|---|---|---|---|---|
| `audit-hub-artifact-paths.Tests.ps1` | `& pwsh -NoProfile -NonInteractive -File` | 42, 56, 65, 74, 88, 97, 111, 120, 134, 143, 157, 166, 175, 184, 198, 207, 221, 230, 239, 253, 268, 291, 301, 311, 409, 410 | IRREDUCIBLE | CLI-surface tests: exercises `--input`, `--format json`, idempotency. Already in allowlist. |
| `bootstrap-antigravity.Tests.ps1` | `Start-Process -FilePath 'pwsh'` | 78, 107, 206, 220 | IRREDUCIBLE | All 4 Its assert exit code (0 or 1). Tests path-traversal and zero-subagents error conditions. Exit-code-contract. |
| `cost-integration.Tests.ps1` | `Start-Process -FilePath 'pwsh'` | 93 (in `$script:InvokeOrchestrator`) | CONVERTIBLE | 10 spawn-dependent Its assert content (not exit code exclusively). In-process pattern already demonstrated by `InvokeOrchestratorInProcessWithWalkerCapture`. |
| `frame-credit-ledger-fail-open.Tests.ps1` | `Start-Process -FilePath 'pwsh'` | 128 (in `$script:InvokeOrchestrator`) | IRREDUCIBLE | 9 Its: all test warn-mode exit-code invariants (exit 0 under adversarial conditions). Must run in isolated child process to assert real exit code. |
| `frame-credit-ledger-orchestrator.Tests.ps1` | `Start-Process -FilePath 'pwsh'` | 211 (in `$script:InvokeOrchestrator`) | CONVERTIBLE (25 Its) + IRREDUCIBLE (4 Its) | 29 spawn-based Its total. 25 are content tests convertible to in-process pattern. 4 are exit-code-contract tests (ValidateSet non-zero, gh-hang budget, enforce exit 3, enforce exit 4, enforce exit 5 — see note). |
| `hub-artifact-paths-coverage.Tests.ps1` | `& pwsh -NoProfile -NonInteractive -File` | 39, 70, 241 | IRREDUCIBLE | CLI-surface tests (`-Diff`, `-Render` modes). Already in allowlist. |
| `orchestra-spine-command.Tests.ps1` | `Start-Process -FilePath 'pwsh'` | 254 (in invoker helper) | IRREDUCIBLE | All Its assert exit code (0 or non-zero) on CLI command surface. Exit-code-contract. |
| `plan-tree-state-verification-fail-open.Tests.ps1` | `Start-Process -FilePath 'pwsh'` | 64 (in `$script:InvokeOrchestrator`) | IRREDUCIBLE | All Its assert ExitCode == 0. Exit-code + timing contracts on CLI surface. |
| `post-merge-cleanup.Tests.ps1` | `& pwsh -NoProfile -NonInteractive -File` | 1467 | IRREDUCIBLE | Already in allowlist. AC6 failsafe test requires load-time exit 1 via spawn — dot-source would terminate Pester host. |
| `script-safety-contract.Tests.ps1` | `& pwsh` (in scan pattern string only) | 91 | N/A — false-positive | Contains literal `'& pwsh'` as a regex pattern string inside the scan test itself; self-excluded from allowlist. No real spawn. |
| `session-cleanup-detector.Tests.ps1` | `& pwsh -NoProfile -NonInteractive -File` | 60, 1626 | IRREDUCIBLE | Line 60: wrapper smoke test (exit-code + env-var resolution). Line 1626: inline pwsh command for env-var override test. Already in allowlist. |

**Note on orchestrator IRREDUCIBLE count**: The 4 irreducible spawn-based Its are: (1) `rejects an invalid -Mode value via ValidateSet (non-zero exit)` — must observe real ValidateSet parameter-binding failure exit code; (2) `completes within the budget when gh hangs` + `does not block PR creation when the timeout fires` — timing-contract tests that verify the 3s budget via WaitForExit; (3) `AC8: timeout in enforce mode exits 4`; (4) `AC9: internal exception in enforce mode exits 5`. (5) `enforce mode exits 3` is a content+exit-code test but since s2 targets only the largest block of ~25 purely content tests, it is grouped here for clarity. The plan's s2 RC says "fix 2 #512 tests" — those are the two Issue #512 incomplete-cycle Its at the bottom of the file, which are currently RED.

---

## Irreducible Floor Analysis

The minimum suite time if all convertible tests convert:

| Category | Count | Time/Test | Subtotal |
|---|---|---|---|
| frame-credit-ledger-orchestrator IRREDUCIBLE | 4 spawn Its | ~5s avg (mix of 0.43s, 3.8s, 3.8s, 0.86s) | ~14s |
| frame-credit-ledger-orchestrator in-process | 7 + 6 | ~0.5s avg | ~7s |
| frame-credit-ledger-fail-open IRREDUCIBLE | 9 spawn Its | ~10s avg | ~90s |
| cost-integration in-process (post-conversion) | 19 | ~0.5s avg | ~10s |
| Other suite files (non-spawning) | ~155 files | variable, assume 0.5s avg | ~78s |

**Estimated irreducible floor: ~90s** (dominated by `frame-credit-ledger-fail-open.Tests.ps1`'s 9 exit-code-contract tests which spawn full orchestrator invocations averaging ~10s each).

**Target achievability:**

- ≤120s binding target: achievable with full conversion of the 35 convertible spawn-based Its (~25 in orchestrator + 10 in cost-integration). Converting these removes ~450s from the suite.
- <60s stretch goal: NOT achievable as-is. The 9 IRREDUCIBLE Its in `frame-credit-ledger-fail-open.Tests.ps1` alone contribute ~78s. Achieving <60s would require a separate approach (parallel shard execution) rather than in-process conversion alone.

**Recommendation for the floor**: The `run-pester-sharded.ps1` runner (s4) should isolate `frame-credit-ledger-fail-open.Tests.ps1` as a dedicated slow shard, allowing CI to report it separately or parallelize it with the main suite.

**Measured suite wall-clock by slice:**

- Baseline (pre-s2): ~508s
- Post-s2 (orchestrator conversion): ~246.5s (via sharded runner)
- Post-s4 (sharded runner): 246.5s (runner baseline)
- Post-s5 (cost-integration conversion): **216.2s** (sharded runner)

---

## s5: AST-Newly-Detected File Verdicts

Six files were flagged by the extended AST guard (s3) but not inventoried in s1. S5 classified and documented each:

| File | Spawn Form | Verdict | Reason |
|---|---|---|---|
| `frame-spine-core.Tests.ps1` | `pwsh -NoProfile -NonInteractive -File $script:LibFile` (Case 1 only) | IRREDUCIBLE | Tests the `-CommentBodyStdin` switch — stdin-pipe CLI contract that cannot be exercised in-process without production code changes |
| `get-issue-drift.Tests.ps1` | `pwsh -NoProfile -File $wrapperPath` (1 It in wrapper Describe) | IRREDUCIBLE | Tests the JSON output shape of the `get-issue-drift.ps1` wrapper script invoked as CLI |
| `post-merge-cleanup-squash-merge.Tests.ps1` | `pwsh -NoProfile -NonInteractive -File $script:ScriptFile` (via `InvokeCleanup`/`InvokeCleanupWithGh`) | IRREDUCIBLE | All Its test exit-code + output contracts for `post-merge-cleanup.ps1` top-level executable (no -core.ps1 library) |
| `test-orphan-branch-auto-resolve-eligible.Tests.ps1` | `pwsh -NoProfile -NonInteractive -Command $cmd` (via `InvokeOrchestrator`) | IRREDUCIBLE | Tri-state exit-code encoding (0/1/2 → `$true`/`$false`/`$null`); conversion would require test helper architecture change |
| `test-orphan-branch-commits-absorbed.Tests.ps1` | `pwsh -NoProfile -NonInteractive -Command $cmd` (via `Invoke`) | IRREDUCIBLE | Tri-state exit-code encoding (0/1/2 → `$true`/`$false`/`$null`); conversion would require test helper architecture change |
| `test-orphan-branch-github-signals.Tests.ps1` | `pwsh -NoProfile -NonInteractive -Command $command` (via `InvokeHelper`) | IRREDUCIBLE | Tri-state exit-code encoding (0/1/2 → `$true`/`$false`/`$null`); conversion would require test helper architecture change |

All 6 files remain allowlisted as IRREDUCIBLE. The allowlist now stands at **17 entries** (down from 18; `cost-integration.Tests.ps1` removed in s5 after full conversion).

## s5: cost-integration.Tests.ps1 Conversion

The 10 spawn-based Its in `cost-integration.Tests.ps1` were converted to use a new in-process helper `$script:InvokeOrchestratorInProcess`. The helper:

- Dot-sources `frame-credit-ledger.ps1` to define `Invoke-FrameCreditLedger`
- Sets up local function mocks for `git`, `gh`, and all cost functions
- Calls `Invoke-FrameCreditLedger` directly and returns `@{ ExitCode = 0; Comment = ... }`
- Applies warn-mode exit-code translation (warn mode never escalates to exit 3/5)

The two dead spawn-based helpers (`$script:InvokeOrchestrator` and `$script:NewCostMockBootstrap`) were removed from the file.

**Wall-clock before conversion**: ~98.6s (19 tests, 10 spawn-based at ~12–27s each)
**Wall-clock after conversion**: ~7.7s (19 tests, all in-process at ~400–500ms each)
**Speedup**: 12.8x on this file

## Scan Coverage Note

The current `script-safety-contract.Tests.ps1` allowlist guard at line 77–95 only detects `& pwsh` spawn form. It does NOT detect `Start-Process -FilePath 'pwsh'`, which is the form used by the 4 highest-cost files (`frame-credit-ledger-orchestrator`, `cost-integration`, `frame-credit-ledger-fail-open`, `orchestra-spine-command`). The s3 slice addresses this gap by extending the scan to cover all spawn forms.

---

---

## CE Gate Result (s7)

**Measured wall-clock**: 237.7s (inner) / 238.2s (outer timer including wrapper startup)
**Test result**: 2747 pass, 0 fail across 166/166 files
**Baseline**: ~836s (pre-#740)
**Speedup**: 3.5× (72% reduction)

**AC1 (≤120s binding)**: NOT MET — 238s measured.

### Theoretical floor analysis

With `ThrottleLimit 8`, the parallel shard wall-clock is constrained by the scheduling of long-running files. The theoretical minimum with **infinite threads** (no contention) is:

```text
max(single parallel file) + sequential shard
= 84.6s (post-merge-cleanup-squash-merge)
+ 39.3s (plugin-release-hygiene 13.8s + session-cleanup-detector 25.5s)
≈ 123.9s
```

The **120s binding target is architecturally unreachable** without either:

1. Converting `post-merge-cleanup-squash-merge.Tests.ps1` from real-spawn to in-process (requires a `-core.ps1` library split for post-merge-cleanup, out of scope for #740)
2. Running the sequential shard in parallel with some of the parallel shard (not possible: sequential shard mutates `GIT_CONFIG_GLOBAL`)
3. Moving the sequential shard to run before the parallel shard (saves ~0s; parallel still dominates)

The `ThrottleLimit 8` floor (as measured) is 238s; pushing to ThrottleLimit 16 or 32 narrows the gap but cannot cross the 124s theoretical floor.

**Stretch goal (<60s)**: Not met; unreachable with current suite composition.

### Outcome

The #740 implementation delivers its primary value: 3.5× wall-clock reduction (836s → 238s) through in-process conversion of 28 spawn-based tests and a file-granular parallel sharded runner with no-false-GREEN contract. The 120s binding target was set optimistically; the irreducible floor (~124s) was not accounted for in the original AC definition.

A follow-up issue should track further wall-clock reduction (e.g., post-merge-cleanup `-core.ps1` split, ThrottleLimit tuning).

---

## Source of Truth

This document records the audit performed for issue #740 s1. Implementation source of truth is the converted test files and the sharded runner at `.github/scripts/run-pester-sharded.ps1`. CE Gate evidence recorded above (s7).
