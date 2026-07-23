#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for .github/scripts/lib/goal-run-stage-core.ps1 (issue #874,
    plan step 4, AC1 command + stage-machine half).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-stage-core.ps1'
    . $script:LibPath

    function script:New-GRSTestRepo {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        & git -C $Path init -q -b main . 2>&1 | Out-Null
        & git -C $Path config user.email 'goal-run-stage-s4@example.com' 2>&1 | Out-Null
        & git -C $Path config user.name 'goal-run-stage-s4' 2>&1 | Out-Null
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBom)
        & git -C $Path add -A 2>&1 | Out-Null
        & git -C $Path commit -q -m 'seed' 2>&1 | Out-Null
        return $Path
    }

    function script:Remove-GRSTestWorktree {
        param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$WorktreePath)
        & git -C $RepoRoot worktree remove --force $WorktreePath 2>&1 | Out-Null
        & git -C $RepoRoot worktree prune 2>&1 | Out-Null
        if (Test-Path -LiteralPath $WorktreePath) {
            Remove-Item -LiteralPath $WorktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'goal-run-stage-core.ps1: Test-Path resolves the lib file' -Tag 'unit' {
    It 'exists at the expected path' {
        (Test-Path -LiteralPath $script:LibPath) | Should -Be $true
    }
}

Describe 'Resolve-GoalRunResumeStage' -Tag 'unit' {

    It 'reports blocked when the contract hash is not verified, regardless of other signals' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $false -InflightMarkerPresent $true -ActiveStatePresent $true
        $result.ResumeStage | Should -Be 'blocked'
        $result.Reason | Should -Be 'contract-hash-unverified'
    }

    It 'reports complete when terminal emissions are verified, overriding everything else' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -TerminalEmissionsVerified $true -ExplicitStageMarker 'loop-launched'
        $result.ResumeStage | Should -Be 'complete'
    }

    It 'reports pre-loop on a fresh launch with nothing present' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true
        $result.ResumeStage | Should -Be 'pre-loop'
        $result.Reason | Should -Be 'fresh-launch'
    }

    It 'reports pre-loop when only the inflight marker is present (crash mid pre-loop)' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true
        $result.ResumeStage | Should -Be 'pre-loop'
        $result.Reason | Should -Be 'marker-posted-not-provisioned'
    }

    It 'reports loop-launched when the worktree is provisioned but the loop has not started' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true -ActiveStatePresent $true
        $result.ResumeStage | Should -Be 'loop-launched'
    }

    It 'reports loop-released when the run log has a checkpoint but no explicit stage marker exists' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ActiveStatePresent $true -RunLogHasCheckpoint $true
        $result.ResumeStage | Should -Be 'loop-released'
        $result.Reason | Should -Be 'run-log-implies-loop-launched-no-explicit-marker'
    }

    It 'reports loop-released when the explicit stage marker says loop-launched' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ExplicitStageMarker 'loop-launched'
        $result.ResumeStage | Should -Be 'loop-released'
    }

    It 'reports chain-dispatched when the explicit stage marker says loop-released' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ExplicitStageMarker 'loop-released'
        $result.ResumeStage | Should -Be 'chain-dispatched'
    }

    It 'reports chain-dispatched (awaiting terminal emissions) when the explicit stage marker says chain-dispatched' {
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ExplicitStageMarker 'chain-dispatched'
        $result.ResumeStage | Should -Be 'chain-dispatched'
        $result.Reason | Should -Be 'awaiting-terminal-emissions'
    }

    It 'lets an explicit stage marker take precedence over a stale ActiveStatePresent=false signal' {
        # Even if the caller failed to detect the active-state file for some
        # reason, an explicit stage marker is authoritative.
        $result = Resolve-GoalRunResumeStage -ContractHashVerified $true -ActiveStatePresent $false -ExplicitStageMarker 'loop-released'
        $result.ResumeStage | Should -Be 'chain-dispatched'
    }
}

Describe 'Goal-run stage marker body round-trip' -Tag 'unit' {

    It 'builds and parses a stage marker body symmetrically' {
        $body = New-GoalRunStageMarkerBody -Issue 874 -Stage 'loop-launched' -ContractHash ('a' * 64) -UpdatedAt '2026-07-23T00:00:00.0000000Z'
        $parsed = ConvertFrom-GoalRunStageMarkerBody -Body $body
        $parsed.Parsed | Should -Be $true
        $parsed.Issue | Should -Be 874
        $parsed.Stage | Should -Be 'loop-launched'
        $parsed.ContractHash | Should -Be ('a' * 64)
        $parsed.UpdatedAt | Should -Be '2026-07-23T00:00:00.0000000Z'
    }

    It 'reports Parsed = $false for a body with no stage-marker head' {
        $parsed = ConvertFrom-GoalRunStageMarkerBody -Body 'not a marker at all'
        $parsed.Parsed | Should -Be $false
    }
}

