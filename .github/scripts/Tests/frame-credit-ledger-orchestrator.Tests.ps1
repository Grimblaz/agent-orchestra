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
            [string]$ClaudeTimeoutSeconds = '2',
            [object[]]$RollingEntries = @()
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
            $script:FCL_TEST_ROLLING_ENTRIES = @($RollingEntries)
            $script:FCL_TEST_CHECKPOINT_COVERAGE = $null

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

            function Get-FCLTestClaudeCostEvent {
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

            function Get-FCLTestCopilotCostEvent {
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

            function Get-CostTranscriptSlug { param([string]$CwdPath) $null = $CwdPath; return 'test-slug' }
            function Invoke-CostTranscriptWalk {
                param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
                $null = $Slug
                $null = $ParentCwd
                $null = $IssueNumber
                if ($Branch -ne $env:FCL_TEST_COST_BRANCH) { throw "unexpected Claude branch '$Branch'" }
                switch ($env:FCL_TEST_CLAUDE_MODE) {
                    'throw' { throw 'simulated Claude walker failure' }
                    'timeout' { Start-Sleep -Seconds 10; return @() }
                    'empty' { return @() }
                    default { return @(Get-FCLTestClaudeCostEvent) }
                }
            }
            function Invoke-CostCopilotWalk {
                param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
                $null = $RepoRoot
                $null = $OtelJsonlPath
                $null = $WorkspaceFolderBasename
                if ($Branch -ne $env:FCL_TEST_COST_BRANCH) { throw "unexpected Copilot branch '$Branch'" }
                switch ($env:FCL_TEST_COPILOT_MODE) {
                    'throw' { throw 'simulated Copilot walker failure' }
                    'timeout' { Start-Sleep -Seconds 10; return @() }
                    'empty' { return @() }
                    default { return @(Get-FCLTestCopilotCostEvent) }
                }
            }
            function Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) $null = $TimeoutSeconds; return @{ timed_out = $false; entries = @($script:FCL_TEST_ROLLING_ENTRIES) } }
            function Get-MostRecentRegimeCheckpoint { param([string]$Path, [string]$Coverage = '') $null = $Path; $script:FCL_TEST_CHECKPOINT_COVERAGE = $Coverage; return $null }
            function Get-CostAnomalyFlags {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
                param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint)
                $null = $ThisRun
                $null = $RollingHistory
                $null = $RegimeCheckpoint
                return @()
            }

            $result = Invoke-FrameCreditLedger -Pr 429 -Mode warn
            return @{
                Result             = $result
                CheckpointCoverage = $script:FCL_TEST_CHECKPOINT_COVERAGE
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
            Remove-Variable -Name FCL_TEST_ROLLING_ENTRIES -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name FCL_TEST_CHECKPOINT_COVERAGE -Scope Script -ErrorAction SilentlyContinue
        }
    }

    # In-process helper for content tests — replaces the spawn-based InvokeOrchestrator for
    # all It-blocks that assert on comment content or exit-code values returned by
    # Invoke-FrameCreditLedger (not OS-level process exit codes or timeout mechanics).
    #
    # Returns a hashtable:
    #   Result         — the hashtable returned by Invoke-FrameCreditLedger
    #   UpdatedPrBody  — the updated PR body string written by gh pr edit --body-file (or $null)
    #   GhCallLog      — array of joined gh argument strings
    #
    # Parameters mirror the most common InvokeOrchestrator call patterns so that
    # converting a spawn-based It-block is a mechanical replacement.
    $script:InvokeOrchestratorInProcess = {
        param(
            [int]$Pr = 429,
            [ValidateSet('warn', 'enforce')][string]$Mode = 'warn',
            [AllowEmptyString()][string]$PrBodyJson = '',
            [string]$IssueCommentsJson = '{"comments":[]}',
            [int]$BaseRefAttemptsBeforeSuccess = 0,
            [bool]$ThrowOnBodyFetch = $false,
            [hashtable]$EnvVars = @{},
            # When non-empty, the GH mock calls this scriptblock for pr view --json body.
            # Allows tests to supply custom per-call body responses.
            [scriptblock]$CustomBodyBranch = $null
        )

        # Snapshot env vars that we will mutate so we can restore them in finally.
        $previousEnvSnapshot = @{}
        $envKeys = @(
            'FRAME_CREDIT_LEDGER_TEST_NO_SLEEP',
            'FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS',
            'FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER',
            'FRAME_ENFORCE',
            'PR_CREATED_AT'
        ) + @($EnvVars.Keys)
        foreach ($k in ($envKeys | Select-Object -Unique)) {
            $previousEnvSnapshot[$k] = [System.Environment]::GetEnvironmentVariable($k)
        }

        # State collected during the call for the caller to assert on.
        $script:InProcessGhCallLog = @()
        $script:InProcessUpdatedPrBody = $null
        $script:InProcessBaseRefAttempts = 0

        # Save Pr and Mode before dot-sourcing — the dot-source assigns those param names
        # in the calling scope, which would overwrite our own parameters.
        $private:prNumber = $Pr
        $private:modeValue = $Mode

        try {
            # Apply caller-supplied env vars.
            foreach ($k in $EnvVars.Keys) {
                [System.Environment]::SetEnvironmentVariable($k, [string]$EnvVars[$k])
            }

            # Dot-source the orchestrator to load all functions without running the
            # top-level execution block (because $isDotSourced will be $true).
            . $script:OrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null
            $script:FrameCreditLedgerRepoRoot = $script:RepoRoot

            # ---- git mock -------------------------------------------------------
            function git {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                if ($joined -match 'rev-parse --show-toplevel') {
                    $global:LASTEXITCODE = 0; return $script:RepoRoot
                }
                if ($joined -match 'config --get remote\.origin\.url') {
                    $global:LASTEXITCODE = 0; return 'https://github.com/example/example.git'
                }
                if ($joined -match 'rev-parse --abbrev-ref HEAD') {
                    $global:LASTEXITCODE = 0; return 'feature/test-branch'
                }
                if ($joined -match 'diff') {
                    $global:LASTEXITCODE = 0; return ''
                }
                $global:LASTEXITCODE = 0; return ''
            }

            # ---- gh mock --------------------------------------------------------
            # Resolve body JSON once (the mock can be called multiple times).
            $resolvedPrBodyJson = $PrBodyJson
            if ([string]::IsNullOrEmpty($resolvedPrBodyJson)) {
                $resolvedPrBodyJson = (@{ body = '## empty body' } | ConvertTo-Json -Compress)
            }
            $resolvedIssueComments = $IssueCommentsJson
            $capturedBaseRefAttemptsBeforeSuccess = $BaseRefAttemptsBeforeSuccess
            $capturedThrowOnBodyFetch = $ThrowOnBodyFetch

            function gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $script:InProcessGhCallLog += $joined

                if ($joined -match 'pr view \d+ --json baseRefOid') {
                    $script:InProcessBaseRefAttempts++
                    if ($script:InProcessBaseRefAttempts -le $capturedBaseRefAttemptsBeforeSuccess) {
                        $global:LASTEXITCODE = 0; return '{"baseRefOid":null}'
                    }
                    $global:LASTEXITCODE = 0; return '{"baseRefOid":"abc123"}'
                }

                if ($joined -match 'pr view \d+ ') {
                    $jsonIdx = [Array]::IndexOf($Args, '--json')
                    $jsonFields = if ($jsonIdx -ge 0 -and $jsonIdx + 1 -lt $Args.Count) { [string]$Args[$jsonIdx + 1] } else { '' }

                    if ($jsonFields -eq 'body,comments') {
                        if ($capturedThrowOnBodyFetch) {
                            throw 'simulated body-fetch failure'
                        }
                        $global:LASTEXITCODE = 0
                        # Parse the PrBodyJson to get the body string, then wrap with empty comments.
                        try {
                            $parsedBody = $resolvedPrBodyJson | ConvertFrom-Json
                            if ($null -ne $parsedBody -and $null -ne $parsedBody.body) {
                                # Already has body+comments shape.
                                return $resolvedPrBodyJson
                            }
                        }
                        catch { }
                        # Treat as raw body string or simple {body:...} JSON.
                        return (@{ body = ($resolvedPrBodyJson | ConvertFrom-Json -ErrorAction SilentlyContinue)?.body ?? $resolvedPrBodyJson; comments = @() } | ConvertTo-Json -Compress -Depth 8)
                    }

                    if ($jsonFields -eq 'body') {
                        if ($capturedThrowOnBodyFetch) {
                            throw 'simulated body-fetch failure'
                        }
                        $global:LASTEXITCODE = 0; return $resolvedPrBodyJson
                    }
                }

                if ($joined -match 'issue view \d+ --json comments') {
                    $global:LASTEXITCODE = 0; return $resolvedIssueComments
                }

                if ($joined -match 'pr edit \d+ .*--body-file') {
                    $idx = [Array]::IndexOf($Args, '--body-file')
                    if ($idx -ge 0 -and $idx + 1 -lt $Args.Count) {
                        $bodyFile = [string]$Args[$idx + 1]
                        $script:InProcessUpdatedPrBody = (Test-Path -LiteralPath $bodyFile) ? (Get-Content -LiteralPath $bodyFile -Raw) : ''
                    }
                    $global:LASTEXITCODE = 0; return 'https://github.com/example/example/pull/429'
                }

                if ($joined -match 'pr edit \d+ .*--body') {
                    $idx = [Array]::IndexOf($Args, '--body')
                    if ($idx -ge 0 -and $idx + 1 -lt $Args.Count) {
                        $script:InProcessUpdatedPrBody = [string]$Args[$idx + 1]
                    }
                    $global:LASTEXITCODE = 0; return 'https://github.com/example/example/pull/429'
                }

                if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/pulls/\d+') {
                    foreach ($arg in $Args) {
                        $argText = [string]$arg
                        if ($argText -like 'body=*') {
                            $script:InProcessUpdatedPrBody = $argText.Substring(5)
                            break
                        }
                    }
                    $global:LASTEXITCODE = 0; return '{"html_url":"https://github.com/example/example/pull/429"}'
                }

                if ($joined -match '(issue|pr) comment \d+ --body') {
                    $global:LASTEXITCODE = 0; return 'https://github.com/example/example/pull/429#issuecomment-1'
                }

                if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                    $global:LASTEXITCODE = 0; return '{"owner":{"login":"example"},"name":"example"}'
                }

                if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
                    $global:LASTEXITCODE = 0; return '{"html_url":"https://github.com/example/example/pull/429#issuecomment-2"}'
                }

                $global:LASTEXITCODE = 0; return ''
            }

            # Cost-walker stubs (same as InvokeCostWalkerOrchestratorInProcess — cost path
            # is always fail-open in these content tests, so empty events is fine).
            function Get-CostTranscriptSlug { param([string]$CwdPath) $null = $CwdPath; return 'test-slug' }
            function Invoke-CostTranscriptWalk {
                param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
                $null = $Slug; $null = $Branch; $null = $ParentCwd; $null = $IssueNumber
                return @()
            }
            function Invoke-CostCopilotWalk {
                param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
                $null = $Branch; $null = $RepoRoot; $null = $OtelJsonlPath; $null = $WorkspaceFolderBasename
                return @()
            }
            function Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) $null = $TimeoutSeconds; return @{ timed_out = $false; entries = @() } }
            function Get-MostRecentRegimeCheckpoint { param([string]$Path, [string]$Coverage = '') $null = $Path; $null = $Coverage; return $null }
            function Get-CostAnomalyFlags {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
                param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint)
                $null = $ThisRun; $null = $RollingHistory; $null = $RegimeCheckpoint
                return @()
            }

            $result = Invoke-FrameCreditLedger -Pr $private:prNumber -Mode $private:modeValue
            return @{
                Result        = $result
                UpdatedPrBody = $script:InProcessUpdatedPrBody
                GhCallLog     = $script:InProcessGhCallLog
            }
        }
        finally {
            # Restore env vars.
            foreach ($k in $previousEnvSnapshot.Keys) {
                [System.Environment]::SetEnvironmentVariable($k, $previousEnvSnapshot[$k])
            }
            Remove-Variable -Name InProcessGhCallLog -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name InProcessUpdatedPrBody -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name InProcessBaseRefAttempts -Scope Script -ErrorAction SilentlyContinue
        }
    }
}

