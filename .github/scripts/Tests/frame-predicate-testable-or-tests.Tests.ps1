#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# TDD tests for changeset.touchesTestableCodeOrTests predicate (issue #442, Step 3b).
#
# This predicate is the union of testable-source and test-path detection.
# It returns TRUE when the changeset touches:
#   - Any *.ps1 file (whether source or test), OR
#   - Any file in a *Tests/* path
#
# This is distinct from the shipped changeset.touchesTestableCode, which returns
# true only for PS1 source files (excluding *Tests/* paths).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:PredicateCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'
    if (Test-Path $script:PredicateCoreLib) {
        . $script:PredicateCoreLib
    }

    function script:New-CS {
        param([string[]]$Files = @())
        return @{ ChangedFiles = $Files }
    }
}

# ---------------------------------------------------------------------------
# Registration -- identifier must be supported
# ---------------------------------------------------------------------------

Describe 'changeset.touchesTestableCodeOrTests registration (Step 3b)' {

    It 'includes changeset.touchesTestableCodeOrTests in the supported identifier list' {
        $supported = Get-FVSupportedChangesetIdentifiers
        $supported | Should -Contain 'changeset.touchesTestableCodeOrTests'
    }

    It 'parses the identifier without returning ParseError' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $ast | Should -Not -BeNullOrEmpty
        $ast.Kind | Should -Not -Be 'ParseError'
        $ast.Name | Should -Be 'changeset.touchesTestableCodeOrTests'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- PS1 source files (non-test)
# ---------------------------------------------------------------------------

Describe 'changeset.touchesTestableCodeOrTests returns TRUE for PS1 source files' {

    It 'returns true when a lib PS1 source file is touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @('.github/scripts/lib/frame-predicate-core.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when a top-level scripts PS1 file is touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @('.github/scripts/bump-version.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- test path files
# ---------------------------------------------------------------------------

Describe 'changeset.touchesTestableCodeOrTests returns TRUE for test path files' {

    It 'returns true when a PS1 test file is touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @('.github/scripts/Tests/frame-predicate.Tests.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when a non-PS1 fixture file in Tests is touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @('.github/scripts/Tests/fixtures/sample.json')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when a mix of doc and test files is touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @(
            'Documents/Design/foo.md',
            '.github/scripts/Tests/bar.Tests.ps1'
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- non-PS1, non-test files
# ---------------------------------------------------------------------------

Describe 'changeset.touchesTestableCodeOrTests returns FALSE when no PS1 or test files' {

    It 'returns false when only doc files are touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @(
            'Documents/Design/foo.md',
            'Documents/Decisions/bar.md'
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when only agent MD files are touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @('agents/Code-Smith.agent.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when only skill YAML/SKILL.md files are touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @(
            'skills/frame-credit-emission/SKILL.md',
            'skills/plan-authoring/SKILL.md'
        )

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when ChangedFiles is empty' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCodeOrTests'
        $cs = script:New-CS -Files @()

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# Shipped changeset.touchesTestableCode is NOT modified
# ---------------------------------------------------------------------------

Describe 'shipped changeset.touchesTestableCode semantics preserved' {

    It 'touchesTestableCode still returns false for PS1 test files (shipped semantics unchanged)' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCode'
        $cs = script:New-CS -Files @('.github/scripts/Tests/frame-predicate.Tests.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'touchesTestableCode still returns true for PS1 source files (shipped semantics unchanged)' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesTestableCode'
        $cs = script:New-CS -Files @('.github/scripts/lib/frame-predicate-core.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}
