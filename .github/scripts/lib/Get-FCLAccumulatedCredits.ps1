#Requires -Version 7.0
<#
.SYNOPSIS
    Get-FCLAccumulatedCredits — reads all credit rows from the file-based accumulator.

.DESCRIPTION
    Returns the deserialized credit rows from .tmp/issue-{N}/fclcredits.jsonl.
    Returns an empty array when the file does not exist (fail-open behavior).

    Path resolution: this script lives at .github/scripts/lib/, so the repo
    root is three levels up ($PSScriptRoot/../../..). The accumulator file is
    at <repo-root>/.tmp/issue-{N}/fclcredits.jsonl.

.PARAMETER IssueNumber
    The GitHub issue number associated with the current work session.

.OUTPUTS
    [pscustomobject[]] — zero or more credit row objects in append order.
#>
function Get-FCLAccumulatedCredits {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][int]$IssueNumber
    )

    # .github/scripts/lib is 3 levels from repo root
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $file = Join-Path $repoRoot ".tmp/issue-$IssueNumber/fclcredits.jsonl"

    if (-not (Test-Path -LiteralPath $file)) {
        return @()
    }

    return Get-Content -Path $file | ForEach-Object { $_ | ConvertFrom-Json }
}
