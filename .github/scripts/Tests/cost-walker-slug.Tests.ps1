#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Get-CostTranscriptSlug coverage, split out of cost-walker.Tests.ps1 by issue
# #908 so it can be gated by CI on its own.
#
# Why the split, as it stood at the time: cost-walker.Tests.ps1 was quarantined
# out of .github/workflows/pester.yml's selection, and this repository had no way
# to measure whether it was Linux-clean (no Linux runner available to the
# maintainer, and its 13 conditional skips gate on git-remote availability
# rather than on platform, so a local run could not stand in for one). Promoting
# it wholesale would therefore have been an unmeasured bet. This file is
# Linux-clean by construction and could be promoted on evidence rather than
# assumption:
# Get-CostTranscriptSlug is a pure string function, every assertion is a string
# or integer comparison, and the Windows-shaped paths below are only ever
# function arguments -- nothing here touches the filesystem, git, or a PSDrive.
# Dot-sourcing cost-walker.ps1 is likewise side-effect-free (its only top-level
# statements are two platform-neutral variable assignments).
#
# An earlier revision of this comment asserted the parent suite was Linux-RED,
# citing 'C:\fake\path' literals as the #909 failure shape. Review measured that
# claim as unsubstantiated (4 such literals, none reaching path composition, vs
# 61 in the #909 comparator) and it has been withdrawn -- see issue #932. The
# split stood on the absence of evidence either way, not on evidence of redness.
#
# THE EVIDENCE NOW EXISTS, and it settles the question in the parent suite's
# favour. Issue #1035 measured the whole corpus on Linux and cost-walker.Tests.ps1
# passed; #1036 promoted it, so both suites run on every pull request and neither
# is an unmeasured bet any more. The split is retained because a pure-string
# function with its own file is cheaper to reason about than one buried in a
# larger suite -- not because the parent cannot be gated.

