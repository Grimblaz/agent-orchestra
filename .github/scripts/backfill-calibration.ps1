#Requires -Version 7.0
<#
.SYNOPSIS
    Backfills .copilot-tracking/calibration/review-data.json from merged PR pipeline-metrics.
#>

[CmdletBinding()]
param(
    [string]$Repo,
    [int]$Limit = 100,
    [string]$GhCliPath = 'gh',
    [string]$WriteScript = (Join-Path $PSScriptRoot 'write-calibration-entry.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Shared helpers (Get-YamlField, Get-FindingsArray)
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'lib\pipeline-metrics-helpers.ps1')

# ---------------------------------------------------------------------------
# Helper: safe integer conversion — returns 0 for null / n/a / empty
# ---------------------------------------------------------------------------
function ConvertTo-IntSafe {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @('n/a', 'N/A')) { return 0 }
    return [int]$Value
}

# ---------------------------------------------------------------------------
# Fetch PRs
# ---------------------------------------------------------------------------
$repoArgs = if ($Repo) { @('--repo', $Repo) } else { @() }

$ghOut = & $GhCliPath pr list --state merged --limit $Limit --json number,mergedAt,body @repoArgs
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Error "gh pr list failed with exit code $exitCode"
    exit $exitCode
}

$prs = ($ghOut -join '') | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Process each PR
# ---------------------------------------------------------------------------
foreach ($pr in $prs) {
    # 1. Extract the pipeline-metrics block
    $bodyText = [string]$pr.body
    $match = [regex]::Match($bodyText, '(?s)<!--\s*pipeline-metrics\s*(.*?)-->')
    if (-not $match.Success) { continue }

    $metricsBlock = $match.Groups[1].Value

    # 2. Extract findings array - skip if none (v1-only)
    $findings = Get-FindingsArray -Block $metricsBlock
    if ($findings.Count -eq 0) { continue }

    # 3. Normalize merged_at - ConvertFrom-Json may auto-convert ISO strings to DateTime
    $rawMergedAt = $pr.mergedAt
    if ($rawMergedAt -is [datetime]) {
        $mergedAtStr = $rawMergedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } else {
        $mergedAtStr = [string]$rawMergedAt
    }

    # 4. Build summary from metrics block scalar fields
    $summary = @{
        prosecution_findings = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'prosecution_findings')
        pass_1_findings      = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'pass_1_findings')
        pass_2_findings      = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'pass_2_findings')
        pass_3_findings      = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'pass_3_findings')
        defense_disproved    = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'defense_disproved')
        judge_accepted       = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'judge_accepted')
        judge_rejected       = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'judge_rejected')
        judge_deferred       = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'judge_deferred')
    }

    # 5. Build entry
    $entry = @{
        pr_number  = [int]$pr.number
        created_at = $mergedAtStr  # surrogate: no pre-merge write-time; use PR mergedAt
        findings   = $findings
        summary    = $summary
    }

    # 6. Serialize and call write script in a child process (write script calls exit)
    $entryJson = $entry | ConvertTo-Json -Depth 10 -Compress
    & pwsh -NoProfile -NonInteractive -File $WriteScript -EntryJson $entryJson
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "write-calibration-entry failed for PR #$($pr.number) - continuing"
    }
}

exit 0
