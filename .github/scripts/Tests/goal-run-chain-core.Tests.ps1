#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for .github/scripts/lib/goal-run-chain-core.ps1 (issue #874,
    plan step 6, AC1 chain half + AC2 classing/halt-producer half).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-chain-core.ps1'
    . $script:LibPath

    function script:New-WellFormedGoalContract {
        [pscustomobject]@{
            schema_version       = 1
            issue                = 874
            contract_hash        = ('a' * 64)
            evidence_obligations = [pscustomobject]@{
                checkpoint_commits    = 'per-target-green'
                run_log               = 'deviation entries plus experience observations per checkpoint'
                required_markers      = @('pipeline-metrics-credits', 'goal-run-class')
            }
        }
    }
}

Describe 'goal-run-chain-core.ps1: lib resolves' -Tag 'unit' {
    It 'exists at the expected path' {
        (Test-Path -LiteralPath $script:LibPath) | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# 1. Re-validation stage: reuse-not-reimplement fixture
# ---------------------------------------------------------------------------

Describe 'Invoke-GoalRunChainRevalidate: reuses the step 5 disposition function' -Tag 'unit' {

    BeforeAll {
        $script:PinnedHash = ('a' * 64)
        $script:MatchingPinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $LaunchPinnedHash } }
    }

    $cases = @(
        @{ ExitCode = 0; Reason = $null; Description = 'exit 0 satisfied' }
        @{ ExitCode = 1; Reason = $null; Description = 'exit 1 not-satisfied' }
        @{ ExitCode = 2; Reason = $null; Description = 'exit 2 refused -> halt' }
        @{ ExitCode = 2; Reason = 'refused: contract-hash-mismatch'; Description = 'exit 2 refused with reason -> halt' }
        @{ ExitCode = 3; Reason = 'infra-error: powershell-yaml module is required but could not be loaded'; Description = 'exit 3 infra-error -> halt' }
        @{ ExitCode = 3; Reason = 'review-required: mandatory-review flags present'; Description = 'exit 3 flag-bearing -> satisfied' }
        @{ ExitCode = 3; Reason = $null; Description = 'exit 3 no reason -> satisfied' }
        @{ ExitCode = 99; Reason = $null; Description = 'unrecognized exit code -> halt' }
    )

    It 'produces the EXACT SAME Disposition/Reason as calling Resolve-GoalRunValidatorExitDisposition directly (<Description>)' -TestCases $cases {
        param($ExitCode, $Reason, $Description)

        $expected = Resolve-GoalRunValidatorExitDisposition -ExitCode $ExitCode -Reason $Reason

        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = $ExitCode; Reason = $Reason } }
        $actual = Invoke-GoalRunChainRevalidate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $script:MatchingPinCheck -ValidatorInvoker $invoker

        $actual.Disposition | Should -Be $expected.Disposition
        $actual.Reason | Should -Be $expected.Reason
        $actual.ExitCode | Should -Be $ExitCode
    }

    It 'maps a halt Disposition to HaltReason chain-stage-failure -- the same bucket the step 5 composed predicate uses for exit-2/exit-3-infra-error' {
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 2; Reason = $null } }
        $result = Invoke-GoalRunChainRevalidate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $script:MatchingPinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'halt'
        $result.HaltReason | Should -Be 'chain-stage-failure'
    }

    It 'leaves HaltReason null when Disposition is satisfied' {
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 0; Reason = $null } }
        $result = Invoke-GoalRunChainRevalidate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $script:MatchingPinCheck -ValidatorInvoker $invoker
        $result.HaltReason | Should -BeNullOrEmpty
    }

    It 'leaves HaltReason null when Disposition is not-satisfied' {
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 1; Reason = $null } }
        $result = Invoke-GoalRunChainRevalidate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $script:MatchingPinCheck -ValidatorInvoker $invoker
        $result.HaltReason | Should -BeNullOrEmpty
    }

    # -----------------------------------------------------------------------
    # M1 fix: launch-pinned contract-hash check wired into chain re-validation
    # -----------------------------------------------------------------------

    It 'halts with invariant-conflict on a launch-pinned-hash mismatch BEFORE invoking the validator (mismatch short-circuits -- validator is never invoked)' {
        $mismatchPinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $false; Reason = 'contract-hash-mismatch-since-launch'; LiveHash = 'deadbeef' } }
        $script:chainInvokerCallCount = 0
        $invoker = {
            param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath)
            $script:chainInvokerCallCount++
            [pscustomobject]@{ ExitCode = 0; Reason = $null }
        }

        $result = Invoke-GoalRunChainRevalidate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $mismatchPinCheck -ValidatorInvoker $invoker

        $result.Disposition | Should -Be 'halt'
        $result.HaltReason | Should -Be 'invariant-conflict'
        $result.Reason | Should -Be 'contract-hash-mismatch-since-launch'
        $script:chainInvokerCallCount | Should -Be 0 -Because 'a launch-pinned-hash mismatch must short-circuit before the validator is ever invoked'
    }

    It 'proceeds to invoke the validator normally when the launch-pinned hash matches' {
        $script:chainInvokerCallCount2 = 0
        $invoker = {
            param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath)
            $script:chainInvokerCallCount2++
            [pscustomobject]@{ ExitCode = 0; Reason = $null }
        }

        $result = Invoke-GoalRunChainRevalidate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $script:MatchingPinCheck -ValidatorInvoker $invoker

        $result.Disposition | Should -Be 'satisfied'
        $script:chainInvokerCallCount2 | Should -Be 1
    }

    # -----------------------------------------------------------------------
    # M23 fix: ParseFailed pass-through -- lost-Reason-on-exit-3 fails closed
    # -----------------------------------------------------------------------

    It 'M23: halts (fails closed) when the validator invoker result carries ParseFailed=$true on an exit-3/null-Reason result' {
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 3; Reason = $null; ParseFailed = $true } }
        $result = Invoke-GoalRunChainRevalidate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $script:MatchingPinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'halt'
        $result.HaltReason | Should -Be 'chain-stage-failure'
    }

    It 'M23: stays satisfied when the validator invoker result carries no ParseFailed property at all (pre-fix test doubles are not regressed)' {
        $invoker = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 3; Reason = $null } }
        $result = Invoke-GoalRunChainRevalidate -Issue 874 -RepoRoot 'C:\gr-874-token' -LaunchPinnedHash $script:PinnedHash -PinCheck $script:MatchingPinCheck -ValidatorInvoker $invoker
        $result.Disposition | Should -Be 'satisfied'
    }
}

