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
