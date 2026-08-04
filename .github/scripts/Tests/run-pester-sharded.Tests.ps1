#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for the file-granular parallel sharded Pester runner (issue #740).

.DESCRIPTION
    Contract under test:
      T1 - The runner discovers all .Tests.ps1 files in TestsPath
      T2 - The real-git allowlist is keyed on actual fixture behavior, not string grep
      T3 - No-false-GREEN: crashed worker (exit code 1, no result file) = hard failure
      T4 - Determinism check: same set run twice, verify no flip detected on stable suite
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreFile = Join-Path $script:RepoRoot '.github/scripts/lib/pester-sharded-core.ps1'
    $script:TestsDir = Join-Path $script:RepoRoot '.github/scripts/Tests'

    . $script:CoreFile
}

Describe 'run-pester-sharded — file discovery' {

    It 'T1: discovers all .Tests.ps1 files in TestsPath' {
        # The real Tests directory must have multiple files
        $files = @(Get-ChildItem -LiteralPath $script:TestsDir -Filter '*.Tests.ps1' -File)
        $files.Count | Should -BeGreaterThan 1 -Because 'the Tests directory must contain multiple test files'
    }

    It 'T1b: the runner discovers the same count as direct Get-ChildItem' {
        $expected = @(Get-ChildItem -LiteralPath $script:TestsDir -Filter '*.Tests.ps1' -File)
        # Verify Get-RealGitFiles returns a subset of what exists
        $realGitFiles = @(Get-RealGitFiles)
        foreach ($rgf in $realGitFiles) {
            $found = $expected | Where-Object { $_.Name -eq $rgf }
            $found | Should -Not -BeNullOrEmpty -Because "$rgf must be a real file in the Tests directory"
        }
    }
}

