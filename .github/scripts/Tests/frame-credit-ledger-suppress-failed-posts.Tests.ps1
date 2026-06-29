#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Issue #769 — CR7 regression: the FCL_SUPPRESS_FAILED_POSTS off-switch must be
# honored INSIDE the worker runspace.
#
# Background (the bug this guards):
#   $_suppressFailedPosts was assigned only at top-level script scope (from
#   $env:FCL_SUPPRESS_FAILED_POSTS). But Invoke-FrameCreditLedger runs inside a
#   cloned worker runspace (New-FCLInitialSessionStateClone), which carries only
#   functions + GLOBAL-scope variables + 5 named cost vars. A *script*-scoped
#   $_suppressFailedPosts is therefore NOT carried into the worker, so the
#   consumer (`if ($_isOrchestrated -and $_suppressFailedPosts)`) read $null and
#   the off-switch was dead — a FAILED comment got posted even with the env var
#   set. The fix recomputes the flag from the (process-global) environment inside
#   Invoke-FrameCreditLedger, so it survives the runspace boundary.
#
# These tests drive the FULL orchestrator in a child pwsh process (so the real
# worker-runspace dispatch path executes, exactly where the bug lived). They use
# the same gh-mock + harness pattern as frame-credit-ledger-fail-open.Tests.ps1.
#
# IMPORTANT — why upsert state is tracked via a FILE, not a $global: var:
#   The comment upsert happens INSIDE the cloned worker runspace. A $global:
#   variable set in the harness is COPIED into the worker's initial session state,
#   so the worker mutates its OWN copy and the mutation never propagates back to
#   the harness. A file write, by contrast, crosses the runspace boundary. The
#   gh mock therefore appends to a probe file (path passed via env var) whenever
#   it posts/patches a comment; the parent test reads that file to decide whether
#   a FAILED comment was posted. (This is the same isolation property the CR7 fix
#   itself relies on for env vars.)
#
# Scenario shape (the missing-pipeline-metrics short-circuit, line ~1267):
#   * orchestrated origin       -> via $env:GITHUB_HEAD_REF = feature/issue-769-*
#   * PR body with NO metrics    -> $metrics is $null -> FAILED short-circuit path
#   * FCL_SUPPRESS_FAILED_POSTS  -> toggles whether the FAILED comment is posted

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:OrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'

    # A PR body with NO <!-- pipeline-metrics ... --> block. This drives
    # Read-PRMetricsBlock to return $null, which enters the missing-metrics
    # short-circuit where the suppression off-switch is consulted.
    #
    # IMPORTANT: this body must NOT contain orchestration body-signals
    # (issue_id: N / <!-- plan-issue-N -->) so that orchestrated-origin is
    # determined SOLELY by $env:GITHUB_HEAD_REF in these tests.
    $script:NoMetricsBody = @'
## Summary

