#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Parity tests for pipeline-entry agent body wiring (issue #442, Step 11).
#
# (a) Each pipeline-entry agent references skills/frame-credit-emission/SKILL.md exactly once.
# (b) Each agent's terminal step section contains the credit-input marker post instruction.
# (c) The credit-input instruction cites the agent-specific completion marker per the table:
#     Experience-Owner → experience-owner-complete-{ISSUE_NUMBER}
#     Solution-Designer → design-phase-complete-{ISSUE_NUMBER}
#     Issue-Planner     → plan-issue-{ISSUE_NUMBER}
# (d) Existing completion markers are still present (no regression).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:AgentTable = @(
        [pscustomobject]@{
            Name             = 'Experience-Owner'
            Path             = 'agents/Experience-Owner.agent.md'
            Port             = 'experience'
            CompletionMarker = 'experience-owner-complete'
        },
        [pscustomobject]@{
            Name             = 'Solution-Designer'
            Path             = 'agents/Solution-Designer.agent.md'
            Port             = 'design'
            CompletionMarker = 'design-phase-complete'
        },
        [pscustomobject]@{
            Name         = 'Issue-Planner'
            Path         = 'agents/Issue-Planner.agent.md'
            Port         = 'plan'
            CompletionMarker = 'plan-issue'
        }
    )
}

# ---------------------------------------------------------------------------
# (a) Each agent references the frame-credit-emission skill exactly once
# ---------------------------------------------------------------------------

Describe 'Pipeline-entry agent references frame-credit-emission skill (Step 11a)' -ForEach @(
    @{ Name = 'Experience-Owner'; AgentPath = 'agents/Experience-Owner.agent.md' }
    @{ Name = 'Solution-Designer'; AgentPath = 'agents/Solution-Designer.agent.md' }
    @{ Name = 'Issue-Planner'; AgentPath = 'agents/Issue-Planner.agent.md' }
) {
    param($Name, $AgentPath)

    BeforeAll {
        $fullPath = Join-Path $script:RepoRoot $AgentPath
        $script:Content = if (Test-Path $fullPath) { Get-Content -Raw $fullPath } else { '' }
    }

    It "$Name agent references skills/frame-credit-emission/SKILL.md" {
        $script:Content | Should -Match ([regex]::Escape('skills/frame-credit-emission/SKILL.md')) `
            -Because "$Name must load the frame-credit-emission skill at its terminal step"
    }

    It "$Name agent references frame-credit-emission exactly once" {
        $matches = ([regex]::Matches($script:Content, [regex]::Escape('skills/frame-credit-emission/SKILL.md'))).Count
        $matches | Should -Be 1 -Because "$Name should reference the skill once (no duplicate load pointers)"
    }
}

# ---------------------------------------------------------------------------
# (b) Each agent contains the credit-input marker post instruction
# ---------------------------------------------------------------------------

Describe 'Pipeline-entry agent contains credit-input marker instruction (Step 11b)' -ForEach @(
    @{ Name = 'Experience-Owner'; AgentPath = 'agents/Experience-Owner.agent.md'; Port = 'experience' }
    @{ Name = 'Solution-Designer'; AgentPath = 'agents/Solution-Designer.agent.md'; Port = 'design' }
    @{ Name = 'Issue-Planner'; AgentPath = 'agents/Issue-Planner.agent.md'; Port = 'plan' }
) {
    param($Name, $AgentPath, $Port)

    BeforeAll {
        $fullPath = Join-Path $script:RepoRoot $AgentPath
        $script:Content = if (Test-Path $fullPath) { Get-Content -Raw $fullPath } else { '' }
    }

    It "$Name contains credit-input-$Port marker instruction" {
        $script:Content | Should -Match "credit-input-$Port" `
            -Because "$Name must instruct the agent to post the <!-- credit-input-$Port-{ID} --> comment"
    }

    It "$Name credit-input instruction is near the terminal step" {
        $creditInputIdx = $script:Content.IndexOf("credit-input-$Port", [System.StringComparison]::Ordinal)
        $creditInputIdx | Should -BeGreaterThan 0 -Because "$Name must contain the credit-input instruction"
    }
}

# ---------------------------------------------------------------------------
# (c) Each agent cites the correct agent-specific completion marker
# ---------------------------------------------------------------------------

Describe 'Pipeline-entry agent credit-input instruction cites correct completion marker (Step 11c)' -ForEach @(
    @{ Name = 'Experience-Owner'; AgentPath = 'agents/Experience-Owner.agent.md'; Port = 'experience'; CompletionMarker = 'experience-owner-complete' }
    @{ Name = 'Solution-Designer'; AgentPath = 'agents/Solution-Designer.agent.md'; Port = 'design'; CompletionMarker = 'design-phase-complete' }
    @{ Name = 'Issue-Planner'; AgentPath = 'agents/Issue-Planner.agent.md'; Port = 'plan'; CompletionMarker = 'plan-issue' }
) {
    param($Name, $AgentPath, $Port, $CompletionMarker)

    BeforeAll {
        $fullPath = Join-Path $script:RepoRoot $AgentPath
        $script:Content = if (Test-Path $fullPath) { Get-Content -Raw $fullPath } else { '' }
    }

    It "$Name credit-input instruction cites the '$CompletionMarker' completion marker" {
        $script:Content | Should -Match ([regex]::Escape($CompletionMarker)) `
            -Because "$Name must cite '$CompletionMarker' as evidence in the credit-input payload"
    }
}

# ---------------------------------------------------------------------------
# (d) Existing completion markers are still present (regression guard)
# ---------------------------------------------------------------------------

Describe 'Pipeline-entry agent completion markers not regressed (Step 11d)' -ForEach @(
    @{ Name = 'Experience-Owner'; AgentPath = 'agents/Experience-Owner.agent.md'; CompletionMarker = 'experience-owner-complete-{ISSUE_NUMBER}' }
    @{ Name = 'Solution-Designer'; AgentPath = 'agents/Solution-Designer.agent.md'; CompletionMarker = 'design-phase-complete-{ISSUE_NUMBER}' }
    @{ Name = 'Issue-Planner'; AgentPath = 'agents/Issue-Planner.agent.md'; CompletionMarker = 'plan-issue-{ID}' }
) {
    param($Name, $AgentPath, $CompletionMarker)

    BeforeAll {
        $fullPath = Join-Path $script:RepoRoot $AgentPath
        $script:Content = if (Test-Path $fullPath) { Get-Content -Raw $fullPath } else { '' }
    }

    It "$Name still contains the original completion marker '$CompletionMarker'" {
        $script:Content | Should -Match ([regex]::Escape($CompletionMarker)) `
            -Because "$Name must still instruct the agent to post its original completion marker"
    }
}
