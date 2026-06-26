#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'frame-architecture.md anchor presence' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DocPath = Join-Path $script:RepoRoot 'Documents/Design/frame-architecture.md'
        $script:DocContent = if (Test-Path $script:DocPath) { Get-Content -Raw -Path $script:DocPath } else { '' }
    }

    It 'contains the d14-reification-contract anchor (AC10)' {
        $script:DocPath | Should -Exist
        $script:DocContent | Should -Match '<!-- d14-reification-contract -->'
    }

    It 'contains the D14 Sub-Issue Reification Contract section heading' {
        $script:DocContent | Should -Match '## Sub-Issue Reification Contract \(D14\)'
    }

    It 'documents all four D10 selector-locus categories' {
        $script:DocContent | Should -Match 'Agent-owned, post-PR'
        $script:DocContent | Should -Match 'Agent-owned, pre-PR'
        $script:DocContent | Should -Match 'Skill-only'
        $script:DocContent | Should -Match 'CE Gate surface'
    }

    It 'documents the additive-merge rule (D9)' {
        $script:DocContent | Should -Match 'Additive-merge rule'
        $script:DocContent | Should -Match 'mode\.synthetic-backfill'
    }

    It 'documents the D12 predicate identifiers table' {
        $script:DocContent | Should -Match 'isPipelineEntryTrivial'
        $script:DocContent | Should -Match 'touchesTestableCodeOrTests'
        $script:DocContent | Should -Match 'touchedAreaHasDebt'
        $script:DocContent | Should -Match 'touchesBehaviorOrInterfaceDocsExtended'
    }

    It 'records D17 precondition for sub-#439 advisory enforce mode' {
        $script:DocContent | Should -Match 'D17.*#442'
        $script:DocContent | Should -Match 'Activation precondition'
        $script:DocContent | Should -Match '30-PR recalibration'
    }
}
