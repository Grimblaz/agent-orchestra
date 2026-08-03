#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Issue #951 / chunk #956 — standing checks for the brief-review emission
    surface, its routing, the adjudication-standard partition, and the corpus
    migration.

.DESCRIPTION
    The brief's universal criteria (U1-U6) are evidenced by the property that
    KEEPS EXECUTING after the run that wrote it, not by a transcript showing
    the quantifier held once. Everything in this file is that property.

    Two disciplines are structural here rather than aspirational:

      1. EVERY ABSENCE CLAIM SHIPS ITS POSITIVE CONTROL. Where a test asserts
         something is not found, a sibling test plants an instance and asserts
         the SAME search finds it. Without the control, "nothing found" and
         "nothing looked" are the same observation.

      2. POPULATIONS, NOT JUST VERDICTS (U5). The partition's failure mode
         produces its own success evidence: if every plan-catchable row landed
         in one sub-arm, the other renders withheld and the pre-existing rates
         read unchanged — exactly what a correct partition also looks like from
         outside. The partition tests therefore assert sub-arm n values.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-rolling-history-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/brief-review-migration-core.ps1')

    $script:Id = 95600

    function script:New-BriefRows {
        param([int]$Count, [string]$Stage = 'brief-review', [string]$Prefix = 'brief-review', [int]$Id = $script:Id)
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 1; $i -le $Count; $i++) {
            [void]$sb.AppendLine("<!-- phase-containment-$Id -->")
            [void]$sb.AppendLine("finding_key: ${Prefix}:${Id}:N$i")
            [void]$sb.AppendLine('introduced_phase: design')
            [void]$sb.AppendLine('catchable_phase: plan')
            [void]$sb.AppendLine("caught_stage: $Stage")
            [void]$sb.AppendLine('escape_distance: 0')
            [void]$sb.AppendLine('severity: medium')
            [void]$sb.AppendLine('systemic_fix_type: instruction')
            [void]$sb.AppendLine('category: pattern')
            [void]$sb.AppendLine("<!-- /phase-containment-$Id -->")
        }
        return $sb.ToString()
    }

    function script:New-BriefHead {
        param(
            [string]$FilterRan = 'true',
            [int]$Filtered = 3,
            [int]$Sustained = 2,
            [int]$Dismissed = 0,
            [switch]$OmitAssertion,
            [switch]$OmitFiltered
        )
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('brief_dispositions:')
        if (-not $OmitAssertion) { $lines.Add("  convergence_filter_ran: $FilterRan") }
        if (-not $OmitFiltered) { $lines.Add("  filtered_count: $Filtered") }
        $lines.Add('  findings:')
        for ($i = 1; $i -le $Sustained; $i++) {
            $lines.Add("    - finding_id: N$i"); $lines.Add('      disposition: incorporate')
        }
        for ($i = 1; $i -le $Dismissed; $i++) {
            $lines.Add("    - finding_id: D$i"); $lines.Add('      disposition: dismiss')
        }
        return ($lines -join "`n")
    }

    function script:New-BriefPlanComment {
        param([switch]$Undeclared, [int]$Id = $script:Id)
        $variant = if ($Undeclared) { 'spine-omitted: plan-too-small' } else { 'plan-variant: brief' }
        return @"
<!-- plan-issue-$Id -->

---
$variant
---

## Plan: fixture

**Plan Stress-Test**: reviewed under the ``design-challenge`` adapter.
"@
    }

    function script:New-BriefLedger {
        param([string]$Head, [string]$Rows = '', [string]$Extra = '', [int]$Id = $script:Id)
        return "<!-- phase-containment-ledger-$Id -->`n`n$Extra`n`n$Head`n`n$Rows"
    }

    # Hoisted to the FILE-level BeforeAll (post-review fix, finding P-A).
    # These lived in the 'Migration guard and render coverage' Describe's own
    # BeforeAll while the #968 AC3 Describe below also consumes them, so any
    # name-filtered run of AC3 died with CommandNotFoundException instead of
    # the assertion result. Whole-file runs hid it because Pester executes
    # Describes in file order. That matters here beyond ergonomics: this
    # chunk's evidence procedure is revert-run-observe on a TARGETED run, and
    # a filtered red is indistinguishable from a mutation's red.
    #
    # NOTE: New-ContaminatedForTail is duplicated as script:New-968Contaminated
    # in migrate-brief-review-corpus.Tests.ps1 -- forced, since Pester files are
    # not dot-sourceable and Tests/ has no shared helper module. Keep in step.
    function script:New-ContaminatedForTail {
        param([int]$Issue, [int]$Rows, [string]$Prefix = 'N', [string]$StageValue = 'plan-stress-test', [string]$Indent = '')
        # LF-joined, not StringBuilder.AppendLine. AppendLine emits CRLF on
        # Windows, and Get-PhaseContainmentBlock does not extract blocks
        # from a CRLF body — so a CRLF fixture makes every block-grain
        # assertion below vacuous. The bodies this migration actually
        # handles arrive LF-normalised.
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("<!-- phase-containment-ledger-$Issue -->")
        $lines.Add('')
        $lines.Add('<!-- judge-rulings')
        for ($i = 1; $i -le $Rows; $i++) {
            $lines.Add("- finding_id: ${Prefix}$i")
            $lines.Add('  judge_ruling: sustained')
        }
        $lines.Add('-->')
        $lines.Add('')
        for ($i = 1; $i -le $Rows; $i++) {
            $lines.Add("<!-- phase-containment-$Issue -->")
            $lines.Add("${Indent}finding_key: plan-stress-test:${Issue}:${Prefix}$i")
            $lines.Add("${Indent}introduced_phase: design")
            $lines.Add("${Indent}catchable_phase: plan")
            $lines.Add("${Indent}caught_stage: $StageValue")
            $lines.Add("${Indent}escape_distance: 0")
            $lines.Add("${Indent}severity: medium")
            $lines.Add("${Indent}systemic_fix_type: instruction")
            $lines.Add("${Indent}category: pattern")
            $lines.Add("<!-- /phase-containment-$Issue -->")
        }
        return ($lines -join "`n") + "`n"
    }
    function script:New-HistPlan { param([int]$Issue) "<!-- plan-issue-$Issue -->`n`n---`nspine-omitted: plan-too-small`n---`n`n**Plan Stress-Test**: three lenses.`n" }

    $script:JudgeHead = @"
<!-- judge-rulings
- finding_id: N1
  judge_ruling: sustained
-->
"@
}

# ---------------------------------------------------------------------------
# U4 — every site that must recognise the new vocabulary does.
# ---------------------------------------------------------------------------

Describe 'U4: caught_stage set drift — all four naming sites agree (issue #951)' {

    BeforeAll {
        $schemaPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/schemas/phase-containment.schema.json'
        $script:Schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        $script:LiveProjections = @($script:StageProjections.Keys)
        $script:LiveValidStages = @($script:ValidCaughtStages)
        $script:LiveSchemaEnum = @($script:Schema.properties.caught_stage.enum)
        $script:LivePattern = $script:FindingKeyPattern
    }

    It 'the LIVE tree has no drift across projections, valid-stages, schema enum, and the finding_key alternation' {
        $r = Get-PhaseContainmentStageSetDriftStatus `
            -Projections $script:LiveProjections `
            -ValidStages $script:LiveValidStages `
            -SchemaEnum $script:LiveSchemaEnum `
            -FindingKeyPattern $script:LivePattern
        $r.DriftDetails -join ' | ' | Should -BeExactly ''
        $r.HasDrift | Should -BeFalse
    }

    It 'brief-review is actually present in all four (the guard above passes vacuously on a set that never gained it)' {
        $script:LiveProjections | Should -Contain 'brief-review'
        $script:LiveValidStages | Should -Contain 'brief-review'
        $script:LiveSchemaEnum  | Should -Contain 'brief-review'
        $script:LivePattern     | Should -Match 'brief-review'
    }

    # --- one induced omission per CLASS of site -----------------------------

    It 'INDUCED (enum-member class): omitting brief-review from ValidCaughtStages is caught' {
        $r = Get-PhaseContainmentStageSetDriftStatus `
            -Projections $script:LiveProjections `
            -ValidStages @($script:LiveValidStages | Where-Object { $_ -ne 'brief-review' }) `
            -SchemaEnum $script:LiveSchemaEnum `
            -FindingKeyPattern $script:LivePattern
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'ValidCaughtStages'
    }

    It 'INDUCED (projection class): omitting brief-review from StageProjections is caught' {
        $r = Get-PhaseContainmentStageSetDriftStatus `
            -Projections @($script:LiveProjections | Where-Object { $_ -ne 'brief-review' }) `
            -ValidStages $script:LiveValidStages `
            -SchemaEnum $script:LiveSchemaEnum `
            -FindingKeyPattern $script:LivePattern
        $r.HasDrift | Should -BeTrue
    }

    It 'INDUCED (schema-enum class): omitting brief-review from the schema enum is caught' {
        $r = Get-PhaseContainmentStageSetDriftStatus `
            -Projections $script:LiveProjections `
            -ValidStages $script:LiveValidStages `
            -SchemaEnum @($script:LiveSchemaEnum | Where-Object { $_ -ne 'brief-review' }) `
            -FindingKeyPattern $script:LivePattern
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'schema caught_stage enum'
    }

    It 'INDUCED (pattern-alternation class): the exact three-of-four omission both pre-#951 guards missed is caught' {
        # This is the case the old guards could not see: the stage is present
        # in projections, valid-stages AND the schema enum, and the two copies
        # of the alternation still match each other byte-for-byte — they are
        # simply both missing the stage.
        $r = Get-PhaseContainmentStageSetDriftStatus `
            -Projections $script:LiveProjections `
            -ValidStages $script:LiveValidStages `
            -SchemaEnum $script:LiveSchemaEnum `
            -FindingKeyPattern '^(code-review|design-challenge|plan-stress-test|post-review-observer):.+'
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'finding_key alternation'
    }

    It 'INDUCED (entry-point-surface-list class): neither entry-point call site hard-codes the issue surface list' {
        # The failure this class names is "a new surface exists in the library
        # and no entry point asks for it" — invisible to every behavioural
        # test, because the library is correct. It is a source-level property,
        # so it is checked at source level.
        $entry = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/scripts/phase-containment-emission-check.ps1')
        $hardCoded = [regex]::Matches($entry, [regex]::Escape("@('design-challenge', 'plan-stress-test')"))
        $hardCoded.Count | Should -Be 0 -Because 'both issue surface lists must route through Get-IssueEmissionSurfaces'
        # Count real CALL SITES, not mentions — a prose reference in a comment
        # is not a call, and counting mentions would let a commented-out call
        # site satisfy the guard.
        $callSites = [regex]::Matches($entry, '@\(Get-IssueEmissionSurfaces\s+-Bodies')
        $callSites.Count | Should -Be 2 -Because 'single-target mode and corpus mode are the two call sites'
    }

    It 'POSITIVE CONTROL for the source scan: the same search does find a planted hard-coded list' {
        $planted = "x = @('design-challenge', 'plan-stress-test')"
        ([regex]::Matches($planted, [regex]::Escape("@('design-challenge', 'plan-stress-test')"))).Count | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# U1 — no brief-review record carries judge-adjudication vocabulary.
# ---------------------------------------------------------------------------

Describe 'U1: brief-review records carry no judge-adjudication vocabulary (issue #951)' {

    BeforeAll {
        # The token set is fixed HERE, in the check — not chosen when a piece
        # of evidence is written.
        $script:JudgeTokens = @('judge_ruling', 'judge-rulings')

        function script:Test-HasJudgeVocabulary {
            param([string]$Text)
            foreach ($t in $script:JudgeTokens) {
                if ($Text -match [regex]::Escape($t)) { return $true }
            }
            return $false
        }

        # Enumerate every committed brief-review record in the tree. A record
        # is any file carrying a `brief_dispositions:` head.
        # -Include requires a wildcard path when combined with -Recurse; the
        # bare-directory form silently returns nothing, which would make this
        # enumeration vacuously clean. The non-emptiness assertion below is
        # what catches that, and it did.
        $script:BriefRecordFiles = @(
            Get-ChildItem -Path (Join-Path $script:RepoRoot '*') -Recurse -File -Include '*.md', '*.txt', '*.ps1' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.FullName -notmatch '[\\/]\.tmp[\\/]' } |
                Where-Object {
                    $c = Get-Content -Raw -LiteralPath $_.FullName -ErrorAction SilentlyContinue
                    $c -and ($c -match '(?m)^\s*brief_dispositions[ \t]*:')
                }
        )
    }

    It 'the emitted brief-review authorizing record contains no judge token' {
        $ledger = script:New-BriefLedger -Head (script:New-BriefHead) -Rows (script:New-BriefRows -Count 2)
        script:Test-HasJudgeVocabulary -Text $ledger | Should -BeFalse
    }

    It 'POSITIVE CONTROL: the same search fires on a planted judge token' {
        $planted = (script:New-BriefLedger -Head (script:New-BriefHead) -Rows (script:New-BriefRows -Count 2)) + "`n" + $script:JudgeHead
        script:Test-HasJudgeVocabulary -Text $planted | Should -BeTrue
    }

    It 'the writer refuses to persist a brief head carrying judge vocabulary' {
        # The reader-side D6 check must never be the first thing to notice.
        $core = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-phase-ledger-core.ps1')
        $core | Should -Match 'BriefHeadContent carries judge vocabulary'
    }

    Context 'M2: the writer is exercised, not just grepped' {

        # The post-fix review (M9) found Set-PPLBriefHeadBlockOnComment was
        # never INVOKED by any test — every reference in the tree was a
        # source-text assertion, so the whole refusal block was deletable in
        # silence. These cases call the real function. The network read is
        # stubbed to $null, so reaching "Could not read comment" proves every
        # validation passed and the function was about to write; any other
        # Reason is a refusal that fired.
        BeforeAll {
            . (Join-Path $script:RepoRoot '.github/scripts/lib/find-or-upsert-comment.ps1')
            . (Join-Path $script:RepoRoot '.github/scripts/lib/marker-transport-core.ps1')
            . (Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-phase-ledger-core.ps1')
            function script:Get-PPLCommentBodyById { param($Owner, $Repo, $CommentId) return $null }

            $script:CanonHead = @(
                'brief_dispositions:'
                '  convergence_filter_ran: true'
                '  filtered_count: 8'
                '  findings:'
                '    - finding_id: N1'
                '      disposition: incorporate'
            ) -join "`n"

            function script:InvokeWriter {
                param([string]$Head)
                $r = Set-PPLBriefHeadBlockOnComment -Owner o -Repo r -CommentId 1 -ExpectedMarker 'M' -BriefHeadContent $Head
                # Normalise to 'accepted' / the refusal reason.
                if ($r.Reason -like 'Could not read comment*') { return 'accepted' }
                return [string]$r.Reason
            }
        }

        It 'accepts a canonical head (LF and CRLF) — the guards are not simply refusing everything' {
            # Without this, every refusal assertion below would pass just as
            # well against a function that rejected its own valid input.
            script:InvokeWriter -Head $script:CanonHead | Should -BeExactly 'accepted'
            script:InvokeWriter -Head ($script:CanonHead -replace "`n", "`r`n") | Should -BeExactly 'accepted'
        }

        It 'REFUSES two concatenated heads — <label>' -TestCases @(
            @{ label = 'LF' ; nl = "`n" }
            @{ label = 'CRLF'; nl = "`r`n" }
        ) {
            param($label, $nl)
            # The finding M2 case. Every other guard is structurally blind to
            # it: the preamble scan truncates at the FIRST head's findings:
            # key, so both uniqueness counts still read 1, and the column-0
            # check's global replace collapses to the last head's body, which
            # is properly indented. Only the head-key occurrence count sees it.
            # Measured before the fix: accepted, written, then read back
            # ParseStatus=could-not-verify Reason=duplicate-head.
            $twoHeads = (($script:CanonHead + "`n" + $script:CanonHead) -replace "`n", $nl)
            script:InvokeWriter -Head $twoHeads | Should -Match 'line-start .?brief_dispositions:.? heads'
        }

        It 'still refuses everything it refused before the two-head guard was added' {
            # The two-head guard is ADDITIVE. If it had been implemented by
            # narrowing the span-replace instead, the flat-head case below
            # would have regressed — that is why the judge made "do not tighten
            # the global replace" a binding constraint on this fix.
            $flat = @(
                'brief_dispositions:'
                'convergence_filter_ran: true'
                'filtered_count: 8'
                'findings:'
                '- finding_id: N1'
                '  disposition: incorporate'
            ) -join "`n"
            script:InvokeWriter -Head $flat | Should -Match 'column-0 \(un-indented\) line'

            script:InvokeWriter -Head ($script:CanonHead -replace '  filtered_count: 8', "  convergence_filter_ran: true`n  filtered_count: 8") |
                Should -Match 'more than one .?convergence_filter_ran'
            script:InvokeWriter -Head ($script:CanonHead -replace '  findings:', "  filtered_count: 9`n  findings:") |
                Should -Match 'more than one .?filtered_count'
            script:InvokeWriter -Head ($script:CanonHead -replace '      disposition: incorporate', '      judge_ruling: sustained') |
                Should -Match 'carries judge vocabulary'
            script:InvokeWriter -Head ($script:CanonHead -replace 'convergence_filter_ran: true', 'convergence_filter_ran: false') |
                Should -Match 'declares .?convergence_filter_ran: false'
            script:InvokeWriter -Head 'nothing_here: true' |
                Should -Match 'no line-start .?brief_dispositions:.? head'
        }

        It 'refuses finding fields in the head''s own preamble, including the hyphen-without-space form' {
            # The `-?` alternative in the preamble scan is narrow but NOT dead:
            # the list-item truncation requires whitespace after the hyphen, so
            # `-finding_id: X` survives truncation and is caught only here.
            script:InvokeWriter -Head ($script:CanonHead -replace '  findings:', "  finding_id: X`n  findings:") |
                Should -Match 'in the head''s own preamble'
            script:InvokeWriter -Head ($script:CanonHead -replace '  findings:', "  -finding_id: X`n  findings:") |
                Should -Match 'in the head''s own preamble'
        }
    }

    It 'every committed brief-review record in the tree is judge-free, and the enumeration is non-empty' {
        # Non-emptiness asserted SEPARATELY, so "no offending record" and
        # "no record at all" can never be the same green.
        $script:BriefRecordFiles.Count | Should -BeGreaterThan 0
        $offenders = @()
        foreach ($f in $script:BriefRecordFiles) {
            $raw = Get-Content -Raw -LiteralPath $f.FullName
            # Isolate the brief head region only: a source file may legitimately
            # discuss the judge vocabulary elsewhere (this very suite does).
            $m = [regex]::Match($raw, '(?ms)^\s*brief_dispositions[ \t]*:.*?(?=^\S|\z)')
            if ($m.Success -and (script:Test-HasJudgeVocabulary -Text $m.Value)) { $offenders += $f.FullName }
        }
        $offenders -join ', ' | Should -BeExactly ''
    }
}

# ---------------------------------------------------------------------------
# U2 — the convergence-filter assertion, over its full value domain.
# ---------------------------------------------------------------------------

Describe 'U2: no run whose convergence filter did not execute can reach clean (issue #951 D3 / A1(d))' {

    It 'convergence_filter_ran: true reaches clean' {
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), (script:New-BriefLedger -Head (script:New-BriefHead -FilterRan 'true') -Rows (script:New-BriefRows -Count 2))) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'ok'
        $g.Reason | Should -BeExactly 'ok'
        $g.Gap | Should -Be 0
    }

    It 'convergence_filter_ran: false renders could-not-verify — the case A1(d) exists for' {
        # Present, parseable, honestly written. An implementation keyed on
        # key-ABSENCE satisfies D3's original text and lets this reach clean,
        # rewarding the run that omits the field over the one that declares.
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), (script:New-BriefLedger -Head (script:New-BriefHead -FilterRan 'false') -Rows (script:New-BriefRows -Count 2))) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'could-not-verify'
        $g.Reason | Should -BeExactly 'filter-not-run'
    }

    It 'an absent assertion renders could-not-verify' {
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), (script:New-BriefLedger -Head (script:New-BriefHead -OmitAssertion) -Rows (script:New-BriefRows -Count 2))) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'could-not-verify'
        $g.Reason | Should -BeExactly 'filter-unasserted'
    }

    It 'filter ran but filtered_count omitted renders could-not-verify (the count is consumed, not decorative)' {
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), (script:New-BriefLedger -Head (script:New-BriefHead -OmitFiltered) -Rows (script:New-BriefRows -Count 2))) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'could-not-verify'
    }

    It 'two contradictory assertions fail loud rather than picking one' {
        $head = "brief_dispositions:`n  convergence_filter_ran: true`n  convergence_filter_ran: false`n  filtered_count: 1`n  findings:`n    - finding_id: N1`n      disposition: incorporate"
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), (script:New-BriefLedger -Head $head)) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'could-not-verify'
    }
}

