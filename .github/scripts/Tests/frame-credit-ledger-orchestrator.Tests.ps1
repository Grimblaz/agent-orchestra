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
  - port: review
    status: passed
    evidence: "judge ruling: keep"
  - port: implement-test
    status: passed
    evidence: "tests GREEN at HEAD"
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

    # Helper: build a `function global:gh { ... }` bootstrap snippet that
    # the harness will dot into the same scope as the orchestrator
    # invocation. Mirrors the pattern in find-or-upsert-comment.Tests.ps1.
    $script:NewGhMockBootstrap = {
        param(
            [string]$BaseRefOidJson = '{"baseRefOid":"abc123"}',
            [string]$BodyJson = $null,
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
$ExtraDeclarations

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

    if (`$joined -match 'issue view \d+ --json comments') {
        `$global:LASTEXITCODE = 0
        return '{"comments":[]}'
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
            $combined = "$($result.Stdout)`n$($result.Stderr)"
            $combined | Should -Match '(?i)pre-v4 metrics detected'
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
}
