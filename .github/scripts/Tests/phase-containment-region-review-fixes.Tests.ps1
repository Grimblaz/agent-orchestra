#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Regression pins for the PR #1006 adversarial review of issue #944.
#
# WHY A SEPARATE SUITE. The 34 findings that review produced share one shape:
# the remedy for a silent-measurement defect reproduced that defect inside
# itself, four separate times. Every test below fails against the reviewed
# revision and passes against the fix, so each one is a pin on a defect that
# actually shipped rather than a restatement of intent. The finding id is on
# each test because the ledger entry is where the reasoning lives.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-region-guard-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1')

    # The repair script's transform functions, lifted by AST so the file's own
    # body (which fetches and PATCHes) never runs.
    $repairSrc = [System.IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot '.github/scripts/repair-phase-containment-regions.ps1'),
        [System.Text.Encoding]::UTF8)
    $repairAst = [System.Management.Automation.Language.Parser]::ParseInput($repairSrc, [ref]$null, [ref]$null)
    foreach ($fn in $repairAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        if ($fn.Name -in @('Split-RegionIntoEntries', 'Set-EntryFindingKey', 'Repair-Body')) {
            . ([scriptblock]::Create($fn.Extent.Text))
        }
    }

    $script:Head = '<' + '!-- phase-containment-'
}

