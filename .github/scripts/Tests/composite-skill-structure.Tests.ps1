#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Contract tests for composite-skill entryway structure after the D5 extraction.

.DESCRIPTION
    Locks issue #403 Step 8: the refactored composite skills stay small, enumerate the
    extracted reference files they own, and avoid inlining the extracted methodology
    headings back into the SKILL.md entryways.
#>

Describe 'Composite skill structure contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        $script:GetNormalizedContent = {
            param([string]$Path)

            return ((Get-Content -Path $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n")
        }

        $script:GetLineCount = {
            param([string]$Content)

            if ([string]::IsNullOrEmpty($Content)) {
                return 0
            }

            return ($Content -split "`n").Count
        }

        $script:CompositeSkills = @(
            @{
                Name                      = 'customer-experience'
                SkillPath                 = Join-Path $script:RepoRoot 'skills\customer-experience\SKILL.md'
                ReferencesPath            = Join-Path $script:RepoRoot 'skills\customer-experience\references'
                DisallowedHeadingPatterns = @(
                    '(?m)^## Customer Experience Gate \(CE Gate\)\s*$',
                    '(?m)^## Two-Track Defect Response\s*$'
                )
            },
            @{
                Name                      = 'calibration-pipeline'
                SkillPath                 = Join-Path $script:RepoRoot 'skills\calibration-pipeline\SKILL.md'
                ReferencesPath            = Join-Path $script:RepoRoot 'skills\calibration-pipeline\references'
                DisallowedHeadingPatterns = @(
                    '(?m)^## Pipeline Metrics\s*$',
                    '(?m)^## Verdict Mapping\s*$',
                    '(?m)^## Findings Array\s*$'
                )
            },
            @{
                Name                      = 'validation-methodology'
                SkillPath                 = Join-Path $script:RepoRoot 'skills\validation-methodology\SKILL.md'
                ReferencesPath            = Join-Path $script:RepoRoot 'skills\validation-methodology\references'
                DisallowedHeadingPatterns = @(
                    '(?m)^## Review Reconciliation Loop\s*$',
                    '(?m)^## Post-Judgment Re-Activation Detection\s*$'
                )
            },
            @{
                Name                      = 'code-review-intake'
                SkillPath                 = Join-Path $script:RepoRoot 'skills\code-review-intake\SKILL.md'
                ReferencesPath            = Join-Path $script:RepoRoot 'skills\code-review-intake\references'
                DisallowedHeadingPatterns = @(
                    '(?m)^## Express Lane Gate.*$'
                )
            },
            @{
                Name                      = 'parallel-execution'
                SkillPath                 = Join-Path $script:RepoRoot 'skills\parallel-execution\SKILL.md'
                ReferencesPath            = Join-Path $script:RepoRoot 'skills\parallel-execution\references'
                DisallowedHeadingPatterns = @(
                    '(?m)^## Subagent Call Resilience \(R5\)\s*$',
                    '(?m)^## Error Handling\s*$',
                    '(?m)^### Terminal Non-Interactive Guardrails \(Mandatory\)\s*$',
                    '(?m)^### Terminal Lifecycle Protocol\s*$'
                )
            }
        ) | ForEach-Object {
            $content = & $script:GetNormalizedContent -Path $_.SkillPath
            $referenceFiles = @(
                Get-ChildItem -Path $_.ReferencesPath -File |
                    Sort-Object Name |
                    ForEach-Object { $_.Name }
                )

                [pscustomobject]@{
                    Name                      = $_.Name
                    SkillPath                 = $_.SkillPath
                    Content                   = $content
                    LineCount                 = & $script:GetLineCount -Content $content
                    ReferenceFiles            = $referenceFiles
                    DisallowedHeadingPatterns = $_.DisallowedHeadingPatterns
                }
            }
    }

    It 'keeps each refactored composite SKILL.md at 80 lines or fewer' {
        foreach ($skill in $script:CompositeSkills) {
            $skill.LineCount | Should -BeLessOrEqual 80 -Because "$($skill.Name) should remain a compact composite entryway rather than regrowing the extracted methodology"
        }
    }

    It 'requires each composite skill to enumerate every file in its references folder' {
        foreach ($skill in $script:CompositeSkills) {
            $skill.Content | Should -Match '(?m)^## Composite References\s*$' -Because "$($skill.Name) should act as an entryway that indexes its extracted references explicitly"
            $skill.ReferenceFiles.Count | Should -BeGreaterThan 0 -Because "$($skill.Name) should have at least one extracted reference file after the D5 refactor"

            foreach ($referenceFile in $skill.ReferenceFiles) {
                $skill.Content | Should -Match ([regex]::Escape($referenceFile)) -Because "$($skill.Name) must name every file in its references/ folder so the entryway remains discoverable"
            }
        }
    }

    It 'prevents the composite entry skills from inlining the extracted methodology headings back into SKILL.md' {
        foreach ($skill in $script:CompositeSkills) {
            foreach ($pattern in $skill.DisallowedHeadingPatterns) {
                $skill.Content | Should -Not -Match $pattern -Because "$($skill.Name) should point to extracted reference files instead of reintroducing the extracted section heading into SKILL.md"
            }
        }
    }
}