Describe 'frame-credit-ledger.ps1 orchestrator' {

    Context 'Parameter parsing + outer fail-open wrapper' {

        It 'accepts -Pr <int> -Mode warn and exits 0 on the all-covered v4 fixture' {
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson

            $ip.Result.ExitCode | Should -Be 0
        }

        It 'accepts -Pr <int> -Mode enforce and exits 0 on the all-covered v4 fixture' {
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'enforce' `
                -PrBodyJson $bodyJson `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1' }

            $ip.Result.ExitCode | Should -Be 0
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

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson `
                -BaseRefAttemptsBeforeSuccess 0 `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' }

            $ip.Result.ExitCode | Should -Be 0
            # Exactly one baseRefOid call when it succeeds on the first try.
            $baseRefCalls = @($ip.GhCallLog | Where-Object { $_ -match 'pr view \d+ --json baseRefOid' })
            $baseRefCalls | Should -HaveCount 1
        }

        It 'retries with bounded backoff when first calls return null and eventually succeeds' {
            # Mock returns null twice then a real SHA on the 3rd attempt.
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson `
                -BaseRefAttemptsBeforeSuccess 2 `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' }

            $ip.Result.ExitCode | Should -Be 0
            # Mock returns null for attempts 1 and 2, real SHA on attempt 3.
            $baseRefCalls = @($ip.GhCallLog | Where-Object { $_ -match 'pr view \d+ --json baseRefOid' })
            $baseRefCalls | Should -HaveCount 3
        }

        It 'bails out after 3 attempts and emits a stderr note (warn mode exit 0)' {
            # Always return null -> orchestrator exhausts retries; fail-open: exit 0.
            # Provide a valid body so the function continues past baseRefOid failure.
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson `
                -BaseRefAttemptsBeforeSuccess 999 `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' }

            $ip.Result.ExitCode | Should -Be 0
            # All 3 retry attempts should have been made.
            $baseRefCalls = @($ip.GhCallLog | Where-Object { $_ -match 'pr view \d+ --json baseRefOid' })
            $baseRefCalls | Should -HaveCount 3
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

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson

            $ip.Result.ExitCode | Should -Be 0
            # Comment should contain the canonical marker and the ledger heading.
            $ip.Result.Comment | Should -Match '(?i)frame-credit-ledger-429'
            $ip.Result.Comment | Should -Match '(?i)Frame credit ledger'
        }

        It 'short-circuits to the pre-v4 comment when metrics_version is not 4' {
            $bodyJson = (@{ body = $script:PreV4Body } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson

            # In-process: Invoke-FrameCreditLedger returns ExitCode 5 for the pre-v4 short-circuit
            # path (IsInternalError = true). The process-level exit code is 0 in warn mode — that
            # coercion happens in the top-level execution block, outside Invoke-FrameCreditLedger.
            # The meaningful assertion is that the comment contains the pre-v4 text.
            $ip.Result.Comment | Should -Not -BeNullOrEmpty
            $ip.Result.Comment | Should -Match '(?i)pre-v4 metrics detected'
        }

        It 'enforce mode exits 3 when at least one port is NotCovered' {
            $bodyJson = (@{ body = $script:V4WithNotCoveredBody } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'enforce' `
                -PrBodyJson $bodyJson `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1' }

            $ip.Result.ExitCode | Should -Be 3
        }

        It 'enforce mode exits 0 when no ports are NotCovered (only Covered or Inconclusive)' {
            $bodyJson = (@{ body = $script:V4AllCoveredBody } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'enforce' `
                -PrBodyJson $bodyJson `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1' }

            $ip.Result.ExitCode | Should -Be 0
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

        It 'passes current coverage to regime checkpoint lookup' {
            $result = & $script:InvokeCostWalkerOrchestratorInProcess -ClaudeMode 'ok' -CopilotMode 'ok'

            $result.Result.ExitCode | Should -Be 0
            $result.CheckpointCoverage | Should -Be 'claude+copilot'
        }

        It 'renders the transition notice from production rolling metadata when matching coverage history is below five entries' {
            $rollingEntries = @()
            for ($i = 0; $i -lt 4; $i++) {
                $rollingEntries += @{ coverage = 'claude+copilot'; install_status = 'ok' }
            }
            $rollingEntries += @{ coverage = 'claude-only'; install_status = 'ok' }

            $result = & $script:InvokeCostWalkerOrchestratorInProcess -ClaudeMode 'ok' -CopilotMode 'ok' -RollingEntries $rollingEntries

            $result.Result.ExitCode | Should -Be 0
            $result.Result.Comment | Should -Match '⚠ building cross-tool baseline — matching-coverage history < 5 entries'
        }

        It 'classifies missing Copilot OTel file with Claude events as fallback-warning coverage without adding Copilot support' {
            $result = & $script:InvokeCostWalkerOrchestratorInProcess -ClaudeMode 'ok' -CopilotMode 'empty'

            $result.Result.ExitCode | Should -Be 0
            $result.Result.Comment | Should -Match '(?m)^coverage: claude-only-with-copilot-fallback-warning$'
            $result.Result.Comment | Should -Match '(?m)^install_status: missing-or-fallback$'
            $result.Result.Comment | Should -Not -Match 'provider_support: \["claude", "copilot"\]'
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
            # PR body has empty comments array — spine found only via issue comments fallback.
            $bodyJson = (@{ body = $prBody; comments = @() } | ConvertTo-Json -Compress -Depth 8)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson `
                -IssueCommentsJson $issueCommentsJson

            $ip.Result.ExitCode | Should -Be 0
            $incompleteRows = @($ip.Result.Comment -split "`r?`n" | Where-Object {
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
            # PR body includes spine comment — spine found via PR comments path.
            $bodyJson = (@{ body = $prBody; comments = @($spineComment) } | ConvertTo-Json -Compress -Depth 8)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson `
                -IssueCommentsJson $issueCommentsJson

            $ip.Result.ExitCode | Should -Be 0
            $incompleteRows = @($ip.Result.Comment -split "`r?`n" | Where-Object {
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

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson `
                -IssueCommentsJson $issueCommentsJson

            $ip.Result.ExitCode | Should -Be 0
            $incompleteRows = @($ip.Result.Comment -split "`r?`n" | Where-Object { $_ -match 'incomplete-cycle' })

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

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson `
                -IssueCommentsJson $issueCommentsJson

            $ip.Result.ExitCode | Should -Be 0
            # Split before Cost Pattern so we only check the coverage table rows.
            $coverageText = ($ip.Result.Comment -split '(?m)^## Cost Pattern', 2)[0]
            $portRows = @($coverageText -split "`r?`n" | Where-Object { $_ -match '^\|\s*implement-test\s*\|' })

            $portRows | Should -HaveCount 1
            $portRows[0] | Should -Match 'failed'
            $portRows[0] | Should -Match 'terminal cycle failed'
            $portRows[0] | Should -Not -Match 'earlier cycle passed'
            $ip.Result.Comment | Should -Not -Match 'incomplete-cycle'
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

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'warn' `
                -PrBodyJson $bodyJson `
                -IssueCommentsJson $issueCommentsJson

            $ip.Result.ExitCode | Should -Be 0
            $incompleteRows = @($ip.Result.Comment -split "`r?`n" | Where-Object { $_ -match 'incomplete-cycle' })

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

            $ip = & $script:InvokeOrchestratorInProcess -Pr 429 -Mode 'warn' -PrBodyJson $bodyJson

            $ip.Result.ExitCode | Should -Be 0
            $ip.UpdatedPrBody | Should -Not -BeNullOrEmpty -Because 'the orchestrator must re-emit the PR body metrics block when applying additive fallback metrics'
            $ip.UpdatedPrBody | Should -Not -Match '(?m)^\s*spine-stale-fallback-count\s*:' `
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

            $ip = & $script:InvokeOrchestratorInProcess -Pr 429 -Mode 'warn' -PrBodyJson $bodyJson

            $ip.Result.ExitCode | Should -Be 0
            $ip.UpdatedPrBody | Should -Not -BeNullOrEmpty -Because 'stale-spine fallback events must be persisted back into PR-body pipeline metrics'
            $ip.UpdatedPrBody | Should -Match '(?m)^spine-stale-fallback-count:\s*2\s*$'
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

            $ip = & $script:InvokeOrchestratorInProcess -Pr 429 -Mode 'warn' -PrBodyJson $bodyJson

            $ip.Result.ExitCode | Should -Be 0
            $ip.UpdatedPrBody | Should -Not -BeNullOrEmpty -Because 'additive PR-body metrics updates must preserve previously observed stale-spine fallback counts'
            $ip.UpdatedPrBody | Should -Match '(?m)^spine-stale-fallback-count:\s*5\s*$'
            $ip.UpdatedPrBody | Should -Not -Match '(?m)^spine-stale-fallback-count:\s*[0-4]\s*$'
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

    Context 'Issue #439 enforce mode — block-on-inconclusive, kill switch, exit codes' {

        # AC3: inconclusive review port (block-on-inconclusive: true) blocks in enforce mode.
        It 'AC3: inconclusive review credit blocks in enforce mode (block-on-inconclusive: true → exit 3)' {
            # Start from the fully-covered fixture and swap review from passed → inconclusive.
            # All other ports remain covered so the only blocking candidate is review.
            $prBody = $script:V4AllCoveredBody -replace '(?m)(port: review\s*\n\s*status:)\s*passed', '$1 inconclusive'
            $bodyJson = (@{ body = $prBody } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'enforce' `
                -PrBodyJson $bodyJson `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1' }

            # review has block-on-inconclusive: true → inconclusive review is blocking → exit 3
            $ip.Result.ExitCode | Should -Be 3
        }

        # AC4: inconclusive ce-gate-cli port (block-on-inconclusive: false) is non-blocking in enforce mode.
        It 'AC4: inconclusive ce-gate-cli credit does not block in enforce mode (block-on-inconclusive: false → exit 0)' {
            # Start from the fully-covered fixture and swap ce-gate-cli from not-applicable → inconclusive.
            # All other ports remain covered so the only questionable port is ce-gate-cli.
            $prBody = $script:V4AllCoveredBody -replace '(?m)(port: ce-gate-cli\s*\n\s*status:)\s*not-applicable', '$1 inconclusive'
            $bodyJson = (@{ body = $prBody } | ConvertTo-Json -Compress)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'enforce' `
                -PrBodyJson $bodyJson `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1' }

            # ce-gate-cli has block-on-inconclusive: false → inconclusive ce-gate-cli is non-blocking → exit 0
            $ip.Result.ExitCode | Should -Be 0
        }

        # AC7: FRAME_ENFORCE=0 kill switch coerces enforce → warn → exit 0 even when credits are missing.
        # NOTE: The kill switch check is in the top-level execution block (before Invoke-FrameCreditLedger
        # is called), so this test must use the spawn helper to exercise the real code path.
        It 'AC7: FRAME_ENFORCE=0 kill switch coerces enforce to warn and exits 0 even when credits are missing' {
            # V4WithNotCoveredBody has review: failed → would exit 3 in real enforce mode.
            $bodyJson = (@{ body = $script:V4WithNotCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'enforce' `
                -Env @{
                FRAME_CREDIT_LEDGER_TEST_NO_SLEEP              = '1'
                FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1'
                FRAME_ENFORCE                                  = '0'
            } `
                -MockBootstrap $bootstrap

            # Kill switch coerces to warn → fail-open → exit 0
            $result.ExitCode | Should -Be 0
        }

        # AC8: timeout in enforce mode → exit 4.
        It 'AC8: timeout in enforce mode exits 4 (not 0 as in warn mode)' {
            $bootstrap = & $script:NewGhMockBootstrap -HangOnBaseRef $true

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'enforce' `
                -Env @{
                FRAME_CREDIT_LEDGER_TEST_NO_SLEEP              = '1'
                FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS        = '3'
                FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1'
            } `
                -TimeoutSeconds 30 `
                -MockBootstrap $bootstrap

            # Enforce mode on timeout must exit 4 (not 0)
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 4
        }

        # AC9: internal exception in enforce mode → exit 5.
        It 'AC9: internal exception in enforce mode exits 5 (not 0 as in warn mode)' {
            # Same technique as the warn-mode exception test: patch the body-fetch branch to throw.
            $extra = @'
$global:ThrowOnBody = $true
'@
            $bootstrapBase = & $script:NewGhMockBootstrap -ExtraDeclarations $extra
            $bootstrap = $bootstrapBase -replace [regex]::Escape("if (`$joined -match 'pr view \d+ --json body') {"), @"
if (`$joined -match 'pr view \d+ --json body') {
        throw 'simulated body-fetch failure'
"@

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'enforce' `
                -Env @{
                FRAME_CREDIT_LEDGER_TEST_NO_SLEEP              = '1'
                FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1'
            } `
                -MockBootstrap $bootstrap

            # Enforce mode on internal error must exit 5 (not 0)
            $result.ExitCode | Should -Be 5
        }

        # s3 AC: frame-override marker removes a blocking port → exit 0 in enforce mode.
        It 'frame-override-429 marker from OWNER overrides a blocking NotCovered port in enforce mode → exit 0' {
            # Start from the fully-covered fixture and swap review from passed → failed (NotCovered → would block).
            # Every other port remains covered so overriding review leaves no remaining blocking ports.
            $prBodyWithFailedReview = $script:V4AllCoveredBody -replace '(?m)(port: review\s*\n\s*status:)\s*passed', '$1 failed'
            $prComments = @(
                [pscustomobject]@{
                    body              = "<!-- frame-override-429`nports: review`nreason: emergency deploy`n-->"
                    authorAssociation = "OWNER"
                }
            )
            $bodyJson = (@{
                    body     = $prBodyWithFailedReview
                    comments = $prComments
                } | ConvertTo-Json -Compress -Depth 10)

            $ip = & $script:InvokeOrchestratorInProcess `
                -Pr 429 -Mode 'enforce' `
                -PrBodyJson $bodyJson `
                -EnvVars @{ FRAME_CREDIT_LEDGER_TEST_SKIP_ACTIVATION_CUTOVER = '1' }

            # Override applied → no blocking ports remain → exit 0
            $ip.Result.ExitCode | Should -Be 0
        }

        # AC10(a): Far-future sentinel in enforce-activation.yaml → coerces to warn → exit 0.
        It 'AC10a: far-future activation_timestamp sentinel coerces enforce to warn → exit 0 (advisory ship)' {
            # Do NOT set SKIP_ACTIVATION_CUTOVER — this exercises the real cutover path.
            # The repo's enforce-activation.yaml has activation_timestamp: 9999-12-31 which
            # should trip the far-future guard and downgrade to warn mode.
            $bodyJson = (@{ body = $script:V4WithNotCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'enforce' `
                -Env @{
                FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'
            } `
                -MockBootstrap $bootstrap

            # Far-future sentinel → coerced to warn → fail-open → exit 0 even with NotCovered port
            $result.ExitCode | Should -Be 0
            # Stderr should mention the advisory/far-future downgrade
            $result.Stderr | Should -Match '(?i)(far.future|advisory|sentinel|warn)'
        }

        # AC10(b): PR created before activation timestamp → coerces to warn → exit 0.
        It 'AC10b: PR_CREATED_AT before activation_timestamp coerces enforce to warn → exit 0' {
            # The repo has activation_timestamp: 9999-12-31T00:00:00Z.
            # Any PR_CREATED_AT in 2026 is before that timestamp → coerce to warn.
            $bodyJson = (@{ body = $script:V4WithNotCoveredBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'enforce' `
                -Env @{
                FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'
                PR_CREATED_AT                     = '2026-01-01T00:00:00Z'
            } `
                -MockBootstrap $bootstrap

            # PR_CREATED_AT (2026) < activation_timestamp (9999-12-31) → caught by PR_CREATED_AT guard
            # → coerced to warn → exit 0
            $result.ExitCode | Should -Be 0
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
