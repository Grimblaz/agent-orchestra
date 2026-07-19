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
        $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-validate-core.ps1'

        if (Test-Path $script:LibFile) {
            . $script:LibFile
        }

        $script:InvokeFrameValidateCli = {
            param(
                [string[]]$Arguments = @(),
                [AllowNull()][string]$InputText
            )

            $invokeParameters = @{}
            for ($index = 0; $index -lt @($Arguments).Count; $index += 2) {
                $name = [string]$Arguments[$index]
                $value = if (($index + 1) -lt @($Arguments).Count) { [string]$Arguments[$index + 1] } else { '' }
                switch ($name) {
                    '-Mode' { $invokeParameters['Mode'] = $value }
                    '-CommentFile' { $invokeParameters['CommentFile'] = (Resolve-Path -LiteralPath $value).ProviderPath }
                    '-RootPath' { $invokeParameters['RootPath'] = $value }
                    default { throw "Unsupported frame-validate test argument '$name'." }
                }
            }

            if ($PSBoundParameters.ContainsKey('InputText')) {
                $invokeParameters['CommentText'] = $InputText
            }

            $validateResult = Invoke-FrameValidate @invokeParameters
            $outputLines = [System.Collections.Generic.List[string]]::new()
            foreach ($check in @($validateResult.Results)) {
                $prefix = if ($check.Passed) { '[PASS]' } else { '[FAIL]' }
                $detail = if ($check.Detail) { " - $($check.Detail)" } else { '' }
                $outputLines.Add("$prefix $($check.Name)$detail") | Out-Null
            }
            $outputLines.Add("Frame-validate: $($validateResult.PassCount)/$($validateResult.TotalCount) checks passed") | Out-Null

            return [PSCustomObject]@{
                ExitCode = [int]$validateResult.ExitCode
                Output   = [string](@($outputLines.ToArray()) -join "`n")
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

        # --- 872-D5 goal-contract variant fixtures ---
        # Dot-sourced so direct Test-GCVariantFrontmatter coverage and
        # goal-contract fixture construction share the one parser lib
        # (872-D6); frame-validate-core.ps1 does not yet dot-source this
        # file (that wiring is frame-slice s4, not yet implemented).
        $script:GCLibFile = Join-Path $script:RepoRoot '.github/scripts/lib/goal-contract-core.ps1'
        if (Test-Path $script:GCLibFile) {
            . $script:GCLibFile
        }

        $script:NewGCContractBlockLines = {
            param(
                [ValidateSet('valid', 'empty', 'malformed', 'schema-invalid-halt', 'schema-invalid-version')]
                [string]$Shape = 'valid',
                [string]$AcRef = 'AC2',
                [string]$IssueField = '872',
                [string]$ContractHash = ('0' * 64)
            )

            if ($Shape -eq 'empty') {
                return @('<!-- goal-contract', '-->')
            }

            if ($Shape -eq 'malformed') {
                # Unterminated flow-sequence: a genuine YAML syntax error,
                # not merely a schema violation.
                return @(
                    '<!-- goal-contract'
                    'schema_version: 1'
                    'issue: 872'
                    'targets: ['
                    '-->'
                )
            }

            $haltConditions = @('unachievable-target', 'invariant-conflict', 'budget-exhausted', 'gate-input-needed', 'chain-stage-failure')
            if ($Shape -eq 'schema-invalid-halt') {
                $haltConditions = @('unachievable-target', 'invariant-conflict', 'budget-exhausted')
            }
            $schemaVersion = if ($Shape -eq 'schema-invalid-version') { 2 } else { 1 }

            return @(
                '<!-- goal-contract'
                "schema_version: $schemaVersion"
                "issue: $IssueField"
                "contract_hash: `"$ContractHash`""
                'targets:'
                '  - id: T1'
                "    ac_ref: $AcRef"
                '    category: structure-presence'
                '    check: "pwsh -NoProfile -File .github/scripts/example-check.ps1"'
                '    expected: "exit 0; example check passes"'
                '    source: null'
                'invariants:'
                '  - full-pester-suite-no-new-failures'
                '  - test-diff-integrity'
                'evidence_obligations:'
                '  checkpoint_commits: per-target-green'
                '  run_log: "deviation entries + experience observations per checkpoint"'
                '  experience_obligations:'
                '    - scenario: S2'
                '      surface: cli'
                '  required_markers: [pipeline-metrics-credits, goal-run-class]'
                'general_experience_standard: "Canonical clause and four guardrails, verbatim from #848 D8."'
                "halt_conditions: [$($haltConditions -join ', ')]"
                'budget:'
                '  tokens: 100000'
                '  wall_clock: 4h'
                '  chain_sub_ceiling: 2'
                '  non_convergence: halt-report'
                '-->'
            )
        }

        # Builds a plan comment in the REAL persisted-comment shape: the
        # plan-issue and phase-containment-ledger-ref markers precede the
        # --- frontmatter fence (Issue-Planner.agent.md:132,
        # plan-authoring/SKILL.md:373), so the fence is never line 1. A
        # fixture without those markers cannot detect a strict-line-1
        # anchoring bug (872 plan step 3, M3 regression class).
        $script:NewGCPlanCommentBody = {
            param(
                [int]$IssueNumber = 872,
                [switch]$OmitVariantFrontmatter,
                [switch]$OmitPlanIssueMarker,
                [switch]$IncludePlanTooSmall,
                [switch]$IncludeSpineAndSlice,
                [AllowNull()][string[]]$ContractBlockLines = $null,
                [string[]]$AcceptanceCriteriaBullets = @('- **AC2** frame-validate accepts a goal-contract plan and still rejects a bare spine-less plan.'),
                [string[]]$ExtraProseLines = @()
            )

            $lines = [System.Collections.Generic.List[string]]::new()

            if (-not $OmitPlanIssueMarker) {
                $lines.Add("<!-- plan-issue-$IssueNumber -->") | Out-Null
            }
            $lines.Add('<!-- phase-containment-ledger-ref: 5016023361 -->') | Out-Null
            $lines.Add('') | Out-Null
            $lines.Add('---') | Out-Null
            $lines.Add('status: pending') | Out-Null
            $lines.Add("issue_id: $IssueNumber") | Out-Null
            if (-not $OmitVariantFrontmatter) {
                $lines.Add('plan-variant: goal-contract') | Out-Null
            }
            if ($IncludePlanTooSmall) {
                $lines.Add('spine-omitted: plan-too-small') | Out-Null
            }
            $lines.Add('---') | Out-Null
            $lines.Add('') | Out-Null
            $lines.Add("## Plan: Goal-contract fixture for issue $IssueNumber") | Out-Null
            $lines.Add('Fixture body for RED tests over the 872-D5 state matrix.') | Out-Null
            $lines.Add('') | Out-Null
            $lines.Add('## Acceptance Criteria') | Out-Null
            foreach ($bullet in $AcceptanceCriteriaBullets) { $lines.Add($bullet) | Out-Null }
            $lines.Add('') | Out-Null

            if ($IncludeSpineAndSlice) {
                $slice = & $script:NewFrameSliceBlock -StepId 's1' -CommitIndex '1' -FieldLines @(
                    'provides: [implement-test]',
                    'depends-on: []',
                    'ac-refs: [AC2]'
                )
                $lines.Add('<!-- frame-spine') | Out-Null
                $lines.Add('spine_schema_version: 1') | Out-Null
                $lines.Add('generated_at: 2026-07-19T00:00:00Z') | Out-Null
                $lines.Add('coverage: complete') | Out-Null
                $lines.Add('ports:') | Out-Null
                $lines.Add('  implement-test: [s1]') | Out-Null
                $lines.Add('slices:') | Out-Null
                $lines.Add('  s1:') | Out-Null
                $lines.Add('    execution_mode: serial') | Out-Null
                $lines.Add('    rc: fixture slice') | Out-Null
                $lines.Add('    ac_refs: [AC2]') | Out-Null
                $lines.Add('    depends_on: []') | Out-Null
                $lines.Add('    cycle: 1') | Out-Null
                $lines.Add('-->') | Out-Null
                $lines.Add('') | Out-Null
                $lines.Add($slice) | Out-Null
                $lines.Add('') | Out-Null
            }

            foreach ($prose in $ExtraProseLines) { $lines.Add($prose) | Out-Null }

            if ($null -ne $ContractBlockLines) {
                foreach ($contractLine in $ContractBlockLines) { $lines.Add($contractLine) | Out-Null }
            }

            return [string]($lines.ToArray() -join "`n")
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

    It 'does not false-match frame-slices-{ID} or frame-slices-generated-at sibling markers as frame-slice blocks (863 regression pin)' {
        $documentedSlice = & $script:NewFrameSliceBlock -StepId 's4' -CommitIndex '4'
        $siblingMarkers = @(
            '<!-- frame-slices-512 -->'
            '<!-- frame-slices-generated-at: 2026-05-04T15:00:00Z -->'
        ) -join "`n"
        $comment = & $script:NewPlanComment -PortLines @('  implement-test: [s4]') -SliceBlocks @($siblingMarkers, $documentedSlice)

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

    Context '872-D5 goal-contract variant plan mode (issue #872, frame-slice s3)' {

        It 'accepts a schema-valid goal-contract plan with no spine block (872-D5 row 1: yes/no/yes)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC2'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Be 0 -Because 'a schema-valid goal-contract plan with no spine block must be accepted'
            $result.Output | Should -Match 'PlanStructuralCoverage'
        }

        It 'rejects ambiguity when a plan declares the goal-contract variant and also carries a frame-spine block (872-D5 row 2: yes/yes/any)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC2'
            $comment = & $script:NewGCPlanCommentBody -IncludeSpineAndSlice -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'a variant-declared plan that also carries a frame-spine block is ambiguous per 872-D5 row 2'
            $result.Output | Should -Match '(?i)ambigu' -Because 'the failure detail must name the ambiguity, not merely fail generically'
        }

        It 'rejects a plan that declares the goal-contract variant but has neither a spine nor a contract block (872-D5 row 3: yes/no/no)' {
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $null

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'a variant declaration with no contract block and no spine must fail loudly'
            $result.Output | Should -Match '(?i)variant' -Because 'the failure must name the variant declaration, distinguishing it from the generic missing-spine message'
            $result.Output | Should -Match '(?i)contract block' -Because 'the failure must name the missing contract block specifically'
        }

        It 'rejects a spine-less plan carrying a contract block that omits the goal-contract variant frontmatter (872-D5 row 4: no/any/yes)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC2'
            $comment = & $script:NewGCPlanCommentBody -OmitVariantFrontmatter -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'a contract block without plan-variant: goal-contract frontmatter must fail per 872-D5 row 4'
            $result.Output | Should -Match '(?i)variant' -Because 'the failure must name the missing variant declaration'
            $result.Output | Should -Match '(?i)contract block' -Because 'the failure must name the contract block that triggered it'
        }

        It 'leaves the existing frame-spine path unchanged for a plan with neither variant frontmatter nor a contract block (872-D5 row 5: no/yes/no)' {
            $comment = & $script:NewGCPlanCommentBody -OmitVariantFrontmatter -IncludeSpineAndSlice -ContractBlockLines $null

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Be 0 -Because '872-D5 row 5 (existing spine path) must be behaviorally unchanged'
            $result.Output | Should -Match 'PlanStructuralCoverage'
        }

        It 'leaves the bare spine-less rejection message unchanged for a plan with neither variant, spine, nor contract block (872-D5 row 6: no/no/no)' {
            $comment = & $script:NewGCPlanCommentBody -OmitVariantFrontmatter -ContractBlockLines $null

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because '872-D5 row 6 (bare spine-less fail) must be behaviorally unchanged'
            $result.Output | Should -Match ([regex]::Escape('Missing frame-spine block.')) -Because 'the unchanged bare spine-less message must be verbatim'
        }

        It 'hard-fails a goal-contract plan whose schema_version is not the accepted value (schema_version gate)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'schema-invalid-version' -AcRef 'AC2'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'an unsupported schema_version must be a loud, hard failure'
            $result.Output | Should -Match 'PlanStructuralCoverage'
            $result.Output | Should -Match '(?i)schema_version'
        }

        It 'hard-fails a goal-contract plan whose target ac_ref is absent from the Acceptance Criteria section (ac_ref membership failure)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC9'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines -AcceptanceCriteriaBullets @('- **AC2** frame-validate accepts a goal-contract plan and still rejects a bare spine-less plan.')

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'a target ac_ref with no matching Acceptance Criteria entry is a membership failure, not a warn-only gap'
            $result.Output | Should -Match 'AC9'
        }

        It 'warns without failing when an Acceptance Criteria entry has no matching contract target (warn-only reverse-coverage row)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC2'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines -AcceptanceCriteriaBullets @(
                '- **AC2** frame-validate accepts a goal-contract plan and still rejects a bare spine-less plan.'
                '- **AC3** uncovered acceptance criterion with no contract target.'
            )

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Be 0 -Because 'the reverse AC-coverage direction is warn-only, mirroring the spine path'
            $result.Output | Should -Match '(?i)coverage-gap'
            $result.Output | Should -Match 'AC3'
        }

        It 'surfaces a distinct message for an empty goal-contract block payload (empty/unparseable-block row)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'empty'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'an empty goal-contract payload cannot validate against the schema'
            $result.Output | Should -Match '(?i)empty' -Because 'the failure must distinguish an empty payload from a generic missing-spine message'
        }

        It 'surfaces a distinct message for an unparseable (malformed YAML) goal-contract block (empty/unparseable-block row)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'malformed'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'malformed YAML in the contract block must fail loudly'
            $result.Output | Should -Match '(?i)(pars|yaml|malform|invalid)' -Because 'the failure must name the parse problem, not a generic missing-spine message'
        }

        It 'captures a schema-invalid contract as a named PlanStructuralCoverage failure, never the outer FrameValidate catch (EAP=Stop regression guard, frame-validate-core.ps1:555-556)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'schema-invalid-halt' -AcRef 'AC2'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'a schema-invalid contract must fail'
            $result.Output | Should -Match '(?i)halt_conditions' -Because 'the schema violation detail must be captured, not swallowed by a terminating-error catch'
            $result.Output | Should -Match '\[FAIL\] PlanStructuralCoverage' -Because 'the check name must remain PlanStructuralCoverage'
            $result.Output | Should -Not -Match '\[FAIL\] FrameValidate' -Because 'Test-Json running under $ErrorActionPreference = ''Stop'' must never be promoted to the outer FrameValidate catch-all'
        }

        It 'resolves the plan-too-small x goal-contract-variant cross by routing to the variant branch (872-D5 precedence, identical to orchestra-spine)' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC2'
            $comment = & $script:NewGCPlanCommentBody -IncludePlanTooSmall -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Be 0 -Because 'the variant branch must win over the legacy plan-too-small escape'
            $result.Output | Should -Not -Match 'spine-omitted: plan-too-small' -Because 'a variant-declared plan must not fall through to the legacy plan-too-small escape detail'
        }

        It 'passes the conditional issue: cross-check when the contract issue: field matches the plan-issue-{ID} marker' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC2' -IssueField '872'
            $comment = & $script:NewGCPlanCommentBody -IssueNumber 872 -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Be 0 -Because 'a matching issue: field must not be treated as a violation'
        }

        It 'hard-fails the conditional issue: cross-check when the contract issue: field does not match the plan-issue-{ID} marker' {
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC2' -IssueField '999'
            $comment = & $script:NewGCPlanCommentBody -IssueNumber 872 -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Not -Be 0 -Because 'a contract issue: field that disagrees with the plan-issue-{ID} marker must fail'
            $result.Output | Should -Match '(?i)issue'
            $result.Output | Should -Match '872'
            $result.Output | Should -Match '999'
        }

        It 'skips the conditional issue: cross-check when no plan-issue-{ID} marker is present in the comment body' {
            # Deliberately unrealistic fixture (omits the plan-issue marker) to
            # exercise the documented "absent -> skipped" fallback; every OTHER
            # test in this file keeps the real persisted markers per the slice's
            # fixture-realism requirement.
            $contractLines = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC2' -IssueField '999'
            $comment = & $script:NewGCPlanCommentBody -IssueNumber 872 -OmitPlanIssueMarker -ContractBlockLines $contractLines

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Be 0 -Because 'with no plan-issue-{ID} marker to compare against, the issue: cross-check must be skipped rather than failed'
        }

        It 'does not route a frame-spine plan quoting the literal plan-variant: goal-contract in prose to the variant branch (false-positive guard 1 of 2)' {
            $comment = & $script:NewGCPlanCommentBody -OmitVariantFrontmatter -IncludeSpineAndSlice -ContractBlockLines $null -ExtraProseLines @(
                'Authoring note: some plans declare'
                'plan-variant: goal-contract'
                'at the start of a prose line for illustration purposes only.'
                ''
            )

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Be 0 -Because 'a body-wide quoted literal outside the real frontmatter region must not trigger the variant branch'
            $result.Output | Should -Match 'PlanStructuralCoverage'
        }

        It 'does not trip the contract-block-without-variant-metadata row for a frame-spine plan whose prose contains a fenced goal-contract example block (false-positive guard 2 of 2)' {
            $exampleBlock = & $script:NewGCContractBlockLines -Shape 'valid' -AcRef 'AC1'
            $fencedExample = @('Authoring example for reference:', '', '```text') + $exampleBlock + @('```', '')
            $comment = & $script:NewGCPlanCommentBody -OmitVariantFrontmatter -IncludeSpineAndSlice -ContractBlockLines $null -ExtraProseLines $fencedExample

            $result = & $script:InvokeFrameValidateCli -Arguments @('-Mode', 'plan') -InputText $comment

            $result.ExitCode | Should -Be 0 -Because 'a fenced documentation example must not be treated as a real contract block absent variant metadata'
            $result.Output | Should -Match 'PlanStructuralCoverage'
        }

        It 'Test-GCVariantFrontmatter recognizes plan-variant: goal-contract anchored in the real frontmatter region following persist-time marker lines' {
            (Get-Command Test-GCVariantFrontmatter -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'goal-contract-core.ps1 (frame-slice s2) must define Test-GCVariantFrontmatter'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $null

            Test-GCVariantFrontmatter -CommentBody $comment | Should -BeTrue
        }

        It 'Test-GCVariantFrontmatter returns false when the literal appears only in body prose, not inside the frontmatter region' {
            (Get-Command Test-GCVariantFrontmatter -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'goal-contract-core.ps1 (frame-slice s2) must define Test-GCVariantFrontmatter'
            $comment = & $script:NewGCPlanCommentBody -OmitVariantFrontmatter -ContractBlockLines $null -ExtraProseLines @('plan-variant: goal-contract', 'quoted here as documentation prose only.')

            Test-GCVariantFrontmatter -CommentBody $comment | Should -BeFalse
        }

        It 'Test-GCVariantFrontmatter tolerates multiple leading marker lines before the frontmatter fence' {
            (Get-Command Test-GCVariantFrontmatter -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'goal-contract-core.ps1 (frame-slice s2) must define Test-GCVariantFrontmatter'
            $comment = & $script:NewGCPlanCommentBody -ContractBlockLines $null

            # Sanity: the fixture builder places two marker lines (plan-issue,
            # phase-containment-ledger-ref) plus a blank line before the fence.
            ($comment -split "`n")[0] | Should -Match '^<!-- plan-issue-'
            ($comment -split "`n")[1] | Should -Match '^<!-- phase-containment-ledger-ref'

            Test-GCVariantFrontmatter -CommentBody $comment | Should -BeTrue
        }
    }
}
