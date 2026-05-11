#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for the frame spine and slice parser pure-logic library (issue #512, Step 2 RED).
#
# Library under test: .github/scripts/lib/frame-spine-core.ps1
# At Step 2 RED the library does NOT exist yet, so the dot-source is guarded and
# every It-block exercises a public function. Calls fail with CommandNotFoundException
# until the GREEN lane lands the production parser.

Describe 'frame spine parser' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github/scripts/lib/frame-spine-core.ps1'

        if (Test-Path $script:LibFile) {
            . $script:LibFile
        }

        $script:CanonicalSpineBlock = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-04T14:30:00Z'
            'coverage: complete'
            'ports:'
            '  ce-gate-api: [s8#cycle:3#terminal]'
            '  implement-code: [s2, s5]'
            '  implement-test: [s3]'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    rc: GREEN code action'
            '    ac_refs: [AC1, AC2]'
            '    depends_on: []'
            '    cycle: 1'
            '  s5:'
            '    execution_mode: parallel'
            '    rc: GREEN code/test action'
            '    ac_refs: [AC4]'
            '    depends_on: [s2]'
            '    cycle: 2'
            '  s8:'
            '    execution_mode: serial'
            '    rc: CE Gate evidence capture'
            '    ac_refs: [AC9]'
            '    depends_on: [s5]'
            '    cycle: 3'
            '    terminal: true'
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

        $script:CanonicalSpineBlockV2WithAdapters = @(
            'spine_schema_version: 2'
            'generated_at: 2026-05-11T10:05:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code: [s2]'
            '  implement-test: [s3#terminal]'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    adapter: code-smith'
            '    rc: GREEN code action'
            '    ac_refs: [AC1]'
            '    depends_on: []'
            '    cycle: 1'
            '  s3:'
            '    execution_mode: serial'
            '    adapter: test-writer'
            '    rc: RED tests for v2 schema acceptance'
            '    ac_refs: [AC1, AC5, AC7]'
            '    depends_on: [s2]'
            '    cycle: 1'
            '    terminal: true'
        ) -join "`n"

        $script:S2SliceBlock = @(
            'step_id: s2'
            'ports: [implement-code]'
            'execution_mode: serial'
            'rc: GREEN code action'
            'ac_refs: [AC1, AC2]'
            'depends_on: []'
            'cycle: 1'
        ) -join "`n"

        $script:S2ProvidesSliceBlock = @(
            'id: s2'
            'provides: [implement-code]'
            'execution_mode: serial'
            'rc: GREEN code action'
            'ac_refs: [AC1, AC2]'
            'depends_on: []'
            'cycle: 1'
        ) -join "`n"

        $script:S5SliceBlock = @(
            'step_id: s5'
            'ports: [implement-code]'
            'execution_mode: parallel'
            'rc: GREEN code/test action'
            'ac_refs: [AC4]'
            'depends_on: [s2]'
            'cycle: 2'
        ) -join "`n"

        $script:S3SliceBlock = @(
            'step_id: s3'
            'ports: [implement-test]'
            'execution_mode: serial'
            'rc: RED test action'
            'ac_refs: [AC1, AC2]'
            'depends_on: [s2]'
            'cycle: 1'
        ) -join "`n"

        $script:CommentBody = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlock
            '-->'
            ''
            'Planning prose between machine-readable blocks.'
            ''
            '<!-- frame-slice'
            $script:S2SliceBlock
            '-->'
            ''
            '<!-- frame-slice'
            $script:S5SliceBlock
            '-->'
            ''
            '<!-- frame-slice'
            $script:S3SliceBlock
            '-->'
            ''
            'Trailing issue comment prose.'
        ) -join "`n"

        $script:LookupCommentBody = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlock
            '-->'
            ''
            '<!-- frame-slice'
            $script:S2ProvidesSliceBlock
            '-->'
        ) -join "`n"

        $script:GetPortEntries = {
            param(
                [Parameter(Mandatory)]$ParsedSpine,
                [Parameter(Mandatory)][string]$PortName
            )

            $ports = $ParsedSpine.Ports
            $ports | Should -Not -BeNullOrEmpty

            if ($ports -is [System.Collections.IDictionary]) {
                $ports.Contains($PortName) | Should -BeTrue
                return @($ports[$PortName])
            }

            $property = $ports.PSObject.Properties[$PortName]
            $property | Should -Not -BeNullOrEmpty
            return @($property.Value)
        }

        $script:AssertStepToken = {
            param(
                [Parameter(Mandatory)]$Token,
                [Parameter(Mandatory)][string]$StepId,
                [Parameter(Mandatory)][int]$Cycle,
                [Parameter(Mandatory)][bool]$Terminal
            )

            $Token.PSObject.Properties['StepId'] | Should -Not -BeNullOrEmpty
            $Token.PSObject.Properties['Cycle'] | Should -Not -BeNullOrEmpty
            $Token.PSObject.Properties['Terminal'] | Should -Not -BeNullOrEmpty
            $Token.StepId | Should -Be $StepId
            $Token.Cycle | Should -Be $Cycle
            $Token.Terminal | Should -Be $Terminal
        }

        $script:WriteCommentBody = {
            param([Parameter(Mandatory)][string]$Content)

            $path = Join-Path -Path 'TestDrive:' -ChildPath "frame-spine-comment-$([System.Guid]::NewGuid().ToString('N')).md"
            Set-Content -Path $path -Value $Content -Encoding utf8NoBOM
            return $path
        }

        $script:InvokeLookupCli = {
            param(
                [Parameter(Mandatory)][string]$CommentBodyPath,
                [Parameter(Mandatory)][string]$GeneratedAt,
                [Parameter(Mandatory)][string]$StepId
            )

            $resolvedCommentBodyPath = (Resolve-Path -LiteralPath $CommentBodyPath).ProviderPath
            $lookupResult = Invoke-FSCCommand -Op Lookup -CommentBodyPath $resolvedCommentBodyPath -GeneratedAt $GeneratedAt -StepId $StepId
            return [PSCustomObject]@{
                ExitCode = [int]$lookupResult.ExitCode
                Output   = [string](@($lookupResult.Lines | ForEach-Object { [string]$_ }) -join "`n")
            }
        }
    }

    It 'ships the in-process frame spine parser library and public function surface' {
        $script:LibFile | Should -Exist

        foreach ($functionName in @(
                'Get-FSCSpineBlock'
                'Get-FSCSliceBlocksByStepId'
                'Get-FSCSliceBlocksByPort'
                'Test-FSCCanonicalForm'
                'ConvertFrom-FSCSpineYaml'
            )) {
            $result = Get-Command $functionName -ErrorAction SilentlyContinue
            $result | Should -Not -BeNullOrEmpty
            $null = $result
        }
    }

    It 'extracts the frame-spine YAML payload from a GitHub comment blob' {
        $spineBlock = Get-FSCSpineBlock -CommentBody $script:CommentBody

        $spineBlock | Should -BeExactly $script:CanonicalSpineBlock
    }

    It 'extracts a frame-slice block by step ID' {
        $sliceBlocks = @(Get-FSCSliceBlocksByStepId -CommentBody $script:CommentBody -StepId 's2')

        $sliceBlocks | Should -HaveCount 1
        $sliceBlocks[0] | Should -BeExactly $script:S2SliceBlock
    }

    It 'extracts a bare frame-slice block addressed by id and provides fields' {
        $commentBody = @(
            '<!-- frame-slice'
            $script:S2ProvidesSliceBlock
            '-->'
        ) -join "`n"

        $byStepId = @(Get-FSCSliceBlocksByStepId -CommentBody $commentBody -StepId 's2')
        $byPort = @(Get-FSCSliceBlocksByPort -CommentBody $commentBody -PortName 'implement-code')

        $byStepId | Should -HaveCount 1
        $byPort | Should -HaveCount 1
        $byStepId[0] | Should -BeExactly $script:S2ProvidesSliceBlock
        $byPort[0] | Should -BeExactly $script:S2ProvidesSliceBlock
    }

    It 'extracts a documented bare frame-slice marker followed by a YAML payload' {
        $commentBody = @(
            '<!-- frame-slice -->'
            $script:S2ProvidesSliceBlock
            '-->'
        ) -join "`n"

        $byStepId = @(Get-FSCSliceBlocksByStepId -CommentBody $commentBody -StepId 's2')
        $byPort = @(Get-FSCSliceBlocksByPort -CommentBody $commentBody -PortName 'implement-code')

        $byStepId | Should -HaveCount 1
        $byPort | Should -HaveCount 1
        $byStepId[0] | Should -BeExactly $script:S2ProvidesSliceBlock
        $byPort[0] | Should -BeExactly $script:S2ProvidesSliceBlock
    }

    It 'extracts every frame-slice block for a port name' {
        $sliceBlocks = @(Get-FSCSliceBlocksByPort -CommentBody $script:CommentBody -PortName 'implement-code')

        $sliceBlocks | Should -HaveCount 2
        $sliceBlocks | Should -Contain $script:S2SliceBlock
        $sliceBlocks | Should -Contain $script:S5SliceBlock
    }

    It 'round-trips canonical spine YAML through parse and serialize without byte changes' {
        $parsed = ConvertFrom-FSCSpineYaml -SpineBlock $script:CanonicalSpineBlock

        $parsed | Should -Not -BeNullOrEmpty
        $parsed.CanonicalYaml | Should -BeExactly $script:CanonicalSpineBlock
        Test-FSCCanonicalForm -SpineBlock $script:CanonicalSpineBlock | Should -BeTrue
    }

    It 'accepts schema v2 spine YAML without requiring adapter fields on slices' {
        $parsed = ConvertFrom-FSCSpineYaml -SpineBlock $script:CanonicalSpineBlockV2WithoutAdapter

        $parsed | Should -Not -BeNullOrEmpty
        $parsed.CanonicalYaml | Should -BeExactly $script:CanonicalSpineBlockV2WithoutAdapter
        $parsed.CanonicalYaml | Should -Not -Match '(?m)^\s+adapter:'
        $parsed.Slices | Should -HaveCount 2

        $tokens = @(& $script:GetPortEntries -ParsedSpine $parsed -PortName 'implement-test')
        $tokens | Should -HaveCount 1
        & $script:AssertStepToken -Token $tokens[0] -StepId 's3' -Cycle 1 -Terminal $true
    }

    It 'accepts schema v2 spine YAML when each slice declares an adapter' {
        $parsed = ConvertFrom-FSCSpineYaml -SpineBlock $script:CanonicalSpineBlockV2WithAdapters

        $parsed | Should -Not -BeNullOrEmpty
        $parsed.CanonicalYaml | Should -BeExactly $script:CanonicalSpineBlockV2WithAdapters
        $parsed.CanonicalYaml | Should -Match '(?m)^    adapter: code-smith$'
        $parsed.CanonicalYaml | Should -Match '(?m)^    adapter: test-writer$'

        $tokens = @(& $script:GetPortEntries -ParsedSpine $parsed -PortName 'implement-test')
        $tokens | Should -HaveCount 1
        & $script:AssertStepToken -Token $tokens[0] -StepId 's3' -Cycle 1 -Terminal $true
    }

    It 'executes the documented lookup CLI and returns the requested slice content' {
        $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBody

        $result = & $script:InvokeLookupCli -CommentBodyPath $commentFile -GeneratedAt '2026-05-04T14:30:00Z' -StepId 's2'
        $lookupExitCode = $result.ExitCode
        $lookupOutput = $result.Output

        $lookupExitCode | Should -Be 0
        $lookupOutput | Should -Not -BeNullOrEmpty
        $lookupOutput | Should -Match 'status:\s*ok'
        $lookupOutput | Should -Match 'step_id:\s*s2'
        $lookupOutput | Should -Match 'provides:\s*\[implement-code\]'
        $null = $result
    }

    It 'executes lookup against a documented bare frame-slice marker followed by YAML' {
        $commentBody = @(
            'Issue discussion before the durable handoff.'
            ''
            '<!-- frame-spine'
            $script:CanonicalSpineBlock
            '-->'
            ''
            '<!-- frame-slice -->'
            $script:S2ProvidesSliceBlock
            '-->'
        ) -join "`n"
        $commentFile = & $script:WriteCommentBody -Content $commentBody

        $result = & $script:InvokeLookupCli -CommentBodyPath $commentFile -GeneratedAt '2026-05-04T14:30:00Z' -StepId 's2'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'status:\s*ok'
        $result.Output | Should -Match 'step_id:\s*s2'
        $result.Output | Should -Match 'provides:\s*\[implement-code\]'
        $null = $result
    }

    It 'executes the documented lookup CLI and reports stale-spine on generated_at mismatch' {
        $commentFile = & $script:WriteCommentBody -Content $script:LookupCommentBody

        $result = & $script:InvokeLookupCli -CommentBodyPath $commentFile -GeneratedAt '2026-05-04T14:29:00Z' -StepId 's2'
        $lookupExitCode = $result.ExitCode
        $lookupOutput = $result.Output

        $lookupExitCode | Should -Be 0
        $lookupOutput | Should -Match 'stale-spine'
        $lookupOutput | Should -Match '2026-05-04T14:29:00Z'
        $lookupOutput | Should -Match '2026-05-04T14:30:00Z'
        $null = $result
    }

    It 'parses generated_at as ISO-8601 UTC and rejects invalid generated_at gracefully' {
        $parsed = ConvertFrom-FSCSpineYaml -SpineBlock $script:CanonicalSpineBlock
        $parsed | Should -Not -BeNullOrEmpty
        $parsed.GeneratedAt | Should -BeOfType [System.DateTimeOffset]
        $parsed.GeneratedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-05-04T14:30:00Z'

        $invalidGeneratedAt = $script:CanonicalSpineBlock -replace 'generated_at: 2026-05-04T14:30:00Z', 'generated_at: 05/04/2026 14:30'
        $invalidGeneratedAtError = $null

        try {
            ConvertFrom-FSCSpineYaml -SpineBlock $invalidGeneratedAt | Should -BeNullOrEmpty
        }
        catch {
            $invalidGeneratedAtError = $_.Exception.Message
        }

        $invalidGeneratedAtError | Should -BeNullOrEmpty
    }

    It 'enforces deterministic alphabetical ordering for port keys' {
        $nonCanonical = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-04T14:30:00Z'
            'coverage: complete'
            'ports:'
            '  implement-test: [s3]'
            '  implement-code: [s2]'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    rc: GREEN code action'
            '    ac_refs: [AC1]'
            '    depends_on: []'
            '    cycle: 1'
            '  s3:'
            '    execution_mode: serial'
            '    rc: RED test action'
            '    ac_refs: [AC2]'
            '    depends_on: [s2]'
            '    cycle: 1'
        ) -join "`n"

        $result = Test-FSCCanonicalForm -SpineBlock $nonCanonical
        $result | Should -BeFalse
        $null = $result
    }

    It 'enforces inline list-style syntax for port and slice reference lists' {
        $blockListStyle = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-04T14:30:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code:'
            '    - s2'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
            '    rc: GREEN code action'
            '    ac_refs:'
            '      - AC1'
            '    depends_on: []'
            '    cycle: 1'
        ) -join "`n"

        $result = Test-FSCCanonicalForm -SpineBlock $blockListStyle
        $result | Should -BeFalse
        $null = $result
    }

    It 'returns null instead of throwing for malformed spine YAML' {
        $malformedYaml = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-04T14:30:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code: [s2]'
            '  : this line has no key'
            '    bad indentation: [unbalanced'
            'slices:'
            '  s2:'
            '    execution_mode: serial'
        ) -join "`n"
        $malformedYamlError = $null

        try {
            ConvertFrom-FSCSpineYaml -SpineBlock $malformedYaml | Should -BeNullOrEmpty
        }
        catch {
            $malformedYamlError = $_.Exception.Message
        }

        $malformedYamlError | Should -BeNullOrEmpty
    }

    It 'parses cycle markers from flow-style port lists' {
        $cycleSpineBlock = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-04T14:30:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code: [s4, s5#cycle:2, s8#cycle:3#terminal]'
            'slices:'
            '  s4:'
            '    execution_mode: serial'
            '    rc: GREEN code action'
            '    ac_refs: [AC1]'
            '    depends_on: []'
            '    cycle: 1'
            '  s5:'
            '    execution_mode: parallel'
            '    rc: GREEN code/test action'
            '    ac_refs: [AC2]'
            '    depends_on: [s4]'
            '    cycle: 2'
            '  s8:'
            '    execution_mode: serial'
            '    rc: CE Gate evidence capture'
            '    ac_refs: [AC9]'
            '    depends_on: [s5]'
            '    cycle: 3'
            '    terminal: true'
        ) -join "`n"

        $parsed = ConvertFrom-FSCSpineYaml -SpineBlock $cycleSpineBlock
        $tokens = @(& $script:GetPortEntries -ParsedSpine $parsed -PortName 'implement-code')

        $tokens | Should -HaveCount 3
        & $script:AssertStepToken -Token $tokens[0] -StepId 's4' -Cycle 1 -Terminal $false
        & $script:AssertStepToken -Token $tokens[1] -StepId 's5' -Cycle 2 -Terminal $false
        & $script:AssertStepToken -Token $tokens[2] -StepId 's8' -Cycle 3 -Terminal $true
    }

    It 'rejects cycle markers outside flow-style brackets as malformed' {
        $blockStyleCycleMarker = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-04T14:30:00Z'
            'coverage: complete'
            'ports:'
            '  implement-code:'
            '    - s5#cycle:2'
            'slices:'
            '  s5:'
            '    execution_mode: parallel'
            '    rc: GREEN code/test action'
            '    ac_refs: [AC4]'
            '    depends_on: []'
            '    cycle: 2'
        ) -join "`n"
        $blockStyleCycleMarkerError = $null

        try {
            ConvertFrom-FSCSpineYaml -SpineBlock $blockStyleCycleMarker | Should -BeNullOrEmpty
        }
        catch {
            $blockStyleCycleMarkerError = $_.Exception.Message
        }

        $blockStyleCycleMarkerError | Should -BeNullOrEmpty
    }
}
