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
    [string[]]$UntaggedTrackingFiles = @(),

    [Parameter()]
    [string]$TmpRoot = ''
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/session-startup-git-helpers.ps1"
if (-not (Get-Command Get-SCDPersistentTrackingExclusions -ErrorAction SilentlyContinue)) {
    Write-Error "HALT: Get-SCDPersistentTrackingExclusions is not defined after loading session-startup-git-helpers.ps1. Aborting executor to prevent destruction of persistent tracking files. (mf6-executor-failsafe)"
    exit 1
}
$persistentExclusions = Get-SCDPersistentTrackingExclusions
if ($null -eq $persistentExclusions -or $null -eq $persistentExclusions.Filenames) {
    Write-Error "HALT: Get-SCDPersistentTrackingExclusions returned null or missing Filenames — registry integrity failure. Aborting executor to prevent destruction of persistent tracking files. (mf6-executor-failsafe)"
    exit 1
}
$script:PersistentTrackingFilenames = [string[]]$persistentExclusions.Filenames

# Guard: require IssueNumber, FeatureBranch, OR at least one of the new category parameters
# (C6/C1: -FeatureBranch alone is sufficient — used by detector for no-issue-id stale branches
#  so the no-issue-id path can also flow through this composite script instead of raw git.)
if ($null -eq $IssueNumber -and
    [string]::IsNullOrWhiteSpace($FeatureBranch) -and
    $OrphanBranches.Count -eq 0 -and
    $SiblingWorktrees.Count -eq 0 -and
    $UntaggedTrackingFiles.Count -eq 0 -and
    [string]::IsNullOrWhiteSpace($TmpRoot)) {
    Write-Error "Must specify -IssueNumber, -FeatureBranch, or at least one of -OrphanBranches, -SiblingWorktrees, -UntaggedTrackingFiles, -TmpRoot."
    exit 1
}

# Warn about -TmpRoot-only (scratch clearing requires -IssueNumber)
if (-not [string]::IsNullOrWhiteSpace($TmpRoot) -and $null -eq $IssueNumber) {
    Write-Warning "-TmpRoot supplied without -IssueNumber; no scratch files will be cleared."
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

function Remove-OrphanBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [ref]$DeletedCount,

        [System.Collections.Generic.List[string]]$DeletedNames
    )

    if ($Branch -eq $DefaultBranch) {
        Write-Warning "Remove-OrphanBranch: Refusing to delete default branch '$Branch'."
        return
    }

    $isMerged = Test-BranchMergedIntoDefault -BranchName $Branch -DefaultBranch $DefaultBranch
    $autoResolveApproved = $false
    if (-not $isMerged) {
        $autoResolve = Test-OrphanBranchAutoResolveEligible -Branch $Branch -DefaultBranch $DefaultBranch
        switch ($autoResolve) {
            $true { $autoResolveApproved = $true } # fall through to delete via -D
            $null {
                Write-Output "Skipped '$Branch' — could not verify auto-resolve signals — review before deleting"
                return
            }
            default {
                Write-Output "Skipped '$Branch' — auto-resolve declined — review before deleting"
                return
            }
        }
    }

    if ($autoResolveApproved) {
        # Auto-resolve path: commits are absorbed per GitHub signals; use -D directly
        Invoke-SCDNativeCommand { git branch -D $Branch 2>$null }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to delete orphan branch '$Branch' (exit $LASTEXITCODE)"
            return
        }
    }
    else {
        # Prefer -d (safe); escalate to -D only after re-confirming merged
        Invoke-SCDNativeCommand { git branch -d $Branch 2>$null }
        if ($LASTEXITCODE -ne 0) {
            # Re-confirm still merged before forcing
            if (Test-BranchMergedIntoDefault -BranchName $Branch -DefaultBranch $DefaultBranch) {
                Invoke-SCDNativeCommand { git branch -D $Branch 2>$null }
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to delete orphan branch '$Branch' (exit $LASTEXITCODE)"
                    return
                }
            }
            else {
                Write-Output "Skipped '$Branch' — branch not reachable from default (merged-state re-check returned false) — review before deleting"
                return
            }
        }
    }

    $DeletedCount.Value++
    $DeletedNames.Add($Branch)
}

