#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED contract tests for the /orchestra:spine deterministic inspection command.

.DESCRIPTION
    Locks issue #512 Step 11 / AC10 before the command exists. The future
    command must render only the latest plan comment's frame spine, provide a
    readable port-to-step inspection table, handle no-spine and error cases
    deterministically, and expose an offline render path for fast tests.

    These tests intentionally avoid live GitHub calls. Fixture-backed command
    execution installs a gh mock that fails the test if the implementation
    ignores the fixture path and reaches for the network.
#>

Describe '/orchestra:spine deterministic inspection command' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptPath = Join-Path $script:RepoRoot '.github/scripts/orchestra-spine.ps1'
        $script:CommandPath = Join-Path $script:RepoRoot 'commands/orchestra-spine.md'
        $script:ClaudeMdPath = Join-Path $script:RepoRoot 'CLAUDE.md'
        $script:AgentBodyArchPath = Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md'

        $script:RepresentativeSpine = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-05T11:00:00Z'
            'coverage: complete'
            'ports:'
            '  ce-gate-cli: [s15#cycle:4#terminal]'
            '  implement-code: [s12#cycle:2]'
            '  implement-test: [s11]'
            '  review: [s14#cycle:3#terminal]'
            'slices:'
            '  s11:'
            '    execution_mode: serial'
            '    rc: RED tests for /orchestra:spine inspection'
            '    ac_refs: [AC10]'
            '    depends_on: []'
            '    cycle: 1'
            '  s12:'
            '    execution_mode: serial'
            '    rc: GREEN command implementation'
            '    ac_refs: [AC10]'
            '    depends_on: [s11]'
            '    cycle: 2'
            '  s14:'
            '    execution_mode: serial'
            '    rc: Adversarial review terminal step'
            '    ac_refs: [AC10]'
            '    depends_on: [s12]'
            '    cycle: 3'
            '    terminal: true'
            '  s15:'
            '    execution_mode: serial'
            '    rc: CE Gate evidence capture'
            '    ac_refs: [AC10]'
            '    depends_on: [s14]'
            '    cycle: 4'
            '    terminal: true'
        ) -join "`n"

        $script:OlderSpine = @(
            'spine_schema_version: 1'
            'generated_at: 2026-05-05T10:00:00Z'
            'coverage: complete'
            'ports:'
            '  implement-test: [s1]'
            'slices:'
            '  s1:'
            '    execution_mode: serial'
            '    rc: stale older plan comment'
            '    ac_refs: [AC10]'
            '    depends_on: []'
            '    cycle: 1'
        ) -join "`n"

        $script:LatestPlanCommentBody = @(
            '<!-- plan-issue-512 -->'
            ''
            '---'
            'status: in_progress'
            'issue_id: 512'
            '---'
            ''
            '## Plan: Frame plan-routing/context-sharing spine'
            ''
            'This prose plan must not appear in /orchestra:spine output.'
            ''
            '<!-- frame-spine'
            $script:RepresentativeSpine
            '-->'
            ''
            '<!-- frame-slice -->'
            'id: s11'
            'provides: [implement-test]'
            'requirement-contract: |'
            '  RED test body that must not appear in inspection output.'
            '-->'
        ) -join "`n"

        $script:LatestCommentsJson = @{
            comments = @(
                @{
                    id        = 1001
                    updatedAt = '2026-05-05T10:01:00Z'
                    body      = "<!-- plan-issue-512 -->`n`n<!-- frame-spine`n$($script:OlderSpine)`n-->"
                }
                @{
                    id        = 1002
                    updatedAt = '2026-05-05T11:01:00Z'
                    body      = $script:LatestPlanCommentBody
                }
            )
        } | ConvertTo-Json -Depth 12

        $script:PlanTooSmallJson = @{
            comments = @(
                @{
                    id        = 1003
                    updatedAt = '2026-05-05T12:00:00Z'
                    body      = @(
                        '<!-- plan-issue-512 -->'
                        '---'
                        'status: approved'
                        'issue_id: 512'
                        'spine-omitted: plan-too-small'
                        '---'
                        ''
                        '## Plan: Tiny cleanup'
                        'Prose plan remains in the issue comment.'
                    ) -join "`n"
                }
            )
        } | ConvertTo-Json -Depth 12

        $script:LegacyPlanJson = @{
            comments = @(
                @{
                    id        = 1005
                    updatedAt = '2026-05-05T14:00:00Z'
                    body      = @(
                        '<!-- plan-issue-512 -->'
                        ''
                        '## Plan: Legacy approved plan'
                        'This older approved plan predates frame-spine emission.'
                    ) -join "`n"
                }
            )
        } | ConvertTo-Json -Depth 12

        $unknownPortSpine = $script:RepresentativeSpine -replace '  review: \[s14#cycle:3#terminal\]', '  unregistered-port: [s14#cycle:3#terminal]'
        $script:UnknownPortJson = @{
            comments = @(
                @{
                    id        = 1004
                    updatedAt = '2026-05-05T13:00:00Z'
                    body      = @(
                        '<!-- plan-issue-512 -->'
                        ''
                        '<!-- frame-spine'
                        $unknownPortSpine
                        '-->'
                    ) -join "`n"
                }
            )
        } | ConvertTo-Json -Depth 12

        $script:MissingPlanJson = @{ comments = @() } | ConvertTo-Json -Depth 4

        $script:WriteFixture = {
            param([Parameter(Mandatory)][string]$Json)

            $fixturePath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.comments.json')
            Set-Content -Path $fixturePath -Value $Json -Encoding UTF8
            return $fixturePath
        }

        $script:QuoteForHarness = {
            param([AllowEmptyString()][string]$Value)

            return "'$($Value -replace "'", "''")'"
        }

        $script:InvokeCommand = {
            param(
                [AllowNull()][string]$IssueArgument,
                [AllowNull()][string]$CommentsJsonPath,
                [hashtable]$Env = @{},
                [int]$TimeoutSeconds = 10
            )

            $harnessPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.orchestra-spine-harness.ps1')
            $stdoutPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.stdout.txt')
            $stderrPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.stderr.txt')

            $argumentLines = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $IssueArgument) {
                $argumentLines.Add("`$commandArguments += '-Issue'") | Out-Null
                $argumentLines.Add("`$commandArguments += $(& $script:QuoteForHarness -Value $IssueArgument)") | Out-Null
            }
            if ($null -ne $CommentsJsonPath) {
                $argumentLines.Add("`$commandArguments += '-CommentsJsonPath'") | Out-Null
                $argumentLines.Add("`$commandArguments += $(& $script:QuoteForHarness -Value $CommentsJsonPath)") | Out-Null
            }

            $envLines = foreach ($key in $Env.Keys) {
                "`$env:$key = $(& $script:QuoteForHarness -Value ([string]$Env[$key]))"
            }

            $harness = @"
