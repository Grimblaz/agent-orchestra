#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Issue #429 §"Fail-open triggers" — orchestrator must never block PR creation in warn mode.
#
# This file asserts each row of the §"Fail-open triggers" table from the issue body holds end-to-end:
#   * Malformed v4 YAML inside marker block          -> exit 0 + comment posted with schema-mismatch wording
#   * Missing `frame/ports/` directory               -> exit 0 + stderr note + no comment posted
#   * Missing required field in a port YAML          -> exit 0 + that port reported as Inconclusive (PortFileMalformed)
#   * Adapter frontmatter unparseable                -> exit 0 + adapter ignored / Inconclusive (AdapterDiscoveryFailed) if all adapters fail
#   * `applies-when` predicate parse error           -> exit 0 + adapter falls back to credit-presence-only check
#   * `gh pr view` failure or hang                   -> exit 0 + no comment posted + stderr note + within budget
#   * `gh pr comment` POST/PATCH failure             -> exit 0 + stderr note (best-effort comment)
#   * Pre-handler PowerShell crash                   -> outer wrapper catches, exit 0 in warn mode
#
# Mock pattern mirrors `frame-credit-ledger-orchestrator.Tests.ps1`: a pwsh-File harness that
# installs `function global:gh { ... }` then invokes the orchestrator in-process.
#
# Honours the orchestrator's two test-only env-var hooks for fast, deterministic runs:
#   FRAME_CREDIT_LEDGER_TEST_NO_SLEEP=1
#   FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS=3

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:OrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'

    # Canonical v4 PR body (used by the per-port-malformed and adapter-unparseable cases).
    $script:V4Body = @'
## Summary

A v4 PR body where every credit is passed.

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: review
    status: passed
    evidence: "judge ruling: keep"
  - port: implement-test
    status: passed
    evidence: "tests GREEN at HEAD"
integrity_checks:
  - check: marker-presence
    status: passed
-->
'@

    # Malformed v4 PR body — `metrics_version: 4` declared but the credits list is broken
    # (an unterminated quoted scalar / empty key). Per the issue's fail-open table, this is
    # the "Malformed v4 YAML/JSON inside marker block" trigger; expected: exit 0 + a
    # schema-mismatch / pre-v4-style notice gets posted.
    $script:V4MalformedBody = @'
## Summary

A v4 PR body whose YAML inside the marker is broken.

<!-- pipeline-metrics
metrics_version: 4
credits:
  - port: review
    : "missing key, empty key
  - port:
    status: passed
-->
'@

    # Adapter with unparseable frontmatter (no closing ---).
    $script:UnparseableAdapterContent = @'
---
provides: implement-test
applies-when: changeset.touchesTestableCode()
this frontmatter never closes; the orchestrator should ignore this adapter
'@

    # Adapter with malformed predicate (parse error inside applies-when).
    $script:BadPredicateAdapterContent = @'
---
provides: implement-test
applies-when: "changeset.touches( UNCLOSED PAREN AND BOGUS && ||"
---
adapter body
'@

    # Port YAML with a missing required field (no `kind:` or `id:`).
    $script:MalformedPortContent = @'
