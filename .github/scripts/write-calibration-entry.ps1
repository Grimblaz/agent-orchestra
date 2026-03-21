#Requires -Version 7.0
<#
.SYNOPSIS
    Writes a review calibration entry to .copilot-tracking/calibration/review-data.json.

.PARAMETER EntryJson
    Mandatory JSON string representing the calibration entry to write.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EntryJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────

function Test-HasProperty {
    param($Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.ContainsKey($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Write-ValidationError {
    param([string]$Message)
    Write-Error $Message -ErrorAction Continue
    exit 1
}

# Recursively convert DateTime values to compact ISO 8601 strings.
# ConvertFrom-Json (even with -AsHashtable) may parse ISO date strings into
# DateTime objects; this normalizer restores them to the original string form
# so round-trips do not add fractional-second noise.
function ConvertTo-NormalizedObject {
    param($obj)
    if ($null -eq $obj) { return $null }
    if ($obj -is [datetime]) {
        $utc = if ($obj.Kind -eq [System.DateTimeKind]::Utc) { $obj } else { $obj.ToUniversalTime() }
        if ($utc.Millisecond -eq 0) {
            return $utc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        else {
            return $utc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }
    }
    if ($obj -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in $obj.Keys) { $out[$key] = ConvertTo-NormalizedObject $obj[$key] }
        return $out
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return , @($obj | ForEach-Object { ConvertTo-NormalizedObject $_ })
    }
    return $obj
}

# ── Parse input ────────────────────────────────────────────────────────────────

try {
    $entry = $EntryJson | ConvertFrom-Json -AsHashtable
}
catch {
    Write-Error "Failed to parse -EntryJson: $_" -ErrorAction Continue
    exit 1
}

# ── Validate top-level required fields ────────────────────────────────────────

if (-not (Test-HasProperty $entry 'pr_number')) {
    Write-ValidationError "Validation failed: required top-level field 'pr_number' is missing."
}
try {
    if ([int]$entry['pr_number'] -le 0) { throw "pr_number must be a positive integer" }
}
catch {
    Write-ValidationError "Validation failed: 'pr_number' must be a positive integer. Got: $($entry['pr_number'])"
}
if (-not (Test-HasProperty $entry 'created_at')) {
    Write-ValidationError "Validation failed: required top-level field 'created_at' is missing."
}
try {
    $rawCreatedAt = $entry['created_at']
    if ($rawCreatedAt -isnot [datetime]) {
        [void][datetime]::Parse([string]$rawCreatedAt, [System.Globalization.CultureInfo]::InvariantCulture)
    }
}
catch {
    Write-ValidationError "Validation failed: 'created_at' must be a parseable ISO 8601 datetime string. Got: $($entry['created_at'])"
}

# ── Validate findings ─────────────────────────────────────────────────────────

if (Test-HasProperty $entry 'findings') {
    $requiredFindingFields = @('id', 'category', 'judge_ruling')
    foreach ($finding in $entry.findings) {
        foreach ($field in $requiredFindingFields) {
            if (-not (Test-HasProperty $finding $field)) {
                Write-ValidationError "Validation failed: a finding is missing required field '$field'."
            }
        }
    }
}

# ── Validate summary sub-fields ───────────────────────────────────────────────

if (Test-HasProperty $entry 'summary') {
    $requiredSummaryFields = @(
        'prosecution_findings', 'pass_1_findings', 'pass_2_findings',
        'pass_3_findings', 'defense_disproved', 'judge_accepted',
        'judge_rejected', 'judge_deferred'
    )
    foreach ($field in $requiredSummaryFields) {
        if (-not (Test-HasProperty $entry.summary $field)) {
            Write-ValidationError "Validation failed: summary is missing required field '$field'."
        }
    }
}

# ── Normalize DateTime values to compact ISO strings (must be after validation) ─

$entry = ConvertTo-NormalizedObject $entry

# ── Resolve paths ──────────────────────────────────────────────────────────────

$calibDir = Join-Path (Get-Location).Path '.copilot-tracking' 'calibration'
$dataFile = Join-Path $calibDir 'review-data.json'
$tmpFile = "$dataFile.tmp"

# Clean up any stale .tmp from a previous incomplete run
if (Test-Path $tmpFile) {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

# ── Ensure directory exists ───────────────────────────────────────────────────

New-Item -ItemType Directory -Path $calibDir -Force | Out-Null

# ── Load or initialize data ───────────────────────────────────────────────────

if (Test-Path $dataFile) {
    $data = Get-Content $dataFile -Raw | ConvertFrom-Json -AsHashtable
}
else {
    $data = [ordered]@{
        calibration_version = 1
        entries             = @()
    }
}

# ── Deduplicate by pr_number, then append new entry ───────────────────────────

$prNumber = $entry.pr_number
$filtered = @($data.entries | Where-Object { $_.pr_number -ne $prNumber })
$newEntries = $filtered + @($entry)

# ── Build output — preserve all top-level keys from existing data ──────────────

$output = [ordered]@{}
foreach ($key in $data.Keys) { $output[$key] = $data[$key] }
$output['entries'] = $newEntries

# ── Crash-safe write: tmp → validate → rename ─────────────────────────────────

try {
    $json = $output | ConvertTo-Json -Depth 10
    Set-Content -Path $tmpFile -Value $json -Encoding UTF8

    # Validate the written file is parseable JSON before promoting it
    $null = Get-Content $tmpFile -Raw | ConvertFrom-Json

    Move-Item -Path $tmpFile -Destination $dataFile -Force
}
catch {
    if (Test-Path $tmpFile) {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
    Write-Error "Failed to write calibration data: $_" -ErrorAction Continue
    exit 1
}

exit 0