# ---------------------------------------------------------------------------
# W2 / D6 — the self-certification contradiction.
# ---------------------------------------------------------------------------

Describe 'W2: the self-certification contradiction renders and names itself (issue #951 D6)' {

    It 'a brief-declared issue whose ledger sibling carries a judge head cannot reach clean' {
        $ledger = script:New-BriefLedger -Head (script:New-BriefHead) -Rows (script:New-BriefRows -Count 2) -Extra $script:JudgeHead
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'could-not-verify'
        $g.Reason | Should -BeExactly 'judge-head-contradiction'
    }

    It 'CONTROL: the same input with the judge head removed renders clean — so the verdict is attributable to the contradiction' {
        $ledger = script:New-BriefLedger -Head (script:New-BriefHead) -Rows (script:New-BriefRows -Count 2)
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'ok'
    }

    It 'FALSE-POSITIVE BOUND: a judge head elsewhere on the issue, off the ledger sibling, does not trip it' {
        $ledger = script:New-BriefLedger -Head (script:New-BriefHead) -Rows (script:New-BriefRows -Count 2)
        $unrelated = "Some other comment on the issue, e.g. a cross-posted PR review.`n`n$script:JudgeHead"
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger, $unrelated) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'ok'
    }

    It 'A1(b): the check would NOT have caught the historical shape — judge head, no brief head, no declaration' {
        # Recorded as a test rather than only as prose, because D6's original
        # justification claimed the opposite and that claim was reported to the
        # maintainer as verified fact.
        #
        # The fixture is the HISTORICAL shape specifically (#963 review,
        # finding E): a sibling carrying a judge head and NO brief head, under
        # an undeclared plan comment. Neither routing arm fires, so the issue
        # is not a brief at all and the contradiction cannot arise. An earlier
        # version of this test used a sibling carrying BOTH heads, which is not
        # a shape the corpus ever had — and it passed only because the check
        # was then keyed on the declaration alone, which was itself the defect.
        $ledger = "<!-- phase-containment-ledger-$script:Id -->`n`n$script:JudgeHead"
        Test-BriefJudgeHeadContradiction -Bodies @((script:New-BriefPlanComment -Undeclared), $ledger) -Id $script:Id | Should -BeFalse
    }

    It 'the head arm IS guarded now: an undeclared issue whose sibling carries both heads is a contradiction' {
        # The complement of the test above, and the reason it is not a
        # regression. Before #963 the head arm could route an issue to the
        # brief surface with no contradiction guard whatsoever, so a judge head
        # sitting on the same sibling certified silently.
        $ledger = script:New-BriefLedger -Head (script:New-BriefHead) -Rows (script:New-BriefRows -Count 2) -Extra $script:JudgeHead
        Test-BriefJudgeHeadContradiction -Bodies @((script:New-BriefPlanComment -Undeclared), $ledger) -Id $script:Id | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# W3 / AC4 — recorded-nothing reads as unverified.
# ---------------------------------------------------------------------------

Describe 'W3: recorded-nothing reads as unverified, not verified-and-empty (issue #951 AC4)' {

    It 'a declared brief that emitted nothing renders could-not-verify' {
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment)) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'could-not-verify'
        $g.Reason | Should -BeExactly 'head-missing'
    }

    It 'CONTRAST: a genuinely verified-and-empty brief renders differently' {
        $ledger = script:New-BriefLedger -Head (script:New-BriefHead -Sustained 0 -Dismissed 1 -Filtered 0)
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'ok'
        $g.SustainedCount | Should -Be 0
    }

    It 'the two states are rendered with different text, not merely different flags' {
        $recordedNothing = Get-EmissionGap -Bodies @((script:New-BriefPlanComment)) -Id $script:Id -Surface 'brief-review'
        $verifiedEmpty = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), (script:New-BriefLedger -Head (script:New-BriefHead -Sustained 0 -Dismissed 1 -Filtered 0))) -Id $script:Id -Surface 'brief-review'
        $recordedNothing.Reason | Should -Not -BeExactly $verifiedEmpty.Reason
    }

    It 'an issue that neither declares nor carries a brief head gets no manufactured gap' {
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment -Undeclared)) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'ok'
    }
}

# ---------------------------------------------------------------------------
# U3 — only the brief's own surface reports on its artifacts.
# ---------------------------------------------------------------------------

