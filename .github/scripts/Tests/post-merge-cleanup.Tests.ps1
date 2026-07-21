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
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/post-merge-cleanup.ps1'
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

# git worktree list --porcelain (Issue #889 s3: Test-WorktreeIsPrimary + locked/prunable scan)
if ($a.Count -ge 2 -and $a[0] -eq 'worktree' -and $a[1] -eq 'list') {
    $val = Get-ConfigValue 'worktree-list-porcelain'
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 0
}

# git rev-list <base>..<branch> --count (Issue #889 s1 rung 1 — Test-WorktreeBranchRemovalEligible)
if ($a.Count -ge 3 -and $a[0] -eq 'rev-list' -and $a[-1] -eq '--count') {
    $spec = $a[1]
    $branchPart = ($spec -split '\.\.')[-1]
    $key = "rev-list-count-$branchPart"
    $val = Get-ConfigValue $key
    # Default to '1' so existing cherry/diff/merge-tree-based fixtures keep routing through
    # rung 2 (tree-equivalence) without needing to add this key everywhere (backward-compat).
    if ($null -eq $val) { $val = '1' }
    Write-Output $val
    exit 0
}

# git rev-parse <branch> (bare positional form — OID lookup for Get-SCDMergedPrByHeadOid)
if ($a.Count -eq 2 -and $a[0] -eq 'rev-parse' -and $a[1] -notlike '--*') {
    $branchArg = $a[1]
    $val = Get-ConfigValue "rev-parse-$branchArg"
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 0
}

# git status --porcelain (supports -C path via $gitWorkDir — Test-WorktreeRemovalPreflight dirty check)
if ($a.Count -ge 2 -and $a[0] -eq 'status' -and $a[1] -eq '--porcelain') {
    $val = Get-PathConfigValue -Name 'status-porcelain-output' -Path $gitWorkDir
    $exitVal = Get-PathConfigValue -Name 'status-porcelain-exit' -Path $gitWorkDir
    if ($null -eq $exitVal) { $exitVal = 0 }
    if ($null -ne $val) { Write-Output $val }
    exit ([int]$exitVal)
}

