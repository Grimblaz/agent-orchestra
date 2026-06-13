#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Scan for repo changes since an issue was created and return drift candidates as JSON.

.DESCRIPTION
    Thin wrapper that dot-sources get-issue-drift-core.ps1 and forwards all parameters
    to Get-IssueDrift. Output is written to stdout as JSON.

    Use -IssueJsonOverride and -PrListJsonOverride for testing without live gh calls.

.PARAMETER IssueNumber
    Issue number to scan (resolved against the consumer's gh repo context).

.PARAMETER ThresholdDays
    Age gate: scan only if the issue is strictly older than ThresholdDays x 24 hours.
    Default: 7.

.PARAMETER Force
    Bypass the age gate -- always scan regardless of issue age.

.PARAMETER Cap
    Maximum number of path-matched candidate PRs to return. Default: 10.

.PARAMETER ExcludePaths
    Paths or prefixes filtered from intersection matching.
    Default: .claude-plugin/, .github/plugin/, plugin.json, marketplace.json, CHANGELOG.md

.PARAMETER IssueJsonOverride
    JSON string replacing the gh issue view call (for testing/DI).

.PARAMETER PrListJsonOverride
    JSON string replacing the gh pr list call (for testing/DI).

.OUTPUTS
    JSON to stdout. Always exits 0.
    - {"skipped":"below-threshold"} when age gate fires without -Force
    - {"error":"..."} on gh failure or malformed JSON
    - Full result object when scan completes
#>

param(
    [Parameter(Mandatory)]
    [string]$IssueNumber,

    [int]$ThresholdDays = 7,

    [switch]$Force,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$Cap = 10,

    # Default ExcludePaths is intentionally omitted here — the core function owns
    # the canonical default. Omitting it ensures @PSBoundParameters does not
    # forward a stale copy that could diverge from the core's single-source default.
    [string[]]$ExcludePaths,

    [AllowNull()]
    [string]$IssueJsonOverride = $null,

    [AllowNull()]
    [string]$PrListJsonOverride = $null
)

. (Join-Path $PSScriptRoot 'get-issue-drift-core.ps1')

$result = Get-IssueDrift @PSBoundParameters
$result | ConvertTo-Json -Depth 10
