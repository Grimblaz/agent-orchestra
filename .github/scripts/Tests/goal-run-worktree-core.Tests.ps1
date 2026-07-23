#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for .github/scripts/lib/goal-run-worktree-core.ps1 (issue #874,
    plan step 2, AC3 provisioning + teardown half).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-worktree-core.ps1'
    . $script:LibPath

    # Real, local-identity temp git repo -- never the invoking repo -- same
    # pattern as goal-contract-validate-core.Tests.ps1's New-GCTestRepo.
    function script:New-GRTestRepo {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        & git -C $Path init -q -b main . 2>&1 | Out-Null
        & git -C $Path config user.email 'goal-run-worktree-s2@example.com' 2>&1 | Out-Null
        & git -C $Path config user.name 'goal-run-worktree-s2' 2>&1 | Out-Null
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBom)
        & git -C $Path add -A 2>&1 | Out-Null
        & git -C $Path commit -q -m 'seed' 2>&1 | Out-Null
        return $Path
    }

    # A smart forwarding mock: passes every git invocation through to the
    # REAL git binary except `worktree remove`, which fails for the first
    # $FailCount calls. Mirrors goal-contract-validate-core.Tests.ps1's
    # New-MockGitTeardownFailure exactly -- exercises the retry/defer path
    # WITHOUT ever holding a real OS-level file lock.
    function script:New-GRMockGitTeardownFailure {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$CounterFile,
            [Parameter(Mandatory)][int]$FailCount
        )
        @"
param()
`$argsJoined = `$args -join ' '
if (`$argsJoined -match 'worktree remove') {
    `$count = 0
    if (Test-Path -LiteralPath '$CounterFile') { `$count = [int](Get-Content -LiteralPath '$CounterFile' -Raw) }
    `$count++
    Set-Content -LiteralPath '$CounterFile' -Value `$count -NoNewline
    if (`$count -le $FailCount) {
        exit 1
    }
}
& git @args
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
    }

    # Manual cleanup for real worktrees a persistent-failure test leaks
    # (Pester only auto-cleans TestDrive, and the mock never actually
    # removes anything on disk).
    function script:Remove-GRTestWorktree {
        param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$WorktreePath)
        & git -C $RepoRoot worktree remove --force $WorktreePath 2>&1 | Out-Null
        & git -C $RepoRoot worktree prune 2>&1 | Out-Null
        if (Test-Path -LiteralPath $WorktreePath) {
            Remove-Item -LiteralPath $WorktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'goal-run-worktree-core.ps1: Test-Path resolves the lib file' -Tag 'unit' {
    It 'exists at the expected path' {
        (Test-Path -LiteralPath $script:LibPath) | Should -Be $true
    }
}

Describe 'New-GoalRunWorktree' -Tag 'unit' {

    It 'refuses provisioning on a dirty invoking tree' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'dirty-repo')
        [System.IO.File]::WriteAllText((Join-Path $repo 'dirty.txt'), 'uncommitted', [System.Text.UTF8Encoding]::new($false))

        $result = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 874

        $result.Success | Should -Be $false
        $result.RefusalReason | Should -Be 'refused: uncommitted-changes'
        $result.Path | Should -BeNullOrEmpty

        $worktreeList = & git -C $repo worktree list
        @($worktreeList).Count | Should -Be 1 -Because 'a refused provision must not create a worktree'
    }

    It 'provisions a named goal-run branch and worktree at the configurable root, and sets core.longpaths' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'clean-repo')
        $worktreeRoot = Join-Path $TestDrive 'gr-root'
        New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null

        try {
            $result = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 874 -WorktreeRoot $worktreeRoot

            $result.Success | Should -Be $true
            $result.BranchName | Should -Match '^goal-run/issue-874-[0-9a-f]{32}$'
            $result.Path | Should -Match ([regex]::Escape($worktreeRoot))
            (Split-Path -Leaf $result.Path) | Should -Match '^gr-874-[0-9a-f]{32}$'
            (Test-Path -LiteralPath $result.Path) | Should -Be $true

            $longpaths = (& git -C $result.Path config core.longpaths).Trim()
            $longpaths | Should -Be 'true'
        }
        finally {
            if ($result -and $result.Path) {
                script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $result.Path
            }
        }
    }

    It 'defaults the worktree root to the repo-parent directory when -WorktreeRoot is not supplied' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'default-root-repo')
        $expectedParent = Split-Path -Parent $repo

        try {
            $result = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 1

            $result.Success | Should -Be $true
            (Split-Path -Parent $result.Path) | Should -Be $expectedParent
        }
        finally {
            if ($result -and $result.Path) {
                script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $result.Path
            }
        }
    }

    It 'generates a collision-proof unique token across two consecutive provisions for the same issue' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'collision-repo')

        try {
            $first = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 42
            $second = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 42

            $first.Success | Should -Be $true
            $second.Success | Should -Be $true
            $first.BranchName | Should -Not -Be $second.BranchName
            $first.Path | Should -Not -Be $second.Path
            (Test-Path -LiteralPath $first.Path) | Should -Be $true
            (Test-Path -LiteralPath $second.Path) | Should -Be $true

            $worktreeList = & git -C $repo worktree list
            @($worktreeList).Count | Should -Be 3 -Because 'main + two distinct goal-run worktrees'
        }
        finally {
            if ($first -and $first.Path) { script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $first.Path }
            if ($second -and $second.Path) { script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $second.Path }
        }
    }
}

