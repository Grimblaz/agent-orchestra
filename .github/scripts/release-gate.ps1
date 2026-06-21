#Requires -Version 7.0
<#
.SYNOPSIS
    CI release gate: fail PRs that touch plugin entry points without a version bump + CHANGELOG entry.
.DESCRIPTION
    Reads changed files and versions from git, then invokes Invoke-ReleaseGateEvaluation.
    Exits 0 on pass, exits 1 on failure with an actionable message.

    Parameters:
      -BaseRef   The base branch ref (e.g. 'main' or 'origin/main'). The caller (workflow)
                 must have already run 'git fetch origin <base>' before invoking this script.
      -HeadRef   Optional. Defaults to 'HEAD'.

    Environment:
      GITHUB_TOKEN  Optional. Not needed for local git operations.
#>
param(
    [Parameter(Mandatory)][string]$BaseRef,
    [string]$HeadRef = 'HEAD'
)

. (Join-Path $PSScriptRoot 'lib' 'release-gate-core.ps1')

$changedFiles = @(git diff --name-only "origin/$BaseRef...$HeadRef")
$gitExitCode = $LASTEXITCODE
if ($gitExitCode -ne 0) {
    Write-Error "Failed to get changed files (exit $gitExitCode) — failing closed"
    exit 1
}

if ($changedFiles.Count -eq 0) {
    Write-Host "No files changed — gate passes."
    exit 0
}

$entryPointTouched = Test-ReleaseGateEntryPointTouched -ChangedFiles $changedFiles
if (-not $entryPointTouched) {
    Write-Host "No plugin entry points changed — gate passes."
    exit 0
}

$baseJsonRaw = @(git show "origin/${BaseRef}:.claude-plugin/plugin.json")
$baseJsonExitCode = $LASTEXITCODE
if ($baseJsonExitCode -ne 0) {
    Write-Error "Failed to read base-branch plugin.json (exit $baseJsonExitCode) — failing closed"
    exit 1
}
$baseJsonContent = $baseJsonRaw -join "`n"

$baseVersion = $null
if ($baseJsonContent -match '"version":\s*"([\d.]+)"') {
    $baseVersion = $matches[1]
}
if (-not $baseVersion -or $baseVersion -notmatch '^\d+\.\d+\.\d+$') {
    Write-Error "Base plugin.json has invalid or missing version '$baseVersion' — failing closed"
    exit 1
}

$headVersion = Get-PluginVersion -Path '.claude-plugin/plugin.json'
if ($null -eq $headVersion) {
    Write-Error "Head plugin.json has invalid or missing version — failing closed"
    exit 1
}

$headMsg = git log -1 --format=%B HEAD

$changelog = ''
if (Test-Path 'CHANGELOG.md') {
    $changelog = Get-Content -Path 'CHANGELOG.md' -Raw -ErrorAction SilentlyContinue
    if ($null -eq $changelog) {
        Write-Error "CHANGELOG.md exists but could not be read — failing closed"
        exit 1
    }
}
# $changelog is '' if the file is absent (will fail the changelog leg cleanly)

$result = Invoke-ReleaseGateEvaluation `
    -ChangedFiles $changedFiles `
    -HeadVersion $headVersion `
    -BaseVersion $baseVersion `
    -ChangelogContent $changelog `
    -HeadCommitMessage ($headMsg ?? '')

if ($result.Pass) {
    if ($result.WaiverApplied) {
        Write-Host "Release gate PASSED (waiver applied: $($result.WaiverApplied))."
    } else {
        Write-Host "Release gate PASSED."
    }
    exit 0
} else {
    Write-Error "Release gate FAILED. Failed legs: $($result.FailedLegs -join ', ')"
    if ($result.FailedLegs -contains 'bump') {
        Write-Host "  Version bump required: head version must be greater than base version."
        Write-Host "  To waive the entire gate (use sparingly): Skip-Release-Check: all <reason>"
    }
    if ($result.FailedLegs -contains 'changelog') {
        Write-Host "  CHANGELOG entry required: add a '## [$headVersion]' section."
        Write-Host "  To waive the CHANGELOG leg only: Skip-Release-Check: changelog-only"
    }
    exit 1
}
