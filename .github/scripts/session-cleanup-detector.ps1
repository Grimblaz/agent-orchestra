#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    SessionStart hook: detect stale post-merge branches and tracking artifacts.

.DESCRIPTION
    Runs on every VS Code Copilot SessionStart. Two independent detection paths:
      1. BRANCH CHECK: Is the current branch a merged/deleted remote branch?
      2. TRACKING FILE CHECK: Are there .copilot-tracking/ files for merged issues?
    If either (or both) fire, injects additionalContext so the agent can prompt
    for cleanup. No-ops silently when nothing to clean.

.OUTPUTS
    JSON to stdout conforming to VS Code SessionStart hookSpecificOutput schema.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Write-NoOp {
    Write-Output '{}'
}

function Get-DefaultBranch {
    <#
    .SYNOPSIS
        Resolves the remote default branch using the same multi-strategy pattern as
        post-merge-cleanup.ps1: symbolic-ref → show-ref main → show-ref master → 'main'.
    #>
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
        $localHead = (git symbolic-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $localHead) {
            $branch = $localHead -replace 'refs/heads/', ''
        }
    }
    if (-not $branch) { $branch = 'main' }
    return $branch
}

# ============================================================
# STEP 1: BRANCH CHECK (runs before tracking-file gate)
# ============================================================
$staleBranch = $null
$defaultBranch = 'main'   # initialise; resolved below only if needed

$currentBranch = (git branch --show-current 2>$null)
if ($LASTEXITCODE -ne 0) { $currentBranch = '' }

if ($currentBranch) {
    $defaultBranch = Get-DefaultBranch

    if ($currentBranch -ne $defaultBranch) {
        # Check if an upstream tracking ref is configured (never-pushed branches have none)
        $upstreamRef = (git rev-parse --abbrev-ref '@{u}' 2>$null)
        if ($LASTEXITCODE -eq 0) {
            # Has upstream — check whether the remote branch still exists
            $remoteName        = ($upstreamRef -split '/', 2)[0]
            $remoteBranchName  = ($upstreamRef -split '/', 2)[1]
            if ([string]::IsNullOrWhiteSpace($remoteBranchName)) { $remoteBranchName = $currentBranch }
            $remoteHeads = (git ls-remote --heads $remoteName $remoteBranchName 2>$null)
            if ($LASTEXITCODE -eq 0) {
                if ([string]::IsNullOrWhiteSpace($remoteHeads)) {
                    # Remote branch is gone — stale branch detected
                    $branchIssueId = $null
                    if ($currentBranch -match 'issue-(\d+)') {
                        $branchIssueId = $Matches[1]
                    }
                    $staleBranch = @{
                        BranchName = $currentBranch
                        IssueId    = $branchIssueId
                    }
                }
            }
        }
    }
}

# ============================================================
# STEP 2: TRACKING FILE CHECK (existing logic, intact)
# ============================================================
$cleanupNeeded = @()
$trackingRoot = '.copilot-tracking'

if (Test-Path $trackingRoot) {
    $trackingFiles = @(Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^\.gitkeep$' })

    if ($trackingFiles.Count -gt 0) {
        $issueIds = @()
        $unknownFiles = @()
        foreach ($file in $trackingFiles) {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match '(?m)^issue_id:\s*["\x27]?(\d+)["\x27]?') {
                $id = $Matches[1]
                if ($id -notin $issueIds) {
                    $issueIds += $id
                }
            }
            else {
                $unknownFiles += $file.FullName
            }
        }

        if ($unknownFiles.Count -gt 0 -and $issueIds -notcontains 'unknown') {
            $issueIds += 'unknown'
        }

        foreach ($id in $issueIds) {
            if ($id -eq 'unknown') {
                $cleanupNeeded += @{
                    IssueId      = $id
                    BranchName   = $null
                    UnknownFiles = $unknownFiles
                }
                continue
            }

            # Check for remote branches matching feature/issue-{id}-*
            $remoteCheck = git ls-remote --heads origin "feature/issue-$id-*" 2>$null
            # Guard: git failure (network error, etc.) → skip to avoid false positives
            if ($LASTEXITCODE -ne 0) { continue }
            $localBranches = @(git branch --list "feature/issue-$id-*" 2>$null |
                ForEach-Object { ($_ -replace '^\* ', '').Trim() } |
                Where-Object { $_ })
            $localBranch = $localBranches | Select-Object -First 1
            if ($LASTEXITCODE -ne 0) { $localBranches = @(); $localBranch = $null }

            if ([string]::IsNullOrWhiteSpace($remoteCheck)) {
                $cleanupNeeded += @{ IssueId = $id; BranchName = $localBranch; AllBranches = $localBranches }
            }
        }
    }
}

# ============================================================
# STEP 3: MERGE & OUTPUT
# ============================================================
if ($null -eq $staleBranch -and $cleanupNeeded.Count -eq 0) {
    Write-NoOp
    exit 0
}

$lines = @()