Describe 'Get-CostTranscriptSlug' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-walker.ps1'
        # Fail loudly rather than letting every It below report a confusing
        # "command not found" if the library ever moves.
        if (-not (Test-Path -LiteralPath $script:LibPath)) {
            throw "cost-walker library not found at $script:LibPath"
        }
        . $script:LibPath

        # Amendment A2 comparison rule: a derived slug's tail is compared
        # exactly, its drive letter case-insensitively. The drive character is
        # the one position whose case a caller-supplied path can legitimately
        # differ on (an MSYS path carries a lowercase drive; the session that
        # ran there recorded an uppercase one), and the on-disk lookup is
        # case-insensitive there. Everywhere else, case is load-bearing.
        function script:Should-MatchSlug {
            param([string]$Actual, [string]$Expected)
            $Actual.Substring(1) | Should -BeExactly $Expected.Substring(1)
            $Actual.Substring(0, 1) | Should -Be $Expected.Substring(0, 1)
        }
    }

    # Expectations below are derived from the vendor rule as extracted from the
    # installed CLI binary (`cwd.replace(/[^a-zA-Z0-9]/g,'-')`, capped at 200
    # with a base-36 `abs(hash)` suffix), independently recomputed against a
    # reference implementation, and cross-checked against the real
    # ~/.claude/projects/* directory names on disk where a corresponding
    # directory exists. None is computed by calling the function under test.
    #
    # Assertions use -BeExactly, not -Be: slug strings name real directories and
    # -Be is case-insensitive, so it cannot see a case regression. The single
    # exception is the drive character under A2, via Should-MatchSlug above.
    Context 'slug derivation' {
        It 'derives slug from Windows backslash path' {
            Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\Code 2\copilot-orchestra' |
                Should -BeExactly 'C--Users-Micah-Code-2-copilot-orchestra'
        }
        It 'maps the drive-letter colon to a dash and preserves the drive case' {
            Get-CostTranscriptSlug -CwdPath 'D:\repos\project' |
                Should -BeExactly 'D--repos-project'
        }
        It 'preserves case in path segments' {
            Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\MyRepo' |
                Should -BeExactly 'C--Users-Micah-MyRepo'
        }
        It 'replaces spaces with dashes' {
            Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\My Project' |
                Should -BeExactly 'C--Users-Micah-My-Project'
        }
    }

    Context 'input shape equivalence (AC2 no-regression floor)' {
        # AC2's real content: two spellings of one physical path must derive one
        # slug. Asserting equivalence rather than a hard-coded literal is what
        # makes these tests survive the drive-case question A1 got wrong --
        # the earlier revision pinned a literal lowercase MSYS slug that named
        # no directory on disk, which would have failed a correct future fix.
        It 'derives the same slug from forward-slash and backslash spellings' {
            $back = Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\Code 2\copilot-orchestra'
            $fwd = Get-CostTranscriptSlug -CwdPath 'C:/Users/Micah/Code 2/copilot-orchestra'
            $back | Should -Not -BeNullOrEmpty
            script:Should-MatchSlug -Actual $fwd -Expected $back
        }
        It 'derives the same slug from the git-bash MSYS spelling on Windows' -Skip:(-not $IsWindows) {
            $win = Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\Code 2\copilot-orchestra'
            $msys = Get-CostTranscriptSlug -CwdPath '/c/Users/Micah/Code 2/copilot-orchestra'
            $win | Should -Not -BeNullOrEmpty
            script:Should-MatchSlug -Actual $msys -Expected $win
        }
        It 'treats a single-letter first segment as a real directory on POSIX' -Skip:($IsWindows) {
            # The MSYS rewrite is Windows-gated precisely so this stays correct:
            # on a POSIX host '/c/repo' is a directory, and the vendor rule
            # derives a leading dash for it.
            Get-CostTranscriptSlug -CwdPath '/c/repo' | Should -BeExactly '-c-repo'
        }
    }

    Context 'POSIX paths (the platform the CI gate runs on)' {
        It 'derives a leading dash for an absolute POSIX path' {
            Get-CostTranscriptSlug -CwdPath '/home/runner/work/agent-orchestra/agent-orchestra' |
                Should -BeExactly '-home-runner-work-agent-orchestra-agent-orchestra'
        }
        It 'maps POSIX dotted segments the same way as Windows ones' {
            Get-CostTranscriptSlug -CwdPath '/home/runner/repo/.claude/worktrees/x-1' |
                Should -BeExactly '-home-runner-repo--claude-worktrees-x-1'
        }
        It 'does not treat a trailing backslash as a separator on a POSIX-shaped path' {
            # PR #937 review: '\' is an ordinary filename character on POSIX,
            # not a separator. A directory literally named with a trailing
            # backslash is unusual but legal, and the vendor rule maps it to a
            # trailing dash rather than dropping it. The discriminator that
            # decides this is the path's own shape (no drive letter and not
            # backslash-rooted), never $IsWindows -- this input has no drive
            # letter and does not start with '\', regardless of which platform
            # actually runs this test.
            Get-CostTranscriptSlug -CwdPath '/tmp/repo\' | Should -BeExactly '-tmp-repo-'
        }
        It 'trims a genuine trailing slash regardless of host OS' {
            # PR #937 post-fix review (M4): the POSIX branch of the trim had
            # no coverage of its own trimming action -- deleting the whole
            # branch left this suite green. Multiple trailing slashes collapse
            # via the regex's '+' quantifier, same as the drive-letter branch.
            Get-CostTranscriptSlug -CwdPath '/tmp/repo/' | Should -BeExactly '-tmp-repo'
            Get-CostTranscriptSlug -CwdPath '/tmp/repo///' | Should -BeExactly '-tmp-repo'
        }
    }

    Context 'separator-trim discriminator is path shape, not host OS or drive-letter alone (PR #937 review)' {
        # M2: an earlier revision of this fix treated "no drive letter" as
        # sufficient evidence of "POSIX-shaped" and stripped a legitimate
        # trailing backslash from every Windows path that isn't
        # drive-letter-absolute -- UNC, long-UNC, and drive-relative-rooted
        # paths all regressed against HEAD. The fix restores HEAD parity for
        # every one of those by also treating a leading '\' as Windows
        # evidence, without reintroducing the $IsWindows gate that would
        # regress the drive-letter case on the Linux CI runner (both classes
        # below are host-OS-independent regardless of which platform runs
        # this file).
        It 'trims a UNC path''s trailing backslash (HEAD parity)' {
            Get-CostTranscriptSlug -CwdPath '\\server\share\repo\' | Should -BeExactly '--server-share-repo'
        }
        It 'trims a long-UNC path''s trailing backslash (HEAD parity)' {
            Get-CostTranscriptSlug -CwdPath '\\?\C:\repo\' | Should -BeExactly '----C--repo'
        }
        It 'trims a drive-relative rooted path''s trailing backslash (HEAD parity)' {
            Get-CostTranscriptSlug -CwdPath '\dir\sub\' | Should -BeExactly '-dir-sub'
        }
        It 'still trims a drive-letter path''s trailing backslash regardless of host OS' {
            Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\Code\Copilot-Orchestra\' |
                Should -BeExactly 'C--Users-Micah-Code-Copilot-Orchestra'
        }
        It 'preserves a bare relative path''s trailing backslash as a documented residual' {
            # A bare relative path (no drive letter, no leading separator)
            # carries no evidence of which platform it belongs to, and no
            # live caller supplies one as a cwd (git rev-parse
            # --show-toplevel / Resolve-Path / Get-Location all return
            # absolutes). Treating it as POSIX-shaped rather than guessing
            # Windows is a deliberate, narrower-than-HEAD choice: the
            # alternative (an unevidenced disjunct covering this class) was
            # measured to restore this one unreachable class only by
            # misclassifying a different reachable one (a POSIX relative name
            # containing a backslash and no slash). This pin also kills a
            # weakened '^[A-Za-z]:' -> '^[A-Za-z]' discriminator mutation:
            # under that mutation this input's leading letter alone would
            # route it to the drive branch and trim the backslash.
            Get-CostTranscriptSlug -CwdPath 'dir\sub\' | Should -BeExactly 'dir-sub-'
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

    Context 'degenerate input' {
        # The pre-#908 implementation returned '' for separator-only input.
        # Downstream guards (cost-baseline-harvest, cost-session-render) test
        # emptiness rather than validity, so an all-dash slug would pass them
        # and start a walk on garbage. The input guard restores the old
        # degradation without touching the vendor rule for any valid path.
        It 'returns empty for a path carrying no alphanumeric character' {
            Get-CostTranscriptSlug -CwdPath '/' | Should -BeExactly ''
            Get-CostTranscriptSlug -CwdPath '//' | Should -BeExactly ''
            Get-CostTranscriptSlug -CwdPath '\' | Should -BeExactly ''
            Get-CostTranscriptSlug -CwdPath '...' | Should -BeExactly ''
        }
        It 'still derives normally when a single alphanumeric character is present' {
            Get-CostTranscriptSlug -CwdPath '/a' | Should -BeExactly '-a'
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
        It 'derives one over-cap suffix regardless of separator spelling' {
            # Regression pin for issue #932 M1: the hash preimage is the raw
            # path, so before separator canonicalization these two spellings of
            # one physical path produced '-ax22zk' and '-q2619p' respectively --
            # a content difference no case-insensitive lookup can recover.
            $tail = ('d' * 160)
            $back = Get-CostTranscriptSlug -CwdPath ("C:\Users\Micah\Code\Copilot-Orchestra\.claude\worktrees\$tail")
            $fwd = Get-CostTranscriptSlug -CwdPath ("C:/Users/Micah/Code/Copilot-Orchestra/.claude/worktrees/$tail")
            $back.Length | Should -BeGreaterThan 200
            $fwd | Should -BeExactly $back
        }
        It 'pins the documented over-cap MSYS gap: prefix agrees, suffix does not' -Skip:(-not $IsWindows) {
            # Documented-gap pin, not an aspiration. Node preserves whatever
            # drive case it is handed -- measured: process.chdir('c:\') leaves
            # process.cwd() reporting 'c:\' -- so drive case IS derivable from a
            # path that carries one. An MSYS path does not: '/c/...' spells the
            # drive lowercase by convention regardless of what Windows reported,
            # so the reconstruction has no case information to recover. Below
            # the cap the case-insensitive lookup absorbs that; above it the
            # drive character is part of the hash preimage and the suffix
            # diverges. Guessing uppercase here would be unevidenced -- this
            # test exists so anyone who tries has to justify it.
            $tail = ('d' * 160)
            $win = Get-CostTranscriptSlug -CwdPath ("C:\Users\Micah\Code\Copilot-Orchestra\.claude\worktrees\$tail")
            $msys = Get-CostTranscriptSlug -CwdPath ("/c/Users/Micah/Code/Copilot-Orchestra/.claude/worktrees/$tail")
            $win.Length | Should -BeGreaterThan 200
            # Everything up to the cap agrees apart from the drive character.
            $msys.Substring(1, 200 - 1) | Should -BeExactly $win.Substring(1, 200 - 1)
            # The suffix does not, and no live caller supplies an MSYS path.
            $msys.Substring(200) | Should -Not -BeExactly $win.Substring(200)
        }
    }

    Context 'Get-CostWalkerSlugHashSuffix (direct coverage)' {
        # The helper is a port of a foreign algorithm; its two most delicate
        # behaviours are the zero-hash branch and the widening that keeps
        # Math.abs(-2^31) from throwing in .NET. Reaching it directly (the
        # library is dot-sourced, so script: scope is addressable) is the only
        # way to assert either -- two long-path literals cannot distinguish a
        # correct port from one that diverges only on those inputs.
        It 'renders a zero hash as "0"' {
            script:Get-CostWalkerSlugHashSuffix -Value '' | Should -BeExactly '0'
        }
        It 'renders a small positive hash in lowercase base-36' {
            script:Get-CostWalkerSlugHashSuffix -Value 'a' | Should -BeExactly '2p'
        }
        It 'renders a negative (two''s-complement wrapped) hash by magnitude' {
            # hash('zzzzzzzzzz') = -1580979136; abs -> base36 'q59vb4'.
            script:Get-CostWalkerSlugHashSuffix -Value 'zzzzzzzzzz' | Should -BeExactly 'q59vb4'
        }
        It 'renders a large negative hash near the int32 boundary' {
            # hash = -2095299652, within 52M of int32 min -- exercises the
            # widening path that [Math]::Abs on [int] would throw on.
            script:Get-CostWalkerSlugHashSuffix -Value 'negative-hash-probe-string-abcdefgh' |
                Should -BeExactly 'ynhjk4'
        }
    }
}
