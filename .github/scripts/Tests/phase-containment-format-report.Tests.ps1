#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for Format-PhaseContainmentReport (issue #772, D5b).
#
# File under test: .github/scripts/lib/phase-containment-rolling-history-core.ps1
#   (Format-PhaseContainmentReport, Get-PhaseContainmentRollup)
#
# This spec gates the production renderer directly — it calls the real
# Get-PhaseContainmentRollup + Format-PhaseContainmentReport functions, not a
# re-implementation. It replaces the retired standalone harness
# Tests/Invoke-CEGate762.ps1, whose inline copy of the display logic had
# drifted from production (its DataUntrustworthy branch rendered
# "N/A (data untrustworthy)" and was never reachable by its own fixtures —
# it never passed -SustainedCounts to Get-PhaseContainmentRollup).
#
# Fixture entries mirror the retired harness's four scenario buckets:
#   code-review      : 4 entries (n=4 < 5)   -> INSUFFICIENT DATA        (AC8)
#   plan-stress-test : 6 clean entries (n=6)  -> EscapeRate=0, ELIGIBLE   (AC3/AC4)
#   design-challenge : 7 entries, 2 escaped   -> EscapeRate~0.29, NOT ELIGIBLE (AC4/AC12)
#   experience-catchable : 1 entry            -> leakage matrix only, no stage bucket
#
# NOTE: Do NOT import powershell-yaml or use ConvertFrom-Yaml in this file.

