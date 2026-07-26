#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for .github/scripts/lib/goal-run-predicate-core.ps1 (issue
    #874, M1 fix: wires the launch-pinned contract-hash check into the
    vendor /goal loop live predicate command).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-predicate-core.ps1'
    . $script:LibPath

    $script:PinnedHash = ('a' * 64)

    function script:New-StubActiveStateReader {
        param([string]$ContractHash = $script:PinnedHash)
        return { param($WorktreePath) [pscustomobject]@{ contract_hash = $ContractHash } }.GetNewClosure()
    }
}

Describe 'goal-run-predicate-core.ps1: lib resolves' -Tag 'unit' {
    It 'exists at the expected path' {
        (Test-Path -LiteralPath $script:LibPath) | Should -Be $true
    }
}

Describe 'Invoke-GoalRunPredicateEvaluate' -Tag 'unit' {

    It 'halts with invariant-conflict on a launch-pinned-hash mismatch and does NOT proceed to the validator check' {
        $activeStateReader = script:New-StubActiveStateReader
        $script:resolverCallCount = 0
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            $script:resolverCallCount++
            [pscustomobject]@{ Disposition = 'halt'; HaltReason = 'invariant-conflict'; Reason = 'contract-hash-mismatch-since-launch'; ExitCode = $null; ValidatorRan = $false }
        }
        $script:haltEmitCalls = @()
        $haltEmitter = {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            $script:haltEmitCalls += , $Report
            [pscustomobject]@{ Success = $true; Url = 'https://example.invalid/comment/1' }
        }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter

        $result.ExitCode | Should -Be 2
        $result.Disposition | Should -Be 'halt'
        $result.HaltReason | Should -Be 'invariant-conflict'
        $result.HaltEmitted | Should -Be $true
        $result.ValidatorRan | Should -Be $false

        # The resolver itself (Resolve-GoalRunLoopPredicate in production)
        # is what short-circuits before invoking the validator -- this
        # asserts this evaluator does not add a SECOND validator call on
        # top of whatever the resolver already decided.
        $script:resolverCallCount | Should -Be 1
        $script:haltEmitCalls.Count | Should -Be 1
        $script:haltEmitCalls[0].halt_reason | Should -Be 'invariant-conflict'
    }

    It 'proceeds normally and reports satisfied (ExitCode 0) when the launch-pinned hash matches' {
        $activeStateReader = script:New-StubActiveStateReader
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            $LaunchPinnedHash | Should -Be $script:PinnedHash
            [pscustomobject]@{ Disposition = 'satisfied'; HaltReason = $null; Reason = $null; ExitCode = 0; ValidatorRan = $true }
        }
        $script:haltEmitCalledForMatch = $false
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) $script:haltEmitCalledForMatch = $true }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter

        $result.ExitCode | Should -Be 0
        $result.Disposition | Should -Be 'satisfied'
        $result.HaltEmitted | Should -Be $false
        $script:haltEmitCalledForMatch | Should -Be $false
    }

    It 'F15(a): refreshes the in-loop heartbeat exactly once per iteration' {
        $activeStateReader = script:New-StubActiveStateReader
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            [pscustomobject]@{ Disposition = 'not-satisfied'; HaltReason = $null; Reason = $null; ExitCode = 1; ValidatorRan = $true }
        }
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) }
        $script:heartbeatCallCount = 0
        $script:heartbeatPath = $null
        $heartbeatRefresher = {
            param($WorktreePath)
            $script:heartbeatCallCount++
            $script:heartbeatPath = $WorktreePath
        }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter -HeartbeatRefresher $heartbeatRefresher

        $script:heartbeatCallCount | Should -Be 1
        $script:heartbeatPath | Should -Be 'C:\gr-874-token'
        $result.HeartbeatRefreshed | Should -Be $true
        # The verdict is unaffected by the heartbeat wiring.
        $result.ExitCode | Should -Be 1
    }

    It 'F15(a): a failed heartbeat refresh never changes the predicate verdict (best-effort)' {
        $activeStateReader = script:New-StubActiveStateReader
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            [pscustomobject]@{ Disposition = 'satisfied'; HaltReason = $null; Reason = $null; ExitCode = 0; ValidatorRan = $true }
        }
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) }
        $throwingRefresher = { param($WorktreePath) throw 'no state file found' }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter -HeartbeatRefresher $throwingRefresher

        $result.ExitCode | Should -Be 0
        $result.Disposition | Should -Be 'satisfied'
        $result.HeartbeatRefreshed | Should -Be $false
    }

    It 'reports ExitCode 1 (not-satisfied) without emitting a halt report when the validator ran and targets are not yet met' {
        $activeStateReader = script:New-StubActiveStateReader
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            [pscustomobject]@{ Disposition = 'not-satisfied'; HaltReason = $null; Reason = $null; ExitCode = 1; ValidatorRan = $true }
        }
        $script:notSatisfiedHaltEmitterCalled = $false
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) $script:notSatisfiedHaltEmitterCalled = $true }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter

        $result.ExitCode | Should -Be 1
        $result.Disposition | Should -Be 'not-satisfied'
        $result.HaltEmitted | Should -Be $false
        $script:notSatisfiedHaltEmitterCalled | Should -Be $false
    }

    It 'reports ExitCode 2 and emits a halt report on a validator-side halt (e.g. refused / infra error), distinct from a pin mismatch' {
        $activeStateReader = script:New-StubActiveStateReader
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            [pscustomobject]@{ Disposition = 'halt'; HaltReason = 'chain-stage-failure'; Reason = 'infra-error: worktree session threw'; ExitCode = 3; ValidatorRan = $true }
        }
        $script:haltReasonSeen = $null
        # #912 s1: return a real emitter-shaped Success object (not nothing) so
        # this assertion survives plan step 7's change to read .Success instead
        # of unconditionally setting HaltEmitted = $true.
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) $script:haltReasonSeen = $Report.halt_reason; [pscustomobject]@{ Success = $true; Url = 'https://example.invalid/comment/2' } }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter

        $result.ExitCode | Should -Be 2
        $result.HaltEmitted | Should -Be $true
        $script:haltReasonSeen | Should -Be 'chain-stage-failure'
    }

    It 'fails closed (ExitCode 2, halt) and emits a halt report when goal-run-active.json cannot be read at all' {
        $activeStateReader = { param($WorktreePath) $null }
        $script:resolverCalledForMissingState = $false
        $resolver = { param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath) $script:resolverCalledForMissingState = $true; [pscustomobject]@{ Disposition = 'satisfied'; HaltReason = $null; Reason = $null; ExitCode = 0; ValidatorRan = $true } }
        $script:haltEmittedForMissingState = $false
        # #912 s1: return a real emitter-shaped Success object (not nothing) so
        # this assertion survives plan step 7's change to read .Success instead
        # of unconditionally setting HaltEmitted = $true.
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) $script:haltEmittedForMissingState = $true; [pscustomobject]@{ Success = $true; Url = 'https://example.invalid/comment/3' } }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter

        $result.ExitCode | Should -Be 2
        $result.Disposition | Should -Be 'halt'
        $result.Reason | Should -Be 'goal-run-active-state-unreadable'
        $result.HaltEmitted | Should -Be $true
        $script:resolverCalledForMissingState | Should -Be $false -Because 'the pin check has no hash to compare against without the active-state file'
        $script:haltEmittedForMissingState | Should -Be $true
    }

    It '#912 AC12: does not report HaltEmitted = $true when the halt emitter itself fails to post (the modal Find-OrUpsertComment gh-failure path)' {
        $activeStateReader = script:New-StubActiveStateReader
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            [pscustomobject]@{ Disposition = 'halt'; HaltReason = 'chain-stage-failure'; Reason = 'infra-error: worktree session threw'; ExitCode = 3; ValidatorRan = $true }
        }
        # Find-OrUpsertComment returns $null without throwing on every gh
        # failure path (find-or-upsert-comment.ps1:152-153, 183-184, 208-209,
        # 246-247) -- this is the modal failure a try/catch around the emit
        # call never sees, so a real emitter surfaces it as Success = $false.
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) [pscustomobject]@{ Success = $false; Url = $null } }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter

        $result.ExitCode | Should -Be 2
        $result.HaltEmitted | Should -Be $false -Because 'the emit itself failed, so reporting HaltEmitted = $true would be a false success claim'
    }

    It '#912 AC12: does not report HaltEmitted = $true when the halt emitter returns bare $null' {
        $activeStateReader = script:New-StubActiveStateReader
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            [pscustomobject]@{ Disposition = 'halt'; HaltReason = 'chain-stage-failure'; Reason = 'infra-error: worktree session threw'; ExitCode = 3; ValidatorRan = $true }
        }
        # A caller-supplied emitter that returns nothing at all (not even a
        # Success=$false object) must not crash the .Success read nor be
        # treated as a successful emit.
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) }

        $result = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter

        $result.ExitCode | Should -Be 2
        $result.HaltEmitted | Should -Be $false -Because 'a bare $null return carries no proof of a successful post'
    }

    It '#912 AC12: a schema-invalid report (HaltEmitter throws) does not propagate, and the halt disposition is preserved with HaltEmitted = $false' {
        $activeStateReader = script:New-StubActiveStateReader
        $resolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            [pscustomobject]@{ Disposition = 'halt'; HaltReason = 'chain-stage-failure'; Reason = 'infra-error: worktree session threw'; ExitCode = 3; ValidatorRan = $true }
        }
        # Mirrors Invoke-GoalRunHaltEmit's real refusal throw
        # (goal-run-halt-core.ps1:218) when Test-GoalRunHaltReport rejects the
        # report object -- this must not propagate out of
        # Invoke-GoalRunPredicateEvaluate.
        $haltEmitter = { param($Report, $Issue, $RepoRoot, $Owner, $Repo) throw 'Invoke-GoalRunHaltEmit: refusing to post an invalid halt-report object -- schema violation' }

        { $script:acSchemaInvalidResult = Invoke-GoalRunPredicateEvaluate -Issue 874 -RepoRoot 'C:\gr-874-token' -ActiveStateReader $activeStateReader -PredicateResolver $resolver -HaltEmitter $haltEmitter } | Should -Not -Throw

        $script:acSchemaInvalidResult.ExitCode | Should -Be 2
        $script:acSchemaInvalidResult.Disposition | Should -Be 'halt'
        $script:acSchemaInvalidResult.HaltReason | Should -Be 'chain-stage-failure' -Because 'the halt disposition is computed from the resolver result, not the emit outcome, and must survive the emitter throwing'
        $script:acSchemaInvalidResult.HaltEmitted | Should -Be $false -Because 'the emit itself threw, so it never posted'
    }
}