function Remove-SiblingWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorktreePath,

        [Parameter(Mandatory)]
        [string]$DefaultBranch,

        [ref]$DeletedCount,

        [System.Collections.Generic.List[string]]$DeletedPaths
    )

    # G2: Resolve branch name. Try the in-worktree query first; fall back to the
    # porcelain worktree list if the directory is missing or detached (prunable).
    $worktreeBranch = Invoke-SCDNativeCommand { git -C $WorktreePath branch --show-current 2>$null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($worktreeBranch)) {
        $porcelain = Invoke-SCDNativeCommand { git worktree list --porcelain 2>$null }
        if ($LASTEXITCODE -eq 0 -and $porcelain) {
            $blocks = ($porcelain -join "`n") -split "`n`n+"
            foreach ($block in $blocks) {
                $blockLines = $block -split "`r?`n"
                $pathLine = ($blockLines | Where-Object { $_ -match '^worktree\s+(.+)$' } | Select-Object -First 1)
                if (-not $pathLine) { continue }
                $blockPath = ($pathLine -replace '^worktree\s+', '').Trim()
                # Compare normalized paths (case-insensitive on Windows, slash-direction agnostic)
                $normBlock = $blockPath.Replace('\', '/').TrimEnd('/')
                $normTarget = $WorktreePath.Replace('\', '/').TrimEnd('/')
                if ([string]::Equals($normBlock, $normTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $branchLine = ($blockLines | Where-Object { $_ -match '^branch\s+refs/heads/(.+)$' } | Select-Object -First 1)
                    if ($branchLine -match '^branch\s+refs/heads/(.+)$') {
                        $worktreeBranch = $Matches[1].Trim()
                    }
                    break
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($worktreeBranch)) {
            Write-Warning "Could not determine branch for worktree '$WorktreePath' — skipping"
            return
        }
    }

    $isMerged = Test-BranchMergedIntoDefault -BranchName $worktreeBranch -DefaultBranch $DefaultBranch
    if (-not $isMerged) {
        Write-Output "Skipped '$worktreeBranch' (worktree '$WorktreePath') — unmerged commits — review before deleting"
        return
    }

    # C5: Try non-force removal first. Only escalate to --force when the worktree
    # is prunable (directory deleted) or already gone — never silently --force
    # over a worktree with uncommitted changes.
    Invoke-SCDNativeCommand { git worktree remove $WorktreePath 2>$null }
    if ($LASTEXITCODE -ne 0) {
        $shouldForce = $false
        if (-not (Test-Path $WorktreePath)) {
            $shouldForce = $true  # directory missing => prunable
        } else {
            # Check porcelain output for 'prunable' or 'locked' markers
            $porcelainCheck = Invoke-SCDNativeCommand { git worktree list --porcelain 2>$null }
            if ($LASTEXITCODE -eq 0 -and $porcelainCheck) {
                $blocks2 = ($porcelainCheck -join "`n") -split "`n`n+"
                foreach ($block in $blocks2) {
                    $blockLines = $block -split "`r?`n"
                    $pathLine = ($blockLines | Where-Object { $_ -match '^worktree\s+(.+)$' } | Select-Object -First 1)
                    if (-not $pathLine) { continue }
                    $blockPath = ($pathLine -replace '^worktree\s+', '').Trim()
                    $normBlock = $blockPath.Replace('\', '/').TrimEnd('/')
                    $normTarget = $WorktreePath.Replace('\', '/').TrimEnd('/')
                    if ([string]::Equals($normBlock, $normTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                        if ($block -match '(?m)^prunable' -or $block -match '(?m)^locked') {
                            $shouldForce = $true
                        }
                        break
                    }
                }
            }
        }
        if ($shouldForce) {
            Invoke-SCDNativeCommand { git worktree remove --force $WorktreePath 2>$null }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to remove worktree '$WorktreePath' even with --force (exit $LASTEXITCODE)"
                return
            }
        } else {
            Write-Warning "Worktree '$WorktreePath' has uncommitted changes or other state preventing safe removal — skipping. Inspect manually and run 'git worktree remove --force' if appropriate."
            return
        }
    }

    Invoke-SCDNativeCommand { git branch -d $worktreeBranch 2>$null }
    if ($LASTEXITCODE -ne 0) {
        if (Test-BranchMergedIntoDefault -BranchName $worktreeBranch -DefaultBranch $DefaultBranch) {
            Invoke-SCDNativeCommand { git branch -D $worktreeBranch 2>$null }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to delete branch '$worktreeBranch' after worktree removal"
                return
            }
        }
        else {
            Write-Output "Removed worktree '$WorktreePath', but skipped branch '$worktreeBranch' — unmerged commits — review before deleting"
            $DeletedCount.Value++
            $DeletedPaths.Add($WorktreePath)
            return
        }
    }

    $DeletedCount.Value++
    $DeletedPaths.Add($WorktreePath)
}

function Remove-IssueTmpScratch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $IssueNumber,

        [Parameter(Mandatory)]
        [string]$TmpRoot
    )

    $resolvedTmpRoot = $TmpRoot
    if (-not [System.IO.Path]::IsPathRooted($TmpRoot)) {
        $gitRootRaw = & git rev-parse --show-toplevel 2>$null
        $gitRoot = if ($null -ne $gitRootRaw) { $gitRootRaw.Trim() } else { '' }
        $baseDir = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitRoot)) { $gitRoot } else { (Get-Location).Path }
        $resolvedTmpRoot = Join-Path $baseDir $TmpRoot
    }

    if (-not (Test-Path $resolvedTmpRoot)) {
        Write-Output "Cleaned 0 .tmp/ scratch files for issue #$IssueNumber"
        return
    }

    $escapedN = [regex]::Escape($IssueNumber)
    # Flat scope only — scratch convention uses top-level .tmp/{N}-* files; nested subdirs are not swept.
    $allTmpFiles = Get-ChildItem -Path $resolvedTmpRoot -File -ErrorAction SilentlyContinue
    $filesToRemove = @($allTmpFiles | Where-Object {
        $name = $_.Name
        # Form 1: {N}-* (literal '-' already anchors the right boundary)
        ($name -like "$IssueNumber-*") -or
        # Form 2: issue-{N}.ext, issue-{N}-rest, or bare issue-{N}
        ($name -match "^issue-$escapedN(\.|-)") -or
        ($name -eq "issue-$IssueNumber")
    })

    $removedCount = 0
    foreach ($file in $filesToRemove) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        $removedCount++
    }

    Write-Output "Cleaned $removedCount .tmp/ scratch files for issue #$IssueNumber"
}

