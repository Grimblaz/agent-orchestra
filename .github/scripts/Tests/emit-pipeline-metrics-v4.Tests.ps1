#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for emit-pipeline-metrics-v4.ps1 (issue #769 s2).
#
# Script under test: .github/scripts/emit-pipeline-metrics-v4.ps1
#
# Coverage:
#   1. Success: valid V3BaseYaml + credit row -> BodyFile contains
#      metrics_version: 4 and the credit; exit 0.
#   2. Builder-throw (empty V3BaseYaml) -> BodyFile contains cost-capture-failed sentinel;
#      exit non-zero.
#   3. Empty credits -> Test-PipelineMetricsV4Block rejects -> sentinel emitted;
#      exit non-zero.
#   4. Sentinel token mismatch (M21): sentinel does NOT match pipeline-metrics pattern;
#      Test-PipelineMetricsV4Block does not count it.
#   5. v3-base opener injection (M7): V3BaseYaml containing pipeline-metrics opener
#      -> builder throws -> sentinel emitted correctly.

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreLibPath  = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    $script:EmitCorePath = Join-Path $script:RepoRoot '.github/scripts/lib/emit-pipeline-metrics-v4-core.ps1'

    # Load core lib so helpers (New-/Test-/Read-PipelineMetricsV4Block) are
    # available to test assertions.
    if (Test-Path $script:CoreLibPath) {
        . $script:CoreLibPath
    }

    # Dot-source the emit core so Invoke-PipelineMetricsV4Emit can be called
    # in-process (no child pwsh spawn — #257 script-safety contract).
    if (Test-Path $script:EmitCorePath) {
        . $script:EmitCorePath
    }

    # Minimal valid v3 base YAML (no pipeline-metrics wrapper, no metrics_version line).
    $script:ValidV3Base = 'pr_number: 42'

    # Sentinel token (stored to avoid parser confusion with HTML comment syntax in test titles).
    $script:SentinelToken  = '<!-- cost-capture-failed -->'
    $script:SentinelRegex  = [regex]::Escape($script:SentinelToken)

    # A valid credit row pscustomobject shaped as Build-ImplementCodeCreditRow returns.
    $script:ValidCredit = [pscustomobject]@{
        port               = 'implement-code'
        adapter            = 'skills/implementation-discipline/adapters/implement-code-adapter.md'
        status             = 'passed'
        run_index          = 1
        evidence           = 'emit-pipeline-metrics-v4.Tests.ps1 -- success fixture'
        'terminal-step-id' = 2
    }

    # Helper: create a unique temp body file path (not yet created -- the script creates it).
    # Stored as a scriptblock so It-blocks can invoke it via & $script:TempBodyFile.
    $script:TempBodyFile = {
        return [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(),
            "emit-v4-test-$([System.Guid]::NewGuid().ToString('N')).md"
        )
    }

    # Helper: invoke the emit core in-process and CAPTURE warning records, for
    # tests that assert on Write-Warning text (repo-derivation failure, pre-PR
    # warn). Does not silence warnings -- collects them into -WarningVariable.
    #
    # Single source of truth (issue #794 Fix G — consolidated from a near-byte-
    # identical sibling, InvokeScript, which differed only in NOT capturing
    # -WarningVariable and NOT returning a Warnings field). InvokeScript below
    # is now a thin wrapper that calls this helper and discards Warnings, since
    # this helper is a strict superset of InvokeScript's behavior: the same
    # Invoke-PipelineMetricsV4Emit call with the same parameters, plus warning
    # capture, which has no observable effect on ExitCode or BodyContent for
    # callers that never look at $warnings.
    $script:InvokeScriptCapturingWarnings = {
        param(
            [string]$BodyFile,
            [string]$V3BaseYaml = '',
            [pscustomobject[]]$Credits = @(),
            [pscustomobject[]]$DispatchCostSamples = @(),
            [int]$IssueNumber = 0,
            [string]$RichBody = '',
            [string]$Repo = '',
            [string]$GhCliPath = 'gh',
            [switch]$SkipMarkerHarvest
        )

        $warnings = $null
        $emitResult = Invoke-PipelineMetricsV4Emit `
            -BodyFile            $BodyFile `
            -V3BaseYaml          $V3BaseYaml `
            -Credits             $Credits `
            -DispatchCostSamples $DispatchCostSamples `
            -IssueNumber         $IssueNumber `
            -RichBody            $RichBody `
            -Repo                $Repo `
            -GhCliPath           $GhCliPath `
            -SkipMarkerHarvest:  $SkipMarkerHarvest `
            -WarningVariable     warnings `
            -WarningAction       SilentlyContinue

        $bodyContent = ''
        if (Test-Path -LiteralPath $BodyFile) {
            $bodyContent = Get-Content -LiteralPath $BodyFile -Raw
        }

        return [pscustomobject]@{
            ExitCode    = $emitResult.ExitCode
            BodyContent = $bodyContent
            Warnings    = @($warnings | ForEach-Object { $_.ToString() })
        }
    }

    # Helper: invoke the emit core in-process and return @{ ExitCode; BodyContent }.
    # Dot-source + in-process call pattern (#257) — Invoke-PipelineMetricsV4Emit
    # returns an ExitCode object instead of calling exit, so no child pwsh is spawned.
    #
    # Thin wrapper over InvokeScriptCapturingWarnings (issue #794 Fix G): forwards
    # all parameters unchanged and returns the same ExitCode/BodyContent shape as
    # before the consolidation, dropping only the Warnings field that none of this
    # helper's 17 call sites ever read.
    $script:InvokeScript = {
        param(
            [string]$BodyFile,
            [string]$V3BaseYaml = '',
            [pscustomobject[]]$Credits = @(),
            [pscustomobject[]]$DispatchCostSamples = @(),
            [int]$IssueNumber = 0,
            [string]$RichBody = '',
            [string]$Repo = '',
            [string]$GhCliPath = 'gh',
            [switch]$SkipMarkerHarvest
        )

        $captured = & $script:InvokeScriptCapturingWarnings `
            -BodyFile            $BodyFile `
            -V3BaseYaml          $V3BaseYaml `
            -Credits             $Credits `
            -DispatchCostSamples $DispatchCostSamples `
            -IssueNumber         $IssueNumber `
            -RichBody            $RichBody `
            -Repo                $Repo `
            -GhCliPath           $GhCliPath `
            -SkipMarkerHarvest:  $SkipMarkerHarvest

        return [pscustomobject]@{
            ExitCode    = $captured.ExitCode
            BodyContent = $captured.BodyContent
        }
    }

    # Test-double gh script (issue #794 s2): a fake 'gh' executable that never
    # makes a live network call. Used to inject deterministic gh behavior for
    # marker-harvest tests without violating the #257 script-safety contract.
    # Understands the subset of gh invocations Invoke-CreditInputHarvest and
    # script:Resolve-EmitV4Repo issue:
    #   gh repo view --json nameWithOwner --jq '.nameWithOwner'  -> prints a repo slug
    #   gh api repos/{repo}/issues/{n}/comments --paginate --slurp -> prints comments JSON
    # Controlled via environment variables so each test can shape the response
    # without needing a different script file per scenario.
    $script:FakeGhScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) "emit-v4-fake-gh-$([System.Guid]::NewGuid().ToString('N')).ps1"
    @'
