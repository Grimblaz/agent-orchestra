#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'powershell-yaml'; ModuleVersion = '0.4.0' }

<#
.SYNOPSIS
    Warn-only validator for <!-- review-dispositions-{PR} --> PR-comment markers (SMC-23).

.DESCRIPTION
    Finds <!-- review-dispositions-{PR} --> comments on a GitHub PR, parses their YAML
    payloads, and validates against the review-dispositions payload schema:
      - schema_version must be 1, 2, or 3 (`{1,2,3}`). v1 entries are exempt from ac_cross_check checks.
      - passes_run must be a non-empty subset of [1,2,3,4,5]
      - entries[] must each carry stable_finding_key, pass, disposition, classification,
        disposition_rationale
    Warn-only: never throws, never returns non-zero exit code, never blocks PR creation.

    SMC-19 invariant: does NOT read or write design-phase-complete markers.
    SMC-23: this is the dedicated validator for review-dispositions-{PR} markers.

.PARAMETER PullRequestNumber
    The GitHub PR number to validate.

.PARAMETER Repo
    Optional. GitHub repository in owner/name format.

.PARAMETER GhCliPath
    Optional. Path to the gh CLI.

.PARAMETER InMemoryMarkers
    Optional. Raw marker strings for tests / in-session use without gh.

.OUTPUTS
    [hashtable] with keys:
      findings      - array of hashtable {pr, issue, severity: 'warn', message}
      marker_count  - total review-dispositions markers found
      entry_count   - total entries across all markers
      status        - 'clean' | 'findings'
#>

# SMC-19 invariant: this validator is deliberately separate from
# design-disposition-audit.Tests.ps1, which validates finding_dispositions on
# design-phase-complete markers. review-dispositions are PR-keyed (SMC-23);
# design finding_dispositions are issue-keyed (SMC-19). Never merge these paths.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$PullRequestNumber,

    [string]$Repo = '',
    [string]$GhCliPath = 'gh',
    [string[]]$InMemoryMarkers = @()
)

$ErrorActionPreference = 'Stop'

$findings = @()
$markerCount = 0
$entryCount = 0

function Add-RdvFinding {
    param([string]$Msg)
    $script:findings += @{ pr = $PullRequestNumber; severity = 'warn'; message = $Msg }
}

# ─── Gather raw markers ───────────────────────────────────────────────────────

$rawBodies = @()

if ($InMemoryMarkers.Count -gt 0) {
    $rawBodies = $InMemoryMarkers
} else {
    if ([string]::IsNullOrWhiteSpace($Repo)) {
        try {
            $Repo = & git config --get remote.origin.url
            if ($Repo -match 'github\.com[:/]([^/]+/[^/.]+)(\.git)?') { $Repo = $Matches[1] }
            if ($Repo -notmatch '^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$') { $Repo = '' }
        } catch { Write-Warning "Could not resolve repo: $_" }
    }
    try {
        $rawJson = & $GhCliPath pr view $PullRequestNumber --repo $Repo --json comments 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rawJson)) {
            $commentsObj = $rawJson | ConvertFrom-Json
            foreach ($c in $commentsObj.comments) { $rawBodies += $c.body }
        }
    } catch { Write-Warning "gh pr view failed: $_" }
}

# ─── Parse and validate ───────────────────────────────────────────────────────

$markerPattern = '(?m)^\s*<!--\s*review-dispositions-(\d+)\s*-->'

