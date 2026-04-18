#Requires -Version 7.0
<#
.SYNOPSIS
    Writes a review calibration entry and/or re-activation event to .copilot-tracking/calibration/review-data.json.

.PARAMETER EntryJson
    JSON string representing the calibration entry to write. At least one of -EntryJson or -ReactivationEventJson is required.

.PARAMETER ReactivationEventJson
    JSON string representing a re-activation event to write. Required fields: category, triggered_at_pr, expires_at_pr, trigger_source.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$EntryJson,

    [Parameter()]
    [string]$ReactivationEventJson
)

. "$PSScriptRoot/write-calibration-entry-core.ps1"

$result = Invoke-WriteCalibrationEntry @PSBoundParameters
if ($result.Output) { Write-Output $result.Output }
if ($result.Error) { Write-Error $result.Error -ErrorAction Continue }
exit $result.ExitCode
