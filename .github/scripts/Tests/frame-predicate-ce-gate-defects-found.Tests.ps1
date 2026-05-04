#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for the ceGate.defectsFound runtime resolver (issue #443, Step 2).
#
# ceGate.defectsFound is registered as a deferred-credit-reference identifier
# (no static resolver).  When the changeset carries a CeGate block with a
# DefectsFound field, Resolve-CeGateDefectsFound extracts the numeric value
# and returns it for comparison evaluation.  When no CeGate block is present,
# the identifier falls through to the existing deferred-unknown path.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:PredicateCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'
    if (Test-Path $script:PredicateCoreLib) {
        . $script:PredicateCoreLib
    }

    function script:New-CS {
        param(
            [string[]]$Files = @(),
            [int]$TotalLines = 10,
            [object]$CeGate = $null
        )
        $cs = @{
            ChangedFiles  = $Files
            TotalLines    = $TotalLines
            IsReReview    = $false
            IsProxyGithub = $false
            JudgeScore    = $null
        }
        if ($null -ne $CeGate) { $cs['CeGate'] = $CeGate }
        return $cs
    }

    function script:Eval {
        param([string]$Predicate, [object]$CeGate = $null)
        $ast = ConvertTo-FVPredicate -Predicate $Predicate
        $cs  = script:New-CS -CeGate $CeGate
        return Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
    }
}

Describe 'Resolve-CeGateDefectsFound' {
    Context 'direct function tests' {
        It 'returns $null when changeset has no CeGate key' {
            $result = Resolve-CeGateDefectsFound -Changeset (script:New-CS)
            $result | Should -BeNullOrEmpty
        }

        It 'returns integer when CeGate.DefectsFound present (hashtable changeset)' {
            $cs = script:New-CS -CeGate @{ DefectsFound = 3 }
            $result = Resolve-CeGateDefectsFound -Changeset $cs
            $result | Should -Be 3
        }

        It 'returns 0 when DefectsFound is 0' {
            $cs = script:New-CS -CeGate @{ DefectsFound = 0 }
            $result = Resolve-CeGateDefectsFound -Changeset $cs
            $result | Should -Be 0
        }

        It 'returns $null when CeGate block lacks DefectsFound field' {
            $cs = script:New-CS -CeGate @{ OtherField = 'value' }
            $result = Resolve-CeGateDefectsFound -Changeset $cs
            $result | Should -BeNullOrEmpty
        }

        It 'works with pscustomobject CeGate' {
            $cs = script:New-CS -CeGate ([pscustomobject]@{ DefectsFound = 5 })
            $result = Resolve-CeGateDefectsFound -Changeset $cs
            $result | Should -Be 5
        }
    }

    Context 'end-to-end predicate evaluation' {
        It 'ceGate.defectsFound > 0 is true when DefectsFound = 2' {
            $result = script:Eval -Predicate 'ceGate.defectsFound > 0' -CeGate @{ DefectsFound = 2 }
            $result.Result | Should -Be 'true'
        }

        It 'ceGate.defectsFound > 0 is false when DefectsFound = 0' {
            $result = script:Eval -Predicate 'ceGate.defectsFound > 0' -CeGate @{ DefectsFound = 0 }
            $result.Result | Should -Be 'false'
        }

        It 'ceGate.defectsFound > 0 is unknown when no CeGate data' {
            $result = script:Eval -Predicate 'ceGate.defectsFound > 0' -CeGate $null
            $result.Result | Should -Be 'unknown'
        }

        It 'reason string contains deferred-credit-reference-identifier when no CeGate' {
            $result = script:Eval -Predicate 'ceGate.defectsFound > 0' -CeGate $null
            $result.Reason | Should -BeLike '*deferred-credit-reference-identifier*'
        }

        It 'ceGate.defectsFound == 0 is true when DefectsFound = 0' {
            $result = script:Eval -Predicate 'ceGate.defectsFound == 0' -CeGate @{ DefectsFound = 0 }
            $result.Result | Should -Be 'true'
        }
    }
}
