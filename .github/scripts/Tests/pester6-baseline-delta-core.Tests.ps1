#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for the post-port acceptance delta gate (issue #818 / s7).

.DESCRIPTION
    Contract under test, exercised against small synthetic fixture record
    arrays (not the real ~3400-test baseline artifacts):
      T1 - a genuinely new failure (Failed in candidate, Passed in baseline)
           is caught in newFailures and fails the gate
      T2 - a reason-change on an already-red test (Failed in both, different
           reason) is caught in reasonChanged and fails the gate (the
           #566-laundering guard from stress-test finding M9)
      T3 - a resolved failure (Failed in baseline, Passed in candidate) is
           reported in `resolved` but does NOT fail the gate
      T4 - a clean identical-failure-set (same identities, same statuses,
           same reasons) passes
      T5 - a discovery-error is treated as a failing status for both
           newFailures and reasonChanged purposes
      T6 - identity drift (renamed test) is reported via identityDrift and
           annotated against the known-rename-file allowlist, without by
           itself flipping the verdict
      T7 - reason normalization ignores volatile substrings (timestamps,
           GUIDs) so a reason that is substantively identical does not
           false-positive as reasonChanged
      T8 - the JSON-artifact I/O wrapper (Invoke-Pester6BaselineDelta) reads
           two real files on disk and drives the same verdict logic
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreFile = Join-Path $script:RepoRoot '.github/scripts/lib/pester6-baseline-delta-core.ps1'

    . $script:CoreFile

    function script:New-Rec {
        param(
            [string]$Identity,
            [string]$File = 'fixture.Tests.ps1',
            [string]$Status = 'Passed',
            [string]$Reason = '',
            [string]$Kind = 'test'
        )
        return [pscustomobject]@{
            kind     = $Kind
            identity = $Identity
            file     = $File
            status   = $Status
            reason   = $Reason
        }
    }
}

Describe 'pester6-baseline-delta-core — newFailures (AC1 violation set)' {

    It 'T1: a Passed-in-baseline test that is Failed in candidate is a new failure and fails the gate' {
        $baseline = @(
            script:New-Rec -Identity 'a.Tests.ps1 :: Suite > passes cleanly' -Status 'Passed'
        )
        $candidate = @(
            script:New-Rec -Identity 'a.Tests.ps1 :: Suite > passes cleanly' -Status 'Failed' -Reason 'Expected 1, got 2'
        )

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        $delta.verdict | Should -Be 'Fail'
        @($delta.newFailures).Count | Should -Be 1
        $delta.newFailures[0].identity | Should -Be 'a.Tests.ps1 :: Suite > passes cleanly'
        @($delta.reasonChanged).Count | Should -Be 0
    }

    It 'T1b: a test absent from the baseline entirely but Failed in candidate is also a new failure' {
        $baseline = @(
            script:New-Rec -Identity 'a.Tests.ps1 :: Suite > unrelated' -Status 'Passed'
        )
        $candidate = @(
            script:New-Rec -Identity 'a.Tests.ps1 :: Suite > unrelated' -Status 'Passed'
            script:New-Rec -Identity 'b.Tests.ps1 :: Suite > brand new failing test' -Status 'Failed' -Reason 'boom'
        )

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        $delta.verdict | Should -Be 'Fail'
        @($delta.newFailures).Count | Should -Be 1
        $delta.newFailures[0].identity | Should -Be 'b.Tests.ps1 :: Suite > brand new failing test'
        $delta.newFailures[0].baselineStatus | Should -BeNullOrEmpty
    }
}

Describe 'pester6-baseline-delta-core — reasonChanged (#566-laundering guard)' {

    It 'T2: a test Failed in both baseline and candidate, but with a different reason, is caught and fails the gate' {
        $baseline = @(
            script:New-Rec -Identity 'c.Tests.ps1 :: Suite > pre-existing red test' -Status 'Failed' -Reason 'unknown flag: --paginate'
        )
        $candidate = @(
            script:New-Rec -Identity 'c.Tests.ps1 :: Suite > pre-existing red test' -Status 'Failed' -Reason 'NullReferenceException: object reference not set'
        )

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        $delta.verdict | Should -Be 'Fail' -Because 'a same-test reason-change must not be silently waved through as pre-existing (#566-laundering)'
        @($delta.reasonChanged).Count | Should -Be 1
        $delta.reasonChanged[0].identity | Should -Be 'c.Tests.ps1 :: Suite > pre-existing red test'
        @($delta.newFailures).Count | Should -Be 0 -Because 'the identity already existed and was already failing, so it is a reason-change, not a new failure'
    }

    It 'T7: reason normalization ignores volatile substrings (timestamps, GUIDs) so a substantively identical reason does not false-positive' {
        $baseline = @(
            script:New-Rec -Identity 'd.Tests.ps1 :: Suite > flaky-ish red test' -Status 'Failed' -Reason 'captured at 2026-07-08T12:00:00.1234567Z with id 3fa85f64-5717-4562-b3fc-2c963f66afa6'
        )
        $candidate = @(
            script:New-Rec -Identity 'd.Tests.ps1 :: Suite > flaky-ish red test' -Status 'Failed' -Reason 'captured at 2026-07-09T03:31:08.0000000Z with id 11111111-2222-3333-4444-555555555555'
        )

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        @($delta.reasonChanged).Count | Should -Be 0 -Because 'timestamps and GUIDs are volatile substrings, not a substantive reason change'
        $delta.verdict | Should -Be 'Pass'
    }
}

