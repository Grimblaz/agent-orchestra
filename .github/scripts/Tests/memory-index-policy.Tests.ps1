#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Regression suite for skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1.

.DESCRIPTION
    The check's whole value is that each axis can FAIL on the defect it names. A one-time
    manual control run cannot hold that property across later edits, so every axis here is
    exercised against a modified copy, never against an expectation.

    Each defect case is paired with the conforming control that isolates it: the case and the
    control differ by exactly the planted defect, so a test that passes because the fixture is
    malformed in some other way fails its control.

    Two fixture shapes: New-Index builds a legacy store (full policy text as the index's own
    header) and New-SplitStore builds a split store (stanza in the index, canonical policy and
    this store's values in a policy file beside it).

    Dates are pinned and -AsOf is passed explicitly wherever staleness is in play, so a
    staleness assertion cannot start passing or failing because time moved.
#>

Describe 'Test-MemoryIndexPolicy' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:Core = Join-Path $script:RepoRoot 'skills/agent-memory-compaction/scripts/lib/memory-index-policy-core.ps1'
        $script:EntryPoint = Join-Path $script:RepoRoot 'skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1'
        $script:Skill = Join-Path $script:RepoRoot 'skills/agent-memory-compaction/SKILL.md'
        $script:PreSupersession = Join-Path $script:RepoRoot 'skills/agent-memory-compaction/templates/policy-pre-supersession.md'
        . $script:Core
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("mip-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

        # The two canonical texts, read the same way the check reads them.
        function script:Read-Region {
            param([string]$Path, [string]$Begin, [string]$End)
            $lines = @([System.IO.File]::ReadAllLines($Path))
            $region = Get-MIPMarkedRegion -Lines $lines -BeginMarker $Begin -EndMarker $End
            if (-not $region.Found) { throw "region $Begin not found in $Path" }
            return @($region.Block)
        }

        $script:CanonicalLines = @(script:Read-Region -Path $script:Skill -Begin '<!-- policy-canonical-begin -->' -End '<!-- policy-canonical-end -->')
        $script:StanzaLines = @(script:Read-Region -Path $script:Skill -Begin '<!-- stanza-canonical-begin -->' -End '<!-- stanza-canonical-end -->')
        $script:LegacyCanonicalLines = @(script:Read-Region -Path $script:PreSupersession -Begin '<!-- policy-canonical-begin -->' -End '<!-- policy-canonical-end -->')

        # Pinned dates. The observation is the one this release records; the two -AsOf values
        # sit either side of the 30-day default bound.
        $script:ObservationDate = '2026-08-06'
        $script:FreshAsOf = [datetime]::ParseExact('2026-08-20', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $script:StaleAsOf = [datetime]::ParseExact('2026-10-06', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        # Derived, never written down: a test that hard-codes the budget is the same defect
        # the shipped text is forbidden to commit - an absolute standing in for a formula.
        $script:ExpectedBudget = [int][Math]::Floor(0.80 * 24978)
        $script:DefaultValues = @(
            'budget_fraction: 0.80',
            'staleness_bound_days: 30',
            "limit_observation: $script:ObservationDate | 24978 | characters | truncation-boundary test (agent-orchestra#1015 review round 3)"
        )

        # Build a LEGACY index file: policy header, a section heading, then the supplied body.
        function script:New-Index {
            param([string[]]$Body, [string[]]$Header = $null, [string]$Name = $null)

            if ($null -eq $Header) { $Header = $script:CanonicalLines }
            if ([string]::IsNullOrEmpty($Name)) { $Name = ([guid]::NewGuid().ToString('N').Substring(0, 10) + '.md') }
            $path = Join-Path $script:Work $Name
            [System.IO.File]::WriteAllLines($path, (@($Header) + @('', '## Entries', '') + $Body))
            return $path
        }

        # Build a SPLIT store: its own directory holding an index carrying the stanza and a
        # policy file carrying the canonical text plus this store's values.
        function script:New-SplitStore {
            param(
                [string[]]$Body,
                [string[]]$Stanza = $null,
                [string[]]$PolicyText = $null,
                [string[]]$Values = $null,
                [switch]$OmitValuesBlock,
                [switch]$OmitPolicyFile,
                [switch]$OmitStanzaMarkers,
                [string]$MarkerPath = 'POLICY.md',
                [string]$PolicyFileName = 'POLICY.md'
            )

            if ($null -eq $Stanza) { $Stanza = $script:StanzaLines }
            if ($null -eq $PolicyText) { $PolicyText = $script:CanonicalLines }
            if ($null -eq $Values) { $Values = $script:DefaultValues }
            if ($null -eq $Body) { $Body = $script:ConformingBody }

            $dir = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $indexLines = if ($OmitStanzaMarkers) { @() } else {
                @("<!-- memory-policy-stanza-begin: $MarkerPath -->") + @($Stanza) + @('<!-- memory-policy-stanza-end -->')
            }
            $indexLines = @($indexLines) + @('', '## Entries', '') + @($Body)
            $indexPath = Join-Path $dir 'MEMORY.md'
            [System.IO.File]::WriteAllLines($indexPath, $indexLines)

            $policyPath = Join-Path $dir $PolicyFileName
            if (-not $OmitPolicyFile) {
                $policyLines = @('# Store policy', '')
                if (-not $OmitValuesBlock) {
                    $policyLines = @($policyLines) + @('<!-- store-values-begin -->') + @($Values) + @('<!-- store-values-end -->', '')
                }
                $policyLines = @($policyLines) + @('<!-- policy-canonical-begin -->') + @($PolicyText) + @('<!-- policy-canonical-end -->')
                [System.IO.File]::WriteAllLines($policyPath, $policyLines)
            }
            return [pscustomobject]@{ IndexPath = $indexPath; PolicyPath = $policyPath; Dir = $dir }
        }

        # Pointer lines of the live store's shape - one subject, a clause of its own, ~160
        # characters - repeated until the index passes the requested size. Nothing but the
        # SIZE axis may fail on the result, which is what makes an over-budget red attributable.
        function script:New-RealisticPointers {
            param([int]$MinimumCharacters)

            $lines = [System.Collections.Generic.List[string]]::new()
            $chars = 0
            $i = 0
            while ($chars -lt $MinimumCharacters) {
                $i++
                $line = "- [lesson $i](reference_lesson_$i.md) - a stale read wins the race on attempt $i and the retry cap silently drops the write, so the tail of that batch never lands at all"
                $lines.Add($line)
                $chars += $line.Length + 1
            }
            return $lines.ToArray()
        }

        # In-process, per the repo's script-safety contract: dot-source the core and call it
        # directly rather than spawning a child shell per test.
        function script:Invoke-Check {
            param([string]$IndexPath, [string]$ReferencePath = $null, [switch]$AsJson, [datetime]$AsOf = $script:FreshAsOf)

            $report = Invoke-MemoryIndexPolicyCheck -IndexPath $IndexPath -PolicyReferencePath $ReferencePath -AsOf $AsOf
            $rendered = Format-MemoryIndexPolicyReport -Report $report -AsJson:$AsJson
            return [pscustomobject]@{ Text = ($rendered | Out-String); Code = $report.ExitCode; Report = $report }
        }

        # A body that conforms: two subjects, each with its own clause.
        $script:ConformingBody = @(
            '- [alpha](reference_alpha_lesson.md) — a stale read wins the race and silently drops the write',
            '- [beta](project_beta_thing.md) — the retry cap is three, not unlimited'
        )
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'the conforming controls' {
        It 'reports a legacy store clean and exits 0' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody)
            $r.Text | Should -Match 'RESULT: clean'
            $r.Code | Should -Be 0
        }

        It 'reports a conforming split store clean, on all four axes' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Text | Should -Match 'RESULT: clean'
            $r.Text | Should -Match 'policy: split - stanza and policy file both match the reference'
            $r.Text | Should -Match "of $($script:ExpectedBudget.ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)) characters"
            $r.Text | Should -Match 'subjects_without_hook: 0'
            $r.Text | Should -Match 'unattributed_shared_notes: 0'
            $r.Report.StoreShape | Should -BeExactly 'split'
            $r.Report.Size.State | Should -BeExactly 'within'
            $r.Code | Should -Be 0
        }
    }

    Context 'policy axis - legacy shape' {
        It 'reports absent when the header is removed' {
            $path = script:New-Index -Body $script:ConformingBody -Header @('# Some other file')
            $r = script:Invoke-Check -IndexPath $path
            $r.Text | Should -Match 'policy: in-index header - absent'
            $r.Code | Should -Be 1
        }

        It 'reports INCOMPLETE for a case-only divergence rather than clean' {
            # Regression: -eq is case-insensitive in PowerShell, so this once reported complete.
            $header = @($script:CanonicalLines)
            $idx = [array]::IndexOf($header, ($header | Where-Object { $_ -match 'COMPACTION POLICY' } | Select-Object -First 1))
            $header[$idx] = $header[$idx].Replace('COMPACTION POLICY', 'compaction policy')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $header)
            $r.Text | Should -Match 'policy: in-index header - present, INCOMPLETE'
            $r.Code | Should -Be 1
        }

        It 'reports a present-but-edited first line as INCOMPLETE with a divergence, not as absent' {
            $header = @($script:CanonicalLines)
            $header[0] = $header[0].Replace('—', '-')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $header)
            $r.Text | Should -Match 'policy: in-index header - present, INCOMPLETE'
            $r.Text | Should -Match 'first divergence at header line'
        }

        It 'does not let text outside the header region answer the presence question' {
            # Regression the rewrite had to design against: the probe once scanned the WHOLE
            # index, so policy prose quoted anywhere in the body flipped the header verdict.
            $body = @($script:CanonicalLines) + @('') + @($script:ConformingBody)
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body -Header @('# Some other file'))
            $r.Text | Should -Match 'policy: in-index header - absent'
            $r.Text | Should -Match 'below its first section heading'
        }

        It 'names a pointer line sitting inside the header region' {
            $header = @($script:CanonicalLines) + @('', '- [gamma](reference_gamma_lesson.md) — a clause')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $header)
            $r.Text | Should -Match 'pointer line sits inside the header region'
            $r.Code | Should -Be 1
        }

        It 'refuses a reference copy whose canonical block carries a section heading' {
            # Regression: both surfaces were once delimited by the same '## ' token, so promoting
            # a heading inside the policy shrank the compared region on both sides at once and
            # still reported complete.
            $ref = Join-Path $script:Work 'ref-with-heading.md'
            $body = @('<!-- policy-canonical-begin -->', '**HEADER**', '', '## Promoted heading', 'text `project_` more',
                '<!-- policy-canonical-end -->', '',
                '<!-- stanza-canonical-begin -->', '**STANZA**', 'more', '<!-- stanza-canonical-end -->')
            [System.IO.File]::WriteAllLines($ref, $body)
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody) -ReferencePath $ref
            $r.Text | Should -Match 'section heading'
            $r.Code | Should -Be 2
        }

        It 'refuses a reference copy with no canonical markers' {
            $ref = Join-Path $script:Work 'ref-no-markers.md'
            [System.IO.File]::WriteAllLines($ref, @('# Nothing here', 'no markers'))
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody) -ReferencePath $ref
            $r.Text | Should -Match 'malformed'
            $r.Code | Should -Be 2
        }

        It 'a stanza-less reference copy refuses a SPLIT store and still judges a LEGACY one' {
            # Both polarities of one deliberate scoping decision. A reference that cannot supply
            # the stanza text cannot judge a split store, and saying so beats comparing against
            # nothing and calling the stanza complete. But demanding it unconditionally would
            # break the preserved pre-supersession copy, which predates the stanza entirely -
            # the no-forced-migration route this release exists to keep open.
            $ref = Join-Path $script:Work 'ref-no-stanza.md'
            [System.IO.File]::WriteAllLines($ref, (@('<!-- policy-canonical-begin -->') + @($script:CanonicalLines) + @('<!-- policy-canonical-end -->')))

            $split = script:Invoke-Check -IndexPath (script:New-SplitStore -Body $script:ConformingBody).IndexPath -ReferencePath $ref
            $split.Text | Should -Match 'canonical stanza'
            $split.Text | Should -Match 'declares the split shape'
            $split.Code | Should -Be 2

            $legacy = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody) -ReferencePath $ref
            $legacy.Text | Should -Match 'RESULT: clean'
            $legacy.Code | Should -Be 0
        }
    }

    Context 'policy axis - split shape' {
        It 'does not read clean when the stanza is absent' {
            $store = script:New-SplitStore -Body $script:ConformingBody -OmitStanzaMarkers
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Text | Should -Match 'policy: in-index header - absent'
            $r.Text | Should -Not -Match 'RESULT: clean'
            $r.Code | Should -Be 1
        }

        It 'does not read clean when the stanza is missing an operative write rule' {
            # The digest is the whole reason the stanza exists: a stanza that dropped R3 would
            # leave a writer composing whole-file writes from a truncated view.
            $stanza = @($script:StanzaLines | Where-Object { $_ -notmatch '^\s*-\s+\*\*R3' })
            $stanza.Count | Should -BeLessThan $script:StanzaLines.Count -Because 'the control must actually remove a rule'
            $store = script:New-SplitStore -Body $script:ConformingBody -Stanza $stanza
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Text | Should -Match 'stanza INCOMPLETE'
            $r.Text | Should -Match 'first divergence at stanza line'
            $r.Code | Should -Be 1
        }

        It 'reports the half-migrated state by name, as a defect and not a refusal' {
            $store = script:New-SplitStore -Body $script:ConformingBody -OmitPolicyFile
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.StoreShape | Should -BeExactly 'split-incomplete'
            $r.Text | Should -Match 'half-migrated'
            $r.Text | Should -Match 'no such file sits beside this index'
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'subjects_without_hook: 0'   # the other axes still report
        }

        It 'refuses - not half-migrated - when the policy file exists and cannot be read' -Skip:(-not $IsWindows) {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $stream = [System.IO.File]::Open($store.PolicyPath, 'Open', 'Read', 'None')
            try { $r = script:Invoke-Check -IndexPath $store.IndexPath } finally { $stream.Dispose() }
            $r.Code | Should -Be 2
            $r.Text | Should -Match "policy file could not be read"
            $r.Text | Should -Match 'not the half-migrated state'
        }

        It 'refuses when the policy file exists but carries no canonical markers' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            [System.IO.File]::WriteAllLines($store.PolicyPath, @('# Store policy', 'no markers here'))
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Code | Should -Be 2
            $r.Text | Should -Match "policy file is malformed"
        }

        It 'refuses a stanza that opens and never closes' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $lines = @([System.IO.File]::ReadAllLines($store.IndexPath)) | Where-Object { $_.Trim() -ne '<!-- memory-policy-stanza-end -->' }
            [System.IO.File]::WriteAllLines($store.IndexPath, $lines)
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'never closed'
            $r.Text | Should -Match 'not read back as a legacy store'
        }

        It 'keeps an adapted store checked against its own kinds after it splits' {
            # Regression the split had to design against: emptying the index header of policy
            # text moves the vocabulary source. A store that renamed its kinds exactly as the
            # adapt-note instructs must not be refused and told to adapt.
            $rename = { param($t) $t -replace '`reference_`', '`lesson_`' -replace '`feedback_`', '`howto_`' -replace '`project_`', '`task_`' -replace '`user_`', '`me_`' }
            $adaptedPolicy = @($script:CanonicalLines | ForEach-Object { & $rename $_ })
            $ref = Join-Path $script:Work 'adapted-reference.md'
            [System.IO.File]::WriteAllLines($ref, (
                    @('<!-- policy-canonical-begin -->') + @($adaptedPolicy) + @('<!-- policy-canonical-end -->', '') +
                    @('<!-- stanza-canonical-begin -->') + @($script:StanzaLines) + @('<!-- stanza-canonical-end -->')))

            $body = @('- [alpha](lesson_alpha_thing.md) — a stale read drops the write', '- [beta](task_beta_thing.md) — the retry cap is three')
            $store = script:New-SplitStore -Body $body -PolicyText $adaptedPolicy
            $r = script:Invoke-Check -IndexPath $store.IndexPath -ReferencePath $ref
            $r.Text | Should -Not -Match 'entry-kind vocabulary not recognized'
            $r.Text | Should -Match 'read from the store policy file'
            $r.Report.KindPrefixes | Should -Contain 'lesson_'
            $r.Code | Should -Be 0
        }
    }

    Context 'canonical comparison on the split surface' {
        # Two polarities on the SAME fixture and the SAME mechanism. Neither can be discharged
        # against the untouched tree: before this change there was no split-store comparison at
        # all, so a control that appeared to pass there would be measuring something else.
        It 'reports an edit INSIDE the policy file canonical region as a divergence' {
            $edited = @($script:CanonicalLines)
            $edited[0] = $edited[0].Replace('COMPACTION POLICY', 'COMPACTION RULES')
            $store = script:New-SplitStore -Body $script:ConformingBody -PolicyText $edited
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Text | Should -Match 'policy file INCOMPLETE'
            $r.Text | Should -Match 'first divergence at policy file line 1'
            $r.Code | Should -Be 1
        }

        It 'does NOT report a changed per-store instance value as a divergence' {
            $values = @(
                'budget_fraction: 0.75',
                'staleness_bound_days: 45',
                "limit_observation: $script:ObservationDate | 24978 | characters | truncation-boundary test (agent-orchestra#1015 review round 3)",
                'limit_observation: 2026-08-18 | 25600 | characters | re-observed by a later sweep'
            )
            $store = script:New-SplitStore -Body $script:ConformingBody -Values $values
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Text | Should -Match 'RESULT: clean'
            $r.Text | Should -Not -Match 'divergence'
            $r.Code | Should -Be 0
            # and the appended observation is the one that governs: latest date, not last line
            $r.Report.Size.ObservedOn | Should -BeExactly '2026-08-18'
            $r.Report.Size.Budget | Should -Be ([int][Math]::Floor(0.75 * 25600))
        }

        It 'lets the policy file live under a name the stanza marker chooses' {
            $store = script:New-SplitStore -Body $script:ConformingBody -MarkerPath 'store-policy.md' -PolicyFileName 'store-policy.md'
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Text | Should -Match 'RESULT: clean'
            $r.Code | Should -Be 0
        }
    }

    Context 'size axis' {
        It 'fires as a defect on an over-budget but otherwise-clean store, at real magnitude' {
            # The magnitude bar is the live store's own size measured by this counting rule on
            # 2026-08-08: 29,886 characters (30,271 bytes on disk - the 385-unit gap is why the
            # unit is pinned). The bar is a constant, not a live read: the fixture is synthetic,
            # no live content is copied here, and no committed test touches the store's path.
            $store = script:New-SplitStore -Body (script:New-RealisticPointers -MinimumCharacters 30000)
            $r = script:Invoke-Check -IndexPath $store.IndexPath

            $r.Report.Size.Measured | Should -BeGreaterOrEqual 29886
            $r.Report.Size.State | Should -BeExactly 'over'
            $r.Code | Should -Be 1
            $r.Text | Should -Match 'OVER BY'
            # otherwise-clean: the exit code is attributable to the size axis alone
            $r.Report.HeaderComplete | Should -BeTrue
            $r.Report.SubjectsWithoutHook | Should -Be 0
            $r.Report.UnattributedSharedNotes | Should -Be 0
        }

        It 'is silent about size on a fitting store' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'within'
            $r.Text | Should -Not -Match 'OVER BY'
            $r.Code | Should -Be 0
        }

        It 'never renders a budget without the formula and the dated observation behind it' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $sizeLine = @(($r.Text -split "`r?`n") | Where-Object { $_ -match '^size: ' })[0]
            $sizeLine | Should -Match "of $($script:ExpectedBudget.ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)) characters"
            $sizeLine | Should -Match 'budget = 0\.80 of the 24,978-character limit observed 2026-08-06'
        }

        It 'counts characters, not bytes' {
            # A discriminating pair: same subject count, one body carrying multi-byte characters.
            # Under a byte count the second measures larger; under the pinned rule they match.
            $ascii = @('- [alpha](reference_alpha_lesson.md) - a stale read drops the write here')
            $wide = @('- [alpha](reference_alpha_lesson.md) — a stale read drops the write here')
            $a = script:Invoke-Check -IndexPath (script:New-SplitStore -Body $ascii).IndexPath
            $w = script:Invoke-Check -IndexPath (script:New-SplitStore -Body $wide).IndexPath
            $a.Report.Size.Measured | Should -Be $w.Report.Size.Measured
            [System.Text.Encoding]::UTF8.GetByteCount(($wide -join '')) |
                Should -BeGreaterThan ([System.Text.Encoding]::UTF8.GetByteCount(($ascii -join '')))
        }

        It 'reports not-evaluated for a legacy store, which has nowhere to record budget inputs' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody)
            $r.Report.Size.State | Should -BeExactly 'not-evaluated'
            $r.Text | Should -Match 'size: not evaluated - this store records no budget inputs'
            $r.Code | Should -Be 0
        }

        It 'distinguishes a half-migrated store from one that simply records nothing' {
            $store = script:New-SplitStore -Body $script:ConformingBody -OmitPolicyFile
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'not-evaluated'
            $r.Text | Should -Match "policy file does not exist yet"
        }
    }

    Context 'size axis - could not verify, and staleness' {
        It 'reports could-not-verify when budget inputs are recorded with no observation' {
            $store = script:New-SplitStore -Body $script:ConformingBody -Values @('budget_fraction: 0.80')
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r.Text | Should -Match 'size: could not verify - the store records budget inputs but no limit observation'
            $r.Code | Should -Be 1
        }

        It 'reports could-not-verify - naming the unit - rather than converting one' {
            $values = @("limit_observation: $script:ObservationDate | 24986 | bytes | a byte-counted observation")
            $store = script:New-SplitStore -Body $script:ConformingBody -Values $values
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r.Text | Should -Match "unit must be 'characters'"
            $r.Text | Should -Match 'does not convert between units'
            $r.Code | Should -Be 1
        }

        It 'does not suppress the other axes when the size axis cannot verify' {
            # The defect must stay on its own axis: a per-axis failure that blanked the counts
            # would be the global refusal path wearing a different name.
            $body = @('- [alpha lesson](reference_alpha_lesson.md)') + $script:ConformingBody
            $store = script:New-SplitStore -Body $body -Values @('budget_fraction: 0.80')
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Result | Should -BeExactly 'defects'
            $r.Text | Should -Match 'could not verify'
            $r.Text | Should -Match 'subjects_without_hook: 1'
            $r.Text | Should -Match 'unattributed_shared_notes: 0'
            $r.Text | Should -Match 'bare title'
        }

        It 'renders a staleness signal past the bound and none inside it' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $fresh = script:Invoke-Check -IndexPath $store.IndexPath -AsOf $script:FreshAsOf
            $stale = script:Invoke-Check -IndexPath $store.IndexPath -AsOf $script:StaleAsOf

            $fresh.Report.Size.Stale | Should -BeFalse
            $fresh.Text | Should -Not -Match 're-observe the limit'
            $stale.Report.Size.Stale | Should -BeTrue
            $stale.Text | Should -Match 'the observation is 61 days old against a 30-day bound - re-observe the limit'
        }

        It 'reports staleness without turning it into a defect' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $r = script:Invoke-Check -IndexPath $store.IndexPath -AsOf $script:StaleAsOf
            $r.Code | Should -Be 0
            $r.Text | Should -Match 'RESULT: clean'
        }

        It 'applies the shipped default bound to a store that declares none' {
            $values = @("limit_observation: $script:ObservationDate | 24978 | characters | truncation-boundary test")
            $store = script:New-SplitStore -Body $script:ConformingBody -Values $values
            $r = script:Invoke-Check -IndexPath $store.IndexPath -AsOf $script:StaleAsOf
            $r.Report.Size.StalenessBoundDays | Should -Be 30
            $r.Report.Size.Stale | Should -BeTrue
            $r.Report.Size.Budget | Should -Be $script:ExpectedBudget
        }

        It 'rejects a malformed values line rather than quietly skipping it' {
            $values = @('budget_fraction: eighty percent', "limit_observation: $script:ObservationDate | 24978 | characters | m")
            $store = script:New-SplitStore -Body $script:ConformingBody -Values $values
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r.Text | Should -Match 'budget_fraction must be a finite number'
        }
    }

    Context 'legacy stores keep a truthful verdict' {
        # The standing guard on the presence probe. If a future rewrite of the canonical text
        # drops its overlap with the pre-supersession text to nothing, a legacy store would
        # report 'absent' and lose the divergence message with it. That is this test's red.
        It 'reports a pre-supersession store as present but diverged, never absent and never refused' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $script:LegacyCanonicalLines)
            $r.Report.Result | Should -BeExactly 'defects'
            $r.Report.HeaderPresent | Should -BeTrue
            $r.Text | Should -Match 'policy: in-index header - present, INCOMPLETE'
            $r.Text | Should -Not -Match 'RESULT: refused'
            $r.Code | Should -Be 1
        }

        It 'explains the supersession and names the onward paths, obliging none of them' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $script:LegacyCanonicalLines)
            $r.Text | Should -Match 'predates the supersession of the never-retire ratchet'
            $r.Text | Should -Match 'adopt the split shape'
            $r.Text | Should -Match 'policy-pre-supersession\.md'
            $r.Text | Should -Match 'nothing here obliges any of them'
        }

        It 'does not evaluate the size axis on a legacy store, and says so on the axis line' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $script:LegacyCanonicalLines)
            $r.Report.Size.State | Should -BeExactly 'not-evaluated'
            $r.Text | Should -Match 'size: not evaluated'
            $r.Text | Should -Not -Match 'OVER BY'
        }

        It 'reports clean against the shipped pre-supersession reference' {
            # AC7(ii): the release must not destroy the only copy of the text a never-adapted
            # store is checked against. This is that copy, shipped and reachable.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $script:LegacyCanonicalLines) `
                -ReferencePath $script:PreSupersession
            $r.Text | Should -Match 'RESULT: clean'
            $r.Text | Should -Match 'policy: in-index header - present, complete'
            $r.Code | Should -Be 0
        }

        It 'ships the pre-supersession text as a usable reference copy, not just prose' {
            Test-Path -LiteralPath $script:PreSupersession -PathType Leaf | Should -BeTrue
            $preamble = @([System.IO.File]::ReadAllLines($script:PreSupersession)) -join "`n"
            $preamble | Should -Match 'PolicyReferencePath'
            (Get-Content -LiteralPath $script:Skill -Raw) | Should -Match 'templates/policy-pre-supersession\.md'
        }
    }

    Context 'hook axis' {
        It 'counts a bare title whose every word is already in the filename' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [alpha lesson](reference_alpha_lesson.md)'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
            $r.Text | Should -Match 'bare title'
            $r.Code | Should -Be 1
        }

        It 'rejects generic filler sitting in the LINK TEXT, not only in a clause' {
            # Regression: the filler set was applied only to trailing clauses, so a pointer whose
            # link text was literally "see body" reported clean.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [see body](reference_alpha_lesson.md)'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
            $r.Code | Should -Be 1
        }

        It 'rejects a generic-filler clause' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [alpha lesson](reference_alpha_lesson.md) — see body'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
        }

        It 'rejects "N/A" as a clause, not only the bare spelling "na"' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [alpha lesson](reference_alpha_lesson.md) — N/A'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
        }

        It 'does not accept a punctuation-only clause as a hook' {
            # Regression: emptiness was tested on the raw clause, so "**" and "." counted.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- **[alpha lesson](reference_alpha_lesson.md)**'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
        }

        It 'still credits link text that states the lesson when a filler clause trails it' {
            # Regression: R1 is disjunctive, but the branches were exclusive, so a filler clause
            # suppressed the link-text path and flagged a conforming subject.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [a stale read silently drops the write](reference_alpha_lesson.md) — see body'))
            $r.Text | Should -Match 'subjects_without_hook: 0'
        }

        It 'treats hyphen and apostrophe splits as the same words as the filename' {
            # Regression: "pre-existing" tokenized to pre+existing and never matched "preexisting",
            # so a textbook bare title passed.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [pre-existing](reference_preexisting.md)'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
            $r.Code | Should -Be 1
        }

        It 'credits a clause that sits BETWEEN two links to the link it follows' {
            # Regression: the clause was read only after the LAST link on a line, so the first
            # subject was reported bare and the second subject's own clause was reported as a
            # shared note.
            $body = @('- [alpha](reference_alpha_lesson.md) — a stale read drops the write, [beta](project_beta_thing.md) — the retry cap is three')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'subjects_without_hook: 0'
            $r.Text | Should -Match 'unattributed_shared_notes: 0'
            $r.Code | Should -Be 0
        }
    }

    Context 'shared-note axis' {
        It 'counts one trailing note over a run of bare subjects' {
            $body = @('- [reference alpha lesson](reference_alpha_lesson.md) [reference beta lesson](reference_beta_lesson.md) — one note covering both of them')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'unattributed_shared_notes: 1'
            $r.Code | Should -Be 1
        }

        It 'counts one LEADING note over a run of bare subjects' {
            $body = @('- These three runs all died on the same trigger-shaped mistake: [reference alpha lesson](reference_alpha_lesson.md), [reference beta lesson](reference_beta_lesson.md)')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'unattributed_shared_notes: 1'
        }

        It 'does NOT flag a grouped line whose subjects each carry their own hook' {
            # Regression: keyed on missing clauses rather than missing hooks, this fired on a
            # conforming grouped line - the shape the chunked-delivery brief carves out.
            $body = @('- Topic: [a stale read drops the write](reference_alpha_lesson.md) · [merge base predates both](reference_beta_lesson.md) · [the retry cap is three](project_beta_thing.md) — and that cap is not configurable')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'unattributed_shared_notes: 0'
        }

        It 'does not treat a short topic label as a note' {
            $body = @('- Git/CI truth: [reference alpha lesson](reference_alpha_lesson.md) [reference beta lesson](reference_beta_lesson.md)')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'unattributed_shared_notes: 0'
        }
    }

    Context 'scope: nothing is judged silently' {
        It 'judges pointers on * and + and numbered bullets, not only on -' {
            # Regression: the gate was '^\s*-\s', so eight bare '*' pointers reported clean.
            $body = @(
                '- [alpha](reference_alpha_lesson.md) — a stale read drops the write',
                '* [reference beta lesson](reference_beta_lesson.md)',
                '+ [reference gamma lesson](reference_gamma_lesson.md)',
                '1. [reference delta lesson](reference_delta_lesson.md)'
            )
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'subjects_without_hook: 3'
            $r.Code | Should -Be 1
        }

        It 'parses and judges anchored, titled and uppercase-extension targets' {
            # Regression: the target pattern rejected these, and a rejected link was dropped
            # silently - not counted, not reported, not refused.
            $body = @(
                '- [alpha](reference_alpha_lesson.md) — a stale read drops the write',
                '- [reference beta lesson](reference_beta_lesson.md#top)',
                '- [reference gamma lesson](reference_gamma_lesson.md "a title")',
                '- [reference delta lesson](reference_delta_lesson.MD)'
            )
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'subjects_without_hook: 3'
        }

        It 'refuses when a link-like construct cannot be parsed' {
            $body = @(
                '- [alpha](reference_alpha_lesson.md) — a stale read drops the write',
                '- [beta](my notes/reference_beta_lesson.md)'
            )
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'could not be parsed'
            $r.Code | Should -Be 2
        }

        It 'refuses an index with no section heading' {
            $path = Join-Path $script:Work ('nosection-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.md')
            [System.IO.File]::WriteAllLines($path, @('- [alpha](reference_alpha_lesson.md) — a clause here'))
            $r = script:Invoke-Check -IndexPath $path
            $r.Text | Should -Match 'structure not recognized'
            $r.Code | Should -Be 2
        }

        It 'refuses an index with no pointer line' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('Just prose, no pointers.'))
            $r.Text | Should -Match 'structure not recognized'
            $r.Code | Should -Be 2
        }
    }

    Context 'entry-kind vocabulary' {
        It 'refuses when no entry matches any kind the policy names' {
            $body = @('- [note one](zz-note-one.md) — a clause', '- [note two](zz-note-two.md) — another clause')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'entry-kind vocabulary not recognized'
            $r.Code | Should -Be 2
        }

        It 'discloses how many subjects carry none of the named prefixes' {
            $body = @(
                '- [alpha](reference_alpha_lesson.md) — a stale read drops the write',
                '- [note one](zz-note-one.md) — a clause of its own'
            )
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'matched 1 of 2 linked subjects'
            $r.Text | Should -Match 'carry none of those prefixes'
        }

        It 'reads the kind vocabulary from an adapted index header rather than the reference' {
            # Regression: the vocabulary came only from the reference, so a store that adapted
            # its policy text exactly as the adapt-note instructs was refused and told to adapt.
            $header = @($script:CanonicalLines) | ForEach-Object {
                $_ -replace '`reference_`', '`lesson_`' -replace '`feedback_`', '`howto_`' -replace '`project_`', '`task_`' -replace '`user_`', '`me_`'
            }
            $body = @('- [alpha](lesson_alpha_thing.md) — a stale read drops the write', '- [beta](task_beta_thing.md) — the retry cap is three')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body -Header $header)
            $r.Text | Should -Not -Match 'entry-kind vocabulary not recognized'
            $r.Text | Should -Match 'read from the index header'
        }
    }

    Context 'output contract' {
        It 'emits JSON on the clean path' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody) -AsJson
            { $r.Text | ConvertFrom-Json } | Should -Not -Throw
            ($r.Text | ConvertFrom-Json).result | Should -Be 'clean'
        }

        It 'emits JSON on the refusal path' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('Just prose, no pointers.')) -AsJson
            ($r.Text | ConvertFrom-Json).result | Should -Be 'refused'
            $r.Code | Should -Be 2
        }

        It 'emits JSON on the usage-error path' {
            # Regression: the exit-3 branch wrote plain text before -Json was consulted.
            $r = script:Invoke-Check -IndexPath (Join-Path $script:Work 'does-not-exist.md') -AsJson
            ($r.Text | ConvertFrom-Json).result | Should -Be 'usage-error'
            $r.Code | Should -Be 3
        }

        It 'carries the split shape and the whole size axis in -Json, not only in the text' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $j = (script:Invoke-Check -IndexPath $store.IndexPath -AsJson).Text | ConvertFrom-Json
            $j.store_shape | Should -BeExactly 'split'
            $j.policy_file | Should -Not -BeNullOrEmpty
            $j.size.state | Should -BeExactly 'within'
            $j.size.unit | Should -BeExactly 'characters'
            $j.size.budget | Should -Be $script:ExpectedBudget
            $j.size.fraction | Should -Be 0.8
            $j.size.observation_value | Should -Be 24978
            $j.size.observation_date | Should -BeExactly $script:ObservationDate
            $j.size.observation_method | Should -Match 'truncation-boundary test'
            $j.size.staleness_bound_days | Should -Be 30
            $j.size.stale | Should -BeFalse
        }

        It 'carries every not-evaluated and could-not-verify state in -Json too' {
            $legacy = (script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody) -AsJson).Text | ConvertFrom-Json
            $legacy.store_shape | Should -BeExactly 'legacy'
            $legacy.size.state | Should -BeExactly 'not-evaluated'
            $legacy.size.cause | Should -Match 'records no budget inputs'
            $legacy.size.budget | Should -BeNullOrEmpty

            $half = (script:Invoke-Check -IndexPath (script:New-SplitStore -Body $script:ConformingBody -OmitPolicyFile).IndexPath -AsJson).Text | ConvertFrom-Json
            $half.store_shape | Should -BeExactly 'split-incomplete'
            $half.policy_explanation | Should -Not -BeNullOrEmpty

            $unusable = (script:Invoke-Check -IndexPath (script:New-SplitStore -Body $script:ConformingBody -Values @('budget_fraction: 0.80')).IndexPath -AsJson).Text | ConvertFrom-Json
            $unusable.size.state | Should -BeExactly 'could-not-verify'
            $unusable.subjects_without_hook | Should -Be 0
        }

        It 'returns the report as data, not only as host output' {
            # Regression: the report was written with Write-Host, so an in-process caller
            # captured an empty string.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody)
            $r.Report.Result | Should -Be 'clean'
            $r.Report.SubjectsWithoutHook | Should -Be 0
            $r.Text | Should -Match 'RESULT: clean'
        }

        It 'refuses rather than reporting defects when the index cannot be read' -Skip:(-not $IsWindows) {
            # Regression: an IO failure fell through to exit 1, the code the contract documents
            # as "defects found". Windows-only: the lock is not advisory there.
            $path = script:New-Index -Body $script:ConformingBody
            $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
            try { $r = script:Invoke-Check -IndexPath $path } finally { $stream.Dispose() }
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'could not be read'
        }
    }

    Context 'adversarial review fix cycle - store-side markers and paths (grouping a)' {
        It 'does not let an index that QUOTES the adoption snippet become a split store' {
            # The panel's anchor finding. The shipped docs print these markers, so an index that
            # copies the migration recipe into itself was read as split - and the preserved-text
            # route then refused, blaming the shipped template for the index's own content.
            $quoted = @('The migration recipe, for later:', '', '```text',
                '   <!-- memory-policy-stanza-begin: POLICY.md -->', '   ...stanza...',
                '   <!-- memory-policy-stanza-end -->', '```', '') + $script:ConformingBody
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $quoted)
            $r.Report.StoreShape | Should -BeExactly 'legacy'
            $r.Text | Should -Match 'RESULT: clean'
            $r.Code | Should -Be 0
        }

        It 'keeps the preserved-text route clean for a legacy store that quotes the snippet' {
            # AC7(ii) under the same input: this is the consequence that made the finding high.
            $quoted = @('Notes to self:', '', '<!-- memory-policy-stanza-begin: POLICY.md -->',
                '<!-- memory-policy-stanza-end -->', '') + $script:ConformingBody
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $quoted -Header $script:LegacyCanonicalLines) `
                -ReferencePath $script:PreSupersession
            $r.Text | Should -Match 'RESULT: clean'
            $r.Text | Should -Not -Match 'malformed'
            $r.Code | Should -Be 0
        }

        It 'does not read the shipped SKILL.md as a split-store declaration' {
            # The direct probe: SKILL.md carries a well-formed store-side marker in an example.
            $lines = @([System.IO.File]::ReadAllLines($script:Skill))
            $firstSection = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match '^##\s' })
            $firstSection | Should -BeGreaterThan -1
            (Get-MIPStoreStanza -Lines $lines -HeaderLineCount $firstSection).Found | Should -BeFalse
            # ...and the marker text really is in the file, so the guard is not vacuous. It is
            # at column 0 (the adoption snippet is copy-pasteable), well below the first heading.
            $markerLines = @($lines | Where-Object { $_.TrimEnd() -match '^<!--\s*memory-policy-stanza-begin' })
            $markerLines.Count | Should -BeGreaterThan 0 -Because 'SKILL.md must still show the marker it documents'
            [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l.TrimEnd() -match '^<!--\s*memory-policy-stanza-begin' }) |
                Should -BeGreaterThan $firstSection
        }

        It 'refuses an indented stanza marker rather than accepting it' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $lines = @([System.IO.File]::ReadAllLines($store.IndexPath))
            $lines[0] = '   ' + $lines[0]
            [System.IO.File]::WriteAllLines($store.IndexPath, $lines)
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.StoreShape | Should -BeExactly 'legacy'
        }

        It 'refuses a stanza marker written without its path rather than reading it back as legacy' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $lines = @([System.IO.File]::ReadAllLines($store.IndexPath))
            $lines[0] = '<!-- memory-policy-stanza-begin -->'
            [System.IO.File]::WriteAllLines($store.IndexPath, $lines)
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'names no policy file'
            $r.Text | Should -Not -Match 'in-index header - absent'
        }

        It 'calls an unusable policy-file declaration malformed, not half-migrated' {
            # Three declarations that cannot name a file beside the index. Each must be told
            # apart from a store that simply has not created its policy file yet.
            foreach ($bad in @('..\..\outside\POLICY.md', 'C:\Windows\win.ini', '/etc/passwd')) {
                $store = script:New-SplitStore -Body $script:ConformingBody -MarkerPath $bad -OmitPolicyFile
                $r = script:Invoke-Check -IndexPath $store.IndexPath
                $r.Code | Should -Be 2 -Because "'$bad' cannot name a file beside the index"
                $r.Text | Should -Match 'malformed declaration, not the half-migrated state'
            }
            # control: the same store with a lawful path IS half-migrated, a defect not a refusal
            $ok = script:New-SplitStore -Body $script:ConformingBody -OmitPolicyFile
            (script:Invoke-Check -IndexPath $ok.IndexPath).Code | Should -Be 1
        }

        It 'reports policy text left in the header region beside the stanza' {
            # Migration residue: a store that "split" without removing what it was splitting out.
            $store = script:New-SplitStore -Body $script:ConformingBody
            $lines = @($script:LegacyCanonicalLines) + @('') + @([System.IO.File]::ReadAllLines($store.IndexPath))
            [System.IO.File]::WriteAllLines($store.IndexPath, $lines)
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Code | Should -Be 1
            $r.Text | Should -Match "header region still carries policy text outside the stanza"
        }

        It 'refuses nested links instead of throwing on a negative substring length' {
            # Pre-existing at origin/main; repaired here because this release ships the claim
            # that an unparsable link construct is an exit-2 refusal.
            $body = @('- [alpha](reference_alpha_lesson.md) - a stale read drops the write',
                '- [see [ref:foo](reference_foo_lesson.md) detail](reference_bar_lesson.md) - a clause')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'could not be parsed'
            $r.Text | Should -Match 'nested or overlapping links'
        }
    }

    Context 'adversarial review fix cycle - the values record as a record (grouping b)' {
        It 'rejects a non-finite budget fraction instead of throwing' {
            # NaN and Infinity both survive TryParse, and every comparison against NaN is false,
            # so a range guard alone waved them through to a cast that threw: exit 1 with no
            # report at all and an empty -Json payload.
            foreach ($bad in @('NaN', 'Infinity', '-Infinity')) {
                $store = script:New-SplitStore -Body $script:ConformingBody -Values @("budget_fraction: $bad")
                # An unhandled throw fails this line outright, which is the red state.
                $r = script:Invoke-Check -IndexPath $store.IndexPath
                $r.Report.Size.State | Should -BeExactly 'could-not-verify' -Because "'$bad' must be reported, not thrown on"
                $r.Code | Should -Be 1
                $j = (script:Invoke-Check -IndexPath $store.IndexPath -AsJson).Text
                $j | Should -Not -BeNullOrEmpty -Because 'the -Json payload must exist on every terminal path'
                ($j | ConvertFrom-Json).size.state | Should -BeExactly 'could-not-verify'
            }
        }

        It 'rejects a future-dated observation, which would otherwise govern forever' {
            # The freshest date governs and the record is append-only, so a mistyped year
            # outranks every honest re-observation that follows it - permanently, and rendered
            # as an evaluated axis rather than one that could not verify.
            $values = @(
                "limit_observation: 2126-08-06 | 24978 | characters | mistyped year",
                'limit_observation: 2026-09-01 | 20000 | characters | the limit shrank')
            $store = script:New-SplitStore -Body $script:ConformingBody -Values $values
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r.Text | Should -Match 'dated 2126-08-06, in the future'
            $r.Code | Should -Be 1

            # control: the same two rows with an honest year - the later, smaller limit governs
            $ok = script:New-SplitStore -Body $script:ConformingBody -Values @(
                "limit_observation: 2026-08-06 | 24978 | characters | truncation-boundary test",
                'limit_observation: 2026-09-01 | 20000 | characters | the limit shrank')
            $c = script:Invoke-Check -IndexPath $ok.IndexPath -AsOf ([datetime]::ParseExact('2026-09-10', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))
            $c.Report.Size.ObservedOn | Should -BeExactly '2026-09-01'
            $c.Report.Size.Budget | Should -Be ([int][Math]::Floor(0.80 * 20000))
        }

        It 'rejects a repeated scalar key instead of silently taking the last one' {
            $store = script:New-SplitStore -Body $script:ConformingBody -Values @(
                'budget_fraction: 0.80', 'budget_fraction: 0.10',
                "limit_observation: $script:ObservationDate | 24978 | characters | m")
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r.Text | Should -Match "'budget_fraction' is recorded more than once"
            $r.Code | Should -Be 1
        }

        It 'rejects a second values region rather than letting the first silently govern' {
            # The shipped format example, left above the real values, governed the budget.
            $store = script:New-SplitStore -Body $script:ConformingBody
            $policy = @([System.IO.File]::ReadAllLines($store.PolicyPath))
            $example = @('<!-- store-values-begin -->', 'budget_fraction: 0.80',
                'limit_observation: 2020-01-01 | 500 | characters | an example', '<!-- store-values-end -->', '')
            [System.IO.File]::WriteAllLines($store.PolicyPath, (@($policy[0..1]) + $example + @($policy[2..($policy.Count - 1)])))
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r.Text | Should -Match "carries 2 '<!-- store-values-begin -->' regions"
            $r.Code | Should -Be 1
        }

        It 'reads a declared-but-empty values region the same way whichever way it was written' {
            # A blank line inside the markers used to flip the verdict across the clean/defect
            # line. Declared-and-empty is one intent and must read as one outcome.
            $adjacent = script:New-SplitStore -Body $script:ConformingBody -Values @()
            $blank = script:New-SplitStore -Body $script:ConformingBody -Values @('')
            $a = script:Invoke-Check -IndexPath $adjacent.IndexPath
            $b = script:Invoke-Check -IndexPath $blank.IndexPath
            $a.Report.Size.State | Should -BeExactly 'could-not-verify'
            $b.Report.Size.State | Should -BeExactly $a.Report.Size.State
            $a.Code | Should -Be $b.Code
            # ...and a store with no region at all still reads as recording nothing
            $none = script:New-SplitStore -Body $script:ConformingBody -OmitValuesBlock
            (script:Invoke-Check -IndexPath $none.IndexPath).Report.Size.State | Should -BeExactly 'not-evaluated'
        }

        It 'rejects a unit that differs only in case' {
            $store = script:New-SplitStore -Body $script:ConformingBody -Values @(
                "limit_observation: $script:ObservationDate | 24978 | CHARACTERS | m")
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r.Text | Should -Match "unit must be 'characters'"
        }
    }

    Context 'adversarial review fix cycle - honest reporting' {
        It 'does not refuse an adapted store while it is half-migrated' {
            # Chunk 3 puts every store it migrates through this state. Refusing here told an
            # adapted owner to "adapt the policy text first" - which they had done - and
            # suppressed every count.
            $rename = { param($t) $t -replace '`reference_`', '`lesson_`' -replace '`feedback_`', '`howto_`' -replace '`project_`', '`task_`' -replace '`user_`', '`me_`' }
            $adapted = @($script:CanonicalLines | ForEach-Object { & $rename $_ })
            $body = @('- [alpha](lesson_alpha_thing.md) — a stale read drops the write', '- [beta](task_beta_thing.md) — the retry cap is three')
            $store = script:New-SplitStore -Body $body -PolicyText $adapted -OmitPolicyFile
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Code | Should -Be 1
            $r.Report.Result | Should -BeExactly 'defects'
            $r.Text | Should -Not -Match 'entry-kind vocabulary not recognized'
            $r.Text | Should -Match 'half-migrated'
            $r.Text | Should -Match 'subjects_without_hook: 0'
        }

        It 'harvests entry kinds only from the region the comparison actually audits' {
            # A kind named outside the compared region was governing behaviour under a verdict
            # that said the policy file matched the reference.
            $store = script:New-SplitStore -Body @('- [alpha](zzz_alpha_lesson.md) — a stale read drops the write')
            $policy = @([System.IO.File]::ReadAllLines($store.PolicyPath)) + @('', 'Notes: we also keep `zzz_` entries.')
            [System.IO.File]::WriteAllLines($store.PolicyPath, $policy)
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'entry-kind vocabulary not recognized'
            $r.Text | Should -Not -Match 'zzz_' -Because 'a kind named outside the compared region must not enter the vocabulary'
        }

        It 'states both readings of a legacy divergence instead of one false remedy' {
            # The divergence explanation is unconditional by design (no version recognition),
            # so its remedies must be too: a store diverging by an ordinary typo in the CURRENT
            # text gets no clean verdict from the pre-supersession reference.
            $header = @($script:CanonicalLines)
            $header[-1] = $header[-1].Replace('runs it', 'runsit')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $header)
            $r.Text | Should -Match 'cannot tell which policy text this store adopted'
            $r.Text | Should -Match 'will NOT produce a clean verdict in that case'
        }

        It 'reports the policy axis honestly in -Json for a half-migrated store' {
            $j = (script:Invoke-Check -IndexPath (script:New-SplitStore -Body $script:ConformingBody -OmitPolicyFile).IndexPath -AsJson).Text | ConvertFrom-Json
            $j.policy_present | Should -BeFalse
            $j.header_present | Should -BeFalse -Because 'the retained legacy key must carry the same truth, not a constant'
            $j.policy_complete | Should -BeFalse
            $j.policy_divergence | Should -Not -BeNullOrEmpty
        }

        It 'exercises the unreadable-policy-file refusal on every platform' {
            # The Windows lock has no POSIX equivalent, so the one construction that separates
            # AC8's refusal from the half-migrated defect had no standing guard on the merge
            # path. A directory standing where the file should be is readable-as-a-path and
            # unreadable-as-a-file on both.
            $store = script:New-SplitStore -Body $script:ConformingBody -OmitPolicyFile
            New-Item -ItemType Directory -Path $store.PolicyPath -Force | Out-Null
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'not the half-migrated state'
        }
    }

    Context 'the shipped surfaces describe what the check actually does' {
        It 'keeps the documented parameter surface exactly, and keeps -Policy and -Index unambiguous' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:EntryPoint, [ref]$null, [ref]$null)
            $declared = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } | Sort-Object)
            $declared | Should -Be @('IndexPath', 'Json', 'PolicyReferencePath')
            @($declared | Where-Object { $_.StartsWith('Policy') }) | Should -Be @('PolicyReferencePath')
            @($declared | Where-Object { $_.StartsWith('Index') }) | Should -Be @('IndexPath')
        }

        It 'keeps bare marker lines out of the compared regions' {
            # A line that IS a marker, sitting inside the text a store copies, truncates that
            # store's own region when the check reads it back. The text describes the markers
            # in several places, so this is a live footgun, not a hypothetical one.
            foreach ($pair in @(
                    @{ b = '<!-- policy-canonical-begin -->'; e = '<!-- policy-canonical-end -->' },
                    @{ b = '<!-- stanza-canonical-begin -->'; e = '<!-- stanza-canonical-end -->' })) {
                $block = @(script:Read-Region -Path $script:Skill -Begin $pair.b -End $pair.e)
                @($block | Where-Object { $_.Trim() -match '^<!--.*-->$' }) |
                    Should -BeNullOrEmpty -Because "a bare marker line inside $($pair.b) would truncate every store that adopts the text"
            }
        }

        It 'names four axes in the shipped policy text and in both script headers' {
            $canon = ($script:CanonicalLines -join "`n")
            $canon | Should -Match 'four axes'
            $canon | Should -Not -Match 'three axes'
            # -Match is case-insensitive, so one spelling covers both; the alternation an
            # earlier revision carried was a no-op dressed as thoroughness.
            foreach ($p in @($script:EntryPoint, $script:Core)) {
                (Get-Content -LiteralPath $p -Raw) | Should -Not -Match 'three axes'
            }
        }

        It 'ships an expected-output example whose axes match a real run, in order' {
            $store = script:New-SplitStore -Body $script:ConformingBody
            $r = script:Invoke-Check -IndexPath $store.IndexPath
            $r.Code | Should -Be 0
            $actual = @(($r.Text -split "`r?`n") | Select-Object -First 5 | ForEach-Object { ($_ -split ':', 2)[0] })

            $start = [array]::FindIndex([string[]]$script:CanonicalLines, [Predicate[string]] { param($l) $l -eq 'RESULT: clean' })
            $start | Should -BeGreaterThan -1 -Because 'the canonical text must carry an expected-output example'
            $example = @($script:CanonicalLines[$start..($start + 4)] | ForEach-Object { ($_ -split ':', 2)[0] })
            $example | Should -Be $actual
        }

        It 'states no budget as a bare absolute anywhere it ships' {
            # The negative universal, swept by named patterns over the shipped skill text:
            #   - the historical 17.1K target, declared non-authoritative, must appear nowhere.
            #     Spelled here in the parent design's own shorthand on purpose: writing the
            #     numeral would make this comment the first thing its own sweep found.
            #   - the computed budget may appear only alongside the formula that produced it
            $shipped = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'skills/agent-memory-compaction') -Recurse -Filter '*.md') +
            @(Get-Item -LiteralPath $PSCommandPath)   # this suite is fixture text, and bound by the same rule
            $shipped.Count | Should -BeGreaterThan 2 -Because 'the sweep must actually reach the shipped text AND the fixtures'
            foreach ($f in $shipped) {
                $text = Get-Content -LiteralPath $f.FullName -Raw
                $text | Should -Not -Match '17,?100' -Because "$($f.Name) must not resurrect the non-authoritative historical target"
                foreach ($line in @($text -split "`r?`n" | Where-Object { $_ -match '19,?982' })) {
                    $line | Should -Match 'budget = ' -Because "$($f.Name) states the budget without its formula: '$line'"
                }
            }
        }
    }
}
