#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'post-merge-cleanup.ps1 - squash-merge orphan cleanup (Issue #513)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/post-merge-cleanup.ps1'
        $script:SavedPath = $env:PATH

        $script:InvokeGit = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,

                [Parameter(Mandatory)]
                [string[]]$Arguments
            )

            $gitOutput = & git -C $RepoPath @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "git -C '$RepoPath' $($Arguments -join ' ') failed with exit $LASTEXITCODE.`n$($gitOutput | Out-String)"
            }
            return $gitOutput
        }

        $script:InvokeGitInit = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,

                [switch]$Bare
            )

            $initArguments = @(
                '-c', 'init.defaultBranch=main',
                '-c', 'core.autocrlf=false',
                '-c', 'commit.gpgsign=false',
                'init'
            )
            if ($Bare) { $initArguments += '--bare' }
            $initArguments += $RepoPath

            $gitOutput = & git @initArguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "git $($initArguments -join ' ') failed with exit $LASTEXITCODE.`n$($gitOutput | Out-String)"
            }
        }

        $script:SetRepoFile = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,

                [Parameter(Mandatory)]
                [string]$RelativePath,

                [Parameter(Mandatory)]
                [string]$Content
            )

            $filePath = Join-Path $RepoPath $RelativePath
            $parentPath = Split-Path -Parent $filePath
            if (-not (Test-Path -LiteralPath $parentPath)) {
                New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
            }
            Set-Content -Path $filePath -Value $Content -Encoding utf8NoBOM
        }

        $script:CommitAll = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,

                [Parameter(Mandatory)]
                [string]$Message
            )

            & $script:InvokeGit -RepoPath $RepoPath -Arguments @('add', '--all') | Out-Null
            & $script:InvokeGit -RepoPath $RepoPath -Arguments @('commit', '-m', $Message) | Out-Null
        }

        $script:NewSyntheticRepo = {
            param(
                [Parameter(Mandatory)]
                [string]$Name
            )

            $repoPath = Join-Path $TestDrive $Name
            $originPath = Join-Path $TestDrive "$Name-origin.git"
            New-Item -ItemType Directory -Path $repoPath -Force | Out-Null

            & $script:InvokeGitInit -RepoPath $repoPath
            & $script:InvokeGitInit -RepoPath $originPath -Bare

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('config', 'user.name', 'Pester Fixture') | Out-Null
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('config', 'user.email', 'pester@example.invalid') | Out-Null
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('config', 'commit.gpgsign', 'false') | Out-Null
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('config', 'core.autocrlf', 'false') | Out-Null

            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'app.txt' -Content "base`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'base commit'

            $originGitPath = $originPath -replace '\\', '/'
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('remote', 'add', 'origin', $originGitPath) | Out-Null
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('push', '-u', 'origin', 'main') | Out-Null
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main') | Out-Null

            return $repoPath
        }

        $script:PushMain = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath
            )

            & $script:InvokeGit -RepoPath $RepoPath -Arguments @('push', 'origin', 'main') | Out-Null
            & $script:InvokeGit -RepoPath $RepoPath -Arguments @('fetch', 'origin', '--prune') | Out-Null
            & $script:InvokeGit -RepoPath $RepoPath -Arguments @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main') | Out-Null
        }

        $script:NewFailingGhShim = {
            param(
                [Parameter(Mandatory)]
                [string]$ParentPath
            )

            $shimPath = Join-Path $ParentPath "path-shim-$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $shimPath -Force | Out-Null

            $ghMock = @'
param()
$callLogPath = Join-Path $PSScriptRoot 'gh-calls.log'
($args -join "`t") | Add-Content -Path $callLogPath -Encoding utf8
Write-Error 'gh should not be called by offline post-merge cleanup fixtures'
exit 64
'@
            Set-Content -Path (Join-Path $shimPath 'gh.ps1') -Value $ghMock -Encoding utf8NoBOM

            $cmdContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0gh.ps1`" %*`r`nexit %ERRORLEVEL%"
            Set-Content -Path (Join-Path $shimPath 'gh.cmd') -Value $cmdContent -Encoding ascii

            return $shimPath
        }

        $script:InvokeCleanup = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,

                [Parameter(Mandatory)]
                [string]$BranchName
            )

            $shimPath = & $script:NewFailingGhShim -ParentPath $RepoPath
            $pathSeparator = [System.IO.Path]::PathSeparator

            try {
                $env:PATH = "$shimPath$pathSeparator$script:SavedPath"
                Push-Location -LiteralPath $RepoPath
                try {
                    $scriptOutput = pwsh -NoProfile -NonInteractive -File $script:ScriptFile -OrphanBranches $BranchName 2>&1
                    $exitCode = $LASTEXITCODE
                }
                finally {
                    Pop-Location
                }

                $ghCallLogPath = Join-Path $shimPath 'gh-calls.log'
                $ghCalls = if (Test-Path -LiteralPath $ghCallLogPath) {
                    @(Get-Content -Path $ghCallLogPath -ErrorAction SilentlyContinue)
                }
                else { @() }

                return [pscustomobject]@{
                    ExitCode = $exitCode
                    Output   = ($scriptOutput | Out-String).Trim()
                    GhCalls  = $ghCalls
                }
            }
            finally {
                $env:PATH = $script:SavedPath
            }
        }

        $script:TestLocalBranchExists = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,

                [Parameter(Mandatory)]
                [string]$BranchName
            )

            & git -C $RepoPath show-ref --verify --quiet "refs/heads/$BranchName" 2>$null
            return ($LASTEXITCODE -eq 0)
        }

        $script:TestTreeEquivalentToMain = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,

                [Parameter(Mandatory)]
                [string]$BranchName
            )

            & git -C $RepoPath diff --quiet origin/main $BranchName 2>$null
            return ($LASTEXITCODE -eq 0)
        }
    }

    AfterAll {
        $env:PATH = $script:SavedPath
    }

    It 'deletes a squash-merged orphan branch whose branch commits are tree-equivalent to main' {
        $repoPath = & $script:NewSyntheticRepo -Name 'squash-merged-orphan'
        $branch = 'pester-temp/issue-513-squash-merged'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'feature.txt' -Content "A`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'feature A'
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'feature.txt' -Content "A`nB`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'feature B'
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'feature.txt' -Content "A`nB`nC`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'feature C'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
        & $script:InvokeGit -RepoPath $repoPath -Arguments @('merge', '--squash', $branch) | Out-Null
        & $script:CommitAll -RepoPath $repoPath -Message 'squash feature ABC'
        & $script:PushMain -RepoPath $repoPath

        (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeTrue -Because 'the squash fixture must model a branch whose final tree is already on main'

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch

        $result.ExitCode | Should -Be 0
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'tree-equivalent squash-merged branches are safe orphans and should be deleted'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 orphan branch(es): $branch"))
        $result.GhCalls | Should -HaveCount 0 -Because 'squash detection must stay local and offline'
    }

    It 'skips a genuinely unmerged orphan branch with a non-empty tree diff' {
        $repoPath = & $script:NewSyntheticRepo -Name 'genuinely-unmerged-orphan'
        $branch = 'pester-temp/issue-513-unmerged'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'unmerged.txt' -Content "work not on main`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'unmerged work'
        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
        & $script:PushMain -RepoPath $repoPath

        (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'the unmerged fixture must have a non-empty tree diff'

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch

        $result.ExitCode | Should -Be 0
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeTrue -Because 'genuinely unmerged work must not be deleted'
        $result.Output | Should -Match ([regex]::Escape("Skipped '$branch'"))
        $result.Output | Should -Match 'unmerged commits'
        $result.GhCalls | Should -HaveCount 0 -Because 'unmerged detection should not require GitHub'
    }

    It 'deletes a rebase-merged orphan branch whose patches are already on main' {
        $repoPath = & $script:NewSyntheticRepo -Name 'rebase-merged-orphan'
        $branch = 'pester-temp/issue-513-rebase-merged'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'rebased.txt' -Content "one`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'rebased one'
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'rebased.txt' -Content "one`ntwo`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'rebased two'
        $branchCommits = @(& git -C $repoPath rev-list --reverse "main..$branch")

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
        foreach ($commitId in $branchCommits) {
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('cherry-pick', $commitId) | Out-Null
        }
        & $script:PushMain -RepoPath $repoPath

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch

        $result.ExitCode | Should -Be 0
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'patch-equivalent rebase-merged branches are safe to delete'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 orphan branch(es): $branch"))
        $result.GhCalls | Should -HaveCount 0 -Because 'rebase-merged detection should not require GitHub'
    }

    It 'deletes a plain merge-commit orphan branch whose tip is in main history' {
        $repoPath = & $script:NewSyntheticRepo -Name 'plain-merge-commit-orphan'
        $branch = 'pester-temp/issue-513-merge-commit'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'merged.txt' -Content "merged through a merge commit`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'plain merge feature'
        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
        & $script:InvokeGit -RepoPath $repoPath -Arguments @('merge', '--no-ff', $branch, '-m', 'merge feature branch') | Out-Null
        & $script:PushMain -RepoPath $repoPath

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch

        $result.ExitCode | Should -Be 0
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'plain merged branches should be deleted by the cleanup script'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 orphan branch(es): $branch"))
        $result.GhCalls | Should -HaveCount 0 -Because 'plain merge detection should not require GitHub'
    }

    It 'deletes an empty orphan branch with no commits beyond main' {
        $repoPath = & $script:NewSyntheticRepo -Name 'empty-orphan'
        $branch = 'pester-temp/issue-513-empty'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
        & $script:PushMain -RepoPath $repoPath

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch

        $result.ExitCode | Should -Be 0
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'branches with no commits beyond main are safe orphans'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 orphan branch(es): $branch"))
        $result.GhCalls | Should -HaveCount 0 -Because 'empty branch detection should not require GitHub'
    }
}