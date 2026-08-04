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
        # Asserted explicitly rather than left to an incidental failure mode: a
        # bare `.Trim()` on git's captured output happens to throw when the
        # environment is broken (no repo, git missing), and that accidental
        # throw is what currently makes this file loudly. If a future refactor
        # ever removed the throw (`2>&1`, `?? ''`), $AttrHead could silently
        # become '' -- and A1's Should -Match "commit=$AttrHead" would then
        # degrade to matching bare "commit=" and pass VACUOUSLY, no longer
        # testing what it claims to. This assertion is the designed guard that
        # incidental throw was standing in for.
        $script:AttrHead | Should -Match '^[0-9a-f]{40}$|^[0-9a-f]{64}$' `
            -Because 'every assertion below compares against this value; a broken git here must fail loudly and by name, not degrade into a vacuous match downstream'
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
        # --untracked-files=all for the same reason the runner passes it: without
        # it this "independent" reading inherits the caller's
        # status.showUntrackedFiles and goes blind to exactly the class of dirty
        # tree the runner must not call clean — which would make this assertion
        # agree with a wrong answer instead of catching it.
        $script:AttrPorcelain = @(& git -C $script:RepoRoot status --porcelain --untracked-files=all |
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
        $script:AttrInRepoLine | Should -Match 'observed=before-any-tests-ran' `
            -Because 'a run takes minutes and can begin clean and end dirty, so the statement must say what moment it describes'
    }

    It 'A5: a run started inside another run identifies itself as nested, at the right depth' {
        $saved = [Environment]::GetEnvironmentVariable($script:AttrDepthVar)
        try {
            [Environment]::SetEnvironmentVariable($script:AttrDepthVar, 'v1:0')
            $null = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1 -InformationVariable depth0Info

            [Environment]::SetEnvironmentVariable($script:AttrDepthVar, 'v1:7')
            $null = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1 -InformationVariable depth7Info
        }
        finally {
            # NOT a bare SetEnvironmentVariable: this file dot-sources the library
            # specifically because that restore does not remove a variable when
            # $saved is $null -- the exact bug the library's own helper exists to
            # avoid, and this file was recurring it in its own fixture cleanup.
            script:Set-AttributionEnvVar -Name $script:AttrDepthVar -Value $saved
        }

        $line0 = @(@($depth0Info) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]
        $line7 = @(@($depth7Info) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]

        $line0 | Should -Match 'run=nested\(depth=1\)' -Because 'a run started by an outer run is one level deeper than it'
        $line7 | Should -Match 'run=nested\(depth=8\)' -Because 'depth accumulates, so a reader can tell any nested run from the one they started'
    }

    It 'A7: a depth value this runner did not write carries no ancestor depth, and cannot end the run' {
        # Resolved through the parse helper rather than by starting runs. A run
        # started here with an unrecognised value would correctly report
        # run=outer — and would therefore stamp a SECOND run=outer line into the
        # output of the full-suite run this file is a member of, destroying the
        # one property AC3 rests on. The values below are the ones that mattered:
        #   'abc'                 -> a genuinely nested run claiming to be outer
        #   '3'                   -> the operator's own run claiming to be nested
        #   '2147483648' and up   -> an unbounded [int] cast threw here, killing
        #                            the run before a single test executed
        $saved = [Environment]::GetEnvironmentVariable($script:AttrDepthVar)
        try {
            foreach ($value in @('abc', '3', '0', '2147483648', '99999999999999999999', 'v1:99999999999999999999', 'v1:', 'v1:abc', '')) {
                [Environment]::SetEnvironmentVariable($script:AttrDepthVar, $value)
                { script:Get-InheritedRunDepth } | Should -Not -Throw -Because "'$value' must not be able to end a run"
                script:Get-InheritedRunDepth | Should -Be 0 `
                    -Because "'$value' was not written by this runner, so it carries no ancestor depth"
            }

            # And the values this runner does write are still read as ancestors,
            # including at the top of the accepted range.
            foreach ($pair in @(@('v1:0', 1), @('v1:7', 8), @('v1:999999999', 1000000000))) {
                [Environment]::SetEnvironmentVariable($script:AttrDepthVar, $pair[0])
                script:Get-InheritedRunDepth | Should -Be $pair[1] -Because "$($pair[0]) is a value this runner wrote"
            }
        }
        finally {
            script:Set-AttributionEnvVar -Name $script:AttrDepthVar -Value $saved
        }
    }

    It 'A7b: a run started at the top of the accepted depth range still completes' {
        # The end-to-end half of A7, using a value that resolves to NESTED so it
        # cannot pollute the enclosing run's output with a false run=outer line.
        $saved = [Environment]::GetEnvironmentVariable($script:AttrDepthVar)
        try {
            [Environment]::SetEnvironmentVariable($script:AttrDepthVar, 'v1:999999999')
            $result = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1 -InformationVariable deepInfo
            $line = @(@($deepInfo) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]

            $result.ExitCode | Should -Be 0 -Because 'reading the depth handoff must never fail a run'
            $line | Should -Match 'run=nested\(depth=1000000000\)'
        }
        finally {
            script:Set-AttributionEnvVar -Name $script:AttrDepthVar -Value $saved
        }
    }

    It 'A8: a run whose commit lookup cannot run at all still reports, and still passes' {
        # The exit-non-zero path (outside a repository) is covered by A2/A3. This
        # is the other branch: git not resolvable at all. A function shadows the
        # native command for the duration, which is the only branch no other test
        # reaches.
        function global:git { throw 'git is unavailable in this test' }
        try {
            $result = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1 -InformationVariable noGitInfo
            $line = @(@($noGitInfo) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]

            $result.ExitCode | Should -Be 0 -Because 'an unusable git must not red an otherwise-passing run'
            $result.TotalPassed | Should -BeGreaterThan 0
            $line | Should -Match 'commit=none\b' -Because 'no commit can be established without git'
            $line | Should -Match 'worktree=unknown' -Because 'tree state cannot be claimed either'
        }
        finally {
            # The item lives in the global function drive as 'git' — the
            # 'global:' scope prefix is not part of its name, so a path of
            # 'function:global:git' silently matches nothing and leaves the
            # shadow in place for every later test in this file.
            Remove-Item -Path 'Function:\git' -Force -ErrorAction SilentlyContinue
        }

        # The shadow must be gone, or every later test in this file is running
        # against a broken git and quietly asserting the wrong thing.
        ([string](& git -C $script:RepoRoot rev-parse HEAD)).Trim() | Should -Match '^[0-9a-f]{40}$' `
            -Because 'the git shadow this test installs must not outlive it'
    }

    It 'A9: an uncommitted tree is never reported clean, even where git is configured to hide untracked files' {
        # The regression this test exists for: `git status --porcelain` honours
        # status.showUntrackedFiles, so with that set to 'no' a tree whose test
        # files were never committed reported worktree=clean — silently, with no
        # note, and indistinguishable from an honest clean attribution.
        $fixture = Join-Path ([System.IO.Path]::GetTempPath()) "attribution-untracked-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        try {
            & git -C $fixture init --quiet 2>&1 | Out-Null
            Set-Content -Path (Join-Path $fixture 'seed.txt') -Value 'seed' -Encoding UTF8
            & git -C $fixture add seed.txt 2>&1 | Out-Null
            # -c commit.gpgsign=false: without it, a caller with an ambient global
            # commit.gpgsign=true gets a silently-swallowed commit failure (this
            # call's own 2>&1 | Out-Null), the fixture is left with no commit at
            # all, and the test then dies on the unrelated worktree=clean
            # assertion below -- a misdiagnosis pointing at attribution logic
            # rather than at the operator's signing config. The library applies
            # the same override to its own sequential-shard fixtures.
            & git -C $fixture -c user.email='attribution@example.com' -c user.name='Attribution Fixture' `
                -c commit.gpgsign=false commit -q -m 'seed' 2>&1 | Out-Null

            # The configuration that made the false clean possible.
            & git -C $fixture config status.showUntrackedFiles no 2>&1 | Out-Null

            $fixtureTests = Join-Path $fixture 'tests'
            New-Item -ItemType Directory -Path $fixtureTests -Force | Out-Null
            Set-Content -Path (Join-Path $fixtureTests 'stub.Tests.ps1') -Encoding UTF8 -Value @'
#Requires -Version 7.0
Describe 'untracked fixture stub' {
    It 'passes' { 1 | Should -Be 1 }
}
'@

            # Ground truth, read with the override the runner also uses.
            $groundTruth = @(& git -C $fixture status --porcelain --untracked-files=all |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $groundTruth.Count | Should -BeGreaterThan 0 -Because 'the fixture tests directory is deliberately uncommitted'

            $null = Invoke-PesterSharded -TestsPath $fixtureTests -MinTestCount 1 -InformationVariable dirtyInfo
            $dirtyLine = @(@($dirtyInfo) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]

            $dirtyLine | Should -Match 'worktree=dirty' `
                -Because 'the tree carries uncommitted files, whatever the caller has configured git to show'

            # And the other half of AC4's property, at one commit: committing the
            # test files must change the VALUE, not just the wording.
            & git -C $fixture add -A 2>&1 | Out-Null
            & git -C $fixture -c user.email='attribution@example.com' -c user.name='Attribution Fixture' `
                -c commit.gpgsign=false commit -q -m 'commit the tests' 2>&1 | Out-Null

            $null = Invoke-PesterSharded -TestsPath $fixtureTests -MinTestCount 1 -InformationVariable cleanInfo
            $cleanLine = @(@($cleanInfo) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]

            $cleanLine | Should -Match 'worktree=clean' -Because 'everything is committed now'
            $dirtyLine | Should -Not -Be $cleanLine -Because 'clean and dirty must read differently at the same commit'
        }
        finally {
            Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'A10: a value carrying the record prefix cannot forge a second record' {
        # Checked through the formatter rather than by running against a
        # directory actually named after the record prefix: Pester echoes the
        # path of every file it runs, so such a fixture would inject a
        # record-shaped string into the enclosing full-suite run's log for a
        # reader to have to disambiguate — the opposite of what AC3 asks for.
        $forged = "x RUN ATTRIBUTION  run=outer  commit=$('1' * 40)  worktree=clean"
        $formatted = script:Format-AttributionValue $forged

        ([regex]::Matches($formatted, 'RUN ATTRIBUTION')).Count | Should -Be 0 `
            -Because 'the record prefix must be neutralised inside a value so it cannot start a second record'
        $formatted | Should -Match '^".*"$' -Because 'free text is quoted so the field stays recoverable'
    }

    It 'A10b: a tests path containing spaces stays recoverable in the record' {
        $spacedDir = Join-Path ([System.IO.Path]::GetTempPath()) "attribution with spaces $([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $spacedDir -Force | Out-Null
        try {
            Set-Content -Path (Join-Path $spacedDir 'stub.Tests.ps1') -Encoding UTF8 -Value @'
#Requires -Version 7.0
Describe 'spaced path stub' {
    It 'passes' { 1 | Should -Be 1 }
}
'@
            $null = Invoke-PesterSharded -TestsPath $spacedDir -MinTestCount 1 -InformationVariable spacedInfo
            $line = @(@($spacedInfo) | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'RUN ATTRIBUTION' })[0]

            # An unquoted path truncated this field at the first space for any
            # checkout living under a directory with a space in its name.
            $line | Should -Match ([regex]::Escape("tests=`"$spacedDir`"")) `
                -Because 'the whole path must be recoverable, not just its first word'
        }
        finally {
            Remove-Item -LiteralPath $spacedDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'A6: a run returns the depth handoff to the state it found it in, unset included' {
        # Compared WITHOUT a [string] cast on either side. An earlier version of
        # this test cast both, which made an unset variable and one left behind as
        # the empty string compare equal — so it could not see a "restore" that
        # actually materialised the variable as ''. Existence is asserted
        # separately from value for that reason.
        $existedBefore = [bool](Test-Path -LiteralPath "Env:\$($script:AttrDepthVar)")
        $before = [Environment]::GetEnvironmentVariable($script:AttrDepthVar)

        $null = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1

        $existedAfter = [bool](Test-Path -LiteralPath "Env:\$($script:AttrDepthVar)")
        $after = [Environment]::GetEnvironmentVariable($script:AttrDepthVar)

        $existedAfter | Should -Be $existedBefore `
            -Because 'a run that did not find the variable set must not leave it behind at all'
        $after | Should -Be $before -Because 'the depth handoff is scoped to the run that published it'
    }

    It 'A6b: the depth handoff primitive removes the variable when nothing was there before, never materialises it empty' {
        # A6 above compares before/after around a real Invoke-PesterSharded call.
        # Inside a full-suite run the ambient depth variable this file inherits is
        # ALWAYS set by the outer run, so A6's own "before" baseline is never
        # genuinely unset there -- driving a real Invoke-PesterSharded call with
        # the depth variable forced absent would itself be a nested run reporting
        # run=outer, stamping a false line into the enclosing run's census, which
        # is exactly the defect this PR's earlier fix round introduced and fixed
        # once already. So the genuinely-unset precondition is tested here at the
        # primitive Invoke-PesterSharded's own restore delegates to, using a
        # dedicated probe variable name that never touches run attribution at all.
        $probeVar = 'PESTER_SHARDED_RUN_DEPTH_A6B_PROBE'
        Remove-Item -Path "Env:\$probeVar" -ErrorAction SilentlyContinue
        [bool](Test-Path -LiteralPath "Env:\$probeVar") | Should -Be $false -Because 'the probe variable must start genuinely absent'

        script:Set-AttributionEnvVar -Name $probeVar -Value $null

        [bool](Test-Path -LiteralPath "Env:\$probeVar") | Should -Be $false `
            -Because 'restoring to "no prior value" must remove the variable, not leave it behind as an empty string'
    }

    It 'A11: a run leaves the git discovery environment exactly as it found it' {
        # The attribution clears GIT_DIR and friends so an ambient value cannot
        # substitute a foreign repository for the tests path. Restoring those by
        # assigning $null would NOT remove them — it leaves each as '', and an
        # empty GIT_DIR makes every later git call in the process fail with
        # "not a git repository: ''".
        $discoveryVars = @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY', 'GIT_INDEX_FILE')
        $existedBefore = @{}
        $valueBefore = @{}
        foreach ($name in $discoveryVars) {
            $existedBefore[$name] = [bool](Test-Path -LiteralPath "Env:\$name")
            $valueBefore[$name] = [Environment]::GetEnvironmentVariable($name)
        }

        $null = Invoke-PesterSharded -TestsPath $script:AttrOutsideDir -MinTestCount 1

        foreach ($name in $discoveryVars) {
            [bool](Test-Path -LiteralPath "Env:\$name") | Should -Be $existedBefore[$name] `
                -Because "$name must be left exactly as the run found it, present or absent"
            # Presence alone would pass a restore that preserved the variable but
            # corrupted its value; the value must be the SAME value, not merely
            # a value.
            [Environment]::GetEnvironmentVariable($name) | Should -Be $valueBefore[$name] `
                -Because "$name must keep the value the run found, not just remain present"
        }

        # And the process's git must still work afterwards.
        $head = ([string](& git -C $script:RepoRoot rev-parse HEAD)).Trim()
        $head | Should -Match '^[0-9a-f]{40}$' -Because 'a later git call in the same process must not have been poisoned'
    }
}