Describe 'Goal-run inflight marker body round-trip' -Tag 'unit' {

    It 'builds and parses an unresolved inflight marker body symmetrically' {
        $body = New-GoalRunInflightMarkerBody -Issue 874 -ContractHash ('b' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z'
        $parsed = ConvertFrom-GoalRunInflightMarkerBody -Body $body
        $parsed.Parsed | Should -Be $true
        $parsed.Issue | Should -Be 874
        $parsed.Status | Should -Be 'unresolved'
        $parsed.ContractHash | Should -Be ('b' * 64)
        $parsed.ResolvedReason | Should -BeNullOrEmpty
    }

    It 'round-trips a resolved marker carrying a resolved_reason' {
        $body = New-GoalRunInflightMarkerBody -Issue 874 -ContractHash ('b' * 64) -LaunchedAt '2026-07-23T00:00:00.0000000Z' -Status 'resolved' -ResolvedReason 'yielded-to-lower-comment-id'
        $parsed = ConvertFrom-GoalRunInflightMarkerBody -Body $body
        $parsed.Status | Should -Be 'resolved'
        $parsed.ResolvedReason | Should -Be 'yielded-to-lower-comment-id'
    }
}

Describe 'Resolve-GoalRunInflightMutexOutcome (marker-first ordering + reconcile tiebreak)' -Tag 'unit' {

    It 'lets the lowest (earliest) comment id proceed when two concurrent markers exist' {
        $result = Resolve-GoalRunInflightMutexOutcome -OwnCommentId 100 -LiveMarkerCommentIds @(100, 105)
        $result.Outcome | Should -Be 'proceed'
        $result.WinningCommentId | Should -Be 100
    }

    It 'makes the higher comment id yield when two concurrent markers exist' {
        $result = Resolve-GoalRunInflightMutexOutcome -OwnCommentId 105 -LiveMarkerCommentIds @(100, 105)
        $result.Outcome | Should -Be 'yield'
        $result.WinningCommentId | Should -Be 100
    }

    It 'proceeds when it is the only live marker' {
        $result = Resolve-GoalRunInflightMutexOutcome -OwnCommentId 42 -LiveMarkerCommentIds @()
        $result.Outcome | Should -Be 'proceed'
    }

    It 'auto-includes the own id even if the caller omitted it from the live set' {
        $result = Resolve-GoalRunInflightMutexOutcome -OwnCommentId 50 -LiveMarkerCommentIds @(60, 70)
        $result.Outcome | Should -Be 'proceed'
        $result.WinningCommentId | Should -Be 50
    }
}

Describe 'Invoke-GoalRunMutexLaunch' -Tag 'unit' {

    It 'aborts before provisioning when the marker post itself fails' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $false; CommentId = $null; Url = $null; LaunchedAt = $null } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith { @() }
        Mock -CommandName New-GoalRunWorktree -MockWith { throw 'New-GoalRunWorktree must not be called on marker-post failure' }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64)

        $result.Outcome | Should -Be 'abort-marker-post-failed'
        Should -Invoke -CommandName New-GoalRunWorktree -Times 0
    }

    It 'yields and never provisions when reconcile finds a lower-id live marker' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 105; Url = 'https://example/105'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @(
                [pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null },
                [pscustomobject]@{ CommentId = 105; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null }
            )
        }
        Mock -CommandName Set-GoalRunInflightMarkerResolved -MockWith { $true }
        Mock -CommandName New-GoalRunWorktree -MockWith { throw 'New-GoalRunWorktree must not be called when yielding' }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64) -Owner 'Grimblaz' -Repo 'agent-orchestra'

        $result.Outcome | Should -Be 'yielded'
        Should -Invoke -CommandName New-GoalRunWorktree -Times 0
        Should -Invoke -CommandName Set-GoalRunInflightMarkerResolved -Times 1
    }

    It 'provisions exactly once when reconcile confirms this run is the sole/lowest live marker' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 100; Url = 'https://example/100'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @([pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null })
        }
        Mock -CommandName New-GoalRunWorktree -MockWith { [pscustomobject]@{ Success = $true; RefusalReason = $null; Path = 'C:\fake\gr-874'; BranchName = 'goal-run/issue-874-token' } }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64)

        $result.Outcome | Should -Be 'launched'
        $result.Worktree.Path | Should -Be 'C:\fake\gr-874'
        Should -Invoke -CommandName New-GoalRunWorktree -Times 1
    }

    It 'surfaces a provisioning failure distinctly from a marker-post failure' {
        Mock -CommandName New-GoalRunInflightMarker -MockWith { [pscustomobject]@{ Success = $true; CommentId = 100; Url = 'https://example/100'; LaunchedAt = '2026-07-23T00:00:00.0000000Z' } }
        Mock -CommandName Get-GoalRunInflightMarkers -MockWith {
            @([pscustomobject]@{ CommentId = 100; Status = 'unresolved'; ContractHash = ('c' * 64); LaunchedAt = '2026-07-23T00:00:00.0000000Z'; ResolvedReason = $null })
        }
        Mock -CommandName New-GoalRunWorktree -MockWith { [pscustomobject]@{ Success = $false; RefusalReason = 'refused: uncommitted-changes'; Path = $null; BranchName = $null } }

        $result = Invoke-GoalRunMutexLaunch -Issue 874 -RepoRoot 'C:\fake\repo' -ContractHash ('c' * 64)

        $result.Outcome | Should -Be 'launch-failed-provisioning'
    }
}

