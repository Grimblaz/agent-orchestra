#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Bumps the version string across all version-bearing files in the repo.

.DESCRIPTION
    Updates the version in plugin.json, .claude-plugin/plugin.json,
    .claude-plugin/marketplace.json (2 occurrences), .github/plugin/marketplace.json
    (2 occurrences), and README.md (1 occurrence) — 7 occurrences total across 5 files
    + CHANGELOG.md when -ChangelogEntry is provided.

    The two plugin manifests are dual-written: Copilot reads plugin.json,
    Claude Code reads .claude-plugin/plugin.json. The two marketplace catalogs are
    also dual-written: Copilot marketplace lookup uses .github/plugin/marketplace.json,
    Claude Code uses .claude-plugin/marketplace.json. Cache invalidation in Claude Code
    depends on the version bumping, so dual-write is non-optional (see ADR-0002).

    Before writing, verifies that all current version values agree. If any differ,
    the script exits with an error and prints which file has the conflicting value.

    When -ChangelogEntry is provided, the script inserts a new ## [X.Y.Z] — YYYY-MM-DD
    section into CHANGELOG.md after all version-file bumps complete (write order ensures
    CHANGELOG is only touched after the version files succeed). The insertion is
    idempotent: if the new version heading already exists, it is skipped.

.PARAMETER Version
    New version in MAJOR.MINOR.PATCH format (e.g., 1.6.0).

.PARAMETER DryRun
    Preview what would change without writing any files.

.PARAMETER ChangelogEntry
    Multi-line body of the changelog entry. Do NOT include a ## [X.Y.Z] release header —
    the script synthesizes it. Pass only the body bullets/prose. When empty or whitespace,
    CHANGELOG.md is not touched.

.PARAMETER ChangelogSection
    Optional: override the ### subsection name (default: 'Changed'). For example, pass
    'Fixed' or 'Added' to categorize the entry.

.OUTPUTS
    Exit code 0 on success, exit code 1 on validation failure or version drift.

.EXAMPLE
    .\bump-version.ps1 -Version 1.6.0
    .\bump-version.ps1 -Version 1.6.0 -DryRun
    .\bump-version.ps1 -Version 1.6.0 -ChangelogEntry "- Fixed the thing" -ChangelogSection 'Fixed'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [switch]$DryRun,

    [string]$ChangelogEntry = '',

    [string]$ChangelogSection = ''
)

$ErrorActionPreference = 'Stop'

$Red = "`e[31m"
$Green = "`e[32m"
$Yellow = "`e[33m"
$Reset = "`e[0m"

function Fail([string]$Message, [string]$Hint = '') {
    Write-Host "${Red}✗${Reset} $Message"
    if ($Hint) { Write-Host "${Yellow}  $Hint${Reset}" }
    exit 1
}

# Dot-source release-gate-core for Test-ChangelogSectionPresent and
# changelog-insert-core for Invoke-ChangelogInsertion
$releaseGateCore = Join-Path $PSScriptRoot 'lib/release-gate-core.ps1'
if (Test-Path $releaseGateCore) { . $releaseGateCore }
$changelogInsertCore = Join-Path $PSScriptRoot 'lib/changelog-insert-core.ps1'
if (Test-Path $changelogInsertCore) { . $changelogInsertCore }

# --- Validate version format ---
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Fail "Invalid version format '$Version' — expected MAJOR.MINOR.PATCH (e.g., 1.6.0)"
}

# --- Validate ChangelogEntry does not contain its own release header ---
if ($ChangelogEntry -match '(?m)^## \[\d+\.\d+\.\d+\]') {
    Fail "-ChangelogEntry must not contain a '## [X.Y.Z]' release header — the script synthesizes the header. Pass only the entry body."
}

# --- Normalize ChangelogSection ---
if ([string]::IsNullOrWhiteSpace($ChangelogSection)) {
    $ChangelogSection = 'Changed'
}

# --- Resolve file paths ---
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
$pluginJson = Join-Path $repoRoot 'plugin.json'
$claudePluginJson = Join-Path $repoRoot '.claude-plugin/plugin.json'
$claudeMarketplaceJson = Join-Path $repoRoot '.claude-plugin/marketplace.json'
$marketplaceJson = Join-Path $repoRoot '.github/plugin/marketplace.json'
$readme = Join-Path $repoRoot 'README.md'

# --- Read files into memory (written back as UTF-8 without BOM) ---
$pluginContent = [System.IO.File]::ReadAllText($pluginJson)
$claudePluginContent = [System.IO.File]::ReadAllText($claudePluginJson)
$claudeMarketplaceContent = [System.IO.File]::ReadAllText($claudeMarketplaceJson)
$marketplaceContent = [System.IO.File]::ReadAllText($marketplaceJson)
$readmeContent = [System.IO.File]::ReadAllText($readme)

# --- Extract current versions ---
$pluginVersion = [regex]::Match($pluginContent, '"version":\s*"([\d.]+)"').Groups[1].Value
$claudePluginVersion = [regex]::Match($claudePluginContent, '"version":\s*"([\d.]+)"').Groups[1].Value
$marketplaceMatches = [regex]::Matches($marketplaceContent, '"version":\s*"([\d.]+)"')
if ($marketplaceMatches.Count -ne 2) {
    Fail "Expected exactly 2 'version' fields in .github/plugin/marketplace.json, found $($marketplaceMatches.Count)"
}
$marketplaceVersion1 = $marketplaceMatches[0].Groups[1].Value
$marketplaceVersion2 = $marketplaceMatches[1].Groups[1].Value
$claudeMarketplaceMatches = [regex]::Matches($claudeMarketplaceContent, '"version":\s*"([\d.]+)"')
if ($claudeMarketplaceMatches.Count -ne 2) {
    Fail "Expected exactly 2 'version' fields in .claude-plugin/marketplace.json, found $($claudeMarketplaceMatches.Count)"
}
$claudeMarketplaceVersion1 = $claudeMarketplaceMatches[0].Groups[1].Value
$claudeMarketplaceVersion2 = $claudeMarketplaceMatches[1].Groups[1].Value
$readmeVersion = [regex]::Match($readmeContent, 'version-v([\d.]+)-blue').Groups[1].Value