if ($null -ne $IssueNumber) {
    Write-Output "== Post-merge cleanup: issue #$IssueNumber =="
} else {
    Write-Output "== Post-merge cleanup =="
}

# Fetch to refresh remote refs; fail-open on error
Invoke-SCDNativeCommand { git fetch origin --prune 2>$null }
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Fetch failed (exit $LASTEXITCODE) — proceeding with cached refs; some merged-status checks may be stale"
}

# Determine default branch defensively (try multiple strategies before assuming 'main')
$defaultBranch = Get-SCDDefaultBranch
$remoteDefaultRef = Get-RemoteDefaultRef -DefaultBranch $defaultBranch
$remoteDefaultParts = $remoteDefaultRef -split '/', 2
if ($remoteDefaultParts.Count -eq 2 -and $remoteDefaultParts[0] -ne 'origin') {
    $upstreamRemote = $remoteDefaultParts[0]
    Invoke-SCDNativeCommand { git fetch $upstreamRemote --prune 2>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Fetch failed for remote '$upstreamRemote' (exit $LASTEXITCODE) — proceeding with cached refs; some merged-status checks may be stale"
    }
}

# ── Orphan branch cleanup ──────────────────────────────────────────────────
$deletedOrphanCount = 0
$deletedOrphanNames = [System.Collections.Generic.List[string]]::new()
foreach ($branch in $OrphanBranches) {
    Remove-OrphanBranch -Branch $branch -DefaultBranch $defaultBranch -DeletedCount ([ref]$deletedOrphanCount) -DeletedNames $deletedOrphanNames
}
if ($deletedOrphanCount -gt 0) {
    Write-Output "Deleted $deletedOrphanCount orphan branch(es): $($deletedOrphanNames -join ', ')"
}

# ── Sibling worktree cleanup ───────────────────────────────────────────────
$deletedSiblingCount = 0
$deletedSiblingPaths = [System.Collections.Generic.List[string]]::new()
foreach ($worktreePath in $SiblingWorktrees) {
    Remove-SiblingWorktree -WorktreePath $worktreePath -DefaultBranch $defaultBranch -DeletedCount ([ref]$deletedSiblingCount) -DeletedPaths $deletedSiblingPaths
}
if ($deletedSiblingCount -gt 0) {
    Write-Output "Deleted $deletedSiblingCount sibling worktree(s): $($deletedSiblingPaths -join ', ')"
}

