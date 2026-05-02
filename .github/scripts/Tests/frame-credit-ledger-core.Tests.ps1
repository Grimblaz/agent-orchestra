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
        $out = Compose-MissingMetricsShortCircuitComment -MarkerToken $marker

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
}
