#!/usr/bin/env pwsh
<#
.SYNOPSIS
    SessionStart hook: detect stale post-merge tracking artifacts.

.DESCRIPTION
    Runs on every VS Code Copilot SessionStart. Checks for .copilot-tracking/ 
    files from issues whose feature branch has since been merged (remote gone).
    If found, injects additionalContext so the agent can prompt for cleanup.
    No-ops silently (<100ms) when nothing to clean.

.OUTPUTS
    JSON to stdout conforming to VS Code SessionStart hookSpecificOutput schema.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Write-NoOp {
    Write-Output '{}'
}

# Fast path: no tracking directory or no files
$trackingRoot = '.copilot-tracking'
if (-not (Test-Path $trackingRoot)) {
    Write-NoOp
    exit 0
}

$trackingFiles = @(Get-ChildItem -Path $trackingRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^\.gitkeep$' })

if ($trackingFiles.Count -eq 0) {
    Write-NoOp
    exit 0
}

# Extract issue IDs from frontmatter
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

# Check each issue: is the remote branch gone?
$cleanupNeeded = @()
foreach ($id in $issueIds) {
    if ($id -eq 'unknown') {
        # Can't check branch state; include as generic cleanup candidate
        $cleanupNeeded += @{
            IssueId      = $id
            BranchName   = $null
            UnknownFiles = $unknownFiles
        }
        continue
    }

    # Check for remote branches matching feature/issue-{id}-*
    $remoteCheck = git ls-remote --heads origin "feature/issue-$id-*" 2>$null
    # Guard: if git failed (network error, not a git repo, etc.) skip this issue
    # to avoid falsely treating a failed lookup as "branch deleted".
    if ($LASTEXITCODE -ne 0) { continue }
    $localBranches = @(git branch --list "feature/issue-$id-*" 2>$null |
        ForEach-Object { ($_ -replace '^\* ', '').Trim() } |
        Where-Object { $_ })
    $localBranch = $localBranches | Select-Object -First 1

    # If no remote match but tracking files exist — likely merged
    if ([string]::IsNullOrWhiteSpace($remoteCheck)) {
        $cleanupNeeded += @{ IssueId = $id; BranchName = $localBranch; AllBranches = $localBranches }
    }
    # If remote still exists, work is in-progress — don't suggest cleanup
}

if ($cleanupNeeded.Count -eq 0) {
    Write-NoOp
    exit 0
}

# Build additionalContext message
$lines = @('**Post-merge cleanup detected** — stale tracking artifacts found:')
$lines += ''

foreach ($item in $cleanupNeeded) {
    if ($item.IssueId -eq 'unknown') {
        $count = $item.UnknownFiles.Count
        $fileList = ($item.UnknownFiles | ForEach-Object { "  - ``$_``" }) -join "`n"
        $lines += "- $count tracking file(s) with no issue ID found in ```.copilot-tracking/```:"
        $lines += $fileList
    }
    else {
        $extra = if ($item.AllBranches.Count -gt 1) { " +$($item.AllBranches.Count - 1) more" } else { '' }
        $branchInfo = if ($item.BranchName) { " (local branch: ``$($item.BranchName)``$extra)" } else { '' }
        $lines += "- Issue #$($item.IssueId)$branchInfo — remote branch merged/deleted"
    }
}

$lines += ''
$lines += 'To clean up, run:'
$lines += '```powershell'
foreach ($item in $cleanupNeeded) {
    if ($item.IssueId -ne 'unknown') {
        if ($item.BranchName) {
            foreach ($b in $item.AllBranches) {
                $lines += "pwsh .github/scripts/post-merge-cleanup.ps1 -IssueNumber $($item.IssueId) -FeatureBranch '$($b -replace "'", "''")'"
            }
        }
        else {
            $lines += "pwsh .github/scripts/post-merge-cleanup.ps1 -IssueNumber $($item.IssueId) -SkipRemoteDelete -SkipLocalDelete  # branch not found locally; archives tracking files only"
        }
    }
    else {
        $lines += '# Unknown issue ID — manually inspect and archive files in .copilot-tracking/'
    }
}
$lines += '```'
$lines += ''
$lines += 'Or skip by continuing with your request.'

$additionalContext = $lines -join "`n"

$output = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $additionalContext
    }
} | ConvertTo-Json -Depth 3 -Compress

Write-Output $output
exit 0