# Helper: emit tracking-file bullet lines
function Get-TrackingLines {
    param([array]$Items)
    $out = @()
    foreach ($item in $Items) {
        if ($item.IssueId -eq 'unknown') {
            $count = $item.UnknownFiles.Count
            $fileList = ($item.UnknownFiles | ForEach-Object { "  - ``$_``" }) -join "`n"
            $out += "- $count tracking file(s) with no issue ID found in ```.copilot-tracking/```:"
            $out += $fileList
        }
        else {
            $extra = if ($item.AllBranches.Count -gt 1) { " +$($item.AllBranches.Count - 1) more" } else { '' }
            $branchInfo = if ($item.BranchName) { " (local branch: ``$($item.BranchName)``$extra)" } else { '' }
            $out += "- Issue #$($item.IssueId)$branchInfo — remote branch merged/deleted"
        }
    }
    return $out
}

# Helper: emit cleanup command lines for tracking-file items
function Get-TrackingCommands {
    param([array]$Items)
    $out = @()
    foreach ($item in $Items) {
        if ($item.IssueId -ne 'unknown') {
            if ($item.BranchName) {
                foreach ($b in $item.AllBranches) {
                    $out += "pwsh .github/scripts/post-merge-cleanup.ps1 -IssueNumber $($item.IssueId) -FeatureBranch '$($b -replace "'", "''")'"
                }
            }
            else {
                $out += "pwsh .github/scripts/post-merge-cleanup.ps1 -IssueNumber $($item.IssueId) -SkipRemoteDelete -SkipLocalDelete  # branch not found locally; archives tracking files only"
            }
        }
        else {
            $out += '# Unknown issue ID — manually inspect and archive files in .copilot-tracking/'
        }
    }
    return $out
}

$escaped        = if ($null -ne $staleBranch) { $staleBranch.BranchName -replace "'", "''" } else { $null }
$escapedDefault = $defaultBranch -replace "'", "''"

if ($null -ne $staleBranch -and $cleanupNeeded.Count -eq 0) {
    # ── Branch-only signal ─────────────────────────────────────────────────────
    $lines += '**Post-merge cleanup detected** — you''re on a stale branch:'
    $lines += ''
    $lines += "- Current branch ``$($staleBranch.BranchName)`` — remote branch merged/deleted"
    $lines += ''
    $lines += 'To clean up, run:'
    $lines += '```powershell'
    if ($staleBranch.IssueId) {
        $lines += "pwsh .github/scripts/post-merge-cleanup.ps1 -IssueNumber $($staleBranch.IssueId) -FeatureBranch '$escaped'"
    }
    else {
        $lines += "git checkout '$escapedDefault' && git pull && git branch -d '$escaped'  # use -D to force if already confirmed merged"
    }
    $lines += '```'
    $lines += ''
    $lines += 'Or skip by continuing with your request.'
}
elseif ($null -ne $staleBranch -and $cleanupNeeded.Count -gt 0) {
    $dedupedCleanup = @($cleanupNeeded | Where-Object { $_.IssueId -ne $staleBranch.IssueId })
    # ── Both signals — branch info MUST precede 'post-merge cleanup detected' ──
    $lines += '**Post-merge cleanup detected** — stale branch and tracking artifacts found:'
    $lines += ''
    $lines += "- Current branch ``$($staleBranch.BranchName)`` — remote branch merged/deleted"
    $lines += ''
    if ($dedupedCleanup.Count -gt 0) {
        $lines += '**Post-merge cleanup detected** — stale tracking artifacts also found:'
        $lines += ''
        $lines += (Get-TrackingLines -Items $dedupedCleanup)
        $lines += ''
    }
    $lines += 'To clean up, run:'
    $lines += '```powershell'
    if ($staleBranch.IssueId) {
        $lines += "pwsh .github/scripts/post-merge-cleanup.ps1 -IssueNumber $($staleBranch.IssueId) -FeatureBranch '$escaped'"
        if ($dedupedCleanup.Count -gt 0) {
            $lines += (Get-TrackingCommands -Items $dedupedCleanup)
        }
    }
    else {
        $lines += "git checkout '$escapedDefault' && git pull && git branch -d '$escaped'  # use -D to force if already confirmed merged"
        if ($dedupedCleanup.Count -gt 0) {
            $lines += (Get-TrackingCommands -Items $dedupedCleanup)
        }
    }
    $lines += '```'
    $lines += ''
    $lines += 'Or skip by continuing with your request.'
}
else {
    # ── Tracking-files-only signal (existing behaviour) ───────────────────────
    $lines += '**Post-merge cleanup detected** — stale tracking artifacts found:'
    $lines += ''
    $lines += (Get-TrackingLines -Items $cleanupNeeded)
    $lines += ''
    $lines += 'To clean up, run:'
    $lines += '```powershell'
    $lines += (Get-TrackingCommands -Items $cleanupNeeded)
    $lines += '```'
    $lines += ''
    $lines += 'Or skip by continuing with your request.'
}

$additionalContext = $lines -join "`n"

$output = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $additionalContext
    }
} | ConvertTo-Json -Depth 3 -Compress

Write-Output $output
exit 0