Describe 'pester6-baseline-delta-core — resolved (informational only)' {

    It 'T3: a Failed-in-baseline test that is Passed in candidate is reported as resolved but does not fail the gate' {
        $baseline = @(
            script:New-Rec -Identity 'e.Tests.ps1 :: Suite > was red, now fixed' -Status 'Failed' -Reason 'Expected 0, got 1'
        )
        $candidate = @(
            script:New-Rec -Identity 'e.Tests.ps1 :: Suite > was red, now fixed' -Status 'Passed'
        )

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        $delta.verdict | Should -Be 'Pass' -Because 'improvements never fail the gate'
        @($delta.resolved).Count | Should -Be 1
        $delta.resolved[0].identity | Should -Be 'e.Tests.ps1 :: Suite > was red, now fixed'
        $delta.resolved[0].candidateStatus | Should -Be 'Passed'
    }

    It 'T3b: a Failed-in-baseline test entirely absent from candidate (e.g. deleted file) is also resolved, not a violation' {
        $baseline = @(
            script:New-Rec -Identity 'f.Tests.ps1 :: Suite > removed test' -Status 'Failed' -Reason 'gone now'
        )
        $candidate = @()

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        $delta.verdict | Should -Be 'Pass'
        @($delta.resolved).Count | Should -Be 1
    }
}

Describe 'pester6-baseline-delta-core — clean identical-failure-set passes' {

    It 'T4: identical baseline and candidate record sets (including a pre-existing failure) pass the gate cleanly' {
        $records = @(
            script:New-Rec -Identity 'g.Tests.ps1 :: Suite > passes' -Status 'Passed'
            script:New-Rec -Identity 'g.Tests.ps1 :: Suite > skipped' -Status 'Skipped'
            script:New-Rec -Identity 'g.Tests.ps1 :: Suite > pre-existing red' -Status 'Failed' -Reason 'Expected 0, got 1'
        )
        # Fresh copies so the two arrays are distinct object instances.
        $baseline = @($records | ForEach-Object { $_.PSObject.Copy() })
        $candidate = @($records | ForEach-Object { $_.PSObject.Copy() })

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        $delta.verdict | Should -Be 'Pass'
        @($delta.newFailures).Count | Should -Be 0
        @($delta.reasonChanged).Count | Should -Be 0
        @($delta.resolved).Count | Should -Be 0
        @($delta.identityDrift.missingFromCandidate).Count | Should -Be 0
        @($delta.identityDrift.newInCandidate).Count | Should -Be 0
    }
}

Describe 'pester6-baseline-delta-core — discovery-error handling' {

    It 'T5: a discovery-error is treated as a failing status for newFailures purposes' {
        $baseline = @(
            script:New-Rec -Identity 'h.Tests.ps1 :: <discovery>' -Status 'Passed' -Kind 'discovery-error'
        )
        $candidate = @(
            script:New-Rec -Identity 'h.Tests.ps1 :: <discovery>' -Status 'DiscoveryError' -Reason 'parse error' -Kind 'discovery-error'
        )

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        $delta.verdict | Should -Be 'Fail'
        @($delta.newFailures).Count | Should -Be 1
        $delta.newFailures[0].status | Should -Be 'DiscoveryError'
    }

    It 'T5b: a discovery-error present in both, with a different reason, is a reasonChanged' {
        $baseline = @(
            script:New-Rec -Identity 'i.Tests.ps1 :: <discovery>' -Status 'DiscoveryError' -Reason 'old parse error' -Kind 'discovery-error'
        )
        $candidate = @(
            script:New-Rec -Identity 'i.Tests.ps1 :: <discovery>' -Status 'DiscoveryError' -Reason 'new parse error' -Kind 'discovery-error'
        )

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate

        $delta.verdict | Should -Be 'Fail'
        @($delta.reasonChanged).Count | Should -Be 1
    }
}

