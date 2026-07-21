#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for the issue #889 s1 eligibility primitive
    (Test-WorktreeBranchRemovalEligible / Get-WorktreeBranchIssueId) added to
    session-startup-git-helpers.ps1.

.DESCRIPTION
    Mock-git + mock-gh fixtures covering the ordered router:
      1. unique-commit count (git rev-list <remoteDefaultRef>..<branch> --count)
      2. >=1 commit -> git-only tree-equivalence, else OID-checked merged-PR-by-head
      3. 0 commits -> OID-checked merged-PR-by-head first, then closed-issue derivation

    Mock factory pattern reused from post-merge-cleanup.Tests.ps1 (config-driven
    git.ps1/git.cmd + gh.ps1/gh.cmd shims prepended to PATH).
#>

Describe 'session-startup-git-helpers.ps1 — Test-WorktreeBranchRemovalEligible (Issue #889 s1)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-startup-git-helpers.ps1'
        $script:SavedPath = $env:PATH

        # Load the module under test once; PATH-based git/gh mocking below affects
        # the native-command resolution these already-loaded functions perform at
        # call time, so no re-sourcing is needed per test.
        . $script:ScriptFile

        # ---------------------------------------------------------------------------
        # Mock git factory — same pattern as post-merge-cleanup.Tests.ps1 /
        # session-cleanup-detector.Tests.ps1: writes a git.ps1 shim + git.cmd
        # wrapper to a temp dir, prepends to PATH.
        # ---------------------------------------------------------------------------
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
$callLogPath = Join-Path $PSScriptRoot 'git-mock-calls.log'
($a -join "`t") | Add-Content -Path $callLogPath -Encoding UTF8

