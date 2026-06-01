<#
.SYNOPSIS
    Idempotently appends .tmp/ and mangle-literal patterns to the repo .gitignore.
    Called once per session by the SessionStart hook.

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

try {
    # Read current .gitignore (create empty if missing)
    if (Test-Path $gitignorePath) {
        $current = (Get-Content $gitignorePath -Raw -ErrorAction Stop) ?? ''
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
    if (Test-Path $gitignorePath) {
        $newContent = $current.TrimEnd() + "`n" + ($missing -join "`n") + "`n"
        Set-Content -Path $gitignorePath -Value $newContent -NoNewline -ErrorAction Stop
    } else {
        Set-Content -Path $gitignorePath -Value (($requiredLines -join "`n") + "`n") -NoNewline -ErrorAction Stop
    }

    Write-Output "Ensure-ScratchGitignore: appended $($missing.Count) missing pattern(s) to .gitignore."
    exit 0
}
catch {
    # Fail-open: never crash the session-startup hook
    Write-Warning "Ensure-ScratchGitignore: failed to update .gitignore — $($_.Exception.Message). Proceeding without update."
    exit 0
}
