#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for the `never` identifier in the predicate DSL (issue #443, Step 1).
#
# `never` is a deterministic-false bare identifier used by deferred
# trigger-conditional ports (e.g. process-retrospective) whose trigger
# predicate is not yet authored.  It must resolve to Result='false' rather
# than 'unknown', so the port is excluded from the coverage denominator
# without emitting a deferred-unknown warning.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:PredicateCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'
    if (Test-Path $script:PredicateCoreLib) {
        . $script:PredicateCoreLib
    }

    function script:New-CS {
        param([string[]]$Files = @(), [int]$TotalLines = 10)
        return @{ ChangedFiles = $Files; TotalLines = $TotalLines; IsReReview = $false; IsProxyGithub = $false; JudgeScore = $null }
    }

    function script:Parse-And-Eval {
        param([string]$Predicate)
        $ast = ConvertTo-FVPredicate -Predicate $Predicate
        return Test-FVPredicateAgainstChangeset -Ast $ast -Changeset (script:New-CS)
    }
}

Describe 'never identifier' {
    It 'resolves bare never identifier to Result=false' {
        $result = script:Parse-And-Eval -Predicate 'never'
        $result.Result | Should -Be 'false'
    }

    It 'reason string contains deterministic-false' {
        $result = script:Parse-And-Eval -Predicate 'never'
        $result.Reason | Should -BeLike '*deterministic false*'
    }

    It 'result is not unknown — no deferred-unknown warning emitted' {
        $result = script:Parse-And-Eval -Predicate 'never'
        $result.Result | Should -Not -Be 'unknown'
    }

    It 'NOT never resolves to true' {
        $result = script:Parse-And-Eval -Predicate 'NOT never'
        $result.Result | Should -Be 'true'
    }

    It 'never AND changeset.touches resolves to false (short-circuits)' {
        $result = script:Parse-And-Eval -Predicate 'never AND changeset.touches'
        $result.Result | Should -Be 'false'
    }

    It 'never OR never resolves to false' {
        $result = script:Parse-And-Eval -Predicate 'never OR never'
        $result.Result | Should -Be 'false'
    }

    It 'Test-FVPredicateAgainstChangeset with applies-when never returns false' {
        $ast = ConvertTo-FVPredicate -Predicate 'never'
        $cs = script:New-CS -Files @('agents/Process-Review.agent.md')
        $result = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $result.Result | Should -Be 'false'
    }
}
