#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 behavioral tests for migration-scan enforcement (issue #591).

.DESCRIPTION
    Contract under test:
      Invoke-FVPlanValidate enforces that migration-type plans carry migration-scan: true on
      their first implementation slice. Legacy plans (spine-omitted: plan-too-small) get a
      warn-only coverage-gap advisory when Step 1 lacks an exhaustive-scan description.
      Non-migration plans are unaffected.
      Code-Conductor.agent.md and skills/plan-authoring/SKILL.md carry the canonical
      methodology text absorbed in issue #591.
#>

Describe 'Migration-scan enforcement' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-validate-core.ps1'
        . $script:LibFile

        # Builds a minimal spine-bearing migration-type plan comment with one or two slices.
        # $MigrationScanLine: pass 'migration-scan: true' to add the field; omit (default) to test
        # the non-conforming case.
        # $Slice1Coverage: overrides the provides line, e.g. 'coverage: exploratory - reason'.
        $script:NewMigrationPlan = {
            param(
                [string]$MigrationScanLine = '',
                [string]$Slice1Coverage = 'provides: [implement-docs]'
            )

            $slice1FieldLines = [System.Collections.Generic.List[string]]::new()
            if ($MigrationScanLine) { $slice1FieldLines.Add($MigrationScanLine) | Out-Null }
            $slice1FieldLines.Add($Slice1Coverage) | Out-Null
            $slice1FieldLines.Add('depends-on: []') | Out-Null
            $slice1FieldLines.Add('ac-refs: [AC1]') | Out-Null

            $slice1Block = (@(
                '<!-- frame-slice'
                'id: s1'
                'commit-index: 1'
            ) + $slice1FieldLines.ToArray() + @(
                'slice: |'
                '  Step 1 - Produce authoritative file list'
                '-->'
            )) -join "`n"

            $lines = @(
                '# Migration-type plan fixture'
                ''
                '## Acceptance Criteria'
                '- **AC1** Exhaustive scan produces the authoritative file list.'
                ''
                '<!-- frame-spine'
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T15:00:00Z'
                'coverage: complete'
                'ports:'
                '  implement-docs: [s1]'
                'slices:'
                '  s1:'
                '    execution_mode: serial'
                '    rc: GREEN produce authoritative list'
                '    ac_refs: [AC1]'
                '    depends_on: []'
                '    cycle: 1'
                '-->'
                ''
                $slice1Block
            )

            return ($lines -join "`n")
        }

        # Builds a two-slice migration-type plan.
        # $Slice2MigrationScan: whether to add migration-scan: true on the SECOND slice.
        $script:NewTwoSliceMigrationPlan = {
            param([switch]$Slice2MigrationScan)

            $slice2Fields = [System.Collections.Generic.List[string]]::new()
            if ($Slice2MigrationScan) { $slice2Fields.Add('migration-scan: true') | Out-Null }
            $slice2Fields.Add('provides: [implement-code]') | Out-Null
            $slice2Fields.Add('depends-on: [s1]') | Out-Null
            $slice2Fields.Add('ac-refs: []') | Out-Null

            $slice2Block = (@(
                '<!-- frame-slice'
                'id: s2'
                'commit-index: 2'
            ) + $slice2Fields.ToArray() + @(
                'slice: |'
                '  Step 2 - Apply changes'
                '-->'
            )) -join "`n"

            $lines = @(
                '# Migration-type plan fixture'
                ''
                '## Acceptance Criteria'
                '- **AC1** Exhaustive scan.'
                ''
                '<!-- frame-spine'
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T15:00:00Z'
                'coverage: complete'
                'ports:'
                '  implement-docs: [s1]'
                '  implement-code: [s2]'
                'slices:'
                '  s1:'
                '    execution_mode: serial'
                '    rc: GREEN'
                '    ac_refs: [AC1]'
                '    depends_on: []'
                '    cycle: 1'
                '  s2:'
                '    execution_mode: serial'
                '    rc: GREEN'
                '    ac_refs: []'
                '    depends_on: [s1]'
                '    cycle: 1'
                '-->'
                ''
                '<!-- frame-slice'
                'id: s1'
                'commit-index: 1'
                'migration-scan: true'
                'provides: [implement-docs]'
                'depends-on: []'
                'ac-refs: [AC1]'
                'slice: |'
                '  Step 1'
                '-->'
                ''
                $slice2Block
            )

            return ($lines -join "`n")
        }
    }

    Context 'Invoke-FVPlanValidate — spine-bearing migration-type plans' {

        It 'passes a conforming migration-type plan with migration-scan: true on slice #1' {
            $plan = & $script:NewMigrationPlan -MigrationScanLine 'migration-scan: true'

            $result = Invoke-FVPlanValidate -CommentText $plan

            $result.ExitCode | Should -Be 0
            ($result.Results | Where-Object { $_.Name -eq 'PlanStructuralCoverage' }).Passed | Should -BeTrue
        }

        It 'fails a migration-type plan where slice #1 is missing migration-scan: true' {
            $plan = & $script:NewMigrationPlan

            $result = Invoke-FVPlanValidate -CommentText $plan

            $result.ExitCode | Should -Not -Be 0
            $structural = $result.Results | Where-Object { $_.Name -eq 'PlanStructuralCoverage' }
            $structural.Passed | Should -BeFalse
            $structural.Detail | Should -Match 'migration-type plan'
            $structural.Detail | Should -Match 'migration-scan: true'
            $structural.Detail | Should -Match 's1'
        }

        It 'fails when migration-scan: true is paired with coverage: exploratory on slice #1' {
            $plan = & $script:NewMigrationPlan `
                -MigrationScanLine 'migration-scan: true' `
                -Slice1Coverage 'coverage: exploratory - exhaustive scan is not a deterministic port'

            $result = Invoke-FVPlanValidate -CommentText $plan

            $result.ExitCode | Should -Not -Be 0
            $structural = $result.Results | Where-Object { $_.Name -eq 'PlanStructuralCoverage' }
            $structural.Passed | Should -BeFalse
            $structural.Detail | Should -Match 'migration-scan: true'
            $structural.Detail | Should -Match 'exploratory'
        }

        It 'fails when migration-scan: true appears on a non-first slice' {
            $plan = & $script:NewTwoSliceMigrationPlan -Slice2MigrationScan

            $result = Invoke-FVPlanValidate -CommentText $plan

            $result.ExitCode | Should -Not -Be 0
            $structural = $result.Results | Where-Object { $_.Name -eq 'PlanStructuralCoverage' }
            $structural.Passed | Should -BeFalse
            $structural.Detail | Should -Match 'migration-scan: true is only valid on the first'
            $structural.Detail | Should -Match 's2'
        }

        It 'passes a two-slice migration-type plan with migration-scan: true only on slice #1' {
            $plan = & $script:NewTwoSliceMigrationPlan

            $result = Invoke-FVPlanValidate -CommentText $plan

            $result.ExitCode | Should -Be 0
            ($result.Results | Where-Object { $_.Name -eq 'PlanStructuralCoverage' }).Passed | Should -BeTrue
        }

        It 'does not trigger migration-scan enforcement for non-migration-type plans' {
            $plan = @(
                '# Non-migration plan fixture'
                ''
                '## Acceptance Criteria'
                '- **AC1** Standard implementation.'
                ''
                '<!-- frame-spine'
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T15:00:00Z'
                'coverage: complete'
                'ports:'
                '  implement-code: [s1]'
                'slices:'
                '  s1:'
                '    execution_mode: serial'
                '    rc: GREEN'
                '    ac_refs: [AC1]'
                '    depends_on: []'
                '    cycle: 1'
                '-->'
                ''
                '<!-- frame-slice'
                'id: s1'
                'commit-index: 1'
                'provides: [implement-code]'
                'depends-on: []'
                'ac-refs: [AC1]'
                'slice: |'
                '  Step 1 - Implement the feature'
                '-->'
            ) -join "`n"

            $result = Invoke-FVPlanValidate -CommentText $plan

            $result.ExitCode | Should -Be 0
            ($result.Results | Where-Object { $_.Name -eq 'PlanStructuralCoverage' }).Passed | Should -BeTrue
        }
    }

    Context 'Invoke-FVPlanValidate — legacy path (spine-omitted: plan-too-small)' {

        It 'passes a legacy migration-type plan whose Step 1 is an exhaustive scan' {
            $plan = @(
                '<!-- plan-issue-591 -->'
                '---'
                'status: approved'
                'issue_id: 591'
                'spine-omitted: plan-too-small'
                '---'
                ''
                '## Plan: Tiny migration-type fix'
                '1. Exhaustive repo scan — produce the authoritative file list.'
                '2. Apply the rename.'
            ) -join "`n"

            $result = Invoke-FVPlanValidate -CommentText $plan

            $result.ExitCode | Should -Be 0
            $structural = $result.Results | Where-Object { $_.Name -eq 'PlanStructuralCoverage' }
            $structural.Passed | Should -BeTrue
            $structural.Detail | Should -Match 'spine-omitted: plan-too-small'
        }

        It 'emits a warn-only coverage-gap when a legacy migration-type plan lacks a scan in Step 1' {
            $plan = @(
                '<!-- plan-issue-591 -->'
                '---'
                'status: approved'
                'issue_id: 591'
                'spine-omitted: plan-too-small'
                '---'
                ''
                '## Plan: migration-type small change'
                '1. Apply the rename.'
                '2. Update references.'
            ) -join "`n"

            $result = Invoke-FVPlanValidate -CommentText $plan

            $result.ExitCode | Should -Be 0
            $coverage = $result.Results | Where-Object { $_.Name -eq 'PlanCoverageGap' }
            $coverage | Should -Not -BeNullOrEmpty
            $coverage.Passed | Should -BeTrue
            $coverage.Detail | Should -Match 'coverage-gap'
            $coverage.Detail | Should -Match 'migration-type'
        }
    }

    Context 'Code-Conductor.agent.md methodology text' {

        BeforeAll {
            $script:ConductorBody = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md') -Raw
        }

        It 'migration-type plan check documents both insert and planner-omitted-scan' {
            $script:ConductorBody | Should -Match 'insert'
            $script:ConductorBody | Should -Match 'planner-omitted-scan'
        }

        It 'contains no <plan_style_guide> reference' {
            $script:ConductorBody | Should -Not -Match 'plan_style_guide'
        }

        It 'references the plan-authoring skill anchor for the detection predicate' {
            $script:ConductorBody | Should -Match '(?i)plan-authoring.*Migration-type issues|Migration-type issues.*plan-authoring'
        }

        It 'documents the dispatch-fallback-events row for planner-omitted-scan' {
            $script:ConductorBody | Should -Match 'dispatch-fallback-events'
        }
    }

    Context 'skills/plan-authoring/SKILL.md methodology text' {

        BeforeAll {
            $script:PlanAuthoringBody = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'skills/plan-authoring/SKILL.md') -Raw
        }

        It 'names the migration-scan: true marker' {
            $script:PlanAuthoringBody | Should -Match 'migration-scan: true'
        }

        It 'documents the placement constraint (frame-slice block only)' {
            $script:PlanAuthoringBody | Should -Match '(?i)frame-slice'
            $script:PlanAuthoringBody | Should -Match '(?i)placement'
        }

        It 'covers the spine-bearing shape (marker required)' {
            $script:PlanAuthoringBody | Should -Match 'migration-scan: true'
            $script:PlanAuthoringBody | Should -Match '(?i)spine'
        }

        It 'covers the legacy plan shape (spine-omitted prose rule)' {
            $script:PlanAuthoringBody | Should -Match '(?i)spine-omitted|legacy'
        }
    }
}
