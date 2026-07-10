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

# ---- Render report ----

$reportContext = @{
    Rollup            = $rollup
    Source            = $source
    Truncated         = $truncated
    WindowDays        = $WindowDays
    FetchedAt         = $fetchedAt
    InvalidEntryCount = $invalidEntryCount
}

Format-PhaseContainmentReport -Context $reportContext | Write-Output
