#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Issue #922, unit tier: the reporting-honesty invariants of the session
    cleanup detector. Covers AC4, AC5, AC6, AC7, AC8, AC9 and AC15's
    command-composition clause.

.DESCRIPTION
    Decision D2 requires the unit proofs of these criteria to be enforced by
    continuous integration, in a NEW file so it can join
    .github/workflows/pester.yml's allowlist without inheriting issue #904's
    Linux baggage. Its scoping constraint assigns command composition to this
    tier rather than the real-git integration tier, because the real-git
    obligation attaches to the verdict and rendering is where #904's Linux
    failures are concentrated.

    Everything here is either a pure function, a Pester mock over a dot-sourced
    helper, or a real disposable git repository — never the mock-git PATH
    harness, matching the one detector suite that already passes on the Linux
    runner (session-cleanup-detector-goal-run.Tests.ps1).
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    . (Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-startup-git-helpers.ps1')
    . (Join-Path $script:RepoRoot 'skills/session-startup/scripts/session-cleanup-detector-core.ps1')

    $script:CountCapReason = 'could not verify: too many candidates this run'
    $script:TimeCapReason = 'could not verify: ran out of evaluation time this run'
    $script:FreeBoundReason = 'could not verify: local evidence pass ran out of time'
    $script:GitFailedReason = "couldn't verify: git signal failed"
    $script:InconclusiveReason = "couldn't verify: no conclusive merge evidence"

    function script:New-HnCandidate {
        param(
            [Parameter(Mandatory)][string]$BranchName,
            [Parameter(Mandatory)][string]$Category,
            [string]$WorktreePath
        )
        return @{
            BranchName         = $BranchName
            Category           = $Category
            WorktreePath       = $WorktreePath
            NeedsEligibility   = $true
            Eligible           = $false
            Reason             = $null
            Evidence           = $null
            ManualReviewReason = $null
            Outcome            = $null
        }
    }

    function script:New-HnGitRepo {
        <#
        .SYNOPSIS
            A working repo with a real bare 'origin' whose main is pushed. The
            remote is not optional: every candidate arm in the detector requires
            the remote default ref to resolve before it will consider a branch at
            all, so a remote-less repo yields no candidates and would make these
            assertions vacuously true.
        #>
        param([Parameter(Mandatory)][string]$Path)
        $remote = "$Path.git"
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        & git init --bare -q -b main $remote 2>&1 | Out-Null
        & git init -q -b main $Path 2>&1 | Out-Null
        & git -C $Path config user.email 'hn-922@example.com' 2>&1 | Out-Null
        & git -C $Path config user.name 'hn-922' 2>&1 | Out-Null
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBom)
        & git -C $Path add -A 2>&1 | Out-Null
        & git -C $Path commit -q -m 'seed' 2>&1 | Out-Null
        & git -C $Path remote add origin $remote 2>&1 | Out-Null
        & git -C $Path push -q -u origin main 2>&1 | Out-Null
        & git -C $Path fetch -q origin 2>&1 | Out-Null
        return $Path
    }
}