Describe 'M1 — the reader has the entry floor the guard always had' {

    It 'does not report a prose mention of a marker head as a lost region' {
        # The guard suite's own passing false-positive fixture, fed to the
        # reader. Before the fix this returned skipped=1 regions=1 and rendered
        # "1 region present and unreadable, carrying 0 entries" -- a
        # self-contradiction that flipped a clean surface to could-not-verify.
        $prose = 'The region opened with `' + $script:Head + '937` on its own line and was never closed with the self-closed form.'
        $skipped = 0; $unreadable = 0; $regions = 0
        $null = Get-PhaseContainmentBlock -Text $prose -Id '937' `
            -SkippedCount ([ref]$skipped) -UnreadableEntryCount ([ref]$unreadable) -MalformedRegionCount ([ref]$regions) `
            -WarningAction SilentlyContinue

        $regions | Should -Be 0
        $skipped | Should -Be 0
    }

    It 'agrees with the guard on the same input, in both directions' {
        # The two scanners answer the same question; a divergence here is what
        # the review found. Checked on a prose body AND a real region so the
        # agreement is not vacuously "both silent about everything".
        $prose = 'Discussion of ' + $script:Head + '600 and why it never matched.'
        $region = $script:Head + "600`nfinding_key: code-review:x:1`ncaught_stage: code-review`n-->"

        foreach ($case in @(@{ text = $prose; expect = 0 }, @{ text = $region; expect = 1 })) {
            $regions = 0
            $null = Get-PhaseContainmentBlock -Text $case.text -Id '600' `
                -MalformedRegionCount ([ref]$regions) -WarningAction SilentlyContinue
            $guardCount = (Find-MalformedPhaseContainmentRegion -Body $case.text).Count

            $regions | Should -Be $case.expect
            $guardCount | Should -Be $case.expect
        }
    }
}

Describe 'M5 — a matched-but-unclosed block is not diagnosed as never-matched' {

    It 'keeps the #772 unclosed case out of the block-unreadable reason' {
        $body = @'
<!-- judge-rulings pr=500 -->
```yaml
rulings:
  - finding_id: M1
    judge_ruling: sustained
```
'@ + "`n" + $script:Head + "500 -->`nfinding_key: code-review:gh-1`nseverity: low"

        $gap = Get-EmissionGap -Bodies @($body) -Id 500 -Surface 'code-review' -WarningAction SilentlyContinue
        $gap.Reason | Should -Not -Be 'block-unreadable' -Because 'its open tag IS the self-closed form and DID match; the rendered sentence for block-unreadable says the opposite, which would send a maintainer to inspect a head that is correct.'
    }

    It 'still reaches block-unreadable for a genuinely never-matched head' {
        $body = @'
<!-- judge-rulings pr=501 -->
```yaml
rulings:
  - finding_id: M1
    judge_ruling: sustained
```
'@ + "`n" + $script:Head + "501`nfinding_key: code-review:gh-1`nseverity: low`n-->"

        $gap = Get-EmissionGap -Bodies @($body) -Id 501 -Surface 'code-review' -WarningAction SilentlyContinue
        $gap.Reason | Should -Be 'block-unreadable'
        $gap.UnreadableEntryCount | Should -Be 1
    }

    It 'exposes the never-matched count separately from the general skip count' {
        $unclosed = $script:Head + "502 -->`nfinding_key: code-review:gh-1"
        $skipped = 0; $unmatched = 0
        $null = Get-PhaseContainmentBlock -Text $unclosed -Id '502' `
            -SkippedCount ([ref]$skipped) -UnmatchedOpenTagCount ([ref]$unmatched) -WarningAction SilentlyContinue

        $skipped | Should -Be 1 -Because 'the block is still dropped and still counted as a drop'
        $unmatched | Should -Be 0 -Because 'its open tag matched; only the close tag is missing'
    }
}

Describe 'M8 — a skipped span is bounded, and counted once' {

    It 'does not swallow the rest of the document on the unclosed-final path' {
        # One unclosed block carrying 1 entry, then a malformed region carrying
        # 3. Truth: 4 entries across 2 regions. The reviewed revision handed the
        # whole tail to the counter and reported 6, double-counting the region
        # while shadowing the unclosed block's own entry.
        $body = $script:Head + "700 -->`nfinding_key: code-review:a:1`nseverity: low`n-->`n`n" +
                $script:Head + "700`n- finding_key: code-review:b:1`n- finding_key: code-review:b:2`n- finding_key: code-review:b:3`n-->"

        $unreadable = 0; $regions = 0
        $null = Get-PhaseContainmentBlock -Text $body -Id '700' `
            -UnreadableEntryCount ([ref]$unreadable) -MalformedRegionCount ([ref]$regions) `
            -WarningAction SilentlyContinue

        $regions | Should -Be 2
        $unreadable | Should -Be 4 -Because 'UnreadableEntryCount is the number AC3 pins; double-counting it is the defect this work exists to remove, reproduced by the remedy.'
    }
}

Describe 'M10 — a head immediately followed by the terminator is not silently skipped' {

    It 'is seen by the reader' {
        # One missing space. The hyphen was in the id-boundary exclusion class,
        # so both scanners treated it as a different id and skipped it, while
        # the pairing loop could not match it either: total silence.
        $body = $script:Head + "800--`u{003E}`nfinding_key: code-review:a:1`nseverity: low"
        $regions = 0
        $null = Get-PhaseContainmentBlock -Text $body -Id '800' `
            -MalformedRegionCount ([ref]$regions) -WarningAction SilentlyContinue
        $regions | Should -BeGreaterThan 0
    }

    It 'is seen by the guard' {
        $body = $script:Head + "800--`u{003E}`nfinding_key: code-review:a:1`nseverity: low"
        (Find-MalformedPhaseContainmentRegion -Body $body).Count | Should -BeGreaterThan 0
    }

    It 'still treats a hyphen that continues an id as part of the id' {
        # The boundary rule must not swing the other way: scanning for '94'
        # must not claim a neighbouring 944 region.
        $body = $script:Head + "944 -->`nfinding_key: code-review:gh-1`n<!-- /phase-containment-944 -->"
        $regions = 0
        $null = Get-PhaseContainmentBlock -Text $body -Id '94' `
            -MalformedRegionCount ([ref]$regions) -WarningAction SilentlyContinue
        $regions | Should -Be 0
    }
}

Describe 'M14 — the entry counter does not assume field order or ignore scalars' {

    It 'counts a sequence whose items lead with an unlisted field' {
        # The reviewed revision required the item's FIRST field to be one of
        # twelve names -- a field-ordering assumption nothing enforces -- and
        # reported 1 where the truth was 3. That is the undercount direction
        # this counter exists to eliminate.
        $region = "- disposition: sustained`n  finding_key: a:1`n" +
                  "- disposition: sustained`n  finding_key: a:2`n" +
                  "- disposition: sustained`n  finding_key: a:3"
        $body = $script:Head + "900`n$region`n-->"
        $unreadable = 0
        $null = Get-PhaseContainmentBlock -Text $body -Id '900' `
            -UnreadableEntryCount ([ref]$unreadable) -WarningAction SilentlyContinue
        $unreadable | Should -Be 3
    }

    It 'does not count bullets quoted inside a block scalar' {
        $region = "finding_key: a:1`nrationale: |`n  the judge listed:`n  - severity: high`n  - severity: low"
        $body = $script:Head + "901`n$region`n-->"
        $unreadable = 0
        $null = Get-PhaseContainmentBlock -Text $body -Id '901' `
            -UnreadableEntryCount ([ref]$unreadable) -WarningAction SilentlyContinue
        $unreadable | Should -Be 1
    }

    It 'does not count a nested sub-list as separate entries' {
        $region = "finding_key: a:1`nrelated:`n  - category: pattern`n  - category: script-automation"
        $body = $script:Head + "902`n$region`n-->"
        $unreadable = 0
        $null = Get-PhaseContainmentBlock -Text $body -Id '902' `
            -UnreadableEntryCount ([ref]$unreadable) -WarningAction SilentlyContinue
        $unreadable | Should -Be 1
    }
}

Describe 'M2 / M26 / M34 — the advisory is inert, and says what it means' {

    BeforeAll {
        $script:Findings = Find-MalformedPhaseContainmentRegion -Body (
            $script:Head + "123`n- finding_key: code-review:a:1`n- finding_key: code-review:a:2`n-->")
        $script:Report = Format-MalformedRegionReport -Findings $script:Findings -SourceLabel 'comment 99 on #123'
    }

    It 'carries no marker head any reader would treat as a lost region' {
        # M2: the reviewed revision wrote a literal id into its exemplar, so
        # posting the advisory made the thread's own surface unreadable.
        # Probed across ids, because the defect was id-specific.
        (Find-MalformedPhaseContainmentRegion -Body $script:Report).Count | Should -Be 0
        foreach ($probe in @('123', '944', '1006')) {
            $skipped = 0; $regions = 0
            $null = Get-PhaseContainmentBlock -Text $script:Report -Id $probe `
                -SkippedCount ([ref]$skipped) -MalformedRegionCount ([ref]$regions) -WarningAction SilentlyContinue
            $regions | Should -Be 0 -Because "an advisory that poisons issue #$probe reproduces the class it reports"
            $skipped | Should -Be 0
        }
    }

    It 'renders its inline code rather than eating the backticks' {
        # M26: in a double-quoted PowerShell string the backtick is the escape
        # character, so the intended rendering vanished and the suite's
        # -Match assertion could not see it.
        $script:Report | Should -Match '`phase-containment-123`'
    }

    It 'agrees with itself on number' {
        # M34: the pluralizer varied the noun but not the verb.
        $script:Report | Should -Match '1 region here opens with'
        $script:Report | Should -Match '2 ledger entries'
    }

    It 'shows the malformed shape across lines, not as a well-formed one-liner' {
        # M34: the single-line exemplar was a complete, valid HTML comment --
        # so the one example a maintainer copies did not show the defect.
        $wrongLine = ($script:Report -split "`n" | Where-Object { $_ -match 'wrong:' })
        $wrongLine | Should -Not -BeNullOrEmpty
        $wrongLine | Should -Not -Match '-->' -Because 'a terminator on the same line as the head makes the exemplar well-formed'
    }
}

Describe 'M9 / M12 — the repair transform keeps what it was handed' {

    It 'does not truncate a region at a terminator quoted inside a block scalar' {
        # M9: the reviewed revision took the first terminator after the head,
        # spilling the scalar outside the block and injecting a close tag
        # mid-sentence -- while all four preflights reported OK.
        $body = $script:Head + "910`nfinding_key: code-review:a:1`nrationale: |`n  the judge wrote the head then`n  --> which ended the comment`n  and this is the rest`nseverity: high`n-->"
        $repaired = Repair-Body -Body $body -Id '910' -KeyOverrides $null

        $repaired.EntriesWritten | Should -Be 1

        # ASSERTED THROUGH THE READER, NOT AGAINST THE RAW STRING. An earlier
        # version of this test checked that the text appeared anywhere in the
        # repaired body — which the BROKEN transform also satisfied, because
        # truncating at the scalar's terminator leaves the remainder sitting as
        # prose outside the block it should be inside. A test that a defect
        # passes is not a test. What the criterion actually claims is that the
        # fields are still IN the entry, so the entry is what gets read.
        $blocks = Get-PhaseContainmentBlock -Text $repaired.Body -Id '910' -WarningAction SilentlyContinue
        @($blocks).Count | Should -Be 1
        $parsed = ConvertFrom-PhaseContainmentYaml -Yaml @($blocks)[0]
        $parsed['severity'] | Should -Be 'high' -Because 'a field after the block scalar must survive inside the entry, not be spilled below it'
        @($blocks)[0] | Should -Match 'and this is the rest'
        $repaired.Body | Should -Not -Match '(?m)^\s*-->\s*$' -Because 'an orphan terminator left behind is the signature of a mid-scalar truncation'
    }

    It 'keeps fields that appear before the first sequence item' {
        # M12(a): `appended_at` is the rolling-window dedup recency key, and it
        # is not a required field -- so dropping it passed schema validation.
        $entries = Split-RegionIntoEntries -Content "appended_at: 2026-08-04T00:00:00Z`n- finding_key: a:1`n  severity: high"
        (($entries -join "`n")) | Should -Match 'appended_at'
    }

    It 'does not chop characters off an under-indented continuation line' {
        # M12(b): the de-indent guarded on LENGTH, not indentation, turning
        # `severity` into `everity`.
        $entries = Split-RegionIntoEntries -Content "- finding_key: a:1`nseverity: high`ncategory: pattern"
        ($entries -join "`n") | Should -Match '(?m)^severity: high$'
        # Line-anchored: 'everity' is a substring of the CORRECT output, so an
        # unanchored negative assertion fails against a passing fix.
        ($entries -join "`n") | Should -Not -Match '(?m)^everity: high$'
    }

    It 'does not let a bullet quoted in a block scalar displace the real entry' {
        # M12(c): the decoy replaced the real entry entirely.
        $entries = Split-RegionIntoEntries -Content "finding_key: code-review:real:1`nseverity: high`nrationale: |`n  the judge listed:`n  - finding_key: decoy:1`n    severity: low"
        ($entries -join "`n") | Should -Match 'code-review:real:1'
    }
}
