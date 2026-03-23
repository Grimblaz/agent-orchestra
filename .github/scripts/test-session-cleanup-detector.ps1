#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Verification harness for session-cleanup-detector.ps1.

.DESCRIPTION
    Exercises the detector across 14 scenarios using git mocking (temp mock dir on PATH).
    Covers stale-branch detection plus issue #185 calibration exclusion paths.

.USAGE
    pwsh .github/scripts/test-session-cleanup-detector.ps1 [-Verbose]
#>

param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$detectorPath = Join-Path $scriptDir 'session-cleanup-detector.ps1'

$script:passed = 0
$script:failed = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function New-MockGitDir {
    <#
    Creates a temp directory containing:
      git-mock.ps1  — the mock dispatch logic, reads its config from git-mock-config.json
      git.cmd       — thin batch wrapper so the OS resolves "git" to our mock
    Returns the directory path.
    #>
    param([hashtable]$Config)

    $mockDir = Join-Path ([System.IO.Path]::GetTempPath()) "git-mock-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $mockDir | Out-Null

    # Persist config so the mock script can read it (env vars don't handle complex data well)
    $Config | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $mockDir 'git-mock-config.json') -Encoding UTF8

    # The mock script — dispatch on $args, answer from config
    $mockPs1 = @'
param()
$configPath = Join-Path $PSScriptRoot 'git-mock-config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json

# Normalise args (PowerShell splits on spaces when called via cmd %*)
$a = $args

if ($a.Count -ge 2 -and $a[0] -eq 'branch' -and $a[1] -eq '--show-current') {
    $val = $config.'branch--show-current'
    if ($null -ne $val) { Write-Output $val }
    exit 0
}

if ($a.Count -ge 2 -and $a[0] -eq 'symbolic-ref' -and $a[1] -eq 'refs/remotes/origin/HEAD') {
    $val = $config.'symbolic-ref-origin-HEAD'
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 128
}

if ($a.Count -ge 2 -and $a[0] -eq 'symbolic-ref' -and $a[1] -eq 'HEAD') {
    $val = $config.'symbolic-ref-HEAD'
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 128
}

if ($a.Count -ge 3 -and $a[0] -eq 'rev-parse' -and $a[1] -eq '--abbrev-ref' -and $a[2] -eq '@{u}') {
    $upstreamExit = if ($null -ne $config.'rev-parse-exit') { [int]$config.'rev-parse-exit' } else { 128 }
    if ($upstreamExit -eq 0) {
        $val = $config.'rev-parse-upstream'
        if ($null -ne $val) { Write-Output $val }
        exit 0
    }
    exit $upstreamExit
}

if ($a[0] -eq 'show-ref') {
    if ($a -contains 'refs/remotes/origin/main') {
        $code = if ($null -ne $config.'show-ref-main-exitcode') { [int]$config.'show-ref-main-exitcode' } else { 1 }
        exit $code
    }
    if ($a -contains 'refs/remotes/origin/master') {
        $code = if ($null -ne $config.'show-ref-master-exitcode') { [int]$config.'show-ref-master-exitcode' } else { 1 }
        exit $code
    }
    exit 1
}

if ($a.Count -ge 4 -and $a[0] -eq 'ls-remote' -and $a[1] -eq '--heads' -and $a[2] -eq 'origin') {
    # Allow forcing ls-remote to fail (simulate network error / PAT-4)
    if ($null -ne $config.'ls-remote-exitcode' -and [int]$config.'ls-remote-exitcode' -ne 0) {
        exit [int]$config.'ls-remote-exitcode'
    }
    $pattern = $a[3]
    # Try exact key match first (e.g. "ls-remote-feature/issue-36-stale")
    $exactKey = "ls-remote-$pattern"
    if ($null -ne $config.$exactKey) { Write-Output $config.$exactKey; exit 0 }
    # Try wildcard-pattern key (e.g. "ls-remote-feature/issue-36-*")
    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -like 'ls-remote-*') {
            $keyPattern = $prop.Name.Substring('ls-remote-'.Length)
            if ($pattern -like $keyPattern) {
                Write-Output $prop.Value
                exit 0
            }
        }
    }
    # Default for ls-remote: return empty (no remote = stale)
    if ($null -ne $config.'ls-remote-default') { Write-Output $config.'ls-remote-default' }
    exit 0
}

