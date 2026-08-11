#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    The guard that makes CI's suite selection unable to drift quietly.

.DESCRIPTION
    CI used to carry a hand-maintained ALLOWLIST of test files. That makes
    exclusion the default and makes it silent: a suite is unprotected from the
    moment it is written, and nothing notices. Measured at the point this
    shipped — 52 files registered, 191 not, 4,136 of 5,475 test blocks never
    running in CI, including suites written the same week.

    Selection is now a glob minus an explicit quarantine, and this file is what
    keeps the two honest. Its central property:

      EVERY *.Tests.ps1 ON DISK IS EITHER RUN OR EXPLICITLY QUARANTINED.

    The converse matters just as much and is asserted separately: a quarantine
    entry must name a file that EXISTS. Without that, the registry silently
    accumulates entries for deleted suites, and "quarantined" stops
    distinguishing skipped coverage from deleted coverage.

    This file is itself selected by the glob, so the guard cannot be dropped
    without dropping the thing that would report it.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:RepoRoot '.github/scripts/lib/ci-suite-selection-core.ps1')
    $script:TestsRoot = Join-Path $script:RepoRoot '.github/scripts/Tests'
    $script:QuarantinePath = Join-Path $script:TestsRoot 'ci-quarantine.json'
    $script:Live = Get-CISuiteSelection -TestsRoot $script:TestsRoot -QuarantinePath $script:QuarantinePath

    # Mutations run against a throwaway registry outside the repo, never
    # against the live one — the working tree is not a fixture.
    $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("ci-suite-sel-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Scratch | Out-Null
    function script:New-ScratchTree {
        param([string[]]$Files, [object[]]$Quarantine)
        $dir = Join-Path $script:Scratch ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($f in $Files) { Set-Content -LiteralPath (Join-Path $dir $f) -Value '# fixture' -Encoding utf8 }
        $qp = Join-Path $dir 'ci-quarantine.json'
        Set-Content -LiteralPath $qp -Value (([ordered]@{ quarantine = @($Quarantine) }) | ConvertTo-Json -Depth 6) -Encoding utf8
        return [PSCustomObject]@{ Dir = $dir; QuarantinePath = $qp }
    }
}

