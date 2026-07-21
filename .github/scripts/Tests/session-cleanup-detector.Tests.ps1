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
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector.ps1'
        $script:LibFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1'
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
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector.ps1'
        . (Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1')

        $script:CopilotBaselineFixturePath = Join-Path $PSScriptRoot 'fixtures/copilot-baseline-additional-context.txt'
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

if ($a.Count -ge 2 -and $a[0] -eq 'for-each-ref') {
    $refPrefix = $a[-1]
    $exitValue = Get-MockConfigValue "for-each-ref-exit-$refPrefix"
    if ($null -eq $exitValue) { $exitValue = Get-MockConfigValue 'for-each-ref-exit' }
    if ($null -eq $exitValue) { $exitValue = 0 }

    $exactKey = "for-each-ref-$refPrefix"
    $exactValue = Get-MockConfigValue $exactKey
    if ($null -ne $exactValue) {
        Write-Output $exactValue
        exit ([int]$exitValue)
    }

    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -like 'for-each-ref-*' -and $prop.Name -notlike 'for-each-ref-exit*') {
            $keyPattern = $prop.Name.Substring('for-each-ref-'.Length)
            if ($refPrefix -like $keyPattern) {
                Write-Output $prop.Value
                exit ([int]$exitValue)
            }
        }
    }

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

if ($a.Count -ge 4 -and $a[0] -eq 'ls-remote' -and $a[1] -eq '--heads') {
    if ((Get-MockConfigValue 'log-ls-remote-env') -eq $true) {
        "ls-remote-env`t$env:GIT_TERMINAL_PROMPT`t$env:GCM_INTERACTIVE`t$env:GIT_ASKPASS" | Add-Content -Path $callLogPath -Encoding UTF8
    }

    if ((Get-MockConfigValue 'ls-remote-mode') -eq 'timeout') {
        exit 124
    }

    $pattern = $a[3]
    $exitValue = Get-MockConfigValue "ls-remote-exit-$pattern"
    if ($null -eq $exitValue) { $exitValue = Get-MockConfigValue 'ls-remote-default-exit' }
    if ($null -eq $exitValue) { $exitValue = 0 }

    $exactKey = "ls-remote-$pattern"
    $exactValue = Get-MockConfigValue $exactKey
    if ($null -ne $exactValue) { Write-Output $exactValue; exit ([int]$exitValue) }
    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -like 'ls-remote-*' -and $prop.Name -notlike 'ls-remote-exit-*') {
            $keyPattern = $prop.Name.Substring('ls-remote-'.Length)
            if ($pattern -like $keyPattern) {
                Write-Output $prop.Value
                exit ([int]$exitValue)
            }
        }
    }
    if ($null -ne $config.'ls-remote-default') { Write-Output $config.'ls-remote-default' }
    exit ([int]$exitValue)
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

if ($a.Count -ge 3 -and $a[0] -eq 'rev-list' -and $a[-1] -eq '--count') {
    # git rev-list <range> --count (Issue #889 s4 eligibility-primitive rung 1).
    # DEFAULT (unconfigured) is "1" — deliberately the OPPOSITE default from the
    # s1 primitive's own dedicated mock (session-startup-git-helpers.Tests.ps1,
    # which defaults to 0) — routing pre-existing fixtures here (whose branch
    # names mostly do not match the real issue-id derivation regex) through the
    # primitive's rung-2 tree-equivalence check instead of rung-3 issue/PR
    # derivation, so this file's large pre-#889 fixture set stays green without
    # per-test gh mocking. Tests exercising rung 3 explicitly set
    # "rev-list-count-<range>" = 0.
    $range = $a[1]
    $exitValue = Get-MockConfigValue "rev-list-exit-$range"
    if ($null -eq $exitValue) { $exitValue = 0 }
    $val = Get-MockConfigValue "rev-list-count-$range"
    if ($null -eq $val) { $val = 1 }
    if ([int]$exitValue -eq 0) { Write-Output "$val" }
    exit ([int]$exitValue)
}

if ($a.Count -ge 4 -and $a[0] -eq 'diff' -and $a[1] -eq '--quiet') {
    # git diff --quiet [--ignore-cr-at-eol] <baseRef> <branch> (rung 2 primary check).
    # DEFAULT (unconfigured) exit 0 = tree-equivalent, for the same backward-
    # compatibility reason as the rev-list-count default above.
    $argIndex = 2
    if ($a[$argIndex] -eq '--ignore-cr-at-eol') { $argIndex++ }
    $targetBranch = if ($argIndex + 1 -lt $a.Count) { $a[$argIndex + 1] } else { '' }
    $exitValue = Get-MockConfigValue "diff-quiet-exit-$targetBranch"
    if ($null -eq $exitValue) { $exitValue = 0 }
    exit ([int]$exitValue)
}

