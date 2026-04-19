#Requires -Version 7.0
<#
.SYNOPSIS
    Creates a classified improvement issue from a systemic pattern proposal.

.DESCRIPTION
    Thin CLI wrapper for Invoke-CreateImprovementIssue. Gates: §2d consolidation →
    calibration dedup → GitHub search dedup → D10 ceiling advisory → D-259-7
    classification → gh issue create → calibration linkage.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PatternKey,
    [Parameter(Mandatory)][int[]]$EvidencePrs,
    [Parameter(Mandatory)][string]$FirstEmittedAt,
    [Parameter(Mandatory)][int]$FixTypeLevel,
    [Parameter(Mandatory)][string]$TargetFile,
    [Parameter(Mandatory)][string]$ProposedChange,
    [Parameter(Mandatory)][string]$SystemicFixType,
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][bool]$UpstreamPreflightPassed,
    [string]$CalibrationPath,
    [string]$ComplexityJsonPath,
    [string]$GhCliPath = 'gh',
    [string]$FixTypeOverride,
    [string[]]$Labels = @('priority: medium'),
    [switch]$SkipConsolidation
)

. "$PSScriptRoot/create-improvement-issue-core.ps1"

$result = Invoke-CreateImprovementIssue @PSBoundParameters
if ($result.Output) { Write-Output $result.Output }
if ($result.Error) { Write-Error $result.Error -ErrorAction Continue }
exit $result.ExitCode
