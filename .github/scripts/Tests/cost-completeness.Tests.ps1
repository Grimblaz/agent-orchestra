#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-SessionCompleteness' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-completeness.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        # Helper: build a minimal assistant event with the given stop_reason
        function script:New-AssistantEvent {
            param(
                [string]$Uuid = [System.Guid]::NewGuid().ToString(),
                [string]$StopReason = $null,
                [string]$Branch = 'feature/test-branch',
                [object[]]$Content = @()
            )
            $msg = @{
                usage   = @{ input_tokens = 10; output_tokens = 5 }
                content = $Content
            }
            if ($null -ne $StopReason) {
                $msg['stop_reason'] = $StopReason
            }
            return @{
                type      = 'assistant'
                uuid      = $Uuid
                timestamp = '2026-01-01T00:00:00Z'
                cwd       = '/c/test/repo'
                gitBranch = $Branch
                message   = $msg
            }
        }

        # Helper: build a tool_use content item
        function script:New-ToolUseContent {
            param([string]$Id = [System.Guid]::NewGuid().ToString(), [string]$Name = 'SomeTool')
            return @{ type = 'tool_use'; id = $Id; name = $Name }
        }

        # Helper: build a tool_result content item (for user events)
        function script:New-ToolResultContent {
            param([string]$ToolUseId)
            return @{ type = 'tool_result'; tool_use_id = $ToolUseId; content = 'result' }
        }

        # Helper: build a user event with tool_result
        function script:New-UserEvent {
            param([object[]]$Content = @())
            return @{
                type    = 'user'
                uuid    = [System.Guid]::NewGuid().ToString()
                content = $Content
            }
        }
    }

    Context 'stop_reason classification' {
        It 'end_turn -> complete' {
            $events = @(script:New-AssistantEvent -StopReason 'end_turn')
            $result = Get-SessionCompleteness -Events $events
            $result.completeness | Should -Be 'complete'
            $result.stop_reason | Should -Be 'end_turn'
        }

        It 'tool_use with matching tool_result -> complete' {
            $toolId = [System.Guid]::NewGuid().ToString()
            $toolUseContent = script:New-ToolUseContent -Id $toolId
            $assistantEvent = script:New-AssistantEvent -StopReason 'tool_use' -Content @($toolUseContent)
            $userEvent = script:New-UserEvent -Content @(script:New-ToolResultContent -ToolUseId $toolId)
            $events = @($assistantEvent, $userEvent)
            $result = Get-SessionCompleteness -Events $events
            $result.completeness | Should -Be 'complete'
            $result.stop_reason | Should -Be 'tool_use'
        }

        It 'tool_use without matching tool_result -> partial (dangling)' {
            $toolId = [System.Guid]::NewGuid().ToString()
            $toolUseContent = script:New-ToolUseContent -Id $toolId
            $assistantEvent = script:New-AssistantEvent -StopReason 'tool_use' -Content @($toolUseContent)
            # No user event with tool_result
            $events = @($assistantEvent)
            $result = Get-SessionCompleteness -Events $events
            $result.completeness | Should -Be 'partial'
            $result.stop_reason | Should -Be 'tool_use'
        }

        It 'pause_turn -> partial' {
            $events = @(script:New-AssistantEvent -StopReason 'pause_turn')
            $result = Get-SessionCompleteness -Events $events
            $result.completeness | Should -Be 'partial'
            $result.stop_reason | Should -Be 'pause_turn'
        }

        It 'max_tokens -> partial' {
            $events = @(script:New-AssistantEvent -StopReason 'max_tokens')
            $result = Get-SessionCompleteness -Events $events
            $result.completeness | Should -Be 'partial'
            $result.stop_reason | Should -Be 'max_tokens'
        }

        It 'null stop_reason -> partial' {
            # Event exists but stop_reason is null/absent
            $events = @(script:New-AssistantEvent)
            $result = Get-SessionCompleteness -Events $events
            $result.completeness | Should -Be 'partial'
            $result.stop_reason | Should -BeNullOrEmpty
        }

        It 'refusal -> partial' {
            $events = @(script:New-AssistantEvent -StopReason 'refusal')
            $result = Get-SessionCompleteness -Events $events
            $result.completeness | Should -Be 'partial'
            $result.stop_reason | Should -Be 'refusal'
        }
    }

    Context 'empty / missing events' {
        It 'empty events array -> unknown' {
            $result = Get-SessionCompleteness -Events @()
            $result.completeness | Should -Be 'unknown'
            $result.stop_reason | Should -BeNullOrEmpty
        }

        It 'no assistant events -> unknown' {
            $events = @(
                @{ type = 'user'; uuid = [System.Guid]::NewGuid().ToString(); content = 'hello' }
                @{ type = 'system'; uuid = [System.Guid]::NewGuid().ToString() }
            )
            $result = Get-SessionCompleteness -Events $events
            $result.completeness | Should -Be 'unknown'
            $result.stop_reason | Should -BeNullOrEmpty
        }
    }

    Context 'excluded_from_rolling_baseline' {
        It 'partial session -> excluded_from_rolling_baseline: true' {
            $events = @(script:New-AssistantEvent -StopReason 'max_tokens')
            $result = Get-SessionCompleteness -Events $events
            $result.excluded_from_rolling_baseline | Should -Be $true
        }

        It 'unknown session -> excluded_from_rolling_baseline: true' {
            $result = Get-SessionCompleteness -Events @()
            $result.excluded_from_rolling_baseline | Should -Be $true
        }

        It 'complete session without ExcludeReason -> excluded_from_rolling_baseline: false' {
            $events = @(script:New-AssistantEvent -StopReason 'end_turn')
            $result = Get-SessionCompleteness -Events $events
            $result.excluded_from_rolling_baseline | Should -Be $false
            $result.exclude_reason | Should -BeNullOrEmpty
        }

        It 'complete session with ExcludeReason -> excluded_from_rolling_baseline: true (outlier-PR)' {
            $events = @(script:New-AssistantEvent -StopReason 'end_turn')
            $result = Get-SessionCompleteness -Events $events -ExcludeReason 'foundational PR #467 — ~10x typical cost'
            $result.excluded_from_rolling_baseline | Should -Be $true
            $result.exclude_reason | Should -Be 'foundational PR #467 — ~10x typical cost'
        }

        It 'complete phase-marker-only session preserves completeness but excludes rolling baseline with reason' {
            $events = @(script:New-AssistantEvent -StopReason 'end_turn' -Branch 'main')
            $result = Get-SessionCompleteness -Events $events -Branch 'feature/issue-529-step-4'
            $result.completeness | Should -Be 'complete'
            $result.excluded_from_rolling_baseline | Should -Be $true
            $result.exclude_reason | Should -Be 'phase-marker-only attribution; rolling-history excluded'
        }

        It 'complete strict-branch session remains eligible for rolling baseline' {
            $events = @(script:New-AssistantEvent -StopReason 'end_turn' -Branch 'feature/issue-529-step-4')
            $result = Get-SessionCompleteness -Events $events -Branch 'feature/issue-529-step-4'
            $result.completeness | Should -Be 'complete'
            $result.excluded_from_rolling_baseline | Should -Be $false
            $result.exclude_reason | Should -BeNullOrEmpty
        }
    }
}

