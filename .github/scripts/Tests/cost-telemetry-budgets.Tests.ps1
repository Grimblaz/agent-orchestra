#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Contract test for the cost-telemetry budget chain (issue #496).
#
# The four budget knobs NEST. They are not independent tunables:
#
#     claudeWalker + copilotWalker + renderMargin  <=  costSubBudget
#     costSubBudget + outerSlack                   <=  outerBudget
#
# The outer budget is a HARD WALL — frame-credit-ledger.ps1's watchdog does
# `WaitOne(budgetSeconds * 1000)` then `$worker.Stop()`. So raising an inner
# knob WITHOUT raising the ones that contain it changes nothing at runtime: the
# outer wall still kills the worker at the old deadline, and the only visible
# symptom is silently-missing cost telemetry plus a red `Cost Pattern Presence
# Check`. That failure is invisible at edit time and expensive to diagnose —
# it was hit for real while raising the Claude walker timeout for #496.
#
# This test is the guard issue #496 asked for. It asserts the RELATIONSHIP, not
# the specific numbers: every value here is free to change, as long as the chain
# still nests. A future edit that raises one knob past its container fails here,
# at the cheapest possible point, instead of silently losing telemetry in
# production.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:BudgetsPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-telemetry-budgets.ps1'

    # Dot-source the real constants file — no fixtures, no duplication of the
    # values. This test reads exactly what production reads.
    . $script:BudgetsPath
    . (Join-Path $script:RepoRoot '.github/scripts/lib/cost-fcl-helpers.ps1')
}