AfterAll {
    if ($script:Scratch -and (Test-Path -LiteralPath $script:Scratch)) {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'CI suite selection: the live tree' {

    It 'has no drift — every suite is either selected or explicitly quarantined' {
        $script:Live.DriftDetails -join ' | ' | Should -BeExactly ''
        $script:Live.HasDrift | Should -BeFalse
    }

    It 'actually selected something, and the numbers add up (a guard over an empty set passes vacuously)' {
        $onDisk = @(Get-ChildItem -LiteralPath $script:TestsRoot -Filter '*.Tests.ps1' -File).Count
        $script:Live.Selected.Count | Should -BeGreaterThan 0
        ($script:Live.Selected.Count + $script:Live.Quarantined.Count) | Should -Be $onDisk
    }

    It 'runs THIS file, so the guard cannot be silently dropped' {
        $script:Live.SelectedNames | Should -Contain 'ci-suite-registration.Tests.ps1'
    }

    It 'holds no entry whose justification is that nobody looked' {
        # This assertion replaces one that could not fail. It read
        # `UnclassifiedCount -BeGreaterOrEqual 0` and `-BeLessOrEqual` the size
        # of the set it is a subset of: a tautology and a structural bound, both
        # green over a registry of 189 unmeasured entries. Issue #1035 measured
        # the whole corpus on Linux and #1036 spent that measurement, so the
        # honest assertion is now available and is the one that stands.
        $script:Live.UnclassifiedCount | Should -Be 0 -Because 'the `unclassified` class was retired by #1036; an entry still carrying it rests on nobody having measured the suite, which is no longer true of any suite here'
    }

    It 'every entry meets its own class requirement, so the next one that does not is refused rather than regretted' {
        # The whole of T1 in one live assertion: legal class, non-empty reason,
        # and an issue on every class whose exclusion is expected to end. It is
        # a restatement of HasDrift over exactly the entry-level rules, kept
        # separate so a failure names the registry rather than the tree.
        # The enums come from the LIBRARY, not from literals retyped here. A
        # copy would turn this live assertion red for a conforming registry the
        # day a lawful fourth class is added, training the next author to edit
        # the literal rather than read the guard — which is the defect this file
        # argues against for pinned counts further down.
        $legal = $script:CIQuarantineClasses
        $ticketed = $script:CIQuarantineIssueRequiredClasses
        $legal | Should -Not -BeNullOrEmpty -Because 'the library must actually export the class set this test reads'
        $ticketed | Should -Not -BeNullOrEmpty -Because 'the library must actually export the issue-required set this test reads'

        $examined = 0
        foreach ($e in $script:Live.Quarantined) {
            [string]$e.class | Should -BeIn $legal -Because "$($e.file) must carry a class that is a decision about a measured suite"
            [string]$e.reason | Should -Not -BeNullOrEmpty -Because "$($e.file) must say why it is skipped"
            if ([string]$e.class -in $ticketed) {
                $hasIssue = ($e.PSObject.Properties.Match('issue').Count -gt 0) -and -not [string]::IsNullOrWhiteSpace([string]$e.issue)
                $hasIssue | Should -BeTrue -Because "$($e.file) is class '$($e.class)', whose exclusion is expected to end, so something must be tracking that ending"
            }
            $examined++
        }

        # A foreach over an empty collection runs zero assertions and reports
        # green, so the coverage is asserted rather than assumed. An EMPTY
        # registry is a lawful end state here — #1047 is expected to keep
        # shrinking it — so this is deliberately not a "greater than zero"
        # floor; it is the statement that whatever the registry holds, this
        # test looked at all of it.
        $examined | Should -Be $script:Live.Quarantined.Count -Because 'every entry in the registry must have been examined, and an empty registry must report zero examined rather than silently skipping a populated one'
    }

    It 'every suite the gate ENUMERATES is either selected or admitted by a live registry entry (T6 coverage)' {
        # TWO LIMITS, STATED, because an earlier revision of this test was
        # titled "no suite beneath the tests root is absent from the gate for
        # any other reason" and could not deliver that universal:
        #
        #   1. The enumeration is NON-RECURSIVE (ci-suite-selection-core.ps1's
        #      Get-ChildItem -Filter, no -Recurse), so a suite in a SUBDIRECTORY
        #      of the tests root is absent from the gate, produces no drift, and
        #      is invisible here. audit-controls/README.md records the same fact.
        #   2. Name comparison is `-notcontains`, which is CASE-INSENSITIVE,
        #      while CI's filesystem is case-SENSITIVE. An entry differing only
        #      in case excludes the suite it names on Linux while reporting no
        #      stale entry and no drift.
        #
        # Both are properties of the selection library that predate this test
        # and neither is closed here. What this asserts is the narrower true
        # thing: over the population the gate actually enumerates, every absent
        # suite is absent on an entry the registry admits.
        # The gate selects by SUBTRACTION, so `selected = onDisk - registry`
        # holds by construction and proves nothing on its own. What this asserts
        # is the part that does not: that every subtracted name is subtracted by
        # an entry the clause above ADMITS. Before #1036 this was false for 188
        # suites — they were absent on entries carrying a class that no longer
        # exists — and the difference is empty only because that was fixed.
        $admitted = @(
            $script:Live.Quarantined |
                Where-Object {
                    [string]$_.class -in $script:CIQuarantineClasses -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.reason)
                } |
                ForEach-Object { [string]$_.file }
        )
        $onDiskNames = @(Get-ChildItem -LiteralPath $script:TestsRoot -Filter '*.Tests.ps1' -File | ForEach-Object { $_.Name })
        $absentButNotAdmitted = @($onDiskNames | Where-Object { $script:Live.SelectedNames -notcontains $_ -and $admitted -notcontains $_ })
        $absentButNotAdmitted | Should -BeNullOrEmpty -Because 'over the population the gate enumerates, a suite absent on an entry the registry no longer admits is the silent exclusion this registry replaced an allowlist to prevent'
    }

    It 'the one exemption the registry cannot express is stated rather than silent (T6 disclosure)' {
        # The audit controls exist to exhibit each terminal state — including
        # one that never returns. They are exempt from the gate by PLACEMENT,
        # outside the tests root, because the contributor-facing recursive
        # `Invoke-Pester` over that root is quarantine-blind and would hang on
        # it. That is a deliberate decision, and this assertion is what makes it
        # distinguishable from an oversight: if a control is ever moved beneath
        # the tests root, it must be registered like anything else.
        $controlsRoot = Join-Path $script:RepoRoot '.github/scripts/audit-controls'
        Test-Path -LiteralPath $controlsRoot | Should -BeTrue -Because 'the exemption is a real directory, not a story about one'
        $controls = @(Get-ChildItem -LiteralPath $controlsRoot -Filter '*.Tests.ps1' -File | ForEach-Object { $_.Name })
        $controls.Count | Should -BeGreaterThan 0

        # Keyed on the CONTROL NAMING CONVENTION found beneath the tests root,
        # not on the list of controls still sitting in audit-controls/. An
        # earlier revision iterated the latter, which detects a COPY into the
        # tests root and is structurally blind to the MOVE its own comment
        # claims to guard: a moved control drops out of the collection being
        # iterated, so nothing checks it. That matters most for the one control
        # that never returns — beneath the tests root it would be selected by
        # the glob with no registry entry and hold the gate to its timeout.
        $onDiskNames = @(Get-ChildItem -LiteralPath $script:TestsRoot -Filter '*.Tests.ps1' -File | ForEach-Object { $_.Name })
        $strays = @($onDiskNames | Where-Object { $_ -like '*.Control.Tests.ps1' })
        $strays | Should -BeNullOrEmpty -Because 'an audit control beneath the tests root is selected by the glob with no registry entry; the controls are exempt by living OUTSIDE that root, and one of them never returns'

        foreach ($c in $controls) {
            $onDiskNames | Should -Not -Contain $c -Because "$c is exempt from the gate by living outside the tests root; beneath it, it would need a registry entry like any other suite"
        }
    }
}

Describe 'CI suite selection: one induced failure per class the guard claims to catch' {

    It 'INDUCED (new-suite class): a suite that is neither run nor quarantined FAILS' {
        # The defect this whole change exists to close: a file appears and is
        # silently unprotected. Here selection is "everything not quarantined",
        # so a new file is picked UP — the assertion is that it is not lost.
        $t = script:New-ScratchTree -Files @('a.Tests.ps1', 'b.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'b.Tests.ps1'; class = 'never-ci'; reason = 'fixture'; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.SelectedNames | Should -Contain 'a.Tests.ps1'
        $r.SelectedNames | Should -Not -Contain 'b.Tests.ps1'
        $r.HasDrift | Should -BeFalse
    }

    It 'INDUCED (stale-entry class): a quarantine entry naming a deleted file FAILS' {
        $t = script:New-ScratchTree -Files @('a.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'gone.Tests.ps1'; class = 'never-ci'; reason = 'fixture'; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'do not exist'
        ($r.DriftDetails -join ' ') | Should -Match 'gone\.Tests\.ps1'
    }

    It 'INDUCED (unjustified-exclusion class): an entry with no reason FAILS' {
        $t = script:New-ScratchTree -Files @('a.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'never-ci'; reason = ''; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'empty reason'
    }

    It 'INDUCED (unknown-class class): an entry with an invented class FAILS' {
        $t = script:New-ScratchTree -Files @('a.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'later-maybe'; reason = 'fixture'; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'is not one of'
    }

    It 'INDUCED (retired class): an entry still classed `unclassified` FAILS, and the refusal names the retirement' {
        # The class this registry carried for 189 entries. Retiring it is the
        # whole enforcement half of #1036: without this, "nobody looked" stays
        # a legal justification and the backlog can grow back one entry at a
        # time. The input here is one the pre-work registry ACTUALLY CONTAINED,
        # reason text and all, so this is not a hypothetical rejection.
        $preWorkReason = 'Never registered under the allowlist this registry replaces, and never excluded for a stated reason — it was simply omitted. Whether it is CI-viable has not been measured on Linux.'
        $t = script:New-ScratchTree -Files @('a.Tests.ps1', 'b.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'unclassified'; reason = $preWorkReason; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'RETIRED by issue #1036'
        $r.UnclassifiedCount | Should -Be 1 -Because 'the count still reports the retired class so the gate can say the backlog is gone rather than leave it inferred'
    }

    It 'INDUCED (retired class, freshly phrased): the refusal is on the CLASS and survives wording it has never seen' {
        # 187 of the 188 pre-work entries carried ONE byte-identical sentence.
        # A guard keyed on that sentence would pass both polarity arms above and
        # then wave through every future entry phrased differently — which is
        # the specific way this check could be vacuous. So: same class, a reason
        # this repository has never contained, and it must still be refused.
        $t = script:New-ScratchTree -Files @('a.Tests.ps1', 'b.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'unclassified'; reason = 'Nobody has got round to checking whether this one works on the build machines yet.'; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'RETIRED by issue #1036'
    }

    It 'CONVERSE: the pre-work sentence on a LEGAL class is clean, so the refusal is provably not keyed on wording' {
        # The other half of the same property, and the half that is easy to
        # leave out. If the check inspected the reason text, this tree would go
        # red — the reason is the exact 187-entry sentence. It must not.
        $preWorkReason = 'Never registered under the allowlist this registry replaces, and never excluded for a stated reason — it was simply omitted. Whether it is CI-viable has not been measured on Linux.'
        $t = script:New-ScratchTree -Files @('a.Tests.ps1', 'b.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'never-ci'; reason = $preWorkReason; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.DriftDetails -join ' | ' | Should -BeExactly ''
        $r.HasDrift | Should -BeFalse
    }

    It 'INDUCED (ticketless no-signal): a suite that yields no verdict needs a ticket for the condition that will end it' {
        # Amendment 6 E1. Three suites are `executed-no-tests` because every
        # test in them is skipped behind a dated Copilot-sunset TODO. Neither
        # surviving class was a true statement about them: they are not failing
        # on the platform, and the condition is not permanent. The cheap fix —
        # widening never-ci — would have weakened the one class the whole triage
        # exists to police, so this class carries linux-red's issue cost.
        $bad = script:New-ScratchTree -Files @('a.Tests.ps1', 'b.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'no-signal'; reason = 'every test skipped'; issue = $null }
        )
        $rBad = Get-CISuiteSelection -TestsRoot $bad.Dir -QuarantinePath $bad.QuarantinePath
        $rBad.HasDrift | Should -BeTrue
        ($rBad.DriftDetails -join ' ') | Should -Match 'no issue number'

        $good = script:New-ScratchTree -Files @('a.Tests.ps1', 'b.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'no-signal'; reason = 'every test skipped behind a dated sunset TODO'; issue = 651 }
        )
        $rGood = Get-CISuiteSelection -TestsRoot $good.Dir -QuarantinePath $good.QuarantinePath
        $rGood.DriftDetails -join ' | ' | Should -BeExactly ''
        $rGood.HasDrift | Should -BeFalse
    }

    It 'INDUCED (ticketless-temporary class): linux-red with no issue FAILS, never-ci without one does NOT' {
        # The distinction the three classes exist for. A temporary exclusion
        # with no ticket is a permanent one that has not admitted it; a
        # permanent one does not need a ticket it will never close.
        $red = script:New-ScratchTree -Files @('a.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'linux-red'; reason = 'fixture'; issue = $null }
        )
        $rRed = Get-CISuiteSelection -TestsRoot $red.Dir -QuarantinePath $red.QuarantinePath
        $rRed.HasDrift | Should -BeTrue
        ($rRed.DriftDetails -join ' ') | Should -Match 'no issue number'

        # Two files, so quarantining one does not also trip the
        # empty-selection rule and make this assertion pass for the wrong
        # reason — the first draft of this fixture did exactly that.
        $perm = script:New-ScratchTree -Files @('a.Tests.ps1', 'keeps-selection-non-empty.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'never-ci'; reason = 'needs a live gh'; issue = $null }
        )
        $rPerm = Get-CISuiteSelection -TestsRoot $perm.Dir -QuarantinePath $perm.QuarantinePath
        $rPerm.DriftDetails -join ' | ' | Should -BeExactly ''
        $rPerm.HasDrift | Should -BeFalse
    }

    It 'INDUCED (missing-registry class): an absent registry FAILS instead of selecting everything' {
        # Fail-open is the shape this guard exists to prevent: a vanished
        # config file must not read as "nothing to exclude".
        $t = script:New-ScratchTree -Files @('a.Tests.ps1') -Quarantine @()
        Remove-Item -LiteralPath $t.QuarantinePath -Force
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.HasDrift | Should -BeTrue
        $r.Selected.Count | Should -Be 0
        ($r.DriftDetails -join ' ') | Should -Match 'not found'
    }

    It 'INDUCED (unparseable-registry class): malformed JSON FAILS' {
        $t = script:New-ScratchTree -Files @('a.Tests.ps1') -Quarantine @()
        Set-Content -LiteralPath $t.QuarantinePath -Value '{ "quarantine": [ ' -Encoding utf8
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'did not parse'
    }

    It 'INDUCED (everything-quarantined class): a selection of nothing FAILS' {
        # A run that selects no suites reports green for the same reason an
        # empty test run does.
        $t = script:New-ScratchTree -Files @('a.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'a.Tests.ps1'; class = 'never-ci'; reason = 'fixture'; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.HasDrift | Should -BeTrue
        ($r.DriftDetails -join ' ') | Should -Match 'every suite on disk is quarantined'
    }

    It 'POSITIVE CONTROL: a well-formed tree with a real quarantine reports clean' {
        # Without this, every assertion above is satisfied by a function that
        # returns HasDrift = $true for all inputs.
        $t = script:New-ScratchTree -Files @('a.Tests.ps1', 'b.Tests.ps1', 'c.Tests.ps1') -Quarantine @(
            [ordered]@{ file = 'b.Tests.ps1'; class = 'linux-red'; reason = 'fixture'; issue = 123 },
            [ordered]@{ file = 'c.Tests.ps1'; class = 'never-ci'; reason = 'fixture'; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.DriftDetails -join ' | ' | Should -BeExactly ''
        $r.SelectedNames | Should -Be @('a.Tests.ps1')
        $r.UnclassifiedCount | Should -Be 0
    }
}

Describe 'CI suite selection: properties that do not rot' {

    It 'no file is both selected and quarantined' {
        # Deliberately NOT "the selected count is 52". A pinned count is a
        # driftable constant that fails the first time a suite is legitimately
        # added — which would train the next author to edit the number rather
        # than read the guard, and that is the defect class this whole change
        # exists to close. The migration's conservatism was verified once, as
        # evidence in the PR; what stands here are properties that stay true.
        $q = @($script:Live.Quarantined | ForEach-Object { [string]$_.file })
        @($script:Live.SelectedNames | Where-Object { $q -contains $_ }) | Should -BeNullOrEmpty
    }

    It 'every quarantine entry carries a reason a human wrote' {
        foreach ($e in $script:Live.Quarantined) {
            [string]$e.reason | Should -Not -BeNullOrEmpty -Because "$($e.file) must say why it is skipped"
        }
    }

    It 'the two suites the old workflow excluded IN PROSE kept their stated reason and ticket' {
        $byName = @{}
        foreach ($q in $script:Live.Quarantined) { $byName[[string]$q.file] = $q }
        $byName['session-cleanup-detector.Tests.ps1'].class | Should -BeExactly 'linux-red'
        $byName['session-cleanup-detector.Tests.ps1'].issue | Should -Be 904
        $byName['cost-baseline-harvest.Tests.ps1'].class | Should -BeExactly 'linux-red'
        $byName['cost-baseline-harvest.Tests.ps1'].issue | Should -Be 909
    }
}
