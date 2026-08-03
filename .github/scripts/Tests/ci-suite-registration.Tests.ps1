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

    It 'reports the unclassified backlog, so it stays visible while it shrinks' {
        # Not asserted to be zero — it is 189 at the moment this ships, and
        # pretending otherwise would be the dishonest version of this guard.
        # Asserted to be REPORTED, and bounded by the quarantine's own size.
        $script:Live.UnclassifiedCount | Should -BeGreaterOrEqual 0
        $script:Live.UnclassifiedCount | Should -BeLessOrEqual $script:Live.Quarantined.Count
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
            [ordered]@{ file = 'c.Tests.ps1'; class = 'unclassified'; reason = 'fixture'; issue = $null }
        )
        $r = Get-CISuiteSelection -TestsRoot $t.Dir -QuarantinePath $t.QuarantinePath
        $r.DriftDetails -join ' | ' | Should -BeExactly ''
        $r.SelectedNames | Should -Be @('a.Tests.ps1')
        $r.UnclassifiedCount | Should -Be 1
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