function Get-ConfigValue {
    param([string]$Name)
    $prop = $config.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

# git symbolic-ref refs/remotes/origin/HEAD
if ($a.Count -ge 2 -and $a[0] -eq 'symbolic-ref' -and $a[1] -eq 'refs/remotes/origin/HEAD') {
    $val = Get-ConfigValue 'symbolic-ref-origin-HEAD'
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 128
}

# git rev-parse --abbrev-ref <branch>@{upstream}
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

# git rev-parse <branch>  (bare tip lookup — must come after the --abbrev-ref case above)
if ($a.Count -ge 2 -and $a[0] -eq 'rev-parse') {
    $ref = $a[1]
    $key = "rev-parse-$ref"
    $val = Get-ConfigValue $key
    $exitVal = Get-ConfigValue "rev-parse-exit-$ref"
    if ($null -eq $exitVal) { $exitVal = 0 }
    if ($null -ne $val) { Write-Output $val }
    exit ([int]$exitVal)
}

# git rev-list <ref>..<branch> --count
if ($a.Count -ge 3 -and $a[0] -eq 'rev-list' -and $a[-1] -eq '--count') {
    $range = $a[1]
    $key = "rev-list-count-$range"
    $val = Get-ConfigValue $key
    $exitVal = Get-ConfigValue "rev-list-exit-$range"
    if ($null -eq $exitVal) { $exitVal = 0 }
    "rev-list-called`t$range" | Add-Content -Path $callLogPath -Encoding UTF8
    if ([int]$exitVal -eq 0) {
        if ($null -eq $val) { $val = 0 }
        Write-Output "$val"
    }
    exit ([int]$exitVal)
}

# git diff --quiet [--ignore-cr-at-eol] <baseRef> <branch>
if ($a.Count -ge 4 -and $a[0] -eq 'diff' -and $a[1] -eq '--quiet') {
    $argIndex = 2
    if ($a[$argIndex] -eq '--ignore-cr-at-eol') { $argIndex++ }
    if ($argIndex + 1 -lt $a.Count) {
        $baseRef = $a[$argIndex]
        $targetBranch = $a[$argIndex + 1]
        $diffExit = Get-ConfigValue "diff-quiet-exit-$targetBranch"
        if ($null -eq $diffExit) { $diffExit = 1 }
        "diff-quiet-called`t$baseRef`t$targetBranch" | Add-Content -Path $callLogPath -Encoding UTF8
        exit ([int]$diffExit)
    }
    exit 1
}

# git merge-tree --write-tree <baseRef> <branch>
if ($a.Count -ge 4 -and $a[0] -eq 'merge-tree' -and $a[1] -eq '--write-tree') {
    $targetBranch = $a[3]
    $mergeTreeOutput = Get-ConfigValue "merge-tree-output-$targetBranch"
    $mergeTreeExit = Get-ConfigValue "merge-tree-exit-$targetBranch"
    if ($null -eq $mergeTreeExit) { $mergeTreeExit = 1 }
    "merge-tree-called`t$targetBranch" | Add-Content -Path $callLogPath -Encoding UTF8
    if ($null -ne $mergeTreeOutput -and $mergeTreeOutput -ne '') { Write-Output $mergeTreeOutput }
    exit ([int]$mergeTreeExit)
}

# git cherry <baseRef> <branch>
if ($a.Count -ge 3 -and $a[0] -eq 'cherry') {
    $targetBranch = $a[2]
    $cherryOutput = Get-ConfigValue "cherry-$targetBranch"
    $cherryExit = Get-ConfigValue "cherry-exit-$targetBranch"
    if ($null -eq $cherryExit) { $cherryExit = 0 }
    if ($null -ne $cherryOutput -and $cherryOutput -ne '') { Write-Output $cherryOutput }
    "cherry-called`t$targetBranch" | Add-Content -Path $callLogPath -Encoding UTF8
    exit ([int]$cherryExit)
}

# git remote get-url origin
if ($a.Count -ge 3 -and $a[0] -eq 'remote' -and $a[1] -eq 'get-url') {
    $val = Get-ConfigValue 'remote-url'
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 1
}

# git worktree list --porcelain (Issue #889 s2 — Test-WorktreeIsPrimary / Test-WorktreeRemovalPreflight)
if ($a.Count -ge 3 -and $a[0] -eq 'worktree' -and $a[1] -eq 'list' -and $a[2] -eq '--porcelain') {
    $val = Get-ConfigValue 'worktree-list-porcelain'
    $exitVal = Get-ConfigValue 'worktree-list-porcelain-exit'
    if ($null -eq $exitVal) { $exitVal = 0 }
    "worktree-list-porcelain-called" | Add-Content -Path $callLogPath -Encoding UTF8
    if ($null -ne $val -and $val -ne '') { Write-Output $val }
    exit ([int]$exitVal)
}

# git -C <path> status --porcelain (Issue #889 s2 — Test-WorktreeRemovalPreflight dirty probe)
if ($a.Count -ge 4 -and $a[0] -eq '-C' -and $a[2] -eq 'status' -and $a[3] -eq '--porcelain') {
    $path = $a[1]
    $key = "status-porcelain-$path"
    $val = Get-ConfigValue $key
    $exitVal = Get-ConfigValue "status-porcelain-exit-$path"
    if ($null -eq $exitVal) { $exitVal = 0 }
    "status-porcelain-called`t$path" | Add-Content -Path $callLogPath -Encoding UTF8
    if ($null -ne $val -and $val -ne '') { Write-Output $val }
    exit ([int]$exitVal)
}

# Default: success, no output
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
        # Mock gh factory — writes a gh.ps1 shim + gh.cmd wrapper to the same temp dir.
        # Supports an optional global 'gh-sleep-ms' config key so a single fixture can
        # simulate a hung gh process for the Invoke-SCDGhWithTimeout kill path.
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

$sleepMs = Get-GhConfigValue 'gh-sleep-ms'
if ($null -ne $sleepMs -and [int]$sleepMs -gt 0) {
    Start-Sleep -Milliseconds ([int]$sleepMs)
}

# gh pr list --head <branch> --base <default> --state merged --json number,headRefOid
if ($a.Count -ge 6 -and $a[0] -eq 'pr' -and $a[1] -eq 'list') {
    $headIdx = [Array]::IndexOf([string[]]$a, '--head')
    $branch = if ($headIdx -ge 0 -and $headIdx + 1 -lt $a.Count) { $a[$headIdx + 1] } else { '' }
    $key = "pr-list-merged-$branch"
    $val = Get-GhConfigValue $key
    if ($null -ne $val) { Write-Output $val; exit 0 }
    exit 0
}

# gh issue view <id> --repo <owner/repo> --json state
if ($a.Count -ge 3 -and $a[0] -eq 'issue' -and $a[1] -eq 'view') {
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
        # Helper: run a scriptblock with git (and optionally gh) mocked onto PATH.
        # Restores PATH afterward regardless of outcome.
        # ---------------------------------------------------------------------------
        $script:WithMockedGit = {
            param(
                [hashtable]$GitConfig,
                [hashtable]$GhConfig = $null,
                [scriptblock]$Body
            )

            $tempParent = Join-Path $TestDrive "mockenv-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $tempParent -Force | Out-Null

            $mockDir = & $script:NewMockGitDir -ParentDir $tempParent -Config $GitConfig
            if ($null -ne $GhConfig) {
                & $script:AddMockGh -MockDir $mockDir -GhConfig $GhConfig
            }

            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"
                & $Body -MockDir $mockDir
            }
            finally {
                $env:PATH = $script:SavedPath
            }
        }

        $script:DefaultGitConfig = @{
            'symbolic-ref-origin-HEAD' = 'refs/remotes/origin/main'
        }
    }

    AfterAll {
        $env:PATH = $script:SavedPath
    }

    # =========================================================================
    # Get-WorktreeBranchIssueId — pure string derivation, no git/gh calls
    # =========================================================================
    Context 'Get-WorktreeBranchIssueId — issue-id derivation' {

        It 'TC-Derive-1: derives the issue id from a feature/issue-N- branch' {
            Get-WorktreeBranchIssueId -BranchName 'feature/issue-889-post-merge-cleanup-classification' | Should -Be 889
        }

        It 'TC-Derive-2: derives the issue id from a claude/*-N-<hex6> branch (hex digit-run tip)' {
            Get-WorktreeBranchIssueId -BranchName 'claude/agent-orchestra-experience-872-91fd03' | Should -Be 872
        }

        It 'TC-Derive-3: returns $null for a non-claude/-prefixed, non-feature/issue- name (no derivation)' {
            Get-WorktreeBranchIssueId -BranchName 'bugfix/foo-123-abc123' | Should -BeNullOrEmpty
        }

        It 'TC-Derive-4: returns $null for a claude/ branch missing the trailing 6-hex disambiguator' {
            Get-WorktreeBranchIssueId -BranchName 'claude/agent-orchestra-experience-872' | Should -BeNullOrEmpty
        }
    }

    # =========================================================================
    # Test-WorktreeBranchRemovalEligible — ordered router
    # =========================================================================
    Context 'Test-WorktreeBranchRemovalEligible — router' {

        It 'TC-Router-1: git-signal-failure on rev-list retains with the git-signal reason' {
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'rev-list-exit-origin/main..feature/issue-1-x' = 128
            }) -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName 'feature/issue-1-x' -DefaultBranch 'main'
                $result.Eligible | Should -Be $false
                $result.ManualReviewReason | Should -Be "couldn't verify: git signal failed"
            }
        }

        It 'TC-Router-2: commit-carrying branch merged via git-only tree-equivalence is eligible without any gh call' {
            $branch = 'feature/issue-2-tree-equiv'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-count-origin/main..$branch" = 3
                "diff-quiet-exit-$branch"              = 0
            }) -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main'
                $result.Eligible | Should -Be $true
                $result.Evidence | Should -Match '\(tree-equivalent\)'
                $ghCallLog = Join-Path $MockDir 'gh-mock-calls.log'
                (Test-Path $ghCallLog) | Should -Be $false -Because 'git-only tree-equivalence must not invoke gh'
            }
        }

        It 'TC-Router-3: commit-carrying branch with a name-matched PR at a DIFFERENT head OID is NOT eligible (proves the OID fix)' {
            $branch = 'feature/issue-3-stale-pr'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-count-origin/main..$branch" = 2
                "diff-quiet-exit-$branch"              = 1
                "merge-tree-exit-$branch"              = 1
                "cherry-$branch"                       = '+ deadbee Unmerged tip commit'
                "rev-parse-$branch"                    = 'currenttipsha'
            }) -GhConfig @{
                "pr-list-merged-$branch" = '[{"number":77,"headRefOid":"oldstalesha"}]'
            } -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main'
                $result.Eligible | Should -Be $false
                $result.ManualReviewReason | Should -Be 'unmerged commits'
            }
        }

        It 'TC-Router-4: commit-carrying branch with no PR and unmerged cherry output retains as unmerged commits' {
            $branch = 'feature/issue-4-unmerged'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-count-origin/main..$branch" = 1
                "diff-quiet-exit-$branch"              = 1
                "merge-tree-exit-$branch"              = 1
                "cherry-$branch"                       = '+ deadbee Unmerged tip commit'
                "rev-parse-$branch"                    = 'currenttipsha'
            }) -GhConfig @{
                'pr-list-default-exit' = 0
            } -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main'
                $result.Eligible | Should -Be $false
                $result.ManualReviewReason | Should -Be 'unmerged commits'
            }
        }

        It 'TC-Router-5: zero-commit branch with a merged PR by matching head OID is eligible via rung-3(a) (PR-first)' {
            $branch = 'claude/some-work-501-abcdef'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-count-origin/main..$branch" = 0
                "rev-parse-$branch"                    = 'matchingsha'
            }) -GhConfig @{
                "pr-list-merged-$branch" = '[{"number":501,"headRefOid":"matchingsha"}]'
            } -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main'
                $result.Eligible | Should -Be $true
                $result.Evidence | Should -Be 'PR #501 merged'
                $issueCallLog = Join-Path $MockDir 'gh-mock-calls.log'
                $issueCalls = @(Get-Content -Path $issueCallLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^issue\tview' })
                $issueCalls.Count | Should -Be 0 -Because 'the merged-PR-by-head rung must be checked before issue derivation is attempted'
            }
        }

        It 'TC-Router-6: zero-commit branch with a closed issue and no PR is eligible with closed-issue evidence' {
            $branch = 'feature/issue-600-done'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-count-origin/main..$branch" = 0
                'remote-url'                            = 'https://github.com/Grimblaz/agent-orchestra.git'
            }) -GhConfig @{
                'issue-view-600' = '{"state":"CLOSED"}'
            } -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main'
                $result.Eligible | Should -Be $true
                $result.Evidence | Should -Be 'issue #600 closed (no code changes)'
            }
        }

        It 'TC-Router-7: zero-commit branch with an open issue and no PR retains as still-open' {
            $branch = 'feature/issue-601-inflight'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-count-origin/main..$branch" = 0
                'remote-url'                            = 'https://github.com/Grimblaz/agent-orchestra.git'
            }) -GhConfig @{
                'issue-view-601' = '{"state":"OPEN"}'
            } -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main'
                $result.Eligible | Should -Be $false
                $result.ManualReviewReason | Should -Be 'issue #601 still open'
            }
        }

        It 'TC-Router-8: zero-commit branch with no derivable issue id and no PR retains as no-issue-number-derivable' {
            $branch = 'pester-temp/zero-commit-no-id'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-count-origin/main..$branch" = 0
            }) -GhConfig @{
                'pr-list-default-exit' = 0
            } -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main'
                $result.Eligible | Should -Be $false
                $result.ManualReviewReason | Should -Be 'no issue number derivable'
            }
        }

        It 'TC-Router-9: gh-timeout during the merged-PR-by-head check retains with the gh-timeout reason' {
            $branch = 'feature/issue-700-gh-hang'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-count-origin/main..$branch" = 0
            }) -GhConfig @{
                'gh-sleep-ms' = 6000
            } -Body {
                param($MockDir)
                $result = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main'
                $result.Eligible | Should -Be $false
                $result.ManualReviewReason | Should -Be "couldn't verify: gh timeout"
            }
        } -Tag 'Slow'

        It 'TC-Router-10: a call made while the caller has $ErrorActionPreference = "Stop" does not throw (EAP-suppression invariant, M7)' {
            $branch = 'feature/issue-800-eap-stop'
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                "rev-list-exit-origin/main..$branch" = 1
            }) -Body {
                param($MockDir)
                $previousEap = $ErrorActionPreference
                $ErrorActionPreference = 'Stop'
                try {
                    { $script:EapResult = Test-WorktreeBranchRemovalEligible -BranchName $branch -DefaultBranch 'main' } | Should -Not -Throw
                }
                finally {
                    $ErrorActionPreference = $previousEap
                }
                $script:EapResult.Eligible | Should -Be $false
                $script:EapResult.ManualReviewReason | Should -Be "couldn't verify: git signal failed"
            }
        }
    }

    # =========================================================================
    # Test-WorktreeIsPrimary — shared primary-worktree guard (Issue #889 s2)
    # =========================================================================
    Context 'Test-WorktreeIsPrimary — shared primary-worktree guard' {

        It 'TC-Primary-1: returns $true when the path matches the FIRST porcelain record' {
            $porcelain = @(
                'worktree /repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
                ''
                'worktree /repo/sibling'
                'HEAD bbb222'
                'branch refs/heads/feature/issue-2-x'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain' = $porcelain
            }) -Body {
                param($MockDir)
                Test-WorktreeIsPrimary -WorktreePath '/repo/main' | Should -Be $true
            }
        }

        It 'TC-Primary-2: returns $false when the path matches a LATER (non-first) porcelain record' {
            $porcelain = @(
                'worktree /repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
                ''
                'worktree /repo/sibling'
                'HEAD bbb222'
                'branch refs/heads/feature/issue-2-x'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain' = $porcelain
            }) -Body {
                param($MockDir)
                Test-WorktreeIsPrimary -WorktreePath '/repo/sibling' | Should -Be $false
            }
        }

        It 'TC-Primary-3: bare-main record #1 (no branch line) is still treated as the primary record when its path matches' {
            $porcelain = @(
                'worktree /repo/bare.git'
                'bare'
                ''
                'worktree /repo/sibling'
                'HEAD bbb222'
                'branch refs/heads/feature/issue-2-x'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain' = $porcelain
            }) -Body {
                param($MockDir)
                Test-WorktreeIsPrimary -WorktreePath '/repo/bare.git' | Should -Be $true
            }
        }

        It 'TC-Primary-4: porcelain probe failure (non-zero exit) fails SAFE toward primary ($true — never authorizes removal on an indeterminate primary check)' {
            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain-exit' = 128
            }) -Body {
                param($MockDir)
                Test-WorktreeIsPrimary -WorktreePath '/repo/anything' | Should -Be $true
            }
        }

        It 'TC-Primary-5: path comparison is normalized (backslash separators + case-insensitive on Windows)' {
            $porcelain = @(
                'worktree C:/repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain' = $porcelain
            }) -Body {
                param($MockDir)
                Test-WorktreeIsPrimary -WorktreePath 'C:\REPO\Main\' | Should -Be $true
            }
        }
    }

    # =========================================================================
    # Get-WorktreeRemovalOutcome — pure 7-state diagnosis over injected probes (Issue #889 s2, M5)
    # =========================================================================
    Context 'Get-WorktreeRemovalOutcome — full registered x {absent,empty,non-empty} matrix' {

        It 'TC-Outcome-1: not-registered + absent -> removed' {
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 0 `
                -PorcelainRegistrationProbe { $false } -FileSystemProbe { 'absent' }
            $result | Should -Be 'removed'
        }

        It 'TC-Outcome-2: not-registered + empty -> removed-partial-root-held' {
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 1 `
                -PorcelainRegistrationProbe { $false } -FileSystemProbe { 'empty' }
            $result | Should -Be 'removed-partial-root-held'
        }

        It 'TC-Outcome-3: not-registered + non-empty -> removed-partial-content-remains' {
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 1 `
                -PorcelainRegistrationProbe { $false } -FileSystemProbe { 'non-empty' }
            $result | Should -Be 'removed-partial-content-remains'
        }

        It 'TC-Outcome-4: registered + absent -> stale-registration' {
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 1 `
                -PorcelainRegistrationProbe { $true } -FileSystemProbe { 'absent' }
            $result | Should -Be 'stale-registration'
        }

        It 'TC-Outcome-5: registered + empty -> removed-partial-root-held' {
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 1 `
                -PorcelainRegistrationProbe { $true } -FileSystemProbe { 'empty' }
            $result | Should -Be 'removed-partial-root-held'
        }

        It 'TC-Outcome-6: registered + non-empty -> failed' {
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 1 `
                -PorcelainRegistrationProbe { $true } -FileSystemProbe { 'non-empty' }
            $result | Should -Be 'failed'
        }

        It 'TC-Outcome-7: registration-probe error ($null) -> verification-indeterminate' {
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 1 `
                -PorcelainRegistrationProbe { $null } -FileSystemProbe { 'absent' }
            $result | Should -Be 'verification-indeterminate'
        }

        It 'TC-Outcome-8: filesystem-probe error ($null) -> verification-indeterminate' {
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 1 `
                -PorcelainRegistrationProbe { $true } -FileSystemProbe { $null }
            $result | Should -Be 'verification-indeterminate'
        }

        It 'TC-Outcome-9: purity — each injected probe is invoked exactly once, no live git/fs call is made' {
            $script:RegProbeCalls = 0
            $script:FsProbeCalls = 0
            $result = Get-WorktreeRemovalOutcome -WorktreePath '/repo/x' -RemovalExitCode 0 `
                -PorcelainRegistrationProbe { $script:RegProbeCalls++; $false } `
                -FileSystemProbe { $script:FsProbeCalls++; 'absent' }
            $result | Should -Be 'removed'
            $script:RegProbeCalls | Should -Be 1
            $script:FsProbeCalls | Should -Be 1
        }
    }

    # =========================================================================
    # Get-WorktreeRemovalOutcomeMessage — self-contained message-mapping table (Issue #889 s2, M24)
    # =========================================================================
    Context 'Get-WorktreeRemovalOutcomeMessage — outcome-to-literal-message mapping' {

        It 'TC-Message-1: removed' {
            Get-WorktreeRemovalOutcomeMessage -Outcome 'removed' -WorktreePath '/repo/x' | Should -Be 'removed /repo/x'
        }

        It 'TC-Message-2: removed-partial-root-held' {
            Get-WorktreeRemovalOutcomeMessage -Outcome 'removed-partial-root-held' -WorktreePath '/repo/x' |
                Should -Be 'contents removed but the root directory was held by another process — the worktree is gone; an empty directory remains at /repo/x'
        }

        It 'TC-Message-3: removed-partial-content-remains' {
            Get-WorktreeRemovalOutcomeMessage -Outcome 'removed-partial-content-remains' -WorktreePath '/repo/x' |
                Should -Be 'worktree unregistered but files remain at /repo/x (a process is holding content) — inspect manually'
        }

        It 'TC-Message-4: stale-registration' {
            Get-WorktreeRemovalOutcomeMessage -Outcome 'stale-registration' -WorktreePath '/repo/x' |
                Should -Be 'removing stale registration — directory already gone at /repo/x'
        }

        It 'TC-Message-5: failed carries the supplied Detail' {
            Get-WorktreeRemovalOutcomeMessage -Outcome 'failed' -WorktreePath '/repo/x' -Detail 'exit 128' |
                Should -Be 'could not remove /repo/x (exit 128)'
        }

        It 'TC-Message-6: verification-indeterminate' {
            Get-WorktreeRemovalOutcomeMessage -Outcome 'verification-indeterminate' -WorktreePath '/repo/x' |
                Should -Be 'could not verify the final state — inspect manually at /repo/x'
        }
    }

    # =========================================================================
    # Test-WorktreeRemovalPreflight — skip-before-attempt decision (Issue #889 s2, M12/M14)
    # =========================================================================
    Context 'Test-WorktreeRemovalPreflight — skip decision' {

        It 'TC-Preflight-1: primary worktree -> Skip=true, Reason=primary (checked before locked/dirty)' {
            $porcelain = @(
                'worktree /repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain' = $porcelain
            }) -Body {
                param($MockDir)
                $result = Test-WorktreeRemovalPreflight -WorktreePath '/repo/main'
                $result.Skip | Should -Be $true
                $result.Reason | Should -Be 'primary'
            }
        }

        It 'TC-Preflight-2: locked-and-not-prunable (not primary) -> Skip=true, Reason=locked' {
            $porcelain = @(
                'worktree /repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
                ''
                'worktree /repo/sibling'
                'HEAD bbb222'
                'branch refs/heads/feature/issue-2-x'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain' = $porcelain
            }) -Body {
                param($MockDir)
                $result = Test-WorktreeRemovalPreflight -WorktreePath '/repo/sibling' -IsLocked $true -IsPrunable $false
                $result.Skip | Should -Be $true
                $result.Reason | Should -Be 'locked'
            }
        }

        It 'TC-Preflight-3: locked-AND-prunable (M14 qualified predicate) does NOT skip at preflight — falls through to a clean dirty-check' {
            $porcelain = @(
                'worktree /repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
                ''
                'worktree /repo/sibling'
                'HEAD bbb222'
                'branch refs/heads/feature/issue-2-x'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain'   = $porcelain
                'status-porcelain-/repo/sibling' = ''
            }) -Body {
                param($MockDir)
                $result = Test-WorktreeRemovalPreflight -WorktreePath '/repo/sibling' -IsLocked $true -IsPrunable $true
                $result.Skip | Should -Be $false
                $result.Reason | Should -BeNullOrEmpty
            }
        }

        It 'TC-Preflight-4: dirty (non-empty status --porcelain) -> Skip=true, Reason=dirty' {
            $porcelain = @(
                'worktree /repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
                ''
                'worktree /repo/sibling'
                'HEAD bbb222'
                'branch refs/heads/feature/issue-2-x'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain'         = $porcelain
                'status-porcelain-/repo/sibling'  = ' M some-file.txt'
            }) -Body {
                param($MockDir)
                $result = Test-WorktreeRemovalPreflight -WorktreePath '/repo/sibling'
                $result.Skip | Should -Be $true
                $result.Reason | Should -Be 'dirty'
            }
        }

        It "TC-Preflight-5: the preflight's OWN dirty probe erroring (non-zero exit) skips WITHOUT attempt — never falls through" {
            $porcelain = @(
                'worktree /repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
                ''
                'worktree /repo/sibling'
                'HEAD bbb222'
                'branch refs/heads/feature/issue-2-x'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain'              = $porcelain
                'status-porcelain-exit-/repo/sibling'  = 128
            }) -Body {
                param($MockDir)
                $result = Test-WorktreeRemovalPreflight -WorktreePath '/repo/sibling'
                $result.Skip | Should -Be $true
                $result.Reason | Should -Be "couldn't verify preflight state"
            }
        }

        It 'TC-Preflight-6: not primary, not locked, clean status -> Skip=false, Reason=$null' {
            $porcelain = @(
                'worktree /repo/main'
                'HEAD aaa111'
                'branch refs/heads/main'
                ''
                'worktree /repo/sibling'
                'HEAD bbb222'
                'branch refs/heads/feature/issue-2-x'
            ) -join "`n"

            & $script:WithMockedGit -GitConfig ($script:DefaultGitConfig + @{
                'worktree-list-porcelain'         = $porcelain
                'status-porcelain-/repo/sibling'  = ''
            }) -Body {
                param($MockDir)
                $result = Test-WorktreeRemovalPreflight -WorktreePath '/repo/sibling'
                $result.Skip | Should -Be $false
                $result.Reason | Should -BeNullOrEmpty
            }
        }
    }
}