foreach ($body in $rawBodies) {
    if ($body -notmatch $markerPattern) { continue }
    $commentPr = [int]$Matches[1]
    if ($commentPr -ne $PullRequestNumber) { continue }

    $markerCount++

    # Extract YAML
    $yamlContent = $null
    if ($body -match '```yaml\s*([\s\S]*?)```') {
        $yamlContent = $Matches[1].Trim()
    } else {
        $idx = $body.IndexOf("-->")
        if ($idx -ge 0) { $yamlContent = $body.Substring($idx + 3).Trim() }
    }

    if ([string]::IsNullOrWhiteSpace($yamlContent)) {
        Add-RdvFinding "review-dispositions-${PullRequestNumber}: marker found but no YAML payload"
        continue
    }

    try {
        Import-Module powershell-yaml -ErrorAction Stop
        $payload = ConvertFrom-Yaml -Yaml $yamlContent
    } catch {
        Add-RdvFinding "review-dispositions-${PullRequestNumber}: YAML parse error: $_"
        continue
    }

    # schema_version
    if ($null -eq $payload.schema_version -or $payload.schema_version -notin @(1, 2, 3)) {
        Add-RdvFinding "review-dispositions-${PullRequestNumber}: schema_version must be 1, 2, or 3, got: $($payload.schema_version)"
    }

    # passes_run
    if ($null -eq $payload.passes_run -or $payload.passes_run.Count -eq 0) {
        Add-RdvFinding "review-dispositions-${PullRequestNumber}: passes_run must be a non-empty subset of [1,2,3,4,5]"
    } else {
        $uniquePasses = $payload.passes_run | Select-Object -Unique
        if ($uniquePasses.Count -ne $payload.passes_run.Count) {
            Add-RdvFinding "review-dispositions-${PullRequestNumber}: passes_run contains duplicate values (must be unique per schema uniqueItems)"
        }
        foreach ($p in $payload.passes_run) {
            if ($p -notin @(1, 2, 3, 4, 5)) {
                Add-RdvFinding "review-dispositions-${PullRequestNumber}: passes_run contains invalid value: $p (must be 1-5)"
            }
        }
    }

    # entries
    if ($null -eq $payload.entries) {
        Add-RdvFinding "review-dispositions-${PullRequestNumber}: entries[] is required"
    } else {
        $idx = 0
        foreach ($entry in $payload.entries) {
            $entryCount++
            $entryLabel = "entry[$idx]"
            if ([string]::IsNullOrWhiteSpace($entry.stable_finding_key)) {
                Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel missing required stable_finding_key"
            }
            if ($entry.pass -notin @(1, 2, 3, 4, 5)) {
                Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel pass must be 1-5"
            }
            if ($null -ne $entry.pass_role -and $entry.pass_role -notin @('generalist-A', 'generalist-B', 'spec-correctness', 'spec-security', 'spec-architecture')) {
                Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel pass_role must be one of generalist-A|generalist-B|spec-correctness|spec-security|spec-architecture"
            }
            if ($entry.disposition -notin @('incorporate', 'dismiss', 'escalate', 'defer')) {
                Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel disposition must be incorporate|dismiss|escalate|defer"
            }
            if ($entry.classification -notin @('load-bearing', 'routine')) {
                Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel classification must be load-bearing|routine"
            }
            if ([string]::IsNullOrWhiteSpace($entry.disposition_rationale)) {
                Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel missing required disposition_rationale"
            }
            # v2/v3: ac_cross_check required on >=medium dismiss/defer entries
            if ($payload.schema_version -in @(2, 3)) {
                $mediumOrAbove = @('medium', 'high', 'critical')
                $dismissOrDefer = @('dismiss', 'defer')
                if ($entry.disposition -in $dismissOrDefer -and $entry.severity -in $mediumOrAbove) {
                    if ($null -eq $entry.ac_cross_check) {
                        Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel (v$($payload.schema_version)) dismiss/defer entry at severity '$($entry.severity)' is missing required ac_cross_check"
                    }
                }
            }
            if ($null -ne $entry.also_flagged_by -and $entry.also_flagged_by.Count -gt 0) {
                $uniqueAlso = $entry.also_flagged_by | Select-Object -Unique
                if ($uniqueAlso.Count -ne $entry.also_flagged_by.Count) {
                    Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel also_flagged_by contains duplicate pass IDs (must be unique)"
                }
                foreach ($af in $entry.also_flagged_by) {
                    if ($af -notin @(1, 2, 3, 4, 5)) {
                        Add-RdvFinding "review-dispositions-${PullRequestNumber}: $entryLabel also_flagged_by contains invalid value: $af (must be 1-5)"
                    }
                }
            }
            $idx++
        }
    }
}

$status = if ($findings.Count -gt 0) { 'findings' } else { 'clean' }
return @{
    findings     = $findings
    marker_count = $markerCount
    entry_count  = $entryCount
    status       = $status
}
