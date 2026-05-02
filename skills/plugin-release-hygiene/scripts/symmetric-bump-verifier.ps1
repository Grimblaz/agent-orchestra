#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies that all version-bearing manifest files carry the same version string
    (symmetric bump) and persists the result as a v4 release-hygiene credit to
    the .claude/.state/release-hygiene-{slug}.json state file.

.DESCRIPTION
    Three result paths (issue #441, Step 7a — D-new-5):

      passed         — All five manifest files carry the same version.
      failed         — At least one file has a different version (drift).
      not-applicable — No manifest file appears in the touched-files set
                       (auto: no manifest change).

    Manifest set (5 files, matching bump-version.ps1):
      plugin.json
      .claude-plugin/plugin.json
      .claude-plugin/marketplace.json   (2 version occurrences)
      .github/plugin/marketplace.json   (2 version occurrences)
      README.md

    Output credit shape (v4 frame port):
      port:        release-hygiene
      adapter:     symmetric-bump
      status:      passed | failed | not-applicable
      evidence:    human-readable string
      verified_at: ISO-8601 UTC timestamp

.NOTES
    Intended to be dot-sourced by Pester tests and by the PostToolUse hook.
    When dot-sourced, no entry-point code runs.
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Manifest configuration (mirrors bump-version.ps1)
# ---------------------------------------------------------------------------

$script:SBVManifests = @(
    @{ RelPath = 'plugin.json';                         Pattern = '"version":\s*"([\d.]+)"'; Expected = 1 }
    @{ RelPath = '.claude-plugin/plugin.json';           Pattern = '"version":\s*"([\d.]+)"'; Expected = 1 }
    @{ RelPath = '.claude-plugin/marketplace.json';      Pattern = '"version":\s*"([\d.]+)"'; Expected = 2 }
    @{ RelPath = '.github/plugin/marketplace.json';      Pattern = '"version":\s*"([\d.]+)"'; Expected = 2 }
    @{ RelPath = 'README.md';                            Pattern = 'version-v([\d.]+)-blue';  Expected = 1 }
)

# Normalized relative paths used for touched-file matching.
$script:SBVManifestRelPaths = $script:SBVManifests | ForEach-Object { $_.RelPath }

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function script:Get-SBVManifestVersions {
    <#
    .SYNOPSIS
        Reads all manifest files from $RepoRoot and returns version information.

    .OUTPUTS
        [pscustomobject]@{
            in_lockstep   : $true | $false
            version       : '2.8.0'  (if in_lockstep) | $null
            drift_details : @( @{ file; found_versions } )  (if not in_lockstep)
            missing_files : @( 'path' )
        }
        Returns $null if any mandatory file is unreadable.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $allVersions     = [System.Collections.Generic.List[string]]::new()
    $perFileVersions = [ordered]@{}
    $missingFiles    = [System.Collections.Generic.List[string]]::new()

    foreach ($manifest in $script:SBVManifests) {
        $fullPath = Join-Path $RepoRoot $manifest.RelPath
        if (-not (Test-Path $fullPath)) {
            $missingFiles.Add($manifest.RelPath)
            continue
        }

        try {
            $content = [System.IO.File]::ReadAllText($fullPath)
        }
        catch {
            return $null
        }

        $matches = [regex]::Matches($content, $manifest.Pattern)
        if ($matches.Count -lt $manifest.Expected) {
            $missingFiles.Add($manifest.RelPath)
            continue
        }

        $fileVersions = @($matches | ForEach-Object { $_.Groups[1].Value })
        $perFileVersions[$manifest.RelPath] = $fileVersions
        foreach ($v in $fileVersions) {
            $allVersions.Add($v)
        }
    }

    if ($allVersions.Count -eq 0) {
        return $null
    }

    $distinct = @($allVersions | Sort-Object -Unique)

    if ($distinct.Count -eq 1 -and $missingFiles.Count -eq 0) {
        return [pscustomobject]@{
            in_lockstep   = $true
            version       = $distinct[0]
            drift_details = @()
            missing_files = @()
        }
    }

    # Build per-file drift detail.
    $driftDetails = [System.Collections.Generic.List[object]]::new()
    foreach ($kv in $perFileVersions.GetEnumerator()) {
        $uniqueInFile = @($kv.Value | Sort-Object -Unique)
        $driftDetails.Add([pscustomobject]@{
            file            = $kv.Key
            found_versions  = $uniqueInFile -join ', '
        })
    }
    foreach ($mf in $missingFiles) {
        $driftDetails.Add([pscustomobject]@{
            file           = $mf
            found_versions = '(missing or unreadable)'
        })
    }

    return [pscustomobject]@{
        in_lockstep   = $false
        version       = $null
        drift_details = @($driftDetails)
        missing_files = @($missingFiles)
    }
}

function script:Test-SBVManifestTouched {
    <#
    .SYNOPSIS
        Returns $true when at least one entry in $TouchedFiles matches a manifest path.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$TouchedFiles
    )

    foreach ($touched in $TouchedFiles) {
        $normalized = ($touched -replace '\\', '/') -replace '^(\./|\.\\)', ''
        if ($script:SBVManifestRelPaths -contains $normalized) {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Merge-SymmetricBumpCreditToStateFile {
    <#
    .SYNOPSIS
        Reads $StatePath (if it exists), sets/overwrites the `symmetric_bump_credit`
        field from $Credit, and writes the merged object back.

    .NOTES
        Creates the file if it does not exist. Preserves all other top-level fields.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatePath,

        [Parameter(Mandatory)]
        [pscustomobject]$Credit
    )

    $state = $null
    if (Test-Path $StatePath) {
        try {
            $raw = Get-Content -Path $StatePath -Raw -ErrorAction Stop
            $state = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $state = $null
        }
    }

    if ($null -eq $state) {
        $state = [pscustomobject]@{}
    }

    # Add or overwrite symmetric_bump_credit.
    if ($null -ne $state.PSObject.Properties['symmetric_bump_credit']) {
        $state.symmetric_bump_credit = $Credit
    }
    else {
        $state | Add-Member -MemberType NoteProperty -Name 'symmetric_bump_credit' -Value $Credit -Force
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $json      = $state | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($StatePath, $json, $utf8NoBom)
}

function Invoke-SymmetricBumpVerifier {
    <#
    .SYNOPSIS
        Verifies symmetric-bump status for the given repo root and touched-file set.

    .PARAMETER RepoRoot
        Absolute path to the repository root (where plugin.json lives).

    .PARAMETER TouchedFiles
        Array of repo-relative paths edited in the current session/hook run.
        Slash-normalized; forward or backward slash accepted.

    .PARAMETER StatePath
        Optional. If provided, the credit result is merged into this state file
        via Merge-SymmetricBumpCreditToStateFile.

    .OUTPUTS
        [pscustomobject]@{
            port        = 'release-hygiene'
            adapter     = 'symmetric-bump'
            status      = 'passed' | 'failed' | 'not-applicable'
            evidence    = <string>
            verified_at = <ISO-8601 UTC>
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$TouchedFiles,

        [string]$StatePath
    )

    $verifiedAt = (Get-Date).ToUniversalTime().ToString('o')

    # Path: not-applicable — no manifest in touched set.
    if (-not (script:Test-SBVManifestTouched -TouchedFiles $TouchedFiles)) {
        $credit = [pscustomobject]@{
            port        = 'release-hygiene'
            adapter     = 'symmetric-bump'
            status      = 'not-applicable'
            evidence    = 'not-applicable (auto: no manifest change)'
            verified_at = $verifiedAt
        }

        if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
            Merge-SymmetricBumpCreditToStateFile -StatePath $StatePath -Credit $credit
        }
        return $credit
    }

    # Read all manifest versions.
    $versionState = script:Get-SBVManifestVersions -RepoRoot $RepoRoot

    if ($null -eq $versionState) {
        # Cannot read manifests — treat as failed.
        $credit = [pscustomobject]@{
            port        = 'release-hygiene'
            adapter     = 'symmetric-bump'
            status      = 'failed'
            evidence    = 'drift: unable to read one or more manifest files'
            verified_at = $verifiedAt
        }

        if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
            Merge-SymmetricBumpCreditToStateFile -StatePath $StatePath -Credit $credit
        }
        return $credit
    }

    # Path: passed — all in lockstep.
    if ($versionState.in_lockstep) {
        $credit = [pscustomobject]@{
            port        = 'release-hygiene'
            adapter     = 'symmetric-bump'
            status      = 'passed'
            evidence    = "all manifests at $($versionState.version)"
            verified_at = $verifiedAt
        }

        if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
            Merge-SymmetricBumpCreditToStateFile -StatePath $StatePath -Credit $credit
        }
        return $credit
    }

    # Path: failed — drift detected.
    $driftLines = $versionState.drift_details | ForEach-Object {
        "$($_.file): $($_.found_versions)"
    }
    $evidence = "drift: version mismatch across manifests — " + ($driftLines -join '; ')

    $credit = [pscustomobject]@{
        port        = 'release-hygiene'
        adapter     = 'symmetric-bump'
        status      = 'failed'
        evidence    = $evidence
        verified_at = $verifiedAt
    }

    if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
        Merge-SymmetricBumpCreditToStateFile -StatePath $StatePath -Credit $credit
    }
    return $credit
}

# ---------------------------------------------------------------------------
# Entry-point guard — do not run when dot-sourced
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "symmetric-bump-verifier.ps1: dot-source this file to use its functions." -ForegroundColor Yellow
}
