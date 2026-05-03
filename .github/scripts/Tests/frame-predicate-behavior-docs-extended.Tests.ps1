#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# TDD tests for changeset.touchesBehaviorOrInterfaceDocsExtended predicate (issue #442, Step 3d).
#
# Returns TRUE when the changeset touches docs that carry behavioral or interface intent:
#   - Documents/** (design/decision docs)
#   - **/SKILL.md
#   - **/*.agent.md
#   - commands/**/*.md
#   - README.md
#   - CLAUDE.md
#
# Returns FALSE for other top-level *.md (CHANGELOG.md, CONTRIBUTING.md, CUSTOMIZATION.md)
# and source *.ps1 files.
#
# Distinct from shipped changeset.changesBehaviorOrInterface (different semantics).

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

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended registration (Step 3d)' {

    It 'includes changeset.touchesBehaviorOrInterfaceDocsExtended in the supported identifier list' {
        $supported = Get-FVSupportedChangesetIdentifiers
        $supported | Should -Contain 'changeset.touchesBehaviorOrInterfaceDocsExtended'
    }

    It 'parses the identifier without returning ParseError' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $ast | Should -Not -BeNullOrEmpty
        $ast.Kind | Should -Not -Be 'ParseError'
        $ast.Name | Should -Be 'changeset.touchesBehaviorOrInterfaceDocsExtended'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- Documents/**
# ---------------------------------------------------------------------------

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended returns TRUE for Documents/**' {

    It 'returns true when touching Documents/Design/foo.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('Documents/Design/foo.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when touching Documents/Decisions/bar.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('Documents/Decisions/bar.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- **/SKILL.md
# ---------------------------------------------------------------------------

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended returns TRUE for SKILL.md files' {

    It 'returns true when touching skills/test-driven-development/SKILL.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('skills/test-driven-development/SKILL.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when touching skills/frame-credit-emission/SKILL.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('skills/frame-credit-emission/SKILL.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- **/*.agent.md
# ---------------------------------------------------------------------------

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended returns TRUE for *.agent.md files' {

    It 'returns true when touching agents/Code-Smith.agent.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('agents/Code-Smith.agent.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when touching agents/Experience-Owner.agent.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('agents/Experience-Owner.agent.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- commands/**/*.md
# ---------------------------------------------------------------------------

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended returns TRUE for commands/**/*.md' {

    It 'returns true when touching commands/orchestrate.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('commands/orchestrate.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when touching commands/plan.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('commands/plan.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# TRUE cases -- README.md and CLAUDE.md
# ---------------------------------------------------------------------------

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended returns TRUE for README.md and CLAUDE.md' {

    It 'returns true when touching README.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('README.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when touching CLAUDE.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('CLAUDE.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- excluded top-level *.md files
# ---------------------------------------------------------------------------

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended returns FALSE for excluded top-level *.md' {

    It 'returns false when touching CHANGELOG.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('CHANGELOG.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when touching CONTRIBUTING.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('CONTRIBUTING.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when touching CUSTOMIZATION.md' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('CUSTOMIZATION.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- source PS1 files
# ---------------------------------------------------------------------------

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended returns FALSE for source PS1 files' {

    It 'returns false when only a lib PS1 source file is touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('.github/scripts/lib/frame-predicate-core.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when only PS1 test files are touched' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @('.github/scripts/Tests/frame-predicate.Tests.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# FALSE cases -- empty changeset
# ---------------------------------------------------------------------------

Describe 'changeset.touchesBehaviorOrInterfaceDocsExtended returns FALSE for empty changeset' {

    It 'returns false when ChangedFiles is empty' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesBehaviorOrInterfaceDocsExtended'
        $cs = script:New-CS -Files @()

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }
}

# ---------------------------------------------------------------------------
# Shipped changeset.changesBehaviorOrInterface semantics NOT modified
# ---------------------------------------------------------------------------

Describe 'shipped changeset.changesBehaviorOrInterface semantics preserved' {

    It 'changesBehaviorOrInterface still returns false when only MD files touched (shipped semantics)' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.changesBehaviorOrInterface'
        $cs = script:New-CS -Files @('README.md', 'CLAUDE.md')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'changesBehaviorOrInterface still returns true when source touched (shipped semantics)' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.changesBehaviorOrInterface'
        $cs = script:New-CS -Files @('.github/scripts/lib/frame-predicate-core.ps1')

        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }
}