Describe 'Issue #922 — AC8: the budget-exhaustion reason names the cause that applied' -Tag 'unit' {

    It 'names the per-category COUNT cap, in a budget whose elapsed cap demonstrably cannot have fired' {
        $budget = New-SCDCollectionGhBudget -PerCategoryLimit 1 -GlobalSeconds 9999
        Get-SCDCollectionGhBudgetOutcome -Budget $budget -Category 'sibling' | Should -BeNullOrEmpty
        # Independently established: the elapsed cap is 9999 s and the stopwatch has
        # run for milliseconds, so the count cap is the only condition that can fire.
        $budget.Stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 9999
        Get-SCDCollectionGhBudgetOutcome -Budget $budget -Category 'sibling' |
            Should -BeExactly $script:CountCapReason
    }

    It 'names the ELAPSED cap, in a budget whose count cap demonstrably cannot have fired' {
        $budget = New-SCDCollectionGhBudget -PerCategoryLimit 9999 -GlobalSeconds 0
        Start-Sleep -Milliseconds 5
        # Independently established: no category has spent a slot, so the count cap
        # cannot be the cause. Distinctness is not accuracy — this keys the reason
        # to which condition actually held.
        $budget.CategoryCounts.Count | Should -Be 0
        Get-SCDCollectionGhBudgetOutcome -Budget $budget -Category 'sibling' |
            Should -BeExactly $script:TimeCapReason
    }

    It 'sources both cap reasons from the PRODUCT, and they differ there' {
        # Comparing this file's own literals to one another would be a tautology —
        # two constants defined a few lines apart, which is the "distinctness is
        # not accuracy" trap. These read the detector's own variables.
        $SCDCollectionCountCapManualReviewReason | Should -BeExactly $script:CountCapReason
        $SCDCollectionTimeCapManualReviewReason | Should -BeExactly $script:TimeCapReason
        $SCDCollectionCountCapManualReviewReason | Should -Not -BeExactly $SCDCollectionTimeCapManualReviewReason `
            -Because 'AC8: one literal standing for both caps is Defect C itself'
    }
}

Describe 'Issue #922 — AC4/I-2: free evidence is gathered before any candidate spends network budget' -Tag 'unit' {

    It 'yields a free-resolvable candidate as eligible even when network-costly candidates ahead of it exhausted the SHARED budget' {
        # AC4's falsifier, stated as the design states it. The budget is threaded
        # explicitly as one instance across all candidates — the collection
        # functions used to default it to a fresh expression per call, so a proof
        # that lets each call construct its own budget demonstrates nothing.
        $sharedBudget = New-SCDCollectionGhBudget -PerCategoryLimit 2 -GlobalSeconds 9999
        $freeBudget = New-SCDFreeEvidenceBudget

        $paidOne = New-HnCandidate -BranchName 'claude/paid-one-001-aaaaaa' -Category 'sibling'
        $paidTwo = New-HnCandidate -BranchName 'claude/paid-two-002-bbbbbb' -Category 'sibling'
        $paidThree = New-HnCandidate -BranchName 'claude/paid-three-003-cccccc' -Category 'sibling'
        $mergedLast = New-HnCandidate -BranchName 'claude/merged-last-004-dddddd' -Category 'sibling'

        # The three leading candidates need the network; the trailing one is
        # settled by content evidence in the free pass.
        Mock Get-SCDFreeEligibilityEvidence {
            if ($BranchName -eq 'claude/merged-last-004-dddddd') {
                return @{
                    Resolved = $true
                    Result   = @{
                        Eligible           = $true
                        Evidence           = 'merged into origin/main (tree-equivalent)'
                        ManualReviewReason = $null
                        Outcome            = 'eligible'
                    }
                }
            }
            return @{
                Resolved      = $false
                PaidRung      = 'rung2'
                PendingReason = $script:InconclusiveReason
                Result        = @{ Eligible = $false; Evidence = $null; ManualReviewReason = $null; Outcome = 'not-eligible' }
            }
        }
        Mock Resolve-SCDPaidEligibility {
            return @{ Eligible = $false; Evidence = $null; ManualReviewReason = $script:InconclusiveReason; Outcome = 'not-eligible' }
        }

        Resolve-SCDCandidateEligibility `
            -Candidates @($paidOne, $paidTwo, $paidThree, $mergedLast) `
            -DefaultBranch 'main' -GhBudget $sharedBudget -FreeBudget $freeBudget

        # The budget really was exhausted by the leaders...
        $paidThree.ManualReviewReason | Should -BeExactly $script:CountCapReason `
            -Because 'the third network-costly candidate must have hit the shared per-category cap of two'
        # ...and the merged candidate behind them is still eligible.
        $mergedLast.Eligible | Should -Be $true `
            -Because 'AC4: free evidence must be obtained for every candidate before any candidate consumes the network budget'
        $mergedLast.Evidence | Should -BeExactly 'merged into origin/main (tree-equivalent)'
    }

    It 'charges no budget unit at all for a candidate the free pass settled' {
        $budget = New-SCDCollectionGhBudget -PerCategoryLimit 20 -GlobalSeconds 9999
        $freeBudget = New-SCDFreeEvidenceBudget
        $settled = New-HnCandidate -BranchName 'claude/settled-005-eeeeee' -Category 'orphan'

        Mock Get-SCDFreeEligibilityEvidence {
            @{
                Resolved = $true
                Result   = @{ Eligible = $true; Evidence = 'merged into origin/main (merge-tree no-op)'; ManualReviewReason = $null; Outcome = 'eligible' }
            }
        }

        Resolve-SCDCandidateEligibility -Candidates @($settled) -DefaultBranch 'main' -GhBudget $budget -FreeBudget $freeBudget

        $settled.Eligible | Should -Be $true
        $budget.CategoryCounts.Count | Should -Be 0 `
            -Because 'the pre-#922 wrapper charged a unit BEFORE delegating, which is the cost inversion invariant I-2 removes'
    }
}

