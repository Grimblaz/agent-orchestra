#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Issue #944 — emitted-but-unparseable ledger regions.
#
# WHAT THIS SUITE IS ABOUT. A region written as
#
#     <!-- phase-containment-{ID}
#     ...entries...
#     -->
#
# is a valid multi-line HTML comment. Get-PhaseContainmentBlock's open tag is
# the self-closed `<!-- phase-containment-{ID} -->`, matched by exact ordinal
# IndexOf, so that head never matches — and the parser's malformed-block
# warnings fire only AFTER a match. The result was total silence: not parsed,
# not counted, not warned. Sixty-three entries across seven issues sat
# invisible, thirteen of them critical or high, suppressing the relaxation
# veto on all four review stages at once.
#
# WHY THE FIXTURES BELOW ARE COPIED FROM THE CORPUS. A test that authors a
# malformed block and reads it back demonstrates the reader handles a shape
# the test invented. The two shapes pinned here are transcribed from the live
# comments — PR #937's seven-item sequence and issue #471's single mappings —
# because those are the shapes that actually cost the corpus entries.

BeforeAll {
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'
    . (Join-Path $script:LibRoot 'phase-containment-core.ps1')
    . (Join-Path $script:LibRoot 'phase-containment-rolling-history-core.ps1')
    . (Join-Path $script:LibRoot 'phase-containment-emission-check-core.ps1')

    # Transcribed from https://github.com/Grimblaz/agent-orchestra/issues/937
    # comment 5096544713 — a single malformed-open region carrying a SEVEN-item
    # YAML sequence, followed by a correct close tag. The close tag is why a
    # bare terminator repair is unsafe here: adding ' -->' to the head would
    # make ONE block out of seven entries, parsed last-wins with a null key.
    $script:Real937Region = @'
Some judgment prose above the region.

<!-- phase-containment-937
- finding_id: M1
  category: implementation-clarity
  severity: medium
  introduced_phase: implementation
  catchable_phase: implementation
  caught_stage: code-review
  escape_distance: 0
  apparatus_meta: false
  systemic_fix_type: none
- finding_id: M2
  category: script-automation
  severity: medium
  introduced_phase: implementation
  catchable_phase: implementation
  caught_stage: code-review
  escape_distance: 0
  apparatus_meta: false
  systemic_fix_type: none
- finding_id: M3
  category: script-automation
  severity: medium
  introduced_phase: implementation
  catchable_phase: implementation
  caught_stage: code-review
  escape_distance: 0
  apparatus_meta: false
  systemic_fix_type: none
- finding_id: M4
  category: script-automation
  severity: medium
  introduced_phase: implementation
  catchable_phase: implementation
  caught_stage: code-review
  escape_distance: 0
  apparatus_meta: false
  systemic_fix_type: none
- finding_id: M5
  category: implementation-clarity
  severity: low
  introduced_phase: implementation
  catchable_phase: implementation
  caught_stage: code-review
  escape_distance: 0
  apparatus_meta: false
  systemic_fix_type: none
- finding_id: M6
  category: documentation-audit
  severity: low
  introduced_phase: implementation
  catchable_phase: implementation
  caught_stage: code-review
  escape_distance: 0
  apparatus_meta: false
  systemic_fix_type: none
- finding_id: M7
  category: pattern
  severity: low
  introduced_phase: implementation
  catchable_phase: implementation
  caught_stage: code-review
  escape_distance: 0
  apparatus_meta: false
  systemic_fix_type: none
-->
<!-- /phase-containment-937 -->
'@

    # Transcribed from issue #471 comment 4837695451 — two of its eleven
    # single-mapping regions, each carrying a lawful finding_key and each
    # terminated by a bare '-->' with no close tag at all.
    $script:Real471Regions = @'
<!-- phase-containment-471
finding_key: plan-stress-test:471:reporting-economy:M1
introduced_phase: plan
catchable_phase: plan
caught_stage: plan-stress-test
escape_distance: 0
severity: high
systemic_fix_type: plan-template
category: implementation-clarity
apparatus_meta: false
-->

<!-- phase-containment-471
finding_key: plan-stress-test:471:reporting-economy:M2
introduced_phase: design
catchable_phase: design
caught_stage: plan-stress-test
escape_distance: 1
severity: high
systemic_fix_type: plan-template
category: script-automation
apparatus_meta: false
-->
'@

    $script:WellFormedBlock = @'
<!-- phase-containment-500 -->
finding_key: code-review:gh-1234
introduced_phase: implementation
catchable_phase: implementation
caught_stage: code-review
escape_distance: 0
severity: low
systemic_fix_type: none
category: pattern
apparatus_meta: false
<!-- /phase-containment-500 -->
'@
}

