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

function Get-PRHDefaultBranch {
    $branch = (git symbolic-ref refs/remotes/origin/HEAD 2>$null) -replace 'refs/remotes/origin/', ''
    if ($LASTEXITCODE -ne 0) { $branch = $null }
    if (-not $branch) {
        git show-ref --verify --quiet refs/remotes/origin/main 2>$null
        if ($LASTEXITCODE -eq 0) { $branch = 'main' }
    }
    if (-not $branch) {
        git show-ref --verify --quiet refs/remotes/origin/master 2>$null
        if ($LASTEXITCODE -eq 0) { $branch = 'master' }
    }
    if (-not $branch) {
        git show-ref --verify --quiet refs/heads/main 2>$null
        if ($LASTEXITCODE -eq 0) { $branch = 'main' }
    }
    if (-not $branch) {
        git show-ref --verify --quiet refs/heads/master 2>$null
        if ($LASTEXITCODE -eq 0) { $branch = 'master' }
    }
    if (-not $branch) {
        $localHead = (git symbolic-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $localHead) {
            $branch = $localHead -replace 'refs/heads/', ''
        }
    }
    if (-not $branch) { $branch = 'main' }
    return $branch
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

function ConvertTo-PRHSafeSlug {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $sanitized = (($Value -replace '[^A-Za-z0-9._-]+', '-') -replace '^-+|-+$', '')
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return 'session'
    }

    return $sanitized
}

function Get-PRHStateRoot {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    try {
        $commonDir = (& git rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDir)) {
            return $RepoRoot
        }

        $resolvedCommonDir = $commonDir.Trim()
        $commonDirParent = Split-Path -Path $resolvedCommonDir -Parent
        $commonRoot = if ((Split-Path -Path $commonDirParent -Leaf) -eq 'worktrees') {
            Split-Path -Path (Split-Path -Path $commonDirParent -Parent) -Parent
        }
        else {
            Split-Path -Path $resolvedCommonDir -Parent
        }
        if ([string]::IsNullOrWhiteSpace($commonRoot)) {
            return $RepoRoot
        }

        return $commonRoot
    }
    catch {
        return $RepoRoot
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

function Get-PRHKeyingInfo {
    param(
        $Payload
    )

    if ($null -ne $Payload -and -not [string]::IsNullOrWhiteSpace($Payload.session_id)) {
        return [PSCustomObject]@{
            slug            = ConvertTo-PRHSafeSlug -Value ([string]$Payload.session_id)
            keying_strategy = 'session_id'
        }
    }

    $branch = (& git branch --show-current 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        $headSha = (& git rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($headSha)) {
            return [PSCustomObject]@{
                slug            = ConvertTo-PRHSafeSlug -Value ([string]$headSha)
                keying_strategy = 'session_fallback'
            }
        }

        return [PSCustomObject]@{
            slug            = 'session'
            keying_strategy = 'session_fallback'
        }
    }

    $trimmed = $branch.Trim()
    if ($trimmed -match 'issue-(\d+)') {
        return [PSCustomObject]@{
            slug            = $matches[1]
            keying_strategy = 'branch_slug'
        }
    }

    return [PSCustomObject]@{
        slug            = ConvertTo-PRHSafeSlug -Value $trimmed
        keying_strategy = 'branch_slug'
    }
}

function Get-PRHStatePath {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Slug
    )

    try {
        $stateRoot = Get-PRHStateRoot -RepoRoot $RepoRoot
        $stateDir = Join-Path $stateRoot '.claude/.state'
        if (-not (Test-Path $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }

        return Join-Path $stateDir ("release-hygiene-{0}.json" -f $Slug)
    }
    catch {
        return $null
    }
}

function Get-PRHManagedVersionState {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [string]$GitRef
    )

    try {
        $paths = @(
            @{ Path = 'plugin.json'; Pattern = '"version":\s*"([\d.]+)"'; Expected = 1 },
            @{ Path = '.claude-plugin/plugin.json'; Pattern = '"version":\s*"([\d.]+)"'; Expected = 1 },
            @{ Path = '.claude-plugin/marketplace.json'; Pattern = '"version":\s*"([\d.]+)"'; Expected = 2 },
            @{ Path = '.github/plugin/marketplace.json'; Pattern = '"version":\s*"([\d.]+)"'; Expected = 2 },
            @{ Path = 'README.md'; Pattern = 'version-v([\d.]+)-blue'; Expected = 1 }
        )

        $versions = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $paths) {
            $content = if ([string]::IsNullOrWhiteSpace($GitRef)) {
                $fullPath = Join-Path $RepoRoot $entry.Path
                if (-not (Test-Path $fullPath)) {
                    return $null
                }

                [System.IO.File]::ReadAllText($fullPath)
            }
            else {
                $gitContent = (& git show "${GitRef}:$($entry.Path)" 2>$null)
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitContent)) {
                    return $null
                }

                [string]$gitContent
            }

            $versionMatches = [regex]::Matches($content, $entry.Pattern)
            if ($versionMatches.Count -lt $entry.Expected) {
                return $null
            }

            foreach ($match in $versionMatches) {
                $versions.Add($match.Groups[1].Value)
            }
        }

        $distinctVersions = @($versions | Sort-Object -Unique)
        if ($distinctVersions.Count -ne 1) {
            return [PSCustomObject]@{
                in_lockstep = $false
                version     = $null
            }
        }

        return [PSCustomObject]@{
            in_lockstep = $true
            version     = [version]$distinctVersions[0]
        }
    }
    catch {
        return $null
    }
}

function Test-PRHVersionAlreadyBumped {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    try {
        $defaultBranch = Get-PRHDefaultBranch
        $currentState = Get-PRHManagedVersionState -RepoRoot $RepoRoot
        $baselineState = Get-PRHManagedVersionState -RepoRoot $RepoRoot -GitRef $defaultBranch

        if ($null -eq $currentState -or $null -eq $baselineState) {
            return $false
        }

        if (-not $currentState.in_lockstep -or -not $baselineState.in_lockstep) {
            return $false
        }

        return $currentState.version -gt $baselineState.version
    }
    catch {
        return $false
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

if (Test-PRHVersionAlreadyBumped -RepoRoot $repoRoot) {
    exit 0
}

$keyingInfo = Get-PRHKeyingInfo -Payload $payload
$statePath = Get-PRHStatePath -RepoRoot $repoRoot -Slug $keyingInfo.slug
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
        proposed_level  = if ($state.proposed_level) { [string]$state.proposed_level } else { 'patch' }
        chosen_level    = if ($state.chosen_level) { [string]$state.chosen_level } else { $null }
        keying_strategy = [string]$keyingInfo.keying_strategy
        touched_files   = $touched
    }

    [void](Save-PRHState -StatePath $statePath -State $updatedState)
    exit 0
}

$newState = [PSCustomObject]@{
    proposed_level  = 'patch'
    chosen_level    = $null
    keying_strategy = [string]$keyingInfo.keying_strategy
    touched_files   = @($relativePath)
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