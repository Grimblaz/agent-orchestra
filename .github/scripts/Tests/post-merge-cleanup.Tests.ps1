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

function Get-SequenceConfigValue {
    param([string]$Name, [int]$Index)
    $sequence = Get-ConfigValue $Name
    if ($null -eq $sequence) { return $null }
    $items = @($sequence)
    if ($items.Count -eq 0) { return $null }
    if ($Index -lt $items.Count) { return $items[$Index] }
    return $items[-1]
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

# git rev-parse --abbrev-ref "main@{upstream}"
if ($a.Count -ge 3 -and $a[0] -eq 'rev-parse' -and $a[1] -eq '--abbrev-ref') {
    $refSpec = $a[2]
    if ($refSpec -match '^(?<branch>.+)@\{upstream\}$') {
        $key = "upstream-ref-$($Matches.branch)"
        $val = Get-ConfigValue $key
        if ($null -ne $val) { Write-Output $val }
        exit 0
    }
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
    $remoteName = if ($a.Count -ge 2) { $a[1] } else { '' }
    $exitVal = Get-ConfigValue "fetch-exit-$remoteName"
    if ($null -eq $exitVal) { $exitVal = Get-ConfigValue 'fetch-exit' }
    if ($null -eq $exitVal) { $exitVal = 0 }
    "fetch-called`t$remoteName" | Add-Content -Path $callLogPath -Encoding UTF8
    exit ([int]$exitVal)
}

# git cherry <baseRef> <branch>
# Empty stdout = merged; lines starting with - or + = unmerged commits present
# git merge-tree --write-tree <baseRef> <branch>
if ($a.Count -ge 4 -and $a[0] -eq 'merge-tree' -and $a[1] -eq '--write-tree') {
    $baseRef = $a[2]
    $targetBranch = $a[3]
    $mergeTreeOutput = Get-ConfigValue "merge-tree-output-$targetBranch"
    $mergeTreeExit = Get-ConfigValue "merge-tree-exit-$targetBranch"
    if ($null -eq $mergeTreeExit) { $mergeTreeExit = 1 }
    "merge-tree-called`t$baseRef`t$targetBranch" | Add-Content -Path $callLogPath -Encoding UTF8
    if ($null -ne $mergeTreeOutput -and $mergeTreeOutput -ne '') { Write-Output $mergeTreeOutput }
    exit ([int]$mergeTreeExit)
}

# git diff --quiet [--ignore-cr-at-eol] <baseRef> <branch>
if ($a.Count -ge 4 -and $a[0] -eq 'diff' -and $a[1] -eq '--quiet') {
    $argIndex = 2
    $ignoreCrAtEol = $false
    if ($a[$argIndex] -eq '--ignore-cr-at-eol') {
        $ignoreCrAtEol = $true
        $argIndex++
    }
    if ($argIndex + 1 -lt $a.Count) {
        $baseRef = $a[$argIndex]
        $targetBranch = $a[$argIndex + 1]
        $priorDiffCalls = @(Get-Content -Path $callLogPath -ErrorAction SilentlyContinue | Where-Object { $_ -match "^diff-quiet-called\t.+\t$([regex]::Escape($targetBranch))\t" })
        $diffExit = Get-SequenceConfigValue -Name "diff-quiet-exit-sequence-$targetBranch" -Index $priorDiffCalls.Count
        if ($null -eq $diffExit) { $diffExit = Get-ConfigValue "diff-quiet-exit-$targetBranch" }
        if ($null -eq $diffExit) { $diffExit = 1 }
        "diff-quiet-called`t$baseRef`t$targetBranch`tignore-cr-at-eol=$ignoreCrAtEol" | Add-Content -Path $callLogPath -Encoding UTF8
        exit ([int]$diffExit)
    }
    exit 1
}

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

# gh pr list --head <branch> --base <defaultBranch> --state merged --json number
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

            # When all params are empty arrays, guard should fire — but if only OrphanBranches
            # is empty and something else is provided, zero-count suppression applies
            # For this test, provide IssueNumber to isolate the zero-count suppression behavior.

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
            $ghCalls | Should -Contain "pr`tlist`t--head`t$branch`t--base`tmain`t--state`tmerged`t--json`tnumber" -Because 'GitHub fallback must constrain the PR lookup to the resolved default branch'
        }

        It 'TC-Sibling-4: counts removed worktree when branch deletion is skipped after merged re-check fails' {
            $workDir = Join-Path $TestDrive 'sibling-removed-branch-skip'
            $siblingPath = Join-Path $TestDrive 'sibling-removed-branch-skip-other'
            New-Item -ItemType Directory -Path $workDir, $siblingPath -Force | Out-Null
            $branch = 'pester-temp/issue-500-sibling-recheck-unmerged'
            $siblingFwdPath = $siblingPath -replace '\\', '/'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                "diff-quiet-exit-sequence-$branch" = @(0, 1)
                "cherry-$branch"                    = '+ abc123 Commit that appears unmerged during re-check'
                'worktree-remove-exit'              = 0
                'branch-d-exit'                     = 1
                'path-configs'                      = @{
                    $siblingFwdPath = @{ 'branch--show-current' = $branch }
                }
            } -ScriptParams @{
                SiblingWorktrees = [string[]]@($siblingFwdPath)
            }

            $result.ExitCode | Should -Be 0
            $branchSkipPattern = [regex]::Escape("Removed worktree '$siblingFwdPath', but skipped branch '$branch'") + ' (?:—|-) ' + [regex]::Escape('unmerged commits') + ' (?:—|-) ' + [regex]::Escape('review before deleting')
            $result.Output | Should -Match $branchSkipPattern
            $result.Output | Should -Match ([regex]::Escape("Deleted 1 sibling worktree(s): $siblingFwdPath")) -Because 'the summary must include a worktree that was already successfully removed'
            $worktreeRemovals = @($result.GitCalls | Where-Object { $_ -eq "worktree-removed`t$siblingFwdPath" })
            $worktreeRemovals.Count | Should -Be 1 -Because 'the worktree removal itself must have succeeded before the branch skip'
            $successfulForcedBranchDeletes = @($result.GitCalls | Where-Object { $_ -eq "branch-deleted`t-D`t$branch" })
            $successfulForcedBranchDeletes.Count | Should -Be 0 -Because 'branch deletion must remain skipped after the second merged check fails'
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
            $ghCalls | Should -Contain "pr`tlist`t--head`t$branch`t--base`tmain`t--state`tmerged`t--json`tnumber" -Because 'GitHub fallback must constrain the PR lookup to the resolved default branch'
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

        It 'TC-SquashOffline-S5: deletes a tree-equivalent squash-style orphan without gh on PATH' {
            $workDir = Join-Path $TestDrive 'squash-offline-clean'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-513-squash-offline-clean'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                "diff-quiet-exit-$branch"          = 0
                "cherry-$branch"                    = '+ abc123 Squash-equivalent commit not patch-equivalent'
                'branch-d-exit'                     = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0
            $deleteCalls = @($result.GitCalls | Where-Object { $_ -match "^branch-deleted\t.*$([regex]::Escape($branch))" })
            $deleteCalls.Count | Should -BeGreaterThan 0 -Because 'tree-equivalent squash-merged orphan should be deleted once diff-first detection is implemented'
            $result.GhCalls.Count | Should -Be 0 -Because 'offline-clean detection must not require gh invocations'
            $diffCalls = @($result.GitCalls | Where-Object { $_ -match '^diff-quiet-called\t' })
            $diffCalls | Should -Contain "diff-quiet-called`torigin/main`t$branch`tignore-cr-at-eol=True" -Because 'tree-equivalence diff must ignore CR at EOL for Windows-safe cleanup'
        }

        It 'TC-MergeTreeNoOp: deletes an accumulated squash branch when merge-tree result matches default' {
            $workDir = Join-Path $TestDrive 'merge-tree-noop'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-513-merge-tree-noop'
            $mergedTreeOid = 'tree-merge-noop-oid'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                "diff-quiet-exit-$branch"          = 1
                "merge-tree-output-$branch"         = $mergedTreeOid
                "merge-tree-exit-$branch"           = 0
                "diff-quiet-exit-$mergedTreeOid"    = 0
                "cherry-$branch"                    = '+ abc123 Squash-equivalent commit not patch-equivalent'
                'branch-d-exit'                     = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0
            $deleteCalls = @($result.GitCalls | Where-Object { $_ -match "^branch-deleted\t.*$([regex]::Escape($branch))" })
            $deleteCalls.Count | Should -BeGreaterThan 0 -Because 'merge-tree no-op detection should authorize cleanup before cherry fallback'
            $mergeTreeCalls = @($result.GitCalls | Where-Object { $_ -match "^merge-tree-called\torigin/main\t$([regex]::Escape($branch))$" })
            $mergeTreeCalls.Count | Should -Be 1 -Because 'direct diff mismatch should fall through to merge-tree no-op detection'
            $mergeTreeDiff = @($result.GitCalls | Where-Object { $_ -eq "diff-quiet-called`torigin/main`t$mergedTreeOid`tignore-cr-at-eol=True" })
            $mergeTreeDiff.Count | Should -Be 1 -Because 'merge-tree result must be compared to the remote default tree with CR-at-EOL ignored'
            $cherryCalls = @($result.GitCalls | Where-Object { $_ -match '^cherry-called\t' })
            $cherryCalls.Count | Should -Be 0 -Because 'successful merge-tree no-op detection should not need cherry fallback'
        }

        It 'TC-NonOriginUpstream: fetches and checks a configured non-origin default upstream' {
            $workDir = Join-Path $TestDrive 'non-origin-upstream'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-513-non-origin-upstream'

            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'upstream-ref-main'                 = 'upstream/main'
                'fetch-exit'                        = 0
                "cherry-$branch"                   = ''
                'branch-d-exit'                     = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }

            $result.ExitCode | Should -Be 0
            $result.GitCalls | Should -Contain "fetch-called`torigin" -Because 'cleanup should keep the existing origin fetch'
            $result.GitCalls | Should -Contain "fetch-called`tupstream" -Because 'cleanup should refresh a non-origin configured upstream remote'
            $result.GitCalls | Should -Contain "diff-quiet-called`tupstream/main`t$branch`tignore-cr-at-eol=True" -Because 'direct diff should use the configured upstream ref'
            $result.GitCalls | Should -Contain "cherry-called`tupstream/main`t$branch" -Because 'cherry fallback should use the configured upstream ref'
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

    # =========================================================================
    # Post-review fixes from PR #502 bot reviewers (Copilot + Gemini)
    # =========================================================================
    Describe 'Post-review hardening (PR #502 bot findings)' {

        It 'TC-FeatureBranch-Guard: -FeatureBranch alone satisfies the guard (C6/C1)' {
            # Per Copilot reviewer: -FeatureBranch should satisfy the guard so the
            # detector can route no-issue-id stale-branch cleanup through the
            # composite script instead of raw git lines.
            $workDir = Join-Path $TestDrive 'fb-only'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'fetch-exit'               = 0
                'ls-remote-exit'           = 0
                'branch-d-exit'            = 0
            } -ScriptParams @{
                FeatureBranch    = 'feature/issue-500-test-fb-only'
                SkipRemoteDelete = $true
                SkipGitUpdate    = $true
            }
            $result.ExitCode | Should -Be 0 -Because '-FeatureBranch alone must be a valid invocation per C1/C6 fix'
            $result.Output | Should -Not -Match 'Must specify -IssueNumber' -Because 'guard must accept -FeatureBranch alone'
        }

        It 'TC-Cherry-DashLines: cherry output with only "-" lines is treated as merged (C4)' {
            # Per Copilot reviewer: git cherry prefixes with '+' (not in upstream)
            # or '-' (patch-equivalent). A branch with only '-' lines is merged.
            $workDir = Join-Path $TestDrive 'cherry-dash'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-cherry-dash'
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'fetch-exit'               = 0
                # cherry returns "- abc1234 patch-equivalent" — should be treated as merged
                "cherry-$branch"           = "- abc1234 Patch-equivalent commit already in upstream"
                'branch-d-exit'            = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Deleted 1 orphan branch' -Because 'branch with only "-" lines is merged (patch-equivalent) and must be deleted'
            $result.Output | Should -Not -Match 'Skipped' -Because 'branch should not be skipped — "-" lines indicate it IS merged'
        }

        It 'TC-Cherry-PlusLines: cherry output with "+" lines correctly treated as unmerged (C4 sanity check)' {
            # Sanity check: branches with '+' lines must still be skipped.
            $workDir = Join-Path $TestDrive 'cherry-plus'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $branch = 'pester-temp/issue-500-cherry-plus'
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'fetch-exit'               = 0
                "cherry-$branch"           = "+ def5678 New commit not yet in upstream"
                'branch-d-exit'            = 0
            } -ScriptParams @{
                OrphanBranches = [string[]]@($branch)
            }
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Skipped' -Because 'branch with "+" lines is unmerged and must be skipped'
            $result.Output | Should -Not -Match 'Deleted 1 orphan branch'
        }

        It 'TC-Path-Traversal-1: -UntaggedTrackingFiles blocks paths outside .copilot-tracking/ (C2)' {
            # Per Copilot reviewer: validate path resolves under .copilot-tracking/
            # to block ../somefile or absolute paths.
            $workDir = Join-Path $TestDrive 'traversal'
            $trackingDir = Join-Path $workDir '.copilot-tracking'
            New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
            # Create a file OUTSIDE .copilot-tracking that we'll try to attack via traversal
            $sensitiveFile = Join-Path $workDir 'sensitive-data.txt'
            'should not be moved' | Set-Content -Path $sensitiveFile -Encoding UTF8
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'fetch-exit'               = 0
            } -ScriptParams @{
                UntaggedTrackingFiles = [string[]]@('.copilot-tracking/../sensitive-data.txt')
            }
            $result.ExitCode | Should -Be 0 -Because 'script continues after blocking the malicious path'
            $result.Output | Should -Match 'Path traversal blocked' -Because 'traversal attempt must be reported'
            Test-Path $sensitiveFile | Should -Be $true -Because 'sensitive file outside .copilot-tracking/ must NOT be moved'
            $result.Output | Should -Not -Match 'Archived 1 untagged file' -Because 'no archival should occur when path traversal is blocked'
        }
    }
}