Describe 'Get-PhaseContainmentBlock — malformed-open regions are reported, not silent (#944 AC1/AC2)' {

    It 'reports PR #937''s real region and counts all SEVEN entries it carries' {
        $skipped = 0; $unreadable = 0; $regions = 0
        $result = Get-PhaseContainmentBlock -Text $script:Real937Region -Id '937' `
            -SkippedCount ([ref]$skipped) `
            -UnreadableEntryCount ([ref]$unreadable) `
            -MalformedRegionCount ([ref]$regions) `
            -WarningAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $regions | Should -Be 1
        $unreadable | Should -Be 7 -Because 'the region carries a seven-item sequence; a region count of 1 is what made the advisory report 3 where 7 were lost.'
        $skipped | Should -Be 1
    }

    It 'reports issue #471''s real single-mapping regions, one entry each' {
        $skipped = 0; $unreadable = 0; $regions = 0
        $result = Get-PhaseContainmentBlock -Text $script:Real471Regions -Id '471' `
            -SkippedCount ([ref]$skipped) `
            -UnreadableEntryCount ([ref]$unreadable) `
            -MalformedRegionCount ([ref]$regions) `
            -WarningAction SilentlyContinue

        $result | Should -BeNullOrEmpty
        $regions | Should -Be 2
        $unreadable | Should -Be 2
    }

    It 'emits a warning naming the region and its entry count' {
        $null = Get-PhaseContainmentBlock -Text $script:Real937Region -Id '937' `
            -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join ' ') | Should -Match 'unreadable phase-containment-937 region'
        ($warnings -join ' ') | Should -Match '7 entry/entries'
    }

    It 'distinguishes a malformed region from a genuinely absent one (AC2)' {
        # THE WHOLE POINT. Before #944 these two inputs produced byte-identical
        # observable results — $null and nothing else — which is how the
        # escape-rate report came to print "none carried a phase-containment
        # block" over bodies carrying sixty-three of them.
        $absentSkipped = 0; $absentUnreadable = 0; $absentRegions = 0
        $absent = Get-PhaseContainmentBlock -Text 'Ordinary PR chatter with no marker at all.' -Id '937' `
            -SkippedCount ([ref]$absentSkipped) `
            -UnreadableEntryCount ([ref]$absentUnreadable) `
            -MalformedRegionCount ([ref]$absentRegions)

        $malformedSkipped = 0; $malformedUnreadable = 0; $malformedRegions = 0
        $malformed = Get-PhaseContainmentBlock -Text $script:Real937Region -Id '937' `
            -SkippedCount ([ref]$malformedSkipped) `
            -UnreadableEntryCount ([ref]$malformedUnreadable) `
            -MalformedRegionCount ([ref]$malformedRegions) `
            -WarningAction SilentlyContinue

        $absent | Should -BeNullOrEmpty
        $malformed | Should -BeNullOrEmpty
        # Same return value; the counters are what tell them apart.
        $absentRegions | Should -Be 0
        $absentUnreadable | Should -Be 0
        $malformedRegions | Should -BeGreaterThan 0
        $malformedUnreadable | Should -BeGreaterThan 0
    }

    It 'returns well-formed blocks AND reports a malformed region in the same body' {
        # PR #937 and #884 are both mixed bodies — 3 parsed beside 7 lost, and
        # 37 parsed beside 3 lost. A fix that only worked on all-or-nothing
        # bodies would have left both understated.
        $mixed = $script:WellFormedBlock + "`n`n" + ($script:Real471Regions -replace '471', '500')
        $skipped = 0; $unreadable = 0; $regions = 0
        $result = Get-PhaseContainmentBlock -Text $mixed -Id '500' `
            -SkippedCount ([ref]$skipped) `
            -UnreadableEntryCount ([ref]$unreadable) `
            -MalformedRegionCount ([ref]$regions) `
            -WarningAction SilentlyContinue

        $result.Count | Should -Be 1
        $result[0] | Should -Match 'code-review:gh-1234'
        $regions | Should -Be 2
        $unreadable | Should -Be 2
    }

    It 'does not report a marker head quoted inside a YAML block scalar' {
        # The #863 M6 forgery class: a `rationale: |` scalar that discusses the
        # marker shape is string data, not a region. Bounding the
        # false-positive direction matters as much as the miss direction — an
        # advisory that cries wolf is one a maintainer learns to skip.
        $text = @'
<!-- some-other-marker-600 -->
disposition_rationale: |
  The judge wrote the region as
  <!-- phase-containment-600
  ...which never matched, and that was the bug.
other_field: value
'@
        $skipped = 0; $unreadable = 0; $regions = 0
        $null = Get-PhaseContainmentBlock -Text $text -Id '600' `
            -SkippedCount ([ref]$skipped) `
            -UnreadableEntryCount ([ref]$unreadable) `
            -MalformedRegionCount ([ref]$regions) `
            -WarningAction SilentlyContinue

        $regions | Should -Be 0
        $unreadable | Should -Be 0
        $skipped | Should -Be 0
    }

    It 'does not report a neighbouring id whose number merely starts with this one' {
        # Scanning for id '94' must not match `phase-containment-944`. Without
        # the boundary check this reports another family's WELL-FORMED region
        # as malformed — a false positive manufactured by string prefixing.
        $text = "<!-- phase-containment-944 -->`nfinding_key: code-review:gh-1`n<!-- /phase-containment-944 -->"
        $skipped = 0; $unreadable = 0; $regions = 0
        $null = Get-PhaseContainmentBlock -Text $text -Id '94' `
            -SkippedCount ([ref]$skipped) `
            -UnreadableEntryCount ([ref]$unreadable) `
            -MalformedRegionCount ([ref]$regions) `
            -WarningAction SilentlyContinue

        $regions | Should -Be 0
        $skipped | Should -Be 0
    }

    It 'does not throw when the new [ref] parameters are omitted (back-compat)' {
        { Get-PhaseContainmentBlock -Text $script:Real937Region -Id '937' -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'reports a fenced region, because the pairing loop reads a fenced tag as structure' {
        # PR #810's two lost regions sit inside ```yaml fences and carry lawful
        # finding_keys. An earlier revision of this fix excluded code spans and
        # went silent on exactly those two. The pairing loop matches by ordinal
        # IndexOf and has never cared about fences, so a WELL-FORMED tag inside
        # a fence is read today — staying silent about a MALFORMED one would
        # reproduce this issue's defect in the half nobody was looking at.
        $text = "``````yaml`n<!-- phase-containment-810`nfinding_key: code-review:x:1`ncaught_stage: code-review`n-->`n``````"
        $unreadable = 0; $regions = 0
        $null = Get-PhaseContainmentBlock -Text $text -Id '810' `
            -UnreadableEntryCount ([ref]$unreadable) `
            -MalformedRegionCount ([ref]$regions) `
            -WarningAction SilentlyContinue

        $regions | Should -Be 1
        $unreadable | Should -Be 1
    }
}

Describe 'Invoke-PhaseContainmentCommentScan inherits the distinction (#944 AC2, caller 1)' {

    It 'surfaces the unreadable entry count and folds the region into InvalidEntryCount' {
        $result = Invoke-PhaseContainmentCommentScan `
            -CommentBodies @($script:Real937Region) -IssueOrPrNumber 937 -Surface 'code-review' `
            -WarningAction SilentlyContinue

        $result.Entries.Count | Should -Be 0
        $result.MalformedRegionCount | Should -Be 1
        $result.UnreadableEntryCount | Should -Be 7
        $result.InvalidEntryCount | Should -BeGreaterThan 0 -Because 'the escape-rate report''s INVALID-EMPTY discrimination keys on this counter; leaving it at zero is what produced the false "none carried a phase-containment block" render.'
    }

    It 'reports zero on a genuinely markerless body' {
        $result = Invoke-PhaseContainmentCommentScan `
            -CommentBodies @('LGTM, nothing to see here.') -IssueOrPrNumber 937 -Surface 'code-review'

        $result.MalformedRegionCount | Should -Be 0
        $result.UnreadableEntryCount | Should -Be 0
        $result.InvalidEntryCount | Should -Be 0
    }
}

Describe 'Get-EmissionGap inherits the distinction (#944 AC2/AC3, caller 2)' {

    BeforeAll {
        # A judge-rulings head so Test-EmissionMarkerPresent lets the body
        # through to the block scan; without one the body is ordinary chatter
        # and contributes nothing by design.
        $script:GapBody = @'
<!-- judge-rulings pr=937 -->
```yaml
rulings:
  - finding_id: M1
    judge_ruling: sustained
  - finding_id: M2
    judge_ruling: sustained
  - finding_id: M3
    judge_ruling: sustained
```
'@ + "`n" + $script:Real937Region
    }

    It 'reports the real unreadable entry count, not an arithmetic difference (AC3)' {
        $gap = Get-EmissionGap -Bodies @($script:GapBody) -Id 937 -Surface 'code-review' -WarningAction SilentlyContinue

        $gap.UnreadableEntryCount | Should -Be 7 -Because 'the live advisory reported missing=3 where seven entries were genuinely present and unreadable.'
        $gap.MalformedRegionCount | Should -Be 1
    }

    It 'refuses to present the counts as a measurement' {
        $gap = Get-EmissionGap -Bodies @($script:GapBody) -Id 937 -Surface 'code-review' -WarningAction SilentlyContinue

        $gap.ParseStatus | Should -Be 'could-not-verify'
        $gap.Reason | Should -Be 'block-unreadable'
    }

    It 'stays clean, and reports zero, when nothing is unreadable' {
        $clean = @'
<!-- judge-rulings pr=500 -->
```yaml
rulings:
  - finding_id: M1
    judge_ruling: sustained
```
'@ + "`n" + $script:WellFormedBlock
        $gap = Get-EmissionGap -Bodies @($clean) -Id 500 -Surface 'code-review' -WarningAction SilentlyContinue

        $gap.UnreadableEntryCount | Should -Be 0
        $gap.MalformedRegionCount | Should -Be 0
        $gap.Reason | Should -Not -Be 'block-unreadable'
    }
}
