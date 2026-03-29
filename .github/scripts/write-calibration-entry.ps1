#Requires -Version 7.0
<#
.SYNOPSIS
    Writes a review calibration entry and/or re-activation event to .copilot-tracking/calibration/review-data.json.

.PARAMETER EntryJson
    JSON string representing the calibration entry to write. At least one of -EntryJson or -ReactivationEventJson is required.

.PARAMETER ReactivationEventJson
    JSON string representing a re-activation event to write. Required fields: category, triggered_at_pr, expires_at_pr, trigger_source.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$EntryJson,

    [Parameter()]
    [string]$ReactivationEventJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────

function Test-HasProperty {
    param($Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
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

# ── At-least-one validation ────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($EntryJson) -and [string]::IsNullOrWhiteSpace($ReactivationEventJson)) {
    Write-ValidationError "At least one of -EntryJson or -ReactivationEventJson must be provided."
}

# ── Parse and validate entry (conditional) ─────────────────────────────────────

$entry = $null
if (-not [string]::IsNullOrWhiteSpace($EntryJson)) {
    try {
        $entry = $EntryJson | ConvertFrom-Json -AsHashtable
    }
    catch {
        Write-Error "Failed to parse -EntryJson: $_" -ErrorAction Continue
        exit 1
    }

    # ── Validate top-level required fields ────────────────────────────────────

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

    # ── Validate findings ─────────────────────────────────────────────────────

    if (Test-HasProperty $entry 'findings') {
        $requiredFindingFields = @('id', 'category', 'judge_ruling')
        foreach ($finding in $entry.findings) {
            $isExpressLane = (Test-HasProperty $finding 'express_lane') -and ($finding.express_lane -eq $true -or $finding.express_lane -eq 'true')
            foreach ($field in $requiredFindingFields) {
                if ($field -eq 'judge_ruling' -and $isExpressLane) { continue }
                if (-not (Test-HasProperty $finding $field)) {
                    Write-ValidationError "Validation failed: a finding is missing required field '$field'."
                }
            }
        }
    }

    # ── Validate summary sub-fields ───────────────────────────────────────────

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

    # ── Normalize DateTime values to compact ISO strings ──────────────────────

    $entry = ConvertTo-NormalizedObject $entry
}

# ── Parse and validate re-activation event (conditional) ──────────────────────

$reactivationEvent = $null
if (-not [string]::IsNullOrWhiteSpace($ReactivationEventJson)) {
    try {
        $reactivationEvent = $ReactivationEventJson | ConvertFrom-Json -AsHashtable
    }
    catch {
        Write-ValidationError "ReactivationEventJson is not valid JSON: $_"
    }

    if (-not (Test-HasProperty $reactivationEvent 'category')) {
        Write-ValidationError "Re-activation event missing required field: category"
    }
    if (-not (Test-HasProperty $reactivationEvent 'triggered_at_pr')) {
        Write-ValidationError "Re-activation event missing required field: triggered_at_pr"
    }
    if (-not (Test-HasProperty $reactivationEvent 'expires_at_pr')) {
        Write-ValidationError "re-activation event missing required field 'expires_at_pr'"
    }
    if (-not (Test-HasProperty $reactivationEvent 'trigger_source')) {
        Write-ValidationError "re-activation event missing required field 'trigger_source'"
    }
    # Range check (only if both are present):
    if ((Test-HasProperty $reactivationEvent 'expires_at_pr') -and (Test-HasProperty $reactivationEvent 'triggered_at_pr')) {
        try {
            if ([int]$reactivationEvent.expires_at_pr -le [int]$reactivationEvent.triggered_at_pr) {
                Write-ValidationError "re-activation event 'expires_at_pr' ($($reactivationEvent.expires_at_pr)) must be greater than 'triggered_at_pr' ($($reactivationEvent.triggered_at_pr))"
            }
        }
        catch {
            Write-ValidationError "re-activation event 'expires_at_pr' and 'triggered_at_pr' must be integers"
            return
        }
    }

    $reactivationEvent = ConvertTo-NormalizedObject $reactivationEvent
}

# ── Resolve paths ──────────────────────────────────────────────────────────────

$calibDir = Join-Path -Path (Get-Location).Path -ChildPath '.copilot-tracking' -AdditionalChildPath 'calibration'
$dataFile = Join-Path -Path $calibDir -ChildPath 'review-data.json'
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

# ── Deduplicate by pr_number, then append new entry (if provided) ─────────────

if ($null -ne $entry) {
    $prNumber = $entry.pr_number
    $filtered = @($data.entries | Where-Object { $_.pr_number -ne $prNumber })
    $data['entries'] = $filtered + @($entry)
}

# ── Re-activation event handling ──────────────────────────────────────────────

if (-not (Test-HasProperty $data 're_activation_events')) {
    $data['re_activation_events'] = @()
}

if ($null -ne $reactivationEvent) {
    $data['re_activation_events'] = @($data['re_activation_events'] | Where-Object {
            -not ($_.category -eq $reactivationEvent.category -and [int]$_.triggered_at_pr -eq [int]$reactivationEvent.triggered_at_pr)
        })
    $data['re_activation_events'] += $reactivationEvent
}

# ── Build output — preserve all top-level keys from existing data ──────────────

$output = [ordered]@{}
foreach ($key in $data.Keys) { $output[$key] = $data[$key] }

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
