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
#>
[CmdletBinding()]
param(
    [double]$DecayLambda = 0.023,
    [int]$Limit = 100,
    [string]$Repo = '',
    [string]$CalibrationFile = '.copilot-tracking/calibration/review-data.json',
    [string]$ComplexityJsonPath = '',
    [string]$GhCliPath = 'gh'
)

. "$PSScriptRoot/lib/aggregate-review-scores-core.ps1"

$result = Invoke-AggregateReviewScores @PSBoundParameters
if ($result.Output) { Write-Output $result.Output }
if ($result.Error) { Write-Error $result.Error }
exit $result.ExitCode