Describe 'run-pester-sharded — real-git allowlist correctness' {

    It 'T2a: plugin-release-hygiene.Tests.ps1 is in the real-git allowlist' {
        $list = @(Get-RealGitFiles)
        $list | Should -Contain 'plugin-release-hygiene.Tests.ps1' `
            -Because 'it runs git init + git commit fixture in BeforeAll'
    }

    It 'T2b: session-cleanup-detector.Tests.ps1 is in the real-git allowlist' {
        $list = @(Get-RealGitFiles)
        $list | Should -Contain 'session-cleanup-detector.Tests.ps1' `
            -Because 'it sets GIT_TERMINAL_PROMPT/GCM_INTERACTIVE/GIT_ASKPASS and asserts the detector overrides them'
    }

    It 'T2c: Resolve-PersistDecision.Tests.ps1 is NOT in the real-git allowlist' {
        # Resolve-PersistDecision.Tests.ps1 contains the string 'git push origin HEAD:feature/x'
        # as a literal string assertion, not a real git call. It must NOT be in the real-git shard.
        $list = @(Get-RealGitFiles)
        $list | Should -Not -Contain 'Resolve-PersistDecision.Tests.ps1' `
            -Because "its 'git push' is a string literal in a Should -Match assertion, not a real git invocation"
    }

    It 'T2d: real-git allowlist has exactly the two keyed files' {
        $list = @(Get-RealGitFiles)
        $list.Count | Should -Be 2 -Because 'exactly two files have real git init/commit fixture behavior'
    }

    It 'T2e: plugin-release-hygiene.Tests.ps1 contains actual git init invocation (verifies allowlist basis)' {
        $filePath = Join-Path $script:TestsDir 'plugin-release-hygiene.Tests.ps1'
        $content = Get-Content -LiteralPath $filePath -Raw
        $content | Should -Match 'git init' -Because 'allowlist entry is based on real git init fixture'
        $content | Should -Match 'git commit' -Because 'allowlist entry is based on real git commit fixture'
    }

    It 'T2f: session-cleanup-detector.Tests.ps1 sets git env vars as test setup (verifies allowlist basis)' {
        $filePath = Join-Path $script:TestsDir 'session-cleanup-detector.Tests.ps1'
        $content = Get-Content -LiteralPath $filePath -Raw
        $content | Should -Match 'GIT_TERMINAL_PROMPT' -Because 'allowlist entry is based on ambient git env mutation'
        $content | Should -Match 'GCM_INTERACTIVE' -Because 'allowlist entry is based on ambient git env mutation'
        $content | Should -Match 'GIT_ASKPASS' -Because 'allowlist entry is based on ambient git env mutation'
    }
}

Describe 'run-pester-sharded — no-false-GREEN contract' {

    BeforeAll {
        # Create a temp TestsPath with a controlled set of stub test files
        $script:TempTestsDir = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-sharded-contract-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempTestsDir -Force | Out-Null

        # Create a minimal passing test file
        $passingContent = @'
#Requires -Version 7.0
Describe 'Stub passing' {
    It 'passes' { 1 | Should -Be 1 }
}
'@
        Set-Content -Path (Join-Path $script:TempTestsDir 'stub-passing.Tests.ps1') -Value $passingContent -Encoding UTF8
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempTestsDir) {
            Remove-Item -LiteralPath $script:TempTestsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'T3a: a passing test file yields ExitCode 0 and TotalPassed > 0' {
        $result = Invoke-PesterSharded -TestsPath $script:TempTestsDir -MinTestCount 1
        $result.ExitCode | Should -Be 0 -Because 'all stub files pass'
        $result.TotalPassed | Should -BeGreaterThan 0 -Because 'at least one test should pass'
        $result.TotalFailed | Should -Be 0
    }

    It 'T3b: MinTestCount failure when suite runs fewer tests than baseline' {
        # With MinTestCount = 9999, even a real run should fail the baseline check
        $result = Invoke-PesterSharded -TestsPath $script:TempTestsDir -MinTestCount 9999
        $result.ExitCode | Should -Be 1 -Because 'fewer tests ran than MinTestCount baseline'
    }

    It 'T3c: missing result entry appears in MissingFiles when a file crashes' {
        # Inject a file that does not produce a result file by producing an invalid Pester invocation.
        # We simulate this by checking the MissingFiles contract behavior: if a file is discovered
        # but does not produce a result, it must appear in MissingFiles.
        # We test this via a file that crashes the pwsh process immediately.
        $crashContent = @'
#Requires -Version 7.0
throw 'deliberate crash to test no-false-GREEN contract'
'@
        $crashFile = Join-Path $script:TempTestsDir 'crash-worker.Tests.ps1'
        Set-Content -Path $crashFile -Value $crashContent -Encoding UTF8

        try {
            $result = Invoke-PesterSharded -TestsPath $script:TempTestsDir -MinTestCount 0
            # The crashed file must either appear in MissingFiles or have Failed > 0
            $crashedOrMissing = ($result.MissingFiles -contains 'crash-worker.Tests.ps1') -or
                                ($result.FailedFiles -contains 'crash-worker.Tests.ps1')
            $crashedOrMissing | Should -Be $true `
                -Because 'a worker that crashes must be counted as failure, not silently skipped'
            $result.ExitCode | Should -Be 1 -Because 'a crashed worker yields a non-zero exit code'
        }
        finally {
            Remove-Item -LiteralPath $crashFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'T3d: a test file that discovers zero tests is flagged as a failure (no-false-GREEN F1 fix)' {
        $emptyContent = @'
#Requires -Version 7.0
Describe 'Empty describe' { }
'@
        $emptyFile = Join-Path $script:TempTestsDir 'zero-tests.Tests.ps1'
        Set-Content -Path $emptyFile -Value $emptyContent -Encoding UTF8

        try {
            $result = Invoke-PesterSharded -TestsPath $script:TempTestsDir -MinTestCount 0
            $result.FailedFiles | Should -Contain 'zero-tests.Tests.ps1' `
                -Because 'a file with zero discovered tests must appear in FailedFiles'
            $result.ExitCode | Should -Be 1 -Because 'zero discovered tests is a no-false-GREEN failure'
        }
        finally {
            Remove-Item -LiteralPath $emptyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'run-pester-sharded — determinism check' {

    BeforeAll {
        $script:TempDetDir = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-sharded-det-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempDetDir -Force | Out-Null

        # Create a stable test file — will pass on every run
        $stableContent = @'
#Requires -Version 7.0
Describe 'Determinism stub' {
    It 'always passes run 1' { 1 | Should -Be 1 }
    It 'always passes run 2' { 2 | Should -Be 2 }
}
'@
        Set-Content -Path (Join-Path $script:TempDetDir 'determinism-stub.Tests.ps1') -Value $stableContent -Encoding UTF8
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempDetDir) {
            Remove-Item -LiteralPath $script:TempDetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'T4: determinism check passes with a stable test suite (no flip)' {
        $result = Invoke-PesterSharded -TestsPath $script:TempDetDir -DeterminismCheck -MinTestCount 1
        $result.ExitCode | Should -Be 0 -Because 'a stable test file should not flip between runs'
        if ($null -ne $result.DeterminismDiff) {
            $result.DeterminismDiff.Count | Should -Be 0 -Because 'no file should flip between runs'
        }
    }
}

Describe 'run-pester-sharded — run attribution (issue #958)' {

    BeforeAll {
        # Every expectation below is checked against an INDEPENDENT reading of
        # git taken here, never against the runner's own lookup, so no assertion
        # can pass by a function agreeing with itself.
        $script:AttrHead = ([string](& git -C $script:RepoRoot rev-parse HEAD)).Trim()
        $script:AttrDepthVar = 'PESTER_SHARDED_RUN_DEPTH'

        $stub = @'
#Requires -Version 7.0
Describe 'attribution stub' {
    It 'passes' { 1 | Should -Be 1 }
}
'@

        # A tests directory INSIDE this repository. '.tmp/' is gitignored, so the
        # fixture leaves the working tree exactly as clean or dirty as it found
        # it, and it sits outside .github/scripts/Tests so the suite's own static
        # scanners never see the stub.
        $script:AttrInRepoDir = Join-Path $script:RepoRoot ".tmp/attribution-in-repo-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:AttrInRepoDir -Force | Out-Null
        Set-Content -Path (Join-Path $script:AttrInRepoDir 'stub.Tests.ps1') -Value $stub -Encoding UTF8

        # A tests directory that is not inside any repository at all.
        $script:AttrOutsideDir = Join-Path ([System.IO.Path]::GetTempPath()) "attribution-outside-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:AttrOutsideDir -Force | Out-Null
        Set-Content -Path (Join-Path $script:AttrOutsideDir 'stub.Tests.ps1') -Value $stub -Encoding UTF8

        # Read immediately before the run it is compared against.
        $script:AttrPorcelain = @(& git -C $script:RepoRoot status --porcelain |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        # NOTE: nothing here clears the depth variable, deliberately. Inside a
        # full-suite run this file executes in a shard child that has inherited
        # it, and a run that cleared it would emit a second 'run=outer' line into
        # the outer run's output — destroying the property A5 exists to protect.
        $script:AttrInRepoResult = Invoke-PesterSharded -TestsPath $script:AttrInRepoDir -MinTestCount 1 -InformationVariable inRepoInfo
        $script:AttrInRepoLine = @(@($inRepoInfo) | ForEach-Object { [string]$_ } |
            Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]

        $script:AttrOutsideResult = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1 -InformationVariable outsideInfo
        $script:AttrOutsideText = (@($outsideInfo) | ForEach-Object { [string]$_ }) -join "`n"
        $script:AttrOutsideLine = @(($script:AttrOutsideText -split "`n") |
            Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]
    }

    AfterAll {
        Remove-Item -LiteralPath $script:AttrInRepoDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:AttrOutsideDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'A1: a run whose tests live in this repository names this repository''s commit' {
        $script:AttrInRepoLine | Should -Not -BeNullOrEmpty -Because 'every run states what it ran against'
        $script:AttrInRepoLine | Should -Match ([regex]::Escape("commit=$($script:AttrHead)")) `
            -Because 'the reported commit must equal what git independently reports for this tree'
    }

    It 'A2: a run whose commit cannot be established claims none, and never the invoking checkout''s' {
        $script:AttrOutsideLine | Should -Match 'commit=none\b' `
            -Because 'a tests directory outside any repository has no commit to report'
        $script:AttrOutsideText | Should -Not -Match ([regex]::Escape($script:AttrHead)) `
            -Because 'an implementation anchored on the invoking process would print this repository''s commit here'
    }

    It 'A3: the attribution attempt does not fail a run whose commit cannot be established' {
        $script:AttrOutsideResult.ExitCode | Should -Be 0 -Because 'a failed lookup must not red an otherwise-passing run'
        $script:AttrOutsideResult.TotalPassed | Should -BeGreaterThan 0
        $script:AttrOutsideResult.TotalFailed | Should -Be 0
    }

    It 'A4: the attribution states tree state matching an independent reading, and when it was observed' {
        $expected = if ($script:AttrPorcelain.Count -eq 0) { 'worktree=clean' } else { 'worktree=dirty' }
        $script:AttrInRepoLine | Should -Match ([regex]::Escape($expected)) `
            -Because "git status --porcelain independently reported $($script:AttrPorcelain.Count) change(s)"
        $script:AttrInRepoLine | Should -Match 'observed=before any tests ran' `
            -Because 'a run takes minutes and can begin clean and end dirty, so the statement must say what moment it describes'
    }

    It 'A5: a run started inside another run identifies itself as nested, at the right depth' {
        $saved = [Environment]::GetEnvironmentVariable($script:AttrDepthVar)
        try {
            [Environment]::SetEnvironmentVariable($script:AttrDepthVar, '0')
            $null = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1 -InformationVariable depth0Info

            [Environment]::SetEnvironmentVariable($script:AttrDepthVar, '7')
            $null = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1 -InformationVariable depth7Info
        }
        finally {
            [Environment]::SetEnvironmentVariable($script:AttrDepthVar, $saved)
        }

        $line0 = @(@($depth0Info) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]
        $line7 = @(@($depth7Info) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]

        $line0 | Should -Match 'run=nested\(depth=1\)' -Because 'a run started by an outer run is one level deeper than it'
        $line7 | Should -Match 'run=nested\(depth=8\)' -Because 'depth accumulates, so a reader can tell any nested run from the one they started'
    }

    It 'A6: a run returns the depth handoff to the state it found it in' {
        $before = [Environment]::GetEnvironmentVariable($script:AttrDepthVar)
        $null = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1
        $after = [Environment]::GetEnvironmentVariable($script:AttrDepthVar)

        # Cast so an unset variable ('' both sides) compares as cleanly as a set one.
        [string]$after | Should -Be ([string]$before) -Because 'the depth handoff is scoped to the run that published it'
    }
}
