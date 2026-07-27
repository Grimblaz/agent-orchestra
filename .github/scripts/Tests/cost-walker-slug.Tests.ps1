#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Get-CostTranscriptSlug coverage, split out of cost-walker.Tests.ps1 by issue
# #908 so it can be registered as a CI gate.
#
# Why the split: cost-walker.Tests.ps1 is deliberately absent from
# .github/workflows/pester.yml. Several of its blocks pass hard-coded
# 'C:\fake\path' literals into path-composition and filesystem code, which is the
# same shape as the Linux-CI failures documented for cost-baseline-harvest.Tests.ps1
# (issue #909), so registering that suite wholesale would import known-red tests.
#
# This file is Linux-clean by construction and therefore safe to register:
# Get-CostTranscriptSlug is a pure string function, every assertion below is a
# string comparison, and the Windows-shaped paths here are only ever function
# arguments -- nothing in this file touches the filesystem, git, or a PSDrive.
# Dot-sourcing cost-walker.ps1 is likewise side-effect-free (its only top-level
# statements are two platform-neutral variable assignments).

Describe 'Get-CostTranscriptSlug' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-walker.ps1'
        # Fail loudly rather than letting every It below report a confusing
        # "command not found" if the library ever moves.
        if (-not (Test-Path -LiteralPath $script:LibPath)) {
            throw "cost-walker library not found at $script:LibPath"
        }
        . $script:LibPath
    }

    # Every expectation below is hard-coded from the issue #908 evidence pass:
    # the observed ~/.claude/projects/* directory names on disk, cross-checked
    # against Claude Code's own slug builder as extracted from the installed CLI
    # (`cwd.replace(/[^a-zA-Z0-9]/g,'-')`, capped at 200 chars with a base-36
    # `abs(hash)` suffix). None of them is computed by calling the function under
    # test, so a regression cannot restate itself as its own expectation.
    #
    # Assertions use -BeExactly, not -Be: slug strings name real directories, and
    # -Be is case-insensitive, so it cannot see a drive-case regression.
    Context 'slug derivation' {
        It 'derives slug from Windows backslash path' {
            Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\Code 2\copilot-orchestra' |
                Should -BeExactly 'C--Users-Micah-Code-2-copilot-orchestra'
        }
        It 'derives slug from git-bash /c/ path' {
            Get-CostTranscriptSlug -CwdPath '/c/Users/Micah/Code 2/copilot-orchestra' |
                Should -BeExactly 'c--Users-Micah-Code-2-copilot-orchestra'
        }
        It 'replaces spaces with dashes' {
            Get-CostTranscriptSlug -CwdPath '/c/Users/Micah/My Project' |
                Should -BeExactly 'c--Users-Micah-My-Project'
        }
        It 'preserves case in path segments' {
            Get-CostTranscriptSlug -CwdPath '/c/Users/Micah/MyRepo' |
                Should -BeExactly 'c--Users-Micah-MyRepo'
        }
        It 'maps the drive-letter colon to a dash and preserves the drive case' {
            Get-CostTranscriptSlug -CwdPath 'D:\repos\project' |
                Should -BeExactly 'D--repos-project'
        }
    }

    Context 'punctuation classes (issue #908 evidence pass)' {
        It 'derives the on-disk slug for a .claude/worktrees checkout' {
            # The #908 repro. The pre-fix segment-join rule emitted
            # '...-Orchestra-.claude-worktrees-...', which matched no directory
            # and left the primary-slug lookup dead for every worktree session.
            Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\Code\Copilot-Orchestra\.claude\worktrees\issue-908-implementation-99513b' |
                Should -BeExactly 'C--Users-Micah-Code-Copilot-Orchestra--claude-worktrees-issue-908-implementation-99513b'
        }
        It 'derives the same worktree slug from a forward-slash path' {
            Get-CostTranscriptSlug -CwdPath 'C:/Users/Micah/Code/Copilot-Orchestra/.claude/worktrees/issue-908-implementation-99513b' |
                Should -BeExactly 'C--Users-Micah-Code-Copilot-Orchestra--claude-worktrees-issue-908-implementation-99513b'
        }
        It 'maps non-leading dots and underscores to dashes' {
            Get-CostTranscriptSlug -CwdPath 'C:\repo\src\my.app_v2' |
                Should -BeExactly 'C--repo-src-my-app-v2'
        }
        It 'does not collapse runs and does not trim a trailing dash' {
            Get-CostTranscriptSlug -CwdPath 'C:\repo\a..b\.x.y.' |
                Should -BeExactly 'C--repo-a--b--x-y-'
        }
        It 'keeps the separator of a bare drive root' {
            Get-CostTranscriptSlug -CwdPath 'C:\' | Should -BeExactly 'C--'
        }
        It 'drops a trailing separator so it cannot derive a trailing dash' {
            Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\Code\Copilot-Orchestra\' |
                Should -BeExactly 'C--Users-Micah-Code-Copilot-Orchestra'
        }
    }

    Context 'over-long paths (vendor 200-char cap)' {
        It 'returns an uncapped slug at exactly 200 characters' {
            $cwd = 'C:\r\' + ('e' * 195)
            $slug = Get-CostTranscriptSlug -CwdPath $cwd
            $slug.Length | Should -Be 200
            $slug | Should -BeExactly ('C--r-' + ('e' * 195))
        }
        It 'caps at 200 characters and appends the base-36 hash suffix' {
            $cwd = 'C:\r\' + ('e' * 196)
            Get-CostTranscriptSlug -CwdPath $cwd |
                Should -BeExactly (('C--r-' + ('e' * 196)).Substring(0, 200) + '-3mny41')
        }
        It 'caps an over-long worktree path with its own hash suffix' {
            $cwd = 'C:\Users\Micah\Code\Copilot-Orchestra\.claude\worktrees\' + ('d' * 160)
            $expected = ('C--Users-Micah-Code-Copilot-Orchestra--claude-worktrees-' + ('d' * 160)).Substring(0, 200) + '-ax22zk'
            Get-CostTranscriptSlug -CwdPath $cwd | Should -BeExactly $expected
        }
    }
}