Describe 'Test-GoalRunInflightAppearsDead (crash-atomicity)' -Tag 'unit' {

    It 'is not dead when the marker is already resolved' {
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'resolved' -LaunchedAt (Get-Date).AddHours(-5) -HaltReportExists $false -PrExists $false -Now (Get-Date)
        $result.AppearsDead | Should -Be $false
        $result.Reason | Should -Be 'marker-already-resolved'
    }

    It 'is not dead when a halt report already exists, even if very stale' {
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt (Get-Date).AddHours(-10) -HaltReportExists $true -PrExists $false -Now (Get-Date)
        $result.AppearsDead | Should -Be $false
        $result.Reason | Should -Be 'terminal-outcome-present'
    }

    It 'is not dead when a PR already exists, even if very stale' {
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt (Get-Date).AddHours(-10) -HaltReportExists $false -PrExists $true -Now (Get-Date)
        $result.AppearsDead | Should -Be $false
    }

    It 'is not dead within the stale threshold using LaunchedAt when no heartbeat exists' {
        $now = Get-Date
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $now.AddMinutes(-10) -HaltReportExists $false -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $false
    }

    It 'appears dead past the stale threshold using LaunchedAt when no heartbeat exists (never provisioned)' {
        $now = Get-Date
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $now.AddMinutes(-90) -HaltReportExists $false -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $true
        $result.Reason | Should -Be 'stale-no-terminal-outcome'
    }

    It 'prefers HeartbeatAt over LaunchedAt when both are present' {
        $now = Get-Date
        # Launched long ago, but heartbeat is recent -- must NOT appear dead.
        $result = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $now.AddHours(-5) -HeartbeatAt $now.AddMinutes(-5) -HaltReportExists $false -PrExists $false -Now $now -StaleThresholdMinutes 60
        $result.AppearsDead | Should -Be $false
        $result.LastSeenAt | Should -Be $now.AddMinutes(-5)
    }
}

Describe 'Resolve-GoalRunInvocationAction' -Tag 'unit' {

    It 'launches a new run when no unresolved marker exists' {
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $null -AppearsDead $false
        $result.Action | Should -Be 'launch-new'
    }

    It 'refuses and offers resume when an unresolved marker exists and does not appear dead' {
        $marker = [pscustomobject]@{ CommentId = 100 }
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $false
        $result.Action | Should -Be 'refuse-resume-existing'
    }

    It 'offers triage when an unresolved marker exists and appears dead' {
        $marker = [pscustomobject]@{ CommentId = 100 }
        $result = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $true
        $result.Action | Should -Be 'triage-dead-run'
    }
}

