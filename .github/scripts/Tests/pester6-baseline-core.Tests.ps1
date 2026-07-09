#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for the version-pinned, per-test-identity Pester baseline
    capture tool (issue #818 / s2).

.DESCRIPTION
    Contract under test:
      T1 - RequiredVersion is a mandatory parameter (no "newest installed" default)
      T2 - the captured baseline records the Pester version actually imported,
           and it matches whatever -RequiredVersion was requested, proving the
           child process honors the pin rather than resolving ambiently
      T3 - records carry full Describe > Context > It identity (not just counts)
      T4 - a failed test's record carries a non-empty failure reason
      T5 - a passed test's record carries an empty reason
      T6 - a discovery-time throw in one file does not prevent a sibling file's
           tests from running (the run is not crashed/collapsed)
      T7 - the discovery-time throw is recorded as a distinct discovery-error
           record carrying the throw's message, not silently dropped

    NOTE: This file exercises the real child-pwsh subprocess path against a
    small scratch fixture directory (not the full 186-file suite) — each
    Invoke-Pester6BaselineCapture call spawns a fresh pwsh process, so this
    file is slower than a pure-unit test file but still runs in low-single-
    digit seconds per call. It is intentionally NOT registered in pester.yml's
    CI run list (per the plan's non-goal: s2 does not touch pester.yml); CI
    installs only a single pinned Pester major via pester.yml, and T2's
    honoring proof needs at least two distinct installed majors to be
    meaningful.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreFile = Join-Path $script:RepoRoot '.github/scripts/lib/pester6-baseline-core.ps1'

    . $script:CoreFile

    # Discover installed Pester versions to drive the RequiredVersion-honoring
    # tests without hardcoding version numbers that may drift after this
    # migration completes.
    $script:InstalledVersions = @(
        Get-Module -Name Pester -ListAvailable |
            Select-Object -ExpandProperty Version |
            Sort-Object -Descending -Unique |
            ForEach-Object { $_.ToString() }
    )

    function script:New-BaselineFixture {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "pester6-baseline-fixture-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $mixedContent = @'
Describe 'Fixture Suite' {
    Context 'inner context' {
        It 'passing behavior' { 1 | Should -Be 1 }
        It 'failing behavior' { 1 | Should -Be 2 }
    }
}
'@
        Set-Content -Path (Join-Path $dir 'mixed.Tests.ps1') -Value $mixedContent -Encoding UTF8

        $throwingContent = @'
throw 'deliberate discovery-time throw for pester6-baseline-core.Tests.ps1'
Describe 'Never reached' {
    It 'never runs' { 1 | Should -Be 1 }
}
'@
        Set-Content -Path (Join-Path $dir 'throwing.Tests.ps1') -Value $throwingContent -Encoding UTF8

        return $dir
    }
}

Describe 'pester6-baseline-core — RequiredVersion is mandatory and honored' {

    It 'T1: RequiredVersion is a mandatory parameter on Invoke-Pester6BaselineCapture' {
        $cmd = Get-Command Invoke-Pester6BaselineCapture
        $param = $cmd.Parameters['RequiredVersion']
        $param | Should -Not -BeNullOrEmpty
        $isMandatory = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            ForEach-Object { $_.Mandatory } | Where-Object { $_ }
        $isMandatory | Should -Not -BeNullOrEmpty -Because 'the tool exists specifically because run-pester-sharded.ps1 auto-resolves "newest installed" with no version selector; a default here would reintroduce that gap'
    }

    It 'T1b: RequiredVersion is a mandatory parameter on capture-pester6-baseline.ps1' {
        $wrapperPath = Join-Path $script:RepoRoot '.github/scripts/capture-pester6-baseline.ps1'
        Test-Path -LiteralPath $wrapperPath | Should -Be $true
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$null, [ref]$null)
        $paramBlock = $ast.ParamBlock
        $requiredVersionParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RequiredVersion' }
        $requiredVersionParam | Should -Not -BeNullOrEmpty
        $hasMandatory = $requiredVersionParam.Attributes | Where-Object {
            $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'Parameter'
        } | ForEach-Object {
            $_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' }
        }
        $hasMandatory | Should -Not -BeNullOrEmpty -Because 'the CLI wrapper must not silently default to "newest installed" either'
    }

    It 'T1c: an unrecognized RequiredVersion fails loudly instead of silently falling through' {
        $fixtureDir = script:New-BaselineFixture
        try {
            $result = Invoke-Pester6BaselineCapture -TestsPath $fixtureDir -RequiredVersion '999.999.999'
            $result.ExitCode | Should -Be 1 -Because 'a non-installed version must fail the capture, not silently substitute a different one'
        }
        finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'T2: the captured baseline records the Pester version actually imported, matching the requested -RequiredVersion' {
        if ($script:InstalledVersions.Count -lt 2) {
            Set-ItResult -Skipped -Because 'this proof needs at least two distinct installed Pester majors; only one is present in this environment'
            return
        }

        $fixtureDir = script:New-BaselineFixture
        try {
            foreach ($v in $script:InstalledVersions[0..1]) {
                $result = Invoke-Pester6BaselineCapture -TestsPath $fixtureDir -RequiredVersion $v
                $result.ExitCode | Should -Be 0 -Because "capture under Pester $v should succeed"
                $result.Result.requiredVersion | Should -Be $v
                $result.Result.importedVersion | Should -Be $v -Because 'the child process must import the exact requested version, not whatever resolves ambiently'
            }
        }
        finally {
            Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'pester6-baseline-core — test-identity + failure-reason capture' {

    BeforeAll {
        if ($script:InstalledVersions.Count -eq 0) {
            throw 'No Pester version is installed; cannot exercise the capture tool.'
        }
        $script:ProbeVersion = $script:InstalledVersions[0]
        $script:FixtureDir = script:New-BaselineFixture
        $script:CaptureResult = Invoke-Pester6BaselineCapture -TestsPath $script:FixtureDir -RequiredVersion $script:ProbeVersion
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:FixtureDir) {
            Remove-Item -LiteralPath $script:FixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'T3a: capture succeeds against the fixture directory' {
        $script:CaptureResult.ExitCode | Should -Be 0
    }

    It 'T3b: emits per-test identity records carrying the full Describe > Context > It path, not just aggregate counts' {
        $testRecords = @($script:CaptureResult.Result.records | Where-Object { $_.kind -eq 'test' })
        $testRecords.Count | Should -Be 2 -Because 'the fixture defines exactly two It blocks'

        $passingRecord = $testRecords | Where-Object { $_.identity -match 'passing behavior' }
        $passingRecord | Should -Not -BeNullOrEmpty
        $passingRecord.identity | Should -Match 'Fixture Suite' -Because 'identity must carry the Describe name'
        $passingRecord.identity | Should -Match 'inner context' -Because 'identity must carry the Context name'
        $passingRecord.file | Should -Match 'mixed\.Tests\.ps1'
    }

    It 'T4: a failed test record carries a non-empty failure reason' {
        $testRecords = @($script:CaptureResult.Result.records | Where-Object { $_.kind -eq 'test' })
        $failingRecord = $testRecords | Where-Object { $_.identity -match 'failing behavior' }
        $failingRecord | Should -Not -BeNullOrEmpty
        $failingRecord.status | Should -Be 'Failed'
        $failingRecord.reason | Should -Not -BeNullOrEmpty -Because 'a delta gate that only sees counts cannot tell a genuine regression from a pre-existing failure'
        $failingRecord.reason | Should -Match 'Expected'
    }

    It 'T5: a passed test record carries an empty reason' {
        $testRecords = @($script:CaptureResult.Result.records | Where-Object { $_.kind -eq 'test' })
        $passingRecord = $testRecords | Where-Object { $_.identity -match 'passing behavior' }
        $passingRecord.status | Should -Be 'Passed'
        $passingRecord.reason | Should -BeNullOrEmpty
    }

    It 'T3c: the summary counts match the record-level detail' {
        $summary = $script:CaptureResult.Result.summary
        $summary.passed | Should -Be 1
        $summary.failed | Should -Be 1
    }
}

Describe 'pester6-baseline-core — discovery-time throw handling' {

    BeforeAll {
        if ($script:InstalledVersions.Count -eq 0) {
            throw 'No Pester version is installed; cannot exercise the capture tool.'
        }
        $script:ProbeVersion2 = $script:InstalledVersions[0]
        $script:FixtureDir2 = script:New-BaselineFixture
        $script:CaptureResult2 = Invoke-Pester6BaselineCapture -TestsPath $script:FixtureDir2 -RequiredVersion $script:ProbeVersion2
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:FixtureDir2) {
            Remove-Item -LiteralPath $script:FixtureDir2 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'T6: a discovery-time throw in one file does not prevent a sibling file''s tests from running' {
        $script:CaptureResult2.ExitCode | Should -Be 0 -Because 'the capture itself must not crash when one file throws at discovery time'
        $testRecords = @($script:CaptureResult2.Result.records | Where-Object { $_.kind -eq 'test' })
        $testRecords.Count | Should -Be 2 -Because 'mixed.Tests.ps1''s two tests must still be captured even though throwing.Tests.ps1 failed discovery'
    }

    It 'T7: the discovery-time throw is recorded as a distinct discovery-error record carrying the throw message' {
        $discoveryRecords = @($script:CaptureResult2.Result.records | Where-Object { $_.kind -eq 'discovery-error' })
        $discoveryRecords.Count | Should -Be 1 -Because 'exactly one fixture file throws at discovery time'
        $discoveryRecords[0].file | Should -Match 'throwing\.Tests\.ps1'
        $discoveryRecords[0].status | Should -Be 'DiscoveryError'
        $discoveryRecords[0].reason | Should -Match 'deliberate discovery-time throw' -Because 'the record must carry the actual throw message, not collapse it silently'
        $script:CaptureResult2.Result.summary.discoveryErrors | Should -Be 1
    }
}
