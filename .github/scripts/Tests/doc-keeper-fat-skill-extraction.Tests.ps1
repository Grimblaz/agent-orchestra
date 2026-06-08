#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for issue #612 fat-skill extraction: Documentation Maintenance
    Responsibilities moved from agents/Doc-Keeper.agent.md to
    skills/documentation-finalization/SKILL.md.

.DESCRIPTION
    Test honesty marker: these tests use file-content grep only.
    They perform NO live Agent-tool dispatch.
#>

Describe 'Issue #612 Doc-Keeper fat-skill extraction contract (grep only; NO live dispatch)' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DocKeeperBodyPath = Join-Path $script:RepoRoot 'agents\Doc-Keeper.agent.md'
        $script:DocFinalizationSkillPath = Join-Path $script:RepoRoot 'skills\documentation-finalization\SKILL.md'

        $script:ReadText = {
            param([Parameter(Mandatory)][string]$Path)
            return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        }
    }

    Context 'skills/documentation-finalization/SKILL.md carries the extracted section' {

        It 'contains the ## Documentation Maintenance Responsibilities section header' {
            $content = & $script:ReadText -Path $script:DocFinalizationSkillPath
            $content | Should -Match '(?m)^## Documentation Maintenance Responsibilities\s*$'
        }

        It 'lists CHANGELOG.md as a maintained file' {
            $content = & $script:ReadText -Path $script:DocFinalizationSkillPath
            $content | Should -Match 'CHANGELOG\.md'
        }

        It 'lists NEXT-STEPS.md as a maintained file' {
            $content = & $script:ReadText -Path $script:DocFinalizationSkillPath
            $content | Should -Match 'NEXT-STEPS\.md'
        }

        It 'lists QUICK-START.md as a maintained file' {
            $content = & $script:ReadText -Path $script:DocFinalizationSkillPath
            $content | Should -Match 'QUICK-START\.md'
        }

        It 'lists Documents/Decisions/ as a maintained path' {
            $content = & $script:ReadText -Path $script:DocFinalizationSkillPath
            $content | Should -Match 'Documents/Decisions/'
        }

        It 'lists ROADMAP.md as a maintained file' {
            $content = & $script:ReadText -Path $script:DocFinalizationSkillPath
            $content | Should -Match 'ROADMAP\.md'
        }
    }

    Context 'agents/Doc-Keeper.agent.md is a pointer-only body (bijection preserved)' {

        It 'still contains the ## Documentation Maintenance Responsibilities H2 heading' {
            $content = & $script:ReadText -Path $script:DocKeeperBodyPath
            $content | Should -Match '(?m)^## Documentation Maintenance Responsibilities\s*$'
        }

        It 'contains a reference to skills/documentation-finalization/SKILL.md' {
            $content = & $script:ReadText -Path $script:DocKeeperBodyPath
            $content | Should -Match 'skills/documentation-finalization/SKILL\.md'
        }

        It 'does NOT contain the full bullet list content that was moved to the skill' {
            $content = & $script:ReadText -Path $script:DocKeeperBodyPath
            $content | Should -Not -Match 'Update BEFORE merge - add entry during PR documentation finalization'
        }
    }
}
