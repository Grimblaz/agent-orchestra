#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Executed demonstrations of the sweep procedure, its records, its gates, and its three procedural
    checks.

.DESCRIPTION
    The deliverable of agent-orchestra#1018 is documentation plus record shapes, and documentation
    whose demonstration is reading it back is planted green at documentation grain. So every
    demonstration here runs against a COMMITTED fixture store under fixtures/memory-sweep/, and
    asserts over the artifacts the procedure produces - records written, index bytes, exit codes -
    rather than over a transcript describing them.

    Contexts are organised by acceptance criterion. Cases whose name ends in a bracketed finding id
    (M1, M5, ...) pin a defect the adversarial review of PR #1026 sustained; each was red against
    the revision that shipped that defect.

    Two things this suite deliberately pins that are NOT code: the authority table's polarity cells
    and the settle-in-place Exit? cell. Both are prose a future unattended session reads as
    instruction, and both were invertible with the whole suite green.

    Dates are pinned and -AsOf is passed everywhere expiry, staleness or a future-date guard is in
    play.
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
        $script:Instruments = @(
            (Join-Path $script:SkillDir 'scripts/Get-MemorySweepInventory.ps1'),
            (Join-Path $script:SkillDir 'scripts/Test-MemorySweepDisposition.ps1'),
            (Join-Path $script:SkillDir 'scripts/Test-MemorySweepPartition.ps1'),
            (Join-Path $script:SkillDir 'scripts/Measure-MemorySurface.ps1'))
        $script:Fixture = Join-Path $PSScriptRoot 'fixtures/memory-sweep'

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

        $script:Sweep1 = [datetime]::ParseExact('2026-08-08', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $script:Sweep2 = [datetime]::ParseExact('2026-09-15', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $script:AdmissionRuleLanded = [datetime]::ParseExact('2026-06-01', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

        $script:MachinerySection = @(
            '## Sweep machinery (not part of the compared text)',
            '',
            'Sweeps of this store follow `skills/agent-memory-compaction/references/sweep-procedure.md`',
            'in the agent-orchestra plugin. Its records live beside this file: `LEDGER.md`, `SLATE.md`,',
            'and `ARCHIVE.md`. Their shapes are defined in',
            '`skills/agent-memory-compaction/references/store-records.md`.',
            '')

        function script:New-FixtureStore {
            param([switch]$OmitValuesBlock, [switch]$OmitMachinerySection, [string[]]$ExtraValues = @(), [string]$PolicyFileName = 'POLICY.md')

            $dir = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $body = @([System.IO.File]::ReadAllLines((Join-Path $script:Fixture 'index-body.md')))
            $indexLines = @("<!-- memory-policy-stanza-begin: $PolicyFileName -->") + $script:StanzaLines +
            @('<!-- memory-policy-stanza-end -->', '') + $body
            [System.IO.File]::WriteAllLines((Join-Path $dir 'MEMORY.md'), $indexLines)

            $policyLines = @('# Store policy', '')
            if (-not $OmitValuesBlock) {
                $values = @([System.IO.File]::ReadAllLines((Join-Path $script:Fixture 'store-values.txt')) | Where-Object { $_.Trim() -ne '' })
                $policyLines += @('<!-- store-values-begin -->') + $values + @($ExtraValues) + @('<!-- store-values-end -->', '')
            }
            if (-not $OmitMachinerySection) { $policyLines += $script:MachinerySection }
            $policyLines += @('<!-- policy-canonical-begin -->') + $script:CanonicalLines + @('<!-- policy-canonical-end -->')
            [System.IO.File]::WriteAllLines((Join-Path $dir $PolicyFileName), $policyLines)

            Copy-Item -LiteralPath (Join-Path $script:Fixture 'LEDGER.md') -Destination $dir
            Copy-Item -LiteralPath (Join-Path $script:Fixture 'SLATE.md') -Destination $dir
            foreach ($e in @(Get-ChildItem -LiteralPath (Join-Path $script:Fixture 'entries') -Filter '*.md' -File)) {
                Copy-Item -LiteralPath $e.FullName -Destination $dir
            }
            return [pscustomobject]@{
                Dir     = $dir
                Index   = Join-Path $dir 'MEMORY.md'
                Policy  = Join-Path $dir $PolicyFileName
                Ledger  = Join-Path $dir 'LEDGER.md'
                Slate   = Join-Path $dir 'SLATE.md'
                Archive = Join-Path $dir 'ARCHIVE.md'
            }
        }

        # A TRUE append - the whole point of the one-marker region shape. This is the discipline the
        # shipped text describes, exercised as written: no read, no rewrite, nothing a concurrent
        # writer can lose.
        function script:Add-Record { param([string]$Path, [string[]]$Rows)
            [System.IO.File]::AppendAllText($Path, (($Rows -join "`n") + "`n")) }
        function script:Add-LedgerRecord { param([string]$Path, [string[]]$Rows) script:Add-Record -Path $Path -Rows $Rows }
        function script:Add-SlateRow { param([string]$Path, [string[]]$Rows) script:Add-Record -Path $Path -Rows $Rows }

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
            return [pscustomobject]@{ Text = ((Format-MemoryIndexPolicyReport -Report $report) | Out-String); Code = $report.ExitCode; Report = $report }
        }

        function script:Get-ValuesRegion {
            param([string]$PolicyPath)
            $lines = @([System.IO.File]::ReadAllLines($PolicyPath))
            $r = Get-MIPMarkedRegion -Lines $lines -BeginMarker '<!-- store-values-begin -->' -EndMarker '<!-- store-values-end -->'
            if (-not $r.Found) { return @() }
            return @($r.Block)
        }
        function script:Add-ValuesRow {
            param([string]$PolicyPath, [string]$Row)
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.AddRange([string[]]@([System.IO.File]::ReadAllLines($PolicyPath)))
            $at = $lines.FindIndex({ param($l) $l.Trim() -ceq '<!-- store-values-end -->' })
            if ($at -lt 0) { throw 'no values region' }
            $lines.Insert($at, $Row)
            [System.IO.File]::WriteAllLines($PolicyPath, $lines)
        }

        function script:Row { param([string]$Doc, [string]$Prefix)
            return @(($Doc -split "`r?`n") | Where-Object { $_.StartsWith($Prefix, [System.StringComparison]::Ordinal) }) }

        $script:ProcedureText = [System.IO.File]::ReadAllText($script:ProcedureDoc)
        $script:RecordsText = [System.IO.File]::ReadAllText($script:RecordsDoc)
        $script:SkillText = [System.IO.File]::ReadAllText($script:Skill)
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'the fixture store is a conforming control' {
        It 'reports clean on all four axes with the sweep-machinery section present' {
            $store = script:New-FixtureStore
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Text | Should -Match 'RESULT: clean'
            $r.Text | Should -Match 'policy: split - stanza and policy file both match the reference'
            $r.Code | Should -Be 0
        }

        It 'parses every committed ledger record and slate row' {
            $store = script:New-FixtureStore
            (Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1).Malformed | Should -BeNullOrEmpty
            (Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1).Malformed | Should -BeNullOrEmpty
        }
    }

    Context 'AC1 - the exit record is decidable, and a proposal is never an exit' {
        It 'reads the six fields and the status vocabulary off a committed record' {
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            $ledger.State | Should -BeExactly 'present'
            $promotion = @($ledger.Records | Where-Object { $_.Identity -ceq 'reference_interrupted_eta@2026-07-05' })[0]
            $promotion.Status | Should -BeExactly 'executed'
            $promotion.Disposition | Should -BeExactly 'promote'
            $promotion.Name | Should -BeExactly 'reference_interrupted_eta'
            $promotion.Admitted | Should -BeExactly '2026-07-05'
            $promotion.Destination | Should -Match 'merged to main'
            @($ledger.Records | ForEach-Object { $_.Status } | Sort-Object -Unique) | Should -Be @('executed', 'proposed', 'reconciled')
        }

        It 'never reads a proposal as an executed exit' {
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            @($ledger.Records | Where-Object { $_.Status -ceq 'proposed' })[0].Identity | Should -BeExactly 'reference_ordinary_alpha@2026-06-14'
            $ledger.ExitsInForce.ContainsKey('reference_ordinary_alpha@2026-06-14') | Should -BeFalse
        }

        It 'treats a record with the wrong field count as malformed rather than executed' {
            $store = script:New-FixtureStore
            script:Add-LedgerRecord -Path $store.Ledger -Rows @('2026-08-08 | promote | reference_tail_zeta@2026-07-22 | missing its status | somewhere')
            $ledger = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            @($ledger.Malformed).Count | Should -Be 1
            @($ledger.Malformed)[0].Why | Should -Match 'exactly 6 pipe-separated fields'
            $ledger.ExitsInForce.ContainsKey('reference_tail_zeta@2026-07-22') | Should -BeFalse
        }

        It 'rejects a pipe inside a reason instead of shifting it into the destination [M6]' {
            $store = script:New-FixtureStore
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | demote | reference_tail_zeta@2026-07-22 | superseded by A | B, so it goes | ARCHIVE.md')
            $bad = @((Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1).Malformed)
            @($bad).Count | Should -Be 1
            @($bad)[0].Why | Should -Match 'No field may contain a pipe'
        }

        It 'refuses a future-dated record instead of letting it govern forever [M8]' {
            $store = script:New-FixtureStore
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2099-01-01 | executed | promote | reference_tail_zeta@2026-07-22 | mistyped year | somewhere (merged to main)')
            @((Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1).Malformed)[0].Why | Should -Match 'in the future'
        }

        It 'reports a calendar-invalid date as malformed rather than throwing [M17]' {
            # Both ParseExact sites: a slate until-date and a ledger identity.
            $store = script:New-FixtureStore
            script:Add-SlateRow -Path $store.Slate -Rows @('2026-08-01 | reference_tail_zeta@2026-07-22 | deferral | 1 | until 2026-02-30')
            { Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1 } | Should -Not -Throw
            @((Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1).Malformed)[0].Why | Should -Match 'real date'

            { Test-MSAdmissionRemovalEligible -Identity 'reference_x@2026-02-30' -AdmissionRuleLandedOn $script:AdmissionRuleLanded } | Should -Not -Throw
            (Test-MSAdmissionRemovalEligible -Identity 'reference_x@2026-02-30' -AdmissionRuleLandedOn $script:AdmissionRuleLanded).Eligible | Should -BeFalse

            # and the instrument still produces its artifact on such a store
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            $inv.subject_count | Should -BeGreaterThan 0
        }

        It 'refuses to read any record when the region marker appears twice [M13]' {
            $store = script:New-FixtureStore
            $text = [System.IO.File]::ReadAllText($store.Ledger)
            [System.IO.File]::WriteAllText($store.Ledger,
                "<!-- memory-ledger-begin -->`n2026-08-08 | executed | promote | reference_forged@2026-01-01 | forged | nowhere`n" + $text)
            $ledger = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            $ledger.State | Should -BeExactly 'duplicated'
            @($ledger.Records).Count | Should -Be 0
            $ledger.StateWhy | Should -Match 'which region governs has no answer'
        }

        It 'does not let a leading # erase a record [M15]' {
            $store = script:New-FixtureStore
            $lines = @([System.IO.File]::ReadAllLines($store.Ledger) | ForEach-Object {
                    if ($_ -match 'reference_interrupted_eta') { '#' + $_ } else { $_ } })
            [System.IO.File]::WriteAllLines($store.Ledger, $lines)
            $ledger = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            @($ledger.Malformed).Count | Should -Be 1 -Because 'a commented-out record is reported, not silently dropped'
            $ledger.ExitsInForce.ContainsKey('reference_interrupted_eta@2026-07-05') | Should -BeFalse
        }

        It 'surfaces an executed record whose act never completed, first, at the next sweep' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.incomplete_dispositions).Count | Should -Be 1
            @($inv.incomplete_dispositions)[0].Identity | Should -BeExactly 'reference_interrupted_eta@2026-07-05'
            @($inv.subjects)[0].group | Should -BeExactly '1-incomplete-disposition'
        }

        It 'lets a restore supersede an exit, so a restored entry stops being an incomplete disposition [M22]' {
            $store = script:New-FixtureStore
            $before = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($before.incomplete_dispositions).Count | Should -Be 1

            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | restore | reference_interrupted_eta@2026-07-05 | the promotion was abandoned; the pointer is back | MEMORY.md')
            $after = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($after.incomplete_dispositions).Count | Should -Be 0
            @($after.subjects | Where-Object { $_.name -ceq 'reference_interrupted_eta' })[0].group | Should -Not -BeExactly '1-incomplete-disposition'
        }

        It 'makes reconciled reachable by appending, so retention can key on it [M4]' {
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            # The committed fixture already carries the two-row shape for the first life.
            $key = "reference_reused_name@2026-01-05`0promote"
            $ledger.Effective.ContainsKey($key) | Should -BeTrue
            $ledger.Effective[$key].Status | Should -BeExactly 'reconciled' -Because 'the latest row governs, which is what makes the retention bound reachable'
            $ledger.ExitsInForce.ContainsKey('reference_reused_name@2026-01-05') | Should -BeTrue -Because 'a reconciled exit is still an exit'
            $script:RecordsText | Should -Match 'Effective status'
            $script:RecordsText | Should -Match 'the retention bound below is inert'
        }

        It 'decides that a re-earned name is NOT exited, on the life key' {
            $store = script:New-FixtureStore
            $ledger = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            $verdict = Get-MSReconciliation -EntryPath (Join-Path $store.Dir 'reference_reused_name.md') -Ledger $ledger
            $verdict.Identity | Should -BeExactly 'reference_reused_name@2026-08-08'
            $verdict.Verdict | Should -BeExactly 'not-exited'
            @($ledger.ExitsInForce.Keys | Where-Object { $ledger.ExitsInForce[$_].Name -ceq 'reference_reused_name' }).Count |
                Should -BeGreaterThan 0 -Because 'a name-keyed read would find a record and call the live entry handled'
        }

        It 'reports undecidable - not exited, not not-exited - for an entry with no life binding' {
            $store = script:New-FixtureStore
            $verdict = Get-MSReconciliation -EntryPath (Join-Path $store.Dir 'reference_legacy_unknown.md') -Ledger (Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1)
            $verdict.Verdict | Should -BeExactly 'undecidable'
            $verdict.Verdict | Should -Not -BeExactly 'exited'
            $verdict.Verdict | Should -Not -BeExactly 'not-exited'
        }

        It 'refuses an identity whose name carries an @ rather than decoding it two ways [M37]' {
            $store = script:New-FixtureStore
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | promote | reference_foo@2026-01-01@2026-02-02 | ambiguous | somewhere (merged)')
            @((Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1).Malformed)[0].Why | Should -Match "may not contain '@'"
        }

        It 'keeps the sweep''s own record names reserved from entries [M3]' {
            $store = script:New-FixtureStore
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | promote | sweep@2026-08-08 | an entry may not borrow a reserved name | somewhere (merged)')
            @((Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1).Malformed)[0].Why | Should -Match 'reserved for the sweep'
        }

        It 'accepts the step-7 closing record its own procedure mandates [M3]' {
            $store = script:New-FixtureStore
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | sweep-complete | sweep@2026-08-08 | 12 subjects walked, 0 exits | LEDGER.md')
            $ledger = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            $ledger.Malformed | Should -BeNullOrEmpty
            # and it does not make the partition check report a loss on a store where nothing left
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @((Test-MSPartition -Inventory $inv -IndexPath $store.Index -AsOf $script:Sweep1).record_problems).Count | Should -Be 0
            # the shape is the one the procedure documents
            @(script:Row -Doc $script:ProcedureText -Prefix '2026-08-08 | executed | sweep-complete').Count | Should -Be 1
        }

        It 'states its retention bound, its append discipline, and which policy rules reach it' {
            $script:RecordsText | Should -Match 'at\s+least\s+one\s+further\s+sweep'
            $script:RecordsText | Should -Match 'ledger-compaction'
            $script:RecordsText | Should -Match 'R1 and R2 do not reach them'
            $script:RecordsText | Should -Match 'R3 reaches all three'
            $script:RecordsText | Should -Match 'size budget does not reach them'
            $script:RecordsText | Should -Match 'written before the act it authorizes'
        }

        It 'ships a region shape an append can actually reach [M12]' {
            # The claim the format has to make true. A real AppendAllText lands INSIDE the region and
            # the parser sees it - which a begin/end bounded region makes impossible.
            $store = script:New-FixtureStore
            $before = @((Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1).Records).Count
            [System.IO.File]::AppendAllText($store.Ledger,
                "2026-08-08 | proposed | remove-obsolete | reference_tail_zeta@2026-07-22 | appended, not rewritten | none (accepted recall loss)`n")
            @((Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1).Records).Count | Should -Be ($before + 1)

            # and two concurrent appenders both survive - the property the rationale claims
            $a = "2026-08-08 | proposed | promote | reference_dupe_source@2026-07-01 | session A | somewhere (merged)"
            $b = "2026-08-08 | proposed | promote | reference_dupe_survivor@2026-06-05 | session B | somewhere (merged)"
            [System.IO.File]::AppendAllText($store.Ledger, "$a`n")
            [System.IO.File]::AppendAllText($store.Ledger, "$b`n")
            $raw = [System.IO.File]::ReadAllText($store.Ledger)
            $raw.Contains($a, [System.StringComparison]::Ordinal) | Should -BeTrue
            $raw.Contains($b, [System.StringComparison]::Ordinal) | Should -BeTrue

            $script:RecordsText | Should -Match 'opening marker and no closing one'
            [System.IO.File]::ReadAllText($store.Ledger) | Should -Not -Match 'memory-ledger-end'
        }
    }

    Context 'AC2 - the sweep walks both populations, takes the first things first, and covers the authorized moves' {
        It 'walks the index pointers AND the entry files no pointer points at' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.subjects | Where-Object { $_.population -eq 'pointer' }).Count | Should -Be 11
            @($inv.subjects | Where-Object { $_.population -eq 'orphan-body' } | ForEach-Object { $_.name }) |
                Should -Be @('reference_critical_orphan')
        }

        It 'does not enumerate a file that is not a memory entry [M7]' {
            $store = script:New-FixtureStore
            [System.IO.File]::WriteAllText((Join-Path $store.Dir 'README.md'), "# notes`nnot an entry`n")
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.subjects | Where-Object { $_.name -ceq 'README' }) | Should -BeNullOrEmpty
            @($inv.non_entry_files) | Should -Contain 'README'
        }

        It 'does not enumerate a store''s policy file under whatever name it declares [M7]' {
            $store = script:New-FixtureStore -PolicyFileName 'store-policy.md'
            (script:Invoke-PolicyCheck -IndexPath $store.Index).Code | Should -Be 0
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.subjects | Where-Object { $_.name -ceq 'store-policy' }) | Should -BeNullOrEmpty
        }

        It 'enumerates one file once when its name differs in case from its pointer [M20]' {
            # The live half of the case-sensitivity defect. A pointer's body is located with
            # Test-Path, which is case-insensitive here, so a case-sensitive pointed-at set counts
            # the same file twice: as a pointer subject AND as an orphan body.
            $store = script:New-FixtureStore
            Rename-Item -LiteralPath (Join-Path $store.Dir 'reference_tail_zeta.md') -NewName 'Reference_Tail_Zeta.md'
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.subjects | Where-Object { $_.name -match '(?i)^reference_tail_zeta$' }).Count |
                Should -Be 1 -Because 'it is one file, and the pointer already accounts for it'
            @($inv.subjects | Where-Object { $_.population -eq 'orphan-body' } | ForEach-Object { $_.name }) |
                Should -Be @('reference_critical_orphan')
        }

        It 'excludes the record files whatever case they are written in [M20]' {
            $store = script:New-FixtureStore
            Rename-Item -LiteralPath $store.Ledger -NewName 'ledger.md'
            @(Get-MSReservedNames -IndexPath $store.Index) | Should -Contain 'LEDGER'
            $reserved = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-MSReservedNames -IndexPath $store.Index), [System.StringComparer]::OrdinalIgnoreCase)
            $reserved.Contains('ledger') | Should -BeTrue -Because 'Test-Path found it under that name, so the exclusion must too'
        }

        It 'surfaces every critical entry before any other disposition, including one in an orphan body' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1

            $body = @([System.IO.File]::ReadAllLines($store.Index))
            $criticalLine = [array]::FindIndex([string[]]$body, [Predicate[string]] { param($l) $l -match 'reference_critical_delta\.md' })
            $firstPointer = [array]::FindIndex([string[]]$body, [Predicate[string]] { param($l) $l -match '\]\(reference_|\]\(project_|\]\(feedback_' })
            $criticalLine | Should -BeGreaterThan $firstPointer -Because 'the critical entry must not be first in file order, or the ordering proves nothing'

            $ordered = @($inv.subjects | ForEach-Object { $_.group })
            $criticalPositions = @(0..($ordered.Count - 1) | Where-Object { $ordered[$_] -eq '2-critical' })
            $otherPositions = @(0..($ordered.Count - 1) | Where-Object { $ordered[$_] -notin @('1-incomplete-disposition', '2-critical') })
            (@($criticalPositions) | Measure-Object -Maximum).Maximum | Should -BeLessThan (@($otherPositions) | Measure-Object -Minimum).Minimum
            @($inv.subjects | Where-Object { $_.group -eq '2-critical' } | ForEach-Object { $_.name } | Sort-Object) |
                Should -Be @('reference_critical_delta', 'reference_critical_orphan')
        }

        It 'surfaces unassessed entries ahead of expired deferrals [M38]' {
            $store = script:New-FixtureStore
            script:Add-SlateRow -Path $store.Slate -Rows @('2026-08-01 | reference_reused_name@2026-08-08 | deferral | 1 | until 2026-08-02 - expired')
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($inv.subjects | Where-Object { $_.name -ceq 'reference_reused_name' })[0].group |
                Should -BeExactly '3-unassessed' -Because 'nobody has assessed it, which is the next question about it'
        }

        It 'stops surfacing an orphan body whose life has already exited [M2]' {
            $store = script:New-FixtureStore
            $before = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($before.subjects | Where-Object { $_.name -ceq 'reference_critical_orphan' }).Count | Should -Be 1

            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | promote | reference_critical_orphan@2026-06-30 | landed in the runbook | ops runbook (merged to main)')
            $after = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            @($after.subjects | Where-Object { $_.name -ceq 'reference_critical_orphan' }) |
                Should -BeNullOrEmpty -Because 'it has left; its body simply has not been deleted'
            $script:RecordsText | Should -Not -Match '\| `presence` \|'
        }

        It 'maps every authorized size-reduction move to a named disposition, move by move' {
            $expected = @(
                @{ move = '1. Promote and remove'; disposition = 'promote' },
                @{ move = '2. Demote to the cold archive'; disposition = 'demote' },
                @{ move = '3. Demote a settled `project_` entry'; disposition = 'settle-in-place' },
                @{ move = '4. Merge settled `project_` pointers onto one line'; disposition = 'settle-in-place' },
                @{ move = '5. Deduplicate'; disposition = 'dedupe-into' },
                @{ move = '6. Remove an obsolete entry'; disposition = 'remove-obsolete' })
            foreach ($row in $expected) {
                $line = @(script:Row -Doc $script:ProcedureText -Prefix "| $($row.move)")
                @($line).Count | Should -Be 1 -Because "the covering mapping must carry a row for '$($row.move)'"
                @($line)[0] | Should -Match ([regex]::Escape("``$($row.disposition)``"))
            }
            $canon = ($script:CanonicalLines -join "`n")
            foreach ($n in 1..6) { $canon | Should -Match "(?m)^$n\. \*\*" }
            $canon | Should -Not -Match '(?m)^7\. \*\*'
        }

        It 'pins settle-in-place as NOT an exit, in the table a reader acts on [M35]' {
            # Prose, pinned. Inverting this cell used to leave the whole suite green.
            $line = @(script:Row -Doc $script:ProcedureText -Prefix '| `settle-in-place` |')
            @($line).Count | Should -Be 1
            @($line)[0] | Should -Match '\|\s*\*\*no\*\*\s*\|' -Because 'the settled-section move books no exit record, and inverting this cell must turn a test red'
            @(script:Row -Doc $script:ProcedureText -Prefix '| `keep-hot-with-expiry` |')[0] | Should -Match '\|\s*\*\*no\*\*\s*\|'
            foreach ($exit in @('promote', 'demote', 'dedupe-into', 'remove-obsolete', 'remove-fails-admission', 'evaporate-on-close')) {
                @(script:Row -Doc $script:ProcedureText -Prefix "| ``$exit`` |")[0] |
                    Should -Match '\|\s*yes\s*\|' -Because "$exit removes the pointer and books an exit record"
            }
        }

        It 'pins the authority table''s two refusals, which a future unattended session reads as its rule [M35]' {
            foreach ($act in @('Execute any exit, demotion, body deletion, structural rewrite', 'Compact `LEDGER.md` or `SLATE.md`')) {
                $line = @(script:Row -Doc $script:ProcedureText -Prefix "| $act |")
                @($line).Count | Should -Be 1 -Because "the authority table must carry a row for '$act'"
                @($line)[0] | Should -Match '\|\s*\*\*no\*\*\s*\|\s*yes\s*\|' -Because 'an unattended session may not do this, and inverting the cell must turn a test red'
            }
            foreach ($act in @('Admit a new entry, append a `critical` row for it', 'Append a `proposed` ledger record')) {
                @(script:Row -Doc $script:ProcedureText -Prefix "| $act |")[0] | Should -Match '\|\s*yes\s*\|\s*yes\s*\|'
            }
        }

        It 'grandfathers the pre-rule corpus out of remove-fails-admission, and does not grandfather the rest' {
            $preRule = Test-MSAdmissionRemovalEligible -Identity 'feedback_prerule_epsilon@2026-05-02' -AdmissionRuleLandedOn $script:AdmissionRuleLanded
            $preRule.Eligible | Should -BeFalse
            $preRule.Why | Should -Match 'grandfathered'
            (Test-MSAdmissionRemovalEligible -Identity 'reference_critical_delta@2026-07-10' -AdmissionRuleLandedOn $script:AdmissionRuleLanded).Eligible | Should -BeTrue
            (Test-MSAdmissionRemovalEligible -Identity 'reference_legacy_unknown@unknown' -AdmissionRuleLandedOn $script:AdmissionRuleLanded).Eligible | Should -BeFalse
        }

        It 'carries the residue step on evaporate-on-close and names promotion the primary outflow' {
            $script:ProcedureText | Should -Match '`evaporate-on-close` carries a residue step'
            $script:ProcedureText | Should -Match 'written as a `reference_` entry'
            $script:ProcedureText | Should -Match '\*\*Promotion is the primary outflow\.\*\*'
        }

        It 'requires the destination to carry the lesson for EVERY exit, not only a critical one [M34]' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            $ordinary = Test-MSExitAllowed -SlateState $slate -Identity 'reference_ordinary_alpha@2026-06-14' -Disposition 'promote' -DestinationCarriesLesson $false -DestinationLanded $true
            $ordinary.Allowed | Should -BeFalse
            $ordinary.Why | Should -Match 'read and confirmed to carry the lesson'
            (Test-MSExitAllowed -SlateState $slate -Identity 'reference_ordinary_alpha@2026-06-14' -Disposition 'promote' -DestinationCarriesLesson $true -DestinationLanded $false).Allowed |
                Should -BeTrue -Because 'an ordinary entry needs the lesson carried, not a landing'
        }

        It 'refuses to exit a critical entry whose destination does not carry the lesson' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            $destination = Join-Path $store.Dir 'pretend-permanent-home.md'
            [System.IO.File]::WriteAllText($destination, "# A home that does not carry it yet`n")
            $probe = 'A marker head that is not self-closed is dropped in silence.'

            (Test-MSDestinationCarriesLesson -Path $destination -Probe $probe).Carries | Should -BeFalse
            (Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition 'promote' -DestinationCarriesLesson $false -DestinationLanded $true).Allowed | Should -BeFalse

            [System.IO.File]::AppendAllText($destination, "$probe`n")
            (Test-MSDestinationCarriesLesson -Path $destination -Probe $probe).Carries | Should -BeTrue
            (Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition 'promote' -DestinationCarriesLesson $true -DestinationLanded $true).Allowed | Should -BeTrue
        }

        It 'refuses a landing that is only on an unmerged branch' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            $verdict = Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition 'promote' -DestinationCarriesLesson $true -DestinationLanded $false
            $verdict.Allowed | Should -BeFalse
            $verdict.Why | Should -Match 'merged to the default branch'
            $script:ProcedureText | Should -Match 'means merged to the default branch'
        }

        It 'applies the landing gate to demotion and removal too, not only promotion' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            foreach ($d in @('demote', 'remove-obsolete', 'dedupe-into', 'remove-fails-admission', 'evaporate-on-close')) {
                (Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition $d -DestinationCarriesLesson $true -DestinationLanded $false).Allowed |
                    Should -BeFalse -Because "a critical entry must not leave via $d without a verified landing"
            }
        }

        It 'refuses an unrecognized disposition rather than waving it through [M18]' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            foreach ($d in @('Promote', 'delete-everything', 'PROMOTE')) {
                $v = Test-MSExitAllowed -SlateState $slate -Identity 'reference_reused_name@2026-08-08' -Disposition $d -DestinationCarriesLesson $true -DestinationLanded $true
                $v.Allowed | Should -BeFalse -Because "'$d' is not a disposition the procedure names"
                $v.Why | Should -Match 'not a disposition the sweep procedure names'
            }
        }

        It 'refuses to disposition an entry nobody has assessed' {
            $store = script:New-FixtureStore
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            (Test-MSExitAllowed -SlateState $slate -Identity 'reference_reused_name@2026-08-08' -Disposition 'promote' -DestinationCarriesLesson $true -DestinationLanded $true).Why |
                Should -Match 'has not been assessed'
        }

        It 'leaves the index byte-identical on an unattended walk that records proposals' {
            $store = script:New-FixtureStore
            $before = (Get-FileHash -LiteralPath $store.Index -Algorithm SHA256).Hash
            $ledgerBefore = @((Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1).Records).Count

            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | proposed | remove-obsolete | reference_obsolete_gamma@2026-06-25 | the surface it describes no longer exists | none (accepted recall loss)',
                '2026-08-08 | proposed | dedupe-into | reference_dupe_source@2026-07-01 | the survivor carries the same lesson | reference_dupe_survivor.md')

            (Get-FileHash -LiteralPath $store.Index -Algorithm SHA256).Hash | Should -BeExactly $before
            $after = Get-MSLedger -Path $store.Ledger -AsOf $script:Sweep1
            @($after.Records).Count | Should -Be ($ledgerBefore + 2)
            @($after.Records | Where-Object { $_.Date -eq $script:Sweep1 } | ForEach-Object { $_.Status } | Sort-Object -Unique) | Should -Be @('proposed')
            @($after.ExitsInForce.Keys) | Should -Not -Contain 'reference_obsolete_gamma@2026-06-25'
        }
    }

    Context 'AC3 - deferral expires, and a critical entry is not deferred twice' {
        BeforeAll {
            $script:S = script:New-FixtureStore
            script:Add-SlateRow -Path $script:S.Slate -Rows @(
                '2026-08-08 | reference_critical_delta@2026-07-10 | deferral | 1 | until 2026-09-07 - waiting on the marker-contract change',
                '2026-08-08 | reference_ordinary_alpha@2026-06-14 | deferral | 1 | until 2026-09-07 - re-check after the retry-cap fix',
                '2026-08-08 | reference_critical_orphan@2026-06-30 | landing | in-flight | agent-orchestra PR #1031')
            script:Add-LedgerRecord -Path $script:S.Ledger -Rows @(
                '2026-08-08 | executed | keep-hot-with-expiry | reference_critical_delta@2026-07-10 | the destination is not decided yet | none - deferred to 2026-09-07',
                '2026-08-08 | executed | keep-hot-with-expiry | reference_ordinary_alpha@2026-06-14 | the fix that would settle it is not merged | none - deferred to 2026-09-07')
            $script:Sweep2Inventory = New-MSInventory -IndexPath $script:S.Index -AsOf $script:Sweep2
            $script:Sweep2Slate = Get-MSSlateState -Path $script:S.Slate -AsOf $script:Sweep2
        }

        It 'brings an expired deferral back into the slate' {
            $alpha = @($script:Sweep2Inventory.subjects | Where-Object { $_.name -ceq 'reference_ordinary_alpha' })[0]
            $alpha.deferral_count | Should -Be 1
            $alpha.deferred_until | Should -BeExactly '2026-09-07'
            $alpha.group | Should -BeExactly '4-expired-deferral'
        }

        It 'does not bring an unexpired deferral back' {
            $atSweep1 = New-MSInventory -IndexPath $script:S.Index -AsOf $script:Sweep1
            @($atSweep1.subjects | Where-Object { $_.name -ceq 'reference_ordinary_alpha' })[0].group | Should -BeExactly '5-other'
        }

        It 'blocks a second deferral of a critical entry, and writes no second deferral row' {
            $verdict = Test-MSDeferralAllowed -SlateState $script:Sweep2Slate -Identity 'reference_critical_delta@2026-07-10'
            $verdict.Allowed | Should -BeFalse
            $verdict.Why | Should -Match 'may not be deferred twice'

            script:Add-LedgerRecord -Path $script:S.Ledger -Rows @(
                "2026-09-15 | proposed | keep-hot-with-expiry | reference_critical_delta@2026-07-10 | REFUSED - a critical entry may not be deferred twice | none")
            $after = Get-MSSlateState -Path $script:S.Slate -AsOf $script:Sweep2
            @($after.Rows | Where-Object { $_.Identity -ceq 'reference_critical_delta@2026-07-10' -and $_.Track -ceq 'deferral' }).Count | Should -Be 1
            (Get-MSTrackValue -SlateState $after -Identity 'reference_critical_delta@2026-07-10' -Track 'deferral').Value | Should -Be 1
        }

        It 'allows a second deferral of an ORDINARY entry, so the block is about criticality' {
            (Test-MSDeferralAllowed -SlateState $script:Sweep2Slate -Identity 'reference_ordinary_alpha@2026-06-14').Allowed | Should -BeTrue
        }

        It 'refuses to defer an entry nobody has assessed, so the twice-rule is not escapable [M19]' {
            $v = Test-MSDeferralAllowed -SlateState $script:Sweep2Slate -Identity 'reference_reused_name@2026-08-08'
            $v.Allowed | Should -BeFalse
            $v.Why | Should -Match 'has not been assessed'
        }

        It 'refuses every gate when the slate carries a row it cannot read [M14]' {
            $store = script:New-FixtureStore
            script:Add-SlateRow -Path $store.Slate -Rows @('2026-08-08 | reference_critical_delta@2026-07-10 | deferral | 1 | hold for now')
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            $slate.Trustworthy | Should -BeFalse
            @($slate.Malformed).Count | Should -Be 1

            $d = Test-MSDeferralAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10'
            $d.Allowed | Should -BeFalse -Because 'a deferral history that might say anything is not one the twice-rule may be applied to'
            $d.Why | Should -Match 'cannot read'
            (Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition 'promote' -DestinationCarriesLesson $true -DestinationLanded $true).Allowed |
                Should -BeFalse
        }

        It 'surfaces a landing in flight with its vehicle, and does not count it as a deferral' {
            $orphan = @($script:Sweep2Inventory.subjects | Where-Object { $_.name -ceq 'reference_critical_orphan' })[0]
            $orphan.landing | Should -BeExactly 'in-flight'
            $orphan.landing_vehicle | Should -Match 'PR #1031'
            $orphan.deferral_count | Should -Be 0
            $orphan.group | Should -BeExactly '2-critical'
            (Test-MSDeferralAllowed -SlateState $script:Sweep2Slate -Identity 'reference_critical_orphan@2026-06-30').Allowed | Should -BeTrue
        }

        It 'reads the deferral state without replaying the exit record' {
            $noLedger = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8) + '-LEDGER.md')
            $state = Get-MSSlateState -Path $script:S.Slate -AsOf $script:Sweep2
            (Get-MSTrackValue -SlateState $state -Identity 'reference_critical_delta@2026-07-10' -Track 'deferral').Value | Should -Be 1
            (Get-MSLedger -Path $noLedger -AsOf $script:Sweep2).State | Should -BeExactly 'absent'
        }

        It 'refuses a slate value outside its vocabulary [M5]' {
            $store = script:New-FixtureStore
            script:Add-SlateRow -Path $store.Slate -Rows @(
                '2026-08-01 | reference_tail_zeta@2026-07-22 | critical | Yes | a capitalized letter is not the vocabulary',
                '2026-08-01 | reference_dupe_source@2026-07-01 | landing | ladned | typo',
                '2026-08-01 | reference_dupe_survivor@2026-06-05 | deferral | many | until 2026-09-01')
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            @($slate.Malformed).Count | Should -Be 3
            @($slate.Malformed | Where-Object { $_.Raw -match 'Yes' })[0].Why | Should -Match 'lower case, exactly'
            $slate.Trustworthy | Should -BeFalse
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
            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_tail_zeta'

            $caught = Test-MSPartition -Inventory $fromDisk -IndexPath $store.Index -AsOf $script:Sweep1
            $caught.result | Should -BeExactly 'unaccounted'
            @($caught.unaccounted | Where-Object { $_.name -ceq 'reference_tail_zeta' }).Count | Should -Be 1
        }

        It 'does NOT catch it when the enumeration came from a truncated view - which is why the read is from disk' {
            $store = script:New-FixtureStore
            $indexText = [System.IO.File]::ReadAllText($store.Index)
            $cut = [int][Math]::Floor((Measure-MIPCharacters -Text $indexText) * 0.80)

            $loadedViewDir = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Path $loadedViewDir -Force | Out-Null
            $loadedView = Join-Path $loadedViewDir 'MEMORY.md'
            [System.IO.File]::WriteAllText($loadedView, $indexText.Substring(0, $cut))
            $truncated = New-MSInventory -IndexPath $loadedView -AsOf $script:Sweep1
            @($truncated.subjects | Where-Object { $_.name -ceq 'reference_tail_zeta' }) | Should -BeNullOrEmpty

            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_tail_zeta'
            @((Test-MSPartition -Inventory $truncated -IndexPath $store.Index -AsOf $script:Sweep1).unaccounted |
                    Where-Object { $_.name -ceq 'reference_tail_zeta' }) | Should -BeNullOrEmpty
        }

        It 'catches an unrecorded removal even when a PRIOR LIFE was demoted under the same name [M1]' {
            # The exhibit four review passes reproduced. An archive line from an earlier life used to
            # account for a removal that had no record of its own.
            $store = script:New-FixtureStore
            [System.IO.File]::WriteAllLines($store.Archive, @(
                    '# Cold archive', '', '## Demoted 2025-01-05', '',
                    '- [zeta, an older life](reference_tail_zeta.md) - a prior life of this name'))
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_tail_zeta'

            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index -AsOf $script:Sweep1
            $partition.result | Should -BeExactly 'unaccounted'
            @($partition.unaccounted | Where-Object { $_.identity -ceq 'reference_tail_zeta@2026-07-22' }).Count | Should -Be 1
        }

        It 'catches an unrecorded removal when the name has since been RE-EARNED [M1]' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            # life 1 leaves with no record; life 2 takes the same name and the same pointer
            $body = Join-Path $store.Dir 'reference_ordinary_alpha.md'
            $rewritten = @([System.IO.File]::ReadAllLines($body) | ForEach-Object { $_ -replace 'admitted: 2026-06-14', 'admitted: 2026-08-08' })
            [System.IO.File]::WriteAllLines($body, $rewritten)

            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index -AsOf $script:Sweep1
            @($partition.unaccounted | Where-Object { $_.identity -ceq 'reference_ordinary_alpha@2026-06-14' }).Count |
                Should -Be 1 -Because 'the pointer now belongs to a different life; this one left with no record'
            @($partition.unaccounted | Where-Object { $_.identity -ceq 'reference_ordinary_alpha@2026-06-14' })[0].why |
                Should -Match 'different life'
        }

        It 'reports undecidable presence rather than guessing when a body was deleted [M1/M21]' {
            # The trap the obvious fix falls into: keying presence by identity alone would flip a
            # lawfully body-deleted entry from still-hot to a claimed loss.
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            Remove-Item -LiteralPath (Join-Path $store.Dir 'reference_dupe_survivor.md') -Force

            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index -AsOf $script:Sweep1
            $entry = @($partition.unaccounted | Where-Object { $_.name -ceq 'reference_dupe_survivor' })
            @($entry).Count | Should -Be 1
            @($entry)[0].why | Should -Match 'cannot be decided' -Because 'a pointer is still there; which life it is cannot be established'
        }

        It 'accounts a demoted pointer from its RECORD, corroborated by the archive line' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            $inv.archive.present | Should -BeFalse

            $pointer = @([System.IO.File]::ReadAllLines($store.Index) | Where-Object { $_ -match 'reference_obsolete_gamma\.md' })[0]
            [System.IO.File]::WriteAllLines($store.Archive, @('# Cold archive', '', '## Demoted 2026-08-08', '', $pointer))
            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_obsolete_gamma'
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | demote | reference_obsolete_gamma@2026-06-25 | its subject no longer exists | ARCHIVE.md')

            script:Remove-Pointer -IndexPath $store.Index -Name 'reference_dupe_source'
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | executed | dedupe-into | reference_dupe_source@2026-07-01 | folded into the survivor | reference_dupe_survivor.md')
            script:Add-SlateRow -Path $store.Slate -Rows @(
                '2026-08-08 | reference_critical_orphan@2026-06-30 | critical | yes | re-assessed at this sweep')

            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index -AsOf $script:Sweep1
            $partition.result | Should -BeExactly 'accounted'
            @($partition.accounted | Where-Object { $_.name -ceq 'reference_obsolete_gamma' })[0].how | Should -BeExactly 'demoted'
            @($partition.accounted | Where-Object { $_.name -ceq 'reference_dupe_source' })[0].how | Should -BeExactly 'exited-with-record'
        }

        It 'accounts an orphan only when THIS sweep assessed it [M9]' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            # the fixture's orphan carries a row dated 2026-06-30, long before this enumeration
            $stale = Test-MSPartition -Inventory $inv -IndexPath $store.Index -AsOf $script:Sweep1
            @($stale.unaccounted | Where-Object { $_.name -ceq 'reference_critical_orphan' })[0].why |
                Should -Match 'neither dispositioned nor assessed'

            script:Add-SlateRow -Path $store.Slate -Rows @(
                '2026-08-08 | reference_critical_orphan@2026-06-30 | critical | yes | assessed at this sweep')
            $fresh = Test-MSPartition -Inventory $inv -IndexPath $store.Index -AsOf $script:Sweep1
            @($fresh.accounted | Where-Object { $_.name -ceq 'reference_critical_orphan' })[0].how | Should -BeExactly 'orphan-assessed'
        }

        It 'reports an unreadable record instead of passing over it' {
            $store = script:New-FixtureStore
            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            script:Add-LedgerRecord -Path $store.Ledger -Rows @('2026-08-08 | executed | promote | not-a-life-key | broken | somewhere')
            $partition = Test-MSPartition -Inventory $inv -IndexPath $store.Index -AsOf $script:Sweep1
            $partition.result | Should -BeExactly 'unaccounted'
            @($partition.record_problems).Count | Should -BeGreaterThan 0
        }

        It 'handles all three shipped size-axis states, including the one with no observation' {
            $none = script:New-FixtureStore -OmitValuesBlock
            $r1 = script:Invoke-PolicyCheck -IndexPath $none.Index
            $r1.Report.Size.State | Should -BeExactly 'not-evaluated'
            $r1.Code | Should -Be 0

            $measured = script:New-FixtureStore
            $r2 = script:Invoke-PolicyCheck -IndexPath $measured.Index -AsOf $script:Sweep1
            $r2.Report.Size.State | Should -BeExactly 'within'
            $r2.Report.Size.Stale | Should -BeTrue
            $r2.Code | Should -Be 0 -Because 'a stale observation is reported, not treated as a defect'

            $broken = script:New-FixtureStore
            $policyLines = @([System.IO.File]::ReadAllLines($broken.Policy) | Where-Object { -not $_.StartsWith('limit_observation:', [System.StringComparison]::Ordinal) })
            [System.IO.File]::WriteAllLines($broken.Policy, $policyLines)
            $r3 = script:Invoke-PolicyCheck -IndexPath $broken.Index
            $r3.Report.Size.State | Should -BeExactly 'could-not-verify'
            $r3.Code | Should -Be 1

            $script:ProcedureText | Should -Match 'no values region at all'
            $script:ProcedureText | Should -Match 'a values region with no usable observation'
            $script:ProcedureText | Should -Match 'defers the re-observation with a record'
        }

        It 'appends a re-observation and leaves every prior row byte-identical' {
            $store = script:New-FixtureStore
            $before = @(script:Get-ValuesRegion -PolicyPath $store.Policy)
            script:Add-ValuesRow -PolicyPath $store.Policy -Row 'limit_observation: 2026-09-15 | 25600 | characters | truncation-boundary test (sweep 2)'
            $after = @(script:Get-ValuesRegion -PolicyPath $store.Policy)
            @($after).Count | Should -Be (@($before).Count + 1)
            for ($i = 0; $i -lt @($before).Count; $i++) { $after[$i] | Should -BeExactly $before[$i] }
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index -AsOf $script:Sweep2
            $r.Report.Size.ObservedOn | Should -BeExactly '2026-09-15'
            $r.Code | Should -Be 0
        }

        It 'records a destination measurement in the values region, tolerated and reported [M29]' {
            $store = script:New-FixtureStore
            $destination = Join-Path $store.Dir 'pretend-CLAUDE.md'
            [System.IO.File]::WriteAllText($destination, "# Admission rule`r`nline two`r`n")
            $m = New-MSSurfaceMeasurement -Path $destination -AsOf $script:Sweep1
            script:Add-ValuesRow -PolicyPath $store.Policy -Row (Format-MSSurfaceMeasurement -Measurement $m)

            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Code | Should -Be 0
            @($r.Report.Size.IgnoredKeys) | Should -Contain 'x-destination_observation'
            $script:RecordsText | Should -Match 'x-destination_observation'
        }

        It 'errors on the same key written bare, which is why the prefix is not optional' {
            $store = script:New-FixtureStore
            script:Add-ValuesRow -PolicyPath $store.Policy -Row 'destination_observation: 2026-08-08 | 26 | characters | ~/x.md | m'
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Code | Should -Be 1
            $r.Text | Should -Match "unrecognized key 'destination_observation'"
        }

        It 'repeats the growth key rather than rewriting it, and stays clean' {
            $store = script:New-FixtureStore -ExtraValues @('x-last-sweep: 2026-08-08', 'x-last-sweep: 2026-09-15')
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index -AsOf $script:Sweep2
            $r.Code | Should -Be 0
            @(script:Get-ValuesRegion -PolicyPath $store.Policy | Where-Object { $_.StartsWith('x-last-sweep:', [System.StringComparison]::Ordinal) }).Count | Should -Be 2
            $script:RecordsText | Should -Match 'repeats'
        }

        It 'leaves a values-less store still clean after a sweep' {
            $store = script:New-FixtureStore -OmitValuesBlock
            $policyBefore = (Get-FileHash -LiteralPath $store.Policy -Algorithm SHA256).Hash
            script:Add-LedgerRecord -Path $store.Ledger -Rows @(
                '2026-08-08 | proposed | sweep-complete | sweep@2026-08-08 | this store records no budget inputs; the destination measurement is not recorded here | LEDGER.md')
            (Get-FileHash -LiteralPath $store.Policy -Algorithm SHA256).Hash | Should -BeExactly $policyBefore
            $r = script:Invoke-PolicyCheck -IndexPath $store.Index
            $r.Report.Size.State | Should -BeExactly 'not-evaluated'
            $r.Code | Should -Be 0
        }

        It 'flips a values-less store from clean to defects if a sweep writes the key into it - which is why it must not' {
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

        It 'produces a measurement in the counting rule, with a comparable surface [M30]' {
            $store = script:New-FixtureStore
            $destination = Join-Path $store.Dir 'pretend-CLAUDE.md'
            [System.IO.File]::WriteAllText($destination, "# Admission rule`r`nline two`r`n")
            $m = New-MSSurfaceMeasurement -Path $destination -AsOf $script:Sweep1
            $m.date | Should -BeExactly '2026-08-08'
            $m.unit | Should -BeExactly 'characters'
            $m.value | Should -Be 26 -Because 'CRLF normalizes to a single LF before counting'
            $m.value | Should -BeLessThan ([System.IO.File]::ReadAllText($destination).Length)
            $m.surface | Should -Not -Match '\\' -Because 'a surface a second machine can compare uses forward slashes'
            (Test-MSSurfaceMeasurement -Record (Format-MSSurfaceMeasurement -Measurement $m)).Conforming | Should -BeTrue
        }

        It 'writes a home-relative surface, not one machine''s absolute path [M30]' {
            $underHome = Join-Path ([System.Environment]::GetFolderPath('UserProfile')) ('mip-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.md')
            try {
                [System.IO.File]::WriteAllText($underHome, "probe`n")
                (New-MSSurfaceMeasurement -Path $underHome -AsOf $script:Sweep1).surface |
                    Should -Match '^~/' -Because 'a series keyed on one account''s home directory is incomparable anywhere else'
            }
            finally { if (Test-Path -LiteralPath $underHome) { Remove-Item -LiteralPath $underHome -Force } }
        }

        It 'reports a measurement missing its unit or its surface as non-conforming' {
            (Test-MSSurfaceMeasurement -Record '2026-08-08 | 2548 | bytes | ~/.claude/CLAUDE.md | by hand').Conforming | Should -BeFalse
            @((Test-MSSurfaceMeasurement -Record '2026-08-08 | 2548 | bytes | ~/.claude/CLAUDE.md | by hand').Problems) | Should -Match "unit must be 'characters'"
            $noSurface = Test-MSSurfaceMeasurement -Record '2026-08-08 | 2548 | characters |  | by hand'
            $noSurface.Conforming | Should -BeFalse
            @($noSurface.Problems) | Should -Match 'surface must name the file measured'
            (Test-MSSurfaceMeasurement -Record '2026-08-08 | 2548 | characters').Conforming | Should -BeFalse
        }

        It 'refuses the destination the policy check refuses, which is why this instrument exists' {
            $store = script:New-FixtureStore
            $destination = Join-Path $store.Dir 'pretend-CLAUDE.md'
            [System.IO.File]::WriteAllText($destination, "# Admission rule`n")
            (Invoke-MemoryIndexPolicyCheck -IndexPath $destination -AsOf $script:Sweep1).ExitCode | Should -Be 2
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
            @(($r.Text -split "`r?`n") | Where-Object { $_ -match '^(policy|size|subjects_without_hook|unattributed_shared_notes):' }).Count | Should -Be 4
        }

        It 'never writes to the store from any instrument' {
            $store = script:New-FixtureStore
            $before = script:Get-FileDigests -Dir $store.Dir
            $artifact = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')

            $inv = New-MSInventory -IndexPath $store.Index -AsOf $script:Sweep1
            [System.IO.File]::WriteAllText($artifact, ($inv | ConvertTo-Json -Depth 6))
            Test-MSPartition -Inventory ([System.IO.File]::ReadAllText($artifact) | ConvertFrom-Json) -IndexPath $store.Index -AsOf $script:Sweep1 | Out-Null
            New-MSSurfaceMeasurement -Path $store.Index -AsOf $script:Sweep1 | Out-Null
            $slate = Get-MSSlateState -Path $store.Slate -AsOf $script:Sweep1
            Test-MSDeferralAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' | Out-Null
            Test-MSExitAllowed -SlateState $slate -Identity 'reference_critical_delta@2026-07-10' -Disposition 'promote' | Out-Null

            $after = script:Get-FileDigests -Dir $store.Dir
            @($after.Keys | Sort-Object) | Should -Be @($before.Keys | Sort-Object)
            foreach ($name in $before.Keys) { $after[$name] | Should -BeExactly $before[$name] }
        }

        It 'depends on no path outside the repository, across every shipped sweep file [M31]' {
            # Widened from the suite text plus the fixture dir to every file this chunk ships, and
            # from one hardcoded project-directory spelling to the shapes a dependency can take.
            $population = @($script:Instruments) + @($script:SweepCore) + @($PSCommandPath) +
            @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures/memory-sweep') -Recurse -File | ForEach-Object { $_.FullName })
            @($population).Count | Should -BeGreaterThan 15 -Because 'the sweep must reach the scripts, the core, this suite and the fixtures'

            # The read-verb patterns are assembled at runtime rather than written as literals,
            # because a sweep written as a literal finds ITSELF: the first draft of this case failed
            # on its own assertion line, which contains both a read verb and the home-directory
            # spelling it forbids. Known remaining gap, stated rather than left silent: a dependency
            # introduced through a variable the sweep cannot resolve statically is not caught here.
            $verbs = '(' + (@('Test-Path', 'ReadAllText', 'ReadAllLines', 'Get-Content', 'Resolve-Path') -join '|') + ')'
            $homeVar = '\' + '$HOME'
            $homeTilde = '~/' + '\.claude'

            foreach ($f in $population) {
                $text = Get-Content -LiteralPath $f -Raw
                foreach ($line in @($text -split "`r?`n")) {
                    # A path that names a real store is a dependency; naming one in .EXAMPLE prose is
                    # not, so the rule is about executable references, not the word appearing at all.
                    $line | Should -Not -Match '\.claude[/\\]projects[/\\]C--Users' -Because "$f must not reference the owner's live store"
                    $line | Should -Not -Match "$verbs[^\n]*$homeVar" -Because "$f must not read a path under the home variable"
                    $line | Should -Not -Match "$verbs[^\n]*$homeTilde" -Because "$f must not read a path under the home store directory"
                }
            }
        }
    }

    Context 'AC6 - reachable from where its readers read, and its claims about the checker are pinned' {
        It 'walks the pointer chain from the skill to the procedure to the record shapes' {
            $script:SkillText | Should -Match 'references/sweep-procedure\.md'
            $script:SkillText | Should -Match 'references/store-records\.md'
            Test-Path -LiteralPath $script:ProcedureDoc -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $script:RecordsDoc -PathType Leaf | Should -BeTrue
            $script:ProcedureText | Should -Match 'skills/agent-memory-compaction/references/store-records\.md'
            $script:RecordsText | Should -Match 'skills/agent-memory-compaction/references/sweep-procedure\.md'
        }

        It 'names every shipped instrument in the procedure and in the skill [M10]' {
            foreach ($s in $script:Instruments) {
                Test-Path -LiteralPath $s -PathType Leaf | Should -BeTrue
                $leaf = Split-Path -Leaf $s
                $script:ProcedureText | Should -Match ([regex]::Escape($leaf)) -Because "the procedure must name $leaf at the step that uses it"
                $script:SkillText | Should -Match ([regex]::Escape($leaf)) -Because "the skill must list $leaf"
            }
        }

        It 'puts every gate on the shipped execution path, not only in the suite [M10]' {
            # The defect: five decision functions whose only caller was this file.
            $gateScript = Join-Path $script:SkillDir 'scripts/Test-MemorySweepDisposition.ps1'
            $text = Get-Content -LiteralPath $gateScript -Raw
            foreach ($fn in @('Test-MSDeferralAllowed', 'Test-MSExitAllowed', 'Test-MSAdmissionRemovalEligible', 'Test-MSDestinationCarriesLesson', 'Get-MSReconciliation')) {
                $text | Should -Match ([regex]::Escape($fn)) -Because "$fn must be reachable from a shipped entry point"
            }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($gateScript, [ref]$null, [ref]$null)
            $gateParam = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Gate' })
            @($gateParam).Count | Should -Be 1
            foreach ($g in @('deferral', 'exit', 'admission', 'reconcile')) {
                $script:ProcedureText | Should -Match "-Gate $g" -Because "the procedure must show how to run the $g gate"
            }
        }

        It 'gives a store that split BEFORE this machinery a path to it, at its first sweep' {
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
            $after.Report.HeaderComplete | Should -BeTrue
        }

        It 'gives a store adopting the split AFTER this machinery the same pointer, at adoption' {
            $new = script:New-FixtureStore
            (Get-Content -LiteralPath $new.Policy -Raw) | Should -Match 'references/sweep-procedure\.md'
            (script:Invoke-PolicyCheck -IndexPath $new.Index).Code | Should -Be 0
            $script:SkillText | Should -Match 'Limb 2'
            $script:SkillText | Should -Match 'Sweep machinery'
        }

        It 'covers the store generation that never split at all [M24]' {
            # The shape the store this machinery was written for is in today.
            $script:ProcedureText | Should -Match 'Never split at all'
            $script:ProcedureText | Should -Match 'adopts the split shape first'
            # and a legacy store is still a lawful, clean thing the checker supports
            $dir = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $body = @([System.IO.File]::ReadAllLines((Join-Path $script:Fixture 'index-body.md')))
            $legacyIndex = Join-Path $dir 'MEMORY.md'
            [System.IO.File]::WriteAllLines($legacyIndex, @($script:CanonicalLines) + @('') + $body)
            $r = script:Invoke-PolicyCheck -IndexPath $legacyIndex
            $r.Report.StoreShape | Should -BeExactly 'legacy'
            Test-Path -LiteralPath (Join-Path $dir 'POLICY.md') | Should -BeFalse
        }

        It 'says on the skill''s discovery surfaces that it now carries sweep machinery' {
            $frontmatter = @($script:SkillText -split "`r?`n")[0..8] -join "`n"
            $frontmatter | Should -Match 'sweep'
            $descriptionLine = @(script:Row -Doc $script:SkillText -Prefix 'description:')
            @($descriptionLine).Count | Should -Be 1
            @($descriptionLine)[0] | Should -Match 'DO NOT USE FOR:'
            $script:SkillText | Should -Match '(?s)## When to Use.{0,1200}sweep'
        }

        It 'counts the procedure''s steps the same way the procedure does [M25]' {
            $steps = @(($script:ProcedureText -split "`r?`n") | Where-Object { $_ -match '^## Step \d' })
            @($steps).Count | Should -Be 8
            $script:SkillText | Should -Match 'the eight steps'
            $script:SkillText | Should -Not -Match 'the seven steps'
        }

        It 'states the condition under which a sweep is due, in terms a session can observe' {
            $script:ProcedureText | Should -Match '## When a sweep is due'
            $script:ProcedureText | Should -Match 'reports\s+`size:`\s+\*\*over\*\*'
            $script:ProcedureText | Should -Match "store's owner calls one"
        }

        It 'pins every claim the new documentation makes about checker behaviour' {
            $claims = @(
                'ignored and reported',
                'a hard error unless it is `x-`-prefixed',
                'The region''s presence is keyed',
                'refuses a path that is not an index',
                'reported, not treated as a defect')
            foreach ($c in $claims) {
                $script:ProcedureText.Contains($c, [System.StringComparison]::Ordinal) | Should -BeTrue -Because "the procedure must carry the claim '$c'"
            }
        }

        It 'declares its dependency on the sibling core rather than reaching into it silently [M26]' {
            $core = Get-Content -LiteralPath $script:SweepCore -Raw
            $core | Should -Match 'declared\s*\n?\s*dependency'
            $core | Should -Not -Match '\$script:PointerLinePattern\b(?![^\n]*MSPointer)' -Because 'the sibling''s private pattern is re-declared, not borrowed'
            $core | Should -Match 'MSPointerLinePattern'
            $core | Should -Match 'Set-StrictMode -Version Latest'
        }
    }

    Context 'AC7 - the chunk-3-facing shapes are documented as interfaces' {
        It 'names each interface in a section that says what consumes it' {
            $script:RecordsText | Should -Match '## Interfaces the next chunk consumes'
            foreach ($interface in @(
                    'The ledger record', 'The disposition vocabulary', 'The proposal record', 'Entry identity',
                    'The critical flag', 'Keep-hot expiry', 'Landing in flight', 'The cold archive',
                    'The destination measurement')) {
                $script:RecordsText | Should -Match ([regex]::Escape("**$interface**"))
            }
            $script:RecordsText | Should -Match 'an edit to the parent''s chunk boundary'
        }

        It 'names the disposition vocabulary the parser hard-rejects outside [M23]' {
            foreach ($d in @('promote', 'demote', 'keep-hot-with-expiry', 'settle-in-place', 'dedupe-into',
                    'remove-obsolete', 'remove-fails-admission', 'evaporate-on-close', 'restore',
                    'sweep-complete', 'ledger-compaction')) {
                $script:RecordsText | Should -Match ([regex]::Escape("``$d``")) -Because "the interface list must name $d"
            }
            $script:RecordsText | Should -Match 'reserved'
        }

        It 'states the producer obligation chunk 3 owes for the life key [M11]' {
            $script:RecordsText | Should -Match 'Chunk 3 owes the producer'
            $script:RecordsText | Should -Match 'must require `metadata\.admitted`'
            $script:RecordsText | Should -Match 'every identity in a real store is `@unknown`'
            # and the procedure says what to do with an undecidable verdict
            $script:ProcedureText | Should -Match 'undecidable'
            $script:ProcedureText | Should -Match 'dispositioned by the owner explicitly, or it is left hot'
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
