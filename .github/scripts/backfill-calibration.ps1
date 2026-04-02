#Requires -Version 7.0
<#
.SYNOPSIS
    Backfills .copilot-tracking/calibration/review-data.json from merged PR pipeline-metrics.
#>

[CmdletBinding()]
param(
    [string]$Repo,
    [int]$Limit = 100,
    [string]$GhCliPath = 'gh'
)

. "$PSScriptRoot/lib/backfill-calibration-core.ps1"

$result = Invoke-BackfillCalibration @PSBoundParameters
if ($result.Output) { Write-Output $result.Output }
if ($result.Error) { Write-Error $result.Error }
exit $result.ExitCode
