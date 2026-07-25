#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for the goal-run/* protection + reporting + aging escalation +
    deferred-teardown retry integration in session-cleanup-detector-core.ps1
    (issue #874, plan step 3, AC3 detector-protection half).

.DESCRIPTION
    Deliberately avoids the pre-existing mock-git PATH harness used by
    session-cleanup-detector.Tests.ps1's other Describe blocks: every code
    path this file's goal-run additions touch either (a) never calls git at
    all (Get-SCDGoalRunWorktreeStatus is a pure state-file read,
    Get-SCDGoalRunProtectedLines is pure rendering) or (b) reaches a real,
    disposable git repo created fresh per test (mirrors
    goal-run-worktree-core.Tests.ps1's New-GRTestRepo pattern) -- so no mock
    binary is needed. Pre-existing (non-goal-run) detector tests are
    unaffected and continue to live in session-cleanup-detector.Tests.ps1.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:DetectorLibPath = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1'
    $script:GoalRunLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-worktree-core.ps1'
    . $script:DetectorLibPath
    . $script:GoalRunLibPath

    function script:New-SCDGoalRunTestRepo {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        & git -C $Path init -q -b main . 2>&1 | Out-Null
        & git -C $Path config user.email 'scd-goal-run@example.com' 2>&1 | Out-Null
        & git -C $Path config user.name 'scd-goal-run' 2>&1 | Out-Null
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBom)
        & git -C $Path add -A 2>&1 | Out-Null
        & git -C $Path commit -q -m 'seed' 2>&1 | Out-Null
        return $Path
    }

    function script:Set-SCDGoalRunStateHeartbeatAge {
        <#
        .SYNOPSIS
            Test-only helper: rewrites goal-run-active.json's heartbeat_at to
            $MinutesAgo minutes in the past, bypassing the lib's own private
            writer (direct file I/O only, matching the format
            Save-GoalRunActiveState itself writes: ConvertTo-Json -Depth 20,
            UTF8 no-BOM, no trailing newline).
        #>
        param(
            [Parameter(Mandatory)][string]$WorktreePath,
            [Parameter(Mandatory)][double]$MinutesAgo
        )
        $statePath = Join-Path $WorktreePath 'goal-run-active.json'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $state.heartbeat_at = (Get-Date).ToUniversalTime().AddMinutes(-1 * $MinutesAgo).ToString('o')
        ($state | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $statePath -Encoding utf8 -NoNewline
    }

    function script:New-SCDWorktreeRecord {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Branch
        )
        return @{
            WorktreePath = $Path
            BranchName   = $Branch
            IsBare       = $false
            IsDetached   = $false
            IsLocked     = $false
            LockReason   = ''
            IsPrunable   = $false
        }
    }

    $script:GetAdditionalContext = {
        param([string]$Output)
        $json = $Output | ConvertFrom-Json -ErrorAction Stop
        return $json.hookSpecificOutput.additionalContext
    }
}

Describe 'Test-SCDGoalRunBranchName' -Tag 'unit' {
    It 'matches the goal-run/ prefix' {
        Test-SCDGoalRunBranchName -BranchName 'goal-run/issue-874-abc123' | Should -Be $true
    }
    It 'does not match unrelated prefixes' {
        Test-SCDGoalRunBranchName -BranchName 'feature/issue-874-goal-run-harness' | Should -Be $false
        Test-SCDGoalRunBranchName -BranchName 'claude/goal-run-scratch-abcde' | Should -Be $false
    }
    It 'fails open (false) on null/empty input' {
        Test-SCDGoalRunBranchName -BranchName '' | Should -Be $false
        Test-SCDGoalRunBranchName -BranchName $null | Should -Be $false
    }
}

