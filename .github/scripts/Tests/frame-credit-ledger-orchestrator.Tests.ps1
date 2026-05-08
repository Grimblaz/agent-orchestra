#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester integration tests for the frame credit ledger ORCHESTRATOR script
# (issue #429, Step 4 RED).
#
# Script under test: .github/scripts/frame-credit-ledger.ps1
#
# At Step 4 RED the orchestrator does NOT exist yet, so every It-block fails
# with one of the two canonical RED signals:
#
#   1. "script not found" — `Test-Path` against the orchestrator path returns
#      `$false`, or `pwsh -File <missing>` emits a "Cannot find path" /
#      non-zero exit before the script can be parsed.
#   2. "function not found" — when an It-block dot-sources the orchestrator
#      and the surface (e.g. helper function names) is missing.
#
# Step 5 GREEN lands the orchestrator and turns these RED signals green.
#
# ============================================================================
# TEST HOOK CONTRACT — read this before implementing the orchestrator
# ============================================================================
#
#   The orchestrator MUST honour two test-only environment-variable hooks so
#   these integration tests can run deterministically without burning real
#   wall-clock seconds on retry-backoff or 30-second-budget assertions:
#
#     FRAME_CREDIT_LEDGER_TEST_NO_SLEEP=1
#         When set to '1' (string), the orchestrator skips every
#         `Start-Sleep` it would otherwise perform between gh-retry attempts.
#         Backoff durations (2s, 4s) collapse to 0s. The retry COUNT and
#         ORDER must remain identical to the production path — only the
#         delay is suppressed.
#
#     FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS=<int>
#         When set to a positive integer, overrides the default 30-second
#         outer budget (used by the Wait-Job / Wait-Process timeout
#         primitive). Tests set this to a small value (e.g. 3) to validate
#         the timeout code path in bounded wall-clock time without lying
#         about which branch executed.
#
#   Additionally, the orchestrator MUST resolve `gh` via `Get-Command gh`
#   (or PATH lookup) so a `function global:gh { ... }` mock installed in
#   the parent session is found. Direct hard-coded paths to the gh binary
#   would make these tests un-mockable.
#
# ============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:OrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'
    $script:CoreLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    $script:UpsertLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/find-or-upsert-comment.ps1'
    $script:PredicateLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'

    # Canonical v4 PR body fixture: every port covered (no NotCovered rows).
    $script:V4AllCoveredBody = @'
## Summary

A v4 PR body where every credit is passed.

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
    - port: ce-gate-api
        status: passed
        evidence: "API CE Gate not required for this fixture"
    - port: ce-gate-browser
        status: passed
        evidence: "browser CE Gate not required for this fixture"
    - port: ce-gate-canvas
        status: passed
        evidence: "canvas CE Gate not required for this fixture"
  - port: review
    status: passed
    evidence: "judge ruling: keep"
    - port: implement-code
        status: passed
        evidence: "implementation complete"
  - port: implement-test
    status: passed
    evidence: "tests GREEN at HEAD"
    - port: implement-refactor
        status: passed
        evidence: "refactor review complete"
    - port: implement-docs
        status: passed
        evidence: "docs complete"
    - port: design
        status: passed
        evidence: "design complete"
    - port: experience
        status: passed
        evidence: "experience complete"
    - port: plan
        status: passed
        evidence: "plan complete"
    - port: post-fix-review
        status: passed
        evidence: "post-fix review complete"
    - port: post-pr
        status: passed
        evidence: "post-pr complete"
    - port: process-retrospective
        status: passed
        evidence: "process retrospective complete"
    - port: process-review
        status: passed
        evidence: "process review complete"
    - port: release-hygiene
        status: passed
        evidence: "release hygiene complete"
  - port: ce-gate-cli
    status: not-applicable
    evidence: "no CLI surface touched"
integrity_checks:
  - check: schema-version-pinned
    status: passed
  - check: marker-presence
    status: passed
-->

More text after the marker.
'@

    # v4 PR body fixture with at least one credit deliberately failed -> NotCovered row.
    $script:V4WithNotCoveredBody = @'
## Summary

A v4 PR body where the review credit failed.

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: review
    status: failed
    evidence: "judge ruling: revise"
  - port: implement-test
    status: passed
    evidence: "tests GREEN"
integrity_checks:
  - check: marker-presence
    status: passed
-->
'@

    # pre-v4 (legacy v3) PR body fixture — should short-circuit.
    $script:PreV4Body = @'
## Summary

A pre-v4 PR body.

