#Requires -Version 7.0
<#
.SYNOPSIS
    Shared git helpers for session-startup automation.
#>

function Get-SCDDefaultBranch {
    <#
    .SYNOPSIS
        Resolves the remote default branch using the same multi-strategy pattern as
        post-merge-cleanup.ps1: symbolic-ref -> show-ref main -> show-ref master -> current HEAD -> main.
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