Describe 'cost-telemetry budget chain contract (issue #496)' {

    Context 'every budget is a usable positive value' {

        It 'defines every chain constant as a positive number' {
            $chain = [ordered]@{
                'CostTelemetryClaudeWalkerTimeoutSeconds'  = $script:CostTelemetryClaudeWalkerTimeoutSeconds
                'CostTelemetryCopilotWalkerTimeoutSeconds' = $script:CostTelemetryCopilotWalkerTimeoutSeconds
                'CostTelemetryRenderMarginSeconds'         = $script:CostTelemetryRenderMarginSeconds
                'CostTelemetryCostSubBudgetSeconds'        = $script:CostTelemetryCostSubBudgetSeconds
                'CostTelemetryOuterSlackSeconds'           = $script:CostTelemetryOuterSlackSeconds
                'CostTelemetryOuterBudgetSeconds'          = $script:CostTelemetryOuterBudgetSeconds
            }

            foreach ($name in $chain.Keys) {
                $value = $chain[$name]
                $value | Should -Not -BeNullOrEmpty -Because @"
`$script:$name is unset or empty.

Every consumer treats these constants as an [int] budget. An unset constant
resolves to `$null, which becomes 0 when bound to an [int] — a 0-second budget
expires instantly, so cost telemetry would be lost on every run with no error.
Define $name in:
  .github/scripts/lib/cost-telemetry-budgets.ps1
"@
                $value | Should -BeGreaterThan 0 -Because @"
`$script:$name is $value, which is not a positive budget.

A zero or negative budget expires immediately at its first yield point, so the
walk it guards can never complete. If you meant to disable a walker, do it at
the call site — do not encode it as a non-positive budget.
"@
            }
        }

        It 'defines the separate rolling-history GitHub-API budget as positive' {
            # Not part of the walker chain (see the constants file header) —
            # asserted only for the same $null/0 degradation hazard.
            $script:CostRollingHistoryFetchBudgetSeconds | Should -BeGreaterThan 0
            $script:CostRollingHistoryCacheTtlHours | Should -BeGreaterThan 0
        }
    }

    Context 'the chain nests: each budget contains the ones inside it' {

        It 'fits both walker timeouts plus the render margin inside the cost sub-budget' {
            $claude = $script:CostTelemetryClaudeWalkerTimeoutSeconds
            $copilot = $script:CostTelemetryCopilotWalkerTimeoutSeconds
            $margin = $script:CostTelemetryRenderMarginSeconds
            $required = $claude + $copilot + $margin
            $subBudget = $script:CostTelemetryCostSubBudgetSeconds

            $required | Should -BeLessOrEqual $subBudget -Because @"
BROKEN BUDGET CHAIN: the two walkers plus the render margin do not fit inside
the cost sub-budget that contains them.

    claudeWalker   $claude s
  + copilotWalker  $copilot s
  + renderMargin   $margin s
  ---------------------------
  = required       $required s
    costSubBudget  $subBudget s   <-- must be >= $required s

WHY THIS MATTERS: the walkers run SEQUENTIALLY inside the cost sub-budget, and
the render margin is the time step-6g still needs AFTER both walks return to do
attribution -> completeness -> eligibility -> preservation -> render. If the
sub-budget cannot cover all three, the sub-budget expires first and the cost
section is never composed — telemetry is silently lost, not reported as an
error.

TO FIX: raise CostTelemetryCostSubBudgetSeconds to at least $required, or lower
a walker timeout. Then re-check the OUTER budget too — it must contain the
sub-budget you just raised. All values live in
.github/scripts/lib/cost-telemetry-budgets.ps1.
"@
        }

        It 'fits the cost sub-budget plus outer slack inside the outer hard-wall budget' {
            $subBudget = $script:CostTelemetryCostSubBudgetSeconds
            $slack = $script:CostTelemetryOuterSlackSeconds
            $required = $subBudget + $slack
            $outer = $script:CostTelemetryOuterBudgetSeconds

            $required | Should -BeLessOrEqual $outer -Because @"
BROKEN BUDGET CHAIN: the cost sub-budget plus outer slack does not fit inside
the outer budget that contains it.

    costSubBudget  $subBudget s
  + outerSlack     $slack s
  ---------------------------
  = required       $required s
    outerBudget    $outer s   <-- must be >= $required s

WHY THIS MATTERS: the outer budget is a HARD WALL, not a hint —
frame-credit-ledger.ps1 does `WaitOne(outerBudget * 1000)` and then
`$worker.Stop()`. It kills the whole ledger worker, cost composition included.
The outer slack is the time the rest of the ledger run still needs outside cost
composition (baseRefOid retry, PR-body fetch, adapter discovery, comment
upsert).

THIS IS THE TRAP: raising an inner budget alone accomplishes NOTHING. The outer
wall still stops the worker at the old deadline, so the symptom (missing cost
telemetry, red Cost Pattern Presence Check) does not change and looks like the
inner fix did not work.

TO FIX: raise CostTelemetryOuterBudgetSeconds to at least $required. All values
live in .github/scripts/lib/cost-telemetry-budgets.ps1.
"@
        }

        It 'orders the chain strictly: walkers < cost sub-budget < outer budget' {
            # Redundant with the two margin assertions above by construction, but
            # states the invariant a reader checks by eye, and catches a
            # margin that was zeroed out to force a broken chain through.
            $script:CostTelemetryClaudeWalkerTimeoutSeconds |
                Should -BeLessThan $script:CostTelemetryCostSubBudgetSeconds `
                    -Because 'a single walker must never be able to consume the entire cost sub-budget that contains it'
            $script:CostTelemetryCostSubBudgetSeconds |
                Should -BeLessThan $script:CostTelemetryOuterBudgetSeconds `
                    -Because 'the outer budget is the hard wall; a cost sub-budget >= the outer budget can never be reached before the worker is stopped'
        }
    }

    Context 'consumers resolve the constants instead of re-hardcoding literals' {
        # Without this, the chain contract above can be bypassed: a future edit
        # that hardcodes a literal back into a consumer would keep this file's
        # constants consistent while the running code ignores them entirely.

        It 'resolves the outer budget from the constant in frame-credit-ledger.ps1' {
            $content = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1') -Raw
            $content | Should -Match 'lib/cost-telemetry-budgets\.ps1' `
                -Because 'frame-credit-ledger.ps1 must dot-source the budgets file to resolve the outer budget'
            $content | Should -Match '\$budgetSeconds\s*=\s*\$script:CostTelemetryOuterBudgetSeconds' `
                -Because 'the outer budget must come from the constant, not a re-hardcoded literal'
        }

        It 'resolves the sub-budget and both walker timeouts from constants in cost-session-render.ps1' {
            $content = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/scripts/lib/cost-session-render.ps1') -Raw
            $content | Should -Match 'cost-telemetry-budgets\.ps1'
            $content | Should -Match '\$costBudgetSeconds\s*=\s*\$script:CostTelemetryCostSubBudgetSeconds'
            $content | Should -Match '-DefaultSeconds\s+\$script:CostTelemetryClaudeWalkerTimeoutSeconds'
            $content | Should -Match '-DefaultSeconds\s+\$script:CostTelemetryCopilotWalkerTimeoutSeconds'
        }

        It 'resolves the fetch budget and cache TTL from constants in cost-rolling-history.ps1' {
            $content = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/scripts/lib/cost-rolling-history.ps1') -Raw
            $content | Should -Match 'cost-telemetry-budgets\.ps1'
            $content | Should -Match '\$TimeoutSeconds\s*=\s*\$script:CostRollingHistoryFetchBudgetSeconds'
            $content | Should -Match '\$age\.TotalHours\s+-lt\s+\$script:CostRollingHistoryCacheTtlHours'
        }

        It 'resolves the rolling-history CALLER timeout in cost-session-render.ps1 from the constant (CR-1)' {
            # The previous assertion above only checks the DEFINITION site
            # (cost-rolling-history.ps1's own [TimeoutSeconds] parameter
            # default). It never checked this CALLER site — the
            # Get-CostRollingHistory call inside Invoke-CostSessionRender,
            # which overrides that default with its own [Math]::Min(...)
            # expression. A hardcoded literal 10 there silently bypassed the
            # constant while every other assertion in this file stayed green,
            # which is exactly how CR-1 shipped unnoticed.
            $content = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/scripts/lib/cost-session-render.ps1') -Raw
            $content | Should -Match 'Get-CostRollingHistory\s+-TimeoutSeconds\s*\(\[Math\]::Min\(\s*\$script:CostRollingHistoryFetchBudgetSeconds\s*,' `
                -Because 'the rolling-history caller in cost-session-render.ps1 must reference $script:CostRollingHistoryFetchBudgetSeconds, not a re-hardcoded literal'
        }
    }

    Context 'env overrides still win over the constants (behavior preserved)' {

        It 'prefers a valid positive env override to the constant default' {
            $previous = $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS
            try {
                $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS = '7'
                $resolved = script:Get-FCLCostWalkerTimeoutSeconds `
                    -EnvironmentVariableName 'FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS' `
                    -DefaultSeconds $script:CostTelemetryClaudeWalkerTimeoutSeconds
                $resolved | Should -Be 7
            }
            finally {
                $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS = $previous
            }
        }

        It 'falls back to the constant default when the env override is absent or invalid' {
            $previous = $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS
            try {
                foreach ($invalid in @($null, '', 'not-an-int', '0', '-5')) {
                    if ($null -eq $invalid) {
                        Remove-Item Env:\FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS -ErrorAction SilentlyContinue
                    }
                    else {
                        $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS = $invalid
                    }
                    $resolved = script:Get-FCLCostWalkerTimeoutSeconds `
                        -EnvironmentVariableName 'FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS' `
                        -DefaultSeconds $script:CostTelemetryClaudeWalkerTimeoutSeconds
                    $resolved | Should -Be $script:CostTelemetryClaudeWalkerTimeoutSeconds `
                        -Because "an override of '$invalid' is not a valid positive int, so the constant default must win"
                }
            }
            finally {
                $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS = $previous
            }
        }
    }
}

# Regression test for issue #496 C-1 (post-review fix). Every assertion above
# either Should -Match's file TEXT or calls a function INLINE in this same
# test process — neither crosses a runspace boundary, so neither could ever
# have caught this bug class: 3818/3818 tests passed while production shipped
# completely broken. This Describe block builds the SAME kind of runspace
# clone frame-credit-ledger.ps1 builds for its worker, using the real
# production clone function, and runs the LITERAL worker script-block text
# extracted live from frame-credit-ledger.ps1 inside it. It is therefore RED
# against the pre-fix file (the extracted block does not dot-source the
# budgets file, so the constant is unset inside the clone) and GREEN after the
# fix (the constant resolves to its real value).
Describe 'cost-telemetry budget worker-runspace isolation (issue #496 C-1)' {

    It 'resolves cost-telemetry budget constants inside the cloned worker runspace, not $null-degraded-to-0' {
        $fclPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'
        $fclContent = Get-Content -LiteralPath $fclPath -Raw

        # Extract the worker AddScript({ ... }) block text via a balanced-
        # brace scan (not a single-line regex) so this test tracks the real
        # source even as the block grows across multiple lines.
        $anchor = '$null = $worker.AddScript({'
        $anchorIndex = $fclContent.IndexOf($anchor)
        $anchorIndex | Should -BeGreaterThan -1 `
            -Because 'the worker AddScript() call site must exist in frame-credit-ledger.ps1 — update this anchor if the worker construction is refactored'

        $braceStart = $anchorIndex + $anchor.Length - 1
        $depth = 0
        $braceEnd = -1
        for ($i = $braceStart; $i -lt $fclContent.Length; $i++) {
            if ($fclContent[$i] -eq '{') { $depth++ }
            elseif ($fclContent[$i] -eq '}') {
                $depth--
                if ($depth -eq 0) { $braceEnd = $i; break }
            }
        }
        $braceEnd | Should -BeGreaterThan $braceStart -Because 'the worker AddScript() script block must have balanced braces'

        $workerBlockText = $fclContent.Substring($braceStart, $braceEnd - $braceStart + 1)
        $innerText = $workerBlockText.Substring(1, $workerBlockText.Length - 2)

        # Swap the real pipeline call for a probe that reports back the
        # resolved budget constant, so this test observes the SAME setup
        # code (including the fix, if present) without running the full
        # gh-dependent Invoke-FrameCreditLedger pipeline.
        $probeMarker = 'Invoke-FrameCreditLedger -Pr $PrArg -Mode $ModeArg'
        $innerText.Contains($probeMarker) | Should -BeTrue `
            -Because 'the worker script block must still end by calling Invoke-FrameCreditLedger — update this probe marker if that call site changes'
        $probeText = $innerText.Replace($probeMarker, 'return $script:CostTelemetryClaudeWalkerTimeoutSeconds')

        # Real production clone mechanism (New-FCLInitialSessionStateClone,
        # unmodified), real repo root, real marshaled cost-script state —
        # exactly what frame-credit-ledger.ps1 builds for its own worker.
        $costScriptState = script:Get-FCLCostScriptState
        $iss = script:New-FCLInitialSessionStateClone
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()
        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.Runspace = $rs
        try {
            $null = $worker.AddScript($probeText).AddArgument(0).AddArgument('warn').AddArgument($script:RepoRoot).AddArgument($costScriptState)
            $result = $worker.Invoke()

            $worker.HadErrors | Should -BeFalse `
                -Because ('worker probe threw: ' + (@($worker.Streams.Error) -join '; '))

            $resolvedInsideWorker = @($result) | Select-Object -Last 1
            $resolvedInsideWorker | Should -Be $script:CostTelemetryClaudeWalkerTimeoutSeconds -Because @"
Inside the cloned worker runspace, `$script:CostTelemetryClaudeWalkerTimeoutSeconds
must resolve to the same real constant value it has at the top level
($($script:CostTelemetryClaudeWalkerTimeoutSeconds)s), not `$null (which
silently coerces to 0 when bound to a mandatory [int] parameter, with no
error). If this fails, the worker script block in frame-credit-ledger.ps1
no longer re-dot-sources lib/cost-telemetry-budgets.ps1 before using the
constants (issue #496 C-1).
"@
        }
        finally {
            try { $worker.Dispose() } catch { $null = $_ }
            try { $rs.Close(); $rs.Dispose() } catch { $null = $_ }
        }
    }
}
