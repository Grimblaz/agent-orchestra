#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for session-cleanup-detector.ps1.

.DESCRIPTION
    Contract:
      Test A – valid -RepoRoot                               → exit 0
      Test B – empty -RepoRoot                               → exit non-zero with plugin-install guidance
      Test C – wrapper smoke (no env vars, $PSScriptRoot)    → exit 0
      Test E – ONLY calibration cache present                → exit 0 with '{}'
      Test F – Calibration + stale issue tracking artifact   → reports only the stale issue artifact
      Test G – Calibration + stale branch                    → still reports the stale branch

    Tests A-C cover the repo-root resolution contract after env var removal
    (v2.0.0 — the wrapper now resolves repo root via $PSScriptRoot). Tests
    E-G are the calibration-exclusion coverage originally added for issue #185.
#>

Describe 'session-cleanup-detector.ps1 — repo root resolution' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills\session-startup\scripts\session-cleanup-detector.ps1'
        $script:LibFile = Join-Path $script:RepoRoot 'skills\session-startup\scripts\session-cleanup-detector-core.ps1'
        . $script:LibFile
    }

    Context 'when -RepoRoot is a valid path' {
        It 'exits 0' {
            Push-Location $script:RepoRoot
            try {
                $result = Invoke-SessionCleanupDetector -RepoRoot $script:RepoRoot
                $result.ExitCode | Should -Be 0 -Because 'a valid repo root should satisfy the resolution gate'
            }
            finally {
                Pop-Location
            }
        }
    }

    Context 'when -RepoRoot is empty' {
        It 'exits non-zero' {
            $result = Invoke-SessionCleanupDetector -RepoRoot ''
            $result.ExitCode | Should -Not -Be 0 -Because 'empty repo root must signal failure'
        }

        It 'emits a plugin-install hint in the error JSON' {
            $result = Invoke-SessionCleanupDetector -RepoRoot ''
            $result.Output | Should -Match 'agent-orchestra|plugin' `
                -Because 'the error message must direct users to the plugin install path'
        }
    }

    Context 'wrapper smoke test' {
        It 'exits 0 with no env vars set (repo root resolved via $PSScriptRoot)' {
            $null = & pwsh -NoProfile -NonInteractive -File $script:ScriptFile 2>$null
            $LASTEXITCODE | Should -Be 0 -Because 'wrapper must resolve repo root via $PSScriptRoot without any env vars'
        }
    }
}

Describe 'session-cleanup-detector.ps1 — calibration tracking exclusion' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills\session-startup\scripts\session-cleanup-detector.ps1'
        . (Join-Path $script:RepoRoot 'skills\session-startup\scripts\session-cleanup-detector-core.ps1')

        $script:CopilotBaselineFixturePath = Join-Path $PSScriptRoot 'fixtures\copilot-baseline-additional-context.txt'
        $script:SavedPath = $env:PATH

        $script:NewMockGitDir = {
            param(
                [string]$ParentDir,
                [hashtable]$Config
            )

            $mockDir = Join-Path $ParentDir "git-mock-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $mockDir -Force | Out-Null

            $Config | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $mockDir 'git-mock-config.json') -Encoding UTF8

            $mockPs1 = @'
param()
$configPath = Join-Path $PSScriptRoot 'git-mock-config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json
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

if ($a.Count -ge 3 -and $a[0] -eq 'rev-parse' -and $a[1] -eq '--abbrev-ref' -and $a[2] -eq '@{u}') {
    $upstreamExit = if ($null -ne $config.'rev-parse-exit') { [int]$config.'rev-parse-exit' } else { 128 }
    if ($upstreamExit -eq 0) {
        $val = $config.'rev-parse-upstream'
        if ($null -ne $val) { Write-Output $val }
        exit 0
    }
    exit $upstreamExit
}

if ($a.Count -ge 4 -and $a[0] -eq 'ls-remote' -and $a[1] -eq '--heads' -and $a[2] -eq 'origin') {
    $pattern = $a[3]
    $exactKey = "ls-remote-$pattern"
    if ($null -ne $config.$exactKey) { Write-Output $config.$exactKey; exit 0 }
    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -like 'ls-remote-*') {
            $keyPattern = $prop.Name.Substring('ls-remote-'.Length)
            if ($pattern -like $keyPattern) {
                Write-Output $prop.Value
                exit 0
            }
        }
    }
    if ($null -ne $config.'ls-remote-default') { Write-Output $config.'ls-remote-default' }
    exit 0
}

if ($a.Count -ge 3 -and $a[0] -eq 'branch' -and $a[1] -eq '--list') {
    $pattern = $a[2]
    $key = "branch-list-$pattern"
    if ($null -ne $config.$key) { Write-Output $config.$key; exit 0 }
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

exit 0
'@
            Set-Content -Path (Join-Path $mockDir 'git-mock.ps1') -Value $mockPs1 -Encoding UTF8

            $ps1Shim = @'
#!/usr/bin/env pwsh
& (Join-Path $PSScriptRoot 'git-mock.ps1') @args
exit $LASTEXITCODE
'@
            Set-Content -Path (Join-Path $mockDir 'git.ps1') -Value $ps1Shim -Encoding UTF8

            $cmdContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0git-mock.ps1`" %*`r`nexit %ERRORLEVEL%"
            Set-Content -Path (Join-Path $mockDir 'git.cmd') -Value $cmdContent -Encoding ASCII

            return $mockDir
        }

        # In-process helper: injects git mock via PATH, changes CWD, calls library directly.
        # Note: git mock .cmd wrappers internally spawn child pwsh processes — this is a known
        # residual limitation of the git mock infrastructure and cannot be eliminated here.
        $script:InvokeDetectorInWorkDir = {
            param(
                [string]$WorkDir,
                [hashtable]$GitConfig,
                [string]$RepoRoot = $script:RepoRoot
            )

            $mockDir = & $script:NewMockGitDir -ParentDir $WorkDir -Config $GitConfig
            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"
                Push-Location $WorkDir
                try {
                    return Invoke-SessionCleanupDetector -RepoRoot $RepoRoot
                }
                finally {
                    Pop-Location
                }
            }
            finally {
                $env:PATH = $script:SavedPath
                Remove-Item -Recurse -Force -Path $mockDir -ErrorAction SilentlyContinue
            }
        }

        $script:WriteFixtureFile = {
            param(
                [string]$WorkDir,
                [string]$RelativePath,
                [string]$Content
            )

            $filePath = Join-Path $WorkDir $RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $filePath) -Force | Out-Null
            $Content | Set-Content -Path $filePath -Encoding UTF8
            return $filePath
        }

        $script:GetAdditionalContext = {
            param([string]$Output)

            $json = $Output | ConvertFrom-Json -ErrorAction Stop
            return $json.hookSpecificOutput.additionalContext
        }

        $script:AssertCalibrationNoiseExcluded = {
            param([string]$Context)

            $Context | Should -Not -Match 'calibration|review-data\.json'
            $Context | Should -Not -Match 'tracking file\(s\) with no issue ID'
        }

        $script:GetUtf8Hex = {
            param([Parameter(Mandatory)][string]$Text)

            return [System.Convert]::ToHexString([System.Text.Encoding]::UTF8.GetBytes($Text))
        }
    }

    AfterAll {
        $env:PATH = $script:SavedPath
    }

    It 'returns a no-op when only calibration data is present' {
        $workDir = Join-Path $TestDrive 'calibration-only'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\calibration\review-data.json' -Content '{"calibration_version":1,"entries":[]}' | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'     = 'main'
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match '^\{\s*\}$'
    }

    It 'T8 AC9 returns a no-op on the default branch when no tracking files are present' {
        $workDir = Join-Path $TestDrive 'default-branch-clean'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'     = 'main'
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match '^\{\s*\}$'
    }

    It 'T6 AC7 preserves the current-branch Copilot stale cleanup output byte for byte' {
        $workDir = Join-Path $TestDrive 'copilot-current-branch-baseline'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -RepoRoot 'C:/agent-orchestra' -GitConfig @{
            'branch--show-current'                                       = 'feature/issue-452-cleanup-detector-worktrees'
            'symbolic-ref-origin-HEAD'                                   = 'refs/remotes/origin/main'
            'rev-parse-exit'                                             = 0
            'rev-parse-upstream'                                         = 'origin/feature/issue-452-cleanup-detector-worktrees'
            'ls-remote-feature/issue-452-cleanup-detector-worktrees'     = ''
        }
        $context = & $script:GetAdditionalContext -Output $result.Output
        $expectedBytes = [System.IO.File]::ReadAllBytes($script:CopilotBaselineFixturePath)
        $expectedHex = [System.Convert]::ToHexString($expectedBytes)
        $actualHex = & $script:GetUtf8Hex -Text $context

        $result.ExitCode | Should -Be 0
        $actualHex | Should -BeExactly $expectedHex `
            -Because 'the current-branch Copilot cleanup message is a compatibility contract for SessionStart additionalContext'
    }

    It 'reports only the stale issue artifact when calibration data coexists with stale tracking state' {
        $workDir = Join-Path $TestDrive 'calibration-plus-stale-issue'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\calibration\review-data.json' -Content '{"calibration_version":1,"entries":[]}' | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\research\issue-185-red.md' -Content @'
---
issue_id: "185"
title: "Issue 185 RED fixture"
---
# Fixture tracking file
'@ | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'            = 'main'
            'symbolic-ref-origin-HEAD'        = 'refs/remotes/origin/main'
            'ls-remote-feature/issue-185-*'   = ''
            'branch-list-feature/issue-185-*' = '  feature/issue-185-red'
        }
        $context = & $script:GetAdditionalContext -Output $result.Output

        $result.ExitCode | Should -Be 0
        $context | Should -Match 'Issue #185'
        & $script:AssertCalibrationNoiseExcluded -Context $context
    }

    It 'still reports a stale branch when calibration data is present' {
        $workDir = Join-Path $TestDrive 'calibration-plus-stale-branch'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\calibration\review-data.json' -Content '{"calibration_version":1,"entries":[]}' | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'                     = 'feature/issue-185-stale-branch'
            'symbolic-ref-origin-HEAD'                 = 'refs/remotes/origin/main'
            'rev-parse-exit'                           = 0
            'rev-parse-upstream'                       = 'origin/feature/issue-185-stale-branch'
            'ls-remote-feature/issue-185-stale-branch' = ''
        }
        $context = & $script:GetAdditionalContext -Output $result.Output

        $result.ExitCode | Should -Be 0
        $context | Should -Match 'feature/issue-185-stale-branch'
        & $script:AssertCalibrationNoiseExcluded -Context $context
    }
}
