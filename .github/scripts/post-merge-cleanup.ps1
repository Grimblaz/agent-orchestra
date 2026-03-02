#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Post-merge cleanup for tracking files and feature branches.

.DESCRIPTION
    Archives all files under .copilot-tracking/ into a dated issue context
    folder, cleans empty tracking directories, and removes the feature branch
    locally/remotely.

    Supports both manual invocation and SessionStart hook-driven invocation.

.EXAMPLE
    # Parameterized (explicit)
    pwsh .github/scripts/post-merge-cleanup.ps1 -IssueNumber 36 -FeatureBranch "feature/issue-36-janitor-to-hook"

.EXAMPLE
    # With GitHub CLI (close issue via gh)
    pwsh .github/scripts/post-merge-cleanup.ps1 -IssueNumber 36 -FeatureBranch "feature/issue-36-janitor-to-hook" -UseGh
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$IssueNumber,

    [Parameter(Mandatory = $true)]
    [string]$FeatureBranch,

    [Parameter()]
    [int]$PrNumber,

    [Parameter()]
    [string]$Repo,

    [switch]$UseGh,

    [switch]$SkipRemoteDelete,

    [switch]$SkipLocalDelete,

    [switch]$SkipGitUpdate
)

$ErrorActionPreference = 'Stop'

function Get-RepoFromOrigin {
    $originUrl = (git remote get-url origin) 2>$null
    if (-not $originUrl) { return $null }
    if ($originUrl -match 'github.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
        return "$($Matches.owner)/$($Matches.repo)"
    }
    return $null
}

function Remove-EmptyDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Root)
    if (-not (Test-Path $Root)) { return }
    Get-ChildItem -Path $Root -Recurse -Directory |
        Sort-Object FullName -Descending |
        ForEach-Object {
            $hasFiles = Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue
            if (-not $hasFiles -and $PSCmdlet.ShouldProcess($_.FullName, 'Remove empty directory')) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
}

Write-Output "== Post-merge cleanup: issue #$IssueNumber =="

$timestamp   = Get-Date
$year        = $timestamp.ToString('yyyy')
$month       = $timestamp.ToString('MM')
$archiveRoot = Join-Path '.copilot-tracking-archive' (Join-Path $year $month)
$archivePath = Join-Path $archiveRoot "issue-$IssueNumber"

Write-Output "Archive target: $archivePath"
New-Item -ItemType Directory -Path $archivePath -Force | Out-Null

$trackingRoot  = '.copilot-tracking'
$allTrackingFiles = Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue
# Exclude .gitkeep placeholder files, then filter to only files belonging to this issue
$trackingFiles = @($allTrackingFiles | Where-Object { $_.Name -ne '.gitkeep' } | Where-Object {
    $content = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
    $match = Select-String -InputObject $content -Pattern 'issue_id:\s*(\d+)' -AllMatches
    if ($match) {
        [int]$match.Matches[0].Groups[1].Value -eq $IssueNumber
    } else {
        Write-Warning "Skipping '$($_.Name)': no issue_id frontmatter found."
        $false
    }
})

$archivedCount = 0
foreach ($file in $trackingFiles) {
    $relativePath = $file.FullName.Substring((Resolve-Path $trackingRoot).Path.Length).TrimStart('\', '/')
    $destDir = Join-Path $archivePath (Split-Path $relativePath -Parent)
    New-Item -Force -ItemType Directory -Path $destDir | Out-Null
    Move-Item -LiteralPath $file.FullName -Destination (Join-Path $destDir $file.Name)
    $archivedCount++
}

Remove-EmptyDirectory -Root $trackingRoot

$remaining = (Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Output "Archived $archivedCount file(s). Tracking files remaining: $remaining"

$defaultBranch = (git symbolic-ref refs/remotes/origin/HEAD 2>$null) -replace 'refs/remotes/origin/', ''
if (-not $defaultBranch) { $defaultBranch = 'main' }  # fallback

if (-not $SkipGitUpdate) {
    Write-Output "Switching to $defaultBranch and pulling latest..."
    git checkout $defaultBranch
    git pull
}

if (-not $SkipRemoteDelete) {
    $remoteExists = git ls-remote --heads origin $FeatureBranch 2>$null
    if ($remoteExists) {
        Write-Output "Deleting remote branch: $FeatureBranch"
        git push origin --delete $FeatureBranch
    } else {
        Write-Output "Remote branch not found (already deleted): $FeatureBranch"
    }
}

if (-not $SkipLocalDelete) {
    $localExists = git branch --list $FeatureBranch
    if ($localExists) {
        $currentBranch = git branch --show-current 2>$null
        if ($currentBranch -eq $FeatureBranch) {
            git checkout $defaultBranch
        }
        Write-Output "Deleting local branch: $FeatureBranch"
        git branch -D $FeatureBranch
    } else {
        Write-Output "Local branch not found: $FeatureBranch"
    }
}

if ($UseGh) {
    $resolvedRepo = if ($Repo) { $Repo } else { Get-RepoFromOrigin }
    if (-not $resolvedRepo) {
        Write-Warning 'gh enabled, but repo could not be resolved. Use -Repo owner/name.'
    } elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning 'gh enabled, but GitHub CLI not found on PATH.'
    } else {
        $bodyLines = @(
            'Work complete.',
            '',
            $(if ($PrNumber) { "**Merged PR**: #$PrNumber" } else { $null }),
            ("**Files Archived**: ``$archivePath/``"),
            'Cleaned up via SessionStart hook.'
        ) | Where-Object { $_ -ne $null }

        gh issue comment $IssueNumber --repo $resolvedRepo --body ($bodyLines -join "`n")
    }
} else {
    Write-Output 'Note: Use -UseGh to automatically post a GitHub issue comment.'
}

Write-Output 'Cleanup complete.'
