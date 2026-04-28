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
    T2/T3/T4/T11 – Current no-upstream claude/* worktree detection and fail-open behavior
    T1/T3/T4b/T5/T9/T10/T13 – Sibling worktree detection, fail-open behavior, and command placement

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

function Get-MockConfigValue {
    param([string]$Name)

    $property = $config.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Normalize-MockPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

function Get-MockPathConfigValue {
    param(
        [string]$Name,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $pathConfigs = Get-MockConfigValue 'path-configs'
    if ($null -eq $pathConfigs) { return $null }

    $normalizedPath = Normalize-MockPath $Path
    foreach ($entry in $pathConfigs.PSObject.Properties) {
        if ((Normalize-MockPath $entry.Name) -eq $normalizedPath) {
            $property = $entry.Value.PSObject.Properties[$Name]
            if ($null -ne $property) { return $property.Value }
            return $null
        }
    }

    return $null
}

function Get-MockConfigValueForPath {
    param(
        [string]$Name,
        [string]$Path
    )

    $pathValue = Get-MockPathConfigValue -Name $Name -Path $Path
    if ($null -ne $pathValue) { return $pathValue }

    return Get-MockConfigValue $Name
}

$originalArgs = @($a)
$gitWorkDir = $null
if ($a.Count -ge 3 -and $a[0] -eq '-C') {
    $gitWorkDir = $a[1]
    $a = @($a[2..($a.Count - 1)])
}

$callLogPath = Join-Path $PSScriptRoot 'git-mock-calls.log'
($originalArgs -join "`t") | Add-Content -Path $callLogPath -Encoding UTF8

if ($a.Count -ge 3 -and $a[0] -eq 'worktree' -and $a[1] -eq 'list' -and $a[2] -eq '--porcelain') {
    $exitValue = Get-MockConfigValue 'worktree-list-exit'
    if ($null -eq $exitValue) { $exitValue = 0 }
    $val = Get-MockConfigValue 'worktree-list-porcelain'
    if ($null -ne $val) { Write-Output $val }
    exit ([int]$exitValue)
}

if ($a.Count -ge 2 -and $a[0] -eq 'branch' -and $a[1] -eq '--show-current') {
    $val = Get-MockConfigValueForPath -Name 'branch--show-current' -Path $gitWorkDir
    if ($null -ne $val) { Write-Output $val }
    exit 0
}

if ($a.Count -ge 2 -and $a[0] -eq 'symbolic-ref' -and $a[1] -eq 'refs/remotes/origin/HEAD') {
    $val = $config.'symbolic-ref-origin-HEAD'
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 128
}

if ($a.Count -ge 2 -and $a[0] -eq 'symbolic-ref' -and $a[1] -eq 'HEAD') {
    $val = Get-MockConfigValueForPath -Name 'symbolic-ref-HEAD' -Path $gitWorkDir
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 128
}

if ($a.Count -ge 3 -and $a[0] -eq 'config' -and $a[1] -eq '--get' -and $a[2] -match '^branch\..+\.(remote|merge)$') {
    $val = Get-MockConfigValueForPath -Name "config-$($a[2])" -Path $gitWorkDir
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 1
}

if ($a.Count -ge 4 -and $a[0] -eq 'show-ref' -and $a[1] -eq '--verify' -and $a[2] -eq '--quiet') {
    $ref = $a[3]
    $exitValue = Get-MockConfigValue "show-ref-$ref"
    if ($null -eq $exitValue) { $exitValue = Get-MockConfigValue 'show-ref-default-exit' }
    if ($null -eq $exitValue) { $exitValue = 1 }
    exit ([int]$exitValue)
}

if ($a.Count -ge 3 -and $a[0] -eq 'rev-parse' -and $a[1] -eq '--abbrev-ref' -and $a[2] -eq '@{u}') {
    $configuredExit = Get-MockConfigValueForPath -Name 'rev-parse-exit' -Path $gitWorkDir
    $upstreamExit = if ($null -ne $configuredExit) { [int]$configuredExit } else { 128 }
    if ($upstreamExit -eq 0) {
        $val = Get-MockConfigValueForPath -Name 'rev-parse-upstream' -Path $gitWorkDir
        if ($null -ne $val) { Write-Output $val }
        exit 0
    }
    exit $upstreamExit
}

if ($a.Count -ge 4 -and $a[0] -eq 'ls-remote' -and $a[1] -eq '--heads' -and $a[2] -eq 'origin') {
    $pattern = $a[3]
    $exactKey = "ls-remote-$pattern"
    $exactValue = Get-MockConfigValue $exactKey
    if ($null -ne $exactValue) { Write-Output $exactValue; exit 0 }
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

if ($a.Count -ge 1 -and $a[0] -eq 'fetch') {
    if ((Get-MockConfigValue 'fetch-mode') -eq 'timeout') {
        exit 124
    }

    $fetchExit = Get-MockConfigValue 'fetch-exit'
    if ($null -eq $fetchExit) { $fetchExit = 0 }
    exit ([int]$fetchExit)
}

if ($a.Count -ge 4 -and $a[0] -eq 'merge-base' -and $a[1] -eq '--is-ancestor') {
    $candidateRef = $a[2]
    $targetRef = $a[3]
    $exitValue = Get-MockConfigValueForPath -Name "merge-base-$candidateRef-$targetRef" -Path $gitWorkDir
    if ($null -eq $exitValue) { $exitValue = Get-MockConfigValueForPath -Name "merge-base-$candidateRef" -Path $gitWorkDir }
    if ($null -eq $exitValue) { $exitValue = Get-MockConfigValue 'merge-base-exit' }
    if ($null -eq $exitValue) { $exitValue = 1 }
    exit ([int]$exitValue)
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
                [string]$RepoRoot = $script:RepoRoot,
                [switch]$IncludeGitCalls
            )

            $mockDir = & $script:NewMockGitDir -ParentDir $WorkDir -Config $GitConfig
            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"
                Push-Location $WorkDir
                try {
                    $result = Invoke-SessionCleanupDetector -RepoRoot $RepoRoot
                    if ($IncludeGitCalls) {
                        $callLogPath = Join-Path $mockDir 'git-mock-calls.log'
                        $result['GitCalls'] = if (Test-Path $callLogPath) {
                            @(Get-Content -Path $callLogPath -ErrorAction SilentlyContinue)
                        }
                        else {
                            @()
                        }
                    }
                    return $result
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

        $script:GetFencedPowerShellBlocks = {
            param([string]$Context)

            if ([string]::IsNullOrEmpty($Context)) { return @() }
            return @([regex]::Matches($Context, '(?ms)```powershell\s*(.*?)```') | ForEach-Object { $_.Groups[1].Value })
        }

        $script:RemoveFencedPowerShellBlocks = {
            param([string]$Context)

            if ([string]::IsNullOrEmpty($Context)) { return '' }
            return [regex]::Replace($Context, '(?ms)```powershell\s*.*?```', '')
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

        $script:ToPorcelainPath = {
            param([Parameter(Mandatory)][string]$Path)

            return ([System.IO.Path]::GetFullPath($Path)).Replace('\', '/')
        }

        $script:NewWorktreeRecord = {
            param(
                [Parameter(Mandatory)][string]$Path,
                [string]$Branch,
                [string[]]$States = @()
            )

            $lines = @(
                "worktree $Path",
                'HEAD 0000000000000000000000000000000000000000'
            )
            if (-not [string]::IsNullOrWhiteSpace($Branch)) {
                $lines += "branch refs/heads/$Branch"
            }
            $lines += $States

            return $lines -join "`n"
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

    Context 'current no-upstream Claude worktree detection' {
        It 'T2 AC1 AC8 surfaces a merged current claude worktree with inline cleanup outside the fenced block' {
            $workDir = Join-Path $TestDrive 'current-claude-merged'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/widget-fixer-abcde'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -RepoRoot 'C:/agent-orchestra' -GitConfig @{
                'branch--show-current'             = $branch
                'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
                'rev-parse-exit'                   = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                       = 0
                'merge-base-exit'                  = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $outsideFence = & $script:RemoveFencedPowerShellBlocks -Context $context
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match 'Post-merge cleanup detected'
            $context | Should -Match ([regex]::Escape($branch))
            $outsideFence | Should -Match '(?s)git worktree remove.*git branch -D'
            $outsideFence | Should -Match ([regex]::Escape($branch))
            $insideFence | Should -Not -Match 'git worktree remove'
            $insideFence | Should -Not -Match "git branch -D\s+'?$([regex]::Escape($branch))'?"
        }

        It 'T2 D1 AC1 derives the current claude merge-base target from the default branch remote' {
            $workDir = Join-Path $TestDrive 'current-claude-upstream-default-remote'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/upstream-default-abcde'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -RepoRoot 'C:/agent-orchestra' -IncludeGitCalls -GitConfig @{
                'branch--show-current'                 = $branch
                'symbolic-ref-HEAD'                    = 'refs/heads/main'
                'rev-parse-exit'                       = 128
                'config-branch.main.remote'            = 'upstream'
                'show-ref-refs/remotes/origin/main'    = 1
                'show-ref-refs/remotes/origin/master'  = 1
                'show-ref-refs/remotes/upstream/main'  = 0
                'fetch-exit'                           = 0
                "merge-base-$branch-refs/remotes/upstream/main" = 0
                "merge-base-$branch-refs/remotes/origin/main"   = 1
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $mergeBaseCalls = @($result['GitCalls'] | Where-Object { $_ -match '^merge-base\t--is-ancestor\t' })

            $result.ExitCode | Should -Be 0
            $context | Should -Match 'Post-merge cleanup detected'
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match 'refs/remotes/upstream/main'
            $result['GitCalls'] | Should -Contain "config`t--get`tbranch.main.remote"
            $result['GitCalls'] | Should -Contain "show-ref`t--verify`t--quiet`trefs/remotes/upstream/main"
            $mergeBaseCalls | Should -Contain "merge-base`t--is-ancestor`t$branch`trefs/remotes/upstream/main"
            $mergeBaseCalls | Should -Not -Contain "merge-base`t--is-ancestor`t$branch`trefs/remotes/origin/main"
        }

        It 'T3 AC3 leaves an unmerged current no-upstream claude worktree unflagged' {
            $workDir = Join-Path $TestDrive 'current-claude-unmerged'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'             = 'claude/in-flight-zyxwv'
                'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
                'rev-parse-exit'                   = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                       = 0
                'merge-base-exit'                  = 1
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$'
        }

        It 'T4 AC4 fails open when the remote default ref is missing for a no-upstream claude branch' {
            $workDir = Join-Path $TestDrive 'current-claude-missing-default'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                = 'claude/missing-default-abcde'
                'rev-parse-exit'                      = 128
                'show-ref-refs/remotes/origin/main'   = 1
                'show-ref-refs/remotes/origin/master' = 1
                'fetch-exit'                          = 0
                'merge-base-exit'                     = 0
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$'
        }

        It 'T4 AC4 fails open when merge-base returns an unexpected exit code for the current candidate' {
            $workDir = Join-Path $TestDrive 'current-claude-merge-base-error'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'             = 'claude/merge-base-error-abcde'
                'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
                'rev-parse-exit'                   = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                       = 0
                'merge-base-exit'                  = 2
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$'
        }

        It 'T4 AC4 uses local refs and does not throw when fetch fails for a merged current claude candidate' {
            $workDir = Join-Path $TestDrive 'current-claude-fetch-failure'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/fetch-failure-abcde'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'             = $branch
                'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
                'rev-parse-exit'                   = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                       = 128
                'merge-base-exit'                  = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match 'git worktree remove'
            $context | Should -Match 'git branch -D'
        }

        It 'T11 AC4 treats a fetch timeout sentinel as fail-open and continues with local refs' {
            $workDir = Join-Path $TestDrive 'current-claude-fetch-timeout'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/fetch-timeout-abcde'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'             = $branch
                'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
                'rev-parse-exit'                   = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-mode'                       = 'timeout'
                'merge-base-exit'                  = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match 'git worktree remove'
            $context | Should -Match 'git branch -D'
        }

        It 'AC6 does not fetch when a no-upstream current branch is outside the claude namespace' {
            $workDir = Join-Path $TestDrive 'current-non-claude-no-candidate'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -IncludeGitCalls -GitConfig @{
                'branch--show-current'             = 'scratch/local-only'
                'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
                'rev-parse-exit'                   = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                       = 99
            }
            $fetchCalls = @($result['GitCalls'] | Where-Object { $_ -match '^fetch(\t|$)' })

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$'
            $fetchCalls.Count | Should -Be 0
        }
    }

    Context 'sibling worktree cleanup detection' {
        It 'T1 AC2 surfaces a merged sibling claude worktree inside the fenced cleanup block' {
            $workDir = Join-Path $TestDrive 'sibling-claude-merged-current'
            $siblingDir = Join-Path $TestDrive 'sibling-claude-merged-other'
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            $branch = 'claude/foo-bar-12345'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $branch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                 = 'main'
                'symbolic-ref-origin-HEAD'             = 'refs/remotes/origin/main'
                'worktree-list-porcelain'              = $worktreeList
                'show-ref-refs/remotes/origin/main'    = 0
                'fetch-exit'                           = 0
                "merge-base-$branch-refs/remotes/origin/main" = 0
                'path-configs'                         = @{
                    "$siblingPath" = @{
                        'branch--show-current' = $branch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match 'Post-merge cleanup detected'
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match ([regex]::Escape($siblingPath))
            $insideFence | Should -Match ([regex]::Escape("git worktree remove '$siblingPath'"))
            $insideFence | Should -Match ([regex]::Escape("git branch -D '$branch'"))
        }

        It 'T3 AC3 leaves an unmerged sibling claude worktree unflagged' {
            $workDir = Join-Path $TestDrive 'sibling-claude-unmerged-current'
            $siblingDir = Join-Path $TestDrive 'sibling-claude-unmerged-other'
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            $branch = 'claude/in-flight-zyxwv'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $branch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                 = 'main'
                'symbolic-ref-origin-HEAD'             = 'refs/remotes/origin/main'
                'worktree-list-porcelain'              = $worktreeList
                'show-ref-refs/remotes/origin/main'    = 0
                'fetch-exit'                           = 0
                "merge-base-$branch-refs/remotes/origin/main" = 1
                'path-configs'                         = @{
                    "$siblingPath" = @{
                        'branch--show-current' = $branch
                        'rev-parse-exit'       = 128
                    }
                }
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$'
        }

        It 'T4b AC4 fails open for <CaseName> and preserves no-op output' -TestCases @(
            @{ CaseName = 'worktree-list failure'; CaseKind = 'list-failure' }
            @{ CaseName = 'missing branch line'; CaseKind = 'missing-branch' }
        ) {
            param(
                [string]$CaseName,
                [string]$CaseKind
            )

            $workDir = Join-Path $TestDrive ("sibling-fail-open-$($CaseKind)")
            $siblingDir = Join-Path $TestDrive ("sibling-fail-open-$($CaseKind)-other")
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir

            $gitConfig = @{
                'branch--show-current'     = 'main'
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
            }
            if ($CaseKind -eq 'list-failure') {
                $gitConfig['worktree-list-exit'] = 128
            }
            else {
                $gitConfig['worktree-list-porcelain'] = @(
                    (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                    (& $script:NewWorktreeRecord -Path $siblingPath -Branch '')
                ) -join "`n`n"
            }

            $result = $null
            $exception = $null
            try {
                $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig $gitConfig
            }
            catch {
                $exception = $_
            }

            $exception | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$'
        }

        It 'T5 AC8 keeps sibling cleanup commands in the fenced block while current-worktree commands stay outside' {
            $workDir = Join-Path $TestDrive 'sibling-placement-current'
            $siblingDir = Join-Path $TestDrive 'sibling-placement-other'
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            $currentBranch = 'claude/current-merged-abcde'
            $siblingBranch = 'claude/sibling-merged-abcde'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $currentBranch),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $siblingBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                 = $currentBranch
                'symbolic-ref-origin-HEAD'             = 'refs/remotes/origin/main'
                'rev-parse-exit'                       = 128
                'worktree-list-porcelain'              = $worktreeList
                'show-ref-refs/remotes/origin/main'    = 0
                'fetch-exit'                           = 0
                "merge-base-$currentBranch-refs/remotes/origin/main" = 0
                "merge-base-$siblingBranch-refs/remotes/origin/main" = 0
                'path-configs'                         = @{
                    "$siblingPath" = @{
                        'branch--show-current' = $siblingBranch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $outsideFence = & $script:RemoveFencedPowerShellBlocks -Context $context
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $outsideFence | Should -Match ([regex]::Escape($currentBranch))
            $outsideFence | Should -Match '(?s)git worktree remove.*git branch -D'
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$currentBranch'"))
            $insideFence | Should -Match ([regex]::Escape("git worktree remove '$siblingPath'"))
            $insideFence | Should -Match ([regex]::Escape("git branch -D '$siblingBranch'"))
            $outsideFence | Should -Not -Match ([regex]::Escape("git worktree remove '$siblingPath'"))
            $outsideFence | Should -Not -Match ([regex]::Escape("git branch -D '$siblingBranch'"))
        }

        It 'T9 D3 handles locked and prunable records while skipping bare and detached records' {
            $workDir = Join-Path $TestDrive 'sibling-porcelain-edge-current'
            $lockedDir = Join-Path $TestDrive 'sibling-porcelain-edge-locked'
            $prunableDir = Join-Path $TestDrive 'sibling-porcelain-edge-prunable'
            $bareDir = Join-Path $TestDrive 'sibling-porcelain-edge-bare'
            $detachedDir = Join-Path $TestDrive 'sibling-porcelain-edge-detached'
            New-Item -ItemType Directory -Path $workDir, $lockedDir, $prunableDir, $bareDir, $detachedDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $lockedPath = & $script:ToPorcelainPath -Path $lockedDir
            $prunablePath = & $script:ToPorcelainPath -Path $prunableDir
            $barePath = & $script:ToPorcelainPath -Path $bareDir
            $detachedPath = & $script:ToPorcelainPath -Path $detachedDir
            $lockedBranch = 'claude/locked-record-abcde'
            $prunableBranch = 'claude/prunable-record-abcde'
            $bareBranch = 'claude/bare-record-abcde'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $lockedPath -Branch $lockedBranch -States @('locked checked out by maintainer')),
                (& $script:NewWorktreeRecord -Path $prunablePath -Branch $prunableBranch -States @('prunable gitdir file points to missing checkout')),
                (& $script:NewWorktreeRecord -Path $barePath -Branch $bareBranch -States @('bare')),
                (& $script:NewWorktreeRecord -Path $detachedPath -Branch '' -States @('detached'))
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                 = 'main'
                'symbolic-ref-origin-HEAD'             = 'refs/remotes/origin/main'
                'worktree-list-porcelain'              = $worktreeList
                'show-ref-refs/remotes/origin/main'    = 0
                'fetch-exit'                           = 0
                'merge-base-exit'                      = 0
                'path-configs'                         = @{
                    "$lockedPath" = @{
                        'branch--show-current' = $lockedBranch
                        'rev-parse-exit'       = 128
                    }
                    "$prunablePath" = @{
                        'branch--show-current' = $prunableBranch
                        'rev-parse-exit'       = 128
                    }
                    "$barePath" = @{
                        'branch--show-current' = $bareBranch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($lockedBranch))
            $context | Should -Match ([regex]::Escape($prunableBranch))
            $context | Should -Match 'locked'
            $context | Should -Match 'checked out by maintainer'
            $insideFence | Should -Match ([regex]::Escape("git worktree remove --force '$lockedPath'"))
            $insideFence | Should -Match ([regex]::Escape("git branch -D '$lockedBranch'"))
            $insideFence | Should -Match ([regex]::Escape("git worktree remove '$prunablePath'"))
            $insideFence | Should -Not -Match ([regex]::Escape("git worktree remove --force '$prunablePath'"))
            $insideFence | Should -Match ([regex]::Escape("git branch -D '$prunableBranch'"))
            $context | Should -Not -Match ([regex]::Escape($bareBranch))
            $context | Should -Not -Match ([regex]::Escape($detachedPath))
        }

        It 'T10 D8 normalizes slash direction and drive-letter case so the current worktree record is not duplicated as a sibling' {
            $workDir = Join-Path $TestDrive 'sibling-normalized-current'
            $siblingDir = Join-Path $TestDrive 'sibling-normalized-other'
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            if ($currentPath -match '^([A-Za-z]):/(.*)$') {
                $drive = if ($Matches[1] -ceq $Matches[1].ToUpperInvariant()) { $Matches[1].ToLowerInvariant() } else { $Matches[1].ToUpperInvariant() }
                $currentRecordPath = '{0}:\{1}' -f $drive, ($Matches[2] -replace '/', '\')
            }
            else {
                $currentRecordPath = $currentPath -replace '/', '\'
            }
            $currentBranch = 'claude/current-normalized-abcde'
            $siblingBranch = 'claude/sibling-normalized-abcde'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentRecordPath -Branch $currentBranch),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $siblingBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                 = $currentBranch
                'symbolic-ref-origin-HEAD'             = 'refs/remotes/origin/main'
                'rev-parse-exit'                       = 128
                'worktree-list-porcelain'              = $worktreeList
                'show-ref-refs/remotes/origin/main'    = 0
                'fetch-exit'                           = 0
                "merge-base-$currentBranch-refs/remotes/origin/main" = 0
                "merge-base-$siblingBranch-refs/remotes/origin/main" = 0
                'path-configs'                         = @{
                    "$siblingPath" = @{
                        'branch--show-current' = $siblingBranch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $insideFence | Should -Match ([regex]::Escape("git worktree remove '$siblingPath'"))
            $insideFence | Should -Match ([regex]::Escape("git branch -D '$siblingBranch'"))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$currentBranch'"))
        }

        It 'T13 AC11 surfaces a sibling feature issue branch whose upstream remote branch is gone while the current worktree remains active' {
            $workDir = Join-Path $TestDrive 'sibling-upstream-deleted-current'
            $siblingDir = Join-Path $TestDrive 'sibling-upstream-deleted-other'
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            $currentBranch = 'claude/current-active-abcde'
            $siblingBranch = 'feature/issue-333-remote-deleted'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $currentBranch),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $siblingBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                 = $currentBranch
                'symbolic-ref-origin-HEAD'             = 'refs/remotes/origin/main'
                'rev-parse-exit'                       = 128
                'worktree-list-porcelain'              = $worktreeList
                'show-ref-refs/remotes/origin/main'    = 0
                'fetch-exit'                           = 0
                "merge-base-$currentBranch-refs/remotes/origin/main" = 1
                "ls-remote-$siblingBranch"             = ''
                'path-configs'                         = @{
                    "$siblingPath" = @{
                        'branch--show-current'                 = $siblingBranch
                        'rev-parse-exit'                       = 0
                        'rev-parse-upstream'                   = "origin/$siblingBranch"
                        "config-branch.$siblingBranch.remote" = 'origin'
                        "config-branch.$siblingBranch.merge"  = "refs/heads/$siblingBranch"
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($siblingBranch))
            $context | Should -Not -Match ([regex]::Escape($currentBranch))
            $insideFence | Should -Match ([regex]::Escape("git worktree remove '$siblingPath'"))
            $insideFence | Should -Match ([regex]::Escape("git branch -D '$siblingBranch'"))
        }
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
