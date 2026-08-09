#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for the /open surface (issue #974, chunk 3 of #957).

.DESCRIPTION
    Pins the four properties of this chunk that no other suite observes:

      1. The entrance has NO natural-language routing intent, checked by a
         probe carrying its own positive control. This cannot ride the
         general nl-intent-routing run: that suite's only per-entry loop
         asserts each declared intent resolves to an existing command file,
         so once commands/open.md exists an added /open intent makes it
         PASS. The absence needs a check that could have come out positive.

      2. The open-for-work-affirmed marker family is registered, is
         post-new (never upsert), and was APPENDED rather than inserted --
         the two positional fixtures in persist-marker-core.Tests.ps1 still
         select the families they selected before this row existed.

      3. The command and skill exist, the command halts rather than
         improvising when the methodology cannot be loaded, and the skill
         reaches beat 2, the floor, the escape hatch, and both outputs.

      4. post-pr-review names the close-out record at close time, scoped to
         issues that ran this flow, pointing at the existing ledger rather
         than re-emitting it.

      5. (issue #1028) The close-out obligation reaches the run that owes
         it: stated on the brief before the PR-creation action and marked
         advisory, backstopped at close time for a PR-less run, resting on
         the run-ends basis rather than the falsified findability one,
         scoped in EVERY register row that asserts auto-close suffices,
         naming the same two moments on every surface that states it,
         carrying its lifecycle rules where it is stated, and firing its
         amendment on the surface it names. The read set widens past the
         skills tree for this -- the doctrine document and the decision
         register are surfaces this suite never opened before.

    The affirmation gate's register entries and its skill-side rule block
    are pinned by engagement-gate-non-overridability.Tests.ps1, which owns
    the bounded-clause contract for every registered gate.
#>

Describe 'open-for-work surface (issue #974)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        $script:ReadRepoFile = {
            param([string]$RelativePath)
            $path = Join-Path $script:RepoRoot $RelativePath
            if (-not (Test-Path -LiteralPath $path)) { return '' }
            return (Get-Content -LiteralPath $path -Raw) -replace "`r`n?", "`n"
        }

        # The probe under test: given a routing table, return every entry
        # that would route a request to the open-for-work entrance. Written
        # to take the table as an argument precisely so it can be aimed at a
        # synthetic table that DOES contain such an entry.
        #
        # Matching is deliberately WIDER than an equality test on 'open'
        # (#974 review, M20): criterion 10's property is "no bare-pickup
        # intent FOR THE ENTRANCE", not "no intent literally named /open".
        # An alias spelled /orchestra:open or /open-for-work would satisfy
        # an equality test while routing to the same entrance, so the probe
        # keys on the command's last path segment containing the token
        # 'open', and also on an intent_key naming the entrance.
        $script:FindEntranceIntents = {
            param([object]$RoutingTable)

            $entries = @()
            if ($null -eq $RoutingTable) { return $entries }
            $nl = $RoutingTable.nl_intent_routing
            if ($null -eq $nl -or $null -eq $nl.entries) { return $entries }

            foreach ($entry in @($nl.entries)) {
                $matched = $false

                $commands = @($entry.claude_command, $entry.copilot_command) | Where-Object { $_ }
                foreach ($command in $commands) {
                    $leaf = ($command.TrimStart('/') -split ':')[-1]
                    if ($leaf -match '(^|-)open(-|$)') { $matched = $true; break }
                }

                if (-not $matched -and $entry.intent_key -and $entry.intent_key -match '(^|-)open(-|$)') {
                    $matched = $true
                }

                if ($matched) { $entries += $entry }
            }
            return $entries
        }

        $script:LiveRoutingConfig = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'skills/routing-tables/assets/routing-config.json') -Raw |
            ConvertFrom-Json
    }

    Context 'no natural-language routing intent for the entrance (criterion 10)' {

        It 'the probe finds planted entrance intents, including aliases it is weakest at (positive control)' {
            # Controls are planted in the shapes the probe is WEAKEST at, not
            # the one it cannot miss (#974 review, M20). A control spelled
            # exactly '/open' would pass under an equality test too and would
            # therefore prove nothing about alias coverage.
            $planted = @{
                nl_intent_routing = @{
                    source  = 'synthetic-positive-control'
                    entries = @(
                        [pscustomobject]@{
                            intent_key      = 'review-local'
                            patterns        = @('review this')
                            claude_command  = '/orchestra:review'
                            copilot_command = '/review'
                        },
                        [pscustomobject]@{
                            intent_key      = 'open-for-work'
                            patterns        = @("let's work on #?\d+", 'pick up #?\d+')
                            claude_command  = '/open'
                            copilot_command = $null
                        },
                        [pscustomobject]@{
                            intent_key      = 'pickup-namespaced-alias'
                            patterns        = @('pick up #?\d+')
                            claude_command  = '/orchestra:open'
                            copilot_command = $null
                        },
                        [pscustomobject]@{
                            intent_key      = 'pickup-suffixed-alias'
                            patterns        = @('start work on #?\d+')
                            claude_command  = '/open-for-work'
                            copilot_command = $null
                        }
                    )
                }
            } | ConvertTo-Json -Depth 6 | ConvertFrom-Json

            $hits = @(& $script:FindEntranceIntents $planted)
            $hitKeys = @($hits | ForEach-Object { $_.intent_key })
            $hitKeys | Should -Contain 'open-for-work' -Because 'the bare /open spelling must be caught'
            $hitKeys | Should -Contain 'pickup-namespaced-alias' -Because 'a namespaced alias routes to the same entrance and must be caught'
            $hitKeys | Should -Contain 'pickup-suffixed-alias' -Because 'a suffixed alias routes to the same entrance and must be caught'
            $hitKeys | Should -Not -Contain 'review-local' -Because 'the probe must not flag unrelated intents'
        }

        It 'the live routing table declares no intent that routes to the entrance' {
            $hits = @(& $script:FindEntranceIntents $script:LiveRoutingConfig)
            $intentKeys = ($hits | ForEach-Object { $_.intent_key }) -join ', '
            $hits.Count | Should -Be 0 -Because "the entrance is explicit-invocation only (#957 D9, Amendment 5): a bare pickup must not silently enter a flow whose first act is an engagement gate. Offending intents: $intentKeys"
        }

        It 'the live routing table is non-empty, so the negative result is not vacuous' {
            # PowerShell's @($null).Count is 1, not 0, and a PSCustomObject
            # returns $null for an absent property — so a bare .Count check
            # PASSES when the property has been renamed away. The probe fails
            # open the same way (it returns @() when $nl.entries is $null), so
            # a routing-schema rename would make criterion 10 vacuously green
            # in both directions at once. Assert the schema, then the content.
            $nl = $script:LiveRoutingConfig.nl_intent_routing
            $nl | Should -Not -BeNullOrEmpty `
                -Because 'a renamed nl_intent_routing key would make the probe return zero hits for the wrong reason'
            $nl.PSObject.Properties.Name | Should -Contain 'entries' `
                -Because 'the probe reads nl_intent_routing.entries; a renamed key must turn this red, not silently empty the probe'

            $realEntries = @($nl.entries | Where-Object { $null -ne $_ })
            $realEntries.Count | Should -BeGreaterThan 0 `
                -Because 'an empty table would make the absence assertion above trivially true'
        }
    }

    Context 'the open-for-work-affirmed marker family (criterion 2)' {

        BeforeAll {
            . (Join-Path $script:RepoRoot '.github/scripts/lib/marker-transport-core.ps1')
            . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1')
            . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-spine-core.ps1')
            . (Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-marker-core.ps1')
            $script:Registry = @(Get-MarkerFamilyRegistry)
        }

        It 'is registered as a post-new issue-surface family' {
            $row = @($script:Registry | Where-Object { $_.Family -eq 'open-for-work-affirmed' })
            $row.Count | Should -Be 1 -Because 'the affirmation record has exactly one registry row'
            $row[0].TargetSurface | Should -Be 'issue'
            $row[0].WriteShape | Should -Be 'post-new' -Because 'upsert PATCHes in place, which voids the record as an ordering witness, breaks the escape hatch''s new-record rule, and destroys the record sequence the re-route count is cross-checked against'
            $row[0].MarkerTemplate | Should -Be ('<' + '!-- open-for-work-affirmed-{ID} -->') -Because 'the catalog drift guard recognizes only -{ID}/-{PR} and silently skips any other placeholder token'
        }

        It 'was appended, not inserted: both positional fixtures still select their pre-#974 families' {
            # persist-marker-core.Tests.ps1 binds $script:PostNewFamily to
            # the FIRST post-new/issue row and $issueOnlyFamily to
            # the FIRST issue-surface row. open-for-work-affirmed is
            # post-new/issue with a null adapter and null post-step -- the
            # exact shape those fixtures select -- so an inserted row would
            # re-point roughly two dozen generic write-path assertions at it
            # while every one of them still passed.
            @($script:Registry | Where-Object { $_.WriteShape -eq 'post-new' -and $_.TargetSurface -eq 'issue' })[0].Family |
                Should -Be 'design-phase-complete'
            @($script:Registry | Where-Object { $_.TargetSurface -eq 'issue' })[0].Family |
                Should -Be 'plan-issue'
        }

        # The live accept/refuse behavior of the write primitive is checked
        # out-of-suite against the real script (this chunk's criterion-2
        # evidence): a suite test that called Invoke-PersistMarkerWrite
        # would issue a network write once the registry preflight passes,
        # which is exactly the stage this row changes.

        It 'is discoverable from the documented catalog, not only from the script' {
            $catalog = & $script:ReadRepoFile 'skills/session-memory-contract/references/handoff-markers.md'
            $catalog | Should -Match ([regex]::Escape('(family `open-for-work-affirmed`, `post-new`)')) `
                -Because 'the catalog is the surface CLAUDE.md points readers at, and the runtime never reads it'
            $catalog | Should -Match ([regex]::Escape('Open-for-work affirmation (interim form, issue 957 Amendment 8) - issue {ID}')) `
                -Because 'a resume must be able to recognise interim-form records from the catalog alone'
        }
    }

    Context 'the entrance command and its methodology (criteria 1, 8, 9)' {

        BeforeAll {
            $script:CommandText = & $script:ReadRepoFile 'commands/open.md'
            $script:SkillText   = & $script:ReadRepoFile 'skills/open-for-work/SKILL.md'

            # Slice one '## ' section out of the skill, so an assertion about
            # the resume can only be satisfied by text inside the resume.
            # Returns '' when the heading is absent, which reds the caller
            # rather than passing vacuously.
            $script:ResumeSection = {
                [regex]::Match(
                    $script:SkillText,
                    '(?ms)^##\s+Resuming an issue already opened for work\b.*?(?=^##\s|\z)'
                ).Value
            }

            # Tighter still: just the disclosure block, from its bolded
            # lead-in to the next '### ' heading. Needed because the resume
            # section ALREADY says 'earliest lawful' in step 2's ordering
            # check, so a section-scoped assertion on that phrase is satisfied
            # by text that predates #995 -- verified by mutation: deleting the
            # phrase from the disclosure block left the section-scoped
            # assertion green.
            #
            # Two scoping details, each closing a false green that a later
            # #995 review pass demonstrated against a mirror of the tree (the
            # first shape of this scoper stayed green through both mutations):
            #
            #   * It slices out of (& $script:ResumeSection), not out of
            #     $script:SkillText. Matching the whole document meant that
            #     relocating this entire block into a '##' section of its own
            #     left the suite green while the resume section the test is
            #     NAMED for carried no disclosure at all.
            #   * Its terminator is any '### ' heading, not the literal
            #     '### Deciding the state'. An end-of-document fallback
            #     anchored on one heading title widens the block to \z the
            #     moment that heading is renamed, and step 2's ordering check
            #     -- which also says 'earliest lawful' -- then satisfies the
            #     assertion from pre-#995 text.
            #
            # Residual, stated rather than left implied: DELETING every '###'
            # heading below the block still widens it to the end of the resume
            # section. Closing that needs a positive end anchor, which would
            # pin prose this guard has no business pinning.
            #
            # The two scopers did not land together: ResumeSection came in
            # f28b4aa, DisclosureBlock in 6193826.
            $script:DisclosureBlock = {
                [regex]::Match(
                    (& $script:ResumeSection),
                    '(?ms)^\*\*Who posted it.*?(?=^###\s|\z)'
                ).Value
            }
        }

        It 'the command exists and loads the methodology skill' {
            $script:CommandText | Should -Not -BeNullOrEmpty
            $script:CommandText | Should -Match ([regex]::Escape('skills/open-for-work/SKILL.md'))
        }

        It 'the command halts on a failed methodology load instead of improvising one' {
            $script:CommandText | Should -Match ([regex]::Escape('Skill load failed for skills/open-for-work/SKILL.md')) `
                -Because 'the halt message must be exact enough for an operator to recognise'
            $script:CommandText | Should -Match '(?i)cannot continue without the canonical methodology'
            $script:CommandText | Should -Match '(?i)do not improvise the flow'
        }

        It 'the skill reaches past beat 1 — the floor, beat 2, the escape hatch, and both outputs' {
            # Criteria 8 and 9 exist because a skill carrying only the
            # worth-it check and beat 1 would have satisfied the first
            # draft's criteria while shipping a flow that could not route,
            # floor, or produce either output.
            $script:SkillText | Should -Match '(?i)trivial floor'
            $script:SkillText | Should -Match '(?i)fails closed'
            $script:SkillText | Should -Match '(?i)beat 2'
            $script:SkillText | Should -Match '(?i)escape hatch'
            $script:SkillText | Should -Match '(?i)routine arm'
            $script:SkillText | Should -Match '(?i)novel arm'
        }

        It 'the floor risk-guard clause is unqualified, not merely present' {
            # #974 review, M27: a bare presence assertion stays green when a
            # meaning-inverting qualifier is APPENDED to the pinned clause
            # ("...is never below the floor, unless the change is confined to
            # a single file"). Pin the clause AND the absence of a trailing
            # exemption, so the invertible edit turns this red.
            # The tail runs to the end of the PARAGRAPH (first blank line), not
            # the end of the line: markdown prose wraps, so a trailing "unless…"
            # lands on the next physical line as a matter of ordinary reflow and
            # would escape a single-line window entirely.
            $guard = [regex]::Match(
                $script:SkillText,
                'permission, authentication, or data-integrity behavior is never below the floor(?<tail>[^\n]*(?:\n(?!\s*\n)[^\n]*)*)')
            $guard.Success | Should -BeTrue -Because 'the risk guard must be stated verbatim in the skill'
            # This alternation is INCREMENTAL HARDENING, not closure. It is an
            # open-ended denylist -- 'aside from', 'subject to', 'so long as',
            # 'barring', 'with the exception of' would all slip through. It
            # raises the cost of an accidental invalidating append; it does not
            # make one impossible. If that guarantee is ever needed, pin the
            # whole risk-guard sentence verbatim and drop the denylist.
            $guard.Groups['tail'].Value | Should -Not -Match '(?i)\b(unless|except|other than|save (for|where)|provided that|does not apply|only (when|if))\b' `
                -Because 'the risk guard admits no exemption; a trailing qualifier anywhere in the same paragraph inverts it while leaving the clause present'
        }

        It 'the skill fixes every gate-decision token field, including classification and outcome' {
            # #974 review, M10: the earlier version of this test asserted
            # only phase, two decision ids, and window_position — so the
            # classification and outcome COLUMNS, which are what
            # gate-reconciliation-core.ps1 actually branches on, could be
            # deleted wholesale and it stayed green.
            $script:SkillText | Should -Match ([regex]::Escape('phase: experience'))
            $script:SkillText | Should -Match ([regex]::Escape('open-for-work-affirmation-{ID}'))
            $script:SkillText | Should -Match ([regex]::Escape('open-for-work-brief-approval-{ID}'))

            # Assert the table itself carries all five columns, and that each
            # checkpoint row states a classification and an outcome — read
            # from the table rows, not from surrounding prose (which is where
            # a bare 'pre-ask' substring assertion silently passed off).
            $header = [regex]::Match(
                $script:SkillText,
                '(?m)^\|\s*Checkpoint\s*\|\s*`decision_id`\s*\|\s*`window_position`\s*\|\s*`classification`\s*\|\s*`outcome`\s*\|')
            $header.Success | Should -BeTrue -Because 'the token table must declare all five fields as columns'

            $rows = @([regex]::Matches(
                    $script:SkillText,
                    '(?m)^\|\s*(?<checkpoint>Worth-it doors|Affirmation gate|Brief approval[^|]*?)\s*\|(?<rest>.*)$'))
            $rows.Count | Should -Be 3 -Because 'all three checkpoints the flow runs must have a row'
            foreach ($row in $rows) {
                $cells = @($row.Groups['rest'].Value -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $cells.Count | Should -BeGreaterOrEqual 4 -Because "row '$($row.Groups['checkpoint'].Value.Trim())' must fill decision_id, window_position, classification and outcome"
                $cells[1] | Should -Match 'pre-ask' -Because 'window_position must be the pre-dispatch firing position'
                $cells[2] | Should -Match '(?i)load-bearing|routine' -Because 'classification must be stated per checkpoint'
                $cells[3] | Should -Match '(?i)asked|declined|same-decision-resume|gate-fails|greenfield-defer' -Because 'outcome must be stated per checkpoint'
            }
        }

        It 'the skill states that a clean reconciliation over zero tokens does not discharge the obligation' {
            # #974 review, M11: gate-reconciliation-core.ps1 returns
            # status=clean whenever findings is empty, which includes the
            # zero-token case — so "clean discharges this" let a run that
            # emitted nothing pass its own check.
            $script:SkillText | Should -Match ([regex]::Escape('token_count')) `
                -Because 'the check must read token_count, not status alone'
            $script:SkillText | Should -Match '(?i)does not discharge this' `
                -Because 'the skill must say plainly that a clean status alone is insufficient'
        }

        It 'the skill tells a resume to read comments from a source carrying updated_at' {
            $script:SkillText | Should -Match ([regex]::Escape('gh api repos/{owner}/{repo}/issues/{ID}/comments --paginate')) `
                -Because 'gh issue view --json comments carries includesCreatedEdit and no updated_at, so the void-if-edited rule cannot be evaluated from it -- and --paginate is load-bearing in its own right: a first-page-only read misses a lawful record on a long-threaded issue. Pin the flag, not just the endpoint; this PR already dropped it once elsewhere (round-2 finding gh-3706084076)'
            # Scoped to the section rather than the document. #995 round-1
            # finding M17: this pin was `$script:SkillText | Should -Match`,
            # and occurrences of `affirmed-not-routed` went 2 -> 3 when the
            # trust model gained a paragraph ~90 lines away, so a
            # document-wide match became satisfiable by prose that has
            # nothing to do with the state table this test is about.
            (& $script:ResumeSection) | Should -Match '(?i)affirmed-not-routed' `
                -Because 'the state the resume lands in when a record exists but beat 2 is unrun must be named inside the section that decides state'
        }

        It 'the resume section carries the author-disclosure obligation (#995 guard, not criterion evidence)' {
            # THIS IS A GUARD, NOT EVIDENCE. #995's acceptance criteria are
            # discharged by cold reads of the changed text by fresh readers,
            # never by text presence -- a test asserting a sentence exists
            # cannot fail for the reason those criteria care about, and the
            # brief says so in its own falsifiers. What this buys is narrower
            # and still worth having: without it, deleting the disclosure
            # outright leaves this suite green (round-1 finding M17).
            $resuming = & $script:ResumeSection
            $resuming | Should -Not -BeNullOrEmpty `
                -Because 'the section heading must be findable before anything can be scoped to it'

            $disclosure = & $script:DisclosureBlock
            $disclosure | Should -Not -BeNullOrEmpty `
                -Because 'the disclosure block must be findable; if its lead-in is gone the obligation is gone'

            $disclosure | Should -Match ([regex]::Escape('user.login')) `
                -Because 'the field the disclosure is built on has to be named where the resume reads comments, or the instruction has no referent'

            # The load-bearing half. Round-1 finding M2 (the only sustained
            # high): naming ONLY the record being resumed under leaves the
            # earliest lawful record unnamed -- and the earliest is what step
            # 2 derives lawfulness from, so a planted record can supply the
            # authority and never appear in the output. Disclosure that runs
            # and shows nothing is the failure mode this change exists to
            # avoid, so it gets the assertion.
            #
            # Asserted against the DISCLOSURE BLOCK, not the whole section:
            # step 2 already said 'earliest lawful' before #995, so a
            # section-scoped assertion here passes on pre-existing text.
            # Mutation-verified in 6193826, and again after the block scoper
            # was rederived from the resume section (see BeforeAll).
            $disclosure | Should -Match '(?i)earliest lawful' `
                -Because 'the output obligation must itself name the record the ordering check reads, because that is the one a single-record disclosure hides'
            $disclosure | Should -Match '(?i)name both' `
                -Because 'M2: the output obligation must reach both records when they differ, not only the resumed-under one'
        }

        It 'both trust-model sites answer all four planted-record questions (#995 guard)' {
            # Paired-presence, deliberately: the risk this guards is DRIFT
            # BETWEEN the two sites, not the wording of either. Round-1
            # finding M5 was exactly that -- the doctrine site had dropped the
            # delete prohibition and the earliest-record consequence the skill
            # carried. Deleting a clause from one site alone reds this; both
            # sites drifting together does not, which is honest about what a
            # presence pair can detect.
            $doctrine = & $script:ReadRepoFile 'Documents/Design/open-for-work.md'
            $doctrine | Should -Not -BeNullOrEmpty

            # Scoped to each file's trust model, not to the whole file. A
            # whole-file probe cannot see the drift it is named for: dropping
            # the author-blind claim from the SKILL's trust model left the
            # pair green, because the alternative 'is conditioned on who
            # posted it' is answered in § Resuming -- a different section,
            # about a different obligation. That mutation IS the drift.
            # No `|\z` fallback here, deliberately, and this is the one
            # asymmetry with $script:DisclosureBlock above. An end-of-document
            # fallback would let the block widen to swallow § Resuming the
            # moment no '##' heading follows the trust model -- and § Resuming
            # carries 'is conditioned on who posted it', which is probe 5's
            # third alternative. That is exactly the false green this scoper
            # was written to close, restored through the back door.
            # Reproduced before removing it: demote every '##' heading below
            # the trust model and strip author-blind from the SKILL's copy,
            # and the parity assertion passed. Without the fallback that shape
            # yields an empty match instead, which the non-empty guards below
            # turn into a loud red. Failing to find the block is the correct
            # outcome when the block cannot be delimited; over-capturing is not.
            $trustModel = {
                param([string]$Text)
                [regex]::Match($Text, '(?ms)^\*\*Trust model.*?(?=^#{2,}\s)').Value
            }
            $skillTrust    = & $trustModel $script:SkillText
            $doctrineTrust = & $trustModel $doctrine
            $skillTrust | Should -Not -BeNullOrEmpty `
                -Because 'the skill''s trust model must be findable before anything can be scoped to it'
            $doctrineTrust | Should -Not -BeNullOrEmpty `
                -Because 'the doctrine''s trust model must be findable before anything can be scoped to it'

            $probes = [ordered]@{
                'anyone who can comment can post an accepted record' = '(?i)anyone (with a GitHub account )?who can comment'
                'nothing gates it'                                   = '(?i)no author check, no permission check'
                'this is accepted rather than overlooked'            = '(?i)known and accepted'
                'what to do on noticing one'                         = '(?i)do not resume under (it|that record)'
                'no authorship condition was added'                  = '(?i)author-blind|stay author-blind|is conditioned on who posted it'
            }
            foreach ($probe in $probes.GetEnumerator()) {
                $skillTrust | Should -Match $probe.Value `
                    -Because "the skill's trust model must answer: $($probe.Key)"
                $doctrineTrust | Should -Match $probe.Value `
                    -Because "the doctrine's trust model must answer: $($probe.Key) -- a statement landing at one site and not the other is the drift this repository's parity discipline exists against"
            }
        }

        It 'the resume decides state from sequence, not merely from which artifacts exist' {
            # #974 review, M2/M3/M6 collapsed to one root cause: a
            # presence-based state table cannot see a routing artifact that
            # predates the affirmation record (property 3's whole point), nor
            # the window after the escape hatch re-affirms but before beat 2
            # is re-run.
            $script:SkillText | Should -Match '(?i)earliest lawful' `
                -Because 'the ordering comparison must name WHICH record it uses; a latest-record reading declares every lawful escape-hatch run unlawful'
            $script:SkillText | Should -Match '(?i)re-affirmed-not-re-routed' `
                -Because 'the window between re-affirmation and beat-2 re-run needs its own state, or it reads as routed'
            $script:SkillText | Should -Match '(?i)not lawful under source \(b\)' `
                -Because 'the ordering check must state the outcome when it fails'
        }

        It 'the supersession check accounts for the brief plan comment being upsert-in-place' {
            # Round-3 finding fc-2: the plan-issue family is upsert, and a PATCH
            # can never advance created_at — only updated_at. A created_at-only
            # supersession check therefore reports a re-persisted brief as
            # permanently older than the affirmation that superseded it, so a
            # correctly-routed issue is misclassified re-affirmed-not-re-routed
            # on every future resume, and that row instructs a re-author which
            # PATCHes over the reviewed brief.
            $script:SkillText | Should -Match '(?i)upsert-in-place' `
                -Because 'the resume must name the write shape that makes created_at unreliable for this artifact'
            $script:SkillText | Should -Match '(?i)can never advance' `
                -Because 'the reason created_at is insufficient must be stated, not just worked around'
            $script:SkillText | Should -Match '(?i)Upgrade to \*\*`routed`\*\* only when \*\*both\*\* hold' `
                -Because 'the upgrade to routed requires the updated_at check AND the content read together, not either alone'

            # Step 2 must stay on created_at: it asks when the artifact came
            # into existence, and an updated_at reading would let an artifact
            # created before any record pass merely because it was touched
            # afterwards.
            $script:SkillText | Should -Match '(?i)on both sides' `
                -Because 'the back-fit check must be explicitly pinned to created_at so a later edit does not generalise the updated_at fix onto it'
        }

        It 'the re-route count is not defined as arithmetic over comment counts' {
            # #974 review, M6: records-minus-one disagrees with the observed
            # count in three directions (voided records, no-op writes,
            # retried writes), so neither surface may state it as the
            # definition.
            foreach ($text in @($script:SkillText, (& $script:ReadRepoFile 'skills/post-pr-review/SKILL.md'))) {
                $text | Should -Not -Match '(?i)derivable by counting the issue''s affirmation records and subtracting one' `
                    -Because 'that phrasing is the arithmetic definition the review found wrong in three directions'
            }
            $script:SkillText | Should -Match '(?i)cross-check, not the definition' `
                -Because 'the skill must say what comment counting is for'
        }
    }

    Context 'the close-out record''s close-time reader (criterion 7)' {

        BeforeAll {
            $script:PostPrText = & $script:ReadRepoFile 'skills/post-pr-review/SKILL.md'

            # Extract Step 9's own body so the assertions below cannot be
            # satisfied by a phrase that migrated to another section. Without
            # this, deleting a Step 9 item leaves the suite green whenever the
            # same words appear anywhere else in the file — the exact
            # document-scope defect this Context is meant to catch.
            $step9 = [regex]::Match(
                $script:PostPrText,
                '(?ms)^### 9\.\s*Close-Out Record[^\n]*\n(?<body>.*?)(?=^#{2,3}\s|\z)')
            $script:Step9Text = $step9.Groups['body'].Value
        }

        It 'the close-time checklist carries the close-out record step' {
            $script:PostPrText | Should -Match '(?m)^### 9\. Close-Out Record'
            $script:Step9Text | Should -Not -BeNullOrEmpty -Because 'Step 9 must have a body to assert against'
            $script:Step9Text | Should -Match '(?i)dead-premises note'
            $script:Step9Text | Should -Match '(?i)re-route count'
        }

        It 'the step is scoped to issues that ran the flow' {
            $script:Step9Text | Should -Match '(?i)affirmation record'
            $script:Step9Text | Should -Match '(?i)does not apply otherwise' `
                -Because 'an unconditional instruction turns every unrelated close into a demand for a beat-2 re-route count'
        }

        It 'the step points at the existing ledger rather than emitting one' {
            $script:Step9Text | Should -Match '(?i)does not emit ledger blocks'
        }

        It 'the step defines a zero-findings form for a close with no ledger' {
            # Reachable on a PR-less close and on a novel-arm parent closed
            # after its chunks carried their own reviews; without a stated
            # form, an agent invents a ledger reference or omits the item.
            $script:Step9Text | Should -Match '(?i)no phase-containment ledger was produced' `
                -Because 'the no-ledger case needs an explicit sentence, not silence'
        }

        It 'the completion section routes to the step, so the walk does not terminate before it' {
            # The close-time path continues past ## Completion into
            # ## Structured Outcome Contract; the walk must reach Step 9
            # from the checklist and be re-pointed at it from Completion.
            $completion = [regex]::Match($script:PostPrText, '(?ms)^## Completion\s*\n(?<body>.*?)(?=^## |\z)')
            $completion.Success | Should -BeTrue
            $completion.Groups['body'].Value | Should -Match '(?i)close-out record'
        }
    }

    Context 'the close-out obligation reaches the run that owes it (issue #1028)' {

        # One It per pinned property of AC1-AC7, so a regression in any one
        # of them reddens on its own. A single aggregate assertion would go
        # red for the whole deliverable and establish nothing about which
        # property broke.
        #
        # The read set is deliberately WIDER than the skills tree. Before
        # this Context the suite never opened the doctrine document or the
        # decision register, so the doctrine could contradict the skill and
        # every assertion here would still pass -- that read-set gap is the
        # defect this Context exists to close, not an incidental detail.
        #
        # NAMED RESIDUES -- properties AC1-AC7 state that these checks do
        # NOT fully express. AC8 requires naming such a property rather
        # than dropping it silently, so they are named here and in the PR's
        # evidence account. Each was demonstrated by an executed mutation
        # that left this Context green before the current shape landed.
        #
        #   1. AC4 ("no register row asserts unconditionally"). Rows are
        #      selected by VOCABULARY. The set was widened after a mutation
        #      inserting a third row ("The closing keyword alone discharges
        #      the issue; no follow-up note on the issue is ever needed")
        #      passed green; that phrasing is now caught. But "every row"
        #      is not decidable by pattern -- a row asserting sufficiency
        #      in wording none of these patterns anticipates still escapes.
        #      This is exactly the trap the brief's own falsifier names:
        #      the vocabulary is the limit, not the diligence.
        #   2. AC3 ("stops telling them something false"). The negative is
        #      keyed on the "can still find" claim family, after a match on
        #      the deleted sentence verbatim let a paraphrase back in. A
        #      restatement of the findability basis sharing none of that
        #      wording still escapes. Whether a sentence asserts the
        #      falsified basis is a reading, not a match.
        #   3. AC5 ("every surface"). The surface set is DISCOVERED by scan
        #      rather than hand-listed, which closes the new-surface
        #      mutation. The residue is the discovery predicate itself: a
        #      surface stating the obligation without ever using the phrase
        #      "close-out record" is invisible to the scan -- the same
        #      class as the register row that used no such phrase and was
        #      missed twice by earlier passes.
        #
        # None of the three is closable by a stronger regex; closing them
        # needs a reader. Do not add a detector to paper over it: the brief
        # declined that mechanism deliberately, and nothing here re-checks
        # these properties once a run ends.

        BeforeAll {
            $script:PostPr = & $script:ReadRepoFile 'skills/post-pr-review/SKILL.md'
            $script:OfwSkill = & $script:ReadRepoFile 'skills/open-for-work/SKILL.md'
            $script:OfwDoctrine = & $script:ReadRepoFile 'Documents/Design/open-for-work.md'
            $script:PlanAuthoring = & $script:ReadRepoFile 'skills/plan-authoring/SKILL.md'
            $script:SessionHooks = & $script:ReadRepoFile 'Documents/Design/session-hooks.md'
            $script:SkillsIndex = & $script:ReadRepoFile 'skills/README.md'
            $script:OpenCommand = & $script:ReadRepoFile 'commands/open.md'
            $script:ResponseLoop = & $script:ReadRepoFile 'skills/code-review-intake/references/response-loop-completion.md'
            $script:ReviewJudgment = & $script:ReadRepoFile 'skills/review-judgment/SKILL.md'

            # Every lane that runs a judge, keyed by the entry document a
            # reader of that lane actually opens. This map is the AC1/AC2/AC3
            # property in executable form: reach is a lane's own entry
            # document naming the home, not a file some later hop happens to
            # open. `/orchestra:review-prosecute` and `-defend` are absent
            # deliberately -- both stop before judge, so no pass on them can
            # sustain a finding.
            # `/spine-run` is absent deliberately and the reason is pinned by
            # the out-of-population assertion below rather than left to this
            # comment: Spine-Runner dispatches no judge -- its `review` port
            # is `skill-only`, verifying a PR-body row another lane emitted.
            # A verifier of someone else's judge sustains no findings, so it
            # triggers no amendment. PR #1041's panel asserted the opposite
            # across two lenses and the judge sustained it; reading
            # `agents/Spine-Runner.agent.md` § Dispatch Table falsified it.
            $script:JudgeLanes = @{
                'local review (/orchestra:review)'       = 'commands/orchestra-review.md'
                'local review (/orchestra:review-lite)'  = 'commands/orchestra-review-lite.md'
                'local review (/orchestra:review-judge)' = 'commands/orchestra-review-judge.md'
                'GitHub intake (/review-github)'         = 'commands/review-github.md'
                'Conductor local review'                 = 'agents/Code-Conductor.agent.md'
                'goal-run Stage 3'                       = 'agents/Goal-Run.agent.md'
            }

            # The obligation's home, extracted so an assertion cannot be
            # satisfied by text elsewhere in a 790-line file.
            # Terminator is `^#{1,5}\s`, not `^#{2,4}\s`. The narrower form
            # cannot match an h5 at all -- it consumes four '#' then needs
            # whitespace against the fifth -- so demoting the terminating
            # heading to `#####` silently ran the span past the section and
            # quietly retired the "cannot be satisfied by text elsewhere"
            # property this extraction exists for.
            $script:CloseOutHome = [regex]::Match(
                $script:PlanAuthoring,
                '(?ms)^#### The close-out obligation on an affirmation-record issue[^\n]*\n(?<body>.*?)(?=^#{1,5}\s|\z)'
            ).Groups['body'].Value

            $script:Step9 = [regex]::Match(
                $script:PostPr,
                '(?ms)^### 9\.\s*Close-Out Record[^\n]*\n(?<body>.*?)(?=^#{2,3}\s|\z)'
            ).Groups['body'].Value
        }

        It 'AC1 - the obligation is stated on the brief, before the PR-creation action, and as advisory' {
            $script:CloseOutHome | Should -Not -BeNullOrEmpty `
                -Because 'the brief is the artifact every failing run was dispatched against; without this section the obligation reaches none of them'
            $script:CloseOutHome | Should -Match '(?i)before the PR-creation action' `
                -Because 'a moment stated after the PR is created is read too late to act on'
            $script:CloseOutHome | Should -Match '(?i)advisory obligation, not a blocking gate' `
                -Because 'D2a decided advisory; leaving the force unstated lets a blocking gate satisfy every other property'
            $script:CloseOutHome | Should -Match '(?i)does not apply otherwise' `
                -Because 'relocating the statement must not widen the population the obligation binds'
        }

        It 'AC2 - the close-time backstop is stated where a PR-less run meets it' {
            $closeOut = [regex]::Match(
                $script:OfwSkill,
                '(?ms)^## Close-out\s*\n(?<body>.*?)(?=^## |\z)'
            ).Groups['body'].Value

            $closeOut | Should -Not -BeNullOrEmpty
            $closeOut | Should -Match '(?i)before the close' `
                -Because 'the PR-less reader is this section, and the post-merge checklist arrives after the close by construction'
            $closeOut | Should -Match '(?i)without a pull request' `
                -Because 'the backstop exists for exactly the population a pre-PR moment cannot reach'
        }

        It 'AC3 - the ordering rule gives the run-ends basis, drops the falsified one, and states its limit' {
            $script:Step9 | Should -Match '(?i)the run ends at the close' `
                -Because 'that is the basis that actually holds'
            # Keyed on the CLAIM family, not the deleted sentence. Matching
            # the original sentence verbatim let a paraphrase of the same
            # falsified basis back in with the suite green (demonstrated:
            # "Write it before the close so a reader can still find the
            # issue the record sits on." passed). Still narrower than the
            # property AC3 states -- see named residue 2 above.
            $script:Step9 | Should -Not -Match '(?i)can still find' `
                -Because 'the findability rationale is falsified at the grain this step itself reads, and a paraphrase reintroduces the same false claim'
            $script:Step9 | Should -Match '(?i)ages? out of time-windowed sweeps' `
                -Because 'without the surviving limit a reader over-learns the correction into "ordering never matters"'
        }

        It 'AC4 - every register row asserting auto-close suffices is scoped, not just the known one' {
            # Reads EVERY row that makes the assertion. The register never
            # uses the phrase "close-out" at all, and its second row uses
            # different vocabulary from its first -- a check keyed on one
            # row, or on this repository's usual vocabulary, misses it.
            # Vocabulary widened past the two rows known to exist, so a
            # third row phrased differently has a chance of being read.
            # This reduces the escape; it does not close it -- residue 1.
            $rows = @(
                $script:SessionHooks -split "`n" | Where-Object {
                    $_ -match '(?i)auto-close is sufficient' -or
                    $_ -match '(?i)Summary comment on issue' -or
                    $_ -match '(?i)closing keyword alone' -or
                    ($_ -match '(?i)(auto[- ]?close|closes #|closing keyword)' -and
                     $_ -match '(?i)(sufficient|discharges|no .{0,40}(comment|note|record).{0,25}(needed|required))')
                }
            )

            $rows.Count | Should -BeGreaterOrEqual 2 `
                -Because 'the register carries two such rows; finding fewer means the probe stopped reading early'

            foreach ($row in $rows) {
                $row | Should -Match '(?i)affirmation record' `
                    -Because "this register row asserts auto-close suffices and must name the population it does not cover: $row"
            }
        }

        It 'AC5 - every surface stating the obligation names the same two moments' {
            # The surface set is DISCOVERED, not hand-listed. A hardcoded
            # list cannot fail the way AC5 needs it to: adding a brand-new
            # skill stating only the post-merge moment -- the exact
            # regression AC5 exists to prevent -- left a hand-listed
            # version of this assertion green, demonstrated by mutation.
            # `agents` added in #1041 round 2: the amendment's lane wiring put
            # close-out text into agent bodies, which sat outside all three
            # original roots and were therefore reachable by neither the
            # two-moments assertion nor either carve-out guard.
            $roots = @('skills', 'commands', 'Documents/Design', 'agents')
            $candidates = @(
                foreach ($root in $roots) {
                    $full = Join-Path $script:RepoRoot $root
                    if (Test-Path -LiteralPath $full) {
                        Get-ChildItem -LiteralPath $full -Recurse -File -Filter '*.md' |
                            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?i)close-out record' }
                    }
                }
            )

            # Carve-out, stated rather than silent. These surfaces carry the
            # record's AMENDMENT LIFECYCLE rule, not the statement of when
            # the record is owed, so "names the same two moments" does not
            # apply to them. Membership rule: a surface is in AC5's set when
            # it tells a reader the record is OWED; it is carved out when it
            # only tells a reader how an existing record is later amended.
            #
            # The list grew from three to thirteen in #1039, when the amendment
            # rule moved to a lane-neutral home and every lane's entry
            # document had to name it. A longer hand-list is a longer thing
            # to go stale, so the two checks below make the list itself
            # falsifiable in both directions the brief named -- an entry that
            # no longer belongs, and an entry quietly absorbing text it was
            # never exempted for.
            $amendmentOnly = @(
                'skills/review-judgment/SKILL.md',
                'skills/review-judgment/platforms/claude.md',
                'skills/code-review-intake/SKILL.md',
                'skills/code-review-intake/references/response-loop-completion.md',
                'skills/validation-methodology/references/review-reconciliation.md',
                'skills/persist-changes/SKILL.md',
                'commands/orchestra-review.md',
                'commands/orchestra-review-lite.md',
                'commands/orchestra-review-judge.md',
                'commands/review-github.md',
                'agents/Code-Conductor.agent.md',
                'agents/Goal-Run.agent.md',
                # The skills index ROUTES to the obligation rather than
                # stating it -- its close-out clause points at plan-authoring
                # for the two moments, and that pointer is pinned by the AC7
                # It below, which follows it and checks the destination
                # actually states both. Requiring the index to restate the
                # moments would be the duplication AC7 exists to avoid.
                'skills/README.md'
            )

            $candidateRels = @($candidates | ForEach-Object {
                    ($_.FullName.Substring($script:RepoRoot.Length).TrimStart('\', '/')) -replace '\\', '/'
                })

            # Floor moved off the RAW candidate count in #1041 round 2. The
            # outbound loop below requires every exempt path to be a
            # candidate, so a raw floor at or below the exemption-list length
            # is ENTAILED by that loop and can no longer come out negative:
            # the scan could collapse to exactly the exempt set and a raw
            # floor would still pass while the two-moments loop iterated zero
            # files. The floor now counts the surfaces actually CHECKED.
            $checkedCount = @($candidateRels | Where-Object { $amendmentOnly -notcontains $_ }).Count

            $checkedCount | Should -BeGreaterOrEqual 6 `
                -Because 'the two-moments assertions below must actually iterate; a scan returning only exempt surfaces makes AC5 vacuously true with the suite green'

            # OUTBOUND staleness: an exemption for a path the scan no longer
            # reaches is dead text that reads as live coverage. Renaming,
            # deleting, or emptying an exempted surface reddens here rather
            # than silently shrinking the checked set.
            foreach ($rel in $amendmentOnly) {
                $candidateRels | Should -Contain $rel `
                    -Because "$rel is exempted from AC5 but the discovery scan no longer finds it; a carve-out for a surface that no longer mentions the record exempts nothing and hides that the set shrank"
            }

            # INBOUND half-in guard: an exempted surface must be amendment-only
            # all the way through. If one starts telling a reader WHEN the
            # record is owed, it belongs in AC5's set and must satisfy the
            # assertions below -- not sit exempt while stating half the rule.
            # Discriminating on the delivered tree: all thirteen state neither
            # moment and all six non-exempt surfaces state both, so the split
            # is clean and moving any file across it reddens one side or the
            # other.
            foreach ($rel in $amendmentOnly) {
                $exempt = (& $script:ReadRepoFile $rel) -replace "`r`n?", "`n"
                $exempt | Should -Not -Match '(?i)before the PR-creation action' `
                    -Because "$rel is exempted as amendment-only, so it must not also state when the record is owed; move it out of the exemption list instead"
                # `(?![-\w])` not `\b`: the hyphen in "close-out" IS a word
                # boundary, so `before the close\b` matched "before the
                # close-out record is amended" -- a false red on the exact
                # vocabulary all thirteen exempt surfaces are written in. The
                # positive arm below deliberately uses the same shape, so the
                # two arms can no longer disagree about what "before the
                # close" means (a surface writing "before the closeout"
                # satisfied one and escaped the other).
                $exempt | Should -Not -Match '(?i)before the close(?![-\w])' `
                    -Because "$rel is exempted as amendment-only, so it must not also state the close-time backstop; move it out of the exemption list instead"
            }

            foreach ($file in $candidates) {
                $rel = ($file.FullName.Substring($script:RepoRoot.Length).TrimStart('\', '/')) -replace '\\', '/'
                if ($amendmentOnly -contains $rel) { continue }

                $text = (Get-Content -LiteralPath $file.FullName -Raw) -replace "`r`n?", "`n"
                $text | Should -Match '(?i)before the PR-creation action' `
                    -Because "$rel states the close-out obligation and must name the pre-PR moment"
                # Same shape as the exempt-side arm above, deliberately: when
                # the two arms differ, a surface can satisfy one and escape
                # the other. `(?!-)` also stops "before the close-out record"
                # counting as a statement of the backstop moment.
                $text | Should -Match '(?i)before the close(?![-\w])' `
                    -Because "$rel states the close-out obligation and must name the close-time backstop"
            }
        }

        It 'AC6 - the record lifecycle rules are readable where the obligation is stated' {
            $script:CloseOutHome | Should -Match '(?i)provisional until the PR merges' `
                -Because 'a pre-PR record describes a run that has not landed'
            $script:CloseOutHome | Should -Match '(?i)amends the existing record rather than posting a new one' `
                -Because 'two records on one issue leave no way to tell which is current'
            # #1039 retired the 'Response Loop Completion' pin and replaced
            # it with the pin below. The retirement has a reason, stated
            # rather than silent: that surface is the GitHub-intake lane's
            # terminal sequence, so pinning it here asserted the amendment
            # rule lives somewhere two of the three judge-running lanes never
            # load. The property the pin exists for -- the obligation's home
            # names a firing surface -- is not weakened; it is re-established
            # against the lane-neutral home on the next line.
            $script:CloseOutHome | Should -Match '(?i)review-judgment/SKILL\.md[`\s]*§[`\s]*Close-Out Record Amendment' `
                -Because 'an amendment rule with no firing surface reproduces the defect it was written to close, and a firing surface only one lane loads reproduces it one level down'
        }

        It 'AC6 - the named firing surface actually carries the amendment step' {
            # SCOPED to the amendment section's own body, not matched against
            # the whole document (external review, PR #1033 F6, post-fix
            # round 2 M-A/M-B/M-C). A whole-document match has already burned
            # this suite three times -- see the CloseOutHome and Step9
            # scopers above, #995 round-1 M17, and the step-6 instance this
            # scoper replaces, where every un-scoped assertion stayed green
            # through inverting "Advisory ... never halts the loop" to
            # "Blocking ... halts the loop until resolved".
            #
            # Terminator is `^##\s` -- exactly two hashes then whitespace, so
            # the section's own `###` children stay inside the span while the
            # next h2 ends it. Demoting that next h2 to `###` would run the
            # span past the section, so the over-run assertion below closes
            # the same hole the CloseOutHome scoper's `^#{1,5}\s` closes for
            # its own extraction.
            $amendment = [regex]::Match(
                $script:ReviewJudgment,
                '(?ms)^## Close-Out Record Amendment[^\n]*\n(?<body>.*?)(?=^##\s|\z)'
            ).Groups['body'].Value

            $amendment | Should -Not -BeNullOrEmpty `
                -Because 'the amendment section must exist and have a body to assert against'
            # Keyed on the neighbouring section's HEADING at any level, not on
            # a token that happens to live inside it. The previous canary
            # (`stable_finding_key`) sat in a sub-section that could migrate
            # to a reference file, retiring the guard silently. The demotion
            # case it exists for is real: `## Post-Judge Disposition Gate` is
            # the file's last h2, so demoting it runs the span to `\z`.
            $amendment | Should -Not -Match '(?m)^#{1,6}\s+Post-Judge Disposition Gate' `
                -Because 'the extract must stop before the next section; capturing its heading at any level means the scoper over-ran and every assertion below is unscoped again'

            # \s+ throughout, not a literal space: a newline inserted mid-
            # phrase by ordinary markdown reflow does not cross '.' without
            # (?s), and does not match a literal space either -- both were
            # demonstrated to false-red an earlier, literal-space version of
            # these same anchors.
            $amendment | Should -Match '(?i)never\s+halts\s+the\s+loop' `
                -Because 'the advisory, never-halts property is the whole reason this step cannot become a silent blocking gate'
            $amendment | Should -Match '(?i)amend\s+that\s+record\s+in\s+place' `
                -Because 'posting a second record is the failure mode this step exists to prevent'
            $amendment | Should -Match ([regex]::Escape('⚠️ close-out record amendment skipped — {reason}')) `
                -Because 'the loud literal, glyph and all, is what makes a skipped amendment visible rather than silent -- this repository already pins this document''s sibling loud literals the same way, verbatim with glyph, in code-conductor-inline-commands.Tests.ps1'
            $amendment | Should -Match '(?i)closingIssuesReferences' `
                -Because 'the GitHub-intake lane is entirely PR-keyed; without a PR-side issue-resolution route the amendment has no issue to check or amend there'

            # Added in #1039. The three above travelled from step 6; these
            # pin what the move itself is for and what it must not become.
            # Anchored to the ordered list's own items, not to the phrase
            # anywhere in the section. An unanchored version stayed green
            # through gutting the held-id route outright, because the
            # section's prose quotes "active issue id if available" a few
            # lines away -- the adjacent-occurrence class that burned the
            # step-6 assertions, found by mutation before this shape landed.
            #
            # Ordinal 1 is the PR's own closing reference and ordinal 2 the
            # held issue id (reordered in #1041 round 2: the held id winning
            # unconditionally let a run holding a designed parent append a
            # chunk's findings to the parent's record). What must stay true
            # is that the held-id route SURVIVES and is reachable when the
            # PR route yields nothing -- without it a PR-less run takes its
            # visible-skip branch every time, which is the defect being
            # closed wearing the fix's clothes.
            $amendment | Should -Match '(?ms)^1\.\s+\*\*When the review target is a pull request' `
                -Because 'the pull request''s own closingIssuesReferences is authoritative about what it closes; a held issue id outranking it misattributes a chunk''s findings to a parent''s record'
            $amendment | Should -Match '(?ms)^2\.\s+\*\*Otherwise, the active issue id the parent already holds' `
                -Because 'the held-id route is what a PR-less run resolves through; drop it and the step visibly skips on every non-PR target -- present, loud, and discharging nothing'
            $amendment | Should -Match '(?i)fall through to route 2' `
                -Because 'route 1 returning zero must continue to route 2, not terminate; a first route that ends the search re-creates the always-skip path one ordinal up'
            $amendment | Should -Match '(?i)never the judge subagent' `
                -Because 'Code-Review-Response''s scope boundary and #552 D11 place this durable write with the orchestrating parent, so naming the judge as executor is a step nothing is authorised to run'
            $amendment | Should -Match '(?i)does not already account for' `
                -Because 'the record has no dedupe key by design, so a step firing on every judge pass must bound its amendment by what the record already carries'

            # Added in #1041 round 2. This section is declared the SOLE owner
            # of the amend-in-place procedure, and § 9 deliberately removes
            # the persist-marker write path, so a home that names no
            # transport leaves the executor to pick one -- and both obvious
            # picks are documented mis-write traps that edit some other
            # comment on the issue. Each of the three below escaped the
            # round-2 mutation campaign before these assertions existed.
            $amendment | Should -Match '(?i)--method PATCH repos/\{owner\}/\{repo\}/issues/comments/' `
                -Because 'the sole home of the amend-in-place procedure must name the write route by comment id; without it the executor hand-composes transport and the repo''s own trap catalogue shows both natural picks mis-target'
            $amendment | Should -Match '(?i)re-read that comment''s live body immediately before writing' `
                -Because 'the record accumulates appended lines, so a body composed from an earlier read silently drops whatever landed in between'

            # External review, PR #1041 CodeRabbit: route 1 can resolve to
            # several issues ("more than one: evaluate each separately"), and
            # the outcome-reporting rule said "one outcome per judge pass" --
            # undefined for a pass that touched three issues with three
            # different outcomes. Pinned per-issue rather than per-pass.
            $amendment | Should -Match '(?i)one outcome per resolved issue,\s*per judge pass' `
                -Because 'a pass resolving to several issues (route 1''s more-than-one case) must report one outcome per issue, not one blended or arbitrarily-chosen line per pass'
            $amendment | Should -Match '(?i)amended.{0,40}on one and.{0,20}not-applicable.{0,20}on another' `
                -Because 'mixed outcomes across issues in the same pass must be named as the ordinary shape, not left for a reader to reconcile into a single line'
            $amendment | Should -Match '(?i)--edit-last' `
                -Because 'naming the forbidden shortcut is what stops it being rediscovered as the obvious one; a transport section that lists only the right answer does not survive an executor who already knows the wrong one'
        }

        It 'AC6 - the amendment rule has one home, and every judge-running lane names it' {
            # AC1/AC2/AC3 in executable form. Reach is a lane's OWN entry
            # document naming the home -- a file some later hop eventually
            # opens is not a section a lane names, and that distinction is
            # the whole defect #1039 closed.
            # SCOPED PER LANE, not matched against the whole entry document.
            # The whole-document form was reproduced green-while-broken by
            # both defense and judge on PR #1041: deleting this paragraph
            # outright from commands/orchestra-review.md and leaving any
            # unrelated mention of the home elsewhere in the file kept the
            # suite at 32/0/0 with the covered lane carrying no trigger.
            # That is the fourth instance of the class this file's own
            # comments record -- and it landed in the assertion written to
            # close it. Extract the amendment paragraph first; assert inside.
            foreach ($lane in $script:JudgeLanes.GetEnumerator()) {
                $entry = & $script:ReadRepoFile $lane.Value

                # The paragraph runs from its bolded label (command files) or
                # its bullet (agent bodies) to the next blank-line-separated
                # block that starts a new label, bullet, or heading. No `|\z`
                # fallback, deliberately (external review, PR #1041 CodeRabbit):
                # a paragraph not followed by one of those four block openers
                # -- ordinary prose after it, or the paragraph sitting last in
                # the file -- took that arm, and $para then held the rest of
                # the document, which is the exact whole-document match this
                # extraction exists to prevent (the fourth instance of the
                # class this file's own comments already record, found a
                # fifth time in the assertion written to close the fourth).
                # Prefer failing to delimit over over-capturing: an
                # undelimitable paragraph reds through the non-empty guard
                # below rather than silently widening. Same discipline as the
                # $trustModel scoper's rejected end-of-document fallback.
                # The third alternative is also dropped: `\*\*Close-out record
                # amendment` already matches everything
                # `\*\*Close-out record amendment\*\*` matches, and regex
                # alternation is ordered, so it was unreachable.
                $para = [regex]::Match(
                    $entry,
                    '(?ms)^(?:\*\*Close-out record amendment|-\s+`skills/review-judgment/SKILL\.md § Close-Out Record Amendment`).*?(?=\n\n(?:\*\*|#|-\s|\d+\.\s))'
                ).Value

                $para | Should -Not -BeNullOrEmpty `
                    -Because "the $($lane.Key) lane's entry document ($($lane.Value)) must carry a close-out record amendment paragraph of its own; a mention elsewhere in the file is not a trigger this lane's reader reaches"

                $para | Should -Match '(?i)review-judgment/SKILL\.md[`\s]*§[`\s]*Close-Out Record Amendment' `
                    -Because "the $($lane.Key) lane runs a judge and can sustain findings after a record exists; its own paragraph must name the amendment's home or that lane has no documented trigger"

                # The step is advisory, so its report is the only trace it
                # leaves. A lane that names the home but no channel lets a
                # skip vanish into an otherwise complete report -- present,
                # loud, and unaccounted for. Asserted inside the paragraph for
                # the same reason as the line above.
                $para | Should -Match '(?i)(Response Summary item 5|judgment payload|pipeline-metrics|stage 3 report|halt report)' `
                    -Because "the $($lane.Key) lane's own paragraph must name positively where the amendment outcome is reported; producing no summary today is not the same as owing no slot"

                # The Conductor lane takes two mutually exclusive paths and
                # only one of them assembles a Response Summary. Naming just
                # item 5 points the new-PR path at a slot it never produces --
                # which is the "channel that does not exist" finding four
                # prosecution lenses converged on. Both paths must be named.
                if ($lane.Value -eq 'agents/Code-Conductor.agent.md') {
                    $para | Should -Match '(?i)Response Summary item 5' `
                        -Because 'the existing-PR path reports into item 5'
                    $para | Should -Match '(?i)pipeline-metrics' `
                        -Because 'the new-PR path fires no persist-changes and assembles no Response Summary, so item 5 does not exist there; without a second named slot a skipped amendment on that path has nowhere to surface'
                }
            }

            # The pointer must land somewhere. Two of the six lanes route
            # their outcome to Response Summary item 5, so that item existing
            # and still being the amendment's slot is part of those lanes'
            # coverage, not a separate file's business.
            $summary = & $script:ReadRepoFile 'skills/validation-methodology/references/review-reconciliation.md'
            $summary | Should -Match '(?ms)^5\.\s+\*\*Close-out record amendment outcome' `
                -Because 'two lanes name Response Summary item 5 as their accountability channel; if that item is renamed or dropped, those pointers dangle and a skipped amendment has nowhere to surface'

            # The other half of "move, not add". The rule was NOT duplicated
            # into the lane that used to hold it: step 6 now hands off an
            # outcome and states no procedure of its own. Keyed on the two
            # procedure details a restatement would drag back with it.
            $step6 = [regex]::Match(
                $script:ResponseLoop,
                '(?ms)^6\.\s+\*\*Close-out record amendment.*?(?=^\d+\.\s+\*\*|\z)'
            ).Value
            $step6 | Should -Not -BeNullOrEmpty `
                -Because 'the GitHub lane still reports the outcome, so the step survives as a hand-off even though the rule moved'
            $step6 | Should -Match '(?i)review-judgment/SKILL\.md[`\s]*§[`\s]*Close-Out Record Amendment' `
                -Because 'a hand-off that does not name what it hands off from is an orphan'
            $step6 | Should -Not -Match '(?i)closingIssuesReferences' `
                -Because 'two statements of one trigger is option 2 shipped under option 1''s name -- the drift class this move removed'
            $step6 | Should -Not -Match ([regex]::Escape('⚠️ close-out record amendment skipped — {reason}')) `
                -Because 'the loud literal belongs to the rule''s single home; a second copy here is a second thing to keep in sync'
        }

        It 'AC8 - every judge-running path excluded from the lane table carries a stated reason' {
            # AC8's proof standard: "for each path found but excluded, state
            # the reason it is out of population rather than omitting it."
            # A silent omission is the disqualifying shape, so the exclusions
            # are asserted rather than trusted to prose discipline.
            #
            # /spine-run is here rather than in $JudgeLanes because reading
            # agents/Spine-Runner.agent.md falsified the panel's claim that it
            # runs a judge: its `review` port dispatches `skill-only`, which
            # VERIFIES a PR-body row another lane emitted. Two prosecution
            # lenses asserted otherwise and the judge sustained them; the
            # tree did not. Covering it would have put a false claim in the
            # rule's own home, so it is excluded WITH its reason -- which is
            # what AC8 asks for and what this assertion pins.
            $amendment = [regex]::Match(
                $script:ReviewJudgment,
                '(?ms)^## Close-Out Record Amendment[^\n]*\n(?<body>.*?)(?=^##\s|\z)'
            ).Groups['body'].Value

            foreach ($excluded in @('review-prosecute', 'review-defend', 'spine-run', 'design-challenge', 'proxy-github')) {
                $amendment | Should -Match ([regex]::Escape($excluded)) `
                    -Because "$excluded reaches or neighbours a judge stage and is not in the lane table; AC8 requires its exclusion to be stated in the rule's home, not left to silence"
            }

            $amendment | Should -Match '(?i)skill-only' `
                -Because 'the spine-run exclusion rests on its review port being dispatched skill-only (verify a row another lane emitted); without the mechanism named, the exclusion is an assertion a later reader cannot check'
        }

        It 'AC7 - the index routing pointer lands on a surface that states both moments' {
            # Follows the pointer rather than pattern-matching the row. An
            # earlier version of this assertion required the row to mention
            # plan-authoring -- which the PRE-CHANGE row already did, for an
            # unrelated topic in the same cell. It passed against the
            # untouched tree and so proved nothing.
            $rows = @($script:SkillsIndex -split "`n" | Where-Object { $_ -match '(?i)close-out' })
            $rows.Count | Should -BeGreaterOrEqual 1 `
                -Because 'the index routes close-out mechanics somewhere and that pointer is what a reader follows'

            # Only the close-out clause, not the whole cell: the same cell
            # routes other topics, and a skill named for one of those would
            # otherwise satisfy this without the close-out reader landing
            # anywhere useful.
            # Bounded PER ROW, not over the joined text. Joining first and
            # slicing from the first 'close-out' to end-of-string means a
            # second index row mentioning close-out silently widens the
            # clause across every row after it, re-admitting exactly the
            # destinations this narrowing exists to exclude.
            $clause = (@($rows | ForEach-Object {
                        $i = $_.IndexOf('close-out', [System.StringComparison]::OrdinalIgnoreCase)
                        if ($i -ge 0) { $_.Substring($i) }
                    })) -join ' '

            $targets = @{
                'post-pr-review' = 'skills/post-pr-review/SKILL.md'
                'plan-authoring' = 'skills/plan-authoring/SKILL.md'
                'open-for-work'  = 'skills/open-for-work/SKILL.md'
            }

            $named = @($targets.Keys | Where-Object { $clause -match [regex]::Escape($_) })
            $named.Count | Should -BeGreaterOrEqual 1 `
                -Because 'the close-out routing clause must name a destination'

            $landed = @($named | Where-Object {
                    $text = & $script:ReadRepoFile $targets[$_]
                    ($text -match '(?i)before the PR-creation action') -and ($text -match '(?i)before the close')
                })

            $landed.Count | Should -BeGreaterOrEqual 1 `
                -Because "a reader following this pointer must land on a surface stating both moments; it routes to: $($named -join ', ')"

            # The clause must ALSO name the obligation's own home. Without
            # this the assertion is ENTAILED by AC5's post-pr-review checks
            # and pins nothing about the index: reverting this row wholesale
            # to its pre-change text left the whole Context green, because
            # the pre-change clause named post-pr-review and post-pr-review
            # now states both moments. That is the same defect the previous
            # version of this test claimed to have fixed, one level down.
            # Discriminating because the pre-change clause -- the text from
            # 'close-out' onward -- named only post-pr-review.
            $clause | Should -Match '(?i)plan-authoring' `
                -Because 'the pre-change clause routed only to the post-merge checklist; naming the home is what makes this assertion fail at baseline'
        }
    }
}
