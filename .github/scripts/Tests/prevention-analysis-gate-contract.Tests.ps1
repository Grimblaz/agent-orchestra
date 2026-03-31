#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for the prevention analysis gate (§2d + D10) wiring.

.DESCRIPTION
    Locks the issue #240 prevention analysis gate contract across:
      - .github/instructions/safe-operations.instructions.md (§2d — same-principle consolidation gate)
      - .github/agents/Code-Conductor.agent.md (Auto-Tracking §2d reference, CE Gate Track 2 §2d reference, D10 capacity check)
      - .github/agents/Process-Review.agent.md (§4.8 §2d reference, §4.9 §2d reference + prevention_gate_outcome field)
      - Documents/Design/guidance-complexity.md (D10 decision record)

    The files must satisfy:
        - §2d exists in safe-operations with principle-level consolidation guidance, 3 worked examples,
          prevention alternatives, and scope exclusion for compression/extraction issues
        - Code-Conductor Auto-Tracking section references §2d
        - Code-Conductor CE Gate Track 2 section references §2d
        - Code-Conductor contains D10 capacity check language pointing to measure-guidance-complexity.ps1,
          including compression-prerequisite and exemption language
        - Process-Review §4.8 and §4.9 both reference §2d
        - Process-Review §4.9 YAML format includes the prevention_gate_outcome field
        - Documents/Design/guidance-complexity.md documents D10 in both the decisions table and a standalone heading

    These tests lock the issue #240 wiring so future edits to the participating files do not
    silently drift from the prevention analysis gate contract.
#>

