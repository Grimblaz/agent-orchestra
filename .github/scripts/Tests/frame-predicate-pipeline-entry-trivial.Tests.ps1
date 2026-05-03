#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# RED tests for changeset.isPipelineEntryTrivial predicate (issue #442, Step 3a).
#
# This predicate identifies small, safe pipeline-entry changesets that do not
# touch production source code.
#
# Returns TRUE when:
# - TotalLines < 50
# - Changed file count <= 3
# - Changeset does not touch source (tests, docs, pipeline files only)
#
# Returns FALSE when any of the above conditions fail.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:PredicateCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'
    if (Test-Path $script:PredicateCoreLib) {
        . $script:PredicateCoreLib
    }

    # Helper: build a minimal changeset hashtable.
    function script:New-CS {
        param(
            [string[]]$Files = @(),
            [int]$TotalLines = 10
        )
        return @{
            ChangedFiles = $Files
            TotalLines   = $TotalLines
        }
    }
}

# ---------------------------------------------------------------------------
# Registration -- identifier must be supported
# ---------------------------------------------------------------------------

Describe 'changeset.isPipelineEntryTrivial registration (Step 3a)' {

    It 'includes changeset.isPipelineEntryTrivial in the supported identifier list' {
        $supported = Get-FVSupportedChangesetIdentifiers
        $supported | Should -Contain 'changeset.isPipelineEntryTrivial'
    }

    It 'parses the identifier without returning ParseError' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $ast | Should -Not -BeNullOrEmpty
        $ast.Kind | Should -Not -Be 'ParseError'
        $ast.Name | Should -Be 'changeset.isPipelineEntryTrivial'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- small safe changes
# ---------------------------------------------------------------------------

Describe 'changeset.isPipelineEntryTrivial returns TRUE' {

    It 'returns true when TotalLines=30, 2 test files, no source touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            '.github/scripts/Tests/foo.Tests.ps1',
            '.github/scripts/Tests/bar.Tests.ps1'
        ) -TotalLines 30

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when TotalLines=49, 3 doc files, no source touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            'Documents/Design/foo.md',
            'Documents/Decisions/bar.md',
            'README.md'
        ) -TotalLines 49

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true at the exact boundary: TotalLines=49, 3 files, no source' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            'Documents/Design/a.md',
            'Documents/Design/b.md',
            'Documents/Design/c.md'
        ) -TotalLines 49

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- TotalLines threshold
# ---------------------------------------------------------------------------

Describe 'changeset.isPipelineEntryTrivial returns FALSE when TotalLines >= 50' {

    It 'returns false when TotalLines=50 (at threshold), 2 test files' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            '.github/scripts/Tests/foo.Tests.ps1',
            '.github/scripts/Tests/bar.Tests.ps1'
        ) -TotalLines 50

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when TotalLines=100, 1 doc file' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            'Documents/Design/large.md'
        ) -TotalLines 100

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- file count threshold
# ---------------------------------------------------------------------------

Describe 'changeset.isPipelineEntryTrivial returns FALSE when file count > 3' {

    It 'returns false when 4 test files are changed, TotalLines=30' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            '.github/scripts/Tests/a.Tests.ps1',
            '.github/scripts/Tests/b.Tests.ps1',
            '.github/scripts/Tests/c.Tests.ps1',
            '.github/scripts/Tests/d.Tests.ps1'
        ) -TotalLines 30

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when 5 doc files are changed, TotalLines=20' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            'Documents/Design/a.md',
            'Documents/Design/b.md',
            'Documents/Design/c.md',
            'Documents/Design/d.md',
            'Documents/Design/e.md'
        ) -TotalLines 20

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- source touched
# ---------------------------------------------------------------------------

Describe 'changeset.isPipelineEntryTrivial returns FALSE when source is touched' {

    It 'returns false when a production PowerShell script is touched, TotalLines=10, 1 file' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            '.github/scripts/bump-version.ps1'
        ) -TotalLines 10

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when mixed source and test files are touched, TotalLines=25, 3 files' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            '.github/scripts/lib/frame-predicate-core.ps1',
            '.github/scripts/Tests/foo.Tests.ps1',
            'Documents/Design/bar.md'
        ) -TotalLines 25

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when workflow YAML is touched, TotalLines=10, 1 file (preserves changeset.touchesSource semantics)' {
        # Rationale: existing changeset.touchesSource treats .github/workflows/*.yml
        # as source (not docs, not tests, not temp artifacts), so this predicate
        # must return FALSE for workflow changes even if they are small.
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            '.github/workflows/ci.yml'
        ) -TotalLines 10

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# Existing changeset.touchesSource semantics preservation
# ---------------------------------------------------------------------------

Describe 'changeset.isPipelineEntryTrivial follows existing changeset.touchesSource semantics for Markdown' {

    It 'returns true when agent .md files are changed (preserves shipped doc-classification semantics), TotalLines=20, 2 files' {
        # Rationale: existing changeset.touchesSource treats all .md files as
        # docs via Test-FVPathIsDoc. This test validates that
        # isPipelineEntryTrivial follows the same shipped semantics, NOT
        # plugin-aware source logic.
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            'agents/Code-Smith.agent.md',
            'Documents/Design/foo.md'
        ) -TotalLines 20

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when skill .md files are changed (preserves shipped doc-classification semantics), TotalLines=15, 1 file' {
        # Rationale: existing changeset.touchesSource treats all .md files as
        # docs via Test-FVPathIsDoc. This test validates that
        # isPipelineEntryTrivial follows the same shipped semantics, NOT
        # plugin-aware source logic.
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            'skills/test-driven-development/SKILL.md'
        ) -TotalLines 15

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when command .md files are changed (preserves shipped doc-classification semantics), TotalLines=10, 1 file' {
        # Rationale: existing changeset.touchesSource treats all .md files as
        # docs via Test-FVPathIsDoc. This test validates that
        # isPipelineEntryTrivial follows the same shipped semantics, NOT
        # plugin-aware source logic.
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            'commands/orchestrate.md'
        ) -TotalLines 10

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

Describe 'changeset.isPipelineEntryTrivial edge cases' {

    It 'returns true when ChangedFiles is empty (0 files), TotalLines=0' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @() -TotalLines 0

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns false when TotalLines is exactly 50 at the boundary' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.isPipelineEntryTrivial'
        $cs = script:New-CS -Files @(
            'Documents/Design/a.md'
        ) -TotalLines 50

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}