Describe 'pester6-baseline-delta-core — identityDrift (renamed tests)' {

    It 'T6: a renamed It (old identity gone, new identity appears in the same file) is reported via identityDrift and does not by itself fail the gate' {
        $baseline = @(
            script:New-Rec -Identity 'j.Tests.ps1 :: Suite > old <token> name' -File 'j.Tests.ps1' -Status 'Passed'
        )
        $candidate = @(
            script:New-Rec -Identity 'j.Tests.ps1 :: Suite > old token-escaped name' -File 'j.Tests.ps1' -Status 'Passed'
        )

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate -KnownRenameFiles @('j.Tests.ps1')

        $delta.verdict | Should -Be 'Pass' -Because 'a passing test being renamed is not a failure-status transition'
        @($delta.identityDrift.missingFromCandidate).Count | Should -Be 1
        @($delta.identityDrift.newInCandidate).Count | Should -Be 1
        $delta.identityDrift.missingFromCandidate[0].expectedRenameFile | Should -Be $true
        $delta.identityDrift.newInCandidate[0].expectedRenameFile | Should -Be $true
    }

    It 'T6b: identity drift in a file NOT on the known-rename allowlist is still reported, flagged as unexpected' {
        $baseline = @(
            script:New-Rec -Identity 'k.Tests.ps1 :: Suite > vanished test' -File 'k.Tests.ps1' -Status 'Passed'
        )
        $candidate = @()

        $delta = Compare-Pester6BaselineRecords -BaselineRecords $baseline -CandidateRecords $candidate -KnownRenameFiles @('j.Tests.ps1')

        @($delta.identityDrift.missingFromCandidate).Count | Should -Be 1
        $delta.identityDrift.missingFromCandidate[0].expectedRenameFile | Should -Be $false
    }
}

Describe 'pester6-baseline-delta-core — Invoke-Pester6BaselineDelta (JSON artifact I/O)' {

    BeforeAll {
        $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester6-baseline-delta-fixture-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:FixtureDir -Force | Out-Null

        $script:BaselineJsonPath = Join-Path $script:FixtureDir 'baseline.json'
        $script:CandidateJsonPath = Join-Path $script:FixtureDir 'candidate.json'

        $baselineArtifact = [ordered]@{
            requiredVersion = '5.7.1'
            summary         = [ordered]@{ totalTests = 2; passed = 1; failed = 1; skipped = 0; notRun = 0; discoveryErrors = 0 }
            records         = @(
                [ordered]@{ kind = 'test'; identity = 'x.Tests.ps1 :: Suite > ok'; file = 'x.Tests.ps1'; status = 'Passed'; reason = '' }
                [ordered]@{ kind = 'test'; identity = 'x.Tests.ps1 :: Suite > pre-existing red'; file = 'x.Tests.ps1'; status = 'Failed'; reason = 'known issue' }
            )
        }
        $candidateArtifactNewFailure = [ordered]@{
            requiredVersion = '6.0.0'
            summary         = [ordered]@{ totalTests = 2; passed = 1; failed = 1; skipped = 0; notRun = 0; discoveryErrors = 0 }
            records         = @(
                [ordered]@{ kind = 'test'; identity = 'x.Tests.ps1 :: Suite > ok'; file = 'x.Tests.ps1'; status = 'Failed'; reason = 'newly broken under 6.x' }
                [ordered]@{ kind = 'test'; identity = 'x.Tests.ps1 :: Suite > pre-existing red'; file = 'x.Tests.ps1'; status = 'Failed'; reason = 'known issue' }
            )
        }

        ($baselineArtifact | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:BaselineJsonPath -Encoding UTF8
        ($candidateArtifactNewFailure | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:CandidateJsonPath -Encoding UTF8
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:FixtureDir) {
            Remove-Item -LiteralPath $script:FixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'T8: reads two JSON artifacts from disk, drives the same verdict logic, and reports ExitCode 1 on a real new failure' {
        $outJson = Join-Path $script:FixtureDir 'delta.json'
        $outMd = Join-Path $script:FixtureDir 'delta.md'

        $result = Invoke-Pester6BaselineDelta -BaselinePath $script:BaselineJsonPath -CandidatePath $script:CandidateJsonPath -OutputJsonPath $outJson -OutputMarkdownPath $outMd

        $result.ExitCode | Should -Be 1
        $result.Result.verdict | Should -Be 'Fail'
        @($result.Result.newFailures).Count | Should -Be 1
        $result.Result.newFailures[0].identity | Should -Be 'x.Tests.ps1 :: Suite > ok'

        Test-Path -LiteralPath $outJson | Should -Be $true
        Test-Path -LiteralPath $outMd | Should -Be $true
        (Get-Content -LiteralPath $outMd -Raw) | Should -Match 'FAIL'
    }

    It 'T8b: a missing BaselinePath fails loudly with ExitCode 1 instead of throwing an uncaught exception' {
        $result = Invoke-Pester6BaselineDelta -BaselinePath (Join-Path $script:FixtureDir 'does-not-exist.json') -CandidatePath $script:CandidateJsonPath
        $result.ExitCode | Should -Be 1
        $result.Result | Should -BeNullOrEmpty
    }
}