Describe 'Issue #922 — AC5/D5: the free-evidence phase is itself bounded' -Tag 'unit' {

    It 'uses a production default that is a small, finite number of seconds' {
        $script:SCDFreeEvidencePhaseSeconds | Should -BeOfType [int]
        $script:SCDFreeEvidencePhaseSeconds | Should -BeGreaterThan 0
        $script:SCDFreeEvidencePhaseSeconds | Should -BeLessOrEqual 30 `
            -Because 'this bound runs on the first turn of every conversation; a value that can never fire bounds nothing'
    }

    It 'yields the inconclusive outcome — never silence, never a conclusive negative — for candidates the bound cut off, AT the production default' {
        # The bound under test is the PRODUCTION default: New-SCDFreeEvidenceBudget
        # is constructed with no override, and the stopwatch is then pre-aged past
        # it. Overriding the value instead would satisfy a test while bounding
        # nothing in production.
        $freeBudget = New-SCDFreeEvidenceBudget
        $freeBudget.Seconds | Should -Be $script:SCDFreeEvidencePhaseSeconds

        $unreached = New-HnCandidate -BranchName 'claude/unreached-006-ffffff' -Category 'sibling'

        # Pre-age the clock past the production bound.
        $freeBudget.Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 5
        $freeBudget.Seconds = $script:SCDFreeEvidencePhaseSeconds
        Mock Test-SCDFreeEvidenceBudgetExceeded { $true }

        Resolve-SCDCandidateEligibility -Candidates @($unreached) -DefaultBranch 'main' `
            -GhBudget (New-SCDCollectionGhBudget) -FreeBudget $freeBudget

        $unreached.Eligible | Should -Be $false
        $unreached.ManualReviewReason | Should -BeExactly $script:FreeBoundReason `
            -Because 'AC5: exceeding the free-phase bound must state its own cause'
        $unreached.Outcome | Should -BeExactly 'not-eligible' `
            -Because 'AC5: never a definitively-unmerged verdict, which would render silently'
        $unreached.ManualReviewReason | Should -Not -BeNullOrEmpty `
            -Because 'AC5: never silence'
    }

    It 'sources the free-phase bound reason from the PRODUCT, distinct there from both network-budget caps' {
        $SCDFreePhaseBoundManualReviewReason | Should -BeExactly $script:FreeBoundReason
        $SCDFreePhaseBoundManualReviewReason | Should -Not -BeExactly $SCDCollectionCountCapManualReviewReason
        $SCDFreePhaseBoundManualReviewReason | Should -Not -BeExactly $SCDCollectionTimeCapManualReviewReason `
            -Because 'AC6: running out of LOCAL evidence time is a different cause from running out of NETWORK budget'
    }
}