# ── Issue .tmp/ scratch clearing ──────────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($TmpRoot) -and $null -ne $IssueNumber) {
    Remove-IssueTmpScratch -IssueNumber $IssueNumber -TmpRoot $TmpRoot
}

# ── Untagged tracking file archival ───────────────────────────────────────
$archivedUntaggedCount = 0
if ($UntaggedTrackingFiles.Count -gt 0) {
    # G3: Anchor on the repo root so behavior is independent of the script's CWD.
    $repoRoot = (Invoke-SCDNativeCommand { git rev-parse --show-toplevel 2>$null })
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
        $repoRoot = (Get-Location).Path
    } else {
        $repoRoot = $repoRoot.Trim()
    }
    # C2: Resolve the canonical .copilot-tracking root for path-traversal validation.
    $trackingRootCanonical = $null
    $trackingRootDir = Join-Path $repoRoot '.copilot-tracking'
    if (Test-Path $trackingRootDir) {
        $trackingRootCanonical = (Resolve-Path -LiteralPath $trackingRootDir).Path.TrimEnd('\', '/')
    }
    $timestamp = Get-Date
    $year = $timestamp.ToString('yyyy')
    $month = $timestamp.ToString('MM')
    $unknownArchiveDir = Join-Path '.copilot-tracking-archive' (Join-Path $year (Join-Path $month 'unknown'))
    New-Item -ItemType Directory -Path $unknownArchiveDir -Force | Out-Null
    foreach ($relPath in $UntaggedTrackingFiles) {
        $absPath = Join-Path $repoRoot $relPath
        if (-not (Test-Path $absPath)) {
            Write-Warning "Untagged tracking file not found: '$relPath' — skipping"
            continue
        }
        # C2: Validate the resolved path lives under .copilot-tracking/. This blocks
        # both '..' traversal (e.g. '../../etc/hosts') and absolute paths that
        # escape the tracking root.
        $resolvedAbs = (Resolve-Path -LiteralPath $absPath).Path
        if (-not $trackingRootCanonical -or
            -not $resolvedAbs.StartsWith("$trackingRootCanonical$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($resolvedAbs, $trackingRootCanonical, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Path traversal blocked: '$relPath' resolves outside .copilot-tracking/ — skipping"
            continue
        }
        # Registry guard: skip persistent root-level files (mf6-executor-failsafe, AC4)
        $relFromTrackingRoot = $resolvedAbs.Substring($trackingRootCanonical.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, '/')
        if ($script:PersistentTrackingFilenames.Count -gt 0 -and
            -not $relFromTrackingRoot.Contains([System.IO.Path]::DirectorySeparatorChar) -and
            -not $relFromTrackingRoot.Contains('/') -and
            $script:PersistentTrackingFilenames -icontains $relFromTrackingRoot) {
            Write-Warning "Persistent tracking file skipped — registry-protected, will not be archived: '$relPath'"
            continue
        }
        $fileInfo = Get-Item $absPath
        # CR-5 defensive guard: skip directories (caller should only pass files via -File,
        # but guard against API misuse that could move an entire tracking subtree)
        if ($fileInfo.PSIsContainer) {
            Write-Warning "Untagged tracking path is not a file: '$relPath' — skipping"
            continue
        }
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
        Remove-EmptyDirectory -Root '.copilot-tracking'
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
    # S-C1: hoist loop-invariant path resolution out of the per-file Where-Object and foreach
    $trackingRootResolved = (Resolve-Path $trackingRoot).Path
    $allTrackingFiles = Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue
    # Exclude .gitkeep placeholder files, then filter to only files belonging to this issue
    $trackingFiles = @($allTrackingFiles | Where-Object { $_.Name -ne '.gitkeep' } | Where-Object {
            # Registry guard: skip persistent root-level files (AC4)
            $relFromRoot = $_.FullName.Substring($trackingRootResolved.Length).TrimStart('\', '/')
            if ($script:PersistentTrackingFilenames.Count -gt 0 -and
                -not $relFromRoot.Contains('\') -and
                -not $relFromRoot.Contains('/') -and
                $script:PersistentTrackingFilenames -icontains $relFromRoot) {
                Write-Warning "Persistent tracking file skipped — registry-protected, will not be archived: '$($_.Name)'"
                return $false
            }
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
        $relativePath = $file.FullName.Substring($trackingRootResolved.Length).TrimStart('\', '/')
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