Describe 'Get-SCDGoalRunWorktreeStatus' -Tag 'unit' {

    It 'reports IsProtected=$true, IsStale=$false for a backed worktree with a fresh heartbeat' {
        $worktreeDir = Join-Path $TestDrive 'status-fresh'
        New-Item -ItemType Directory -Path $worktreeDir -Force | Out-Null
        New-GoalRunActiveState -WorktreePath $worktreeDir -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-fresh' -ContractHash ('1' * 64) | Out-Null

        $status = Get-SCDGoalRunWorktreeStatus -BranchName 'goal-run/issue-1-fresh' -WorktreePath $worktreeDir

        $status.IsProtected | Should -Be $true
        $status.IsStale | Should -Be $false
        $status.Note | Should -BeNullOrEmpty
        $status.AgeMinutes | Should -BeLessThan 1
    }

    It 'reports IsProtected=$true, IsStale=$true once the heartbeat is older than the threshold' {
        $worktreeDir = Join-Path $TestDrive 'status-stale'
        New-Item -ItemType Directory -Path $worktreeDir -Force | Out-Null
        New-GoalRunActiveState -WorktreePath $worktreeDir -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-stale' -ContractHash ('2' * 64) | Out-Null
        script:Set-SCDGoalRunStateHeartbeatAge -WorktreePath $worktreeDir -MinutesAgo ($script:GoalRunHeartbeatStaleThresholdMinutes + 30)

        $status = Get-SCDGoalRunWorktreeStatus -BranchName 'goal-run/issue-2-stale' -WorktreePath $worktreeDir

        $status.IsProtected | Should -Be $true
        $status.IsStale | Should -Be $true
        $status.AgeMinutes | Should -BeGreaterThan $script:GoalRunHeartbeatStaleThresholdMinutes
    }

    It 'a heartbeat exactly at the threshold is not yet stale (strictly-greater-than boundary)' {
        $worktreeDir = Join-Path $TestDrive 'status-boundary'
        New-Item -ItemType Directory -Path $worktreeDir -Force | Out-Null
        New-GoalRunActiveState -WorktreePath $worktreeDir -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-boundary' -ContractHash ('3' * 64) | Out-Null
        script:Set-SCDGoalRunStateHeartbeatAge -WorktreePath $worktreeDir -MinutesAgo ($script:GoalRunHeartbeatStaleThresholdMinutes - 1)

        $status = Get-SCDGoalRunWorktreeStatus -BranchName 'goal-run/issue-3-boundary' -WorktreePath $worktreeDir

        $status.IsStale | Should -Be $false
    }

    It 'fails open (IsProtected=$false, note set) when no state file exists' {
        $worktreeDir = Join-Path $TestDrive 'status-unbacked'
        New-Item -ItemType Directory -Path $worktreeDir -Force | Out-Null

        $status = Get-SCDGoalRunWorktreeStatus -BranchName 'goal-run/issue-4-unbacked' -WorktreePath $worktreeDir

        $status.IsProtected | Should -Be $false
        $status.Note | Should -Be $script:GoalRunUnbackedNote
    }

    It 'fails open (never throws) on a corrupt/unreadable state file' {
        $worktreeDir = Join-Path $TestDrive 'status-corrupt'
        New-Item -ItemType Directory -Path $worktreeDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $worktreeDir 'goal-run-active.json') -Value '{ not valid json' -Encoding utf8

        { $status = Get-SCDGoalRunWorktreeStatus -BranchName 'goal-run/issue-5-corrupt' -WorktreePath $worktreeDir } | Should -Not -Throw
        $status = Get-SCDGoalRunWorktreeStatus -BranchName 'goal-run/issue-5-corrupt' -WorktreePath $worktreeDir
        $status.IsProtected | Should -Be $false
        $status.Note | Should -Be $script:GoalRunUnbackedNote
    }

    It 'fails open when the goal-run lib was never dot-sourced (Get-GoalRunActiveState undefined)' {
        # In-process runspace (NOT a child pwsh/powershell process -- script-
        # safety-contract.Tests.ps1's AST scan only flags literal 'pwsh'/
        # 'powershell' CommandAst nodes, and [powershell]::Create() never
        # spawns one): a fresh, isolated Runspace within this same OS process
        # dot-sources ONLY the detector core, never the goal-run lib, proving
        # Get-SCDGoalRunWorktreeStatus's own Get-Command guard drives the
        # fail-open path. Isolated on purpose -- mutating this file's own
        # already-loaded function table (e.g. Remove-Item function:...) was
        # tried first and left the removal from a wider scope than a
        # same-scope re-dot-source in `finally` could restore, breaking every
        # later Describe in this file that depends on the lib staying loaded.
        $worktreeDir = Join-Path $TestDrive 'status-lib-unavailable'
        New-Item -ItemType Directory -Path $worktreeDir -Force | Out-Null

        $ps = [powershell]::Create()
        try {
            $ps.AddScript({
                param($DetectorLibPath, $BranchName, $WorktreePath)
                . $DetectorLibPath
                $libLoaded = [bool](Get-Command Get-GoalRunActiveState -ErrorAction SilentlyContinue)
                $status = Get-SCDGoalRunWorktreeStatus -BranchName $BranchName -WorktreePath $WorktreePath
                [pscustomobject]@{ LibLoaded = $libLoaded; IsProtected = $status.IsProtected; Note = $status.Note }
            }).AddArgument($script:DetectorLibPath).AddArgument('goal-run/issue-6-no-lib').AddArgument($worktreeDir) | Out-Null

            $invokeResult = $ps.Invoke()
            # Not asserting $ps.HadErrors here: it has been observed $true even
            # with zero entries across every output stream (Error/Warning/Debug/
            # Verbose/Information) and a Completed InvocationStateInfo -- a known
            # unreliable signal for a bare [powershell]::Create() runspace. The
            # actual returned values below are the load-bearing assertions.
            $invokeResult.Count | Should -Be 1 -Because 'the scriptblock must produce exactly one result object'

            $invokeResult[0].LibLoaded | Should -Be $false -Because 'the guard under test only means anything if the goal-run lib was genuinely never loaded in that runspace'
            $invokeResult[0].IsProtected | Should -Be $false
            $invokeResult[0].Note | Should -Be $script:GoalRunUnbackedNote
        }
        finally {
            $ps.Dispose()
        }
    }
}