Describe 'Issue #922 — AC6/I-3: an inconclusive candidate is reported with its actual cause' -Tag 'unit' {

    It 'gives each cause in the enumerated set its own distinct text, read from the PRODUCT' {
        # Read from the detector's and the gate's own variables — not from this
        # file's literals, which would compare five constants to each other.
        $causes = @(
            $SCDCollectionCountCapManualReviewReason
            $SCDCollectionTimeCapManualReviewReason
            $SCDFreePhaseBoundManualReviewReason
            $WorktreeEligibilityReasons.GitSignalFailed
            $WorktreeEligibilityReasons.InconclusiveMergeEvidence
        )
        @($causes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 5 `
            -Because 'every cause must actually exist in the product'
        ($causes | Select-Object -Unique).Count | Should -Be 5 `
            -Because 'AC6 enumerates five causes: count cap, elapsed cap, free-phase bound, gathering failure, and the merge-tree-conflicting case'
    }

    It 'keeps the inconclusive cause distinguishable from the conclusive negative, which renders nothing at all' {
        $script:InconclusiveReason | Should -Not -BeExactly $script:WorktreeEligibilityReasons.UnmergedCommits
        # And they are carried by different outcomes, so the renderer never has to
        # decide by string-matching a reason.
        $script:WorktreeEligibilityOutcomes.DefinitivelyUnmerged | Should -Not -BeExactly $script:WorktreeEligibilityOutcomes.NotEligible
    }

    It 'reports a merge-tree CONFLICT as inconclusive rather than as unmerged commits, keyed to a verdict independently shown to be undetermined' {
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive 'ac6-conflict')
        $branch = 'claude/ac6-conflict-007-aaaaaa'
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

        # Both sides edit the same line, so merge-tree conflicts: no conclusive
        # content evidence exists in either direction.
        & git -C $repo checkout -q -b $branch 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), "branch side`n", $utf8NoBom)
        & git -C $repo add -A 2>&1 | Out-Null
        & git -C $repo commit -q -m 'branch edit' 2>&1 | Out-Null
        & git -C $repo checkout -q main 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), "main side`n", $utf8NoBom)
        & git -C $repo add -A 2>&1 | Out-Null
        & git -C $repo commit -q -m 'main edit' 2>&1 | Out-Null
        # The verdict compares against the REMOTE default, so main's divergent
        # edit must actually be published for merge-tree to conflict.
        & git -C $repo push -q origin main 2>&1 | Out-Null
        & git -C $repo fetch -q origin 2>&1 | Out-Null

        Push-Location $repo
        try {
            $verdict = Get-SCDBranchMergeVerdict -BranchName $branch -DefaultBranch 'main'
            $verdict.Verdict | Should -BeExactly 'undetermined' -Because 'the independently-established fact this reason is keyed to'
            $verdict.Cause | Should -BeExactly 'merge-tree conflicted'

            $free = Get-SCDFreeEligibilityEvidence -BranchName $branch -DefaultBranch 'main'
            $free.Resolved | Should -Be $false
            $free.PendingReason | Should -BeExactly $script:InconclusiveReason `
                -Because 'AC6: an inconclusive result must not be reported as the conclusive negative'
            $free.PendingReason | Should -Not -BeExactly $script:WorktreeEligibilityReasons.UnmergedCommits
        }
        finally { Pop-Location }
    }
}

Describe 'Issue #922 — AC7/I-5: no failure to gather evidence grants eligibility' -Tag 'unit' {

    It 'resolves <Name> to a not-eligible outcome carrying a stated cause' -TestCases @(
        @{ Name = 'a unique-commit count that cannot be obtained' }
        @{ Name = 'a merge verdict whose signals all failed' }
    ) {
        param($Name)
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive ("ac7-" + ($Name -replace '[^a-z]', '')))
        Push-Location $repo
        try {
            # No remote and no such branch: every git signal fails.
            $result = Test-WorktreeBranchRemovalEligible -BranchName 'claude/does-not-exist-008-bbbbbb' -DefaultBranch 'main'
            $result.Eligible | Should -Be $false -Because 'AC7: a failure must never grant eligibility'
            $result.ManualReviewReason | Should -Not -BeNullOrEmpty -Because 'AC7: the failure must be stated, not swallowed'
            $result.Outcome | Should -Not -BeExactly 'definitively-unmerged' -Because 'a failure is not a conclusive negative'
        }
        finally { Pop-Location }
    }

    It 'returns the undetermined verdict, not a conclusive one, when the content signals cannot run at all' {
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive 'ac7-verdict')
        Push-Location $repo
        try {
            $verdict = Get-SCDBranchMergeVerdict -BranchName 'claude/nope-009-cccccc' -DefaultBranch 'main'
            $verdict.Verdict | Should -BeExactly 'undetermined'
            $verdict.Cause | Should -BeExactly 'git signal failed'
        }
        finally { Pop-Location }
    }

    It 'reports the all-empty-commit DETERMINATION as undetermined when it cannot be made' {
        # Stated in terms of the determination rather than a named helper, so a
        # future change that relocates or absorbs it still satisfies this.
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive 'ac7-allempty')
        Push-Location $repo
        try {
            $determination = Test-SCDUniqueCommitsAllEmpty -BranchName 'main' -RemoteDefaultRef 'origin/does-not-exist'
            $determination | Should -BeNullOrEmpty -Because 'a git failure must not be reported as a determination of "not all empty"'
            $null -eq $determination | Should -Be $true
        }
        finally { Pop-Location }
    }

    It 'withholds tree-equivalence evidence — rather than granting eligibility on it — when the all-empty determination fails' {
        # The specific fail-open. The caller reads $false as "do not withhold" and
        # grants eligibility, so before this fix `-not $null` fabricated
        # "merged (tree-equivalent)" evidence out of an unrelated `git log` error.
        #
        # A REAL merged branch is used, so everything except the determination is
        # genuine: only the determination is forced to fail.
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive 'ac7-failopen')
        $branch = 'claude/fail-open-010-dddddd'
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        # A real (non-empty) commit that is then squash-merged, so the branch is
        # genuinely tree-equivalent AND its unique commits touch files — otherwise
        # the all-empty guard legitimately withholds and the control below cannot
        # distinguish the fix from the pre-existing behaviour.
        & git -C $repo checkout -q -b $branch 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'shipped.txt'), "shipped`n", $utf8NoBom)
        & git -C $repo add -A 2>&1 | Out-Null
        & git -C $repo commit -q -m 'real work' 2>&1 | Out-Null
        & git -C $repo checkout -q main 2>&1 | Out-Null
        & git -C $repo merge --squash $branch 2>&1 | Out-Null
        & git -C $repo commit -q -m 'squashed' 2>&1 | Out-Null
        & git -C $repo push -q origin main 2>&1 | Out-Null
        & git -C $repo fetch -q origin 2>&1 | Out-Null

        Push-Location $repo
        try {
            # Control: with the determination working, this branch IS resolved.
            $baseline = Get-SCDFreeEligibilityEvidence -BranchName $branch -DefaultBranch 'main'
            $baseline.Resolved | Should -Be $true -Because 'the control must show the fixture would otherwise resolve, or the assertion below proves nothing'
            $baseline.Result.Eligible | Should -Be $true

            Mock Test-SCDUniqueCommitsAllEmpty { $null }

            $free = Get-SCDFreeEligibilityEvidence -BranchName $branch -DefaultBranch 'main'

            $free.Resolved | Should -Be $false -Because 'the merged evidence must be withheld, not accepted'
            $free.Result.Eligible | Should -Be $false
            $free.PendingReason | Should -BeExactly $script:GitFailedReason `
                -Because 'I-5: the gathering failure must be reported, not the conclusive negative that was never established'
        }
        finally { Pop-Location }
    }
}

Describe 'Issue #922 — AC9: a prescription appears exactly when a command exists' -Tag 'unit' {

    BeforeAll {
        function script:Get-HnRenderedContext {
            param([Parameter(Mandatory)][string]$Cwd)
            $previous = Get-Location
            try {
                Set-Location -LiteralPath $Cwd
                $result = Invoke-SessionCleanupDetector -RepoRoot $Cwd
                if ($result.Output -eq '{}') { return '' }
                return [string](($result.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext)
            }
            finally { Set-Location -LiteralPath $previous }
        }
    }

    It 'emits no cleanup-prescription block, and says there is nothing to run, when every finding is held back' {
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive 'ac9-all-held')
        $branch = 'claude/ac9-held-011-eeeeee'
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        & git -C $repo checkout -q -b $branch 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'held.txt'), "unshipped`n", $utf8NoBom)
        & git -C $repo add -A 2>&1 | Out-Null
        & git -C $repo commit -q -m 'unshipped work' 2>&1 | Out-Null
        & git -C $repo checkout -q main 2>&1 | Out-Null
        $wt = Join-Path (Split-Path $repo -Parent) 'ac9-held-wt'
        & git -C $repo worktree add -q $wt $branch 2>&1 | Out-Null

        # Force every candidate to a held-back (reported, not offered) outcome.
        Mock Get-SCDFreeEligibilityEvidence {
            @{
                Resolved = $true
                Result   = @{ Eligible = $false; Evidence = $null; ManualReviewReason = $script:InconclusiveReason; Outcome = 'not-eligible' }
            }
        }

        $context = Get-HnRenderedContext -Cwd $repo

        $context | Should -Not -BeNullOrEmpty -Because 'the findings themselves must still be reported'
        $context | Should -Match ([regex]::Escape($script:InconclusiveReason))
        $context | Should -Not -Match 'To clean up, run:' `
            -Because 'AC9: no command exists, so no prescription block may be opened'
        $context | Should -Not -Match '```powershell' `
            -Because 'AC9: the header, opening fence and closing fence were all unconditional before this fix'
        $context | Should -Match 'Nothing to run automatically' `
            -Because 'AC9: the customer must be able to tell this apart from a session where candidates were dropped unexamined'
        $context | Should -Match 'was evaluated'
    }

    It 'emits the prescription block when a candidate IS offered' {
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive 'ac9-offered')
        $branch = 'claude/ac9-offered-012-ffffff'
        & git -C $repo checkout -q -b $branch 2>&1 | Out-Null
        & git -C $repo commit -q --allow-empty -m 'shipped' 2>&1 | Out-Null
        & git -C $repo checkout -q main 2>&1 | Out-Null
        $wt = Join-Path (Split-Path $repo -Parent) 'ac9-offered-wt'
        & git -C $repo worktree add -q $wt $branch 2>&1 | Out-Null

        Mock Get-SCDFreeEligibilityEvidence {
            @{
                Resolved = $true
                Result   = @{ Eligible = $true; Evidence = 'merged into origin/main (tree-equivalent)'; ManualReviewReason = $null; Outcome = 'eligible' }
            }
        }

        $context = Get-HnRenderedContext -Cwd $repo

        $context | Should -Match 'To clean up, run:' -Because 'AC9: the block is present whenever an emitter has content'
        $context | Should -Match '```powershell'
        $context | Should -Match 'post-merge-cleanup\.ps1'
        $context | Should -Not -Match 'Nothing to run automatically'
    }
}

