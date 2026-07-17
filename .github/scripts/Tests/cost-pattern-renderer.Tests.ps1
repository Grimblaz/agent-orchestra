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

        It 'unknown: header renders honest environment-state diagnostic and unavailable cost fields, no #488 pointer' {
            $attribution = script:Add-CoverageMetadata `
                -Attribution (script:New-MinimalAttribution) `
                -Coverage 'claude-only-with-copilot-fallback-warning' `
                -InstallStatus 'missing-or-fallback' `
                -ProviderSupport @('claude')
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $false }
            $result | Should -Not -Match ([regex]::Escape((script:Get-LegacyUnknownSessionWarningText)))
            $result | Should -Match 'cost-fields unavailable'
            $result | Should -Match 'no local session data on this machine'
            $result | Should -Not -Match '488'
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
            $result | Should -Match 'Copilot-side collection was not captured for this run'
            $result | Should -Not -Match '488'
            $result | Should -Not -Match 'session not found'
        }
    }

    Context 'unknown-completeness three render states (issue #825 s2, M12)' {
        It 'CI state: RenderContext IsCi true renders the CI-cannot-see-local-transcripts message' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $true; ProjectsRootPresent = $false }
            $result | Should -Match 'CI cannot see local transcripts'
            $result | Should -Not -Match '488'
            $result | Should -Not -Match 'no session activity'
        }

        It 'non-CI, no local projects root: renders the no-local-session-data message' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $false }
            $result | Should -Match 'no local session data on this machine'
            $result | Should -Not -Match '488'
            $result | Should -Not -Match 'no session activity'
        }

        It 'non-CI, projects root present, genuinely empty walk: renders the honest-zero message naming the pinned loss modes' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $true }
            $result | Should -Match 'transcripts were searched on this machine and none matched'
            $result | Should -Match 'walk ran where transcripts are unavailable'
            $result | Should -Match 'local walk never ran or exited before the cost step'
            $result | Should -Match 'since-deleted sibling worktree'
            $result | Should -Match 'mid-session'
            $result | Should -Match 'linked issue could not be resolved'
            $result | Should -Not -Match '488'
            $result | Should -Not -Match 'no session activity'
        }

        It 'all three unknown-completeness states are textually distinct' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $ci = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $true; ProjectsRootPresent = $false }
            $noRoot = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $false }
            $emptyWalk = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $true }
            $ci | Should -Not -BeExactly $noRoot
            $ci | Should -Not -BeExactly $emptyWalk
            $noRoot | Should -Not -BeExactly $emptyWalk
        }

        It 'non-CI, projects root present, walker budget-exceeded (L11, issue #825 post-review fix): renders a distinct message naming the timeout/budget cause, not the genuine-empty-walk message' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $true; DegradedReason = 'budget-exceeded' }
            $result | Should -Match 'exceeded its time budget'
            $result | Should -Match 'FRAME_CREDIT_LEDGER_TEST_COST_BUDGET_SECONDS'
            $result | Should -Not -Match 'transcripts were searched on this machine and none matched'
            $result | Should -Not -Match '488'
            $result | Should -Not -Match 'no session activity'
        }

        It 'all four unknown-completeness states (including budget-exceeded, L11) are textually distinct from each other' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $ci = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $true; ProjectsRootPresent = $false }
            $noRoot = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $false }
            $emptyWalk = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $true }
            $budgetExceeded = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $true; DegradedReason = 'budget-exceeded' }
            $states = @($ci, $noRoot, $emptyWalk, $budgetExceeded)
            for ($i = 0; $i -lt $states.Count; $i++) {
                for ($j = $i + 1; $j -lt $states.Count; $j++) {
                    $states[$i] | Should -Not -BeExactly $states[$j] -Because "state $i and state $j must render distinct text"
                }
            }
        }
    }

    Context 'coverage annotation on populated blocks (issue #825 s2, M6)' {
        It 'appends the coverage annotation when RejectedDirCount is greater than zero' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RejectedDirCount 3
            $result | Should -Match 'activity from 3 unverifiable location\(s\) may be excluded'
        }

        It 'omits the coverage annotation when RejectedDirCount is zero' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RejectedDirCount 0
            $result | Should -Not -Match 'unverifiable location'
        }

        It 'never appends the coverage annotation on an unknown-completeness (unpopulated) block, even with RejectedDirCount set' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $true } -RejectedDirCount 5
            $result | Should -Not -Match 'unverifiable location'
        }
    }

    Context 'eligible-partial header (mid-session baseline-eligible, issue #824 M6)' {
        It 'clean: header always carries the mid-session disclosure and never the excluded-partial or clean-baseline strings' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'partial' -StopReason 'tool_use' -Excluded $false
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match 'mid-session capture — baseline-eligible; totals may understate the final turn'
            $result | Should -Not -Match 'session incomplete'
            $result | Should -Not -Match 'excluded from rolling-history aggregation'
            $result | Should -Not -Match 'within rolling baseline'
        }

        It 'anomalies present: header carries disclosure AND the anomaly-count qualifier, self-contained' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'partial' -StopReason 'tool_use' -Excluded $false
            $flag1 = script:New-AnomalyFlag
            $flag2 = script:New-AnomalyFlag -Metric 'cost_estimate_usd.total' -Port $null
            $flags = @($flag1, $flag2)
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -AnomalyFlags $flags
            $result | Should -Match 'mid-session capture — baseline-eligible; totals may understate the final turn'
            $result | Should -Match '2 anomalies vs rolling baseline'
            $result | Should -Not -Match 'excluded from rolling-history aggregation'
        }

        It 'rolling-history timed out: header carries disclosure AND the timed-out qualifier, self-contained' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'partial' -StopReason 'tool_use' -Excluded $false
            $rollingMeta = @{ timed_out = $true }
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RollingMeta $rollingMeta
            $result | Should -Match 'mid-session capture — baseline-eligible; totals may understate the final turn'
            $result | Should -Match 'rolling-history fetch timed out'
            $result | Should -Not -Match 'excluded from rolling-history aggregation'
        }

        It 'excluded partial (excluded_from_rolling_baseline true) still uses the legacy excluded-partial string, not the disclosure' {
            $attribution = script:New-MinimalAttribution
            $completeness = script:New-Completeness -Completeness 'partial' -StopReason 'max_tokens' -Excluded $true -ExcludeReason 'session completeness: partial'
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match 'session incomplete'
            $result | Should -Not -Match 'mid-session capture — baseline-eligible'
        }
    }

    Context 'table structure' {
        It 'emits per-port rows for ports that ran' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match '\| experience \|'
        }

        It 'omits a zero-activity port that did not run (issue #489 s1 suppression)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $completeness = script:New-Completeness
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            # design port not in attribution and carries no anomaly flag -> suppressed,
            # not rendered as a zero-dispatch dash row (issue #489 s1 changed this).
            $result | Should -Not -Match '\| design \|'
            $result | Should -Match 'ports had zero dispatches, zero attributed cost, and zero token activity, and are omitted from this table\.'
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

        It 'replaces the legacy unknown-session warning with an honest environment-state message, never #488' {
            $attribution = script:Add-CoverageMetadata `
                -Attribution (script:New-MinimalAttribution) `
                -Coverage 'claude-only-with-copilot-fallback-warning' `
                -InstallStatus 'missing-or-fallback' `
                -ProviderSupport @('claude')
            $completeness = script:New-Completeness -Completeness 'unknown' -StopReason $null -Excluded $true -ExcludeReason 'session completeness: unknown'

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -RenderContext @{ IsCi = $false; ProjectsRootPresent = $false }

            $result | Should -Not -Match ([regex]::Escape((script:Get-LegacyUnknownSessionWarningText)))
            $result | Should -Match 'no local session data on this machine'
            $result | Should -Not -Match '488'
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

        It 'treats a flag with a null metric as no anomaly rather than a blank name (C14)' {
            $attribution = script:New-MinimalAttribution -PortNames @('design')
            $completeness = script:New-Completeness
            # Built directly (not via New-AnomalyFlag) — that helper's [string]
            # parameter coerces a $null argument to '', which would not
            # exercise the true-null case this fix targets.
            $flags = @(@{ metric = $null; port = 'design'; direction = 'shrink'; confidence = 'medium' })
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -AnomalyFlags $flags
            $lines = $result -split "`n"
            $designLine = $lines | Where-Object { $_ -match '\| design \|' }
            $designLine | Should -Match ' — '
        }

        It 'treats a flag with a blank metric as no anomaly rather than a blank name (C14)' {
            $attribution = script:New-MinimalAttribution -PortNames @('design')
            $completeness = script:New-Completeness
            $flags = @(script:New-AnomalyFlag -Metric '' -Port 'design')
            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness -AnomalyFlags $flags
            $lines = $result -split "`n"
            $designLine = $lines | Where-Object { $_ -match '\| design \|' }
            $designLine | Should -Match ' — '
        }
    }

    Context 'null-event Note per-reason breakdown (issue #487 s3)' {
        It 'names unknown models verbatim, provider-qualified, and code-span-wrapped (AC2 core case)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 2
            $attribution['unknown_models'] = @('claude/claude-unknown-future-model', 'copilot/gpt-4o-mini')
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 2; rate_unavailable = 0; empty_model = 0 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '`claude/claude-unknown-future-model`'
            $result | Should -Match '`copilot/gpt-4o-mini`'
            $result | Should -Match '2 event\(s\) from models missing from the rate table'
        }

        It 'omits zero-count clauses, rendering only the unknown_key clause when the other two reasons are zero' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 1
            $attribution['unknown_models'] = @('claude/claude-unknown-future-model')
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 0; empty_model = 0 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match 'models missing from the rate table'
            $result | Should -Not -Match 'intentionally unpublished rates'
            $result | Should -Not -Match 'had no model identifier'
        }

        It 'renders all three per-reason clauses when unknown_key, rate_unavailable, and empty_model are all nonzero' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 6
            $attribution['unknown_models'] = @('claude/claude-unknown-future-model')
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 2; empty_model = 3 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '1 event\(s\) from models missing from the rate table:.*— add rows to `cost-rate-table\.json` \(see `cost-rate-table\.md` for the exact row format\)\.'
            $result | Should -Match '2 event\(s\) from models with intentionally unpublished rates\.'
            $result | Should -Match '3 event\(s\) had no model identifier\.'
        }

        It 'includes the cost-rate-table.md pointer in the unknown_key clause (CE-F1)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 1
            $attribution['unknown_models'] = @('claude/claude-unknown-future-model')
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 0; empty_model = 0 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '\(see `cost-rate-table\.md` for the exact row format\)'
        }

        It 'renders the by-design "intentionally unpublished" clause count-only, with no model named, for an all-four-null Copilot-shaped row (CE-F2)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 2
            $attribution['unknown_models'] = @()
            $attribution['malformed_rate_models'] = @()
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 0; rate_unavailable = 2; rate_unavailable_malformed = 0; empty_model = 0 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '2 event\(s\) from models with intentionally unpublished rates\.'
            $result | Should -Not -Match 'incomplete rate-table row'
            $result | Should -Not -Match 'copilot/'
            $result | Should -Not -Match 'claude/'
        }

        It 'renders the neutral, model-naming clause for a partial-null (malformed) rate row, without claiming it is intentional (CE-F2)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 1
            $attribution['unknown_models'] = @()
            $attribution['malformed_rate_models'] = @('claude/claude-fatfingered-model')
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 0; rate_unavailable = 1; rate_unavailable_malformed = 1; empty_model = 0 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '1 event\(s\) from models with an incomplete rate-table row \(some rate fields are null\): `claude/claude-fatfingered-model` — check `cost-rate-table\.json`\.'
            $result | Should -Not -Match 'intentionally unpublished'
        }

        It 'renders all four clauses cleanly separated when unknown_key, by-design rate_unavailable, malformed rate_unavailable, and empty_model are all nonzero (CE-F2 mixed fixture)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 7
            $attribution['unknown_models'] = @('claude/claude-unknown-future-model')
            $attribution['malformed_rate_models'] = @('claude/claude-fatfingered-model')
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 2; rate_unavailable_malformed = 1; empty_model = 3 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '1 event\(s\) from models missing from the rate table: `claude/claude-unknown-future-model` — add rows to `cost-rate-table\.json` \(see `cost-rate-table\.md` for the exact row format\)\.'
            $result | Should -Match '1 event\(s\) from models with intentionally unpublished rates\.' -Because 'rate_unavailable (2) minus rate_unavailable_malformed (1) leaves 1 by-design event'
            $result | Should -Match '1 event\(s\) from models with an incomplete rate-table row \(some rate fields are null\): `claude/claude-fatfingered-model` — check `cost-rate-table\.json`\.'
            $result | Should -Match '3 event\(s\) had no model identifier\.'
        }

        It 'defaults rate_unavailable_malformed to 0 and preserves the original count-only clause when the field is absent (backwards compatibility)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 2
            $attribution['unknown_models'] = @()
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 0; rate_unavailable = 2; empty_model = 0 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '2 event\(s\) from models with intentionally unpublished rates\.'
            $result | Should -Not -Match 'incomplete rate-table row'
        }

        Context 'sanitizer neutralizes dangerous characters in the Note (plan findings M2/M10/M11/M13)' {
            It 'neutralizes an embedded newline, preventing a forged top-level field' {
                $attribution = script:New-MinimalAttribution -PortNames @('experience')
                $attribution['ports']['experience']['null_cost_events'] = 1
                $attribution['unknown_models'] = @("claude/evil`nsession_id: hijacked")
                $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 0; empty_model = 0 }
                $completeness = script:New-Completeness

                $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

                $result | Should -Not -Match "evil`nsession_id"
                ($result -split "`n" | Where-Object { $_ -match '^session_id:' }) | Should -BeNullOrEmpty
            }

            It 'neutralizes an embedded comma, preventing the model list from splitting into an extra entry' {
                $attribution = script:New-MinimalAttribution -PortNames @('experience')
                $attribution['ports']['experience']['null_cost_events'] = 1
                $attribution['unknown_models'] = @('claude/evil,injected-model')
                $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 0; empty_model = 0 }
                $completeness = script:New-Completeness

                $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

                $result | Should -Not -Match 'claude/evil,injected-model'
                $result | Should -Match 'claude/evil injected-model'
            }

            It 'round-trips a literal quote without corrupting the rendered Note' {
                $attribution = script:New-MinimalAttribution -PortNames @('experience')
                $attribution['ports']['experience']['null_cost_events'] = 1
                $attribution['unknown_models'] = @('claude/evil"quoted')
                $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 0; empty_model = 0 }
                $completeness = script:New-Completeness

                $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

                $result | Should -Match '`claude/evil"quoted`'
            }

            It 'neutralizes an embedded <!-- comment-open marker' {
                $attribution = script:New-MinimalAttribution -PortNames @('experience')
                $attribution['ports']['experience']['null_cost_events'] = 1
                $attribution['unknown_models'] = @('claude/evil<!--forged')
                $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 0; empty_model = 0 }
                $completeness = script:New-Completeness

                $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

                $result | Should -Not -Match '<!--forged'
                $result | Should -Match '\(comment-open\)forged'
            }

            It 'neutralizes an embedded --> comment-close marker' {
                $attribution = script:New-MinimalAttribution -PortNames @('experience')
                $attribution['ports']['experience']['null_cost_events'] = 1
                $attribution['unknown_models'] = @('claude/evil-->forged')
                $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 0; empty_model = 0 }
                $completeness = script:New-Completeness

                $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

                $result | Should -Not -Match 'evil-->forged'
                $result | Should -Match 'evil\(comment-close\)forged'
            }

            It 'neutralizes an embedded backtick, preventing a Markdown link from escaping the code span (plan finding M1)' {
                $attribution = script:New-MinimalAttribution -PortNames @('experience')
                $attribution['ports']['experience']['null_cost_events'] = 1
                $attribution['unknown_models'] = @('claude/evil`[click me](http://evil.example)')
                $attribution['null_cost_events_by_reason'] = @{ unknown_key = 1; rate_unavailable = 0; empty_model = 0 }
                $completeness = script:New-Completeness

                $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

                # The backtick is neutralized to a placeholder, so no unescaped
                # backtick reaches the Note — the enclosing code span cannot be
                # closed early and the link text stays inert (not a live anchor).
                $result | Should -Not -Match '`\[click me\]\(http://evil\.example\)`'
                $result | Should -Match '\(backtick\)\[click me\]\(http://evil\.example\)'
                # The whole sanitized entry is wrapped in exactly one backtick
                # pair (the Note's own wrapping), confirming no unescaped
                # backtick from the payload survives inside that span.
                $result | Should -Match '`claude/evil\(backtick\)\[click me\]\(http://evil\.example\)`'
            }
        }

        It 'covers a Copilot-origin unknown string alongside a transcript-origin string (plan finding M19)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 2
            # Copilot-origin shape: cost-walker-copilot.ps1 lifts gen_ai.response.model
            # verbatim, which for OpenAI-family models contains dots (this exact shape),
            # unlike Claude's hyphen-only model names.
            $attribution['unknown_models'] = @('claude/claude-unknown-future-model', 'copilot/gpt-4o-mini-2024-07-18')
            $attribution['null_cost_events_by_reason'] = @{ unknown_key = 2; rate_unavailable = 0; empty_model = 0 }
            $completeness = script:New-Completeness

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness

            $result | Should -Match '`claude/claude-unknown-future-model`'
            $result | Should -Match '`copilot/gpt-4o-mini-2024-07-18`'
        }

        It 'renders the old count-only Note when unknown_models / null_cost_events_by_reason are absent (backwards compatibility)' {
            $attribution = script:New-MinimalAttribution -PortNames @('experience')
            $attribution['ports']['experience']['null_cost_events'] = 3
            $completeness = script:New-Completeness

            { Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness } | Should -Not -Throw

            $result = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
            $result | Should -Match '3 cost event\(s\) had unknown models not present in `cost-rate-table\.json`'
            $result | Should -Not -Match 'models missing from the rate table:'
        }
    }
}

