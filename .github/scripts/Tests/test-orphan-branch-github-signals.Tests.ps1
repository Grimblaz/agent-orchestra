#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Unit tests for Test-OrphanBranchGitHubSignalsShipped.
#>

Describe 'Test-OrphanBranchGitHubSignalsShipped' {
    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HelpersPath = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-startup-git-helpers.ps1'
        $script:SavedPath  = $env:PATH
        $script:TempBase   = Join-Path ([System.IO.Path]::GetTempPath()) "pester-gh-signals-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempBase -Force | Out-Null

        # Create a minimal git repo for git rev-parse to work
        $script:RepoPath = Join-Path $script:TempBase 'repo'
        & git -c init.defaultBranch=main -c commit.gpgsign=false init $script:RepoPath 2>&1 | Out-Null
        & git -C $script:RepoPath -c user.email='test@test.com' -c user.name='Test' `
              commit --allow-empty -m 'init' 2>&1 | Out-Null
        & git -C $script:RepoPath checkout -b 'feature/issue-548-test' 2>&1 | Out-Null
        & git -C $script:RepoPath -c user.email='test@test.com' -c user.name='Test' `
              commit --allow-empty -m 'feature commit' 2>&1 | Out-Null
        $script:FeatureTip = (git -C $script:RepoPath rev-parse 'feature/issue-548-test' 2>$null).Trim()

        $script:MakeGhShim = {
            param(
                [string]$State = 'CLOSED',
                [string]$StateReason = 'COMPLETED',
                [string]$HeadRefOid = '',
                [switch]$EmptyPRList,
                [switch]$FailOnCall,
                [switch]$BadJson
            )
            $shimDir = Join-Path $script:TempBase "shim-$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $shimDir -Force | Out-Null

            $issueJson = if ($BadJson) { 'not-json' } else { "{""state"":""$State"",""stateReason"":""$StateReason""}" }
            $prJson    = if ($EmptyPRList) { '[]' } elseif ($BadJson) { 'not-json' } else { "[{""number"":1,""mergedAt"":""2026-01-01T00:00:00Z"",""headRefOid"":""$HeadRefOid""}]" }

            $mock = if ($FailOnCall) {
@'
param()
$callLogPath = Join-Path $PSScriptRoot 'gh-calls.log'
($args -join "`t") | Add-Content -Path $callLogPath -Encoding utf8
Write-Error 'gh shim: configured to fail'
exit 64
'@
            } else {
@"
param()
`$callLogPath = Join-Path `$PSScriptRoot 'gh-calls.log'
(`$args -join "`t") | Add-Content -Path `$callLogPath -Encoding utf8
if (`$args -contains 'issue' -and `$args -contains 'view') {
    Write-Output '$issueJson'
    exit 0
}
if (`$args -contains 'pr' -and `$args -contains 'list') {
    Write-Output '$prJson'
    exit 0
}
exit 1
"@
            }
            Set-Content -Path (Join-Path $shimDir 'gh.ps1') -Value $mock -Encoding utf8NoBOM
            $cmdContent = "@echo off`r`npwsh -NoProfile -NonInteractive -File `"%~dp0gh.ps1`" %*`r`nexit %ERRORLEVEL%"
            Set-Content -Path (Join-Path $shimDir 'gh.cmd') -Value $cmdContent -Encoding ascii
            return $shimDir
        }

        $script:InvokeHelper = {
            param(
                [string]$Branch = 'feature/issue-548-test',
                [string]$DefaultBranch = 'main',
                [string]$GhShimPath = '',
                [switch]$RemoveGh
            )
            # Load helpers in a subprocess so $script: scope is clean
            $helperPath = $script:HelpersPath.Replace("'", "''")
            $repoPath   = $script:RepoPath.Replace("'", "''")
            $branchArg  = $Branch.Replace("'", "''")
            $defaultArg = $DefaultBranch.Replace("'", "''")

            $command = @"
Push-Location '$repoPath'
. '$helperPath'
`$result = Test-OrphanBranchGitHubSignalsShipped -Branch '$branchArg' -DefaultBranch '$defaultArg'
if (`$null -eq `$result) { exit 2 }
elseif (`$result -eq `$true) { exit 0 }
else { exit 1 }
"@
            $sep = [System.IO.Path]::PathSeparator
            if ($RemoveGh) {
                # Remove gh from PATH entirely
                $pathParts = $env:PATH -split $sep | Where-Object { -not (Test-Path (Join-Path $_ 'gh.ps1')) -and -not (Test-Path (Join-Path $_ 'gh.cmd')) -and -not (Test-Path (Join-Path $_ 'gh.exe')) }
                $env:PATH = $pathParts -join $sep
            } elseif ($GhShimPath) {
                $env:PATH = "$GhShimPath$sep$script:SavedPath"
            }
            try {
                pwsh -NoProfile -NonInteractive -Command $command 2>&1 | Out-Null
                $exitCode = $LASTEXITCODE
                switch ($exitCode) {
                    0 { return $true }
                    2 { return $null }
                    default { return $false }
                }
            } finally {
                $env:PATH = $script:SavedPath
            }
        }
    }

    AfterAll {
        $env:PATH = $script:SavedPath
        if (Test-Path $script:TempBase) { Remove-Item -Recurse -Force $script:TempBase -ErrorAction SilentlyContinue }
    }

    Context 'returns $true when signals confirm shipped' {
        It 'state CLOSED + matched merged PR returns $true' {
            $shim = & $script:MakeGhShim -State 'CLOSED' -HeadRefOid $script:FeatureTip
            $result = & $script:InvokeHelper -GhShimPath $shim
            $result | Should -BeTrue
        }

        It 'state CLOSED with stateReason NOT_PLANNED + matched merged PR returns $true (D-state-reason)' {
            $shim = & $script:MakeGhShim -State 'CLOSED' -StateReason 'NOT_PLANNED' -HeadRefOid $script:FeatureTip
            $result = & $script:InvokeHelper -GhShimPath $shim
            $result | Should -BeTrue
        }

        It 'state CLOSED with stateReason DUPLICATE + matched merged PR returns $true' {
            $shim = & $script:MakeGhShim -State 'CLOSED' -StateReason 'DUPLICATE' -HeadRefOid $script:FeatureTip
            $result = & $script:InvokeHelper -GhShimPath $shim
            $result | Should -BeTrue
        }
    }

    Context 'returns $false when signals indicate not shipped' {
        It 'state OPEN returns $false' {
            $shim = & $script:MakeGhShim -State 'OPEN' -HeadRefOid $script:FeatureTip
            $result = & $script:InvokeHelper -GhShimPath $shim
            $result | Should -BeFalse
        }

        It 'no merged PR (empty list) returns $false' {
            $shim = & $script:MakeGhShim -State 'CLOSED' -EmptyPRList
            $result = & $script:InvokeHelper -GhShimPath $shim
            $result | Should -BeFalse
        }

        It 'merged PR with non-matching headRefOid returns $false' {
            $wrongOid = '0000000000000000000000000000000000000000'
            $shim = & $script:MakeGhShim -State 'CLOSED' -HeadRefOid $wrongOid
            $result = & $script:InvokeHelper -GhShimPath $shim
            $result | Should -BeFalse
        }

        It 'branch name not matching shared regex returns $false' {
            $shim = & $script:MakeGhShim -State 'CLOSED' -HeadRefOid $script:FeatureTip
            # Use a branch that doesn't match ^feature/issue-(\d+)-
            $result = & $script:InvokeHelper -Branch 'claude/old-feature' -GhShimPath $shim
            $result | Should -BeFalse
        }
    }

    Context 'returns $null on fail-open scenarios' {
        It 'gh missing on PATH returns $null' {
            $result = & $script:InvokeHelper -RemoveGh
            $result | Should -BeNullOrEmpty
        }

        It 'gh non-zero exit returns $null' {
            $shim = & $script:MakeGhShim -FailOnCall
            $result = & $script:InvokeHelper -GhShimPath $shim
            $result | Should -BeNullOrEmpty
        }

        It 'JSON parse failure returns $null' {
            $shim = & $script:MakeGhShim -BadJson
            $result = & $script:InvokeHelper -GhShimPath $shim
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'with master as default branch' {
        It 'state CLOSED + matched merged PR with master as default branch returns $true' {
            $helperPath = $script:HelpersPath.Replace("'", "''")
            $repoPath   = $script:RepoPath.Replace("'", "''")

            $shim = & $script:MakeGhShim -State 'CLOSED' -HeadRefOid $script:FeatureTip

            $command = @"
Push-Location '$repoPath'
. '$helperPath'
`$result = Test-OrphanBranchGitHubSignalsShipped -Branch 'feature/issue-548-test' -DefaultBranch 'master'
if (`$null -eq `$result) { exit 2 }
elseif (`$result -eq `$true) { exit 0 }
else { exit 1 }
"@
            $sep = [System.IO.Path]::PathSeparator
            $env:PATH = "$shim$sep$script:SavedPath"
            try {
                pwsh -NoProfile -NonInteractive -Command $command 2>&1 | Out-Null
                $exitCode = $LASTEXITCODE
            } finally {
                $env:PATH = $script:SavedPath
            }
            switch ($exitCode) {
                0 { $result = $true }
                2 { $result = $null }
                default { $result = $false }
            }
            $result | Should -BeTrue

            $callLog = Join-Path $shim 'gh-calls.log'
            $callLogContent = if (Test-Path $callLog) { Get-Content $callLog -Raw } else { '' }
            $callLogContent | Should -Match '--base\s+master' `
                -Because "Test-OrphanBranchGitHubSignalsShipped must pass --base `$DefaultBranch to gh pr list, not hardcode 'main'"
        }
    }
}
