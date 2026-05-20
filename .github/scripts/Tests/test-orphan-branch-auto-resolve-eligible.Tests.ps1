#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Unit tests for Test-OrphanBranchAutoResolveEligible — tri-state matrix + name-guard.
#>

Describe 'Test-OrphanBranchAutoResolveEligible' {
    BeforeAll {
        $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HelpersPath = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-startup-git-helpers.ps1'
        $script:TempBase    = Join-Path ([System.IO.Path]::GetTempPath()) "pester-autoresolve-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempBase -Force | Out-Null

        # Create a minimal git repo so we have a valid git context
        $script:RepoPath = Join-Path $script:TempBase 'repo'
        & git -c init.defaultBranch=main -c commit.gpgsign=false init $script:RepoPath 2>&1 | Out-Null
        & git -C $script:RepoPath -c user.email='t@t.com' -c user.name='T' commit --allow-empty -m 'root' 2>&1 | Out-Null

        # Helper to invoke the orchestrator with stubbed inner helpers
        # $SignalsResult and $AbsorbedResult can be $true, $false, or $null
        $script:InvokeOrchestrator = {
            param(
                [string]$Branch = 'feature/issue-548-test',
                [string]$DefaultBranch = 'main',
                [object]$SignalsResult = $true,
                [object]$AbsorbedResult = $true
            )

            # Build a stub helpers script that patches the two inner helpers
            $stubSignalsExitCode = if ($null -eq $SignalsResult) { 2 } elseif ($SignalsResult -eq $true) { 0 } else { 1 }
            $stubAbsorbedExitCode = if ($null -eq $AbsorbedResult) { 2 } elseif ($AbsorbedResult -eq $true) { 0 } else { 1 }

            $helperArg  = $script:HelpersPath.Replace("'", "''")
            $repoArg    = $script:RepoPath.Replace("'", "''")
            $branchArg  = $Branch.Replace("'", "''")
            $defaultArg = $DefaultBranch.Replace("'", "''")

            # Load real helpers, then override the two inner helpers with stubs
            $cmd = @"
Push-Location '$repoArg'
. '$helperArg'
# Override inner helpers with stubs
function Test-OrphanBranchGitHubSignalsShipped { param([string]`$Branch,[string]`$DefaultBranch) ; `$c = $stubSignalsExitCode ; if (`$c -eq 2) { return `$null } ; return (`$c -eq 0) }
function Test-OrphanBranchCommitsAbsorbed { param([string]`$Branch,[string]`$DefaultBranch,[int]`$IssueId) ; `$c = $stubAbsorbedExitCode ; if (`$c -eq 2) { return `$null } ; return (`$c -eq 0) }
`$r = Test-OrphanBranchAutoResolveEligible -Branch '$branchArg' -DefaultBranch '$defaultArg'
if (`$null -eq `$r) { exit 2 } elseif (`$r -eq `$true) { exit 0 } else { exit 1 }
"@
            pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-Null
            switch ($LASTEXITCODE) {
                0 { return $true }
                2 { return $null }
                default { return $false }
            }
        }
    }

    AfterAll {
        if (Test-Path $script:TempBase) { Remove-Item -Recurse -Force $script:TempBase -ErrorAction SilentlyContinue }
    }

    Context 'name guard — non-feature/issue-N branches return $false' {
        It 'claude/old-feature returns $false (name guard)' {
            $result = & $script:InvokeOrchestrator -Branch 'claude/old-feature'
            $result | Should -BeFalse
        }

        It 'feature/issue-548 (no trailing hyphen) returns $false' {
            $result = & $script:InvokeOrchestrator -Branch 'feature/issue-548'
            $result | Should -BeFalse
        }

        It 'wip/issue-548-foo returns $false (wrong prefix)' {
            $result = & $script:InvokeOrchestrator -Branch 'wip/issue-548-foo'
            $result | Should -BeFalse
        }
    }

    Context '3x3 tri-state propagation matrix' {
        # signals=$true, absorbed=$true -> $true
        It 'signals=true, absorbed=true returns $true' {
            $result = & $script:InvokeOrchestrator -SignalsResult $true -AbsorbedResult $true
            $result | Should -BeTrue
        }

        # signals=$true, absorbed=$false -> $false
        It 'signals=true, absorbed=false returns $false' {
            $result = & $script:InvokeOrchestrator -SignalsResult $true -AbsorbedResult $false
            $result | Should -BeFalse
        }

        # signals=$true, absorbed=$null -> $null
        It 'signals=true, absorbed=null returns $null' {
            $result = & $script:InvokeOrchestrator -SignalsResult $true -AbsorbedResult $null
            $result | Should -BeNullOrEmpty
        }

        # signals=$false, absorbed=* -> $false (short-circuit at signals)
        It 'signals=false, absorbed=true returns $false' {
            $result = & $script:InvokeOrchestrator -SignalsResult $false -AbsorbedResult $true
            $result | Should -BeFalse
        }

        It 'signals=false, absorbed=false returns $false' {
            $result = & $script:InvokeOrchestrator -SignalsResult $false -AbsorbedResult $false
            $result | Should -BeFalse
        }

        It 'signals=false, absorbed=null returns $false' {
            $result = & $script:InvokeOrchestrator -SignalsResult $false -AbsorbedResult $null
            $result | Should -BeFalse
        }

        # signals=$null, absorbed=* -> $null (null propagation higher precedence than false)
        It 'signals=null, absorbed=true returns $null' {
            $result = & $script:InvokeOrchestrator -SignalsResult $null -AbsorbedResult $true
            $result | Should -BeNullOrEmpty
        }

        It 'signals=null, absorbed=false returns $null' {
            $result = & $script:InvokeOrchestrator -SignalsResult $null -AbsorbedResult $false
            $result | Should -BeNullOrEmpty
        }

        It 'signals=null, absorbed=null returns $null' {
            $result = & $script:InvokeOrchestrator -SignalsResult $null -AbsorbedResult $null
            $result | Should -BeNullOrEmpty
        }
    }
}
