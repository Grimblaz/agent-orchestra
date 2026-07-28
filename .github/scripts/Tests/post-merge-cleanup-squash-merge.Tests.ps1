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

        $script:SetRepoFileExact = {
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
            [System.IO.File]::WriteAllText($filePath, $Content, [System.Text.UTF8Encoding]::new($false))
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

        # Issue #922: the gh shims below were Windows-only — a `gh.ps1` plus a
        # `gh.cmd` batch wrapper. On Linux neither is resolvable by the bare name
        # `gh`, so `Get-Command gh` failed, the eligibility primitive reported
        # "gh unavailable", and any fixture depending on gh evidence silently took
        # the retain path. That is why S3 failed on the runner and passed on
        # Windows: on Linux its cherry-pick reproduced the original commit's exact
        # SHA (identical tree, parent, message and committer second), leaving zero
        # unique commits, which routes to the gh-dependent zero-commit rung — the
        # one rung the shim could not serve there.
        #
        # This writes an extensionless POSIX wrapper alongside, with the execute
        # bit set, so the same fixture means the same thing on both platforms.
        $script:AddPosixGhShim = {
            param([Parameter(Mandatory)][string]$ShimPath)

            if ($IsWindows) { return }

            $posixWrapper = "#!/bin/sh`nexec pwsh -NoProfile -NonInteractive -File `"`$(dirname `"`$0`")/gh.ps1`" `"`$@`"`n"
            $target = Join-Path $ShimPath 'gh'
            [System.IO.File]::WriteAllText($target, $posixWrapper, [System.Text.UTF8Encoding]::new($false))
            & chmod +x $target 2>&1 | Out-Null
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
            & $script:AddPosixGhShim -ShimPath $shimPath

            return $shimPath
        }

        $script:NewPassingGhShim = {
            param(
                [Parameter(Mandatory)]
                [string]$ParentPath,

                [string]$State = 'CLOSED',
                [string]$StateReason = 'COMPLETED',
                [int]$PRNumber = 1,
                [string]$MergedAt = '2026-01-01T00:00:00Z',
                [string]$HeadRefOidBranch = '',
                [string]$HeadRefOid = '',
                [switch]$EmptyPRList
            )

            $shimPath = Join-Path $ParentPath "path-shim-$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $shimPath -Force | Out-Null

            # Resolve headRefOid at shim creation time
            $resolvedOid = $HeadRefOid
            if (-not $resolvedOid -and $HeadRefOidBranch) {
                $resolvedOid = (git rev-parse $HeadRefOidBranch 2>$null).Trim()
            }

            $issueJsonContent = "{""state"":""$State"",""stateReason"":""$StateReason""}"
            $prJsonContent     = if ($EmptyPRList) { '[]' } else { "[{""number"":$PRNumber,""mergedAt"":""$MergedAt"",""headRefOid"":""$resolvedOid""}]" }

            $ghMock = @"
param()
`$callLogPath = Join-Path `$PSScriptRoot 'gh-calls.log'
(`$args -join "`t") | Add-Content -Path `$callLogPath -Encoding utf8
if (`$args -contains 'issue' -and `$args -contains 'view') {
    Write-Output '$issueJsonContent'
    exit 0
}
if (`$args -contains 'pr' -and `$args -contains 'list') {
    Write-Output '$prJsonContent'
    exit 0
}
Write-Error "Unexpected gh invocation: `$(`$args -join ' ')"
exit 1
"@
            Set-Content -Path (Join-Path $shimPath 'gh.ps1') -Value $ghMock -Encoding utf8NoBOM
            $cmdContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0gh.ps1`" %*`r`nexit %ERRORLEVEL%"
            Set-Content -Path (Join-Path $shimPath 'gh.cmd') -Value $cmdContent -Encoding ascii
            & $script:AddPosixGhShim -ShimPath $shimPath
            return $shimPath
        }

        $script:InvokeCleanup = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,

                [Parameter(Mandatory)]
                [string]$BranchName,

                [switch]$UseNativeErrorPreference
            )

            $shimPath = & $script:NewFailingGhShim -ParentPath $RepoPath
            $pathSeparator = [System.IO.Path]::PathSeparator

            try {
                $env:PATH = "$shimPath$pathSeparator$script:SavedPath"
                Push-Location -LiteralPath $RepoPath
                try {
                    if ($UseNativeErrorPreference) {
                        $escapedScriptFile = $script:ScriptFile.Replace("'", "''")
                        $escapedBranchName = $BranchName.Replace("'", "''")
                        $command = "`$PSNativeCommandUseErrorActionPreference = `$true; & '$escapedScriptFile' -OrphanBranches '$escapedBranchName'"
                        $scriptOutput = pwsh -NoProfile -NonInteractive -Command $command 2>&1
                    }
                    else {
                        $scriptOutput = pwsh -NoProfile -NonInteractive -File $script:ScriptFile -OrphanBranches $BranchName 2>&1
                    }
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

        $script:InvokeCleanupWithGh = {
            param(
                [Parameter(Mandatory)]
                [string]$RepoPath,
                [Parameter(Mandatory)]
                [string]$BranchName,
                [Parameter(Mandatory)]
                [string]$GhShimPath
            )

            $pathSeparator = [System.IO.Path]::PathSeparator
            $env:PATH = "$GhShimPath$pathSeparator$script:SavedPath"
            try {
                Push-Location -LiteralPath $RepoPath
                try {
                    $scriptOutput = pwsh -NoProfile -NonInteractive -File $script:ScriptFile -OrphanBranches $BranchName 2>&1
                    $exitCode = $LASTEXITCODE
                }
                finally {
                    Pop-Location
                }

                $ghCallLogPath = Join-Path $GhShimPath 'gh-calls.log'
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

    It 'deletes a squash-merged orphan branch through branch deletion fallback when native command error preference is enabled' {
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
        & git -C $repoPath merge-base --is-ancestor $branch main 2>$null
        $LASTEXITCODE | Should -Not -Be 0 -Because 'the squash fixture must require git branch -d to fall back to forced deletion'

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch -UseNativeErrorPreference

        $result.ExitCode | Should -Be 0 -Because 'expected git branch -d failure must not abort cleanup when the native command error preference is true'
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'tree-equivalent squash-merged branches are safe orphans and should be deleted'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 orphan branch(es): $branch"))
        $result.GhCalls | Should -HaveCount 0 -Because 'squash detection must stay local and offline'
    }

    It 'deletes an accumulated squash-merged orphan after main advances' {
        $repoPath = & $script:NewSyntheticRepo -Name 'advanced-main-squash-orphan'
        $branch = 'pester-temp/issue-513-advanced-main-squash'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'feature.txt' -Content "feature value`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'feature commit'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
        & $script:InvokeGit -RepoPath $repoPath -Arguments @('merge', '--squash', $branch) | Out-Null
        & $script:CommitAll -RepoPath $repoPath -Message 'squash feature'
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'unrelated.txt' -Content "main advanced`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'advance main after squash'
        & $script:PushMain -RepoPath $repoPath

        (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'the branch tree no longer equals the current remote default after main advances'

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch

        $result.ExitCode | Should -Be 0
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'merge-tree no-op detection should delete accumulated squash branches after main advances'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 orphan branch(es): $branch"))
        $result.GhCalls | Should -HaveCount 0 -Because 'advanced-main squash detection must stay local and offline'
    }

    It 'deletes a branch whose only difference from main is CR at EOL' {
        $repoPath = & $script:NewSyntheticRepo -Name 'crlf-only-orphan'
        $branch = 'pester-temp/issue-513-crlf-only'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
        & $script:SetRepoFileExact -RepoPath $repoPath -RelativePath 'line-endings.txt' -Content "one`r`ntwo`r`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'add CRLF content'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
        & $script:SetRepoFileExact -RepoPath $repoPath -RelativePath 'line-endings.txt' -Content "one`ntwo`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'add LF equivalent content'
        & $script:PushMain -RepoPath $repoPath

        (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'the fixture must differ at the byte level without --ignore-cr-at-eol'

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch

        $result.ExitCode | Should -Be 0
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because '--ignore-cr-at-eol should classify CRLF-only differences as safe'
        $result.Output | Should -Match ([regex]::Escape("Deleted 1 orphan branch(es): $branch"))
        $result.GhCalls | Should -HaveCount 0 -Because 'CRLF-only detection should not require GitHub'
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
        $result.Output | Should -Match 'auto-resolve declined'
        $result.GhCalls | Should -HaveCount 0 -Because 'unmerged detection should not require GitHub'
    }

    It 'skips a genuinely unmerged branch when native command error preference is enabled' {
        $repoPath = & $script:NewSyntheticRepo -Name 'native-command-preference-unmerged'
        $branch = 'pester-temp/issue-513-native-pref-unmerged'

        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
        & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'native-pref-unmerged.txt' -Content "work not on main`n"
        & $script:CommitAll -RepoPath $repoPath -Message 'native preference unmerged work'
        & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
        & $script:PushMain -RepoPath $repoPath

        (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'git diff exit 1 is ordinary unmerged control flow in this fixture'

        $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch -UseNativeErrorPreference

        $result.ExitCode | Should -Be 0 -Because 'expected non-zero native exits should not abort cleanup when the preference is true'
        (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeTrue -Because 'genuinely unmerged work must still be preserved'
        $result.Output | Should -Match ([regex]::Escape("Skipped '$branch'"))
        $result.Output | Should -Match 'auto-resolve declined'
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

    Context 'auto-resolve eligible orphan branches (Issue #548)' {
        It 'S1: no-regression — squash-fingerprint orphan deletes via existing path without calling gh' {
            # This re-asserts that the squash-fingerprint (tree-equivalent) path still works.
            # Test-BranchMergedIntoDefault short-circuits before new helper runs.
            $repoPath = & $script:NewSyntheticRepo -Name 's1-squash-fingerprint'
            $branch   = 'feature/issue-548-s1-squash'

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 's1.txt' -Content "A`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'feature A'
            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 's1.txt' -Content "A`nB`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'feature B'

            # Squash onto main
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('merge', '--squash', $branch) | Out-Null
            & $script:CommitAll -RepoPath $repoPath -Message 'squash AB'
            & $script:PushMain -RepoPath $repoPath

            # Verify squash precondition
            (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeTrue

            $result = & $script:InvokeCleanup -RepoPath $repoPath -BranchName $branch
            $result.ExitCode   | Should -Be 0
            $result.GhCalls    | Should -HaveCount 0 -Because 'squash-fingerprint deletion must stay offline'
            (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse
        }

        It 'S2: spike-only orphan auto-resolves via new helper when gh signals CLOSED+matched' {
            $repoPath = & $script:NewSyntheticRepo -Name 's2-spike-only'
            $branch   = 'feature/issue-548-s2-spike'

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
            $spikeDir = Join-Path $repoPath '.tmp/issue-548'
            New-Item -ItemType Directory -Path $spikeDir -Force | Out-Null
            Set-Content -Path (Join-Path $spikeDir 'spike.md') -Value 'spike notes'
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('add', '-A') | Out-Null
            & $script:CommitAll -RepoPath $repoPath -Message 'add spike notes'

            # Push main WITHOUT the spike commit → branch has cherry+ lines
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
            & $script:PushMain -RepoPath $repoPath

            # Non-zero tree diff precondition (spike file not on main)
            (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse

            # Capture branch tip for headRefOid
            $branchTip = (& git -C $repoPath rev-parse $branch 2>$null).Trim()
            $shimPath  = & $script:NewPassingGhShim -ParentPath $repoPath -State 'CLOSED' -HeadRefOid $branchTip

            $result = & $script:InvokeCleanupWithGh -RepoPath $repoPath -BranchName $branch -GhShimPath $shimPath
            $result.ExitCode | Should -Be 0
            (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'spike-only orphan should be auto-resolved'
        }

        It 'S3: stray-but-reachable orphan auto-resolves via ancestor sub-case' {
            $repoPath = & $script:NewSyntheticRepo -Name 's3-stray-ancestor'
            $branch   = 'feature/issue-548-s3-ancestor'

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'stray.txt' -Content "stray`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'stray commit'

            # Cherry-pick stray onto main (same content, same patch).
            #
            # Issue #922: committed with a DIFFERENT message on purpose. A plain
            # `cherry-pick` preserves the original message, so when the replay lands
            # in the same committer second it reproduces the source commit's exact
            # SHA — main and the branch then point at one commit, the branch has
            # ZERO unique commits, and the test silently exercises the zero-commit
            # rung instead of the absorption chain it is named for. That is a race,
            # not a platform difference; it merely surfaced on the Linux runner
            # first. Patch-id is content-derived, so a different message keeps the
            # commit patch-equivalent while guaranteeing a distinct SHA.
            $strayCommit = (& git -C $repoPath rev-parse $branch 2>$null).Trim()
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('cherry-pick', '--no-commit', $strayCommit) | Out-Null
            & $script:CommitAll -RepoPath $repoPath -Message 'stray commit (replayed onto main)'
            & $script:PushMain -RepoPath $repoPath

            # Issue #922: this fixture asserted its OUTCOME without ever checking
            # its own PRECONDITION. `cherry-pick`'s output is swallowed, so if it
            # fails — as it evidently does on the Linux runner, where this test is
            # the single failure in an otherwise green suite — main never receives
            # the content, and the test reports "the branch was not absorbed" while
            # the real cause is that the fixture was never built. Assert the
            # precondition so the failure names itself.
            $mainHasStray = @(& git -C $repoPath ls-tree -r --name-only main 2>$null)
            $mainHasStray | Should -Contain 'stray.txt' `
                -Because 'the fixture requires the stray commit to have been cherry-picked onto main; if this fails, the cherry-pick did, and the outcome assertion below is meaningless'

            # The cherry-pick landing is necessary but not sufficient: this test's
            # premise is that the branch is TREE-IDENTICAL to the remote default, so
            # the merged check clears it on content evidence with no gh call. Pin
            # that directly, and report the actual signal state on failure, so a
            # platform difference localises itself instead of surfacing as the
            # downstream "branch was not absorbed".
            $branchTree = (& git -C $repoPath rev-parse "${branch}^{tree}" 2>$null)
            $remoteTree = (& git -C $repoPath rev-parse 'origin/main^{tree}' 2>$null)
            & git -C $repoPath diff --quiet --ignore-cr-at-eol 'origin/main' $branch 2>$null
            $tolerantDiffExit = $LASTEXITCODE
            "$branchTree" | Should -BeExactly "$remoteTree" `
                -Because "the branch must be tree-identical to origin/main for this fixture to mean what it claims (tolerant diff exit was $tolerantDiffExit)"

            # Pin the shape this test is named for: the branch must still carry its
            # own commit, or it is exercising the zero-commit rung instead of the
            # patch-equivalence absorption chain.
            $uniqueCount = (& git -C $repoPath rev-list "origin/main..$branch" --count 2>$null)
            "$uniqueCount".Trim() | Should -BeExactly '1' `
                -Because 'S3 is the stray-but-reachable ANCESTOR sub-case; a branch with zero unique commits takes a different path entirely'

            # git cherry should show '-' for the feature commit (patch-equivalent)
            $branchTip = (& git -C $repoPath rev-parse $branch 2>$null).Trim()
            $shimPath  = & $script:NewPassingGhShim -ParentPath $repoPath -State 'CLOSED' -HeadRefOid $branchTip

            $result = & $script:InvokeCleanupWithGh -RepoPath $repoPath -BranchName $branch -GhShimPath $shimPath

            $result.ExitCode | Should -Be 0
            # With the fixture pinned to one unique commit and a tree identical to
            # origin/main, this resolves on content evidence alone. Asserting the
            # absence of gh traffic keeps that true: if a future change routes this
            # shape through a network rung, it will be visible here rather than
            # showing up as a platform-dependent flake.
            @($result.GhCalls).Count | Should -Be 0 `
                -Because 'a tree-identical branch is merged on local evidence; no gh call is needed on either platform'
            (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'patch-equivalent stray commit should be absorbed'
        }

        It 'S3b: tree-at-HEAD orphan auto-resolves via fourth sub-case (reworded squash)' {
            $repoPath = & $script:NewSyntheticRepo -Name 's3b-tree-at-head'
            $branch   = 'feature/issue-548-s3b-tree'

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'src/helper.ps1' -Content "Write-Output 'helper'`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'add helper (feature commit)'

            # Main: same content, different commit message (different patch-id)
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'src/helper.ps1' -Content "Write-Output 'helper'`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'ship helper via reworded squash'
            & $script:PushMain -RepoPath $repoPath

            # Tree diff: main now has src/helper.ps1 with same content → tree-equivalent at path level
            # But commit diff: different commit messages → different patch-id → cherry shows '+'
            $branchTip = (& git -C $repoPath rev-parse $branch 2>$null).Trim()
            $shimPath  = & $script:NewPassingGhShim -ParentPath $repoPath -State 'CLOSED' -HeadRefOid $branchTip

            $result = & $script:InvokeCleanupWithGh -RepoPath $repoPath -BranchName $branch -GhShimPath $shimPath
            $result.ExitCode | Should -Be 0
            (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'tree-at-HEAD-equivalent orphan should be auto-resolved via fourth sub-case'
        }

        It 'S4: open parent issue returns auto-resolve declined' {
            $repoPath = & $script:NewSyntheticRepo -Name 's4-open-parent'
            $branch   = 'feature/issue-548-s4-open'

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'work.txt' -Content "wip`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'wip'
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
            & $script:PushMain -RepoPath $repoPath

            # Non-zero tree diff
            (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse

            $branchTip = (& git -C $repoPath rev-parse $branch 2>$null).Trim()
            $shimPath  = & $script:NewPassingGhShim -ParentPath $repoPath -State 'OPEN' -HeadRefOid $branchTip

            $result = & $script:InvokeCleanupWithGh -RepoPath $repoPath -BranchName $branch -GhShimPath $shimPath
            $result.ExitCode | Should -Be 0
            $result.Output   | Should -Match 'auto-resolve declined'
            (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeTrue -Because 'open parent issue should not trigger auto-delete'
        }

        It 'S5a: CLOSED+NOT_PLANNED parent allows auto-delete (D-state-reason)' {
            $repoPath = & $script:NewSyntheticRepo -Name 's5a-not-planned'
            $branch   = 'feature/issue-548-s5a-notplanned'

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
            $spikeDir = Join-Path $repoPath '.tmp/issue-548'
            New-Item -ItemType Directory -Path $spikeDir -Force | Out-Null
            Set-Content -Path (Join-Path $spikeDir 'notes.md') -Value 'planned work'
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('add', '-A') | Out-Null
            & $script:CommitAll -RepoPath $repoPath -Message 'planned work (not-planned closure)'
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
            & $script:PushMain -RepoPath $repoPath

            (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse

            $branchTip = (& git -C $repoPath rev-parse $branch 2>$null).Trim()
            $shimPath  = & $script:NewPassingGhShim -ParentPath $repoPath -State 'CLOSED' -StateReason 'NOT_PLANNED' -HeadRefOid $branchTip

            $result = & $script:InvokeCleanupWithGh -RepoPath $repoPath -BranchName $branch -GhShimPath $shimPath
            $result.ExitCode | Should -Be 0
            (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeFalse -Because 'CLOSED with NOT_PLANNED should allow auto-delete per D-state-reason'
        }

        It 'S5b: CLOSED parent + empty PR list returns auto-resolve declined' {
            $repoPath = & $script:NewSyntheticRepo -Name 's5b-empty-pr'
            $branch   = 'feature/issue-548-s5b-emptyprs'

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'work.txt' -Content "work`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'work'
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
            & $script:PushMain -RepoPath $repoPath

            (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse

            $shimPath = & $script:NewPassingGhShim -ParentPath $repoPath -State 'CLOSED' -EmptyPRList

            $result = & $script:InvokeCleanupWithGh -RepoPath $repoPath -BranchName $branch -GhShimPath $shimPath
            $result.ExitCode | Should -Be 0
            $result.Output   | Should -Match 'auto-resolve declined'
            (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeTrue
        }

        It 'S6: gh non-zero exit returns could not verify auto-resolve signals' {
            $repoPath = & $script:NewSyntheticRepo -Name 's6-gh-fail'
            $branch   = 'feature/issue-548-s6-ghfail'

            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', '-b', $branch) | Out-Null
            & $script:SetRepoFile -RepoPath $repoPath -RelativePath 'work.txt' -Content "work`n"
            & $script:CommitAll -RepoPath $repoPath -Message 'work'
            & $script:InvokeGit -RepoPath $repoPath -Arguments @('checkout', 'main') | Out-Null
            & $script:PushMain -RepoPath $repoPath

            (& $script:TestTreeEquivalentToMain -RepoPath $repoPath -BranchName $branch) | Should -BeFalse

            $shimPath = & $script:NewFailingGhShim -ParentPath $repoPath

            $result = & $script:InvokeCleanupWithGh -RepoPath $repoPath -BranchName $branch -GhShimPath $shimPath
            $result.ExitCode | Should -Be 0
            $result.Output   | Should -Match 'could not verify auto-resolve signals'
            (& $script:TestLocalBranchExists -RepoPath $repoPath -BranchName $branch) | Should -BeTrue
        }
    }
}