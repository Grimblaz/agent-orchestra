#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Copilot cost walker helpers' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-walker-copilot.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }
    }

    Context 'branch slug derivation' {
        It 'normalizes branch name <Branch> to <Expected>' -TestCases @(
            @{ Branch = 'Feature/Issue-488-Copilot-Cost'; Expected = 'feature-issue-488-copilot-cost' }
            @{ Branch = 'bugfix/Quotes:And*Stars '; Expected = 'bugfix-quotes-and-stars' }
            @{ Branch = "release/Issue-488`t"; Expected = 'release-issue-488' }
        ) {
            param([string]$Branch, [string]$Expected)

            Get-CopilotBranchSlug -Branch $Branch | Should -Be $Expected
        }
    }

    Context 'outfile template resolution' {
        It 'resolves helper-owned VS variables and environment variables to a literal path' {
            $envName = "COPILOT_OTEL_TEST_$([System.Guid]::NewGuid().ToString('N'))"
            $previousValue = [System.Environment]::GetEnvironmentVariable($envName, 'Process')

            try {
                [System.Environment]::SetEnvironmentVariable($envName, 'capture', 'Process')
                $template = '${userHome}/.copilot-otel/${workspaceFolderBasename}/${env:' + $envName + '}.jsonl'

                $result = Resolve-CostCopilotOutfileTemplate `
                    -Template $template `
                    -WorkspaceRoot 'C:\Users\Micah\Code 2\copilot-orchestra' `
                    -UserHome 'C:\Users\Micah'

                $result.ResolvedPath.Replace('\', '/') | Should -Be 'C:/Users/Micah/.copilot-otel/copilot-orchestra/capture.jsonl'
                $result.Substitutions | Should -Contain 'userHome'
                $result.Substitutions | Should -Contain 'workspaceFolderBasename'
                $result.Substitutions | Should -Contain "env:$envName"
            }
            finally {
                [System.Environment]::SetEnvironmentVariable($envName, $previousValue, 'Process')
            }
        }

        It 'records that github.copilot.chat.otel.outfile templates require helper resolution before writing settings' {
            $result = Resolve-CostCopilotOutfileTemplate `
                -Template '${userHome}/.copilot-otel/${workspaceFolderBasename}/copilot.jsonl' `
                -WorkspaceRoot 'C:\Users\Micah\Code 2\copilot-orchestra' `
                -UserHome 'C:\Users\Micah'

            $result.TemplateSupportedByVSCode | Should -BeFalse
            $result.Diagnostics | Where-Object {
                $_ -match 'github\.copilot\.chat\.otel\.outfile' -and $_ -match 'literal'
            } | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-CostCopilotWalk' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-walker-copilot.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures\cost-walker-copilot'
        $script:FixtureJsonl = Join-Path $script:FixtureDir 'copilot-chat.jsonl'
        $script:SyntheticReflog = Join-Path $script:FixtureDir 'synthetic-reflog.txt'
        $script:RepoRoot = 'C:\Users\Micah\Code 2\copilot-orchestra'
        $script:TargetBranch = 'feature/issue-488-copilot-cost-collection'
        $script:WorkspaceBasename = 'copilot-orchestra'

        function script:Get-ObjectValue {
            param(
                [Parameter(Mandatory)][object]$Object,
                [Parameter(Mandatory)][string]$Name
            )

            if ($Object -is [hashtable]) { return $Object[$Name] }
            return $Object.$Name
        }

        function script:Get-NormalizedUsage {
            param([Parameter(Mandatory)][object]$Record)

            $message = script:Get-ObjectValue -Object $Record -Name 'message'
            return script:Get-ObjectValue -Object $message -Name 'usage'
        }

        function script:Write-TestJsonl {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][object[]]$Records
            )

            $dir = Split-Path -Parent $Path
            if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            $Records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 } | Set-Content -Path $Path -Encoding utf8NoBOM
        }

        function script:New-CopilotOtelRecord {
            param(
                [Parameter(Mandatory)][string]$SessionId,
                [Parameter(Mandatory)][string]$Timestamp,
                [string]$OtelRecordName = 'gen_ai.client.inference.operation.details',
                [string]$AgentName = 'GitHub Copilot Chat',
                [string]$Model = 'claude-sonnet-4.6',
                [Nullable[int]]$InputTokens = 20,
                [Nullable[int]]$OutputTokens = 7
            )

            $epochSeconds = [System.DateTimeOffset]::Parse($Timestamp).ToUnixTimeSeconds()
            $attributes = @{
                'event.name'           = $OtelRecordName
                'session.id'           = $SessionId
                'gen_ai.agent.name'    = $AgentName
                'gen_ai.request.model' = $Model
                'gen_ai.response.model' = $Model
            }

            if ($null -ne $InputTokens) { $attributes['gen_ai.usage.input_tokens'] = [int]$InputTokens }
            if ($null -ne $OutputTokens) { $attributes['gen_ai.usage.output_tokens'] = [int]$OutputTokens }

            return @{
                hrTime               = @($epochSeconds, 0)
                hrTimeObserved       = @($epochSeconds, 0)
                resource             = @{
                    _rawAttributes = @(
                        @('service.name', 'copilot-chat'),
                        @('service.version', '0.47.0'),
                        @('session.id', $SessionId)
                    )
                }
                instrumentationScope = @{ name = 'copilot-chat'; version = '0.47.0' }
                attributes           = $attributes
                _body                = $OtelRecordName
            }
        }

        function script:Invoke-CopilotWalkForRecords {
            param(
                [Parameter(Mandatory)][object[]]$Records,
                [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReflogLines,
                [string]$Branch = $script:TargetBranch,
                [string]$WorkspaceBasename = $script:WorkspaceBasename,
                [ref]$Warnings
            )

            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-copilot-test-$([System.Guid]::NewGuid())"
            $otelPath = Join-Path $tmp 'copilot-chat.jsonl'
            script:Write-TestJsonl -Path $otelPath -Records $Records

            try {
                Mock Get-CostCopilotReflog { return $ReflogLines } -ParameterFilter { $RepoRoot -eq $script:RepoRoot }

                $result = @(Invoke-CostCopilotWalk `
                    -Branch $Branch `
                    -RepoRoot $script:RepoRoot `
                    -OtelJsonlPath $otelPath `
                    -WorkspaceFolderBasename $WorkspaceBasename `
                    -WarningVariable localWarnings)

                if ($null -ne $Warnings) {
                    $Warnings.Value = @($localWarnings)
                }

                return $result
            }
            finally {
                if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
            }
        }
    }

    Context 'sanitized fixture contract' {
        It 'joins the S1 OTel fixture to the synthetic reflog and emits a normalized Copilot cost event' {
            $reflogLines = Get-Content -Path $script:SyntheticReflog -Encoding utf8
            Mock Get-CostCopilotReflog { return $reflogLines } -ParameterFilter { $RepoRoot -eq $script:RepoRoot }

            $walkOutput = @(Invoke-CostCopilotWalk `
                -Branch $script:TargetBranch `
                -RepoRoot $script:RepoRoot `
                -OtelJsonlPath $script:FixtureJsonl `
                -WorkspaceFolderBasename $script:WorkspaceBasename)

            $walkOutput.Count | Should -Be 1
            $costRecord = $walkOutput[0]
            script:Get-ObjectValue -Object $costRecord -Name 'type' | Should -Be 'assistant'
            script:Get-ObjectValue -Object $costRecord -Name 'provider' | Should -Be 'copilot'
            script:Get-ObjectValue -Object $costRecord -Name 'agentType' | Should -Be 'GitHub Copilot Chat'
            script:Get-ObjectValue -Object $costRecord -Name 'cwd' | Should -Be 'copilot-otel://copilot-orchestra'
            script:Get-ObjectValue -Object $costRecord -Name 'gitBranch' | Should -Be $script:TargetBranch
            script:Get-ObjectValue -Object $costRecord -Name 'sessionId' | Should -Be 'session-001'

            $usage = script:Get-NormalizedUsage -Record $costRecord
            script:Get-ObjectValue -Object $usage -Name 'input_tokens' | Should -BeGreaterThan 0
            script:Get-ObjectValue -Object $usage -Name 'output_tokens' | Should -BeGreaterThan 0
            script:Get-ObjectValue -Object $usage -Name 'cache_creation_input_tokens' | Should -BeNullOrEmpty
            script:Get-ObjectValue -Object $usage -Name 'cache_read_input_tokens' | Should -BeNullOrEmpty

            Should -Invoke Get-CostCopilotReflog -Exactly -Times 1 -ParameterFilter { $RepoRoot -eq $script:RepoRoot }
        }
    }

    Context 'session grouping and reflog attribution' {
        It 'emits one normalized event per matched session and drops sessions outside the target branch window' {
            $records = @(
                script:New-CopilotOtelRecord -SessionId 'session-outside' -Timestamp '2025-12-31T23:59:30Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-outside' -Timestamp '2025-12-31T23:59:31Z' -InputTokens 10 -OutputTokens 5
                script:New-CopilotOtelRecord -SessionId 'session-a' -Timestamp '2026-01-01T00:00:02Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-a' -Timestamp '2026-01-01T00:00:03Z' -InputTokens 20 -OutputTokens 7
                script:New-CopilotOtelRecord -SessionId 'session-a' -Timestamp '2026-01-01T00:00:04Z' -InputTokens 30 -OutputTokens 8
                script:New-CopilotOtelRecord -SessionId 'session-b' -Timestamp '2026-01-01T00:04:59Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-b' -Timestamp '2026-01-01T00:05:00Z' -InputTokens 40 -OutputTokens 9
            )

            $walkOutput = script:Invoke-CopilotWalkForRecords -Records $records -ReflogLines (Get-Content -Path $script:SyntheticReflog -Encoding utf8)
            $sessionIds = @($walkOutput | ForEach-Object { script:Get-ObjectValue -Object $_ -Name 'sessionId' })

            $sessionIds | Should -BeExactly @('session-a', 'session-b')
            foreach ($costRecord in $walkOutput) {
                script:Get-ObjectValue -Object $costRecord -Name 'cwd' | Should -Be 'copilot-otel://copilot-orchestra'
                script:Get-ObjectValue -Object $costRecord -Name 'gitBranch' | Should -Be $script:TargetBranch
                $usage = script:Get-NormalizedUsage -Record $costRecord
                script:Get-ObjectValue -Object $usage -Name 'input_tokens' | Should -BeGreaterThan 0
                script:Get-ObjectValue -Object $usage -Name 'output_tokens' | Should -BeGreaterThan 0
            }
        }

        It 'attributes a session by its start timestamp when later token events straddle a branch switch' {
            $records = @(
                script:New-CopilotOtelRecord -SessionId 'session-before-switch' -Timestamp '2025-12-31T23:59:54Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-before-switch' -Timestamp '2026-01-01T00:00:02Z' -InputTokens 50 -OutputTokens 10
                script:New-CopilotOtelRecord -SessionId 'session-clock-skew' -Timestamp '2025-12-31T23:59:56Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-clock-skew' -Timestamp '2026-01-01T00:00:01Z' -InputTokens 60 -OutputTokens 12
            )

            $walkOutput = script:Invoke-CopilotWalkForRecords -Records $records -ReflogLines (Get-Content -Path $script:SyntheticReflog -Encoding utf8)
            $sessionIds = @($walkOutput | ForEach-Object { script:Get-ObjectValue -Object $_ -Name 'sessionId' })

            $sessionIds | Should -Contain 'session-clock-skew'
            $sessionIds | Should -Not -Contain 'session-before-switch'
        }
    }

    Context 'reflog robustness' {
        It 'ignores rebase noise when determining the active target branch' {
            $records = @(
                script:New-CopilotOtelRecord -SessionId 'session-after-rebase-noise' -Timestamp '2026-01-01T00:02:00Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-after-rebase-noise' -Timestamp '2026-01-01T00:02:01Z' -InputTokens 15 -OutputTokens 4
            )
            $reflogLines = @(
                'aaaaaaa HEAD@{2026-01-01T00:00:00+00:00}: checkout: moving from main to feature/issue-488-copilot-cost-collection'
                'bbbbbbb HEAD@{2026-01-01T00:01:00+00:00}: rebase (start): checkout main'
                'ccccccc HEAD@{2026-01-01T00:01:20+00:00}: rebase (pick): step(1): capture fixture'
            )

            $walkOutput = script:Invoke-CopilotWalkForRecords -Records $records -ReflogLines $reflogLines

            @($walkOutput | ForEach-Object { script:Get-ObjectValue -Object $_ -Name 'sessionId' }) | Should -Be @('session-after-rebase-noise')
        }

        It 'handles branch rename reflog entries as continuity for the target branch' {
            $records = @(
                script:New-CopilotOtelRecord -SessionId 'session-after-rename' -Timestamp '2026-01-01T00:04:00Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-after-rename' -Timestamp '2026-01-01T00:04:01Z' -InputTokens 25 -OutputTokens 6
            )
            $reflogLines = @(
                'aaaaaaa HEAD@{2026-01-01T00:00:00+00:00}: checkout: moving from main to old/issue-488-cost'
                'bbbbbbb HEAD@{2026-01-01T00:03:00+00:00}: Branch: renamed refs/heads/old/issue-488-cost to refs/heads/feature/issue-488-copilot-cost-collection'
            )

            $walkOutput = script:Invoke-CopilotWalkForRecords -Records $records -ReflogLines $reflogLines

            @($walkOutput | ForEach-Object { script:Get-ObjectValue -Object $_ -Name 'sessionId' }) | Should -Be @('session-after-rename')
        }

        It 'skips detached HEAD transitions and emits a detached-head diagnostic' {
            $records = @(
                script:New-CopilotOtelRecord -SessionId 'session-detached' -Timestamp '2026-01-01T00:02:00Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-detached' -Timestamp '2026-01-01T00:02:01Z' -InputTokens 25 -OutputTokens 6
            )
            $reflogLines = @(
                'aaaaaaa HEAD@{2026-01-01T00:00:00+00:00}: checkout: moving from main to feature/issue-488-copilot-cost-collection'
                'bbbbbbb HEAD@{2026-01-01T00:01:00+00:00}: checkout: moving from feature/issue-488-copilot-cost-collection to 638455b1904af88d14f076a50c3693099dc40aca'
            )
            $warnings = @()

            $walkOutput = script:Invoke-CopilotWalkForRecords -Records $records -ReflogLines $reflogLines -Warnings ([ref]$warnings)

            $walkOutput.Count | Should -Be 0
            $warnings | Where-Object { $_ -match 'copilot-reflog-detached-head' -or $_ -match 'detached HEAD' } | Should -Not -BeNullOrEmpty
        }

        It 'emits an empty-reflog diagnostic for a worktree-add capture with no reflog lines' {
            $records = @(
                script:New-CopilotOtelRecord -SessionId 'session-empty-reflog' -Timestamp '2026-01-01T00:02:00Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-empty-reflog' -Timestamp '2026-01-01T00:02:01Z' -InputTokens 10 -OutputTokens 3
            )
            $warnings = @()

            $walkOutput = script:Invoke-CopilotWalkForRecords -Records $records -ReflogLines @() -Warnings ([ref]$warnings)

            $walkOutput.Count | Should -Be 0
            $warnings | Where-Object { $_ -match 'copilot-reflog-empty' -or $_ -match 'empty reflog' } | Should -Not -BeNullOrEmpty
        }

        It 'emits a distinct unmapped-session diagnostic when OTel sessions have no matching reflog branch window' {
            $records = @(
                script:New-CopilotOtelRecord -SessionId 'session-unmapped' -Timestamp '2026-01-01T00:02:00Z' -OtelRecordName 'copilot_chat.session.start' -InputTokens $null -OutputTokens $null
                script:New-CopilotOtelRecord -SessionId 'session-unmapped' -Timestamp '2026-01-01T00:02:01Z' -InputTokens 10 -OutputTokens 3
            )
            $reflogLines = @(
                'aaaaaaa HEAD@{2026-01-01T00:00:00+00:00}: checkout: moving from main to feature/some-other-work'
            )
            $warnings = @()

            $walkOutput = script:Invoke-CopilotWalkForRecords -Records $records -ReflogLines $reflogLines -Warnings ([ref]$warnings)

            $walkOutput.Count | Should -Be 0
            $warnings | Where-Object {
                $_ -match 'copilot-reflog-no-match' -and $_ -match 'session-unmapped' -and $_ -match 'unmapped_session_count=1'
            } | Should -Not -BeNullOrEmpty
        }
    }
}