# ---------------------------------------------------------------------------
# 2. Fix-cycle cap
# ---------------------------------------------------------------------------

Describe 'Test-GoalRunFixCycleCapExceeded' -Tag 'unit' {

    It 'reports not exceeded below the cap' {
        Test-GoalRunFixCycleCapExceeded -CompletedFixCycles 0 | Should -Be $false
        Test-GoalRunFixCycleCapExceeded -CompletedFixCycles 1 | Should -Be $false
    }

    It 'reports exceeded at and beyond the default cap of 2' {
        Test-GoalRunFixCycleCapExceeded -CompletedFixCycles 2 | Should -Be $true
        Test-GoalRunFixCycleCapExceeded -CompletedFixCycles 3 | Should -Be $true
    }

    It 'honors a caller-supplied Cap override' {
        Test-GoalRunFixCycleCapExceeded -CompletedFixCycles 1 -Cap 1 | Should -Be $true
        Test-GoalRunFixCycleCapExceeded -CompletedFixCycles 0 -Cap 1 | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 3. Halt-reason precedence (M2) -- exhaustive co-occurrence coverage
# ---------------------------------------------------------------------------

Describe 'Resolve-GoalRunHaltPrecedence' -Tag 'unit' {

    It 'returns no halt when nothing is true' {
        $result = Resolve-GoalRunHaltPrecedence
        $result.HasHalt | Should -Be $false
        $result.HaltReason | Should -BeNullOrEmpty
        $result.TrueConditions | Should -BeNullOrEmpty
    }

    # Single-condition cases.
    It 'invariant-conflict alone wins' {
        (Resolve-GoalRunHaltPrecedence -InvariantConflict).HaltReason | Should -Be 'invariant-conflict'
    }
    It 'unachievable-target alone wins' {
        (Resolve-GoalRunHaltPrecedence -UnachievableTarget).HaltReason | Should -Be 'unachievable-target'
    }
    It 'gate-input-needed alone wins' {
        (Resolve-GoalRunHaltPrecedence -GateInputNeeded).HaltReason | Should -Be 'gate-input-needed'
    }
    It 'budget-exhausted alone wins' {
        (Resolve-GoalRunHaltPrecedence -BudgetExhausted).HaltReason | Should -Be 'budget-exhausted'
    }
    It 'chain-stage-failure alone wins' {
        (Resolve-GoalRunHaltPrecedence -ChainStageFailure).HaltReason | Should -Be 'chain-stage-failure'
    }

    # Every pairwise combination (10 pairs) -- higher-precedence name must win.
    # Case generation lives in BeforeDiscovery so the arrays exist for both
    # Pester discovery (which needs the -TestCases array up front) and the
    # later run phase; each case carries its own resolved switch names so no
    # It block needs to look anything up in a Describe-scope hashtable that
    # would not otherwise survive into the run phase.
    BeforeDiscovery {
        $script:PrecedenceOrder = @('invariant-conflict', 'unachievable-target', 'gate-input-needed', 'budget-exhausted', 'chain-stage-failure')
        $script:SwitchNames = @{
            'invariant-conflict'  = 'InvariantConflict'
            'unachievable-target' = 'UnachievableTarget'
            'gate-input-needed'   = 'GateInputNeeded'
            'budget-exhausted'    = 'BudgetExhausted'
            'chain-stage-failure' = 'ChainStageFailure'
        }

        $script:PairCases = @()
        for ($i = 0; $i -lt $script:PrecedenceOrder.Count; $i++) {
            for ($j = $i + 1; $j -lt $script:PrecedenceOrder.Count; $j++) {
                $higher = $script:PrecedenceOrder[$i]
                $lower = $script:PrecedenceOrder[$j]
                $script:PairCases += @{ Higher = $higher; Lower = $lower; HigherSwitch = $script:SwitchNames[$higher]; LowerSwitch = $script:SwitchNames[$lower] }
            }
        }

        # Every non-empty subset of the five conditions (31 combinations) --
        # exhaustive multi-way co-occurrence: the winner must always be the
        # earliest name (by the stated order) among the TRUE conditions.
        $script:AllSwitchNames = @('InvariantConflict', 'UnachievableTarget', 'GateInputNeeded', 'BudgetExhausted', 'ChainStageFailure')

        $script:SubsetCases = @()
        for ($mask = 1; $mask -lt 32; $mask++) {
            $trueSwitches = @()
            $trueReasons = @()
            for ($bit = 0; $bit -lt 5; $bit++) {
                if ($mask -band (1 -shl $bit)) {
                    $trueSwitches += $script:AllSwitchNames[$bit]
                    $trueReasons += $script:PrecedenceOrder[$bit]
                }
            }
            $winnerCandidates = @($script:PrecedenceOrder | Where-Object { $trueReasons -contains $_ })
            $expectedWinner = $winnerCandidates[0]
            $script:SubsetCases += @{ Mask = $mask; TrueSwitches = $trueSwitches; ExpectedWinner = $expectedWinner }
        }
    }

    It 'resolves pair (<Higher> + <Lower>) to <Higher> per the stated total order' -TestCases $script:PairCases {
        param($Higher, $Lower, $HigherSwitch, $LowerSwitch)
        $params = @{ $HigherSwitch = $true; $LowerSwitch = $true }
        $result = Resolve-GoalRunHaltPrecedence @params
        $result.HaltReason | Should -Be $Higher
        $result.TrueConditions | Should -Contain $Higher
        $result.TrueConditions | Should -Contain $Lower
    }

    It 'resolves subset mask <Mask> (<TrueSwitches>) to the highest-precedence true condition (<ExpectedWinner>)' -TestCases $script:SubsetCases {
        param($Mask, $TrueSwitches, $ExpectedWinner)
        $params = @{}
        foreach ($name in $TrueSwitches) { $params[$name] = $true }
        $result = Resolve-GoalRunHaltPrecedence @params
        $result.HaltReason | Should -Be $ExpectedWinner
        $result.HasHalt | Should -Be $true
        $result.TrueConditions.Count | Should -Be $TrueSwitches.Count
    }

    # Exhaustiveness itself is proven by the 31 individually-enumerated
    # "resolves subset mask N" cases directly above (masks 1 through 31)
    # plus the single "returns no halt when nothing is true" case (mask 0)
    # earlier in this Describe block -- 32 total scenarios, not asserted
    # again here as a separate count check (a Pester discovery-vs-run
    # scope boundary makes a script-scope count set in BeforeDiscovery
    # unreliable to re-read from a plain, non-TestCases It at run time).

    It 'the all-five-true case resolves to invariant-conflict, the single highest-precedence producer' {
        $result = Resolve-GoalRunHaltPrecedence -InvariantConflict -UnachievableTarget -GateInputNeeded -BudgetExhausted -ChainStageFailure
        $result.HaltReason | Should -Be 'invariant-conflict'
        $result.TrueConditions.Count | Should -Be 5
    }
}

# ---------------------------------------------------------------------------
# 4. Untrusted-content discipline pass-through
# ---------------------------------------------------------------------------

Describe 'ConvertTo-GoalRunChainSafeText' -Tag 'unit' {

    It 'redacts secret-shaped content, reusing the step 1 redaction pass' {
        $text = 'the executor reported api_key: LiveSecretValue987654 in its evidence'
        $safe = ConvertTo-GoalRunChainSafeText -Text $text
        $safe | Should -Not -Match 'LiveSecretValue987654'
        $safe | Should -Match '\[REDACTED:kv-secret-assignment\]'
    }
}

Describe 'New-GoalRunChainHaltReport' -Tag 'unit' {

    It 'builds a schema-valid halt-report object accepted by Invoke-GoalRunHaltEmit validation' {
        $report = New-GoalRunChainHaltReport -Issue 874 -HaltReason 'chain-stage-failure' -Stage 'fix-cycle' -PlanRemediation 'Escalate to a human reviewer.' -Evidence @('two fix cycles exhausted without a green re-validation')
        $validation = Test-GoalRunHaltReport -Report $report -RepoRoot $script:RepoRoot
        $validation.IsValid | Should -Be $true
    }

    It 'redacts secret-shaped content in evidence and plan_remediation before the report object is built' {
        $report = New-GoalRunChainHaltReport -Issue 874 -HaltReason 'invariant-conflict' -Stage 'validate' -PlanRemediation 'token: LiveSecretValue987654 leaked in the executor claim' -Evidence @('api_key: LiveSecretValue987654 appeared in the transcript')
        $report.plan_remediation | Should -Not -Match 'LiveSecretValue987654'
        $report.evidence[0] | Should -Not -Match 'LiveSecretValue987654'
    }

    It 'M3: redacts secret-shaped content in target_ref before the report object is built' {
        $report = New-GoalRunChainHaltReport -Issue 874 -HaltReason 'unachievable-target' -Stage 'validate' -PlanRemediation 'Escalate to a human reviewer.' -TargetRef 'token: LiveSecretValue987654 was the target id'
        $report.target_ref | Should -Not -Match 'LiveSecretValue987654'
        $report.target_ref | Should -Match '\[REDACTED:kv-secret-assignment\]'
    }

    It 'M3: redacts secret-shaped content in recommended_next_owner before the report object is built' {
        $report = New-GoalRunChainHaltReport -Issue 874 -HaltReason 'unachievable-target' -Stage 'validate' -PlanRemediation 'Escalate to a human reviewer.' -RecommendedNextOwner 'token: LiveSecretValue987654 owns this'
        $report.recommended_next_owner | Should -Not -Match 'LiveSecretValue987654'
        $report.recommended_next_owner | Should -Match '\[REDACTED:kv-secret-assignment\]'
    }

    It 'M3: preserves a $null target_ref (schema-legal for halt reasons with no single target) rather than coercing it to an empty/redacted string' {
        $report = New-GoalRunChainHaltReport -Issue 874 -HaltReason 'budget-exhausted' -Stage 'loop' -PlanRemediation 'Increase the wall-clock budget.' -Evidence @('ceiling reached')
        $report.target_ref | Should -BeNullOrEmpty
        $validation = Test-GoalRunHaltReport -Report $report -RepoRoot $script:RepoRoot
        $validation.IsValid | Should -Be $true -Because ($validation.Violations -join '; ')
    }
}

# ---------------------------------------------------------------------------
# 5. Classing (874-D7)
# ---------------------------------------------------------------------------

Describe 'Get-GoalRunRequiredMarkerCreditRows' -Tag 'unit' {

    It 'builds one credit row per required_markers entry, port equal to the marker name' {
        $rows = Get-GoalRunRequiredMarkerCreditRows -Contract (script:New-WellFormedGoalContract)
        $rows.Count | Should -Be 2
        ($rows | ForEach-Object { $_.port }) | Should -Contain 'pipeline-metrics-credits'
        ($rows | ForEach-Object { $_.port }) | Should -Contain 'goal-run-class'
    }
}

Describe 'Invoke-GoalRunClassEmission: additive-safe classing' -Tag 'unit' {

    BeforeEach {
        $script:BodyFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "goal-run-chain-test-$([System.Guid]::NewGuid().ToString('N')).md")
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:BodyFile) { Remove-Item -LiteralPath $script:BodyFile -ErrorAction SilentlyContinue }
    }

    It 'emits a v4 metrics block carrying the goal_run_class field and a goal-run port credit row' {
        $result = Invoke-GoalRunClassEmission -Issue 874 -BodyFile $script:BodyFile -Contract (script:New-WellFormedGoalContract) -GoalRunClass 'goal-run' -SkipMarkerHarvest
        $result.ExitCode | Should -Be 0

        $bodyContent = Get-Content -LiteralPath $script:BodyFile -Raw
        $bodyContent | Should -Match 'goal_run_class: goal-run'

        $parsed = Read-PRMetricsBlock -PrBody $bodyContent
        $parsed.MetricsVersion | Should -Be 4
        ($parsed.Credits | ForEach-Object { $_.Port }) | Should -Contain 'goal-run'
        ($parsed.Credits | ForEach-Object { $_.Port }) | Should -Contain 'pipeline-metrics-credits'
        ($parsed.Credits | ForEach-Object { $_.Port }) | Should -Contain 'goal-run-class'
    }

    It 'never hands an empty credits array to the emit primitive -- required-marker rows plus the base goal-run row are always present' {
        $emptyMarkersContract = script:New-WellFormedGoalContract
        $emptyMarkersContract.evidence_obligations.required_markers = @()

        $result = Invoke-GoalRunClassEmission -Issue 874 -BodyFile $script:BodyFile -Contract $emptyMarkersContract -SkipMarkerHarvest
        $result.ExitCode | Should -Be 0
        $result.SentinelWritten | Should -Be $false

        $bodyContent = Get-Content -LiteralPath $script:BodyFile -Raw
        $bodyContent | Should -Not -Match '<!-- cost-capture-failed -->'
    }

    It 'is additive-safe: an unrelated pre-existing v3-base scalar field survives and is ignored by Read-PRMetricsBlock/Get-FCLScalar-style extraction, unaffected by the new goal_run_class field' {
        $result = Invoke-GoalRunClassEmission -Issue 874 -BodyFile $script:BodyFile -Contract (script:New-WellFormedGoalContract) -V3BaseYaml "pr_number: 42`nsome_unrelated_future_field: kept" -SkipMarkerHarvest
        $result.ExitCode | Should -Be 0

        $bodyContent = Get-Content -LiteralPath $script:BodyFile -Raw
        $bodyContent | Should -Match 'pr_number: 42'
        $bodyContent | Should -Match 'some_unrelated_future_field: kept'
        $bodyContent | Should -Match 'goal_run_class: goal-run'

        # A reader that knows nothing about goal_run_class or the unrelated
        # future field still parses the block successfully (additive-safe).
        $parsed = Read-PRMetricsBlock -PrBody $bodyContent
        $parsed.MetricsVersion | Should -Be 4
    }

    It 'merges caller-supplied credits alongside the classing rows rather than replacing them' {
        $callerCredit = [pscustomobject]@{ port = 'implement-code'; adapter = 'work-adapter'; status = 'passed'; evidence = 'pre-existing credit row' }
        $result = Invoke-GoalRunClassEmission -Issue 874 -BodyFile $script:BodyFile -Contract (script:New-WellFormedGoalContract) -Credits @($callerCredit) -SkipMarkerHarvest
        $result.ExitCode | Should -Be 0

        $bodyContent = Get-Content -LiteralPath $script:BodyFile -Raw
        $parsed = Read-PRMetricsBlock -PrBody $bodyContent
        ($parsed.Credits | ForEach-Object { $_.Port }) | Should -Contain 'implement-code'
        ($parsed.Credits | ForEach-Object { $_.Port }) | Should -Contain 'goal-run'
    }
}

