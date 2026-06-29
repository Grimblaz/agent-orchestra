#Requires -Version 7.0
<#
.SYNOPSIS
    Get-FCLAccumulatedCredits — reads all credit rows from the file-based accumulator.

.DESCRIPTION
    Returns the deserialized credit rows from .tmp/issue-{N}/fclcredits.jsonl.
    Returns an empty array when the file does not exist (fail-open behavior).

    Malformed JSONL lines are skipped with a warning rather than aborting the
    run (B4b fix: corrupt accumulator line does not poison the whole session).

    Always returns an array type — never $null or a scalar (B5 fix).

    Path resolution: this script lives at .github/scripts/lib/, so the repo
    root is three levels up ($PSScriptRoot/../../..). The accumulator file is
    at <repo-root>/.tmp/issue-{N}/fclcredits.jsonl.

.PARAMETER IssueNumber
    The GitHub issue number associated with the current work session.
    Must be >= 1.

.OUTPUTS
    [pscustomobject[]] — zero or more credit row objects in append order.
#>
function Get-FCLAccumulatedCredits {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$IssueNumber
    )

    # .github/scripts/lib is 3 levels from repo root
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $file = Join-Path $repoRoot ".tmp/issue-$IssueNumber/fclcredits.jsonl"

    if (-not (Test-Path -LiteralPath $file)) {
        return @()
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in (Get-Content -Path $file)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $rows.Add(($line | ConvertFrom-Json))
        } catch {
            Write-Warning "Get-FCLAccumulatedCredits: skipping malformed JSONL row: $_"
        }
    }
    return @($rows)
}
