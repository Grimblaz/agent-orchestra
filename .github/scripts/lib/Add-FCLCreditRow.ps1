#Requires -Version 7.0
<#
.SYNOPSIS
    Add-FCLCreditRow — appends a credit row to the file-based accumulator.

.DESCRIPTION
    Appends the JSON-serialized credit row to .tmp/issue-{N}/fclcredits.jsonl,
    creating the directory if needed. The file is the authoritative in-flight
    accumulator for emit-pipeline-metrics-v4.ps1.

    Path resolution: this script lives at .github/scripts/lib/, so the repo
    root is three levels up ($PSScriptRoot/../../..). The accumulator file is
    at <repo-root>/.tmp/issue-{N}/fclcredits.jsonl.

.PARAMETER IssueNumber
    The GitHub issue number associated with the current work session.

.PARAMETER CreditRow
    A pscustomobject credit row as returned by Build-*CreditRow builders.
#>
function Add-FCLCreditRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][pscustomobject]$CreditRow
    )

    # .github/scripts/lib is 3 levels from repo root
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $dir = Join-Path $repoRoot ".tmp/issue-$IssueNumber"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir 'fclcredits.jsonl'
    $json = $CreditRow | ConvertTo-Json -Compress -Depth 10
    Add-Content -Path $file -Value $json -Encoding utf8NoBOM
}
