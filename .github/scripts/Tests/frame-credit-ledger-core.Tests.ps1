#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for the frame-credit-ledger-core pure-logic library (issue #429, Step 3 RED).
#
# Library under test: .github/scripts/lib/frame-credit-ledger-core.ps1
# At Step 3 RED the library does NOT exist yet, so the dot-source is guarded and
# every It-block exercises a public function. Calls fail with
# CommandNotFoundException until Step 4 GREEN lands the library.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    $script:LivePortsDir = Join-Path $script:RepoRoot 'frame/ports'

    if (Test-Path $script:LibPath) {
        . $script:LibPath
    }

    # Helper: build a v4 pipeline-metrics PR body from a YAML payload string.
    # Wraps the YAML in the canonical HTML-comment marker block.
    # Stored as a script-scoped scriptblock so It-blocks can invoke it via `& $script:NewV4PrBody`.
    $script:NewV4PrBody = {
        param(
            [Parameter(Mandatory)][string]$Yaml,
            [string]$Prefix = "## Summary`n`nA PR.`n`n",
            [string]$Suffix = "`n`nMore text after the marker.`n"
        )
        return "$Prefix<!-- pipeline-metrics`n$Yaml`n-->$Suffix"
    }

    # Canonical v4 YAML payload with both Credits and IntegrityChecks.
    $script:V4FullYaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    status: passed
    evidence: "judge ruling: keep"
  - port: implement-test
    status: failed
    evidence: "tests RED at HEAD"
  - port: ce-gate-cli
    status: not-applicable
    evidence: "no CLI surface touched"
integrity_checks:
  - check: schema-version-pinned
    status: passed
  - check: marker-presence
    status: passed
'@

    $script:PreV4Yaml = @'
metrics_version: 3
some_legacy_field: value
'@

    $script:MalformedYaml = @"
metrics_version: 4
credits:
  - port: review
    status: passed
  : this line is not valid YAML
    bad indentation: [unbalanced
"@
}

Describe 'Read-PRMetricsBlock' {

    It 'parses a v4 marker into MetricsVersion=4 with a Credits array' {
        $body = & $script:NewV4PrBody -Yaml $script:V4FullYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 4
        $result.Credits | Should -Not -BeNullOrEmpty
        @($result.Credits).Count | Should -Be 3
        ($result.Credits | Where-Object { $_.Port -eq 'review' }).Status | Should -Be 'passed'
    }

    It 'parses a v4 marker into both Credits and IntegrityChecks arrays' {
        $body = & $script:NewV4PrBody -Yaml $script:V4FullYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $result.IntegrityChecks | Should -Not -BeNullOrEmpty
        @($result.IntegrityChecks).Count | Should -Be 2
        $result.FrameVersion | Should -Be 1
    }

    It 'returns MetricsVersion=pre-v4 when the marker exists but version is not 4' {
        $body = & $script:NewV4PrBody -Yaml $script:PreV4Yaml
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 'pre-v4'
    }

    It 'returns $null when no pipeline-metrics marker is present' {
        $body = "## Summary`n`nJust a regular PR body without any marker.`n"
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -BeNullOrEmpty
    }

    It 'returns MetricsVersion=parse-error when the marker contains malformed YAML' {
        $body = & $script:NewV4PrBody -Yaml $script:MalformedYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 'parse-error'
        $result.Reason | Should -Not -BeNullOrEmpty
    }

    It 'tolerates Windows CRLF line endings inside the marker block' {
        $crlfYaml = ($script:V4FullYaml -replace "`n", "`r`n")
        $body = "## Summary`r`n`r`n<!-- pipeline-metrics`r`n$crlfYaml`r`n-->`r`n"
        $result = Read-PRMetricsBlock -PrBody $body

        $result.MetricsVersion | Should -Be 4
        @($result.Credits).Count | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
# AC5 — Detected-state diagnostic (issue #739 s1)
# Tests for DetectedVersion field on Read-PRMetricsBlock and the
# Compose-PreV4ShortCircuitComment rendering per detected state.
# ---------------------------------------------------------------------------
Describe 'Read-PRMetricsBlock — DetectedVersion field (issue #739 AC5)' {

    It '#737-shape fixture: self-closing marker captures empty block -> DetectedVersion=no-version-field' {
        # Replicates the exact emission from PR #737 as documented in the issue Evidence section:
        # the conductor emitted <!-- pipeline-metrics --> (self-closing) which the regex matches
        # with an empty captured block, producing no metrics_version field.
        # Source: issue #739 Evidence section — built from the issue body, NOT from gh pr view 737.
        $prBody = @"
## Summary

A PR opened through the inline orchestration flow.

<!-- pipeline-metrics -->
``````yaml
schema_version: 2
issue: 735
review_mode: full
stages_run: [experience, design, plan, implement, review]
``````
<!-- /pipeline-metrics -->

More text after.
"@

        $result = Read-PRMetricsBlock -PrBody $prBody

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 'pre-v4'
        $result.DetectedVersion | Should -Be 'no-version-field'
    }

    It 'literal-version fixture: block with metrics_version: 3 -> DetectedVersion=version-N-not-4' {
        $body = "## Summary`n`n<!-- pipeline-metrics`nmetrics_version: 3`n-->`n"

        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 'pre-v4'
        $result.DetectedVersion | Should -Be 'version-N-not-4'
    }

    It 'existing MetricsVersion=pre-v4 test still passes (backwards-compatibility guard)' {
        $body = & $script:NewV4PrBody -Yaml $script:PreV4Yaml
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 'pre-v4'
    }

    It 'v4 block returns null or absent DetectedVersion (only meaningful on pre-v4 path)' {
        $body = & $script:NewV4PrBody -Yaml $script:V4FullYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $result.MetricsVersion | Should -Be 4
        # DetectedVersion may be absent or null on the v4 path — both are acceptable
        if ($null -ne $result.PSObject.Properties['DetectedVersion']) {
            $result.DetectedVersion | Should -BeNullOrEmpty
        }
    }
}

Describe 'Compose-PreV4ShortCircuitComment — DetectedVersion rendering (issue #739 AC5)' {

    It 'no-version-field renders the correct phrase about missing metrics_version field' {
        $comment = Compose-PreV4ShortCircuitComment -MarkerToken '<!-- frame-credit-ledger-warn -->' -DetectedVersion 'no-version-field'

        $comment | Should -Match 'no `metrics_version` field'
        $comment | Should -Match 'Coverage details are unavailable'
    }

    It 'version-N-not-4 renders the correct phrase about metrics_version set to a value other than 4' {
        $comment = Compose-PreV4ShortCircuitComment -MarkerToken '<!-- frame-credit-ledger-warn -->' -DetectedVersion 'version-N-not-4'

        $comment | Should -Match 'metrics_version.*other than 4|other than 4.*metrics_version'
        $comment | Should -Match 'Coverage details are unavailable'
    }

    It 'parse-error renders the correct phrase about block that could not be parsed' {
        $comment = Compose-PreV4ShortCircuitComment -MarkerToken '<!-- frame-credit-ledger-warn -->' -DetectedVersion 'parse-error'

        $comment | Should -Match 'could not be parsed'
        $comment | Should -Match 'Coverage details are unavailable'
    }

    It 'null/empty DetectedVersion falls back to the original hardcoded text' {
        $comment = Compose-PreV4ShortCircuitComment -MarkerToken '<!-- frame-credit-ledger-warn -->'

        $comment | Should -Match 'pre-v4 `pipeline-metrics` block'
    }

    It '#737-shape: no-version-field comment contains the correct description (end-to-end)' {
        # Verify that the no-version-field state detected by Read-PRMetricsBlock
        # produces the correct Compose-PreV4ShortCircuitComment output.
        $prBody = @"
## Summary

<!-- pipeline-metrics -->
``````yaml
schema_version: 2
``````
<!-- /pipeline-metrics -->
"@
        $metrics = Read-PRMetricsBlock -PrBody $prBody
        $metrics.DetectedVersion | Should -Be 'no-version-field'

        $comment = Compose-PreV4ShortCircuitComment -MarkerToken '<!-- frame-credit-ledger-warn -->' -DetectedVersion $metrics.DetectedVersion

        $comment | Should -Match 'no `metrics_version` field'
        $comment | Should -Match 'v3/pre-v4 base'
        $comment | Should -Match 'Coverage details are unavailable'
    }
}

Describe 'dispatch-cost-samples v4 metrics contract (issue #512 Step 12)' {

        BeforeAll {
                $script:V4DispatchCostSamplesYaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: pass
        judge-disposition: accepted
    - step-id: s13
        mode: budget-exceeded
        bytes: 9216
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
integrity_checks:
    - check: marker-presence
        status: passed
'@
        }

        It 'parses dispatch-cost-samples rows with the exact required key set' {
                $body = & $script:NewV4PrBody -Yaml $script:V4DispatchCostSamplesYaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 4
                $result.DispatchCostSamples | Should -Not -BeNullOrEmpty
                @($result.DispatchCostSamples).Count | Should -Be 2

                $sample = @($result.DispatchCostSamples)[0]
                (@($sample.PSObject.Properties.Name) -join ',') | Should -Be 'step-id,mode,bytes,rc-conformance,judge-disposition'
                $sample.'step-id' | Should -Be 's12'
                $sample.mode | Should -Be 'spine'
                $sample.bytes | Should -Be 7421
                $sample.'rc-conformance' | Should -Be 'pass'
                $sample.'judge-disposition' | Should -Be 'accepted'
        }

        It 'rejects dispatch-cost-samples rows with missing or extra keys' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: pass
        extra: "must not be accepted"
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 'parse-error'
                $result.Reason | Should -Match 'dispatch-cost-samples'
        }

        It 'rejects dispatch-cost-samples rows with values outside the allowed enums' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: partial-spine
        bytes: 7421
        rc-conformance: unknown
        judge-disposition: maybe
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 'parse-error'
                $result.Reason | Should -Match 'dispatch-cost-samples'
        }

        # -------------------------------------------------------------------------
        # Step 3 RED — 6-key provider field tests (issue #514)
        # These tests FAIL against the current implementation because:
        #   - ConvertFrom-FCLDispatchCostSampleChunk rejects any row with count != 5
        #   - New-DispatchCostSampleRow has no -Provider parameter
        #   - Set-FCLDispatchCostSamplesSection is not merge-aware
        # They go GREEN after Step 4 adds provider support.
        # -------------------------------------------------------------------------

        Context 'Context: 6-key provider field — parser back-compat' {

            It 'parses 5-key legacy rows without throwing (back-compat invariant)' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: pass
        judge-disposition: accepted
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 4
                $result.DispatchCostSamples | Should -Not -BeNullOrEmpty
                $sample = @($result.DispatchCostSamples)[0]
                # 5-key back-compat: exactly the five base keys, no provider
                (@($sample.PSObject.Properties.Name) -join ',') | Should -Be 'step-id,mode,bytes,rc-conformance,judge-disposition'
                $sample.'step-id' | Should -Be 's12'
            }
        }

        Context 'Context: 6-key provider field — parser additive' {

            It 'parses 6-key rows with provider: claude and round-trips through Set-FCLDispatchCostSamplesSection' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: pass
        judge-disposition: accepted
        provider: claude
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 4
                $result.DispatchCostSamples | Should -Not -BeNullOrEmpty
                $sample = @($result.DispatchCostSamples)[0]
                $sample.PSObject.Properties['provider'] | Should -Not -BeNullOrEmpty
                $sample.provider | Should -Be 'claude'
            }

            It 'parses 6-key rows with provider: copilot without error' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s13
        mode: spine
        bytes: 5000
        rc-conformance: pass
        judge-disposition: accepted
        provider: copilot
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 4
                $result.DispatchCostSamples | Should -Not -BeNullOrEmpty
                $sample = @($result.DispatchCostSamples)[0]
                $sample.provider | Should -Be 'copilot'
            }

            It 'tolerates unknown provider value per #467 D12 additivity (provider: future-tool does not throw)' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s14
        mode: spine
        bytes: 3000
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        provider: future-tool
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 4
                $result.DispatchCostSamples | Should -Not -BeNullOrEmpty
            }
        }

        Context 'Context: 6-key provider field — strict-position enforcement' {

            It 'throws when a 6-key row has provider at the wrong position (not position 6)' {
                # provider appears at position 2 (after step-id), which is wrong position
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        provider: claude
        mode: spine
        bytes: 7421
        rc-conformance: pass
        judge-disposition: accepted
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 'parse-error'
            }
        }

        Context 'Context: merge-aware dispatch-cost-samples writer (M9)' {

            It 'preserves existing provider:claude rows when called with provider:copilot rows for different tuples' {
                # PR body that already has a (s12, spine) row with provider: claude
                $existingYaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: pass
        judge-disposition: accepted
        provider: claude
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $existingYaml

                # Add a new (s13, spine, copilot) row — different tuple
                $updated = Add-DispatchCostSampleToPrBody -PrBody $body -StepId 's13' -Mode 'spine' -Bytes 5000 -Provider 'copilot'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

                # Both tuples must be present in the output
                $normalized | Should -Match 'step-id: s12'
                $normalized | Should -Match 'provider: claude'
                $normalized | Should -Match 'step-id: s13'
                $normalized | Should -Match 'provider: copilot'
            }

            It 'replaces existing rows when the same (step-id, mode, provider) tuple is submitted' {
                # Existing block has (s12, spine, claude, 7421)
                $existingYaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: pass
        judge-disposition: accepted
        provider: claude
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $existingYaml

                # Update the same tuple with bytes 9000
                $updated = Add-DispatchCostSampleToPrBody -PrBody $body -StepId 's12' -Mode 'spine' -Bytes 9000 -Provider 'claude'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

                # s12/spine/claude row should now have bytes 9000, not 7421
                $normalized | Should -Match 'bytes: 9000'
                $normalized | Should -Not -Match 'bytes: 7421'
            }
        }

        Context 'Context: D17 baseline-equivalence fixture (mixed 5-key + 6-key)' {

            It 'mixed 5-key and 6-key sample set parses without error (D17 calibration not reset by provider field)' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s10
        mode: legacy-fallback
        bytes: 1234
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: pass
        judge-disposition: accepted
        provider: claude
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $result.MetricsVersion | Should -Be 4
                @($result.DispatchCostSamples).Count | Should -Be 2

                $withProvider = @($result.DispatchCostSamples) | Where-Object { $_.'step-id' -eq 's12' }
                $withProvider | Should -Not -BeNullOrEmpty
                $withProvider.provider | Should -Be 'claude'

                $withoutProvider = @($result.DispatchCostSamples) | Where-Object { $_.'step-id' -eq 's10' }
                $withoutProvider | Should -Not -BeNullOrEmpty
            }
        }
}

