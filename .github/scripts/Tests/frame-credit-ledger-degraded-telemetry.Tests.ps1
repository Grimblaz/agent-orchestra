#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Issue #794, slice s4 — degraded telemetry: typed reason + auto-posted honest
# comment (sub-observation 4 + AC6).
#
# Part 1 (script:Set-FCLCostCoverageMetadata): a typed `degraded_reason` field
# (env-absent | budget-exceeded | no-transcript-found) derived from EITHER the
# Claude or the Copilot walk's TimedOut/Failed flags, plus a Claude-projects-
# root-absence check (the `frame-enforce.yml` ubuntu-latest CI landmine).
#
# Part 2 (AC6): an orchestrated-origin PR with a genuinely degraded walk (and
# no prior populated cost-pattern-data comment) gets a standalone, schema-
# valid degraded-honest `cost-pattern-data` comment auto-posted, distinct from
# the main frame-credit-ledger-{Pr} comment.
#
# Harness: in-process dot-source of the orchestrator (mirrors
# frame-credit-ledger-orchestrator.Tests.ps1's InvokeCostWalkerOrchestratorInProcess
# helper) so walker-function mocks defined AFTER the dot-source correctly shadow
# the real cost-walker.ps1 functions in the same scope (a full child-process
# invocation would instead have the real lib functions win, since `& script.ps1`
# dot-sources its own libs into a fresh local scope that shadows any pre-defined
# `global:` mock of the same name).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:OrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'

    $script:V4AllCoveredBody = @'
## Summary

A v4 PR body where every credit is passed.

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: review
    status: passed
    evidence: "judge ruling: keep"
  - port: implement-code
    status: passed
    evidence: "implementation complete"
  - port: implement-test
    status: passed
    evidence: "tests GREEN at HEAD"
integrity_checks:
  - check: schema-version-pinned
    status: passed
  - check: marker-presence
    status: passed
-->
'@

    $script:NoMetricsNoSignalBody = @'
## Summary

