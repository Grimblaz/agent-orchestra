#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for Build-DeferredPortCreditRow (issue #443, Step 4).
#
# Generic emitter for ports whose trigger predicate is formalized but deferred.
# The evidence string always begins with DEFERRED(#NNN): — this prefix is the
# migration-detection contract (regex ^DEFERRED\(#\d+\):).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $lib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $lib) { . $lib }
}

Describe 'Build-DeferredPortCreditRow' {
    It 'port matches the supplied Port parameter' {
        $row = Build-DeferredPortCreditRow -Port 'process-retrospective' -DeferredToIssue 348
        $row.port | Should -Be 'process-retrospective'
    }

    It 'status is always not-applicable' {
        $row = Build-DeferredPortCreditRow -Port 'process-retrospective' -DeferredToIssue 348
        $row.status | Should -Be 'not-applicable'
    }

    It 'evidence starts with DEFERRED(#NNN): prefix' {
        $row = Build-DeferredPortCreditRow -Port 'process-retrospective' -DeferredToIssue 348
        $row.evidence | Should -Match '^DEFERRED\(#\d+\):'
    }

    It 'evidence contains the correct issue number' {
        $row = Build-DeferredPortCreditRow -Port 'process-retrospective' -DeferredToIssue 348
        $row.evidence | Should -BeLike '*DEFERRED(#348):*'
    }

    It 'default AdapterName is explicit-skip' {
        $row = Build-DeferredPortCreditRow -Port 'process-retrospective' -DeferredToIssue 348
        $row.adapter | Should -Be 'explicit-skip'
    }

    It 'accepts custom AdapterName' {
        $row = Build-DeferredPortCreditRow -Port 'process-retrospective' -DeferredToIssue 348 -AdapterName 'custom'
        $row.adapter | Should -Be 'custom'
    }

    It 'includes DeferredSince in auto-generated evidence' {
        $row = Build-DeferredPortCreditRow -Port 'process-retrospective' -DeferredToIssue 348 -DeferredSince '2026-05-03'
        $row.evidence | Should -BeLike '*2026-05-03*'
    }

    It 'custom Evidence suffix appears after DEFERRED(#NNN): prefix' {
        $row = Build-DeferredPortCreditRow -Port 'process-retrospective' -DeferredToIssue 348 -Evidence 'custom note'
        $row.evidence | Should -Be 'DEFERRED(#348): custom note'
    }

    It 'works for any port name, not just process-retrospective' {
        $row = Build-DeferredPortCreditRow -Port 'some-other-port' -DeferredToIssue 999
        $row.port | Should -Be 'some-other-port'
        $row.evidence | Should -Match '^DEFERRED\(#999\):'
    }
}