if ($a.Count -ge 5 -and $a[0] -eq 'log' -and $a[1] -eq '--no-merges' -and $a[2] -eq '--pretty=format:' -and $a[3] -eq '--name-only') {
    # git log --no-merges --pretty=format: --name-only <range> (Issue #889 fix
    # cycle, finding C — Test-SCDUniqueCommitsAllEmpty). DEFAULT (unconfigured) is
    # a placeholder touched path, for the same backward-compatibility reason as
    # the rev-list-count/diff-quiet-exit defaults above.
    $range = $a[4]
    $val = Get-MockConfigValue "log-name-only-$range"
    if ($null -eq $val) { $val = 'placeholder-touched-file.txt' }
    if ($val -ne '') { Write-Output $val }
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

        # ---------------------------------------------------------------------------
        # Mock gh factory (Issue #889 s4, M15) — writes a gh.ps1 shim + gh.cmd wrapper
        # to the same mock dir as the git mock, mirroring the pattern already shipped
        # in session-startup-git-helpers.Tests.ps1 for the s1 eligibility primitive.
        # Only layered onto PATH when a test explicitly passes -GhConfig — most
        # fixtures never reach gh at all (they resolve at rung-2 tree-equivalence via
        # the git mock's rev-list/diff defaults above), so this stays opt-in.
        # ---------------------------------------------------------------------------
        $script:AddMockGh = {
            param(
                [string]$MockDir,
                [hashtable]$GhConfig
            )

            $GhConfig | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $MockDir 'gh-mock-config.json') -Encoding UTF8

            $ghMockPs1 = @'
param()
$configPath = Join-Path $PSScriptRoot 'gh-mock-config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$a = $args
$callLogPath = Join-Path $PSScriptRoot 'gh-mock-calls.log'
($a -join "`t") | Add-Content -Path $callLogPath -Encoding UTF8

function Get-GhConfigValue {
    param([string]$Name)
    $prop = $config.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

# gh pr list --head <branch> --base <default> --state merged --json number,headRefOid
if ($a.Count -ge 2 -and $a[0] -eq 'pr' -and $a[1] -eq 'list') {
    $headIdx = [Array]::IndexOf([string[]]$a, '--head')
    $branch = if ($headIdx -ge 0 -and $headIdx + 1 -lt $a.Count) { $a[$headIdx + 1] } else { '' }
    $key = "pr-list-merged-$branch"
    $val = Get-GhConfigValue $key
    if ($null -ne $val) { Write-Output $val }
    exit 0
}

# gh issue view <id> --repo <owner/repo> --json state
if ($a.Count -ge 2 -and $a[0] -eq 'issue' -and $a[1] -eq 'view') {
    $issueId = $a[2]
    $key = "issue-view-$issueId"
    $val = Get-GhConfigValue $key
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 1
}

exit 0
'@
            Set-Content -Path (Join-Path $MockDir 'gh-mock.ps1') -Value $ghMockPs1 -Encoding UTF8

            $ghPs1Shim = @'
#!/usr/bin/env pwsh
& (Join-Path $PSScriptRoot 'gh-mock.ps1') @args
exit $LASTEXITCODE
'@
            Set-Content -Path (Join-Path $MockDir 'gh.ps1') -Value $ghPs1Shim -Encoding UTF8

            $ghCmdContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0gh-mock.ps1`" %*`r`nexit %ERRORLEVEL%"
            Set-Content -Path (Join-Path $MockDir 'gh.cmd') -Value $ghCmdContent -Encoding ASCII
        }

        # In-process helper: injects git mock via PATH, changes CWD, calls library directly.
        # Note: git mock .cmd wrappers internally spawn child pwsh processes — this is a known
        # residual limitation of the git mock infrastructure and cannot be eliminated here.
        $script:InvokeDetectorInWorkDir = {
            param(
                [string]$WorkDir,
                [hashtable]$GitConfig,
                [string]$RepoRoot = $script:RepoRoot,
                [switch]$IncludeGitCalls,
                [hashtable]$GhConfig = $null,
                [switch]$IncludeGhCalls
            )

            $mockDir = & $script:NewMockGitDir -ParentDir $WorkDir -Config $GitConfig
            if ($null -ne $GhConfig) {
                & $script:AddMockGh -MockDir $mockDir -GhConfig $GhConfig
            }
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
                    if ($IncludeGhCalls) {
                        $ghCallLogPath = Join-Path $mockDir 'gh-mock-calls.log'
                        $result['GhCalls'] = if (Test-Path $ghCallLogPath) {
                            @(Get-Content -Path $ghCallLogPath -ErrorAction SilentlyContinue)
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

    It 'T8 AC6 AC9 returns a no-op on the default branch with no candidates and does not fetch' {
        $workDir = Join-Path $TestDrive 'default-branch-clean'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -IncludeGitCalls -GitConfig @{
            'branch--show-current'     = 'main'
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
            'fetch-exit'               = 99
        }
        $fetchCalls = @($result['GitCalls'] | Where-Object { $_ -match '^fetch(\t|$)' })

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match '^\{\s*\}$'
        $fetchCalls.Count | Should -Be 0 -Because 'Phase B fetch should be skipped when there are no current, sibling, orphan, or tracking candidates'
    }

    It 'T6 AC7 preserves the current-branch Copilot stale cleanup output byte for byte' {
        $workDir = Join-Path $TestDrive 'copilot-current-branch-baseline'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -RepoRoot 'C:/agent-orchestra' -GitConfig @{
            'branch--show-current'                                   = 'feature/issue-452-cleanup-detector-worktrees'
            'symbolic-ref-origin-HEAD'                               = 'refs/remotes/origin/main'
            'rev-parse-exit'                                         = 0
            'rev-parse-upstream'                                     = 'origin/feature/issue-452-cleanup-detector-worktrees'
            'ls-remote-feature/issue-452-cleanup-detector-worktrees' = ''
        }
        $context = & $script:GetAdditionalContext -Output $result.Output
        $expectedBytes = [System.IO.File]::ReadAllBytes($script:CopilotBaselineFixturePath)
        $expectedHex = [System.Convert]::ToHexString($expectedBytes)
        $actualHex = & $script:GetUtf8Hex -Text $context

        $result.ExitCode | Should -Be 0
        $actualHex | Should -BeExactly $expectedHex `
            -Because 'the current-branch Copilot cleanup message is a compatibility contract for SessionStart additionalContext'
    }

    It 'F2 fails open and uses noninteractive environment for timeout-sentinel remote-head checks' {
        $workDir = Join-Path $TestDrive 'remote-head-timeout-sentinel'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $branch = 'feature/issue-452-remote-timeout'

        $savedGitTerminalPrompt = $env:GIT_TERMINAL_PROMPT
        $savedGcmInteractive = $env:GCM_INTERACTIVE
        $savedGitAskPass = $env:GIT_ASKPASS
        try {
            $env:GIT_TERMINAL_PROMPT = 'interactive'
            $env:GCM_INTERACTIVE = 'Always'
            $env:GIT_ASKPASS = 'askpass-tool'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -IncludeGitCalls -GitConfig @{
                'branch--show-current'     = $branch
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'rev-parse-exit'           = 0
                'rev-parse-upstream'       = "origin/$branch"
                'log-ls-remote-env'        = $true
                'ls-remote-mode'           = 'timeout'
            }
        }
        finally {
            $env:GIT_TERMINAL_PROMPT = $savedGitTerminalPrompt
            $env:GCM_INTERACTIVE = $savedGcmInteractive
            $env:GIT_ASKPASS = $savedGitAskPass
        }
        $lsRemoteEnvCalls = @($result['GitCalls'] | Where-Object { $_ -match '^ls-remote-env\t' })

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match '^\{\s*\}$'
        $lsRemoteEnvCalls | Should -Contain "ls-remote-env`t0`tNever`techo" `
            -Because 'remote-head probes must not inherit interactive credential prompting settings'
    }

    Context 'current no-upstream Claude worktree detection' {
        It 'T2 AC1 AC8 surfaces a merged current claude worktree with inline cleanup outside the fenced block' {
            $workDir = Join-Path $TestDrive 'current-claude-merged'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/widget-fixer-abcde'
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $primaryPath = & $script:ToPorcelainPath -Path (Join-Path $TestDrive 'current-claude-merged-primary')
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $primaryPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $branch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -RepoRoot 'C:/agent-orchestra' -GitConfig @{
                'branch--show-current'              = $branch
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'rev-parse-exit'                    = 128
                'worktree-list-porcelain'           = $worktreeList
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                         = 0
                'merge-base-exit'                    = 0
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
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $primaryPath = & $script:ToPorcelainPath -Path (Join-Path $TestDrive 'current-claude-upstream-default-remote-primary')
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $primaryPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $branch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -RepoRoot 'C:/agent-orchestra' -IncludeGitCalls -GitConfig @{
                'branch--show-current'                          = $branch
                'symbolic-ref-HEAD'                             = 'refs/heads/main'
                'rev-parse-exit'                                = 128
                'worktree-list-porcelain'                       = $worktreeList
                'config-branch.main.remote'                     = 'upstream'
                'show-ref-refs/remotes/origin/main'             = 1
                'show-ref-refs/remotes/origin/master'           = 1
                'show-ref-refs/remotes/upstream/main'           = 0
                'fetch-exit'                                    = 0
                "merge-base-$branch-refs/remotes/upstream/main" = 0
                "merge-base-$branch-refs/remotes/origin/main"   = 1
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $mergeBaseCalls = @($result['GitCalls'] | Where-Object { $_ -match '^merge-base\t--is-ancestor\t' })

            $result.ExitCode | Should -Be 0
            $context | Should -Match 'Post-merge cleanup detected'
            $context | Should -Match ([regex]::Escape($branch))
            # Issue #889 s4 (D6): the rendered evidence text now comes from the shared
            # eligibility primitive, not the site-level ancestry ref used only to decide
            # whether to flag the candidate — so the primitive's own remote-default
            # resolution (which does not see this test's upstream-remote config) is not
            # asserted here. The upstream-vs-origin derivation this test targets is fully
            # covered by the $mergeBaseCalls assertions below.
            $result['GitCalls'] | Should -Contain "config`t--get`tbranch.main.remote"
            $result['GitCalls'] | Should -Contain "show-ref`t--verify`t--quiet`trefs/remotes/upstream/main"
            $mergeBaseCalls | Should -Contain "merge-base`t--is-ancestor`t$branch`trefs/remotes/upstream/main"
            $mergeBaseCalls | Should -Not -Contain "merge-base`t--is-ancestor`t$branch`trefs/remotes/origin/main"
        }

        It 'T3 AC3 leaves an unmerged current no-upstream claude worktree unflagged' {
            $workDir = Join-Path $TestDrive 'current-claude-unmerged'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'              = 'claude/in-flight-zyxwv'
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'rev-parse-exit'                    = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                'merge-base-exit'                   = 1
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
                'branch--show-current'              = 'claude/merge-base-error-abcde'
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'rev-parse-exit'                    = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                'merge-base-exit'                   = 2
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$'
        }

        It 'T4 AC4 uses local refs and does not throw when fetch fails for a merged current claude candidate' {
            $workDir = Join-Path $TestDrive 'current-claude-fetch-failure'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/fetch-failure-abcde'
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $primaryPath = & $script:ToPorcelainPath -Path (Join-Path $TestDrive 'current-claude-fetch-failure-primary')
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $primaryPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $branch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'              = $branch
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'rev-parse-exit'                    = 128
                'worktree-list-porcelain'           = $worktreeList
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 128
                'merge-base-exit'                   = 0
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
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $primaryPath = & $script:ToPorcelainPath -Path (Join-Path $TestDrive 'current-claude-fetch-timeout-primary')
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $primaryPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $branch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'              = $branch
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'rev-parse-exit'                    = 128
                'worktree-list-porcelain'           = $worktreeList
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-mode'                        = 'timeout'
                'merge-base-exit'                   = 0
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
                'branch--show-current'              = 'scratch/local-only'
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'rev-parse-exit'                    = 128
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 99
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
                'branch--show-current'                        = 'main'
                'symbolic-ref-origin-HEAD'                    = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                     = $worktreeList
                'show-ref-refs/remotes/origin/main'           = 0
                'fetch-exit'                                  = 0
                "merge-base-$branch-refs/remotes/origin/main" = 0
                'path-configs'                                = @{
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
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape("-SiblingWorktrees @('$siblingPath')")) -Because 'sibling worktree path must appear as -SiblingWorktrees argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for sibling category'
        }

        It 'F2 fetches the remote default once while evaluating multiple sibling no-upstream candidates' {
            $workDir = Join-Path $TestDrive 'sibling-claude-fetch-once-current'
            $firstSiblingDir = Join-Path $TestDrive 'sibling-claude-fetch-once-first'
            $secondSiblingDir = Join-Path $TestDrive 'sibling-claude-fetch-once-second'
            New-Item -ItemType Directory -Path $workDir, $firstSiblingDir, $secondSiblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $firstSiblingPath = & $script:ToPorcelainPath -Path $firstSiblingDir
            $secondSiblingPath = & $script:ToPorcelainPath -Path $secondSiblingDir
            $firstBranch = 'claude/fetch-once-first-abcde'
            $secondBranch = 'claude/fetch-once-second-abcde'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $firstSiblingPath -Branch $firstBranch),
                (& $script:NewWorktreeRecord -Path $secondSiblingPath -Branch $secondBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -IncludeGitCalls -GitConfig @{
                'branch--show-current'                              = 'main'
                'symbolic-ref-origin-HEAD'                          = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                           = $worktreeList
                'show-ref-refs/remotes/origin/main'                 = 0
                'fetch-exit'                                        = 0
                "merge-base-$firstBranch-refs/remotes/origin/main"  = 0
                "merge-base-$secondBranch-refs/remotes/origin/main" = 0
                'path-configs'                                      = @{
                    "$firstSiblingPath"  = @{
                        'branch--show-current' = $firstBranch
                        'rev-parse-exit'       = 128
                    }
                    "$secondSiblingPath" = @{
                        'branch--show-current' = $secondBranch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $fetchCalls = @($result['GitCalls'] | Where-Object { $_ -match '^fetch(\t|$)' })

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($firstBranch))
            $context | Should -Match ([regex]::Escape($secondBranch))
            $fetchCalls.Count | Should -Be 1 -Because 'one remote/default refresh is enough for all sibling no-upstream candidates in the run'
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
                'branch--show-current'                        = 'main'
                'symbolic-ref-origin-HEAD'                    = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                     = $worktreeList
                'show-ref-refs/remotes/origin/main'           = 0
                'fetch-exit'                                  = 0
                "merge-base-$branch-refs/remotes/origin/main" = 1
                'path-configs'                                = @{
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
            $primaryPath = & $script:ToPorcelainPath -Path (Join-Path $TestDrive 'sibling-placement-primary')
            $currentBranch = 'claude/current-merged-abcde'
            $siblingBranch = 'claude/sibling-merged-abcde'
            # Issue #889 s4: primary (first record) must be a DISTINCT path from the
            # current session worktree — Test-WorktreeIsPrimary treats the first
            # `git worktree list --porcelain` record as primary, and the primary
            # checkout can never be a `git worktree remove` target.
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $primaryPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $currentBranch),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $siblingBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                               = $currentBranch
                'symbolic-ref-origin-HEAD'                           = 'refs/remotes/origin/main'
                'rev-parse-exit'                                     = 128
                'worktree-list-porcelain'                            = $worktreeList
                'show-ref-refs/remotes/origin/main'                  = 0
                'fetch-exit'                                         = 0
                "merge-base-$currentBranch-refs/remotes/origin/main" = 0
                "merge-base-$siblingBranch-refs/remotes/origin/main" = 0
                'path-configs'                                       = @{
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
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape("-SiblingWorktrees @('$siblingPath')")) -Because 'sibling worktree path must appear as -SiblingWorktrees argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for sibling category'
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
                'branch--show-current'              = 'main'
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'worktree-list-porcelain'           = $worktreeList
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                'merge-base-exit'                   = 0
                'path-configs'                      = @{
                    "$lockedPath"   = @{
                        'branch--show-current' = $lockedBranch
                        'rev-parse-exit'       = 128
                    }
                    "$prunablePath" = @{
                        'branch--show-current' = $prunableBranch
                        'rev-parse-exit'       = 128
                    }
                    "$barePath"     = @{
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
            # After composite migration: locked vs prunable distinction moves into the script;
            # fenced block contains a single composite -SiblingWorktrees invocation instead of
            # individual git worktree remove + git branch -D lines.
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape($lockedPath)) -Because 'locked worktree path must appear in -SiblingWorktrees list'
            $insideFence | Should -Match ([regex]::Escape($prunablePath)) -Because 'prunable worktree path must appear in -SiblingWorktrees list'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for sibling category'
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
                'branch--show-current'                               = $currentBranch
                'symbolic-ref-origin-HEAD'                           = 'refs/remotes/origin/main'
                'rev-parse-exit'                                     = 128
                'worktree-list-porcelain'                            = $worktreeList
                'show-ref-refs/remotes/origin/main'                  = 0
                'fetch-exit'                                         = 0
                "merge-base-$currentBranch-refs/remotes/origin/main" = 0
                "merge-base-$siblingBranch-refs/remotes/origin/main" = 0
                'path-configs'                                       = @{
                    "$siblingPath" = @{
                        'branch--show-current' = $siblingBranch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape($siblingPath)) -Because 'sibling path must appear in -SiblingWorktrees argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for sibling category'
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
                'branch--show-current'                               = $currentBranch
                'symbolic-ref-origin-HEAD'                           = 'refs/remotes/origin/main'
                'rev-parse-exit'                                     = 128
                'worktree-list-porcelain'                            = $worktreeList
                'show-ref-refs/remotes/origin/main'                  = 0
                'fetch-exit'                                         = 0
                "merge-base-$currentBranch-refs/remotes/origin/main" = 1
                "ls-remote-$siblingBranch"                           = ''
                'path-configs'                                       = @{
                    "$siblingPath" = @{
                        'branch--show-current'                = $siblingBranch
                        'rev-parse-exit'                      = 0
                        'rev-parse-upstream'                  = "origin/$siblingBranch"
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
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape($siblingPath)) -Because 'sibling path must appear in -SiblingWorktrees argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for sibling category'
        }

        It 'F1 ignores non-issue upstream-deleted sibling branches while preserving feature issue positives' {
            $workDir = Join-Path $TestDrive 'sibling-upstream-scope-current'
            $featureDir = Join-Path $TestDrive 'sibling-upstream-scope-feature'
            $releaseDir = Join-Path $TestDrive 'sibling-upstream-scope-release'
            New-Item -ItemType Directory -Path $workDir, $featureDir, $releaseDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $featurePath = & $script:ToPorcelainPath -Path $featureDir
            $releasePath = & $script:ToPorcelainPath -Path $releaseDir
            $featureBranch = 'feature/issue-452-sibling-upstream-deleted'
            $releaseBranch = 'release/2026-04-cleanup'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $featurePath -Branch $featureBranch),
                (& $script:NewWorktreeRecord -Path $releasePath -Branch $releaseBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -IncludeGitCalls -GitConfig @{
                'branch--show-current'     = 'main'
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'worktree-list-porcelain'  = $worktreeList
                "ls-remote-$featureBranch" = ''
                "ls-remote-$releaseBranch" = ''
                'path-configs'             = @{
                    "$featurePath" = @{
                        'branch--show-current' = $featureBranch
                        'rev-parse-exit'       = 0
                        'rev-parse-upstream'   = "origin/$featureBranch"
                    }
                    "$releasePath" = @{
                        'branch--show-current' = $releaseBranch
                        'rev-parse-exit'       = 0
                        'rev-parse-upstream'   = "origin/$releaseBranch"
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"
            $releaseRemoteCalls = @($result['GitCalls'] | Where-Object { $_ -eq "ls-remote`t--heads`torigin`t$releaseBranch" })

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($featureBranch))
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape($featurePath)) -Because 'feature worktree path must appear in -SiblingWorktrees argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for sibling category'
            $context | Should -Not -Match ([regex]::Escape($releaseBranch))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$releaseBranch'"))
            $releaseRemoteCalls.Count | Should -Be 0 -Because 'remote-deleted sibling cleanup is documented as feature/issue-* scoped'
        }

        It 'F3 reports a prunable missing-path feature issue sibling from main-repo branch config' {
            $workDir = Join-Path $TestDrive 'sibling-prunable-missing-current'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $missingPath = & $script:ToPorcelainPath -Path (Join-Path $TestDrive 'sibling-prunable-missing-other')
            $branch = 'feature/issue-452-prunable-upstream-deleted'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $missingPath -Branch $branch -States @('prunable gitdir file points to missing checkout'))
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'         = 'main'
                'symbolic-ref-origin-HEAD'     = 'refs/remotes/origin/main'
                'worktree-list-porcelain'      = $worktreeList
                "config-branch.$branch.remote" = 'origin'
                "config-branch.$branch.merge"  = "refs/heads/$branch"
                "ls-remote-$branch"            = ''
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match 'prunable'
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape($missingPath)) -Because 'prunable path must appear in -SiblingWorktrees argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for sibling category'
        }
    }

    Context 'orphan branch cleanup detection' {
        It 'T7 AC5 flags a merged orphan claude branch, skips an unmerged orphan, and subtracts attached branches' {
            $workDir = Join-Path $TestDrive 'orphan-claude-sweep-current'
            $siblingDir = Join-Path $TestDrive 'orphan-claude-sweep-sibling'
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            $currentBranch = 'claude/current-attached-abcde'
            $attachedBranch = 'claude/sibling-attached-abcde'
            $mergedOrphan = 'claude/orphan-merged-abcde'
            $unmergedOrphan = 'claude/orphan-unmerged-abcde'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $currentBranch),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $attachedBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                                = $currentBranch
                'symbolic-ref-origin-HEAD'                            = 'refs/remotes/origin/main'
                'rev-parse-exit'                                      = 0
                'rev-parse-upstream'                                  = "origin/$currentBranch"
                "ls-remote-$currentBranch"                            = 'abc refs/heads/claude/current-attached-abcde'
                'worktree-list-porcelain'                             = $worktreeList
                'show-ref-refs/remotes/origin/main'                   = 0
                'fetch-exit'                                          = 0
                'for-each-ref-refs/heads/claude/'                     = @($currentBranch, $attachedBranch, $mergedOrphan, $unmergedOrphan)
                "merge-base-$mergedOrphan-refs/remotes/origin/main"   = 0
                "merge-base-$unmergedOrphan-refs/remotes/origin/main" = 1
                'path-configs'                                        = @{
                    "$siblingPath" = @{
                        'branch--show-current' = $attachedBranch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match 'Post-merge cleanup detected'
            $context | Should -Match ([regex]::Escape($mergedOrphan))
            # After composite migration: orphan branches appear as -OrphanBranches parameter
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape("-OrphanBranches @('$mergedOrphan')")) -Because 'merged orphan must appear in -OrphanBranches argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for orphan category'
            $context | Should -Not -Match ([regex]::Escape($unmergedOrphan))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$unmergedOrphan'"))
            $context | Should -Not -Match ([regex]::Escape($attachedBranch))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$attachedBranch'"))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$currentBranch'"))
        }

        It 'T6b AC7b preserves the Copilot stale branch bullet and appends claude orphan cleanup under one post-merge heading' {
            $workDir = Join-Path $TestDrive 'mixed-copilot-claude-orphan'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $copilotBranch = 'feature/issue-452-cleanup-detector-worktrees'
            $orphanBranch = 'claude/orphan-mixed-abcde'
            $baselineText = [System.IO.File]::ReadAllText($script:CopilotBaselineFixturePath)
            $expectedCopilotBullet = @($baselineText -split "`r?`n" | Where-Object { $_ -like '- Current branch *' } | Select-Object -First 1)[0]

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -RepoRoot 'C:/agent-orchestra' -GitConfig @{
                'branch--show-current'                              = $copilotBranch
                'symbolic-ref-origin-HEAD'                          = 'refs/remotes/origin/main'
                'rev-parse-exit'                                    = 0
                'rev-parse-upstream'                                = "origin/$copilotBranch"
                "ls-remote-$copilotBranch"                          = ''
                'worktree-list-porcelain'                           = (& $script:NewWorktreeRecord -Path (& $script:ToPorcelainPath -Path $workDir) -Branch $copilotBranch)
                'show-ref-refs/remotes/origin/main'                 = 0
                'fetch-exit'                                        = 0
                'for-each-ref-refs/heads/claude/'                   = @($orphanBranch)
                "merge-base-$orphanBranch-refs/remotes/origin/main" = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"
            $actualCopilotBullet = @($context -split "`r?`n" | Where-Object { $_ -like '- Current branch *' } | Select-Object -First 1)[0]
            $postMergeHeadingCount = ([regex]::Matches($context, '\*\*Post-merge cleanup detected\*\*')).Count

            $result.ExitCode | Should -Be 0
            (& $script:GetUtf8Hex -Text $actualCopilotBullet) | Should -BeExactly (& $script:GetUtf8Hex -Text $expectedCopilotBullet) `
                -Because 'the current-branch Copilot bullet text is byte-locked by the baseline fixture even in mixed output'
            $postMergeHeadingCount | Should -Be 1
            $context | Should -Match '^\*\*Post-merge cleanup detected\*\*'
            $context | Should -Not -Match '(?im)^\*\*Claude'
            $context | Should -Match ([regex]::Escape($orphanBranch))
            # After composite migration: orphan appears in -OrphanBranches parameter
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape($orphanBranch)) -Because 'orphan branch must appear in -OrphanBranches argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for orphan category'
        }

        It 'T12 D9 caps claude orphan output at 10 cleanup bullets and commands with a deterministic overflow hint' {
            $workDir = Join-Path $TestDrive 'orphan-claude-bounded'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branches = 1..12 | ForEach-Object { 'claude/reclaimable-{0:d2}-abcde' -f $_ }
            $gitConfig = @{
                'branch--show-current'              = 'main'
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'worktree-list-porcelain'           = (& $script:NewWorktreeRecord -Path (& $script:ToPorcelainPath -Path $workDir) -Branch 'main')
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                'for-each-ref-refs/heads/claude/'   = $branches
            }
            foreach ($branch in $branches) {
                $gitConfig["merge-base-$branch-refs/remotes/origin/main"] = 0
            }

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig $gitConfig
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"
            $concreteBulletCount = ([regex]::Matches($context, '(?m)^- .*claude/reclaimable-')).Count
            # After composite migration: orphan entries appear in a single -OrphanBranches @(...) invocation
            # Count entries in the -OrphanBranches array instead of individual git branch -D lines
            $concreteOrphanEntryCount = ([regex]::Matches($insideFence, "(?m)'claude/reclaimable-")).Count
            $overflowCommandPattern = [regex]::Escape("git for-each-ref --format='%(refname:short)' refs/heads/claude/")

            $result.ExitCode | Should -Be 0
            $concreteBulletCount | Should -Be 10
            $concreteOrphanEntryCount | Should -Be 10 -Because 'exactly 10 orphan branch entries must appear in the -OrphanBranches array'
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match '-OrphanBranches' -Because '-OrphanBranches parameter must appear in composite invocation'
            $context | Should -Match "\+2 more.*$overflowCommandPattern"
            $context | Should -Not -Match ([regex]::Escape($branches[10]))
            $context | Should -Not -Match ([regex]::Escape($branches[11]))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$($branches[10])'"))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$($branches[11])'"))
        }

        It 'T12 D9 counts a merged current claude worktree against the 10-item output cap before orphan deletes' {
            $workDir = Join-Path $TestDrive 'current-plus-orphan-claude-bounded'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $currentBranch = 'claude/current-overflow-abcde'
            $orphanBranches = 1..10 | ForEach-Object { 'claude/reclaimable-{0:d2}-abcde' -f $_ }
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $primaryPath = & $script:ToPorcelainPath -Path (Join-Path $TestDrive 'current-plus-orphan-claude-bounded-primary')
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $primaryPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $currentBranch)
            ) -join "`n`n"
            $gitConfig = @{
                'branch--show-current'              = $currentBranch
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'rev-parse-exit'                    = 128
                'worktree-list-porcelain'           = $worktreeList
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                'for-each-ref-refs/heads/claude/'   = @($currentBranch) + $orphanBranches
            }
            $gitConfig["merge-base-$currentBranch-refs/remotes/origin/main"] = 0
            foreach ($branch in $orphanBranches) {
                $gitConfig["merge-base-$branch-refs/remotes/origin/main"] = 0
            }

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig $gitConfig
            $context = & $script:GetAdditionalContext -Output $result.Output
            $outsideFence = & $script:RemoveFencedPowerShellBlocks -Context $context
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"
            $concreteClaudeBulletCount = ([regex]::Matches($context, '(?m)^- .*(?:claude/current-overflow-abcde|claude/reclaimable-)')).Count
            $visibleOrphanBulletCount = ([regex]::Matches($context, '(?m)^- .*claude/reclaimable-')).Count
            # After composite migration: count orphan entries in -OrphanBranches array instead of git branch -D lines
            $visibleOrphanEntryCount = ([regex]::Matches($insideFence, "(?m)'claude/reclaimable-")).Count
            $overflowCommandPattern = [regex]::Escape("git for-each-ref --format='%(refname:short)' refs/heads/claude/")

            $result.ExitCode | Should -Be 0
            $outsideFence | Should -Match ([regex]::Escape($currentBranch))
            $outsideFence | Should -Match '(?s)Current-worktree cleanup must be run from another checkout:.*git worktree remove.*git branch -D'
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$currentBranch'"))
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match '-OrphanBranches' -Because '-OrphanBranches parameter must appear in composite invocation'
            $concreteClaudeBulletCount | Should -Be 10
            $visibleOrphanBulletCount | Should -Be 9
            $visibleOrphanEntryCount | Should -Be 9 -Because 'exactly 9 orphan entries must appear in the -OrphanBranches array'
            $context | Should -Match "\+1 more.*$overflowCommandPattern"
            $context | Should -Not -Match ([regex]::Escape($orphanBranches[9]))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$($orphanBranches[9])'"))
        }

        It 'T14 AC12 emits branch deletion for an orphan feature issue branch whose upstream branch is gone' {
            $workDir = Join-Path $TestDrive 'orphan-feature-upstream-deleted'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'feature/issue-452-orphan-upstream-deleted'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                    = 'main'
                'symbolic-ref-origin-HEAD'                = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                 = (& $script:NewWorktreeRecord -Path (& $script:ToPorcelainPath -Path $workDir) -Branch 'main')
                'fetch-exit'                              = 0
                'for-each-ref-refs/heads/feature/issue-*' = @($branch)
                'for-each-ref-refs/heads/feature/'        = @($branch)
                'for-each-ref-refs/heads/'                = @($branch)
                "config-branch.$branch.remote"            = 'origin'
                "config-branch.$branch.merge"             = "refs/heads/$branch"
                "ls-remote-$branch"                       = ''
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape($branch)) -Because 'orphan feature branch must appear in -OrphanBranches argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for orphan category'
        }

        It 'F1 ignores orphan upstream-deleted branches outside feature issue scope while preserving feature issue positives' {
            $workDir = Join-Path $TestDrive 'orphan-upstream-scope'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $featureBranch = 'feature/issue-452-orphan-upstream-deleted'
            $scratchBranch = 'scratch/orphan-upstream-deleted'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -IncludeGitCalls -GitConfig @{
                'branch--show-current'                = 'main'
                'symbolic-ref-origin-HEAD'            = 'refs/remotes/origin/main'
                'worktree-list-porcelain'             = (& $script:NewWorktreeRecord -Path (& $script:ToPorcelainPath -Path $workDir) -Branch 'main')
                'for-each-ref-refs/heads/'            = @($featureBranch, $scratchBranch)
                "config-branch.$featureBranch.remote" = 'origin'
                "config-branch.$featureBranch.merge"  = "refs/heads/$featureBranch"
                "config-branch.$scratchBranch.remote" = 'origin'
                "config-branch.$scratchBranch.merge"  = "refs/heads/$scratchBranch"
                "ls-remote-$featureBranch"            = ''
                "ls-remote-$scratchBranch"            = ''
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"
            $scratchRemoteCalls = @($result['GitCalls'] | Where-Object { $_ -eq "ls-remote`t--heads`torigin`t$scratchBranch" })

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($featureBranch))
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
            $insideFence | Should -Match ([regex]::Escape($featureBranch)) -Because 'feature orphan branch must appear in -OrphanBranches argument'
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'raw git branch -D must not appear in fenced block for orphan category'
            $context | Should -Not -Match ([regex]::Escape($scratchBranch))
            $insideFence | Should -Not -Match ([regex]::Escape("git branch -D '$scratchBranch'"))
            $scratchRemoteCalls.Count | Should -Be 0 -Because 'remote-deleted orphan cleanup is documented as feature/issue-* scoped'
        }

        It 'composite: fenced block contains no raw git branch -D lines when orphan category fires' {
            $workDir = Join-Path $TestDrive 'orphan-no-raw-branch-d'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $mergedOrphan = 'claude/orphan-composite-abcde'
            $unmergedOrphan = 'claude/orphan-unmerged-composite-abcde'
            $worktreeList = & $script:NewWorktreeRecord -Path (& $script:ToPorcelainPath -Path $workDir) -Branch 'main'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                                 = 'main'
                'symbolic-ref-origin-HEAD'                             = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                              = $worktreeList
                'show-ref-refs/remotes/origin/main'                    = 0
                'fetch-exit'                                           = 0
                'for-each-ref-refs/heads/claude/'                      = @($mergedOrphan, $unmergedOrphan)
                "merge-base-$mergedOrphan-refs/remotes/origin/main"    = 0
                "merge-base-$unmergedOrphan-refs/remotes/origin/main"  = 1
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $insideFence | Should -Not -Match 'git branch -D ' -Because 'composite: no raw git branch -D must appear in fenced block for orphan category'
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
        }

        It 'composite: unknown-issue-id tracking file becomes -UntaggedTrackingFiles parameter not a comment line' {
            $workDir = Join-Path $TestDrive 'untagged-tracking-composite'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            # Create an untagged tracking file (no issue_id frontmatter)
            $trackingDir = Join-Path $workDir '.copilot-tracking/research'
            New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
            Set-Content -Path (Join-Path $trackingDir 'orphan-no-id.md') -Value "# No issue_id header`nSome content" -Encoding UTF8

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'     = 'main'
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'worktree-list-porcelain'  = (& $script:NewWorktreeRecord -Path (& $script:ToPorcelainPath -Path $workDir) -Branch 'main')
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $insideFence | Should -Not -Match '# Unknown issue ID' -Because 'unknown-issue tracking files must not appear as comment lines in fenced block'
            $insideFence | Should -Match ([regex]::Escape('-UntaggedTrackingFiles')) -Because 'untagged files must appear as -UntaggedTrackingFiles parameter'
            $insideFence | Should -Match 'post-merge-cleanup\.ps1' -Because 'composite invocation must reference the cleanup script'
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

Describe 'Get-OrphanBranchLines — per-line suffix and composite invocation' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        . (Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1')
    }

    It 'appends "; eligible for auto-resolve at cleanup time" to feature/issue-N orphan lines' {
        $items = @(
            [pscustomobject]@{ BranchName = 'feature/issue-548-test'; Reason = 'remote branch deleted' }
        )
        $lines = @(Get-SCDOrphanBranchLines -Items $items)
        $lines[0] | Should -Match ([regex]::Escape('; eligible for auto-resolve at cleanup time')) `
            -Because 'feature/issue-N orphan lines must append the auto-resolve suffix'
    }

    It 'does not append suffix to claude/* orphan lines' {
        $items = @(
            [pscustomobject]@{ BranchName = 'claude/old-feature'; Reason = 'remote branch deleted' }
        )
        $lines = @(Get-SCDOrphanBranchLines -Items $items)
        $lines[0] | Should -Not -Match ([regex]::Escape('; eligible for auto-resolve at cleanup time')) `
            -Because 'claude/* orphan lines must not receive the auto-resolve suffix'
    }

    It 'handles mixed-list: feature/issue-N gets suffix, claude/* does not' {
        $items = @(
            [pscustomobject]@{ BranchName = 'feature/issue-548-mixed'; Reason = 'remote branch deleted' }
            [pscustomobject]@{ BranchName = 'claude/old-feature'; Reason = 'remote branch deleted' }
        )
        $lines = @(Get-SCDOrphanBranchLines -Items $items)
        $lines[0] | Should -Match ([regex]::Escape('; eligible for auto-resolve at cleanup time')) `
            -Because 'feature/issue-N item must have the suffix'
        $lines[1] | Should -Not -Match ([regex]::Escape('; eligible for auto-resolve at cleanup time')) `
            -Because 'claude/* item must not have the suffix'
    }

    It 'emits exactly one composite pwsh invocation with both -SiblingWorktrees and -OrphanBranches when both categories present' {
        $workDir = Join-Path $TestDrive 'composite-both-categories-current'
        $siblingDir = Join-Path $TestDrive 'composite-both-categories-sibling'
        New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
        $currentPath = & $script:ToPorcelainPath -Path $workDir
        $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
        $currentBranch = 'main'
        $siblingBranch = 'claude/sibling-composite-abcde'
        $orphanBranch = 'claude/orphan-composite-abcde'
        $worktreeList = @(
            (& $script:NewWorktreeRecord -Path $currentPath -Branch $currentBranch),
            (& $script:NewWorktreeRecord -Path $siblingPath -Branch $siblingBranch)
        ) -join "`n`n"

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'                               = $currentBranch
            'symbolic-ref-origin-HEAD'                           = 'refs/remotes/origin/main'
            'worktree-list-porcelain'                            = $worktreeList
            'show-ref-refs/remotes/origin/main'                  = 0
            'fetch-exit'                                         = 0
            "merge-base-$siblingBranch-refs/remotes/origin/main" = 0
            'for-each-ref-refs/heads/claude/'                    = @($siblingBranch, $orphanBranch)
            "merge-base-$orphanBranch-refs/remotes/origin/main"  = 0
            'path-configs'                                       = @{
                "$siblingPath" = @{
                    'branch--show-current' = $siblingBranch
                    'rev-parse-exit'       = 128
                }
            }
        }
        $context = & $script:GetAdditionalContext -Output $result.Output
        $fencedBlocks = & $script:GetFencedPowerShellBlocks -Context $context
        $cleanupLines = @($fencedBlocks | ForEach-Object { $_ -split "`n" } | Where-Object { $_ -match 'post-merge-cleanup\.ps1' })

        $result.ExitCode | Should -Be 0
        $cleanupLines.Count | Should -Be 1 `
            -Because 'exactly one composite post-merge-cleanup.ps1 line must appear in the fenced block'
        $cleanupLines[0] | Should -Match ([regex]::Escape('-SiblingWorktrees @(')) `
            -Because 'the composite invocation must include -SiblingWorktrees'
        $cleanupLines[0] | Should -Match ([regex]::Escape('-OrphanBranches @(')) `
            -Because 'the composite invocation must include -OrphanBranches'
    }
}

Describe 'session-cleanup-detector.ps1 — persistent root-level tracking file exclusion (#656)' {

    BeforeAll {
        # Load the core library so Invoke-SessionCleanupDetector and
        # Get-SCDPersistentTrackingExclusions are defined in this Describe scope.
        # The $script: helpers (InvokeDetectorInWorkDir, WriteFixtureFile, etc.) were
        # set during the calibration-exclusion Describe's BeforeAll and are reused here.
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        . (Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1')
    }

    It 'AC1: gate-events.jsonl at tracking root is excluded from cleanup detection' {
        $workDir = Join-Path $TestDrive 'persistent-gate-events'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\gate-events.jsonl' -Content '{"window_position":"pre-ask"}' | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'     = 'main'
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
        }

        $result.ExitCode | Should -Be 0
        $result.Output   | Should -Match '^\{\s*\}$' -Because 'gate-events.jsonl is a live persistent file and must not trigger cleanup'
    }

    It 'AC1: references-state.yml at tracking root is excluded from cleanup detection' {
        $workDir = Join-Path $TestDrive 'persistent-references-state'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\references-state.yml' -Content 'version: 1' | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'     = 'main'
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
        }

        $result.ExitCode | Should -Be 0
        $result.Output   | Should -Match '^\{\s*\}$' -Because 'references-state.yml is a live persistent file and must not trigger cleanup'
    }

    It 'AC1: references-init.manifest at tracking root is excluded from cleanup detection' {
        $workDir = Join-Path $TestDrive 'persistent-references-init-manifest'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\references-init.manifest' -Content '{}' | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'     = 'main'
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
        }

        $result.ExitCode | Should -Be 0
        $result.Output   | Should -Match '^\{\s*\}$' -Because 'references-init.manifest is a live persistent file and must not trigger cleanup'
    }

    It 'AC3: non-registry untagged root file is still flagged (positive companion)' {
        $workDir = Join-Path $TestDrive 'persistent-positive-companion'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\stale-notes.md' -Content '# no issue_id here' | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'     = 'main'
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
        }
        $context = & $script:GetAdditionalContext -Output $result.Output
        $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

        $result.ExitCode | Should -Be 0
        $insideFence     | Should -Match 'stale-notes' -Because 'untagged non-registry root file must still appear in cleanup recommendations'
    }

    It 'AC5: registry-named file at depth >= 1 is NOT excluded (over-exclusion guard)' {
        $workDir = Join-Path $TestDrive 'persistent-depth-check'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        & $script:WriteFixtureFile -WorkDir $workDir -RelativePath '.copilot-tracking\sub\gate-events.jsonl' -Content '{}' | Out-Null

        $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
            'branch--show-current'     = 'main'
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
        }
        $context = & $script:GetAdditionalContext -Output $result.Output
        $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

        $result.ExitCode | Should -Be 0
        $insideFence     | Should -Match 'gate-events' -Because 'a registry-named file in a subdirectory must NOT be excluded'
    }

    It 'AC6: undefined accessor causes detector to halt loudly instead of silently proceeding' {
        # Strategy: run the detector wrapper script in a fresh subprocess where the helpers file
        # has been temporarily replaced with an empty stub so Get-SCDPersistentTrackingExclusions
        # is never defined. Using a subprocess avoids mutating the in-process function provider.
        $workDir = Join-Path $TestDrive 'persistent-accessor-missing'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        # Write an empty helpers stub so the dot-source succeeds but the accessor is absent
        $helpersStubPath = Join-Path $TestDrive 'session-startup-git-helpers-stub.ps1'
        Set-Content -Path $helpersStubPath -Value '# stub — accessor intentionally omitted' -Encoding UTF8

        # Build a patched copy of the detector core that loads the stub instead of the real helpers
        $coreContent = Get-Content -Path (Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1') -Raw
        $patchedCore = $coreContent -replace [regex]::Escape('. "$PSScriptRoot/session-startup-git-helpers.ps1"'), ('. "' + ($helpersStubPath -replace '\\', '/') + '"')
        $patchedCorePath = Join-Path $TestDrive 'patched-detector-core.ps1'
        Set-Content -Path $patchedCorePath -Value $patchedCore -Encoding UTF8

        # Run a subprocess that dot-sources the patched core and calls Invoke-SessionCleanupDetector
        $escapedWorkDir = $workDir -replace "'", "''"
        $escapedCorePath = $patchedCorePath -replace "'", "''"
        $output = pwsh -NoProfile -NonInteractive -Command @"
. '$escapedCorePath'
`$r = Invoke-SessionCleanupDetector -RepoRoot '$escapedWorkDir'
Write-Output "EXIT:`$(`$r.ExitCode)"
Write-Output "OUT:`$(`$r.Output)"
"@ 2>&1
        $outputStr = ($output -join "`n")
        $exitCodeLine = $output | Where-Object { $_ -match '^EXIT:' } | Select-Object -First 1
        $detectorExitCode = if ($exitCodeLine -match '^EXIT:(\d+)') { [int]$Matches[1] } else { -1 }

        $detectorExitCode | Should -Be 1 -Because 'undefined accessor must cause a hard halt'
        $outputStr        | Should -Match 'HALT' -Because 'a loud HALT message must be emitted'
    }

    It 'AC7: writer-oracle — registry contains all known root-level persistent tracking writers' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        # Get the registered filenames from the accessor
        $exclusions = Get-SCDPersistentTrackingExclusions
        $registeredFilenames = @($exclusions.Filenames | ForEach-Object { $_.ToLowerInvariant() })

        # Writer oracle: scan all .ps1 files for patterns that write root-level files under .copilot-tracking/
        $psFiles = Get-ChildItem -Path $repoRoot -Filter '*.ps1' -Recurse |
            Where-Object {
                $_.FullName -notmatch '\.Tests\.' -and
                $_.Name -ne 'session-cleanup-detector-core.ps1' -and
                $_.Name -ne 'post-merge-cleanup.ps1' -and
                $_.Name -ne 'session-cleanup-detector.ps1' -and
                $_.Name -notmatch 'gate-reconciliation' -and
                $_.Name -notmatch 'Resolve-PersistDecision'
            }

        $writtenBasenames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($file in $psFiles) {
            $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            # Pattern 1: Join-Path $trackingDir 'filename.ext' (depth-0 file only — no slash in filename)
            $matches1 = [regex]::Matches($content, "Join-Path\s+\`$\w*[Tt]racking\w*\s+['\`"]([^/\\'\`"]+\.[a-zA-Z0-9]+)['\`"]")
            foreach ($m in $matches1) { $null = $writtenBasenames.Add($m.Groups[1].Value) }

            # Pattern 2: Join-Path ... '.copilot-tracking' 'filename.ext'
            $matches2 = [regex]::Matches($content, "Join-Path\s+\S+\s+'?\.copilot-tracking'?\s+['\`"]([^/\\'\`"]+\.[a-zA-Z0-9]+)['\`"]")
            foreach ($m in $matches2) { $null = $writtenBasenames.Add($m.Groups[1].Value) }
        }

        # Every oracle-found basename must be in the registry (filter empties to prevent silent BeNullOrEmpty pass)
        $unregistered = @($writtenBasenames | Where-Object { $_ } | Where-Object { $registeredFilenames -notcontains $_.ToLowerInvariant() })
        $unregistered | Should -BeNullOrEmpty `
            -Because "oracle-found root-level tracking writers must all be enrolled in Get-SCDPersistentTrackingExclusions: missing: $($unregistered -join ', ')"
    }

    It 'AC7: no persistent-filename literal exists outside Get-SCDPersistentTrackingExclusions' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        $exclusions = Get-SCDPersistentTrackingExclusions

        foreach ($fname in $exclusions.Filenames) {
            $matches = @(
                Get-ChildItem -Path (Join-Path $repoRoot 'skills/session-startup/scripts') -Filter '*.ps1' |
                Where-Object { $_.Name -ne 'session-startup-git-helpers.ps1' } |
                ForEach-Object {
                    $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                    if ($content -match [regex]::Escape($fname)) {
                        $_.Name
                    }
                }
            )
            $matches | Should -BeNullOrEmpty `
                -Because "'$fname' must only appear in the accessor, not as a literal in other session-startup scripts"
        }
    }
}

Describe 'session-cleanup-detector.ps1 — Issue #889 s4: shared eligibility gating' {

    BeforeAll {
        # Reuses $script:RepoRoot / $script:InvokeDetectorInWorkDir / $script:ToPorcelainPath /
        # $script:NewWorktreeRecord / $script:GetAdditionalContext / $script:GetFencedPowerShellBlocks /
        # $script:RemoveFencedPowerShellBlocks — all set in the "calibration tracking exclusion"
        # Describe's BeforeAll earlier in this file. Functions are per-Describe-scope in Pester 5
        # (unlike $script: variables), so the core library must be re-dot-sourced here — same
        # pattern already used by the "Get-OrphanBranchLines" Describe above.
        . (Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1')
    }

    Context 'zero-commit candidates are not flagged (rung-3 primitive path, all five sites)' {

        It 'site 1: sibling remote-head-missing zero-commit candidate is manual-review only' {
            $workDir = Join-Path $TestDrive 's4-zero-sibling-remote-head-current'
            $siblingDir = Join-Path $TestDrive 's4-zero-sibling-remote-head-other'
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            $siblingBranch = 'feature/issue-9001-zero-commit-remote-head'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $siblingBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GhConfig @{} -GitConfig @{
                'branch--show-current'                        = 'main'
                'symbolic-ref-origin-HEAD'                    = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                     = $worktreeList
                "ls-remote-$siblingBranch"                    = ''
                "rev-list-count-origin/main..$siblingBranch"  = 0
                'path-configs'                                 = @{
                    "$siblingPath" = @{
                        'branch--show-current'                = $siblingBranch
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
            $context | Should -Match 'needs manual review'
            $insideFence | Should -Not -Match ([regex]::Escape($siblingPath)) `
                -Because 'an ineligible sibling candidate must not appear in the -SiblingWorktrees composite argument'
        }

        It 'site 2: sibling ancestry zero-commit candidate is manual-review only' {
            $workDir = Join-Path $TestDrive 's4-zero-sibling-ancestry-current'
            $siblingDir = Join-Path $TestDrive 's4-zero-sibling-ancestry-other'
            New-Item -ItemType Directory -Path $workDir, $siblingDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            $siblingBranch = 'claude/scratch-ancestor-zero'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $siblingBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GhConfig @{} -GitConfig @{
                'branch--show-current'                               = 'main'
                'symbolic-ref-origin-HEAD'                           = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                            = $worktreeList
                'show-ref-refs/remotes/origin/main'                  = 0
                'fetch-exit'                                         = 0
                "merge-base-$siblingBranch-refs/remotes/origin/main" = 0
                "rev-list-count-origin/main..$siblingBranch"         = 0
                'path-configs'                                        = @{
                    "$siblingPath" = @{
                        'branch--show-current' = $siblingBranch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($siblingBranch))
            $context | Should -Match ([regex]::Escape("needs manual review: no issue number derivable"))
            $insideFence | Should -Not -Match ([regex]::Escape($siblingPath)) `
                -Because 'an ineligible sibling candidate must not appear in the -SiblingWorktrees composite argument'
        }

        It 'site 3: orphan remote-head-missing zero-commit candidate is manual-review only' {
            $workDir = Join-Path $TestDrive 's4-zero-orphan-remote-head'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'feature/issue-9002-zero-commit-orphan'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GhConfig @{} -GitConfig @{
                'branch--show-current'                    = 'main'
                'symbolic-ref-origin-HEAD'                = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                 = (& $script:NewWorktreeRecord -Path (& $script:ToPorcelainPath -Path $workDir) -Branch 'main')
                'fetch-exit'                               = 0
                'for-each-ref-refs/heads/feature/issue-*' = @($branch)
                'for-each-ref-refs/heads/feature/'        = @($branch)
                'for-each-ref-refs/heads/'                = @($branch)
                "config-branch.$branch.remote"            = 'origin'
                "config-branch.$branch.merge"             = "refs/heads/$branch"
                "ls-remote-$branch"                       = ''
                "rev-list-count-origin/main..$branch"     = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match 'needs manual review'
            $insideFence | Should -Not -Match ([regex]::Escape($branch)) `
                -Because 'an ineligible orphan candidate must not appear in the -OrphanBranches composite argument'
        }

        It 'site 4: orphan ancestry zero-commit candidate is manual-review only' {
            $workDir = Join-Path $TestDrive 's4-zero-orphan-ancestry'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/scratch-orphan-zero'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GhConfig @{} -GitConfig @{
                'branch--show-current'                        = 'main'
                'symbolic-ref-origin-HEAD'                    = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                     = (& $script:NewWorktreeRecord -Path (& $script:ToPorcelainPath -Path $workDir) -Branch 'main')
                'show-ref-refs/remotes/origin/main'           = 0
                'fetch-exit'                                  = 0
                'for-each-ref-refs/heads/claude/'             = @($branch)
                "merge-base-$branch-refs/remotes/origin/main" = 0
                "rev-list-count-origin/main..$branch"         = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match ([regex]::Escape("needs manual review: no issue number derivable"))
            $insideFence | Should -Not -Match ([regex]::Escape($branch)) `
                -Because 'an ineligible orphan candidate must not appear in the -OrphanBranches composite argument'
        }

        It 'site 5: current-no-upstream zero-commit candidate is manual-review only' {
            $workDir = Join-Path $TestDrive 's4-zero-current-current'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/scratch-current-zero'
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $primaryPath = & $script:ToPorcelainPath -Path (Join-Path $TestDrive 's4-zero-current-primary')
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $primaryPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $currentPath -Branch $branch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GhConfig @{} -GitConfig @{
                'branch--show-current'                = $branch
                'symbolic-ref-origin-HEAD'            = 'refs/remotes/origin/main'
                'rev-parse-exit'                      = 128
                'worktree-list-porcelain'              = $worktreeList
                'show-ref-refs/remotes/origin/main'   = 0
                'fetch-exit'                            = 0
                'merge-base-exit'                       = 0
                "rev-list-count-origin/main..$branch" = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"
            $outsideFence = & $script:RemoveFencedPowerShellBlocks -Context $context

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match ([regex]::Escape("needs manual review: no issue number derivable"))
            $outsideFence | Should -Not -Match 'git worktree remove' `
                -Because 'an ineligible current-branch candidate must not render the worktree-remove command block'
            $insideFence | Should -Not -Match 'git worktree remove'
        }
    }

    Context 'structural primary-worktree guard' {

        It 'primary worktree on a non-default branch is not flagged as a sibling candidate' {
            $workDir = Join-Path $TestDrive 's4-primary-sibling-current'
            $primaryDir = Join-Path $TestDrive 's4-primary-sibling-primary'
            New-Item -ItemType Directory -Path $workDir, $primaryDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $primaryPath = & $script:ToPorcelainPath -Path $primaryDir
            $primaryBranch = 'claude/primary-on-feature-abcde'
            # Primary (first record) is on a NON-default branch — the 2026-07-20 incident
            # shape: the agent runs from a non-primary linked worktree ($workDir) while the
            # primary checkout ($primaryDir) sits on some other branch, not main.
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $primaryPath -Branch $primaryBranch),
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main')
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                               = 'main'
                'symbolic-ref-origin-HEAD'                           = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                            = $worktreeList
                'show-ref-refs/remotes/origin/main'                  = 0
                'fetch-exit'                                         = 0
                "merge-base-$primaryBranch-refs/remotes/origin/main" = 0
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$' `
                -Because 'the primary worktree must never be offered as a sibling cleanup candidate, regardless of eligibility signals'
        }

        It 'primary worktree on a non-default branch is not flagged as the current-branch candidate' {
            $workDir = Join-Path $TestDrive 's4-primary-current-current'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'claude/primary-current-abcde'
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            # Single-record layout: the current location IS the primary (first and only
            # worktree record) — the common solo-checkout shape, where `git worktree
            # remove` can never legitimately target the current location.
            $worktreeList = (& $script:NewWorktreeRecord -Path $currentPath -Branch $branch)

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'              = $branch
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'rev-parse-exit'                    = 128
                'worktree-list-porcelain'           = $worktreeList
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                'merge-base-exit'                   = 0
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$' `
                -Because 'the primary checkout can never be a git worktree remove target, so the current-branch category must be suppressed'
        }
    }

    Context 'eligible vs manual-review mutual exclusivity and line rendering' {

        It 'an ineligible candidate is absent from composite args while an eligible candidate from the same run is present, and each renders its own evidence/reason string' {
            $workDir = Join-Path $TestDrive 's4-mutual-exclusivity-current'
            $eligibleDir = Join-Path $TestDrive 's4-mutual-exclusivity-eligible'
            $ineligibleDir = Join-Path $TestDrive 's4-mutual-exclusivity-ineligible'
            New-Item -ItemType Directory -Path $workDir, $eligibleDir, $ineligibleDir -Force | Out-Null
            $currentPath = & $script:ToPorcelainPath -Path $workDir
            $eligiblePath = & $script:ToPorcelainPath -Path $eligibleDir
            $ineligiblePath = & $script:ToPorcelainPath -Path $ineligibleDir
            $eligibleBranch = 'claude/mutual-eligible-abcde'
            $ineligibleBranch = 'claude/mutual-ineligible-zero'
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $currentPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $eligiblePath -Branch $eligibleBranch),
                (& $script:NewWorktreeRecord -Path $ineligiblePath -Branch $ineligibleBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GhConfig @{} -GitConfig @{
                'branch--show-current'                                  = 'main'
                'symbolic-ref-origin-HEAD'                              = 'refs/remotes/origin/main'
                'worktree-list-porcelain'                               = $worktreeList
                'show-ref-refs/remotes/origin/main'                     = 0
                'fetch-exit'                                            = 0
                "merge-base-$eligibleBranch-refs/remotes/origin/main"   = 0
                "merge-base-$ineligibleBranch-refs/remotes/origin/main" = 0
                "rev-list-count-origin/main..$ineligibleBranch"         = 0
                'path-configs'                                           = @{
                    "$eligiblePath"   = @{ 'branch--show-current' = $eligibleBranch; 'rev-parse-exit' = 128 }
                    "$ineligiblePath" = @{ 'branch--show-current' = $ineligibleBranch; 'rev-parse-exit' = 128 }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"

            $result.ExitCode | Should -Be 0
            $insideFence | Should -Match ([regex]::Escape("-SiblingWorktrees @('$eligiblePath')")) `
                -Because 'the eligible sibling must appear alone in the composite -SiblingWorktrees argument'
            $insideFence | Should -Not -Match ([regex]::Escape($ineligiblePath)) `
                -Because 'the ineligible sibling must never appear in the composite args'
            $context | Should -Match ([regex]::Escape($ineligibleBranch))
            $context | Should -Match ([regex]::Escape("needs manual review: no issue number derivable")) `
                -Because 'the manual-review line must render the primitive ManualReviewReason string'
            $context | Should -Match ([regex]::Escape('merged into origin/main (tree-equivalent)')) `
                -Because 'the eligible line must render the primitive Evidence string'
        }
    }

    Context 'degraded-CWD downgrade' {

        It 'degraded CWD downgrades sibling candidates to manual review, suppresses current-branch, and adds a caveat' {
            $workDir = Join-Path $TestDrive 's4-degraded-cwd-current'
            $otherPrimaryDir = Join-Path $TestDrive 's4-degraded-cwd-other-primary'
            $siblingDir = Join-Path $TestDrive 's4-degraded-cwd-sibling'
            New-Item -ItemType Directory -Path $workDir, $otherPrimaryDir, $siblingDir -Force | Out-Null
            $otherPrimaryPath = & $script:ToPorcelainPath -Path $otherPrimaryDir
            $siblingPath = & $script:ToPorcelainPath -Path $siblingDir
            $siblingBranch = 'claude/degraded-sibling-abcde'
            $currentBranch = 'claude/degraded-current-abcde'
            # Neither record matches $workDir (the actual CWD) — simulates a wiped/relocated
            # linked worktree whose directory-walk falls through to a DIFFERENT checkout, so
            # `git worktree list --porcelain` never lists $workDir at all (issue #889's own
            # dispatch-env shape).
            $worktreeList = @(
                (& $script:NewWorktreeRecord -Path $otherPrimaryPath -Branch 'main'),
                (& $script:NewWorktreeRecord -Path $siblingPath -Branch $siblingBranch)
            ) -join "`n`n"

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'                               = $currentBranch
                'symbolic-ref-origin-HEAD'                           = 'refs/remotes/origin/main'
                'rev-parse-exit'                                     = 128
                'worktree-list-porcelain'                            = $worktreeList
                'show-ref-refs/remotes/origin/main'                  = 0
                'fetch-exit'                                         = 0
                "merge-base-$currentBranch-refs/remotes/origin/main" = 0
                "merge-base-$siblingBranch-refs/remotes/origin/main" = 0
                'path-configs'                                        = @{
                    "$siblingPath" = @{
                        'branch--show-current' = $siblingBranch
                        'rev-parse-exit'       = 128
                    }
                }
            }
            $context = & $script:GetAdditionalContext -Output $result.Output
            $insideFence = (& $script:GetFencedPowerShellBlocks -Context $context) -join "`n"
            $outsideFence = & $script:RemoveFencedPowerShellBlocks -Context $context

            $result.ExitCode | Should -Be 0
            $context | Should -Not -Match ([regex]::Escape($currentBranch)) `
                -Because 'the current-branch category must be suppressed entirely under degraded CWD'
            $outsideFence | Should -Not -Match 'git worktree remove'
            $context | Should -Match ([regex]::Escape($siblingBranch))
            $context | Should -Match 'needs manual review'
            $insideFence | Should -Not -Match ([regex]::Escape($siblingPath)) `
                -Because 'degraded CWD must downgrade sibling candidates to report-only, excluded from composite args'
            $context | Should -Match 'did not match a registered worktree' `
                -Because 'the degraded-CWD caveat note must be rendered'
        }
    }

    Context 'collection-time gh budget' {

        It 'no candidates yields zero gh calls' {
            $workDir = Join-Path $TestDrive 's4-no-candidates-zero-gh'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GhConfig @{} -IncludeGhCalls -GitConfig @{
                'branch--show-current'     = 'main'
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '^\{\s*\}$'
            $result['GhCalls'].Count | Should -Be 0 `
                -Because 'zero candidates must never spend the gh mock (or a real gh call in production)'
        }

        It 'finding D (#889 fix cycle): a per-category COUNT-cap exhaustion is reported with the distinct "too many candidates" reason, not GhTimeout' {
            $budget = New-SCDCollectionGhBudget -PerCategoryLimit 1 -GlobalSeconds 999
            # Spend the single count-cap slot for this category.
            Test-SCDCollectionGhBudgetExceeded -Budget $budget -Category 'orphan' | Should -Be $false
            $result = Get-SCDGatedEligibility -Budget $budget -Category 'orphan' -BranchName 'feature/issue-1-x' -DefaultBranch 'main'
            $result.Eligible | Should -Be $false
            $result.ManualReviewReason | Should -Be "couldn't verify: too many candidates this run" `
                -Because 'a count-cap exhaustion means no gh call was even attempted — GhTimeout is reserved for a genuine per-call timeout'
        }

        It 'finding D (#889 fix cycle): an elapsed-time budget-cap exhaustion is reported with the distinct "too many candidates" reason, not GhTimeout' {
            $budget = New-SCDCollectionGhBudget -PerCategoryLimit 999 -GlobalSeconds 0
            Start-Sleep -Milliseconds 5
            $result = Get-SCDGatedEligibility -Budget $budget -Category 'orphan' -BranchName 'feature/issue-2-x' -DefaultBranch 'main'
            $result.Eligible | Should -Be $false
            $result.ManualReviewReason | Should -Be "couldn't verify: too many candidates this run" `
                -Because 'the elapsed-time cap is also a collection-budget decision, not a genuine gh subprocess timeout'
        }
    }

    Context 'finding K (#889 fix cycle): Get-SCDRemoteDefaultRef single-sources on the shared Get-RemoteDefaultRef resolution strategy' {

        It 'falls back to branch.<X>.remote config (via the shared resolver''s own fallback) when the @{upstream} shorthand is unavailable, matching the previously-separate detector-only resolver''s behavior' {
            $workDir = Join-Path $TestDrive 's4-remote-default-ref-config-fallback'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $mockDir = & $script:NewMockGitDir -ParentDir $workDir -Config @{
                'config-branch.main.remote' = 'upstream'
            }
            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"
                Push-Location $workDir
                try {
                    $result = Get-SCDRemoteDefaultRef -DefaultBranch 'main'
                    $result.RemoteName | Should -Be 'upstream'
                    $result.BranchName | Should -Be 'main'
                    $result.RefName | Should -Be 'refs/remotes/upstream/main'
                }
                finally { Pop-Location }
            }
            finally { $env:PATH = $script:SavedPath }
        }

        It 'falls back to the shared helper''s origin/<DefaultBranch> default when no upstream ref or remote config is resolvable' {
            $workDir = Join-Path $TestDrive 's4-remote-default-ref-hard-default'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $mockDir = & $script:NewMockGitDir -ParentDir $workDir -Config @{}
            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"
                Push-Location $workDir
                try {
                    $result = Get-SCDRemoteDefaultRef -DefaultBranch 'main'
                    $result.RemoteName | Should -Be 'origin'
                    $result.BranchName | Should -Be 'main'
                    $result.RefName | Should -Be 'refs/remotes/origin/main'
                }
                finally { Pop-Location }
            }
            finally { $env:PATH = $script:SavedPath }
        }
    }

    Context 'finding G (#889 fix cycle): the sixth candidate site (current branch, upstream configured, remote gone) is gated' {

        It 'an eligible stale current branch still emits the plain detection line and the composite -FeatureBranch command' {
            $workDir = Join-Path $TestDrive 's4-staleBranch-gated-eligible'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'feature/issue-9100-stale-gated-eligible'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GitConfig @{
                'branch--show-current'      = $branch
                'symbolic-ref-origin-HEAD'  = 'refs/remotes/origin/main'
                'rev-parse-exit'            = 0
                'rev-parse-upstream'        = "origin/$branch"
                "ls-remote-$branch"         = ''
                "diff-quiet-exit-$branch"   = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match ([regex]::Escape('remote branch merged/deleted'))
            $context | Should -Not -Match 'needs manual review before running the cleanup command below' `
                -Because 'an eligible stale branch must not be annotated as needing manual review'
            $context | Should -Match ([regex]::Escape("-FeatureBranch '$branch'")) `
                -Because 'the composite command must still be emitted for an eligible candidate'
        }

        It 'an ineligible stale current branch is annotated with a manual-review reason (regression test for finding G — previously this was the one ungated site)' {
            $workDir = Join-Path $TestDrive 's4-staleBranch-gated-ineligible'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'bugfix/random-stale-no-derivable-id'

            $result = & $script:InvokeDetectorInWorkDir -WorkDir $workDir -GhConfig @{} -GitConfig @{
                'branch--show-current'                       = $branch
                'symbolic-ref-origin-HEAD'                   = 'refs/remotes/origin/main'
                'rev-parse-exit'                              = 0
                'rev-parse-upstream'                          = "origin/$branch"
                "ls-remote-$branch"                           = ''
                "rev-list-count-origin/main..$branch"         = 0
            }
            $context = & $script:GetAdditionalContext -Output $result.Output

            $result.ExitCode | Should -Be 0
            $context | Should -Match ([regex]::Escape($branch))
            $context | Should -Match 'needs manual review before running the cleanup command below' `
                -Because 'a genuinely ineligible stale branch must be visibly flagged now that this site is gated'
            $context | Should -Match ([regex]::Escape('no issue number derivable')) `
                -Because 'the manual-review annotation must name the eligibility primitive''s actual reason'
        }
    }
}