Describe 'Resolve-CostDataPreservation' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-completeness.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        # Helper: build a minimal completeness result hashtable
        function script:New-CompletenessResult {
            param(
                [string]$Completeness = 'complete',
                [string]$StopReason = 'end_turn',
                [string]$Timestamp = '2026-01-01T00:00:00Z'
            )
            return @{
                completeness                   = $Completeness
                stop_reason                    = $StopReason
                excluded_from_rolling_baseline = ($Completeness -ne 'complete')
                exclude_reason                 = $null
                rendered_at                    = $Timestamp
            }
        }

        # Helper: build completeness result WITH token data
        function script:New-CompletenessResultWithTokens {
            param(
                [string]$Completeness = 'complete',
                [string]$StopReason = 'end_turn',
                [string]$Timestamp = '2026-01-01T00:00:00Z',
                [int]$TokenSum = 0
            )
            return @{
                completeness                   = $Completeness
                stop_reason                    = $StopReason
                excluded_from_rolling_baseline = ($Completeness -ne 'complete')
                exclude_reason                 = $null
                rendered_at                    = $Timestamp
            }
        }
    }

    It '(complete, any prior) -> use current' {
        $current = script:New-CompletenessResult -Completeness 'complete'
        $prior = script:New-CompletenessResult -Completeness 'complete'
        $result = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
    }

    It '(partial, prior=complete) -> use_prior: true, notice set' {
        $current = script:New-CompletenessResult -Completeness 'partial' -StopReason 'max_tokens' -Timestamp '2026-01-02T00:00:00Z'
        $prior = script:New-CompletenessResult -Completeness 'complete' -Timestamp '2026-01-01T00:00:00Z'
        $result = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $true
        $result.notice | Should -Not -BeNullOrEmpty
    }

    It '(unknown, prior=complete) -> use_prior: true, notice set' {
        $current = script:New-CompletenessResult -Completeness 'unknown' -StopReason $null -Timestamp '2026-01-02T00:00:00Z'
        $prior = script:New-CompletenessResult -Completeness 'complete' -Timestamp '2026-01-01T00:00:00Z'
        $result = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $true
        $result.notice | Should -Not -BeNullOrEmpty
    }

    It '(partial, prior=partial) -> use current (most recent wins)' {
        $current = script:New-CompletenessResult -Completeness 'partial' -StopReason 'max_tokens' -Timestamp '2026-01-02T00:00:00Z'
        $prior = script:New-CompletenessResult -Completeness 'partial' -StopReason 'pause_turn' -Timestamp '2026-01-01T00:00:00Z'
        $result = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
    }

    It '(partial, prior=none) -> use current' {
        $current = script:New-CompletenessResult -Completeness 'partial' -StopReason 'max_tokens'
        $result = Resolve-CostDataPreservation -Current $current
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
    }

    It '(complete, prior=none) -> use current' {
        $current = script:New-CompletenessResult -Completeness 'complete'
        $result = Resolve-CostDataPreservation -Current $current
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
    }

    It 'notice text mentions prior_run_timestamp when use_prior is true' {
        $priorTimestamp = '2026-01-01T12:00:00Z'
        $current = script:New-CompletenessResult -Completeness 'partial' -StopReason 'max_tokens' -Timestamp '2026-01-02T00:00:00Z'
        $prior = script:New-CompletenessResult -Completeness 'complete' -Timestamp $priorTimestamp
        $result = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $true
        $result.notice | Should -Match $priorTimestamp
    }

    It 'outlier-PR exclusion: complete with ExcludeReason -> excluded_from_rolling_baseline: true with reason (one-time annotation)' {
        $excludeReason = 'foundational PR #467 — ~10x typical cost'
        $current = @{
            completeness                   = 'complete'
            stop_reason                    = 'end_turn'
            excluded_from_rolling_baseline = $true
            exclude_reason                 = $excludeReason
            rendered_at                    = '2026-01-01T00:00:00Z'
        }
        $result = Resolve-CostDataPreservation -Current $current
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
        # The caller is responsible for propagating excluded_from_rolling_baseline;
        # Resolve-CostDataPreservation just signals use_prior=false so the current data wins.
        $current.excluded_from_rolling_baseline | Should -Be $true
        $current.exclude_reason | Should -Be $excludeReason
    }

    Context 'populated-predicate (token-magnitude)' {
        # Non-landing root cause: Code-Conductor posts local render immediately after gh pr create.
        # Local session is in-flight → completeness='partial', tokens>0. CI runs later on ubuntu-latest
        # (no transcript) → completeness='unknown', tokens=0. Without the populated predicate, both are
        # non-complete so Resolve-CostDataPreservation returns use_prior=false → CI zeros overwrite the
        # populated local render. The populated predicate (sum port tokens > 0) fixes this: a populated
        # prior always beats an empty current, regardless of completeness or write order.

        It 'empty-complete current must NOT clobber complete-populated prior' {
            # Cell 2: current=complete tokens=0, prior=complete tokens>0
            # Current code: complete → use_prior=false (complete always wins). Should be true.
            $current = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 0
            $prior = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 1500
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 0 -PriorTokenSum 1500
            $result.use_prior | Should -Be $true
            $result.notice | Should -Not -BeNullOrEmpty
        }

        It 'partial-nonzero current beats complete-zero prior' {
            # Cell 3: current=partial tokens>0, prior=complete tokens=0
            # Current code: partial + prior=complete → use_prior=true (preserve complete). Should be false.
            $current = script:New-CompletenessResultWithTokens -Completeness 'partial' -StopReason 'max_tokens' -TokenSum 800
            $prior = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 0
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 800 -PriorTokenSum 0
            $result.use_prior | Should -Be $false
        }

        It 'empty-unknown current must NOT clobber unknown-populated prior (CI-overwrites-local scenario)' {
            # Cell 5: current=unknown tokens=0, prior=unknown tokens>0
            # This is the dominant non-landing bug: local renders first (unknown, populated),
            # CI renders second (unknown, zeros). Without populated predicate, both-unknown → use_prior=false → CI wins.
            $current = script:New-CompletenessResultWithTokens -Completeness 'unknown' -StopReason $null -TokenSum 0
            $prior = script:New-CompletenessResultWithTokens -Completeness 'unknown' -StopReason $null -TokenSum 1200
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 0 -PriorTokenSum 1200
            $result.use_prior | Should -Be $true
            $result.notice | Should -Match 'populated'
        }

        It 'populated-unknown current beats complete-zero prior' {
            # Cell 6: current=unknown tokens>0, prior=complete tokens=0
            # Current code: unknown + prior=complete → use_prior=true (preserve complete). Should be false.
            $current = script:New-CompletenessResultWithTokens -Completeness 'unknown' -StopReason $null -TokenSum 900
            $prior = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 0
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 900 -PriorTokenSum 0
            $result.use_prior | Should -Be $false
        }
    }

    Context 'populated-predicate — regression guards' {
        It '#760 regression guard: legacy populated prior (null completeness) still preserved when current is empty' {
            # Prior has null completeness (legacy render before completeness field existed).
            # Lines 1741-1746 of call site default null completeness to complete.
            # Even if the predicate sees it as complete, empty current must not clobber populated prior.
            $current = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 0
            $prior = @{
                completeness                   = $null
                stop_reason                    = $null
                excluded_from_rolling_baseline = $false
                exclude_reason                 = $null
                rendered_at                    = '2026-01-01T00:00:00Z'
                token_sum                      = 2000
            }
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 0 -PriorTokenSum 2000
            $result.use_prior | Should -Be $true
            $result.notice | Should -Not -BeNullOrEmpty
        }

        It 'both-empty no-op idempotence: both complete tokens=0 -> use current (no churn)' {
            $current = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 0
            $prior = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 0
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 0 -PriorTokenSum 0
            $result.use_prior | Should -Be $false
        }

        It 'both-populated falls back to completeness: current=complete, prior=complete -> use current' {
            $current = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 1000
            $prior = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 1500
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 1000 -PriorTokenSum 1500
            $result.use_prior | Should -Be $false
        }

        It 'both-populated falls back to completeness: current=partial, prior=complete-populated -> use prior' {
            $current = script:New-CompletenessResultWithTokens -Completeness 'partial' -StopReason 'max_tokens' -TokenSum 600
            $prior = script:New-CompletenessResultWithTokens -Completeness 'complete' -StopReason 'end_turn' -TokenSum 1200
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 600 -PriorTokenSum 1200
            $result.use_prior | Should -Be $true
            $result.notice | Should -Not -BeNullOrEmpty
        }

        It 'synthetic-fallback prior (completeness=complete, no ports) + empty current -> use_prior=true via completeness fallback' {
            # Exercises the path where priorCostData is the frame-credit-ledger synthetic fallback
            # (@{ completeness = 'complete' }, no ports key) and both token sums are 0.
            # Both-empty falls through to completeness logic: prior=complete beats current=unknown.
            $current = script:New-CompletenessResultWithTokens -Completeness 'unknown' -TokenSum 0
            $prior = @{ completeness = 'complete' }  # synthetic fallback shape -- no ports, no rendered_at
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 0 -PriorTokenSum 0
            $result.use_prior | Should -Be $true
        }

        It 'long-boundary: PriorTokenSum > int32.max does not throw and populated prior wins over empty current' {
            # Regression for CR1 (int->long fix): a token sum exceeding Int32.MaxValue must not throw
            # ParameterBindingArgumentTransformationException.
            $current = script:New-CompletenessResultWithTokens -Completeness 'unknown' -TokenSum 0
            $prior = script:New-CompletenessResultWithTokens -Completeness 'unknown' -TokenSum 0
            # Invoke in the current scope so $result is populated after the throw-check.
            { Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 0 -PriorTokenSum 3000000000 } | Should -Not -Throw
            $result = Resolve-CostDataPreservation -Current $current -Prior $prior -CurrentTokenSum 0 -PriorTokenSum 3000000000
            $result.use_prior | Should -Be $true  # populated prior (>0) beats empty current
            $result.notice | Should -Match 'populated'
        }
    }
}
