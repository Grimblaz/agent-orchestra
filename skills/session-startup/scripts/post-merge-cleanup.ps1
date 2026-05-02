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
    pwsh skills/session-startup/scripts/post-merge-cleanup.ps1 -IssueNumber 36 -FeatureBranch "feature/issue-36-janitor-to-hook"

.EXAMPLE
    # With GitHub CLI (close issue via gh)
    pwsh skills/session-startup/scripts/post-merge-cleanup.ps1 -IssueNumber 36 -FeatureBranch "feature/issue-36-janitor-to-hook" -UseGh
#>

[CmdletBinding()]
param(
    [Parameter()]
    [Nullable[int]]$IssueNumber = $null,

    [Parameter()]
    [string]$FeatureBranch = '',

    [Parameter()]
    [int]$PrNumber,

    [Parameter()]
    [string]$Repo,

    [switch]$UseGh,

    [switch]$SkipRemoteDelete,

    [switch]$SkipLocalDelete,

    [switch]$SkipGitUpdate,

    [Parameter()]
    [string[]]$OrphanBranches = @(),

    [Parameter()]
    [string[]]$SiblingWorktrees = @(),

    [Parameter()]
    [string[]]$UntaggedTrackingFiles = @()
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/session-startup-git-helpers.ps1"

# Guard: require IssueNumber OR at least one of the new category parameters
if ($null -eq $IssueNumber -and $OrphanBranches.Count -eq 0 -and $SiblingWorktrees.Count -eq 0 -and $UntaggedTrackingFiles.Count -eq 0) {
    Write-Error "Must specify -IssueNumber or at least one of -OrphanBranches, -SiblingWorktrees, -UntaggedTrackingFiles."
    exit 1
}

function Test-BranchMergedIntoDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    # Primary: git cherry — empty stdout means all commits already in default (squash-merge safe)
    $cherryOutput = git cherry $DefaultBranch $BranchName 2>$null
    if ($LASTEXITCODE -eq 0) {
        # Empty output means merged
        return [string]::IsNullOrWhiteSpace($cherryOutput)
    }

    # Fallback: gh pr list
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $prJson = gh pr list --head $BranchName --state merged --json number 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($prJson)) {
            try {
                $prs = $prJson | ConvertFrom-Json -ErrorAction Stop
                return ($prs.Count -gt 0)
            }
            catch { }
        }
    }

    # Conservative: treat as unmerged for safety
    return $false
}

function Get-RepoFromOrigin {
    $originUrl = (git remote get-url origin) 2>$null
    if (-not $originUrl) { return $null }
    if ($originUrl -match 'github.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
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

if ($null -ne $IssueNumber) {
    Write-Output "== Post-merge cleanup: issue #$IssueNumber =="
} else {
    Write-Output "== Post-merge cleanup =="
}

# Fetch to refresh remote refs; fail-open on error
git fetch origin --prune 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Fetch failed (exit $LASTEXITCODE) — proceeding with cached refs; some merged-status checks may be stale"
}

# Determine default branch defensively (try multiple strategies before assuming 'main')
$defaultBranch = Get-SCDDefaultBranch

# ── Orphan branch cleanup ──────────────────────────────────────────────────
$deletedOrphanCount = 0
$deletedOrphanNames = [System.Collections.Generic.List[string]]::new()
foreach ($branch in $OrphanBranches) {
    $isMerged = Test-BranchMergedIntoDefault -BranchName $branch -DefaultBranch $defaultBranch
    if (-not $isMerged) {
        Write-Output "Skipped '$branch' — unmerged commits — review before deleting"
        continue
    }
    # Prefer -d (safe); escalate to -D only after re-confirming merged
    git branch -d $branch 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Re-confirm still merged before forcing
        if (Test-BranchMergedIntoDefault -BranchName $branch -DefaultBranch $defaultBranch) {
            git branch -D $branch 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to delete orphan branch '$branch' (exit $LASTEXITCODE)"
                continue
            }
        }
        else {
            Write-Output "Skipped '$branch' — unmerged commits — review before deleting"
            continue
        }
    }
    $deletedOrphanCount++
    $deletedOrphanNames.Add($branch)
}
if ($deletedOrphanCount -gt 0) {
    Write-Output "Deleted $deletedOrphanCount orphan branch(es): $($deletedOrphanNames -join ', ')"
}

# ── Sibling worktree cleanup ───────────────────────────────────────────────
$deletedSiblingCount = 0
$deletedSiblingPaths = [System.Collections.Generic.List[string]]::new()
foreach ($worktreePath in $SiblingWorktrees) {
    # Determine branch from worktree
    $worktreeBranch = git -C $worktreePath branch --show-current 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($worktreeBranch)) {
        Write-Warning "Could not determine branch for worktree '$worktreePath' — skipping"
        continue
    }
    $isMerged = Test-BranchMergedIntoDefault -BranchName $worktreeBranch -DefaultBranch $defaultBranch
    if (-not $isMerged) {
        Write-Output "Skipped '$worktreeBranch' (worktree '$worktreePath') — unmerged commits — review before deleting"
        continue
    }
    git worktree remove --force $worktreePath 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to remove worktree '$worktreePath' (exit $LASTEXITCODE)"
        continue
    }
    git branch -d $worktreeBranch 2>$null
    if ($LASTEXITCODE -ne 0) {
        if (Test-BranchMergedIntoDefault -BranchName $worktreeBranch -DefaultBranch $defaultBranch) {
            git branch -D $worktreeBranch 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to delete branch '$worktreeBranch' after worktree removal"
                continue
            }
        }
    }
    $deletedSiblingCount++
    $deletedSiblingPaths.Add($worktreePath)
}
if ($deletedSiblingCount -gt 0) {
    Write-Output "Deleted $deletedSiblingCount sibling worktree(s): $($deletedSiblingPaths -join ', ')"
}

