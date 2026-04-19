#Requires -Version 7.0
<#
.SYNOPSIS
    Aggregates pipeline-metrics from merged PRs and computes a time-weighted
    calibration profile for the prosecution/defense/judge review pipeline.

.DESCRIPTION
    Reads merged PRs from the current (or specified) GitHub repository via the
    gh CLI, extracts <!-- pipeline-metrics --> blocks from PR bodies, and
    computes exponentially-decayed aggregate statistics.

    This script writes prosecution_depth_state, time-decay re-activation events,
    complexity_over_ceiling_history, and proposals_emitted to the calibration file
    when present.

    When -HealthReport is specified, all calibration file write-back is suppressed
    (read-only mode) and the health report Markdown is emitted to stdout instead of
    the YAML output. When -OutputPath is specified, the health report is written to
    the given file path (write-back still occurs unless -HealthReport is also set).

.PARAMETER DecayLambda
    Exponential decay parameter. Default: 0.023 (half-life approximately 30 days).

.PARAMETER Limit
    Maximum number of merged PRs to fetch. Default: 100.

.PARAMETER Repo
    Repository in owner/name format. If omitted, auto-detected via
    'gh repo view --json nameWithOwner'.

.PARAMETER CalibrationFile
    Path to the local calibration JSON file produced by write-calibration-entry.ps1.
    Default: .copilot-tracking/calibration/review-data.json
    When the file does not exist, the script falls back to PR-body-only mode.

.PARAMETER ComplexityJsonPath
    Path to a measure-guidance-complexity.ps1 JSON output file. When provided,
    increments consecutive_count for over-ceiling agents and logs consolidation events.

.PARAMETER GhCliPath
    Path to the gh CLI executable. Defaults to 'gh'. Override for testing.

.PARAMETER HealthReport
    When present, suppresses all calibration file write-back (read-only mode) and
    emits the health report Markdown to stdout instead of the YAML output. If
    -OutputPath is also provided, the health report is written to that file.

.PARAMETER OutputPath
    Optional file path to write the health report Markdown. When specified, the
    health report is written to this file regardless of whether -HealthReport is
    set. Does not affect stdout routing or write-back suppression on its own.
#>
[CmdletBinding()]
param(
    [double]$DecayLambda = 0.023,
    [int]$Limit = 100,
    [string]$Repo = '',
    [string]$CalibrationFile = '.copilot-tracking/calibration/review-data.json',
    [string]$ComplexityJsonPath = '',
    [string]$GhCliPath = 'gh',
    [switch]$HealthReport,
    [string]$OutputPath = ''
)

. "$PSScriptRoot/aggregate-review-scores-core.ps1"

# OutputPath is wrapper-only; remove before splatting to core function
$null = $PSBoundParameters.Remove('OutputPath')
$result = Invoke-AggregateReviewScores @PSBoundParameters

# Write health report to file if OutputPath specified
if (-not [string]::IsNullOrWhiteSpace($OutputPath) -and $result.ContainsKey('HealthReport')) {
    try {
        Set-Content -Path $OutputPath -Value $result.HealthReport -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to write health report to '$OutputPath': $_"
    }
}

# Route stdout: health report if -HealthReport switch, else YAML
if ($HealthReport.IsPresent) {
    if ($result.ContainsKey('HealthReport')) { Write-Output $result.HealthReport }
    elseif ($result.Output) { Write-Error $result.Output -ErrorAction Continue }
}
else {
    if ($result.Output) { Write-Output $result.Output }
}

if ($result.Error) { Write-Error $result.Error -ErrorAction Continue }
exit $result.ExitCode