Describe 'Get-SCDSiblingWorktreeCleanups — goal-run integration' -Tag 'unit' {

    It 'excludes a protected (backed + fresh heartbeat) goal-run sibling from ordinary candidacy' {
        $repo = script:New-SCDGoalRunTestRepo -Path (Join-Path $TestDrive 'sibling-protected-repo')
        $worktreeDir = Join-Path $TestDrive 'sibling-protected-worktree'
        $branch = 'goal-run/issue-874-protected'
        & git -C $repo worktree add -b $branch $worktreeDir 2>&1 | Out-Null
        New-GoalRunActiveState -WorktreePath $worktreeDir -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-sibling-protected' -ContractHash ('4' * 64) | Out-Null

        try {
            Push-Location $repo
            $records = @(
                (script:New-SCDWorktreeRecord -Path $repo -Branch 'main'),
                (script:New-SCDWorktreeRecord -Path $worktreeDir -Branch $branch)
            )
            $result = @(Get-SCDSiblingWorktreeCleanups -CurrentWorktreePath $repo -DefaultBranch 'main' -NoUpstreamBranchPrefixes @('claude/') -WorktreeRecords $records)

            $result.Count | Should -Be 1
            $result[0].IsGoalRunProtected | Should -Be $true
            $result[0].BranchName | Should -Be $branch
            $result[0].IsStale | Should -Be $false
            $result[0].ContainsKey('Eligible') | Should -Be $false -Because 'a protected goal-run item must never carry the ordinary Eligible key'
        }
        finally {
            Pop-Location
            & git -C $repo worktree remove --force $worktreeDir 2>&1 | Out-Null
        }
    }

    It 'reports an unbacked goal-run-named sibling as an ordinary manual-review candidate with the point-2 note' {
        $repo = script:New-SCDGoalRunTestRepo -Path (Join-Path $TestDrive 'sibling-unbacked-repo')
        $worktreeDir = Join-Path $TestDrive 'sibling-unbacked-worktree'
        $branch = 'goal-run/issue-874-unbacked'
        & git -C $repo worktree add -b $branch $worktreeDir 2>&1 | Out-Null
        # Deliberately no goal-run-active.json written at $worktreeDir.

        try {
            Push-Location $repo
            $records = @(
                (script:New-SCDWorktreeRecord -Path $repo -Branch 'main'),
                (script:New-SCDWorktreeRecord -Path $worktreeDir -Branch $branch)
            )
            $result = @(Get-SCDSiblingWorktreeCleanups -CurrentWorktreePath $repo -DefaultBranch 'main' -NoUpstreamBranchPrefixes @('claude/') -WorktreeRecords $records)

            $result.Count | Should -Be 1
            $result[0].IsGoalRunProtected | Should -BeNullOrEmpty
            $result[0].Eligible | Should -Be $false
            $result[0].ManualReviewReason | Should -Be 'looks like a goal-run name but has no run state.'
        }
        finally {
            Pop-Location
            & git -C $repo worktree remove --force $worktreeDir 2>&1 | Out-Null
        }
    }

    It 'treats a corrupt state file the same as unbacked -- fails open, never crashes, never excludes forever' {
        $repo = script:New-SCDGoalRunTestRepo -Path (Join-Path $TestDrive 'sibling-corrupt-repo')
        $worktreeDir = Join-Path $TestDrive 'sibling-corrupt-worktree'
        $branch = 'goal-run/issue-874-corrupt'
        & git -C $repo worktree add -b $branch $worktreeDir 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $worktreeDir 'goal-run-active.json') -Value 'not-json-at-all' -Encoding utf8

        try {
            Push-Location $repo
            $records = @(
                (script:New-SCDWorktreeRecord -Path $repo -Branch 'main'),
                (script:New-SCDWorktreeRecord -Path $worktreeDir -Branch $branch)
            )
            { $result = @(Get-SCDSiblingWorktreeCleanups -CurrentWorktreePath $repo -DefaultBranch 'main' -NoUpstreamBranchPrefixes @('claude/') -WorktreeRecords $records) } | Should -Not -Throw
            $result = @(Get-SCDSiblingWorktreeCleanups -CurrentWorktreePath $repo -DefaultBranch 'main' -NoUpstreamBranchPrefixes @('claude/') -WorktreeRecords $records)

            $result.Count | Should -Be 1
            $result[0].Eligible | Should -Be $false
            $result[0].ManualReviewReason | Should -Be 'looks like a goal-run name but has no run state.'
        }
        finally {
            Pop-Location
            & git -C $repo worktree remove --force $worktreeDir 2>&1 | Out-Null
        }
    }
}

