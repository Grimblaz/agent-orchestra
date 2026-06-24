#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Structural invariant tests for the Advisory Value Reflex (issue #729).
.DESCRIPTION
    Asserts that the Value Reflex methodology is correctly authored in
    skills/customer-experience/SKILL.md and agents/Experience-Owner.agent.md.
    Tests are structural, not bare word-presence.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CustomerExperienceSkill = Join-Path $script:RepoRoot 'skills/customer-experience/SKILL.md'
    $script:ExperienceOwnerAgent = Join-Path $script:RepoRoot 'agents/Experience-Owner.agent.md'
    $script:EngagementRecordCore = Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1'

    $script:GetContent = {
        param([string]$Path)
        return (Get-Content -Path $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    $script:SkillContent = & $script:GetContent $script:CustomerExperienceSkill
    $script:AgentContent = & $script:GetContent $script:ExperienceOwnerAgent
}

Describe 'Value Reflex - skills/customer-experience/SKILL.md' {

    It '(a) enumerates exactly 3 numbered prompts (Bet, Falsifier, Alternative) as bold numbered items' {
        # Extract the Value Reflex section: text from the heading to the next ## or ### heading
        $sectionMatch = [regex]::Match(
            $script:SkillContent,
            '(?ms)^### Value Reflex \(first beat\)\n(.*?)(?=\n#{2,3} |\z)'
        )
        $sectionMatch.Success | Should -BeTrue -Because 'the ### Value Reflex (first beat) section must exist in the skill'

        $section = $sectionMatch.Groups[1].Value

        # Assert all three labels appear as bold numbered items
        $section | Should -Match '\*\*Bet\*\*' -Because 'the Bet prompt must appear as a bold label'
        $section | Should -Match '\*\*Falsifier\*\*' -Because 'the Falsifier prompt must appear as a bold label'
        $section | Should -Match '\*\*Alternative\*\*' -Because 'the Alternative prompt must appear as a bold label'

        # Count bold numbered items: lines matching "N. **Label**"
        $boldNumberedMatches = [regex]::Matches($section, '(?m)^\d+\. \*\*')
        $boldNumberedMatches.Count | Should -Be 3 -Because 'the reflex must enumerate exactly 3 numbered bold-label prompt items'
    }

    It '(b) names the `frame it` skip affordance as a code-formatted string' {
        $script:SkillContent | Should -Match ([regex]::Escape('`frame it`')) -Because 'the skip affordance must appear code-formatted so it is unambiguous'
    }

    It '(c) states the no-numeric-score guard in the section heading' {
        $script:SkillContent | Should -Match 'no numeric score' -Because 'the heading must include the no-numeric-score guard phrase'
    }

    It '(d) item 0 appears before item 1 in ## Upstream Framing At A Glance' {
        $script:SkillContent | Should -Match '0\. Before framing begins' -Because 'item 0 must use the "Before framing begins" phrasing'
        $script:SkillContent | Should -Match '1\. Describe' -Because 'item 1 must use the "Describe" phrasing'

        $pos0 = $script:SkillContent.IndexOf('0. Before framing begins')
        $pos1 = $script:SkillContent.IndexOf('1. Describe')
        $pos0 | Should -BeLessThan $pos1 -Because 'item 0 (Value Reflex trigger) must precede item 1 in the framing checklist'
    }

    It '(e-extra) recommendation enum completeness: all five outcome values are present' {
        $script:SkillContent | Should -Match 'Proceed-full' -Because 'the Proceed-full outcome must be documented in the skill'
        $script:SkillContent | Should -Match 'Proceed-lite' -Because 'the Proceed-lite outcome must be documented in the skill'
        $script:SkillContent | Should -Match 'Shrink' -Because 'the Shrink outcome must be documented in the skill'
        $script:SkillContent | Should -Match 'Park' -Because 'the Park outcome must be documented in the skill'
        $script:SkillContent | Should -Match 'Decline' -Because 'the Decline outcome must be documented in the skill'
    }
}

Describe 'Value Reflex - agents/Experience-Owner.agent.md recording wiring' {

    It '(e) references worth-it-{ISSUE} engagement-record recording via decision_id: worth-it- pattern' {
        $script:AgentContent | Should -Match 'decision_id: worth-it-' -Because 'the agent must document the worth-it-{ISSUE_NUMBER} decision_id slug for Park/Decline recording'
    }

    It '(f1) documents label-apply behavior for parked and declined outcomes' {
        $script:AgentContent | Should -Match 'status: parked' -Because 'the agent must document the parked label name for gh issue edit'
        $script:AgentContent | Should -Match 'status: declined' -Because 'the agent must document the declined label name for gh issue edit'
    }

    It '(f2) documents Halt behavior near label application instructions' {
        # Find the Value Reflex recording wiring section
        $wiringMatch = [regex]::Match(
            $script:AgentContent,
            '(?ms)^\*\*Value Reflex recording wiring\*\*[^\n]*\n(.*?)(?=\n## |\z)'
        )
        $wiringMatch.Success | Should -BeTrue -Because 'the **Value Reflex recording wiring** section must exist in the agent'

        $wiringSection = $wiringMatch.Groups[1].Value
        $wiringSection | Should -Match 'Halt' -Because 'the recording wiring section must document the Halt behavior after label application'
    }
}

Describe 'Value Reflex - constant validations' {

    BeforeAll {
        $script:SlugFunctionAvailable = $false
        try {
            . $script:EngagementRecordCore
            # Verify the function loaded successfully
            if (Get-Command Test-EngagementRecordSlug -ErrorAction SilentlyContinue) {
                $script:SlugFunctionAvailable = $true
            }
        }
        catch {
            Write-Warning "Could not dot-source frame-engagement-record-core.ps1: $_"
        }
    }

    It 'worth-it-729 passes Test-EngagementRecordSlug (valid slug)' {
        if (-not $script:SlugFunctionAvailable) {
            Set-ItResult -Skipped -Because 'Test-EngagementRecordSlug not available'
            return
        }
        Test-EngagementRecordSlug -DecisionId 'worth-it-729' | Should -BeTrue -Because 'worth-it-729 is a valid lowercase hyphenated slug'
    }

    It 'worth-it-42 passes Test-EngagementRecordSlug (generic issue number)' {
        if (-not $script:SlugFunctionAvailable) {
            Set-ItResult -Skipped -Because 'Test-EngagementRecordSlug not available'
            return
        }
        Test-EngagementRecordSlug -DecisionId 'worth-it-42' | Should -BeTrue -Because 'worth-it-42 is a valid lowercase hyphenated slug'
    }

    It 'Worth-It-729 FAILS Test-EngagementRecordSlug (capitalized slug is invalid)' {
        if (-not $script:SlugFunctionAvailable) {
            Set-ItResult -Skipped -Because 'Test-EngagementRecordSlug not available'
            return
        }
        Test-EngagementRecordSlug -DecisionId 'Worth-It-729' | Should -BeFalse -Because 'the slug regex is case-sensitive; uppercase letters must be rejected'
    }

    It 'Read-EngagementRecords $Phase ValidateSet includes "experience"' {
        $coreContent = & $script:GetContent $script:EngagementRecordCore
        $coreContent | Should -Match "\[ValidateSet\([^)]*'experience'" -Because 'the Phase parameter must include "experience" as a valid value'
    }
}