Describe 'Build-CostPatternTable suppression (issue #489 s1)' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-pattern-renderer.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        # Local copy of the renderer's canonical port order (issue #489 s1 fixture
        # scope). Each Describe block in this file owns its own fixture helpers
        # rather than sharing state with sibling Describe blocks (existing
        # file convention — see New-YamlAttribution vs New-MinimalAttribution).
        $script:SuppressionPortOrder = @(
            'experience', 'design', 'plan', 'orchestration',
            'implement-code', 'implement-test', 'implement-refactor', 'implement-docs',
            'review', 'process-review'
        )

        function script:New-SuppressionActivePortBucket {
            return @{
                tokens               = @{ input = 100; output = 50; cache_creation = 10; cache_read = 20 }
                dispatch_count       = 1
                cost_estimate_usd    = 0.01
                cache_read_hit_ratio = 0.2
                mixed_regime         = $false
            }
        }

        function script:New-SuppressionZeroPortBucket {
            return @{
                tokens               = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                dispatch_count       = 0
                cost_estimate_usd    = 0.0
                cache_read_hit_ratio = 0.0
                mixed_regime         = $false
            }
        }

        function script:New-SuppressionAttribution {
            <#
            .SYNOPSIS
                Every canonical port is present (in-attribution) and active by
                default; -PortOverrides replaces specific port buckets so a test
                can isolate exactly the ports it wants to exercise without the
                other nine canonical ports also rendering as suppressible zero
                rows and polluting the omission count.
            #>
            param([hashtable]$PortOverrides = @{})

            $ports = @{}
            foreach ($p in $script:SuppressionPortOrder) {
                $ports[$p] = if ($PortOverrides.ContainsKey($p)) { $PortOverrides[$p] } else { script:New-SuppressionActivePortBucket }
            }
            return @{
                ports                 = $ports
                orchestrator_overhead = @{
                    tokens               = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                    cost_estimate_usd    = 0.0
                    cache_read_hit_ratio = 0.0
                }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{
                    tokens            = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                    cost_estimate_usd = 0.0
                }
            }
        }

        function script:Get-SuppressionRow {
            param(
                [Parameter(Mandatory)][string]$Markdown,
                [Parameter(Mandatory)][string]$PortLabel
            )
            return @($Markdown -split "`n" | Where-Object { $_ -like "| $PortLabel |*" })[0]
        }
    }

    Context 'suppression-fires' {
        It 'omits a fully-zero-activity port and emits the singular omission line for exactly one suppressed row' {
            $attribution = script:New-SuppressionAttribution -PortOverrides @{ design = (script:New-SuppressionZeroPortBucket) }

            $result = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags @()

            script:Get-SuppressionRow -Markdown $result -PortLabel 'design' | Should -BeNullOrEmpty
            $result | Should -Match ([regex]::Escape("`n`n1 port had zero dispatches, zero attributed cost, and zero token activity, and is omitted from this table."))
        }

        It 'emits the plural omission line when more than one row is suppressed' {
            $attribution = script:New-SuppressionAttribution -PortOverrides @{
                design = (script:New-SuppressionZeroPortBucket)
                plan   = (script:New-SuppressionZeroPortBucket)
            }

            $result = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags @()

            script:Get-SuppressionRow -Markdown $result -PortLabel 'design' | Should -BeNullOrEmpty
            script:Get-SuppressionRow -Markdown $result -PortLabel 'plan' | Should -BeNullOrEmpty
            $result | Should -Match ([regex]::Escape("`n`n2 ports had zero dispatches, zero attributed cost, and zero token activity, and are omitted from this table."))
        }
    }

    Context 'suppression-no-op' {
        It 'keeps a port visible when it carries any non-zero signal' {
            $partialBucket = script:New-SuppressionZeroPortBucket
            $partialBucket['tokens']['output'] = 5
            $attribution = script:New-SuppressionAttribution -PortOverrides @{ design = $partialBucket }

            $result = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags @()

            script:Get-SuppressionRow -Markdown $result -PortLabel 'design' | Should -Not -BeNullOrEmpty
            $result | Should -Not -Match 'omitted from this table'
        }
    }

    Context 'cache-read-active-retained' {
        It 'keeps a zero-dispatch, zero-cost port visible when cache_read tokens are nonzero' {
            $cacheOnlyBucket = script:New-SuppressionZeroPortBucket
            $cacheOnlyBucket['tokens']['cache_read'] = 40
            $attribution = script:New-SuppressionAttribution -PortOverrides @{ design = $cacheOnlyBucket }

            $result = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags @()

            script:Get-SuppressionRow -Markdown $result -PortLabel 'design' | Should -Not -BeNullOrEmpty
            $result | Should -Not -Match 'omitted from this table'
        }
    }

    Context 'anomaly-flagged-zero-row-retained' {
        It 'keeps a fully-zero-activity port visible when it carries an anomaly flag' {
            $attribution = script:New-SuppressionAttribution -PortOverrides @{ design = (script:New-SuppressionZeroPortBucket) }
            $flags = @(@{ metric = 'dispatches.per_port[design]'; port = 'design'; direction = 'shrink'; confidence = 'medium' })

            $result = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags $flags

            script:Get-SuppressionRow -Markdown $result -PortLabel 'design' | Should -Not -BeNullOrEmpty
            $result | Should -Not -Match 'omitted from this table'
        }
    }

    Context 'blank-metric-anomaly-does-not-block-suppression (C14)' {
        It 'suppresses a zero-activity port whose only anomaly flag has a null metric' {
            $attribution = script:New-SuppressionAttribution -PortOverrides @{ design = (script:New-SuppressionZeroPortBucket) }
            $flags = @(@{ metric = $null; port = 'design'; direction = 'shrink'; confidence = 'medium' })

            $result = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags $flags

            script:Get-SuppressionRow -Markdown $result -PortLabel 'design' | Should -BeNullOrEmpty
            $result | Should -Match 'omitted from this table'
        }

        It 'suppresses a zero-activity port whose only anomaly flag has a blank metric' {
            $attribution = script:New-SuppressionAttribution -PortOverrides @{ design = (script:New-SuppressionZeroPortBucket) }
            $flags = @(@{ metric = ''; port = 'design'; direction = 'shrink'; confidence = 'medium' })

            $result = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags $flags

            script:Get-SuppressionRow -Markdown $result -PortLabel 'design' | Should -BeNullOrEmpty
            $result | Should -Match 'omitted from this table'
        }
    }

    Context 'in-attribution-YAML-retention' {
        It 'keeps a suppressed in-attribution port present in Format-CostPatternYaml output (machine block is render-layer-independent)' {
            $attribution = script:New-SuppressionAttribution -PortOverrides @{ design = (script:New-SuppressionZeroPortBucket) }
            $completeness = @{ completeness = 'complete'; stop_reason = 'end_turn'; excluded_from_rolling_baseline = $false; exclude_reason = '' }

            $table = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags @()
            $yaml = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness

            script:Get-SuppressionRow -Markdown $table -PortLabel 'design' | Should -BeNullOrEmpty
            $yaml | Should -Match '(?m)^  - name: design$'
        }
    }

    Context 'render-twice-identical' {
        It 'produces byte-identical output across two calls against the same fixture (AC4 re-run idempotency)' {
            $attribution = script:New-SuppressionAttribution -PortOverrides @{
                design = (script:New-SuppressionZeroPortBucket)
                plan   = (script:New-SuppressionZeroPortBucket)
            }

            $first = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags @()
            $second = script:Build-CostPatternTable -Attribution $attribution -AnomalyFlags @()

            $second | Should -BeExactly $first
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

    It 'emits capture_point, session_id, head_ref as additive top-level scalars before the ports: block (issue #824 s2)' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness -Completeness 'partial' -Excluded $false
        $completeness['capture_point'] = 'pr-creation-mid-session'
        $result = Format-CostPatternYaml `
            -Attribution $attribution `
            -Completeness $completeness `
            -Pr 824 `
            -Branch 'feature/issue-824-baseline-eligibility' `
            -SessionId 'session-abc-123' `
            -HeadRef 'feature/issue-824-baseline-eligibility'

        $result | Should -Match '(?m)^capture_point: pr-creation-mid-session$'
        $result | Should -Match '(?m)^session_id: session-abc-123$'
        $result | Should -Match '(?m)^head_ref: feature/issue-824-baseline-eligibility$'

        $capturePos = $result.IndexOf('capture_point:')
        $sessionPos = $result.IndexOf('session_id:')
        $headRefPos = $result.IndexOf('head_ref:')
        $portsPos   = $result.IndexOf("`nports:")

        $capturePos | Should -BeLessThan $portsPos
        $sessionPos | Should -BeLessThan $portsPos
        $headRefPos | Should -BeLessThan $portsPos
    }

    It 'defaults capture_point to n/a when the completeness hashtable does not carry it' {
        $attribution = script:New-YamlAttribution
        $completeness = script:New-YamlCompleteness
        $result = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness
        $result | Should -Match '(?m)^capture_point: n/a$'
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

Describe 'Format-CostRendererSanitizedModelString (issue #487 s3)' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-pattern-renderer.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }
    }

    It 'truncates a 200-character model string to 128 characters without severing a comment-marker replacement (truncate-then-neutralize ordering, plan finding M13)' {
        # Marker straddles the 128-char cut: 127 'a' chars (indices 0-126) + '-->' + 70 'b' chars.
        # Substring(0,128) keeps indices 0-127: all 127 'a's plus only the first
        # character ('-') of the marker — the marker itself never survives intact
        # into the neutralization pass.
        $raw = ('a' * 127) + '-->' + ('b' * 70)
        $raw.Length | Should -Be 200

        $correct = script:Format-CostRendererSanitizedModelString -Model $raw

        # Correct (truncate-first) behavior: length capped at 128, and no raw or
        # partially-neutralized marker text appears — the neutralization pass
        # never fired because only a lone '-' survived truncation.
        $correct.Length | Should -Be 128
        $correct | Should -Not -Match '-->'
        $correct | Should -Not -Match '\(comment-close'

        # Contrast with the WRONG order (neutralize-then-truncate) to prove why
        # ordering matters: neutralizing the full 200-char string first replaces
        # the complete marker with the 15-char '(comment-close)' placeholder
        # (127 'a's + 15-char placeholder + 70 'b's = 212 chars); THEN truncating
        # to 128 chars cuts mid-placeholder, leaving a dangling partial-replacement
        # artifact right at the boundary.
        $wrongOrderNeutralized = $raw -replace '[\x00-\x1F\x7F]', ' ' -replace ',', ' ' -replace '<!--', '(comment-open)' -replace '-->', '(comment-close)'
        $wrongOrderTruncated = $wrongOrderNeutralized.Substring(0, 128)
        $wrongOrderTruncated | Should -Match '\($'
        $wrongOrderTruncated | Should -Not -Match '\(comment-close\)'
        $wrongOrderTruncated | Should -Not -Be $correct
    }

    It 'backs the truncation cut up by one when a naive 128-char cut would bisect a UTF-16 surrogate pair (plan finding M7)' {
        # 127 'a' chars (indices 0-126) + an astral-plane emoji (a 2-code-unit
        # surrogate pair at indices 127-128) + 70 'b' chars. A naive
        # Substring(0, 128) keeps only the high surrogate at index 127 and
        # drops its low-surrogate partner at index 128, leaving an unpaired
        # surrogate at the very end of the truncated string.
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $raw = ('a' * 127) + $emoji + ('b' * 70)

        # Prove the naive cut is genuinely dangerous before asserting the fix.
        [char]::IsHighSurrogate($raw[127]) | Should -BeTrue
        $naiveCut = $raw.Substring(0, 128)
        [char]::IsHighSurrogate($naiveCut[$naiveCut.Length - 1]) | Should -BeTrue
        [char]::IsLowSurrogate($naiveCut[$naiveCut.Length - 1]) | Should -BeFalse

        $result = script:Format-CostRendererSanitizedModelString -Model $raw

        # The fix backs the cut up to 127, dropping the whole emoji rather
        # than bisecting it — no unpaired surrogate survives.
        $result.Length | Should -Be 127
        $result | Should -Be ('a' * 127)
        for ($i = 0; $i -lt $result.Length; $i++) {
            if ([char]::IsHighSurrogate($result[$i])) {
                $i + 1 | Should -BeLessThan $result.Length
                [char]::IsLowSurrogate($result[$i + 1]) | Should -BeTrue
            }
            if ([char]::IsLowSurrogate($result[$i])) {
                $i | Should -BeGreaterThan 0
                [char]::IsHighSurrogate($result[$i - 1]) | Should -BeTrue
            }
        }
    }
}