<!-- pipeline-metrics
metrics_version: 3
some_legacy_field: value
-->
'@

    # Helper: invokes the orchestrator script in a child pwsh process so we
    # can capture exit codes + stderr deterministically. Returns a hashtable
    # with ExitCode / Stdout / Stderr / DurationSeconds.
    $script:InvokeOrchestrator = {
        param(
            [int]$Pr = 429,
            [string]$Mode = 'warn',
            [hashtable]$Env = @{},
            [int]$TimeoutSeconds = 60,
            [string]$MockBootstrap = ''
        )

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # Build a tiny harness script that:
        #   1. installs the gh/external-command mocks (passed in via $MockBootstrap)
        #   2. dot-sources or invokes the orchestrator
        #   3. reports exit code through $LASTEXITCODE
        $harnessPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.harness.ps1')

        # Inline env-var setup at the top of the harness so we can use
        # `pwsh -File`, which (unlike `pwsh -Command`) preserves the child
        # exit code verbatim. This is critical for the RED signal: a missing
        # orchestrator must surface as exit 127, not be coerced to 1 by
        # `pwsh -Command`'s exit-code normalization.
        $envLines = foreach ($key in $Env.Keys) {
            "`$env:$key = '$($Env[$key])'"
        }
        $envPrelude = ($envLines -join "`n")

        $harness = @"
`$ErrorActionPreference = 'Continue'
$envPrelude
`$orchestratorPath = '$($script:OrchestratorPath -replace "'", "''")'
if (-not (Test-Path -LiteralPath `$orchestratorPath -PathType Leaf)) {
    [Console]::Error.WriteLine("ORCHESTRATOR_NOT_FOUND: `$orchestratorPath")
    exit 127
}
$MockBootstrap

# Invoke the orchestrator in-process so the gh function mock (defined above
# in MockBootstrap, in this same scope) is reachable.
& `$orchestratorPath -Pr $Pr -Mode $Mode
exit `$LASTEXITCODE
"@
        Set-Content -Path $harnessPath -Value $harness -Encoding UTF8

        $stdoutPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.stdout.txt')
        $stderrPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.stderr.txt')

        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $harnessPath) `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru `
            -WindowStyle Hidden

        $waited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $waited) {
            try { $proc.Kill($true) } catch { $null = $_ }
            $stopwatch.Stop()
            return @{
                ExitCode        = -1
                Stdout          = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
                'Stderr'        = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
                DurationSeconds = $stopwatch.Elapsed.TotalSeconds
                TimedOut        = $true
            }
        }
        $stopwatch.Stop()

        return @{
            ExitCode        = $proc.ExitCode
            Stdout          = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
            'Stderr'        = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
            DurationSeconds = $stopwatch.Elapsed.TotalSeconds
            TimedOut        = $false
        }
    }

    # Helper: build a `function global:gh { ... }` bootstrap snippet that
    # the harness will dot into the same scope as the orchestrator
    # invocation. Mirrors the pattern in find-or-upsert-comment.Tests.ps1.
    $script:NewGhMockBootstrap = {
        param(
            [string]$BaseRefOidJson = '{"baseRefOid":"abc123"}',
            [string]$BodyJson = $null,
            [string]$IssueCommentsJson = '{"comments":[]}',
            [int]$BaseRefAttemptsBeforeSuccess = 0,
            [bool]$HangOnBaseRef = $false,
            [string]$ExtraDeclarations = ''
        )

        # NOTE: this snippet is interpolated into a -Command string and then
        # written to a harness .ps1; double-up `$` for variables that should
        # survive the outer expansion.
        $bodyDefault = if ($null -ne $BodyJson) { $BodyJson } else {
            (@{ body = "## empty body`n" } | ConvertTo-Json -Compress)
        }

        return @"
`$global:GhCallLog = @()
`$global:BaseRefAttempts = 0
`$global:BaseRefAttemptsBeforeSuccess = $BaseRefAttemptsBeforeSuccess
`$global:HangOnBaseRef = `$$HangOnBaseRef
`$global:UpsertCalled = `$false
`$global:UpsertBody = ''
`$global:UpsertMarker = ''
`$global:UpdatedPrBody = ''
$ExtraDeclarations

function global:Write-UpdatedPrBodyCapture {
    param([AllowEmptyString()][string]`$Body)

    `$global:UpdatedPrBody = `$Body
    [Console]::Out.WriteLine('UPDATED_PR_BODY_BEGIN')
    [Console]::Out.WriteLine(`$Body)
    [Console]::Out.WriteLine('UPDATED_PR_BODY_END')
}

function global:gh {
    param([Parameter(ValueFromRemainingArguments = `$true)]`$Args)
    `$joined = `$Args -join ' '
    `$global:GhCallLog += `$joined

    if (`$joined -match 'pr view \d+ --json baseRefOid') {
        `$global:BaseRefAttempts++
        if (`$global:HangOnBaseRef) {
            Start-Sleep -Seconds 60
        }
        if (`$global:BaseRefAttempts -le `$global:BaseRefAttemptsBeforeSuccess) {
            `$global:LASTEXITCODE = 0
            return '{"baseRefOid":null}'
        }
        `$global:LASTEXITCODE = 0
        return '$BaseRefOidJson'
    }

    if (`$joined -match 'pr view \d+ --json body') {
        `$global:LASTEXITCODE = 0
        return '$bodyDefault'
    }

    if (`$joined -match 'pr edit \d+ .*--body-file') {
        `$idx = [Array]::IndexOf(`$Args, '--body-file')
        if (`$idx -ge 0 -and `$idx + 1 -lt `$Args.Count) {
            `$bodyFile = [string]`$Args[`$idx + 1]
            `$bodyText = (Test-Path -LiteralPath `$bodyFile) ? (Get-Content -LiteralPath `$bodyFile -Raw) : ''
            Write-UpdatedPrBodyCapture -Body `$bodyText
        }
        `$global:LASTEXITCODE = 0
        return 'https://github.com/example/example/pull/429'
    }

    if (`$joined -match 'pr edit \d+ .*--body') {
        `$idx = [Array]::IndexOf(`$Args, '--body')
        if (`$idx -ge 0 -and `$idx + 1 -lt `$Args.Count) {
            Write-UpdatedPrBodyCapture -Body ([string]`$Args[`$idx + 1])
        }
        `$global:LASTEXITCODE = 0
        return 'https://github.com/example/example/pull/429'
    }

    if (`$joined -match 'api -X PATCH repos/[^/]+/[^/]+/pulls/\d+') {
        foreach (`$arg in `$Args) {
            `$argText = [string]`$arg
            if (`$argText -like 'body=*') {
                Write-UpdatedPrBodyCapture -Body (`$argText.Substring(5))
                break
            }
        }
        `$global:LASTEXITCODE = 0
        return '{"html_url":"https://github.com/example/example/pull/429"}'
    }

    if (`$joined -match 'issue view \d+ --json comments') {
        `$global:LASTEXITCODE = 0
        return '$IssueCommentsJson'
    }

    if (`$joined -match '(issue|pr) comment \d+ --body') {
        `$global:UpsertCalled = `$true
        `$idx = [Array]::IndexOf(`$Args, '--body')
        if (`$idx -ge 0 -and `$idx + 1 -lt `$Args.Count) {
            `$global:UpsertBody = [string]`$Args[`$idx + 1]
        }
        `$global:LASTEXITCODE = 0
        return 'https://github.com/example/example/pull/429#issuecomment-1'
    }

    if (`$joined -match 'api repos/[^/]+/[^/]+ ') {
        `$global:LASTEXITCODE = 0
        return '{"owner":{"login":"example"},"name":"example"}'
    }

    if (`$joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
        `$global:UpsertCalled = `$true
        `$global:LASTEXITCODE = 0
        return '{"html_url":"https://github.com/example/example/pull/429#issuecomment-2"}'
    }

    `$global:LASTEXITCODE = 0
    return ''
}
"@
    }

    $script:NewV4PrBodyWithCredits = {
        param([Parameter(Mandatory)][Alias('CreditRows')][string]$LedgerRows)

        return @"
## Summary

Spine-backed PR body.

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
$LedgerRows
integrity_checks:
  - check: marker-presence
    status: passed
-->
"@
    }

    $script:NewV4PrBodyWithFallbackMetrics = {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$MetricsPrelude,
            [Parameter(Mandatory)][Alias('CreditRows')][string]$LedgerRows
        )

        return @"
## Summary

Spine-backed PR body.

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
$MetricsPrelude
credits:
$LedgerRows
integrity_checks:
  - check: marker-presence
    status: passed
-->
"@
    }

    $script:GetUpdatedPrBody = {
        param([AllowEmptyString()][string]$Output)

        $match = [regex]::Match($Output, '(?s)UPDATED_PR_BODY_BEGIN\r?\n(?<body>.*?)\r?\nUPDATED_PR_BODY_END')
        if (-not $match.Success) { return $null }

        return (($match.Groups['body'].Value -replace "`r`n", "`n") -replace "`r", "`n")
    }

    $script:NewFrameSpineComment = {
        param([Parameter(Mandatory)][string]$SpineBlock)

        $commentBody = @(
            '<!-- frame-spine'
            $SpineBlock
            '-->'
        ) -join "`n"

        return [pscustomobject]@{
            body = $commentBody
            url  = 'https://github.com/example/example/issues/512#issuecomment-spine'
        }
    }

    $script:InvokeCostWalkerOrchestratorInProcess = {
        param(
            [ValidateSet('ok', 'throw', 'timeout', 'empty')][string]$ClaudeMode = 'ok',
            [ValidateSet('ok', 'throw', 'timeout', 'empty')][string]$CopilotMode = 'ok',
            [string]$CostBranch = 'feature/issue-488-copilot-cost-collection',
            [string]$CopilotTimeoutSeconds = '2',
            [string]$ClaudeTimeoutSeconds = '2'
        )

        $previousCopilotPath = $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_OTEL_JSONL
        $previousCopilotTimeout = $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS
        $previousClaudeTimeout = $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS
        $previousClaudeMode = $env:FCL_TEST_CLAUDE_MODE
        $previousCopilotMode = $env:FCL_TEST_COPILOT_MODE
        $previousCostBranch = $env:FCL_TEST_COST_BRANCH
        $previousRepoRoot = $env:FCL_TEST_REPO_ROOT
        $copilotJsonlPath = Join-Path $TestDrive 'copilot-test.jsonl'

        try {
            $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_OTEL_JSONL = $copilotJsonlPath
            $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS = $CopilotTimeoutSeconds
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS = $ClaudeTimeoutSeconds

            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null
            $script:FrameCreditLedgerRepoRoot = $script:RepoRoot

            $env:FCL_TEST_CLAUDE_MODE = $ClaudeMode
            $env:FCL_TEST_COPILOT_MODE = $CopilotMode
            $env:FCL_TEST_COST_BRANCH = $CostBranch
            $env:FCL_TEST_REPO_ROOT = $script:RepoRoot

            function git {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '

                if ($joined -match 'rev-parse --show-toplevel') {
                    $global:LASTEXITCODE = 0
                    return $env:FCL_TEST_REPO_ROOT
                }
                if ($joined -match 'config --get remote\.origin\.url') {
                    $global:LASTEXITCODE = 0
                    return 'https://github.com/example/example.git'
                }
                if ($joined -match 'rev-parse --abbrev-ref HEAD') {
                    $global:LASTEXITCODE = 0
                    return $env:FCL_TEST_COST_BRANCH
                }
                if ($joined -match 'diff') {
                    $global:LASTEXITCODE = 0
                    return ''
                }

                $global:LASTEXITCODE = 0
                return ''
            }

            function gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                if ($joined -match 'pr view \d+ --json baseRefOid') {
                    $global:LASTEXITCODE = 0
                    return '{"baseRefOid":"abc123"}'
                }
                if ($joined -match 'pr view \d+ --json body') {
                    $global:LASTEXITCODE = 0
                    return (@{ body = $script:V4AllCoveredBody; comments = @() } | ConvertTo-Json -Compress -Depth 8)
                }
                if ($joined -match 'issue view \d+ --json comments') {
                    $global:LASTEXITCODE = 0
                    return '{"comments":[]}'
                }
                if ($joined -match 'pr edit \d+ .*--body-file') {
                    $global:LASTEXITCODE = 0
                    return 'https://github.com/example/example/pull/429'
                }
                if ($joined -match '(issue|pr) comment \d+ --body') {
                    $global:LASTEXITCODE = 0
                    return 'https://github.com/example/example/pull/429#issuecomment-1'
                }
                if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                    $global:LASTEXITCODE = 0
                    return '{"owner":{"login":"example"},"name":"example"}'
                }
                if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
                    $global:LASTEXITCODE = 0
                    return '{"html_url":"https://github.com/example/example/pull/429#issuecomment-2"}'
                }

                $global:LASTEXITCODE = 0
                return ''
            }

            function New-FCLTestClaudeCostEvent {
                return @{
                    type      = 'assistant'
                    provider  = 'claude'
                    cwd       = $env:FCL_TEST_REPO_ROOT
                    gitBranch = $env:FCL_TEST_COST_BRANCH
                    message   = @{
                        model       = 'claude-sonnet-4-x'
                        stop_reason = 'end_turn'
                        usage       = @{
                            input_tokens                = 100
                            output_tokens               = 20
                            cache_creation_input_tokens = 0
                            cache_read_input_tokens     = 0
                        }
                        content     = @()
                    }
                }
            }

            function New-FCLTestCopilotCostEvent {
                return @{
                    type      = 'assistant'
                    provider  = 'copilot'
                    agentType = 'GitHub Copilot Chat'
                    cwd       = 'copilot-otel://copilot-orchestra'
                    gitBranch = $env:FCL_TEST_COST_BRANCH
                    message   = @{
                        model       = 'claude-sonnet-4.6'
                        stop_reason = 'end_turn'
                        usage       = @{
                            input_tokens                = 40
                            output_tokens               = 10
                            cache_creation_input_tokens = 0
                            cache_read_input_tokens     = 0
                        }
                        content     = @()
                    }
                }
            }

            function Get-CostTranscriptSlug { param([string]$CwdPath) return 'test-slug' }
            function Invoke-CostTranscriptWalk {
                param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
                if ($Branch -ne $env:FCL_TEST_COST_BRANCH) { throw "unexpected Claude branch '$Branch'" }
                switch ($env:FCL_TEST_CLAUDE_MODE) {
                    'throw' { throw 'simulated Claude walker failure' }
                    'timeout' { Start-Sleep -Seconds 10; return @() }
                    'empty' { return @() }
                    default { return @(New-FCLTestClaudeCostEvent) }
                }
            }
            function Invoke-CostCopilotWalk {
                param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
                if ($Branch -ne $env:FCL_TEST_COST_BRANCH) { throw "unexpected Copilot branch '$Branch'" }
                switch ($env:FCL_TEST_COPILOT_MODE) {
                    'throw' { throw 'simulated Copilot walker failure' }
                    'timeout' { Start-Sleep -Seconds 10; return @() }
                    'empty' { return @() }
                    default { return @(New-FCLTestCopilotCostEvent) }
                }
            }
            function Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
            function Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
            function Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }

            $result = Invoke-FrameCreditLedger -Pr 429 -Mode warn
            return @{
                Result = $result
            }
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_OTEL_JSONL = $previousCopilotPath
            $env:FRAME_CREDIT_LEDGER_TEST_COPILOT_WALKER_TIMEOUT_SECONDS = $previousCopilotTimeout
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_WALKER_TIMEOUT_SECONDS = $previousClaudeTimeout
            $env:FCL_TEST_CLAUDE_MODE = $previousClaudeMode
            $env:FCL_TEST_COPILOT_MODE = $previousCopilotMode
            $env:FCL_TEST_COST_BRANCH = $previousCostBranch
            $env:FCL_TEST_REPO_ROOT = $previousRepoRoot
        }
    }
}

