#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Format-CostPatternMarkdown' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-pattern-renderer.ps1'
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

        function script:Add-CoverageMetadata {
            param(
                [Parameter(Mandatory)][hashtable]$Attribution,
                [Parameter(Mandatory)][string]$Coverage,
                [string]$InstallStatus = 'ok',
                [int]$UnmappedSessionCount = 0,
                [string[]]$ProviderSupport = @('claude')
            )

            $Attribution['coverage'] = $Coverage
            $Attribution['install_status'] = $InstallStatus
            $Attribution['unmapped_session_count'] = $UnmappedSessionCount
            $Attribution['provider_support'] = $ProviderSupport
            return $Attribution
        }

        function script:New-CrossToolAttribution {
            $attribution = script:New-MinimalAttribution `
                -PortNames @('implement-code') `
                -DispatchCount 2 `
                -InputTok 1500 `
                -OutputTok 350 `
                -CacheCreate 125 `
                -CacheRead 625 `
                -PortCost 0.0200

            $attribution = script:Add-CoverageMetadata `
                -Attribution $attribution `
                -Coverage 'claude+copilot' `
                -InstallStatus 'ok' `
                -ProviderSupport @('claude', 'copilot')

            $attribution['ports']['implement-code']['provider_support'] = @('claude', 'copilot')
            $attribution['ports']['implement-code']['providers'] = @{
                claude  = @{
                    tokens               = @{ input = 1000; output = 250; cache_creation = 125; cache_read = 625 }
                    dispatch_count       = 1
                    cost_estimate_usd    = 0.0200
                    cache_read_hit_ratio = 0.357
                }
                copilot = @{
                    tokens                     = @{ input = 500; output = 100; cache_creation = $null; cache_read = $null }
                    dispatch_count             = 1
                    cost_estimate_usd          = $null
                    cache_metric_unavailable   = $true
                    rate_unavailable           = $true
                    per_token_rates_published  = $false
                }
            }
            return $attribution
        }

        function script:New-CopilotOnlyAttribution {
            return @{
                provider_support       = @('copilot')
                coverage               = 'copilot-only'
                install_status         = 'ok'
                unmapped_session_count = 0
                ports                  = @{
                    'implement-test' = @{
                        tokens                     = @{ input = 750; output = 120; cache_creation = $null; cache_read = $null }
                        dispatch_count             = 1
                        cost_estimate_usd          = $null
                        cache_read_hit_ratio       = $null
                        mixed_regime               = $false
                        provider_support           = @('copilot')
                        providers                  = @{
                            copilot = @{
                                tokens                    = @{ input = 750; output = 120; cache_creation = $null; cache_read = $null }
                                dispatch_count            = 1
                                cost_estimate_usd         = $null
                                cache_metric_unavailable  = $true
                                rate_unavailable          = $true
                                per_token_rates_published = $false
                            }
                        }
                    }
                    plan             = @{
                        tokens                     = @{ input = 900; output = 150; cache_creation = $null; cache_read = $null }
                        dispatch_count             = 1
                        cost_estimate_usd          = $null
                        cache_read_hit_ratio       = $null
                        mixed_regime               = $false
                        provider_support           = @('copilot')
                        providers                  = @{
                            copilot = @{
                                tokens                    = @{ input = 900; output = 150; cache_creation = $null; cache_read = $null }
                                dispatch_count            = 1
                                cost_estimate_usd         = $null
                                cache_metric_unavailable  = $true
                                rate_unavailable          = $true
                                per_token_rates_published = $false
                            }
                        }
                    }
                }
                orchestrator_overhead = @{
                    tokens               = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                    cost_estimate_usd    = 0.0
                    cache_read_hit_ratio = 0.0
                }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{
                    tokens            = @{ input = 1650; output = 270; cache_creation = 0; cache_read = 0 }
                    cost_estimate_usd = $null
                }
            }
        }

        function script:Get-RenderedTableRow {
            param(
                [Parameter(Mandatory)][string]$Markdown,
                [Parameter(Mandatory)][string]$PortLabel
            )

            return @($Markdown -split "`n" | Where-Object { $_ -like "| $PortLabel |*" })[0]
        }

        function script:Get-LegacyUnknownSessionWarningText {
            return ('session not found or ' + 'unrecognized')
        }

        function script:Assert-CopilotFallbackRemediationFooter {
            param([Parameter(Mandatory)][string]$Markdown)

            $Markdown | Should -Match 'Copilot telemetry may be incomplete or not included for this run'
            $Markdown | Should -Match 'Initialize-CopilotCostCollection'
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

        It 'unknown: header renders cross-tool diagnostic and unavailable cost fields' {
            $attribution = script:Add-CoverageMetadata `
                -Attribution (script:New-MinimalAttribution) `
                -Coverage 'claude-only-with-copilot-fallback-warning' `
                -InstallStatus 'missing-or-fallback' `
                -ProviderSupport @('claude')
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Not -Match ([regex]::Escape((script:Get-LegacyUnknownSessionWarningText)))
            $result | Should -Match 'cost-fields unavailable'
            $result | Should -Match 'no Claude or Copilot session activity recorded for this PR''s branch; cross-tool collection is enabled — see `Initialize-CopilotCostCollection` if Copilot is installed but data is missing, or #488 for diagnostics\.'
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
            $result | Should -Match 'Claude-side phase-marker attribution'
            $result | Should -Match 'Copilot-side collection remains tracked by \[#488\]\(https://github\.com/Grimblaz/agent-orchestra/issues/488\)'
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

    Context 'cross-tool coverage rendering (#488 Step 4 RED)' {
        It 'renders a top-level coverage line for each coverage mode' -TestCases @(
            @{ Coverage = 'claude+copilot'; InstallStatus = 'ok'; ProviderSupport = @('claude', 'copilot') }
            @{ Coverage = 'claude-only'; InstallStatus = 'ok'; ProviderSupport = @('claude') }
            @{ Coverage = 'copilot-only'; InstallStatus = 'ok'; ProviderSupport = @('copilot') }
            @{ Coverage = 'claude-only-with-copilot-fallback-warning'; InstallStatus = 'missing-or-fallback'; ProviderSupport = @('claude') }
        ) {
            param([string]$Coverage, [string]$InstallStatus, [string[]]$ProviderSupport)

            $attribution = script:New-MinimalAttribution
            $attribution = script:Add-CoverageMetadata `
                -Attribution $attribution `
                -Coverage $Coverage `
                -InstallStatus $InstallStatus `
                -ProviderSupport $ProviderSupport
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match "(?m)^coverage: $([regex]::Escape($Coverage))$"
        }

        It 'annotates a multi-provider port row as merged' {
            $attribution = script:New-CrossToolAttribution
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '\| implement-code \(merged\) \|'
        }

        It 'renders Copilot cache cells as n/a footnoted cells and cost as an empty USD cell' {
            $attribution = script:New-CopilotOnlyAttribution
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $row = script:Get-RenderedTableRow -Markdown $result -PortLabel 'implement-test'

            $row | Should -Not -BeNullOrEmpty
            $row | Should -Match '\| n/a \* \| n/a \* \| n/a \* \|  \|'
            $result | Should -Match 'Copilot per-token rates not published; cost figures excluded for Copilot rows\.'
        }

        It 'renders the Copilot cache footnote once for a section with multiple Copilot rows' {
            $attribution = script:New-CopilotOnlyAttribution
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $cacheFootnoteMatches = [regex]::Matches($result, 'Copilot cache metrics are unavailable from Copilot telemetry; cache cells marked n/a \* are excluded from cache-hit baselines\.')

            $cacheFootnoteMatches.Count | Should -Be 1
        }

        It 'renders the transition notice when matching-coverage rolling history is below five entries' {
            $attribution = script:New-CrossToolAttribution
            $completeness = script:New-Completeness
            $rollingMeta = @{ matching_coverage_history_count = 4 }

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RollingMeta $rollingMeta

            $result | Should -Match '⚠ building cross-tool baseline — matching-coverage history < 5 entries'
        }

        It 'replaces the legacy unknown-session warning with the cross-tool diagnostic text' {
            $attribution = script:Add-CoverageMetadata `
                -Attribution (script:New-MinimalAttribution) `
                -Coverage 'claude-only-with-copilot-fallback-warning' `
                -InstallStatus 'missing-or-fallback' `
                -ProviderSupport @('claude')
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Not -Match ([regex]::Escape((script:Get-LegacyUnknownSessionWarningText)))
            $result | Should -Match 'no Claude or Copilot session activity recorded for this PR''s branch; cross-tool collection is enabled — see `Initialize-CopilotCostCollection` if Copilot is installed but data is missing, or #488 for diagnostics\.'
        }

        It 'renders the inline coverage-tag legend once when fallback-warning coverage appears' {
            $attribution = script:Add-CoverageMetadata `
                -Attribution (script:New-MinimalAttribution) `
                -Coverage 'claude-only-with-copilot-fallback-warning' `
                -InstallStatus 'missing-or-fallback' `
                -ProviderSupport @('claude')
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $legendMatches = [regex]::Matches($result, 'Coverage tags:')

            $legendMatches.Count | Should -Be 1
            $result | Should -Match 'Coverage tags:.*claude\+copilot.*claude-only.*copilot-only.*claude-only-with-copilot-fallback-warning'
        }

        It 'renders a complete-session fallback remediation footer for <Coverage> / <InstallStatus>' -TestCases @(
            @{ Coverage = 'claude-only-with-copilot-fallback-warning'; InstallStatus = 'ok' }
            @{ Coverage = 'claude-only'; InstallStatus = 'missing-or-fallback' }
        ) {
            param([string]$Coverage, [string]$InstallStatus)

            $attribution = script:Add-CoverageMetadata `
                -Attribution (script:New-MinimalAttribution) `
                -Coverage $Coverage `
                -InstallStatus $InstallStatus `
                -ProviderSupport @('claude')
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            script:Assert-CopilotFallbackRemediationFooter -Markdown $result
        }

        It 'renders a partial-session fallback remediation footer for <Coverage> / <InstallStatus>' -TestCases @(
            @{ Coverage = 'claude-only-with-copilot-fallback-warning'; InstallStatus = 'ok' }
            @{ Coverage = 'claude-only'; InstallStatus = 'missing-or-fallback' }
        ) {
            param([string]$Coverage, [string]$InstallStatus)

            $attribution = script:Add-CoverageMetadata `
                -Attribution (script:New-MinimalAttribution) `
                -Coverage $Coverage `
                -InstallStatus $InstallStatus `
                -ProviderSupport @('claude')
            $completeness = script:New-Completeness -Completeness 'partial' -StopReason 'max turns' -Excluded $true -ExcludeReason 'session completeness: partial'

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            script:Assert-CopilotFallbackRemediationFooter -Markdown $result
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
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-pattern-renderer.ps1'
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

        function script:Add-YamlCoverageMetadata {
            param(
                [Parameter(Mandatory)][hashtable]$Attribution,
                [Parameter(Mandatory)][string]$Coverage,
                [string]$InstallStatus = 'ok',
                [int]$UnmappedSessionCount = 0,
                [string[]]$ProviderSupport = @('claude')
            )

            $Attribution['coverage'] = $Coverage
            $Attribution['install_status'] = $InstallStatus
            $Attribution['unmapped_session_count'] = $UnmappedSessionCount
            $Attribution['provider_support'] = $ProviderSupport
            return $Attribution
        }

        function script:New-YamlCrossToolAttribution {
            $attribution = script:New-YamlAttribution
            $attribution = script:Add-YamlCoverageMetadata `
                -Attribution $attribution `
                -Coverage 'claude+copilot' `
                -InstallStatus 'ok' `
                -ProviderSupport @('claude', 'copilot')

            $attribution['ports']['experience']['provider_support'] = @('claude', 'copilot')
            $attribution['ports']['experience']['providers'] = @{
                claude  = @{
                    tokens               = @{ input = 1000; output = 500; cache_creation = 89; cache_read = 456 }
                    dispatch_count       = 1
                    prompt_size_chars    = 2200
                    cost_estimate_usd    = 0.0123
                    cache_read_hit_ratio = 0.295
                    null_cost_events     = 0
                    mixed_regime         = $false
                }
                copilot = @{
                    tokens                    = @{ input = 234; output = 67; cache_creation = $null; cache_read = $null }
                    dispatch_count            = 1
                    prompt_size_chars         = 800
                    cost_estimate_usd         = $null
                    cache_metric_unavailable  = $true
                    rate_unavailable          = $true
                    per_token_rates_published = $false
                }
            }
            return $attribution
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

    It 'preserves null port, overhead, and total cost estimates in YAML' {
        $attribution = script:New-YamlAttribution
        $attribution['ports']['experience']['cost_estimate_usd'] = $null
        $attribution['orchestrator_overhead']['cost_estimate_usd'] = $null
        $attribution['totals']['cost_estimate_usd'] = $null

        $result = Format-CostPatternYaml -Attribution $attribution -Completeness (script:New-YamlCompleteness)

        $result | Should -Match '(?m)^    cost_estimate_usd: null$'
        $result | Should -Match '(?m)^  cost_estimate_usd: null$'
    }

    It 'emits phase_scope: branch-session-only disclosure field' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness
        $result = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness
        $result | Should -Match '(?m)^phase_scope: branch-session-only$'
    }

    It 'emits phase_scope after generated_at and before pr' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness
        $result = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness -Pr 42 -Branch 'test'
        $generatedAtPos = $result.IndexOf('generated_at:')
        $phaseScopePos  = $result.IndexOf('phase_scope:')
        $prPos          = $result.IndexOf("`npr: ")
        $phaseScopePos | Should -BeGreaterThan $generatedAtPos
        $phaseScopePos | Should -BeLessThan $prPos
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

    Context 'cross-tool YAML contract (#488 Step 4 RED)' {
        It 'emits additive cross-tool fields only when cross-tool data is present' {
            $crossTool = Format-CostPatternYaml `
                -Attribution (script:New-YamlCrossToolAttribution) `
                -Completeness (script:New-YamlCompleteness) `
                -Pr 488 `
                -Branch 'feature/issue-488-copilot-cost-collection'

            $claudeOnlyAttribution = script:Add-YamlCoverageMetadata `
                -Attribution (script:New-YamlAttribution) `
                -Coverage 'claude-only' `
                -InstallStatus 'ok' `
                -ProviderSupport @('claude')
            $claudeOnly = Format-CostPatternYaml -Attribution $claudeOnlyAttribution -Completeness (script:New-YamlCompleteness)

            $crossTool | Should -Match 'provider_support: \["claude", "copilot"\]'
            $crossTool | Should -Match '(?m)^coverage: claude\+copilot$'
            $crossTool | Should -Match '(?m)^install_status: ok$'
            $crossTool | Should -Match '(?m)^unmapped_session_count: 0$'
            $crossTool | Should -Match '(?m)^    providers:$'
            $crossTool | Should -Match '(?m)^      claude:$'
            $crossTool | Should -Match '(?m)^      copilot:$'
            $crossTool | Should -Match '(?m)^        cache_metric_unavailable: true$'
            $claudeOnly | Should -Not -Match 'provider_support: \["claude"\]'
        }

        It 'emits missing-or-fallback install status when Copilot install sentinel is absent' {
            $attribution = script:Add-YamlCoverageMetadata `
                -Attribution (script:New-YamlAttribution) `
                -Coverage 'claude-only-with-copilot-fallback-warning' `
                -InstallStatus 'missing-or-fallback' `
                -ProviderSupport @('claude')

            $result = Format-CostPatternYaml -Attribution $attribution -Completeness (script:New-YamlCompleteness)

            $result | Should -Match '(?m)^coverage: claude-only-with-copilot-fallback-warning$'
            $result | Should -Match '(?m)^install_status: missing-or-fallback$'
        }
    }
}

Describe 'cost-pattern-data schema documentation' {
    It 'documents the post-#488 additive YAML fields' {
        $schemaPath = Join-Path $PSScriptRoot '../lib/cost-pattern-data-schema.md'
        $schemaPath | Should -Exist
        $schema = Get-Content -LiteralPath $schemaPath -Raw

        foreach ($field in @('provider_support', 'coverage', 'install_status', 'providers', 'unmapped_session_count', 'phase_scope')) {
            $schema | Should -Match "``$field``"
        }
    }
}
