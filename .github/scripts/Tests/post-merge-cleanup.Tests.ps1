#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for post-merge-cleanup.ps1 new parameters (Issue #500 — TDD red phase).

.DESCRIPTION
    Tests the new parameters and behaviors being added in Issue #500:
    - IssueNumber becomes optional (Nullable[int] default $null)
    - OrphanBranches: deletes merged orphan branches via git cherry oracle
    - SiblingWorktrees: removes sibling worktrees and their branches
    - UntaggedTrackingFiles: archives files without known issue IDs
    - git fetch fail-open: fetch failures emit warning but do not abort
    - Guard: must fail when called with neither -IssueNumber nor any
      non-empty new parameter
    - Back-compat: -IssueNumber provided with empty new params => existing
      behavior preserved

    All test branches use pester-temp/issue-500- prefix so leaked branches
    are obvious. Teardown force-deletes any pester-temp/issue-500-* branches.

    NOTE: These tests are the RED phase — they document behavior that does
    not yet exist in the current script.
#>

Describe 'post-merge-cleanup.ps1 — new parameters (Issue #500)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills\session-startup\scripts\post-merge-cleanup.ps1'
        $script:SavedPath = $env:PATH

        # Record pre-test branch state for leak detection in AfterAll
        $script:PreTestBranches = @(git -C $script:RepoRoot branch --list 'pester-temp/issue-500-*' 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

        # ---------------------------------------------------------------------------
        # Mock git factory — same pattern as session-cleanup-detector.Tests.ps1
        # Writes a git.ps1 shim + git.cmd wrapper to a temp dir, prepends to PATH.
        # ---------------------------------------------------------------------------
        $script:NewMockGitDir = {
            param(
                [string]$ParentDir,
                [hashtable]$Config
            )

            $mockDir = Join-Path $ParentDir "git-mock-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $mockDir -Force | Out-Null

            $Config | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $mockDir 'git-mock-config.json') -Encoding UTF8

            # The mock dispatch script — reads config and responds based on git subcommand
            $mockPs1 = @'
param()
$configPath = Join-Path $PSScriptRoot 'git-mock-config.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$a = $args
$callLogPath = Join-Path $PSScriptRoot 'git-mock-calls.log'
($a -join "`t") | Add-Content -Path $callLogPath -Encoding UTF8

function Get-ConfigValue {
    param([string]$Name)
    $prop = $config.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Normalize-Path {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

function Get-PathConfigValue {
    param([string]$Name, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $pathConfigs = Get-ConfigValue 'path-configs'
    if ($null -eq $pathConfigs) { return $null }
    $normalizedPath = Normalize-Path $Path
    foreach ($entry in $pathConfigs.PSObject.Properties) {
        if ((Normalize-Path $entry.Name) -eq $normalizedPath) {
            $prop = $entry.Value.PSObject.Properties[$Name]
            if ($null -ne $prop) { return $prop.Value }
            return $null
        }
    }
    return $null
}

function Get-ConfigValueForPath {
    param([string]$Name, [string]$Path)
    $pathVal = Get-PathConfigValue -Name $Name -Path $Path
    if ($null -ne $pathVal) { return $pathVal }
    return Get-ConfigValue $Name
}

# Strip -C <path> prefix so subcommand handlers work uniformly
$gitWorkDir = $null
if ($a.Count -ge 3 -and $a[0] -eq '-C') {
    $gitWorkDir = $a[1]
    $a = @($a[2..($a.Count - 1)])
}

# git symbolic-ref refs/remotes/origin/HEAD
if ($a.Count -ge 2 -and $a[0] -eq 'symbolic-ref' -and $a[1] -eq 'refs/remotes/origin/HEAD') {
    $val = Get-ConfigValue 'symbolic-ref-origin-HEAD'
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 128
}

# git symbolic-ref HEAD
if ($a.Count -ge 2 -and $a[0] -eq 'symbolic-ref' -and $a[1] -eq 'HEAD') {
    $val = Get-ConfigValueForPath -Name 'symbolic-ref-HEAD' -Path $gitWorkDir
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 128
}

# git show-ref --verify --quiet <ref>
if ($a.Count -ge 4 -and $a[0] -eq 'show-ref' -and $a[1] -eq '--verify' -and $a[2] -eq '--quiet') {
    $ref = $a[3]
    $key = "show-ref-$ref"
    $exitVal = Get-ConfigValue $key
    if ($null -eq $exitVal) { $exitVal = Get-ConfigValue 'show-ref-default-exit' }
    if ($null -eq $exitVal) { $exitVal = 1 }
    exit ([int]$exitVal)
}

# git branch --show-current (supports -C path via $gitWorkDir)
if ($a.Count -ge 2 -and $a[0] -eq 'branch' -and $a[1] -eq '--show-current') {
    $val = Get-ConfigValueForPath -Name 'branch--show-current' -Path $gitWorkDir
    if ($null -ne $val) { Write-Output $val }
    exit 0
}

# git branch --list <pattern>
if ($a.Count -ge 3 -and $a[0] -eq 'branch' -and $a[1] -eq '--list') {
    $pattern = $a[2]
    $key = "branch-list-$pattern"
    $val = Get-ConfigValue $key
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 0
}

# git branch -d <branch>  (safe delete)
if ($a.Count -ge 3 -and $a[0] -eq 'branch' -and ($a[1] -eq '-d' -or $a[1] -eq '-D')) {
    $branch = $a[2]
    $flagKey = if ($a[1] -eq '-d') { 'branch-d-exit' } else { 'branch-D-exit' }
    $specificKey = "$($a[1])-$branch"
    $exitVal = Get-ConfigValue $specificKey
    if ($null -eq $exitVal) { $exitVal = Get-ConfigValue $flagKey }
    if ($null -eq $exitVal) { $exitVal = 0 }
    if ([int]$exitVal -eq 0) {
        # Log the successful delete for verification
        "branch-deleted`t$($a[1])`t$branch" | Add-Content -Path $callLogPath -Encoding UTF8
    }
    exit ([int]$exitVal)
}

# git checkout <branch>
if ($a.Count -ge 2 -and $a[0] -eq 'checkout') {
    $val = Get-ConfigValue 'checkout-exit'
    if ($null -eq $val) { $val = 0 }
    exit ([int]$val)
}

# git pull
if ($a.Count -ge 1 -and $a[0] -eq 'pull') {
    $val = Get-ConfigValue 'pull-exit'
    if ($null -eq $val) { $val = 0 }
    exit ([int]$val)
}

# git ls-remote --heads origin <branch>
if ($a.Count -ge 4 -and $a[0] -eq 'ls-remote' -and $a[1] -eq '--heads') {
    $branch = $a[3]
    $key = "ls-remote-$branch"
    $val = Get-ConfigValue $key
    if ($null -ne $val) { Write-Output $val }
    $exitVal = Get-ConfigValue 'ls-remote-exit'
    if ($null -eq $exitVal) { $exitVal = 0 }
    exit ([int]$exitVal)
}

# git remote get-url origin
if ($a.Count -ge 3 -and $a[0] -eq 'remote' -and $a[1] -eq 'get-url') {
    $val = Get-ConfigValue 'remote-url'
    if ($null -ne $val) { Write-Output $val }
    exit 0
}

# git fetch origin --prune
if ($a.Count -ge 1 -and $a[0] -eq 'fetch') {
    $exitVal = Get-ConfigValue 'fetch-exit'
    if ($null -eq $exitVal) { $exitVal = 0 }
    "fetch-called" | Add-Content -Path $callLogPath -Encoding UTF8
    exit ([int]$exitVal)
}

# git cherry <baseRef> <branch>
# Empty stdout = merged; lines starting with - or + = unmerged commits present
if ($a.Count -ge 3 -and $a[0] -eq 'cherry') {
    $baseRef = $a[1]       # the base ref (should be origin/<defaultBranch>)
    $targetBranch = $a[2]  # the branch being checked
    $cherryKey = "cherry-$targetBranch"
    $cherryOutput = Get-ConfigValue $cherryKey
    $cherryExit = Get-ConfigValue "cherry-exit-$targetBranch"
    if ($null -eq $cherryExit) { $cherryExit = Get-ConfigValue 'cherry-default-exit' }
    if ($null -eq $cherryExit) { $cherryExit = 0 }
    if ($null -ne $cherryOutput -and $cherryOutput -ne '') {
        Write-Output $cherryOutput
    }
    # Log the call for assertion: includes baseRef so tests can verify origin/ prefix is used
    "cherry-called`t$baseRef`t$targetBranch" | Add-Content -Path $callLogPath -Encoding UTF8
    # Assert base ref uses origin/ prefix when config requires it
    $requireOrgRef = Get-ConfigValue 'cherry-require-origin-prefix'
    if ($null -ne $requireOrgRef -and [bool]$requireOrgRef -and -not $baseRef.StartsWith('origin/')) {
        "cherry-base-ref-error`t$baseRef`t(expected origin/ prefix)" | Add-Content -Path $callLogPath -Encoding UTF8
        exit 2
    }
    exit ([int]$cherryExit)
}

# git worktree remove [--force] <path>
if ($a.Count -ge 3 -and $a[0] -eq 'worktree' -and $a[1] -eq 'remove') {
    $path = $a[-1]
    $key = "worktree-remove-exit-$path"
    $exitVal = Get-ConfigValue $key
    if ($null -eq $exitVal) { $exitVal = Get-ConfigValue 'worktree-remove-exit' }
    if ($null -eq $exitVal) { $exitVal = 0 }
    "worktree-removed`t$path" | Add-Content -Path $callLogPath -Encoding UTF8
    exit ([int]$exitVal)
}

# git worktree remove <path> (2-arg form)
if ($a.Count -ge 2 -and $a[0] -eq 'worktree' -and $a[1] -eq 'remove') {
    $path = $a[2]
    $exitVal = Get-ConfigValue 'worktree-remove-exit'
    if ($null -eq $exitVal) { $exitVal = 0 }
    "worktree-removed`t$path" | Add-Content -Path $callLogPath -Encoding UTF8
    exit ([int]$exitVal)
}

# Default: success
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
        # Mock gh factory — writes a gh.ps1 shim to the same temp dir
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

# gh pr list --head <branch> --state merged --json number
if ($a.Count -ge 6 -and $a[0] -eq 'pr' -and $a[1] -eq 'list') {
    $headIdx = [Array]::IndexOf([string[]]$a, '--head')
    $branch = if ($headIdx -ge 0 -and $headIdx + 1 -lt $a.Count) { $a[$headIdx + 1] } else { '' }
    $key = "pr-list-merged-$branch"
    $val = Get-GhConfigValue $key
    if ($null -ne $val) { Write-Output $val; exit 0 }
    $defaultExit = Get-GhConfigValue 'pr-list-default-exit'
    if ($null -eq $defaultExit) { $defaultExit = 0 }
    $defaultOutput = Get-GhConfigValue 'pr-list-default-output'
    if ($null -ne $defaultOutput) { Write-Output $defaultOutput }
    exit ([int]$defaultExit)
}

exit 0
'@
            Set-Content -Path (Join-Path $MockDir 'gh-mock.ps1') -Value $ghMockPs1 -Encoding UTF8

            $ps1Shim = @'
#!/usr/bin/env pwsh
& (Join-Path $PSScriptRoot 'gh-mock.ps1') @args
exit $LASTEXITCODE
'@
            Set-Content -Path (Join-Path $MockDir 'gh.ps1') -Value $ps1Shim -Encoding UTF8

            $cmdContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0gh-mock.ps1`" %*`r`nexit %ERRORLEVEL%"
            Set-Content -Path (Join-Path $MockDir 'gh.cmd') -Value $cmdContent -Encoding ASCII
        }

        # ---------------------------------------------------------------------------
        # Helper: invoke post-merge-cleanup.ps1 in a temp work directory.
        # Injects git (and optionally gh) mock via PATH.
        # Returns hashtable: ExitCode, Output, GitCalls, GhCalls
        # ---------------------------------------------------------------------------
        $script:InvokeScript = {
            param(
                [string]$WorkDir,
                [hashtable]$GitConfig,
                [hashtable]$GhConfig = $null,
                [hashtable]$ScriptParams = @{}
            )

            $mockDir = & $script:NewMockGitDir -ParentDir $WorkDir -Config $GitConfig
            if ($null -ne $GhConfig) {
                & $script:AddMockGh -MockDir $mockDir -GhConfig $GhConfig
            }

            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"

                # Build parameter string for pwsh invocation
                $paramParts = @()
                foreach ($key in $ScriptParams.Keys) {
                    $val = $ScriptParams[$key]
                    if ($val -is [System.Management.Automation.SwitchParameter] -or $val -is [bool]) {
                        if ($val) { $paramParts += "-$key" }
                    }
                    elseif ($val -is [int]) {
                        $paramParts += "-$key $val"
                    }
                    elseif ($val -is [string[]]) {
                        $arrStr = ($val | ForEach-Object { "'$_'" }) -join ','
                        $paramParts += "-$key @($arrStr)"
                    }
                    elseif ($null -eq $val) {
                        # Null — skip (for nullable int not provided)
                    }
                    else {
                        $paramParts += "-$key '$val'"
                    }
                }
                $paramStr = $paramParts -join ' '

                $scriptPath = $script:ScriptFile
                $output = pwsh -NoProfile -NonInteractive -Command `
                    "Set-Location '$WorkDir'; & '$scriptPath' $paramStr" `
                    2>&1

                $exitCode = $LASTEXITCODE
                $outputStr = ($output | Out-String).Trim()

                $callLogPath = Join-Path $mockDir 'git-mock-calls.log'
                $gitCalls = if (Test-Path $callLogPath) {
                    @(Get-Content -Path $callLogPath -ErrorAction SilentlyContinue)
                }
                else { @() }

                $ghCallLogPath = Join-Path $mockDir 'gh-mock-calls.log'
                $ghCalls = if (Test-Path $ghCallLogPath) {
                    @(Get-Content -Path $ghCallLogPath -ErrorAction SilentlyContinue)
                }
                else { @() }

                return @{
                    ExitCode = $exitCode
                    Output   = $outputStr
                    GitCalls = $gitCalls
                    GhCalls  = $ghCalls
                }
            }
            finally {
                $env:PATH = $script:SavedPath
                Remove-Item -Recurse -Force -Path $mockDir -ErrorAction SilentlyContinue
            }
        }
    }

    AfterAll {
        $env:PATH = $script:SavedPath

        # Force-delete any leaked pester-temp/issue-500-* branches (recursive-irony defense)
        $leakedBranches = @(git -C $script:RepoRoot branch --list 'pester-temp/issue-500-*' 2>$null |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and $_ -notin $script:PreTestBranches })

        foreach ($leaked in $leakedBranches) {
            Write-Warning "AfterAll: cleaning up leaked test branch: $leaked"
            git -C $script:RepoRoot branch -D $leaked 2>$null | Out-Null
        }
    }

    # =========================================================================
    # Guard tests
    # =========================================================================
    Context 'Guard — parameter validation' {

        It 'TC-Guard-1: exits non-zero with usage error when called with no parameters' {
            $workDir = Join-Path $TestDrive 'guard-no-params'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
            } -ScriptParams @{}

            $result.ExitCode | Should -Not -Be 0 -Because 'script must fail when neither -IssueNumber nor orphan/sibling/untagged params are provided'
            # NOTE: After Issue #500 implementation, IssueNumber becomes nullable optional.
            # The guard must then emit its own usage error (not the PS mandatory-param error).
            # For now the existing mandatory-param error is acceptable as long as exit is non-zero.
            $result.Output | Should -Not -BeNullOrEmpty -Because 'some error message must be present when script fails'
        }

        It 'TC-Guard-2: exits zero when called with -IssueNumber 0 (falsy but valid)' {
            $workDir = Join-Path $TestDrive 'guard-issue-0'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            # IssueNumber 0 is technically valid (issue #0) — should not trigger guard
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'checkout-exit'  = 0
                'pull-exit'      = 0
                'fetch-exit'     = 0
            } -ScriptParams @{
                IssueNumber   = 0
                SkipGitUpdate = $true
                SkipRemoteDelete = $true
                SkipLocalDelete  = $true
            }

            $result.ExitCode | Should -Be 0 -Because 'IssueNumber 0 is a valid explicit value and must not trigger the guard'
        }
    }

    # =========================================================================
    # OrphanBranches tests
    # =========================================================================
    Context 'OrphanBranches — merged orphan deletion' {

        It 'TC-Orphan-1: deletes a merged orphan branch and emits summary line' {
            $workDir = Join-Path $TestDrive 'orphan-merged'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-orphan-merged'

            # git cherry returns empty stdout = merged
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'     = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                   = 0
                "cherry-$branch"               = ''
                'branch-d-exit'                = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match ([regex]::Escape("Deleted 1 orphan branch(es):")) -Because 'summary line must appear when orphan is deleted'
            $result.Output | Should -Match ([regex]::Escape($branch)) -Because 'deleted branch name must appear in output'
            $deleteCalls = @($result.GitCalls | Where-Object { $_ -match '^branch-deleted\t' })
            $deleteCalls.Count | Should -BeGreaterThan 0 -Because 'git branch -d (or -D) must be called for merged orphan'
        }

        It 'TC-Orphan-2: skips unmerged orphan with message and does NOT delete it' {
            $workDir = Join-Path $TestDrive 'orphan-unmerged'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-orphan-unmerged'

            # git cherry returns commit lines = unmerged
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'     = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                   = 0
                "cherry-$branch"               = "+ abc123def456 commit message here"
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match ([regex]::Escape("Skipped '$branch'")) -Because 'skip message must appear for unmerged branch'
            $result.Output | Should -Match 'unmerged' -Because 'skip reason must mention unmerged commits'
            $deleteCalls = @($result.GitCalls | Where-Object { $_ -match "^branch-deleted\t.*$([regex]::Escape($branch))" })
            $deleteCalls.Count | Should -Be 0 -Because 'unmerged branch must NOT be deleted'
        }

        It 'TC-Orphan-3: emits no zero-count summary when OrphanBranches is empty' {
            $workDir = Join-Path $TestDrive 'orphan-empty'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit' = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@()
                SiblingWorktrees = [string[]]@()  # need at least something to pass guard
            }

            # When all params are empty arrays, guard should fire — but if only OrphanBranches
            # is empty and something else is provided, zero-count suppression applies
            # For this test, provide a token SiblingWorktrees that doesn't exist to isolate
            # the zero-count suppression behavior

            # Re-invoke with at least one non-empty array to bypass guard
            $result2 = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit' = 0
            } -ScriptParams @{
                IssueNumber    = 42
                OrphanBranches = [string[]]@()
                SkipGitUpdate  = $true
                SkipRemoteDelete = $true
                SkipLocalDelete  = $true
            }

            $result2.Output | Should -Not -Match 'Deleted 0 orphan' -Because 'zero-count summary lines must be suppressed when no orphans were processed'
        }
    }

    # =========================================================================
    # SiblingWorktrees tests
    # =========================================================================
    Context 'SiblingWorktrees — worktree and branch removal' {

        It 'TC-Sibling-1: removes a sibling worktree and its branch' {
            $workDir = Join-Path $TestDrive 'sibling-exists'
            $siblingPath = Join-Path $TestDrive 'sibling-exists-other'
            New-Item -ItemType Directory -Path $workDir, $siblingPath -Force | Out-Null
            $branch = 'pester-temp/issue-500-sibling-branch'
            $siblingFwdPath = $siblingPath -replace '\\', '/'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'               = 0
                "cherry-$branch"           = ''
                'worktree-remove-exit'     = 0
                'branch-d-exit'            = 0
                'path-configs'             = @{
                    $siblingFwdPath = @{ 'branch--show-current' = $branch }
                }
            } -ScriptParams @{
                SiblingWorktrees = [string[]]@($siblingFwdPath)
            }

            $result.ExitCode | Should -Be 0
            $worktreeRemovals = @($result.GitCalls | Where-Object { $_ -match 'worktree-removed' })
            $worktreeRemovals.Count | Should -BeGreaterThan 0 -Because 'git worktree remove must be called for sibling path'
        }

        It 'TC-Sibling-2: emits no zero-count summary when SiblingWorktrees is empty (with IssueNumber as guard-bypass)' {
            $workDir = Join-Path $TestDrive 'sibling-zero'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit' = 0
                'checkout-exit' = 0
                'pull-exit'     = 0
            } -ScriptParams @{
                IssueNumber      = 42
                SiblingWorktrees = [string[]]@()
                SkipGitUpdate    = $true
                SkipRemoteDelete = $true
                SkipLocalDelete  = $true
            }

            $result.Output | Should -Not -Match 'Deleted 0 sibling' -Because 'zero-count summary lines must be suppressed when no siblings were processed'
        }

        It 'TC-Sibling-3: uses gh pr list fallback when git cherry fails for sibling worktree branch' {
            $workDir = Join-Path $TestDrive 'sibling-gh-fallback'
            $siblingPath = Join-Path $TestDrive 'sibling-gh-fallback-other'
            New-Item -ItemType Directory -Path $workDir, $siblingPath -Force | Out-Null
            $branch = 'pester-temp/issue-500-sibling-gh-fallback'
            $siblingFwdPath = $siblingPath -replace '\\', '/'

            # git cherry fails (non-zero exit) -> should fall back to gh pr list
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'     = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                   = 0
                "cherry-exit-$branch"          = 1   # cherry fails
                'worktree-remove-exit'         = 0
                'branch-d-exit'                = 0
                'path-configs'                 = @{
                    $siblingFwdPath = @{ 'branch--show-current' = $branch }
                }
            } -GhConfig @{
                "pr-list-merged-$branch"  = '[{"number":123}]'  # merged PR exists
                'pr-list-default-exit'    = 0
            } -ScriptParams @{
                SiblingWorktrees = [string[]]@($siblingFwdPath)
            }

            $result.ExitCode | Should -Be 0
            $ghCalls = @($result.GhCalls | Where-Object { $_ -match '^pr\tlist' })
            $ghCalls.Count | Should -BeGreaterThan 0 -Because 'gh pr list must be called as fallback when git cherry fails'
        }
    }

    # =========================================================================
    # UntaggedTrackingFiles tests
    # =========================================================================
    Context 'UntaggedTrackingFiles — archive under unknown/ subfolder' {

        It 'TC-Untagged-1: archives an untagged tracking file with mtime suffix under unknown/ subfolder' {
            $workDir = Join-Path $TestDrive 'untagged-archive'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            # Create a tracking file without issue_id frontmatter
            $trackingDir = Join-Path $workDir '.copilot-tracking\research'
            New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
            $trackingFile = Join-Path $trackingDir 'unknown-tracking.md'
            Set-Content -Path $trackingFile -Value "# No issue_id header`nSome content" -Encoding UTF8

            $relTrackingPath = 'unknown-tracking.md'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'               = 0
            } -ScriptParams @{
                UntaggedTrackingFiles = [string[]]@('.copilot-tracking\research\unknown-tracking.md')
            }

            $result.ExitCode | Should -Be 0

            # File must appear under .copilot-tracking-archive/{year}/{month}/unknown/
            $archiveRoot = Join-Path $workDir '.copilot-tracking-archive'
            $archivedFiles = @(Get-ChildItem -Path $archiveRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'unknown' -and $_.Name -match 'unknown-tracking' })
            $archivedFiles.Count | Should -BeGreaterThan 0 -Because 'file must be archived under .copilot-tracking-archive/{yyyy}/{mm}/unknown/'

            # Check path structure
            $archivePath = $archivedFiles[0].DirectoryName -replace '\\', '/'
            $archivePath | Should -Match '/unknown$' -Because 'untagged files must land in the unknown/ subfolder'
        }

        It 'TC-Untagged-2: two files with same name and same mtime get distinct archive filenames (collision-safe)' {
            $workDir = Join-Path $TestDrive 'untagged-collision'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            # Create two tracking files with the same name in different subdirs
            $trackingDir1 = Join-Path $workDir '.copilot-tracking\research'
            $trackingDir2 = Join-Path $workDir '.copilot-tracking\planning'
            New-Item -ItemType Directory -Path $trackingDir1, $trackingDir2 -Force | Out-Null
            $file1 = Join-Path $trackingDir1 'issue-plan.md'
            $file2 = Join-Path $trackingDir2 'issue-plan.md'
            Set-Content -Path $file1 -Value '# No issue_id' -Encoding UTF8
            Set-Content -Path $file2 -Value '# No issue_id either' -Encoding UTF8

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'               = 0
            } -ScriptParams @{
                UntaggedTrackingFiles = [string[]]@(
                    '.copilot-tracking\research\issue-plan.md',
                    '.copilot-tracking\planning\issue-plan.md'
                )
            }

            $result.ExitCode | Should -Be 0

            # Both files must land as distinct filenames under the archive
            $archiveRoot = Join-Path $workDir '.copilot-tracking-archive'
            $archivedFiles = @(Get-ChildItem -Path $archiveRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'issue-plan' })
            $archivedFiles.Count | Should -Be 2 -Because 'both files must be archived even when they share a base name'

            # All archived filenames must be unique
            $uniqueNames = $archivedFiles | Select-Object -ExpandProperty Name | Sort-Object -Unique
            $uniqueNames.Count | Should -Be 2 -Because 'collision-safe naming must produce distinct filenames'
        }

        It 'TC-Untagged-3: emits no zero-count summary when UntaggedTrackingFiles is empty (with IssueNumber as guard-bypass)' {
            $workDir = Join-Path $TestDrive 'untagged-zero'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'     = 0
                'checkout-exit'  = 0
                'pull-exit'      = 0
            } -ScriptParams @{
                IssueNumber           = 42
                UntaggedTrackingFiles = [string[]]@()
                SkipGitUpdate         = $true
                SkipRemoteDelete      = $true
                SkipLocalDelete       = $true
            }

            $result.Output | Should -Not -Match 'Archived 0 untagged' -Because 'zero-count summary lines must be suppressed'
        }
    }

    # =========================================================================
    # git fetch fail-open
    # =========================================================================
    Context 'git fetch fail-open' {

        It 'TC-FetchFail-1: when fetch exits non-zero, emits warning and continues; merged orphan is still deleted' {
            $workDir = Join-Path $TestDrive 'fetch-fail-open'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-orphan-fetch-fail'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'               = 128   # fetch FAILS
                "cherry-$branch"           = ''    # branch is merged
                'branch-d-exit'            = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0 -Because 'fetch failure must be fail-open — script must not abort'
            $result.Output | Should -Match '(?i)(fetch.{0,30}fail|warn|stale|cached)' -Because 'fetch failure warning must be emitted'
            $deleteCalls = @($result.GitCalls | Where-Object { $_ -match "^branch-deleted\t.*$([regex]::Escape($branch))" })
            $deleteCalls.Count | Should -BeGreaterThan 0 -Because 'execution must continue and delete merged branch despite fetch failure'
        }
    }

    # =========================================================================
    # Squash-aware oracle (git cherry)
    # =========================================================================
    Context 'git cherry squash-aware oracle' {

        It 'TC-Cherry-1: empty stdout from git cherry means merged (uses -d not -D)' {
            $workDir = Join-Path $TestDrive 'cherry-merged'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-cherry-merged'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'               = 0
                "cherry-$branch"           = ''   # empty = merged
                'branch-d-exit'            = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0
            # Verify git branch -d was called (not --is-ancestor)
            $branchDeleteCalls = @($result.GitCalls | Where-Object { $_ -match "^branch-deleted\t" })
            $branchDeleteCalls.Count | Should -BeGreaterThan 0 -Because 'merged branch must be deleted'
            $ancestorCalls = @($result.GitCalls | Where-Object { $_ -match 'is-ancestor' })
            $ancestorCalls.Count | Should -Be 0 -Because 'must NEVER use --is-ancestor; use git cherry instead'
        }

        It 'TC-Cherry-2: when git cherry exits non-zero, falls back to gh pr list' {
            $workDir = Join-Path $TestDrive 'cherry-fallback-gh'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-cherry-gh-fallback'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                   = 0
                "cherry-exit-$branch"          = 128  # cherry fails
                'branch-d-exit'                = 0
            } -GhConfig @{
                "pr-list-merged-$branch" = '[{"number":42}]'
                'pr-list-default-exit'   = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0
            $ghCalls = @($result.GhCalls | Where-Object { $_ -match '^pr\tlist' })
            $ghCalls.Count | Should -BeGreaterThan 0 -Because 'gh pr list must be called when git cherry fails'
        }

        It 'TC-Cherry-3: when gh is unavailable, treats branch as unmerged (returns false for safety)' {
            $workDir = Join-Path $TestDrive 'cherry-gh-unavailable'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-cherry-gh-unavailable'

            # Cherry fails AND no gh mock → gh call will fail
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                   = 0
                "cherry-exit-$branch"          = 128  # cherry fails; gh not mocked -> unavailable
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            # Script must not crash, and branch must NOT be deleted (safety: treat as unmerged)
            $result.ExitCode | Should -Be 0 -Because 'script must fail-open when gh is unavailable'
            $deleteCalls = @($result.GitCalls | Where-Object { $_ -match "^branch-deleted\t.*$([regex]::Escape($branch))" })
            $deleteCalls.Count | Should -Be 0 -Because 'when gh is unavailable, branch must be treated as unmerged (safe default: do not delete)'
        }

        It 'TC-Cherry-OrgRef: git cherry is called with origin/<defaultBranch> as the base ref (not bare <defaultBranch>)' {
            # Regression test for M1: Test-BranchMergedIntoDefault must use origin/$DefaultBranch
            # so it compares against the fetched remote tip, not a potentially stale local ref.
            $workDir = Join-Path $TestDrive 'cherry-org-ref'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-cherry-org-ref'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'     = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                   = 0
                "cherry-$branch"               = ''   # empty = merged
                'branch-d-exit'                = 0
                'cherry-require-origin-prefix' = $true   # mock enforces origin/ prefix
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0 -Because 'script must succeed when git cherry is called with origin/<defaultBranch>'

            # Verify the logged cherry-called line uses origin/main as the base ref
            $cherryCalls = @($result.GitCalls | Where-Object { $_ -match "^cherry-called\t" })
            $cherryCalls.Count | Should -BeGreaterThan 0 -Because 'git cherry must have been called'
            $baseRefCall = $cherryCalls | Where-Object { $_ -match "^cherry-called\torigin/" } | Select-Object -First 1
            $baseRefCall | Should -Not -BeNullOrEmpty -Because "git cherry base ref must use origin/ prefix (M1 fix: compare against fetched remote tip, not stale local ref)"

            # Also confirm no error log entries (which the mock writes when origin/ prefix is missing)
            $errorCalls = @($result.GitCalls | Where-Object { $_ -match 'cherry-base-ref-error' })
            $errorCalls.Count | Should -Be 0 -Because 'mock must not have detected a missing origin/ prefix'
        }
    }

    # =========================================================================
    # Back-compat: existing -IssueNumber behavior preserved
    # =========================================================================
    Context 'Back-compat — IssueNumber behavior' {

        It 'TC-BackCompat-1: -IssueNumber 42 with no new params archives tracking files and deletes feature branch' {
            $workDir = Join-Path $TestDrive 'backcompat-issue42'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            # Create a tracking file for issue 42
            $trackingDir = Join-Path $workDir '.copilot-tracking\research'
            New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
            Set-Content -Path (Join-Path $trackingDir 'issue-42-plan.md') -Value @"
---
issue_id: "42"
title: "Issue 42 back-compat test"
---
# Test tracking file
"@ -Encoding UTF8

            $featureBranch = 'feature/issue-42-back-compat-test'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'           = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main'  = 0
                'checkout-exit'                      = 0
                'pull-exit'                          = 0
                'fetch-exit'                         = 0
                "ls-remote-$featureBranch"           = ''   # remote gone
                "branch-list-$featureBranch"         = "  $featureBranch"
                'branch--show-current'               = 'main'
                'branch-D-exit'                      = 0
            } -ScriptParams @{
                IssueNumber   = 42
                FeatureBranch = $featureBranch
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Archived 1 file' -Because 'back-compat: tracking file must be archived'
            $result.Output | Should -Match ([regex]::Escape($featureBranch)) -Because 'back-compat: feature branch must be mentioned in output'
            $result.Output | Should -Match 'Cleanup complete' -Because 'back-compat: completion message must appear'
        }
    }

    # =========================================================================
    # Combined-categories integration test (M7)
    # Verifies that -OrphanBranches, -SiblingWorktrees, AND -UntaggedTrackingFiles
    # all work correctly in a single invocation. M2 showed combined-category paths
    # need explicit coverage.
    # =========================================================================
    Describe 'TC-Combined-1: combined OrphanBranches + SiblingWorktrees + UntaggedTrackingFiles in one invocation' {

        BeforeAll {
            $script:CombinedWorkDir = Join-Path $TestDrive 'combined-categories'
            $script:CombinedSiblingDir = Join-Path $TestDrive 'combined-sibling'
            New-Item -ItemType Directory -Path $script:CombinedWorkDir, $script:CombinedSiblingDir -Force | Out-Null

            # Create untagged tracking file in the work dir
            $trackingDir = Join-Path $script:CombinedWorkDir '.copilot-tracking\misc'
            New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
            $script:CombinedTrackingFile = Join-Path $trackingDir 'combined-untagged.md'
            Set-Content -Path $script:CombinedTrackingFile -Value '# No issue_id frontmatter' -Encoding UTF8
        }

        It 'TC-Combined-1: all three categories succeed; orphan deleted, sibling removed, untagged archived; exit 0' {
            $orphanBranch = 'pester-temp/issue-500-combined-orphan'
            $siblingBranch = 'pester-temp/issue-500-combined-sibling-branch'
            $siblingFwdPath = $script:CombinedSiblingDir -replace '\\', '/'
            $relTrackingPath = '.copilot-tracking\misc\combined-untagged.md'

            $result = & $script:InvokeScript -WorkDir $script:CombinedWorkDir -GitConfig @{
                'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                "cherry-$orphanBranch"              = ''   # merged
                "cherry-$siblingBranch"             = ''   # merged
                'branch-d-exit'                     = 0
                'worktree-remove-exit'              = 0
                'path-configs'                      = @{
                    $siblingFwdPath = @{ 'branch--show-current' = $siblingBranch }
                }
            } -ScriptParams @{
                OrphanBranches        = [string[]]@($orphanBranch)
                SiblingWorktrees      = [string[]]@($siblingFwdPath)
                UntaggedTrackingFiles = [string[]]@($relTrackingPath)
            }

            # Exit code must be 0
            $result.ExitCode | Should -Be 0 -Because 'combined invocation must succeed'

            # Orphan branch deleted
            $result.Output | Should -Match 'Deleted 1 orphan branch' -Because 'orphan branch summary line must appear'

            # Sibling worktree removed
            $result.Output | Should -Match 'Deleted 1 sibling worktree' -Because 'sibling worktree summary line must appear'
            $worktreeRemovals = @($result.GitCalls | Where-Object { $_ -match 'worktree-removed' })
            $worktreeRemovals.Count | Should -BeGreaterThan 0 -Because 'git worktree remove must have been called'

            # Untagged tracking file archived
            $result.Output | Should -Match 'Archived 1 untagged file' -Because 'untagged archival summary line must appear'
            $archiveRoot = Join-Path $script:CombinedWorkDir '.copilot-tracking-archive'
            $archivedFiles = @(Get-ChildItem -Path $archiveRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'combined-untagged' })
            $archivedFiles.Count | Should -BeGreaterThan 0 -Because 'untagged tracking file must be archived to disk'

            # Original file must no longer exist at its source location
            Test-Path $script:CombinedTrackingFile | Should -Be $false -Because 'archived file must be moved out of .copilot-tracking/'
        }
    }
}
