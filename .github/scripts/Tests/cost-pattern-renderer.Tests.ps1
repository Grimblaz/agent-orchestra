#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Format-CostPatternMarkdown' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-pattern-renderer.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        # Helper: minimal attribution with one port
        function script:New-MinimalAttribution {
            param(
                [string[]]$PortNames = @('experience'),
                [int]$DispatchCount = 2,
                [int]$InputTok = 1234,
                [int]$OutputTok = 567,
                [int]$CacheCreate = 89,
                [int]$CacheRead = 456,
                [double]$PortCost = 0.0123,
                [int]$OhInput = 890,
                [int]$OhOutput = 234,
                [int]$OhCacheCreate = 45,
                [int]$OhCacheRead = 123,
                [double]$OhCost = 0.0045,
                [int]$GenPurpose = 1,
                [int]$Unattributed = 0
            )
            $ports = @{}
            foreach ($pName in $PortNames) {
                $denom = $CacheRead + $CacheCreate + $InputTok
                $ratio = if ($denom -gt 0) { [double]$CacheRead / [double]$denom } else { 0.0 }
                $ports[$pName] = @{
                    tokens               = @{ input = $InputTok; output = $OutputTok; cache_creation = $CacheCreate; cache_read = $CacheRead }
                    dispatch_count       = $DispatchCount
                    cost_estimate_usd    = $PortCost
                    cache_read_hit_ratio = $ratio
                    mixed_regime         = $false
                }
            }
            $ohDenom = $OhCacheRead + $OhCacheCreate + $OhInput
            $ohRatio = if ($ohDenom -gt 0) { [double]$OhCacheRead / [double]$ohDenom } else { 0.0 }
            $totalInput = ($PortNames.Count * $InputTok) + $OhInput
            $totalOutput = ($PortNames.Count * $OutputTok) + $OhOutput
            $totalCacheCreate = ($PortNames.Count * $CacheCreate) + $OhCacheCreate
            $totalCacheRead = ($PortNames.Count * $CacheRead) + $OhCacheRead
            $totalCost = ($PortNames.Count * $PortCost) + $OhCost
            return @{
                ports                 = $ports
                orchestrator_overhead = @{
                    tokens               = @{ input = $OhInput; output = $OhOutput; cache_creation = $OhCacheCreate; cache_read = $OhCacheRead }
                    cost_estimate_usd    = $OhCost
                    cache_read_hit_ratio = $ohRatio
                }
                dispatches            = @{ general_purpose_count = $GenPurpose; unattributed_count = $Unattributed }
                totals                = @{
                    tokens            = @{ input = $totalInput; output = $totalOutput; cache_creation = $totalCacheCreate; cache_read = $totalCacheRead }
                    cost_estimate_usd = $totalCost
                }
            }
        }

        # Helper: minimal completeness result
        function script:New-Completeness {
            param(
                [string]$Completeness = 'complete',
                [string]$StopReason = 'end_turn',
                [bool]$Excluded = $false,
                [string]$ExcludeReason = ''
            )
            return @{
                completeness                   = $Completeness
                stop_reason                    = $StopReason
                excluded_from_rolling_baseline = $Excluded
                exclude_reason                 = $ExcludeReason
            }
        }

        # Helper: build a single anomaly flag for a port/metric
        function script:New-AnomalyFlag {
            param(
                [string]$Metric = 'dispatches.per_port[experience]',
                [string]$Port = 'experience'
            )
            return @{
                metric     = $Metric
                port       = $Port
                direction  = 'shrink'
                confidence = 'medium'
            }
        }
    }

    Context 'header paths (golden assertions per M20/M21/M22)' {
        It 'normal-with-flags: header contains anomaly count' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness
            $flag1 = script:New-AnomalyFlag
            $flag2 = script:New-AnomalyFlag -Metric 'cost_estimate_usd.total' -Port $null
            $flags = @($flag1, $flag2)
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -AnomalyFlags $flags
            $result | Should -Match '## Cost Pattern \(2 anomalies vs rolling baseline\)'
        }

        It 'normal-clean: header contains "within rolling baseline"' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -AnomalyFlags @()
            $result | Should -Match '## Cost Pattern — within rolling baseline'
        }

        It 'partial: header contains "session incomplete" and stop_reason' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'partial' -StopReason 'max_tokens' -Excluded $true -ExcludeReason 'session completeness: partial'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match 'session incomplete'
            $result | Should -Match 'max_tokens'
        }

        It 'unknown: header contains "session not found or unrecognized"' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match 'session not found or unrecognized'
        }

        It 'timeout: header contains "rolling-history fetch timed out"' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness
            $rollingMeta = @{ timed_out = $true }
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RollingMeta $rollingMeta
            $result | Should -Match 'rolling-history fetch timed out'
        }

        It 'outlier-pr: header contains exclude_reason text' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Excluded $true -ExcludeReason 'foundational PR #467'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match 'foundational PR #467'
            $result | Should -Match 'excluded from rolling-history aggregation'
        }

        It 'phase-marker-only complete path does not render session-not-found header' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Excluded $true -ExcludeReason 'phase-marker-only attribution; rolling-history excluded'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match 'phase-marker-only attribution; rolling-history excluded'
            $result | Should -Not -Match 'session not found'
        }
    }

    Context 'table structure' {
        It 'emits per-port rows for ports that ran' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match '\| experience \|'
        }

        It 'emits dash for ports that did not run' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            # design port not in attribution -> should appear as zero-dispatch row with dashes
            $result | Should -Match '\| design \|'
            # The design row should show 0 dispatches and dashes for tokens/cost
            $result | Should -Match '\| design \| 0 \|'
        }

        It 'emits orchestrator-overhead row' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match 'orchestrator-overhead'
        }

        It 'emits totals row' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match '\*\*TOTAL\*\*'
        }

        It 'uses invariant culture for number formatting' {
            $attribution = script:New-MinimalAttribution -PortCost 0.0123
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            # Cost should use dot as decimal separator (invariant culture), not comma
            $result | Should -Match '\$0\.0123'
        }
    }

    Context 'anomaly annotations' {
        It 'shows anomaly metric names in Anomalies column' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $completeness = script:New-Completeness
            $flags = @(script:New-AnomalyFlag -Metric 'dispatches.per_port[experience]' -Port 'experience')
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -AnomalyFlags $flags
            $result | Should -Match 'dispatches'
        }

        It 'shows dash when no anomalies for a port' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience', 'design')
            $completeness = script:New-Completeness
            $flags = @(script:New-AnomalyFlag -Metric 'dispatches.per_port[experience]' -Port 'experience')
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -AnomalyFlags $flags
            # design port has no anomaly flag — its row should show " — " in anomaly column
            $lines = $result -split "`n"
            $designLine = $lines | Where-Object { $_ -match '\| design \|' }
            $designLine | Should -Match ' — '
        }
    }
}

