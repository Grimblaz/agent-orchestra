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
            $script:SkillText | Should -Match '(?i)affirmed-not-routed'
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
}