Describe 'dispatch-cost-samples PR-body mutation helpers (issue #512 Step 12)' {

        It 'creates dispatch-time placeholder rows with both evaluation fields not-evaluated' {
                $command = Get-Command New-DispatchCostSampleRow -ErrorAction SilentlyContinue
                $command | Should -Not -BeNullOrEmpty

                $row = & $command -StepId 's12' -Mode 'spine' -Bytes 7421

                (@($row.PSObject.Properties.Name) -join ',') | Should -Be 'step-id,mode,bytes,rc-conformance,judge-disposition'
                $row.'step-id' | Should -Be 's12'
                $row.mode | Should -Be 'spine'
                $row.bytes | Should -Be 7421
                $row.'rc-conformance' | Should -Be 'not-evaluated'
                $row.'judge-disposition' | Should -Be 'not-evaluated'
        }

        It 'validates mode, rc-conformance, and judge-disposition enums when building rows' {
                $command = Get-Command New-DispatchCostSampleRow -ErrorAction SilentlyContinue
                $command | Should -Not -BeNullOrEmpty

                { & $command -StepId 's12' -Mode 'partial-spine' -Bytes 1 } | Should -Throw
                { & $command -StepId 's12' -Mode 'spine' -Bytes 1 -RcConformance 'unknown' } | Should -Throw
                { & $command -StepId 's12' -Mode 'spine' -Bytes 1 -JudgeDisposition 'maybe' } | Should -Throw
        }

        It 'inserts placeholder rows into a v4 PR-body metrics block without regressing existing fields' {
                $command = Get-Command Add-DispatchCostSampleToPrBody -ErrorAction SilentlyContinue
                $command | Should -Not -BeNullOrEmpty

                $body = & $script:NewV4PrBody -Yaml $script:V4FullYaml
                $updated = & $command -PrBody $body -StepId 's12' -Mode 'spine' -Bytes 7421
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

                $normalized | Should -Match '(?m)^metrics_version:\s*4\s*$'
                $normalized | Should -Match '(?m)^frame_version:\s*1\s*$'
                $normalized | Should -Match '(?m)^credits:\s*$'
                $normalized | Should -Match '(?m)^integrity_checks:\s*$'
                $normalized | Should -Match '(?ms)^dispatch-cost-samples:\n  - step-id: s12\n    mode: spine\n    bytes: 7421\n    rc-conformance: not-evaluated\n    judge-disposition: not-evaluated\s*$'
        }

        It 'back-fills a dispatch-cost-samples row by composite step-id and mode only' {
                $command = Get-Command Update-DispatchCostSampleEvaluationInPrBody -ErrorAction SilentlyContinue
                $command | Should -Not -BeNullOrEmpty

                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
    - step-id: s12
        mode: legacy-fallback
        bytes: 20531
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
integrity_checks:
    - check: marker-presence
        status: passed
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $updated = & $command -PrBody $body -StepId 's12' -Mode 'spine' -RcConformance 'pass' -JudgeDisposition 'accepted'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

                $normalized | Should -Match '(?ms)- step-id: s12\n    mode: spine\n    bytes: 7421\n    rc-conformance: pass\n    judge-disposition: accepted'
                $normalized | Should -Match '(?ms)- step-id: s12\n    mode: legacy-fallback\n    bytes: 20531\n    rc-conformance: not-evaluated\n    judge-disposition: not-evaluated'
                $normalized | Should -Match '(?m)^credits:\s*$'
                $normalized | Should -Match '(?m)^integrity_checks:\s*$'
        }

        It 'leaves evaluation back-fill unchanged when no matching dispatch-cost sample exists' {
                $command = Get-Command Update-DispatchCostSampleEvaluationInPrBody -ErrorAction SilentlyContinue
                $command | Should -Not -BeNullOrEmpty

                $body = & $script:NewV4PrBody -Yaml $script:V4FullYaml
                $updated = & $command -PrBody $body -StepId 's99' -Mode 'spine' -RcConformance 'pass'

                $updated | Should -Be $body -Because 'pre-PR lifecycle must create the placeholder sample before RC or judge back-fill can target it'
        }

        # -------------------------------------------------------------------------
        # Step 3 RED — producer-side provider emission tests (issue #514)
        # These tests FAIL against the current implementation because:
        #   - New-DispatchCostSampleRow has no -Provider parameter
        #   - Add-DispatchCostSampleToPrBody has no -Provider parameter
        # They go GREEN after Step 4 adds provider support.
        # -------------------------------------------------------------------------

        Context 'Context: producer-side -Provider emission (M13)' {

            It 'New-DispatchCostSampleRow -Provider claude produces row with provider field' {
                $row = New-DispatchCostSampleRow -StepId 's12' -Mode 'spine' -Bytes 7421 -Provider 'claude'
                $row.PSObject.Properties['provider'] | Should -Not -BeNullOrEmpty
                $row.provider | Should -Be 'claude'
            }

            It 'New-DispatchCostSampleRow -Provider copilot produces row with provider: copilot' {
                $row = New-DispatchCostSampleRow -StepId 's12' -Mode 'spine' -Bytes 7421 -Provider 'copilot'
                $row.provider | Should -Be 'copilot'
            }

            It 'New-DispatchCostSampleRow without -Provider omits provider field for back-compat' {
                $row = New-DispatchCostSampleRow -StepId 's12' -Mode 'spine' -Bytes 7421
                $row.PSObject.Properties['provider'] | Should -BeNullOrEmpty
            }
        }

        Context 'Context: Add-DispatchCostSampleToPrBody -Provider passthrough (M13)' {

            It 'Add-DispatchCostSampleToPrBody -Provider claude produces PR body with provider: claude line' {
                $body = & $script:NewV4PrBody -Yaml $script:V4FullYaml
                $updated = Add-DispatchCostSampleToPrBody -PrBody $body -StepId 's12' -Mode 'spine' -Bytes 7421 -Provider 'claude'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

                $normalized | Should -Match 'provider: claude'
            }
        }

        Context 'Context: Update-DispatchCostSampleEvaluationInPrBody provider preservation (issue #514 F1/F4a)' {

            It 'provider: claude is preserved when Update-DispatchCostSampleEvaluationInPrBody back-fills RC on a 6-key row' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        provider: claude
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $updated = Update-DispatchCostSampleEvaluationInPrBody -PrBody $body -StepId 's12' -Mode 'spine' -Provider 'claude' -RcConformance 'pass'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

                # provider: claude must survive the back-fill
                $normalized | Should -Match 'provider: claude'
                # rc-conformance must be updated
                $normalized | Should -Match 'rc-conformance: pass'
                # exactly one dispatch-cost-samples row must exist (no duplicate)
                $result = Read-PRMetricsBlock -PrBody $updated
                @($result.DispatchCostSamples).Count | Should -Be 1
            }

            It 'provider: copilot is preserved when Update-DispatchCostSampleEvaluationInPrBody back-fills judge-disposition' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s10
        mode: spine
        bytes: 4096
        rc-conformance: pass
        judge-disposition: not-evaluated
        provider: copilot
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $updated = Update-DispatchCostSampleEvaluationInPrBody -PrBody $body -StepId 's10' -Mode 'spine' -Provider 'copilot' -JudgeDisposition 'accepted'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

                $normalized | Should -Match 'provider: copilot'
                $normalized | Should -Match 'judge-disposition: accepted'
                $result = Read-PRMetricsBlock -PrBody $updated
                @($result.DispatchCostSamples).Count | Should -Be 1
            }

            It 'cross-tool rows are not duplicated: claude and copilot rows for same (step-id, mode) are preserved as two distinct rows' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        provider: claude
    - step-id: s12
        mode: spine
        bytes: 3100
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        provider: copilot
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                # Update only the claude row
                $updated = Update-DispatchCostSampleEvaluationInPrBody -PrBody $body -StepId 's12' -Mode 'spine' -Provider 'claude' -RcConformance 'pass'
                $result = Read-PRMetricsBlock -PrBody $updated

                # Both rows must survive — no duplication, no cross-contamination
                @($result.DispatchCostSamples).Count | Should -Be 2
                $claudeRow = @($result.DispatchCostSamples) | Where-Object { $_.provider -eq 'claude' }
                $copilotRow = @($result.DispatchCostSamples) | Where-Object { $_.provider -eq 'copilot' }
                $claudeRow.'rc-conformance' | Should -Be 'pass'
                $copilotRow.'rc-conformance' | Should -Be 'not-evaluated'
            }

            It 'no-Provider call leaves a 6-key (provider-attributed) row unchanged' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 1234
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        provider: claude
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $updated = Update-DispatchCostSampleEvaluationInPrBody -PrBody $body -StepId 's12' -Mode 'spine' -RcConformance 'pass'
                $updated | Should -Be $body
            }

            It 'no-Provider call updates a 5-key legacy (no-provider) row' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 1234
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $updated = Update-DispatchCostSampleEvaluationInPrBody -PrBody $body -StepId 's12' -Mode 'spine' -RcConformance 'pass'
                $updated | Should -Not -Be $body
                $updated | Should -Match 'rc-conformance: pass'
            }
        }

        Context 'Context: provider field preserved on RC back-fill update (M13 upsert preservation)' {

            It 'provider: claude is not dropped when Add-DispatchCostSampleToPrBody updates an existing row by RC back-fill' {
                # Build PR body that already has (s12, spine) row WITH provider: claude
                $existingYaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s12
        mode: spine
        bytes: 7421
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        provider: claude
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $existingYaml

                # RC back-fill update for the same step-id+mode (same tuple)
                $updated = Add-DispatchCostSampleToPrBody -PrBody $body -StepId 's12' -Mode 'spine' -Bytes 7421 -Provider 'claude'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"

                # provider: claude must be preserved after the upsert
                $normalized | Should -Match 'provider: claude'
            }
        }

        Context 'Context: model field — round-trip (issue #706)' {

            It 'model-without-provider: 6-key row (model at position 6) parses without error (A fix)' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s20
        mode: spine
        bytes: 8000
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        model: opus
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body
                $result.MetricsVersion | Should -Be 4
                $sample = @($result.DispatchCostSamples)[0]
                $sample.PSObject.Properties['model'] | Should -Not -BeNullOrEmpty
                $sample.model | Should -Be 'opus'
            }

            It 'model-with-provider: 7-key row (provider at 6, model at 7) round-trips correctly' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s21
        mode: spine
        bytes: 9000
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        provider: anthropic
        model: sonnet
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body
                $sample = @($result.DispatchCostSamples)[0]
                $sample.provider | Should -Be 'anthropic'
                $sample.model | Should -Be 'sonnet'
            }

            It 'same step/mode/provider with different model produces two distinct rows — not collapsed (F fix)' {
                $baseYaml = @'
metrics_version: 4
frame_version: 1
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $baseYaml
                # Add opus row first
                $body = Add-DispatchCostSampleToPrBody -PrBody $body -StepId 's22' -Mode 'spine' -Bytes 8000 -Provider 'anthropic' -Model 'opus'
                # Add sonnet row for same step/mode/provider — must NOT collapse into one row
                $body = Add-DispatchCostSampleToPrBody -PrBody $body -StepId 's22' -Mode 'spine' -Bytes 3000 -Provider 'anthropic' -Model 'sonnet'
                $result = Read-PRMetricsBlock -PrBody $body
                @($result.DispatchCostSamples).Count | Should -Be 2
                $opusRow = @($result.DispatchCostSamples) | Where-Object { $_.model -eq 'opus' }
                $sonnetRow = @($result.DispatchCostSamples) | Where-Object { $_.model -eq 'sonnet' }
                $opusRow.bytes | Should -Be 8000
                $sonnetRow.bytes | Should -Be 3000
            }
        }

        Context 'Context: model field — back-fill preservation (issue #706, B fix)' {

            It 'model is preserved when Update-DispatchCostSampleEvaluationInPrBody back-fills RC on a model-only 6-key row' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s23
        mode: spine
        bytes: 8000
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        model: opus
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $updated = Update-DispatchCostSampleEvaluationInPrBody -PrBody $body -StepId 's23' -Mode 'spine' -RcConformance 'pass'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"
                $normalized | Should -Match 'model: opus'
                $normalized | Should -Match 'rc-conformance: pass'
                $result = Read-PRMetricsBlock -PrBody $updated
                @($result.DispatchCostSamples).Count | Should -Be 1
            }

            It 'model is preserved when Update-DispatchCostSampleEvaluationInPrBody back-fills RC on a 7-key provider+model row' {
                $yaml = @'
metrics_version: 4
frame_version: 1
dispatch-cost-samples:
    - step-id: s24
        mode: spine
        bytes: 9000
        rc-conformance: not-evaluated
        judge-disposition: not-evaluated
        provider: anthropic
        model: opus
credits:
    - port: implement-test
        status: passed
        evidence: "tests passed"
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $updated = Update-DispatchCostSampleEvaluationInPrBody -PrBody $body -StepId 's24' -Mode 'spine' -Provider 'anthropic' -RcConformance 'pass'
                $normalized = ($updated -replace "`r`n", "`n") -replace "`r", "`n"
                $normalized | Should -Match 'provider: anthropic'
                $normalized | Should -Match 'model: opus'
                $normalized | Should -Match 'rc-conformance: pass'
            }
        }
}