A PR body with no pipeline-metrics marker block at all.
'@

    # Harness: invoke the orchestrator in a child pwsh process. The gh mock records
    # comment posts to a FILE (path injected via $env:CR7_UPSERT_PROBE_FILE) so the
    # record survives the worker-runspace boundary. The parent reads that file.
    $script:InvokeOrchestratorWithUpsertProbe = {
        param(
            [int]$Pr = 769,
            [string]$Mode = 'warn',
            [hashtable]$Env = @{},
            [int]$TimeoutSeconds = 60,
            [string]$MockBootstrap = ''
        )

        $harnessPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.harness.ps1')
        $probeFile = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.upsert-probe.txt')

        # The probe-file path is always injected; merge it with caller env.
        $effectiveEnv = @{ CR7_UPSERT_PROBE_FILE = $probeFile }
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

        if (-not $waited) {
            try { $proc.Kill($true) } catch {}
            return @{
                ExitCode     = -1
                Stdout       = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
                Stderr       = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
                TimedOut     = $true
                UpsertCalled = $false
                UpsertFailed = $false
            }
        }

        return @{
            ExitCode     = $proc.ExitCode
            Stdout       = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
            Stderr       = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
            TimedOut     = $false
            UpsertCalled = (-not [string]::IsNullOrEmpty($probeContent))
            UpsertFailed = ($probeContent -match 'FAILED')
        }
    }

    # gh-mock bootstrap returning a fixed body (no metrics block). Records each
    # comment POST/PATCH by APPENDING the posted body to the probe file named by
    # $env:CR7_UPSERT_PROBE_FILE — a file write crosses the worker-runspace
    # boundary where a $global: variable mutation would not.
    $script:NewGhMockBootstrap = {
        param([string]$BodyJson)

        return @"
function global:gh {
    param([Parameter(ValueFromRemainingArguments = `$true)]`$Args)
    `$joined = `$Args -join ' '

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

    if (`$joined -match 'api repos/') {
        `$global:LASTEXITCODE = 0
        return '{"full_name":"example/example"}'
    }

    if (`$joined -match '(issue|pr) comment \d+ --body') {
        `$idx = [Array]::IndexOf(`$Args, '--body')
        `$body = ''
        if (`$idx -ge 0 -and `$idx + 1 -lt `$Args.Count) { `$body = [string]`$Args[`$idx + 1] }
        if (`$env:CR7_UPSERT_PROBE_FILE) {
            Add-Content -LiteralPath `$env:CR7_UPSERT_PROBE_FILE -Value `$body -Encoding UTF8
        }
        `$global:LASTEXITCODE = 0
        return 'https://github.com/example/example/pull/769#issuecomment-1'
    }

    if (`$joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
        if (`$env:CR7_UPSERT_PROBE_FILE) {
            Add-Content -LiteralPath `$env:CR7_UPSERT_PROBE_FILE -Value 'PATCHED' -Encoding UTF8
        }
        `$global:LASTEXITCODE = 0
        return '{"html_url":"https://github.com/example/example/pull/769#issuecomment-2"}'
    }

    `$global:LASTEXITCODE = 0
    return ''
}
"@
    }
}

Describe 'frame-credit-ledger FCL_SUPPRESS_FAILED_POSTS off-switch (issue #769 CR7)' {

    Context 'orchestrated-origin PR with a missing pipeline-metrics block' {

        It 'does NOT post a FAILED comment when FCL_SUPPRESS_FAILED_POSTS=1 (suppression honored inside the worker runspace)' {
            $bodyJson = (@{ body = $script:NoMetricsBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestratorWithUpsertProbe `
                -Pr 769 -Mode 'warn' `
                -Env @{
                    FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'
                    GITHUB_HEAD_REF                   = 'feature/issue-769-v4-emission-reliability'
                    FCL_SUPPRESS_FAILED_POSTS         = '1'
                } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: a missing metrics block must not block PR creation'
            $result.UpsertCalled | Should -BeFalse -Because 'CR7: with FCL_SUPPRESS_FAILED_POSTS=1, the FAILED post is suppressed even inside the worker runspace (the flag must be recomputed from the env inside Invoke-FrameCreditLedger)'
        }

        It 'DOES post a FAILED comment when FCL_SUPPRESS_FAILED_POSTS is unset (control: proves the test exercises the FAILED path)' {
            $bodyJson = (@{ body = $script:NoMetricsBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestratorWithUpsertProbe `
                -Pr 769 -Mode 'warn' `
                -Env @{
                    FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1'
                    GITHUB_HEAD_REF                   = 'feature/issue-769-v4-emission-reliability'
                } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: a missing metrics block must not block PR creation'
            $result.UpsertCalled | Should -BeTrue -Because 'control: an orchestrated-origin PR with no metrics block posts a FAILED comment when the off-switch is not set'
            $result.UpsertFailed | Should -BeTrue -Because 'control: the posted comment is the orchestrated FAILED short-circuit notice'
        }
    }
}
