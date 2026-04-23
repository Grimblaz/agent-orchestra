#Requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-PRHRepoRoot {
    try {
        $root = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
            return $null
        }

        return $root.Trim()
    }
    catch {
        return $null
    }
}

function Get-PRHEventPayload {
    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        return $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-PRHEntryPointPath {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $normalized = ($RelativePath -replace '\\', '/') -replace '^(\./|\.\\)', ''
    return (
        $normalized -like 'agents/*' -or
        $normalized -like 'commands/*' -or
        $normalized -like 'skills/*' -or
        $normalized -like '.claude-plugin/*' -or
        $normalized -eq 'plugin.json' -or
        $normalized -eq 'README.md' -or
        $normalized -eq '.github/copilot-instructions.md'
    )
}

function Get-PRHRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$FilePath
    )

    try {
        $rootUri = [Uri]((Resolve-Path $RepoRoot).Path + [IO.Path]::DirectorySeparatorChar)
        $fileUri = [Uri]((Resolve-Path $FilePath).Path)
        $relative = $rootUri.MakeRelativeUri($fileUri).ToString()
        return [Uri]::UnescapeDataString($relative) -replace '\\', '/'
    }
    catch {
        return $FilePath -replace '\\', '/'
    }
}

function Get-PRHSlug {
    $branch = (& git branch --show-current 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        return 'session'
    }

    $trimmed = $branch.Trim()
    if ($trimmed -match 'issue-(\d+)') {
        return $matches[1]
    }

    return (($trimmed -replace '[^A-Za-z0-9._-]+', '-') -replace '^-+|-+$', '')
}

function Get-PRHStatePath {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    try {
        $stateDir = Join-Path $RepoRoot '.claude/.state'
        if (-not (Test-Path $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }

        return Join-Path $stateDir ("release-hygiene-{0}.json" -f (Get-PRHSlug))
    }
    catch {
        return $null
    }
}

function Get-PRHState {
    param(
        [Parameter(Mandatory)]
        [string]$StatePath
    )

    if (-not (Test-Path $StatePath)) {
        return $null
    }

    try {
        return (Get-Content -Path $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Save-PRHState {
    param(
        [Parameter(Mandatory)]
        [string]$StatePath,

        [Parameter(Mandatory)]
        [PSCustomObject]$State
    )

    try {
        $State | ConvertTo-Json -Depth 10 | Set-Content -Path $StatePath -Encoding UTF8
        return $true
    }
    catch {
        return $false
    }
}

$repoRoot = Get-PRHRepoRoot
if (-not $repoRoot) {
    exit 0
}

if (-not (Test-Path (Join-Path $repoRoot '.github/scripts/bump-version.ps1'))) {
    exit 0
}

$payload = Get-PRHEventPayload
if (-not $payload) {
    exit 0
}

$targetPaths = @()
if (-not [string]::IsNullOrWhiteSpace($payload.tool_input.file_path)) {
    $targetPaths += [string]$payload.tool_input.file_path
}
if ($null -ne $payload.tool_input.files) {
    foreach ($file in @($payload.tool_input.files)) {
        if (-not [string]::IsNullOrWhiteSpace($file.filePath)) {
            $targetPaths += [string]$file.filePath
        }
    }
}
if ($targetPaths.Count -eq 0) {
    exit 0
}

$entryPaths = @()
foreach ($targetPath in $targetPaths) {
    $relativePath = Get-PRHRelativePath -RepoRoot $repoRoot -FilePath $targetPath
    if (Test-PRHEntryPointPath -RelativePath $relativePath) {
        $entryPaths += $relativePath
    }
}
if ($entryPaths.Count -eq 0) {
    exit 0
}

$relativePath = $entryPaths[0]

$statePath = Get-PRHStatePath -RepoRoot $repoRoot
$canPersistState = -not [string]::IsNullOrWhiteSpace($statePath)
$state = Get-PRHState -StatePath $statePath

if ($canPersistState -and $null -ne $state) {
    $touched = @()
    if ($null -ne $state.touched_files) {
        $touched = @($state.touched_files)
    }
    if ($touched -notcontains $relativePath) {
        $touched += $relativePath
    }

    $updatedState = [PSCustomObject]@{
        proposed_level = if ($state.proposed_level) { [string]$state.proposed_level } else { 'patch' }
        chosen_level   = if ($state.chosen_level) { [string]$state.chosen_level } else { $null }
        touched_files  = $touched
    }

    [void](Save-PRHState -StatePath $statePath -State $updatedState)
    exit 0
}

$newState = [PSCustomObject]@{
    proposed_level = 'patch'
    chosen_level   = $null
    touched_files  = @($relativePath)
}
if ($canPersistState) {
    [void](Save-PRHState -StatePath $statePath -State $newState)
}

$result = [PSCustomObject]@{
    hookSpecificOutput = [PSCustomObject]@{
        hookEventName     = 'PostToolUse'
        additionalContext = "Entry-point edit detected: $relativePath. Load the plugin-release-hygiene skill to propose a version bump."
    }
}

$result | ConvertTo-Json -Depth 10 -Compress | Write-Output
exit 0