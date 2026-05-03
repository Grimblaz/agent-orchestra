#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# TDD tests for changeset.touchedAreaHasDebt predicate (issue #442, Step 3c).
#
# Returns TRUE when any file in the changeset has:
#   - LineCount > 300 (default threshold), OR
#   - MaxComplexity > 10 (default threshold)
#
# File metadata is supplied via the changeset's FileMetadata field
# (array of hashtables with Path, LineCount, MaxComplexity keys).
# If FileMetadata is absent or empty, returns false (no debt data = no debt).
# Default thresholds: lineCount=300, complexity=10.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:PredicateCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'
    if (Test-Path $script:PredicateCoreLib) {
        . $script:PredicateCoreLib
    }

    function script:New-CS {
        param(
            [string[]]$Files = @(),
            [object[]]$FileMetadata = $null
        )
        $cs = @{ ChangedFiles = $Files }
        if ($null -ne $FileMetadata) { $cs['FileMetadata'] = $FileMetadata }
        return $cs
    }
}

# ---------------------------------------------------------------------------
# Registration -- identifier must be supported
# ---------------------------------------------------------------------------

Describe 'changeset.touchedAreaHasDebt registration (Step 3c)' {

    It 'includes changeset.touchedAreaHasDebt in the supported identifier list' {
        $supported = Get-FVSupportedChangesetIdentifiers
        $supported | Should -Contain 'changeset.touchedAreaHasDebt'
    }

    It 'parses the identifier without returning ParseError' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $ast | Should -Not -BeNullOrEmpty
        $ast.Kind | Should -Not -Be 'ParseError'
        $ast.Name | Should -Be 'changeset.touchedAreaHasDebt'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- line count threshold
# ---------------------------------------------------------------------------

Describe 'changeset.touchedAreaHasDebt returns TRUE when LineCount exceeds threshold' {

    It 'returns true when a file has LineCount=301 (above default 300)' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('some/file.ps1') -FileMetadata @(
            @{ Path = 'some/file.ps1'; LineCount = 301; MaxComplexity = 5 }
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when a file has LineCount=1000, well above threshold' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('some/file.ps1') -FileMetadata @(
            @{ Path = 'some/file.ps1'; LineCount = 1000; MaxComplexity = 3 }
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when one of multiple files has LineCount > 300' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('small.ps1', 'large.ps1') -FileMetadata @(
            @{ Path = 'small.ps1'; LineCount = 50; MaxComplexity = 2 }
            @{ Path = 'large.ps1'; LineCount = 500; MaxComplexity = 3 }
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- cyclomatic complexity threshold
# ---------------------------------------------------------------------------

Describe 'changeset.touchedAreaHasDebt returns TRUE when MaxComplexity exceeds threshold' {

    It 'returns true when a file has MaxComplexity=11 (above default 10)' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('some/file.ps1') -FileMetadata @(
            @{ Path = 'some/file.ps1'; LineCount = 100; MaxComplexity = 11 }
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when a file has MaxComplexity=25, well above threshold' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('some/file.ps1') -FileMetadata @(
            @{ Path = 'some/file.ps1'; LineCount = 50; MaxComplexity = 25 }
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- both axes within threshold
# ---------------------------------------------------------------------------

Describe 'changeset.touchedAreaHasDebt returns FALSE when all files within thresholds' {

    It 'returns false when LineCount=300 (at boundary, not above), MaxComplexity=10 (at boundary)' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('some/file.ps1') -FileMetadata @(
            @{ Path = 'some/file.ps1'; LineCount = 300; MaxComplexity = 10 }
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when LineCount=100 and MaxComplexity=5 (both well within threshold)' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('some/file.ps1') -FileMetadata @(
            @{ Path = 'some/file.ps1'; LineCount = 100; MaxComplexity = 5 }
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when multiple files all within thresholds' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('a.ps1', 'b.ps1') -FileMetadata @(
            @{ Path = 'a.ps1'; LineCount = 200; MaxComplexity = 8 }
            @{ Path = 'b.ps1'; LineCount = 150; MaxComplexity = 4 }
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- no FileMetadata
# ---------------------------------------------------------------------------

Describe 'changeset.touchedAreaHasDebt returns FALSE when no FileMetadata' {

    It 'returns false when FileMetadata is absent from the changeset' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('.github/scripts/lib/frame-predicate-core.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when FileMetadata is an empty array' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @('.github/scripts/lib/frame-predicate-core.ps1') -FileMetadata @()

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when ChangedFiles is empty and FileMetadata is absent' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchedAreaHasDebt'
        $cs = script:New-CS -Files @()

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# Resolver function: custom thresholds
# ---------------------------------------------------------------------------

Describe 'Resolve-FVChangesetTouchedAreaHasDebt accepts custom threshold hashtable' {

    It 'returns true when LineCount exceeds a custom lower threshold of 50' {
        $cs = @{
            ChangedFiles = @('some/file.ps1')
            FileMetadata = @(
                @{ Path = 'some/file.ps1'; LineCount = 75; MaxComplexity = 3 }
            )
        }
        $result = Resolve-FVChangesetTouchedAreaHasDebt -Changeset $cs -Threshold @{ lineCount = 50; complexity = 10 }
        $result | Should -Be $true
    }

    It 'returns false when LineCount=75 and custom threshold is 100 (not exceeded)' {
        $cs = @{
            ChangedFiles = @('some/file.ps1')
            FileMetadata = @(
                @{ Path = 'some/file.ps1'; LineCount = 75; MaxComplexity = 3 }
            )
        }
        $result = Resolve-FVChangesetTouchedAreaHasDebt -Changeset $cs -Threshold @{ lineCount = 100; complexity = 10 }
        $result | Should -Be $false
    }
}