if ($a.Count -ge 3 -and $a[0] -eq 'branch' -and $a[1] -eq '--list') {
    $pattern = $a[2]
    $key = "branch-list-$pattern"
    if ($null -ne $config.$key) { Write-Output $config.$key; exit 0 }
    # Walk all branch-list-* keys trying wildcard match
    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -like 'branch-list-*') {
            $keyPattern = $prop.Name.Substring('branch-list-'.Length)
            if ($pattern -like $keyPattern) {
                Write-Output $prop.Value
                exit 0
            }
        }
    }
    exit 0
}

# Default: no output, success
exit 0
'@
    Set-Content -Path (Join-Path $mockDir 'git-mock.ps1') -Value $mockPs1 -Encoding UTF8

    # Batch wrapper — %* passes all args through to the PS script.
    # Using -File so PowerShell sees $args correctly.
    $cmdContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0git-mock.ps1`" %*"
    Set-Content -Path (Join-Path $mockDir 'git.cmd') -Value $cmdContent -Encoding ASCII

    return $mockDir
}

function Invoke-Scenario {
    param(
        [string]$Name,
        [hashtable]$GitConfig,
        [string]$WorkDir,        # CWD for the detector process
        [scriptblock]$Assert
    )

    $mockDir = New-MockGitDir -Config $GitConfig
    $oldPath = $env:PATH
    $oldCwd = (Get-Location).Path

    try {
        # Prepend mock dir so our git.cmd wins over the real git
        $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$env:PATH"

        # Run detector in an isolated process; capture stdout + stderr combined
        $output = pwsh -NoProfile -NonInteractive -Command `
            "Set-Location '$($WorkDir -replace "'","''")'; & '$($detectorPath -replace "'","''")'" `
            2>&1

        $outputStr = ($output | Out-String).Trim()

        if ($Verbose) {
            Write-Host "    [DBG] output: $outputStr"
        }

        $result = & $Assert $outputStr

        if ($result.Pass) {
            $script:passed++
            Write-Host "  PASS  $Name"
        }
        else {
            $script:failed++
            Write-Host "  FAIL  $Name"
            Write-Host "        Reason : $($result.Reason)"
        }
    }
    catch {
        $script:failed++
        Write-Host "  FAIL  $Name"
        Write-Host "        Exception: $_"
    }
    finally {
        $env:PATH = $oldPath
        Set-Location $oldCwd
        Remove-Item -Recurse -Force $mockDir -ErrorAction SilentlyContinue
    }
}

function Assert-NoOp {
    param([string]$Output)
    # Accept both bare '{}' and pretty-printed '{  }' / '{ }' just in case
    if ($Output -match '^\{\s*\}$') {
        return @{ Pass = $true }
    }
    return @{ Pass = $false; Reason = "Expected '{}' (no-op) but got: $Output" }
}

function Assert-HasCleanupContext {
    param([string]$Output, [string[]]$Contains)
    try {
        $json = $Output | ConvertFrom-Json -ErrorAction Stop
        $ctx = $json.hookSpecificOutput.additionalContext
        if (-not $ctx) {
            return @{ Pass = $false; Reason = "additionalContext absent or empty. Output: $Output" }
        }
        foreach ($needle in $Contains) {
            if ($ctx -notlike "*$needle*") {
                return @{ Pass = $false; Reason = "additionalContext missing '$needle'. ctx=[$ctx]" }
            }
        }
        return @{ Pass = $true }
    }
    catch {
        return @{ Pass = $false; Reason = "JSON parse error or missing structure: $_. Output: $Output" }
    }
}

function Assert-CleanupContextOmitsNoise {
    param([string]$Context, [string[]]$Forbidden)

    foreach ($item in $Forbidden) {
        if ($Context -like "*$item*") {
            return @{ Pass = $false; Reason = "additionalContext should not mention '$item'. ctx=[$Context]" }
        }
    }

    return @{ Pass = $true }
}

function Assert-HasCleanupContextWithoutNoise {
    param(
        [string]$Output,
        [string[]]$Contains,
        [string[]]$Forbidden
    )

    $result = Assert-HasCleanupContext -Output $Output -Contains $Contains
    if (-not $result.Pass) {
        return $result
    }

    try {
        $json = $Output | ConvertFrom-Json -ErrorAction Stop
        return Assert-CleanupContextOmitsNoise -Context $json.hookSpecificOutput.additionalContext -Forbidden $Forbidden
    }
    catch {
        return @{ Pass = $false; Reason = "JSON parse error or missing structure: $_. Output: $Output" }
    }
}

function Assert-BranchFirstInContext {
    param([string]$Output, [string]$BranchContains, [string]$TrackingContains)
    try {
        $json = $Output | ConvertFrom-Json -ErrorAction Stop
        $ctx = $json.hookSpecificOutput.additionalContext
        if (-not $ctx) {
            return @{ Pass = $false; Reason = "No additionalContext. Output: $Output" }
        }

        $branchIdx = ([string]$ctx).IndexOf($BranchContains, [System.StringComparison]::OrdinalIgnoreCase)
        $trackingIdx = ([string]$ctx).IndexOf($TrackingContains, [System.StringComparison]::OrdinalIgnoreCase)

        if ($branchIdx -lt 0) {
            return @{ Pass = $false; Reason = "Branch marker '$BranchContains' not found in additionalContext" }
        }
        if ($trackingIdx -lt 0) {
            return @{ Pass = $false; Reason = "Tracking marker '$TrackingContains' not found in additionalContext" }
        }
        if ($branchIdx -lt $trackingIdx) {
            return @{ Pass = $true }
        }
        return @{ Pass = $false; Reason = "Branch info (pos $branchIdx) is NOT before tracking info (pos $trackingIdx)" }
    }
    catch {
        return @{ Pass = $false; Reason = "Exception in Assert-BranchFirstInContext: $_. Output: $Output" }
    }
}

# ---------------------------------------------------------------------------
# Temp work directory (no tracking files) — used by most scenarios
# ---------------------------------------------------------------------------
$emptyWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "detector-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $emptyWorkDir | Out-Null

# ---------------------------------------------------------------------------
# S7 work directory — has stale tracking files
# ---------------------------------------------------------------------------
$s7WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "detector-test-s7-$([System.IO.Path]::GetRandomFileName())"
$s7TrackingFile = Join-Path $s7WorkDir '.copilot-tracking' 'research' 'issue-40-stale.md'
New-Item -ItemType Directory -Path (Split-Path -Parent $s7TrackingFile) | Out-Null
Set-Content -Path $s7TrackingFile -Value @'
---
issue_id: "40"
title: "Test tracking file for S7"
---
# Issue #40 plan (test fixture — different issue from the stale branch)
'@ -Encoding UTF8

# ---------------------------------------------------------------------------
# S11 work directory — has issue-40 tracking file (same issue as stale branch)
# ---------------------------------------------------------------------------
$s11WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "detector-test-s11-$([System.IO.Path]::GetRandomFileName())"
$s11TrackingFile = Join-Path $s11WorkDir '.copilot-tracking' 'research' 'issue-40-stale.md'
New-Item -ItemType Directory -Path (Split-Path -Parent $s11TrackingFile) | Out-Null
Set-Content -Path $s11TrackingFile -Value @'
---
issue_id: "40"
title: "Test tracking file for S11 (same-issue dedup)"
---
# Issue #40 plan (test fixture)
'@ -Encoding UTF8

# ---------------------------------------------------------------------------
# S12 work directory — calibration-only persistent data
# ---------------------------------------------------------------------------
$s12WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "detector-test-s12-$([System.IO.Path]::GetRandomFileName())"
$s12CalibrationFile = Join-Path $s12WorkDir '.copilot-tracking' 'calibration' 'review-data.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $s12CalibrationFile) | Out-Null
Set-Content -Path $s12CalibrationFile -Value '{"calibration_version":1,"entries":[]}' -Encoding UTF8

# ---------------------------------------------------------------------------
# S13 work directory — calibration plus stale issue-tracking artifact
# ---------------------------------------------------------------------------
$s13WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "detector-test-s13-$([System.IO.Path]::GetRandomFileName())"
$s13CalibrationFile = Join-Path $s13WorkDir '.copilot-tracking' 'calibration' 'review-data.json'
$s13TrackingFile = Join-Path $s13WorkDir '.copilot-tracking' 'research' 'issue-185-red.md'
New-Item -ItemType Directory -Path (Split-Path -Parent $s13CalibrationFile) | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $s13TrackingFile) | Out-Null
Set-Content -Path $s13CalibrationFile -Value '{"calibration_version":1,"entries":[]}' -Encoding UTF8
Set-Content -Path $s13TrackingFile -Value @'
---
issue_id: "185"
title: "Issue 185 RED fixture"
---
# Fixture tracking file
'@ -Encoding UTF8

# ---------------------------------------------------------------------------
# S14 work directory — calibration plus stale branch
# ---------------------------------------------------------------------------
$s14WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "detector-test-s14-$([System.IO.Path]::GetRandomFileName())"
$s14CalibrationFile = Join-Path $s14WorkDir '.copilot-tracking' 'calibration' 'review-data.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $s14CalibrationFile) | Out-Null
Set-Content -Path $s14CalibrationFile -Value '{"calibration_version":1,"entries":[]}' -Encoding UTF8

# ---------------------------------------------------------------------------
# Run scenarios
# ---------------------------------------------------------------------------
Write-Host "`nRunning session-cleanup-detector.ps1 verification (issue #40)`n"

# S1 — On main: fast no-op (no tracking files, no stale branch)
Invoke-Scenario `
    -Name 'S1: On main — no-op (fast exit, no tracking files)' `
    -GitConfig @{
    'branch--show-current'     = 'main'
    'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
} `
    -WorkDir $emptyWorkDir `
    -Assert { param($o) Assert-NoOp $o }

# S2 — On feature/issue-36-stale, upstream set, remote gone → expect cleanup JSON with issue #36
Invoke-Scenario `
    -Name 'S2: Stale branch feature/issue-36-stale (remote gone) → cleanup JSON' `
    -GitConfig @{
    'branch--show-current'             = 'feature/issue-36-stale'
    'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
    'rev-parse-exit'                   = 0
    'rev-parse-upstream'               = 'origin/feature/issue-36-stale'
    'ls-remote-feature/issue-36-stale' = ''   # empty = remote gone
    'ls-remote-feature/issue-36-*'     = ''
    'branch-list-feature/issue-36-*'   = '  feature/issue-36-stale'
} `
    -WorkDir $emptyWorkDir `
    -Assert {
    param($o)
    Assert-HasCleanupContext $o -Contains @('issue-36', 'post-merge-cleanup.ps1')
}

# S3 — On my-experiment, upstream set, remote gone → cleanup JSON with git checkout fallback
Invoke-Scenario `
    -Name 'S3: Stale branch my-experiment (no issue number, remote gone) → cleanup JSON with checkout fallback' `
    -GitConfig @{
    'branch--show-current'     = 'my-experiment'
    'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
    'rev-parse-exit'           = 0
    'rev-parse-upstream'       = 'origin/my-experiment'
    'ls-remote-my-experiment'  = ''   # remote gone
} `
    -WorkDir $emptyWorkDir `
    -Assert {
    param($o)
    # Expects cleanup context mentioning the branch and a checkout fallback (no issue number)
    Assert-HasCleanupContext $o -Contains @('my-experiment', 'git checkout')
}

# S4 — Local branch with NO upstream tracking → no-op (never pushed)
Invoke-Scenario `
    -Name 'S4: Local branch no-upstream → no-op (never pushed)' `
    -GitConfig @{
    'branch--show-current' = 'local-only-branch'
    'rev-parse-exit'       = 128   # no upstream
} `
    -WorkDir $emptyWorkDir `
    -Assert { param($o) Assert-NoOp $o }

# S5 — Detached HEAD (empty branch name) → no-op
Invoke-Scenario `
    -Name 'S5: Detached HEAD (empty branch --show-current) → no-op' `
    -GitConfig @{
    'branch--show-current' = ''    # empty = detached HEAD
    'rev-parse-exit'       = 128
} `
    -WorkDir $emptyWorkDir `
    -Assert { param($o) Assert-NoOp $o }

# S6 — On feature/issue-99-active, upstream set, remote STILL EXISTS → no-op
Invoke-Scenario `
    -Name 'S6: Active branch feature/issue-99-active (remote exists) → no-op' `
    -GitConfig @{
    'branch--show-current'              = 'feature/issue-99-active'
    'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
    'rev-parse-exit'                    = 0
    'rev-parse-upstream'                = 'origin/feature/issue-99-active'
    'ls-remote-feature/issue-99-active' = 'abc123def456 refs/heads/feature/issue-99-active'  # remote exists
    'ls-remote-feature/issue-99-*'      = 'abc123def456 refs/heads/feature/issue-99-active'
    'branch-list-feature/issue-99-*'    = '  feature/issue-99-active'
} `
    -WorkDir $emptyWorkDir `
    -Assert { param($o) Assert-NoOp $o }

# S7 — Stale branch (issue-36) + stale tracking files (issue-40) → cleanup JSON with branch info FIRST
# Branch is issue-36; tracking file is issue-40 — different issues so dedup keeps the tracking entry.
Invoke-Scenario `
    -Name 'S7: Stale branch (issue-36) + tracking file (issue-40) → branch info first in cleanup JSON' `
    -GitConfig @{
    'branch--show-current'                       = 'feature/issue-36-janitor-to-hook'
    'symbolic-ref-origin-HEAD'                   = 'refs/remotes/origin/main'
    'rev-parse-exit'                             = 0
    'rev-parse-upstream'                         = 'origin/feature/issue-36-janitor-to-hook'
    'ls-remote-feature/issue-36-janitor-to-hook' = ''   # remote gone (branch stale)
    'ls-remote-feature/issue-40-*'               = ''   # tracking file issue-40 also stale
    'branch-list-feature/issue-40-*'             = '  feature/issue-40-stale-branch'
} `
    -WorkDir $s7WorkDir `
    -Assert {
    param($o)
    # Combined-signal header must be present, branch info before tracking section
    Assert-BranchFirstInContext $o `
        -BranchContains 'feature/issue-36-janitor-to-hook' `
        -TrackingContains 'stale tracking artifacts also found'
}

# S8 — Master-branch repository: symbolic-ref fails, show-ref main fails, show-ref master succeeds
# Branch has no issue number → fallback uses 'git checkout master'
Invoke-Scenario `
    -Name 'S8: Master-branch repo (show-ref master) → cleanup uses master in fallback command' `
    -GitConfig @{
    'branch--show-current'     = 'feature/my-experiment-master'
    'show-ref-main-exitcode'   = 1    # main not found
    'show-ref-master-exitcode' = 0    # master found
    'rev-parse-exit'           = 0
    'rev-parse-upstream'       = 'origin/feature/my-experiment-master'
    # ls-remote default = '' (empty = stale branch)
} `
    -WorkDir $emptyWorkDir `
    -Assert {
    param($o)
    # Cleanup context must exist and reference 'master' in the fallback checkout command
    Assert-HasCleanupContext $o -Contains @('my-experiment-master', 'master')
}

# S9 — HEAD-fallback strategy: symbolic-ref origin/HEAD fails, both show-ref fail,
# git symbolic-ref HEAD returns refs/heads/develop → default branch = develop
Invoke-Scenario `
    -Name 'S9: HEAD-fallback (symbolic-ref HEAD) → stale branch still fires cleanup' `
    -GitConfig @{
    'branch--show-current'     = 'feature/my-experiment-head-fallback'
    'show-ref-main-exitcode'   = 1    # main not found
    'show-ref-master-exitcode' = 1    # master not found
    'symbolic-ref-HEAD'        = 'refs/heads/develop'
    'rev-parse-exit'           = 0
    'rev-parse-upstream'       = 'origin/feature/my-experiment-head-fallback'
    # ls-remote default = '' (empty = stale branch)
} `
    -WorkDir $emptyWorkDir `
    -Assert {
    param($o)
    # Cleanup context must be non-empty — branch detected as stale
    Assert-HasCleanupContext $o -Contains @('my-experiment-head-fallback')
}

# S10 — ls-remote network failure → Assert-NoOp (PAT-4)
Invoke-Scenario `
    -Name 'S10: ls-remote network failure (exit 1) → no-op (guard prevents false positive)' `
    -GitConfig @{
    'branch--show-current'     = 'feature/issue-40-net-fail'
    'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
    'rev-parse-exit'           = 0
    'rev-parse-upstream'       = 'origin/feature/issue-40-net-fail'
    'ls-remote-exitcode'       = 1    # network failure
} `
    -WorkDir $emptyWorkDir `
    -Assert { param($o) Assert-NoOp $o }

# S11 — Same-issue dual-signal: branch issue-40 + tracking file issue-40 → dedup → single command (PAT-1)
Invoke-Scenario `
    -Name 'S11: Same-issue dual-signal (issue-40 branch + tracking file) → single cleanup command, no tracking section' `
    -GitConfig @{
    'branch--show-current'                    = 'feature/issue-40-stale-branch'
    'symbolic-ref-origin-HEAD'                = 'refs/remotes/origin/main'
    'rev-parse-exit'                          = 0
    'rev-parse-upstream'                      = 'origin/feature/issue-40-stale-branch'
    'ls-remote-feature/issue-40-stale-branch' = ''   # branch stale
    'ls-remote-feature/issue-40-*'            = ''   # tracking file issue-40 also stale
    'branch-list-feature/issue-40-*'          = '  feature/issue-40-stale-branch'
} `
    -WorkDir $s11WorkDir `
    -Assert {
    param($o)
    try {
        $json = $o | ConvertFrom-Json -ErrorAction Stop
        $ctx = $json.hookSpecificOutput.additionalContext
        if (-not $ctx) {
            return @{ Pass = $false; Reason = "Expected cleanup context but additionalContext is empty. Output: $o" }
        }
        # Exactly one reference to post-merge-cleanup.ps1 (dedup removed the tracking entry)
        $cmdMatches = ([regex]::Matches($ctx, 'post-merge-cleanup\.ps1')).Count
        if ($cmdMatches -ne 1) {
            return @{ Pass = $false; Reason = "Expected exactly 1 post-merge-cleanup.ps1 reference, found $cmdMatches. ctx=[$ctx]" }
        }
        # Tracking-file sub-section must be absent (deduplicated away)
        if ($ctx -like '*stale tracking artifacts also found*') {
            return @{ Pass = $false; Reason = "Tracking-file section should be absent after dedup but was found. ctx=[$ctx]" }
        }
        return @{ Pass = $true }
    }
    catch {
        return @{ Pass = $false; Reason = "JSON parse error: $_. Output: $o" }
    }
}

# S12 — Calibration-only subtree → no-op
Invoke-Scenario `
    -Name 'S12: Calibration-only persistent data → no-op' `
    -GitConfig @{
    'branch--show-current'     = 'main'
    'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
} `
    -WorkDir $s12WorkDir `
    -Assert { param($o) Assert-NoOp $o }

# S13 — Calibration + stale issue tracking artifact → report only the issue artifact
Invoke-Scenario `
    -Name 'S13: Calibration + stale issue tracking artifact → issue artifact only' `
    -GitConfig @{
    'branch--show-current'       = 'main'
    'symbolic-ref-origin-HEAD'   = 'refs/remotes/origin/main'
    'ls-remote-feature/issue-185-*' = ''
    'branch-list-feature/issue-185-*' = '  feature/issue-185-red'
} `
    -WorkDir $s13WorkDir `
    -Assert {
    param($o)
    Assert-HasCleanupContextWithoutNoise `
        -Output $o `
        -Contains @('Issue #185', 'post-merge-cleanup.ps1') `
        -Forbidden @('calibration', 'review-data.json', 'tracking file(s) with no issue ID')
}

# S14 — Calibration + stale branch → stale branch still reported
Invoke-Scenario `
    -Name 'S14: Calibration + stale branch → branch cleanup still reported' `
    -GitConfig @{
    'branch--show-current'                     = 'feature/issue-185-stale-branch'
    'symbolic-ref-origin-HEAD'                 = 'refs/remotes/origin/main'
    'rev-parse-exit'                           = 0
    'rev-parse-upstream'                       = 'origin/feature/issue-185-stale-branch'
    'ls-remote-feature/issue-185-stale-branch' = ''
} `
    -WorkDir $s14WorkDir `
    -Assert {
    param($o)
    Assert-HasCleanupContextWithoutNoise `
        -Output $o `
        -Contains @('feature/issue-185-stale-branch', 'post-merge-cleanup.ps1') `
        -Forbidden @('calibration', 'review-data.json', 'tracking file(s) with no issue ID')
}

# ---------------------------------------------------------------------------
# Cleanup temp directories
# ---------------------------------------------------------------------------
Remove-Item -Recurse -Force $emptyWorkDir -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $s7WorkDir    -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $s11WorkDir   -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $s12WorkDir   -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $s13WorkDir   -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $s14WorkDir   -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$total = $script:passed + $script:failed
Write-Host "`n== Results: $($script:passed) passed, $($script:failed) failed (of $total) =="

exit ($script:failed -gt 0 ? 1 : 0)