Describe 'U3: on a brief-routed issue, only the brief surface reports (issue #951 D2 / AC5)' {

    BeforeAll {
        $script:BriefBodies = @(
            (script:New-BriefPlanComment),
            (script:New-BriefLedger -Head (script:New-BriefHead) -Rows (script:New-BriefRows -Count 2))
        )
    }

    It 'the routed surface set is exactly design-challenge + brief-review' {
        $surfaces = @(Get-IssueEmissionSurfaces -Bodies $script:BriefBodies -Id $script:Id)
        ($surfaces -join ',') | Should -BeExactly 'design-challenge,brief-review'
    }

    It 'the brief surface is present AND clean — the positive clause, not just the absence of others' {
        $g = Get-EmissionGap -Bodies $script:BriefBodies -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'ok'
        $g.SustainedCount | Should -Be 2
        $g.BlockCount | Should -Be 2
        $g.Gap | Should -Be 0
    }

    It 'every OTHER surface in the routed set reports nothing attributable to the brief' {
        $surfaces = @(Get-IssueEmissionSurfaces -Bodies $script:BriefBodies -Id $script:Id)
        foreach ($s in ($surfaces | Where-Object { $_ -ne 'brief-review' })) {
            $g = Get-EmissionGap -Bodies $script:BriefBodies -Id $script:Id -Surface $s
            $g.ParseStatus | Should -BeExactly 'ok' -Because "surface $s must not report a could-not-verify for the brief's artifacts"
            $g.Gap | Should -Be 0 -Because "surface $s must not report a gap for the brief's artifacts"
        }
    }

    It 'plan-stress-test is suppressed, and WOULD have produced a false gap had it not been' {
        $surfaces = @(Get-IssueEmissionSurfaces -Bodies $script:BriefBodies -Id $script:Id)
        $surfaces | Should -Not -Contain 'plan-stress-test'
        # The counterfactual, run explicitly: this is what an unrouted brief
        # renders, and why the suppression is load-bearing rather than tidy.
        $unsuppressed = Get-EmissionGap -Bodies $script:BriefBodies -Id $script:Id -Surface 'plan-stress-test'
        $unsuppressed.ParseStatus | Should -BeExactly 'could-not-verify'
    }

    It 'a non-brief issue keeps the pre-#951 surface set unchanged' {
        $plain = @((script:New-BriefPlanComment -Undeclared))
        ((Get-IssueEmissionSurfaces -Bodies $plain -Id $script:Id) -join ',') | Should -BeExactly 'design-challenge,plan-stress-test'
    }

    It 'the two head tokens cannot cross-fire in either direction' {
        $briefLedger = script:New-BriefLedger -Head (script:New-BriefHead)
        $designRecord = "finding_dispositions:`n- finding_id: D1`n  disposition: incorporate`n"
        Test-EmissionMarkerPresent -Surface 'design-challenge' -Body $briefLedger | Should -BeFalse
        Test-EmissionMarkerPresent -Surface 'brief-review' -Body $designRecord | Should -BeFalse
        # POSITIVE CONTROLS: each detector does fire on its own token.
        Test-EmissionMarkerPresent -Surface 'design-challenge' -Body $designRecord | Should -BeTrue
        Test-EmissionMarkerPresent -Surface 'brief-review' -Body $briefLedger | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# U5 — the rollup partition. Populations, not verdicts.
# ---------------------------------------------------------------------------

Describe 'U5: the rollup partitions the plan arm by adjudication standard (issue #951 D4)' {

    BeforeAll {
        function script:New-Entry {
            param([string]$Stage, [int]$Distance = 0, [string]$Severity = 'low')
            return @{
                finding_key = "${Stage}:x"; introduced_phase = 'plan'; catchable_phase = 'plan'
                caught_stage = $Stage; escape_distance = $Distance; severity = $Severity
                systemic_fix_type = 'instruction'; category = 'pattern'; apparatus_meta = $false
            }
        }
        # A mixed corpus: 6 judge-adjudicated, 7 brief-review. Both above the
        # n>=5 floor, so both sub-arms must produce real rates.
        $script:MixedEntries = @(
            (1..6 | ForEach-Object { script:New-Entry -Stage 'plan-stress-test' -Distance $(if ($_ -le 2) { 1 } else { 0 }) }) +
            (1..7 | ForEach-Object { script:New-Entry -Stage 'brief-review' -Distance 0 })
        )
        $script:MixedRollup = Get-PhaseContainmentRollup -Entries $script:MixedEntries
        $script:PlanArm = $script:MixedRollup.Stages['plan-stress-test']
    }

    It 'the plan arm carries a partition with BOTH standards named' {
        @($script:PlanArm.AdjudicationPartition.Keys | Sort-Object) -join ',' | Should -BeExactly 'brief-review,plan-stress-test'
    }

    It 'each sub-arm population is non-empty and CORRECTLY ASSIGNED (falsifier 7 — verdicts alone cannot show this)' {
        # If both stage keys had been added to $stageToCatchablePhase, every
        # plan-catchable row would land in whichever the hashtable enumerated
        # first, and one of these two counts would be 13 while the other was 0.
        $script:PlanArm.AdjudicationPartition['plan-stress-test'].N | Should -Be 6
        $script:PlanArm.AdjudicationPartition['brief-review'].N | Should -Be 7
        # The partition covers ALL standards, so it sums to NAllStandards —
        # not to N, which is the single-standard headline population.
        ($script:PlanArm.AdjudicationPartition['plan-stress-test'].N + $script:PlanArm.AdjudicationPartition['brief-review'].N) | Should -Be $script:PlanArm.NAllStandards
        $script:PlanArm.NAllStandards | Should -Be 13
        $script:PlanArm.N | Should -Be 6
    }

    It 'THE HEADLINE RATE IS COMPUTED OVER ONE STANDARD — brief rows cannot dilute it' {
        # This is U5's actual claim, and an earlier version of this suite
        # asserted its opposite: it pinned the pooled 2/13 as expected, three
        # lines below a comment calling 2/13 "a number belonging to neither
        # standard." The #963 review found the partition was render-only while
        # EscapeRate and RelaxationEligible still pooled.
        #
        # 2 of 6 escapes judge-side, 0 of 7 brief-side. The headline must be
        # the judge-adjudicated 2/6, never the pooled 2/13 — brief rows are
        # structurally escape_distance 0, so pooling can only ever push the
        # rate toward eligibility.
        [Math]::Round($script:PlanArm.EscapeRate, 4) | Should -Be ([Math]::Round(2 / 6, 4))
        [Math]::Round($script:PlanArm.AdjudicationPartition['plan-stress-test'].EscapeRate, 4) | Should -Be ([Math]::Round(2 / 6, 4))
        $script:PlanArm.AdjudicationPartition['brief-review'].EscapeRate | Should -Be 0
    }

    It 'DILUTION PROBE: adding brief rows to an ineligible arm cannot make it eligible' {
        # The concrete exploit the review demonstrated, pinned as a standing
        # property. Judge evidence alone says NOT eligible; piling on
        # irreducible brief rows used to flip it.
        $judgeOnly = @(1..5 | ForEach-Object { script:New-Entry -Stage 'plan-stress-test' -Distance $(if ($_ -eq 1) { 1 } else { 0 }) })
        $armBefore = (Get-PhaseContainmentRollup -Entries $judgeOnly).Stages['plan-stress-test']
        $armBefore.RelaxationEligible | Should -BeFalse

        $diluted = @($judgeOnly + (1..45 | ForEach-Object { script:New-Entry -Stage 'brief-review' -Distance 0 }))
        $armAfter = (Get-PhaseContainmentRollup -Entries $diluted).Stages['plan-stress-test']
        $armAfter.RelaxationEligible | Should -BeFalse -Because 'brief-review rows are a different adjudication standard and must not reach the relaxation number'
        $armAfter.EscapeRate | Should -Be $armBefore.EscapeRate -Because 'the headline rate must be identical with and without the brief population'
    }

    It 'THE SEVERITY VETO SPANS EVERY STANDARD — a sustained critical brief finding blocks relaxation' {
        # Post-fix review, finding M5. The item-26 fix (tallying the veto over
        # $allNonApparatusEntries rather than the brief-excluded
        # $nonApparatusEntries) shipped with NO test, and the mutation proved
        # it: reverting that one loop variable left the whole suite green
        # while the rendered verdict flipped from NOT ELIGIBLE to ELIGIBLE.
        #
        # The distinction the veto turns on: a RATE offered as relaxation
        # evidence must be computed over ONE adjudication standard (that is
        # the dilution probe directly above). A VETO is a safety gate, not a
        # rate — excluding rows from it can only ever LOOSEN it. So the
        # headline rate stays judge-only while the veto spans everything.
        $judgeOnly = @(1..5 | ForEach-Object { script:New-Entry -Stage 'plan-stress-test' -Distance 0 -Severity 'medium' })
        $armClean = (Get-PhaseContainmentRollup -Entries $judgeOnly).Stages['plan-stress-test']
        $armClean.RelaxationEligible | Should -BeTrue -Because 'five medium judge rows with zero escapes is the eligible baseline this test perturbs'

        # One critical finding, caught at brief-review — a standard the
        # headline rate deliberately excludes. It must still veto.
        $withCritical = @($judgeOnly + @(script:New-Entry -Stage 'brief-review' -Distance 0 -Severity 'critical'))
        $armVetoed = (Get-PhaseContainmentRollup -Entries $withCritical).Stages['plan-stress-test']
        $armVetoed.RelaxationEligible | Should -BeFalse -Because 'an unaddressed critical finding in the window blocks relaxation regardless of which adjudication standard caught it'
        $armVetoed.CriticalFindingCount | Should -Be 1

        # The rate itself must be untouched — this is the veto firing, not the
        # brief row leaking into the headline population.
        $armVetoed.EscapeRate | Should -Be $armClean.EscapeRate -Because 'the veto spans standards but the RATE still must not'
        $armVetoed.N | Should -Be $armClean.N

        # Same for high severity, so the fix is not pinned on one enum value.
        # Issue #969: this leg previously captured Stages['brief-review'] into
        # $armHigh and then never read it, while re-running the rollup twice to
        # assert through — so the high side asserted the verdict and the count
        # but NOT the rate-and-population invariance its critical sibling
        # asserts six lines up. Asymmetric coverage of a two-value property is
        # coverage of one value.
        $withHigh = @($judgeOnly + @(script:New-Entry -Stage 'brief-review' -Distance 0 -Severity 'high'))
        $armHigh = (Get-PhaseContainmentRollup -Entries $withHigh).Stages['plan-stress-test']
        $armHigh.RelaxationEligible | Should -BeFalse
        $armHigh.HighFindingCount | Should -Be 1
        $armHigh.CriticalFindingCount | Should -Be 0
        $armHigh.EscapeRate | Should -Be $armClean.EscapeRate -Because 'the veto spans standards but the RATE still must not'
        $armHigh.N | Should -Be $armClean.N
    }

    It 'THE VETO SPANS EVERY STANDARD IN THE RENDER TOO — not only in the rollup object (issue #969)' {
        # C5. The documented near-miss for this exact property was a
        # RENDER-LAYER flip: reverting one loop variable left the whole suite
        # green while the rendered verdict went from NOT ELIGIBLE to ELIGIBLE.
        # The test written in response asserted rollup-object properties and
        # never called Format-PhaseContainmentReport, and every rendered pin on
        # the veto line was built on a single-standard fixture — so until now
        # no test rendered a MIXED-standard corpus and asserted these counts,
        # which is the shape the failure actually took.
        $judgeOnly = @(1..5 | ForEach-Object { script:New-Entry -Stage 'plan-stress-test' -Distance 0 -Severity 'medium' })
        $withCritical = @($judgeOnly + @(script:New-Entry -Stage 'brief-review' -Distance 0 -Severity 'critical'))

        $render = {
            param($Entries)
            (Format-PhaseContainmentReport -Context @{
                    Rollup            = (Get-PhaseContainmentRollup -Entries $Entries -WindowLabel '90d')
                    Source            = 'rest'
                    Truncated         = $false
                    WindowDays        = 90
                    FetchedAt         = ([datetime]'2026-08-01T00:00:00Z')
                    InvalidEntryCount = 0
                }) -join "`n"
        }

        $cleanText = & $render $judgeOnly
        $vetoText  = & $render $withCritical

        # The baseline this perturbs really does render eligible, so the
        # assertion below is a flip and not a constant.
        $cleanText | Should -Match 'Relaxation signal:  ELIGIBLE \(escape_rate ~0, no critical/high findings\)'

        $vetoText | Should -Match 'Relaxation signal:  NOT ELIGIBLE \(1 critical, 0 high severity finding\(s\) in window\)'
        $vetoText.Contains('ELIGIBLE (escape_rate ~0, no critical/high findings)') | Should -BeFalse -Because "a critical finding under ANY standard must block the RENDERED verdict. Actual report:`n$vetoText"
        # And the headline population is still the judge-adjudicated one, so
        # this is the veto firing rather than the brief row leaking into it.
        $vetoText | Should -Match 'Denominator \(catchable=plan\): 5'
    }

    It 'the exclusion is disclosed in the render, not silent' {
        $rendered = Format-PhaseContainmentReport -Context @{
            Rollup = $script:MixedRollup; Source = 'rest'; Truncated = $false
            WindowDays = 90; FetchedAt = ([datetime]'2026-08-01T00:00:00Z'); InvalidEntryCount = 0
        }
        ($rendered -join "`n") | Should -Match 'judge-adjudicated standard only: 7 of 13 row\(s\) excluded'
    }

    It 'the insufficiency guard is RE-DERIVED per sub-arm, not inherited from the parent population' {
        # 8 judge-side + 3 brief-side. The parent arm (n=11) comfortably clears
        # the floor; the 3-row sub-arm must NOT inherit that authority.
        $entries = @(
            (1..8 | ForEach-Object { script:New-Entry -Stage 'plan-stress-test' }) +
            (1..3 | ForEach-Object { script:New-Entry -Stage 'brief-review' })
        )
        $arm = (Get-PhaseContainmentRollup -Entries $entries).Stages['plan-stress-test']
        $arm.InsufficientData | Should -BeFalse -Because 'the parent arm has 11 rows'
        $arm.AdjudicationPartition['brief-review'].Withheld | Should -BeTrue
        $arm.AdjudicationPartition['brief-review'].N | Should -Be 3
        $arm.AdjudicationPartition['plan-stress-test'].Withheld | Should -BeFalse
    }

    It 'a withheld sub-arm renders WITHHELD, never a legitimate zero' {
        $entries = @(
            (1..8 | ForEach-Object { script:New-Entry -Stage 'plan-stress-test' }) +
            (1..3 | ForEach-Object { script:New-Entry -Stage 'brief-review' })
        )
        $arm = (Get-PhaseContainmentRollup -Entries $entries).Stages['plan-stress-test']
        $arm.AdjudicationPartition['brief-review'].EscapeRate | Should -BeNullOrEmpty
    }

    It 'brief-review is NOT a key in the stage->catchable_phase map (falsifier 7, at source level)' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-rolling-history-core.ps1')
        $mapMatch = [regex]::Match($src, "(?ms)\`$stageToCatchablePhase = @\{.*?\}")
        $mapMatch.Success | Should -BeTrue
        $mapMatch.Value | Should -Not -Match 'brief-review'
    }

    It 'the report renders the partition with its populations visible' {
        $rendered = Format-PhaseContainmentReport -Context @{
            Rollup            = $script:MixedRollup
            Source            = 'rest'
            Truncated         = $false
            WindowDays        = 90
            FetchedAt         = ([datetime]'2026-08-01T00:00:00Z')
            InvalidEntryCount = 0
        }
        $text = $rendered -join "`n"
        $text | Should -Match 'By adjudication standard'
        $text | Should -Match 'brief-review: n=7'
        $text | Should -Match 'plan-stress-test: n=6'
    }
}

# ---------------------------------------------------------------------------
# M21 — the required reconciliation exclusion.
# ---------------------------------------------------------------------------

Describe 'M21: brief-review entries are excluded from the sustained-count reconciliation (issue #951)' {

    It 'a caller supplying judge-derived expectations is not spuriously failed closed by brief rows' {
        $entries = @(
            (1..6 | ForEach-Object { @{ finding_key = 'plan-stress-test:x'; introduced_phase = 'plan'; catchable_phase = 'plan'; caught_stage = 'plan-stress-test'; escape_distance = 0; severity = 'low'; systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false } }) +
            (1..4 | ForEach-Object { @{ finding_key = 'brief-review:x'; introduced_phase = 'plan'; catchable_phase = 'plan'; caught_stage = 'brief-review'; escape_distance = 0; severity = 'low'; systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false } })
        )
        $arm = (Get-PhaseContainmentRollup -Entries $entries -SustainedCounts @{ 'plan-stress-test' = 6 }).Stages['plan-stress-test']
        $arm.DataUntrustworthy | Should -BeFalse
        $arm.BriefCaughtCount | Should -Be 4
    }

    It 'a genuine mismatch still fails closed, and the message discloses the exclusion' {
        $entries = @(
            (1..5 | ForEach-Object { @{ finding_key = 'plan-stress-test:x'; introduced_phase = 'plan'; catchable_phase = 'plan'; caught_stage = 'plan-stress-test'; escape_distance = 0; severity = 'low'; systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false } }) +
            (1..4 | ForEach-Object { @{ finding_key = 'brief-review:x'; introduced_phase = 'plan'; catchable_phase = 'plan'; caught_stage = 'brief-review'; escape_distance = 0; severity = 'low'; systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false } })
        )
        $arm = (Get-PhaseContainmentRollup -Entries $entries -SustainedCounts @{ 'plan-stress-test' = 6 }).Stages['plan-stress-test']
        $arm.DataUntrustworthy | Should -BeTrue
        $arm.DataUntrustworthyReason | Should -Match 'brief-review-caught'
    }
}

# ---------------------------------------------------------------------------
# U6 — the cost report's two consumers.
# ---------------------------------------------------------------------------

Describe 'U6: the cost report is correct for a brief-declared issue (issue #951)' {

    BeforeAll {
        . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-cost-core.ps1')
        $script:BriefTuple = [PSCustomObject]@{
            Number          = $script:Id
            Surface         = 'issue'
            Bodies          = @(
                (script:New-BriefPlanComment),
                (script:New-BriefLedger -Head (script:New-BriefHead -Sustained 6 -Dismissed 2 -Filtered 4) -Rows (script:New-BriefRows -Count 6))
            )
            CreatedAtValues = @('2026-08-01T00:00:00Z', '2026-08-01T01:00:00Z')
        }
        $script:BriefCost = Get-ReviewCostRollup -Tuples @($script:BriefTuple) -Source 'rest' -Truncated:$false -ValuePresentPrNumbers @()
    }

    It 'CONSUMER 1 (surface-gated): a compliant brief does not enter the plan defense-kill candidate list' {
        # Without the fix the 811-D1 prose fallback fires on every brief — it
        # carries `<!-- plan-issue-` and the mandated `**Plan Stress-Test**`
        # literal by construction — and the brief is tallied against the
        # judge-rulings shape it does not have.
        $script:BriefCost.PlanStressTest.DefenseKillRate.N | Should -Be 0
    }

    It 'POSITIVE CONTROL: a real plan-stress-test issue DOES enter that list' {
        $planTuple = [PSCustomObject]@{
            Number          = 95601
            Surface         = 'issue'
            Bodies          = @("<!-- plan-issue-95601 -->`n`n**Plan Stress-Test**: reviewed.`n`n<!-- phase-containment-ledger-95601 -->`n`n<!-- judge-rulings`n- finding_id: N1`n  judge_ruling: sustained`n- finding_id: N2`n  judge_ruling: defense-sustained`n-->")
            CreatedAtValues = @('2026-08-01T00:00:00Z')
        }
        $cost = Get-ReviewCostRollup -Tuples @($planTuple) -Source 'rest' -Truncated:$false -ValuePresentPrNumbers @()
        $cost.PlanStressTest.DefenseKillRate.N | Should -BeGreaterThan 0
    }

    It 'CONSUMER 2 (ungated on surface): the design-challenge dismiss rate cannot see the brief head' {
        $script:BriefCost.DesignChallenge.DismissRate.N | Should -Be 0
        $script:BriefCost.DesignChallenge.DismissRate.CouldNotVerifyCount | Should -Be 0
    }

    It 'POSITIVE CONTROL: a real design record DOES reach the design-challenge dismiss rate' {
        $designTuple = [PSCustomObject]@{
            Number          = 95602
            Surface         = 'issue'
            Bodies          = @("<!-- design-phase-complete-95602 -->`n`nfinding_dispositions:`n- finding_id: D1`n  disposition: incorporate`n- finding_id: D2`n  disposition: dismiss`n")
            CreatedAtValues = @('2026-08-01T00:00:00Z')
        }
        $cost = Get-ReviewCostRollup -Tuples @($designTuple) -Source 'rest' -Truncated:$false -ValuePresentPrNumbers @()
        $cost.DesignChallenge.DismissRate.N | Should -Be 2
    }

    It 'A1(d): filtered_count has a real consumer — the brief-review dismiss rate reads its value' {
        # 6 upheld, 2 dismissed, 4 filtered -> denominator 12, numerator 6.
        # If filtered_count were merely validated and never read, N would be 8.
        $script:BriefCost.BriefReview.DismissRate.N | Should -Be 12
        $script:BriefCost.BriefReview.DismissRate.Numerator | Should -Be 6
        $script:BriefCost.BriefReview.DismissRate.Rate | Should -Be 0.5
    }

    It 'a could-not-verify brief head contributes to neither numerator nor denominator, and is disclosed' {
        $badTuple = [PSCustomObject]@{
            Number          = $script:Id
            Surface         = 'issue'
            Bodies          = @(
                (script:New-BriefPlanComment),
                (script:New-BriefLedger -Head (script:New-BriefHead -FilterRan 'false' -Sustained 6))
            )
            CreatedAtValues = @('2026-08-01T00:00:00Z', '2026-08-01T01:00:00Z')
        }
        $cost = Get-ReviewCostRollup -Tuples @($badTuple) -Source 'rest' -Truncated:$false -ValuePresentPrNumbers @()
        $cost.BriefReview.DismissRate.N | Should -Be 0
        $cost.BriefReview.DismissRate.CouldNotVerifyCount | Should -Be 1
    }

    It 'the rendered cost section names the brief-review stage and its non-comparability' {
        $text = (Format-ReviewCostSection -Rollup $script:BriefCost) -join "`n"
        $text | Should -Match 'Stage: brief-review'
        $text | Should -Match 'not directly comparable'
        $text | Should -Match 'NOT APPLICABLE'
    }
}

# ---------------------------------------------------------------------------
# W5 / O1 — the migration.
# ---------------------------------------------------------------------------

Describe 'W5/O1: the corpus migration produces the decided shape, idempotently (issue #951 D5 / A1(c))' {

    BeforeAll {
        # Fixtures reproducing each contamination shape. Deliberately
        # synthetic: this run is bound to write nothing to the live corpus.
        function script:New-ContaminatedLedger {
            param([int]$Issue, [int]$Rows, [string]$Prefix = 'N')
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("<!-- phase-containment-ledger-$Issue -->")
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('<!-- judge-rulings')
            for ($i = 1; $i -le $Rows; $i++) {
                [void]$sb.AppendLine("- finding_id: ${Prefix}$i")
                [void]$sb.AppendLine('  judge_ruling: sustained')
            }
            [void]$sb.AppendLine('-->')
            [void]$sb.AppendLine('')
            for ($i = 1; $i -le $Rows; $i++) {
                [void]$sb.AppendLine("<!-- phase-containment-$Issue -->")
                [void]$sb.AppendLine("finding_key: plan-stress-test:${Issue}:plan-issue-${Issue}:${Prefix}$i")
                [void]$sb.AppendLine('introduced_phase: design')
                [void]$sb.AppendLine('catchable_phase: plan')
                [void]$sb.AppendLine('caught_stage: plan-stress-test')
                [void]$sb.AppendLine('escape_distance: 0')
                [void]$sb.AppendLine('severity: medium')
                [void]$sb.AppendLine('systemic_fix_type: instruction')
                [void]$sb.AppendLine('category: pattern')
                [void]$sb.AppendLine("<!-- /phase-containment-$Issue -->")
            }
            return $sb.ToString()
        }
        function script:New-HistoricalPlan {
            param([int]$Issue)
            # The historical shape: spine-omitted, NO plan-variant declaration.
            return "<!-- plan-issue-$Issue -->`n`n---`nspine-omitted: plan-too-small`n---`n`n**Plan Stress-Test**: three lenses.`n"
        }
    }

    It 'the filtered-projected shape (#939) relabels and renders clean' {
        $before = script:New-ContaminatedLedger -Issue 939 -Rows 29
        $after = (Convert-BRMLedgerBody -Body $before -Issue 939).Body
        $v = Test-BRMCorrectedVerdict -Bodies @((script:New-HistoricalPlan -Issue 939), $after) -Issue 939
        $v.Failures -join ' | ' | Should -BeExactly ''
        $v.Gap.ParseStatus | Should -BeExactly 'ok'
        $v.Gap.SustainedCount | Should -Be 29
        $v.Gap.BlockCount | Should -Be 29
    }

    It 'the unfiltered-projected shape (#941) withdraws and renders the unverified end state' {
        $before = script:New-ContaminatedLedger -Issue 941 -Rows 27 -Prefix 'M'
        $after = (Convert-BRMLedgerBody -Body $before -Issue 941).Body
        $v = Test-BRMCorrectedVerdict -Bodies @((script:New-HistoricalPlan -Issue 941), $after) -Issue 941
        $v.Failures -join ' | ' | Should -BeExactly ''
        $v.Gap.ParseStatus | Should -BeExactly 'could-not-verify'
        $v.Gap.Reason | Should -BeExactly 'filter-not-run'
        $v.Gap.BlockCount | Should -Be 0
    }

    It 'the head rewrite and the resulting SURFACE VISIBILITY are part of the shape, not just the row fields' {
        $before = script:New-ContaminatedLedger -Issue 939 -Rows 29
        $bodies = @((script:New-HistoricalPlan -Issue 939), $before)
        # Before: the undeclared historical plan routes to plan-stress-test.
        (Get-IssueEmissionSurfaces -Bodies $bodies -Id 939) | Should -Contain 'plan-stress-test'
        $after = (Convert-BRMLedgerBody -Body $before -Issue 939).Body
        # After: the ledger sibling's own brief head routes it, WITHOUT any
        # change to the plan comment — the retro-patch A1(a) forbids.
        (Get-IssueEmissionSurfaces -Bodies @((script:New-HistoricalPlan -Issue 939), $after) -Id 939) | Should -Contain 'brief-review'
        (Get-IssueEmissionSurfaces -Bodies @((script:New-HistoricalPlan -Issue 939), $after) -Id 939) | Should -Not -Contain 'plan-stress-test'
    }

    It 'A1(a): the migration never writes a plan-variant declaration onto a historical plan comment' {
        $planBefore = script:New-HistoricalPlan -Issue 939
        $planBefore | Should -Not -Match 'plan-variant'
        # Convert-BRMLedgerBody only ever takes and returns the LEDGER body.
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/scripts/lib/brief-review-migration-core.ps1')
        $src | Should -Not -Match "plan-variant[ \t]*:[ \t]*brief"
    }

    It 'O1: running twice leaves byte-identical state' {
        $before = script:New-ContaminatedLedger -Issue 939 -Rows 29
        $once = (Convert-BRMLedgerBody -Body $before -Issue 939)
        $twice = (Convert-BRMLedgerBody -Body $once.Body -Issue 939)
        $twice.Changed | Should -BeFalse
        $twice.Body | Should -BeExactly $once.Body
    }

    It 'O1: the verification RE-PARSES — a count-grain recount would pass where this fails' {
        # The stage-only relabel: 29 blocks written, 29 blocks readable as
        # text, every one schema-valid. A recount matches. The verdict does
        # not, because the finding_key prefix gate discards all of them.
        $before = script:New-ContaminatedLedger -Issue 939 -Rows 29
        $full = (Convert-BRMLedgerBody -Body $before -Issue 939).Body
        $stageOnly = [regex]::Replace($full, '(?m)^finding_key[ \t]*:[ \t]*brief-review:', 'finding_key: plan-stress-test:')
        ([regex]::Matches($stageOnly, '(?m)^caught_stage[ \t]*:[ \t]*brief-review')).Count | Should -Be 29 -Because 'a count-grain recount sees 29 corrected rows'
        $v = Test-BRMCorrectedVerdict -Bodies @((script:New-HistoricalPlan -Issue 939), $stageOnly) -Issue 939
        $v.Ok | Should -BeFalse -Because 'the verdict-grain check re-parses and sees zero countable blocks'
        ($v.Failures -join ' ') | Should -Match 'BlockCount'
    }

    It 'the bound holds: an unsanctioned issue is refused' {
        { Convert-BRMLedgerBody -Body '<!-- phase-containment-ledger-777 -->' -Issue 777 } | Should -Throw '*outside this one-time migration*'
    }

    It 'the bound holds: a body that is not the named ledger sibling is refused' {
        { Convert-BRMLedgerBody -Body 'unrelated comment text' -Issue 939 } | Should -Throw '*does not carry*'
    }
}

# ---------------------------------------------------------------------------
# W1/W4 — a lawful emission exists, and the standard is machine-readable.
# ---------------------------------------------------------------------------

Describe 'W1/W4: a lawful judge-free emission exists and its standard is machine-readable (issue #951)' {

    It 'W1: a brief review records its findings with no judge token in the authorizing record' {
        $ledger = script:New-BriefLedger -Head (script:New-BriefHead -Sustained 3) -Rows (script:New-BriefRows -Count 3)
        $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review'
        $g.ParseStatus | Should -BeExactly 'ok'
        $g.SustainedCount | Should -Be 3
        $ledger | Should -Not -Match 'judge_ruling'
        $ledger | Should -Not -Match 'judge-rulings'
    }

    It 'W4: two rows upheld under different standards differ in a PARSED and VALIDATED field' {
        $briefEntry = @{
            finding_key = 'brief-review:1:x'; introduced_phase = 'design'; catchable_phase = 'plan'
            caught_stage = 'brief-review'; escape_distance = 0; severity = 'medium'
            systemic_fix_type = 'instruction'; category = 'pattern'
        }
        $judgeEntry = @{
            finding_key = 'plan-stress-test:1:x'; introduced_phase = 'design'; catchable_phase = 'plan'
            caught_stage = 'plan-stress-test'; escape_distance = 0; severity = 'medium'
            systemic_fix_type = 'instruction'; category = 'pattern'
        }
        (Test-PhaseContainmentEntry -Entry $briefEntry).IsValid | Should -BeTrue
        (Test-PhaseContainmentEntry -Entry $judgeEntry).IsValid | Should -BeTrue
        $briefEntry.caught_stage | Should -Not -BeExactly $judgeEntry.caught_stage
    }

    It 'projection 2 is arithmetically correct: a plan-catchable brief finding has escape_distance 0' {
        $entry = @{
            finding_key = 'brief-review:1:x'; introduced_phase = 'design'; catchable_phase = 'plan'
            caught_stage = 'brief-review'; escape_distance = 1; severity = 'medium'
            systemic_fix_type = 'instruction'; category = 'pattern'
        }
        (Test-PhaseContainmentEntry -Entry $entry).IsValid | Should -BeFalse -Because 'projection(brief-review)=2 minus ordinal(plan)=2 is 0, not 1'
    }

    It 'a design-catchable brief finding escapes by exactly 1' {
        $entry = @{
            finding_key = 'brief-review:1:x'; introduced_phase = 'design'; catchable_phase = 'design'
            caught_stage = 'brief-review'; escape_distance = 1; severity = 'medium'
            systemic_fix_type = 'instruction'; category = 'pattern'
        }
        (Test-PhaseContainmentEntry -Entry $entry).IsValid | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# Forgery, shadowing and scoping — the defence classes the surface shipped
# without, found by the PR #963 adversarial review. Every test here fails
# against the pre-review implementation; they are the standing form of that
# review's findings.
# ---------------------------------------------------------------------------

Describe 'Forgery and shadowing defences (PR #963 review)' {

    Context 'duplicate-head guard (finding D)' {

        It 'a FENCED decoy head above the real one fails loud instead of shadowing it' {
            # The decoy needs no invention: it is a copy of the example the
            # doctrine publishes. Pre-fix, first-match-wins plus region
            # isolation at the next fence made the real head invisible.
            $decoy = "``````yaml`n" + (script:New-BriefHead -FilterRan 'true' -Sustained 1) + "`n``````"
            $ledger = script:New-BriefLedger -Head (script:New-BriefHead -FilterRan 'false' -Sustained 3) -Extra $decoy
            $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review'
            $g.ParseStatus | Should -BeExactly 'could-not-verify'
            $g.Reason | Should -BeExactly 'duplicate-head'
        }

        It 'THE SHARP CASE: a decoy cannot convert an honest filter-not-run into clean' {
            $decoy = "``````yaml`n" + (script:New-BriefHead -FilterRan 'true' -Sustained 2) + "`n``````"
            $ledger = script:New-BriefLedger -Head (script:New-BriefHead -FilterRan 'false' -Sustained 2) -Rows (script:New-BriefRows -Count 2) -Extra $decoy
            $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review'
            $g.ParseStatus | Should -Not -BeExactly 'ok'
        }

        It 'CONTROL: exactly one head still parses' {
            $ledger = script:New-BriefLedger -Head (script:New-BriefHead -FilterRan 'true' -Sustained 2) -Rows (script:New-BriefRows -Count 2)
            (Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review').ParseStatus | Should -BeExactly 'ok'
        }
    }

    Context 'ledger scoping (finding C)' {

        It 'a foreign comment cannot disarm the AC4 absence backstop' {
            # Pre-fix this rendered a reassuring clean sustained=0 blocks=0 —
            # the silent zero AC4 exists to close, reintroduced by any comment.
            $foreign = "Unrelated comment.`n`n" + (script:New-BriefHead -FilterRan 'true' -Sustained 0 -Dismissed 2)
            $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $foreign) -Id $script:Id -Surface 'brief-review'
            $g.ParseStatus | Should -BeExactly 'could-not-verify'
            $g.Reason | Should -BeExactly 'head-missing'
        }

        It 'a foreign comment cannot contribute to SustainedCount' {
            $foreign = "Unrelated comment.`n`n" + (script:New-BriefHead -FilterRan 'true' -Sustained 4)
            $ledger = script:New-BriefLedger -Head (script:New-BriefHead -FilterRan 'true' -Sustained 2) -Rows (script:New-BriefRows -Count 2)
            $g = Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger, $foreign) -Id $script:Id -Surface 'brief-review'
            $g.SustainedCount | Should -Be 2 -Because 'only the ledger sibling of this issue authorizes a count'
        }

        It 'a foreign comment cannot route the issue either' {
            $foreign = "Unrelated.`n`n" + (script:New-BriefHead -FilterRan 'true' -Sustained 1)
            ((Get-IssueEmissionSurfaces -Bodies @((script:New-BriefPlanComment -Undeclared), $foreign) -Id $script:Id) -join ',') |
                Should -BeExactly 'design-challenge,plan-stress-test'
        }
    }

    Context 'declaration predicate is fence-blind no longer (finding F)' {

        It 'a plan comment that DOCUMENTS the declaration inside a fence does not declare' {
            $documenting = @"
<!-- plan-issue-$script:Id -->

---
spine-omitted: plan-too-small
---

A chunk brief declares its shape like this:

``````yaml
plan-variant: brief
``````

**Plan Stress-Test**: reviewed with a judge.
"@
            Test-BriefPlanVariantDeclared -Bodies @($documenting) -Id $script:Id | Should -BeFalse
            ((Get-IssueEmissionSurfaces -Bodies @($documenting) -Id $script:Id) -join ',') | Should -BeExactly 'design-challenge,plan-stress-test'
        }

        It 'CONTROL: a real frontmatter declaration still declares' {
            Test-BriefPlanVariantDeclared -Bodies @((script:New-BriefPlanComment)) -Id $script:Id | Should -BeTrue
        }
    }

    Context 'block-scalar index anchoring (finding G)' {

        It 'a disposition following a block scalar is COUNTED, not silently dropped' {
            # The key anchor crosses newlines, so the match starts inside the
            # preceding block scalar while the keyword itself does not.
            # Filtering on the match index discarded a legitimate entry.
            $head = @"
brief_dispositions:
  convergence_filter_ran: true
  filtered_count: 1
  findings:
    - finding_id: N1
      note: |
        A multi-line rationale that occupies a block scalar
        and ends with a trailing blank line.

      disposition: dismiss
    - finding_id: N2
      disposition: incorporate
"@
            $t = Get-DispositionTally -Surface 'brief-review' -Body (script:New-BriefLedger -Head $head)
            $t.ParseStatus | Should -BeExactly 'ok'
            $t.SustainedCount | Should -Be 1
            $t.DismissedCount | Should -Be 1 -Because 'the dismiss sits after a block scalar, not inside one'
        }

        It 'CONTROL: a disposition INSIDE a block scalar is still excluded' {
            $head = @"
brief_dispositions:
  convergence_filter_ran: true
  filtered_count: 0
  findings:
    - finding_id: N1
      disposition: incorporate
      rationale: |
        The reviewer wrote disposition: dismiss inside this prose
        and it must not be counted as a second entry.
"@
            $t = Get-DispositionTally -Surface 'brief-review' -Body (script:New-BriefLedger -Head $head)
            $t.ParseStatus | Should -BeExactly 'ok'
            $t.SustainedCount | Should -Be 1
            $t.DismissedCount | Should -Be 0
        }
    }

    Context 'head-level assertions belong to the head (finding K)' {

        It 'an assertion nested inside a finding entry does not satisfy the head requirement' {
            $head = @"
brief_dispositions:
  findings:
    - finding_id: N1
      disposition: incorporate
      convergence_filter_ran: true
      filtered_count: 4
"@
            $t = Get-DispositionTally -Surface 'brief-review' -Body (script:New-BriefLedger -Head $head)
            $t.ParseStatus | Should -BeExactly 'could-not-verify'
        }
    }

    Context 'fail-loud vocabulary (findings L, M, W, AA, Z)' {

        It 'a non-canonical boolean reads as unreadable, not absent' {
            $head = "brief_dispositions:`n  convergence_filter_ran: True`n  filtered_count: 1`n  findings:`n    - finding_id: N1`n      disposition: incorporate"
            (Get-DispositionTally -Surface 'brief-review' -Body (script:New-BriefLedger -Head $head)).Reason | Should -BeExactly 'filter-value-unrecognized'
        }

        It 'an unbounded filtered_count fails loud instead of throwing out of the whole sweep' {
            $head = "brief_dispositions:`n  convergence_filter_ran: true`n  filtered_count: 99999999999999999999`n  findings:`n    - finding_id: N1`n      disposition: incorporate"
            $bodies = @((script:New-BriefPlanComment), (script:New-BriefLedger -Head $head))
            { Get-EmissionGap -Bodies $bodies -Id $script:Id -Surface 'brief-review' } | Should -Not -Throw
            (Get-EmissionGap -Bodies $bodies -Id $script:Id -Surface 'brief-review').Reason | Should -BeExactly 'head-corrupt'
        }

        It 'a duplicated filtered_count is corruption, not omission' {
            $head = "brief_dispositions:`n  convergence_filter_ran: true`n  filtered_count: 8`n  filtered_count: 99`n  findings:`n    - finding_id: N1`n      disposition: incorporate"
            (Get-DispositionTally -Surface 'brief-review' -Body (script:New-BriefLedger -Head $head)).Reason | Should -BeExactly 'head-corrupt'
        }

        It 'an unknown disposition value is refused rather than silently dropped' {
            $head = "brief_dispositions:`n  convergence_filter_ran: true`n  filtered_count: 0`n  findings:`n    - finding_id: N1`n      disposition: defer`n    - finding_id: N2`n      disposition: incorporate"
            (Get-DispositionTally -Surface 'brief-review' -Body (script:New-BriefLedger -Head $head)).Reason | Should -BeExactly 'unknown-disposition-value'
        }

        It 'a finding_id with no disposition is refused rather than reported as a smaller total' {
            $head = "brief_dispositions:`n  convergence_filter_ran: true`n  filtered_count: 0`n  findings:`n    - finding_id: N1`n    - finding_id: N2`n      disposition: incorporate"
            (Get-DispositionTally -Surface 'brief-review' -Body (script:New-BriefLedger -Head $head)).Reason | Should -BeExactly 'head-corrupt'
        }

        It 'a genuinely fully-filtered brief is a legal empty record, not corruption' {
            # A convergence filter that removes the whole panel output is a
            # real outcome. Pre-fix it rendered head-corrupt — "the head is
            # unparseable" — about a head that parsed perfectly.
            $head = "brief_dispositions:`n  convergence_filter_ran: true`n  filtered_count: 5`n  findings: []"
            $t = Get-DispositionTally -Surface 'brief-review' -Body (script:New-BriefLedger -Head $head)
            $t.ParseStatus | Should -BeExactly 'ok'
            $t.SustainedCount | Should -Be 0
            $t.FilteredCount | Should -Be 5
        }
    }

    Context 'the writer refuses everything the reader refuses (findings B, H, I, J)' {

        BeforeAll {
            $script:WriterSrc = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-phase-ledger-core.ps1')
            $script:WrapperSrc = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-phase-ledger.ps1')
            $script:PlanSkill = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/plan-authoring/SKILL.md')
        }

        It 'the CLI wrapper — the path the doctrine names — accepts -Mode brief and -BriefHeadContent' {
            # Finding B: the wrapper was never touched, so the only documented
            # interface rejected the mode outright while 59 library tests
            # passed. Asserted at the wrapper's own parameter block.
            $script:WrapperSrc | Should -Match "ValidateSet\('plan', 'design', 'brief'\)"
            $script:WrapperSrc | Should -Match '\$BriefHeadContent'
            $script:WrapperSrc | Should -Match '-BriefHeadContent \$BriefHeadContent'
        }

        It 'the wrapper no longer forces judge content on a mode that refuses it' {
            $script:WrapperSrc | Should -Not -Match '\[Parameter\(Mandatory\)\]\[string\]\$JudgeRulingsContent'
        }

        It 'the doctrine invocation resolves against the wrapper parameters' {
            $script:PlanSkill | Should -Match '-Mode brief'
            $script:PlanSkill | Should -Match 'BriefHeadContent'
        }

        It 'Issue-Planner instructs the brief branch at the emission step' {
            $planner = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'agents/Issue-Planner.agent.md')
            $planner | Should -Match '-Mode brief'
            $planner | Should -Match 'brief-review:'
        }

        It 'the writer refuses a head missing filtered_count, declaring filter-not-run, or asserting only inside a finding' {
            $script:WriterSrc | Should -Match 'no `filtered_count` as a key of the head'
            $script:WriterSrc | Should -Match 'declares `convergence_filter_ran: false`'
            $script:WriterSrc | Should -Match '\$headPreamble'
        }
    }

    Context 'the brief finding_key prefix is documented (finding H)' {

        It 'plan-authoring states the brief-review prefix and why a mismatch is invisible' {
            $skill = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/plan-authoring/SKILL.md')
            $skill | Should -Match 'finding_key: brief-review:'
            $skill | Should -Match 'never cross-check'
        }

        It 'the hazard is real: a mismatched prefix validates and is then discarded' {
            # Pinned so the doc sentence above is testable rather than merely
            # asserted — this is the behaviour the sentence warns about.
            $entry = @{
                finding_key       = "plan-stress-test:$($script:Id):N1"
                introduced_phase  = 'design'
                catchable_phase   = 'plan'
                caught_stage      = 'brief-review'
                escape_distance   = 0
                severity          = 'medium'
                systemic_fix_type = 'instruction'
                category          = 'pattern'
            }
            (Test-PhaseContainmentEntry -Entry $entry).IsValid | Should -BeTrue -Because 'nothing cross-checks prefix against stage'
            $ledger = script:New-BriefLedger -Head (script:New-BriefHead -FilterRan 'true' -Sustained 1) -Rows (script:New-BriefRows -Count 1 -Prefix 'plan-stress-test')
            (Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review').BlockCount |
                Should -Be 0 -Because 'the surface-attribution gate discards it unread'
        }
    }
}

# ---------------------------------------------------------------------------
# Remaining PR #963 review findings closed inline: O (guard narrower than the
# parser), AB (withdrawal destroyed data), AF (WITHHELD render untested).
# ---------------------------------------------------------------------------

Describe 'Migration guard and render coverage (PR #963 review: O, AB, AF)' {

    # Fixtures (New-ContaminatedForTail, New-HistPlan) live in the FILE-level
    # BeforeAll — they are shared with the #968 AC3 Describe below, and a
    # Describe-scoped definition made any filtered run of that Describe fail
    # with CommandNotFoundException rather than an assertion result.

    Context 'O: the verdict guard is as discriminating as the parser' {

        It 'a QUOTED caught_stage the rewrite skips is caught by the guard' {
            # Finding O, in full. The rewrite's literal regex does not match a
            # quoted value; ConvertFrom-PhaseContainmentYaml strips the quotes
            # and the entry validates. So the prefix moves, the stage does not,
            # the rows still COUNT — and before this fix the guard added
            # specifically to catch that decoupling was a third copy of the
            # rewrite's own regex, and therefore blind to exactly the inputs
            # the rewrite had skipped.
            #
            # 29 rows, matching the planned correction, so the count
            # assertions PASS and only the parse-grain stage check can fail;
            # otherwise a count mismatch would mask what this test is for.
            $before = script:New-ContaminatedForTail -Issue 939 -Rows 29 -StageValue "'plan-stress-test'"
            $after = (Convert-BRMLedgerBody -Body $before -Issue 939).Body
            $v = Test-BRMCorrectedVerdict -Bodies @((script:New-HistPlan -Issue 939), $after) -Issue 939
            $v.Ok | Should -BeFalse
            ($v.Failures -join ' ') | Should -Match "caught_stage 'plan-stress-test'"
            ($v.Failures -join ' ') | Should -Not -Match 'BlockCount' -Because 'the counts are correct here; only the stage did not move'
        }

        It 'a stage/prefix DECOUPLING is caught at parse grain, with the counts correct' {
            # The real hazard the guard exists for, and the one a CRLF
            # anchoring slip actually produced during implementation: the
            # prefix moved and the stage did not, both halves validate, and
            # BlockCount reads correct while every row grades wrongly.
            $before = script:New-ContaminatedForTail -Issue 939 -Rows 29
            $full = (Convert-BRMLedgerBody -Body $before -Issue 939).Body
            $decoupled = [regex]::Replace($full, '(?m)^caught_stage[ 	]*:[ 	]*brief-review[ 	]*$', 'caught_stage: plan-stress-test')
            $v = Test-BRMCorrectedVerdict -Bodies @((script:New-HistPlan -Issue 939), $decoupled) -Issue 939
            $v.Ok | Should -BeFalse
            ($v.Failures -join ' ') | Should -Match "caught_stage 'plan-stress-test'"
            ($v.Failures -join ' ') | Should -Not -Match 'BlockCount' -Because 'the counts are correct here; only the stage did not move'
        }

        It 'an INDENTED field set is RELABELLED, not skipped, with its indentation preserved' {
            # RETARGETED by item-8 of the PR #963 external review. This test
            # previously asserted the opposite — that the rewrite SKIPS an
            # indented field set and the guard catches the skip. That was a
            # faithful pin of the behavior at the time, but the behavior was
            # itself the defect: Get-PhaseContainmentBlock's field parser is
            # `^\s*finding_key\s*:` / `^\s*caught_stage\s*:` (tolerant of
            # indentation), so a column-0-only rewrite left rows the production
            # reader accepts sitting un-migrated. Item-8 made the rewrite as
            # tolerant as the parser, which retires this input from the
            # "rewrite skips it" class entirely — the guard has nothing left to
            # catch here because there is no longer a skip.
            #
            # The Context's charter (the guard is as discriminating as the
            # parser) is unchanged and still covered by the two tests above,
            # whose inputs the rewrite genuinely does skip. This test now pins
            # item-8's own fix instead, and is discriminating in the same
            # direction: reverting either relabel regex to a column-0 anchor
            # turns every assertion below red, because neither half would move.
            $before = script:New-ContaminatedForTail -Issue 939 -Rows 29 -Indent '  '
            $after = (Convert-BRMLedgerBody -Body $before -Issue 939).Body

            # Both halves of the coupled rewrite asserted SEPARATELY and at
            # their literal indented shape — never a recount, which passes on
            # the half-done state where the prefix moved and the stage did not.
            ([regex]::Matches($after, '(?m)^  finding_key: brief-review:939:')).Count |
                Should -Be 29 -Because 'every finding_key must relabel AND keep its two-space indentation'
            ([regex]::Matches($after, '(?m)^  caught_stage: brief-review[ \t]*\r?$')).Count |
                Should -Be 29 -Because 'every caught_stage must relabel AND keep its two-space indentation'
            $after | Should -Not -Match '(?m)^(finding_key|caught_stage):' -Because 'the replacement must preserve indentation, not flatten the row to column 0'
            $after | Should -Not -Match 'plan-stress-test:939:' -Because 'no old-prefix row may survive the rewrite'

            # And the verdict — the grain that actually matters — now verifies.
            (Test-BRMCorrectedVerdict -Bodies @((script:New-HistPlan -Issue 939), $after) -Issue 939).Ok | Should -BeTrue
        }

        It 'an INDENTED corpus is recognised as already-corrected on a second pass' {
            # Item-8 also widened the idempotency gate's $hasOldPrefix /
            # $hasOldStage probes to tolerate indentation. Without that half,
            # re-running over an indented corpus that HAD been corrected would
            # still read as needing work in one direction or the other; the
            # migration's documented resolution for an interrupted run is
            # "re-run", so a non-idempotent indented path breaks the only
            # recovery procedure the script offers.
            $before = script:New-ContaminatedForTail -Issue 939 -Rows 29 -Indent '  '
            $once = (Convert-BRMLedgerBody -Body $before -Issue 939).Body
            $twice = Convert-BRMLedgerBody -Body $once -Issue 939
            $twice.Changed | Should -BeFalse
            $twice.Reason | Should -BeExactly 'already-corrected'
            $twice.Body | Should -BeExactly $once
        }

        It 'CONTROL: the corpus shape the migration actually targets still verifies' {
            $before = script:New-ContaminatedForTail -Issue 939 -Rows 29
            $after = (Convert-BRMLedgerBody -Body $before -Issue 939).Body
            (Test-BRMCorrectedVerdict -Bodies @((script:New-HistPlan -Issue 939), $after) -Issue 939).Ok | Should -BeTrue
        }
    }

    Context 'M1: judge-rulings ids and their rulings survive blank lines and CRLF' {

        BeforeAll {
            function script:New-JudgeHead {
                param([int]$Blanks = 0, [string]$Nl = "`n", [int]$OmitRulingFor = 0)
                $lines = [System.Collections.Generic.List[string]]::new()
                for ($i = 1; $i -le 3; $i++) {
                    if ($i -gt 1) { for ($b = 0; $b -lt $Blanks; $b++) { $lines.Add('') } }
                    $lines.Add("- finding_id: N$i")
                    if ($i -ne $OmitRulingFor) { $lines.Add('  judge_ruling: sustained') }
                }
                $inner = $lines -join $Nl
                return ('<!-- phase-containment-ledger-939 -->' + $Nl + $Nl + '<!-- judge-rulings' + $Nl + $inner + $Nl + '-->' + $Nl)
            }
        }

        # The post-fix review (M1) found the FIRST attempt at this fix — two
        # regex enumerations joined on .Index — silently returned Ruling=$null
        # for every id after the first whenever entries were separated by blank
        # lines, because the coupled pattern's greedy trailing \s*$ consumed
        # into the gap and desynchronised the two enumerations. Downstream that
        # is a hard throw in New-BRMBriefHead. These cases are the exact
        # trigger boundaries the panel measured.
        It 'reads every id and ruling across <label>' -TestCases @(
            @{ label = 'LF, no blank lines';   blanks = 0; nl = "`n" }
            @{ label = 'LF, one blank line';   blanks = 1; nl = "`n" }
            @{ label = 'LF, two blank lines';  blanks = 2; nl = "`n" }
            @{ label = 'LF, three blank lines'; blanks = 3; nl = "`n" }
            @{ label = 'CRLF, no blank lines'; blanks = 0; nl = "`r`n" }
            @{ label = 'CRLF, one blank line'; blanks = 1; nl = "`r`n" }
            @{ label = 'CRLF, two blank lines'; blanks = 2; nl = "`r`n" }
        ) {
            param($label, $blanks, $nl)
            $r = @(Get-BRMJudgeRulingsFindingIds -Body (script:New-JudgeHead -Blanks $blanks -Nl $nl))
            $r.Count | Should -Be 3 -Because 'every finding_id in the head must be returned'
            @($r | ForEach-Object { $_.Id }) -join ',' | Should -BeExactly 'N1,N2,N3'
            @($r | Where-Object { $null -eq $_.Ruling }).Count | Should -Be 0 -Because 'every one of these entries carries a well-formed judge_ruling line'
        }

        It 'an id whose judge_ruling is ABSENT is returned with a null ruling, not dropped' {
            # This is the case item-28 was accepted to fix in the first place.
            # The pre-fix combined regex dropped the id entirely, producing a
            # head with fewer findings than rows — the false-provenance shape
            # this whole migration exists to remove.
            $r = @(Get-BRMJudgeRulingsFindingIds -Body (script:New-JudgeHead -OmitRulingFor 2))
            $r.Count | Should -Be 3 -Because 'the id must survive even when its ruling cannot be read'
            @($r | ForEach-Object { $_.Id }) -join ',' | Should -BeExactly 'N1,N2,N3'
            $r[1].Ruling | Should -BeNullOrEmpty
            $r[0].Ruling | Should -BeExactly 'sustained'
            $r[2].Ruling | Should -BeExactly 'sustained' -Because 'a ruling-less id must not consume the NEXT entry''s ruling'
        }

        It 'a null ruling reaches New-BRMBriefHead as a refusal, never an invented disposition' {
            $findings = @(Get-BRMJudgeRulingsFindingIds -Body (script:New-JudgeHead -OmitRulingFor 2))
            { New-BRMBriefHead -Findings $findings -ConvergenceFilterRan $true -FilteredCount 0 } |
                Should -Throw -ExpectedMessage '*has no faithful brief-review disposition*'
        }
    }

    Context 'AB: withdrawal removes rows from the count without destroying them' {

        BeforeAll {
            $script:WBefore = script:New-ContaminatedForTail -Issue 941 -Rows 27 -Prefix 'M'
            $script:WAfter = (Convert-BRMLedgerBody -Body $script:WBefore -Issue 941).Body
        }

        It 'the rows no longer count' {
            $v = Test-BRMCorrectedVerdict -Bodies @((script:New-HistPlan -Issue 941), $script:WAfter) -Issue 941
            $v.Gap.BlockCount | Should -Be 0
            $v.Ok | Should -BeTrue
        }

        It 'the phase attribution survives in an archive' {
            $script:WAfter | Should -Match 'Withdrawn rows \(27\)'
            $script:WAfter | Should -Match 'introduced_phase: design'
            $script:WAfter | Should -Match 'systemic_fix_type: instruction'
        }

        It 'the archive is INERT — no live marker can be re-parsed out of it' {
            # The whole point: an archive that a later sweep could read back as
            # live rows would reinstate the contamination it exists to retire.
            (Get-PhaseContainmentBlock -Text $script:WAfter -Id 941) | Should -BeNullOrEmpty
            $script:WAfter | Should -Not -Match '<!--\s*/?phase-containment-941\s*-->'
        }

        It 'the archive does not break idempotency' {
            $second = Convert-BRMLedgerBody -Body $script:WAfter -Issue 941
            $second.Changed | Should -BeFalse
            $second.Body | Should -BeExactly $script:WAfter
        }
    }

    Context 'AF: the WITHHELD sub-arm line is rendered, not just flagged' {

        It 'a sub-arm below the floor renders WITHHELD with its population visible' {
            $mk = {
                param($stage, $n)
                1..$n | ForEach-Object {
                    @{ finding_key = "${stage}:x"; introduced_phase = 'plan'; catchable_phase = 'plan'
                       caught_stage = $stage; escape_distance = 0; severity = 'low'
                       systemic_fix_type = 'none'; category = 'pattern'; apparatus_meta = $false }
                }
            }
            $entries = @((& $mk 'plan-stress-test' 8) + (& $mk 'brief-review' 3))
            $rollup = Get-PhaseContainmentRollup -Entries $entries
            $text = (Format-PhaseContainmentReport -Context @{
                    Rollup = $rollup; Source = 'rest'; Truncated = $false
                    WindowDays = 90; FetchedAt = ([datetime]'2026-08-01T00:00:00Z'); InvalidEntryCount = 0
                }) -join "`n"
            $text | Should -Match 'brief-review: n=3 — WITHHELD \(n<5\)'
            $text | Should -Not -Match 'brief-review: n=3\s+escape='
        }
    }
}

# ---------------------------------------------------------------------------
# Issue #968 — the four PR #963 fixes no behavioural test could observe.
#
# THE BAR HERE IS NOT "a test exists". It is that reverting the fix in
# isolation turns one of these assertions red. Every Context below records the
# mutation that was run against it and what that run reported; a test whose
# guard can be deleted in silence is the exact defect #968 exists to close, so
# a source-text `Should -Match` on a message string satisfies nothing here.
# ---------------------------------------------------------------------------

Describe '#968 AC1: the brief-head writer is observed by invocation, across its residual refusals AND both write outcomes' {

    # WHY A SEPARATE CONTEXT FROM M2's. M2's probe installs one shared read
    # stub returning $null and normalises the result to 'accepted', which is
    # what lets it prove the content guards passed. It therefore cannot reach
    # anything AFTER the read — the expected-marker refusal, the write-failure
    # passthrough, or either success action. Those need the read to SUCCEED,
    # and changing M2's stub in place would turn every one of its cases red.

    BeforeAll {
        . (Join-Path $script:RepoRoot '.github/scripts/lib/find-or-upsert-comment.ps1')
        . (Join-Path $script:RepoRoot '.github/scripts/lib/marker-transport-core.ps1')
        . (Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-phase-ledger-core.ps1')

        $script:W968Marker = '<!-- phase-containment-ledger-968 -->'
        $script:W968ReadBody = $null
        $script:W968WriteResult = [PSCustomObject]@{ Success = $true; Reason = $null }
        $script:W968WrittenBodies = [System.Collections.Generic.List[string]]::new()

        # Both seams stubbed, so no test in this file can reach the network.
        function script:Get-PPLCommentBodyById { param($Owner, $Repo, $CommentId) return $script:W968ReadBody }
        function script:Set-PPLCommentBodyDirect {
            param($Owner, $Repo, $CommentId, $NewBody)
            $script:W968WrittenBodies.Add($NewBody)
            return $script:W968WriteResult
        }

        $script:W968Canon = @(
            'brief_dispositions:'
            '  convergence_filter_ran: true'
            '  filtered_count: 8'
            '  findings:'
            '    - finding_id: N1'
            '      disposition: incorporate'
        ) -join "`n"

        function script:Invoke-W968 {
            # Returns the REAL result object — not a normalised string — because
            # this context asserts Action and the written body, not only Reason.
            param([string]$Head, [string]$Marker = $script:W968Marker)
            return Set-PPLBriefHeadBlockOnComment -Owner o -Repo r -CommentId 1 `
                -ExpectedMarker $Marker -BriefHeadContent $Head
        }
    }

    BeforeEach {
        $script:W968ReadBody = $null
        $script:W968WriteResult = [PSCustomObject]@{ Success = $true; Reason = $null }
        $script:W968WrittenBodies.Clear()
    }

    AfterAll {
        # RESTORE, so this Describe cannot contaminate anything that runs after
        # it (post-review fix, finding P-P). `function script:` binds to the
        # whole FILE container, not to this Describe, and the M2 Context above
        # installs its own `Get-PPLCommentBodyById` returning $null that its
        # 'accepted' normalisation depends on. Ordering makes that safe today
        # — M2's Describe precedes this one and no random-order mode is
        # configured — but leaving a live stub behind means the file's
        # behaviour depends on declaration order rather than on scoping, and
        # a reordering would not fail loudly.
        function script:Get-PPLCommentBodyById { param($Owner, $Repo, $CommentId) return $null }
        Remove-Item -Path 'function:script:Set-PPLCommentBodyDirect' -ErrorAction SilentlyContinue
    }

    Context 'residual content refusals — each named by its OWN reason' {

        # Assert the specific reason, never merely Success=$false: several of
        # these guards have a LATER guard that also refuses the same input, so
        # a bare falsity assertion stays green when the guard under test is
        # deleted (falsifier 5).

        It 'refuses the HTML-comment form of the judge vocabulary, distinctly from the judge_ruling FIELD form' {
            # M2's probe covers the `judge_ruling:` field alternative at
            # persist-phase-ledger-core.ps1:629. The `<!-- judge-rulings` head
            # alternative at :628 is a separate regex and was uncovered.
            # MUTATION RUN: replacing the :628 alternative with a never-
            # matching pattern makes this input reach the read and return
            # 'accepted' — no later guard sees it, because the comment line is
            # indented (so the column-0 check passes) and lies inside the
            # preamble the finding-field scan does not object to.
            $head = $script:W968Canon -replace '  findings:', "  <!-- judge-rulings -->`n  findings:"
            $r = script:Invoke-W968 -Head $head
            $r.Success | Should -BeFalse
            $r.Reason | Should -Match 'carries judge vocabulary \(a judge-rulings head or a judge_ruling field\)'
            $script:W968WrittenBodies.Count | Should -Be 0 -Because 'a refusal must never reach the write'
        }

        It 'refuses a head carrying NO convergence_filter_ran assertion at all' {
            $head = @(
                'brief_dispositions:'
                '  filtered_count: 8'
                '  findings:'
                '    - finding_id: N1'
                '      disposition: incorporate'
            ) -join "`n"
            $r = script:Invoke-W968 -Head $head
            $r.Success | Should -BeFalse
            $r.Reason | Should -Match 'carries no machine-readable .convergence_filter_ran: true\|false. assertion as a key of the head itself'
        }

        It 'refuses a head whose ONLY assertion is nested inside a findings entry' {
            # Same return as the case above, by design — the two are separated
            # by the preamble truncation at persist-phase-ledger-core.ps1:642-646,
            # which has no return of its own. MUTATION RUN: reverting the
            # truncation ($headPreamble = $BriefHeadContent) makes the nested
            # assertion visible, so this input falls through to the
            # filtered_count refusal — a DIFFERENT reason, which is what makes
            # the scoping separately observable rather than redundant.
            $head = @(
                'brief_dispositions:'
                '  findings:'
                '    - finding_id: N1'
                '      disposition: incorporate'
                '      convergence_filter_ran: true'
            ) -join "`n"
            $r = script:Invoke-W968 -Head $head
            $r.Success | Should -BeFalse
            $r.Reason | Should -Match 'as a key of the head itself'
            $r.Reason | Should -Not -Match 'filtered_count' -Because 'the head-scoped read is what refuses here, not the count check'
        }

        It 'refuses a head declaring the filter ran but carrying no filtered_count' {
            $head = $script:W968Canon -replace '  filtered_count: 8\r?\n', ''
            $head | Should -Not -Match 'filtered_count' -Because 'the fixture must actually omit it'
            $r = script:Invoke-W968 -Head $head
            $r.Success | Should -BeFalse
            $r.Reason | Should -Match 'declares the filter ran but carries no .filtered_count. as a key of the head itself'
        }
    }

    Context 'post-read refusals — reachable only once the comment read succeeds' {

        It 'refuses to write onto a comment that does not carry the expected marker' {
            # persist-phase-ledger-core.ps1:713-715. Unreachable while the read
            # is stubbed to $null, so no test had ever exercised it.
            $script:W968ReadBody = "<!-- some-other-marker -->`n`nan unrelated comment`n"
            $r = script:Invoke-W968 -Head $script:W968Canon
            $r.Success | Should -BeFalse
            $r.Reason | Should -Match "does not contain expected marker '<!-- phase-containment-ledger-968 -->'"
            $r.Action | Should -BeNullOrEmpty
            $script:W968WrittenBodies.Count | Should -Be 0
        }

        It 'passes a failed write through as its own reason rather than inventing one' {
            # persist-phase-ledger-core.ps1:729-731. The failure the caller
            # needs to see is the WRITE helper's, verbatim.
            $script:W968ReadBody = "$script:W968Marker`n`nno head yet`n"
            $script:W968WriteResult = [PSCustomObject]@{
                Success = $false
                Reason  = 'gh api PATCH failed for comment 1 (exit 22): HTTP 422 Unprocessable Entity'
            }
            $r = script:Invoke-W968 -Head $script:W968Canon
            $r.Success | Should -BeFalse
            $r.Reason | Should -BeExactly 'gh api PATCH failed for comment 1 (exit 22): HTTP 422 Unprocessable Entity'
            $r.Action | Should -BeNullOrEmpty
            $script:W968WrittenBodies.Count | Should -Be 1 -Because 'the write WAS attempted; it is its failure that propagates'
        }
    }

    Context 'the two write outcomes, observed on the body handed to the writer' {

        # FALSIFIER 6, in force. `Action` and the body mutation both read
        # $headMatch.Success but are computed separately at
        # persist-phase-ledger-core.ps1:720-732, so asserting the LABEL proves
        # only that the predicate was evaluated. Every assertion that matters
        # below reads $script:W968WrittenBodies — the actual body.
        #
        # MUTATION RUN: swapping the two arms of the $newBody assignment leaves
        # Action correct on both cases and turns the body assertions red.

        It 'APPENDS onto a comment carrying no brief head' {
            $script:W968ReadBody = "$script:W968Marker`n`nprose that was already here`n"
            $r = script:Invoke-W968 -Head $script:W968Canon
            $r.Success | Should -BeTrue
            $r.Reason | Should -BeNullOrEmpty
            $r.Action | Should -BeExactly 'written'

            $script:W968WrittenBodies.Count | Should -Be 1
            $body = $script:W968WrittenBodies[0]
            $body | Should -Match 'prose that was already here' -Because 'an append must not destroy what was there'
            ([regex]::Matches($body, '(?m)^brief_dispositions[ \t]*:[ \t]*\r?$')).Count |
                Should -Be 1 -Because 'exactly one head — two heads is the ambiguity the reader fails loud on'
            $body | Should -Match '(?m)^  filtered_count: 8[ \t]*\r?$'

            # POSITION, not merely presence (post-review fix, finding P-C).
            # Every assertion above is presence-only, so inverting the
            # append/replace branch left all of them green: on a headless body
            # $headMatch.Index and .Length are both 0, so the replace arm
            # degenerates to a PREPEND and the head lands ABOVE the ledger
            # marker. `Action` stays 'written' either way, which is falsifier
            # 6's whole point. An append must land the head at the END.
            $body | Should -Match '(?s)^\s*<!-- phase-containment-ledger-968 -->.*prose that was already here.*brief_dispositions:' `
                -Because 'the head is appended BELOW the existing body, never prepended above it'
        }

        It 'REPLACES an existing head in place instead of stacking a second one' {
            # This is the outcome the flat-head refusal exists to protect: a
            # span-replace that missed would leave the old head's fields below
            # the new one and SILENTLY DOUBLE the ledger's counts on re-persist.
            $script:W968ReadBody = @(
                $script:W968Marker
                ''
                'brief_dispositions:'
                '  convergence_filter_ran: true'
                '  filtered_count: 99'
                '  findings:'
                '    - finding_id: OLD'
                '      disposition: dismiss'
                ''
                '<!-- phase-containment-968 -->'
                'finding_key: brief-review:968:N1'
                '<!-- /phase-containment-968 -->'
            ) -join "`n"

            $r = script:Invoke-W968 -Head $script:W968Canon
            $r.Success | Should -BeTrue
            $r.Action | Should -BeExactly 'replaced'

            $script:W968WrittenBodies.Count | Should -Be 1
            $body = $script:W968WrittenBodies[0]
            ([regex]::Matches($body, '(?m)^brief_dispositions[ \t]*:[ \t]*\r?$')).Count |
                Should -Be 1 -Because 'the old head must be REPLACED, not stacked under a second one'
            $body | Should -Match '(?m)^  filtered_count: 8[ \t]*\r?$' -Because 'the new head landed'
            $body | Should -Not -Match 'filtered_count: 99' -Because 'the whole old head must be gone — a surviving field doubles the counts'
            $body | Should -Not -Match 'finding_id: OLD'
            $body | Should -Match '(?m)^<!-- phase-containment-968 -->' -Because 'content BELOW the head must survive the span-replace'
        }

        It 'POSITIVE CONTROL: this context can observe a write at all' {
            # Without this, every assertion above would read the same against a
            # writer that never called the write helper. Distinct from M2's
            # control, which stubs the read to $null and so can only prove the
            # content guards passed — never that anything was written.
            $script:W968ReadBody = "$script:W968Marker`n`nbody`n"
            $null = script:Invoke-W968 -Head $script:W968Canon
            $script:W968WrittenBodies.Count | Should -Be 1
            $script:W968WrittenBodies[0] | Should -Match 'brief_dispositions:'
        }
    }
}

Describe '#968 AC3: the indentation-idempotency gate is pinned on a shape that distinguishes it' {

    BeforeAll {
        # A body the ROUND-TRIP fixture cannot produce: a conformant brief head
        # ALONGSIDE indented old rows. The existing test at
        # 'an INDENTED corpus is recognised as already-corrected' feeds
        # Convert-BRMLedgerBody its own output, and with the item-8 relabel
        # applied that output has no old rows left — so the widened probes are
        # never exercised and reverting them to column-0 anchors leaves all
        # three of its assertions green.
        function script:New-968MixedBody {
            param(
                [int]$Issue = 939,
                [string]$KeyPrefix = 'brief-review',
                [string]$StageValue = 'brief-review',
                [string]$Indent = '  '
            )
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("<!-- phase-containment-ledger-$Issue -->")
            $lines.Add('')
            $lines.Add('brief_dispositions:')
            $lines.Add('  convergence_filter_ran: true')
            $lines.Add('  filtered_count: 8')
            $lines.Add('  findings:')
            $lines.Add('    - finding_id: N1')
            $lines.Add('      disposition: incorporate')
            $lines.Add('')
            $lines.Add("<!-- phase-containment-$Issue -->")
            $lines.Add("${Indent}finding_key: ${KeyPrefix}:${Issue}:N1")
            $lines.Add("${Indent}introduced_phase: design")
            $lines.Add("${Indent}catchable_phase: plan")
            $lines.Add("${Indent}caught_stage: $StageValue")
            $lines.Add("${Indent}escape_distance: 0")
            $lines.Add("${Indent}severity: medium")
            $lines.Add("${Indent}systemic_fix_type: instruction")
            $lines.Add("${Indent}category: pattern")
            $lines.Add("<!-- /phase-containment-$Issue -->")
            return ($lines -join "`n") + "`n"
        }
    }

    # EACH PROBE MUTATED SEPARATELY. brief-review-migration-core.ps1:230-231
    # are two INDEPENDENT detectors of the same corpus, so a fixture carrying
    # both indented field kinds is caught by either one alone and a single
    # mutation proves nothing about the other. Each case below leaves exactly
    # one probe with anything to detect.

    It 'an indented OLD finding_key beside a conformant head is not already-corrected (pins $hasOldPrefix alone)' {
        # caught_stage is already brief-review here, so $hasOldStage is false
        # and only $hasOldPrefix can open the gate.
        # MUTATION RUN: narrowing :230 to a column-0 anchor makes this body read
        # as already-corrected — Changed $false, Reason 'already-corrected'.
        $body = script:New-968MixedBody -KeyPrefix 'plan-stress-test' -StageValue 'brief-review'
        $r = Convert-BRMLedgerBody -Body $body -Issue 939
        $r.Reason | Should -BeExactly 'corrected' -Because 'the gate must not report an uncorrected row as done'
        $r.Changed | Should -BeTrue
        $r.Body | Should -Match '(?m)^  finding_key: brief-review:939:N1' -Because 'and the row is actually relabelled, indentation preserved'
    }

    It 'an indented OLD caught_stage beside a conformant head is not already-corrected (pins $hasOldStage alone)' {
        # finding_key already carries the new prefix, so $hasOldPrefix is false
        # and only $hasOldStage can open the gate.
        # MUTATION RUN: narrowing :231 to a column-0 anchor makes this body read
        # as already-corrected.
        $body = script:New-968MixedBody -KeyPrefix 'brief-review' -StageValue 'plan-stress-test'
        $r = Convert-BRMLedgerBody -Body $body -Issue 939
        $r.Reason | Should -BeExactly 'corrected'
        $r.Changed | Should -BeTrue
        $r.Body | Should -Match '(?m)^  caught_stage: brief-review[ \t]*\r?$'
    }

    It 'CONTROL: the same body at column 0 is caught either way, widened or not' {
        # RENAMED AND RE-ARGUED after review (finding P-K). This carries no
        # discriminating signal on the unmutated tree and never did: the
        # widened `^[ \t]*` probes match column 0 as well, so this returns
        # 'corrected' under the widened anchors AND under both narrowings.
        # The earlier comment claimed the opposite — that these shapes going
        # green under the narrowed anchors would VOID the two cases above —
        # which is backwards, since that is exactly what happens and is
        # exactly what should happen.
        #
        # Its real job is as the control DURING a mutation run: when a probe
        # is narrowed, the indented cases above go red while this stays green.
        # That contrast separates "the anchor was narrowed" from "the whole
        # transform is broken", which a red-everywhere run could not.
        foreach ($shape in @(
                @{ k = 'plan-stress-test'; s = 'brief-review' }
                @{ k = 'brief-review'; s = 'plan-stress-test' }
            )) {
            $body = script:New-968MixedBody -KeyPrefix $shape.k -StageValue $shape.s -Indent ''
            (Convert-BRMLedgerBody -Body $body -Issue 939).Reason | Should -BeExactly 'corrected'
        }
    }

    Context 'withdraw-path idempotency rests on transform stability, not on the gate' {

        BeforeAll {
            $script:W968Withdrawn = (Convert-BRMLedgerBody `
                    -Body (script:New-ContaminatedForTail -Issue 941 -Rows 27 -Prefix 'M') -Issue 941).Body
        }

        It 'the second pass reports a DIFFERENT mechanism from the relabel path''s' {
            # THIS PINS A DEFECT ON PURPOSE, and says so, per the brief's §5.
            # The withdraw archive strips only the HTML-comment delimiters, so
            # `finding_key: plan-stress-test:` lines survive it inert and
            # $hasOldPrefix stays true FOREVER. The already-corrected fast path
            # is therefore unreachable for #941: its second pass falls all the
            # way through to `Changed = ($new -ne $Body)` and returns
            # 'corrected' with Changed $false. It is byte-stable, so there is
            # no data harm — but idempotency here is carried by the TRANSFORM
            # being stable, not by the gate, and nothing asserted that.
            #
            # IF SOMEONE LATER CLOSES THAT GATE PROPERLY, this assertion is the
            # thing to UPDATE — it is not evidence of a regression.
            #
            # MUTATION RUN: making the archive also neutralise the old-prefix
            # lines flips this to 'already-corrected'.
            $second = Convert-BRMLedgerBody -Body $script:W968Withdrawn -Issue 941
            $second.Reason | Should -BeExactly 'corrected' -Because 'the gate never fires on the withdraw path'
            $second.Changed | Should -BeFalse -Because 'stability of the transform is what makes re-running safe'
            $second.Body | Should -BeExactly $script:W968Withdrawn

            # And the contrast that makes 'corrected' meaningful rather than a
            # bare string: the relabel path reaches the gate on ITS second pass.
            $relabelOnce = (Convert-BRMLedgerBody -Body (script:New-ContaminatedForTail -Issue 939 -Rows 29) -Issue 939).Body
            (Convert-BRMLedgerBody -Body $relabelOnce -Issue 939).Reason | Should -BeExactly 'already-corrected'
        }

        It 'the archive is what keeps the gate open — the old-prefix lines are still in the body' {
            # Names the mechanism directly, so the pin above cannot be read as
            # an arbitrary string assertion.
            $script:W968Withdrawn | Should -Match '(?m)^[ \t]*finding_key[ \t]*:[ \t]*plan-stress-test:'
            (Get-PhaseContainmentBlock -Text $script:W968Withdrawn -Id 941) |
                Should -BeNullOrEmpty -Because 'they survive INERT — no reader can count them'
        }
    }
}

Describe '#968 AC4: unreadable-vs-absent is distinguished at the grain a maintainer reads' {

    BeforeAll {
        # The rendered sentence lives in the ORCHESTRATOR, not the core lib.
        # Dot-sourcing is safe and deliberate: the script gates its top-level
        # execution on $MyInvocation.InvocationName -eq '.'.
        . (Join-Path $script:RepoRoot '.github/scripts/phase-containment-emission-check.ps1')

        function script:Get-968FilterGap {
            param([Parameter(Mandatory)][string]$Head)
            $ledger = script:New-BriefLedger -Head $Head -Rows (script:New-BriefRows -Count 2)
            return Get-EmissionGap -Bodies @((script:New-BriefPlanComment), $ledger) -Id $script:Id -Surface 'brief-review'
        }
    }

    # WHY THE OUTER GRAIN. The only pre-existing test naming
    # 'filter-value-unrecognized' asserts Get-DispositionTally — the INNER
    # tally, which already returned that value before the item-19 fix. What
    # the fix changed is the outer flag split at
    # phase-containment-emission-check-core.ps1:3285-3286 and the ladder rung
    # at :3533, which is the layer that decides which sentence a maintainer is
    # shown. Reverting it left the whole suite green.
    #
    # MUTATION RUN: collapsing 'filter-value-unrecognized' back into
    # $sawBriefFilterUnasserted at :3286 (the PRE-FIX direction — the other
    # direction inverts the expectation and proves nothing).
    #
    # FALSIFIER 5: none of the four rungs ABOVE this one is tripped by these
    # fixtures — no judge head, one head, every disposition in the closed set,
    # and the assertion is never the literal `false`.

    It 'a head whose convergence_filter_ran value is unreadable renders the UNREADABLE outcome' {
        $gap = script:Get-968FilterGap -Head (script:New-BriefHead -FilterRan 'maybe')
        $gap.ParseStatus | Should -BeExactly 'could-not-verify'
        $gap.Reason | Should -BeExactly 'filter-value-unrecognized'

        $line = script:Format-EmissionGapLine -Surface 'brief-review' -Id $script:Id -Gap $gap
        $line | Should -Match 'present but its value is not the literal'
        $line | Should -Match 'the assertion is not absent, it is unreadable'
        $line | Should -Not -Match 'carries no machine-readable' -Because 'that sentence sends the maintainer looking for a line that is right in front of them'
    }

    It 'a head carrying no assertion at all still renders the ABSENT outcome' {
        # The half that must stay GREEN under the mutation. Without it, a
        # mutation that reddened both cases would look like discrimination.
        $gap = script:Get-968FilterGap -Head (script:New-BriefHead -OmitAssertion)
        $gap.ParseStatus | Should -BeExactly 'could-not-verify'
        $gap.Reason | Should -BeExactly 'filter-unasserted'

        $line = script:Format-EmissionGapLine -Surface 'brief-review' -Id $script:Id -Gap $gap
        $line | Should -Match 'carries no machine-readable'
        $line | Should -Not -Match 'it is unreadable'
    }

    It 'the two outcomes are distinguishable from each other in the rendered result' {
        # Stated as its own assertion because "each renders something" and
        # "they render DIFFERENT things" are not the same claim, and it is the
        # second one the item-19 fix is about.
        $unreadable = script:Format-EmissionGapLine -Surface 'brief-review' -Id $script:Id `
            -Gap (script:Get-968FilterGap -Head (script:New-BriefHead -FilterRan 'maybe'))
        $absent = script:Format-EmissionGapLine -Surface 'brief-review' -Id $script:Id `
            -Gap (script:Get-968FilterGap -Head (script:New-BriefHead -OmitAssertion))
        $unreadable | Should -Not -BeExactly $absent
    }

    It 'CONTROL: a canonical head still verifies, so the fixtures are not merely broken' {
        $gap = script:Get-968FilterGap -Head (script:New-BriefHead)
        $gap.ParseStatus | Should -BeExactly 'ok'
        $gap.SustainedCount | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
# Issue #969 — the reason vocabulary's PROSE against the CODE it describes.
#
# Two comments in this instrument were true when written and were not
# re-checked when the code beneath them changed; one of them went stale twice
# inside a single pull request's own fix loop. Correcting the sentences leaves
# that class intact. These are the checks that make the drift fail.
#
# The mutation discipline mirrors U4 above: one induced mutation per CLASS of
# drift, each fed to the helper as source text rather than written to the tree,
# plus positive controls proving the searches can fire at all.
# ---------------------------------------------------------------------------

Describe 'C3: the documented reason contract is pinned against the code (issue #969)' {

    BeforeAll {
        $script:EmissionCorePath = Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1'
        $script:LiveEmissionSrc = Get-Content -Raw -LiteralPath $script:EmissionCorePath
    }

    It 'the LIVE tree has no drift between the documented enum, the returned set, the ladder count and the dispatch arms' {
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $script:LiveEmissionSrc
        $r.DriftDetails -join ' | ' | Should -BeExactly ''
        $r.HasDrift | Should -BeFalse
    }

    It 'the check actually READ both sides (a parse that found nothing would pass the guard above vacuously)' {
        # U4's lesson applied here: "no drift" and "nothing enumerated" are the
        # same observation unless the populations are asserted.
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $script:LiveEmissionSrc
        $r.DocumentedReasons.Count | Should -BeGreaterThan 5 -Because 'the enum that shipped with the defect had five values'
        $r.ReturnedReasons.Count   | Should -Be $r.DocumentedReasons.Count
        $r.LadderBriefOnlyCount    | Should -BeGreaterThan 0
        $r.LadderStatedCount       | Should -Be $r.LadderBriefOnlyCount
        $r.SwitchArms.Count        | Should -BeGreaterThan 0
    }

    It 'BOTH return shapes are enumerated — the closure form carries the three values #969 found undocumented' {
        # Falsifier 2. An enumerator keyed only on the obvious `Reason = '...'`
        # literal finds two of eight values and none of the wrong ones, so it
        # reports a clean SUBSET of what is already documented and its green
        # result establishes nothing.
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $script:LiveEmissionSrc
        foreach ($closureOnly in @('duplicate-head', 'filter-value-unrecognized', 'unknown-disposition-value')) {
            $r.ReturnedReasons   | Should -Contain $closureOnly
            $r.DocumentedReasons | Should -Contain $closureOnly
        }
    }

    # --- one induced mutation per CLASS of drift ----------------------------

    It 'INDUCED (closure-return class): a new closure-shaped reason with no docstring entry is caught and NAMED' {
        # Induced in the shape the code actually uses most, not the shape most
        # convenient to detect.
        $anchor = "if ([string]::IsNullOrWhiteSpace(`$Body)) { return (& `$none 'head-missing') }"
        $script:LiveEmissionSrc.Contains($anchor) | Should -BeTrue -Because 'the mutation anchor must still exist, or this test mutates nothing'
        $mutated = $script:LiveEmissionSrc.Replace($anchor, "$anchor`n    if (`$false) { return (& `$none 'zz-closure-reason') }")
        $mutated | Should -Not -BeExactly $script:LiveEmissionSrc

        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'zz-closure-reason'
        ($r.DriftDetails -join ' ') | Should -Match 'does not document'
    }

    It 'INDUCED (direct-assignment class): a new assignment-shaped reason with no docstring entry is caught and NAMED' {
        $anchor = "    `$none = {"
        $script:LiveEmissionSrc.Contains($anchor) | Should -BeTrue
        $mutated = $script:LiveEmissionSrc.Replace(
            $anchor,
            "    if (`$false) { return [PSCustomObject]@{ Reason = 'zz-direct-reason' } }`n$anchor")
        $mutated | Should -Not -BeExactly $script:LiveEmissionSrc
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'zz-direct-reason'
    }

    It 'INDUCED (opposite-direction class): a documented value the code can no longer return is caught' {
        # Falsifier 3. The defect direction is documented-missing-a-returned-
        # value, and a check written only the other way round would have passed
        # on #969's own tree. Both directions are taken, and each names itself.
        $anchor = "'filter-value-unrecognized' | 'filter-unasserted')"
        $script:LiveEmissionSrc.Contains($anchor) | Should -BeTrue
        $mutated = $script:LiveEmissionSrc.Replace($anchor, "'filter-value-unrecognized' | 'filter-unasserted' | 'zz-never-returned')")
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'zz-never-returned'
        ($r.DriftDetails -join ' ') | Should -Match 'can no longer return'
    }

    It 'INDUCED (unreadable-prose class): a docstring the parser cannot read FAILS, it does not go quietly green' {
        # Falsifier 4, and this issue's own defect one level up: a rewrap or a
        # field rename must never turn "could not check" into "nothing to
        # check". The file's own precedent is the helper that reports drift
        # when the set it needs cannot be read at all.
        $mutated = $script:LiveEmissionSrc.Replace("and Reason ('ok'", "and Reason: 'ok'")
        $mutated | Should -Not -BeExactly $script:LiveEmissionSrc
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'could not be read'
        $r.DocumentedReasons.Count | Should -Be 0
    }

    It 'INDUCED (ladder-branch class): a seventh brief-only branch with the comment left at six is caught' {
        # Falsifier 5: one side is COUNTED from the ladder, never asserted
        # against a constant this test authored.
        $anchor = "    elseif (`$sawBriefFilterUnasserted) {"
        $script:LiveEmissionSrc.Contains($anchor) | Should -BeTrue
        $mutated = $script:LiveEmissionSrc.Replace(
            $anchor,
            "    elseif (`$sawBriefZzNewBranch) {`n        'zz-ladder-reason'`n    }`n$anchor")
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        $r.LadderBriefOnlyCount | Should -Be ($r.LadderStatedCount + 1)
        ($r.DriftDetails -join ' ') | Should -Match 'maintenance comment states'
    }

    It 'INDUCED (unreadable-count class): dropping the quantity from the maintenance comment FAILS' {
        # C2 permits replacing the quantity with guidance carrying no driftable
        # number — but not silently, and not while this check is what enforces
        # it. Shedding the count must never read as compliance.
        $mutated = $script:LiveEmissionSrc.Replace('six brief-review-only reasons', 'brief-review-only reasons')
        $mutated | Should -Not -BeExactly $script:LiveEmissionSrc
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'found 0'
    }

    It 'INDUCED (duplicated-claim class): a second count claim anywhere in the file is caught' {
        $mutated = $script:LiveEmissionSrc + "`n# Note: there are four brief-review-only reasons.`n"
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'found 2'
    }

    It 'INDUCED (absorbing-default class): a reason with no dispatch arm is caught, because the default reports it as a CORRUPT HEAD' {
        # Falsifier 11. Prose-versus-code checks are structurally blind to
        # this: a ninth reason added without a switch arm is documented,
        # ladder-counted, and still misdirects the maintainer to diagnose
        # corruption that is not there.
        $mutated = $script:LiveEmissionSrc -replace '(?m)^\s*''duplicate-head''\s*\{[^}]*\}\s*\r?$', ''
        $mutated | Should -Not -BeExactly $script:LiveEmissionSrc
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'no explicit dispatch arm'
        ($r.DriftDetails -join ' ') | Should -Match 'duplicate-head'
    }

    It 'INDUCED (missing-function class): a renamed parser FAILS rather than reporting a clean empty check' {
        $mutated = $script:LiveEmissionSrc.Replace('function script:Get-BriefReviewSustainedCountInternal', 'function script:Get-BriefReviewSustainedCountRenamed')
        $mutated | Should -Not -BeExactly $script:LiveEmissionSrc
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source $mutated
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'could not be located'
    }

    It 'POSITIVE CONTROL: an empty source fails every leg rather than passing all of them' {
        # The single observation separating "this helper checks things" from
        # "this helper returns clean for anything it does not understand".
        $r = Get-PhaseContainmentReasonContractDriftStatus -Source ''
        $r.HasDrift | Should -BeTrue
        $r.DriftDetails.Count | Should -BeGreaterThan 2
    }
}

# ---------------------------------------------------------------------------
# C4 — the vetoed verdict itself says which adjudication standards produced
# its critical/high counts, and no verdict changes.
# ---------------------------------------------------------------------------

Describe 'C4: the veto''s counts are attributable from the verdict line (issue #969)' {

    BeforeAll {
        function script:New-969Row {
            param([string]$Stage, [string]$Severity = 'medium', [int]$Distance = 0, [string]$Key = 'x')
            return @{
                finding_key       = "${Stage}:969:$Key"
                introduced_phase  = 'design'
                catchable_phase   = 'plan'
                caught_stage      = $Stage
                escape_distance   = $Distance
                severity          = $Severity
                systemic_fix_type = 'instruction'
                category          = 'pattern'
                apparatus_meta    = $false
            }
        }
        function script:Get-969Render {
            param($Entries)
            $rollup = Get-PhaseContainmentRollup -Entries $Entries -WindowLabel '90d'
            return (Format-PhaseContainmentReport -Context @{
                    Rollup            = $rollup
                    Source            = 'rest'
                    Truncated         = $false
                    WindowDays        = 90
                    FetchedAt         = ([datetime]'2026-08-01T00:00:00Z')
                    InvalidEntryCount = 0
                }) -join "`n"
        }
        function script:Get-969VetoLine {
            param([string]$Text)
            return (@($Text -split "`n" | Where-Object { $_ -match 'Relaxation signal:\s+NOT ELIGIBLE \(\d+ critical' }) -join ' || ')
        }

        # THE DISCRIMINATOR. Both corpora hold identical per-standard
        # populations (plan-stress-test n=5, brief-review n=1), identical
        # escape distances, and the same totals (1 critical, 0 high). They
        # differ in ONE variable: which standard the critical sits under.
        #
        # This construction is the point. A pair differing in anything else —
        # a row moved between standards, say — changes the headline
        # denominator, the exclusion note and the partition block at baseline,
        # so "the renders differ" could not have come out negative and a run
        # that changed nothing would produce it.
        $script:CorpusHeadline = @(
            (script:New-969Row -Stage 'plan-stress-test' -Severity 'critical' -Key 'A1'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'A2'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'A3'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'A4'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'A5'),
            (script:New-969Row -Stage 'brief-review'     -Key 'A6')
        )
        $script:CorpusExcluded = @(
            (script:New-969Row -Stage 'plan-stress-test' -Key 'B1'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'B2'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'B3'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'B4'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'B5'),
            (script:New-969Row -Stage 'brief-review' -Severity 'critical' -Key 'B6')
        )
        $script:RenderHeadline = script:Get-969Render $script:CorpusHeadline
        $script:RenderExcluded = script:Get-969Render $script:CorpusExcluded
    }

    It 'the two corpora really do hold identical per-standard populations and totals (or the comparison below proves nothing)' {
        $armH = (Get-PhaseContainmentRollup -Entries $script:CorpusHeadline).Stages['plan-stress-test']
        $armE = (Get-PhaseContainmentRollup -Entries $script:CorpusExcluded).Stages['plan-stress-test']
        $armH.N                    | Should -Be $armE.N
        $armH.NAllStandards        | Should -Be $armE.NAllStandards
        $armH.CriticalFindingCount | Should -Be $armE.CriticalFindingCount
        $armH.HighFindingCount     | Should -Be $armE.HighFindingCount
        $armH.AdjudicationPartition['brief-review'].N     | Should -Be $armE.AdjudicationPartition['brief-review'].N
        $armH.AdjudicationPartition['plan-stress-test'].N | Should -Be $armE.AdjudicationPartition['plan-stress-test'].N
        $armH.RelaxationEligible   | Should -Be $armE.RelaxationEligible
    }

    It 'THE COUNT-REPORTING TEXT DIFFERS when only the critical row''s standard differs' {
        script:Get-969VetoLine $script:RenderHeadline | Should -Not -BeExactly (script:Get-969VetoLine $script:RenderExcluded)
        script:Get-969VetoLine $script:RenderHeadline | Should -Match 'of which: plan-stress-test 1 critical'
        script:Get-969VetoLine $script:RenderExcluded | Should -Match 'of which: brief-review 1 critical'
    }

    It 'the attribution survives on a sub-arm whose RATES are withheld (falsifier 9 — a count is not a rate)' {
        # brief-review n=1 is below the sufficiency floor, so its rates are
        # withheld. Extending that suppression to severity would make
        # attribution silent on precisely the single-row shape that produced
        # this issue.
        $script:RenderExcluded | Should -Match 'brief-review: n=1 — WITHHELD'
        script:Get-969VetoLine $script:RenderExcluded | Should -Match 'brief-review 1 critical'
    }

    It 'EVERY contributing standard is named, not just one (falsifier 8)' {
        $mixed = @(
            (script:New-969Row -Stage 'plan-stress-test' -Severity 'critical' -Key 'M1'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'M2'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'M3'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'M4'),
            (script:New-969Row -Stage 'plan-stress-test' -Key 'M5'),
            (script:New-969Row -Stage 'brief-review' -Severity 'high' -Key 'M6')
        )
        $line = script:Get-969VetoLine (script:Get-969Render $mixed)
        $line | Should -Match 'NOT ELIGIBLE \(1 critical, 1 high severity finding\(s\) in window\)'
        $line | Should -Match 'plan-stress-test 1 critical'
        $line | Should -Match 'brief-review 1 high'
    }

    It 'the PINNED span of the veto line is byte-identical — the attribution is appended after the closing parenthesis' {
        # Falsifier 12. The lawful way to add information to a pinned line is
        # to leave the pinned span untouched, not to widen the line and then
        # relax the assertions until they pass — which retires the check while
        # the suite reports green.
        $script:RenderExcluded | Should -BeLike '*Relaxation signal:  NOT ELIGIBLE (1 critical, 0 high severity finding(s) in window)*'
        # And the phrasing the negative pin forbids is not reintroduced.
        $script:RenderExcluded.Contains('critical severity finding in window') | Should -BeFalse
    }

    It 'an ELIGIBLE window is untouched: no attribution clause, and the verdict does not flip' {
        $clean = @(1..5 | ForEach-Object { script:New-969Row -Stage 'plan-stress-test' -Key "E$_" })
        $text = script:Get-969Render $clean
        $text | Should -Match 'Relaxation signal:  ELIGIBLE \(escape_rate ~0, no critical/high findings\)'
        $text | Should -Not -Match 'of which:'
    }

    It 'FAIL LOUD: a stage carrying counts but no partition says so instead of rendering an unattributed count as though it were attributed' {
        $orphan = [PSCustomObject]@{
            CriticalFindingCount  = 2
            HighFindingCount      = 0
            AdjudicationPartition = $null
        }
        Get-PhaseContainmentSeverityAttributionText -Stage $orphan | Should -Match 'not attributable'
    }

    It 'FAIL LOUD: sub-counts that do not sum to the counts they annotate are reported, not silently rendered' {
        # The two numbers are computed over the same population, so a mismatch
        # means one of them was re-scoped — the exact class of change this
        # issue exists to make visible.
        $skewed = [PSCustomObject]@{
            CriticalFindingCount  = 3
            HighFindingCount      = 0
            AdjudicationPartition = @{
                'brief-review' = [PSCustomObject]@{ CriticalFindingCount = 1; HighFindingCount = 0 }
            }
        }
        Get-PhaseContainmentSeverityAttributionText -Stage $skewed | Should -Match 'ATTRIBUTION INCOMPLETE'
    }

    It 'nothing to attribute yields no clause at all' {
        $none = [PSCustomObject]@{
            CriticalFindingCount  = 0
            HighFindingCount      = 0
            AdjudicationPartition = @{}
        }
        Get-PhaseContainmentSeverityAttributionText -Stage $none | Should -BeExactly ''
    }
}