Describe 'goal-run-active.json state-file primitives' -Tag 'unit' {

    It 'round-trips a full state object, including the heartbeat field' {
        $worktreePath = Join-Path $TestDrive 'state-roundtrip-worktree'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null

        $created = New-GoalRunActiveState -WorktreePath $worktreePath `
            -Ceilings @{ turns = 40; wall_clock_minutes = 60 } `
            -Baseline @{ commit = 'abc123' } `
            -Arm 'in-session' `
            -ExecutorSessionId 'session-xyz' `
            -ContractHash ('a' * 64)

        (Test-Path -LiteralPath $created.Path) | Should -Be $true

        $read = Get-GoalRunActiveState -WorktreePath $worktreePath

        $read.arm | Should -Be 'in-session'
        $read.executor_session_id | Should -Be 'session-xyz'
        $read.contract_hash | Should -Be ('a' * 64)
        $read.ceilings.turns | Should -Be 40
        $read.baseline.commit | Should -Be 'abc123'
        $read.teardown_deferred | Should -Be $false
        $read.heartbeat_at | Should -Be $read.launched_at
        [string]::IsNullOrWhiteSpace($read.heartbeat_at) | Should -Be $false
    }

    It 'returns $null when reading a state file that does not exist' {
        $worktreePath = Join-Path $TestDrive 'no-state-worktree'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null

        $read = Get-GoalRunActiveState -WorktreePath $worktreePath

        $read | Should -BeNullOrEmpty
    }

    It 'updates the heartbeat timestamp in place without disturbing other fields' {
        $worktreePath = Join-Path $TestDrive 'heartbeat-update-worktree'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        New-GoalRunActiveState -WorktreePath $worktreePath -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'vendor-only' -ExecutorSessionId 'sid-1' -ContractHash ('b' * 64) | Out-Null

        $before = Get-GoalRunActiveState -WorktreePath $worktreePath
        Start-Sleep -Milliseconds 50

        $updated = Update-GoalRunActiveStateHeartbeat -WorktreePath $worktreePath
        $after = Get-GoalRunActiveState -WorktreePath $worktreePath

        $updated.heartbeat_at | Should -Not -Be $before.heartbeat_at
        $after.heartbeat_at | Should -Be $updated.heartbeat_at
        $after.launched_at | Should -Be $before.launched_at
        $after.arm | Should -Be 'vendor-only'
        $after.executor_session_id | Should -Be 'sid-1'
    }

    It 'throws when updating the heartbeat on a worktree with no state file' {
        $worktreePath = Join-Path $TestDrive 'no-state-heartbeat-worktree'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null

        { Update-GoalRunActiveStateHeartbeat -WorktreePath $worktreePath } | Should -Throw
    }

    It 'sets teardown_deferred and persists it' {
        $worktreePath = Join-Path $TestDrive 'teardown-flag-worktree'
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        New-GoalRunActiveState -WorktreePath $worktreePath -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'vendor-only' -ExecutorSessionId 'sid-2' -ContractHash ('c' * 64) | Out-Null

        Set-GoalRunActiveStateTeardownDeferred -WorktreePath $worktreePath -Value $true | Out-Null
        $after = Get-GoalRunActiveState -WorktreePath $worktreePath

        $after.teardown_deferred | Should -Be $true
    }
}

Describe 'Remove-GoalRunWorktree' -Tag 'unit' {

    It 'removes a real worktree cleanly on the first attempt' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'teardown-clean-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 100

        $result = Remove-GoalRunWorktree -RepoRoot $repo -WorktreePath $provisioned.Path

        $result.Outcome | Should -Be 'removed'
        $result.TeardownDeferred | Should -Be $false
        $result.Attempts | Should -Be 1
        (Test-Path -LiteralPath $provisioned.Path) | Should -Be $false
    }

    It 'retries then defers-and-flags on persistent git worktree remove failure (simulated via a forwarding mock -- never a real corrupted worktree)' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'teardown-defer-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 200
        New-GoalRunActiveState -WorktreePath $provisioned.Path -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-defer' -ContractHash ('d' * 64) | Out-Null

        $mockGitPath = Join-Path $TestDrive 'mock-git-teardown-defer.ps1'
        $counterFile = Join-Path $TestDrive 'mock-git-teardown-defer.counter'
        # FailCount = 10: with the issue #874 PR1 fix, a dirty-only-state-file
        # worktree now issues up to TWO `worktree remove` invocations per
        # bounded attempt (the plain remove, then the state-file-only force
        # escalation) instead of one -- across MaxAttempts=2 that is up to 4
        # real invocations. FailCount must comfortably exceed that so the
        # mock keeps forcing every one of them to fail, proving removal
        # genuinely never succeeds within the retry budget (not just that the
        # mock ran out of forced failures before the budget did).
        script:New-GRMockGitTeardownFailure -Path $mockGitPath -CounterFile $counterFile -FailCount 10

        try {
            $result = Remove-GoalRunWorktree -RepoRoot $repo -WorktreePath $provisioned.Path -GitCliPath $mockGitPath -RetryDelayMs 10 -WarningAction SilentlyContinue

            $result.TeardownDeferred | Should -Be $true
            $result.Attempts | Should -Be 2
            $result.Outcome | Should -Not -BeIn @('removed', 'stale-registration')

            $counterValue = [int](Get-Content -LiteralPath $counterFile -Raw)
            $counterValue | Should -Be 4 -Because 'two bounded attempts, each issuing a plain remove plus the state-file-only force escalation (both fail persistently)'

            $state = Get-GoalRunActiveState -WorktreePath $provisioned.Path
            $state.teardown_deferred | Should -Be $true
        }
        finally {
            script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $provisioned.Path
        }
    }

    It 'retries once after a failed first removal attempt, then succeeds without deferring' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'teardown-retry-succeeds-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 300

        $mockGitPath = Join-Path $TestDrive 'mock-git-teardown-retry-succeeds.ps1'
        $counterFile = Join-Path $TestDrive 'mock-git-teardown-retry-succeeds.counter'
        # FailCount = 1: the first removal attempt fails, the bounded retry succeeds.
        script:New-GRMockGitTeardownFailure -Path $mockGitPath -CounterFile $counterFile -FailCount 1

        try {
            $result = Remove-GoalRunWorktree -RepoRoot $repo -WorktreePath $provisioned.Path -GitCliPath $mockGitPath -RetryDelayMs 10 -WarningAction SilentlyContinue

            $result.Outcome | Should -Be 'removed'
            $result.TeardownDeferred | Should -Be $false
            $result.Attempts | Should -Be 2
            (Test-Path -LiteralPath $provisioned.Path) | Should -Be $false
        }
        finally {
            script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $provisioned.Path
        }
    }

    It 'never force-removes a locked worktree that is still present on disk, on the lock flag alone' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'teardown-locked-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 400
        & git -C $repo worktree lock $provisioned.Path 2>&1 | Out-Null

        try {
            $result = Remove-GoalRunWorktree -RepoRoot $repo -WorktreePath $provisioned.Path -MaxAttempts 1

            $result.Attempts | Should -Be 0 -Because 'a locked, present worktree is never attempted -- manual-review territory'
            $result.TeardownDeferred | Should -Be $true
            (Test-Path -LiteralPath $provisioned.Path) | Should -Be $true -Because 'the locked worktree must remain untouched'
        }
        finally {
            & git -C $repo worktree unlock $provisioned.Path 2>&1 | Out-Null
            script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $provisioned.Path
        }
    }

    It 'removes a routine worktree on the first attempt when the ONLY dirty content is the goal-run state file (issue #874 PR1 fix)' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'teardown-only-state-file-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 700
        New-GoalRunActiveState -WorktreePath $provisioned.Path -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-only-state-file' -ContractHash ('1' * 64) | Out-Null

        try {
            $result = Remove-GoalRunWorktree -RepoRoot $repo -WorktreePath $provisioned.Path

            $result.Outcome | Should -Be 'removed' `
                -Because 'goal-run-active.json is the only untracked content, so a plain-remove refusal must now escalate to --force'
            $result.TeardownDeferred | Should -Be $false
            $result.Attempts | Should -Be 1
            (Test-Path -LiteralPath $provisioned.Path) | Should -Be $false
        }
        finally {
            script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $provisioned.Path
        }
    }

    It 'never force-removes -- and defers as before -- a worktree with EXTRA untracked content beyond the state file' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'teardown-extra-content-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 701
        New-GoalRunActiveState -WorktreePath $provisioned.Path -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-extra-content' -ContractHash ('2' * 64) | Out-Null

        # Simulates the goal loop leaving real, genuine unsaved work behind --
        # this file must never be force-removed, even though the state file
        # alone would now be known-safe.
        $extraFilePath = Join-Path $provisioned.Path 'unsaved-work.txt'
        [System.IO.File]::WriteAllText($extraFilePath, "real work, not yet committed`n", [System.Text.UTF8Encoding]::new($false))

        try {
            $result = Remove-GoalRunWorktree -RepoRoot $repo -WorktreePath $provisioned.Path -RetryDelayMs 10 -MaxAttempts 1

            $result.Outcome | Should -Not -BeIn @('removed', 'stale-registration') `
                -Because 'unexpected untracked content must never be force-removed -- it is not known-safe'
            $result.TeardownDeferred | Should -Be $true
            (Test-Path -LiteralPath $provisioned.Path) | Should -Be $true -Because 'the worktree itself must remain untouched when content is unexpected'
            (Test-Path -LiteralPath $extraFilePath) | Should -Be $true -Because 'the extra untracked file must survive -- proof of non-destruction'
        }
        finally {
            script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $provisioned.Path
        }
    }
}

Describe 'Invoke-GoalRunDeferredTeardownRetry' -Tag 'unit' {
    <#
    .SYNOPSIS
        Issue #874, plan step 3 -- standalone deferred-teardown retry entry
        point. session-cleanup-detector-core.ps1 renders a call to this same
        function; these tests exercise it directly, independent of the
        detector.
    #>

    It 'no-ops with Attempted=$false when no state file exists' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'retry-no-state-repo')
        $bareWorktreeDir = Join-Path $TestDrive 'retry-no-state-worktree'
        New-Item -ItemType Directory -Path $bareWorktreeDir -Force | Out-Null

        $result = Invoke-GoalRunDeferredTeardownRetry -RepoRoot $repo -WorktreePath $bareWorktreeDir

        $result.Attempted | Should -Be $false
        $result.Reason | Should -Be 'no-state-file'
        $result.Outcome | Should -BeNullOrEmpty
    }

    It 'no-ops with Attempted=$false when the state file exists but teardown_deferred is false' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'retry-not-deferred-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 500
        New-GoalRunActiveState -WorktreePath $provisioned.Path -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-not-deferred' -ContractHash ('e' * 64) | Out-Null

        try {
            $result = Invoke-GoalRunDeferredTeardownRetry -RepoRoot $repo -WorktreePath $provisioned.Path

            $result.Attempted | Should -Be $false
            $result.Reason | Should -Be 'not-deferred'
            (Test-Path -LiteralPath $provisioned.Path) | Should -Be $true -Because 'a non-deferred state must never be torn down by this entry point'
        }
        finally {
            script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $provisioned.Path
        }
    }

    It 'retries Remove-GoalRunWorktree and succeeds on first attempt once the mainline untracked-state-file gap is fixed' {
        <#
        Originally discovered while writing this test (issue #874 s3): a real
        `git worktree remove` (without --force) refuses to remove a worktree
        that still has ANY untracked content -- and goal-run-active.json
        itself, sitting inside the worktree it describes, is always untracked
        at teardown time. That made Invoke-GoalRunWorktreeRemovalAttempt's
        default branch (which only escalated to --force when IsPrunable was
        true -- a directory-missing signal, unrelated to "has untracked
        content") come back 'failed'/deferred on essentially every routine,
        healthy teardown. Fixed in issue #874 PR1 by
        Test-GoalRunWorktreeOnlyExpectedContent: when the plain remove fails
        and the ONLY dirty content is the known state file, the removal now
        escalates to --force just as it already did for the prunable case.
        This assertion now proves the mainline case removes cleanly on the
        first attempt; the "extra untracked content is never force-removed"
        half of the fix is covered separately below.
        #>
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'retry-deferred-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 600
        New-GoalRunActiveState -WorktreePath $provisioned.Path -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-retry-succeeds' -ContractHash ('f' * 64) | Out-Null
        Set-GoalRunActiveStateTeardownDeferred -WorktreePath $provisioned.Path -Value $true | Out-Null

        try {
            $result = Invoke-GoalRunDeferredTeardownRetry -RepoRoot $repo -WorktreePath $provisioned.Path -WarningAction SilentlyContinue

            $result.Attempted | Should -Be $true
            $result.Reason | Should -BeNullOrEmpty
            $result.Outcome | Should -Be 'removed' `
                -Because 'goal-run-active.json is the ONLY untracked content, which is now known-safe to force-remove (issue #874 PR1 fix)'
            $result.TeardownDeferred | Should -Be $false
            $result.Attempts | Should -Be 1
            (Test-Path -LiteralPath $provisioned.Path) | Should -Be $false
        }
        finally {
            script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $provisioned.Path
        }
    }

    It 'succeeds when the worktree tree is clean (state file committed, no untracked content)' {
        # Isolates Invoke-GoalRunDeferredTeardownRetry's own dispatch logic
        # from the git worktree removal/force gap documented above -- proves
        # this function's success path DOES work end to end once nothing
        # blocks the underlying git worktree remove.
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'retry-deferred-clean-repo')
        $provisioned = New-GoalRunWorktree -RepoRoot $repo -IssueNumber 601
        New-GoalRunActiveState -WorktreePath $provisioned.Path -Ceilings @{ turns = 10 } -Baseline @{ commit = 'x' } `
            -Arm 'in-session' -ExecutorSessionId 'sid-retry-clean' -ContractHash ('9' * 64) | Out-Null
        Set-GoalRunActiveStateTeardownDeferred -WorktreePath $provisioned.Path -Value $true | Out-Null
        & git -C $provisioned.Path add -A 2>&1 | Out-Null
        & git -C $provisioned.Path commit -q -m 'test-only: commit state file so the tree is clean' 2>&1 | Out-Null

        try {
            $result = Invoke-GoalRunDeferredTeardownRetry -RepoRoot $repo -WorktreePath $provisioned.Path

            $result.Attempted | Should -Be $true
            $result.Outcome | Should -Be 'removed'
            $result.TeardownDeferred | Should -Be $false
            (Test-Path -LiteralPath $provisioned.Path) | Should -Be $false
        }
        finally {
            script:Remove-GRTestWorktree -RepoRoot $repo -WorktreePath $provisioned.Path
        }
    }

    It 'never throws when Get-GoalRunActiveState itself would fail (unreadable state path)' {
        $repo = script:New-GRTestRepo -Path (Join-Path $TestDrive 'retry-unreadable-repo')
        $bogusWorktreeDir = Join-Path $TestDrive 'retry-unreadable-does-not-exist'

        { Invoke-GoalRunDeferredTeardownRetry -RepoRoot $repo -WorktreePath $bogusWorktreeDir } | Should -Not -Throw
    }
}