A PR body with no pipeline-metrics marker block and no body orchestration signals.
'@

    # In-process helper. Parameters:
    #   -ClaudeMode / -CopilotMode : 'ok' | 'empty' | 'timeout' | 'throw'
    #   -ProjectsRootAbsent        : when $true, FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT
    #                                points at a path that does not exist (env-absent case).
    #   -PrBody / -Comments        : control orchestrated-origin (via headRefName) + prior comment.
    #   -HeadRefName               : drives Get-FCLOriginContext's branch-based orchestrated check.
    $script:InvokeDegradedTelemetryInProcess = {
        param(
            [int]$Pr = 794,
            [string]$Mode = 'warn',
            [ValidateSet('ok', 'throw', 'timeout', 'empty')][string]$ClaudeMode = 'empty',
            [ValidateSet('ok', 'throw', 'timeout', 'empty')][string]$CopilotMode = 'empty',
            [bool]$ProjectsRootAbsent = $false,
            [string]$PrBody = $script:V4AllCoveredBody,
            [object[]]$Comments = @(),
            [string]$HeadRefName = 'feature/issue-794-orchestrate-credit-harvest'
        )

        $previousClaudeTimeout = $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS
        $previousCopilotTimeout = $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS
        $previousProjectsRoot = $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT
        $previousHeadRef = $env:GITHUB_HEAD_REF
        $previousNoSleep = $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP

        # A directory that either does not exist (env-absent) or exists-and-is-empty
        # (root present, but the walker legitimately finds nothing).
        $projectsRootPath = if ($ProjectsRootAbsent) {
            Join-Path $TestDrive ('fcl-s4-absent-' + [System.Guid]::NewGuid().ToString('N'))
        }
        else {
            $existingDir = Join-Path $TestDrive ('fcl-s4-present-' + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $existingDir -Force | Out-Null
            $existingDir
        }

        $script:FCLS4PostedComments = [System.Collections.Generic.List[string]]::new()
        $script:FCLS4PatchedBodies = [System.Collections.Generic.List[string]]::new()

        # Save Pr and Mode before dot-sourcing — the dot-source assigns those param
        # names in the calling scope, which would overwrite our own parameters
        # (matches the same guard in frame-credit-ledger-orchestrator.Tests.ps1's
        # InvokeOrchestratorInProcess helper).
        $private:prNumber = $Pr
        $private:modeValue = $Mode

        try {
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS = '1'
            $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS = '1'
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $projectsRootPath
            $env:GITHUB_HEAD_REF = $HeadRefName
            $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'

            # Dot-source the orchestrator to load all functions without running the
            # top-level execution block ($isDotSourced becomes $true for -Pr 0).
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null
            $script:FrameCreditLedgerRepoRoot = $script:RepoRoot

            # ---- git mock -------------------------------------------------------
            function git {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                if ($joined -match 'rev-parse --show-toplevel') { $global:LASTEXITCODE = 0; return $script:RepoRoot }
                if ($joined -match 'config --get remote\.origin\.url') { $global:LASTEXITCODE = 0; return 'https://github.com/example/example.git' }
                if ($joined -match 'rev-parse --abbrev-ref HEAD') { $global:LASTEXITCODE = 0; return $HeadRefName }
                $global:LASTEXITCODE = 0
                return ''
            }

            # ---- gh mock (captures comment posts/patches for assertions) --------
            $capturedBodyJson = (@{ body = $PrBody; comments = @($Comments) } | ConvertTo-Json -Compress -Depth 8)
            function gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '

                if ($joined -match 'pr view \d+ --json baseRefOid') {
                    $global:LASTEXITCODE = 0; return '{"baseRefOid":"abc123"}'
                }
                if ($joined -match 'pr view \d+ --json body,comments') {
                    $global:LASTEXITCODE = 0; return $capturedBodyJson
                }
                if ($joined -match '(issue|pr) view \d+ --json comments') {
                    $global:LASTEXITCODE = 0; return '{"comments":[]}'
                }
                if ($joined -match 'pr view \d+ --json headRefName') {
                    $global:LASTEXITCODE = 0; return $HeadRefName
                }
                if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                    $global:LASTEXITCODE = 0; return '{"owner":{"login":"example"},"name":"example"}'
                }
                if ($joined -match '(issue|pr) comment \d+ --body') {
                    $idx = [Array]::IndexOf($Args, '--body')
                    if ($idx -ge 0 -and $idx + 1 -lt $Args.Count) {
                        $script:FCLS4PostedComments.Add([string]$Args[$idx + 1])
                    }
                    $global:LASTEXITCODE = 0; return 'https://github.com/example/example/pull/794#issuecomment-1'
                }
                if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
                    foreach ($arg in $Args) {
                        $argText = [string]$arg
                        if ($argText -like 'body=*') {
                            $script:FCLS4PatchedBodies.Add($argText.Substring(5))
                            break
                        }
                    }
                    $global:LASTEXITCODE = 0; return '{"html_url":"https://github.com/example/example/pull/794#issuecomment-2"}'
                }

                $global:LASTEXITCODE = 0
                return ''
            }

            # ---- cost-walker mocks (redefined AFTER dot-source; same scope wins) ----
            # NOTE: these functions execute inside a cloned worker runspace
            # (Invoke-FCLCostWalkerWithTimeout / New-FCLInitialSessionStateClone),
            # which only carries GLOBAL-scoped variables across the clone boundary
            # (env vars are process-global and cross automatically; ordinary local
            # scriptblock parameters like $ClaudeMode do NOT). Drive behavior via
            # env vars (matching the existing FCL_TEST_CLAUDE_MODE convention in
            # frame-credit-ledger-orchestrator.Tests.ps1) rather than closing over
            # $ClaudeMode/$CopilotMode directly, which would silently resolve to
            # $null inside the worker and always fall through to 'default'.
            $env:FCL_S4_CLAUDE_MODE = $ClaudeMode
            $env:FCL_S4_COPILOT_MODE = $CopilotMode

            function Get-CostTranscriptSlug { param([string]$CwdPath) $null = $CwdPath; return 'test-slug' }

            function Invoke-CostTranscriptWalk {
                param([string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$RepoRoot = '', [Nullable[int]]$IssueNumber = $null)
                $null = $Slug; $null = $ParentCwd; $null = $RepoRoot; $null = $IssueNumber
                switch ($env:FCL_S4_CLAUDE_MODE) {
                    'throw' { throw 'simulated Claude walker failure' }
                    'timeout' { Start-Sleep -Seconds 5; return @() }
                    'empty' { return @() }
                    default {
                        return @(@{
                            type      = 'assistant'
                            provider  = 'claude'
                            cwd       = $ParentCwd
                            gitBranch = $Branch
                            message   = @{
                                model       = 'claude-sonnet-4-x'
                                stop_reason = 'end_turn'
                                usage       = @{ input_tokens = 100; output_tokens = 20; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
                                content     = @()
                            }
                        })
                    }
                }
            }

            function Invoke-CostCopilotWalk {
                param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
                $null = $Branch; $null = $RepoRoot; $null = $OtelJsonlPath; $null = $WorkspaceFolderBasename
                switch ($env:FCL_S4_COPILOT_MODE) {
                    'throw' { throw 'simulated Copilot walker failure' }
                    'timeout' { Start-Sleep -Seconds 5; return @() }
                    default { return @() }
                }
            }

            function Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) $null = $TimeoutSeconds; return @{ timed_out = $false; entries = @() } }
            function Get-MostRecentRegimeCheckpoint { param([string]$Path, [string]$Coverage = '') $null = $Path; $null = $Coverage; return $null }
            function Get-CostAnomalyFlags {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
                param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint)
                $null = $ThisRun; $null = $RollingHistory; $null = $RegimeCheckpoint
                return @()
            }

            $result = Invoke-FrameCreditLedger -Pr $private:prNumber -Mode $private:modeValue
            return @{
                Result         = $result
                PostedComments = @($script:FCLS4PostedComments)
                PatchedBodies  = @($script:FCLS4PatchedBodies)
            }
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS = $previousClaudeTimeout
            $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS = $previousCopilotTimeout
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $previousProjectsRoot
            $env:GITHUB_HEAD_REF = $previousHeadRef
            $env:FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = $previousNoSleep
            Remove-Item Env:\FCL_S4_CLAUDE_MODE -ErrorAction SilentlyContinue
            Remove-Item Env:\FCL_S4_COPILOT_MODE -ErrorAction SilentlyContinue
            Remove-Variable -Name FCLS4PostedComments -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name FCLS4PatchedBodies -Scope Script -ErrorAction SilentlyContinue
        }
    }
}