Describe 'Get-PortFiles' {

    It 'reads valid port files from the live frame/ports directory and returns objects with Name/Description/Applies/Status' {
        $result = Get-PortFiles -PortsDir $script:LivePortsDir

        $result | Should -Not -BeNullOrEmpty
        @($result).Count | Should -BeGreaterThan 0

        $review = $result | Where-Object { $_.Name -eq 'review' }
        $review | Should -Not -BeNullOrEmpty
        $review.Description | Should -Not -BeNullOrEmpty
        $review.Applies | Should -Be 'always'
        $review.Status | Should -Be 'stable'
    }

    It 'returns an empty array when the ports directory does not exist' {
        $missing = Join-Path $TestDrive 'no-such-ports-dir'
        $result = Get-PortFiles -PortsDir $missing

        # Empty array (not $null) per spec.
        , $result | Should -BeOfType [System.Array]
        @($result).Count | Should -Be 0
    }

    It 'skips a malformed YAML file and still returns the valid ones' {
        $tempPorts = Join-Path $TestDrive 'ports-mixed'
        New-Item -ItemType Directory -Path $tempPorts -Force | Out-Null

        # Valid port.
        @"
name: alpha
description: "First port"
applies: always
status: stable
"@ | Set-Content -Path (Join-Path $tempPorts 'alpha.yaml') -Encoding UTF8

        # Malformed port — unbalanced brackets, bad indentation.
        @"
name: broken
description: "[unbalanced
applies:
  : nope
status: stable
  bad-key
"@ | Set-Content -Path (Join-Path $tempPorts 'broken.yaml') -Encoding UTF8

        # Another valid port.
        @"
name: gamma
description: "Third port"
applies: trigger-conditional
status: experimental
"@ | Set-Content -Path (Join-Path $tempPorts 'gamma.yaml') -Encoding UTF8

        $result = Get-PortFiles -PortsDir $tempPorts

        $names = @($result | ForEach-Object { $_.Name }) | Sort-Object
        $names | Should -Contain 'alpha'
        $names | Should -Contain 'gamma'
        $names | Should -Not -Contain 'broken'
    }

    It 'does not throw when every file in the directory is malformed' {
        $tempPorts = Join-Path $TestDrive 'ports-all-broken'
        New-Item -ItemType Directory -Path $tempPorts -Force | Out-Null

        @"
: only invalid
  [stuff
"@ | Set-Content -Path (Join-Path $tempPorts 'broken.yaml') -Encoding UTF8

        { Get-PortFiles -PortsDir $tempPorts } | Should -Not -Throw
    }
}

Describe 'Resolve-PortStatus' {

    BeforeAll {
        $script:Port = [pscustomobject]@{
            Name        = 'review'
            Description = 'Was the change adversarially reviewed and judged?'
            Applies     = 'always'
            Status      = 'stable'
        }

        $script:AdapterApplies = [pscustomobject]@{
            Name              = 'review-adapter'
            AppliesWhen       = 'always'
            SuggestedNextStep = 'Run /orchestra:review on the PR'
        }

        $script:AdapterApplies2 = [pscustomobject]@{
            Name              = 'review-adapter-secondary'
            AppliesWhen       = 'changeset.touchesReviewableCode()'
            SuggestedNextStep = 'Re-run defense pass'
        }

        $script:AdapterNoneStep = [pscustomobject]@{
            Name              = 'review-adapter'
            AppliesWhen       = 'always'
            SuggestedNextStep = 'none'
        }

        $script:AdapterEmptyStep = [pscustomobject]@{
            Name              = 'review-adapter'
            AppliesWhen       = 'always'
            SuggestedNextStep = ''
        }
    }

    It 'returns Covered/PassedCredit when credit Status is passed' {
        $credit = [pscustomobject]@{ Port = 'review'; Status = 'passed'; Evidence = 'judge: keep' }
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies) `
            -ApplicableMap $map `
            -Credit $credit

        $result.PortName  | Should -Be 'review'
        $result.Status    | Should -Be 'Covered'
        $result.SubReason | Should -Be 'PassedCredit'
        $result.Evidence  | Should -Be 'judge: keep'
    }

    It 'returns Covered/NotApplicableCredit when credit Status is not-applicable' {
        $credit = [pscustomobject]@{ Port = 'review'; Status = 'not-applicable'; Evidence = 'doc-only PR' }
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies) `
            -ApplicableMap $map `
            -Credit $credit

        $result.Status    | Should -Be 'Covered'
        $result.SubReason | Should -Be 'NotApplicableCredit'
    }

    It 'returns Covered/SkippedCredit when credit Status is skipped' {
        $credit = [pscustomobject]@{ Port = 'review'; Status = 'skipped'; Evidence = 'flagged off' }
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies) `
            -ApplicableMap $map `
            -Credit $credit

        $result.Status    | Should -Be 'Covered'
        $result.SubReason | Should -Be 'SkippedCredit'
    }

    It 'returns NotCovered/AdapterFailed when credit Status is failed' {
        $credit = [pscustomobject]@{ Port = 'review'; Status = 'failed'; Evidence = 'judge: revise' }
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies) `
            -ApplicableMap $map `
            -Credit $credit

        $result.Status            | Should -Be 'NotCovered'
        $result.SubReason         | Should -Be 'AdapterFailed'
        $result.AdapterName       | Should -Be 'review-adapter'
        $result.SuggestedNextStep | Should -Be 'Run /orchestra:review on the PR'
    }

    It 'returns NotCovered/MissingAdapter when credit is null but at least one adapter applies' {
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies) `
            -ApplicableMap $map `
            -Credit $null

        $result.Status      | Should -Be 'NotCovered'
        $result.SubReason   | Should -Be 'MissingAdapter'
        $result.AdapterName | Should -Be 'review-adapter'
    }

    It 'returns Covered/AutoNotApplicable (D7) when adapters exist but every adapter is not applicable' {
        $map = @{
            'review-adapter'           = 'false'
            'review-adapter-secondary' = 'false'
        }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies, $script:AdapterApplies2) `
            -ApplicableMap $map `
            -Credit $null

        $result.Status    | Should -Be 'Covered'
        $result.SubReason | Should -Be 'AutoNotApplicable'
    }

    It 'auto-N/A overrides credit: when all adapters are not-applicable the port is Covered/AutoNotApplicable regardless of credit' {
        $credit = [pscustomobject]@{ Port = 'review'; Status = 'failed'; Evidence = 'should be ignored' }
        $map = @{ 'review-adapter' = 'false' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies) `
            -ApplicableMap $map `
            -Credit $credit

        $result.Status    | Should -Be 'Covered'
        $result.SubReason | Should -Be 'AutoNotApplicable'
    }

    It 'returns Inconclusive/InconclusiveCredit when credit Status is inconclusive' {
        $credit = [pscustomobject]@{ Port = 'review'; Status = 'inconclusive'; Evidence = 'partial' }
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies) `
            -ApplicableMap $map `
            -Credit $credit

        $result.Status    | Should -Be 'Inconclusive'
        $result.SubReason | Should -Be 'InconclusiveCredit'
    }

    It 'returns Inconclusive/MissingNextStepField when an applicable adapter has no SuggestedNextStep' {
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterEmptyStep) `
            -ApplicableMap $map `
            -Credit $null

        $result.Status    | Should -Be 'Inconclusive'
        $result.SubReason | Should -Be 'MissingNextStepField'
    }

    It 'returns Inconclusive/AdapterDiscoveryFailed when every adapter has unknown applicability and credit is missing' {
        $map = @{
            'review-adapter'           = 'unknown'
            'review-adapter-secondary' = 'unknown'
        }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterApplies, $script:AdapterApplies2) `
            -ApplicableMap $map `
            -Credit $null

        $result.Status    | Should -Be 'Inconclusive'
        $result.SubReason | Should -Be 'AdapterDiscoveryFailed'
    }

    It "propagates SuggestedNextStep='none' as `$null in the output" {
        $credit = [pscustomobject]@{ Port = 'review'; Status = 'failed'; Evidence = 'fail' }
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($script:AdapterNoneStep) `
            -ApplicableMap $map `
            -Credit $credit

        $result.SuggestedNextStep | Should -BeNullOrEmpty
    }

    # ---------------------------------------------------------------------------
    # Step 10 — Adapter parse-failure reporting (issue #441, Open Question 4)
    # ---------------------------------------------------------------------------

    It 'returns Inconclusive/AdapterParseError when all adapters carry a ParseError field (Step 10)' {
        $brokenAdapter = [pscustomobject]@{
            Name              = '<malformed:standard>'
            Provides          = 'review'
            AppliesWhen       = $null
            SuggestedNextStep = $null
            ParseError        = 'malformed-frontmatter'
        }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($brokenAdapter) `
            -ApplicableMap @{} `
            -Credit $null

        $result.Status    | Should -Be 'Inconclusive'
        $result.SubReason | Should -Be 'AdapterParseError'
        $result.Evidence  | Should -Match '0 parseable adapters'
        $result.Evidence  | Should -Match 'malformed-frontmatter'
    }

    It 'discards parse-error adapters when valid adapters also exist for the same port (Step 10)' {
        $brokenAdapter = [pscustomobject]@{
            Name              = '<malformed:standard>'
            Provides          = 'review'
            AppliesWhen       = $null
            SuggestedNextStep = $null
            ParseError        = 'malformed-frontmatter'
        }

        # $script:AdapterApplies is a valid adapter (no ParseError field)
        $map = @{ 'review-adapter' = 'true' }

        $result = Resolve-PortStatus -Port $script:Port `
            -WorkAdapters @($brokenAdapter, $script:AdapterApplies) `
            -ApplicableMap $map `
            -Credit $null

        # Valid adapter drives the result; parse-error one is discarded
        $result.Status    | Should -Be 'NotCovered'
        $result.SubReason | Should -Be 'MissingAdapter'
    }
}

Describe 'Compose-Comment' {

    BeforeAll {
        $script:Marker = '<!-- frame-credit-ledger-PR-429 -->'
    }

    It 'filters auto-N/A ports out of the table and surfaces them as a footnote count' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'Covered'
                SubReason         = 'PassedCredit'
                AdapterName       = 'review-adapter'
                SuggestedNextStep = $null
                Evidence          = 'judge: keep'
            }
            [pscustomobject]@{
                PortName          = 'design'
                Status            = 'Covered'
                SubReason         = 'AutoNotApplicable'
                AdapterName       = ''
                SuggestedNextStep = $null
                Evidence          = ''
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        $out | Should -Match ([regex]::Escape($script:Marker))
        $out | Should -Match '## Frame credit ledger'
        # Unified table: review appears as a table row.
        $out | Should -Match '\|\s*review\s*\|'
        # Auto-N/A row is NOT rendered as a full table row.
        $out | Should -Not -Match '\|\s*design\s*\|'
        # Auto-N/A count surfaces as a footnote line.
        $out | Should -Match '\(1 ports auto-N/A'
        # No three-section headers.
        $out | Should -Not -Match '### ✅ Covered'
        $out | Should -Not -Match '### ⚠️ Inconclusive'
        $out | Should -Not -Match '### 🚫 Not covered'
    }

    It 'renders all port statuses in a single unified table (no section split)' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'Covered'
                SubReason         = 'PassedCredit'
                AdapterName       = 'review-adapter'
                SuggestedNextStep = $null
                Evidence          = 'judge: keep'
            }
            [pscustomobject]@{
                PortName          = 'implement-test'
                Status            = 'Inconclusive'
                SubReason         = 'InconclusiveCredit'
                AdapterName       = 'test-adapter'
                SuggestedNextStep = 'Re-run pester suite'
                Evidence          = 'flaky'
            }
            [pscustomobject]@{
                PortName          = 'plan'
                Status            = 'NotCovered'
                SubReason         = 'MissingAdapter'
                AdapterName       = 'plan-adapter'
                SuggestedNextStep = 'Re-run /plan'
                Evidence          = ''
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        # All three ports appear in the unified table.
        $out | Should -Match '\|\s*review\s*\|'
        $out | Should -Match '\|\s*implement-test\s*\|'
        $out | Should -Match '\|\s*plan\s*\|'

        # No three-section headers.
        $out | Should -Not -Match '### ✅ Covered'
        $out | Should -Not -Match '### ⚠️ Inconclusive'
        $out | Should -Not -Match '### 🚫 Not covered'

        # Warn-mode footer present.
        $out | Should -Match 'warn'
    }

    It 'renders a table with both Covered and NotCovered rows without section headers' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'Covered'
                SubReason         = 'PassedCredit'
                AdapterName       = 'review-adapter'
                SuggestedNextStep = $null
                Evidence          = ''
            }
            [pscustomobject]@{
                PortName          = 'plan'
                Status            = 'NotCovered'
                SubReason         = 'MissingAdapter'
                AdapterName       = 'plan-adapter'
                SuggestedNextStep = 'Re-run /plan'
                Evidence          = ''
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        $out | Should -Not -Match '### ⚠️ Inconclusive'
        $out | Should -Not -Match '### ✅ Covered'
        $out | Should -Not -Match '### 🚫 Not covered'
        $out | Should -Match '\|\s*review\s*\|'
        $out | Should -Match '\|\s*plan\s*\|'
    }

    It "renders next-step in the Next step column when provided" {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'plan'
                Status            = 'NotCovered'
                SubReason         = 'MissingAdapter'
                AdapterName       = 'plan-adapter'
                SuggestedNextStep = 'Re-run /plan to regenerate'
                Evidence          = ''
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        $out | Should -Match 'Re-run /plan to regenerate'
    }

    It "renders empty next-step cell when SuggestedNextStep is null" {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'plan'
                Status            = 'NotCovered'
                SubReason         = 'MissingAdapter'
                AdapterName       = 'plan-adapter'
                SuggestedNextStep = $null
                Evidence          = ''
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        # Table row for plan is present.
        $out | Should -Match '\|\s*plan\s*\|'
        # No "Suggested next step" label (old format) — just empty column.
        $out | Should -Not -Match '(?i)suggested next step'
    }

    It 'renders AdapterParseError as a table row surfacing the 0-parseable-adapters evidence (Step 10)' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'Inconclusive'
                SubReason         = 'AdapterParseError'
                AdapterName       = ''
                SuggestedNextStep = $null
                Evidence          = '0 parseable adapters (parse error: malformed-frontmatter)'
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        # Port row appears in the unified table.
        $out | Should -Match '\|\s*review\s*\|'
        # Evidence text flows into the table row.
        $out | Should -Match '0 parseable adapters'
        # No separate section headers (D2 single-shape parity).
        $out | Should -Not -Match '### ✅ Covered'
        $out | Should -Not -Match '### 🚫 Not covered'
    }

    It 'renders OverriddenCredit as 🔓 overridden (not ❓ OverriddenCredit) — M3 fix' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'Covered'
                SubReason         = 'OverriddenCredit'
                AdapterName       = ''
                SuggestedNextStep = $null
                Evidence          = 'override: authorized self-override posted in PR 429 comment'
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        $out | Should -Match '🔓'
        $out | Should -Match 'overridden'
        $out | Should -Not -Match '❓'
        $out | Should -Not -Match 'OverriddenCredit'
    }

    It 'renders warn-mode footer when Mode is warn (default) — M4' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'Covered'
                SubReason         = 'PassedCredit'
                AdapterName       = 'review-adapter'
                SuggestedNextStep = $null
                Evidence          = ''
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        $out | Should -Match 'warn'
        $out | Should -Not -Match 'enforce mode'
    }

    It 'renders enforce-mode footer (not blocked) when Mode is enforce and HasBlock is false — M4' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'Covered'
                SubReason         = 'PassedCredit'
                AdapterName       = 'review-adapter'
                SuggestedNextStep = $null
                Evidence          = ''
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports -Mode 'enforce' -HasBlock $false

        $out | Should -Match 'enforce'
        $out | Should -Match 'passed'
        $out | Should -Not -Match 'PR creation was not blocked'
    }

    It 'renders enforce-mode footer (blocked) when Mode is enforce and HasBlock is true — M4' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'NotCovered'
                SubReason         = 'MissingAdapter'
                AdapterName       = ''
                SuggestedNextStep = 'Run /review'
                Evidence          = ''
            }
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports -Mode 'enforce' -HasBlock $true

        $out | Should -Match 'enforce'
        $out | Should -Match 'blocked'
        $out | Should -Not -Match 'PR creation was not blocked'
    }
}

Describe 'Compose-PreV4ShortCircuitComment' {

    It 'returns the canonical pre-v4 short-circuit text with all required substrings' {
        $marker = '<!-- frame-credit-ledger-PR-429 -->'
        $out = Compose-PreV4ShortCircuitComment -MarkerToken $marker

        $out | Should -Not -BeNullOrEmpty
        $out | Should -Match ([regex]::Escape($marker))
        $out | Should -Match 'pre-v4 metrics detected'
        $out | Should -Match 'metrics_version: 4'
        $out | Should -Match 'frame/pipeline-metrics-v4-schema.md'
        $out | Should -Match '(?i)warn'
    }
}

Describe 'Compose-ParseErrorShortCircuitComment (C-Behavior-1: distinct branch from pre-v4)' {

    It 'renders parse-error-specific text (NOT the pre-v4 phrasing) and surfaces the parser reason' {
        $marker = '<!-- frame-credit-ledger-PR-429 -->'
        $reason = 'Marker block contains malformed YAML (empty key, missing colon, or unterminated quoted value).'
        $out = Compose-ParseErrorShortCircuitComment -MarkerToken $marker -Reason $reason

        $out | Should -Not -BeNullOrEmpty
        $out | Should -Match ([regex]::Escape($marker))
        # The parse-error branch must NOT misrepresent itself as pre-v4.
        $out | Should -Not -Match 'pre-v4 metrics detected'
        # It must clearly say the block could not be parsed.
        $out | Should -Match 'pipeline-metrics block could not be parsed'
        # The parser reason is surfaced verbatim so operators can act on it.
        $out | Should -Match ([regex]::Escape($reason))
        $out | Should -Match '(?i)warn'
    }
}

Describe 'Compose-MissingMetricsShortCircuitComment (C-Behavior-1: distinct branch from pre-v4)' {

    It 'renders missing-marker-specific text (NOT the pre-v4 or parse-error phrasing)' {
        $marker = '<!-- frame-credit-ledger-PR-429 -->'
        $out = Compose-MissingMetricsShortCircuitComment -MarkerToken $marker -IsOrchestrated $true

        $out | Should -Not -BeNullOrEmpty
        $out | Should -Match ([regex]::Escape($marker))
        # The missing-marker branch must NOT misrepresent itself as either
        # of the other two non-v4 shapes.
        $out | Should -Not -Match 'pre-v4 metrics detected'
        $out | Should -Not -Match 'could not be parsed'
        # It must clearly say no marker block was found.
        $out | Should -Match 'no pipeline-metrics block found'
        # Suggested next step still points operators at the v4 schema.
        $out | Should -Match 'frame/pipeline-metrics-v4-schema.md'
        $out | Should -Match '(?i)warn'
    }
}

# ---------------------------------------------------------------------------
# Issue #769 — Origin-gated 3-state taxonomy
# Tests: Compose-MissingMetricsShortCircuitComment renders 🛑 FAILED for
# orchestrated-origin and "not measured (non-orchestrated)" for non-orchestrated.
# ---------------------------------------------------------------------------
Describe 'Compose-MissingMetricsShortCircuitComment — origin-gated taxonomy (issue #769 AC3)' {

    It 'IsOrchestrated=$true renders 🛑 FAILED heading and never "not measured"' {
        $marker = '<!-- frame-credit-ledger-PR-769 -->'
        $out = Compose-MissingMetricsShortCircuitComment -MarkerToken $marker -IsOrchestrated $true

        $out | Should -Not -BeNullOrEmpty
        $out | Should -Match ([regex]::Escape($marker))
        $out | Should -Match '🛑'
        $out | Should -Match 'FAILED'
        $out | Should -Match 'no pipeline-metrics block found'
        $out | Should -Not -Match 'non-orchestrated'
        $out | Should -Not -Match 'not measured'
    }

    It 'IsOrchestrated=$false renders "not measured (non-orchestrated)" and never 🛑 FAILED' {
        $marker = '<!-- frame-credit-ledger-PR-769 -->'
        $out = Compose-MissingMetricsShortCircuitComment -MarkerToken $marker -IsOrchestrated $false

        $out | Should -Not -BeNullOrEmpty
        $out | Should -Match ([regex]::Escape($marker))
        $out | Should -Match 'not measured \(non-orchestrated\)'
        $out | Should -Not -Match '🛑'
        $out | Should -Not -Match 'FAILED'
    }
}

Describe 'Compose-MissingMetricsShortCircuitComment — default IsOrchestrated is $false (P2-F4 fix)' {

    It 'default call (no -IsOrchestrated arg) renders not-measured (default is now $false)' {
        $marker = '<!-- frame-credit-ledger-PR-pf4 -->'
        $result = Compose-MissingMetricsShortCircuitComment -MarkerToken $marker

        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match ([regex]::Escape($marker))
        $result | Should -Match 'non-orchestrated'
        $result | Should -Not -Match '🛑'
        $result | Should -Not -Match 'FAILED'
    }
}

# ---------------------------------------------------------------------------
# Issue #441 Step 3 — v4 extended schema parser tests (RED until GREEN lands)
# Tests: status:not-persisted, per-port fields, run_index, mode.synthetic-backfill,
#        and last-wins-by-run_index selection.
# ---------------------------------------------------------------------------

Describe 'Read-PRMetricsBlock v4 extended fields (issue #441)' {

    BeforeAll {
        $script:V4NotPersistedYaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: not-persisted
    run_index: 1
    evidence: "Sentinel present but no credit row written."
'@

        $script:V4PerPortFieldsYaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: passed
    run_index: 1
    evidence: "judge ruling: keep"
  - port: release-hygiene
    adapter: symmetric-bump
    status: passed
    run_index: 1
    evidence: "all four manifest files bumped."
  - port: post-fix-review
    adapter: post-fix
    status: not-applicable
    run_index: 1
    evidence: "trigger absent"
'@

        $script:V4SyntheticBackfillYaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: not-persisted
    run_index: 1
    evidence: "Backfill row."
    mode_backfilled_at: "2026-05-01T00:00:00Z"
    mode_original_pr_merged_at: "2025-03-15T12:34:56Z"
'@

        $script:V4MultiRunYaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: passed
    run_index: 1
    evidence: "first run"
  - port: review
    adapter: standard
    status: failed
    run_index: 2
    evidence: "second run"
  - port: release-hygiene
    adapter: symmetric-bump
    status: passed
    run_index: 1
    evidence: "only run"
'@
    }

    It 'parses status:not-persisted as a valid credit status' {
        $body = & $script:NewV4PrBody -Yaml $script:V4NotPersistedYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 4
        $credit = $result.Credits | Where-Object { $_.Port -eq 'review' }
        $credit | Should -Not -BeNullOrEmpty
        $credit.Status | Should -Be 'not-persisted'
    }

    It 'parses the adapter field on credit rows' {
        $body = & $script:NewV4PrBody -Yaml $script:V4PerPortFieldsYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $reviewCredit = $result.Credits | Where-Object { $_.Port -eq 'review' }
        $reviewCredit | Should -Not -BeNullOrEmpty
        $reviewCredit.Adapter | Should -Be 'standard'

        $rhCredit = $result.Credits | Where-Object { $_.Port -eq 'release-hygiene' }
        $rhCredit | Should -Not -BeNullOrEmpty
        $rhCredit.Adapter | Should -Be 'symmetric-bump'
    }

    It 'parses run_index as an integer on credit rows' {
        $body = & $script:NewV4PrBody -Yaml $script:V4PerPortFieldsYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $reviewCredit = $result.Credits | Where-Object { $_.Port -eq 'review' }
        $reviewCredit | Should -Not -BeNullOrEmpty
        $reviewCredit.RunIndex | Should -Be 1
        $reviewCredit.RunIndex | Should -BeOfType [int]
    }

    It 'parses mode_backfilled_at and mode_original_pr_merged_at from credit rows' {
        $body = & $script:NewV4PrBody -Yaml $script:V4SyntheticBackfillYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $credit = $result.Credits | Where-Object { $_.Port -eq 'review' }
        $credit | Should -Not -BeNullOrEmpty
        $credit.ModeBackfilledAt | Should -Be '2026-05-01T00:00:00Z'
        $credit.ModeOriginalPrMergedAt | Should -Be '2025-03-15T12:34:56Z'
    }

    # -------------------------------------------------------------------------
    # Nested-field parsing (issue #441 follow-up — Gemini findings 2 + 5)
    # -------------------------------------------------------------------------
    # Real PR bodies emit credit metadata using the nested form documented in
    # frame/pipeline-metrics-v4-schema.md (e.g. mode.synthetic-backfill,
    # judge-score, integrity-check, version-bump, symmetric-bump-verification).
    # The flat-key fallback is kept for backward compatibility; the nested form
    # must round-trip cleanly through Read-PRMetricsBlock.

    It 'parses nested mode.synthetic-backfill keys (real-PR schema shape)' {
        $nestedYaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: passed
    run_index: 1
    evidence: "review credit"
    mode:
      synthetic-backfill:
        backfilled_at: 2026-05-01T00:00:00Z
        original_pr_merged_at: 2026-04-25T00:26:35Z
'@
        $body = & $script:NewV4PrBody -Yaml $nestedYaml
        $result = Read-PRMetricsBlock -PrBody $body
        $credit = $result.Credits | Where-Object { $_.Port -eq 'review' }
        $credit | Should -Not -BeNullOrEmpty
        $credit.ModeBackfilledAt | Should -Be '2026-05-01T00:00:00Z'
        $credit.ModeOriginalPrMergedAt | Should -Be '2026-04-25T00:26:35Z'
    }

    It 'parses judge-score sub-block on a credit row (Gemini Finding 2)' {
        $yaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: passed
    run_index: 1
    evidence: "review credit"
    judge-score:
      findings_sustained: 3
      prosecutor_points: 20
      defense_points: 0
'@
        $body = & $script:NewV4PrBody -Yaml $yaml
        $result = Read-PRMetricsBlock -PrBody $body
        $credit = $result.Credits | Where-Object { $_.Port -eq 'review' }
        $credit.JudgeScore | Should -Not -BeNullOrEmpty
        $credit.JudgeScore.findings_sustained | Should -Be '3'
        $credit.JudgeScore.prosecutor_points  | Should -Be '20'
        $credit.JudgeScore.defense_points     | Should -Be '0'
    }

    It 'parses integrity-check scalar field on a credit row (Gemini Finding 2)' {
        $yaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: passed
    run_index: 1
    evidence: "review credit"
    integrity-check: pass
'@
        $body = & $script:NewV4PrBody -Yaml $yaml
        $result = Read-PRMetricsBlock -PrBody $body
        $credit = $result.Credits | Where-Object { $_.Port -eq 'review' }
        $credit.IntegrityCheck | Should -Be 'pass'
    }

    It 'parses version-bump and symmetric-bump-verification fields on release-hygiene credit' {
        $yaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: release-hygiene
    adapter: symmetric-bump
    status: passed
    run_index: 1
    evidence: "version bump 2.7.0 to 2.8.0"
    version-bump: 2.7.0 to 2.8.0
    symmetric-bump-verification: passed
'@
        $body = & $script:NewV4PrBody -Yaml $yaml
        $result = Read-PRMetricsBlock -PrBody $body
        $credit = $result.Credits | Where-Object { $_.Port -eq 'release-hygiene' }
        $credit.VersionBump | Should -Be '2.7.0 to 2.8.0'
        $credit.SymmetricBumpVerificationStatus | Should -Be 'passed'
    }

    It 'splits per-credit chunks correctly (each credit gets only its own nested fields)' {
        $yaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: review
    adapter: standard
    status: passed
    run_index: 1
    evidence: "review credit"
    judge-score:
      findings_sustained: 1
  - port: release-hygiene
    adapter: symmetric-bump
    status: passed
    run_index: 1
    evidence: "release-hygiene credit"
    version-bump: 2.7.0 to 2.8.0
'@
        $body = & $script:NewV4PrBody -Yaml $yaml
        $result = Read-PRMetricsBlock -PrBody $body

        $review = $result.Credits | Where-Object { $_.Port -eq 'review' }
        $rh = $result.Credits | Where-Object { $_.Port -eq 'release-hygiene' }

        # Review carries judge-score but NOT version-bump.
        $review.JudgeScore | Should -Not -BeNullOrEmpty
        $review.VersionBump | Should -BeNullOrEmpty

        # Release-hygiene carries version-bump but NOT judge-score.
        $rh.VersionBump | Should -Be '2.7.0 to 2.8.0'
        $rh.JudgeScore | Should -BeNullOrEmpty
    }

    # -------------------------------------------------------------------------
    # Defensive guard (Gemini Finding 1)
    # -------------------------------------------------------------------------

    It 'Resolve-NotPersistedSynthesis returns null when MetricsBlock is null' {
        $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $null -Comments @(
            [pscustomobject]@{ body = '<!-- review-judge-produced-99 -->' }
        )
        $result | Should -BeNullOrEmpty
    }

    It 'Resolve-NotPersistedSynthesis returns null when MetricsBlock is parse-error' {
        $parseError = [pscustomobject]@{ MetricsVersion = 'parse-error'; Reason = 'malformed' }
        $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $parseError -Comments @(
            [pscustomobject]@{ body = '<!-- review-judge-produced-99 -->' }
        )
        $result | Should -BeNullOrEmpty
    }

    It 'Resolve-NotPersistedSynthesis returns null when MetricsBlock is pre-v4' {
        $preV4 = [pscustomobject]@{ MetricsVersion = 'pre-v4' }
        $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $preV4 -Comments @(
            [pscustomobject]@{ body = '<!-- review-judge-produced-99 -->' }
        )
        $result | Should -BeNullOrEmpty
    }

    It 'Resolve-NotPersistedSynthesis tolerates MetricsBlock without a Credits property under strict mode' {
        # A v4 metrics block missing the Credits property must not throw
        # PropertyNotFoundException — instead, treat as no existing review credit.
        $skinnyV4 = [pscustomobject]@{ MetricsVersion = 4; FrameVersion = 1 }  # No Credits
        $comments = @(
            [pscustomobject]@{ body = '<!-- review-judge-produced-99 -->'; url = 'https://example/c1' }
        )
        $result = Resolve-NotPersistedSynthesis -PrNumber 99 -MetricsBlock $skinnyV4 -Comments $comments
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'not-persisted'
    }

    # -------------------------------------------------------------------------
    # Markdown table newline escape (Gemini Finding 4)
    # -------------------------------------------------------------------------

    It 'Compose-Comment escapes literal newlines in evidence to <br> so table rows survive' {
        $reports = @(
            [pscustomobject]@{
                PortName          = 'review'
                Status            = 'NotApplicable'
                SubReason         = 'PassedCredit'
                Evidence          = "first line`nsecond line`r`nthird line"
                SuggestedNextStep = $null
            }
        )
        $output = Compose-Comment -MarkerToken 'frame-credit-ledger-99' -PortReports $reports
        # Both \n and \r\n should be replaced with <br> so the row is a single Markdown line.
        $output | Should -Match 'first line<br>second line<br>third line'
        $output | Should -Not -Match "first line`nsecond line"
    }

    It 'Select-LastCreditByRunIndex: when multiple credits exist for same (port, adapter), returns the one with the highest run_index' {
        $body = & $script:NewV4PrBody -Yaml $script:V4MultiRunYaml
        $result = Read-PRMetricsBlock -PrBody $body

        # There are two review/standard entries; run_index 2 wins.
        $reviewCredits = @($result.Credits | Where-Object { $_.Port -eq 'review' -and $_.Adapter -eq 'standard' })
        $reviewCredits.Count | Should -BeGreaterThan 1

        $latest = Select-LastCreditByRunIndex -Credits $result.Credits -Port 'review' -Adapter 'standard'
        $latest | Should -Not -BeNullOrEmpty
        $latest.RunIndex | Should -Be 2
        $latest.Status | Should -Be 'failed'
    }

    It 'Select-LastCreditByRunIndex: returns the single entry when only one run exists' {
        $body = & $script:NewV4PrBody -Yaml $script:V4PerPortFieldsYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $latest = Select-LastCreditByRunIndex -Credits $result.Credits -Port 'release-hygiene' -Adapter 'symmetric-bump'
        $latest | Should -Not -BeNullOrEmpty
        $latest.RunIndex | Should -Be 1
        $latest.Status | Should -Be 'passed'
    }

    It 'Select-LastCreditByRunIndex: returns $null when no matching (port, adapter) entry exists' {
        $body = & $script:NewV4PrBody -Yaml $script:V4PerPortFieldsYaml
        $result = Read-PRMetricsBlock -PrBody $body

        $latest = Select-LastCreditByRunIndex -Credits $result.Credits -Port 'nonexistent' -Adapter 'none'
        $latest | Should -BeNullOrEmpty
    }

        It 'Select-AuthoritativeCreditForPort: reports the latest terminal-step failed row over an earlier passed row for the same port' {
                $yaml = @'
metrics_version: 4
frame_version: 1
credits:
    - port: implement-test
        status: passed
        terminal-step-id: 3
        evidence: "earlier terminal cycle passed"
    - port: implement-test
        status: failed
        terminal-step-id: 5
        evidence: "terminal cycle failed"
integrity_checks:
    - check: marker-presence
        status: passed
'@
                $body = & $script:NewV4PrBody -Yaml $yaml
                $result = Read-PRMetricsBlock -PrBody $body

                $credit = Select-AuthoritativeCreditForPort -Credits $result.Credits -Port 'implement-test'

                $credit | Should -Not -BeNullOrEmpty
                $credit.Status | Should -Be 'failed'
                $credit.TerminalStepId | Should -Be 5
                $credit.Evidence | Should -Be 'terminal cycle failed'
        }
}

