#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Deterministic git-mock tests for the planned Branch Authority Gate helper.

.DESCRIPTION
    Deterministic git-mock tests for the Branch Authority Gate helper (issue #205):
      - .github/scripts/lib/branch-authority-gate.ps1

        The helper exposes a testable decision surface that:
            - returns a no-mutation continue result when the live current branch already satisfies the intended working state
            - treats multiple feature/issue-205* branches as ambiguity that must be reconciled before mutation
            - consults git rev-parse only when ambiguity exists
            - keeps same-tip duplicate branches blocked for rename and cleanup
            - keeps divergent branches blocked

        These tests lock the landed branch-authority behavior for issue #205; update them only when the contract semantics intentionally change.
#>

Describe 'branch-authority-gate.ps1' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HelperPath = Join-Path $script:RepoRoot '.github\scripts\lib\branch-authority-gate.ps1'
        $script:SavedPath = $env:PATH

        $script:LoadSubject = {
            (Test-Path $script:HelperPath) | Should -BeTrue -Because 'issue #205 requires a dedicated branch-authority helper under .github/scripts/lib'

            . $script:HelperPath

            Get-Command -Name 'Get-BranchAuthorityGateDecision' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because 'issue #205 requires a testable branch-authority decision surface'
        }

        $script:NewMockGitDir = {
            param(
                [string]$ParentDir,
                [hashtable]$Config
            )

            $mockDir = Join-Path $ParentDir "git-mock-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $mockDir -Force | Out-Null

            $Config | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $mockDir 'git-mock-config.json') -Encoding UTF8

            $mockPs1 = @'
param()
$configPath = Join-Path $PSScriptRoot 'git-mock-config.json'
$logPath = Join-Path $PSScriptRoot 'git-invocations.log'
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$a = $args

Add-Content -Path $logPath -Value ($a -join ' ')

if ($a.Count -ge 2 -and $a[0] -eq 'branch' -and $a[1] -eq '--show-current') {
    $val = $config.'branch--show-current'
    if ($null -ne $val) { Write-Output $val }
    $exitCode = if ($null -ne $config.'exit-branch--show-current') { [int]$config.'exit-branch--show-current' } else { 0 }
    exit $exitCode
}

if ($a.Count -ge 3 -and $a[0] -eq 'branch' -and $a[1] -eq '--list') {
    $pattern = $a[2]
    $exitCode = if ($null -ne $config.'exit-branch--list') { [int]$config.'exit-branch--list' } else { 0 }
    $exactKey = "branch-list-$pattern"
    if ($null -ne $config.$exactKey) {
        foreach ($entry in @($config.$exactKey)) {
            Write-Output $entry
        }
        exit $exitCode
    }

    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -like 'branch-list-*') {
            $keyPattern = $prop.Name.Substring('branch-list-'.Length)
            if ($pattern -like $keyPattern) {
                foreach ($entry in @($prop.Value)) {
                    Write-Output $entry
                }
                exit $exitCode
            }
        }
    }

    exit $exitCode
}

