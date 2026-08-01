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

    It 'A1(b): the check requires the declaration, so it would NOT have caught an undeclared historical brief' {
        # Recorded as a test rather than only as prose, because D6's original
        # justification claimed the opposite and that claim was reported to the
        # maintainer as verified fact.
        $ledger = script:New-BriefLedger -Head (script:New-BriefHead) -Rows (script:New-BriefRows -Count 2) -Extra $script:JudgeHead
        Test-BriefJudgeHeadContradiction -Bodies @((script:New-BriefPlanComment -Undeclared), $ledger) -Id $script:Id | Should -BeFalse
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
        ($script:PlanArm.AdjudicationPartition['plan-stress-test'].N + $script:PlanArm.AdjudicationPartition['brief-review'].N) | Should -Be $script:PlanArm.N
    }

    It 'each sub-arm computes its OWN rate over its OWN population' {
        # 2 of 6 escapes judge-side, 0 of 7 brief-side. An unpartitioned rate
        # would be 2/13 for both — a number belonging to neither standard.
        [Math]::Round($script:PlanArm.AdjudicationPartition['plan-stress-test'].EscapeRate, 4) | Should -Be ([Math]::Round(2 / 6, 4))
        $script:PlanArm.AdjudicationPartition['brief-review'].EscapeRate | Should -Be 0
        [Math]::Round($script:PlanArm.EscapeRate, 4) | Should -Be ([Math]::Round(2 / 13, 4))
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
