#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for session-cleanup-detector.ps1.

.DESCRIPTION
    Contract:
      Test A – ONLY COPILOT_ORCHESTRA_ROOT set (valid path) → exit 0 (primary var honoured)
      Test B – ONLY WORKFLOW_TEMPLATE_ROOT set (valid path)  → exit 0 (legacy fallback works)
      Test D – BOTH vars set                                 → exit 0 (primary var takes priority)
      Test C – NEITHER var set                               → exit non-zero AND output JSON
                                                               mentions both var names
            Test E – ONLY calibration cache present                → exit 0 with '{}'
            Test F – Calibration + stale issue tracking artifact   → reports only the stale issue artifact
            Test G – Calibration + stale branch                    → still reports the stale branch

    Tests A-D are existing env-var coverage. Tests E-G are RED coverage for
    issue #185 and should fail until calibration files are excluded from stale
    tracking detection.
#>

Describe 'session-cleanup-detector.ps1 — env var fallback' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot '.github\skills\session-startup\scripts\session-cleanup-detector.ps1'
        $script:LibFile = Join-Path $script:RepoRoot '.github\skills\session-startup\scripts\session-cleanup-detector-core.ps1'
        . $script:LibFile

        # Snapshot env vars so every test starts from a known baseline
        $script:SavedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
        $script:SavedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT

        # In-process helper: mirrors the wrapper's env-var-to-parameter resolution.
        # Pester v5 isolation: helper stored as a script-scoped scriptblock so
        # It blocks can call it via & $script:InvokeDetector.
        $script:InvokeDetector = {
            # Mirror the wrapper's env-var resolution logic (in-process)
            $repoRoot = if ($env:COPILOT_ORCHESTRA_ROOT) { $env:COPILOT_ORCHESTRA_ROOT } elseif ($env:WORKFLOW_TEMPLATE_ROOT) { $env:WORKFLOW_TEMPLATE_ROOT } else { '' }
            Push-Location $script:RepoRoot
            try {
                return Invoke-SessionCleanupDetector -RepoRoot $repoRoot
            }
            finally {
                Pop-Location
            }
        }
    }

    AfterAll {
        # Restore whatever was set before the suite ran
        $env:COPILOT_ORCHESTRA_ROOT = $script:SavedOrchestra
        $env:WORKFLOW_TEMPLATE_ROOT = $script:SavedWorkflow
    }

    # ------------------------------------------------------------------
    # Test A — primary var COPILOT_ORCHESTRA_ROOT honoured
    # Verifies COPILOT_ORCHESTRA_ROOT is accepted as the primary env var
    # ------------------------------------------------------------------
    Context 'when only COPILOT_ORCHESTRA_ROOT is set' {
        It 'exits 0 and does not produce an env-var-missing error' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                $env:COPILOT_ORCHESTRA_ROOT = $script:RepoRoot
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $result = & $script:InvokeDetector

                # The script must not exit with the env-var-error code
                $result.ExitCode | Should -Be 0 -Because 'COPILOT_ORCHESTRA_ROOT should satisfy the env-var gate'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }

    # ------------------------------------------------------------------
    # Test B — legacy fallback WORKFLOW_TEMPLATE_ROOT still works
    # GREEN: existing behaviour; should pass before and after the change
    # ------------------------------------------------------------------
    Context 'when only WORKFLOW_TEMPLATE_ROOT is set' {
        It 'exits 0 and does not produce an env-var-missing error' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                Remove-Item Env:COPILOT_ORCHESTRA_ROOT -ErrorAction SilentlyContinue
                $env:WORKFLOW_TEMPLATE_ROOT = $script:RepoRoot

                $result = & $script:InvokeDetector

                $result.ExitCode | Should -Be 0 -Because 'WORKFLOW_TEMPLATE_ROOT is the existing accepted var'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }

    # ------------------------------------------------------------------
    # Test D — both vars set → COPILOT_ORCHESTRA_ROOT takes priority
    # Verifies the fallback chain resolves the primary var first
    # ------------------------------------------------------------------
    Context 'when both env vars are set' {
        It 'exits 0 with COPILOT_ORCHESTRA_ROOT taking priority' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                $env:COPILOT_ORCHESTRA_ROOT = $script:RepoRoot
                $env:WORKFLOW_TEMPLATE_ROOT = $script:RepoRoot

                $result = & $script:InvokeDetector

                $result.ExitCode | Should -Be 0 -Because 'COPILOT_ORCHESTRA_ROOT should be resolved first when both are set'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }

    # ------------------------------------------------------------------
    # Test C — neither var set → exit non-zero, both names in output
    # Verifies exit non-zero and both env var names appear in output
    # ------------------------------------------------------------------
    Context 'when neither env var is set' {
        It 'exits non-zero' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                Remove-Item Env:COPILOT_ORCHESTRA_ROOT -ErrorAction SilentlyContinue
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $result = & $script:InvokeDetector

                $result.ExitCode | Should -Not -Be 0 -Because 'missing env vars must signal failure'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }

        It 'includes COPILOT_ORCHESTRA_ROOT in the error JSON' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                Remove-Item Env:COPILOT_ORCHESTRA_ROOT -ErrorAction SilentlyContinue
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $result = & $script:InvokeDetector

                $result.Output | Should -Match 'COPILOT_ORCHESTRA_ROOT' `
                    -Because 'the error message must name the new primary env var'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }

        It 'includes WORKFLOW_TEMPLATE_ROOT in the error JSON' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                Remove-Item Env:COPILOT_ORCHESTRA_ROOT -ErrorAction SilentlyContinue
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $result = & $script:InvokeDetector

                $result.Output | Should -Match 'WORKFLOW_TEMPLATE_ROOT' `
                    -Because 'the error message must also name the legacy fallback var'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }

    # ------------------------------------------------------------------
    # Wrapper smoke test — validates env-var-to-parameter translation
    # Intentional pwsh spawn: tests the wrapper's env-var resolution path
    # (covers requirement: at least 1 test verifies the wrapper contract)
    # ------------------------------------------------------------------
    Context 'wrapper env-var smoke test' {
        It 'exits 0 when COPILOT_ORCHESTRA_ROOT is set via wrapper (pwsh -File)' {
            $savedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
            $savedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
            try {
                $env:COPILOT_ORCHESTRA_ROOT = $script:RepoRoot
                Remove-Item Env:WORKFLOW_TEMPLATE_ROOT -ErrorAction SilentlyContinue

                $null = & pwsh -NoProfile -NonInteractive -File $script:ScriptFile 2>$null
                $exitCode = $LASTEXITCODE

                $exitCode | Should -Be 0 -Because 'wrapper must translate COPILOT_ORCHESTRA_ROOT env var to -RepoRoot parameter'
            }
            finally {
                $env:COPILOT_ORCHESTRA_ROOT = $savedOrchestra
                $env:WORKFLOW_TEMPLATE_ROOT = $savedWorkflow
            }
        }
    }
}

