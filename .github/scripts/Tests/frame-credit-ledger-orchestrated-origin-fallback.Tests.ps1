#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Issue #794, slice s3 — orchestrated-origin detection fix (sub-observation 2).
#
# Background (the bug this guards):
#   The Invoke-FrameCreditLedger call site read $env:GITHUB_HEAD_REF directly
#   and passed it straight to Get-FCLOriginContext -HeadRef. That env var is
#   only populated by GitHub Actions on `pull_request` events — it is empty on
#   local/manual runs. On issue #790, a local/manual run of an orchestrated PR
#   (branch `feature/issue-785-...`) was misclassified as non-orchestrated
#   because $env:GITHUB_HEAD_REF was empty and no PR-body orchestration signal
#   happened to be present either.
#
#   The fix (frame-credit-ledger.ps1, Invoke-FrameCreditLedger, ~line 1300):
#   when $_prHeadRef is empty or the literal string 'HEAD', resolve the head
#   ref via `gh pr view {Pr} --json headRefName --jq '.headRefName'` before
#   calling Get-FCLOriginContext. If that `gh pr view` call fails (non-zero
#   exit or throws), fail quiet: leave $_prHeadRef as-is and fall through to
#   Get-FCLOriginContext's existing PR-body-signal fallback, exactly as today.
#   Get-FCLOriginContext.ps1 itself (the predicate) is NOT modified — it stays
#   a pure, no-gh function; this fallback resolution lives only at the ledger
#   call site.
#
# These tests drive the FULL orchestrator in a child pwsh process (mirrors
# frame-credit-ledger-suppress-failed-posts.Tests.ps1's harness + gh-mock +
# upsert-probe-file pattern) so the real Invoke-FrameCreditLedger call site
# executes, exactly where the bug lived.
#
# Test oracle: the missing-pipeline-metrics short-circuit comment
# (Compose-MissingMetricsShortCircuitComment) renders differently depending on
# $_isOrchestrated:
#   IsOrchestrated=$true  -> "FAILED — Frame credit ledger — no pipeline-metrics..."
#   IsOrchestrated=$false -> "not measured (non-orchestrated)"
# So driving a PR body with NO metrics block and NO body orchestration signals
# isolates the classification to whatever $_prHeadRef ends up resolving to.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:OrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'
    $script:OriginContextPath = Join-Path $script:RepoRoot '.github/scripts/lib/Get-FCLOriginContext.ps1'

    # A PR body with NO <!-- pipeline-metrics ... --> block and NO orchestration
    # body-signals (issue_id: N / <!-- plan-issue-N -->), so orchestrated-origin
    # classification is driven solely by the resolved head ref.
    $script:NoMetricsNoSignalBody = @'
## Summary

