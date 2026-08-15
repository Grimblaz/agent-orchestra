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

        It 'does NOT treat two SAME-POLARITY YAML 1.1 synonyms as a conflict (review L3)' {
            # `true` and `yes` both mean "ran". Before the fix, distinctness
            # was computed over the RAW tokens, so this misreported as
            # duplicate-assertion (ReviewRan=False) even though the account
            # asserts the same polarity twice.
            $r = Read-CompletionAccount -Text "adversarial_review_ran: true`nadversarial_review_ran: yes"
            $r.Verdict | Should -BeExactly 'ran'
            $r.ReviewRan | Should -BeTrue
        }

        It 'still reports a genuine truthy+falsy mix as duplicate-assertion after canonicalization (review L3)' {
            $r = Read-CompletionAccount -Text "adversarial_review_ran: yes`nadversarial_review_ran: no"
            $r.Verdict | Should -BeExactly 'duplicate-assertion'
            $r.ReviewRan | Should -BeFalse
        }

        It 'does not silently swallow an unrecognized value mixed with a recognized one (review L3)' {
            # Canonicalization must not fold a recognized token and an
            # unrecognized token into apparent agreement -- value-unrecognized
            # detection has to survive the mix.
            $r = Read-CompletionAccount -Text "adversarial_review_ran: true`nadversarial_review_ran: probably"
            $r.Verdict | Should -BeExactly 'duplicate-assertion'
        }

        It 'reports AssertionValue as the raw token WRITTEN, not the canonicalized bucket (PF3, review second pass)' {
            # Before the fix, canonicalization fed AssertionValue too, so an
            # account writing `yes` reported AssertionValue: true -- not what
            # the account actually said.
            $r = Read-CompletionAccount -Text 'adversarial_review_ran: yes'
            $r.Verdict | Should -BeExactly 'ran'
            $r.AssertionValue | Should -BeExactly 'yes'

            $r2 = Read-CompletionAccount -Text 'adversarial_review_ran: no'
            $r2.Verdict | Should -BeExactly 'declared-not-run'
            $r2.AssertionValue | Should -BeExactly 'no'
        }

        It 'names the ACTUAL written tokens in the duplicate-assertion warning, not canonical ones (PF4, review second pass)' {
            # Before the fix, an account writing yes/no got a warning saying
            # "assertions (false, true)" -- neither of which the account
            # contains. Isolated to the SPECIFIC "disagreeing" warning
            # (rather than all warnings joined) so an unrelated warning's
            # incidental "No author..." text cannot make this pass for the
            # wrong reason.
            $r = Read-CompletionAccount -Text "adversarial_review_ran: yes`nadversarial_review_ran: no"
            $r.Verdict | Should -BeExactly 'duplicate-assertion'
            $conflictWarning = @($r.Warnings | Where-Object { $_ -match 'disagreeing' })[0]
            $conflictWarning | Should -Not -BeNullOrEmpty
            $conflictWarning | Should -Match '\byes\b'
            $conflictWarning | Should -Match '\bno\b'
            $conflictWarning | Should -Not -Match '\btrue\b'
            $conflictWarning | Should -Not -Match '\bfalse\b'
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

    Context 'the input classes production actually produces (#998 review M29)' {
        # WHY THIS CONTEXT EXISTS. The first draft's fixtures used `n only, so
        # the suite passed 27/27 while the reader was broken for the input its
        # own platform produces. Every case below is one the review panel
        # reproduced against the shipped code. The AC8 comment further down
        # states the rule these were missing: a fixture set that cannot reach
        # the production input class cannot fail for the reason it claims.

        It 'reads a CRLF account -- the line ending the documented write path produces on Windows (M2)' {
            # `Get-Content -Raw` + `gh --body-file` preserve CRLF end to end,
            # and GitHub returns web-authored bodies CRLF-encoded. Before the
            # fix this returned 'unasserted', making the only verdict that
            # reads as EXAMINED unreachable by a conforming account.
            $r = Read-CompletionAccount -Text "adversarial_review_ran: true`r`nBaseline commit: abc1234; 0 added failures."
            $r.Verdict | Should -BeExactly 'ran'
            $r.SuiteStateStated | Should -BeTrue
        }

        It 'reads a lone-CR account' {
            (Read-CompletionAccount -Text "adversarial_review_ran: true`rBaseline abc1234, 0 failures.").Verdict |
                Should -BeExactly 'ran'
        }

        It 'reads the assertion form this skill''s own documentation prints (M1)' {
            # Pinned against the LIVE file rather than a copy of it: a fixture
            # holding its own copy of the example cannot fail when the
            # documentation drifts, which is the failure this finding was.
            $skill = Get-Content (Join-Path $script:RepoRoot 'skills/verification-before-completion/SKILL.md') -Raw
            $m = [regex]::Match($skill, '(?m)^\s*(adversarial_review_ran\s*:\s*\S+[^\r\n]*)$')
            $m.Success | Should -BeTrue -Because 'the skill must print a concrete assertion example for this test to pin'

            $r = Read-CompletionAccount -Text $m.Groups[1].Value
            $r.Verdict | Should -BeExactly 'ran' -Because "the documented form '$($m.Groups[1].Value)' must be readable by the reader that same section prescribes"
        }

        It 'does NOT read a fenced example as a live assertion (M3)' {
            # The author controls incidental prose; if a quoted example counts,
            # the verdict returns to the author and AC2's property is gone.
            $r = Read-CompletionAccount -Text "I did not dispatch a review.`n``````yaml`nadversarial_review_ran: true`n``````"
            $r.Verdict | Should -BeExactly 'unasserted'
            $r.ReviewRan | Should -BeFalse
        }

        It 'does NOT read a YAML block scalar as a live assertion (M3)' {
            # The CM4 defect class the sibling instrument already fixed.
            (Read-CompletionAccount -Text "notes: |`n  adversarial_review_ran: true`nother: 1").ReviewRan |
                Should -BeFalse
        }

        It 'does NOT read an HTML comment as a live assertion (M3)' {
            # Worst of the four: invisible in GitHub's render, so a human sees
            # no assertion at all while the reader would have returned 'ran'.
            (Read-CompletionAccount -Text "<!--`nadversarial_review_ran: true`n-->`nNo review ran.").ReviewRan |
                Should -BeFalse
        }

        It 'does NOT read an unterminated fence''s contents as live' {
            (Read-CompletionAccount -Text "``````yaml`nadversarial_review_ran: true").ReviewRan | Should -BeFalse
        }

        It 'DOES still read a blockquoted assertion -- payload format is the run''s choice' {
            # The deliberate boundary: `>` is a legitimate payload shape, not a
            # decoy. Only spans that are structurally "quoted content" are masked.
            (Read-CompletionAccount -Text '> adversarial_review_ran: true').Verdict | Should -BeExactly 'ran'
        }

        It 'accepts YAML 1.1 boolean synonyms, which the ```yaml-fenced documentation invites (M25)' {
            (Read-CompletionAccount -Text 'adversarial_review_ran: yes').Verdict | Should -BeExactly 'ran'
            (Read-CompletionAccount -Text 'adversarial_review_ran: no').Verdict | Should -BeExactly 'declared-not-run'
            (Read-CompletionAccount -Text 'adversarial_review_ran: True').Verdict | Should -BeExactly 'ran'
            (Read-CompletionAccount -Text 'adversarial_review_ran: probably').Verdict | Should -BeExactly 'value-unrecognized'
        }

        It 'does not call trivially-punctuated agreement a conflict (M27)' {
            (Read-CompletionAccount -Text "adversarial_review_ran: true`n> adversarial_review_ran: true.").Verdict |
                Should -BeExactly 'ran'
            (Read-CompletionAccount -Text '**adversarial_review_ran**: true').Verdict | Should -BeExactly 'ran'
        }
    }

    Context 'the suite-state signal is right in BOTH directions (#998 review M14)' {
        # The first draft fired on a bare label with no content and stayed
        # silent on a real differential sentence -- both polarities wrong,
        # which is the same false-polarity error this chunk exists to remove,
        # one level down.

        It 'does not count a bare label with no content as a suite statement' {
            (Read-CompletionAccount -Text "adversarial_review_ran: true`nBaseline commit:").SuiteStateStated |
                Should -BeFalse
        }

        It 'counts a substantive differential sentence' {
            (Read-CompletionAccount -Text "adversarial_review_ran: true`nSuite: 412 passed, 3 failed against main@abc1234; all 3 predate this branch.").SuiteStateStated |
                Should -BeTrue
        }

        It 'counts an explicit none' {
            (Read-CompletionAccount -Text "adversarial_review_ran: true`nFailures this change added: none.").SuiteStateStated |
                Should -BeTrue
        }

        It 'stays silent-but-advisory: the verdict never changes on suite state' {
            $silent = Read-CompletionAccount -Text 'adversarial_review_ran: true'
            $stated = Read-CompletionAccount -Text "adversarial_review_ran: true`n0 added failures at abc1234."
            $silent.Verdict | Should -BeExactly $stated.Verdict
        }
    }

    Context 'the reader has an invocation point, and it discloses the author (#998 review M6, M10)' {

        It 'selects the account by its family marker, not by concatenating comments' {
            # A concatenated read would let ANY comment on the issue supply the
            # assertion -- including a drive-by one, as this fixture carries.
            $comments = @(
                [pscustomobject]@{ id = 1; body = 'LGTM'; user = [pscustomobject]@{ login = 'someone' } },
                [pscustomobject]@{ id = 2; body = "<!-- completion-account-998 -->`nadversarial_review_ran: true`nBaseline abc1234, 0 added failures."; user = [pscustomobject]@{ login = 'Grimblaz' } },
                [pscustomobject]@{ id = 3; body = 'adversarial_review_ran: true (an UNRELATED comment)'; user = [pscustomobject]@{ login = 'drive-by' } }
            )
            $g = Get-CompletionAccountFromComments -Comments $comments -Id 998
            $g.Found | Should -BeTrue
            $g.CommentId | Should -Be 2
            $g.CandidateCount | Should -Be 1
            $g.Verdict | Should -BeExactly 'ran'
        }

        It 'reports Found=false, not-run, when the issue carries no account' {
            $g = Get-CompletionAccountFromComments -Comments @([pscustomobject]@{ id = 1; body = 'LGTM' }) -Id 998
            $g.Found | Should -BeFalse
            $g.ReviewRan | Should -BeFalse
        }

        It 'does not select a comment that merely MENTIONS the marker mid-line (review L1)' {
            # Unanchored substring matching let a comment that discusses the
            # marker inline -- not at a line start -- read as a candidate.
            # The anchor requires the marker to open a line; prose text
            # before it on the same line breaks that.
            $comments = @(
                [pscustomobject]@{ id = 1; body = "I already posted the account: <!-- completion-account-998 --> see above.`nadversarial_review_ran: false"; user = [pscustomobject]@{ login = 'mentioner' } }
            )
            $g = Get-CompletionAccountFromComments -Comments $comments -Id 998
            $g.Found | Should -BeFalse -Because 'a mid-line mention of the marker is not a candidate'
        }

        It 'does not select a comment where the marker is on LINE 3, not line 1 (PF1, review second pass)' {
            # A `(?m)^` anchor with no first-line restriction matches the
            # start of EVERY line, so a marker several lines down still read
            # as a candidate under the prior fix -- the exact shadowing
            # defect PF1 exists to close.
            $comments = @(
                [pscustomobject]@{ id = 1; body = "Some preamble.`nMore preamble.`n<!-- completion-account-998 -->`nadversarial_review_ran: true"; user = [pscustomobject]@{ login = 'someone' } }
            )
            $g = Get-CompletionAccountFromComments -Comments $comments -Id 998
            $g.Found | Should -BeFalse -Because 'the marker must be the FIRST line, not merely present somewhere in the body'
        }

        It 'does not select a comment where the marker is INDENTED on line 1 (PF1, review second pass)' {
            $comments = @(
                [pscustomobject]@{ id = 1; body = "  <!-- completion-account-998 -->`nadversarial_review_ran: true"; user = [pscustomobject]@{ login = 'someone' } }
            )
            $g = Get-CompletionAccountFromComments -Comments $comments -Id 998
            $g.Found | Should -BeFalse -Because 'leading whitespace on line 1 disqualifies a candidate under the line-1-exact anchor'
        }

        It 'does not select a comment where the marker sits inside a FENCED code block (PF1, review second pass)' {
            $comments = @(
                [pscustomobject]@{ id = 1; body = "``````text`n<!-- completion-account-998 -->`n``````"; user = [pscustomobject]@{ login = 'someone' } }
            )
            $g = Get-CompletionAccountFromComments -Comments $comments -Id 998
            $g.Found | Should -BeFalse -Because 'the fence opener is line 1, not the marker; a fenced example must not read as a live account'
        }

        It 'does not let a GitHub "Quote reply" shadow the real account (review L1)' {
            # Every line of a quote reply is prefixed `> `, including the
            # marker line. Before the fix this quote-reply's substring match
            # made it a candidate, and being the newest (highest id), it
            # outranked and shadowed the honest account -- flipping the read
            # from true to false.
            $comments = @(
                [pscustomobject]@{ id = 1; body = "<!-- completion-account-998 -->`nadversarial_review_ran: true`nBaseline abc1234, 0 added failures."; user = [pscustomobject]@{ login = 'Grimblaz' } },
                [pscustomobject]@{ id = 2; body = "> <!-- completion-account-998 -->`n> adversarial_review_ran: true`n> Baseline abc1234, 0 added failures.`n`nadversarial_review_ran: false"; user = [pscustomobject]@{ login = 'quoter' } }
            )
            $g = Get-CompletionAccountFromComments -Comments $comments -Id 998
            $g.Found | Should -BeTrue
            $g.CommentId | Should -Be 1 -Because 'the quote-reply''s marker line is `> `-prefixed and must not match the line-start anchor'
            $g.CandidateCount | Should -Be 1
            $g.Verdict | Should -BeExactly 'ran'
        }

        It 'does not throw when Comments is $null (review L7)' {
            # `gh issue view --json comments --jq ''.comments''` on a
            # zero-comment issue emits `[]`, which ConvertFrom-Json returns as
            # $null. Before the fix, a $null argument to this Mandatory
            # parameter failed parameter BINDING and threw instead of
            # reaching the advertised Found=$false path.
            { Get-CompletionAccountFromComments -Comments $null -Id 998 } | Should -Not -Throw
            $g = Get-CompletionAccountFromComments -Comments $null -Id 998
            $g.Found | Should -BeFalse
            $g.ReviewRan | Should -BeFalse
        }

        It 'carries the comment author through, because a shape-recognised record does not authenticate itself' {
            $g = Get-CompletionAccountFromComments -Comments @(
                [pscustomobject]@{ id = 7; body = "<!-- completion-account-998 -->`nadversarial_review_ran: true"; user = [pscustomobject]@{ login = 'Grimblaz' } }) -Id 998
            $g.PostedBy | Should -BeExactly 'Grimblaz'
            $g.AuthorDisclosed | Should -BeTrue
        }

        It 'warns when no author is available rather than treating the record as self-authenticating' {
            $r = Read-CompletionAccount -Text 'adversarial_review_ran: true'
            $r.AuthorDisclosed | Should -BeFalse
            ($r.Warnings -join ' ') | Should -Match 'who posted it'
        }

        It 'surfaces a multi-candidate collision, since the primitive''s canonical match is the EARLIEST id' {
            # A record planted before the run is both what a reader retrieves
            # and the comment the run then PATCHes.
            $g = Get-CompletionAccountFromComments -Comments @(
                [pscustomobject]@{ id = 1; body = "<!-- completion-account-998 -->`nadversarial_review_ran: true"; user = [pscustomobject]@{ login = 'planter' } },
                [pscustomobject]@{ id = 2; body = "<!-- completion-account-998 -->`nadversarial_review_ran: false"; user = [pscustomobject]@{ login = 'Grimblaz' } }) -Id 998
            $g.CandidateCount | Should -Be 2
            ($g.Warnings -join ' ') | Should -Match 'planted'
        }

        It 'selects the highest comment ID, not the last array element (review PF-D1)' {
            # The prior selection took $candidates[-1], encoding an unchecked
            # assumption that the caller's fetch returns ascending ids. Here
            # the array order is DELIBERATELY reversed against id order: if
            # selection is positional it picks the planted id-100 record and
            # reports 'declared-not-run'; if it sorts by id it picks the run's
            # own id-900 record and reports 'ran'.
            $g = Get-CompletionAccountFromComments -Comments @(
                [pscustomobject]@{ id = 900; body = "<!-- completion-account-998 -->`nadversarial_review_ran: true";  user = [pscustomobject]@{ login = 'Grimblaz' } },
                [pscustomobject]@{ id = 100; body = "<!-- completion-account-998 -->`nadversarial_review_ran: false"; user = [pscustomobject]@{ login = 'planter'  } }) -Id 998

            $g.CommentId | Should -Be 900 -Because 'the newest comment is the highest id, whatever order the fetch returned them in'
            $g.Verdict | Should -BeExactly 'ran'
            $g.PostedBy | Should -BeExactly 'Grimblaz'
        }

        It 'compares ids numerically, not as strings (review PF-D1)' {
            # A lexicographic comparison would rank '99' above '100'. GitHub
            # comment ids also exceed [int], hence [long] in the implementation.
            $g = Get-CompletionAccountFromComments -Comments @(
                [pscustomobject]@{ id = 5186569899; body = "<!-- completion-account-998 -->`nadversarial_review_ran: true";  user = [pscustomobject]@{ login = 'Grimblaz' } },
                [pscustomobject]@{ id = 999999999;  body = "<!-- completion-account-998 -->`nadversarial_review_ran: false"; user = [pscustomobject]@{ login = 'planter'  } }) -Id 998

            $g.CommentId | Should -Be 5186569899
            $g.Verdict | Should -BeExactly 'ran'
        }

        It 'falls back to caller order when any candidate lacks a usable id (review PF-D1)' {
            # Deliberate degradation: a partial sort would look authoritative
            # while being arbitrary. Assert the fallback is reached without
            # throwing and still returns a usable verdict.
            { Get-CompletionAccountFromComments -Comments @(
                    [pscustomobject]@{ body = "<!-- completion-account-998 -->`nadversarial_review_ran: true" },
                    [pscustomobject]@{ id = 900; body = "<!-- completion-account-998 -->`nadversarial_review_ran: false" }) -Id 998 } |
                Should -Not -Throw

            $g = Get-CompletionAccountFromComments -Comments @(
                [pscustomobject]@{ body = "<!-- completion-account-998 -->`nadversarial_review_ran: true" },
                [pscustomobject]@{ id = 900; body = "<!-- completion-account-998 -->`nadversarial_review_ran: false" }) -Id 998
            $g.CandidateCount | Should -Be 2
            $g.Verdict | Should -BeExactly 'declared-not-run' -Because 'caller order is preserved when ids are unusable'
        }
    }

    Context 'unreadable values are not reported as disagreements (#998 review PF-D2, PF-D3)' {

        It 'reports two DIFFERENT unrecognized values as value-unrecognized, not duplicate-assertion (PF-D2)' {
            # Neither token carries a polarity, so there is nothing to
            # disagree about. Calling it a disagreement sends the maintainer
            # to reconcile a contradiction that does not exist, when the real
            # edit is that no value is readable.
            $r = Read-CompletionAccount -Text "adversarial_review_ran: probably`nadversarial_review_ran: maybe"
            $r.Verdict | Should -BeExactly 'value-unrecognized'
            $r.ReviewRan | Should -BeFalse
            ($r.Warnings -join ' ') | Should -Match 'no value is a recognized polarity'
        }

        It 'still reports a recognized value mixed with an unrecognized one as a conflict (PF-D2 boundary)' {
            # The deliberate NON-change: a readable polarity contradicted by
            # an unreadable token genuinely cannot be trusted.
            (Read-CompletionAccount -Text "adversarial_review_ran: true`nadversarial_review_ran: probably").Verdict |
                Should -BeExactly 'duplicate-assertion'
        }

        It 'names the empty-after-trim case instead of quoting an empty token (PF-D3)' {
            # `***` is consumed entirely by the punctuation trim, leaving ''.
            # The prior message read "its value '' is neither polarity".
            $r = Read-CompletionAccount -Text 'adversarial_review_ran: ***'
            $r.Verdict | Should -BeExactly 'value-unrecognized'
            ($r.Warnings -join ' ') | Should -Match 'empty after trimming'
            ($r.Warnings -join ' ') | Should -Not -Match "value '' is neither polarity" -Because 'quoting an empty token tells a maintainer nothing about what to edit'
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

    Context 'what counts as "a review is recorded" (#998 review M4, M5)' {

        It 'is id-scoped: an ATTRIBUTED head naming a different pull request does not suppress it (M4)' {
            # Before the fix, a ruling block pasted or quoted from another PR
            # switched the backstop off entirely.
            $foreign = @('LGTM.', "<!-- judge-rulings pr=9999 -->`n- finding_id: N1`n  judge_ruling: sustained`n-->")
            $g = Get-EmissionGap -Bodies $foreign -Id 4242 -Surface 'code-review' -TargetKind 'pr'
            $g.Reason | Should -BeExactly 'review-not-run'
        }

        It 'honours an ATTRIBUTED head that names THIS pull request' {
            $own = @('LGTM.', "<!-- judge-rulings pr=4242 -->`n- finding_id: N1`n  judge_ruling: sustained`n-->")
            (Get-EmissionGap -Bodies $own -Id 4242 -Surface 'code-review' -TargetKind 'pr').Reason |
                Should -Not -BeExactly 'review-not-run'
        }

        It 'does NOT claim "nothing examined" when an id-scoped review-dispositions record is present (M5)' {
            # This is the code-review surface's OWN external-review artifact,
            # which the CR-8 seam parses to adjust this very surface's count.
            # Routes whose adapters declare no judge stage (proxy-github,
            # post-fix) reach the backstop through exactly this artifact.
            # Single-quoted here-string: a triple backtick inside a
            # double-quoted PowerShell string is three escape characters, not
            # a code fence -- it silently breaks the file's parse.
            $dispositions = @'
<!-- review-dispositions-4242 -->

```yaml
schema_version: 3
entries:
  - stable_finding_key: k1
    disposition: incorporate
    reviewer_source: coderabbitai
```
'@
            (Get-EmissionGap -Bodies @('LGTM.', $dispositions) -Id 4242 -Surface 'code-review' -TargetKind 'pr').Reason |
                Should -Not -BeExactly 'review-not-run'
        }

        It 'does NOT claim "nothing examined" when the judge''s own sentinel is present (M5)' {
            $bodies = @('LGTM.', '<!-- review-judge-produced-4242 -->')
            (Get-EmissionGap -Bodies $bodies -Id 4242 -Surface 'code-review' -TargetKind 'pr').Reason |
                Should -Not -BeExactly 'review-not-run'
        }

        It 'still fires when a sentinel names a DIFFERENT pull request' {
            $bodies = @('LGTM.', '<!-- review-judge-produced-9999 -->')
            (Get-EmissionGap -Bodies $bodies -Id 4242 -Surface 'code-review' -TargetKind 'pr').Reason |
                Should -BeExactly 'review-not-run'
        }

        It 'does not throw on a body set containing an empty string (M23)' {
            # The entry point filters null COMMENTS but not null BODIES, and a
            # null body casts to ''. Before the fix this aborted the whole
            # check on an uncatchable binding error.
            { Get-EmissionGap -Bodies @('LGTM.', '') -Id 4242 -Surface 'code-review' -TargetKind 'pr' } |
                Should -Not -Throw
        }
    }

    Context 'the rendered maintainer line, asserted where CI actually runs it (#998 review M16)' {
        # The only prior assertion on this string lived in
        # phase-containment-emission-check.Tests.ps1, which was CI-quarantined
        # when this Context was written, so the string was asserted nowhere CI
        # would see it. Both suites run in CI now — #1035 measured the corpus on
        # Linux and #1036 promoted that suite — so this is a second assertion
        # rather than the only live one.

        BeforeAll {
            # Dot-sourcing the entry point skips its top-level execution (it
            # detects InvocationName '.') and brings the renderer into scope.
            . (Join-Path $script:RepoRoot '.github/scripts/phase-containment-emission-check.ps1')
        }

        It 'names the absence of a review rather than a corrupt or missing head' {
            $gap = [pscustomobject]@{ SustainedCount = 0; BlockCount = 0; Gap = 0; ParseStatus = 'could-not-verify'; Reason = 'review-not-run' }
            $line = Format-EmissionGapLine -Surface 'code-review' -Id 4242 -Gap $gap

            $line | Should -Match 'no adversarial review is recorded'
            $line | Should -Not -Match 'partial, do not trust' -Because 'the generic wording sends a maintainer hunting a corrupt comment that does not exist'
            # The reassuring line is `#{Id}: clean -- sustained=...`. Match
            # that shape, not the bare word: this line legitimately contains
            # "reviewed-and-clean" while DENYING it.
            $line | Should -Not -Match ':\s*clean\s*--' -Because 'the whole point is that a review-less unit must not render the reassuring clean line'
        }

        It 'carries the counts, so it cannot suppress 811-D1''s loud negative-gap signal (M5)' {
            # The first draft returned a line with NO numbers, sitting above
            # the negative-gap arm whose own invariant is "never render clean
            # for this -- loud GAP-style wording". That made the new line
            # QUIETER than the line 811-D1 was written to prevent.
            $negative = [pscustomobject]@{ SustainedCount = -1; BlockCount = 0; Gap = -1; ParseStatus = 'could-not-verify'; Reason = 'review-not-run' }
            $line = Format-EmissionGapLine -Surface 'code-review' -Id 4242 -Gap $negative

            $line | Should -Match 'sustained=-1'
            $line | Should -Match 'excess=1'
            $line | Should -Match '811-D1'
        }

        It 'leaves design-challenge rendering byte-for-byte unchanged (817-D3 as narrowed by 817-D3a)' {
            # The amendment permits ONE bespoke code-review line; it does not
            # open every surface. design-challenge stays on the generic wording.
            $gap = [pscustomobject]@{ SustainedCount = 1; BlockCount = 0; Gap = 1; ParseStatus = 'could-not-verify'; Reason = 'head-corrupt' }
            Format-EmissionGapLine -Surface 'design-challenge' -Id 77 -Gap $gap |
                Should -Match 'partial, do not trust'
        }
    }

    Context 'the two copies of the five properties are one statement (#998 review M18)' {
        # The skill CLAIMS they are "restated in full" and "move together".
        # The first draft's copies had already diverged at landing, with
        # nothing pinning them -- the two-surfaces-disagreeing shape this
        # chunk's own differential rule exists to prevent, at prose grain.

        BeforeAll {
            $script:GetScopedProps = {
                param([string]$Path, [string]$Heading)
                $lines = @(Get-Content $Path)
                $start = -1
                for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $Heading) { $start = $i; break } }
                if ($start -lt 0) { return @() }
                $out = @()
                for ($i = $start + 1; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^#{2,3}\s') { break }
                    if ($lines[$i] -match '^\d\.\s+\*\*') { $out += $lines[$i] }
                }
                return $out
            }
        }

        It 'both surfaces state exactly five properties' {
            $c = & $script:GetScopedProps (Join-Path $script:RepoRoot 'CLAUDE.md') '^## What a finished run is true of'
            $s = & $script:GetScopedProps (Join-Path $script:RepoRoot 'skills/verification-before-completion/SKILL.md') '^## The Completion Account'
            $c.Count | Should -Be 5 -Because 'the root guidance file states the five properties'
            $s.Count | Should -Be 5 -Because 'the skill is the ONLY copy a consumer repository receives'
        }

        It 'the two copies are textually identical, property by property' {
            $c = & $script:GetScopedProps (Join-Path $script:RepoRoot 'CLAUDE.md') '^## What a finished run is true of'
            $s = & $script:GetScopedProps (Join-Path $script:RepoRoot 'skills/verification-before-completion/SKILL.md') '^## The Completion Account'
            for ($i = 0; $i -lt 5; $i++) {
                $s[$i] | Should -BeExactly $c[$i] -Because "property $($i + 1) must read the same on both surfaces; the skill claims they are one statement and a consumer repository sees only the skill"
            }
        }
    }

    Context 'the registry and the catalog agree on the account family (#998 review M20)' {
        # The first draft asserted only that the catalog MENTIONS the family --
        # a substring check that passes unchanged if the catalog documented
        # post-new while the registry declared upsert, which is exactly the
        # design-phase-complete drift its own comment cited.

        It 'the catalog documents the same write shape the registry declares' {
            $catalog = Get-Content (Join-Path $script:RepoRoot 'skills/session-memory-contract/references/handoff-markers.md') -Raw
            $row = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'completion-account' })[0]

            $m = [regex]::Match($catalog, '\(family\s+`completion-account`,\s*`(?<shape>[a-z][a-z-]*)`')
            $m.Success | Should -BeTrue -Because 'the catalog row must be parseable in the documented shape, or nothing can be compared against it'

            $documented = $m.Groups['shape'].Value
            $expected = if ($documented -eq 'upsert-in-place') { 'upsert' } else { $documented }
            $row.WriteShape | Should -BeExactly $expected -Because "handoff-markers.md documents completion-account as '$documented' while the registry declares '$($row.WriteShape)'"
        }

        It 'the catalog documents the same target surface the marker template implies' {
            $catalog = Get-Content (Join-Path $script:RepoRoot 'skills/session-memory-contract/references/handoff-markers.md') -Raw
            $row = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'completion-account' })[0]

            $catalog | Should -Match '<!-- completion-account-\{ID\} -->' -Because 'an {ID} placeholder implies an issue-keyed family'
            $row.TargetSurface | Should -BeExactly 'issue'
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