# ---------------------------------------------------------------------------
# issue #739 s2 — New-PipelineMetricsV4Block builder tests
# ---------------------------------------------------------------------------
Describe 'New-PipelineMetricsV4Block (issue #739 s2 — AC1)' {

    # Test 1: basic happy path
    It 'happy path: produces a single pipeline-metrics block with metrics_version: 4, frame_version: 1, and credit row' {
        $credit = @{ port = 'experience'; adapter = 'work-adapter'; evidence = 'test-evidence' }

        $block = New-PipelineMetricsV4Block `
            -V3BaseYaml "pr_number: 42`nschema_version: 2" `
            -Credits @($credit)

        $block | Should -Not -BeNullOrEmpty
        # Exactly one HTML-comment block opener and closer
        $openerPattern = [regex]::Escape('<!-- pipeline-metrics')
        ($block | Select-String $openerPattern -AllMatches).Matches.Count | Should -Be 1
        ($block | Select-String '(?m)^-->' -AllMatches).Matches.Count | Should -Be 1
        # Required v4 fields present
        $block | Should -Match '(?m)^metrics_version:\s*4\s*$'
        $block | Should -Match '(?m)^frame_version:\s*1\s*$'
        # Base YAML preserved
        $block | Should -Match 'pr_number: 42'
        # Credit row present
        $block | Should -Match 'port: experience'
        $block | Should -Match 'adapter: work-adapter'
        $block | Should -Match 'evidence: test-evidence'
    }

    # Test 2: escaping — evidence containing -->
    It 'escaping: evidence containing --> does not appear as raw --> outside the closing tag' {
        $credit = @{ port = 'review'; adapter = 'standard'; evidence = 'see comment --> important' }

        $block = New-PipelineMetricsV4Block `
            -V3BaseYaml 'pr_number: 100' `
            -Credits @($credit)

        # The closing --> must be the LAST occurrence; the body must not contain a raw --> before it
        $normalized = $block -replace "`r`n", "`n" -replace "`r", "`n"
        $lines = $normalized -split "`n"

        # Find the line that is the closing -->
        $closingIdx = -1
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i].Trim() -eq '-->') {
                $closingIdx = $i
                break
            }
        }
        $closingIdx | Should -BeGreaterThan 0 -Because 'closing --> must be present'

        # No --> in any line before the closing tag
        for ($i = 0; $i -lt $closingIdx; $i++) {
            $lines[$i] | Should -Not -Match '-->'
        }
    }

    # Test 3: YAML quoting — credit evidence value containing ':'
    It 'quoting: credit evidence containing colon survives Read-PRMetricsBlock Get-FCLScalar without truncation' {
        $evidenceWithColon = 'judge ruling: keep — no changes required'
        $credit = @{ port = 'review'; adapter = 'standard'; evidence = $evidenceWithColon }

        $block = New-PipelineMetricsV4Block `
            -V3BaseYaml 'pr_number: 99' `
            -Credits @($credit)

        # Wrap in a PR body and round-trip through Read-PRMetricsBlock
        $prBody = "## PR`n`n$block`n`nMore text."
        $parsed = Read-PRMetricsBlock -PrBody $prBody

        $parsed.MetricsVersion | Should -Be 4
        $reviewCredit = @($parsed.Credits) | Where-Object { $_.Port -eq 'review' }
        $reviewCredit | Should -Not -BeNullOrEmpty
        $reviewCredit.Evidence | Should -Be $evidenceWithColon -Because 'colon-containing evidence must round-trip without truncation'
    }

    # Test 4: initial-creation-only guard — ExistingPRBody with v4 block throws
    It 'initial-creation-only guard: calling with ExistingPRBody containing a v4 block throws the expected error' {
        $existingV4Body = "## PR`n`n<!-- pipeline-metrics`npr_number: 1`nmetrics_version: 4`nframe_version: 1`n-->`n"

        {
            New-PipelineMetricsV4Block `
                -V3BaseYaml 'pr_number: 1' `
                -ExistingPRBody $existingV4Body
        } | Should -Throw -ExpectedMessage '*already has a v4 pipeline-metrics block*'
    }

    # Test 4b: initial-creation-only guard bypass with -Force
    It 'initial-creation-only guard: -Force bypasses the existing-v4-block check' {
        $existingV4Body = "## PR`n`n<!-- pipeline-metrics`npr_number: 1`nmetrics_version: 4`nframe_version: 1`n-->`n"

        {
            New-PipelineMetricsV4Block `
                -V3BaseYaml 'pr_number: 1' `
                -ExistingPRBody $existingV4Body `
                -Force
        } | Should -Not -Throw
    }

    # Test 5: double-wrap guard — V3BaseYaml containing <!-- pipeline-metrics throws
    It 'double-wrap guard: V3BaseYaml already containing <!-- pipeline-metrics throws' {
        $yamlWithOpener = '<!-- pipeline-metrics-->pr_number: 5'
        {
            New-PipelineMetricsV4Block -V3BaseYaml $yamlWithOpener
        } | Should -Throw -ExpectedMessage '*already contains a <!-- pipeline-metrics*'
    }

    # Test 5b: metrics_version: 4 in V3BaseYaml is stripped (not thrown); block resolves as v4
    It 'double-wrap guard: V3BaseYaml containing metrics_version: 4 is stripped; block resolves as v4' {
        $yamlWithV4 = "pr_number: 5`nmetrics_version: 4"
        $block = New-PipelineMetricsV4Block -V3BaseYaml $yamlWithV4

        $mvMatches = [regex]::Matches($block, '(?m)^\s*metrics_version\s*:')
        $mvMatches.Count | Should -Be 1

        $prBody = "## PR`n`n$block"
        $parsed = Read-PRMetricsBlock -PrBody $prBody
        $parsed.MetricsVersion | Should -Be '4'
    }

    # Test 6: round-trip text-anchor — every scalar field emitted by the builder
    # is recoverable by Read-PRMetricsBlock
    It 'round-trip text-anchor: scalar credit fields and dispatch-cost-sample fields survive Read-PRMetricsBlock' {
        $credit = @{
            port     = 'implement-code'
            adapter  = 'skills/implementation-discipline/adapters/implement-code-adapter.md'
            status   = 'passed'
            run_index = '1'
            evidence = 'Pester suite passed: 94/94'
        }
        $sample = @{
            'step-id'           = 's2'
            mode                = 'spine'
            bytes               = '8192'
            'rc-conformance'    = 'pass'
            'judge-disposition' = 'accepted'
        }

        $block = New-PipelineMetricsV4Block `
            -V3BaseYaml "pr_number: 739`nschema_version: 2" `
            -Credits @($credit) `
            -DispatchCostSamples @($sample)

        $prBody = "## PR body`n`n$block`n`nMore text."
        $parsed = Read-PRMetricsBlock -PrBody $prBody

        # Scalar v4 fields
        $parsed.MetricsVersion | Should -Be 4
        $parsed.FrameVersion   | Should -Be 1

        # Credit round-trip
        $parsedCredit = @($parsed.Credits) | Where-Object { $_.Port -eq 'implement-code' }
        $parsedCredit | Should -Not -BeNullOrEmpty
        $parsedCredit.Adapter  | Should -Be $credit['adapter']
        $parsedCredit.Status   | Should -Be $credit['status']
        $parsedCredit.RunIndex | Should -Be 1
        $parsedCredit.Evidence | Should -Be $credit['evidence']

        # Dispatch-cost-sample round-trip
        $parsedSample = @($parsed.DispatchCostSamples) | Where-Object { $_.'step-id' -eq 's2' }
        $parsedSample | Should -Not -BeNullOrEmpty
        $parsedSample.mode               | Should -Be 'spine'
        $parsedSample.bytes              | Should -Be 8192
        $parsedSample.'rc-conformance'   | Should -Be 'pass'
        $parsedSample.'judge-disposition' | Should -Be 'accepted'
    }

    # Test 7: empty Credits and DispatchCostSamples — no credits: or dispatch-cost-samples: section emitted
    It 'omits credits: and dispatch-cost-samples: sections when both arrays are empty' {
        $block = New-PipelineMetricsV4Block -V3BaseYaml 'pr_number: 1'

        $block | Should -Not -Match '(?m)^credits:\s*$'
        $block | Should -Not -Match '(?m)^dispatch-cost-samples:\s*$'
    }

    # Test 8: dispatch-cost-samples round-trip with optional provider field
    It 'dispatch-cost-sample with provider field round-trips through Read-PRMetricsBlock' {
        $sample = @{
            'step-id'           = 's3'
            mode                = 'spine'
            bytes               = '4096'
            'rc-conformance'    = 'not-evaluated'
            'judge-disposition' = 'not-evaluated'
            provider            = 'claude'
        }

        $block = New-PipelineMetricsV4Block `
            -V3BaseYaml 'pr_number: 1' `
            -DispatchCostSamples @($sample)

        $prBody = "## PR`n`n$block`n`nMore."
        $parsed = Read-PRMetricsBlock -PrBody $prBody
        $parsedSample = @($parsed.DispatchCostSamples) | Where-Object { $_.'step-id' -eq 's3' }
        $parsedSample.provider | Should -Be 'claude'
    }

    # Test 9: pscustomobject credits (Build-*CreditRow returns pscustomobject, not hashtable)
    It 'accepts pscustomobject credits as returned by Build-*CreditRow functions' {
        $psoCredit = [pscustomobject]@{
            port     = 'implement-code'
            adapter  = 'skills/implementation-discipline/adapters/implement-code-adapter.md'
            status   = 'passed'
            evidence = 'Integration round-trip test'
        }

        # Should not throw — pscustomobject is normalized to hashtable internally
        $block = New-PipelineMetricsV4Block -V3BaseYaml 'pr_number: 1' -Credits @($psoCredit)

        $block | Should -Not -BeNullOrEmpty
        $parsed = Read-PRMetricsBlock -PrBody "## PR`n`n$block`n`nEnd."
        $parsed.MetricsVersion | Should -Be 4
        $parsedCredit = @($parsed.Credits) | Where-Object { $_.Port -eq 'implement-code' }
        $parsedCredit | Should -Not -BeNullOrEmpty
        $parsedCredit.Evidence | Should -Be 'Integration round-trip test'
    }

    # Test 10: both-quote round-trip — value with ' and " survives Read-PRMetricsBlock losslessly
    It 'round-trip: evidence containing both single-quote and double-quote round-trips losslessly' {
        $evidence = "it's a ""quoted"" value: confirmed"
        $credit = @{ port = 'implement-code'; status = 'passed'; evidence = $evidence }

        $block  = New-PipelineMetricsV4Block -V3BaseYaml 'pr_number: 1' -Credits @($credit)
        $parsed = Read-PRMetricsBlock -PrBody "## PR`n`n$block`n`nEnd."
        $parsedCredit = @($parsed.Credits) | Where-Object { $_.Port -eq 'implement-code' }
        $parsedCredit.Evidence | Should -Be $evidence
    }

    # Test 11: newline in evidence — folded to space; block still reads as v4
    It 'round-trip: evidence with embedded newline is folded to space and block remains v4' {
        $credit = @{ port = 'implement-code'; status = 'passed'; evidence = "first line`nsecond line" }

        $block  = New-PipelineMetricsV4Block -V3BaseYaml 'pr_number: 1' -Credits @($credit)
        $parsed = Read-PRMetricsBlock -PrBody "## PR`n`n$block`n`nEnd."
        $parsed.MetricsVersion | Should -Be 4
        $parsedCredit = @($parsed.Credits) | Where-Object { $_.Port -eq 'implement-code' }
        $parsedCredit | Should -Not -BeNullOrEmpty
        $parsedCredit.Evidence | Should -Be 'first line second line'
    }

    # Test 12: v3 base containing --> is escaped so the HTML comment does not close early
    It 'v3-base with --> is escaped; block still reads as v4' {
        $credit = @{ port = 'review'; status = 'passed'; evidence = 'ok' }
        $block  = New-PipelineMetricsV4Block `
            -V3BaseYaml "pr_number: 1`nnote: see --> here in base" `
            -Credits @($credit)

        $parsed = Read-PRMetricsBlock -PrBody "## PR`n`n$block`n`nEnd."
        $parsed.MetricsVersion | Should -Be 4
    }

    # Test 13 (CR4 regression): v3 base containing metrics_version: 3 — builder strips it; block round-trips as v4
    It 'CR4 regression: v3 base containing metrics_version: 3 — builder strips it; block round-trips as v4' {
        $v3Base = "pr_number: 99`nmetrics_version: 3`nframe_version: 1`n"
        $credit = @{ port = 'implement-code'; status = 'passed'; evidence = 'Pester suite passed' }
        $block = New-PipelineMetricsV4Block -V3BaseYaml $v3Base -Credits @($credit) -DispatchCostSamples @()
        $prBody = "## Pipeline Metrics`n`n$block"

        # Only ONE metrics_version line in the output
        $mvMatches = [regex]::Matches($block, '(?m)^\s*metrics_version\s*:')
        $mvMatches.Count | Should -Be 1

        # Reader resolves 4, not 3
        $parsed = Read-PRMetricsBlock -PrBody $prBody
        $parsed | Should -Not -BeNullOrEmpty
        $parsed.MetricsVersion | Should -Be '4'

        # Full validation passes
        $validation = Test-PipelineMetricsV4Block -PRBody $prBody
        $validation.Valid | Should -Be $true
    }
}