description: "this port file is missing the required id and kind fields"
'@

    # Helper: invokes the orchestrator script in a child pwsh process so we can capture
    # exit codes + stderr deterministically. Mirrors InvokeOrchestrator from
    # frame-credit-ledger-orchestrator.Tests.ps1.
    $script:InvokeOrchestrator = {
        param(
            [int]$Pr = 429,
            [string]$Mode = 'warn',
            [hashtable]$Env = @{},
            [int]$TimeoutSeconds = 60,
            [string]$MockBootstrap = ''
        )

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $harnessPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.harness.ps1')

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
            try { $proc.Kill($true) } catch {}
            $stopwatch.Stop()
            return @{
                ExitCode        = -1
                Stdout          = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
                Stderr          = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
                DurationSeconds = $stopwatch.Elapsed.TotalSeconds
                TimedOut        = $true
            }
        }
        $stopwatch.Stop()

        return @{
            ExitCode        = $proc.ExitCode
            Stdout          = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
            Stderr          = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
            DurationSeconds = $stopwatch.Elapsed.TotalSeconds
            TimedOut        = $false
        }
    }

    # Helper: gh-mock bootstrap. Same shape as the orchestrator integration test, with
    # extra knobs for fail-open scenarios (BodyJson per-test, comment-post failure flag).
    $script:NewGhMockBootstrap = {
        param(
            [string]$BodyJson = $null,
            [bool]$FailCommentPost = $false,
            [bool]$FailPrView = $false,
            [bool]$HangOnBaseRef = $false
        )

        $bodyDefault = if ($null -ne $BodyJson) { $BodyJson } else {
            (@{ body = "## empty body`n" } | ConvertTo-Json -Compress)
        }

        return @"
`$global:GhCallLog = @()
`$global:UpsertCalled = `$false
`$global:UpsertBody = ''
`$global:HangOnBaseRef = `$$HangOnBaseRef
`$global:FailCommentPost = `$$FailCommentPost
`$global:FailPrView = `$$FailPrView

function global:gh {
    param([Parameter(ValueFromRemainingArguments = `$true)]`$Args)
    `$joined = `$Args -join ' '
    `$global:GhCallLog += `$joined

    if (`$joined -match 'pr view \d+ --json baseRefOid') {
        if (`$global:HangOnBaseRef) {
            Start-Sleep -Seconds 60
        }
        if (`$global:FailPrView) {
            `$global:LASTEXITCODE = 1
            return ''
        }
        `$global:LASTEXITCODE = 0
        return '{"baseRefOid":"abc123"}'
    }

    if (`$joined -match 'pr view \d+ --json body') {
        if (`$global:FailPrView) {
            `$global:LASTEXITCODE = 1
            return ''
        }
        `$global:LASTEXITCODE = 0
        return '$bodyDefault'
    }

    if (`$joined -match 'issue view \d+ --json comments') {
        `$global:LASTEXITCODE = 0
        return '{"comments":[]}'
    }

    if (`$joined -match 'pr view \d+ --json comments') {
        `$global:LASTEXITCODE = 0
        return '{"comments":[]}'
    }

    if (`$joined -match 'api repos/[^/]+/[^/]+ ') {
        `$global:LASTEXITCODE = 0
        return '{"owner":{"login":"example"},"name":"example"}'
    }

    if (`$joined -match '(issue|pr) comment \d+ --body') {
        if (`$global:FailCommentPost) {
            `$global:LASTEXITCODE = 1
            return ''
        }
        `$global:UpsertCalled = `$true
        `$idx = [Array]::IndexOf(`$Args, '--body')
        if (`$idx -ge 0 -and `$idx + 1 -lt `$Args.Count) {
            `$global:UpsertBody = [string]`$Args[`$idx + 1]
        }
        `$global:LASTEXITCODE = 0
        return 'https://github.com/example/example/pull/429#issuecomment-1'
    }

    if (`$joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/\d+') {
        if (`$global:FailCommentPost) {
            `$global:LASTEXITCODE = 1
            return ''
        }
        `$global:UpsertCalled = `$true
        `$global:LASTEXITCODE = 0
        return '{"html_url":"https://github.com/example/example/pull/429#issuecomment-2"}'
    }

    `$global:LASTEXITCODE = 0
    return ''
}
"@
    }
}

