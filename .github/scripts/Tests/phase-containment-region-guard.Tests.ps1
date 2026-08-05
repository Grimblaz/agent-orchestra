#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Issue #944 — the unattended guard.
#
# THE FALSE-POSITIVE DIRECTION IS TESTED AGAINST REAL TEXT, NOT A FIXTURE.
# A detector exercised only against an example authored to match its own
# pattern proves nothing. The bounding tests below feed it this repository's
# ACTUAL prose about the malformed shape — the brief, the skills' worked
# examples, the design docs, and this suite's own sibling — because those are
# the documents that would light it up if the rules were syntactic.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-region-guard-core.ps1')
}

Describe 'Find-MalformedPhaseContainmentRegion — the miss direction' {

    It 'reports a newly hand-authored region and names its entry count' {
        $body = @'
Post-fix judgment, all findings sustained.

<!-- phase-containment-1234
finding_key: code-review:1234:x:M1
introduced_phase: implementation
catchable_phase: implementation
caught_stage: code-review
escape_distance: 0
severity: high
systemic_fix_type: none
category: pattern
apparatus_meta: false
-->
'@
        $findings = Find-MalformedPhaseContainmentRegion -Body $body
        $findings.Count | Should -Be 1
        $findings[0].Id | Should -Be '1234'
        $findings[0].EntryCount | Should -Be 1
    }

    It 'counts every entry in a multi-entry sequence, not just the region' {
        # The shape that cost PR #937 seven entries. A guard reporting "1
        # region" understates the loss by the same factor the live advisory
        # did when it said missing=3.
        $body = "<!-- phase-containment-1234`n" +
                "- finding_key: code-review:a:1`n  severity: high`n" +
                "- finding_key: code-review:a:2`n  severity: low`n" +
                "- finding_key: code-review:a:3`n  severity: low`n-->"
        $findings = Find-MalformedPhaseContainmentRegion -Body $body
        $findings.Count | Should -Be 1
        $findings[0].EntryCount | Should -Be 3
    }

    It 'reports a region inside a fenced code block' {
        # PR #810's two real lost regions sit inside ```yaml fences. A
        # fence-based exemption would be a blind spot exactly where a real
        # emission already went missing once.
        $body = "``````yaml`n<!-- phase-containment-810`nfinding_key: code-review:x:1`ncaught_stage: code-review`n-->`n``````"
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 1
    }

    It 'reports several distinct regions in one body' {
        $one = "<!-- phase-containment-471`nfinding_key: plan-stress-test:471:x:M1`n-->"
        $two = "<!-- phase-containment-471`nfinding_key: plan-stress-test:471:x:M2`n-->"
        $findings = Find-MalformedPhaseContainmentRegion -Body "$one`n`n$two"
        $findings.Count | Should -Be 2
    }
}