# ===========================================================================
# Test-PipelineMetricsV4Block (issue #739 s3 — AC2, AC3)
# ===========================================================================
Describe 'Test-PipelineMetricsV4Block' {

    BeforeAll {
        # Scriptblock helper: build a minimal valid v4 PR body with one credit entry.
        # Stored as a script-scoped scriptblock so It-blocks can call it via & $script:BuildV4Body.
        $script:BuildV4Body = {
            param(
                [string]$CreditsYaml = "  - port: implement-code`n    status: passed`n    evidence: Pester suite passed"
            )
            $yaml = "pr_number: 739`nmetrics_version: 4`nframe_version: 1`ncredits:`n$CreditsYaml"
            return "## Summary`n`n<!-- pipeline-metrics`n$yaml`n-->`n`nMore text."
        }
    }

    # Test 1: Happy path — valid v4 body with 1 credit → Valid=$true, DetectedMarkerCount=1
    It 'happy path: valid v4 block with 1 credit returns Valid=$true and DetectedMarkerCount=1' {
        $body = & $script:BuildV4Body
        $result = Test-PipelineMetricsV4Block -PRBody $body

        $result.Valid               | Should -Be $true
        $result.DetectedMarkerCount | Should -Be 1
        $result.FailureReason       | Should -BeNullOrEmpty
    }

    # Test 2: Wrong version fails — metrics_version: 3 → Valid=$false, FailureReason mentions version
    It 'wrong version: metrics_version: 3 returns Valid=$false with FailureReason mentioning version' {
        $yaml = "pr_number: 739`nmetrics_version: 3`ncredits:`n  - port: implement-code`n    status: passed`n    evidence: test"
        $body = "## Summary`n`n<!-- pipeline-metrics`n$yaml`n-->`n"

        $result = Test-PipelineMetricsV4Block -PRBody $body

        $result.Valid         | Should -Be $false
        $result.FailureReason | Should -Not -BeNullOrEmpty
        # FailureReason should mention something about version not being 4
        $result.FailureReason | Should -Match 'pre-v4|version|not 4'
    }

    # Test 3: Multi-marker fails — two non-fenced pipeline-metrics blocks → Valid=$false, DetectedMarkerCount=2
    It 'multi-marker: two non-fenced pipeline-metrics blocks returns Valid=$false and DetectedMarkerCount=2' {
        $yaml = "pr_number: 739`nmetrics_version: 4`nframe_version: 1`ncredits:`n  - port: implement-code`n    status: passed`n    evidence: test"
        $block = "<!-- pipeline-metrics`n$yaml`n-->"
        # Two separate blocks in the body (both non-fenced)
        $body = "## Summary`n`n$block`n`nSome text.`n`n$block`n`nEnd."

        $result = Test-PipelineMetricsV4Block -PRBody $body

        $result.Valid               | Should -Be $false
        $result.DetectedMarkerCount | Should -Be 2
    }

    # Test 4: Fenced marker excluded — one real block + one inside triple-backtick fence
    #   → still DetectedMarkerCount=1 (the fenced one doesn't count)
    It 'fenced marker excluded: pipeline-metrics inside a code fence is not counted' {
        $yaml = "pr_number: 739`nmetrics_version: 4`nframe_version: 1`ncredits:`n  - port: implement-code`n    status: passed`n    evidence: test"
        $realBlock = "<!-- pipeline-metrics`n$yaml`n-->"
        # Fenced documentation example — should NOT be counted as a real marker
        $fencedExample = '```' + "`n<!-- pipeline-metrics`nsome: yaml`n-->`n" + '```'
        $body = "## Summary`n`n$realBlock`n`n$fencedExample`n`nEnd."

        $result = Test-PipelineMetricsV4Block -PRBody $body

        $result.Valid               | Should -Be $true
        $result.DetectedMarkerCount | Should -Be 1
    }

    # Test 5: Empty credits fails — v4 block with no credits section → Valid=$false
    It 'empty credits: v4 block with no credit entries returns Valid=$false' {
        # Build a body with a v4 block but no credits: section at all (parser returns empty array)
        $yaml = "pr_number: 739`nmetrics_version: 4`nframe_version: 1"
        $body = "## Summary`n`n<!-- pipeline-metrics`n$yaml`n-->`n"

        $result = Test-PipelineMetricsV4Block -PRBody $body

        $result.Valid         | Should -Be $false
        $result.FailureReason | Should -Not -BeNullOrEmpty
    }

    # Test 6: Never-throws — garbage input does NOT throw; returns Valid=$false
    It 'never-throws: garbage PRBody does not throw and returns Valid=$false' {
        # Invoke directly (not inside a scriptblock) to avoid scoping issues with $result
        $result = Test-PipelineMetricsV4Block -PRBody 'garbage not a block at all'

        $result       | Should -Not -BeNullOrEmpty
        $result.Valid | Should -Be $false
    }

    # Test 7: invalid input terminates quickly and returns Valid=$false (no infinite loop)
    It 'invalid input: returns Valid=$false quickly without hanging' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Test-PipelineMetricsV4Block -PRBody 'not a block'
        $sw.Stop()

        # Function should return quickly (well under 5 seconds)
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5

        $result       | Should -Not -BeNullOrEmpty
        $result.Valid | Should -Be $false
    }
}