Describe 'Invoke-GoalRunAwaitStatusVerdict (bounded retry)' -Tag 'unit' {

    It 'returns released immediately when the verdict is present on the first read' {
        $reader = { param($Path) [pscustomobject]@{ State = 'present-met-true'; Event = [pscustomobject]@{ Fields = [pscustomobject]@{ met = $true } } } }
        $result = Invoke-GoalRunAwaitStatusVerdict -TranscriptPath 'fake.jsonl' -MaxRetries 5 -RetryDelayMs 1 -StatusReader $reader
        $result.Outcome | Should -Be 'released'
        $result.Attempts | Should -Be 1
    }

    It 'retries until the verdict appears within the retry window' {
        $script:GRSCallCount = 0
        $reader = {
            param($Path)
            $script:GRSCallCount++
            if ($script:GRSCallCount -lt 3) {
                return [pscustomobject]@{ State = 'status-absent'; Event = $null }
            }
            return [pscustomobject]@{ State = 'present-met-true'; Event = [pscustomobject]@{ Fields = [pscustomobject]@{ met = $true } } }
        }
        $result = Invoke-GoalRunAwaitStatusVerdict -TranscriptPath 'fake.jsonl' -MaxRetries 5 -RetryDelayMs 1 -StatusReader $reader
        $result.Outcome | Should -Be 'released'
        $result.Attempts | Should -Be 3
    }

    It 'reports retry-exhausted when the verdict never appears within the retry window' {
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }
        $result = Invoke-GoalRunAwaitStatusVerdict -TranscriptPath 'fake.jsonl' -MaxRetries 3 -RetryDelayMs 1 -StatusReader $reader
        $result.Outcome | Should -Be 'retry-exhausted'
        $result.Attempts | Should -Be 3
    }
}

Describe 'Resolve-GoalRunControlReturn (M13: control-return-then-read, distinct diagnostic halt)' -Tag 'unit' {

    It 'returns released and does not attempt a halt emission when the verdict appears in time' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith { throw 'Invoke-GoalRunHaltEmit must not be called on the released path' }
        $reader = { param($Path) [pscustomobject]@{ State = 'present-met-true'; Event = [pscustomobject]@{ Fields = [pscustomobject]@{ met = $true } } } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 3 -RetryDelayMs 1 -StatusReader $reader

        $result.Outcome | Should -Be 'released'
        Should -Invoke -CommandName Invoke-GoalRunHaltEmit -Times 0
    }

    It 'emits a distinct diagnostic halt naming the verdict-not-flushed condition on retry exhaustion' {
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            return [pscustomobject]@{ Success = $true; Url = 'https://example/halt'; Body = 'fake' }
        }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        $result = Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 2 -RetryDelayMs 1 -StatusReader $reader

        $result.Outcome | Should -Be 'halted-verdict-not-flushed'
        Should -Invoke -CommandName Invoke-GoalRunHaltEmit -Times 1 -ParameterFilter {
            $Report.halt_reason -eq 'chain-stage-failure' -and
            ($Report.evidence -join '|') -match 'goal_status verdict did not appear in transcript within 2 retries after loop completion'
        }
    }

    It 'validates the halt report built on retry exhaustion against the real halt schema' {
        $capturedReport = $null
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            $script:CapturedReport = $Report
            return [pscustomobject]@{ Success = $true; Url = 'https://example/halt'; Body = 'fake' }
        }
        $reader = { param($Path) [pscustomobject]@{ State = 'status-absent'; Event = $null } }

        Resolve-GoalRunControlReturn -TranscriptPath 'fake.jsonl' -Issue 874 -RepoRoot $script:RepoRoot -MaxRetries 1 -RetryDelayMs 1 -StatusReader $reader | Out-Null

        $validation = Test-GoalRunHaltReport -Report $script:CapturedReport -RepoRoot $script:RepoRoot
        $validation.IsValid | Should -Be $true -Because ($validation.Violations -join '; ')
    }
}

Describe 'Invoke-GoalRunLaunchChain and Test-GoalRunTerminalEmissionsVerified (seams)' -Tag 'unit' {

    It 'Invoke-GoalRunLaunchChain reports not launched, naming step 6 as the owner' {
        $handle = New-GoalRunExecutorSessionHandle -SessionId 'sess-1' -TranscriptPath 'fake.jsonl'
        $result = Invoke-GoalRunLaunchChain -Issue 874 -RepoRoot $script:RepoRoot -ContractHash ('d' * 64) -WorktreePath 'C:\fake\gr-874' -ExecutorSessionHandle $handle
        $result.Launched | Should -Be $false
        $result.Reason | Should -Be 'not-implemented-pending-step6'
    }

    It 'Test-GoalRunTerminalEmissionsVerified always reports not-verified in this PR' {
        $result = Test-GoalRunTerminalEmissionsVerified -Issue 874 -RepoRoot $script:RepoRoot
        $result.Verified | Should -Be $false
    }

    It 'New-GoalRunExecutorSessionHandle carries the expected shape' {
        $handle = New-GoalRunExecutorSessionHandle -SessionId 'sess-1' -TranscriptPath 'fake.jsonl' -Arm 'in-session'
        $handle.SessionId | Should -Be 'sess-1'
        $handle.TranscriptPath | Should -Be 'fake.jsonl'
        $handle.Arm | Should -Be 'in-session'
    }
}