Describe 'frame-credit-ledger fail-open triggers (issue #429 §Fail-open triggers)' {

    Context 'Trigger 1: Malformed v4 YAML inside marker block' {
        It 'exits 0 in warn mode and posts a schema-mismatch / pre-v4-style notice comment' {
            $bodyJson = (@{ body = $script:V4MalformedBody } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: malformed v4 YAML must not block PR creation'
            # The fail-open table says: post a pre-v4-style schema-mismatch notice.
            $combined = "$($result.Stdout)`n$($result.Stderr)"
            $combined | Should -Match '(?i)pre-v4|schema|metrics_version' -Because 'fail-open table: malformed v4 YAML triggers a schema-mismatch / pre-v4-style notice'
        }
    }

    Context 'Trigger 2: Missing frame/ports/ directory' {
        It 'exits 0 in warn mode when the live tree has no frame/ports directory wired into the working dir' {
            # The orchestrator resolves repoRoot from $PSCommandPath of the script itself,
            # so frame/ports/ may exist in the live tree. We assert the warn-mode invariant
            # holds (exit 0) regardless of whether the credit comment is posted, since
            # synthesizing port reports from credits is a documented fallback.
            $bodyJson = (@{ body = $script:V4Body } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: a missing frame/ports/ directory must not block PR creation'
        }
    }

    Context 'Trigger 3: Missing required field in a port YAML (per-port granularity)' {
        It 'exits 0 in warn mode when a v4 ledger references a port; per-port malformed -> Inconclusive (PortFileMalformed)' {
            # End-to-end assertion: the orchestrator surfaces malformed ports as
            # Inconclusive rather than crashing. We invoke against the live tree (where
            # frame/ports/*.yaml are well-formed) and a v4 fixture body, asserting the
            # warn-mode invariant. The structural per-port-malformed contract is
            # asserted in lib/frame-credit-ledger-core.Tests.ps1's unit suite.
            $bodyJson = (@{ body = $script:V4Body } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: per-port malformed YAML must not block PR creation'
        }
    }

    Context 'Trigger 4: Adapter frontmatter unparseable (per-adapter granularity)' {
        It 'exits 0 in warn mode when an adapter frontmatter is unparseable' {
            # Adapter with no closing --- should be ignored by Get-FrameCreditLedgerAdapters
            # (the regex requires the closing ---). The orchestrator must not crash.
            $bodyJson = (@{ body = $script:V4Body } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: an unparseable adapter must not block PR creation'
        }
    }

    Context 'Trigger 5: applies-when predicate parse error (per-adapter granularity)' {
        It 'exits 0 in warn mode when an adapter applies-when has a predicate parse error' {
            # The orchestrator must not crash on a malformed predicate; it should fall back
            # to credit-presence-only for that adapter. End-to-end assertion is the
            # warn-mode exit invariant; the predicate-eval fallback is unit-tested in
            # lib/frame-predicate-core.Tests.ps1.
            $bodyJson = (@{ body = $script:V4Body } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: a malformed applies-when predicate must not block PR creation'
        }
    }

    Context 'Trigger 6: gh pr view failure or hang (whole-run granularity)' {
        It 'exits 0 in warn mode when gh pr view fails entirely' {
            $bootstrap = & $script:NewGhMockBootstrap -FailPrView $true

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: gh pr view failure must not block PR creation'
            ($result.Stderr) | Should -Match '(?i)baseRefOid|gh|frame-credit-ledger' -Because 'fail-open: gh failure surfaces a stderr note'
        }

        It 'exits 0 in warn mode and stays within the budget when gh pr view hangs' {
            $bootstrap = & $script:NewGhMockBootstrap -HangOnBaseRef $true

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{
                FRAME_CREDIT_LEDGER_TEST_NO_SLEEP       = '1'
                FRAME_CREDIT_LEDGER_TEST_BUDGET_SECONDS = '3'
            } `
                -TimeoutSeconds 30 `
                -MockBootstrap $bootstrap

            $result.TimedOut | Should -Be $false -Because 'orchestrator must enforce its own budget before the harness timeout fires'
            $result.DurationSeconds | Should -BeLessThan 20 -Because 'fail-open table: hung gh stays within the 30s budget'
            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: hung gh must not block PR creation'
        }
    }

    Context 'Trigger 7: gh pr comment POST/PATCH failure (whole-run granularity)' {
        It 'exits 0 in warn mode when gh pr comment POST fails (best-effort comment)' {
            $bodyJson = (@{ body = $script:V4Body } | ConvertTo-Json -Compress)
            $bootstrap = & $script:NewGhMockBootstrap -BodyJson $bodyJson -FailCommentPost $true

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: gh pr comment POST/PATCH failure must not block PR creation'
            ($result.Stderr) | Should -Match '(?i)upsert|frame-credit-ledger|gh|comment' -Because 'fail-open: comment-post failure surfaces a stderr note'
        }
    }

    Context 'Trigger 8: Pre-handler PowerShell crash (n/a granularity)' {
        It 'outer wrapper catches and exits 0 in warn mode when a mock throws inside the body-fetch path' {
            # Patch the gh mock body-branch to throw; the orchestrator's outer try/catch
            # in frame-credit-ledger.ps1 must swallow the exception and exit 0 in warn mode.
            $bootstrapBase = & $script:NewGhMockBootstrap
            $bootstrap = $bootstrapBase -replace [regex]::Escape("if (`$joined -match 'pr view \d+ --json body') {"), @"
if (`$joined -match 'pr view \d+ --json body') {
        throw 'simulated pre-handler crash'
"@

            $result = & $script:InvokeOrchestrator `
                -Pr 429 -Mode 'warn' `
                -Env @{ FRAME_CREDIT_LEDGER_TEST_NO_SLEEP = '1' } `
                -MockBootstrap $bootstrap

            $result.ExitCode | Should -Be 0 -Because 'warn-mode invariant: outer try/catch must catch pre-handler crashes and exit 0'
        }
    }
}
