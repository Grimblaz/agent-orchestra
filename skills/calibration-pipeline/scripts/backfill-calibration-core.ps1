#Requires -Version 7.0
<#
.SYNOPSIS
    Library for backfill-calibration logic. Dot-source this file and call Invoke-BackfillCalibration.
#>

# Dot-source sibling helpers (Get-YamlField, Get-FindingsArray)
$script:_BCCoreLibDir = Split-Path -Parent $PSCommandPath
. "$script:_BCCoreLibDir/pipeline-metrics-helpers.ps1"

function Invoke-BackfillCalibration {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Repo,
        [int]$Limit = 100,
        [string]$GhCliPath = 'gh'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not (Get-Command $GhCliPath -ErrorAction SilentlyContinue)) {
        return @{
            ExitCode = 1
            Output   = ''
            Error    = "gh CLI not found at '$GhCliPath'. Install the GitHub CLI or set -GhCliPath."
        }
    }

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

    $ghOut = & $GhCliPath pr list --state merged --limit $Limit --json 'number,mergedAt,body' @repoArgs
    $ghExitCode = $LASTEXITCODE
    if ($ghExitCode -ne 0) {
        return @{ ExitCode = $ghExitCode; Output = ''; Error = "gh pr list failed with exit code $ghExitCode" }
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
        }
        else {
            $mergedAtStr = [string]$rawMergedAt
        }

        # 4. Build summary from metrics block scalar fields
        # Build pass_findings keyed map from the nested pass_findings block (keys 1-5);
        # fall back to legacy pass_X_findings flat fields for older PR bodies.
        $passFindingsMap = @{}

        # Try to extract the nested pass_findings: block by capturing indented lines after the key.
        $passFindingsBlockMatch = [regex]::Match($metricsBlock, '(?m)^pass_findings:\s*\n((?:[ \t]+\S.*\n?)*)')
        if ($passFindingsBlockMatch.Success) {
            $passFindingsBlock = $passFindingsBlockMatch.Groups[1].Value
            foreach ($passKey in @('1', '2', '3', '4', '5')) {
                $keyMatch = [regex]::Match($passFindingsBlock, "(?m)^\s+${passKey}:\s*(\S+)")
                if ($keyMatch.Success) {
                    $rawVal = $keyMatch.Groups[1].Value.Trim()
                    if ($rawVal -notin @('n/a', 'N/A')) {
                        $passFindingsMap[$passKey] = ConvertTo-IntSafe $rawVal
                    }
                }
            }
        }

        # Legacy fallback: only when no pass_findings: block was present at all (not when block existed but all values were n/a).
        if (-not $passFindingsBlockMatch.Success) {
            foreach ($passKey in @('1', '2', '3')) {
                $legacyValue = Get-YamlField -Block $metricsBlock -FieldName "pass_${passKey}_findings"
                if (-not [string]::IsNullOrWhiteSpace($legacyValue) -and $legacyValue -notin @('n/a', 'N/A')) {
                    $passFindingsMap[$passKey] = ConvertTo-IntSafe $legacyValue
                }
            }
        }

        $summary = @{
            prosecution_findings = ConvertTo-IntSafe (Get-YamlField -Block $metricsBlock -FieldName 'prosecution_findings')
            pass_findings        = $passFindingsMap
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
        $calibDir = Join-Path -Path (Get-Location).Path -ChildPath '.copilot-tracking' -AdditionalChildPath 'calibration'
        $dataFile = Join-Path $calibDir 'review-data.json'
        $tmpFile = "$dataFile.tmp"

        if (Test-Path $dataFile) {
            $data = Get-Content $dataFile -Raw | ConvertFrom-Json -AsHashtable
        }
        else {
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
        $outputDoc = [ordered]@{}
        foreach ($key in $data.Keys) { $outputDoc[$key] = $data[$key] }
        $outputDoc['entries'] = $mergedEntries

        try {
            $json = $outputDoc | ConvertTo-Json -Depth 10
            Set-Content -Path $tmpFile -Value $json -Encoding UTF8
            $null = Get-Content $tmpFile -Raw | ConvertFrom-Json
            Move-Item -Path $tmpFile -Destination $dataFile -Force
        }
        catch {
            if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
            return @{ ExitCode = 1; Output = ''; Error = "Batch write failed: $_" }
        }

        return @{ ExitCode = 0; Output = "Backfilled $($pendingEntries.Count) entries."; Error = '' }
    }

    return @{ ExitCode = 0; Output = ''; Error = '' }
}