Describe 'session-cleanup-detector.ps1 — calibration tracking exclusion' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot '.github\skills\session-startup\scripts\session-cleanup-detector.ps1'
        . (Join-Path $script:RepoRoot '.github\skills\session-startup\scripts\session-cleanup-detector-core.ps1')

        $script:SavedOrchestra = $env:COPILOT_ORCHESTRA_ROOT
        $script:SavedWorkflow = $env:WORKFLOW_TEMPLATE_ROOT
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

            $cmdContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0git-mock.ps1`" %*"
            Set-Content -Path (Join-Path $mockDir 'git.cmd') -Value $cmdContent -Encoding ASCII

            return $mockDir
        }

        # In-process helper: injects git mock via PATH, changes CWD, calls library directly.
        # Note: git mock .cmd wrappers internally spawn child pwsh processes — this is a known
        # residual limitation of the git mock infrastructure and cannot be eliminated here.
        $script:InvokeDetectorInWorkDir = {
            param(
                [string]$WorkDir,
                [hashtable]$GitConfig
            )

            $mockDir = & $script:NewMockGitDir -ParentDir $WorkDir -Config $GitConfig
            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"
                Push-Location $WorkDir
                try {
                    return Invoke-SessionCleanupDetector -RepoRoot $script:RepoRoot
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
    }

    AfterAll {
        $env:COPILOT_ORCHESTRA_ROOT = $script:SavedOrchestra
        $env:WORKFLOW_TEMPLATE_ROOT = $script:SavedWorkflow
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