Describe 'Get-SCDOrphanBranchCleanups — goal-run integration' -Tag 'unit' {

    It 'reports an orphaned goal-run branch (no linked worktree) as an ordinary manual-review candidate' {
        $repo = script:New-SCDGoalRunTestRepo -Path (Join-Path $TestDrive 'orphan-unbacked-repo')
        $branch = 'goal-run/issue-901-orphan'
        & git -C $repo branch $branch 2>&1 | Out-Null

        try {
            Push-Location $repo
            $records = @((script:New-SCDWorktreeRecord -Path $repo -Branch 'main'))
            $result = @(Get-SCDOrphanBranchCleanups -CurrentBranch 'main' -DefaultBranch 'main' -NoUpstreamBranchPrefixes @('claude/') -WorktreeRecords $records)

            $result.Count | Should -Be 1
            $result[0].BranchName | Should -Be $branch
            $result[0].Eligible | Should -Be $false
            $result[0].ManualReviewReason | Should -Be 'looks like a goal-run name but has no run state.'
        }
        finally {
            Pop-Location
        }
    }

    It 'does not report a goal-run branch that is still attached to a worktree record' {
        $repo = script:New-SCDGoalRunTestRepo -Path (Join-Path $TestDrive 'orphan-attached-repo')
        $worktreeDir = Join-Path $TestDrive 'orphan-attached-worktree'
        $branch = 'goal-run/issue-902-attached'
        & git -C $repo worktree add -b $branch $worktreeDir 2>&1 | Out-Null

        try {
            Push-Location $repo
            $records = @(
                (script:New-SCDWorktreeRecord -Path $repo -Branch 'main'),
                (script:New-SCDWorktreeRecord -Path $worktreeDir -Branch $branch)
            )
            $result = @(Get-SCDOrphanBranchCleanups -CurrentBranch 'main' -DefaultBranch 'main' -NoUpstreamBranchPrefixes @('claude/') -WorktreeRecords $records)

            ($result | Where-Object { $_.BranchName -eq $branch }).Count | Should -Be 0 -Because 'a goal-run branch with a linked worktree is never an orphan candidate'
        }
        finally {
            Pop-Location
            & git -C $repo worktree remove --force $worktreeDir 2>&1 | Out-Null
        }
    }
}