Describe 'Test-FCLYamlSane (issue #813 finding N2 regression)' {

    # N2 bug: the old greedy `\"`-strip scanner consumed a genuine trailing
    # escaped backslash (`\\`) immediately before the real closing quote and
    # lost track of where the double-quoted scalar actually ended, causing a
    # validly Escape-FCLScalar-escaped value to be misclassified as malformed.
    # The fix replaced the greedy strip with the scanner regex
    # '^"(?:[^\\"]|\\.)*"', which correctly walks escaped-pair vs. literal-char
    # runs instead of blindly consuming trailing backslash-quote sequences.

    It 'accepts a real Escape-FCLScalar-produced value containing an apostrophe and a trailing literal backslash' {
        # Build the exact escaped line the way production code does: run the
        # value through the real builder (which calls Escape-FCLScalar
        # internally) rather than hand-crafting the escaped YAML text, so this
        # test proves the fix against the actual escaping contract.
        $credit = @{ port = 'review'; adapter = 'standard'; evidence = "it's C:\a\" }
        $block = New-PipelineMetricsV4Block -V3BaseYaml 'pr_number: 1' -Credits @($credit)

        $match = [regex]::Match($block, '(?ms)<!--\s*pipeline-metrics\s*\r?\n(?<yaml>.*?)\r?\n-->')
        $match.Success | Should -BeTrue -Because 'the rendered block must contain a pipeline-metrics YAML payload'

        # Sanity: confirm the escaped line looks like the N2 bug trigger
        # (apostrophe present, and the value ends in an escaped backslash
        # immediately before the closing quote).
        $match.Groups['yaml'].Value | Should -Match 'evidence: "it''s C:\\\\a\\\\"'

        Test-FCLYamlSane -Text $match.Groups['yaml'].Value | Should -Be $true
    }

    It 'rejects a genuinely unterminated double-quoted scalar (proves the scanner regex did not become a rubber stamp)' {
        $text = "port: review`nevidence: `"this value never closes its quote"

        Test-FCLYamlSane -Text $text | Should -Be $false
    }
}
