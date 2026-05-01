#Requires -Version 7.0
<#
.SYNOPSIS
    Core helper library for regime checkpoint management (issue #467, Step 6).
.DESCRIPTION
    Provides Get-MostRecentRegimeCheckpoint and Add-RegimeCheckpoint for reading
    and writing to the cost-regime-checkpoints.yaml accumulation file.

    The loader uses simple YAML line-parsing — no external module required.
    Since checkpoints accumulate by append, the most-recent entry is determined
    by comparing timestamp values.
#>

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function script:ConvertFrom-CheckpointYaml {
    <#
    .SYNOPSIS
        Parses the checkpoints array from a cost-regime-checkpoints.yaml file.
        Returns an array of hashtables, one per checkpoint entry.
    #>
    param([string]$Content)

    $lines = $Content -split '\r?\n'
    $checkpoints = [System.Collections.Generic.List[hashtable]]::new()

    $inCheckpoints = $false
    $current       = $null

    foreach ($line in $lines) {
        # Detect the start of the checkpoints array
        if ($line -match '^\s*checkpoints\s*:\s*(\[\s*\])?\s*$') {
            $inCheckpoints = $true
            # If inline empty array "checkpoints: []" — nothing more to parse
            if ($line -match '\[\s*\]') { $inCheckpoints = $false }
            continue
        }

        if (-not $inCheckpoints) { continue }

        # New entry starts with a list item "  - id:" or "  - timestamp:" etc.
        if ($line -match '^\s+-\s+(\w+)\s*:\s*(.*)$') {
            if ($null -ne $current) { $checkpoints.Add($current) }
            $current = @{}
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim().Trim('"')
            $current[$key] = $val
            continue
        }

        # Continuation key inside an entry (scalar fields)
        if ($null -ne $current -and $line -match '^\s+(\w[^:]*)\s*:\s*(.*)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim().Trim('"')
            # Only store scalar (non-empty) values; skip sub-block openers like "metrics:"
            if ($val -ne '') {
                $current[$key] = $val
            }
            continue
        }
    }

    if ($null -ne $current) { $checkpoints.Add($current) }

    return , $checkpoints.ToArray()
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function Get-MostRecentRegimeCheckpoint {
    <#
    .SYNOPSIS
        Reads cost-regime-checkpoints.yaml and returns the entry with the most
        recent timestamp, or $null if the file is absent or has no entries.
    .PARAMETER Path
        Absolute path to the checkpoints YAML file.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    $entries = script:ConvertFrom-CheckpointYaml -Content $content
    if ($null -eq $entries -or $entries.Count -eq 0) {
        return $null
    }

    # Find the entry with the greatest timestamp (ISO-8601 lexicographic sort is correct)
    $best = $null
    foreach ($entry in $entries) {
        if ($null -eq $best) {
            $best = $entry
            continue
        }
        $bestTs = [string]$best['timestamp']
        $curTs  = [string]$entry['timestamp']
        if ([string]::Compare($curTs, $bestTs, [System.StringComparison]::Ordinal) -gt 0) {
            $best = $entry
        }
    }

    return $best
}

function Add-RegimeCheckpoint {
    <#
    .SYNOPSIS
        Appends a checkpoint entry to the YAML file.
        Creates the file with a schema_version header if absent.
    .PARAMETER Path
        Absolute path to the checkpoints YAML file.
    .PARAMETER Entry
        Hashtable describing the checkpoint. Expected keys:
            id, timestamp, sub_issue, reason, note, metrics, exclusions
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Entry
    )

    # Ensure parent directory exists
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Bootstrap file if absent
    if (-not (Test-Path -LiteralPath $Path)) {
        @"
schema_version: 1
checkpoints: []
"@ | Set-Content -Path $Path -Encoding UTF8 -NoNewline:$false
    }

    # Build the YAML block for this entry
    $id        = [string]$Entry['id']
    $timestamp = [string]$Entry['timestamp']
    $subIssue  = if ($Entry.ContainsKey('sub_issue') -and -not [string]::IsNullOrEmpty($Entry['sub_issue'])) { [string]$Entry['sub_issue'] } else { '' }
    $reason    = [string]$Entry['reason']
    $note      = if ($Entry.ContainsKey('note') -and -not [string]::IsNullOrEmpty([string]$Entry['note'])) { [string]$Entry['note'] } else { '' }

    $metricsLines = ''
    if ($Entry.ContainsKey('metrics') -and $Entry['metrics'] -is [hashtable] -and $Entry['metrics'].Count -gt 0) {
        $metricsLines = ($Entry['metrics'].GetEnumerator() | Sort-Object Key | ForEach-Object {
            "      $($_.Key): $($_.Value)"
        }) -join "`n"
    }

    $exclusionsLines = ''
    if ($Entry.ContainsKey('exclusions') -and $Entry['exclusions'] -is [hashtable] -and $Entry['exclusions'].Count -gt 0) {
        $exclusionsLines = ($Entry['exclusions'].GetEnumerator() | Sort-Object Key | ForEach-Object {
            "      $($_.Key): $($_.Value)"
        }) -join "`n"
    }

    # Build YAML entry block
    $entryLines = [System.Collections.Generic.List[string]]::new()
    $entryLines.Add("  - id: `"$id`"")
    $entryLines.Add("    timestamp: `"$timestamp`"")
    if (-not [string]::IsNullOrEmpty($subIssue)) {
        $entryLines.Add("    sub_issue: `"$subIssue`"")
    }
    $entryLines.Add("    reason: `"$reason`"")
    if (-not [string]::IsNullOrEmpty($note)) {
        $entryLines.Add("    note: `"$note`"")
    }
    if (-not [string]::IsNullOrEmpty($metricsLines)) {
        $entryLines.Add('    metrics:')
        $entryLines.Add($metricsLines)
    }
    else {
        $entryLines.Add('    metrics: {}')
    }
    if (-not [string]::IsNullOrEmpty($exclusionsLines)) {
        $entryLines.Add('    exclusions:')
        $entryLines.Add($exclusionsLines)
    }
    else {
        $entryLines.Add('    exclusions: {}')
    }

    $entryBlock = $entryLines -join "`n"

    # Read existing file, strip trailing blank lines, then splice the new entry
    # after the checkpoints: [] or at the end of the checkpoints array.
    $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($existing)) {
        $existing = "schema_version: 1`ncheckpoints: []`n"
    }

    # Normalize line endings
    $existing = $existing -replace '\r\n', "`n" -replace '\r', "`n"

    # Replace "checkpoints: []" with the new entry in the array, or append to existing array
    if ($existing -match 'checkpoints:\s*\[\s*\]') {
        # Bootstrap case: replace empty array with list containing first entry
        $replacement = "checkpoints:`n$entryBlock"
        $result = $existing -replace 'checkpoints:\s*\[\s*\]', $replacement
    }
    else {
        # Append case: add new entry before any trailing newlines at end of file
        $result = $existing.TrimEnd("`n", "`r") + "`n" + $entryBlock + "`n"
    }

    Set-Content -Path $Path -Value $result -Encoding UTF8 -NoNewline
}