Describe 'unknown_models cap, overflow suffix, and round-trip (issue #487 s3)' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-pattern-renderer.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }
        $script:RollingHistoryLibPath = Join-Path $PSScriptRoot '../lib/cost-rolling-history.ps1'
        if (Test-Path $script:RollingHistoryLibPath) {
            . $script:RollingHistoryLibPath
        }

        function script:New-Cap5Attribution {
            return @{
                ports                 = @{
                    experience = @{
                        tokens               = @{ input = 1234; output = 567; cache_creation = 89; cache_read = 456 }
                        dispatch_count       = 2
                        cost_estimate_usd    = 0.0123
                        cache_read_hit_ratio = 0.617
                        mixed_regime         = $false
                        null_cost_events     = 0
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

        function script:New-Cap5Completeness {
            return @{
                completeness                   = 'complete'
                stop_reason                    = 'end_turn'
                excluded_from_rolling_baseline = $false
                exclude_reason                 = ''
            }
        }
    }

    It '11 distinct unknown models: Note renders "+1 more", YAML array carries exactly 10 entries with no overflow suffix (plan finding M12)' {
        $unknownModels = @(1..11 | ForEach-Object { "claude/model-$_" }) | Sort-Object

        $attribution = script:New-Cap5Attribution
        $attribution['ports']['experience']['null_cost_events'] = 11
        $attribution['unknown_models'] = $unknownModels
        $attribution['null_cost_events_by_reason'] = @{ unknown_key = 11; rate_unavailable = 0; empty_model = 0 }
        $completeness = script:New-Cap5Completeness

        $note = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
        $yaml = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness

        $note | Should -Match '\+1 more'

        $yaml -match '(?m)^unknown_models: (\[.*\])$' | Should -BeTrue
        $yamlArrayText = $Matches[1]
        $yamlModels = script:ConvertFrom-CostPatternYamlArray -Value $yamlArrayText
        $yamlModels.Count | Should -Be 10
        $yaml | Should -Not -Match '\+1 more'
    }

    It 'duplicate and sanitizer-colliding raw unknown_models below the 10 cap render no "+N more" suffix (issue #487 F4)' {
        # 12 raw strings that collapse to only 4 unique sanitized identifiers:
        # repeated raw strings for the same model (repeated events), plus a
        # comma-vs-control-char pair that sanitizes to the identical string.
        # The true unique-and-sanitized count (4) is well under the 10-entry
        # cap, so no overflow suffix should ever appear. Before the fix, the
        # overflow count was raw-array-length minus sanitized-count (12 - 4 =
        # 8), producing a phantom "+8 more" even though every model is shown.
        $unknownModels = @(
            'claude/model-a', 'claude/model-a', 'claude/model-a',
            'claude/model-b', 'claude/model-b',
            'claude/model-c,x', "claude/model-c`u{0001}x",
            'claude/model-d', 'claude/model-d', 'claude/model-d', 'claude/model-d'
        )

        $attribution = script:New-Cap5Attribution
        $attribution['ports']['experience']['null_cost_events'] = $unknownModels.Count
        $attribution['unknown_models'] = $unknownModels
        $attribution['null_cost_events_by_reason'] = @{ unknown_key = $unknownModels.Count; rate_unavailable = 0; empty_model = 0 }
        $completeness = script:New-Cap5Completeness

        $note = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
        $yaml = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness

        $note | Should -Not -Match '\+\d+ more'
        $yaml | Should -Not -Match '\+\d+ more'
    }

    It 'duplicate raw malformed_rate_models below the 10 cap render no "+N more" suffix (issue #487 F4, mirrored block)' {
        # Same phantom-overflow scenario as the unknown_key test above, but
        # exercising the mirrored malformed-rate-models clause, which has its
        # own independent overflow computation.
        $malformedModels = @('claude/bad-model', 'claude/bad-model', 'claude/bad-model')

        $attribution = script:New-Cap5Attribution
        $attribution['ports']['experience']['null_cost_events'] = $malformedModels.Count
        $attribution['unknown_models'] = @()
        $attribution['malformed_rate_models'] = $malformedModels
        $attribution['null_cost_events_by_reason'] = @{ unknown_key = 0; rate_unavailable = $malformedModels.Count; rate_unavailable_malformed = $malformedModels.Count; empty_model = 0 }
        $completeness = script:New-Cap5Completeness

        $note = Format-CostPatternMarkdown -Attribution $attribution -Completeness $completeness
        $yaml = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness

        $note | Should -Not -Match '\+\d+ more'
        $yaml | Should -Not -Match '\+\d+ more'
    }

    It 'emits malformed_rate_models and rate_unavailable_malformed in the YAML block (issue #487 CE-F2)' {
        $attribution = script:New-Cap5Attribution
        $attribution['ports']['experience']['null_cost_events'] = 1
        $attribution['unknown_models'] = @()
        $attribution['malformed_rate_models'] = @('claude/claude-fatfingered-model')
        $attribution['null_cost_events_by_reason'] = @{ unknown_key = 0; rate_unavailable = 1; rate_unavailable_malformed = 1; empty_model = 0 }
        $completeness = script:New-Cap5Completeness

        $yaml = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness

        $yaml -match '(?m)^malformed_rate_models: (\[.*\])$' | Should -BeTrue
        $yamlModels = script:ConvertFrom-CostPatternYamlArray -Value $Matches[1]
        $yamlModels | Should -Be @('claude/claude-fatfingered-model')

        $yaml | Should -Match '(?m)^  rate_unavailable_malformed: 1$'
        $yaml | Should -Match '(?m)^  rate_unavailable: 1$'
    }

    It 'dedups post-sanitization duplicates and re-sorts the result (plan findings M4/M9)' {
        # 'claude/a,b' and "claude/a`x01b" are distinct raw strings, but the
        # sanitizer maps both the comma and the control char to a single
        # space, so they collapse to the identical sanitized output
        # 'claude/a b'. Deduping on the raw string (pre-sanitization, the old
        # behavior) would keep both as visible duplicates; deduping
        # post-sanitization collapses them to one entry. The raw list is also
        # intentionally out of sorted order to prove the re-sort runs after
        # dedup, not before.
        $rawUnknownModels = @('claude/z-model', "claude/a`u{0001}b", 'claude/a,b')

        $deduped = script:Get-CostRendererSanitizedUnknownModels -UnknownModels $rawUnknownModels

        $deduped.Count | Should -Be 2
        $deduped | Should -Be @('claude/a b', 'claude/z-model')
    }

    It 'round-trips a rendered block carrying hostile-but-sanitized unknown_models, keeping ports: intact (plan findings M2/M16)' {
        $hostileModels = @(
            "claude/evil`nsession_id: hijacked",
            'claude/evil,injected-model',
            'claude/evil"quoted',
            'claude/evil<!--forged',
            'claude/evil-->forged'
        ) | Sort-Object

        $attribution = script:New-Cap5Attribution
        $attribution['ports']['experience']['null_cost_events'] = 5
        $attribution['unknown_models'] = $hostileModels
        $attribution['null_cost_events_by_reason'] = @{ unknown_key = 5; rate_unavailable = 0; empty_model = 0 }
        $completeness = script:New-Cap5Completeness

        $yaml = Format-CostPatternYaml -Attribution $attribution -Completeness $completeness -Pr 487 -Branch 'feature/issue-487-rate-table-refresh'

        # Format-CostPatternYaml already returns the complete <!-- cost-pattern-data ... --> block.
        $extracted = script:Get-CostPatternDataFromComment -Body $yaml
        $extracted | Should -Not -BeNullOrEmpty

        $parsed = script:ConvertFrom-CostPatternYaml -Yaml $extracted
        $parsed | Should -Not -BeNullOrEmpty
        $parsed['ports'] | Should -Not -BeNullOrEmpty
        $parsed['ports'].ContainsKey('experience') | Should -Be $true
        $parsed['ports']['experience']['name'] | Should -Be 'experience'
        $parsed['ports']['experience']['dispatch_count'] | Should -Be 2
    }
}

Describe 'cost-pattern-data schema documentation' {
    It 'documents the post-#488 additive YAML fields' {
        $schemaPath = Join-Path $PSScriptRoot '../lib/cost-pattern-data-schema.md'
        $schemaPath | Should -Exist
        $schema = Get-Content -LiteralPath $schemaPath -Raw

        foreach ($field in @('provider_support', 'coverage', 'install_status', 'providers', 'unmapped_session_count', 'phase_scope', 'capture_point', 'session_id', 'head_ref', 'unknown_models', 'null_cost_events_by_reason', 'malformed_rate_models', 'rate_unavailable_malformed')) {
            $schema | Should -Match "``$field``"
        }
    }
}
