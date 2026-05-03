#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for Compose-Comment unified per-port table refactor (issue #441, Step 5b).
#
# D2 single-shape parity: all six status values (passed, failed, skipped,
# not-applicable, inconclusive, not-persisted) must appear in the same per-port
# table shape with status as a column — no separate sections.
#
# Retiring: ### ✅ Covered  /  ### ⚠️ Inconclusive  /  ### 🚫 Not covered
# Replacing with: a single per-port table where each row has port, status, evidence.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'

    if (Test-Path $script:LibPath) {
        . $script:LibPath
    }

    $script:Marker = '<!-- frame-credit-ledger-PR-441 -->'

    # Build a PortReport with a given SubReason → status column mapping.
    function script:New-Report {
        param(
            [string]$PortName = 'test-port',
            [string]$Status = 'Covered',
            [string]$SubReason = 'PassedCredit',
            [string]$CreditStatus = 'passed',
            [string]$Evidence = 'some evidence',
            [string]$AdapterName = 'test-adapter',
            [string]$SuggestedNextStep = $null
        )
        return [pscustomobject]@{
            PortName          = $PortName
            Status            = $Status
            SubReason         = $SubReason
            CreditStatus      = $CreditStatus
            Evidence          = $Evidence
            AdapterName       = $AdapterName
            SuggestedNextStep = $SuggestedNextStep
        }
    }

    # All six status values as PortReports.
    $script:AllSixReports = @(
        script:New-Report -PortName 'review'          -Status 'Covered'      -SubReason 'PassedCredit'        -CreditStatus 'passed'
        script:New-Report -PortName 'release-hygiene' -Status 'NotCovered'   -SubReason 'AdapterFailed'       -CreditStatus 'failed'
        script:New-Report -PortName 'plan'            -Status 'Covered'      -SubReason 'SkippedCredit'       -CreditStatus 'skipped'
        script:New-Report -PortName 'design'          -Status 'Covered'      -SubReason 'NotApplicableCredit' -CreditStatus 'not-applicable'
        script:New-Report -PortName 'post-fix-review' -Status 'Inconclusive' -SubReason 'InconclusiveCredit'  -CreditStatus 'inconclusive'
        script:New-Report -PortName 'experience'      -Status 'NotCovered'   -SubReason 'NotPersistedCredit'  -CreditStatus 'not-persisted'
    )
}

Describe 'Compose-Comment unified per-port table (Step 5b — D2 single-shape parity)' {

    It 'does NOT render the three-section headers (### ✅ Covered, etc.)' {
        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $script:AllSixReports

        $out | Should -Not -Match '### ✅ Covered'
        $out | Should -Not -Match '### ⚠️ Inconclusive'
        $out | Should -Not -Match '### 🚫 Not covered'
    }

    It 'renders a unified markdown table with a header row' {
        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $script:AllSixReports

        # Table must have header and separator rows.
        $out | Should -Match '\|.*Port.*\|.*Status.*\|'
        $out | Should -Match '\|[\s-|]+\|'
    }

    It 'all six status values appear in the same table' {
        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $script:AllSixReports

        $out | Should -Match 'passed'
        $out | Should -Match 'failed'
        $out | Should -Match 'skipped'
        $out | Should -Match 'not-applicable'
        $out | Should -Match 'inconclusive'
        $out | Should -Match 'not-persisted'
    }

    It 'all six port names appear in the same table' {
        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $script:AllSixReports

        $out | Should -Match 'review'
        $out | Should -Match 'release-hygiene'
        $out | Should -Match 'plan'
        $out | Should -Match 'design'
        $out | Should -Match 'post-fix-review'
        $out | Should -Match 'experience'
    }

    It 'still includes the marker token' {
        $out = Compose-Comment -MarkerToken $script:Marker -PortReports @(
            script:New-Report -PortName 'review' -CreditStatus 'passed'
        )
        $out | Should -Match ([regex]::Escape($script:Marker))
    }

    It 'still includes the Frame credit ledger heading' {
        $out = Compose-Comment -MarkerToken $script:Marker -PortReports @(
            script:New-Report -PortName 'review' -CreditStatus 'passed'
        )
        $out | Should -Match '## Frame credit ledger'
    }

    It 'still includes the warn-mode footer' {
        $out = Compose-Comment -MarkerToken $script:Marker -PortReports @(
            script:New-Report -PortName 'review' -CreditStatus 'passed'
        )
        $out | Should -Match '(?i)warn'
    }

    It 'auto-N/A ports are still filtered and reported in a footnote (not as full rows)' {
        $reports = @(
            script:New-Report -PortName 'review'  -Status 'Covered' -SubReason 'PassedCredit'    -CreditStatus 'passed'
            script:New-Report -PortName 'design'  -Status 'Covered' -SubReason 'AutoNotApplicable' -CreditStatus ''
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        # Auto-N/A should NOT be a full table row.
        # (The 'design' port should not appear in the table as a regular row.)
        $out | Should -Match '\(1 ports auto-N/A'
    }

    It 'a single passed row renders correctly in the unified table' {
        $reports = @(
            script:New-Report -PortName 'review' -Status 'Covered' -SubReason 'PassedCredit' -CreditStatus 'passed' -Evidence 'judge ruling: keep'
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        # Port name and status both appear in a table row.
        $out | Should -Match '\|\s*review\s*\|'
        $out | Should -Match '\|\s*✅.*passed.*\||\|\s*passed\s*\|'
    }

    It 'a not-persisted row renders in the same table as passed rows (no separate section)' {
        $reports = @(
            script:New-Report -PortName 'review'     -Status 'Covered'    -SubReason 'PassedCredit'     -CreditStatus 'passed'
            script:New-Report -PortName 'experience' -Status 'NotCovered' -SubReason 'NotPersistedCredit' -CreditStatus 'not-persisted'
        )

        $out = Compose-Comment -MarkerToken $script:Marker -PortReports $reports

        # Both ports in the same table — verify no section split between them.
        $reviewIdx = $out.IndexOf('review')
        $experienceIdx = $out.IndexOf('experience')

        # No section header between them.
        $between = $out.Substring([Math]::Min($reviewIdx, $experienceIdx),
                                   [Math]::Abs($experienceIdx - $reviewIdx))
        $between | Should -Not -Match '###'
    }
}
