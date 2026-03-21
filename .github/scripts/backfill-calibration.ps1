#Requires -Version 7.0
<#
.SYNOPSIS
    Backfills .copilot-tracking/calibration/review-data.json from merged PR pipeline-metrics.
#>

[CmdletBinding()]
param(
    [string]$Repo,
    [int]$Limit = 100,
    [string]$GhCliPath = 'gh'
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
$pendingEntries = [System.Collections.Generic.List[object]]::new()

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

    # 6. Accumulate for batch write
    $pendingEntries.Add($entry)
}

# ── Batch write: load once, merge all entries, write once ─────────────────────

if ($pendingEntries.Count -gt 0) {
    $calibDir = Join-Path (Get-Location).Path '.copilot-tracking' 'calibration'
    $dataFile = Join-Path $calibDir 'review-data.json'
    $tmpFile = "$dataFile.tmp"

    if (Test-Path $dataFile) {
        $data = Get-Content $dataFile -Raw | ConvertFrom-Json -AsHashtable
    } else {
        $data = [ordered]@{
            calibration_version = 1
            entries             = @()
        }
    }

    New-Item -ItemType Directory -Path $calibDir -Force | Out-Null

    # Merge: replace any existing entries with the same pr_number
    $existingEntries = @($data.entries | Where-Object {
        $pn = [int]$_.pr_number
        -not ($pendingEntries | Where-Object { [int]$_.pr_number -eq $pn })
    })
    $mergedEntries = $existingEntries + @($pendingEntries)

    # Preserve all top-level keys from existing data, override only entries
    $output = [ordered]@{}
    foreach ($key in $data.Keys) { $output[$key] = $data[$key] }
    $output['entries'] = $mergedEntries

    try {
        $json = $output | ConvertTo-Json -Depth 10
        Set-Content -Path $tmpFile -Value $json -Encoding UTF8
        $null = Get-Content $tmpFile -Raw | ConvertFrom-Json
        Move-Item -Path $tmpFile -Destination $dataFile -Force
    } catch {
        if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
        Write-Error "Batch write failed: $_" -ErrorAction Continue
        exit 1
    }

    Write-Output "Backfilled $($pendingEntries.Count) entries."
}

exit 0