# git worktree remove [--force] <path>
if ($a.Count -ge 3 -and $a[0] -eq 'worktree' -and $a[1] -eq 'remove') {
    $path = $a[-1]
    $key = "worktree-remove-exit-$path"
    $exitVal = Get-ConfigValue $key
    if ($null -eq $exitVal) { $exitVal = Get-ConfigValue 'worktree-remove-exit' }
    if ($null -eq $exitVal) { $exitVal = 0 }
    "worktree-removed`t$path" | Add-Content -Path $callLogPath -Encoding UTF8
    if ([int]$exitVal -eq 0) {
        # Mirror real git's filesystem side effect so the s3 post-attempt honesty
        # probes (Test-Path/Get-ChildItem) observe an actually-removed directory,
        # unless the fixture explicitly opts out to model a partial-removal residue.
        $leaveResidue = Get-ConfigValue "worktree-remove-leave-residue-$path"
        if (-not $leaveResidue) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    exit ([int]$exitVal)
}

# git worktree remove <path> (2-arg form)
if ($a.Count -ge 2 -and $a[0] -eq 'worktree' -and $a[1] -eq 'remove') {
    $path = $a[2]
    $exitVal = Get-ConfigValue 'worktree-remove-exit'
    if ($null -eq $exitVal) { $exitVal = 0 }
    "worktree-removed`t$path" | Add-Content -Path $callLogPath -Encoding UTF8
    if ([int]$exitVal -eq 0) {
        $leaveResidue = Get-ConfigValue "worktree-remove-leave-residue-$path"
        if (-not $leaveResidue) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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
        # ---------------------------------------------------------------------------
        # Porcelain-fixture helper (Issue #889 s3) — Test-WorktreeIsPrimary fails
        # SAFE (treats an unparseable/empty listing as primary) so every sibling-
        # worktree fixture must supply a 'worktree-list-porcelain' value whose FIRST
        # record is $WorkDir (the primary) — otherwise the fail-safe default refuses
        # the sibling as "primary". Deliberately omits a sibling record: the mock's
        # `git worktree list --porcelain` handler returns a STATIC configured value
        # (it has no dynamic deregistration side effect for a successful `git
        # worktree remove`), so a normal/healthy removal fixture that wants the
        # honest 'removed' outcome (not 'stale-registration') must NOT pre-register
        # the sibling here — Test-WorktreeIsPrimary only needs the FIRST record to
        # prove non-primary. Fixtures that specifically test the locked/prunable
        # dispatch build their OWN porcelain text inline with the sibling included.
        # ---------------------------------------------------------------------------
        $script:NewPrimaryPorcelain = {
            param([string]$WorkDir)
            $workFwd = $WorkDir -replace '\\', '/'
            return @"
worktree $workFwd
HEAD 0000000000000000000000000000000000000000
branch refs/heads/main
"@
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

# gh issue view <id> --repo <repo> --json state (Issue #889 s1 rung 3 — Get-SCDIssueState)
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
                'worktree-list-porcelain'  = (& $script:NewPrimaryPorcelain -WorkDir $workDir)
                "rev-list-count-$branch"   = '2'
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

        It 'TC-Sibling-3: uses the OID-checked gh pr list fallback when git cherry fails for sibling worktree branch' {
            # Issue #889 s3: the initial eligibility check now runs through the shared
            # Test-WorktreeBranchRemovalEligible primitive, whose gh fallback
            # (Get-SCDMergedPrByHeadOid) requests headRefOid and matches it against the
            # branch tip — replacing the old name-only `--json number` fallback.
            $workDir = Join-Path $TestDrive 'sibling-gh-fallback'
            $siblingPath = Join-Path $TestDrive 'sibling-gh-fallback-other'
            New-Item -ItemType Directory -Path $workDir, $siblingPath -Force | Out-Null
            $branch = 'pester-temp/issue-500-sibling-gh-fallback'
            $siblingFwdPath = $siblingPath -replace '\\', '/'
            $branchTip = 'abc123sha-tip'

            # git cherry fails (non-zero exit) -> should fall back to gh pr list
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'     = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                   = 0
                'worktree-list-porcelain'      = (& $script:NewPrimaryPorcelain -WorkDir $workDir)
                "rev-list-count-$branch"       = '2'
                "diff-quiet-exit-$branch"      = 1   # not tree-equivalent
                "merge-tree-exit-$branch"      = 1   # merge-tree no-op detection fails
                "cherry-exit-$branch"          = 1   # cherry fails -> inconclusive
                "rev-parse-$branch"            = $branchTip
                'worktree-remove-exit'         = 0
                'branch-d-exit'                = 0
                'path-configs'                 = @{
                    $siblingFwdPath = @{ 'branch--show-current' = $branch }
                }
            } -GhConfig @{
                "pr-list-merged-$branch"  = "[{`"number`":123,`"headRefOid`":`"$branchTip`"}]"  # merged PR exists, OID matches tip
                'pr-list-default-exit'    = 0
            } -ScriptParams @{
                SiblingWorktrees = [string[]]@($siblingFwdPath)
            }

            $result.ExitCode | Should -Be 0
            $ghCalls = @($result.GhCalls | Where-Object { $_ -match '^pr\tlist' })
            $ghCalls.Count | Should -BeGreaterThan 0 -Because 'gh pr list must be called as fallback when git cherry fails'
            $ghCalls | Should -Contain "pr`tlist`t--head`t$branch`t--base`tmain`t--state`tmerged`t--json`tnumber,headRefOid" -Because 'the OID-checked fallback must request headRefOid, not a name-only lookup'
            $result.Output | Should -Match ([regex]::Escape('eligible: PR #123 merged')) -Because 'an OID-matched merged PR must be named as the eligibility evidence'
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
                'worktree-list-porcelain'           = (& $script:NewPrimaryPorcelain -WorkDir $workDir)
                "rev-list-count-$branch"            = '2'
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
            $trackingDir = Join-Path $workDir '.copilot-tracking/research'
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
            $trackingDir1 = Join-Path $workDir '.copilot-tracking/research'
            $trackingDir2 = Join-Path $workDir '.copilot-tracking/planning'
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

        It 'TC-Cherry-OrgRef: git cherry is called with the origin/ prefixed default-branch ref as the base ref (not the bare default-branch name)' {
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
            $trackingDir = Join-Path $workDir '.copilot-tracking/research'
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
            $trackingDir = Join-Path $script:CombinedWorkDir '.copilot-tracking/misc'
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
                'worktree-list-porcelain'           = (& $script:NewPrimaryPorcelain -WorkDir $script:CombinedWorkDir)
                "rev-list-count-$orphanBranch"      = '2'
                "rev-list-count-$siblingBranch"     = '2'
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

    # =========================================================================
    # Remove-IssueTmpScratch — per-issue .tmp/ disk clearing (Issue #643)
    # RED-phase tests: Remove-IssueTmpScratch and the -TmpRoot / -IssueScratch
    # parameters do not yet exist in post-merge-cleanup.ps1. All tests here
    # FAIL because either (a) the script rejects the unknown parameter with a
    # non-zero exit and ExitCode-based assertions fire, or (b) the script
    # exits 0 but the expected .tmp/-clearing output / file-removal side effects
    # are absent.
    # =========================================================================
    Describe 'Remove-IssueTmpScratch — per-issue .tmp/ disk clearing' {

        It 'TC-TmpScratch-1: removes .tmp/ scratch files for a closed/merged issue (N-N prefix)' {
            # Arrange
            $workDir = Join-Path $TestDrive 'tmp-scratch-remove'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $tmpDir = Join-Path $workDir '.tmp'
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            Set-Content -Path (Join-Path $tmpDir '643-body.md')        -Value 'body content'   -Encoding UTF8
            Set-Content -Path (Join-Path $tmpDir '643-engagement.md')  -Value 'engagement'     -Encoding UTF8
            Set-Content -Path (Join-Path $tmpDir '643-credit-input.md') -Value 'credit'        -Encoding UTF8

            # Act: pass -TmpRoot (new parameter — does not exist yet; script rejects it)
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit' = 0
            } -ScriptParams @{
                IssueNumber   = 643
                TmpRoot       = '.tmp'
                SkipGitUpdate    = $true
                SkipRemoteDelete = $true
                SkipLocalDelete  = $true
            }

            # Assert: script must succeed and scratch files must be gone
            # RED: script fails (non-zero) because -TmpRoot is an unknown parameter,
            # OR exits 0 but the files are still present because no clearing logic exists.
            $result.ExitCode | Should -Be 0 -Because 'Remove-IssueTmpScratch must succeed after clearing scratch files'
            Test-Path (Join-Path $tmpDir '643-body.md')       | Should -Be $false -Because '.tmp/643-* files must be removed for issue 643'
            Test-Path (Join-Path $tmpDir '643-engagement.md') | Should -Be $false -Because '.tmp/643-* files must be removed for issue 643'
        }

        It 'TC-TmpScratch-2: preserves .tmp/ scratch for open/in-flight issues when clearing issue 643' {
            # Arrange
            $workDir = Join-Path $TestDrive 'tmp-scratch-preserve'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $tmpDir = Join-Path $workDir '.tmp'
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            # Issue 643 files to be removed
            Set-Content -Path (Join-Path $tmpDir '643-body.md') -Value 'done' -Encoding UTF8
            # Issue 999 files — in-flight, must be preserved
            Set-Content -Path (Join-Path $tmpDir '999-body.md')       -Value 'in-flight' -Encoding UTF8
            Set-Content -Path (Join-Path $tmpDir '999-engagement.md') -Value 'in-flight' -Encoding UTF8
            # Issue 6431 files — numeric superset of 643; must survive clearing 643
            New-Item -ItemType File -Path (Join-Path $tmpDir '6431-body.md') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $tmpDir 'issue-6431-notes.txt') -Force | Out-Null

            # Act
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit' = 0
            } -ScriptParams @{
                IssueNumber      = 643
                TmpRoot          = '.tmp'
                SkipGitUpdate    = $true
                SkipRemoteDelete = $true
                SkipLocalDelete  = $true
            }

            # Assert
            # RED: script fails on unknown -TmpRoot param, so ExitCode != 0 and file assertions fire.
            $result.ExitCode | Should -Be 0 -Because 'clearing issue 643 scratch must not fail'
            Test-Path (Join-Path $tmpDir '999-body.md')       | Should -Be $true  -Because 'issue 999 is in-flight; its .tmp/ files must be preserved'
            Test-Path (Join-Path $tmpDir '999-engagement.md') | Should -Be $true  -Because 'issue 999 is in-flight; its .tmp/ files must be preserved'
            Test-Path (Join-Path $tmpDir '643-body.md')       | Should -Be $false -Because 'issue 643 is closed; its .tmp/ files must be removed'
            # Superset fixture: issue 6431 scratch must survive
            Test-Path (Join-Path $tmpDir '6431-body.md')          | Should -BeTrue  -Because '6431-body.md is a different issue'
            Test-Path (Join-Path $tmpDir 'issue-6431-notes.txt')  | Should -BeTrue  -Because 'issue-6431-notes.txt is a different issue'
        }

        It 'TC-TmpScratch-3: clears scratch for an issue with issue-N prefix naming (.tmp/issue-643-*)' {
            # Arrange: the alternate naming convention used by some agents
            $workDir = Join-Path $TestDrive 'tmp-scratch-issue-prefix'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $tmpDir = Join-Path $workDir '.tmp'
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            Set-Content -Path (Join-Path $tmpDir 'issue-643-comments.txt')    -Value 'comments' -Encoding UTF8
            Set-Content -Path (Join-Path $tmpDir 'issue-643-utf8.md')         -Value 'utf8 body' -Encoding UTF8
            # Unrelated file (different issue prefix) — must survive
            Set-Content -Path (Join-Path $tmpDir 'issue-610.md')              -Value 'other issue' -Encoding UTF8

            # Act
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit' = 0
            } -ScriptParams @{
                IssueNumber      = 643
                TmpRoot          = '.tmp'
                SkipGitUpdate    = $true
                SkipRemoteDelete = $true
                SkipLocalDelete  = $true
            }

            # Assert
            # RED: -TmpRoot unknown → non-zero exit, file presence assertions also fail.
            $result.ExitCode | Should -Be 0 -Because 'clearing issue-N-prefixed scratch files must succeed'
            Test-Path (Join-Path $tmpDir 'issue-643-comments.txt') | Should -Be $false -Because '.tmp/issue-643-* files must be removed'
            Test-Path (Join-Path $tmpDir 'issue-643-utf8.md')      | Should -Be $false -Because '.tmp/issue-643-* files must be removed'
            Test-Path (Join-Path $tmpDir 'issue-610.md')           | Should -Be $true  -Because '.tmp/issue-610.md belongs to a different issue and must not be removed'
        }

        It 'TC-TmpScratch-4: Remove-IssueTmpScratch output appears after orphan-branch output (call-order observable)' {
            # Arrange: set up both an orphan branch AND a .tmp/ scratch file for the same issue
            $workDir = Join-Path $TestDrive 'tmp-scratch-call-order'
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            $tmpDir = Join-Path $workDir '.tmp'
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            Set-Content -Path (Join-Path $tmpDir '643-body.md') -Value 'body' -Encoding UTF8
            $orphanBranch = 'pester-temp/issue-643-scratch-call-order'

            # Act
            $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
                'symbolic-ref-origin-HEAD'         = 'refs/remotes/origin/main'
                'show-ref-refs/remotes/origin/main' = 0
                'fetch-exit'                        = 0
                "cherry-$orphanBranch"              = ''   # merged
                'branch-d-exit'                     = 0
            } -ScriptParams @{
                IssueNumber    = 643
                TmpRoot        = '.tmp'
                OrphanBranches = [string[]]@($orphanBranch)
                SkipGitUpdate    = $true
                SkipRemoteDelete = $true
                SkipLocalDelete  = $true
            }

            # Assert: output ordering — orphan deletion line appears before .tmp/ clearing line.
            # RED: script fails on unknown -TmpRoot, so ExitCode != 0 and line-order assertion fires.
            $result.ExitCode | Should -Be 0 -Because 'combined orphan + tmp-scratch invocation must exit 0'

            # Verify both output lines are present
            $result.Output | Should -Match 'Deleted 1 orphan branch'        -Because 'orphan deletion summary must appear'
            $result.Output | Should -Match '(?i)(tmp.*scratch|scratch.*643|removed.*\.tmp|cleared.*643)' `
                -Because 'Remove-IssueTmpScratch must emit a summary line for the cleared .tmp/ files'

            # Verify the ordering: the orphan-branch summary line's index in the output
            # must be strictly less than the tmp-scratch summary line's index.
            $outputLines = $result.Output -split "`r?`n"
            $orphanLineIdx = ($outputLines | Select-String -Pattern 'Deleted \d+ orphan branch' |
                Select-Object -First 1).LineNumber
            $scratchLineIdx = ($outputLines | Select-String -Pattern '(?i)(tmp.*scratch|scratch.*643|removed.*\.tmp|cleared.*643)' |
                Select-Object -First 1).LineNumber

            $orphanLineIdx  | Should -Not -BeNullOrEmpty -Because 'orphan summary line must be present to test ordering'
            $scratchLineIdx | Should -Not -BeNullOrEmpty -Because 'tmp-scratch summary line must be present to test ordering'
            $orphanLineIdx  | Should -BeLessThan $scratchLineIdx -Because 'orphan-branch cleanup must complete before .tmp/ scratch clearing'
        }
    }
}

Describe 'post-merge-cleanup.ps1 — persistent root-level file exclusion (#656)' {

    BeforeAll {
        # Initialize the variables this Describe needs so it can run in isolation
        # (e.g. if extracted to a separate file). In normal full-file runs these are
        # also set by the first Describe's BeforeAll (Describe-scoped, not script-scoped).
        # NOTE: $script:InvokeScript and its mock-factory dependencies ($script:NewMockGitDir,
        # $script:AddMockGh, $script:SavedPath) are NOT reproduced here — the AC4 tests
        # (AC4-UntaggedRoute, AC4-IssueNumberRoute) require the full mock infrastructure
        # from the first Describe's BeforeAll to run. AC6-Executor is fully self-contained.
        if (-not $script:RepoRoot) {
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        }
        if (-not $script:ScriptFile) {
            $script:ScriptFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/post-merge-cleanup.ps1'
        }
    }

    It 'AC4-UntaggedRoute: registry-protected file in -UntaggedTrackingFiles is skipped, not archived' {
        $workDir = Join-Path $TestDrive 'persistent-untagged-skip'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        # Create a registry-named file at tracking root
        $trackingDir = Join-Path $workDir '.copilot-tracking'
        New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
        $registryFile = Join-Path $trackingDir 'gate-events.jsonl'
        Set-Content -Path $registryFile -Value '{"window_position":"pre-ask"}' -Encoding UTF8

        $relPath = '.copilot-tracking\gate-events.jsonl'

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
        } -ScriptParams @{
            UntaggedTrackingFiles = [string[]]@($relPath)
            SkipGitUpdate         = $true
            SkipRemoteDelete      = $true
        }

        $result.ExitCode | Should -Be 0 -Because 'script must succeed even when only registry files are passed'
        $result.Output   | Should -Match 'registry-protected' -Because 'a warning about the skipped registry file must appear'
        # File must still exist (not moved to archive)
        Test-Path $registryFile | Should -Be $true -Because 'persistent tracking file must not be archived'
        # No archive directory must have been created for it
        $archiveDir = Join-Path $workDir '.copilot-tracking-archive'
        $archivedCopies = @(Get-ChildItem -Path $archiveDir -Recurse -Filter 'gate-events*' -ErrorAction SilentlyContinue)
        $archivedCopies.Count | Should -Be 0 -Because 'gate-events.jsonl must not be archived'
    }

    It 'AC4-IssueNumberRoute: registry-protected file with issue_id frontmatter is skipped on -IssueNumber route' {
        $workDir = Join-Path $TestDrive 'persistent-issueroute-skip'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        $trackingDir = Join-Path $workDir '.copilot-tracking'
        New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null

        # Registry-named file that also happens to carry issue_id frontmatter (hypothetical future scenario)
        # The registry guard must fire BEFORE the issue_id filter
        $registryFile = Join-Path $trackingDir 'gate-events.jsonl'
        Set-Content -Path $registryFile -Value "issue_id: '999'`n{`"window_position`":`"pre-ask`"}" -Encoding UTF8

        # Legitimate issue-scoped file that should still be archived normally
        $issueFile = Join-Path $trackingDir 'issue-999-research.md'
        Set-Content -Path $issueFile -Value "---`nissue_id: '999'`ntitle: test`n---`n# research" -Encoding UTF8

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
        } -ScriptParams @{
            IssueNumber      = 999
            SkipGitUpdate    = $true
            SkipRemoteDelete = $true
            SkipLocalDelete  = $true
        }

        $result.ExitCode  | Should -Be 0 -Because 'script must succeed'
        $result.Output    | Should -Match 'registry-protected' -Because 'skip warning must appear for gate-events.jsonl'
        # Registry file must still exist at its original location
        Test-Path $registryFile | Should -Be $true -Because 'gate-events.jsonl must not be archived even with matching issue_id'
        # The legitimate issue file must have been archived
        $archiveDir = Join-Path $workDir '.copilot-tracking-archive'
        $archivedIssueFiles = @(Get-ChildItem -Path $archiveDir -Recurse -Filter 'issue-999-research*' -ErrorAction SilentlyContinue)
        $archivedIssueFiles.Count | Should -BeGreaterThan 0 -Because 'the legitimate issue-scoped file must still be archived'
    }

    It 'AC6-Executor: undefined accessor causes executor to halt with exit 1 before any archival' {
        $workDir = Join-Path $TestDrive 'persistent-executor-failsafe'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null

        # Create a registry file that would be archived if the guard did not fire
        $trackingDir = Join-Path $workDir '.copilot-tracking'
        New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
        $registryFile = Join-Path $trackingDir 'gate-events.jsonl'
        Set-Content -Path $registryFile -Value '{"window_position":"pre-ask"}' -Encoding UTF8

        # Strategy: produce a helpers stub that loads cleanly but does NOT define
        # Get-SCDPersistentTrackingExclusions. The script's failsafe guard fires because
        # the function is absent even though the dot-source itself succeeded.
        $helpersStubPath = Join-Path $TestDrive 'helpers-stub-no-accessor.ps1'
        Set-Content -Path $helpersStubPath -Value '# stub — accessor intentionally omitted to trigger failsafe' -Encoding UTF8

        $scriptContent = Get-Content -Path $script:ScriptFile -Raw -ErrorAction Stop
        $stubScriptPath = $helpersStubPath -replace '\\', '/'
        $patchedScript = $scriptContent -replace [regex]::Escape('. "$PSScriptRoot/session-startup-git-helpers.ps1"'), ('. "' + $stubScriptPath + '"')
        $patchedScriptPath = Join-Path $TestDrive 'patched-post-merge-cleanup.ps1'
        Set-Content -Path $patchedScriptPath -Value $patchedScript -Encoding UTF8

        $output = & pwsh -NoProfile -NonInteractive -File $patchedScriptPath `
            -UntaggedTrackingFiles @('.copilot-tracking\gate-events.jsonl') `
            -SkipGitUpdate `
            -SkipRemoteDelete 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode  | Should -Be 1 -Because 'undefined accessor must cause exit 1'
        ($output -join "`n") | Should -Match 'HALT' -Because 'a loud HALT message must appear in stderr/output'
        # File must NOT be archived — no archival must occur when the accessor fails to load
        Test-Path $registryFile | Should -Be $true -Because 'no archival must occur when the accessor fails to load'
    }
}

Describe 'post-merge-cleanup.ps1 — executor re-verify + honest reporting + #522 (Issue #889 s3)' {

    BeforeAll {
        # Reuses $script:InvokeScript and its mock-factory dependencies from the
        # first Describe's BeforeAll (script-scoped) — same pattern as the AC4/AC6
        # block above; these tests must run as part of the full-file suite.
        if (-not $script:RepoRoot) {
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        }
        if (-not $script:ScriptFile) {
            $script:ScriptFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/post-merge-cleanup.ps1'
        }
    }

    It 'S3-Primary: primary worktree passed via -SiblingWorktrees is refused without any destructive call attempted' {
        # Literal regression test for the 2026-07-20 incident: the primary checkout
        # must never reach eligibility/preflight logic, let alone a destructive call.
        $workDir = Join-Path $TestDrive 's3-primary-refused'
        $primaryPath = Join-Path $TestDrive 's3-primary-refused-target'
        New-Item -ItemType Directory -Path $workDir, $primaryPath -Force | Out-Null
        $primaryFwdPath = $primaryPath -replace '\\', '/'
        $branch = 'pester-temp/issue-889-s3-primary'

        $porcelain = @"
worktree $primaryFwdPath
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree $($workDir -replace '\\', '/')
HEAD 2222222222222222222222222222222222222222
branch refs/heads/$branch
"@

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
            'fetch-exit'                        = 0
            'worktree-list-porcelain'           = $porcelain
            'path-configs'                      = @{
                $primaryFwdPath = @{ 'branch--show-current' = 'main' }
            }
        } -ScriptParams @{
            SiblingWorktrees = [string[]]@($primaryFwdPath)
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ([regex]::Escape("refusing to remove the primary worktree at $primaryFwdPath")) -Because 'the primary checkout must be refused by name'
        $removalCalls = @($result.GitCalls | Where-Object { $_ -match 'worktree-removed' })
        $removalCalls.Count | Should -Be 0 -Because 'no destructive git worktree remove call may be attempted against the primary worktree'
        $branchDeleteCalls = @($result.GitCalls | Where-Object { $_ -match '^branch-deleted\t' })
        $branchDeleteCalls.Count | Should -Be 0 -Because 'no destructive git branch -D call may be attempted against the primary worktree branch'
    }

    It 'S3-FeatureBranch-Ineligible: -FeatureBranch on an ineligible branch is retained, not deleted' {
        $workDir = Join-Path $TestDrive 's3-featurebranch-ineligible'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $branch = 'pester-temp/issue-889-s3-fb-ineligible'

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
            'fetch-exit'                        = 0
            'checkout-exit'                     = 0
            'pull-exit'                         = 0
            "branch-list-$branch"               = "  $branch"
            'branch--show-current'              = 'main'
            "rev-list-count-$branch"            = '3'
            "diff-quiet-exit-$branch"           = 1
            "merge-tree-exit-$branch"           = 1
            "cherry-exit-$branch"               = 1
        } -ScriptParams @{
            FeatureBranch    = $branch
            SkipRemoteDelete = $true
            SkipGitUpdate    = $true
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'detector flagged this, but re-verification declined' -Because 'an ineligible feature branch must be declined by the re-verification gate'
        $result.Output | Should -Not -Match ([regex]::Escape("Deleting local branch: $branch")) -Because 'the local branch must not be deleted when re-verification declines'
        $branchDeleteCalls = @($result.GitCalls | Where-Object { $_ -eq "branch-deleted`t-D`t$branch" })
        $branchDeleteCalls.Count | Should -Be 0 -Because 'git branch -D must never be called for an ineligible feature branch'
    }

    It 'S3-LockedDirPresent: a locked+prunable sibling worktree whose directory is still present is skipped for manual review' {
        $workDir = Join-Path $TestDrive 's3-locked-dir-present'
        $siblingPath = Join-Path $TestDrive 's3-locked-dir-present-target'
        New-Item -ItemType Directory -Path $workDir, $siblingPath -Force | Out-Null
        $siblingFwdPath = $siblingPath -replace '\\', '/'
        $branch = 'pester-temp/issue-889-s3-locked-present'

        $porcelain = @"
worktree $($workDir -replace '\\', '/')
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree $siblingFwdPath
HEAD 3333333333333333333333333333333333333333
branch refs/heads/$branch
locked
prunable
"@

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
            'fetch-exit'                        = 0
            'worktree-list-porcelain'           = $porcelain
            "rev-list-count-$branch"            = '2'
            "diff-quiet-exit-$branch"           = 0
            'path-configs'                      = @{
                $siblingFwdPath = @{ 'branch--show-current' = $branch }
            }
        } -ScriptParams @{
            SiblingWorktrees = [string[]]@($siblingFwdPath)
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ([regex]::Escape("skipped locked worktree at $siblingFwdPath - remove the lock first")) -Because 'a dir-present locked+prunable worktree must route to manual review (D5/#522), never force-removed on the porcelain marker alone'
        $forceCalls = @($result.GitCalls | Where-Object { $_ -match "worktree-removed`t$([regex]::Escape($siblingFwdPath))" })
        $forceCalls.Count | Should -Be 0 -Because 'no destructive git worktree remove call may be attempted while the lock is present and the directory still exists'
    }

    It 'S3-PrunableLockedDirAbsent: a locked+prunable worktree with a directory confirmed absent via Test-Path clears as stale-registration' {
        $workDir = Join-Path $TestDrive 's3-locked-dir-absent'
        # NOTE: the sibling path is intentionally never created on disk — Test-Path
        # must independently confirm absence (not merely trust the porcelain 'prunable' marker).
        $siblingPath = Join-Path $TestDrive 's3-locked-dir-absent-target'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $siblingFwdPath = $siblingPath -replace '\\', '/'
        $branch = 'pester-temp/issue-889-s3-locked-absent'

        $porcelain = @"
worktree $($workDir -replace '\\', '/')
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree $siblingFwdPath
HEAD 4444444444444444444444444444444444444444
branch refs/heads/$branch
locked
prunable
"@

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
            'fetch-exit'                        = 0
            'worktree-list-porcelain'           = $porcelain
            "rev-list-count-$branch"            = '2'
            "diff-quiet-exit-$branch"           = 0
            'worktree-remove-exit'              = 0
            'branch-d-exit'                     = 0
            'path-configs'                      = @{
                $siblingFwdPath = @{ 'branch--show-current' = $branch }
            }
        } -ScriptParams @{
            SiblingWorktrees = [string[]]@($siblingFwdPath)
        }

        $result.ExitCode | Should -Be 0
        $staleRegPattern = [regex]::Escape('removing stale registration') + ' (?:—|-) ' + [regex]::Escape("directory already gone at $siblingFwdPath")
        $result.Output | Should -Match $staleRegPattern -Because 'a locked+prunable worktree with a Test-Path-confirmed-absent directory must clear via the honest stale-registration message'
        $forceCalls = @($result.GitCalls | Where-Object { $_ -eq "worktree-removed`t$siblingFwdPath" })
        $forceCalls.Count | Should -BeGreaterThan 0 -Because 'clearing a confirmed-absent locked registration requires a --force git worktree remove call'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 sibling worktree(s): $siblingFwdPath")) -Because 'the stale registration clear must count as a removal'
    }

    It 'S3-PlainPrunable: a plain (not locked) prunable worktree with a directory confirmed absent clears as stale-registration' {
        $workDir = Join-Path $TestDrive 's3-plain-prunable'
        $siblingPath = Join-Path $TestDrive 's3-plain-prunable-target'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $siblingFwdPath = $siblingPath -replace '\\', '/'
        $branch = 'pester-temp/issue-889-s3-plain-prunable'

        $porcelain = @"
worktree $($workDir -replace '\\', '/')
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree $siblingFwdPath
HEAD 5555555555555555555555555555555555555555
branch refs/heads/$branch
prunable
"@

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
            'fetch-exit'                        = 0
            'worktree-list-porcelain'           = $porcelain
            "rev-list-count-$branch"            = '2'
            "diff-quiet-exit-$branch"           = 0
            'worktree-remove-exit'              = 0
            'branch-d-exit'                     = 0
            'path-configs'                      = @{
                $siblingFwdPath = @{ 'branch--show-current' = $branch }
            }
        } -ScriptParams @{
            SiblingWorktrees = [string[]]@($siblingFwdPath)
        }

        $result.ExitCode | Should -Be 0
        $staleRegPattern = [regex]::Escape('removing stale registration') + ' (?:—|-) ' + [regex]::Escape("directory already gone at $siblingFwdPath")
        $result.Output | Should -Match $staleRegPattern -Because 'plain-prunable (dir absent, not locked) must also clear via the stale-registration message'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 sibling worktree(s): $siblingFwdPath")) -Because 'the stale registration clear must count as a removal'
    }

    It 'S3-EligibleSquashMerged: an eligible squash-merged sibling worktree is removed with evidence named in the message' {
        $workDir = Join-Path $TestDrive 's3-squash-merged'
        $siblingPath = Join-Path $TestDrive 's3-squash-merged-target'
        New-Item -ItemType Directory -Path $workDir, $siblingPath -Force | Out-Null
        $siblingFwdPath = $siblingPath -replace '\\', '/'
        $branch = 'pester-temp/issue-889-s3-squash-merged'

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
            'fetch-exit'                        = 0
            'worktree-list-porcelain'           = (& $script:NewPrimaryPorcelain -WorkDir $workDir)
            "rev-list-count-$branch"            = '2'
            "diff-quiet-exit-$branch"           = 0
            'worktree-remove-exit'              = 0
            'branch-d-exit'                     = 0
            'path-configs'                      = @{
                $siblingFwdPath = @{ 'branch--show-current' = $branch }
            }
        } -ScriptParams @{
            SiblingWorktrees = [string[]]@($siblingFwdPath)
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ([regex]::Escape('eligible: merged into origin/main (tree-equivalent)')) -Because 'the removal message must name the evidence backing eligibility'
        $result.Output | Should -Match ([regex]::Escape("removed $siblingFwdPath")) -Because 'the honest post-attempt outcome message must confirm the worktree is gone'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 sibling worktree(s): $siblingFwdPath")) -Because 'a genuinely eligible squash-merged worktree must still be counted as removed'
    }

    It 'S3-Orphan-ZeroCommit-OpenIssue-Retained: a zero-commit claude/* orphan branch with an open parent issue and no merged PR is retained, not deleted (regression test for the literal #889 defect)' {
        # Test-BranchMergedIntoDefault's primary signal is git tree-equivalence, which
        # is trivially TRUE for any zero-unique-commit branch by definition. Without the
        # rung-1 unique-commit-count gate, this in-progress claude/* branch — whose only
        # "work" lives in an open GitHub issue, not commits — would fall straight through
        # to deletion. This is the exact scenario Issue #889 exists to close.
        $workDir = Join-Path $TestDrive 's3-orphan-zero-commit-open'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $branch = 'claude/issue-889-abcdef'

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
            'fetch-exit'                        = 0
            'remote-url'                        = 'https://github.com/owner/repo.git'
            "rev-list-count-$branch"            = '0'
        } -GhConfig @{
            'pr-list-default-output' = '[]'
            'pr-list-default-exit'   = 0
            'issue-view-889'         = '{"state":"OPEN"}'
        } -ScriptParams @{
            OrphanBranches = [string[]]@($branch)
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ([regex]::Escape("Skipped '$branch'")) -Because 'a zero-commit orphan branch with an open parent issue must be retained'
        $result.Output | Should -Match ([regex]::Escape('issue #889 still open')) -Because 'the manual-review reason must name why it was retained'
        $deleteCalls = @($result.GitCalls | Where-Object { $_ -match "^branch-deleted\t.*$([regex]::Escape($branch))" })
        $deleteCalls.Count | Should -Be 0 -Because 'the literal #889 defect: a zero-commit orphan branch must never delete via tree-equivalence trivial-true'
    }

    It 'S3-Orphan-ZeroCommit-MergedPR-Deleted: a zero-commit orphan branch with an OID-matched merged PR is deleted with evidence' {
        $workDir = Join-Path $TestDrive 's3-orphan-zero-commit-merged-pr'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $branch = 'claude/issue-890-abcdef'
        $branchTip = 'orphan-zero-tip-sha'

        $result = & $script:InvokeScript -WorkDir $workDir -GitConfig @{
            'symbolic-ref-origin-HEAD'          = 'refs/remotes/origin/main'
            'show-ref-refs/remotes/origin/main' = 0
            'fetch-exit'                        = 0
            "rev-list-count-$branch"            = '0'
            "rev-parse-$branch"                 = $branchTip
            'branch-D-exit'                     = 0
        } -GhConfig @{
            "pr-list-merged-$branch" = "[{`"number`":77,`"headRefOid`":`"$branchTip`"}]"
            'pr-list-default-exit'   = 0
        } -ScriptParams @{
            OrphanBranches = [string[]]@($branch)
        }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match ([regex]::Escape('eligible: PR #77 merged')) -Because 'the deletion message must name the OID-matched PR as evidence'
        $result.Output | Should -Match 'Deleted 1 orphan branch' -Because 'a zero-commit orphan branch with a genuinely merged PR must be deleted'
        $deleteCalls = @($result.GitCalls | Where-Object { $_ -eq "branch-deleted`t-D`t$branch" })
        $deleteCalls.Count | Should -BeGreaterThan 0 -Because 'deletion must use git branch -D (no commits to preserve via the safe -d path)'
    }

    It 'S3-NoOldFalseSkipLiteral: the retired false-skip literal never appears in the script source' {
        $scriptContent = Get-Content -Path $script:ScriptFile -Raw
        $scriptContent | Should -Not -Match ([regex]::Escape('has uncommitted changes or other state preventing safe removal — skipping')) -Because 'the old misdiagnosis literal must be fully retired (Issue #889 s3)'
    }
}
