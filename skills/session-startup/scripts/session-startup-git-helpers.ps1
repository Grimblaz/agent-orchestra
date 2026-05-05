#Requires -Version 7.0
<#
.SYNOPSIS
    Shared git helpers for session-startup automation.

.NOTES
    Detector-safe helpers only resolve refs or read local git state and may be
    used by session-cleanup-detector-core.ps1. Cleanup-only decision helpers
    feed deletion authorization in post-merge-cleanup.ps1; keep those
    conservative and fail-open when their evidence is unavailable.
#>

function Invoke-SCDNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    $pref = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    if ($null -eq $pref) { return & $Command }

    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try { return & $Command }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function Get-SCDDefaultBranch {
    <#
    .SYNOPSIS
        Resolves the remote default branch using the same multi-strategy pattern as
        post-merge-cleanup.ps1: symbolic-ref -> show-ref main -> show-ref master -> current HEAD -> main.
    #>
    $branch = (Invoke-SCDNativeCommand { git symbolic-ref refs/remotes/origin/HEAD 2>$null }) -replace 'refs/remotes/origin/', ''
    if ($LASTEXITCODE -ne 0) { $branch = $null }
    if (-not $branch) {
        Invoke-SCDNativeCommand { git show-ref --verify --quiet refs/remotes/origin/main 2>$null }
        if ($LASTEXITCODE -eq 0) { $branch = 'main' }
    }
    if (-not $branch) {
        Invoke-SCDNativeCommand { git show-ref --verify --quiet refs/remotes/origin/master 2>$null }
        if ($LASTEXITCODE -eq 0) { $branch = 'master' }
    }
    if (-not $branch) {
        $localHead = (Invoke-SCDNativeCommand { git symbolic-ref HEAD 2>$null })
        if ($LASTEXITCODE -eq 0 -and $localHead) {
            $branch = $localHead -replace 'refs/heads/', ''
        }
    }
    if (-not $branch) { $branch = 'main' }
    return $branch
}

function Get-RemoteDefaultRef {
    # G1: Resolve the remote-tracking ref dynamically rather than hardcoding 'origin/'.
    # Handles users who configure the default branch's upstream as e.g. 'upstream/main'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )
    $upstream = Invoke-SCDNativeCommand { git rev-parse --abbrev-ref "${DefaultBranch}@{upstream}" 2>$null }
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)) {
        return $upstream.Trim()
    }
    return "origin/$DefaultBranch"
}

function Test-BranchMergedIntoDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$DefaultBranch
    )

    # Primary: tree-equivalence check (AC1/AC6) — catches squash-merged branches
    # whose tip content is identical to the remote default even when commit history differs.
    $remoteDefault = Get-RemoteDefaultRef -DefaultBranch $DefaultBranch
    Invoke-SCDNativeCommand { git diff --quiet --ignore-cr-at-eol $remoteDefault $BranchName 2>$null }
    if ($LASTEXITCODE -eq 0) { return $true }

    # Accumulated squash branch: if merging the branch into the current default
    # would produce the same tree, cleanup is still safe after default advances.
    $mergeTreeOutput = @(Invoke-SCDNativeCommand { git merge-tree --write-tree $remoteDefault $BranchName 2>$null })
    if ($LASTEXITCODE -eq 0) {
        $mergedTree = @($mergeTreeOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($mergedTree.Count -gt 0) {
            $mergedTreeOid = $mergedTree[0].Trim()
            Invoke-SCDNativeCommand { git diff --quiet --ignore-cr-at-eol $remoteDefault $mergedTreeOid 2>$null }
            if ($LASTEXITCODE -eq 0) { return $true }
        }
    }

    # Secondary: git cherry against the resolved remote default ref (G1)
    $cherryOutput = Invoke-SCDNativeCommand { git cherry $remoteDefault $BranchName 2>$null }
    if ($LASTEXITCODE -eq 0) {
        # C4: cherry prefixes lines with '+' (not in upstream) or '-' (patch-equivalent
        # already in upstream). Branch is merged when there are NO '+' lines.
        # (Empty stdout is the trivial subset of "no '+' lines".)
        $unmergedLines = @($cherryOutput | Where-Object { $_ -match '^\+\s' })
        return ($unmergedLines.Count -eq 0)
    }

    # Fallback: gh pr list
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $prJson = Invoke-SCDNativeCommand { gh pr list --head $BranchName --state merged --json number 2>$null }
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