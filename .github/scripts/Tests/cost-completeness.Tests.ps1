#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-SessionCompleteness' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-completeness.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        # Helper: build a minimal assistant event with the given stop_reason
        function script:New-AssistantEvent {
            param(
                [string]$Uuid = [System.Guid]::NewGuid().ToString(),
                [string]$StopReason = $null,
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
                gitBranch = 'feature/test-branch'
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
    }
}

Describe 'Resolve-CostDataPreservation' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-completeness.ps1'
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
    }

    It '(complete, any prior) -> use current' {
        $current = script:New-CompletenessResult -Completeness 'complete'
        $prior   = script:New-CompletenessResult -Completeness 'complete'
        $result  = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
    }

    It '(partial, prior=complete) -> use_prior: true, notice set' {
        $current = script:New-CompletenessResult -Completeness 'partial' -StopReason 'max_tokens' -Timestamp '2026-01-02T00:00:00Z'
        $prior   = script:New-CompletenessResult -Completeness 'complete' -Timestamp '2026-01-01T00:00:00Z'
        $result  = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $true
        $result.notice | Should -Not -BeNullOrEmpty
    }

    It '(unknown, prior=complete) -> use_prior: true, notice set' {
        $current = script:New-CompletenessResult -Completeness 'unknown' -StopReason $null -Timestamp '2026-01-02T00:00:00Z'
        $prior   = script:New-CompletenessResult -Completeness 'complete' -Timestamp '2026-01-01T00:00:00Z'
        $result  = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $true
        $result.notice | Should -Not -BeNullOrEmpty
    }

    It '(partial, prior=partial) -> use current (most recent wins)' {
        $current = script:New-CompletenessResult -Completeness 'partial' -StopReason 'max_tokens' -Timestamp '2026-01-02T00:00:00Z'
        $prior   = script:New-CompletenessResult -Completeness 'partial' -StopReason 'pause_turn' -Timestamp '2026-01-01T00:00:00Z'
        $result  = Resolve-CostDataPreservation -Current $current -Prior $prior
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
    }

    It '(partial, prior=none) -> use current' {
        $current = script:New-CompletenessResult -Completeness 'partial' -StopReason 'max_tokens'
        $result  = Resolve-CostDataPreservation -Current $current
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
    }

    It '(complete, prior=none) -> use current' {
        $current = script:New-CompletenessResult -Completeness 'complete'
        $result  = Resolve-CostDataPreservation -Current $current
        $result.use_prior | Should -Be $false
        $result.notice | Should -BeNullOrEmpty
    }

    It 'notice text mentions prior_run_timestamp when use_prior is true' {
        $priorTimestamp = '2026-01-01T12:00:00Z'
        $current = script:New-CompletenessResult -Completeness 'partial' -StopReason 'max_tokens' -Timestamp '2026-01-02T00:00:00Z'
        $prior   = script:New-CompletenessResult -Completeness 'complete' -Timestamp $priorTimestamp
        $result  = Resolve-CostDataPreservation -Current $current -Prior $prior
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
}
