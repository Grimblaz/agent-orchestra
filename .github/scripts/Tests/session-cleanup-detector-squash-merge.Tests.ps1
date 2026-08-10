#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Issue #922, integration tier: the DETECTOR's own candidate-surfacing path,
    exercised against real git repositories containing real squash merges.
    Covers AC1, AC2, AC3, AC11, AC13 and AC14.

.DESCRIPTION
    Decision D2 requires the squash-merge behaviour to be proven against a real
    repository containing an actual squash merge, through the detector's
    candidate-surfacing path rather than the cleanup executor's, and requires
    that proof to be enforced by continuous integration. This file is new so it
    is selected by .github/workflows/pester.yml (which runs a glob minus an
    explicit quarantine — there is no allowlist to be added to) without
    inheriting issue #904's Linux baggage.

    Following the pattern of session-cleanup-detector-goal-run.Tests.ps1 — the one
    detector suite that is NOT quarantined and does pass on the Linux runner — this
    file deliberately avoids the mock-git PATH harness used by
    session-cleanup-detector.Tests.ps1. Every fixture here is a real, disposable
    git repository. That keeps the proof platform-neutral, which is exactly the
    property D2's scoping constraint attaches to the verdict.

    `gh` is not required: every branch these fixtures surface as eligible carries
    unique commits and resolves through a CONTENT signal in the free phase, so no
    network rung is reached. Fixtures that deliberately need the paid rung assert
    only that the candidate is not offered, which holds however gh resolves.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:DetectorLibPath = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1'
    $script:HelpersLibPath = Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-startup-git-helpers.ps1'
    . $script:HelpersLibPath
    . $script:DetectorLibPath

    function script:Invoke-SqGit {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$GitArgs)
        & git -C $Path @GitArgs 2>&1 | Out-Null
    }

    function script:Set-SqFile {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Content)
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $Path $Name), $Content, $utf8NoBom)
    }

    function script:New-SqFixture {
        <#
        .SYNOPSIS
            A bare "remote" plus a working clone whose main is already pushed.
            Returns @{ Root; Remote; Work }.
        #>
        param([Parameter(Mandatory)][string]$Root)

        $remote = Join-Path $Root 'remote.git'
        $work = Join-Path $Root 'work'
        New-Item -ItemType Directory -Path $Root, $work -Force | Out-Null
        & git init --bare -q -b main $remote 2>&1 | Out-Null
        & git init -q -b main $work 2>&1 | Out-Null
        Invoke-SqGit -Path $work -GitArgs @('config', 'user.email', 'scd-922@example.com')
        Invoke-SqGit -Path $work -GitArgs @('config', 'user.name', 'scd-922')
        Set-SqFile -Path $work -Name 'seed.txt' -Content "seed`n"
        Invoke-SqGit -Path $work -GitArgs @('add', '-A')
        Invoke-SqGit -Path $work -GitArgs @('commit', '-q', '-m', 'seed')
        Invoke-SqGit -Path $work -GitArgs @('remote', 'add', 'origin', $remote)
        Invoke-SqGit -Path $work -GitArgs @('push', '-q', '-u', 'origin', 'main')
        return @{ Root = $Root; Remote = $remote; Work = $work }
    }

    function script:Add-SqSquashMergedBranch {
        <#
        .SYNOPSIS
            Creates $Branch with real unique commits, squash-merges it onto main,
            and pushes main — the exact shape that makes the branch's own commits
            non-ancestors of origin/main while its content is present there.
            Leaves the repo on main. Deliberately does NOT configure an upstream
            for $Branch, matching how Claude Code session worktrees are created.
        #>
        param(
            [Parameter(Mandatory)][string]$Work,
            [Parameter(Mandatory)][string]$Branch,
            [Parameter(Mandatory)][string]$FileName
        )
        Invoke-SqGit -Path $Work -GitArgs @('checkout', '-q', '-b', $Branch)
        Set-SqFile -Path $Work -Name $FileName -Content "one`n"
        Invoke-SqGit -Path $Work -GitArgs @('add', '-A')
        Invoke-SqGit -Path $Work -GitArgs @('commit', '-q', '-m', "$Branch one")
        Set-SqFile -Path $Work -Name $FileName -Content "one`ntwo`n"
        Invoke-SqGit -Path $Work -GitArgs @('add', '-A')
        Invoke-SqGit -Path $Work -GitArgs @('commit', '-q', '-m', "$Branch two")
        Invoke-SqGit -Path $Work -GitArgs @('checkout', '-q', 'main')
        Invoke-SqGit -Path $Work -GitArgs @('merge', '--squash', $Branch)
        Invoke-SqGit -Path $Work -GitArgs @('commit', '-q', '-m', "squashed $Branch")
        Invoke-SqGit -Path $Work -GitArgs @('push', '-q', 'origin', 'main')
        Invoke-SqGit -Path $Work -GitArgs @('fetch', '-q', 'origin')
    }

    function script:Add-SqUnmergedBranch {
        <#
        .SYNOPSIS
            Creates $Branch carrying work genuinely ABSENT from origin/main —
            merge-tree merges cleanly and the resulting tree still differs, which
            is Amendment A2.1's conclusive negative. Leaves the repo on main.
        #>
        param(
            [Parameter(Mandatory)][string]$Work,
            [Parameter(Mandatory)][string]$Branch,
            [Parameter(Mandatory)][string]$FileName
        )
        Invoke-SqGit -Path $Work -GitArgs @('checkout', '-q', '-b', $Branch)
        Set-SqFile -Path $Work -Name $FileName -Content "work that never shipped`n"
        Invoke-SqGit -Path $Work -GitArgs @('add', '-A')
        Invoke-SqGit -Path $Work -GitArgs @('commit', '-q', '-m', "$Branch in flight")
        Invoke-SqGit -Path $Work -GitArgs @('checkout', '-q', 'main')
    }

    function script:Get-SqDetectorContext {
        <#
        .SYNOPSIS
            Runs the detector with $Cwd as the working directory and returns its
            rendered additionalContext ('' when the detector reports nothing).
        #>
        param([Parameter(Mandatory)][string]$Cwd, [string]$RepoRootOverride)
        $previous = Get-Location
        try {
            Set-Location -LiteralPath $Cwd
            $root = if ($RepoRootOverride) { $RepoRootOverride } else { $Cwd }
            $result = Invoke-SessionCleanupDetector -RepoRoot $root
            if ($result.Output -eq '{}') { return '' }
            $parsed = $result.Output | ConvertFrom-Json
            return [string]$parsed.hookSpecificOutput.additionalContext
        }
        finally { Set-Location -LiteralPath $previous }
    }

    function script:Get-SqFencedBlock {
        param([string]$Context)
        if (-not $Context) { return '' }
        $matched = [regex]::Matches($Context, '(?s)```powershell(.*?)```')
        return (@($matched | ForEach-Object { $_.Groups[1].Value }) -join "`n")
    }
}