Describe 'Get-SCDGoalRunProtectedLines' -Tag 'unit' {

    It 'renders a plain informational line for a fresh item, with no retry nudge/fenced block' {
        $items = @(@{ BranchName = 'goal-run/issue-1-fresh'; WorktreePath = '/tmp/fresh'; IsStale = $false; AgeMinutes = 2.0; HeartbeatAt = (Get-Date).ToString('o'); TeardownDeferred = $false })
        $lines = Get-SCDGoalRunProtectedLines -RepoRoot '/repo' -Items $items
        $text = $lines -join "`n"

        $text | Should -Match ([regex]::Escape('goal-run/issue-1-fresh'))
        $text | Should -Match 'inflight'
        $text | Should -Not -Match 'stale heartbeat'
        $text | Should -Not -Match '```powershell'
    }

    It 'renders the escalation nudge and a fenced retry command for a stale item' {
        $items = @(@{ BranchName = 'goal-run/issue-2-stale'; WorktreePath = '/tmp/stale-path'; IsStale = $true; AgeMinutes = 500.0; HeartbeatAt = (Get-Date).ToString('o'); TeardownDeferred = $false })
        $lines = Get-SCDGoalRunProtectedLines -RepoRoot '/repo' -Items $items
        $text = $lines -join "`n"

        $text | Should -Match 'stale heartbeat'
        $text | Should -Match '```powershell'
        $text | Should -Match ([regex]::Escape('Invoke-GoalRunDeferredTeardownRetry'))
        $text | Should -Match ([regex]::Escape('/tmp/stale-path'))
    }

    It 'renders the escalation nudge for a teardown-deferred item even when not stale' {
        $items = @(@{ BranchName = 'goal-run/issue-3-deferred'; WorktreePath = '/tmp/deferred-path'; IsStale = $false; AgeMinutes = 1.0; HeartbeatAt = (Get-Date).ToString('o'); TeardownDeferred = $true })
        $lines = Get-SCDGoalRunProtectedLines -RepoRoot '/repo' -Items $items
        $text = $lines -join "`n"

        $text | Should -Match '```powershell'
        $text | Should -Match ([regex]::Escape('/tmp/deferred-path'))
        $text | Should -Match 'teardown previously deferred'
    }

    It 'a mixed fresh+stale batch only lists the stale worktree path inside the retry command' {
        $items = @(
            @{ BranchName = 'goal-run/issue-4-fresh'; WorktreePath = '/tmp/mix-fresh'; IsStale = $false; AgeMinutes = 1.0; HeartbeatAt = (Get-Date).ToString('o'); TeardownDeferred = $false },
            @{ BranchName = 'goal-run/issue-5-stale'; WorktreePath = '/tmp/mix-stale'; IsStale = $true; AgeMinutes = 500.0; HeartbeatAt = (Get-Date).ToString('o'); TeardownDeferred = $false }
        )
        $lines = Get-SCDGoalRunProtectedLines -RepoRoot '/repo' -Items $items
        $text = $lines -join "`n"
        $fenced = ([regex]::Matches($text, '(?ms)```powershell\s*(.*?)```') | ForEach-Object { $_.Groups[1].Value }) -join "`n"

        $fenced | Should -Match ([regex]::Escape('/tmp/mix-stale'))
        $fenced | Should -Not -Match ([regex]::Escape('/tmp/mix-fresh'))
    }
}