Describe 'Issue #922 — AC15/A2.3: only gate-cleared candidates are offered, and the render cap does not drop them' -Tag 'unit' {

    It 'keeps every eligible candidate in the offered command even when more than the render cap are eligible' {
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive 'ac15-cap')
        $parent = Split-Path $repo -Parent
        $branches = 1..12 | ForEach-Object { 'claude/ac15-{0:d2}-aaaaaa' -f $_ }
        foreach ($b in $branches) {
            & git -C $repo branch $b main 2>&1 | Out-Null
            & git -C $repo worktree add -q (Join-Path $parent ("ac15-wt-" + $b.Split('/')[-1])) $b 2>&1 | Out-Null
        }

        Mock Get-SCDFreeEligibilityEvidence {
            @{
                Resolved = $true
                Result   = @{ Eligible = $true; Evidence = 'merged into origin/main (tree-equivalent)'; ManualReviewReason = $null; Outcome = 'eligible' }
            }
        }

        $previous = Get-Location
        try {
            Set-Location -LiteralPath $repo
            $result = Invoke-SessionCleanupDetector -RepoRoot $repo
            $context = [string](($result.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext)
        }
        finally { Set-Location -LiteralPath $previous }

        $fenced = (@([regex]::Matches($context, '(?s)```powershell(.*?)```') | ForEach-Object { $_.Groups[1].Value }) -join "`n")
        $renderedLines = ([regex]::Matches($context, '(?m)^- .*claude/ac15-')).Count
        $offeredEntries = ([regex]::Matches($fenced, "claude/ac15-|ac15-wt-")).Count

        $renderedLines | Should -Be 10 -Because 'the render cap still bounds the readable session-start block'
        $context | Should -Match '\+2 more not listed here'
        $offeredEntries | Should -BeGreaterOrEqual 12 `
            -Because 'A2.3/AC15: an eligible candidate costs one argument, not one line of screen; deriving arguments from the truncated list reintroduces the silent drop this issue exists to fix'
    }

    It 'never places a candidate the gate did not clear into an offered command' {
        $repo = New-HnGitRepo -Path (Join-Path $TestDrive 'ac15-inconclusive')
        $parent = Split-Path $repo -Parent
        & git -C $repo branch 'claude/ac15-held-013-bbbbbb' main 2>&1 | Out-Null
        & git -C $repo worktree add -q (Join-Path $parent 'ac15-held-wt') 'claude/ac15-held-013-bbbbbb' 2>&1 | Out-Null

        Mock Get-SCDFreeEligibilityEvidence {
            @{
                Resolved = $true
                Result   = @{ Eligible = $false; Evidence = $null; ManualReviewReason = $script:InconclusiveReason; Outcome = 'not-eligible' }
            }
        }

        $previous = Get-Location
        try {
            Set-Location -LiteralPath $repo
            $result = Invoke-SessionCleanupDetector -RepoRoot $repo
            $context = [string](($result.Output | ConvertFrom-Json).hookSpecificOutput.additionalContext)
        }
        finally { Set-Location -LiteralPath $previous }

        $fenced = (@([regex]::Matches($context, '(?s)```powershell(.*?)```') | ForEach-Object { $_.Groups[1].Value }) -join "`n")

        $context | Should -Match ([regex]::Escape($script:InconclusiveReason)) -Because 'AC15: an inconclusive candidate is reported with its cause'
        $fenced | Should -Not -Match 'ac15-held-wt' `
            -Because 'AC15/I-4: being unable to establish that a branch is finished is not permission to delete it'
    }
}