Describe 'Find-MalformedPhaseContainmentRegion — the false-positive direction' {

    It 'stays silent on a well-formed paired block' {
        $body = "<!-- phase-containment-500 -->`nfinding_key: code-review:gh-1`n<!-- /phase-containment-500 -->"
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 0
    }

    It 'stays silent on a placeholder-id template' {
        # How this shape gets DOCUMENTED. No reader would ever match a
        # non-numeric id, so it cannot be a lost emission.
        $body = "<!-- phase-containment-{ID}`nfinding_key: code-review:...`n-->"
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 0
    }

    It 'stays silent on a marker head followed by prose rather than entries' {
        $body = 'The region opened with `<!-- phase-containment-937` on its own line and was never closed with the self-closed form.'
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 0
    }

    It 'stays silent on a marker head quoted inside a YAML block scalar' {
        $body = @'
disposition_rationale: |
  The judge wrote it as
  <!-- phase-containment-600
  finding_key: code-review:x:1
  caught_stage: code-review
  ...which never matched.
next_field: value
'@
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 0
    }

    It 'stays silent on the ledger sentinel family' {
        $body = "<!-- phase-containment-ledger-944 -->`nbrief_dispositions:`n  findings: []"
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 0
    }

    It 'does not fire on this repository''s own prose about the malformed shape' {
        # THE BOUNDING TEST THAT MATTERS, AND ITS OWN POSITIVE CONTROL.
        #
        # Every document here discusses the malformed shape at length -- the
        # design docs, the skills' worked examples, the repair script, the
        # filing and brief quoted into issue bodies. If the rules were
        # syntactic rather than semantic, this repository would be the guard's
        # largest single source of noise.
        #
        # The suite directory is scanned SEPARATELY rather than exempted. The
        # sibling suite embeds regions transcribed verbatim from the live
        # comments on PR #937 and issue #471, because a fixture the test
        # invented proves nothing about the corpus. Those are not prose ABOUT
        # the shape -- they ARE the shape, deliberately, and a content scanner
        # firing on them is behaving correctly. Splitting the population lets
        # the negative assertion stay absolute where it matters while the
        # positive one proves the scan is reaching real shapes at all: an
        # exemption list would have made both halves silently weaker.
        #
        # (Repository files are not the guard's production population -- the
        # workflow's trigger is the comment event, since every one of the 63
        # lost entries was hand-authored straight into a GitHub comment. This
        # scan is a false-positive PROXY over the largest body of text that
        # discusses the shape, not a claim about what the guard watches.)
        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files) } finally { Pop-Location }
        $tracked.Count | Should -BeGreaterThan 100 -Because 'an empty file list would make this test pass without checking anything.'

        $textExtensions = @('.md', '.ps1', '.yml', '.yaml', '.json', '.txt', '.psd1', '.psm1')
        $suitePrefix = '.github/scripts/Tests/'
        $noisy = [System.Collections.Generic.List[string]]::new()
        $fixtureHits = [System.Collections.Generic.List[string]]::new()
        $scanned = 0
        $withMarkerText = 0
        foreach ($rel in $tracked) {
            if ([System.IO.Path]::GetExtension($rel) -notin $textExtensions) { continue }
            $full = Join-Path $script:RepoRoot $rel
            if (-not (Test-Path -LiteralPath $full)) { continue }
            $content = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
            $scanned++
            if (-not $content.Contains('phase-containment-')) { continue }
            $withMarkerText++
            $hits = Find-MalformedPhaseContainmentRegion -Body $content
            foreach ($h in $hits) {
                $entry = "${rel}:$($h.Line) (id $($h.Id), $($h.EntryCount) entry/entries)"
                if ($rel.Replace('\', '/').StartsWith($suitePrefix, [System.StringComparison]::Ordinal)) { $fixtureHits.Add($entry) }
                else { $noisy.Add($entry) }
            }
        }

        $scanned | Should -BeGreaterThan 100 -Because 'the scan must actually have read files for the negative result to mean anything.'
        $withMarkerText | Should -BeGreaterThan 10 -Because 'a negative result over files that never mention the marker would be vacuous.'
        $noisy.Count | Should -Be 0 -Because "the guard must not fire on documentation of the very shape it detects. Fired on:`n$($noisy -join "`n")"
        $fixtureHits.Count | Should -BeGreaterThan 0 -Because 'the positive control: the sibling suite carries regions transcribed from the live corpus, and a scan that finds none of them is not reaching real shapes, which would make the negative result above meaningless.'
    }
}

Describe 'Find-MalformedPhaseContainmentRegion — the production population (#1006 M20)' {

    # THE BOUND IS NOW MEASURED WHERE THE GUARD ACTUALLY LOOKS. The repo-file
    # scan above is a proxy over prose; the guard's production population is
    # GitHub comment bodies, and nothing exercised the false-positive direction
    # there. That gap cost a demonstrated production-shaped false positive
    # during review: a maintainer quoting a real region inside a fence, in a
    # comment, drew a hit. The cases below are the comment shapes this defect
    # class generates while it is being discussed.

    It 'stays silent on a comment that discusses the shape in prose and inline code' {
        $body = @'
The region on PR #937 opened with `<!-- phase-containment-937` on its own line
and terminated with a bare `-->`, which is a valid multi-line HTML comment — so
the parser never matched it and nothing warned.
'@
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 0
    }

    It 'stays silent on a comment quoting the placeholder template in a fence' {
        $body = "Write it like this instead:`n`n" + '```text' + "`n<!-- phase-containment-{ID} -->`nfinding_key: code-review:x:1`n<!-- /phase-containment-{ID} -->`n" + '```'
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 0
    }

    It 'stays silent on a comment carrying only well-formed regions' {
        $body = "Judgment below.`n`n<!-- phase-containment-1006 -->`nfinding_key: code-review:1006:x:M1`nseverity: low`n<!-- /phase-containment-1006 -->"
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 0
    }

    It 'stays silent on the guard''s own advisory, at comment scale' {
        # The advisory is itself a comment body, and it is the one body the
        # guard is guaranteed to meet in production.
        $findings = Find-MalformedPhaseContainmentRegion -Body (
            "<!-- phase-containment-1006`n- finding_key: code-review:a:1`n- finding_key: code-review:a:2`n-->")
        $report = Format-MalformedRegionReport -Findings $findings -SourceLabel 'comment 1 on #1006'
        (Find-MalformedPhaseContainmentRegion -Body $report).Count | Should -Be 0
    }

    It 'STILL fires on a real lost region quoted verbatim into a comment' {
        # The honest limit, pinned rather than papered over. A maintainer who
        # pastes a real region into a comment while discussing it DOES draw an
        # advisory: the text is indistinguishable from the emission it quotes,
        # by every rule the guard has. The remedy is the placeholder form the
        # advisory itself teaches, and the idempotency marker bounds the cost
        # to one reply. Recorded here so the next reader knows it was measured,
        # not missed.
        $body = "Here is what PR #937 actually posted:`n`n" + '```yaml' + "`n<!-- phase-containment-937`n- finding_id: M1`n  severity: medium`n-->`n" + '```'
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -Be 1
    }
}

Describe 'Format-MalformedRegionReport' {

    It 'returns nothing to say when there is nothing to say' {
        Format-MalformedRegionReport -Findings @() -SourceLabel 'x' | Should -BeNullOrEmpty
    }

    It 'names the count, the entries, and the documented write path' {
        $findings = Find-MalformedPhaseContainmentRegion -Body (
            "<!-- phase-containment-1234`n- finding_key: code-review:a:1`n- finding_key: code-review:a:2`n-->")
        $report = Format-MalformedRegionReport -Findings $findings -SourceLabel 'comment 99 on #1234'

        $report | Should -Match 'comment 99 on #1234'
        $report | Should -Match '2 ledger entries'
        $report | Should -Match 'persist-phase-ledger\.ps1'
        $report | Should -Match 'phase-containment-1234'
    }
}