Describe 'Issue #922 — squash-merged worktrees reach the detector''s own candidate-surfacing path' -Tag 'unit' {

    Context 'AC1/AC3/AC11 — the sibling worktree path' {

        It 'surfaces a squash-merged sibling worktree with evidence naming the establishing signal, and includes it in the offered command' {
            $root = Join-Path $TestDrive 'sibling-squash'
            $fx = New-SqFixture -Root $root
            $branch = 'claude/sibling-squashed-100-aaaaaa'
            Add-SqSquashMergedBranch -Work $fx.Work -Branch $branch -FileName 'sibling.txt'

            # The pre-#922 candidate pre-filter's own test, run here as the control
            # that makes this fixture discriminating: the branch's commits are NOT
            # ancestors of origin/main, so the removed predicate dropped it.
            & git -C $fx.Work merge-base --is-ancestor $branch 'origin/main' 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0 -Because 'a squash merge writes a new commit, so the pre-filter would have discarded this candidate unexamined'

            $siblingPath = Join-Path $root 'sibling-wt'
            Invoke-SqGit -Path $fx.Work -GitArgs @('worktree', 'add', '-q', $siblingPath, $branch)

            $context = Get-SqDetectorContext -Cwd $fx.Work
            $fenced = Get-SqFencedBlock -Context $context

            $context | Should -Match ([regex]::Escape($branch)) -Because 'AC1: a squash-merged worktree must be surfaced, not silently dropped'
            $context | Should -Match 'merged into origin/main \((tree-equivalent|merge-tree no-op)\)' -Because 'A2.4/AC1: the evidence must name the signal that established the verdict'
            $fenced | Should -Match '-SiblingWorktrees' -Because 'AC1: on the sibling path the candidate appears in the offered command'
        }

        It 'does not offer a sibling worktree whose work is genuinely absent from the default branch, and renders no line for it (AC2/AC13/D4)' {
            $root = Join-Path $TestDrive 'sibling-unmerged'
            $fx = New-SqFixture -Root $root
            $branch = 'claude/sibling-inflight-101-bbbbbb'
            Add-SqUnmergedBranch -Work $fx.Work -Branch $branch -FileName 'inflight.txt'

            # Establish independently that this candidate is EVALUATED to the
            # conclusive negative rather than never looked at — silence produced by
            # a candidate being dropped is already true on the pre-#922 tree and
            # would establish nothing.
            Push-Location $fx.Work
            try {
                $verdict = Get-SCDBranchMergeVerdict -BranchName $branch -DefaultBranch 'main'
                $verdict.Verdict | Should -BeExactly 'definitively-unmerged'
                $verdict.Signal | Should -BeExactly 'merge-tree clean and divergent'
            }
            finally { Pop-Location }

            $siblingPath = Join-Path $root 'sibling-wt'
            Invoke-SqGit -Path $fx.Work -GitArgs @('worktree', 'add', '-q', $siblingPath, $branch)

            $context = Get-SqDetectorContext -Cwd $fx.Work
            $fenced = Get-SqFencedBlock -Context $context

            $context | Should -Not -Match ([regex]::Escape($branch)) -Because 'AC13/D4: a definitively-unmerged candidate renders no finding line at all'
            $fenced | Should -Not -Match ([regex]::Escape($siblingPath)) -Because 'AC2: it must never appear in an offered command'
        }

        It 'surfaces a merged and an unmerged sibling in the SAME run, offering only the merged one (AC2/AC15, paired positive and negative on one arm)' {
            $root = Join-Path $TestDrive 'sibling-mixed'
            $fx = New-SqFixture -Root $root
            $merged = 'claude/sibling-merged-102-cccccc'
            $unmerged = 'claude/sibling-live-103-dddddd'
            Add-SqSquashMergedBranch -Work $fx.Work -Branch $merged -FileName 'merged.txt'
            Add-SqUnmergedBranch -Work $fx.Work -Branch $unmerged -FileName 'live.txt'

            $mergedPath = Join-Path $root 'wt-merged'
            $unmergedPath = Join-Path $root 'wt-live'
            Invoke-SqGit -Path $fx.Work -GitArgs @('worktree', 'add', '-q', $mergedPath, $merged)
            Invoke-SqGit -Path $fx.Work -GitArgs @('worktree', 'add', '-q', $unmergedPath, $unmerged)

            $context = Get-SqDetectorContext -Cwd $fx.Work
            $fenced = Get-SqFencedBlock -Context $context

            # The detector normalizes worktree paths to forward slashes before
            # rendering, so compare against the normalized form.
            $mergedNorm = $mergedPath.Replace('\', '/')
            $unmergedNorm = $unmergedPath.Replace('\', '/')

            $context | Should -Match ([regex]::Escape($merged))
            $context | Should -Not -Match ([regex]::Escape($unmerged))
            $fenced | Should -Match ([regex]::Escape($mergedNorm))
            $fenced | Should -Not -Match ([regex]::Escape($unmergedNorm)) -Because 'widening what is evaluated must not widen what is offered (invariant I-4)'
        }
    }

    Context 'AC1/AC3 — the orphan branch path' {

        It 'surfaces a squash-merged orphan branch (no worktree) and includes it in the offered command' {
            $root = Join-Path $TestDrive 'orphan-squash'
            $fx = New-SqFixture -Root $root
            $branch = 'claude/orphan-squashed-104-eeeeee'
            Add-SqSquashMergedBranch -Work $fx.Work -Branch $branch -FileName 'orphan.txt'

            & git -C $fx.Work merge-base --is-ancestor $branch 'origin/main' 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0 -Because 'the removed pre-filter would have discarded this orphan too'

            $context = Get-SqDetectorContext -Cwd $fx.Work
            $fenced = Get-SqFencedBlock -Context $context

            $context | Should -Match ([regex]::Escape($branch)) -Because 'AC3: the orphan path must be fixed too, not only the sibling path'
            $context | Should -Match 'merged into origin/main \((tree-equivalent|merge-tree no-op)\)'
            $fenced | Should -Match '-OrphanBranches'
            $fenced | Should -Match ([regex]::Escape($branch))
        }

        It 'renders no line and offers nothing for an orphan branch carrying genuinely absent work, in a run where a merged orphan IS offered (AC2/AC13)' {
            # Paired deliberately. Asserting the silence ALONE is vacuous: at
            # 0da36d6 this candidate is equally silent, because the ancestry
            # pre-filter discarded it before any evidence was gathered. Pairing it
            # with a merged orphan on the same arm makes the run as a whole differ
            # from the pre-change tree, where the merged one is dropped too.
            $root = Join-Path $TestDrive 'orphan-unmerged'
            $fx = New-SqFixture -Root $root
            $merged = 'claude/orphan-shipped-105-aaaggg'
            $live = 'claude/orphan-live-105-ffffff'
            Add-SqSquashMergedBranch -Work $fx.Work -Branch $merged -FileName 'orphanshipped.txt'
            Add-SqUnmergedBranch -Work $fx.Work -Branch $live -FileName 'orphanlive.txt'

            $context = Get-SqDetectorContext -Cwd $fx.Work
            $fenced = Get-SqFencedBlock -Context $context

            $context | Should -Match ([regex]::Escape($merged)) -Because 'the same-arm positive must be surfaced, which is what fails on the pre-change tree'
            $fenced | Should -Match ([regex]::Escape($merged))
            $context | Should -Not -Match ([regex]::Escape($live)) -Because 'AC13: the evaluated conclusive negative renders nothing'
            $fenced | Should -Not -Match ([regex]::Escape($live))
        }
    }

    Context 'AC1/AC3 — the current-branch path' {

        It 'surfaces the squash-merged branch of the worktree the session is running in, as that path''s narrative guidance' {
            $root = Join-Path $TestDrive 'current-squash'
            $fx = New-SqFixture -Root $root
            $branch = 'claude/current-squashed-106-aaabbb'
            Add-SqSquashMergedBranch -Work $fx.Work -Branch $branch -FileName 'current.txt'

            # Run the detector FROM a linked worktree checked out on that branch:
            # the current-branch arm never fires in the primary checkout, which
            # `git worktree remove` can never target.
            $currentPath = Join-Path $root 'wt-current'
            Invoke-SqGit -Path $fx.Work -GitArgs @('worktree', 'add', '-q', $currentPath, $branch)

            $context = Get-SqDetectorContext -Cwd $currentPath

            $context | Should -Match ([regex]::Escape($branch)) -Because 'AC3: the current-branch path is the third ancestry-gated path, and is where the live reproduction occurred'
            $context | Should -Match 'merged into origin/main \((tree-equivalent|merge-tree no-op)\)'
            $context | Should -Match 'Current-worktree cleanup must be run from another checkout' `
                -Because 'AC1 qualifies the current-branch path: its guidance sits outside the fenced block, because a worktree cannot remove itself'
        }

        It 'says nothing about the current worktree when its branch carries genuinely absent work, in a run that still surfaces a merged sibling (AC13/D4)' {
            # Paired for the same reason as the orphan case: silence alone is
            # already true at 0da36d6 because the pre-filter dropped the candidate.
            $root = Join-Path $TestDrive 'current-unmerged'
            $fx = New-SqFixture -Root $root
            $sibling = 'claude/sibling-shipped-107-cccddd'
            $branch = 'claude/current-live-107-bbbccc'
            Add-SqSquashMergedBranch -Work $fx.Work -Branch $sibling -FileName 'siblingshipped.txt'
            Add-SqUnmergedBranch -Work $fx.Work -Branch $branch -FileName 'currentlive.txt'
            $siblingPath = Join-Path $root 'wt-sibling'
            $currentPath = Join-Path $root 'wt-current'
            Invoke-SqGit -Path $fx.Work -GitArgs @('worktree', 'add', '-q', $siblingPath, $sibling)
            Invoke-SqGit -Path $fx.Work -GitArgs @('worktree', 'add', '-q', $currentPath, $branch)

            $context = Get-SqDetectorContext -Cwd $currentPath

            $context | Should -Match ([regex]::Escape($sibling)) -Because 'the same-arm positive must be surfaced, which is what fails on the pre-change tree'
            $context | Should -Not -Match 'Current Claude worktree branch' `
                -Because 'the branch of a worktree with real in-flight work is not a leftover'
            $context | Should -Not -Match ([regex]::Escape($branch))
        }
    }

    Context 'AC11 — both merged-signal shapes, against real git' {

        It 'establishes merged by STRICT TREE-EQUIVALENCE when the default has not advanced past the squash' {
            $root = Join-Path $TestDrive 'signal-tree-equivalent'
            $fx = New-SqFixture -Root $root
            $branch = 'claude/shape-tree-equiv-108-cccddd'
            Add-SqSquashMergedBranch -Work $fx.Work -Branch $branch -FileName 'shape1.txt'

            Push-Location $fx.Work
            try {
                $verdict = Get-SCDBranchMergeVerdict -BranchName $branch -DefaultBranch 'main'
                $verdict.Verdict | Should -BeExactly 'merged'
                $verdict.Signal | Should -BeExactly 'tree-equivalent'
            }
            finally { Pop-Location }
        }

        It 'establishes merged by MERGE-TREE NO-OP when the default has advanced past the squash' {
            $root = Join-Path $TestDrive 'signal-merge-tree-noop'
            $fx = New-SqFixture -Root $root
            $branch = 'claude/shape-merge-tree-109-dddeee'
            Add-SqSquashMergedBranch -Work $fx.Work -Branch $branch -FileName 'shape2.txt'

            # Advance main with an unrelated file, so the branch tip is no longer
            # tree-identical to origin/main but merging it is still a no-op.
            Set-SqFile -Path $fx.Work -Name 'unrelated.txt' -Content "later work`n"
            Invoke-SqGit -Path $fx.Work -GitArgs @('add', '-A')
            Invoke-SqGit -Path $fx.Work -GitArgs @('commit', '-q', '-m', 'advance main')
            Invoke-SqGit -Path $fx.Work -GitArgs @('push', '-q', 'origin', 'main')
            Invoke-SqGit -Path $fx.Work -GitArgs @('fetch', '-q', 'origin')

            Push-Location $fx.Work
            try {
                $verdict = Get-SCDBranchMergeVerdict -BranchName $branch -DefaultBranch 'main'
                $verdict.Verdict | Should -BeExactly 'merged'
                $verdict.Signal | Should -BeExactly 'merge-tree no-op' `
                    -Because 'this is the second of the two shapes AC1 mandates, and the pre-#922 gate could report it only by mislabelling its evidence as tree-equivalent'
            }
            finally { Pop-Location }
        }
    }

    Context 'AC11/I-6 — patch history establishes neither conclusive value' {

        It 'does not call a branch merged on patch-history equivalence alone when its work is ABSENT from the default (the revert direction)' {
            # A revert breaks content equivalence while leaving `git cherry`
            # reporting the branch as fully applied upstream. Before Amendment A1.1
            # this returned merged, and the cleanup executor would override git's
            # own refusal to delete and escalate to a forced delete.
            $root = Join-Path $TestDrive 'i6-false-merged'
            $fx = New-SqFixture -Root $root
            $branch = 'claude/i6-reverted-110-eeefff'

            Invoke-SqGit -Path $fx.Work -GitArgs @('checkout', '-q', '-b', $branch)
            Set-SqFile -Path $fx.Work -Name 'reverted.txt' -Content "content that gets reverted`n"
            Invoke-SqGit -Path $fx.Work -GitArgs @('add', '-A')
            Invoke-SqGit -Path $fx.Work -GitArgs @('commit', '-q', '-m', 'work to be reverted')
            Invoke-SqGit -Path $fx.Work -GitArgs @('checkout', '-q', 'main')
            Invoke-SqGit -Path $fx.Work -GitArgs @('merge', '--squash', $branch)
            Invoke-SqGit -Path $fx.Work -GitArgs @('commit', '-q', '-m', 'squashed then reverted')
            Remove-Item -LiteralPath (Join-Path $fx.Work 'reverted.txt') -Force
            Invoke-SqGit -Path $fx.Work -GitArgs @('add', '-A')
            Invoke-SqGit -Path $fx.Work -GitArgs @('commit', '-q', '-m', 'revert it')
            Invoke-SqGit -Path $fx.Work -GitArgs @('push', '-q', 'origin', 'main')
            Invoke-SqGit -Path $fx.Work -GitArgs @('fetch', '-q', 'origin')

            Push-Location $fx.Work
            try {
                # Ground truth, established independently of the code under test:
                # git itself refuses the safe delete.
                & git -C $fx.Work branch -d $branch 2>&1 | Out-Null
                $LASTEXITCODE | Should -Not -Be 0 -Because 'git considers this branch not fully merged, which is the ground truth here'

                $verdict = Get-SCDBranchMergeVerdict -BranchName $branch -DefaultBranch 'main'
                $verdict.Verdict | Should -Not -BeExactly 'merged' `
                    -Because 'I-6: patch-history equivalence is not evidence that the content is present in the default branch now'
            }
            finally { Pop-Location }
        }
    }
}
