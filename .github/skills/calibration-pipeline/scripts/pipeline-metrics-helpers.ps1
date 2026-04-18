#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for parsing pipeline-metrics YAML blocks.
    Dot-sourced by aggregate-review-scores.ps1 and backfill-calibration.ps1.
#>

# Caller contract: dot-source this file before using Get-YamlField or Get-FindingsArray.
# Example: . (Join-Path $PSScriptRoot 'lib\pipeline-metrics-helpers.ps1')

# ---------------------------------------------------------------------------
# Helper: extract a flat YAML field value from a text block
# ---------------------------------------------------------------------------
function Get-YamlField {
    param([string]$Block, [string]$FieldName)
    $m = [regex]::Match($Block, "(?m)^$([regex]::Escape($FieldName)):\s*(.+)$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# ---------------------------------------------------------------------------
# Helper: parse the findings: array from a v2 metrics block
# ---------------------------------------------------------------------------
function Get-FindingsArray {
    param([string]$Block)

    $findings = [System.Collections.Generic.List[hashtable]]::new()
    $findingsKeyPattern = '^findings:\s*$'  # $ is regex end-anchor; interpolates safely in double-quoted strings
    $findingsEmptyPattern = '^findings:\s*\[\]\s*$'  # canonical v2 zero-findings form

    # Recognize canonical zero-findings form: findings: []
    if ([regex]::IsMatch($Block, "(?m)$findingsEmptyPattern")) { Write-Output -NoEnumerate $findings; return }

    # Locate start of findings: section (multi-line form)
    if (-not [regex]::IsMatch($Block, "(?m)$findingsKeyPattern")) { Write-Output -NoEnumerate $findings; return }

    $blockLines = $Block -split "`n"
    $inFindings = $false
    $current = $null

    foreach ($line in $blockLines) {
        if (-not $inFindings) {
            if ($line -match $findingsKeyPattern) {
                $inFindings = $true
            }
            continue
        }

        # New finding entry
        if ($line -match '^\s+-\s+([a-z_]+):\s*(.*)$') {
            if ($null -ne $current) { $findings.Add($current) }
            $current = @{}
            $current[$Matches[1].Trim()] = $Matches[2].Trim()
            continue
        }

        # Stop if we hit a top-level key
        if ($line -match '^[a-z0-9_]+:') {
            if ($null -ne $current) { $findings.Add($current) }
            $current = $null
            break
        }

        # Field within current entry
        if ($null -ne $current -and $line -match '^\s{2,}([a-z_]+):\s*(.*)$') {
            $current[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }

    if ($null -ne $current) { $findings.Add($current) }
    Write-Output -NoEnumerate $findings
}