if ($a.Count -ge 2 -and $a[0] -eq 'rev-parse') {
    $ref = $a[-1]
    $exactKey = "rev-parse-$ref"
    if ($null -ne $config.$exactKey) {
        Write-Output $config.$exactKey
        exit 0
    }

    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -like 'rev-parse-*') {
            $keyPattern = $prop.Name.Substring('rev-parse-'.Length)
            if ($ref -like $keyPattern) {
                Write-Output $prop.Value
                exit 0
            }
        }
    }

    exit 128
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

        $script:NewGitConfig = {
            param(
                [string]$CurrentBranch,
                [string[]]$IssueBranches,
                [hashtable]$BranchCommits = @{},
                [int]$CurrentBranchExitCode = 0,
                [int]$IssueBranchListExitCode = 0
            )

            $config = @{
                'branch--show-current'            = $CurrentBranch
                'branch-list-feature/issue-205*' = @($IssueBranches | ForEach-Object { "  $_" })
                'exit-branch--show-current'      = $CurrentBranchExitCode
                'exit-branch--list'              = $IssueBranchListExitCode
            }

            foreach ($branchName in $BranchCommits.Keys) {
                $config["rev-parse-$branchName"] = $BranchCommits[$branchName]
            }

            return $config
        }

        $script:InvokeGate = {
            param(
                [hashtable]$GitConfig,
                [string]$RequestedAction,
                [string]$IntendedBranch = 'feature/issue-205-branch-authority-gate',
                [string]$AttachedBranchContext = 'feature/issue-205-stale-context'
            )

            $workDir = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null

            $mockDir = & $script:NewMockGitDir -ParentDir $workDir -Config $GitConfig
            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"

                Push-Location $workDir
                try {
                    . $script:LoadSubject

                    $result = Get-BranchAuthorityGateDecision `
                        -IssueNumber 205 `
                        -RequestedAction $RequestedAction `
                        -IntendedBranch $IntendedBranch `
                        -AttachedBranchContext $AttachedBranchContext

                    $logPath = Join-Path $mockDir 'git-invocations.log'
                    $invocations = if (Test-Path $logPath) { Get-Content -Path $logPath } else { @() }

                    return @{
                        Result      = $result
                        Invocations = $invocations
                    }
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

        $script:GetRevParseCallCount = {
            param([string[]]$Invocations)

            return @($Invocations | Where-Object { $_ -match '^rev-parse\b' }).Count
        }

        $script:AssertIssueBranchEnumeration = {
            param([string[]]$Invocations)

            @($Invocations | Where-Object { $_ -match '^branch --list feature/issue-205\*$' }).Count |
                Should -BeGreaterThan 0 -Because 'the Branch Authority Gate must enumerate issue-scoped candidate branches using feature/issue-205*'
        }
    }

    AfterAll {
        $env:PATH = $script:SavedPath
    }

    It 'continues without mutation when the verified current branch already satisfies the intended working state' {
        $run = & $script:InvokeGate -RequestedAction 'create' -AttachedBranchContext 'feature/issue-205-branch-authority-gate' -GitConfig (& $script:NewGitConfig -CurrentBranch 'feature/issue-205-branch-authority-gate' -IssueBranches @('feature/issue-205-branch-authority-gate'))

        & $script:AssertIssueBranchEnumeration -Invocations $run.Invocations
        $run.Result.Outcome | Should -Be 'continue-no-mutation' -Because 'issue #205 allows automatic continuation only when live git already proves the intended working branch is active'
        $run.Result.VerifiedCurrentBranch | Should -Be 'feature/issue-205-branch-authority-gate' -Because 'the live current branch should be surfaced as the verified authority'
        $run.Result.RequiresBranchMutation | Should -BeFalse -Because 'no branch-changing action should run when the verified current branch already satisfies the intended state'
        (& $script:GetRevParseCallCount -Invocations $run.Invocations) | Should -Be 0 -Because 'git rev-parse is not part of the proof set unless ambiguity exists'
    }

    It 'blocks create when the intended issue branch already exists on another current branch' {
        $run = & $script:InvokeGate -RequestedAction 'create' -AttachedBranchContext '' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @('feature/issue-205-branch-authority-gate'))

        & $script:AssertIssueBranchEnumeration -Invocations $run.Invocations
        $run.Result.VerifiedCurrentBranch | Should -Be 'main' -Because 'the helper must still surface the live current branch when create is blocked'
        @($run.Result.MatchingIssueBranches) | Should -Be @('feature/issue-205-branch-authority-gate') -Because 'the helper must report that the intended issue branch already exists before deciding whether create can proceed'
        $run.Result.Outcome | Should -Be 'blocked' -Because 'issue #205 must not allow branch creation when the intended issue branch already exists but the live current branch is somewhere else'
        $run.Result.AuthorityStatus | Should -Be 'verified' -Because 'this case is a proven existing-branch conflict, not ambiguous branch identity'
        $run.Result.RequiresBranchMutation | Should -BeTrue -Because 'the blocked result should still report that reaching the intended issue branch would require a branch mutation rather than being treated as a no-op'
        (& $script:GetRevParseCallCount -Invocations $run.Invocations) | Should -Be 0 -Because 'a single matching issue branch is not an ambiguity case'
    }

    It 'treats multiple feature/issue-205 branches as ambiguity and consults git rev-parse before allowing mutation' {
        $run = & $script:InvokeGate -RequestedAction 'checkout' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @(
                'feature/issue-205-branch-authority-gate'
                'feature/issue-205-recovery-copy'
            ) -BranchCommits @{
                'feature/issue-205-branch-authority-gate' = '1111111111111111111111111111111111111111'
                'feature/issue-205-recovery-copy'         = '1111111111111111111111111111111111111111'
            })

        & $script:AssertIssueBranchEnumeration -Invocations $run.Invocations
        $run.Result.Outcome | Should -Be 'blocked' -Because 'multiple issue-scoped branches must stop mutation until authority is reconciled'
        $run.Result.AuthorityStatus | Should -Be 'ambiguous' -Because 'multiple feature/issue-205* branches are ambiguous until proven otherwise'
        (& $script:GetRevParseCallCount -Invocations $run.Invocations) | Should -BeGreaterThan 0 -Because 'git rev-parse must be consulted when more than one feature/issue-205* branch exists'
    }

    It 'consults git rev-parse only when ambiguity exists' {
        $unambiguous = & $script:InvokeGate -RequestedAction 'checkout' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @('feature/issue-205-branch-authority-gate'))

        $ambiguous = & $script:InvokeGate -RequestedAction 'checkout' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @(
                'feature/issue-205-branch-authority-gate'
                'feature/issue-205-recovery-copy'
            ) -BranchCommits @{
                'feature/issue-205-branch-authority-gate' = '1111111111111111111111111111111111111111'
                'feature/issue-205-recovery-copy'         = '2222222222222222222222222222222222222222'
            })

        (& $script:GetRevParseCallCount -Invocations $unambiguous.Invocations) | Should -Be 0 -Because 'issue #205 limits commit comparison to ambiguity handling only'
        (& $script:GetRevParseCallCount -Invocations $ambiguous.Invocations) | Should -BeGreaterThan 0 -Because 'issue #205 requires commit comparison after multiple feature/issue-205* branches are discovered'
    }

    It 'keeps same-tip duplicate branches blocked for rename and cleanup' -ForEach @(
        @{ RequestedAction = 'rename' }
        @{ RequestedAction = 'cleanup' }
    ) {
        $run = & $script:InvokeGate -RequestedAction $RequestedAction -GitConfig (& $script:NewGitConfig -CurrentBranch 'feature/issue-205-branch-authority-gate' -IssueBranches @(
                'feature/issue-205-branch-authority-gate'
                'feature/issue-205-duplicate'
            ) -BranchCommits @{
                'feature/issue-205-branch-authority-gate' = '1111111111111111111111111111111111111111'
                'feature/issue-205-duplicate'             = '1111111111111111111111111111111111111111'
            })

        $run.Result.Outcome | Should -Be 'blocked' -Because 'same-tip duplicates remain branch-identity ambiguity for rename and cleanup in issue #205'
        $run.Result.AmbiguityKind | Should -Be 'same-tip-duplicate' -Because 'same-commit duplicate branches should be surfaced explicitly rather than treated as safe to mutate'
        $run.Result.RequestedAction | Should -Be $RequestedAction -Because 'the stop result should document which branch-changing action remained blocked'
    }

    It 'keeps divergent issue branches blocked' {
        $run = & $script:InvokeGate -RequestedAction 'checkout' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @(
                'feature/issue-205-branch-authority-gate'
                'feature/issue-205-diverged'
            ) -BranchCommits @{
                'feature/issue-205-branch-authority-gate' = '1111111111111111111111111111111111111111'
                'feature/issue-205-diverged'              = '2222222222222222222222222222222222222222'
            })

        $run.Result.Outcome | Should -Be 'blocked' -Because 'divergent issue branches remain ambiguous and must block branch mutation'
        $run.Result.AuthorityStatus | Should -Be 'ambiguous' -Because 'divergent feature/issue-205* branches do not prove a single authoritative branch'
        $run.Result.AmbiguityKind | Should -Be 'divergent' -Because 'the helper must distinguish divergent history from same-tip duplication'
    }

    It 'blocks branch-changing actions when no matching feature/issue-205 branches exist' -ForEach @(
        @{ RequestedAction = 'checkout' }
        @{ RequestedAction = 'rename' }
        @{ RequestedAction = 'cleanup' }
    ) {
        $gitConfig = @{
            'branch--show-current'            = 'main'
            'branch-list-feature/issue-205*' = @()
            'exit-branch--show-current'      = 0
            'exit-branch--list'              = 0
        }

        $run = & $script:InvokeGate -RequestedAction $RequestedAction -AttachedBranchContext '' -GitConfig $gitConfig

        & $script:AssertIssueBranchEnumeration -Invocations $run.Invocations
        @($run.Result.MatchingIssueBranches).Count | Should -Be 0 -Because 'this scenario must cover the zero-candidate issue-branch case explicitly'
        $run.Result.Outcome | Should -Be 'blocked' -Because 'issue #205 requires branch-changing actions to fail safe when no issue-scoped branch authority can be proven'
        (& $script:GetRevParseCallCount -Invocations $run.Invocations) | Should -Be 0 -Because 'git rev-parse is only valid for ambiguity, not for zero-candidate branch-state proof'
    }

    It 'fails safe when git branch --show-current returns empty output' {
        {
            & $script:InvokeGate -RequestedAction 'checkout' -AttachedBranchContext '' -GitConfig (& $script:NewGitConfig -CurrentBranch '' -IssueBranches @('feature/issue-205-branch-authority-gate')) | Out-Null
        } | Should -Not -Throw -Because 'empty current-branch output should not crash the branch-authority helper'

        $decision = (& $script:InvokeGate -RequestedAction 'checkout' -AttachedBranchContext '' -GitConfig (& $script:NewGitConfig -CurrentBranch '' -IssueBranches @('feature/issue-205-branch-authority-gate'))).Result

        $decision.VerifiedCurrentBranch | Should -BeNullOrEmpty -Because 'the helper should surface that no current branch could be proven from git output'
        $decision.Outcome | Should -Be 'blocked' -Because 'issue #205 requires an empty current-branch proof result to fail safe rather than allowing mutation'
    }

    It 'fails safe when current branch lookup fails' {
        {
            & $script:InvokeGate -RequestedAction 'checkout' -AttachedBranchContext '' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @('feature/issue-205-branch-authority-gate') -CurrentBranchExitCode 128 -IssueBranchListExitCode 0) | Out-Null
        } | Should -Not -Throw -Because 'proof-command failures should produce a safe block decision instead of terminating the helper'

        $decision = (& $script:InvokeGate -RequestedAction 'checkout' -AttachedBranchContext '' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @('feature/issue-205-branch-authority-gate') -CurrentBranchExitCode 128 -IssueBranchListExitCode 0)).Result

        $decision.Outcome | Should -Be 'blocked' -Because 'issue #205 requires non-zero proof-command failures to block branch mutation'
        $decision.RequiresBranchMutation | Should -BeTrue -Because 'the helper should not quietly downgrade a blocked branch-changing action into an allowed mutation after proof failure'
    }

    It 'fails safe when issue branch enumeration fails' {
        {
            & $script:InvokeGate -RequestedAction 'checkout' -AttachedBranchContext '' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @('feature/issue-205-branch-authority-gate') -CurrentBranchExitCode 0 -IssueBranchListExitCode 128) | Out-Null
        } | Should -Not -Throw -Because 'proof-command failures should produce a safe block decision instead of terminating the helper'

        $decision = (& $script:InvokeGate -RequestedAction 'checkout' -AttachedBranchContext '' -GitConfig (& $script:NewGitConfig -CurrentBranch 'main' -IssueBranches @('feature/issue-205-branch-authority-gate') -CurrentBranchExitCode 0 -IssueBranchListExitCode 128)).Result

        $decision.Outcome | Should -Be 'blocked' -Because 'issue #205 requires non-zero proof-command failures to block branch mutation'
        $decision.RequiresBranchMutation | Should -BeTrue -Because 'the helper should not quietly downgrade a blocked branch-changing action into an allowed mutation after proof failure'
    }
}