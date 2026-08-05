#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Issue #998 (chunk 2 of #949): the finish line's two warn-only mechanisms
    and the durable completion-account family.

.DESCRIPTION
    Covers the parts of the chunk that are code rather than guidance. The
    guidance criteria (AC1, AC4, AC6, AC13, AC14, AC16) are proven by the
    artifact-pair standard in the brief -- an account the old text accepted
    shown being rejected by the new text -- and deliberately NOT by tests
    here: `skills/verification-before-completion/SKILL.md` itself states that
    text presence is not behaviour, and a test asserting the new wording
    exists would be exactly the non-discriminating proof that file forbids.

    What IS tested here:

      * Read-CompletionAccount's verdicts (AC2) -- including that absence
        reads as not-run rather than clean, which is the whole false-polarity
        property.
      * Both mechanisms' warn-only-ness (AC15).
      * The completion-account registry row's shape (AC3).
      * The code-review absence backstop over a population containing a unit
        that renders clean on the unchanged tree (AC8). The fixture MUST
        contain such a unit or the test cannot fail for the reason it claims.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    . (Join-Path $script:RepoRoot 'skills/verification-before-completion/scripts/completion-account-core.ps1')
    . (Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-marker-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1')

    # A pull request whose comments are ordinary chatter and carry no
    # judge-rulings head anywhere: the review-never-ran population. On the
    # unchanged tree this returned ParseStatus 'ok' / Reason 'ok' -- the
    # reassuring clean line #949 was filed about.
    $script:ReviewLessBodies = @(
        'LGTM, merging.',
        'CI is green on this one.',
        "## Summary`n`nRefactors the widget loader.`n"
    )

    # The control: same shape of unit, but a review actually ran.
    $script:ReviewedBodies = @(
        'LGTM, merging.',
        "<!-- judge-rulings`n- finding_id: N1`n  judge_ruling: sustained`n-->"
    )
}

Describe 'Completion account reader (#998 AC2, AC15)' {

    Context 'the required assertion has two polarities and absence is not a third' {

        It 'returns ''ran'' when the account asserts the review ran' {
            $r = Read-CompletionAccount -Text "adversarial_review_ran: true`nBaseline commit: abc1234."
            $r.Verdict | Should -BeExactly 'ran'
            $r.ReviewRan | Should -BeTrue
        }

        It 'returns a DIFFERENT verdict for the same account with the value flipped' {
            # AC2's discriminator: two accounts differing only in the VALUE of
            # the assertion, adjudicated by something other than their author.
            $ran = Read-CompletionAccount -Text "adversarial_review_ran: true`nBaseline commit: abc1234."
            $notRun = Read-CompletionAccount -Text "adversarial_review_ran: false`nBaseline commit: abc1234."

            $ran.Verdict | Should -Not -BeExactly $notRun.Verdict
            $notRun.Verdict | Should -BeExactly 'declared-not-run'
            $notRun.ReviewRan | Should -BeFalse
        }

        It 'reads an account with the assertion ABSENT as not-run, never as clean' {
            # Silence must not be readable as examined-and-clean. A criterion
            # satisfied by a merely-absent SECTION would not discharge AC2;
            # this is the value-level version.
            $r = Read-CompletionAccount -Text "All acceptance criteria proved. Nothing outstanding.`nBaseline commit: abc1234."

            $r.AssertionPresent | Should -BeFalse
            $r.Verdict | Should -BeExactly 'unasserted'
            $r.ReviewRan | Should -BeFalse -Because 'an omitted assertion reads as NOT RUN'
        }

        It 'keeps ''unasserted'' distinct from ''declared-not-run'' (different maintainer actions)' {
            (Read-CompletionAccount -Text 'adversarial_review_ran: false').Verdict |
                Should -Not -BeExactly (Read-CompletionAccount -Text 'nothing here').Verdict
        }

        It 'reports a present-but-unreadable value as its own verdict, not as missing' {
            # Telling a maintainer the field is missing when it is right in
            # front of them points at the wrong edit.
            $r = Read-CompletionAccount -Text 'adversarial_review_ran: probably'
            $r.Verdict | Should -BeExactly 'value-unrecognized'
            $r.AssertionPresent | Should -BeTrue
            $r.ReviewRan | Should -BeFalse
        }

        It 'reports disagreeing assertions rather than trusting either' {
            $r = Read-CompletionAccount -Text "adversarial_review_ran: true`nadversarial_review_ran: false"
            $r.Verdict | Should -BeExactly 'duplicate-assertion'
            $r.ReviewRan | Should -BeFalse
        }

        It 'does NOT treat a repeated but AGREEING assertion as a conflict' {
            # A conflict verdict that fires on consistent accounts trains its
            # reader to ignore it for the case that matters.
            $r = Read-CompletionAccount -Text "adversarial_review_ran: true`n- adversarial_review_ran: true"
            $r.Verdict | Should -BeExactly 'ran'
            $r.AssertionCount | Should -BeGreaterThan 1
        }

        It 'reads the assertion inside a bullet or blockquote, since payload format is the run''s choice' {
            (Read-CompletionAccount -Text '- adversarial_review_ran: true').Verdict | Should -BeExactly 'ran'
            (Read-CompletionAccount -Text '> adversarial_review_ran: true').Verdict | Should -BeExactly 'ran'
        }

        It 'treats an empty or whitespace account as unasserted rather than throwing' {
            { Read-CompletionAccount -Text '' } | Should -Not -Throw
            (Read-CompletionAccount -Text '').Verdict | Should -BeExactly 'unasserted'
            (Read-CompletionAccount -Text "   `n  ").Verdict | Should -BeExactly 'unasserted'
        }
    }

    Context 'warn-only (AC15): the reader objects and the run still completes' {

        It 'never throws on any non-conforming account it objects to' {
            foreach ($bad in @('adversarial_review_ran: false', 'adversarial_review_ran: maybe', '', "ran: true`nran: false")) {
                { Read-CompletionAccount -Text $bad } | Should -Not -Throw
            }
        }

        It 'reports Blocking = false on every verdict, including the ones it warns about' {
            foreach ($t in @('adversarial_review_ran: true', 'adversarial_review_ran: false', 'nothing', 'adversarial_review_ran: zzz')) {
                (Read-CompletionAccount -Text $t).Blocking | Should -BeFalse
            }
        }

        It 'emits a warning rather than a verdict change when the account is silent on the suite (AC16 secondary signal)' {
            $silent = Read-CompletionAccount -Text 'adversarial_review_ran: true'
            $stated = Read-CompletionAccount -Text "adversarial_review_ran: true`nBaseline commit: abc1234. Added failures: 0."

            $silent.SuiteStateStated | Should -BeFalse
            $stated.SuiteStateStated | Should -BeTrue
            # The verdict is unchanged by suite silence -- the warning carries it.
            $silent.Verdict | Should -BeExactly $stated.Verdict
            $silent.Warnings.Count | Should -BeGreaterThan $stated.Warnings.Count
        }
    }
}

