#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Contract tests for Code-Conductor shared-body size and extracted-reference directives.

.DESCRIPTION
    Locks issue #403 Step 8 / D5: the shared Code-Conductor body must stay under the
    agreed size ceiling and must continue loading the extracted reference files for the
    sections moved into composite skills.
#>

Describe 'Code-Conductor shared-body size contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ConductorBodyPath = Join-Path $script:RepoRoot 'agents\Code-Conductor.agent.md'
        $script:ConductorBody = (Get-Content -Path $script:ConductorBodyPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        $script:ConductorLineCount = if ([string]::IsNullOrEmpty($script:ConductorBody)) {
            0
        }
        else {
            ($script:ConductorBody -split "`n").Count
        }
    }

    It 'keeps agents/Code-Conductor.agent.md at 500 lines or fewer' {
        $script:ConductorLineCount | Should -BeLessOrEqual 500 -Because 'issue #403 Step 8 locks the shared body size ceiling after the D5 extraction'
    }

    It 'requires explicit extracted-reference directives for the D5 customer-experience and pipeline sections' {
        $script:ConductorBody | Should -Match '(?s)## Customer Experience Gate \(CE Gate\).*?Load and follow these references:.*?skills/customer-experience/references/orchestration-protocol\.md.*?skills/customer-experience/references/defect-response\.md' -Because 'the CE Gate section must load the extracted orchestration and defect-response references explicitly'
        $script:ConductorBody | Should -Match '(?s)## Pipeline Metrics.*?Load and follow these references:.*?skills/calibration-pipeline/references/metrics-schema\.md.*?skills/calibration-pipeline/references/verdict-mapping\.md.*?skills/calibration-pipeline/references/findings-construction\.md' -Because 'the Pipeline Metrics section must load the extracted calibration references explicitly'
    }

    It 'requires explicit extracted-reference directives for the D5 review-reconciliation and error-handling sections' {
        $script:ConductorBody | Should -Match '(?s)## Review Reconciliation Loop \(Mandatory\).*?Load and follow these references:.*?skills/validation-methodology/references/review-reconciliation\.md.*?skills/validation-methodology/references/post-judgment-routing\.md.*?skills/code-review-intake/references/express-lane\.md' -Because 'the review-reconciliation section must keep the extracted validation and express-lane references explicit'
        $script:ConductorBody | Should -Match '(?s)## Subagent Call Resilience \(R5\).*?skills/parallel-execution/references/error-handling\.md' -Because 'the R5 section must explicitly direct readers to the extracted parallel-execution error-handling reference'
        $script:ConductorBody | Should -Match '(?s)## Error Handling.*?skills/parallel-execution/references/error-handling\.md' -Because 'the main error-handling section must explicitly direct readers to the extracted parallel-execution error-handling reference'
    }
}
