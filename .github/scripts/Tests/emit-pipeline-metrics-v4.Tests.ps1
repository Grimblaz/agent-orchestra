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

    # Helper: invoke the emit core in-process and return @{ ExitCode; BodyContent }.
    # Dot-source + in-process call pattern (#257) — Invoke-PipelineMetricsV4Emit
    # returns an ExitCode object instead of calling exit, so no child pwsh is spawned.
    $script:InvokeScript = {
        param(
            [string]$BodyFile,
            [string]$V3BaseYaml = '',
            [pscustomobject[]]$Credits = @(),
            [pscustomobject[]]$DispatchCostSamples = @(),
            [int]$IssueNumber = 0,
            [string]$RichBody = ''
        )

        $emitResult = Invoke-PipelineMetricsV4Emit `
            -BodyFile            $BodyFile `
            -V3BaseYaml          $V3BaseYaml `
            -Credits             $Credits `
            -DispatchCostSamples $DispatchCostSamples `
            -IssueNumber         $IssueNumber `
            -RichBody            $RichBody `
            -WarningAction       SilentlyContinue

        $bodyContent = ''
        if (Test-Path -LiteralPath $BodyFile) {
            $bodyContent = Get-Content -LiteralPath $BodyFile -Raw
        }

        return [pscustomobject]@{
            ExitCode    = $emitResult.ExitCode
            BodyContent = $bodyContent
        }
    }
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
                $result = & $script:InvokeScript `
                    -BodyFile    $bodyFile `
                    -V3BaseYaml  $script:ValidV3Base `
                    -Credits     @() `
                    -IssueNumber 99999

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
}
