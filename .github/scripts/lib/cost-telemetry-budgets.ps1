#Requires -Version 7.0
<#
.SYNOPSIS
    Central named constants for the cost-telemetry budget chain (issue #496).
.DESCRIPTION
    Before this file, the four coupled knobs of the cost-telemetry budget chain
    were hardcoded literals scattered across two files. They NEST, so editing one
    in isolation silently breaks the chain:

        claudeWalker + copilotWalker + renderMargin  <=  costSubBudget
        costSubBudget + outerSlack                   <=  outerBudget

    The outer budget is a HARD WALL, not a hint: the watchdog in
    frame-credit-ledger.ps1 does `WaitOne(budgetSeconds * 1000)` and then
    `$worker.Stop()`.
    Raising an inner knob alone therefore changes NOTHING — the outer wall still
    kills the worker at the old deadline. That trap is the whole reason these
    constants live together in one file, and it is why
    Tests/cost-telemetry-budgets.Tests.ps1 asserts the nesting relationship
    rather than any single value.

    WHY THE WALKER VALUES ARE WHAT THEY ARE (issue #496)
    The previous 10s timeout on the Claude walker failed DETERMINISTICALLY — not
    flakily — on any machine with a grown Claude profile. Measured on a real
    profile (~/.claude/projects = 696 MB / 1770 jsonl files; the
    Copilot-Orchestra slug alone = 139 MB / 34 files), the walk needed 69.1
    seconds against its 10s budget, so cost telemetry was silently lost and the
    `Cost Pattern Presence Check` CI job failed. The corpus grows ~22 MB/day, so
    these values carry real headroom rather than a token bump: 180s is ~2.6x the
    measured 69.1s.

    Raising a timeout is nearly free. A timeout only binds in the slow case; it
    is a ceiling, not a sleep. In CI there are no transcripts, so the walk
    returns instantly and the higher ceiling never engages.

    NOT centralized here, deliberately:
      - the retry loop in `.github/workflows/cost-pattern-presence-check.yml`
        (5 attempts, `sleep 10` between them) — YAML cannot dot-source
        PowerShell, so that budget cannot read these constants. It is a
        separate post-hoc polling budget, not part of the walker chain.

    APOSTROPHE HYGIENE: the prose in this file deliberately avoids possessive
    apostrophes. audit-hub-artifact-paths.ps1 scans .github/scripts/lib/*.ps1
    and extracts path references using a naive single-quote pairing regex (see
    its $singleQuoteRegex) that treats EVERY apostrophe — including one inside
    a comment — as a string delimiter. Adding an odd number of them re-pairs
    every quoted span later in the file and corrupts the extracted path
    inventory, which trips Tests/hub-artifact-paths-coverage.Tests.ps1 with a
    confusing, seemingly unrelated failure.

    The rolling-history constants below are centralized for discoverability but
    are a SEPARATE GitHub-API budget, NOT part of the walker chain above. They
    are intentionally left at their pre-existing values (issue #496): no
    measurement justifies changing them, so the contract test does not tie them
    to the walker nesting relationship.

    Every consumer keeps its existing env-override behavior unchanged: an env
    var that is present AND parses as a positive int wins, otherwise the
    constant below is used. That resolution is owned by
    Get-FCLCostWalkerTimeoutSeconds (lib/cost-fcl-helpers.ps1) — consumers reuse
    it rather than reimplementing the shape.
.NOTES
    Dot-sourced by (each dot-sources it directly rather than relying on a
    caller, so the constants can never resolve to $null and silently degrade a
    budget to 0):
      - frame-credit-ledger.ps1        (outer budget; dot-sourced in the
                                        hard-required lib block, NOT the
                                        fail-open cost block — the outer
                                        watchdog runs even when cost
                                        composition is disabled)
      - lib/cost-session-render.ps1    (cost sub-budget, both walker timeouts)
      - lib/cost-rolling-history.ps1   (fetch budget, cache TTL)

    This file has no dependencies and assigns plain variables, so dot-sourcing
    it more than once in the same scope is idempotent and safe. The constants
    are intentionally NOT `Set-Variable -Option Constant`: that would throw on
    the second dot-source in a shared scope.
#>

# ---------------------------------------------------------------------------
# Walker chain (nesting is enforced by Tests/cost-telemetry-budgets.Tests.ps1)
# ---------------------------------------------------------------------------

# Innermost: per-walker ceilings. Env overrides:
#   FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS
#   FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS
# 180s is ~2.6x the measured 69.1s worst case, leaving headroom for the
# ~22 MB/day corpus growth (was 10s — deterministically insufficient).
$script:CostTelemetryClaudeWalkerTimeoutSeconds = 180
# The Copilot corpus is a single OTEL jsonl rather than a per-session tree, so
# it is far smaller; 60s is proportional headroom (was 6s).
$script:CostTelemetryCopilotWalkerTimeoutSeconds = 60

# Margin reserved inside the cost sub-budget for the non-walker work that must
# still complete after both walks return: attribution -> completeness ->
# eligibility -> preservation -> render (step 6g composes the section).
$script:CostTelemetryRenderMarginSeconds = 30

# Middle: the cost sub-budget must fit both walkers plus the render margin.
# Env override: FRAME_CREDIT_LEDGER_TEST_COST_BUDGET_SECONDS
# 180 + 60 + 30 = 270 (was 19).
$script:CostTelemetryCostSubBudgetSeconds = 270

# Slack reserved inside the outer budget for the rest of the ledger run outside
# cost composition (baseRefOid retry, PR-body fetch, adapter discovery, comment
# upsert).
$script:CostTelemetryOuterSlackSeconds = 30

# Outermost: the HARD WALL (`WaitOne` then `Stop()`). Must fit the cost
# sub-budget plus outer slack, or raising the inner knobs accomplishes nothing.
# Env override: FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS
# 270 + 30 = 300 (was 30).
$script:CostTelemetryOuterBudgetSeconds = 300

# ---------------------------------------------------------------------------
# Rolling history — a SEPARATE GitHub-API budget, not part of the chain above.
# Centralized for discoverability only; values unchanged (issue #496).
# ---------------------------------------------------------------------------

# Per-run budget for the merged-PR rolling-history fetch; returns the timed_out
# sentinel when exceeded at a yield point.
$script:CostRollingHistoryFetchBudgetSeconds = 10

# Cache freshness window for .github/scripts/cache/cost-rolling-history.json.
$script:CostRollingHistoryCacheTtlHours = 1.0