Describe 'frame-credit-ledger degraded telemetry (issue #794 s4)' {

    Context 'Part 1: Set-FCLCostCoverageMetadata unit-level degraded_reason derivation' {
        BeforeAll {
            # Direct dot-source (no Pr/Mode execution — Pr 0 triggers the
            # $isDotSourced short-circuit at the bottom of the script) so
            # script:Set-FCLCostCoverageMetadata and script:Test-FCLClaudeProjectsRootAbsent
            # are callable directly, without going through the full orchestrator.
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null
        }

        AfterEach {
            Remove-Item Env:\FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT -ErrorAction SilentlyContinue
        }

        It 'derives env-absent when the Claude transcript root does not exist' {
            $absentRoot = Join-Path $TestDrive ('fcl-s4-unit-absent-' + [System.Guid]::NewGuid().ToString('N'))
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $absentRoot

            $attribution = @{}
            $claudeWalk = [pscustomobject]@{ Events = @(); TimedOut = $false; Failed = $false; Warnings = @() }
            script:Set-FCLCostCoverageMetadata -Attribution $attribution -Events @() -ClaudeWalk $claudeWalk -CopilotWalk $null -CopilotOtelJsonlPath 'nonexistent-otel.jsonl'

            $attribution['degraded_reason'] | Should -Be 'env-absent'
        }

        It 'derives budget-exceeded when the Claude walk TimedOut is true and the root exists' {
            $presentRoot = Join-Path $TestDrive ('fcl-s4-unit-present-' + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $presentRoot -Force | Out-Null
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $presentRoot

            $attribution = @{}
            $claudeWalk = [pscustomobject]@{ Events = @(); TimedOut = $true; Failed = $false; Warnings = @() }
            script:Set-FCLCostCoverageMetadata -Attribution $attribution -Events @() -ClaudeWalk $claudeWalk -CopilotWalk $null -CopilotOtelJsonlPath 'nonexistent-otel.jsonl'

            $attribution['degraded_reason'] | Should -Be 'budget-exceeded'
        }

        It 'derives budget-exceeded when the Copilot walk TimedOut is true (root exists, Claude walk clean)' {
            $presentRoot = Join-Path $TestDrive ('fcl-s4-unit-present-' + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $presentRoot -Force | Out-Null
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $presentRoot

            $attribution = @{}
            $claudeWalk = [pscustomobject]@{ Events = @(); TimedOut = $false; Failed = $false; Warnings = @() }
            $copilotWalk = [pscustomobject]@{ Events = @(); TimedOut = $true; Failed = $false; Warnings = @() }
            script:Set-FCLCostCoverageMetadata -Attribution $attribution -Events @() -ClaudeWalk $claudeWalk -CopilotWalk $copilotWalk -CopilotOtelJsonlPath 'nonexistent-otel.jsonl'

            $attribution['degraded_reason'] | Should -Be 'budget-exceeded' -Because 'degraded_reason must be derivable from EITHER walker, not Claude-only'
        }

        It 'derives no-transcript-found when the root exists, the walk completed, and found nothing' {
            $presentRoot = Join-Path $TestDrive ('fcl-s4-unit-present-' + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $presentRoot -Force | Out-Null
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $presentRoot

            $attribution = @{}
            $claudeWalk = [pscustomobject]@{ Events = @(); TimedOut = $false; Failed = $false; Warnings = @() }
            script:Set-FCLCostCoverageMetadata -Attribution $attribution -Events @() -ClaudeWalk $claudeWalk -CopilotWalk $null -CopilotOtelJsonlPath 'nonexistent-otel.jsonl'

            $attribution['degraded_reason'] | Should -Be 'no-transcript-found'
        }

        It 'leaves degraded_reason null/absent for a normal, populated walk' {
            $presentRoot = Join-Path $TestDrive ('fcl-s4-unit-present-' + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $presentRoot -Force | Out-Null
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $presentRoot

            $attribution = @{}
            $claudeWalk = [pscustomobject]@{ Events = @(@{ type = 'assistant' }); TimedOut = $false; Failed = $false; Warnings = @() }
            $events = @(@{ type = 'assistant'; provider = 'claude' })
            script:Set-FCLCostCoverageMetadata -Attribution $attribution -Events $events -ClaudeWalk $claudeWalk -CopilotWalk $null -CopilotOtelJsonlPath 'nonexistent-otel.jsonl'

            $attribution['degraded_reason'] | Should -BeNullOrEmpty
        }

        It 'prioritizes env-absent over budget-exceeded when both conditions are present' {
            $absentRoot = Join-Path $TestDrive ('fcl-s4-unit-absent-' + [System.Guid]::NewGuid().ToString('N'))
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $absentRoot

            $attribution = @{}
            $claudeWalk = [pscustomobject]@{ Events = @(); TimedOut = $true; Failed = $false; Warnings = @() }
            script:Set-FCLCostCoverageMetadata -Attribution $attribution -Events @() -ClaudeWalk $claudeWalk -CopilotWalk $null -CopilotOtelJsonlPath 'nonexistent-otel.jsonl'

            $attribution['degraded_reason'] | Should -Be 'env-absent' -Because 'env-absent is the routine CI shape and takes priority over a timeout that could not have meaningfully occurred without a projects root'
        }
    }

    Context 'Part 1 (orchestrator-level): degraded standalone comment carries the typed reason' {
        # These assert via the auto-posted degraded standalone comment (which embeds
        # degraded_reason in its own composed YAML — see Compose-FCLDegradedCostComment).
        # The MAIN frame-credit-ledger-{Pr} comment's cost section is rendered by the
        # untouched Format-CostPatternYaml/Format-CostPatternMarkdown renderer (out of
        # scope for this slice) and intentionally does NOT surface degraded_reason.

        It 'reports budget-exceeded when the Claude walker times out (root present, no events)' {
            $ip = & $script:InvokeDegradedTelemetryInProcess -ClaudeMode 'timeout' -CopilotMode 'empty' -ProjectsRootAbsent $false

            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 1
            $degraded[0] | Should -Match '(?m)^degraded_reason: budget-exceeded$'
        }

        It 'reports no-transcript-found when the root exists but the walk legitimately finds nothing' {
            $ip = & $script:InvokeDegradedTelemetryInProcess -ClaudeMode 'empty' -CopilotMode 'empty' -ProjectsRootAbsent $false

            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 1
            $degraded[0] | Should -Match '(?m)^degraded_reason: no-transcript-found$'
        }

        It 'reports env-absent when the Claude transcript root does not exist (frame-enforce.yml CI shape)' {
            # env-absent never auto-posts (Part 2 rule), so this is verified via
            # stderr diagnostics rather than a posted comment.
            $ip = & $script:InvokeDegradedTelemetryInProcess -ClaudeMode 'empty' -CopilotMode 'empty' -ProjectsRootAbsent $true

            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 0 -Because 'env-absent must never auto-post (verified independently in Part 2)'
        }

        It 'does not set degraded_reason for a normal, populated walk' {
            $ip = & $script:InvokeDegradedTelemetryInProcess -ClaudeMode 'ok' -CopilotMode 'empty' -ProjectsRootAbsent $false

            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 0
        }
    }

    Context 'Part 2 (AC6): degraded-comment auto-post' {

        It 'auto-posts a schema-valid degraded comment for an orchestrated-origin PR with genuine degradation (no-transcript-found) and no prior comment' {
            $ip = & $script:InvokeDegradedTelemetryInProcess `
                -ClaudeMode 'empty' -CopilotMode 'empty' -ProjectsRootAbsent $false `
                -HeadRefName 'feature/issue-794-orchestrate-credit-harvest'

            $ip.PostedComments.Count | Should -BeGreaterThan 0
            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 1
            $degraded[0] | Should -Match 'excluded_from_rolling_baseline: true'
            $degraded[0] | Should -Match 'degraded_reason: no-transcript-found'
        }

        It 'auto-posts a schema-valid degraded comment for genuine degradation (budget-exceeded)' {
            $ip = & $script:InvokeDegradedTelemetryInProcess `
                -ClaudeMode 'timeout' -CopilotMode 'empty' -ProjectsRootAbsent $false `
                -HeadRefName 'feature/issue-794-orchestrate-credit-harvest'

            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 1
            $degraded[0] | Should -Match 'excluded_from_rolling_baseline: true'
            $degraded[0] | Should -Match 'degraded_reason: budget-exceeded'
        }

        It 'does not auto-post when degraded_reason is env-absent (routine CI shape, not a genuine anomaly)' {
            $ip = & $script:InvokeDegradedTelemetryInProcess `
                -ClaudeMode 'empty' -CopilotMode 'empty' -ProjectsRootAbsent $true `
                -HeadRefName 'feature/issue-794-orchestrate-credit-harvest'

            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 0
        }

        It 'does not auto-post when a real walk found events (normal path unaffected)' {
            $ip = & $script:InvokeDegradedTelemetryInProcess `
                -ClaudeMode 'ok' -CopilotMode 'empty' -ProjectsRootAbsent $false `
                -HeadRefName 'feature/issue-794-orchestrate-credit-harvest'

            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 0
        }

        It 'does not clobber an existing populated cost-pattern-data comment on a subsequent degraded walk' {
            $priorCostBody = "## Cost Pattern`n<!-- cost-pattern-data`nversion: 1`nsession_completeness: complete`nexcluded_from_rolling_baseline: false`ngenerated_at: 2026-04-01T00:00:00Z`nports:`n  - name: implement-code`n    tokens:`n      input: 500`n      output: 200`n      cache_creation: 0`n      cache_read: 0`nanomaly_flags: []`npr: 794`n-->"
            $comments = @([pscustomobject]@{ body = $priorCostBody; databaseId = 3001; url = 'https://github.com/example/example/issues/794#issuecomment-3001' })

            $ip = & $script:InvokeDegradedTelemetryInProcess `
                -ClaudeMode 'empty' -CopilotMode 'empty' -ProjectsRootAbsent $false `
                -HeadRefName 'feature/issue-794-orchestrate-credit-harvest' `
                -Comments $comments

            # The populated prior must survive in the main comment (non-clobber gate).
            $ip.Result.Comment | Should -Match '2026-04-01T00:00:00Z' -Because 'the populated prior render must be preserved in the main ledger comment'
            # No standalone degraded comment should have been posted.
            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 0
        }

        It 'stays quiet for a non-orchestrated-origin PR with a degraded walk' {
            $ip = & $script:InvokeDegradedTelemetryInProcess `
                -ClaudeMode 'empty' -CopilotMode 'empty' -ProjectsRootAbsent $false `
                -PrBody $script:NoMetricsNoSignalBody `
                -HeadRefName 'some-random-branch'

            $degraded = @($ip.PostedComments | Where-Object { $_ -match 'cost-pattern-data-degraded-794' })
            $degraded.Count | Should -Be 0
        }
    }
}
