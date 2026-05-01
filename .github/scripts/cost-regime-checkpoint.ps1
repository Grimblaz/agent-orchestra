#Requires -Version 7.0
<#
.SYNOPSIS
    Regime checkpoint CLI — captures a rolling-mean snapshot after a
    cost-reduction sub-issue lands and stabilizes (issue #467, Step 6).
.DESCRIPTION
    Thin shim over Invoke-CostRegimeCheckpoint in cost-checkpoint-core.ps1.
    The CLI exists so maintainers can run the checkpoint capture as a
    one-liner; the body lives in the core lib so tests exercise the same
    flow in-process via dot-source rather than spawning a child pwsh.

    See Invoke-CostRegimeCheckpoint for full parameter documentation and
    the M5 cache-bust ordering contract.
.PARAMETER Reason
    Human-readable reason for the checkpoint (required).
.PARAMETER Note
    Optional free-text annotation.
.PARAMETER SubIssue
    Sub-issue reference to filter (e.g. "#469").
.PARAMETER ExcludeMostRecent
    Number of most-recently fetched PRs to exclude. Defaults to 1.
.PARAMETER CheckpointsPath
    Path to the checkpoints YAML file. Defaults to
    .github/scripts/cost-regime-checkpoints.yaml relative to repo root.
.PARAMETER CacheFilePath
    Path to the rolling-history cache file. Defaults to
    .github/scripts/cache/cost-rolling-history.json relative to repo root.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Reason,

    [string]$Note = '',

    [string]$SubIssue = '',

    [int]$ExcludeMostRecent = 1,

    [string]$CheckpointsPath = '',

    [string]$CacheFilePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Dot-source dependencies ----
. "$PSScriptRoot/lib/cost-rolling-history.ps1"
. "$PSScriptRoot/lib/cost-checkpoint-core.ps1"

# ---- Delegate to core function ----
Invoke-CostRegimeCheckpoint @PSBoundParameters | Out-Null
