#Requires -Version 7.0
<#
.SYNOPSIS
    Keeps agent scratch and goal-run runtime state out of `git status`, using
    two different destinations on purpose.

.DESCRIPTION
    Called once per session by the SessionStart hook. Does two independent,
    idempotent things:

    1. Appends the .tmp/ and mangle-literal scratch-containment patterns (from
       skills/terminal-hygiene/SKILL.md ## Scratch & Temp-File Hygiene) to the
       repo's .gitignore, giving consumer repositories the same scratch
       containment the hub repo gets from its own committed .gitignore.

    2. Writes the goal-run harness runtime-state patterns
       (/goal-run-active.json, /goal-run-log.jsonl) to .git/info/exclude --
       NOT to .gitignore. That file is per-clone and untracked, so these
       entries can never dirty a tracked file; a tracked-.gitignore edit would
       itself leave the launch repo dirty and re-trigger the very
       'refused: uncommitted-changes' halt this exists to prevent (#929).

    Both steps fail open independently: a failure in either is reported and
    swallowed so the SessionStart hook never crashes.

    Requires PowerShell 7+ (uses the ?? null-coalescing operator); the SessionStart
    hook invokes it under pwsh, matching this contract.

.PARAMETER RepoRoot
    Path to the repository root. Defaults to current directory.

.OUTPUTS
    Writes status to stdout. Exits 0 always (fail-open).
#>
param(
    [string]$RepoRoot = (Get-Location).Path
)

$gitignorePath = Join-Path $RepoRoot '.gitignore'

# The canonical scratch-containment net (from terminal-hygiene ## Scratch & Temp-File Hygiene)
# /*[Tt]emp* intentionally omitted (RF4): over-matched template.md, templates/, attempt.js.
# Primary mangle shapes are covered by /[A-Za-z]:* and /[A-Za-z][A-Za-z]sers*.
$requiredLines = @(
    '# Agent scratch — keep out of git status',
    '.tmp/',
    '/[A-Za-z][A-Za-z]sers*',
    '/[A-Za-z]:*',
    '/var*folders*',
    '/[Rr][Uu][Nn][Nn][Ee][Rr]*[Tt][Ee][Mm][Pp]*'
)

# goal-run harness runtime state (#929). The harness writes both files at the
# execution worktree root by design (874-D6), and the contract validator refuses
# a dirty -RepoRoot before doing anything else, so leaving them visible to
# `git status` makes every run's first predicate call halt with
# 'refused: uncommitted-changes'. Ignoring rather than committing is deliberate:
# a run log can carry transcript event content and absolute session paths, so
# committing it would be a disclosure path into the PR.
#
# These go in .git/info/exclude, NOT .gitignore: the exclude file is per-clone
# and untracked, so writing it is structurally incapable of dirtying a tracked
# file — an appended .gitignore line would itself dirty the launch repo and
# re-trigger the exact refusal above. Patterns are anchored (leading slash)
# because the harness only ever writes at the worktree root; a bare basename
# would also hide e.g. fixtures/goal-run-active.json at any depth.
$goalRunExcludeLines = @(
    '/goal-run-active.json',
    '/goal-run-log.jsonl'
)

# --- Step 1: goal-run runtime state -> .git/info/exclude (fail-open) ---
try {
    # --git-common-dir, NOT --git-dir: inside a linked worktree --git-dir points
    # at .git/worktrees/<name>, whose info/exclude git does not consult;
    # --git-common-dir points at the shared .git, which applies to all worktrees.
    $gitCommonDir = & git -C $RepoRoot rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "git rev-parse --git-common-dir failed (exit $LASTEXITCODE) in '$RepoRoot'"
    }

    $gitCommonDir = ("$($gitCommonDir | Select-Object -First 1)").Trim()
    if ([string]::IsNullOrWhiteSpace($gitCommonDir)) {
        throw "git rev-parse --git-common-dir returned no path for '$RepoRoot'"
    }
    if (-not [System.IO.Path]::IsPathRooted($gitCommonDir)) {
        # git -C makes relative output (e.g. '.git') relative to $RepoRoot.
        $gitCommonDir = Join-Path $RepoRoot $gitCommonDir
    }
    # Resolve against PowerShell's location, not [Environment]::CurrentDirectory:
    # the two diverge after Set-Location, and the .NET directory call below reads
    # the latter. Normalizing here keeps it consistent with the -LiteralPath
    # cmdlets. GetFullPath never treats [ ] as wildcards.
    $gitCommonDir = [System.IO.Path]::GetFullPath($gitCommonDir, $PWD.ProviderPath)

    $infoDir = Join-Path $gitCommonDir 'info'
    $excludePath = Join-Path $infoDir 'exclude'

    # -LiteralPath / .NET throughout: -Path treats [ ] as a wildcard character
    # class, so a repo at e.g. 'C:\re[po]x' makes the path unresolvable, which
    # stops the FileSystem provider's dynamic -NoNewline parameter from binding
    # and silently drops the consumer into the fail-open catch with no ignoring
    # applied at all. New-Item has no -LiteralPath, hence the .NET call.
    if (-not (Test-Path -LiteralPath $infoDir)) {
        [System.IO.Directory]::CreateDirectory($infoDir) | Out-Null
    }

    if (Test-Path -LiteralPath $excludePath) {
        $excludeCurrent = (Get-Content -LiteralPath $excludePath -Raw -ErrorAction Stop) ?? ''
    } else {
        $excludeCurrent = ''
    }

    $excludeLines = $excludeCurrent -split "`n" | ForEach-Object { $_.TrimEnd() }
    $missingExclude = @($goalRunExcludeLines | Where-Object { $_ -notin $excludeLines })

    if ($missingExclude.Count -eq 0) {
        Write-Output 'Ensure-ScratchGitignore: .git/info/exclude already contains the goal-run runtime-state patterns.'
    } else {
        if ([string]::IsNullOrWhiteSpace($excludeCurrent)) {
            $newExclude = ($missingExclude -join "`n") + "`n"
        } else {
            $newExclude = $excludeCurrent.TrimEnd() + "`n" + ($missingExclude -join "`n") + "`n"
        }
        Set-Content -LiteralPath $excludePath -Value $newExclude -NoNewline -ErrorAction Stop
        Write-Output "Ensure-ScratchGitignore: added $($missingExclude.Count) goal-run runtime-state pattern(s) to .git/info/exclude."
    }
}
catch {
    # Fail-open: never crash the session-startup hook
    Write-Warning "Ensure-ScratchGitignore: failed to update .git/info/exclude — $($_.Exception.Message). Proceeding without update."
}

# --- Step 2: scratch-containment net -> .gitignore (fail-open) ---
try {
    # Read current .gitignore (create empty if missing). -LiteralPath for the
    # same wildcard-globbing reason as Step 1.
    if (Test-Path -LiteralPath $gitignorePath) {
        $current = (Get-Content -LiteralPath $gitignorePath -Raw -ErrorAction Stop) ?? ''
    } else {
        $current = ''
    }

    $currentLines = $current -split "`n" | ForEach-Object { $_.TrimEnd() }

    # Find which required lines are missing (skip comment lines already present)
    $missing = $requiredLines | Where-Object { $_ -notin $currentLines }

    if ($missing.Count -eq 0) {
        Write-Output 'Ensure-ScratchGitignore: .gitignore already contains all scratch-containment patterns.'
        exit 0
    }

    # Append the missing lines, ensuring the existing content ends with a newline
    # before the block so patterns are never fused with the last existing line (RF2).
    if (Test-Path -LiteralPath $gitignorePath) {
        $newContent = $current.TrimEnd() + "`n" + ($missing -join "`n") + "`n"
        Set-Content -LiteralPath $gitignorePath -Value $newContent -NoNewline -ErrorAction Stop
    } else {
        Set-Content -LiteralPath $gitignorePath -Value (($requiredLines -join "`n") + "`n") -NoNewline -ErrorAction Stop
    }

    Write-Output "Ensure-ScratchGitignore: appended $($missing.Count) missing pattern(s) to .gitignore."
    exit 0
}
catch {
    # Fail-open: never crash the session-startup hook
    Write-Warning "Ensure-ScratchGitignore: failed to update .gitignore — $($_.Exception.Message). Proceeding without update."
    exit 0
}