A PR body with no pipeline-metrics marker block and no body orchestration signals.
'@

    # Harness: invoke the orchestrator in a child pwsh process. The gh mock records
    # comment posts to a FILE (path injected via $env:FCL_S3_UPSERT_PROBE_FILE) so the
    # record survives the worker-runspace boundary, and also records every gh
    # invocation to a second probe file so the test can assert whether/how `gh pr
    # view --json headRefName` was called.
    $script:InvokeOrchestratorWithProbes = {
        param(
            [int]$Pr = 794,
            [string]$Mode = 'warn',
            [hashtable]$Env = @{},
            [int]$TimeoutSeconds = 60,
            [string]$MockBootstrap = ''
        )

        $harnessPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.harness.ps1')
        $probeFile = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.upsert-probe.txt')
        $callLogFile = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.gh-call-log.txt')

        $effectiveEnv = @{
            FCL_S3_UPSERT_PROBE_FILE = $probeFile
            FCL_S3_CALL_LOG_FILE     = $callLogFile
        }
        foreach ($k in $Env.Keys) { $effectiveEnv[$k] = $Env[$k] }

        $envLines = foreach ($key in $effectiveEnv.Keys) {
            "`$env:$key = '$($effectiveEnv[$key] -replace "'", "''")'"
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
        $probeContent = (Test-Path $probeFile) ? (Get-Content $probeFile -Raw) : ''
        $callLogContent = (Test-Path $callLogFile) ? (Get-Content $callLogFile -Raw) : ''

        if (-not $waited) {
            try { $proc.Kill($true) } catch {}
            return @{
                ExitCode     = -1
                Stdout       = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
                Stderr       = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
                TimedOut     = $true
                UpsertCalled = $false
                UpsertFailed = $false
                CallLog      = $callLogContent
            }
        }

        return @{
            ExitCode     = $proc.ExitCode
            Stdout       = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
            Stderr       = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
            TimedOut     = $false
            UpsertCalled = (-not [string]::IsNullOrEmpty($probeContent))
            UpsertFailed = ($probeContent -match 'FAILED')
            CallLog      = $callLogContent
        }
    }

    # gh-mock bootstrap. Knobs:
    #   -HeadRefName     value returned by `gh pr view --json headRefName --jq '.headRefName'`
    #   -FailHeadRefLookup  simulate `gh pr view --json headRefName` failing (non-zero exit)
    $script:NewGhMockBootstrap = {
        param(
            [string]$BodyJson,
            [string]$HeadRefName = 'feature/issue-794-orchestrate-credit-harvest',
            [bool]$FailHeadRefLookup = $false
        )

        return @"
function global:gh {
    param([Parameter(ValueFromRemainingArguments = `$true)]`$Args)
    `$joined = `$Args -join ' '

    if (`$env:FCL_S3_CALL_LOG_FILE) {
        Add-Content -LiteralPath `$env:FCL_S3_CALL_LOG_FILE -Value `$joined -Encoding UTF8
    }

    if (`$joined -match 'pr view \d+ --json baseRefOid') {
        `$global:LASTEXITCODE = 0
        return '{"baseRefOid":"abc123"}'
    }

    if (`$joined -match 'pr view \d+ --json body') {
        `$global:LASTEXITCODE = 0
        return '$BodyJson'
    }

    if (`$joined -match '(issue|pr) view \d+ --json comments') {
        `$global:LASTEXITCODE = 0
        return '{"comments":[]}'
    }

    if (`$joined -match 'pr view \d+ --json headRefName') {
        if (`$$FailHeadRefLookup) {
            `$global:LASTEXITCODE = 1
            return ''
        }
        `$global:LASTEXITCODE = 0
        return '$HeadRefName'
    }

    if (`$joined -match 'api repos/') {
        `$global:LASTEXITCODE = 0
        return '{"full_name":"example/example"}'
    }

    if (`$joined -match '(issue|pr) comment \d+ --body') {
        `$idx = [Array]::IndexOf(`$Args, '--body')
        `$body = ''
        if (`$idx -ge 0 -and `$idx + 1 -lt `$Args.Count) { `$body = [string]`$Args[`$idx + 1] }
        if (`$env:FCL_S3_UPSERT_PROBE_FILE) {
            Add-Content -LiteralPath `$env:FCL_S3_UPSERT_PROBE_FILE -Value `$body -Encoding UTF8
        }
        `$global:LASTEXITCODE = 0
        return 'https://github.com/example/example/pull/794#issuecomment-1'
    }

    if (`$joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
        if (`$env:FCL_S3_UPSERT_PROBE_FILE) {
            Add-Content -LiteralPath `$env:FCL_S3_UPSERT_PROBE_FILE -Value 'PATCHED' -Encoding UTF8
        }
        `$global:LASTEXITCODE = 0
        return '{"html_url":"https://github.com/example/example/pull/794#issuecomment-2"}'
    }

    `$global:LASTEXITCODE = 0
    return ''
}
"@
    }
}

Describe 'frame-credit-ledger orchestrated-origin detection fallback (issue #794 s3)' {

    Context 'GITHUB_HEAD_REF empty, gh pr view resolves an orchestrated head ref' {
        It 'classifies the PR as orchestrated-origin using the gh-resolved head ref' {
            $bodyJson = (@{ body = $script:NoMetricsNoSignalBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson -HeadRefName 'feature/issue-794-orchestrate-credit-harvest'

            $result = & $script:InvokeOrchestratorWithProbes `
                -Pr 794 -Mode 'warn' `
                -Env @{
                    FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'
                    GITHUB_HEAD_REF                   = ''
                } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: must not block PR creation'
            $result.CallLog | Should -Match 'pr view 794 --json headRefName' -Because 'empty GITHUB_HEAD_REF must trigger the gh pr view head-ref fallback lookup'
            $result.UpsertCalled | Should -BeTrue -Because 'orchestrated-origin PR with no metrics block posts a FAILED comment'
            $result.UpsertFailed | Should -BeTrue -Because 'the resolved head ref matches feature/issue-N-... so origin is classified as orchestrated'
        }
    }

    Context 'gh pr view head-ref lookup fails' {
        It 'falls back to the existing PR-body-signal detection path without throwing' {
            $bodyJson = (@{ body = $script:NoMetricsNoSignalBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson -FailHeadRefLookup $true

            $result = & $script:InvokeOrchestratorWithProbes `
                -Pr 794 -Mode 'warn' `
                -Env @{
                    FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'
                    GITHUB_HEAD_REF                   = ''
                } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: a failed gh pr view head-ref lookup must not block PR creation or throw'
            $result.CallLog | Should -Match 'pr view 794 --json headRefName' -Because 'the fallback lookup is still attempted'
            $result.UpsertCalled | Should -BeTrue -Because 'no metrics block still posts a comment (non-orchestrated quiet notice, since no body signal is present either)'
            $result.UpsertFailed | Should -BeFalse -Because 'with no resolvable head ref and no body signal, origin falls back to non-orchestrated -> quiet notice, not FAILED'
        }
    }

    Context 'CI env-var path (GITHUB_HEAD_REF populated) is unchanged' {
        It 'does not attempt a gh pr view head-ref lookup when GITHUB_HEAD_REF is already present' {
            $bodyJson = (@{ body = $script:NoMetricsNoSignalBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestratorWithProbes `
                -Pr 794 -Mode 'warn' `
                -Env @{
                    FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'
                    GITHUB_HEAD_REF                   = 'feature/issue-794-orchestrate-credit-harvest'
                } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: must not block PR creation'
            $result.CallLog | Should -Not -Match 'pr view \d+ --json headRefName' -Because 'the CI env-var path takes priority; no gh pr view fallback call should be attempted'
            $result.UpsertCalled | Should -BeTrue -Because 'orchestrated-origin PR with no metrics block posts a FAILED comment'
            $result.UpsertFailed | Should -BeTrue -Because 'GITHUB_HEAD_REF alone is sufficient to classify as orchestrated'
        }
    }

    Context 'Get-FCLOriginContext.ps1 (the predicate) remains untouched by this fix' {
        It 'contains no executable gh invocation and no $env: read inside the function body' {
            $rawContent = Get-Content -LiteralPath $script:OriginContextPath -Raw

            # Strip `<# ... #>` block comments (the SYNOPSIS/DESCRIPTION/EXAMPLE
            # help block, which legitimately mentions $env:GITHUB_HEAD_REF and
            # `gh pr view` as documentation/usage examples) and `#`-prefixed line
            # comments, so only the function's live executable code remains.
            $noBlockComments = [regex]::Replace($rawContent, '(?s)<#.*?#>', '')
            $codeLines = ($noBlockComments -split "`r?`n") | ForEach-Object {
                [regex]::Replace($_, '#.*$', '')
            }
            $executableContent = $codeLines -join "`n"

            $executableContent | Should -Not -Match '&\s*gh\s' -Because 'Get-FCLOriginContext must stay a pure, no-gh predicate; the gh pr view fallback belongs only at the ledger call site'
            $executableContent | Should -Not -Match '\$env:' -Because 'the predicate takes HeadRef as a parameter and must not read any $env: variable itself'
        }
    }
}
