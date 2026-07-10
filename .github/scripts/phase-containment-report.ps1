#Requires -Version 7.0
<#
.SYNOPSIS
    Thin CLI wrapper for the phase-containment escape-rate ledger.
.DESCRIPTION
    Dot-sources the rolling-history core library and renders a per-stage report.
    Calls Get-PhaseContainmentHistory to fetch and deduplicate entries, then
    Get-PhaseContainmentRollup to aggregate per-stage escape/irreducible rates.

    Output is intended as a CE Gate surface: insufficient_data and data_untrustworthy
    paths are displayed clearly so a maintainer cannot mistake "not enough data" for "clean."
.EXAMPLE
    pwsh -File .github/scripts/phase-containment-report.ps1
    pwsh -File .github/scripts/phase-containment-report.ps1 -WindowDays 30
#>

param(
    [string]$RepoOwner = 'Grimblaz',
    [string]$RepoName  = 'agent-orchestra',
    [int]$WindowDays   = 90,
    [string]$Token     = $env:GH_TOKEN,
    [switch]$NoCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source the rolling-history core library
$libRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libRoot 'phase-containment-rolling-history-core.ps1')

# ---- Fetch entries ----

$fetchParams = @{
    RepoOwner  = $RepoOwner
    RepoName   = $RepoName
    WindowDays = $WindowDays
}
if ($Token) {
    $fetchParams['Token'] = $Token
}
if ($NoCache) {
    # Force cache miss by pointing at a non-existent path
    $fetchParams['CachePath'] = [System.IO.Path]::GetTempFileName() + '.nocache.json'
}

$history = Get-PhaseContainmentHistory @fetchParams

$entries           = @($history.Entries)
$fetchedAt         = $history.FetchedAt
$source            = $history.Source
$truncated         = $history.Truncated
$invalidEntryCount = $history.InvalidEntryCount

# ---- Compute rollup ----

$rollup = Get-PhaseContainmentRollup -Entries $entries -WindowLabel "${WindowDays}d" -Truncated:$truncated

# ---- Render header ----

$headerSuffix = if ($truncated) { ' (TRUNCATED — results incomplete)' } else { '' }

Write-Output ''
Write-Output 'Phase-Containment Escape-Rate Ledger'
Write-Output "Window: ${WindowDays}d | Fetched: $($fetchedAt.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC | Source: $source$headerSuffix"
Write-Output "Total entries processed: $($rollup.WindowEntryCount) | Apparatus-meta entries: $($rollup.ApparatusMetaCount)"
if ($invalidEntryCount -gt 0) {
    Write-Output "WARNING: $invalidEntryCount phase-containment block(s) dropped as invalid/unparseable during this fetch — see gh Action run logs for details."
}
Write-Output ''

# ---- Render per-stage results ----

$stageOrder = @('design-challenge', 'plan-stress-test', 'code-review')

foreach ($stageName in $stageOrder) {
    $stage = $rollup.Stages[$stageName]

    # Map stage name to catchable_phase label for clarity
    $catchableLabel = switch ($stageName) {
        'design-challenge' { 'catchable=design' }
        'plan-stress-test' { 'catchable=plan' }
        'code-review'      { 'catchable=implementation' }
    }

    Write-Output "Stage: $stageName"
    Write-Output "  Denominator ($catchableLabel): $($stage.Denominator)"

    if ($stage.DataUntrustworthy) {
        Write-Output "  DATA UNTRUSTWORTHY -- relaxation signal withheld (entry count mismatch)"
        if ($null -ne $stage.DataUntrustworthyReason) {
            Write-Output "  Reason: $($stage.DataUntrustworthyReason)"
        }
    }

    if ($stage.DenominatorZero) {
        Write-Output "  Escape rate:        N/A (denominator=0)"
        Write-Output "  Irreducible rate:   N/A"
        Write-Output "  Relaxation signal:  WITHHELD (denominator=0)"
    }
    elseif ($stage.InsufficientData) {
        Write-Output "  Escape rate:        INSUFFICIENT DATA (n=$($stage.N) < 5)"
        Write-Output "  Irreducible rate:   INSUFFICIENT DATA"
        Write-Output "  Relaxation signal:  WITHHELD (n<5)"
    }
    elseif ($stage.DataUntrustworthy) {
        $escapeDisplay      = if ($null -ne $stage.EscapeRate)      { '{0:P1}' -f $stage.EscapeRate }      else { 'N/A' }
        $irreducibleDisplay = if ($null -ne $stage.IrreducibleRate) { '{0:P1}' -f $stage.IrreducibleRate } else { 'N/A' }
        Write-Output "  Escape rate:        $escapeDisplay"
        Write-Output "  Irreducible rate:   $irreducibleDisplay"
        Write-Output "  Relaxation signal:  WITHHELD (data untrustworthy)"
    }
    else {
        $escapeCount      = [int][Math]::Round($stage.EscapeRate      * $stage.Denominator)
        $irreducibleCount = [int][Math]::Round($stage.IrreducibleRate * $stage.Denominator)

        $escapeDisplay      = '{0:F2} ({1} of {2} escaped)' -f $stage.EscapeRate, $escapeCount, $stage.Denominator
        $irreducibleDisplay = '{0:F2} ({1} of {2} irreducible)' -f $stage.IrreducibleRate, $irreducibleCount, $stage.Denominator

        Write-Output "  Escape rate:        $escapeDisplay"
        Write-Output "  Irreducible rate:   $irreducibleDisplay"

        if ($null -eq $stage.RelaxationEligible) {
            Write-Output "  Relaxation signal:  WITHHELD"
        }
        elseif ($stage.RelaxationEligible -eq $true) {
            Write-Output "  Relaxation signal:  ELIGIBLE (escape_rate ~0, no critical findings)"
        }
        elseif ($stage.RelaxationEligibleReason -eq 'fetch truncated') {
            # P9: checked BEFORE the EscapeRate reason-guess below so a
            # truncated run never falls through to the misleading
            # "NOT ELIGIBLE (escape_rate > 0)" text.
            Write-Output "  Relaxation signal:  WITHHELD (fetch truncated)"
        }
        else {
            # Determine reason
            if ($stage.EscapeRate -ge 0.05) {
                Write-Output "  Relaxation signal:  NOT ELIGIBLE (escape_rate > 0)"
            }
            else {
                Write-Output "  Relaxation signal:  NOT ELIGIBLE (critical severity finding in window)"
            }
        }
    }

    Write-Output ''
}

# ---- Render leakage matrix ----

$leakageMatrix = $rollup.LeakageMatrix
if ($leakageMatrix.Count -gt 0) {
    Write-Output 'Leakage matrix (introduced x caught combinations):'

    # Sort by count descending, then key name
    $sorted = $leakageMatrix.GetEnumerator() |
        Sort-Object { -$_.Value }, { $_.Key }

    foreach ($pair in $sorted) {
        $label = $pair.Key -replace 'x', ' -> ' -replace [char]0x00D7, ' -> '
        Write-Output ('  {0,-45} {1} findings' -f "$($pair.Key -replace [char]0x00D7, ' -> '):", $pair.Value)
    }
}
else {
    Write-Output 'Leakage matrix: (no entries in window)'
}

Write-Output ''
