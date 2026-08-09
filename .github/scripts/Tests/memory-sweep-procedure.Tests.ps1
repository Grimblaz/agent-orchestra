#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Executed demonstrations of the sweep procedure, its records, and its three procedural checks.

.DESCRIPTION
    The deliverable of agent-orchestra#1018 is documentation plus record shapes, and documentation
    whose demonstration is reading it back is planted green at documentation grain. So every
    demonstration here runs against a COMMITTED fixture store under fixtures/memory-sweep/, and
    asserts over the artifacts the procedure produces - records written, index bytes, exit codes -
    rather than over a transcript describing them. For a procedure deliverable the demonstrator and
    the mechanism are the same actor, and a narrator cannot come out negative about itself.

    Each demonstration carries at least one construction that could fail: a blocked second
    deferral, a pointer dropped beyond a simulated truncation cut, a refused promotion, a bare
    key that errors, a values-less store that must stay clean.

    The fixture store is assembled from committed inputs plus the shipped canonical texts, the
    same way memory-index-policy.Tests.ps1 builds its split stores - so the fixture cannot drift
    from the policy text it is checked against.

    Dates are pinned and -AsOf is passed everywhere expiry or staleness is in play.
#>

Describe 'memory store sweep procedure' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SkillDir = Join-Path $script:RepoRoot 'skills/agent-memory-compaction'
        $script:Skill = Join-Path $script:SkillDir 'SKILL.md'
        $script:ProcedureDoc = Join-Path $script:SkillDir 'references/sweep-procedure.md'
        $script:RecordsDoc = Join-Path $script:SkillDir 'references/store-records.md'
        $script:SweepCore = Join-Path $script:SkillDir 'scripts/lib/memory-sweep-core.ps1'
        $script:PolicyEntryPoint = Join-Path $script:SkillDir 'scripts/Test-MemoryIndexPolicy.ps1'
        $script:InventoryScript = Join-Path $script:SkillDir 'scripts/Get-MemorySweepInventory.ps1'
        $script:PartitionScript = Join-Path $script:SkillDir 'scripts/Test-MemorySweepPartition.ps1'
        $script:MeasureScript = Join-Path $script:SkillDir 'scripts/Measure-MemorySurface.ps1'
        $script:Fixture = Join-Path $PSScriptRoot 'fixtures/memory-sweep'

        # In-process, per the repo's script-safety contract: the sweep core dot-sources the policy
        # core, so one dot-source reaches both surfaces.
        . $script:SweepCore

        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("sweep-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

        function script:Read-Region {
            param([string]$Path, [string]$Begin, [string]$End)
            $lines = @([System.IO.File]::ReadAllLines($Path))
            $region = Get-MIPMarkedRegion -Lines $lines -BeginMarker $Begin -EndMarker $End
            if (-not $region.Found) { throw "region $Begin not found in $Path" }
            return @($region.Block)
        }

        $script:CanonicalLines = @(script:Read-Region -Path $script:Skill -Begin '<!-- policy-canonical-begin -->' -End '<!-- policy-canonical-end -->')
        $script:StanzaLines = @(script:Read-Region -Path $script:Skill -Begin '<!-- stanza-canonical-begin -->' -End '<!-- stanza-canonical-end -->')

        # Pinned dates. Sweep 1 sits inside the fixture's world; sweep 2 is past the expiry sweep 1
        # writes. The admission rule's landing date is the fixture store's, stated in its README.
        $script:Sweep1 = [datetime]::ParseExact('2026-08-08', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $script:Sweep2 = [datetime]::ParseExact('2026-09-15', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $script:AdmissionRuleLanded = [datetime]::ParseExact('2026-06-01', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

        # The store-side section step 0 writes. It sits OUTSIDE both compared regions, which is
        # what lets a store gain a pointer to the machinery without diverging on the policy axis.
        $script:MachinerySection = @(
            '## Sweep machinery (not part of the compared text)',
            '',
            'Sweeps of this store follow `skills/agent-memory-compaction/references/sweep-procedure.md`',
            'in the agent-orchestra plugin. Its records live beside this file: `LEDGER.md`, `SLATE.md`,',
            'and `ARCHIVE.md`. Their shapes are defined in',
            '`skills/agent-memory-compaction/references/store-records.md`.',
            '')

        # Assembles the committed fixture into a working store. -WithMachinerySection off models a
        # store that split under 3.14.0, before this machinery existed.
        function script:New-FixtureStore {
            param([switch]$OmitValuesBlock, [switch]$OmitMachinerySection, [string[]]$ExtraValues = @())

            $dir = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $body = @([System.IO.File]::ReadAllLines((Join-Path $script:Fixture 'index-body.md')))
            $indexLines = @("<!-- memory-policy-stanza-begin: POLICY.md -->") + $script:StanzaLines +
            @('<!-- memory-policy-stanza-end -->', '') + $body
            [System.IO.File]::WriteAllLines((Join-Path $dir 'MEMORY.md'), $indexLines)

            $policyLines = @('# Store policy', '')
            if (-not $OmitValuesBlock) {
                $values = @([System.IO.File]::ReadAllLines((Join-Path $script:Fixture 'store-values.txt')) | Where-Object { $_.Trim() -ne '' })
                $policyLines += @('<!-- store-values-begin -->') + $values + @($ExtraValues) + @('<!-- store-values-end -->', '')
            }
            if (-not $OmitMachinerySection) { $policyLines += $script:MachinerySection }
            $policyLines += @('<!-- policy-canonical-begin -->') + $script:CanonicalLines + @('<!-- policy-canonical-end -->')
            [System.IO.File]::WriteAllLines((Join-Path $dir 'POLICY.md'), $policyLines)

            Copy-Item -LiteralPath (Join-Path $script:Fixture 'LEDGER.md') -Destination $dir
            Copy-Item -LiteralPath (Join-Path $script:Fixture 'SLATE.md') -Destination $dir
            foreach ($e in @(Get-ChildItem -LiteralPath (Join-Path $script:Fixture 'entries') -Filter '*.md' -File)) {
                Copy-Item -LiteralPath $e.FullName -Destination $dir
            }
            return [pscustomobject]@{
                Dir     = $dir
                Index   = Join-Path $dir 'MEMORY.md'
                Policy  = Join-Path $dir 'POLICY.md'
                Ledger  = Join-Path $dir 'LEDGER.md'
                Slate   = Join-Path $dir 'SLATE.md'
                Archive = Join-Path $dir 'ARCHIVE.md'
            }
        }

        # The sweep's own writes. Append-only, into the marked region, exactly as the procedure
        # and the record definitions say - so what the tests exercise is the shipped discipline
        # and not a convenience the tests invented.
        function script:Add-Record {
            param([string]$Path, [string]$BeginMarker, [string]$EndMarker, [string[]]$Rows)
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.AddRange([string[]]@([System.IO.File]::ReadAllLines($Path)))
            $at = $lines.FindIndex({ param($l) $l.Trim() -ceq $EndMarker })
            if ($at -lt 0) { throw "no $EndMarker in $Path" }
            $lines.InsertRange($at, [string[]]@($Rows))
            [System.IO.File]::WriteAllLines($Path, $lines)
        }
        function script:Add-LedgerRecord { param([string]$Path, [string[]]$Rows)
            script:Add-Record -Path $Path -BeginMarker '<!-- memory-ledger-begin -->' -EndMarker '<!-- memory-ledger-end -->' -Rows $Rows }
        function script:Add-SlateRow { param([string]$Path, [string[]]$Rows)
            script:Add-Record -Path $Path -BeginMarker '<!-- memory-slate-begin -->' -EndMarker '<!-- memory-slate-end -->' -Rows $Rows }

        function script:Remove-Pointer {
            param([string]$IndexPath, [string]$Name)
            $kept = @([System.IO.File]::ReadAllLines($IndexPath) | Where-Object { $_ -notmatch [regex]::Escape("$Name.md") })
            [System.IO.File]::WriteAllLines($IndexPath, $kept)
        }

        function script:Get-FileDigests {
            param([string]$Dir)
            $map = @{}
            foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File | Sort-Object Name)) {
                $map[$f.Name] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            }
            return $map
        }

        function script:Invoke-PolicyCheck {
            param([string]$IndexPath, [datetime]$AsOf = $script:Sweep1)
            $report = Invoke-MemoryIndexPolicyCheck -IndexPath $IndexPath -AsOf $AsOf
            return [pscustomobject]@{
                Text = ((Format-MemoryIndexPolicyReport -Report $report) | Out-String)
                Code = $report.ExitCode
                Report = $report
            }
        }

        function script:Get-ValuesRegion {
            param([string]$PolicyPath)
            $lines = @([System.IO.File]::ReadAllLines($PolicyPath))
            $r = Get-MIPMarkedRegion -Lines $lines -BeginMarker '<!-- store-values-begin -->' -EndMarker '<!-- store-values-end -->'
            if (-not $r.Found) { return @() }
            return @($r.Block)
        }

        $script:ProcedureText = [System.IO.File]::ReadAllText($script:ProcedureDoc)
        $script:RecordsText = [System.IO.File]::ReadAllText($script:RecordsDoc)
        $script:SkillText = [System.IO.File]::ReadAllText($script:Skill)
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'the fixture store is a conforming control' {
        It 'reports clean on all four axes with the sweep-machinery section present' {
            # The control that isolates every later failure: nothing but the planted defect may
            # make a case red. It also executes the fact AC6(a) rests on - a POLICY.md section
            # outside both compared regions costs the store nothing on the policy axis.
            $store = script:New-FixtureStore
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Text | Should -Match 'RESULT: clean'
            $r.Text | Should -Match 'policy: split - stanza and policy file both match the reference'
            $r.Code | Should -Be 0
            (Get-Content -LiteralPath $store.Policy -Raw) | Should -Match 'Sweep machinery \(not part of the compared text\)'
        }

        It 'parses every committed ledger record and slate row' {
            $store = script:New-FixtureStore
            (Get-MSLedger -Path $store.Ledger).Malformed | Should -BeNullOrEmpty
            (Get-MSSlateState -Path $store.Slate).Malformed | Should -BeNullOrEmpty
        }
    }

    Context 'AC1 - the exit record is decidable, and a proposal is never an exit' {
        It 'reads the six fields, and the status vocabulary, off a committed record' {
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger
            $ledger.State | Should -BeExactly 'present'
            $promotion = @($ledger.Records | Where-Object { $_.Identity -ceq 'reference_interrupted_eta@2026-07-05' })[0]
            $promotion.Status | Should -BeExactly 'executed'
            $promotion.Disposition | Should -BeExactly 'promote'
            $promotion.Name | Should -BeExactly 'reference_interrupted_eta'
            $promotion.Admitted | Should -BeExactly '2026-07-05'
            $promotion.Reason | Should -Not -BeNullOrEmpty
            $promotion.Destination | Should -Match 'merged to main'
            @($ledger.Records | ForEach-Object { $_.Status } | Sort-Object -Unique) |
                Should -Be @('executed', 'proposed', 'reconciled')
        }

        It 'never reads a proposal as an executed exit' {
            # The polarity that matters: the fixture carries a PROPOSED removal of an entry that
            # is still in the index. A reader that took it for an exit would call a live entry
            # gone. Asserted over the artifact - the proposal is present and the partition still
            # accounts the entry as hot.
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger
            $proposal = @($ledger.Records | Where-Object { $_.Status -ceq 'proposed' })[0]
            $proposal.Identity | Should -BeExactly 'reference_ordinary_alpha@2026-06-14'

            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index
            @($partition.accounted | Where-Object { $_.identity -ceq 'reference_ordinary_alpha@2026-06-14' })[0].how |
                Should -BeExactly 'still-hot'
        }

        It 'treats a record with no status as malformed rather than executed' {
            $store = script:New-FixtureStore
            script:Add-LedgerRecord -Path $store.Ledger -Rows @('2026-08-08 | promote | reference_tail_zeta@2026-07-22 | missing its status field | somewhere')
            $ledger = Get-MSLedger -Path $store.Ledger
            @($ledger.Malformed).Count | Should -Be 1
            @($ledger.Malformed)[0].Why | Should -Match 'expected 6 pipe-separated fields'
            # and it does not become an exit by being unreadable
            @($ledger.Records | Where-Object { -not $_.Malformed -and $_.Name -ceq 'reference_tail_zeta' }) | Should -BeNullOrEmpty
        }

        It 'rejects a status outside the vocabulary instead of guessing' {
            $store = script:New-FixtureStore
            script:Add-LedgerRecord -Path $store.Ledger -Rows @('2026-08-08 | done | promote | reference_tail_zeta@2026-07-22 | a status nobody defined | somewhere')
            @((Get-MSLedger -Path $store.Ledger).Malformed)[0].Why | Should -Match 'status must be one of'
        }

        It 'surfaces an executed record whose act never completed, first, at the next sweep' {
            # Record-before-act makes an interruption visible instead of silent. The fixture's
            # interrupted promotion has an executed record AND a live pointer.
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.incomplete_dispositions).Count | Should -Be 1
            @($inv.incomplete_dispositions)[0].Identity | Should -BeExactly 'reference_interrupted_eta@2026-07-05'
            @($inv.subjects)[0].group | Should -BeExactly '1-incomplete-disposition'
            @($inv.subjects)[0].name | Should -BeExactly 'reference_interrupted_eta'
        }

        It 'decides that a re-earned name is NOT exited, on the life key' {
            # The discriminator is the decision over the LIVING entry, not that two records
            # differ. reference_reused_name has an executed exit record for its FIRST life
            # (@2026-01-05) and a live body admitted @2026-08-08.
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger
            $live = Join-Path $store.Dir 'reference_reused_name.md'

            $verdict = Get-MSReconciliation -EntryPath $live -Ledger $ledger
            $verdict.Identity | Should -BeExactly 'reference_reused_name@2026-08-08'
            $verdict.Verdict | Should -BeExactly 'not-exited'

            # The negative polarity: keyed on NAME alone the same read says exited, which is the
            # wrong answer this field exists to prevent.
            @($ledger.Records | Where-Object { $_.Name -ceq 'reference_reused_name' -and $_.Status -ceq 'executed' }).Count |
                Should -BeGreaterThan 0 -Because 'a name-keyed read would find a record and call the live entry handled'
        }

        It 'decides that a life the ledger really did exit IS exited' {
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger
            # Same body, rewound to its first life: the only thing that changed is the life key.
            $firstLife = Join-Path $store.Dir 'reference_reused_name_firstlife.md'
            $rewound = @([System.IO.File]::ReadAllLines((Join-Path $store.Dir 'reference_reused_name.md')) |
                    ForEach-Object { $_ -replace 'admitted: 2026-08-08', 'admitted: 2026-01-05' })
            [System.IO.File]::WriteAllLines($firstLife, $rewound)
            # The identity is derived from the FILENAME, so name it back for the read.
            $asFirstLife = Join-Path $store.Dir 'reference_reused_name.md'
            [System.IO.File]::WriteAllLines($asFirstLife, $rewound)
            (Get-MSReconciliation -EntryPath $asFirstLife -Ledger $ledger).Verdict | Should -BeExactly 'exited'
        }

        It 'reports undecidable - not exited, not not-exited - for an entry with no life binding' {
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger
            $verdict = Get-MSReconciliation -EntryPath (Join-Path $store.Dir 'reference_legacy_unknown.md') -Ledger $ledger
            $verdict.Identity | Should -BeExactly 'reference_legacy_unknown@unknown'
            $verdict.Verdict | Should -BeExactly 'undecidable'
            $verdict.Verdict | Should -Not -BeExactly 'exited'
            $verdict.Verdict | Should -Not -BeExactly 'not-exited'
        }

        It 'states its retention bound, its append discipline, and which policy rules reach it' {
            $script:RecordsText | Should -Match 'reconciled.{0,80}at least one\s+further sweep'
            $script:RecordsText | Should -Match 'ledger-compaction'
            $script:RecordsText | Should -Match 'Writing is append-only'
            $script:RecordsText | Should -Match 'R1 and R2 do not reach them'
            $script:RecordsText | Should -Match 'R3 reaches all three'
            $script:RecordsText | Should -Match 'size budget does not reach them'
            $script:RecordsText | Should -Match 'written before the act it authorizes'
        }
    }

    Context 'AC2 - the sweep walks both populations, takes the first things first, and covers the authorized moves' {
        It 'walks the index pointers AND the entry files no pointer points at' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.subjects | Where-Object { $_.population -eq 'pointer' }).Count | Should -Be 11
            $orphans = @($inv.subjects | Where-Object { $_.population -eq 'orphan-body' })
            @($orphans).Count | Should -Be 1
            @($orphans)[0].name | Should -BeExactly 'reference_critical_orphan'
        }

        It 'surfaces every critical entry before any other disposition, including one in an orphan body' {
            # The fixture puts its critical pointer sixth in file order and its critical orphan
            # outside the index entirely: an ordering that came from file position would miss both.
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1

            $body = @([System.IO.File]::ReadAllLines($store.Index))
            $criticalLine = [array]::FindIndex([string[]]$body, [Predicate[string]] { param($l) $l -match 'reference_critical_delta\.md' })
            $firstPointer = [array]::FindIndex([string[]]$body, [Predicate[string]] { param($l) $l -match '\]\(reference_|\]\(project_|\]\(feedback_' })
            $criticalLine | Should -BeGreaterThan $firstPointer -Because 'the critical entry must not be first in file order, or the ordering proves nothing'

            $ordered = @($inv.subjects | ForEach-Object { $_.group })
            $criticalPositions = @(0..($ordered.Count - 1) | Where-Object { $ordered[$_] -eq '2-critical' })
            $otherPositions = @(0..($ordered.Count - 1) | Where-Object { $ordered[$_] -notin @('1-incomplete-disposition', '2-critical') })
            (@($criticalPositions) | Measure-Object -Maximum).Maximum |
                Should -BeLessThan (@($otherPositions) | Measure-Object -Minimum).Minimum
            @($inv.subjects | Where-Object { $_.group -eq '2-critical' } | ForEach-Object { $_.name } | Sort-Object) |
                Should -Be @('reference_critical_delta', 'reference_critical_orphan')
        }

        It 'treats an unassessed entry as unassessed rather than as ordinary' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.subjects | Where-Object { $_.group -eq '4-unassessed' } | ForEach-Object { $_.name } | Sort-Object) |
                Should -Be @('reference_legacy_unknown', 'reference_reused_name')
            @($inv.subjects | Where-Object { $_.name -ceq 'reference_reused_name' })[0].critical |
                Should -BeExactly 'unassessed'
        }

        It 'maps every authorized size-reduction move to a named disposition, move by move' {
            # The covering mapping quoted move-by-move. A vocabulary that leaves an authorized
            # move unreachable quietly withdraws it from the sweep's repertoire.
            $expected = @(
                @{ move = '1. Promote and remove'; disposition = 'promote' },
                @{ move = '2. Demote to the cold archive'; disposition = 'demote' },
                @{ move = '3. Demote a settled `project_` entry'; disposition = 'settle-in-place' },
                @{ move = '4. Merge settled `project_` pointers onto one line'; disposition = 'settle-in-place' },
                @{ move = '5. Deduplicate'; disposition = 'dedupe-into' },
                @{ move = '6. Remove an obsolete entry'; disposition = 'remove-obsolete' })
            foreach ($row in $expected) {
                $line = @($script:ProcedureText -split "`r?`n" | Where-Object { $_.StartsWith("| $($row.move)", [System.StringComparison]::Ordinal) })
                @($line).Count | Should -Be 1 -Because "the covering mapping must carry a row for '$($row.move)'"
                @($line)[0] | Should -Match ([regex]::Escape("``$($row.disposition)``"))
            }
            # And the canonical policy really does authorize exactly those six.
            $canon = ($script:CanonicalLines -join "`n")
            foreach ($n in 1..6) { $canon | Should -Match "(?m)^$n\. \*\*" }
            $canon | Should -Not -Match '(?m)^7\. \*\*'
        }

        It 'disambiguates the two senses of demote, and only one of them books an exit' {
            $script:ProcedureText | Should -Match '"Demote" is two moves, and only one of them is an exit'
            # settle-in-place is not an exit; demote is. The distinction is machine-readable in
            # the core, not only in the prose.
            $slate = Get-MSSlateState -Path (script:New-FixtureStore).Slate
            (Test-MSExitAllowed -SlateState $slate -Identity 'project_settled_beta@2026-06-20' -Disposition 'settle-in-place').Why |
                Should -Match 'does not remove the entry from the index'
            (Test-MSExitAllowed -SlateState $slate -Identity 'project_settled_beta@2026-06-20' -Disposition 'demote' -DestinationCarriesLesson $true -DestinationLanded $true).Allowed |
                Should -BeTrue
            $script:RecordsText | Should -Match 'destination'
        }

        It 'grandfathers the pre-rule corpus out of remove-fails-admission, and does not grandfather the rest' {
            # Both polarities. An unscoped rule condemns the whole existing corpus at the first
            # sweep, with the owner's fatigue as the only guard.
            $preRule = Test-MSAdmissionRemovalEligible -Identity 'feedback_prerule_epsilon@2026-05-02' -AdmissionRuleLandedOn $script:AdmissionRuleLanded
            $preRule.Eligible | Should -BeFalse
            $preRule.Why | Should -Match 'grandfathered'

            $postRule = Test-MSAdmissionRemovalEligible -Identity 'reference_critical_delta@2026-07-10' -AdmissionRuleLandedOn $script:AdmissionRuleLanded
            $postRule.Eligible | Should -BeTrue

            $noDate = Test-MSAdmissionRemovalEligible -Identity 'reference_legacy_unknown@unknown' -AdmissionRuleLandedOn $script:AdmissionRuleLanded
            $noDate.Eligible | Should -BeFalse
        }

        It 'carries the residue step on evaporate-on-close and names promotion the primary outflow' {
            $script:ProcedureText | Should -Match '`evaporate-on-close` carries a residue step'
            $script:ProcedureText | Should -Match 'written as a `reference_` entry'
            $script:ProcedureText | Should -Match '\*\*Promotion is the primary outflow\.\*\*'
        }

        It 'refuses to exit a critical entry whose destination does not carry the lesson' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate
            $destination = Join-Path $store.Dir 'pretend-permanent-home.md'
            [System.IO.File]::WriteAllText($destination, "# A home that does not carry it yet`n")
            $probe = 'A marker head that is not self-closed is dropped in silence.'

            $carries = Test-MSDestinationCarriesLesson -Path $destination -Probe $probe
            $carries.Carries | Should -BeFalse
            $refused = Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition 'promote' -DestinationCarriesLesson $carries.Carries -DestinationLanded $true
            $refused.Allowed | Should -BeFalse
            $refused.Why | Should -Match 'read and confirmed to carry the lesson'

            # The other polarity: once the destination really carries it, the same call allows it.
            [System.IO.File]::AppendAllText($destination, "$probe`n")
            $now = Test-MSDestinationCarriesLesson -Path $destination -Probe $probe
            $now.Carries | Should -BeTrue
            (Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition 'promote' -DestinationCarriesLesson $now.Carries -DestinationLanded $true).Allowed |
                Should -BeTrue
        }

        It 'refuses a landing that is only on an unmerged branch' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate
            $verdict = Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition 'promote' -DestinationCarriesLesson $true -DestinationLanded $false
            $verdict.Allowed | Should -BeFalse
            $verdict.Why | Should -Match 'merged to the default branch'
            $script:ProcedureText | Should -Match 'means merged to the default branch'
        }

        It 'applies the landing gate to demotion and removal too, not only promotion' {
            # The canonical text is explicit that demotion counts as leaving. A gate scoped to
            # promotion lets a critical lesson out through the archive instead.
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate
            foreach ($d in @('demote', 'remove-obsolete', 'dedupe-into', 'remove-fails-admission', 'evaporate-on-close')) {
                (Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition $d -DestinationCarriesLesson $false -DestinationLanded $false).Allowed |
                    Should -BeFalse -Because "a critical entry must not leave via $d without a verified landing"
            }
        }

        It 'refuses to disposition an entry nobody has assessed' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate
            $verdict = Test-MSExitAllowed -SlateState $slate -Identity 'reference_reused_name@2026-08-08' -Disposition 'promote' -DestinationCarriesLesson $true -DestinationLanded $true
            $verdict.Allowed | Should -BeFalse
            $verdict.Why | Should -Match 'has not been assessed'
        }

        It 'leaves the index byte-identical on an unattended walk that records proposals' {
            # Asserted over the artifacts - index digest, and the statuses actually written - not
            # over a transcript saying "removed nothing".
            $store = script:New-FixtureStore
            $before = (Get-FileHash -LiteralPath $store.Index -Algorithm SHA256).Hash
            $ledgerBefore = @((Get-MSLedger -Path $store.Ledger).Records).Count

            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | proposed | remove-obsolete | reference_obsolete_gamma@2026-06-25 | the surface it describes no longer exists | none (accepted recall loss)',
                '2026-08-08 | proposed | dedupe-into | reference_dupe_source@2026-07-01 | the survivor carries the same lesson | reference_dupe_survivor.md')

            (Get-FileHash -LiteralPath $store.Index -Algorithm SHA256).Hash | Should -BeExactly $before
            $after = Get-MSLedger -Path $store.Ledger
            @($after.Records).Count | Should -Be ($ledgerBefore + 2)
            @($after.Records | Where-Object { $_.Date -eq $script:Sweep1 } | ForEach-Object { $_.Status } | Sort-Object -Unique) |
                Should -Be @('proposed')
            # and the partition still accounts for everything, because nothing left
            (Test-MSPartition -Inventory $inv -IndexPath $store.Index).result | Should -BeExactly 'accounted'
        }

        It 'says in the procedure which acts an unattended session may and may not take' {
            $script:ProcedureText | Should -Match 'Execute any exit, demotion, body deletion, structural rewrite'
            $script:ProcedureText | Should -Match 'Admit a new entry'
            $script:ProcedureText | Should -Match 'Append a `proposed` ledger record'
        }
    }

    Context 'AC3 - deferral expires, and a critical entry is not deferred twice' {
        BeforeAll {
            # Sweep 1, executed once and read by every case below: defer one critical entry and
            # one ordinary one, and initiate one landing toward a named vehicle.
            $script:S = script:New-FixtureStore
            script:Add-SlateRow -Path $script:S.Slate -Rows @(
                '2026-08-08 | reference_critical_delta@2026-07-10 | deferral | 1 | until 2026-09-07 - waiting on the marker-contract change',
                '2026-08-08 | reference_ordinary_alpha@2026-06-14 | deferral | 1 | until 2026-09-07 - re-check after the retry-cap fix',
                '2026-08-08 | reference_critical_orphan@2026-06-30 | landing | in-flight | agent-orchestra PR #1031')
            script:Add-LedgerRecord -Path $script:S.Ledger -Rows @(
                '2026-08-08 | executed | keep-hot-with-expiry | reference_critical_delta@2026-07-10 | the destination is not decided yet | none - deferred to 2026-09-07',
                '2026-08-08 | executed | keep-hot-with-expiry | reference_ordinary_alpha@2026-06-14 | the fix that would settle it is not merged | none - deferred to 2026-09-07')
            $script:Sweep2Inventory = New-MSInventory -IndexPath $script:S.Index -AsOf $script:Sweep2
            $script:Sweep2Slate = Get-MSSlateState -Path $script:S.Slate
        }

        It 'brings an expired deferral back into the slate' {
            $alpha = @($script:Sweep2Inventory.subjects | Where-Object { $_.name -ceq 'reference_ordinary_alpha' })[0]
            $alpha.deferral_count | Should -Be 1
            $alpha.deferred_until | Should -BeExactly '2026-09-07'
            $alpha.group | Should -BeExactly '3-expired-deferral'
        }

        It 'does not bring an unexpired deferral back' {
            # The polarity that stops the expiry step passing for the wrong reason.
            $atSweep1 = New-MSInventory -IndexPath $script:S.Index -AsOf $script:Sweep1
            @($atSweep1.subjects | Where-Object { $_.name -ceq 'reference_ordinary_alpha' })[0].group |
                Should -BeExactly '5-other'
        }

        It 'blocks a second deferral of a critical entry, and writes no second deferral row' {
            $verdict = Test-MSDeferralAllowed -SlateState $script:Sweep2Slate -Identity 'reference_critical_delta@2026-07-10'
            $verdict.Allowed | Should -BeFalse
            $verdict.Why | Should -Match 'may not be deferred twice'

            # The evidence is the artifact: following the procedure, the refusal is what gets
            # appended, and the deferral count on the slate does not move.
            script:Add-LedgerRecord -Path $script:S.Ledger -Rows @(
                "2026-09-15 | proposed | keep-hot-with-expiry | reference_critical_delta@2026-07-10 | REFUSED: $($verdict.Why) | none")
            $after = Get-MSSlateState -Path $script:S.Slate
            @($after.Rows | Where-Object { $_.Identity -ceq 'reference_critical_delta@2026-07-10' -and $_.Track -ceq 'deferral' }).Count |
                Should -Be 1
            (Get-MSTrackValue -SlateState $after -Identity 'reference_critical_delta@2026-07-10' -Track 'deferral').Value |
                Should -Be 1
        }

        It 'allows a second deferral of an ORDINARY entry, so the block is about criticality' {
            (Test-MSDeferralAllowed -SlateState $script:Sweep2Slate -Identity 'reference_ordinary_alpha@2026-06-14').Allowed |
                Should -BeTrue
        }

        It 'surfaces a landing in flight with its vehicle, and does not count it as a deferral' {
            $orphan = @($script:Sweep2Inventory.subjects | Where-Object { $_.name -ceq 'reference_critical_orphan' })[0]
            $orphan.landing | Should -BeExactly 'in-flight'
            $orphan.landing_vehicle | Should -Match 'PR #1031'
            $orphan.deferral_count | Should -Be 0
            $orphan.group | Should -BeExactly '2-critical'
            # and a critical entry whose only state is an in-flight landing may still be deferred:
            # the in-flight state has not consumed its one deferral.
            (Test-MSDeferralAllowed -SlateState $script:Sweep2Slate -Identity 'reference_critical_orphan@2026-06-30').Allowed |
                Should -BeTrue
        }

        It 'reads the deferral state without replaying the exit record' {
            # The bound the flag and the count both carry. Deleting the ledger entirely must not
            # change what the slate reads.
            $noLedger = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8) + '-LEDGER.md')
            $state = Get-MSSlateState -Path $script:S.Slate
            (Get-MSTrackValue -SlateState $state -Identity 'reference_critical_delta@2026-07-10' -Track 'deferral').Value | Should -Be 1
            (Get-MSLedger -Path $noLedger).State | Should -BeExactly 'absent'
        }

        It 'refuses a deferral row with no expiry, so nothing can be parked forever' {
            $store = script:New-FixtureStore
            script:Add-SlateRow -Path $store.Slate -Rows @('2026-08-08 | reference_tail_zeta@2026-07-22 | deferral | 1 | hold for now')
            $bad = @((Get-MSSlateState -Path $store.Slate).Malformed)
            @($bad).Count | Should -Be 1
            @($bad)[0].Why | Should -Match "must carry 'until"
        }
    }

    Context 'AC4 - the partition check, the staleness step, and the destination measurement' {
        It 'catches a pointer dropped without a record from BEYOND a simulated truncation cut' {
            $store = script:New-FixtureStore
            $indexText = [System.IO.File]::ReadAllText($store.Index)
            $cut = [int][Math]::Floor((Measure-MIPCharacters -Text $indexText) * 0.80)
            $tailAt = $indexText.IndexOf('reference_tail_zeta.md', [System.StringComparison]::Ordinal)
            $tailAt | Should -BeGreaterThan $cut -Because 'the planted loss must sit outside the window a truncated load would carry'

            $fromDisk = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            $fromDisk.source | Should -BeExactly 'disk'

            # The sweep drops the pointer and records nothing - the exact act rule 1 forbids.
            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_tail_zeta'

            $caught = Test-MSPartition -Inventory $fromDisk -IndexPath $store.Index
            $caught.result | Should -BeExactly 'unaccounted'
            @($caught.unaccounted).Count | Should -Be 1
            @($caught.unaccounted)[0].identity | Should -BeExactly 'reference_tail_zeta@2026-07-22'
        }

        It 'does NOT catch it when the enumeration came from a truncated view - which is why the read is from disk' {
            # The discriminator for AC4(a). Same store, same drop, same check; the only difference
            # is where the enumeration came from. A partition of a short list agrees with itself.
            $store = script:New-FixtureStore
            $indexText = [System.IO.File]::ReadAllText($store.Index)
            $cut = [int][Math]::Floor((Measure-MIPCharacters -Text $indexText) * 0.80)

            $loadedViewDir = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Path $loadedViewDir -Force | Out-Null
            $loadedView = Join-Path $loadedViewDir 'MEMORY.md'
            [System.IO.File]::WriteAllText($loadedView, $indexText.Substring(0, $cut))
            $truncated = New-MSInventory -IndexPath $loadedView -AsOf $script:Sweep1
            @($truncated.subjects | Where-Object { $_.name -ceq 'reference_tail_zeta' }) |
                Should -BeNullOrEmpty -Because 'the tail is exactly what a truncated load loses'

            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_tail_zeta'
            (Test-MSPartition -Inventory $truncated -IndexPath $store.Index).result | Should -BeExactly 'accounted'
        }

        It 'accounts a demoted pointer through the archive and a promoted one through the record' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            $inv.archive.present | Should -BeFalse -Because 'a store that has never demoted anything has no archive yet'

            # demote: the archive is created at the first demotion, carrying the pointer unchanged
            $pointer = @([System.IO.File]::ReadAllLines($store.Index) | Where-Object { $_ -match 'reference_obsolete_gamma\.md' })[0]
            [System.IO.File]::WriteAllLines($store.Archive, @(
                    '# Cold archive', '',
                    'Demoted pointers. This file is not loaded at session start.', '',
                    '## Demoted 2026-08-08', '', $pointer))
            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_obsolete_gamma'
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | demote | reference_obsolete_gamma@2026-06-25 | its subject no longer exists, and nobody promoted it | ARCHIVE.md')

            # promote: pointer gone, executed record carries the life key
            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_dupe_source'
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | dedupe-into | reference_dupe_source@2026-07-01 | folded into the survivor | reference_dupe_survivor.md')

            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index
            $partition.result | Should -BeExactly 'accounted'
            @($partition.accounted | Where-Object { $_.name -ceq 'reference_obsolete_gamma' })[0].how | Should -BeExactly 'demoted'
            @($partition.accounted | Where-Object { $_.name -ceq 'reference_dupe_source' })[0].how | Should -BeExactly 'exited-with-record'
        }

        It 'does not accept an exit record written under a different life' {
            # A record for another life of the same name accounts for nothing.
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_tail_zeta'
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | promote | reference_tail_zeta@2025-01-01 | a record for a different life of this name | somewhere (merged to main)')
            (Test-MSPartition -Inventory $inv -IndexPath $store.Index).result | Should -BeExactly 'unaccounted'
        }

        It 'reports an orphan body the sweep never looked at as unaccounted' {
            # The orphan branch's negative polarity. An orphan has no pointer to be still-hot, so
            # "the sweep walked it" is the only thing that can account for it staying put - and a
            # walk that never assessed it has not accounted for anything.
            $store = script:New-FixtureStore
            $unseen = Join-Path $store.Dir 'reference_never_looked_at.md'
            [System.IO.File]::WriteAllLines($unseen, @(
                    '---', 'name: reference-never-looked-at', 'description: "An orphan nobody assessed."',
                    'metadata:', '  node_type: memory', '  type: reference', '  admitted: 2026-07-19', '---', '',
                    'An orphan body sitting in the store with no pointer and no slate row.'))

            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.subjects | Where-Object { $_.name -ceq 'reference_never_looked_at' }).Count |
                Should -Be 1 -Because 'the corpus walk must find it even though no pointer does'

            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index
            $partition.result | Should -BeExactly 'unaccounted'
            @($partition.unaccounted | Where-Object { $_.name -ceq 'reference_never_looked_at' })[0].why |
                Should -Match 'neither dispositioned nor assessed'

            # The other polarity: the assessed orphan in the same store IS accounted for.
            @($partition.accounted | Where-Object { $_.name -ceq 'reference_critical_orphan' })[0].how |
                Should -BeExactly 'orphan-assessed'
        }

        It 'reports an unreadable record instead of passing over it' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            script:Add-LedgerRecord -Path $store.Ledger -Rows @('2026-08-08 | executed | promote | not-a-life-key | broken | somewhere')
            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index
            $partition.result | Should -BeExactly 'unaccounted'
            @($partition.ledger_malformed).Count | Should -Be 1
        }

        It 'handles all three shipped size-axis states, including the one with no observation' {
            # State 1: no values region at all - the lawful opt-out.
            $none = script:New-FixtureStore -OmitValuesBlock
            $r1 = script:Invoke-PolicyCheck -IndexPath $none.Index
            $r1.Report.Size.State | Should -BeExactly 'not-evaluated'
            $r1.Code | Should -Be 0

            # State 2: a region with an observation - measured, and stale against the bound.
            $measured = script:New-FixtureStore
            $r2 = script:Invoke-PolicyCheck -IndexPath $measured.Index -AsOf $script:Sweep1
            $r2.Report.Size.State | Should -BeExactly 'within'
            $r2.Report.Size.Stale | Should -BeTrue -Because 'the fixture observation is older than the 30-day bound at sweep 1'
            $r2.Code | Should -Be 0 -Because 'a stale observation is reported, not treated as a defect'

            # State 3: a region present with NO usable observation - a defect, and the state in
            # which there is no freshest date for a staleness step to read.
            $broken = script:New-FixtureStore
            $policyLines = @([System.IO.File]::ReadAllLines($broken.Policy) | Where-Object { -not $_.StartsWith('limit_observation:', [System.StringComparison]::Ordinal) })
            [System.IO.File]::WriteAllLines($broken.Policy, $policyLines)
            $r3 = script:Invoke-PolicyCheck -IndexPath $broken.Index
            $r3.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r3.Text | Should -Match 'no limit observation'
            $r3.Code | Should -Be 1

            $script:ProcedureText | Should -Match 'no values region at all'
            $script:ProcedureText | Should -Match 'a values region with no usable observation'
            $script:ProcedureText | Should -Match 'defers the re-observation with a record'
        }

        It 'appends a re-observation and leaves every prior row byte-identical' {
            $store = script:New-FixtureStore
            $before = @(script:Get-ValuesRegion -PolicyPath $store.Policy)
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.AddRange([string[]]@([System.IO.File]::ReadAllLines($store.Policy)))
            $at = $lines.FindIndex({ param($l) $l.Trim() -ceq '<!-- store-values-end -->' })
            $lines.Insert($at, 'limit_observation: 2026-09-15 | 25600 | characters | truncation-boundary test (sweep 2)')
            [System.IO.File]::WriteAllLines($store.Policy, $lines)

            $after = @(script:Get-ValuesRegion -PolicyPath $store.Policy)
            @($after).Count | Should -Be (@($before).Count + 1)
            for ($i = 0; $i -lt @($before).Count; $i++) {
                $after[$i] | Should -BeExactly $before[$i] -Because 'a re-observation appends; it never rewrites a prior row'
            }
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index -AsOf $script:Sweep2
            $r.Report.Size.ObservedOn | Should -BeExactly '2026-09-15' -Because 'the freshest observation governs'
            $r.Code | Should -Be 0
        }

        It 'tolerates and reports the SWEEP''S OWN key when it is x-prefixed' {
            # Produced by following step 7, not by re-running chunk 1's shipped fixtures: the key
            # is the one the procedure tells a sweep to write, into a store that already records
            # budget inputs.
            $store = script:New-FixtureStore
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.AddRange([string[]]@([System.IO.File]::ReadAllLines($store.Policy)))
            $at = $lines.FindIndex({ param($l) $l.Trim() -ceq '<!-- store-values-end -->' })
            $lines.Insert($at, 'x-last-sweep: 2026-08-08')
            [System.IO.File]::WriteAllLines($store.Policy, $lines)

            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Code | Should -Be 0
            @($r.Report.Size.IgnoredKeys) | Should -Contain 'x-last-sweep'
            $r.Text | Should -Match 'x-last-sweep'
        }

        It 'errors on the same key written bare, which is why the prefix is not optional' {
            $store = script:New-FixtureStore
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.AddRange([string[]]@([System.IO.File]::ReadAllLines($store.Policy)))
            $at = $lines.FindIndex({ param($l) $l.Trim() -ceq '<!-- store-values-end -->' })
            $lines.Insert($at, 'last_sweep: 2026-08-08')
            [System.IO.File]::WriteAllLines($store.Policy, $lines)

            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Code | Should -Be 1
            $r.Text | Should -Match "unrecognized key 'last_sweep'"
        }

        It 'repeats x-last-sweep rather than rewriting it, and stays clean' {
            # Nothing governs a repeated x- key and the append bound forbids rewriting one, so the
            # key repeats and the freshest row governs. Both rows survive.
            $store = script:New-FixtureStore -ExtraValues @('x-last-sweep: 2026-08-08', 'x-last-sweep: 2026-09-15')
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index -AsOf $script:Sweep2
            $r.Code | Should -Be 0
            @(script:Get-ValuesRegion -PolicyPath $store.Policy | Where-Object { $_.StartsWith('x-last-sweep:', [System.StringComparison]::Ordinal) }).Count |
                Should -Be 2
            $script:ProcedureText | Should -Match 'repeats,\s*\n?one row per sweep, and the freshest date governs'
        }

        It 'leaves a values-less store still clean after a sweep' {
            # The protected class. A sweep of a store that opted out of measurement writes nothing
            # to the values region, so the store still reads not evaluated and still exits 0.
            $store = script:New-FixtureStore -OmitValuesBlock
            $policyBefore = (Get-FileHash -LiteralPath $store.Policy -Algorithm SHA256).Hash

            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | ledger-compaction | reference_ordinary_alpha@2026-06-14 | this store records its sweep dates here, having no values region | LEDGER.md')

            (Get-FileHash -LiteralPath $store.Policy -Algorithm SHA256).Hash | Should -BeExactly $policyBefore
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Report.Size.State | Should -BeExactly 'not-evaluated'
            $r.Text | Should -Match 'RESULT: clean'
            $r.Code | Should -Be 0
            (Test-MSPartition -Inventory $inv -IndexPath $store.Index).result | Should -BeExactly 'accounted'
        }

        It 'flips a values-less store from clean to defects if a sweep writes the key into it - which is why it must not' {
            # The hazard, executed rather than hypothesized. The region's presence is keyed on its
            # markers, so a region holding only an x- key records budget inputs the checker cannot
            # use: could-not-verify, exit 1, on a store that was fine.
            $store = script:New-FixtureStore -OmitValuesBlock
            (script:Invoke-PolicyCheck -IndexPath $store.Index).Code | Should -Be 0

            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.AddRange([string[]]@([System.IO.File]::ReadAllLines($store.Policy)))
            $at = $lines.FindIndex({ param($l) $l.Trim() -ceq '<!-- policy-canonical-begin -->' })
            $lines.InsertRange($at, [string[]]@('<!-- store-values-begin -->', 'x-last-sweep: 2026-08-08', '<!-- store-values-end -->', ''))
            [System.IO.File]::WriteAllLines($store.Policy, $lines)

            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r.Code | Should -Be 1
            $script:ProcedureText | Should -Match 'does not acquire one by being swept'
        }

        It 'produces a destination measurement with value, unit, date and surface, by its stated command' {
            $store = script:New-FixtureStore
            $destination = Join-Path $store.Dir 'pretend-CLAUDE.md'
            [System.IO.File]::WriteAllText($destination, "# Admission rule`r`nline two`r`n")
            $m = New-MSSurfaceMeasurement -Path $destination -AsOf $script:Sweep1
            $m.date | Should -BeExactly '2026-08-08'
            $m.unit | Should -BeExactly 'characters'
            $m.surface | Should -Match 'pretend-CLAUDE'
            # The store's own counting rule: CRLF normalized to a single LF before counting, so
            # the two CRLFs in the file on disk count one each, not two.
            $m.value | Should -Be 26
            $m.value | Should -BeLessThan ([System.IO.File]::ReadAllText($destination).Length) -Because 'the raw file carries two CR characters the counting rule normalizes away'
            (Test-MSSurfaceMeasurement -Record (Format-MSSurfaceMeasurement -Measurement $m)).Conforming | Should -BeTrue
        }

        It 'reports a measurement missing its unit or its surface as non-conforming' {
            (Test-MSSurfaceMeasurement -Record '2026-08-08 | 2548 | bytes | ~/.claude/CLAUDE.md | by hand').Conforming |
                Should -BeFalse
            @((Test-MSSurfaceMeasurement -Record '2026-08-08 | 2548 | bytes | ~/.claude/CLAUDE.md | by hand').Problems) |
                Should -Match "unit must be 'characters'"
            $noSurface = Test-MSSurfaceMeasurement -Record '2026-08-08 | 2548 | characters |  | by hand'
            $noSurface.Conforming | Should -BeFalse
            @($noSurface.Problems) | Should -Match 'surface must name the file measured'
            (Test-MSSurfaceMeasurement -Record '2026-08-08 | 2548 | characters').Conforming | Should -BeFalse
        }

        It 'refuses the destination the policy check refuses, which is why this instrument exists' {
            # The claim the procedure makes about the shipped checker, executed.
            $store = script:New-FixtureStore
            $destination = Join-Path $store.Dir 'pretend-CLAUDE.md'
            [System.IO.File]::WriteAllText($destination, "# Admission rule`n")
            $report = Invoke-MemoryIndexPolicyCheck -IndexPath $destination -AsOf $script:Sweep1
            $report.ExitCode | Should -Be 2 -Because 'the check refuses a file that is not an index'
            (New-MSSurfaceMeasurement -Path $destination -AsOf $script:Sweep1).value | Should -BeGreaterThan 0
        }
    }

    Context 'AC5 - the checker and the store are untouched in the ways the parent pinned' {
        It 'keeps the checker at exactly three parameters and four axes' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:PolicyEntryPoint, [ref]$null, [ref]$null)
            @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } | Sort-Object) |
                Should -Be @('IndexPath', 'Json', 'PolicyReferencePath')
            $store = script:New-FixtureStore
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            @(($r.Text -split "`r?`n") | Where-Object { $_ -match '^(policy|size|subjects_without_hook|unattributed_shared_notes):' }).Count |
                Should -Be 4
        }

        It 'never writes to the store from any of the three instruments' {
            $store = script:New-FixtureStore
            $before = script:Get-FileDigests -Dir $store.Dir
            $artifact = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')

            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            [System.IO.File]::WriteAllText($artifact, ($inv | ConvertTo-Json -Depth 6))
            Test-MSPartition -Inventory ([System.IO.File]::ReadAllText($artifact) | ConvertFrom-Json) -IndexPath $store.Index | Out-Null
            New-MSSurfaceMeasurement -Path $store.Index -AsOf $script:Sweep1 | Out-Null

            $after = script:Get-FileDigests -Dir $store.Dir
            @($after.Keys | Sort-Object) | Should -Be @($before.Keys | Sort-Object)
            foreach ($name in $before.Keys) { $after[$name] | Should -BeExactly $before[$name] }
        }

        It 'depends on no path outside the repository' {
            # No committed test may depend on the owner's live store existing.
            $suite = Get-Content -LiteralPath $PSCommandPath -Raw
            $suite | Should -Not -Match '\.claude[/\\]projects[/\\]C--Users'
            $suite | Should -Not -Match 'C:\\Users\\'
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures/memory-sweep') -Recurse -File)) {
                (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match '\.claude[/\\]projects[/\\]C--Users'
            }
        }
    }

    Context 'AC6 - reachable from where its readers read, and its claims about the checker are pinned' {
        It 'walks the pointer chain from the skill to the procedure to the record shapes' {
            # Paths stated in text, never a directory inferred from a sibling path.
            $script:SkillText | Should -Match 'references/sweep-procedure\.md'
            $script:SkillText | Should -Match 'references/store-records\.md'
            Test-Path -LiteralPath $script:ProcedureDoc -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $script:RecordsDoc -PathType Leaf | Should -BeTrue
            $script:ProcedureText | Should -Match 'skills/agent-memory-compaction/references/store-records\.md'
            $script:RecordsText | Should -Match 'skills/agent-memory-compaction/references/sweep-procedure\.md'
            foreach ($s in @($script:InventoryScript, $script:PartitionScript, $script:MeasureScript)) {
                Test-Path -LiteralPath $s -PathType Leaf | Should -BeTrue
                $script:ProcedureText | Should -Match ([regex]::Escape((Split-Path -Leaf $s)))
            }
        }

        It 'gives a store that split BEFORE this machinery a path to it, at its first sweep' {
            # The generation the adoption instructions cannot reach. Its POLICY.md has no
            # machinery section until step 0 writes one - and writing it keeps the store clean.
            $old = script:New-FixtureStore -OmitMachinerySection
            (Get-Content -LiteralPath $old.Policy -Raw) | Should -Not -Match 'Sweep machinery'
            (script:Invoke-PolicyCheck -IndexPath $old.Index).Code | Should -Be 0

            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.AddRange([string[]]@([System.IO.File]::ReadAllLines($old.Policy)))
            $at = $lines.FindIndex({ param($l) $l.Trim() -ceq '<!-- policy-canonical-begin -->' })
            $lines.InsertRange($at, [string[]]$script:MachinerySection)
            [System.IO.File]::WriteAllLines($old.Policy, $lines)

            $after = script:Invoke-PolicyCheck -IndexPath $old.Index
            $after.Text | Should -Match 'RESULT: clean'
            $after.Report.HeaderComplete | Should -BeTrue -Because 'the section sits outside both compared regions'
            (Get-Content -LiteralPath $old.Policy -Raw) | Should -Match 'references/sweep-procedure\.md'
        }

        It 'gives a store adopting the split AFTER this machinery the same pointer, at adoption' {
            $new = script:New-FixtureStore
            (Get-Content -LiteralPath $new.Policy -Raw) | Should -Match 'references/sweep-procedure\.md'
            (script:Invoke-PolicyCheck -IndexPath $new.Index).Code | Should -Be 0
            # and the adoption instructions tell an adopter to write it
            $script:SkillText | Should -Match 'Limb 2'
            $script:SkillText | Should -Match 'Sweep machinery'
        }

        It 'says on the skill''s discovery surfaces that it now carries sweep machinery' {
            $frontmatter = @($script:SkillText -split "`r?`n")[0..8] -join "`n"
            $frontmatter | Should -Match 'sweep'
            # the repo-wide quick-validate contract: DO NOT USE FOR stays on the description line
            $descriptionLine = @($script:SkillText -split "`r?`n" | Where-Object { $_.StartsWith('description:', [System.StringComparison]::Ordinal) })
            @($descriptionLine).Count | Should -Be 1
            @($descriptionLine)[0] | Should -Match 'DO NOT USE FOR:'
            $script:SkillText | Should -Match '(?s)## When to Use.{0,1200}sweep'
        }

        It 'states the condition under which a sweep is due, in terms a session can observe' {
            $script:ProcedureText | Should -Match '## When a sweep is due'
            $script:ProcedureText | Should -Match 'reports\s+`size:`\s+\*\*over\*\*'
            $script:ProcedureText | Should -Match 'stale\*\* against the store''s staleness bound'
            $script:ProcedureText | Should -Match "store's owner calls one"
        }

        It 'pins every claim the new documentation makes about checker behaviour' {
            # Each of these is asserted against an executed run elsewhere in this suite; this case
            # is the index that says which prose each run pins, so a later checker change turns a
            # test red instead of turning the procedure into a lie.
            $claims = @(
                @{ text = 'ignored and reported'; where = 'AC4 x- tolerance' },
                @{ text = 'a hard error unless it is `x-`-prefixed'; where = 'AC4 bare key' },
                @{ text = 'The region''s presence is keyed'; where = 'AC4 region creation' },
                @{ text = 'refuses a path that is not an index'; where = 'AC4 measurement instrument' },
                @{ text = 'reported, not treated as a defect'; where = 'AC4 staleness' })
            foreach ($c in $claims) {
                $script:ProcedureText.Contains($c.text, [System.StringComparison]::Ordinal) |
                    Should -BeTrue -Because "the procedure must carry the claim pinned by $($c.where)"
            }
        }
    }

    Context 'AC7 - the chunk-3-facing shapes are documented as interfaces' {
        It 'names each interface in a section that says what consumes it' {
            $script:RecordsText | Should -Match '## Interfaces the next chunk consumes'
            foreach ($interface in @(
                    'The ledger record', 'The proposal record', 'Entry identity',
                    'The critical flag', 'Keep-hot expiry', 'Landing in flight', 'The cold archive')) {
                $script:RecordsText | Should -Match ([regex]::Escape("**$interface**"))
            }
            $script:RecordsText | Should -Match 'an edit to the parent''s chunk boundary'
        }

        It 'states each interface concretely enough to be cited rather than re-derived' {
            $script:RecordsText | Should -Match 'proposed`? / `?executed`? / `?reconciled'
            $script:RecordsText | Should -Match '<entry-name>@<admitted-date>'
            $script:RecordsText | Should -Match 'metadata\.admitted'
            $script:RecordsText | Should -Match 'A-C36'
            $script:RecordsText | Should -Match 'A-C37'
        }
    }
}