Describe 'Completion-account marker family (#998 AC3, AC15)' {

    BeforeAll {
        $script:AccountRow = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'completion-account' })[0]
    }

    It 'is registered' {
        $script:AccountRow | Should -Not -BeNullOrEmpty
    }

    It 'is ISSUE-keyed, because the issue is the one id that exists before a pull request does' {
        # This is the property AC3 turns on: a conductorless run reviews before
        # a PR exists, so a PR-keyed account has nowhere to land when written.
        $script:AccountRow.TargetSurface | Should -BeExactly 'issue'
        $script:AccountRow.MarkerTemplate | Should -BeExactly '<!-- completion-account-{ID} -->'
    }

    It 'uses upsert, so one issue has exactly one governing account' {
        $script:AccountRow.WriteShape | Should -BeExactly 'upsert'
    }

    It 'declares NO validator adapter, because an adapter is a hard pre-write refusal (AC15)' {
        # Wiring the assertion check here would make a non-conforming account
        # UNWRITABLE rather than flagged -- worse than the status quo, since
        # the run then leaves no durable account at all, and it is the
        # fail-the-run detector #949 rejected.
        $script:AccountRow.ValidatorAdapter | Should -BeNullOrEmpty
    }

    It 'appears in the documented catalog as well as the registry' {
        # A family lands in both surfaces or it is half-landed; a
        # registry/catalog divergence has already been real behavioural drift
        # once (the design-phase-complete write-shape case).
        $catalog = Get-Content (Join-Path $script:RepoRoot 'skills/session-memory-contract/references/handoff-markers.md') -Raw
        $catalog | Should -Match 'completion-account'
    }

    It 'was APPENDED, not inserted ahead of the fixtures that bind positionally' {
        # persist-marker-core.Tests.ps1 binds generic write-path fixtures to
        # the FIRST post-new/issue row and the FIRST issue-surface row.
        # Inserting an issue-surface row earlier re-points them silently while
        # every assertion still passes.
        $rows = @(Get-MarkerFamilyRegistry)
        $firstIssueRow = @($rows | Where-Object { $_.TargetSurface -eq 'issue' })[0]
        $firstIssueRow.Family | Should -Not -BeExactly 'completion-account'
    }
}