Describe 'frame-credit-ledger.ps1 orchestrator' {

    Context 'Parameter parsing + outer fail-open wrapper' {

        It 'accepts -Pr <int> -Mode warn and exits 0 on the all-covered v4 fixture' {
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
        }

        It 'accepts -Pr <int> -Mode enforce and exits 0 on the all-covered v4 fixture' {
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'enforce' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
        }

        It 'rejects an invalid -Mode value via ValidateSet (non-zero exit)' {
            $bootstrap = & $script:NewGhMockBootstrap

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'bogus' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            # ValidateSet rejection is a parameter-binding failure: pwsh exits non-zero.
            $result.ExitCode | Should -Not -Be 0
            # Guard against false-RED: at Step 4 RED the orchestrator does not
            # exist and the harness exits 127 with ORCHESTRATOR_NOT_FOUND on
            # stderr. That is NOT a valid ValidateSet rejection — fail the
            # test in that case.
            $result.Stderr | Should -Not -Match 'ORCHESTRATOR_NOT_FOUND'
            # Once the orchestrator exists, ValidateSet rejection emits a
            # canonical "Cannot validate argument" / "ValidateSet" message.
            $result.Stderr | Should -Match '(?i)validateset|Cannot validate argument|bogus'
        }

        It 'wraps internal exceptions with try/catch and still exits 0 in warn mode' {
            # Mock that throws inside the body-fetch path. The outer try/catch
            # around the script body must swallow it and exit 0 in warn mode.
            $extra = @'
$global:ThrowOnBody = $true
'@
            $bootstrapBase = & $script:NewGhMockBootstrap -ExtraDeclarations $extra
            # Patch the body branch to throw.
            $bootstrap = $bootstrapBase -replace [regex]::Escape("if (`$joined -match 'pr view \d+ --json body') {"), @"
if (`$joined -match 'pr view \d+ --json body') {
        throw 'simulated body-fetch failure'
"@

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
        }
    }

    Context 'gh pr view --json baseRefOid resolution including bounded retry' {

        It 'succeeds on the first call when baseRefOid is returned immediately' {
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap `
                -BodyJson $bodyJson `
                -BaseRefAttemptsBeforeSuccess 0

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            # Orchestrator should report exactly one baseRefOid call when it succeeds first try.
            $result.Stdout + $result.Stderr | Should -Not -Match '(?i)retry|backoff'
        }

        It 'retries with bounded backoff when first calls return null and eventually succeeds' {
            # Mock returns null twice then a real SHA on the 3rd attempt.
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap `
                -BodyJson $bodyJson `
                -BaseRefAttemptsBeforeSuccess 2

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            # Sleeps are skipped via TEST_NO_SLEEP, so the whole retry sequence completes fast.
            $result.DurationSeconds | Should -BeLessThan 15
        }

        It 'bails out after 3 attempts and emits a stderr note (warn mode exit 0)' {
            # Always return null -> orchestrator exhausts retries.
            $bootstrap = & $script:NewGhMockBootstrap `
                -BaseRefAttemptsBeforeSuccess 999

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            ($result.Stderr) | Should -Match '(?i)baseRefOid|retry|gh'
        }
    }

    Context 'Glob-walk adapter discovery' {

        It 'discovers adapters from frontmatter `provides:` across the configured globs' {
            # Build a minimal TestDrive fixture root with agents/, skills/, commands/.
            $fakeRoot = Join-Path $TestDrive 'fake-repo'
            $agentsDir = Join-Path $fakeRoot 'agents'
            $skillsDir = Join-Path $fakeRoot 'skills/example-skill'
            $skillsAdaptersDir = Join-Path $fakeRoot 'skills/example-skill/adapters'
            $commandsDir = Join-Path $fakeRoot 'commands'
            New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $skillsAdaptersDir -Force | Out-Null
            New-Item -ItemType Directory -Path $commandsDir -Force | Out-Null

            @"
---
name: Test-Writer
provides: implement-test
applies-when: changeset.touchesTestableCode()
---
body
"@ | Set-Content -Path (Join-Path $agentsDir 'Test-Writer.agent.md') -Encoding UTF8

            @"
---
name: example-skill
provides: design-clarity
applies-when: always
---
body
"@ | Set-Content -Path (Join-Path $skillsDir 'SKILL.md') -Encoding UTF8

            @"
---
provides: review
applies-when: changeset.touchesReviewableCode()
---
adapter body
"@ | Set-Content -Path (Join-Path $skillsAdaptersDir 'review-adapter.md') -Encoding UTF8

            @"
---
provides: orchestrate
applies-when: always
---
slash command body
"@ | Set-Content -Path (Join-Path $commandsDir 'orchestrate.md') -Encoding UTF8

            # Dot-source the orchestrator so we can call its discovery helper directly.
            # If the orchestrator doesn't exist yet, this is the RED signal.
            if (-not (Test-Path $script:OrchestratorPath)) {
                throw "RED: orchestrator not found at $script:OrchestratorPath"
            }
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null

            # Code-Smith: expose `Get-FrameCreditLedgerAdapters -RepoRoot <path>`
            # (or equivalent) so glob discovery is unit-testable.
            $adapters = Get-FrameCreditLedgerAdapters -RepoRoot $fakeRoot

            $providesValues = @($adapters | ForEach-Object { [string]$_.Provides })
            $providesValues | Should -Contain 'implement-test'
            $providesValues | Should -Contain 'design-clarity'
            $providesValues | Should -Contain 'review'
            $providesValues | Should -Contain 'orchestrate'
        }

        It 'skips files that have no `provides:` frontmatter key' {
            $fakeRoot = Join-Path $TestDrive 'fake-repo-no-provides'
            $agentsDir = Join-Path $fakeRoot 'agents'
            New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null

            @"
---
name: Plain-Doc
description: just documentation, not an adapter
---
body
"@ | Set-Content -Path (Join-Path $agentsDir 'Plain-Doc.agent.md') -Encoding UTF8

            if (-not (Test-Path $script:OrchestratorPath)) {
                throw "RED: orchestrator not found at $script:OrchestratorPath"
            }
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null

            $adapters = Get-FrameCreditLedgerAdapters -RepoRoot $fakeRoot
            @($adapters).Count | Should -Be 0
        }
    }

    Context '30s budget + per-call timeout primitive' {

        It 'completes within the budget when gh hangs (warn mode exit 0)' {
            # Mock simulates a hanging gh via Start-Sleep -Seconds 60 inside
            # the baseRefOid branch. The orchestrator's outer Wait-Job /
            # Wait-Process -Timeout primitive must return before then.
            $bootstrap = & $script:NewGhMockBootstrap -HangOnBaseRef $true

            # Override the budget to 3s so the test doesn't wait ~30s. The
            # orchestrator must honour FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS.
            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{
                FRAME_CREDIT_LEDGER_TEST_NO_SLEEP       = '1'
                FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS = '3'
            } `
                -TimeoutSeconds 30 `
                -MockBootstrap $bootstrap

            # Outer harness timeout is 30s. If the orchestrator's own timeout
            # works, we return well under that.
            $result.TimedOut | Should -Be $false
            $result.DurationSeconds | Should -BeLessThan 20
            $result.ExitCode | Should -Be 0
        }

        It 'does not block PR creation when the timeout fires (warn-mode invariant)' {
            $bootstrap = & $script:NewGhMockBootstrap -HangOnBaseRef $true

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{
                FRAME_CREDIT_LEDGER_TEST_NO_SLEEP       = '1'
                FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS = '3'
            } `
                -TimeoutSeconds 30 `
                -MockBootstrap $bootstrap

            # Warn mode invariant: even on timeout, exit 0 (do not block PR creation).
            $result.ExitCode | Should -Be 0
        }
    }

    Context 'Orchestrator main flow against v4-fixture PR body' {

        It 'composes a v4 ledger comment and posts it via Find-OrUpsertComment when v4 is detected' {
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0

            # The orchestrator's gh-call log is dumped to stdout for assertion.
            # Code-Smith: emit `GH_CALL_LOG: <line>` for each gh invocation
            # (or print $global:GhCallLog at end of script) so tests can verify
            # the upsert was attempted with the canonical marker.
            $combined = "$($result.Stdout)`n$($result.Stderr)"
            $combined | Should -Match '(?i)frame-credit-ledger-429'
            $combined | Should -Match '(?i)Frame credit ledger'
        }

        It 'short-circuits to the pre-v4 comment when metrics_version is not 4' {
            $bodyJson = (@{ body = $script:PreV4Body } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            (($result.Stdout, $result.Stderr) -join "`n") | Should -Match '(?i)pre-v4 metrics detected'
        }

        It 'enforce mode exits 1 when at least one port is NotCovered' {
            $bodyJson = (@{ body = $script:V4WithNotCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'enforce' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 1
        }

        It 'enforce mode exits 0 when no ports are NotCovered (only Covered or Inconclusive)' {
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'enforce' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
        }
    }

    Context 'Issue #488 Step 8 cost walker integration' {

        It 'renders Claude cost data when the Copilot walker times out' {
            $result = & $script:InvokeCostWalkerOrchestratorInProcess -ClaudeMode 'ok' -CopilotMode 'timeout' -CopilotTimeoutSeconds '1'

            $result.Result.ExitCode | Should -Be 0
            $result.Result.Comment | Should -Match '## Cost Pattern'
            $result.Result.Comment | Should -Match '(?m)^coverage: claude-only-with-copilot-fallback-warning$'
            $result.Result.Comment | Should -Match '(?m)^branch: feature/issue-488-copilot-cost-collection$'
        }

        It 'merges Claude and Copilot walker events before attribution and renders claude+copilot coverage' {
            $result = & $script:InvokeCostWalkerOrchestratorInProcess -ClaudeMode 'ok' -CopilotMode 'ok'

            $result.Result.ExitCode | Should -Be 0
            $result.Result.Comment | Should -Match '(?m)^coverage: claude\+copilot$'
            $result.Result.Comment | Should -Match 'provider_support: \["claude", "copilot"\]'
            $result.Result.Comment | Should -Match '(?m)^branch: feature/issue-488-copilot-cost-collection$'
        }

        It 'fail-opens to no cost section when the Claude walker throws and no Copilot events are available' {
            $result = & $script:InvokeCostWalkerOrchestratorInProcess -ClaudeMode 'throw' -CopilotMode 'empty'

            $result.Result.ExitCode | Should -Be 0
            $result.Result.Comment | Should -Match 'Frame credit ledger'
            $result.Result.Comment | Should -Not -Match '## Cost Pattern'
        }

        It 'wires coverage into the fixture-driven Cost Pattern comment end to end' {
            $result = & $script:InvokeCostWalkerOrchestratorInProcess -ClaudeMode 'ok' -CopilotMode 'ok'

            $result.Result.ExitCode | Should -Be 0
            $result.Result.Comment | Should -Match '<!-- cost-pattern-data'
            $result.Result.Comment | Should -Match '(?m)^coverage: claude\+copilot$'
        }
    }

    Context 'Issue #512 incomplete cycle detection from terminal spine markers' {

        It 'falls back to PR number for issue spine lookup when body and PR comments do not identify an issue' {
            $spineBlock = @(
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T14:30:00Z'
                'coverage: complete'
                'ports:'
                '  implement-test: [s4#cycle:2#terminal]'
                'slices:'
                '  s4:'
                '    execution_mode: serial'
                '    rc: RED test action'
                '    ac_refs: [AC7]'
                '    depends_on: []'
                '    cycle: 2'
                '    terminal: true'
            ) -join "`n"
            $spineComment = & $script:NewFrameSpineComment -SpineBlock $spineBlock
            $issueCommentsJson = (@{ comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $prBody = & $script:NewV4PrBodyWithCredits -CreditRows @'
  - port: review
    status: passed
    evidence: "review complete"
'@
            $bodyJson = (@{ body = $prBody; comments = @() } | ConvertTo-Json -Compress -Depth 8)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson -IssueCommentsJson $issueCommentsJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            $combined = "$($result.Stdout)`n$($result.Stderr)"
            $incompleteRows = @($combined -split "`r?`n" | Where-Object {
                    $_ -match '^\|\s*implement-test\s*\|' -and $_ -match 'incomplete-cycle'
                })

            $incompleteRows | Should -HaveCount 1
            $incompleteRows[0] | Should -Match 's4|terminal-step-id\s*:?\s*4'
        }

        It 'reports an incomplete-cycle row when a terminal-marked spine port has no matching terminal credit' {
            $spineBlock = @(
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T14:30:00Z'
                'coverage: complete'
                'ports:'
                '  implement-test: [s4#cycle:2#terminal]'
                'slices:'
                '  s4:'
                '    execution_mode: serial'
                '    rc: RED test action'
                '    ac_refs: [AC7]'
                '    depends_on: []'
                '    cycle: 2'
                '    terminal: true'
            ) -join "`n"
            $spineComment = & $script:NewFrameSpineComment -SpineBlock $spineBlock
            $issueCommentsJson = (@{ comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $prBody = & $script:NewV4PrBodyWithCredits -CreditRows @'
  - port: review
    status: passed
    evidence: "review complete"
'@
            $bodyJson = (@{ body = $prBody; comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson -IssueCommentsJson $issueCommentsJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            $combined = "$($result.Stdout)`n$($result.Stderr)"
            $incompleteRows = @($combined -split "`r?`n" | Where-Object {
                    $_ -match '^\|\s*implement-test\s*\|' -and $_ -match 'incomplete-cycle'
                })

            $incompleteRows | Should -HaveCount 1
            $incompleteRows[0] | Should -Match 's4|terminal-step-id\s*:?\s*4'
        }

        It 'does not report incomplete-cycle when a later terminal cycle has a matching terminal-step-id credit' {
            $spineBlock = @(
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T14:30:00Z'
                'coverage: complete'
                'ports:'
                '  implement-test: [s2, s5#cycle:2#terminal]'
                'slices:'
                '  s2:'
                '    execution_mode: serial'
                '    rc: RED test action'
                '    ac_refs: [AC7]'
                '    depends_on: []'
                '    cycle: 1'
                '  s5:'
                '    execution_mode: serial'
                '    rc: RED test action'
                '    ac_refs: [AC7]'
                '    depends_on: [s2]'
                '    cycle: 2'
                '    terminal: true'
            ) -join "`n"
            $spineComment = & $script:NewFrameSpineComment -SpineBlock $spineBlock
            $issueCommentsJson = (@{ comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $prBody = & $script:NewV4PrBodyWithCredits -CreditRows @'
  - port: implement-test
    status: passed
    terminal-step-id: 5
    evidence: "tests passed for terminal cycle"
'@
            $bodyJson = (@{ body = $prBody; comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson -IssueCommentsJson $issueCommentsJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            $combined = "$($result.Stdout)`n$($result.Stderr)"
            $incompleteRows = @($combined -split "`r?`n" | Where-Object { $_ -match 'incomplete-cycle' })

            $incompleteRows | Should -HaveCount 0
        }

        It 'reports a matching failed terminal-step credit as the authoritative visible status instead of an earlier passed row' {
            $spineBlock = @(
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T14:30:00Z'
                'coverage: complete'
                'ports:'
                '  implement-test: [s3, s5#cycle:2#terminal]'
                'slices:'
                '  s3:'
                '    execution_mode: serial'
                '    rc: RED test action'
                '    ac_refs: [AC7]'
                '    depends_on: []'
                '    cycle: 1'
                '  s5:'
                '    execution_mode: serial'
                '    rc: terminal validation'
                '    ac_refs: [AC7]'
                '    depends_on: [s3]'
                '    cycle: 2'
                '    terminal: true'
            ) -join "`n"
            $spineComment = & $script:NewFrameSpineComment -SpineBlock $spineBlock
            $issueCommentsJson = (@{ comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $prBody = & $script:NewV4PrBodyWithCredits -CreditRows @'
  - port: implement-test
    status: passed
    terminal-step-id: 3
    evidence: "earlier cycle passed"
  - port: implement-test
    status: failed
    terminal-step-id: 5
    evidence: "terminal cycle failed"
'@
            $bodyJson = (@{ body = $prBody; comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson -IssueCommentsJson $issueCommentsJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            $combined = "$($result.Stdout)`n$($result.Stderr)"
            $coverageText = ($combined -split '(?m)^## Cost Pattern', 2)[0]
            $portRows = @($coverageText -split "`r?`n" | Where-Object { $_ -match '^\|\s*implement-test\s*\|' })

            $portRows | Should -HaveCount 1
            $portRows[0] | Should -Match 'failed'
            $portRows[0] | Should -Match 'terminal cycle failed'
            $portRows[0] | Should -Not -Match 'earlier cycle passed'
            $combined | Should -Not -Match 'incomplete-cycle'
        }

        It 'does not report incomplete-cycle rows when the spine has no terminal markers' {
            $spineBlock = @(
                'spine_schema_version: 1'
                'generated_at: 2026-05-04T14:30:00Z'
                'coverage: complete'
                'ports:'
                '  implement-test: [s2, s5#cycle:2]'
                'slices:'
                '  s2:'
                '    execution_mode: serial'
                '    rc: RED test action'
                '    ac_refs: [AC7]'
                '    depends_on: []'
                '    cycle: 1'
                '  s5:'
                '    execution_mode: serial'
                '    rc: RED test action'
                '    ac_refs: [AC7]'
                '    depends_on: [s2]'
                '    cycle: 2'
            ) -join "`n"
            $spineComment = & $script:NewFrameSpineComment -SpineBlock $spineBlock
            $issueCommentsJson = (@{ comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $prBody = & $script:NewV4PrBodyWithCredits -CreditRows @'
  - port: review
    status: passed
    evidence: "review complete"
'@
            $bodyJson = (@{ body = $prBody; comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson -IssueCommentsJson $issueCommentsJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            $combined = "$($result.Stdout)`n$($result.Stderr)"
            $incompleteRows = @($combined -split "`r?`n" | Where-Object { $_ -match 'incomplete-cycle' })

            $incompleteRows | Should -HaveCount 0
        }
    }

    Context 'Issue #512 stale-spine fallback PR-body metrics' {

        It 'leaves spine-stale-fallback-count absent when no stale-spine fallback event occurred' {
            $prBody = & $script:NewV4PrBodyWithFallbackMetrics `
                -MetricsPrelude '' `
                -CreditRows @'
  - port: implement-test
    status: passed
    evidence: "tests passed"
'@
            $bodyJson = (@{ body = $prBody; comments = @() } | ConvertTo-Json -Compress -Depth 8)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            $updatedBody = & $script:GetUpdatedPrBody -Output "$($result.Stdout)`n$($result.Stderr)"

            $updatedBody | Should -Not -BeNullOrEmpty -Because 'the orchestrator must re-emit the PR body metrics block when applying additive fallback metrics'
            $updatedBody | Should -Not -Match '(?m)^\s*spine-stale-fallback-count\s*:' `
                -Because 'absence, not zero, is the default when no stale-spine fallback event has occurred'
        }

        It 'writes spine-stale-fallback-count with the event count when stale-spine fallback events occurred' {
            $metricsPrelude = @'
dispatch-fallback-events:
  stale-spine:
    - step: 10
      reason: generated_at-mismatch
    - step: 12
      reason: missing-step-id
'@
            $prBody = & $script:NewV4PrBodyWithFallbackMetrics `
                -MetricsPrelude $metricsPrelude `
                -CreditRows @'
  - port: implement-test
    status: passed
    evidence: "tests passed"
'@
            $bodyJson = (@{ body = $prBody; comments = @() } | ConvertTo-Json -Compress -Depth 8)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            $updatedBody = & $script:GetUpdatedPrBody -Output "$($result.Stdout)`n$($result.Stderr)"

            $updatedBody | Should -Not -BeNullOrEmpty -Because 'stale-spine fallback events must be persisted back into PR-body pipeline metrics'
            $updatedBody | Should -Match '(?m)^spine-stale-fallback-count:\s*2\s*$'
        }

        It 'never decrements spine-stale-fallback-count when additive metrics already contain a higher value' {
            $metricsPrelude = @'
spine-stale-fallback-count: 5
dispatch-fallback-events:
  stale-spine:
    - step: 10
      reason: generated_at-mismatch
    - step: 12
      reason: missing-step-id
'@
            $prBody = & $script:NewV4PrBodyWithFallbackMetrics `
                -MetricsPrelude $metricsPrelude `
                -CreditRows @'
  - port: implement-test
    status: passed
    evidence: "tests passed"
'@
            $bodyJson = (@{ body = $prBody; comments = @() } | ConvertTo-Json -Compress -Depth 8)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0
            $updatedBody = & $script:GetUpdatedPrBody -Output "$($result.Stdout)`n$($result.Stderr)"

            $updatedBody | Should -Not -BeNullOrEmpty -Because 'additive PR-body metrics updates must preserve previously observed stale-spine fallback counts'
            $updatedBody | Should -Match '(?m)^spine-stale-fallback-count:\s*5\s*$'
            $updatedBody | Should -Not -Match '(?m)^spine-stale-fallback-count:\s*[0-4]\s*$'
        }
    }

    Context 'Issue #512 dispatch-cost-samples PR-body metrics' {

        It 'back-fills dispatch-cost-samples during the best-effort PR-body metrics pass and preserves existing fields' {
            if (-not (Test-Path $script:OrchestratorPath)) {
                throw "RED: orchestrator not found at $script:OrchestratorPath"
            }
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null

            $body = & $script:NewV4PrBodyWithFallbackMetrics `
                -MetricsPrelude @'
dispatch-cost-samples:
  - step-id: s12
    mode: spine
    bytes: 7421
    rc-conformance: not-evaluated
    judge-disposition: not-evaluated
'@ `
                -CreditRows @'
  - port: implement-test
    status: passed
    terminal-step-id: 12
    evidence: "RC conformance passed"
  - port: review
    status: passed
    evidence: "judge accepted"
'@

            $command = Get-Command Update-FCLPrBodyDispatchCostSamples -ErrorAction SilentlyContinue
            $command | Should -Not -BeNullOrEmpty

            $updated = & $command -PrBody $body -StepId 's12' -Mode 'spine' -RcConformance 'pass' -JudgeDisposition 'accepted'
            $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

            $normalized | Should -Match '(?ms)- step-id: s12\n    mode: spine\n    bytes: 7421\n    rc-conformance: pass\n    judge-disposition: accepted'
            $normalized | Should -Match '(?m)^metrics_version:\s*4\s*$'
            $normalized | Should -Match '(?m)^frame_version:\s*1\s*$'
            $normalized | Should -Match '(?m)^credits:\s*$'
            $normalized | Should -Match '(?m)^integrity_checks:\s*$'
        }
    }

    Context 'C-Risk-1 fix: predicate evaluator is wired into per-adapter applicability' {

        It 'Resolve-FrameCreditLedgerApplicableMap evaluates `applies-when` against the changeset and returns true/false (not "unknown") for supported identifiers' {
            # Dot-source the orchestrator so we can call Resolve-FrameCreditLedgerApplicableMap directly.
            if (-not (Test-Path $script:OrchestratorPath)) {
                throw "RED: orchestrator not found at $script:OrchestratorPath"
            }
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null

            # The release-hygiene adapter declares applies-when: changeset.touchesPluginEntryPoint().
            # Evaluator should resolve this against a synthetic changeset.
            $adapter = [pscustomobject]@{
                Name              = 'plugin-release-hygiene'
                Provides          = 'release-hygiene'
                AppliesWhen       = 'changeset.touchesPluginEntryPoint()'
                SuggestedNextStep = 'bump plugin version'
            }

            # Changeset that touches an agents/*.agent.md plugin entry-point file.
            $hitChangeset = @{
                ChangedFiles  = @('agents/Code-Smith.agent.md')
                TotalLines    = 5
                IsReReview    = $false
                IsProxyGithub = $false
            }
            $script:DeferredNotedPairs = @{}
            $hitMap = Resolve-FrameCreditLedgerApplicableMap -PortName 'release-hygiene' -Adapters @($adapter) -Changeset $hitChangeset
            $hitMap['plugin-release-hygiene'] | Should -Be 'true' -Because 'agents/*.agent.md is a plugin entry-point per Get-FVPluginEntryPointPatterns'

            # Changeset that does NOT touch any plugin entry-point file.
            $missChangeset = @{
                ChangedFiles  = @('Documents/Design/random.md')
                TotalLines    = 5
                IsReReview    = $false
                IsProxyGithub = $false
            }
            $script:DeferredNotedPairs = @{}
            $missMap = Resolve-FrameCreditLedgerApplicableMap -PortName 'release-hygiene' -Adapters @($adapter) -Changeset $missChangeset
            $missMap['plugin-release-hygiene'] | Should -Be 'false' -Because 'Documents/*.md does not match any plugin-entry-point pattern'
        }

        It 'Resolve-FrameCreditLedgerApplicableMap defaults adapters with no `applies-when` to "true" (always applies)' {
            if (-not (Test-Path $script:OrchestratorPath)) {
                throw "RED: orchestrator not found at $script:OrchestratorPath"
            }
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null

            $adapter = [pscustomobject]@{
                Name              = 'always-on-adapter'
                Provides          = 'review'
                AppliesWhen       = $null
                SuggestedNextStep = 'run review'
            }
            $changeset = @{
                ChangedFiles  = @('any/file.txt')
                TotalLines    = 1
                IsReReview    = $false
                IsProxyGithub = $false
            }
            $script:DeferredNotedPairs = @{}
            $map = Resolve-FrameCreditLedgerApplicableMap -PortName 'review' -Adapters @($adapter) -Changeset $changeset
            $map['always-on-adapter'] | Should -Be 'true'
        }

        It 'Resolve-FrameCreditLedgerApplicableMap emits a stderr note for deferred predicate identifiers (one per port-adapter pair)' {
            if (-not (Test-Path $script:OrchestratorPath)) {
                throw "RED: orchestrator not found at $script:OrchestratorPath"
            }
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null

            $adapter = [pscustomobject]@{
                Name              = 'review-credit-aware-adapter'
                Provides          = 'review'
                # review.sustainedCriticalOrHigh is a deferred-credit-reference identifier (returns 'unknown').
                AppliesWhen       = 'review.sustainedCriticalOrHigh == true'
                SuggestedNextStep = 'rerun /orchestra:review'
            }
            $changeset = @{
                ChangedFiles  = @('any/file.txt')
                TotalLines    = 1
                IsReReview    = $false
                IsProxyGithub = $false
            }
            $script:DeferredNotedPairs = @{}
            $map = Resolve-FrameCreditLedgerApplicableMap -PortName 'review' -Adapters @($adapter) -Changeset $changeset 2>&1
            # Map result is the only return; stderr writes go to [Console]::Error which is hard
            # to capture in-process. Validate behaviorally: result is 'unknown' for the deferred id.
            $map['review-credit-aware-adapter'] | Should -Be 'unknown'
            # And the dedup map records the pair.
            $script:DeferredNotedPairs.ContainsKey('review::review-credit-aware-adapter') | Should -BeTrue
        }
    }
}
