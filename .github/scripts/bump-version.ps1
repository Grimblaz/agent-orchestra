#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Bumps the version string across all version-bearing files in the repo.

.DESCRIPTION
    Updates the version in plugin.json, marketplace.json (2 occurrences), and README.md
    (1 occurrence) — 4 occurrences total across 3 files.

    Before writing, verifies that all 4 current version values agree. If any differ,
    the script exits with an error and prints which file has the conflicting value.

.PARAMETER Version
    New version in MAJOR.MINOR.PATCH format (e.g., 1.6.0).

.PARAMETER DryRun
    Preview what would change without writing any files.

.OUTPUTS
    Exit code 0 on success, exit code 1 on validation failure or version drift.

.EXAMPLE
    .\bump-version.ps1 -Version 1.6.0
    .\bump-version.ps1 -Version 1.6.0 -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$Red    = "`e[31m"
$Green  = "`e[32m"
$Yellow = "`e[33m"
$Reset  = "`e[0m"

function Fail([string]$Message, [string]$Hint = '') {
    Write-Host "${Red}✗${Reset} $Message"
    if ($Hint) { Write-Host "${Yellow}  $Hint${Reset}" }
    exit 1
}

# --- Validate version format ---
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Fail "Invalid version format '$Version' — expected MAJOR.MINOR.PATCH (e.g., 1.6.0)"
}

# --- Resolve file paths ---
$repoRoot        = Resolve-Path (Join-Path $PSScriptRoot '../..')
$pluginJson      = Join-Path $repoRoot '.github/plugin/plugin.json'
$marketplaceJson = Join-Path $repoRoot '.github/plugin/marketplace.json'
$readme          = Join-Path $repoRoot 'README.md'

# --- Read files into memory (written back as UTF-8 without BOM) ---
$pluginContent      = [System.IO.File]::ReadAllText($pluginJson)
$marketplaceContent = [System.IO.File]::ReadAllText($marketplaceJson)
$readmeContent      = [System.IO.File]::ReadAllText($readme)

# --- Extract current versions ---
$pluginVersion      = [regex]::Match($pluginContent,      '"version":\s*"([\d.]+)"').Groups[1].Value
$marketplaceMatches = [regex]::Matches($marketplaceContent, '"version":\s*"([\d.]+)"')
if ($marketplaceMatches.Count -ne 2) {
    Fail "Expected exactly 2 'version' fields in marketplace.json, found $($marketplaceMatches.Count)"
}
$marketplaceVersion1 = $marketplaceMatches[0].Groups[1].Value
$marketplaceVersion2 = $marketplaceMatches[1].Groups[1].Value
$readmeVersion      = [regex]::Match($readmeContent, 'version-v([\d.]+)-blue').Groups[1].Value

# --- Pre-bump consistency check ---
$allVersions = [ordered]@{
    'plugin.json'                      = $pluginVersion
    'marketplace.json (metadata)'      = $marketplaceVersion1
    'marketplace.json (plugin version)' = $marketplaceVersion2
    'README.md'                        = $readmeVersion
}

$distinctVersions = @($allVersions.Values | Sort-Object -Unique)
if ($distinctVersions.Count -gt 1) {
    $detail = ($allVersions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
    Fail "Version drift detected: $detail" -Hint 'Fix the inconsistency manually before bumping.'
}

$currentVersion = $distinctVersions[0]
if ($currentVersion -eq '') {
    Fail 'Could not extract version from files — check that version strings match the pattern "version": "MAJOR.MINOR.PATCH"'
}
if ($currentVersion -notmatch '^\d+\.\d+\.\d+$') {
    Fail "Extracted version '$currentVersion' is not in MAJOR.MINOR.PATCH format — check version strings in tracked files"
}
Write-Host "Current version: ${Yellow}$currentVersion${Reset}"

# --- Dry run ---
if ($DryRun) {
    Write-Host "${Yellow}Dry run — no files will be modified${Reset}"
    Write-Host "  Would update .github/plugin/plugin.json: $currentVersion → $Version"
    Write-Host "  Would update .github/plugin/marketplace.json: $currentVersion → $Version (2 occurrences)"
    Write-Host "  Would update README.md: $currentVersion → $Version"
    Write-Host "${Green}✓${Reset} Dry run complete — 4 occurrences across 3 files"
    exit 0
}

# --- Live update ---
Write-Host "Bumping version: ${Yellow}$currentVersion${Reset} → ${Green}$Version${Reset}"

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$updatedPlugin = $pluginContent -replace '"version":\s*"[\d.]+"', "`"version`": `"$Version`""
[System.IO.File]::WriteAllText($pluginJson, $updatedPlugin, $utf8NoBom)
Write-Host "  ${Green}✓${Reset} Updated .github/plugin/plugin.json"

$updatedMarketplace = $marketplaceContent -replace '"version":\s*"[\d.]+"', "`"version`": `"$Version`""
[System.IO.File]::WriteAllText($marketplaceJson, $updatedMarketplace, $utf8NoBom)
Write-Host "  ${Green}✓${Reset} Updated .github/plugin/marketplace.json (2 occurrences)"

$updatedReadme = $readmeContent -replace 'version-v[\d.]+-blue', "version-v$Version-blue"
[System.IO.File]::WriteAllText($readme, $updatedReadme, $utf8NoBom)
Write-Host "  ${Green}✓${Reset} Updated README.md"

Write-Host "${Green}✓${Reset} Version bumped to $Version across 4 occurrences in 3 files"