`$ErrorActionPreference = 'Continue'
$($envLines -join "`n")
`$scriptPath = $(& $script:QuoteForHarness -Value $script:ScriptPath)
`$global:GhCalls = @()
function global:gh {
    param([Parameter(ValueFromRemainingArguments = `$true)]`$Args)
    `$global:GhCalls += (`$Args -join ' ')
    [Console]::Error.WriteLine('LIVE_GH_BLOCKED: ' + (`$Args -join ' '))
    return '{"blocked":true}'
}

`$commandArguments = @()
$($argumentLines.ToArray() -join "`n")

`$exitCode = 0
if (-not (Test-Path -LiteralPath `$scriptPath -PathType Leaf)) {
    [Console]::Error.WriteLine('ORCHESTRA_SPINE_NOT_FOUND: ' + `$scriptPath)
    `$exitCode = 127
}
else {
    try {
        & `$scriptPath @commandArguments
        if (`$global:LASTEXITCODE -is [int] -and `$global:LASTEXITCODE -ne 0) {
            `$exitCode = `$global:LASTEXITCODE
        }
    }
    catch {
        [Console]::Error.WriteLine(`$_.Exception.Message)
        `$exitCode = 1
    }
}

[Console]::Error.WriteLine('GH_CALLS=' + `$global:GhCalls.Count)
exit `$exitCode
"@

            Set-Content -Path $harnessPath -Value $harness -Encoding UTF8

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $process = Start-Process -FilePath 'pwsh' `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $harnessPath) `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -PassThru `
                -WindowStyle Hidden

            $finished = $process.WaitForExit($TimeoutSeconds * 1000)
            if (-not $finished) {
                try { $process.Kill($true) }
                catch { Write-Verbose $_.Exception.Message }
            }
            $stopwatch.Stop()

            return [pscustomobject]@{
                ExitCode             = if ($finished) { $process.ExitCode } else { -1 }
                Stdout               = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { '' }
                Stderr               = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { '' }
                DurationMilliseconds = $stopwatch.Elapsed.TotalMilliseconds
                TimedOut             = -not $finished
            }
        }

        # --- 872-D5 goal-contract variant fixtures (frame-slice s3) ---
        # A minimal schema-valid <!-- goal-contract --> block (872-D2 field
        # set), reused across the goal-contract orchestra-spine tests below.
        # frame-slice s3 covers reader behavior only; hash correctness is
        # #873's concern (872-D3), so a literal 64-zero placeholder is used.
        $script:NewGCContractBlockLines = {
            param([string]$AcRef = 'AC2', [string]$IssueField = '872')

            return @(
                '<!-- goal-contract'
                'schema_version: 1'
                "issue: $IssueField"
                "contract_hash: `"$('0' * 64)`""
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
                'halt_conditions: [unachievable-target, invariant-conflict, budget-exhausted, gate-input-needed, chain-stage-failure]'
                'budget:'
                '  tokens: 100000'
                '  wall_clock: 4h'
                '  chain_sub_ceiling: 2'
                '  non_convergence: halt-report'
                '-->'
            )
        }

        # Builds a plan comment body in the REAL persisted-comment shape: the
        # plan-issue and phase-containment-ledger-ref markers precede the ---
        # frontmatter fence (Issue-Planner.agent.md:132,
        # plan-authoring/SKILL.md:373), so the fence is never line 1 -- a
        # fixture without those markers cannot detect a strict-line-1
        # anchoring defect.
        $script:NewGCPlanCommentBody = {
            param(
                [int]$IssueNumber = 872,
                [switch]$OmitVariantFrontmatter,
                [switch]$IncludePlanTooSmall,
                [switch]$IncludeSpineAndSlice,
                [string[]]$ContractBlockLines = $null,
                [string[]]$ExtraProseLines = @()
            )

            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("<!-- plan-issue-$IssueNumber -->") | Out-Null
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
            $lines.Add('Fixture body for /orchestra:spine RED tests over the 872-D5 state matrix.') | Out-Null
            $lines.Add('') | Out-Null
            $lines.Add('## Acceptance Criteria') | Out-Null
            $lines.Add('- **AC2** frame-validate accepts a goal-contract plan and still rejects a bare spine-less plan.') | Out-Null
            $lines.Add('') | Out-Null

            if ($IncludeSpineAndSlice) {
                $lines.Add('<!-- frame-spine') | Out-Null
                $lines.Add($script:RepresentativeSpine) | Out-Null
                $lines.Add('-->') | Out-Null
                $lines.Add('') | Out-Null
            }

            foreach ($prose in $ExtraProseLines) { $lines.Add($prose) | Out-Null }

            if ($null -ne $ContractBlockLines) {
                foreach ($contractLine in $ContractBlockLines) { $lines.Add($contractLine) | Out-Null }
            }

            return [string]($lines.ToArray() -join "`n")
        }

        $script:NewGCCommentsJson = {
            param([Parameter(Mandatory)][string]$Body, [int]$CommentId = 2001)

            return (@{
                    comments = @(
                        @{ id = $CommentId; updatedAt = '2026-07-19T15:00:00Z'; body = $Body }
                    )
                } | ConvertTo-Json -Depth 12)
        }
    }

    It 'extracts the latest plan comment spine and renders no slices or prose plan' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs an offline-capable script surface'

        $fixturePath = & $script:WriteFixture -Json $script:LatestCommentsJson
        $result = & $script:InvokeCommand -IssueArgument '512' -CommentsJsonPath $fixturePath

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Match 'generated_at:\s*2026-05-05T11:00:00Z' -Because 'the latest matching plan comment must win over older plan comments'
        $result.Stdout | Should -Match 'implement-test' -Because 'the rendered inspection output must include the latest spine ports'
        $result.Stdout | Should -Not -Match '2026-05-05T10:00:00Z|stale older plan comment' -Because 'older plan-issue comments must not leak into the inspection output'
        $result.Stdout | Should -Not -Match 'This prose plan must not appear|frame-slice|requirement-contract|RED test body' -Because 'the command renders just the spine inspection surface, not slices or prose plan content'
        $result.Stderr | Should -Match 'GH_CALLS=0' -Because 'fixture-backed tests must remain offline'
        $result.Stderr | Should -Not -Match 'LIVE_GH_BLOCKED'
    }

    It 'formats a readable port to step-id table including cycle and terminal markers' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs an offline-capable script surface'

        $fixturePath = & $script:WriteFixture -Json $script:LatestCommentsJson
        $result = & $script:InvokeCommand -IssueArgument '512' -CommentsJsonPath $fixturePath

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Match '(?m)^\|\s*Port\s*\|\s*Step' -Because 'operators need a readable port-to-step table, not raw YAML only'
        $result.Stdout | Should -Match '(?m)^\|\s*implement-test\s*\|[^\r\n]*s11[^\r\n]*(cycle\s*[:=]?\s*1|\|\s*1\s*\|)' -Because 'first-cycle steps must still show their cycle value'
        $result.Stdout | Should -Match '(?m)^\|\s*implement-code\s*\|[^\r\n]*s12[^\r\n]*(cycle\s*[:=]?\s*2|\|\s*2\s*\|)' -Because 'continuation cycle markers must be visible'
        $result.Stdout | Should -Match '(?m)^\|\s*review\s*\|[^\r\n]*s14[^\r\n]*(cycle\s*[:=]?\s*3|\|\s*3\s*\|)[^\r\n]*(terminal|true|yes)' -Because 'terminal port entries must be visible in the table'
        $result.Stdout | Should -Match '(?m)^\|\s*ce-gate-cli\s*\|[^\r\n]*s15[^\r\n]*(cycle\s*[:=]?\s*4|\|\s*4\s*\|)[^\r\n]*(terminal|true|yes)' -Because 'CE terminal markers must not be lost'
    }

    It 'does not mark known canonical frame ports as unknown' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs an offline-capable script surface'

        $fixturePath = & $script:WriteFixture -Json $script:LatestCommentsJson
        $result = & $script:InvokeCommand -IssueArgument '512' -CommentsJsonPath $fixturePath

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Match 'implement-code' -Because 'the fixture includes a known implementation port'
        $result.Stdout | Should -Match 'implement-test' -Because 'the fixture includes a known test port'
        $result.Stdout | Should -Not -Match '\[unknown-port\].*implement-code' -Because 'known ports should be loaded as individual HashSet members'
        $result.Stdout | Should -Not -Match '\[unknown-port\].*implement-test' -Because 'known ports should be loaded as individual HashSet members'
    }

    It 'renders the plan-too-small fallback when the plan explicitly omits a spine' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs an offline-capable script surface'

        $fixturePath = & $script:WriteFixture -Json $script:PlanTooSmallJson
        $result = & $script:InvokeCommand -IssueArgument '512' -CommentsJsonPath $fixturePath

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Match 'plan has no spine — see comment for prose plan'
        $result.Stdout | Should -Not -Match 'frame-spine|Port\s*\|\s*Step' -Because 'tiny-plan fallback should not fabricate a spine table'
    }

    It 'renders a legacy-plan-shape no-spine result for an existing plan comment without a frame spine' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs an offline-capable script surface'

        $fixturePath = & $script:WriteFixture -Json $script:LegacyPlanJson
        $result = & $script:InvokeCommand -IssueArgument '512' -CommentsJsonPath $fixturePath

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Match 'legacy-plan-shape' -Because 'operators need an intentional legacy/no-spine result, not a raw parse failure'
        $result.Stdout | Should -Match 'no frame-spine block|no spine is available' -Because 'the message should explain why no table was rendered'
        $result.Stdout | Should -Not -Match '(?m)^\|\s*Port\s*\|\s*Step' -Because 'legacy plans must not fabricate a spine table'
    }

    It 'fails gracefully when no plan comment exists and does not leak authentication tokens' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs an offline-capable script surface'

        $fixturePath = & $script:WriteFixture -Json $script:MissingPlanJson
        $secretToken = 'ghp_issue_512_secret_token_must_not_leak'
        $result = & $script:InvokeCommand -IssueArgument '999' -CommentsJsonPath $fixturePath -Env @{ GH_TOKEN = $secretToken; GITHUB_TOKEN = $secretToken }
        $combinedOutput = $result.Stdout + "`n" + $result.Stderr

        $result.ExitCode | Should -Not -Be 0
        $combinedOutput | Should -Match 'plan-issue-999|issue\s+#?999' -Because 'the error should name the missing plan comment target'
        $combinedOutput | Should -Match 'Usage:\s*/orchestra:spine\s+<issue-number>|positive integer issue number' -Because 'operators need a recovery hint, not a raw parser failure'
        $combinedOutput | Should -Not -Match ([regex]::Escape($secretToken)) -Because 'auth tokens must never appear in command output'
    }

    It 'parses and formats a fixture-backed spine under 50ms without live gh calls' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs an offline-capable render function surface'

        . $script:ScriptPath
        Get-Command Invoke-OrchestraSpineRender -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'tests need a pure render function so parse+format time excludes pwsh process startup'

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $rendered = Invoke-OrchestraSpineRender -IssueNumber 512 -CommentsJson $script:LatestCommentsJson
        $stopwatch.Stop()

        $stopwatch.Elapsed.TotalMilliseconds | Should -BeLessThan 50
        [string]$rendered | Should -Match 'implement-test'
    }

    It 'renders a warning marker for unknown ports instead of dropping them' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs an offline-capable script surface'

        $fixturePath = & $script:WriteFixture -Json $script:UnknownPortJson
        $result = & $script:InvokeCommand -IssueArgument '512' -CommentsJsonPath $fixturePath

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Match 'unregistered-port' -Because 'unknown ports should remain inspectable by the operator'
        $result.Stdout | Should -Match '(?i)warning[^\r\n]*unknown[^\r\n]*port[^\r\n]*unregistered-port|\[unknown-port\][^\r\n]*unregistered-port' -Because 'unknown ports need a visible warning marker instead of silent omission'
    }

    It 'uses shared discovery for the canonical frame port set' {
        $scriptContent = Get-Content -LiteralPath $script:ScriptPath -Raw -ErrorAction Stop

        $scriptContent | Should -Match 'frame-shared-discovery\.ps1' -Because 'canonical port stems belong to the shared frame discovery surface'
        $scriptContent | Should -Match 'Get-FramePortFileStem' -Because 'the command should consume canonical port filename stems through shared discovery'
        $scriptContent | Should -Not -Match 'frame-credit-ledger-core\.ps1|Get-PortFiles' -Because 'the spine inspection command should not depend on ledger-only port parsing for canonical ports'
    }

    It 'accepts only positive integer issue numbers' {
        Test-Path -LiteralPath $script:ScriptPath -PathType Leaf | Should -BeTrue -Because 'the /orchestra:spine command needs argument validation'

        $fixturePath = & $script:WriteFixture -Json $script:LatestCommentsJson
        foreach ($invalidArgument in @($null, '', 'abc', '12.5', '0', '-12')) {
            $result = & $script:InvokeCommand -IssueArgument $invalidArgument -CommentsJsonPath $fixturePath
            $combinedOutput = $result.Stdout + "`n" + $result.Stderr

            $result.ExitCode | Should -Not -Be 0 -Because "'$invalidArgument' is not a positive integer issue number"
            $combinedOutput | Should -Match 'positive integer issue number|Usage:\s*/orchestra:spine\s+<issue-number>'
        }

        $validResult = & $script:InvokeCommand -IssueArgument '512' -CommentsJsonPath $fixturePath
        $validResult.ExitCode | Should -Be 0 -Because 'positive integer issue numbers are valid command input'
    }

    It 'documents command routing in CLAUDE.md as inherited routine inspection' {
        Test-Path -LiteralPath $script:CommandPath -PathType Leaf | Should -BeTrue -Because 'the Claude slash command file must exist for /orchestra:spine'

        $commandContent = Get-Content -Path $script:CommandPath -Raw -ErrorAction Stop
        $commandContent | Should -Match '(?m)^# /orchestra:spine\s*$'
        $commandContent | Should -Not -Match '(?m)^(model|effort):\s*' -Because 'D4 routine inspection commands inherit the dispatcher rather than declaring a model tier'
        $commandContent | Should -Match 'positive integer issue number|Usage:\s*/orchestra:spine\s+<issue-number>' -Because 'the command body must guide invalid argument handling'

        $archContent = Get-Content -Path $script:AgentBodyArchPath -Raw -ErrorAction Stop
        $archContent | Should -Match '(?m)^\|\s*`commands/orchestra-spine\.md`\s*\|\s*`inherit`\s*\|\s*`inherit`\s*\|[^\r\n]*D4:\s*routine inspection' -Because 'agent-body-architecture.md routing table must register the command as inherited D4 routine inspection'
    }

    Context '872-D5 goal-contract variant reader behavior (issue #872, frame-slice s3)' {

        It 'renders the goal-contract variant message instead of the legacy-plan-shape fall-through for a goal-contract plan' {
            . $script:ScriptPath
            $contractLines = & $script:NewGCContractBlockLines -AcRef 'AC2'
            $body = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines
            $commentsJson = & $script:NewGCCommentsJson -Body $body

            $rendered = Invoke-OrchestraSpineRender -IssueNumber 872 -CommentsJson $commentsJson

            [string]$rendered | Should -Match '(?i)goal-contract' -Because 'a goal-contract plan must render the variant-aware message (872-D7 item 1)'
            [string]$rendered | Should -Not -Match 'legacy-plan-shape' -Because 'the variant message replaces the misleading legacy-plan-shape fall-through'
        }

        It 'still renders the frame spine for a plan whose prose merely quotes the plan-variant: goal-contract literal (false-positive guard, C6 for this reader too)' {
            . $script:ScriptPath
            $body = & $script:NewGCPlanCommentBody -OmitVariantFrontmatter -IncludeSpineAndSlice -ContractBlockLines $null -ExtraProseLines @(
                'Authoring note: some plans declare'
                'plan-variant: goal-contract'
                'at the start of a prose line for illustration purposes only.'
                ''
            )
            $commentsJson = & $script:NewGCCommentsJson -Body $body

            $rendered = Invoke-OrchestraSpineRender -IssueNumber 872 -CommentsJson $commentsJson

            [string]$rendered | Should -Match 'implement-test' -Because 'a body-wide quoted literal outside real frontmatter must not suppress the normal spine table'
            [string]$rendered | Should -Not -Match '(?i)goal-contract' -Because 'the quoted literal must not route this spine plan to the variant message'
        }

        It 'resolves the plan-too-small x goal-contract-variant cross identically to frame-validate by rendering the variant message' {
            . $script:ScriptPath
            $contractLines = & $script:NewGCContractBlockLines -AcRef 'AC2'
            $body = & $script:NewGCPlanCommentBody -IncludePlanTooSmall -ContractBlockLines $contractLines
            $commentsJson = & $script:NewGCCommentsJson -Body $body

            $rendered = Invoke-OrchestraSpineRender -IssueNumber 872 -CommentsJson $commentsJson

            [string]$rendered | Should -Match '(?i)goal-contract' -Because 'the variant branch must win over the legacy plan-too-small escape, identically to frame-validate'
            [string]$rendered | Should -Not -Match 'plan has no spine' -Because 'a variant-declared plan must not fall through to the plan-too-small fallback message'
        }

        It 'Invoke-FSCSpineLookupCli returns missing-spine for a goal-contract-only body (872-D7 item 2 backstop, no code change expected)' {
            . $script:ScriptPath
            Get-Command Invoke-FSCSpineLookupCli -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'frame-spine-core.ps1 is dot-sourced transitively by orchestra-spine.ps1'

            $contractLines = & $script:NewGCContractBlockLines -AcRef 'AC2'
            $body = & $script:NewGCPlanCommentBody -ContractBlockLines $contractLines
            $bodyPath = Join-Path $TestDrive 'goal-contract-only-body.txt'
            Set-Content -Path $bodyPath -Value $body -Encoding UTF8 -NoNewline

            $result = Invoke-FSCSpineLookupCli -CommentBodyPath $bodyPath -Format Text -GeneratedAt '2026-07-19T15:00:00Z' -StepId 's1'

            $result.ExitCode | Should -Be 1
            ($result.Lines -join "`n") | Should -Match 'status:\s*missing-spine' -Because 'a goal-contract-only body has no frame-spine block, and 872-D7 settles this as requiring no code change to the lookup backstop'
        }
    }
}