# ── Untagged tracking file archival ───────────────────────────────────────
$archivedUntaggedCount = 0
if ($UntaggedTrackingFiles.Count -gt 0) {
    $timestamp = Get-Date
    $year = $timestamp.ToString('yyyy')
    $month = $timestamp.ToString('MM')
    $unknownArchiveDir = Join-Path '.copilot-tracking-archive' (Join-Path $year (Join-Path $month 'unknown'))
    New-Item -ItemType Directory -Path $unknownArchiveDir -Force | Out-Null
    foreach ($relPath in $UntaggedTrackingFiles) {
        $absPath = Join-Path (Get-Location) $relPath
        if (-not (Test-Path $absPath)) {
            Write-Warning "Untagged tracking file not found: '$relPath' — skipping"
            continue
        }
        $fileInfo = Get-Item $absPath
        $ext = $fileInfo.Extension
        $nameNoExt = $fileInfo.BaseName
        $mtime = $fileInfo.LastWriteTime.ToString('yyyyMMddHHmmss')
        $destName = "$nameNoExt-$mtime$ext"
        $destPath = Join-Path $unknownArchiveDir $destName
        # Collision-safe: add suffix if needed
        $suffix = 1
        while (Test-Path $destPath) {
            $destPath = Join-Path $unknownArchiveDir "$nameNoExt-$mtime-$suffix$ext"
            $suffix++
        }
        Move-Item -LiteralPath $absPath -Destination $destPath
        $archivedUntaggedCount++
    }
    if ($archivedUntaggedCount -gt 0) {
        Write-Output "Archived $archivedUntaggedCount untagged file(s) under $year/$month/unknown/"
    }
}

if ($null -ne $IssueNumber) {
    $timestamp = Get-Date
    $year = $timestamp.ToString('yyyy')
    $month = $timestamp.ToString('MM')
    $archiveRoot = Join-Path '.copilot-tracking-archive' (Join-Path $year $month)
    $archivePath = Join-Path $archiveRoot "issue-$IssueNumber"

    Write-Output "Archive target: $archivePath"
    New-Item -ItemType Directory -Path $archivePath -Force | Out-Null

    $trackingRoot = '.copilot-tracking'
    $allTrackingFiles = Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue
    # Exclude .gitkeep placeholder files, then filter to only files belonging to this issue
    $trackingFiles = @($allTrackingFiles | Where-Object { $_.Name -ne '.gitkeep' } | Where-Object {
            $content = Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match '(?m)^issue_id:\s*["\x27]?(\d+)["\x27]?') {
                [int]$Matches[1] -eq $IssueNumber
            }
            else {
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
}

if (-not $SkipGitUpdate) {
    Write-Output "Switching to $defaultBranch and pulling latest..."
    git checkout $defaultBranch
    if ($LASTEXITCODE -ne 0) { throw "git checkout $defaultBranch failed (exit $LASTEXITCODE). Cleanup aborted." }
    git pull
    if ($LASTEXITCODE -ne 0) { throw "git pull failed (exit $LASTEXITCODE). Cleanup aborted." }
}

if (-not $SkipRemoteDelete -and $FeatureBranch) {
    $remoteExists = git ls-remote --heads origin $FeatureBranch 2>$null
    if ($remoteExists) {
        Write-Output "Deleting remote branch: $FeatureBranch"
        git push origin --delete $FeatureBranch
    }
    else {
        Write-Output "Remote branch not found (already deleted): $FeatureBranch"
    }
}

if (-not $SkipLocalDelete -and $FeatureBranch) {
    $localExists = git branch --list $FeatureBranch
    if ($localExists) {
        $currentBranch = git branch --show-current 2>$null
        if ($currentBranch -eq $FeatureBranch) {
            git checkout $defaultBranch
            if ($LASTEXITCODE -ne 0) { throw "git checkout $defaultBranch failed (exit $LASTEXITCODE). Cannot delete current branch." }
        }
        Write-Output "Deleting local branch: $FeatureBranch"
        git branch -D $FeatureBranch
    }
    else {
        Write-Output "Local branch not found: $FeatureBranch"
    }
}

if ($null -ne $IssueNumber) {
    if ($UseGh) {
        $resolvedRepo = if ($Repo) { $Repo } else { Get-RepoFromOrigin }
        if (-not $resolvedRepo) {
            Write-Warning 'gh enabled, but repo could not be resolved. Use -Repo owner/name.'
        }
        elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Write-Warning 'gh enabled, but GitHub CLI not found on PATH.'
        }
        else {
            $bodyLines = @(
                'Work complete.',
                '',
                $(if ($PrNumber) { "**Merged PR**: #$PrNumber" } else { $null }),
                ("**Files Archived**: ``$archivePath/``"),
                'Cleaned up via SessionStart hook.'
            ) | Where-Object { $_ -ne $null }

            gh issue comment $IssueNumber --repo $resolvedRepo --body ($bodyLines -join "`n")
        }
    }
    else {
        Write-Output 'Note: Use -UseGh to automatically post a GitHub issue comment.'
    }
}

Write-Output 'Cleanup complete.'
