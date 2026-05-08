#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-CostAnomalyFlags' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-anomaly.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        # Helper: build a minimal attribution result for testing
        function script:New-MinimalAttribution {
            param(
                [string]$PortName = 'experience',
                [int]$DispatchCount = 1,
                [int]$InputTok = 1000,
                [int]$OutputTok = 500,
                [int]$CacheRead = 200,
                [int]$CacheCreate = 100,
                [double]$TotalCost = 0.01,
                [string]$Coverage = 'claude-only',
                [string]$InstallStatus = 'ok'
            )
            return @{
                ports                 = @{
                    $PortName = @{
                        tokens               = @{ input = $InputTok; output = $OutputTok; cache_creation = $CacheCreate; cache_read = $CacheRead }
                        dispatch_count       = $DispatchCount
                        cost_estimate_usd    = $TotalCost
                        cache_read_hit_ratio = if (($CacheRead + $CacheCreate + $InputTok) -gt 0) { $CacheRead / ($CacheRead + $CacheCreate + $InputTok) } else { 0 }
                    }
                }
                orchestrator_overhead = @{
                    tokens               = @{ input = 500; output = 200; cache_creation = 50; cache_read = 100 }
                    cost_estimate_usd    = 0.005
                    cache_read_hit_ratio = 0.15
                }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{
                    tokens            = @{ input = $InputTok; output = $OutputTok; cache_creation = $CacheCreate; cache_read = $CacheRead }
                    cost_estimate_usd = $TotalCost
                }
                coverage              = $Coverage
                install_status        = $InstallStatus
            }
        }

        # Helper: build a history of N entries all with the same dispatch count
        function script:New-UniformHistory {
            param(
                [int]$Count,
                [string]$PortName = 'experience',
                [int]$DispatchCount = 1,
                [int]$InputTok = 1000,
                [int]$OutputTok = 500,
                [int]$CacheRead = 200,
                [int]$CacheCreate = 100,
                [double]$TotalCost = 0.01
            )
            $history = @()
            for ($i = 0; $i -lt $Count; $i++) {
                $history += script:New-MinimalAttribution -PortName $PortName `
                    -DispatchCount $DispatchCount -InputTok $InputTok `
                    -OutputTok $OutputTok -CacheRead $CacheRead `
                    -CacheCreate $CacheCreate -TotalCost $TotalCost
            }
            return $history
        }
    }

    Context 'threshold rules' {
        It 'flags metric when both Rule A and Rule B fire (confidence: high)' {
            # Build history of 15 entries: dispatch_count=1 each (mean=1, stddev~0, median=1)
            # We need stddev > 0 for Rule A, so vary the counts slightly
            $history = @()
            # 10 entries with count=1, 5 entries with count=3 -> mean=1.67, stddev>0, median=1
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 3
            }
            # this_value = 20 (far above both baselines)
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 20

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.confidence | Should -Be 'high'
        }

        It 'flags metric when only Rule A fires (confidence: medium)' {
            # N=12 entries with values that form a cluster — Rule A fires, Rule B does not
            # median=100, stddev tight around 100, mean=100
            # Rule B: |this - median| > 0.5 * median => need spike > 150 for Rule B
            # We'll pick a value that triggers Rule A (>2*stddev from mean) but not Rule B
            # Let values be 98,99,100,101,102 repeated, so mean=100, stddev~1.5
            # this_value = 103 — |103-100|=3 > 2*1.5=3, borderline; let's use stddev exactly
            # Better: 12 values all=100 => stddev=0 => Rule A won't fire (requires stddev>0)
            # Use 10 values of 100 and 2 values of 110 => mean=101.67, stddev~3.7
            # |120-101.67| = 18.33 > 2*3.7 = 7.4 (Rule A fires)
            # |120-100| = 20 vs 0.5*100=50 (Rule B does NOT fire since 20 < 50)
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 100
            }
            for ($i = 0; $i -lt 2; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 110
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 120

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.confidence | Should -Be 'medium'
        }

        It 'flags metric when only Rule B fires (confidence: medium)' {
            # Rule B: |this - median| > 0.5 * median AND N >= 5 AND median != 0
            # Rule A requires N >= 10 AND stddev > 0; use N=5 => Rule A cannot fire
            # 5 entries with dispatch_count=2, median=2
            # this_value=5: |5-2|=3 > 0.5*2=1 (Rule B fires)
            $history = @()
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 2
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 5

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.confidence | Should -Be 'medium'
        }

        It 'does not flag metric when neither rule fires' {
            # 15 uniform entries, this_value equals baseline — no spike
            $history = script:New-UniformHistory -Count 15 -PortName 'experience' -DispatchCount 2
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 2

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -BeNullOrEmpty
        }

        It 'Rule A requires N >= 10' {
            # Only 9 entries — Rule A should not fire even if spike is large
            # Rule B also should not fire if spike is small enough
            $history = @()
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1
            }
            for ($i = 0; $i -lt 4; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 3
            }
            # N=9, stddev >0. this_value=50 — would trigger Rule A if N>=10, but not here
            # Rule B: median=1, |50-1|=49 > 0.5*1=0.5 => Rule B would fire, giving medium
            # To test only Rule A is blocked: need a value that triggers Rule A formula but not Rule B
            # median=2 (with 5 ones and 4 threes: sorted=[1,1,1,1,1,3,3,3,3], median=1)
            # Use value that gives |val-median|/median < 0.5: e.g., val=1.4 (dispatch=1)
            # But dispatch_count is int... use 15 entries of 100 minus last few to make N=9
            $history9 = @()
            for ($i = 0; $i -lt 9; $i++) {
                $history9 += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 100
            }
            # this_value=200: |200-100|=100 > 2*stddev (if all 100 => stddev=0, no Rule A anyway)
            # Mix to get stddev>0 but still fewer than 10
            $history9b = @()
            for ($i = 0; $i -lt 5; $i++) {
                $history9b += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 100
            }
            for ($i = 0; $i -lt 4; $i++) {
                $history9b += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 110
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 200

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history9b

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            # Rule B: median=100, |200-100|=100 > 0.5*100=50 => Rule B fires => medium
            # Rule A must NOT fire (N=9 < 10)
            # So flag should exist (Rule B) but confidence should be medium not high
            if ($flag) {
                $flag.confidence | Should -Be 'medium'
            }
            else {
                # If no flag, that's fine — verifies Rule A alone didn't fire
                $flag | Should -BeNullOrEmpty
            }
        }

        It 'Rule B requires N >= 5' {
            # Only 4 entries — Rule B should not fire
            $history = @()
            for ($i = 0; $i -lt 4; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 100

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -BeNullOrEmpty
        }

        It 'Rule A requires non-zero stddev' {
            # 15 identical entries => stddev=0 => Rule A should not fire
            # But Rule B: median=1, this_value=5, |5-1|=4 > 0.5*1=0.5 => Rule B fires
            # So ensure confidence is medium (one rule only)
            $history = script:New-UniformHistory -Count 15 -PortName 'experience' -DispatchCount 1
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 5

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.confidence | Should -Be 'medium'
        }

        It 'Rule B requires non-zero median' {
            # All zero dispatch_count => median=0 => Rule B should not fire
            # Rule A: stddev=0 also => neither rule fires
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 0
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 5

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -BeNullOrEmpty
        }
    }

    Context 'dual-baseline (rolling + checkpoint)' {
        It 'flags vs_baseline: rolling when only rolling triggers' {
            # Rolling history triggers but checkpoint does not
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 3
            }
            # Checkpoint shows a value close to this_value — Rule B won't trigger
            # Rule B: |this - cp| > 0.5 * cp => |20-20|=0 is not > 0.5*20=10
            $checkpoint = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 20

            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 20

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history -RegimeCheckpoint $checkpoint

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.vs_baseline | Should -Be 'rolling'
        }

        It 'flags vs_baseline: checkpoint when only checkpoint triggers' {
            # No rolling history (too few entries), but checkpoint value differs significantly
            $checkpoint = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1

            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 10

            # Use empty rolling history so rolling can't fire
            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory @() -RegimeCheckpoint $checkpoint

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.vs_baseline | Should -Be 'checkpoint'
        }

        It 'flags vs_baseline: both when both trigger' {
            # Rolling history triggers
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 3
            }
            # Checkpoint also shows low value
            $checkpoint = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1

            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 20

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history -RegimeCheckpoint $checkpoint

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.vs_baseline | Should -Be 'both'
        }
    }

    Context 'direction labels' {
        It 'assigns shrink direction to dispatches.per_port metrics' {
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -DispatchCount 3
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 20

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.direction | Should -Be 'shrink'
        }

        It 'assigns grow direction to cache_read.hit_ratio metrics' {
            # cache_read_hit_ratio drops from 0.8 to 0.1 — direction=grow means lower is worse
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                # High cache hit ratio in history: cache_read=800, input=100, cache_create=100 => ratio=800/1000=0.8
                $history += script:New-MinimalAttribution -PortName 'experience' -CacheRead 800 -InputTok 100 -CacheCreate 100
            }
            # this_value has very low cache hit ratio
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -CacheRead 10 -InputTok 100 -CacheCreate 100

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'cache_read.hit_ratio[experience]' }
            $flag | Should -Not -BeNullOrEmpty
            $flag.direction | Should -Be 'grow'
        }
    }

    Context 'mixed-regime skip' {
        It 'skips review port tokens.per_dispatch metrics by default' {
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'review' -DispatchCount 1 -OutputTok 500
                $history += $entry
            }
            $thisRun = script:New-MinimalAttribution -PortName 'review' -DispatchCount 1 -OutputTok 50000

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $outputFlag = $flags | Where-Object { $_.metric -eq 'tokens.per_dispatch.avg.output[review]' }
            $inputFlag = $flags | Where-Object { $_.metric -eq 'tokens.per_dispatch.avg.input[review]' }
            $outputFlag | Should -BeNullOrEmpty
            $inputFlag  | Should -BeNullOrEmpty
        }

        It 'includes review port metrics when cost-target:review-discipline opt-in present' {
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'review' -DispatchCount 1 -OutputTok 500
                $history += $entry
            }
            $thisRun = script:New-MinimalAttribution -PortName 'review' -DispatchCount 1 -OutputTok 50000

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history `
                -OptInLabels @('cost-target:review-discipline')

            $outputFlag = $flags | Where-Object { $_.metric -eq 'tokens.per_dispatch.avg.output[review]' }
            $outputFlag | Should -Not -BeNullOrEmpty
        }
    }

    Context 'coverage-class filtering' {
        It 'filters absolute metrics by effective coverage while leaving dispatch counts and ratios pooled' {
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'implement-test' `
                    -DispatchCount 1 -InputTok 100 -OutputTok 50 -CacheRead 800 `
                    -CacheCreate 100 -TotalCost 1.00 -Coverage 'claude+copilot'
                $entry['orchestrator_overhead']['tokens']['input'] = 500
                $entry['orchestrator_overhead']['cache_read_hit_ratio'] = 0.15
                $history += $entry
            }
            for ($i = 0; $i -lt 15; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'implement-test' `
                    -DispatchCount 1 -InputTok 1000 -OutputTok 500 -CacheRead 800 `
                    -CacheCreate 100 -TotalCost 0.01 -Coverage 'claude-only'
                $entry['orchestrator_overhead']['tokens']['input'] = 5000
                $entry['orchestrator_overhead']['cache_read_hit_ratio'] = 0.80
                $history += $entry
            }

            $thisRun = script:New-MinimalAttribution -PortName 'implement-test' `
                -DispatchCount 20 -InputTok 100 -OutputTok 50 -CacheRead 10 `
                -CacheCreate 100 -TotalCost 1.00 -Coverage 'claude+copilot'
            $thisRun['orchestrator_overhead']['tokens']['input'] = 500
            $thisRun['orchestrator_overhead']['cache_read_hit_ratio'] = 0.15

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            foreach ($metric in @(
                    'ports[implement-test].tokens.input',
                    'ports[implement-test].tokens.output',
                    'orchestrator_overhead.tokens.input',
                    'orchestrator_overhead.cache_read.hit_ratio',
                    'cost_estimate_usd.total'
                )) {
                ($flags | Where-Object { $_.metric -eq $metric }) | Should -BeNullOrEmpty `
                    -Because "$metric is an absolute coverage-sensitive metric and should compare only against claude+copilot history"
            }

            $dispatchFlag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[implement-test]' }
            $dispatchFlag | Should -Not -BeNullOrEmpty -Because 'dispatch counts remain pooled across coverage classes'
            $dispatchFlag.baseline_n | Should -Be 30

            $ratioFlag = $flags | Where-Object { $_.metric -eq 'cache_read.hit_ratio[implement-test]' }
            $ratioFlag | Should -Not -BeNullOrEmpty -Because 'per-port cache ratios remain pooled across coverage classes'
            $ratioFlag.baseline_n | Should -Be 30
        }

        It 'flags per-port absolute input and output tokens against matching coverage history' {
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                $history += script:New-MinimalAttribution -PortName 'implement-test' `
                    -InputTok 100 -OutputTok 50 -TotalCost 0.01 -Coverage 'claude+copilot'
            }

            $thisRun = script:New-MinimalAttribution -PortName 'implement-test' `
                -InputTok 1000 -OutputTok 500 -TotalCost 0.01 -Coverage 'claude+copilot'

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            ($flags | Where-Object { $_.metric -eq 'ports[implement-test].tokens.input' }) |
                Should -Not -BeNullOrEmpty -Because 'per-port absolute input tokens are part of the coverage-filtered anomaly metric set'
            ($flags | Where-Object { $_.metric -eq 'ports[implement-test].tokens.output' }) |
                Should -Not -BeNullOrEmpty -Because 'per-port absolute output tokens are part of the coverage-filtered anomaly metric set'
        }

        It 'treats missing-or-fallback entries as claude-only even when their coverage tag carries a fallback warning' {
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'implement-test' `
                    -InputTok 100 -OutputTok 50 -TotalCost 1.00 -Coverage 'claude+copilot'
                $entry['orchestrator_overhead']['tokens']['input'] = 500
                $history += $entry
            }
            for ($i = 0; $i -lt 15; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'implement-test' `
                    -InputTok 100 -OutputTok 50 -TotalCost 0.10 `
                    -Coverage 'claude-only-with-copilot-fallback-warning' `
                    -InstallStatus 'missing-or-fallback'
                $entry['orchestrator_overhead']['tokens']['input'] = 50
                $history += $entry
            }

            $thisRun = script:New-MinimalAttribution -PortName 'implement-test' `
                -InputTok 100 -OutputTok 50 -TotalCost 1.00 -Coverage 'claude+copilot'
            $thisRun['orchestrator_overhead']['tokens']['input'] = 500

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            ($flags | Where-Object { $_.metric -eq 'cost_estimate_usd.total' }) | Should -BeNullOrEmpty `
                -Because 'missing-or-fallback rows are effectively claude-only and must not contaminate claude+copilot cost baselines'
            ($flags | Where-Object { $_.metric -eq 'orchestrator_overhead.tokens.input' }) | Should -BeNullOrEmpty `
                -Because 'missing-or-fallback rows are effectively claude-only for absolute overhead token baselines'
        }
    }

    Context 'per-sub-issue golden inputs (M12 requirement)' {
        It 'flags #468 metric: dispatches.per_port[implement-code] when dispatch count spikes' {
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'implement-code' -DispatchCount 1
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'implement-code' -DispatchCount 2
            }
            $thisRun = script:New-MinimalAttribution -PortName 'implement-code' -DispatchCount 20

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[implement-code]' }
            $flag | Should -Not -BeNullOrEmpty
        }

        It 'flags #469 metric: orchestrator_overhead.tokens.input when overhead spikes' {
            # Build history entries with overhead tokens.input = 500 (uniform => stddev=0)
            # Use varied to get stddev>0
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'experience' -InputTok 1000
                # Adjust orchestrator_overhead.tokens.input
                $entry['orchestrator_overhead']['tokens']['input'] = 500
                $history += $entry
            }
            for ($i = 0; $i -lt 5; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'experience' -InputTok 1000
                $entry['orchestrator_overhead']['tokens']['input'] = 600
                $history += $entry
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -InputTok 1000
            $thisRun['orchestrator_overhead']['tokens']['input'] = 5000

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'orchestrator_overhead.tokens.input' }
            $flag | Should -Not -BeNullOrEmpty
        }

        It 'flags #470 metric: cache_read.hit_ratio[experience] when cache hit drops' {
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -CacheRead 800 -InputTok 100 -CacheCreate 100
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -CacheRead 5 -InputTok 100 -CacheCreate 100

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'cache_read.hit_ratio[experience]' }
            $flag | Should -Not -BeNullOrEmpty
        }

        It 'flags #471 metric: tokens.per_dispatch.avg.output[plan] when output spikes' {
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'plan' -DispatchCount 1 -OutputTok 500
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'plan' -DispatchCount 1 -OutputTok 600
            }
            $thisRun = script:New-MinimalAttribution -PortName 'plan' -DispatchCount 1 -OutputTok 10000

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'tokens.per_dispatch.avg.output[plan]' }
            $flag | Should -Not -BeNullOrEmpty
        }

        It 'flags #472 metric: tokens.per_dispatch.avg.input[plan] when input spikes' {
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'plan' -DispatchCount 1 -InputTok 1000
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'plan' -DispatchCount 1 -InputTok 1200
            }
            $thisRun = script:New-MinimalAttribution -PortName 'plan' -DispatchCount 1 -InputTok 50000

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'tokens.per_dispatch.avg.input[plan]' }
            $flag | Should -Not -BeNullOrEmpty
        }

        It 'flags #473 metric: dispatches.per_port[plan] when plan dispatch spikes' {
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'plan' -DispatchCount 1
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'plan' -DispatchCount 2
            }
            $thisRun = script:New-MinimalAttribution -PortName 'plan' -DispatchCount 20

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.per_port[plan]' }
            $flag | Should -Not -BeNullOrEmpty
        }

        It 'flags #474 metric: dispatches.general_purpose.count when gp dispatches spike' {
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'experience'
                $entry['dispatches']['general_purpose_count'] = 0
                $history += $entry
            }
            for ($i = 0; $i -lt 5; $i++) {
                $entry = script:New-MinimalAttribution -PortName 'experience'
                $entry['dispatches']['general_purpose_count'] = 1
                $history += $entry
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience'
            $thisRun['dispatches']['general_purpose_count'] = 20

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'dispatches.general_purpose.count' }
            $flag | Should -Not -BeNullOrEmpty
        }

        It 'flags #477 metric: cost_estimate_usd.total when total cost spikes' {
            $history = @()
            for ($i = 0; $i -lt 10; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -TotalCost 0.01
            }
            for ($i = 0; $i -lt 5; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -TotalCost 0.015
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -TotalCost 1.00

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            $flag = $flags | Where-Object { $_.metric -eq 'cost_estimate_usd.total' }
            $flag | Should -Not -BeNullOrEmpty
        }
    }

    Context 'empty/missing data' {
        It 'skips null total and port cost metrics instead of treating them as zero' {
            $history = @()
            for ($i = 0; $i -lt 15; $i++) {
                $history += script:New-MinimalAttribution -PortName 'experience' -TotalCost 1.00
            }
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -TotalCost 0.01
            $thisRun['ports']['experience']['cost_estimate_usd'] = $null
            $thisRun['totals']['cost_estimate_usd'] = $null

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history

            ($flags | Where-Object { $_.metric -eq 'cost_estimate_usd[experience]' }) | Should -BeNullOrEmpty
            ($flags | Where-Object { $_.metric -eq 'cost_estimate_usd.total' }) | Should -BeNullOrEmpty
        }

        It 'returns empty array when rolling history is empty' {
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 5

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory @()

            $flags | Should -BeNullOrEmpty
        }

        It 'handles null checkpoint gracefully' {
            $history = script:New-UniformHistory -Count 15 -PortName 'experience' -DispatchCount 1
            $thisRun = script:New-MinimalAttribution -PortName 'experience' -DispatchCount 1

            $flags = Get-CostAnomalyFlags -ThisRun $thisRun -RollingHistory $history -RegimeCheckpoint $null

            # Should not throw; returns empty array (no anomaly)
            $flags | Should -BeNullOrEmpty
        }
    }
}