# --- Pre-bump consistency check ---
$allVersions = [ordered]@{
    'plugin.json'                                      = $pluginVersion
    '.claude-plugin/plugin.json'                       = $claudePluginVersion
    '.claude-plugin/marketplace.json (metadata)'       = $claudeMarketplaceVersion1
    '.claude-plugin/marketplace.json (plugin version)' = $claudeMarketplaceVersion2
    '.github/plugin/marketplace.json (metadata)'       = $marketplaceVersion1
    '.github/plugin/marketplace.json (plugin version)' = $marketplaceVersion2
    'README.md'                                        = $readmeVersion
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
    Write-Host "  Would update plugin.json: $currentVersion → $Version"
    Write-Host "  Would update .claude-plugin/plugin.json: $currentVersion → $Version"
    Write-Host "  Would update .claude-plugin/marketplace.json: $currentVersion → $Version (2 occurrences)"
    Write-Host "  Would update .github/plugin/marketplace.json: $currentVersion → $Version (2 occurrences)"
    Write-Host "  Would update README.md: $currentVersion → $Version"
    if (-not [string]::IsNullOrWhiteSpace($ChangelogEntry)) {
        $today = Get-Date -Format 'yyyy-MM-dd'
        Write-Host "  Would insert CHANGELOG.md section: ## [$Version] — $today"
        Write-Host "  ### $ChangelogSection"
        Write-Host ''
        Write-Host $ChangelogEntry
        Write-Host ''
    }
    Write-Host "${Green}✓${Reset} Dry run complete — 7 occurrences across 5 files$(if (-not [string]::IsNullOrWhiteSpace($ChangelogEntry)) { ' + CHANGELOG' })"
    exit 0
}

# --- Live update ---
Write-Host "Bumping version: ${Yellow}$currentVersion${Reset} → ${Green}$Version${Reset}"

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$updatedPlugin = $pluginContent -replace '"version":\s*"[\d.]+"', "`"version`": `"$Version`""
[System.IO.File]::WriteAllText($pluginJson, $updatedPlugin, $utf8NoBom)
Write-Host "  ${Green}✓${Reset} Updated plugin.json"

$updatedClaudePlugin = $claudePluginContent -replace '"version":\s*"[\d.]+"', "`"version`": `"$Version`""
[System.IO.File]::WriteAllText($claudePluginJson, $updatedClaudePlugin, $utf8NoBom)
Write-Host "  ${Green}✓${Reset} Updated .claude-plugin/plugin.json"

$updatedClaudeMarketplace = $claudeMarketplaceContent -replace '"version":\s*"[\d.]+"', "`"version`": `"$Version`""
[System.IO.File]::WriteAllText($claudeMarketplaceJson, $updatedClaudeMarketplace, $utf8NoBom)
Write-Host "  ${Green}✓${Reset} Updated .claude-plugin/marketplace.json (2 occurrences)"

$updatedMarketplace = $marketplaceContent -replace '"version":\s*"[\d.]+"', "`"version`": `"$Version`""
[System.IO.File]::WriteAllText($marketplaceJson, $updatedMarketplace, $utf8NoBom)
Write-Host "  ${Green}✓${Reset} Updated .github/plugin/marketplace.json (2 occurrences)"

$updatedReadme = $readmeContent -replace 'version-v[\d.]+-blue', "version-v$Version-blue"
[System.IO.File]::WriteAllText($readme, $updatedReadme, $utf8NoBom)
Write-Host "  ${Green}✓${Reset} Updated README.md"

# --- CHANGELOG insertion (write last — after all version bumps) ---
if (-not [string]::IsNullOrWhiteSpace($ChangelogEntry)) {
    $changelog = Join-Path $repoRoot 'CHANGELOG.md'
    $changelogContent = if (Test-Path $changelog) {
        [System.IO.File]::ReadAllText($changelog)
    } else {
        ''
    }

    $insertResult = Invoke-ChangelogInsertion `
        -ChangelogContent $changelogContent `
        -Version          $Version `
        -ChangelogEntry   $ChangelogEntry `
        -ChangelogSection $ChangelogSection

    if ($insertResult.Skipped) {
        Write-Verbose $insertResult.Message
        Write-Host "  ${Yellow}~${Reset} CHANGELOG.md section ## [$Version] already present — skipped"
    } else {
        if (-not $insertResult.VerifyPass) {
            Write-Warning "CHANGELOG write-back verification failed — skipping write to avoid corruption; manual check required"
        } else {
            [System.IO.File]::WriteAllText($changelog, $insertResult.Content, $utf8NoBom)
            Write-Host "  ${Green}✓${Reset} Updated CHANGELOG.md — $($insertResult.Message)"
        }
    }
}

Write-Host "${Green}✓${Reset} Version bumped to $Version across 7 occurrences in 5 files$(if (-not [string]::IsNullOrWhiteSpace($ChangelogEntry)) { ' + CHANGELOG' })"
