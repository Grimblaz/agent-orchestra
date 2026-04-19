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

# Resolve repo root relative to this script's location.
# Works for plugin-cache installs and direct clones alike: in both cases this
# file lives at {repo}/skills/session-startup/scripts/ so repo root is three
# levels up. No env var configuration needed.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

$result = Invoke-SessionCleanupDetector -RepoRoot $repoRoot

if ($result.Output) { Write-Output $result.Output }
if ($result.Error) { Write-Error $result.Error -ErrorAction Continue }
exit $result.ExitCode
