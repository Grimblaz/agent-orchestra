#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED->GREEN tests for frame-spine-core.ps1 stdin pipe and JSON output mode (issue #514, Step 1).

.DESCRIPTION
    Tests the -CommentBodyStdin switch and -Format Json parameter added in Step 2.
    At Step 1 RED these tests fail because those parameters don't exist yet.
    Wrapper-level codes (gh-not-installed, gh-auth-expired, gh-rate-limited) are out of scope;
    tested at the platform shim layer, not here.
#>

Describe 'frame-spine-core stdin and JSON output' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-spine-core.ps1'

        if (Test-Path $script:LibFile) {
            . $script:LibFile
        }

        # Canonical spine block for case 1 (non-ASCII per M12 requirement):
        # rc field contains em-dash (U+2014), smart quotes (U+201C U+201D), and accented character
        $script:CanonicalSpineBlockNonAscii = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-04T14:30:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code: [s2]'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    rc: GREEN code — résumé "action"'
            '    ac_refs: [AC1, AC2]'
            '    depends_on: []'
            '    cycle: 1'
        ) -join "`n"

        # Canonical spine block for cases 2-6 (ASCII only, simpler)
        $script:CanonicalSpineBlock = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-04T14:30:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code: [s2]'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    rc: GREEN code action'
            '    ac_refs: [AC1, AC2]'
            '    depends_on: []'
            '    cycle: 1'
        ) -join "`n"

        $script:CanonicalSpineBlockV2WithoutAdapter = @(
            'spine_schema_version: 2'
            'generated_at: 2026-05-11T10:00:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code: [s2]'
            '  implement-test: [s3#terminal]'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    rc: GREEN code action'
            '    ac_refs: [AC1]'
            '    depends_on: []'
            '    cycle: 1'
            '  s3:'
            '    execution_mode: serial'
            '    rc: RED tests for v2 schema acceptance'
            '    ac_refs: [AC1, AC5, AC7]'
            '    depends_on: [s2]'
            '    cycle: 1'
            '    terminal: true'
        ) -join "`n"

        # Slice block for non-ASCII case (id/provides style)
        $script:S2SliceBlockNonAscii = @(
            'id: s2'
            'provides: [implement-code]'
            'execution_mode: serial'
            'rc: GREEN code — résumé "action"'
            'ac_refs: [AC1, AC2]'
            'depends_on: []'
            'cycle: 1'
        ) -join "`n"

        # Slice block for ASCII cases (id/provides style)
        $script:S2SliceBlock = @(
            'id: s2'
            'provides: [implement-code]'
            'execution_mode: serial'
            'rc: GREEN code action'
            'ac_refs: [AC1, AC2]'
            'depends_on: []'
            'cycle: 1'
        ) -join "`n"

        $script:S3SliceBlockV2WithoutAdapter = @(
            'id: s3'
            'provides: [implement-test]'
            'execution_mode: serial'
            'rc: RED tests for v2 schema acceptance'
            'ac_refs: [AC1, AC5, AC7]'
            'depends_on: [s2]'
            'cycle: 1'
            'terminal: true'
        ) -join "`n"

        # Full comment body with non-ASCII spine + slice (for case 1)
        $script:LookupCommentBodyNonAscii = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlockNonAscii
            '-->'
            ''
            '<!-- frame-slice'
            $script:S2SliceBlockNonAscii
            '-->'
        ) -join "`n"

        # Full comment body with ASCII spine + slice (for cases 2-6)
        $script:LookupCommentBody = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlock
            '-->'
            ''
            '<!-- frame-slice'
            $script:S2SliceBlock
            '-->'
        ) -join "`n"

        $script:LookupCommentBodyV2WithoutAdapter = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlockV2WithoutAdapter
            '-->'
            ''
            '<!-- frame-slice'
            $script:S3SliceBlockV2WithoutAdapter
            '-->'
        ) -join "`n"

        # Fixtures for the 863-D3/AC5 slice-sibling generated_at cross-check.
        $script:CanonicalSpineBlockWithPointer = @(
            'spine_schema_version: 2'
            'generated_at: 2026-07-16T18:00:00Z'
            'coverage: complete'
            'slice_comment_id: 4995965999'
            'ports:'
            '  implement-code: [s2]'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    rc: GREEN code action'
            '    ac_refs: [AC1, AC2]'
            '    depends_on: []'
            '    cycle: 1'
        ) -join "`n"

        $script:S2SliceBlockWithPointer = @(
            'id: s2'
            'provides: [implement-code]'
            'execution_mode: serial'
            'rc: GREEN code action'
            'ac_refs: [AC1, AC2]'
            'depends_on: []'
            'cycle: 1'
        ) -join "`n"

        # Sibling marker matches the spine's generated_at (fresh, no drift).
        $script:LookupCommentBodyWithFreshSibling = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlockWithPointer
            '-->'
            ''
            '<!-- frame-slices-4995965999 -->'
            '<!-- frame-slices-generated-at: 2026-07-16T18:00:00Z -->'
            ''
            '<!-- frame-slice'
            $script:S2SliceBlockWithPointer
            '-->'
        ) -join "`n"

        # Sibling marker diverges from the spine's generated_at (torn: fresh spine + stale sibling).
        $script:LookupCommentBodyWithStaleSibling = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlockWithPointer
            '-->'
            ''
            '<!-- frame-slices-4995965999 -->'
            '<!-- frame-slices-generated-at: 2026-07-16T10:00:00Z -->'
            ''
            '<!-- frame-slice'
            $script:S2SliceBlockWithPointer
            '-->'
        ) -join "`n"

        # slice_comment_id present, but the sibling's frame-slices-generated-at marker is missing
        # entirely -- a writer defect, not legacy history.
        $script:LookupCommentBodyWithUnstampedSibling = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlockWithPointer
            '-->'
            ''
            '<!-- frame-slices-4995965999 -->'
            ''
            '<!-- frame-slice'
            $script:S2SliceBlockWithPointer
            '-->'
        ) -join "`n"

        # Two frame-slice blocks sharing the same step id in one concatenated body (863-D2 assumes
        # caller-side concatenation already happened before this function runs).
        $script:LookupCommentBodyWithDuplicateSlice = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlock
            '-->'
            ''
            '<!-- frame-slice'
            $script:S2SliceBlock
            '-->'
            ''
            '<!-- frame-slice'
            $script:S2SliceBlock
            '-->'
        ) -join "`n"

        # Helper: write content to a temp file on TestDrive with UTF-8 NoBOM encoding
        $script:WriteCommentBody = {
            param([Parameter(Mandatory)][string]$Content)
            $path = Join-Path -Path 'TestDrive:' -ChildPath "fsc-core-$([System.Guid]::NewGuid().ToString('N')).md"
            Set-Content -Path $path -Value $Content -Encoding utf8NoBOM
            return $path
        }
    }

    # Invariant: existing text-mode behavior is unchanged (Text default back-compat)
    It 'existing text-mode lookup returns status: ok without -Format parameter (back-compat invariant)' {
        $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBody
        $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

        $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -GeneratedAt '2026-05-04T14:30:00Z' -StepId 's2'

        $result | Should -Not -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $outputText = ($result.Lines) -join "`n"
        $outputText | Should -Match 'status:\s*ok'
    }

    Context 'Case 1: -CommentBodyStdin parity with -CommentBodyPath + non-ASCII fixture (M12)' {

        It 'stdin subprocess output matches file-based output: both status ok and step_id s2 with non-ASCII payload' {
            $ts = '2026-05-04T14:30:00Z'
            $stepId = 's2'

            # Write the non-ASCII body to a temp file for the file-based call
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBodyNonAscii
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            # File-based call: Invoke-FSCSpineLookupCli -CommentBodyPath ... -Format Json
            $fileResult = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt $ts -StepId $stepId
            $fileJson = ($fileResult.Lines) -join "`n" | ConvertFrom-Json

            # Stdin subprocess call: pipe body via stdin
            $stdinOutput = $script:LookupCommentBodyNonAscii |
                pwsh -NoProfile -NonInteractive -File $script:LibFile -Op Lookup -CommentBodyStdin -Format Json -GeneratedAt $ts -StepId $stepId
            $stdinJson = ($stdinOutput) -join "`n" | ConvertFrom-Json

            # Both must return status ok
            $fileJson.status | Should -Be 'ok'
            $stdinJson.status | Should -Be 'ok'

            # Both must return the same step_id
            $fileJson.step_id | Should -Be $stepId
            $stdinJson.step_id | Should -Be $stepId

            # Both step_ids must match each other
            $fileJson.step_id | Should -Be $stdinJson.step_id
        }
    }

    Context 'Case 2: -Format Json returns valid JSON on successful lookup' {

        It 'returns JSON with status ok, step_id s2, and generated_at present' {
            $ts = '2026-05-04T14:30:00Z'
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBody
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt $ts -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $result.Lines | Should -Not -BeNullOrEmpty

            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'ok'
            $parsed.step_id | Should -Be 's2'
            $parsed.PSObject.Properties['generated_at'] | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Case 3: -Format Json returns stale-spine JSON on generated_at mismatch' {

        It 'returns JSON with status stale-spine and both dispatched and current generated_at fields' {
            $wrongTs = '2026-05-04T14:29:00Z'
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBody
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt $wrongTs -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'stale-spine'
            $parsed.PSObject.Properties['dispatched_generated_at'] | Should -Not -BeNullOrEmpty
            $parsed.PSObject.Properties['current_generated_at'] | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Case 4: -Format Json returns missing-spine when comment lacks a frame-spine block' {

        It 'returns JSON with status missing-spine when no spine block present' {
            $plainProse = 'This is just a plain issue comment with no spine block at all.'
            $commentFile = & $script:WriteCommentBody -Content $plainProse
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-05-04T14:30:00Z' -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'missing-spine'
        }
    }

    Context 'Case 5: -Format Json returns invalid-spine when spine block is malformed' {

        It 'returns JSON with status invalid-spine when spine block lacks required fields' {
            # Spine block with no slices: section — missing required slices field
            $malformedSpineBlock = @(
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T14:30:00Z'
                'coverage: complete'
                'ports:'
                '  implement-code: [s2]'
            ) -join "`n"

            $bodyWithMalformedSpine = @(
                'Issue discussion.'
                ''
                '<!-- frame-spine'
                $malformedSpineBlock
                '-->'
            ) -join "`n"

            $commentFile = & $script:WriteCommentBody -Content $bodyWithMalformedSpine
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-05-04T14:30:00Z' -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'invalid-spine'
        }
    }

    Context 'Case 6: -Format Json returns missing-slice when requested step ID not in spine' {

        It 'returns JSON with status missing-slice and step_id s99 when s99 not present in spine' {
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBody
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-05-04T14:30:00Z' -StepId 's99'

            $result | Should -Not -BeNullOrEmpty
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'missing-slice'
            $parsed.step_id | Should -Be 's99'
        }
    }

    Context 'Case 7: schema v2 lookup remains compatible with adapter-optional slices' {

        It 'returns the requested v2 slice when the frame-slice block omits adapter' {
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBodyV2WithoutAdapter
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-05-11T10:00:00Z' -StepId 's3'

            $result | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'ok'
            $parsed.step_id | Should -Be 's3'
            $parsed.slice | Should -Match 'provides:\s*\[implement-test\]'
            $parsed.slice | Should -Not -Match '(?m)^adapter:'
        }
    }

    Context 'Case 8: slice-sibling generated_at cross-check (863-D3/AC5)' {

        It 'returns stale-spine JSON when the sibling marker diverges from the spine generated_at' {
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBodyWithStaleSibling
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-07-16T18:00:00Z' -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'stale-spine'
            $parsed.PSObject.Properties['current_generated_at'] | Should -Not -BeNullOrEmpty
            $parsed.PSObject.Properties['sibling_generated_at'] | Should -Not -BeNullOrEmpty
            $parsed.sibling_generated_at | Should -Not -Be $parsed.current_generated_at
        }

        It 'returns ok when the sibling marker matches the spine generated_at' {
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBodyWithFreshSibling
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-07-16T18:00:00Z' -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'ok'
            $parsed.step_id | Should -Be 's2'
        }

        It 'fails loud with sibling-unstamped when slice_comment_id is present but the sibling marker is absent (defect, not history)' {
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBodyWithUnstampedSibling
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-07-16T18:00:00Z' -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -Be 1
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'sibling-unstamped'
            $parsed.PSObject.Properties['slice_comment_id'] | Should -Not -BeNullOrEmpty
        }

        It 'skips the cross-check entirely for a legacy spine with no slice_comment_id pointer' {
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBody
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-05-04T14:30:00Z' -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'ok'
        }

        It 'fails loud with duplicate-slice-id when the concatenated corpus carries two frame-slice blocks for the same step id' {
            $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBodyWithDuplicateSlice
            $resolvedPath = (Resolve-Path -LiteralPath $commentFile).ProviderPath

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $resolvedPath -Format Json -GeneratedAt '2026-05-04T14:30:00Z' -StepId 's2'

            $result | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -Be 1
            $jsonText = ($result.Lines) -join "`n"
            $parsed = $jsonText | ConvertFrom-Json

            $parsed.status | Should -Be 'duplicate-slice-id'
            $parsed.step_id | Should -Be 's2'
            $parsed.count | Should -Be 2
        }
    }
}