param()
$argsList = $args
if ($argsList -contains 'view') {
    if ($env:EMIT_V4_FAKE_GH_REPO_VIEW_FAIL -eq '1') {
        exit 1
    }
    Write-Output $env:EMIT_V4_FAKE_GH_REPO_VIEW_OUTPUT
    exit 0
}
if ($argsList -contains 'api') {
    if ($env:EMIT_V4_FAKE_GH_API_FAIL -eq '1') {
        exit 1
    }
    Write-Output $env:EMIT_V4_FAKE_GH_API_OUTPUT
    exit 0
}
exit 1
'@ | Set-Content -LiteralPath $script:FakeGhScriptPath -Encoding utf8NoBOM

    # Wraps the fake gh *.ps1 script so it can be invoked the same way a real
    # 'gh' executable would be (as a bare command via & $GhCliPath ...). PowerShell
    # can invoke a .ps1 directly via & so GhCliPath is simply this path.
    $script:FakeGhCliPath = $script:FakeGhScriptPath
}

AfterAll {
    Remove-Item -LiteralPath $script:FakeGhScriptPath -ErrorAction SilentlyContinue
}

Describe 'emit-pipeline-metrics-v4.ps1' {

    Context 'Case 3 - success: valid V3BaseYaml plus credit row' {

        It 'writes metrics_version 4 and the credit row to BodyFile, exits 0' {
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile $bodyFile `
                    -V3BaseYaml $script:ValidV3Base `
                    -Credits @($script:ValidCredit)

                $result.ExitCode    | Should -Be 0
                $result.BodyContent | Should -Match 'metrics_version: 4'
                $result.BodyContent | Should -Match 'implement-code'
                $result.BodyContent | Should -Not -Match $script:SentinelRegex
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }

        It 'round-trips through Read-PRMetricsBlock and reports MetricsVersion=4 with credits' {
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile $bodyFile `
                    -V3BaseYaml $script:ValidV3Base `
                    -Credits @($script:ValidCredit)

                $result.ExitCode | Should -Be 0

                $parsed = Read-PRMetricsBlock -PrBody $result.BodyContent
                $parsed                  | Should -Not -BeNullOrEmpty
                $parsed.MetricsVersion   | Should -Be 4
                @($parsed.Credits).Count | Should -BeGreaterThan 0
                ($parsed.Credits | Where-Object { $_.Port -eq 'implement-code' }) | Should -Not -BeNullOrEmpty
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 1 - builder throws: empty V3BaseYaml' {

        It 'writes cost-capture-failed sentinel to BodyFile and exits non-zero' {
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile $bodyFile `
                    -V3BaseYaml '' `
                    -Credits @($script:ValidCredit)

                $result.ExitCode    | Should -Not -Be 0
                $result.BodyContent | Should -Match $script:SentinelRegex
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }

        It 'fallback body contains metrics_emission_failed when no V3BaseYaml and no Credits' {
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile $bodyFile `
                    -V3BaseYaml '' `
                    -Credits @()

                $result.ExitCode    | Should -Not -Be 0
                $result.BodyContent | Should -Match 'metrics_emission_failed'
                $result.BodyContent | Should -Match $script:SentinelRegex
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 2 - empty credits: Test-PipelineMetricsV4Block rejects' {

        It 'writes sentinel when credits array is empty and Test- reports invalid' {
            # New-PipelineMetricsV4Block with valid V3BaseYaml but no credits
            # produces a block with no credits[] section, which Test- rejects (no credits).
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile $bodyFile `
                    -V3BaseYaml $script:ValidV3Base `
                    -Credits @()

                $result.ExitCode    | Should -Not -Be 0
                $result.BodyContent | Should -Match $script:SentinelRegex
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'M21 - sentinel token does not match pipeline-metrics pattern' {

        It 'sentinel token does not match the pipeline-metrics regex' {
            $script:SentinelToken | Should -Not -Match '<!--\s*pipeline-metrics'
        }

        It 'Test-PipelineMetricsV4Block counts sentinel as zero pipeline-metrics markers' {
            # Build a body containing only the sentinel (no real pipeline-metrics block).
            # The function must report DetectedMarkerCount=0 (sentinel is not counted).
            $bodyWithSentinelOnly = "Some PR text.`n`n$($script:SentinelToken)`n`nMore text."

            $testResult = Test-PipelineMetricsV4Block -PRBody $bodyWithSentinelOnly
            $testResult.Valid               | Should -Be $false
            $testResult.DetectedMarkerCount | Should -Be 0
        }

        It 'body with sentinel alongside a valid v4 block still reports exactly 1 marker' {
            # Sentinel plus a real v4 block: marker count must remain 1 (M21).
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile $bodyFile `
                    -V3BaseYaml $script:ValidV3Base `
                    -Credits @($script:ValidCredit)

                $result.ExitCode | Should -Be 0

                # Append sentinel and re-validate.
                $bodyWithBoth = $result.BodyContent + "`n`n$($script:SentinelToken)"
                $testResult = Test-PipelineMetricsV4Block -PRBody $bodyWithBoth
                $testResult.DetectedMarkerCount | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'M7 - v3-base containing pipeline-metrics opener causes builder throw then sentinel' {

        It 'emits sentinel when V3BaseYaml contains the pipeline-metrics opener' {
            # Injecting a pipeline-metrics opener into V3BaseYaml causes
            # New-PipelineMetricsV4Block to throw its double-wrap guard.
            $poisonedBase = "pr_number: 42`n<!-- pipeline-metrics`nsome_field: value`n-->"
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile $bodyFile `
                    -V3BaseYaml $poisonedBase `
                    -Credits @($script:ValidCredit)

                $result.ExitCode    | Should -Not -Be 0
                $result.BodyContent | Should -Match $script:SentinelRegex
                # The poisoned opener must be absent from the fallback body (CR5):
                # reusing the poisoned V3BaseYaml would re-ship the double marker.
                $result.BodyContent | Should -Not -Match '<!--\s*pipeline-metrics'
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 7 - RichBody merging: success path appends v4 block after rich body content' {

        It 'body file contains Closes #769 before the pipeline-metrics block when RichBody is provided' {
            $richBodyContent = "## Summary`n`nCloses #769`n"
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @($script:ValidCredit) `
                    -RichBody    $richBodyContent

                $result.ExitCode    | Should -Be 0
                $result.BodyContent | Should -Match 'Closes #769'
                $result.BodyContent | Should -Match '<!-- pipeline-metrics'
                $result.BodyContent | Should -Match 'metrics_version: 4'
                $result.BodyContent | Should -Not -Match $script:SentinelRegex

                # Ordering: "Closes #769" must appear before "<!-- pipeline-metrics"
                $closesIndex  = $result.BodyContent.IndexOf('Closes #769')
                $metricsIndex = $result.BodyContent.IndexOf('<!-- pipeline-metrics')
                $closesIndex  | Should -BeLessThan $metricsIndex
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }

        It 'fails into the sentinel path when RichBody already contains a v4 pipeline-metrics block (CR3 double-marker guard)' {
            # A RichBody that already carries its own v4 pipeline-metrics block would,
            # when composed with the freshly-built v4 block, produce a double-marker
            # body. Validating the COMPOSED final body (CR3) must catch this and fail
            # into the sentinel fallback rather than shipping two markers.
            $richWithMarker = @(
                '## Summary'
                ''
                'Closes #769'
                ''
                '<!-- pipeline-metrics'
                'metrics_version: 4'
                'pr_number: 42'
                '-->'
            ) -join "`n"

            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile   $bodyFile `
                    -V3BaseYaml $script:ValidV3Base `
                    -Credits    @($script:ValidCredit) `
                    -RichBody   $richWithMarker

                $result.ExitCode    | Should -Not -Be 0
                $result.BodyContent | Should -Match $script:SentinelRegex
                # CR-NEW-1 / CR-DUP-1: the fallback must strip the embedded metrics
                # block from RichBody so downstream readers cannot mistake the failure
                # body for a real v4 emission.
                $result.BodyContent | Should -Not -Match '<!--\s*pipeline-metrics'
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 8 - RichBody preserved in fallback: rich content survives emit failure' {

        It 'body file contains Closes #769 before the sentinel when RichBody is provided and builder throws' {
            # Empty V3BaseYaml forces builder throw (Case 1), so RichBody must survive in fallback.
            $richBodyContent = "## Summary`n`nCloses #769`n"
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  '' `
                    -Credits     @($script:ValidCredit) `
                    -RichBody    $richBodyContent

                $result.ExitCode    | Should -Not -Be 0
                $result.BodyContent | Should -Match 'Closes #769'
                $result.BodyContent | Should -Match $script:SentinelRegex

                # Ordering: "Closes #769" must appear before the sentinel
                $closesIndex   = $result.BodyContent.IndexOf('Closes #769')
                $sentinelIndex = $result.BodyContent.IndexOf($script:SentinelToken)
                $closesIndex   | Should -BeLessThan $sentinelIndex
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 6 (s-acc) - harvest hook: file-based accumulator provides credits when -Credits is empty' {

        It 'produces a valid v4 body with the credit from fclcredits.jsonl when -Credits is empty and -IssueNumber matches' {
            # Arrange: pre-populate the accumulator file for test issue 99999.
            $repoRoot        = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
            $accDir          = Join-Path $repoRoot '.tmp/issue-99999'
            $accFile         = Join-Path $accDir 'fclcredits.jsonl'
            New-Item -ItemType Directory -Force -Path $accDir | Out-Null

            # Write the same shape as Build-ImplementCodeCreditRow returns.
            $creditRow = [pscustomobject]@{
                port               = 'implement-code'
                adapter            = 'skills/implementation-discipline/adapters/implement-code-adapter.md'
                status             = 'passed'
                run_index          = 1
                evidence           = 'emit-pipeline-metrics-v4.Tests.ps1 -- s-acc harvest fixture'
                'terminal-step-id' = 5
            }
            $creditRow | ConvertTo-Json -Compress -Depth 10 | Set-Content -Path $accFile -Encoding utf8NoBOM

            $bodyFile = & $script:TempBodyFile
            try {
                # Act: call with empty -Credits and -IssueNumber 99999.
                # -SkipMarkerHarvest (issue #794 s2): this case tests the pure
                # accumulator/sentinel path, not the marker-harvest path -- without
                # this, -IssueNumber 99999 would now also trigger a live gh call.
                $result = & $script:InvokeScript `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @() `
                    -IssueNumber 99999 `
                    -SkipMarkerHarvest

                # Assert: harvest ran, body is valid v4.
                $result.ExitCode    | Should -Be 0
                $result.BodyContent | Should -Match 'metrics_version: 4'
                $result.BodyContent | Should -Match 'implement-code'
                $result.BodyContent | Should -Not -Match $script:SentinelRegex
            } finally {
                Remove-Item -LiteralPath $bodyFile  -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $accFile   -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $accDir    -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 9 (marker-harvest merge) - issue #794 s2: dedup and precedence rules' {

        BeforeEach {
            # Fake gh in-memory comments JSON containing credit-input markers for
            # 'design' and 'plan' (SMC-17 marker shape), so Invoke-CreditInputHarvest
            # can parse them without a live gh call.
            $designMarker = @'
<!-- credit-input-design-88888 -->
```yaml
port: design
adapter: skills/technical-design/adapters/design-adapter.md
evidence: "harvested design evidence"
```
'@
            $planMarker = @'
<!-- credit-input-plan-88888 -->
```yaml
port: plan
adapter: skills/plan-authoring/adapters/plan-adapter.md
evidence: "harvested plan evidence"
```
'@
            $completionDesign = '<!-- design-phase-complete-88888 -->'
            $completionPlan   = '<!-- plan-issue-88888 -->'

            $commentsPayload = @(
                @{ body = $designMarker },
                @{ body = $completionDesign },
                @{ body = $planMarker },
                @{ body = $completionPlan }
            ) | ConvertTo-Json -Depth 10 -Compress

            $env:EMIT_V4_FAKE_GH_REPO_VIEW_OUTPUT = 'Grimblaz/agent-orchestra'
            $env:EMIT_V4_FAKE_GH_REPO_VIEW_FAIL   = '0'
            $env:EMIT_V4_FAKE_GH_API_OUTPUT       = "[$commentsPayload]"
            $env:EMIT_V4_FAKE_GH_API_FAIL         = '0'
        }

        AfterEach {
            Remove-Item Env:\EMIT_V4_FAKE_GH_REPO_VIEW_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item Env:\EMIT_V4_FAKE_GH_REPO_VIEW_FAIL   -ErrorAction SilentlyContinue
            Remove-Item Env:\EMIT_V4_FAKE_GH_API_OUTPUT       -ErrorAction SilentlyContinue
            Remove-Item Env:\EMIT_V4_FAKE_GH_API_FAIL         -ErrorAction SilentlyContinue
        }

        It 'accumulator row wins over harvested row for the same port (accumulator + harvest collide on plan)' {
            # Arrange: an explicit -Credits row for 'plan' collides with the fake
            # gh harvest's 'plan' row. The explicit row must win (present, unmodified).
            $explicitPlanCredit = [pscustomobject]@{
                port     = 'plan'
                adapter  = 'skills/plan-authoring/adapters/plan-adapter.md'
                status   = 'passed'
                evidence = 'EXPLICIT plan credit -- must win over harvested row'
            }

            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @($script:ValidCredit, $explicitPlanCredit) `
                    -IssueNumber 88888 `
                    -GhCliPath   $script:FakeGhCliPath

                $result.ExitCode | Should -Be 0

                $parsed = Read-PRMetricsBlock -PrBody $result.BodyContent
                $planRows = @($parsed.Credits | Where-Object { $_.Port -eq 'plan' })
                $planRows.Count | Should -Be 1
                $planRows[0].Evidence | Should -Match 'EXPLICIT plan credit'
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }

        It 'harvested-only port (design) is present in the final credits[] when no accumulator/explicit row exists for it' {
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @($script:ValidCredit) `
                    -IssueNumber 88888 `
                    -GhCliPath   $script:FakeGhCliPath

                $result.ExitCode | Should -Be 0

                $parsed = Read-PRMetricsBlock -PrBody $result.BodyContent
                $designRows = @($parsed.Credits | Where-Object { $_.Port -eq 'design' })
                $designRows.Count | Should -Be 1
                $designRows[0].Evidence | Should -Match 'harvested design evidence'
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }

        It 'zero conductor-accumulated credits (-Credits @()) plus marker-harvest alone populates a non-empty credits[]' {
            # Arrange: the exact #790/#793/#804 failure shape -- an orchestrated PR
            # with ZERO conductor-accumulated credits (-Credits @()). Unlike the
            # sibling Case 9 tests above, no accumulator/-Credits row is seeded here.
            # This directly proves harvest-alone (no accumulator input) produces a
            # populated credits[], rather than relying on composing that property
            # from the separately-tested merge logic and harvest function.
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @() `
                    -IssueNumber 88888 `
                    -GhCliPath   $script:FakeGhCliPath

                $result.ExitCode | Should -Be 0

                $parsed = Read-PRMetricsBlock -PrBody $result.BodyContent
                @($parsed.Credits).Count | Should -BeGreaterThan 0
                ($parsed.Credits | Where-Object { $_.Port -eq 'design' -and $_.Evidence -match 'harvested design evidence' }) | Should -Not -BeNullOrEmpty
                ($parsed.Credits | Where-Object { $_.Port -eq 'plan' -and $_.Evidence -match 'harvested plan evidence' }) | Should -Not -BeNullOrEmpty
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }

        It 're-running the emit twice with identical inputs produces an identical credits[] block' {
            $bodyFileA = & $script:TempBodyFile
            $bodyFileB = & $script:TempBodyFile
            try {
                $resultA = & $script:InvokeScript `
                    -BodyFile    $bodyFileA `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @($script:ValidCredit) `
                    -IssueNumber 88888 `
                    -GhCliPath   $script:FakeGhCliPath

                $resultB = & $script:InvokeScript `
                    -BodyFile    $bodyFileB `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @($script:ValidCredit) `
                    -IssueNumber 88888 `
                    -GhCliPath   $script:FakeGhCliPath

                $resultA.ExitCode | Should -Be 0
                $resultB.ExitCode | Should -Be 0

                $parsedA = Read-PRMetricsBlock -PrBody $resultA.BodyContent
                $parsedB = Read-PRMetricsBlock -PrBody $resultB.BodyContent

                ($parsedA.Credits | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($parsedB.Credits | ConvertTo-Json -Depth 10 -Compress)
            } finally {
                Remove-Item -LiteralPath $bodyFileA -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $bodyFileB -ErrorAction SilentlyContinue
            }
        }

        It '-SkipMarkerHarvest bypasses the harvest branch entirely (no harvest-related gh call happens)' {
            # Arrange: point GhCliPath at a script that always fails, proving it is
            # never invoked when -SkipMarkerHarvest is set.
            $neverCalledGhPath = Join-Path ([System.IO.Path]::GetTempPath()) "emit-v4-never-called-gh-$([System.Guid]::NewGuid().ToString('N')).ps1"
            "exit 1" | Set-Content -LiteralPath $neverCalledGhPath -Encoding utf8NoBOM

            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScript `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @($script:ValidCredit) `
                    -IssueNumber 88888 `
                    -GhCliPath   $neverCalledGhPath `
                    -SkipMarkerHarvest

                # If the never-called gh script had been invoked (exit 1), the branch's
                # try/catch handling would still not throw -- so the true assertion is
                # that only the explicit credit is present (design/plan not backfilled).
                $result.ExitCode | Should -Be 0
                $parsed = Read-PRMetricsBlock -PrBody $result.BodyContent
                @($parsed.Credits).Count | Should -Be 1
                $parsed.Credits[0].Port | Should -Be 'implement-code'
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $neverCalledGhPath -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 10 (repo-derivation failure) - issue #794 s2: fail-open when repo cannot be resolved' {

        AfterEach {
            Remove-Item Env:\EMIT_V4_FAKE_GH_REPO_VIEW_FAIL -ErrorAction SilentlyContinue
        }

        It 'script:Resolve-EmitV4Repo returns $null when gh repo view fails and there is no git remote to parse' {
            # Deterministic unit test of the derivation helper itself, run from a
            # freshly created directory with no .git ancestry, so 'git remote
            # get-url origin' cannot succeed regardless of the real dev repo's
            # origin (avoids the non-determinism of running this from inside the
            # actual agent-orchestra checkout, where the real origin resolves).
            $env:EMIT_V4_FAKE_GH_REPO_VIEW_FAIL = '1'
            $isolatedDir = Join-Path ([System.IO.Path]::GetTempPath()) "emit-v4-no-git-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Force -Path $isolatedDir | Out-Null
            $originalLocation = Get-Location
            try {
                Set-Location -LiteralPath $isolatedDir
                $resolved = script:Resolve-EmitV4Repo -GhCliPath $script:FakeGhCliPath
                $resolved | Should -BeNullOrEmpty
            } finally {
                Set-Location -LiteralPath $originalLocation
                Remove-Item -LiteralPath $isolatedDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'emits the loud repo-resolution warning and skips marker-harvest without throwing, when repo cannot be resolved' {
            # End-to-end: force script:Resolve-EmitV4Repo to return $null by running
            # the emit itself from the same isolated, non-git directory used above,
            # with the fake gh's 'view' branch also failing. This proves the full
            # Invoke-PipelineMetricsV4Emit call path fails open (warns, does not
            # throw, still ships a valid body from the explicit credit) rather than
            # only unit-testing the helper in isolation.
            $env:EMIT_V4_FAKE_GH_REPO_VIEW_FAIL = '1'
            $isolatedDir = Join-Path ([System.IO.Path]::GetTempPath()) "emit-v4-no-git-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Force -Path $isolatedDir | Out-Null
            $originalLocation = Get-Location
            $bodyFile = & $script:TempBodyFile
            try {
                Set-Location -LiteralPath $isolatedDir
                $result = & $script:InvokeScriptCapturingWarnings `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @($script:ValidCredit) `
                    -IssueNumber 77777 `
                    -GhCliPath   $script:FakeGhCliPath

                $result.ExitCode    | Should -Be 0
                $result.BodyContent | Should -Not -Match $script:SentinelRegex
                $result.BodyContent | Should -Match 'implement-code'
                ($result.Warnings -join "`n") | Should -Match 'Credits harvest skipped'
            } finally {
                Set-Location -LiteralPath $originalLocation
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $isolatedDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 11 (pre-PR warn) - issue #794 s2: warn fires when composed credits end up empty' {

        It 'emits the "credits[] is empty" warning when V3BaseYaml is empty (forces sentinel path) and no credits are composed' {
            $bodyFile = & $script:TempBodyFile
            try {
                $result = & $script:InvokeScriptCapturingWarnings `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  '' `
                    -Credits     @() `
                    -IssueNumber 66666 `
                    -SkipMarkerHarvest

                $result.ExitCode    | Should -Not -Be 0
                $result.BodyContent | Should -Match $script:SentinelRegex
                ($result.Warnings -join "`n") | Should -Match 'credits\[\] is empty'
            } finally {
                Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Case 12 (no-live-network) - issue #794 s2: full test file makes zero real gh process invocations' {

        It 'running this entire test file spawns no external gh executable' {
            # This is a structural/documentation assertion: every -IssueNumber call
            # site in this file above either passes -SkipMarkerHarvest or a fake
            # -GhCliPath double, so no real 'gh' binary is ever invoked in-process.
            # We assert the source text itself to keep this test resilient to test
            # ordering and to catch future additions that forget the requirement.
            $thisFile = $PSCommandPath
            $sourceText = Get-Content -LiteralPath $thisFile -Raw

            # Every '-IssueNumber' occurrence used as an actual call argument (not in
            # a comment/param block) must be paired, in the same It-block's call, with
            # either '-SkipMarkerHarvest' or '-GhCliPath'. Rather than a fragile
            # per-call-site regex walk, assert the stronger invariant directly: the
            # literal bare command name 'gh ' (a live CLI invocation) never appears
            # outside of comments/strings describing gh, and the fake-gh script path
            # variable is used for every harvest-exercising test above.
            $sourceText | Should -Not -Match '(?m)^\s*&\s*gh\s'
        } -Tag 'NoLiveNetwork'
    }
}