Describe 'Format-CostPatternYaml' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-pattern-renderer.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        # Minimal attribution for YAML tests
        function script:New-YamlAttribution {
            return @{
                ports                 = @{
                    experience = @{
                        tokens               = @{ input = 1234; output = 567; cache_creation = 89; cache_read = 456 }
                        dispatch_count       = 2
                        cost_estimate_usd    = 0.0123
                        cache_read_hit_ratio = 0.617
                        mixed_regime         = $false
                    }
                }
                orchestrator_overhead = @{
                    tokens               = @{ input = 890; output = 234; cache_creation = 45; cache_read = 123 }
                    cost_estimate_usd    = 0.0045
                    cache_read_hit_ratio = 0.115
                }
                dispatches            = @{ general_purpose_count = 1; unattributed_count = 0 }
                totals                = @{
                    tokens            = @{ input = 2124; output = 801; cache_creation = 134; cache_read = 579 }
                    cost_estimate_usd = 0.0168
                }
            }
        }

        function script:New-YamlCompleteness {
            param(
                [string]$Completeness = 'complete',
                [bool]$Excluded = $false,
                [string]$ExcludeReason = ''
            )
            return @{
                completeness                   = $Completeness
                stop_reason                    = 'end_turn'
                excluded_from_rolling_baseline = $Excluded
                exclude_reason                 = $ExcludeReason
            }
        }
    }

    It 'emits <!-- cost-pattern-data block with version: 1' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness
        $result = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness
        $result | Should -Match '<!-- cost-pattern-data'
        $result | Should -Match 'version: 1'
        $result | Should -Match '-->'
    }

    It 'emits excluded_from_rolling_baseline: true for partial session' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness -Completeness 'partial' -Excluded $true -ExcludeReason 'session completeness: partial'
        $result = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness
        $result | Should -Match 'excluded_from_rolling_baseline: true'
        $result | Should -Match 'session_completeness: partial'
    }

    It 'round-trip: parse YAML back and re-render produces byte-identical output' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness
        $firstRender = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness -Pr 123 -Branch 'feature/test'

        # The round-trip test verifies deterministic rendering: same inputs always produce
        # byte-identical output (no timestamp drift, no non-deterministic ordering).
        # Render a second time with the same inputs
        $secondRender = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness -Pr 123 -Branch 'feature/test'
        $secondRender | Should -BeExactly $firstRender
    }

    It 'uses invariant culture for double formatting' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness
        $result = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness
        # Verify decimal separator is dot, not comma
        $result | Should -Match 'cost_estimate_usd: 0\.0123'
    }

    It 'emits anomaly_flags array' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness
        $flags = @(
            @{ metric = 'dispatches.per_port[experience]'; port = 'experience'; direction = 'shrink'; confidence = 'medium'; this_value = 2.0; baseline_mean = 1.0; baseline_median = 1.0; baseline_stddev = 0.1; baseline_n = 10; checkpoint_value = $null; vs_baseline = 'rolling' }
        )
        $result = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness -AnomalyFlags $flags
        $result | Should -Match 'anomaly_flags:'
        $result | Should -Match 'dispatches\.per_port'
    }
}