Describe 'Add-GoalRunPrLabel' -Tag 'unit' {

    It 'reports Success = $true when the injected applier reports success' {
        $applier = { param($PrNumber, $LabelName, $Owner, $Repo, $GhCliPath) $true }
        $result = Add-GoalRunPrLabel -PrNumber 101 -LabelApplier $applier
        $result.Success | Should -Be $true
        $result.LabelName | Should -Be 'goal-run'
    }

    It 'reports Success = $false when the injected applier reports failure' {
        $applier = { param($PrNumber, $LabelName, $Owner, $Repo, $GhCliPath) $false }
        $result = Add-GoalRunPrLabel -PrNumber 101 -LabelApplier $applier
        $result.Success | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 6. Verified-emission terminal condition + repair
# ---------------------------------------------------------------------------

Describe 'Test-GoalRunPrEmissionsVerified' -Tag 'unit' {

    It 'reports Verified = $true for a fresh PR carrying the label AND the goal-run classing metrics row' {
        $bodyWithMetrics = "Some PR body text.`n`n<!-- pipeline-metrics`nmetrics_version: 4`ncredits:`n  - port: goal-run`n    adapter: goal-run-chain`n    status: classed`n    evidence: goal_run_class=goal-run`n-->"
        $reader = {
            param($PrNumber, $Owner, $Repo, $GhCliPath)
            [pscustomobject]@{ body = $bodyWithMetrics; labels = @([pscustomobject]@{ name = 'goal-run' }) }
        }
        $result = Test-GoalRunPrEmissionsVerified -PrNumber 42 -PrReader $reader
        $result.Verified | Should -Be $true
        $result.LabelPresent | Should -Be $true
        $result.MetricsPresent | Should -Be $true
        $result.Reason | Should -BeNullOrEmpty
    }

    It 'reports Verified = $false and identifies label-and-metrics-missing when the PR carries neither' {
        $reader = {
            param($PrNumber, $Owner, $Repo, $GhCliPath)
            [pscustomobject]@{ body = 'Plain PR body, no metrics block at all.'; labels = @() }
        }
        $result = Test-GoalRunPrEmissionsVerified -PrNumber 42 -PrReader $reader
        $result.Verified | Should -Be $false
        $result.Reason | Should -Be 'label-and-metrics-missing'
        $result.LabelPresent | Should -Be $false
        $result.MetricsPresent | Should -Be $false
    }

    It 'reports Verified = $false and identifies metrics-missing when only the label is present' {
        $reader = {
            param($PrNumber, $Owner, $Repo, $GhCliPath)
            [pscustomobject]@{ body = 'No metrics block here.'; labels = @([pscustomobject]@{ name = 'goal-run' }) }
        }
        $result = Test-GoalRunPrEmissionsVerified -PrNumber 42 -PrReader $reader
        $result.Verified | Should -Be $false
        $result.Reason | Should -Be 'metrics-missing'
    }

    It 'reports Verified = $false when the PR cannot be read at all' {
        $reader = { param($PrNumber, $Owner, $Repo, $GhCliPath) $null }
        $result = Test-GoalRunPrEmissionsVerified -PrNumber 42 -PrReader $reader
        $result.Verified | Should -Be $false
        $result.Reason | Should -Be 'pr-unreadable'
    }

    It 'M14 fix: the DEFAULT (non-injected) gh reader path -- which pins console UTF-8 before the gh call -- reads body/labels correctly end to end' {
        $mockGhPath = Join-Path $TestDrive 'gh-pr-view-utf8.ps1'
        @'
param()
Write-Output '{"body":"PR body with a non-ASCII em-dash — and ellipsis …","labels":[{"name":"goal-run"}]}'
exit 0
'@ | Set-Content $mockGhPath -Encoding UTF8

        $result = Test-GoalRunPrEmissionsVerified -PrNumber 42 -GhCliPath $mockGhPath
        $result.LabelPresent | Should -Be $true
        $result.Body | Should -Match 'em-dash'
    }
}

Describe 'Invoke-GoalRunTerminalEmissionsVerifyAndRepair' -Tag 'unit' {

    It 'fixture (a): a fresh PR with correct label+metrics is recognized as terminal/complete, no repair fires' {
        $bodyWithMetrics = "<!-- pipeline-metrics`nmetrics_version: 4`ncredits:`n  - port: goal-run`n    adapter: goal-run-chain`n    status: classed`n    evidence: goal_run_class=goal-run`n-->"
        $reader = {
            param($PrNumber, $Owner, $Repo, $GhCliPath)
            [pscustomobject]@{ body = $bodyWithMetrics; labels = @([pscustomobject]@{ name = 'goal-run' }) }
        }
        $labelApplierCalled = $false
        $bodyWriterCalled = $false
        $labelApplier = { param($PrNumber, $LabelName, $Owner, $Repo, $GhCliPath) $script:labelApplierCalled = $true; $true }
        $bodyWriter = { param($PrNumber, $Owner, $Repo, $GhCliPath, $BodyFile) $script:bodyWriterCalled = $true; $true }

        $result = Invoke-GoalRunTerminalEmissionsVerifyAndRepair -PrNumber 42 -Contract (script:New-WellFormedGoalContract) -PrReader $reader -LabelApplier $labelApplier -BodyWriter $bodyWriter
        $result.Verified | Should -Be $true
        $result.Repaired | Should -Be $false
        $labelApplierCalled | Should -Be $false
        $bodyWriterCalled | Should -Be $false
    }

    It 'fixture (b): a PR that exists but is missing BOTH the label and metrics is NOT recognized as terminal and the repair path re-applies both' {
        $script:CurrentBody = 'A PR body with no metrics block and no label yet.'
        $script:LabelApplied = $false
        $reader = {
            param($PrNumber, $Owner, $Repo, $GhCliPath)
            [pscustomobject]@{ body = $script:CurrentBody; labels = if ($script:LabelApplied) { @([pscustomobject]@{ name = 'goal-run' }) } else { @() } }
        }
        $labelApplier = { param($PrNumber, $LabelName, $Owner, $Repo, $GhCliPath) $script:LabelApplied = $true; $true }
        $bodyWriter = {
            param($PrNumber, $Owner, $Repo, $GhCliPath, $BodyFile)
            $script:CurrentBody = Get-Content -LiteralPath $BodyFile -Raw
            $true
        }

        $result = Invoke-GoalRunTerminalEmissionsVerifyAndRepair -PrNumber 42 -Contract (script:New-WellFormedGoalContract) -PrReader $reader -LabelApplier $labelApplier -BodyWriter $bodyWriter
        $result.Repaired | Should -Be $true
        $result.LabelRepaired | Should -Be $true
        $result.MetricsRepaired | Should -Be $true
        $result.Verified | Should -Be $true
        $script:LabelApplied | Should -Be $true
        $script:CurrentBody | Should -Match 'goal_run_class: goal-run'
    }

    It 'fixture (b variant): a PR missing ONLY the metrics block repairs metrics without re-applying an already-present label' {
        $script:CurrentBody2 = 'A PR body with the label already applied but no metrics block.'
        $labelApplierCalled = $false
        $reader = {
            param($PrNumber, $Owner, $Repo, $GhCliPath)
            [pscustomobject]@{ body = $script:CurrentBody2; labels = @([pscustomobject]@{ name = 'goal-run' }) }
        }
        $labelApplier = { param($PrNumber, $LabelName, $Owner, $Repo, $GhCliPath) $script:labelApplierCalled = $true; $true }
        $bodyWriter = {
            param($PrNumber, $Owner, $Repo, $GhCliPath, $BodyFile)
            $script:CurrentBody2 = Get-Content -LiteralPath $BodyFile -Raw
            $true
        }

        $result = Invoke-GoalRunTerminalEmissionsVerifyAndRepair -PrNumber 42 -Contract (script:New-WellFormedGoalContract) -PrReader $reader -LabelApplier $labelApplier -BodyWriter $bodyWriter
        $result.LabelRepaired | Should -Be $false
        $result.MetricsRepaired | Should -Be $true
        $result.Verified | Should -Be $true
        $labelApplierCalled | Should -Be $false
    }

    It 'M14 fix: re-reads the live body immediately before writing instead of reusing the entry-time snapshot, so a concurrent edit in between is not clobbered' {
        # Simulates a concurrent writer appending content to the PR body in the
        # narrow window between the initial Test-GoalRunPrEmissionsVerified read
        # (inside this function) and the write this function composes. Before
        # the M14 fix, the write payload was built from the stale entry-time
        # $state.Body captured once at the top of the function; after the fix,
        # it re-reads immediately before composing the write payload.
        $script:CallCount = 0
        $script:LiveBody = 'Original PR body, no metrics block yet.'
        $reader = {
            param($PrNumber, $Owner, $Repo, $GhCliPath)
            $script:CallCount++
            if ($script:CallCount -eq 2) {
                # A concurrent writer touched the PR body between the first
                # (entry-time) read and this second (pre-write) reconfirm read.
                $script:LiveBody = 'Original PR body, no metrics block yet. CONCURRENT-EDIT-MARKER.'
            }
            [pscustomobject]@{ body = $script:LiveBody; labels = @([pscustomobject]@{ name = 'goal-run' }) }
        }
        $writtenBody = $null
        $bodyWriter = {
            param($PrNumber, $Owner, $Repo, $GhCliPath, $BodyFile)
            $script:WrittenBody = Get-Content -LiteralPath $BodyFile -Raw
            $true
        }

        $result = Invoke-GoalRunTerminalEmissionsVerifyAndRepair -PrNumber 42 -Contract (script:New-WellFormedGoalContract) -PrReader $reader -BodyWriter $bodyWriter
        $result.MetricsRepaired | Should -Be $true
        $script:CallCount | Should -Be 2
        $script:WrittenBody | Should -Match 'CONCURRENT-EDIT-MARKER'
    }
}
