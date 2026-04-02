#Requires -Version 7.0
<#
.SYNOPSIS
    Library for write-calibration-entry logic. Dot-source this file and call Invoke-WriteCalibrationEntry.
#>

function Test-WCEHasProperty {
    param($Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

# Recursively convert DateTime values to compact ISO 8601 strings.
# ConvertFrom-Json (even with -AsHashtable) may parse ISO date strings into
# DateTime objects; this normalizer restores them to the original string form
# so round-trips do not add fractional-second noise.
function ConvertTo-WCENormalizedObject {
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
        foreach ($key in $obj.Keys) { $out[$key] = ConvertTo-WCENormalizedObject $obj[$key] }
        return $out
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        return , @($obj | ForEach-Object { ConvertTo-WCENormalizedObject $_ })
    }
    return $obj
}

function Invoke-WriteCalibrationEntry {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$EntryJson = '',
        [string]$ReactivationEventJson = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # ── At-least-one validation ────────────────────────────────────────────────────

    if ([string]::IsNullOrWhiteSpace($EntryJson) -and [string]::IsNullOrWhiteSpace($ReactivationEventJson)) {
        return @{ ExitCode = 1; Output = ''; Error = 'At least one of -EntryJson or -ReactivationEventJson must be provided.' }
    }

    # ── Parse and validate entry (conditional) ─────────────────────────────────────

    $entry = $null
    if (-not [string]::IsNullOrWhiteSpace($EntryJson)) {
        try {
            $entry = $EntryJson | ConvertFrom-Json -AsHashtable
        }
        catch {
            return @{ ExitCode = 1; Output = ''; Error = "Failed to parse -EntryJson: $_" }
        }

        # ── Validate top-level required fields ────────────────────────────────────

        if (-not (Test-WCEHasProperty $entry 'pr_number')) {
            return @{ ExitCode = 1; Output = ''; Error = "Validation failed: required top-level field 'pr_number' is missing." }
        }
        try {
            if ([int]$entry['pr_number'] -le 0) { throw "pr_number must be a positive integer" }
        }
        catch {
            return @{ ExitCode = 1; Output = ''; Error = "Validation failed: 'pr_number' must be a positive integer. Got: $($entry['pr_number'])" }
        }
        if (-not (Test-WCEHasProperty $entry 'created_at')) {
            return @{ ExitCode = 1; Output = ''; Error = "Validation failed: required top-level field 'created_at' is missing." }
        }
        try {
            $rawCreatedAt = $entry['created_at']
            if ($rawCreatedAt -isnot [datetime]) {
                [void][datetime]::Parse([string]$rawCreatedAt, [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }
        catch {
            return @{ ExitCode = 1; Output = ''; Error = "Validation failed: 'created_at' must be a parseable ISO 8601 datetime string. Got: $($entry['created_at'])" }
        }

        # ── Validate findings ─────────────────────────────────────────────────────

        if (Test-WCEHasProperty $entry 'findings') {
            $requiredFindingFields = @('id', 'category', 'judge_ruling')
            foreach ($finding in $entry.findings) {
                $isExpressLane = (Test-WCEHasProperty $finding 'express_lane') -and ($finding.express_lane -eq $true -or $finding.express_lane -eq 'true')
                foreach ($field in $requiredFindingFields) {
                    if ($field -eq 'judge_ruling' -and $isExpressLane) { continue }
                    if (-not (Test-WCEHasProperty $finding $field)) {
                        return @{ ExitCode = 1; Output = ''; Error = "Validation failed: a finding is missing required field '$field'." }
                    }
                }
            }
        }

        # ── Validate summary sub-fields ───────────────────────────────────────────

        if (Test-WCEHasProperty $entry 'summary') {
            $requiredSummaryFields = @(
                'prosecution_findings', 'pass_1_findings', 'pass_2_findings',
                'pass_3_findings', 'defense_disproved', 'judge_accepted',
                'judge_rejected', 'judge_deferred'
            )
            foreach ($field in $requiredSummaryFields) {
                if (-not (Test-WCEHasProperty $entry.summary $field)) {
                    return @{ ExitCode = 1; Output = ''; Error = "Validation failed: summary is missing required field '$field'." }
                }
            }
        }

        # ── Normalize DateTime values to compact ISO strings ──────────────────────

        $entry = ConvertTo-WCENormalizedObject $entry
    }

    # ── Parse and validate re-activation event (conditional) ──────────────────────

    $reactivationEvent = $null
    if (-not [string]::IsNullOrWhiteSpace($ReactivationEventJson)) {
        try {
            $reactivationEvent = $ReactivationEventJson | ConvertFrom-Json -AsHashtable
        }
        catch {
            return @{ ExitCode = 1; Output = ''; Error = "ReactivationEventJson is not valid JSON: $_" }
        }

        if (-not (Test-WCEHasProperty $reactivationEvent 'category')) {
            return @{ ExitCode = 1; Output = ''; Error = 'Re-activation event missing required field: category' }
        }
        if (-not (Test-WCEHasProperty $reactivationEvent 'triggered_at_pr')) {
            return @{ ExitCode = 1; Output = ''; Error = 'Re-activation event missing required field: triggered_at_pr' }
        }
        if (-not (Test-WCEHasProperty $reactivationEvent 'expires_at_pr')) {
            return @{ ExitCode = 1; Output = ''; Error = "re-activation event missing required field 'expires_at_pr'" }
        }
        if (-not (Test-WCEHasProperty $reactivationEvent 'trigger_source')) {
            return @{ ExitCode = 1; Output = ''; Error = "re-activation event missing required field 'trigger_source'" }
        }
        # Range check (only if both are present):
        if ((Test-WCEHasProperty $reactivationEvent 'expires_at_pr') -and (Test-WCEHasProperty $reactivationEvent 'triggered_at_pr')) {
            try {
                if ([int]$reactivationEvent.expires_at_pr -le [int]$reactivationEvent.triggered_at_pr) {
                    return @{ ExitCode = 1; Output = ''; Error = "re-activation event 'expires_at_pr' ($($reactivationEvent.expires_at_pr)) must be greater than 'triggered_at_pr' ($($reactivationEvent.triggered_at_pr))" }
                }
            }
            catch {
                return @{ ExitCode = 1; Output = ''; Error = "re-activation event 'expires_at_pr' and 'triggered_at_pr' must be integers" }
            }
        }

        $reactivationEvent = ConvertTo-WCENormalizedObject $reactivationEvent
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

    if (-not (Test-WCEHasProperty $data 're_activation_events')) {
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
        return @{ ExitCode = 1; Output = ''; Error = "Failed to write calibration data: $_" }
    }

    return @{ ExitCode = 0; Output = ''; Error = '' }
}