Describe 'Code-review absence backstop (#998 AC8, AC15)' {

    Context 'a shipped unit whose review never ran is enumerable rather than clean' {

        It 'returns the review-less unit instead of rendering it clean' {
            $g = Get-EmissionGap -Bodies $script:ReviewLessBodies -Id 4242 -Surface 'code-review' -TargetKind 'pr'

            $g.ParseStatus | Should -BeExactly 'could-not-verify'
            $g.Reason | Should -BeExactly 'review-not-run'
        }

        It 'names the review''s absence, NOT a missing or corrupt head' {
            # Reusing the head-missing flag would ship a wrong diagnosis: for
            # this population the head is not missing, the REVIEW is, and the
            # two rendered lines would be indistinguishable.
            $g = Get-EmissionGap -Bodies $script:ReviewLessBodies -Id 4242 -Surface 'code-review' -TargetKind 'pr'
            $g.Reason | Should -Not -BeExactly 'head-missing'
            $g.Reason | Should -Not -BeExactly 'head-corrupt'
        }

        It 'leaves a unit whose review DID run completely unchanged' {
            # The control the fixture exists for: if this went could-not-verify
            # too, the backstop would be firing on everything and the first
            # test would pass for the wrong reason.
            $g = Get-EmissionGap -Bodies $script:ReviewedBodies -Id 4243 -Surface 'code-review' -TargetKind 'pr'

            $g.ParseStatus | Should -BeExactly 'ok'
            $g.Reason | Should -BeExactly 'ok'
            $g.SustainedCount | Should -Be 1
        }

        It 'does not manufacture a gap for a non-pull-request caller' {
            # The false-gap failure mode the brief-surface gate exists to
            # avoid: a direct code-review call against an issue has no
            # code-review artifacts to report on.
            $g = Get-EmissionGap -Bodies $script:ReviewLessBodies -Id 4242 -Surface 'code-review'
            $g.ParseStatus | Should -BeExactly 'ok'
            $g.Reason | Should -BeExactly 'ok'
        }

        It 'does not fire on any other surface' {
            foreach ($s in @('design-challenge', 'plan-stress-test', 'post-review-observer')) {
                $g = Get-EmissionGap -Bodies $script:ReviewLessBodies -Id 4242 -Surface $s -TargetKind 'pr'
                $g.Reason | Should -Not -BeExactly 'review-not-run' -Because "$s is not the code-review surface"
            }
        }

        It 'is warn-only: it sets ParseStatus and returns, never throwing (AC15)' {
            { Get-EmissionGap -Bodies @() -Id 4242 -Surface 'code-review' -TargetKind 'pr' } | Should -Not -Throw
            { Get-EmissionGap -Bodies $script:ReviewLessBodies -Id 4242 -Surface 'code-review' -TargetKind 'pr' } | Should -Not -Throw
        }
    }

    Context 'the reason contract stays pinned (issue #969 leg 2 and leg 4)' {

        It 'reports no drift after the new branch was added' {
            $r = Get-PhaseContainmentReasonContractDriftStatus `
                -Source (Get-Content (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1') -Raw) `
                -EntryPointSource (Get-Content (Join-Path $script:RepoRoot '.github/scripts/phase-containment-emission-check.ps1') -Raw)

            $r.HasDrift | Should -BeFalse -Because ($r.DriftDetails -join ' | ')
        }

        It 'still counts SIX brief-only reasons -- the new branch is code-review-only and must read as shared' {
            # A brief-named flag on this branch would inflate the pinned tally
            # and make it wrong at the moment a future author consults it.
            $r = Get-PhaseContainmentReasonContractDriftStatus `
                -Source (Get-Content (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1') -Raw) `
                -EntryPointSource (Get-Content (Join-Path $script:RepoRoot '.github/scripts/phase-containment-emission-check.ps1') -Raw)

            $r.LadderBriefOnlyCount | Should -Be 6
            $r.LadderBriefOnlyReasons | Should -Not -Contain 'review-not-run'
        }

        It 'places review-not-run below every head-shape reason and above ok' {
            $r = Get-PhaseContainmentReasonContractDriftStatus `
                -Source (Get-Content (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1') -Raw) `
                -EntryPointSource (Get-Content (Join-Path $script:RepoRoot '.github/scripts/phase-containment-emission-check.ps1') -Raw)

            $order = @($r.AggregatorPriorityOrder)
            $order.IndexOf('review-not-run') | Should -BeGreaterThan $order.IndexOf('head-missing')
            $order.IndexOf('review-not-run') | Should -BeLessThan $order.IndexOf('ok')
        }
    }
}