BeforeAll {
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'
    . (Join-Path $script:LibRoot 'phase-containment-rolling-history-core.ps1')
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    function script:New-PC772FixtureEntries {
        $entries = [System.Collections.Generic.List[hashtable]]::new()

        # code-review bucket (catchable_phase=implementation, n=4 -> InsufficientData)
        foreach ($pair in @(
            @{ key = 'code-review:4832813258'; intro = 'design';         sev = 'high';   fix = 'instruction'; cat = 'pattern'               },
            @{ key = 'code-review:4832813940'; intro = 'implementation'; sev = 'medium'; fix = 'instruction'; cat = 'implementation-clarity' },
            @{ key = 'code-review:4832814488'; intro = 'plan';           sev = 'medium'; fix = 'skill';       cat = 'documentation-audit'   },
            @{ key = 'code-review:4832815057'; intro = 'design';         sev = 'medium'; fix = 'instruction'; cat = 'documentation-audit'   }
        )) {
            $entries.Add(@{
                finding_key       = $pair.key
                introduced_phase  = $pair.intro
                catchable_phase   = 'implementation'
                caught_stage      = 'code-review'
                escape_distance   = 0
                severity          = $pair.sev
                systemic_fix_type = $pair.fix
                category          = $pair.cat
                apparatus_meta    = $false
            })
        }

        # plan-stress-test bucket (catchable_phase=plan, n=6, all escape_distance=0 -> RelaxationEligible)
        for ($i = 1; $i -le 6; $i++) {
            $entries.Add(@{
                finding_key       = "plan-stress-test:772:plan-issue-772:P$i"
                introduced_phase  = 'design'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
            })
        }

        # design-challenge bucket (catchable_phase=design, n=7, 2 escaped -> EscapeRate~0.286)
        # 5 caught at design-challenge (escape_distance=0)
        for ($i = 1; $i -le 5; $i++) {
            $entries.Add(@{
                finding_key       = "design-challenge:772:design-phase-complete-772:F$i"
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'design-challenge'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
            })
        }
        # 2 escaped design-challenge, caught at code-review (escape_distance=2)
        for ($i = 1; $i -le 2; $i++) {
            $entries.Add(@{
                finding_key       = "code-review:772:escaped-design-$i"
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'code-review'
                escape_distance   = 2
                severity          = 'high'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
            })
        }

        # experience-catchable (leakage matrix only, no stage bucket)
        $entries.Add(@{
            finding_key       = 'code-review:772:experience-catchable-1'
            introduced_phase  = 'experience'
            catchable_phase   = 'experience'
            caught_stage      = 'code-review'
            escape_distance   = 3
            severity          = 'low'
            systemic_fix_type = 'skill'
            category          = 'pattern'
            apparatus_meta    = $false
        })

        return $entries.ToArray()
    }

    function script:New-PC772Context {
        param(
            [Parameter(Mandatory)][object]$Rollup,
            [bool]$Truncated = $false,
            [int]$InvalidEntryCount = 0
        )
        return @{
            Rollup            = $Rollup
            Source            = 'graphql'
            Truncated         = $Truncated
            WindowDays        = 90
            FetchedAt         = [datetime]::new(2026, 7, 10, 0, 0, 0, [DateTimeKind]::Utc)
            InvalidEntryCount = $InvalidEntryCount
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Production render against fixture rollup (AC3/AC4/AC8/AC12)
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — production render (AC3/AC4/AC8/AC12)' {
    BeforeAll {
        $script:Rollup     = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d'
        $script:Context    = New-PC772Context -Rollup $script:Rollup
        $script:ReportText = (Format-PhaseContainmentReport -Context $script:Context) -join "`n"
    }

    It 'renders INSUFFICIENT DATA escape rate for the code-review stage with n=4 (AC8)' {
        $script:ReportText.Contains('Escape rate:        INSUFFICIENT DATA (n=4 < 5)') | Should -BeTrue -Because (
            "code-review has only 4 non-apparatus entries, below the n>=5 statistical floor.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders WITHHELD (n<5) as the relaxation signal for the code-review stage (AC8)' {
        $script:ReportText.Contains('Relaxation signal:  WITHHELD (n<5)') | Should -BeTrue -Because (
            "an insufficient-data stage must withhold its relaxation signal.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders a 0.00 escape rate for the plan-stress-test stage with 0 of 6 escaped (AC4)' {
        $script:ReportText.Contains('Escape rate:        0.00 (0 of 6 escaped)') | Should -BeTrue -Because (
            "all 6 plan-stress-test fixture entries have escape_distance=0.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders ELIGIBLE as the relaxation signal for the plan-stress-test stage (AC3)' {
        $script:ReportText.Contains('Relaxation signal:  ELIGIBLE (escape_rate ~0, no critical findings)') | Should -BeTrue -Because (
            "plan-stress-test is clean (n=6, escape_rate=0, no critical severity).`nActual report:`n$script:ReportText"
        )
    }

    It 'renders a 0.29 escape rate for the design-challenge stage with 2 of 7 escaped (AC4/AC12)' {
        $script:ReportText.Contains('Escape rate:        0.29 (2 of 7 escaped)') | Should -BeTrue -Because (
            "2 of the 7 design-challenge fixture entries escaped to code-review.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders NOT ELIGIBLE as the relaxation signal for the design-challenge stage (AC4/AC12)' {
        $script:ReportText.Contains('Relaxation signal:  NOT ELIGIBLE (escape_rate > 0)') | Should -BeTrue -Because (
            "design-challenge escape_rate (~0.29) is above the 0.05 relaxation threshold.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders the leakage matrix header (AC12)' {
        $script:ReportText.Contains('Leakage matrix (introduced x caught combinations):') | Should -BeTrue -Because (
            "the fixture has entries in the window so the leakage matrix must render, not the empty-window fallback.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders the per-stage denominators for all three stages (AC12)' {
        $script:ReportText.Contains('Denominator (catchable=implementation): 4') | Should -BeTrue -Because "code-review denominator must equal n=4.`nActual report:`n$script:ReportText"
        $script:ReportText.Contains('Denominator (catchable=plan): 6') | Should -BeTrue -Because "plan-stress-test denominator must equal n=6.`nActual report:`n$script:ReportText"
        $script:ReportText.Contains('Denominator (catchable=design): 7') | Should -BeTrue -Because "design-challenge denominator must equal n=7.`nActual report:`n$script:ReportText"
    }
}

# ---------------------------------------------------------------------------
# 2. DataUntrustworthy branch — exercised for real via -SustainedCounts
#    mismatch (previously unreachable in the retired harness, which never
#    passed -SustainedCounts to Get-PhaseContainmentRollup).
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — DataUntrustworthy branch (SustainedCounts mismatch)' {
    BeforeAll {
        # Deliberate mismatch: the design-challenge fixture bucket has exactly
        # 7 non-apparatus entries (see New-PC772FixtureEntries); 99 is wrong
        # on purpose so DataUntrustworthy fires for real, not by assumption.
        $script:MismatchedRollup = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d' -SustainedCounts @{ 'design-challenge' = 99 }
        $script:MismatchedContext    = New-PC772Context -Rollup $script:MismatchedRollup
        $script:MismatchedReportText = (Format-PhaseContainmentReport -Context $script:MismatchedContext) -join "`n"
    }

    It 'sets DataUntrustworthy on the design-challenge stage when SustainedCounts disagrees with the observed count' {
        $script:MismatchedRollup.Stages['design-challenge'].DataUntrustworthy | Should -BeTrue -Because (
            'the fixture has 7 non-apparatus design-challenge entries but SustainedCounts asserts 99, so the completeness reconciliation must fail closed.'
        )
    }

    It 'renders the DATA UNTRUSTWORTHY banner with the entry-count-mismatch reason' {
        $script:MismatchedReportText.Contains('DATA UNTRUSTWORTHY -- relaxation signal withheld (entry count mismatch)') | Should -BeTrue -Because (
            "Actual report:`n$script:MismatchedReportText"
        )
        $script:MismatchedReportText.Contains("Reason: Entry count mismatch: expected 99 sustained findings for 'design-challenge', observed 7.") | Should -BeTrue -Because (
            "Actual report:`n$script:MismatchedReportText"
        )
    }

    It 'renders WITHHELD (data untrustworthy) as the relaxation signal' {
        $script:MismatchedReportText.Contains('Relaxation signal:  WITHHELD (data untrustworthy)') | Should -BeTrue -Because (
            "Actual report:`n$script:MismatchedReportText"
        )
    }

    It 'renders the actual computed escape-rate percentage, not the retired harness''s drifted N/A text' {
        # Production computes EscapeRate before checking DataUntrustworthy, so
        # a stage with n>=5 still has a real rate to show. The retired
        # Invoke-CEGate762.ps1 harness rendered a hardcoded "N/A (data
        # untrustworthy)" here — that text never reflected production.
        $script:MismatchedReportText.Contains('Escape rate:        28.6%') | Should -BeTrue -Because (
            "production formats the untrustworthy-branch rate as a percentage (P1 format) when EscapeRate is non-null.`nActual report:`n$script:MismatchedReportText"
        )
        $script:MismatchedReportText.Contains('N/A (data untrustworthy)') | Should -BeFalse -Because (
            "this is the retired harness's drifted literal; production never renders it when EscapeRate is available.`nActual report:`n$script:MismatchedReportText"
        )
    }
}

# ---------------------------------------------------------------------------
# 3. Truncated-path render — header suffix + per-stage withholding
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — truncated-path render' {
    BeforeAll {
        $script:TruncatedRollup     = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d' -Truncated
        $script:TruncatedContext    = New-PC772Context -Rollup $script:TruncatedRollup -Truncated $true
        $script:TruncatedReportText = (Format-PhaseContainmentReport -Context $script:TruncatedContext) -join "`n"
    }

    It 'renders the (TRUNCATED — results incomplete) header suffix' {
        $script:TruncatedReportText.Contains('(TRUNCATED — results incomplete)') | Should -BeTrue -Because (
            "Actual report:`n$script:TruncatedReportText"
        )
    }

    It 'renders WITHHELD (fetch truncated) for a stage that would otherwise be NOT ELIGIBLE' {
        # design-challenge would render "NOT ELIGIBLE (escape_rate > 0)" when
        # not truncated (see the first Describe block); a truncated fetch
        # must override that with the fail-closed truncation withholding.
        $script:TruncatedReportText.Contains('Relaxation signal:  WITHHELD (fetch truncated)') | Should -BeTrue -Because (
            "Actual report:`n$script:TruncatedReportText"
        )
        $script:TruncatedReportText.Contains('NOT ELIGIBLE (escape_rate > 0)') | Should -BeFalse -Because (
            "a truncated corpus must never present the design-challenge stage as a confident NOT ELIGIBLE verdict.`nActual report:`n$script:TruncatedReportText"
        )
    }

    It 'renders WITHHELD (fetch truncated) for a stage that would otherwise be ELIGIBLE' {
        # plan-stress-test would render "ELIGIBLE (escape_rate ~0, no critical
        # findings)" when not truncated; truncation must not let a clean-
        # looking stage present a relaxation signal either.
        $script:TruncatedReportText.Contains('ELIGIBLE (escape_rate ~0, no critical findings)') | Should -BeFalse -Because (
            "a truncated corpus must never present a clean relaxation signal, even for a stage whose visible data looks clean.`nActual report:`n$script:TruncatedReportText"
        )
    }
}

# ---------------------------------------------------------------------------
# 4. InvalidEntryCount warning render
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — InvalidEntryCount warning render' {
    BeforeAll {
        $script:BaselineRollup = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d'
    }

    It 'renders the WARNING line when InvalidEntryCount is nonzero' {
        $context     = New-PC772Context -Rollup $script:BaselineRollup -InvalidEntryCount 3
        $reportText  = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $reportText.Contains('WARNING: 3 phase-containment block(s) dropped as invalid/unparseable during this fetch — see gh Action run logs for details.') | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
    }

    It 'omits the WARNING line when InvalidEntryCount is zero' {
        $context    = New-PC772Context -Rollup $script:BaselineRollup -InvalidEntryCount 0
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $reportText.Contains('phase-containment block(s) dropped as invalid/unparseable') | Should -BeFalse -Because (
            "a clean fetch must not render the invalid-entry warning.`nActual report:`n$reportText"
        )
    }
}
