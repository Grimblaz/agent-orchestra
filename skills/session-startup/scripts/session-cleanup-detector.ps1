#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Session startup check: detect stale post-merge branches and tracking artifacts.

.DESCRIPTION
    Runs at the start of every VS Code Copilot session. Two independent detection paths:
      1. BRANCH CHECK: Is the current branch a merged/deleted remote branch?
      2. TRACKING FILE CHECK: Are there .copilot-tracking/ files for merged issues?
    If either (or both) fire, injects additionalContext so the agent can prompt
    for cleanup. No-ops silently when nothing to clean.

.OUTPUTS
    JSON to stdout conforming to the hookSpecificOutput schema for session startup.
#>

. "$PSScriptRoot/session-cleanup-detector-core.ps1"

# Resolve the active repo root from CWD (where the SessionStart hook fires).
# Note: $PSScriptRoot points to the plugin install directory, not the consumer repo —
# do NOT use $PSScriptRoot/../../.. here; it resolves to the plugin cache root.
$gitOutput = & git rev-parse --show-toplevel 2>$null
$repoRoot = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitOutput)) {
    $gitOutput.Trim()
} else {
    (Get-Location).Path
}

# AC5: Idempotently ensure consumer repo .gitignore contains the scratch-containment net.
# Fail-open: any failure in this step is swallowed so the cleanup detector still runs.
try {
    & "$PSScriptRoot/Ensure-ScratchGitignore.ps1" -RepoRoot $repoRoot
} catch {
    Write-Warning "session-cleanup-detector: Ensure-ScratchGitignore step failed — $($_.Exception.Message). Continuing."
}

$result = Invoke-SessionCleanupDetector -RepoRoot $repoRoot

if ($result.Output) { Write-Output $result.Output }
if ($result.Error) { Write-Error $result.Error -ErrorAction Continue }
exit $result.ExitCode
