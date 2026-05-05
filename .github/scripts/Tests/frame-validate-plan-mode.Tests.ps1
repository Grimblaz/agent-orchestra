#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED tests for frame-validate.ps1 plan mode.

.DESCRIPTION
    Contract under test:
      frame-validate.ps1 -Mode plan accepts a plan comment through -CommentFile
      or stdin, validates frame-spine/frame-slice coverage, hard-fails invalid
      routing coverage, and reports warn-only coverage-gap details.
#>

Describe 'Frame validator plan mode CLI' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CliFile = Join-Path $script:RepoRoot '.github/scripts/frame-validate.ps1'

        $script:InvokeFrameValidateCli = {
            param(
                [string[]]$Arguments = @(),
                [AllowNull()][string]$InputText
            )

            if ($PSBoundParameters.ContainsKey('InputText')) {
                $output = $InputText | & pwsh -NoProfile -NonInteractive -File $script:CliFile @Arguments 2>&1
            }
            else {
                $output = & pwsh -NoProfile -NonInteractive -File $script:CliFile @Arguments 2>&1
            }

            return [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output   = [string](@($output | ForEach-Object { [string]$_ }) -join "`n")
            }
        }

        $script:WritePlanComment = {
            param([Parameter(Mandatory)][string]$Content)

            $path = Join-Path -Path 'TestDrive:' -ChildPath "plan-comment-$([System.Guid]::NewGuid().ToString('N')).md"
            Set-Content -Path $path -Value $Content -Encoding utf8NoBOM
            return $path
        }

        $script:NewFrameSliceBlock = {
            param(
                [string]$StepId = 's4',
                [string]$CommitIndex = '4',
                [string[]]$FieldLines = @(
                    'provides: [implement-test]',
                    'depends-on: []',
                    'ac-refs: [AC4]'
                ),
                [switch]$DocumentedBareMarker
            )

            $openingMarker = if ($DocumentedBareMarker) { '<!-- frame-slice -->' } else { '<!-- frame-slice' }

            return [string](@(
                    $openingMarker
                    "id: $StepId"
                    "commit-index: $CommitIndex"
                ) + $FieldLines + @(
                    'slice: |'
                    "  Step $CommitIndex - Validate frame coverage"
                    '  Execution Mode: serial'
                    '  Requirement Contract:'
                    '    - AC slice: AC4 frame-coverage validator'
                    '-->'
                ) -join "`n")
        }

        $script:NewPlanComment = {
            param(
                [string[]]$PortLines = @('  implement-test: [s4]'),
                [string[]]$SpineSliceLines = @(
                    '  s4:',
                    '    execution_mode: serial',
                    '    rc: GREEN validation action',
                    '    ac_refs: [AC4]',
                    '    depends_on: []',
                    '    cycle: 1'
                ),
                [string[]]$AcceptanceCriteria = @('- **AC4** Frame coverage validator catches missing routing coverage.'),
                [string[]]$SliceBlocks = @()
            )

            $lines = @(
                '# Issue 512 plan fixture',
                '',
                '## Acceptance Criteria'
            ) + $AcceptanceCriteria + @(
                '',
                '<!-- frame-spine',
                'spine_schema_version: 1',
                'generated_at: 2026-05-04T15:00:00Z',
                'coverage: complete',
                'ports:'
            ) + $PortLines + @(
                'slices:'
            ) + $SpineSliceLines + @(
                '-->',
                ''
            ) + $SliceBlocks

            return [string]($lines -join "`n")
        }
    }

    It 'rejects an implementation slice that has neither provides nor exploratory coverage' {
        $orphanSlice = & $script:NewFrameSliceBlock -StepId 's4' -CommitIndex '4' -FieldLines @(
            'depends-on: []',
            'ac-refs: [AC4]'
        )
        $comment = & $script:NewPlanComment -PortLines @('  implement-test: []') -SliceBlocks @($orphanSlice)
        $commentFile = & $script:WritePlanComment -Content $comment

        $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan', '-CommentFile', $commentFile)

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 's4'
        $result.Output | Should -Match 'provides:'
    }

    It 'passes an exploratory orphan slice and reports a coverage-gap detail from stdin' {
        $reason = 'research spike does not fill a deterministic frame port'
        $orphanSlice = & $script:NewFrameSliceBlock -StepId 's4' -CommitIndex '4' -FieldLines @(
            'coverage: exploratory - research spike does not fill a deterministic frame port',
            'depends-on: []',
            'ac-refs: [AC4]'
        )
        $comment = & $script:NewPlanComment -PortLines @('  implement-test: []') -SliceBlocks @($orphanSlice)

        $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'coverage-gap'
        $result.Output | Should -Match 's4'
        $result.Output | Should -Match ([regex]::Escape($reason))
    }

    It 'rejects a spine port that has no slice provides anchor' {
        $comment = & $script:NewPlanComment -PortLines @('  implement-test: [s4]') -SliceBlocks @()
        $commentFile = & $script:WritePlanComment -Content $comment

        $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan', '-CommentFile', $commentFile)

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'implement-test'
        $result.Output | Should -Match 'slice provides:'
    }

    It 'rejects a spine entry whose slice provides a different port' {
        $mismatchedSlice = & $script:NewFrameSliceBlock -StepId 's4' -CommitIndex '4' -FieldLines @(
            'provides: [implement-code]',
            'depends-on: []',
            'ac-refs: [AC4]'
        )
        $comment = & $script:NewPlanComment -PortLines @('  implement-test: [s4]') -SliceBlocks @($mismatchedSlice)
        $commentFile = & $script:WritePlanComment -Content $comment

        $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan', '-CommentFile', $commentFile)

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 's4'
        $result.Output | Should -Match 'implement-test'
        $result.Output | Should -Match 'implement-code'
        $result.Output | Should -Match '(?s)implement-test.*implement-code|implement-code.*implement-test'
    }

    It 'validates a documented plan with a bare frame-slice marker followed by YAML' {
        $documentedSlice = & $script:NewFrameSliceBlock -StepId 's4' -CommitIndex '4' -DocumentedBareMarker
        $comment = & $script:NewPlanComment -PortLines @('  implement-test: [s4]') -SliceBlocks @($documentedSlice)

        $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'PlanStructuralCoverage'
        $result.Output | Should -Not -Match '\(missing-id\)'
    }

    It 'warns when an acceptance criterion has no slice ac-refs coverage' {
        $sliceWithoutAc4 = & $script:NewFrameSliceBlock -StepId 's4' -CommitIndex '4' -FieldLines @(
            'provides: [implement-test]',
            'depends-on: []',
            'ac-refs: []'
        )
        $comment = & $script:NewPlanComment `
            -PortLines @('  implement-test: [s4]') `
            -AcceptanceCriteria @('- **AC4** Frame coverage validator catches missing acceptance criteria coverage.') `
            -SliceBlocks @($sliceWithoutAc4)
        $commentFile = & $script:WritePlanComment -Content $comment

        $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan', '-CommentFile', $commentFile)

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'coverage-gap'
        $result.Output | Should -Match 'AC4'
    }

    It 'rejects a present frame-spine block when canonical parsing fails' {
        $validSlice = & $script:NewFrameSliceBlock -StepId 's4' -CommitIndex '4'
        $comment = & $script:NewPlanComment -SliceBlocks @($validSlice)
        $comment = $comment -replace 'generated_at: 2026-05-04T15:00:00Z', 'generated_at: 05/04/2026 15:00'
        $commentFile = & $script:WritePlanComment -Content $comment

        $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan', '-CommentFile', $commentFile)

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Invalid canonical frame-spine block'
    }

    It 'accepts explicit plan-too-small spine omission without a frame-spine block' {
        $comment = @(
            '<!-- plan-issue-512 -->'
            '---'
            'status: approved'
            'issue_id: 512'
            'spine-omitted: plan-too-small'
            '---'
            ''
            '## Plan: Tiny cleanup'
            'Legacy plan body remains valid for fewer than three implementation steps.'
        ) -join "`n"

        $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'spine-omitted: plan-too-small'
    }

    It 'keeps default frame validation behavior available when no mode is supplied' {
        $result = & $script:InvokeFrameValidateCli -Arguments @('-RootPath', $script:RepoRoot)

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'AdapterSymmetry'
        $result.Output | Should -Match 'PredicateParse'
        $result.Output | Should -Match 'Frame-validate:'
    }
}