Describe 'Invoke-SessionCleanupDetector — goal-run end-to-end' -Tag 'unit' {

    It 'fixture (iii): a live goal-run worktree (backed + fresh heartbeat) is excluded from candidacy and reported informationally' {
        $repo = script:New-SCDGoalRunTestRepo -Path (Join-Path $TestDrive 'e2e-live-repo')
        $worktreeDir = Join-Path $TestDrive 'e2e-live-worktree'
        $branch = 'goal-run/issue-874-live'
        & git -C $repo worktree add -b $branch $worktreeDir 2>&1 | Out-Null
        New-GoalRunActiveState -WorktreePath $worktreeDir -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-e2e-live' -ContractHash ('5' * 64) | Out-Null

        try {
            Push-Location $repo
            $result = Invoke-SessionCleanupDetector -RepoRoot $repo
            $context = & $script:GetAdditionalContext -Output $result.Output

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape('Goal-run worktrees detected'))
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match 'inflight'
            $context | Should -Not -Match ([regex]::Escape('-SiblingWorktrees')) `
                -Because 'a live goal-run worktree must never be offered through the ordinary composite cleanup command'
        }
        finally {
            Pop-Location
            & git -C $repo worktree remove --force $worktreeDir 2>&1 | Out-Null
        }
    }

    It 'an unreadable/corrupt state file never crashes the detector and reports the branch as an ordinary candidate' {
        $repo = script:New-SCDGoalRunTestRepo -Path (Join-Path $TestDrive 'e2e-corrupt-repo')
        $worktreeDir = Join-Path $TestDrive 'e2e-corrupt-worktree'
        $branch = 'goal-run/issue-874-corrupt-e2e'
        & git -C $repo worktree add -b $branch $worktreeDir 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $worktreeDir 'goal-run-active.json') -Value '{{{not json' -Encoding utf8

        try {
            Push-Location $repo
            { $result = Invoke-SessionCleanupDetector -RepoRoot $repo } | Should -Not -Throw
            $result = Invoke-SessionCleanupDetector -RepoRoot $repo
            $context = & $script:GetAdditionalContext -Output $result.Output

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match 'looks like a goal-run name but has no run state'
        }
        finally {
            Pop-Location
            & git -C $repo worktree remove --force $worktreeDir 2>&1 | Out-Null
        }
    }

    It 'a stale-heartbeat protected worktree gets the escalation nudge; a fresh one in the same run does not' {
        $repo = script:New-SCDGoalRunTestRepo -Path (Join-Path $TestDrive 'e2e-aging-repo')
        $freshDir = Join-Path $TestDrive 'e2e-aging-fresh-worktree'
        $staleDir = Join-Path $TestDrive 'e2e-aging-stale-worktree'
        $freshBranch = 'goal-run/issue-874-aging-fresh'
        $staleBranch = 'goal-run/issue-874-aging-stale'
        & git -C $repo worktree add -b $freshBranch $freshDir 2>&1 | Out-Null
        & git -C $repo worktree add -b $staleBranch $staleDir 2>&1 | Out-Null
        New-GoalRunActiveState -WorktreePath $freshDir -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-aging-fresh' -ContractHash ('6' * 64) | Out-Null
        New-GoalRunActiveState -WorktreePath $staleDir -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-aging-stale' -ContractHash ('7' * 64) | Out-Null
        script:Set-SCDGoalRunStateHeartbeatAge -WorktreePath $staleDir -MinutesAgo ($script:GoalRunHeartbeatStaleThresholdMinutes + 30)

        try {
            Push-Location $repo
            $result = Invoke-SessionCleanupDetector -RepoRoot $repo
            $context = & $script:GetAdditionalContext -Output $result.Output
            $fenced = ([regex]::Matches($context, '(?ms)```powershell\s*(.*?)```') | ForEach-Object { $_.Groups[1].Value }) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($freshBranch))
            $context | Should -Match ([regex]::Escape($staleBranch))
            $fenced | Should -Match ([regex]::Escape('Invoke-GoalRunDeferredTeardownRetry'))
            $fenced | Should -Match ([regex]::Escape('e2e-aging-stale-worktree'))
            $fenced | Should -Not -Match ([regex]::Escape('e2e-aging-fresh-worktree')) `
                -Because 'a fresh, non-deferred goal-run worktree must never appear in the owner-confirmed retry command'
        }
        finally {
            Pop-Location
            & git -C $repo worktree remove --force $freshDir 2>&1 | Out-Null
            & git -C $repo worktree remove --force $staleDir 2>&1 | Out-Null
        }
    }
}