Describe 'prevention analysis gate contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SafeOps = Join-Path $script:RepoRoot '.github/instructions/safe-operations.instructions.md'
        $script:CodeConductor = Join-Path $script:RepoRoot '.github/agents/Code-Conductor.agent.md'
        $script:ProcessReview = Join-Path $script:RepoRoot '.github/agents/Process-Review.agent.md'
        $script:DesignDoc = Join-Path $script:RepoRoot 'Documents/Design/guidance-complexity.md'

        $script:SafeOpsContent = Get-Content -Path $script:SafeOps -Raw
        $script:CCContent = Get-Content -Path $script:CodeConductor -Raw
        $script:PRContent = Get-Content -Path $script:ProcessReview -Raw
        $script:DesignContent = Get-Content -Path $script:DesignDoc -Raw

        # Extract §2d section from safe-ops (from heading through end of file or next ###-level heading)
        $script:Section2d = [regex]::Match($script:SafeOpsContent, '(?is)### 2d\b.*?(?=### |\Z)').Value

        # Extract §4.8 and §4.9 from Process-Review
        $script:Section48 = [regex]::Match($script:PRContent, '(?is)### 4\.8\b.*?(?=### 4\.\d+|\Z)').Value
        $script:Section49 = [regex]::Match($script:PRContent, '(?is)### 4\.9\b.*?(?=### 4\.\d+|\Z)').Value
    }

    It 'requires §2d heading to exist in safe-operations.instructions.md' {
        $script:SafeOpsContent | Should -Match '### 2d\.' `
            -Because '§2d issue-prevention gate section must be added to safe-operations before any dependent agents can reference it'
    }

    It 'requires §2d to explain principle-level consolidation — checking whether an open issue covers the same underlying principle' {
        $script:Section2d | Should -Not -BeNullOrEmpty `
            -Because '§2d section must be extractable; the heading must exist first'
        $script:Section2d | Should -Match '(?i)(same.*principle|underlying principle|principle.level)' `
            -Because '§2d must guide agents to check whether an existing open issue already covers the same underlying principle before creating a new one'
    }

    It 'requires §2d to contain three worked examples covering input validation, error handling, and documentation' {
        $script:Section2d | Should -Match '(?i)(input.validat|validat.*input)' `
            -Because '§2d must include an input-validation worked example so agents can recognise the pattern in practice'
        $script:Section2d | Should -Match '(?i)(null|timeout).{0,60}(error.handl|handl.*error)|(error.handl|handl.*error).{0,60}(null|timeout)' `
            -Because '§2d must include a null/timeout error-handling worked example'
        $script:Section2d | Should -Match '(?i)(docstring|comment|documentation).{0,80}(example|consolidat|same)|same.{0,80}(docstring|comment|documentation)' `
            -Because '§2d must include a documentation (docstrings/comments) worked example'
    }

    It 'requires §2d to mention prevention alternatives — structural, contract test, upstream catch, or skill extraction' {
        $script:Section2d | Should -Match '(?i)(structural|contract.test|upstream.catch|skill.extract|prevention.alternative)' `
            -Because '§2d must offer concrete prevention alternatives (structural fix, contract test, upstream catch, skill extraction) rather than directing agents only toward new-rule creation'
    }

    It 'requires §2d to explicitly exclude compression and extraction issues from the principle-consolidation gate' {
        $script:Section2d | Should -Match '(?i)(compress|extract).{0,120}(exempt|exclud|skip|not.apply|does.not.apply)|(exempt|exclud|skip).{0,120}(compress|extract)' `
            -Because '§2d must clarify that issues whose purpose is to reduce directives (compression/extraction) are exempt from the same-principle gate to avoid circular blocking'
    }

    It 'requires Code-Conductor Auto-Tracking section to reference safe-operations §2d' {
        $script:CCContent | Should -Match '(?is)auto.tracking.{0,500}§2d|§2d.{0,500}auto.tracking' `
            -Because 'Auto-Tracking in Code-Conductor must reference §2d so the principle-consolidation gate is applied before creating DEFERRED-SIGNIFICANT tracking issues'
    }

    It 'requires Code-Conductor CE Gate Track 2 section to reference §2d' {
        $script:CCContent | Should -Match '(?is)(CE.Gate|Track 2).{0,500}§2d|§2d.{0,500}(CE.Gate|Track 2)' `
            -Because 'CE Gate Track 2 in Code-Conductor must reference §2d so the prevention gate runs before systemic follow-up issues are created'
    }

    It 'requires Code-Conductor to contain D10 capacity check language' {
        $script:CCContent | Should -Match '(?i)(D10|Capacity check)' `
            -Because 'Code-Conductor must contain D10 capacity check language to gate new agent-prompt guardrail proposals behind a complexity ceiling check'
    }

    It 'requires Code-Conductor D10 to reference measure-guidance-complexity.ps1' {
        $script:CCContent | Should -Match '(?is)D10.{0,800}measure-guidance-complexity\.ps1|measure-guidance-complexity\.ps1.{0,800}D10' `
            -Because 'D10 capacity check must reference the measurement script so Code-Conductor knows which tool to invoke when evaluating the ceiling'
    }

    It 'requires Code-Conductor D10 to reference creating a compression prerequisite issue before blocking' {
        $script:CCContent | Should -Match '(?is)D10.{0,800}(compression|prerequisite)' `
            -Because 'D10 must instruct Code-Conductor to create a compression or prerequisite issue rather than silently blocking — giving teams a clear remediation path'
    }

    It 'requires Code-Conductor D10 to include exemption language for issues that reduce directives' {
        $script:CCContent | Should -Match '(?is)D10.{0,1000}exempt' `
            -Because 'D10 must exempt directive-reduction issues (compression, extraction) from the capacity gate to avoid circular blocking'
    }

    It 'requires Process-Review §4.8 to reference §2d' {
        $script:Section48 | Should -Match '§2d' `
            -Because '§4.8 Upstream Gotcha Lifecycle must reference safe-operations §2d so the same-principle check is applied before upstreaming new gotcha issues'
    }

    It 'requires Process-Review §4.9 Step 4 to reference §2d' {
        $script:Section49 | Should -Match '§2d' `
            -Because '§4.9 Root Cause Analysis upstream proposals (Step 4) must reference safe-operations §2d to gate systemic-fix proposals through the principle-consolidation check'
    }

    It 'requires Process-Review §4.9 YAML proposal format to include prevention_gate_outcome field' {
        $script:Section49 | Should -Match 'prevention_gate_outcome' `
            -Because '§4.9 guardrail proposal YAML must include prevention_gate_outcome so downstream consumers and the PR body can record the result of the §2d principle-consolidation check'
    }

    It 'requires guidance-complexity.md to document D10 in the decisions table' {
        $script:DesignContent | Should -Match '\bD10\b' `
            -Because 'Documents/Design/guidance-complexity.md must list D10 in its decisions table so the capacity-check decision is traceable to a design record'
    }

    It 'requires guidance-complexity.md to have a standalone D10 specification section' {
        $script:DesignContent | Should -Match '### D10' `
            -Because 'Documents/Design/guidance-complexity.md must contain a ### D10 heading with the full D10 specification — not just a decisions-table mention'
    }
}
