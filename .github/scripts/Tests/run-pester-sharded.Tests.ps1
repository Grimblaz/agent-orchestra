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
      A  - Run attribution (issue #958)
      S  - Selection-driven execution, honest counting, and the gate's own
           configuration (issue #1037)

    WHY THIS SUITE RUNS IN CI. It was quarantined `unclassified` until issue
    #1037, which is the chunk that extends the runner it guards. Assertions
    protecting that work would have sat in a file the per-PR gate never
    selected — a guard that does not run. It is the one quarantine entry #1037
    promotes, and it pays for itself twice: it invokes the sharded runner at
    many sites (count them rather than trusting a figure written down here —
    the last one this docstring carried was stale by roughly a factor of two
    within the same commit that added it), which makes it the recursion control
    the parent's AC4 asks for.
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
        $list.Count | Should -Be 2 -Because 'exactly two files have real git init/commit fixture behavior; suites that need the sequential shard for ISOLATION are on Get-IsolationRequiredFiles, a separate list with a separate criterion'
    }

    It 'T2g: the sequential shard is the union of the two lists, and each entry is on the one that names its reason' {
        # Issue #1037 split this. The sequential shard buys two different
        # things — an isolated git environment, and a machine with nothing else
        # of ours on it — and merging the reasons into one list means a suite
        # added for the wrong one can never be removed for the right one.
        $realGit = @(Get-RealGitFiles)
        $isolation = @(Get-IsolationRequiredFiles)
        $shard = @(Get-SequentialShardFiles)

        $shard | Should -Be (@($realGit + $isolation | Sort-Object -Unique)) `
            -Because 'the runner partitions on the union; a name on both lists is one shard member, not two'

        # This suite is on the ISOLATION list: its attribution test snapshots
        # `git status` and then asserts the runner reports the same cleanliness,
        # which ONE concurrent suite writing a non-gitignored path into the
        # checkout would flip.
        $isolation | Should -Contain 'run-pester-sharded.Tests.ps1'
        # And the audit core suite, whose 6-second bound was calibrated at
        # ~1.07s on an idle machine and which ten concurrent workers starved
        # past it on the gate's own first run.
        $isolation | Should -Contain 'ci-glob-audit-core.Tests.ps1'
        # And the spine command suite, added by #1036 with the promotion that
        # first exposed it to the fan-out: a 50-millisecond bound, which is the
        # tightest in the corpus. Measured 15/15 alone and 13/15 with the box
        # saturated, so this placement rests on an observation rather than on
        # the shape of the assertion.
        $isolation | Should -Contain 'orchestra-spine-command.Tests.ps1'
    }

    It 'T2h: each sequential-shard entry''s stated basis is present in the file it names' {
        # DISCRIMINATING PINS. An earlier revision matched patterns that appear
        # verbatim in its own assertion lines, so deleting the fixture code they
        # pinned left them green — the self-match hazard, inside the guard for
        # the one entry this chunk promotes. Every pattern below is ASSEMBLED
        # from pieces (or is a regex with a metacharacter), so the string being
        # searched for never appears literally in this file. That is what makes
        # each pin discriminating; it is asserted rather than assumed by the
        # self-match check immediately after the loop.
        $checks = @(
            @{ File = 'run-pester-sharded.Tests.ps1'; Pattern = 'git' + ' -C \$fixture init'; Why = 'real git init fixture' }
            @{ File = 'run-pester-sharded.Tests.ps1'; Pattern = 'status --porcelain --untracked' + '-files=all'; Why = 'tree-state snapshot compared against the runner' }
            @{ File = 'ci-glob-audit-core.Tests.ps1'; Pattern = '\$bound = \d+'; Why = 'a wall-clock bound a neighbour can starve' }
            @{ File = 'orchestra-spine-command.Tests.ps1'; Pattern = 'Elapsed\.TotalMilliseconds \| Should -BeLessThan \d+'; Why = 'a sub-second wall-clock bound a neighbour can starve' }
        )

        $selfSource = Get-Content -LiteralPath (Join-Path $script:TestsDir 'run-pester-sharded.Tests.ps1') -Raw

        foreach ($check in $checks) {
            $path = Join-Path $script:TestsDir $check.File
            $path | Should -Exist
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match $check.Pattern -Because "$($check.File) is on the sequential shard for its $($check.Why)"
        }

        # The two pins that look at THIS file discriminate only while the string
        # they search for lives in FIXTURE code and never inside an assertion.
        # Written out inside a `Should -Match` it would match itself, and
        # deleting the fixture would leave the pin green — the self-match
        # hazard. That is why the patterns above are assembled from pieces; this
        # asserts the property rather than trusting it. Legitimate duplication
        # in fixture code is fine and is not what this counts.
        $assertionLines = @($selfSource -split "`r?`n" | Where-Object { $_ -match 'Should\s+-(Match|BeLike)' })
        foreach ($literal in @(('git' + ' -C $fixture init'), ('status --porcelain --untracked' + '-files=all'))) {
            $inAssertion = @($assertionLines | Where-Object { $_.Contains($literal) })
            $inAssertion.Count | Should -Be 0 `
                -Because "'$literal' must not appear inside an assertion in this file; written out there, the pin matches itself and survives the deletion of the fixture it exists to pin"
        }
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

Describe 'run-pester-sharded — selection-driven execution and honest counting (issue #1037)' {

    BeforeAll {
        # One fixture directory holding every state the gate must react to. The
        # directory deliberately contains suites that most tests below do NOT
        # select: that is what makes "the selection drove the run" checkable
        # rather than asserted — a runner that globbed would pick them up.
        $script:SelDir = Join-Path ([System.IO.Path]::GetTempPath()) `
            "pester-sharded-selection-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:SelDir -Force | Out-Null

        $script:Fixture = @{}
        function script:New-SelFixture {
            param([string]$Name, [string]$Body)
            $path = Join-Path $script:SelDir $Name
            Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
            $script:Fixture[$Name] = $path
        }

        script:New-SelFixture 'sel-pass-a.Tests.ps1' @'
#Requires -Version 7.0
Describe 'pass a' {
    It 'one' { 1 | Should -Be 1 }
    It 'two' { 2 | Should -Be 2 }
}
'@
        script:New-SelFixture 'sel-pass-b.Tests.ps1' @'
#Requires -Version 7.0
Describe 'pass b' {
    It 'one' { 1 | Should -Be 1 }
}
'@
        # State 1: a suite with failing tests.
        script:New-SelFixture 'sel-fail.Tests.ps1' @'
#Requires -Version 7.0
Describe 'fail' {
    It 'fails' { 1 | Should -Be 2 }
    It 'passes' { 1 | Should -Be 1 }
}
'@
        # State 2: a worker that produces no usable result at all. It exits the
        # process during discovery, so the launcher never reaches the line that
        # writes the result file. A `throw` would NOT do this — Pester catches
        # it and still writes a result, which is S2c's case, not this one.
        script:New-SelFixture 'sel-crash.Tests.ps1' @'
#Requires -Version 7.0
[Environment]::Exit(7)
'@
        # State 3a: discovered nothing.
        script:New-SelFixture 'sel-zero.Tests.ps1' @'
#Requires -Version 7.0
Describe 'discovers nothing' { }
'@
        # State 3b: discovered tests and executed none of them. This limb read
        # PASS before #1037: the per-file total included Skipped, so the
        # zero-test detection never fired on it.
        script:New-SelFixture 'sel-allskip.Tests.ps1' @'
#Requires -Version 7.0
Describe 'all skipped' {
    It 'skipped one' -Skip { 1 | Should -Be 1 }
    It 'skipped two' -Skip { 1 | Should -Be 1 }
}
'@

        $script:CleanSelection = @($script:Fixture['sel-pass-a.Tests.ps1'], $script:Fixture['sel-pass-b.Tests.ps1'])

        # The mixed run every counting assertion below reads. Run once: it is
        # the single observation in which each red state is present, so the
        # totals it reports are the ones that had to be honest.
        $script:MixedResult = Invoke-PesterSharded -MinTestCount 0 -FanOutWidth 3 -Output 'None' -SuitePath @(
            $script:Fixture['sel-pass-a.Tests.ps1']
            $script:Fixture['sel-pass-b.Tests.ps1']
            $script:Fixture['sel-fail.Tests.ps1']
            $script:Fixture['sel-crash.Tests.ps1']
            $script:Fixture['sel-zero.Tests.ps1']
            $script:Fixture['sel-allskip.Tests.ps1']
        )

        function script:Get-SelOutcome {
            param([object]$Result, [string]$File)
            return @($Result.SuiteOutcomes | Where-Object { $_.File -eq $File })[0]
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:SelDir) {
            Remove-Item -LiteralPath $script:SelDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'S1: the caller''s selection drives the run, not a directory glob' {

        It 'S1a: runs exactly the suites handed to it, and none of the others sharing their directory' {
            $result = Invoke-PesterSharded -SuitePath $script:CleanSelection -MinTestCount 0 -Output 'None'

            # Derived from what actually produced a result row, not restated
            # from the list handed in.
            $executed = @($result.Results | ForEach-Object { $_.File } | Sort-Object)
            $executed | Should -Be @('sel-pass-a.Tests.ps1', 'sel-pass-b.Tests.ps1')

            # The negative arm, and it is the TREE that controls it: other
            # *.Tests.ps1 files sit in that same directory and were excluded by
            # the selection alone, with no edit to the runner between the two
            # observations.
            @(Get-ChildItem -LiteralPath $script:SelDir -Filter '*.Tests.ps1' -File).Count |
                Should -BeGreaterThan $executed.Count -Because 'the directory holds suites the selection left out; a runner that globbed would have run them'
            $executed | Should -Not -Contain 'sel-fail.Tests.ps1'
            $executed | Should -Not -Contain 'sel-crash.Tests.ps1'

            # And the complement still ran: a negative arm in which nothing ran
            # would satisfy "that suite did not run" and prove nothing.
            $result.ExitCode | Should -Be 0
            $result.TotalPassed | Should -Be 3
        }

        It 'S1b: more than one suite is in flight at once, evidenced by OVERLAP rather than by wall clock' {
            # The observable is whether two suites' execution windows INTERSECT.
            # An earlier revision compared total wall clock at width 1 against
            # width 3, which is a machine-speed-dependent assertion on a suite
            # that now runs in the per-PR gate — the review's own falsifier F8
            # names a nondeterministic red on unrelated pull requests as the
            # most expensive kind. Overlap discriminates just as sharply and
            # cannot be starved into a false red: a serial runner produces
            # strictly disjoint windows no matter how slow the machine is.
            $overlapDir = Join-Path $script:SelDir 'overlap'
            New-Item -ItemType Directory -Path $overlapDir -Force | Out-Null
            try {
                # Each suite stamps UTC ticks on entry and on exit. Under a
                # serial runner every window is disjoint; under fan-out at
                # least two must intersect.
                $sleepers = foreach ($i in 1..3) {
                    $path = Join-Path $overlapDir "ov-$i.Tests.ps1"
                    $stamp = Join-Path $overlapDir "ov-$i.window.txt"
                    Set-Content -LiteralPath $path -Encoding UTF8 -Value @"
#Requires -Version 7.0
Describe 'overlap probe $i' {
    It 'records its own execution window' {
        `$start = [DateTime]::UtcNow.Ticks
        Start-Sleep -Seconds 2
        `$end = [DateTime]::UtcNow.Ticks
        Set-Content -LiteralPath '$stamp' -Value "`$start,`$end" -Encoding UTF8
        1 | Should -Be 1
    }
}
"@
                    $path
                }

                $result = Invoke-PesterSharded -SuitePath @($sleepers) -MinTestCount 0 -FanOutWidth 3 -Output 'None'
                $result.ExitCode | Should -Be 0

                $windows = @(Get-ChildItem -LiteralPath $overlapDir -Filter '*.window.txt' | ForEach-Object {
                        $parts = (Get-Content -LiteralPath $_.FullName -Raw).Trim() -split ','
                        [pscustomobject]@{ Start = [long]$parts[0]; End = [long]$parts[1] }
                    })
                $windows.Count | Should -Be 3 -Because 'every probe must have recorded a window, or the evidence below is over a smaller set than it claims'

                $overlaps = 0
                for ($a = 0; $a -lt $windows.Count; $a++) {
                    for ($b = $a + 1; $b -lt $windows.Count; $b++) {
                        if ($windows[$a].Start -lt $windows[$b].End -and $windows[$b].Start -lt $windows[$a].End) { $overlaps++ }
                    }
                }
                $overlaps | Should -BeGreaterThan 0 `
                    -Because 'at least two suites must have been executing at the same instant; a serial runner produces strictly disjoint windows however slow the machine is'

                # The negative arm, so the instrument is shown to discriminate:
                # the same three suites at width 1 must produce NO overlap.
                Get-ChildItem -LiteralPath $overlapDir -Filter '*.window.txt' | Remove-Item -Force
                $serial = Invoke-PesterSharded -SuitePath @($sleepers) -MinTestCount 0 -FanOutWidth 1 -Output 'None'
                $serial.ExitCode | Should -Be 0

                $serialWindows = @(Get-ChildItem -LiteralPath $overlapDir -Filter '*.window.txt' | ForEach-Object {
                        $parts = (Get-Content -LiteralPath $_.FullName -Raw).Trim() -split ','
                        [pscustomobject]@{ Start = [long]$parts[0]; End = [long]$parts[1] }
                    })
                $serialOverlaps = 0
                for ($a = 0; $a -lt $serialWindows.Count; $a++) {
                    for ($b = $a + 1; $b -lt $serialWindows.Count; $b++) {
                        if ($serialWindows[$a].Start -lt $serialWindows[$b].End -and $serialWindows[$b].Start -lt $serialWindows[$a].End) { $serialOverlaps++ }
                    }
                }
                $serialOverlaps | Should -Be 0 `
                    -Because 'width 1 is one process at a time, so this assertion could have come out positive and did not'
            }
            finally {
                Remove-Item -LiteralPath $overlapDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'S1c: an empty selection fails; it is never a run over nothing' {
            $result = Invoke-PesterSharded -SuitePath @() -MinTestCount 0 -ErrorAction SilentlyContinue
            $result.ExitCode | Should -Be 1 -Because 'the caller selected nothing, and reporting green for that is the false-GREEN shape this runner refuses'
        }

        It 'S1d: a selection naming a file that is not there fails rather than running the rest' {
            $result = Invoke-PesterSharded -MinTestCount 0 -ErrorAction SilentlyContinue -SuitePath @(
                $script:Fixture['sel-pass-a.Tests.ps1']
                (Join-Path $script:SelDir 'never-existed.Tests.ps1')
            )
            $result.ExitCode | Should -Be 1 -Because 'silently dropping a selected suite is the reconciliation failure this runner reports on'
        }
    }

    Context 'S2: the totals say which unit they count, and nothing in them is a failure signal in disguise' {

        It 'S2a: the reported test total is the honest test total, on a run containing a crashed and a zero-test suite' {
            # The discriminating exhibit, on the UNITS question specifically.
            # Exactly one test failed in this run. Under the previous mechanism
            # the reported failure total was that one test PLUS one per
            # zero-test file and one per crashed worker — file counts summed
            # into a test count.
            $script:MixedResult.TotalFailed | Should -Be 1 -Because 'one test failed; the other three red suites failed no tests at all'
            $script:MixedResult.TotalPassed | Should -Be 4 -Because 'two plus one from the passing suites, plus the one passing test in the failing suite'
            $script:MixedResult.TestsExecuted | Should -Be 5
            $script:MixedResult.TestsSkipped | Should -Be 2 -Because 'the all-skipped suite skipped two, and skipped tests are not executed tests'
        }

        It 'S2b: the crashed suite''s own row carries no invented count' {
            $row = @($script:MixedResult.Results | Where-Object { $_.File -eq 'sel-crash.Tests.ps1' })[0]
            $row | Should -Not -BeNullOrEmpty
            $row.HasResult | Should -BeFalse
            $row.Failed | Should -Be 0 -Because 'a fabricated Failed = 1 here is a lie about how many tests failed, told in order to carry a failure signal'
            $row.Passed | Should -Be 0
            $row.TotalCount | Should -Be 0
        }

        It 'S2c: a suite whose discovery threw is not credited with a discovered test' {
            # The per-file total used to be computed with the container failure
            # already folded into the failed count, inflating a discovery-throw
            # file from 0 to 1 — which then suppressed zero-test detection for
            # exactly the most-broken files.
            $throwDir = Join-Path $script:SelDir 'throwcase'
            New-Item -ItemType Directory -Path $throwDir -Force | Out-Null
            $throwFile = Join-Path $throwDir 'sel-throw.Tests.ps1'
            Set-Content -LiteralPath $throwFile -Encoding UTF8 -Value @'
#Requires -Version 7.0
throw 'deliberate discovery failure'
'@
            try {
                $result = Invoke-PesterSharded -SuitePath @($throwFile) -MinTestCount 0 -Output 'None'
                $row = @($result.Results)[0]
                $row.HasResult | Should -BeTrue -Because 'Pester catches a discovery throw and still writes a result'
                $row.ContainerFailures | Should -BeGreaterThan 0
                $row.TotalCount | Should -Be 0 -Because 'no test was discovered, so the discovered-test count is zero'
                $row.Failed | Should -Be 0 -Because 'a failed container is one file, not one test'
                (script:Get-SelOutcome -Result $result -File 'sel-throw.Tests.ps1').Outcome |
                    Should -Be 'no-tests' -Because 'the inflated total used to hide exactly this case'
                $result.ExitCode | Should -Be 1
            }
            finally {
                Remove-Item -LiteralPath $throwDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'S2d: the reported figures and the redness decision come from the same per-suite rows' {
            # Not "two numbers agree": the suite tally is recomputed from the
            # outcome rows and must equal what the run reported, and the exit
            # code must follow those same rows.
            $rows = @($script:MixedResult.SuiteOutcomes)
            $rows.Count | Should -Be 6
            @($rows | Where-Object { $_.Outcome -ne 'passed' }).Count | Should -Be $script:MixedResult.SuitesNotPassed
            $script:MixedResult.ExitCode | Should -Be 1
            $script:MixedResult.SuitesSelected | Should -Be 6
            $script:MixedResult.SuitesReported | Should -Be 6
            $script:MixedResult.Reconciliation.Ok | Should -BeTrue

            # And every row's outcome is what the one shared predicate says
            # about that row, so the printed table cannot drift from the verdict.
            foreach ($r in $script:MixedResult.Results) {
                $expected = (Resolve-PesterSuiteOutcome -Row $r).Outcome
                (script:Get-SelOutcome -Result $script:MixedResult -File $r.File).Outcome | Should -Be $expected
            }
        }
    }

    Context 'S3: each of the four states reddens the check on its own' {

        # Each induced separately, against a run whose only other member passes.
        # An exhibit shared between two states would discharge neither.
        It 'S3a: <Case> reddens the run, and is the only thing wrong with it' -ForEach @(
            @{ Case = 'failing tests'; File = 'sel-fail.Tests.ps1'; Outcome = 'failed-tests' }
            @{ Case = 'no usable result'; File = 'sel-crash.Tests.ps1'; Outcome = 'no-result' }
            @{ Case = 'discovered no tests'; File = 'sel-zero.Tests.ps1'; Outcome = 'no-tests' }
            @{ Case = 'executed no tests, all skipped'; File = 'sel-allskip.Tests.ps1'; Outcome = 'no-tests' }
        ) {
            $result = Invoke-PesterSharded -MinTestCount 0 -Output 'None' -SuitePath @(
                $script:Fixture['sel-pass-a.Tests.ps1']
                $script:Fixture[$File]
            )

            $result.ExitCode | Should -Be 1 -Because "a suite with $Case must redden the check"
            $result.SuitesNotPassed | Should -Be 1 -Because 'the other suite in this run passes, so exactly one thing is wrong'
            (script:Get-SelOutcome -Result $result -File $File).Outcome | Should -Be $Outcome
            (script:Get-SelOutcome -Result $result -File 'sel-pass-a.Tests.ps1').Outcome | Should -Be 'passed'
            $result.Reconciliation.Ok | Should -BeTrue -Because 'nothing was dropped; the failure is the suite, not the accounting'
        }

        It 'S3b: a selected suite that produces no result row at all reddens the run and is named' {
            # The fourth state cannot be induced from outside — it is the run
            # failing to run something it was given. Induced at the shard
            # dispatcher: the manifest names two suites, the shard list holds
            # one. This is the exhibit for the "dropped before it executed" arm,
            # which a run over a smaller set would otherwise report clean.
            $files = @(
                Get-Item -LiteralPath $script:Fixture['sel-pass-a.Tests.ps1']
                Get-Item -LiteralPath $script:Fixture['sel-pass-b.Tests.ps1']
            )
            $dropped = @($files | Where-Object { $_.Name -eq 'sel-pass-a.Tests.ps1' })

            $result = script:Invoke-ShardedRun -ParallelFiles $dropped -SequentialFiles @() `
                -Output 'None' -AllFileManifest $files -MinTestCount 0 -FanOutWidth 2

            $result.ExitCode | Should -Be 1 -Because 'a run that quietly covers a smaller set than it was given is the failure this reports'
            $result.Reconciliation.Ok | Should -BeFalse
            $result.Reconciliation.Selected | Should -Be 2
            $result.Reconciliation.Reported | Should -Be 1
            $result.Reconciliation.Missing | Should -Contain 'sel-pass-b.Tests.ps1'
            (script:Get-SelOutcome -Result $result -File 'sel-pass-b.Tests.ps1').Outcome | Should -Be 'missing'
        }

        It 'S3c: a suite reported but never selected also fails reconciliation' {
            $files = @(
                Get-Item -LiteralPath $script:Fixture['sel-pass-a.Tests.ps1']
                Get-Item -LiteralPath $script:Fixture['sel-pass-b.Tests.ps1']
            )
            $manifest = @($files | Where-Object { $_.Name -eq 'sel-pass-a.Tests.ps1' })

            $result = script:Invoke-ShardedRun -ParallelFiles $files -SequentialFiles @() `
                -Output 'None' -AllFileManifest $manifest -MinTestCount 0 -FanOutWidth 2

            $result.ExitCode | Should -Be 1
            $result.Reconciliation.Ok | Should -BeFalse
            $result.Reconciliation.Unexpected | Should -Contain 'sel-pass-b.Tests.ps1'
        }

        It 'S3d: the negative control — all four absent, and the check is green' {
            $result = Invoke-PesterSharded -SuitePath $script:CleanSelection -MinTestCount 0 -Output 'None'
            $result.ExitCode | Should -Be 0
            $result.SuitesNotPassed | Should -Be 0
            $result.Reconciliation.Ok | Should -BeTrue
            @($result.SuiteOutcomes | Where-Object { $_.Outcome -ne 'passed' }) | Should -BeNullOrEmpty
        }

        It 'S3e: redness for a crashed or zero-test suite does not arrive through a fabricated test count' {
            # The whole point of splitting the channels. Under the previous
            # mechanism both of these ran with a non-zero failure TOTAL — the
            # failure signal WAS the count. Correct the count there and the run
            # goes green; here it does not, because the signal has its own
            # channel.
            foreach ($file in @('sel-crash.Tests.ps1', 'sel-zero.Tests.ps1')) {
                $result = Invoke-PesterSharded -MinTestCount 0 -Output 'None' -SuitePath @(
                    $script:Fixture['sel-pass-a.Tests.ps1']
                    $script:Fixture[$file]
                )
                $result.TotalFailed | Should -Be 0 -Because "$file failed no tests, and saying it failed one is the lie this replaces"
                $result.ExitCode | Should -Be 1 -Because "$file must still redden the run with the count telling the truth"
            }
        }
    }

    Context 'S4: one predicate decides whether a suite passed, and every reader uses it' {

        It 'S4a: the determinism comparison reads the same predicate, and sees a change of KIND' {
            # This site used to recompute the judgement from the legacy fields
            # and collapse every red state to 'fail'. A suite that crashed on
            # one run and failed its tests on the other flipped, and the old
            # comparison reported no flips.
            $run1 = @([pscustomobject]@{ File = 'x.Tests.ps1'; Passed = 0; Failed = 0; Skipped = 0; NotRun = 0; ContainerFailures = 0; TotalCount = 0; HasResult = $false })
            $run2 = @([pscustomobject]@{ File = 'x.Tests.ps1'; Passed = 0; Failed = 2; Skipped = 0; NotRun = 0; ContainerFailures = 0; TotalCount = 2; HasResult = $true })

            $diff = @(script:Compare-RunResults -Run1 $run1 -Run2 $run2)
            $diff.Count | Should -Be 1 -Because 'no-result and failed-tests are different outcomes, and collapsing both to "fail" is what made the determinism check blind'
            $diff[0].Run1Outcome | Should -Be 'no-result'
            $diff[0].Run2Outcome | Should -Be 'failed-tests'
        }

        It 'S4b: a genuinely stable pair still reports no flip' {
            $row = [pscustomobject]@{ File = 'x.Tests.ps1'; Passed = 3; Failed = 0; Skipped = 0; NotRun = 0; ContainerFailures = 0; TotalCount = 3; HasResult = $true }
            @(script:Compare-RunResults -Run1 @($row) -Run2 @($row)) | Should -BeNullOrEmpty
        }
    }

    Context 'S5: the fan-out width is derived from a measured distribution, not chosen' {

        It 'S5a: the measured full-glob distribution yields the width the gate uses' {
            # Inputs read off the record posted on issue #1035 for audit run
            # 31361629558 at commit 0f3c824 — the `suite ms` column over its
            # 254 in-population rows, which is the FULL GLOB: the load the gate
            # carries after #1036, not the subset it gates today.
            $recordParallelTotalMs = 1142460   # 250 suites, the sequential four removed
            $recordParallelMaxMs = 118518      # phase-containment-brief-review.Tests.ps1
            $recordSequentialMs = 79843        # the four sequential-shard suites

            # Reconstructed to the three facts the derivation reads: the
            # parallel set's total, its largest member, and the sequential sum.
            $distribution = @{}
            $distribution['big.Tests.ps1'] = $recordParallelMaxMs
            $remaining = $recordParallelTotalMs - $recordParallelMaxMs
            $each = [int][math]::Floor($remaining / 249)
            for ($i = 1; $i -le 248; $i++) { $distribution["p$i.Tests.ps1"] = $each }
            $distribution['p249.Tests.ps1'] = $remaining - ($each * 248)
            # The four sequential-shard members, at the record's own figures.
            # These are the suites' costs AT THAT COMMIT; the promoted guard
            # suite has since grown (measured 80.3s in gate run 31415554651
            # against the 32,794 ms here), which lengthens the sequential tail
            # and is accounted for in pester.yml's bound arithmetic rather than
            # here — the WIDTH reads only the parallel set.
            $distribution['ci-glob-audit-core.Tests.ps1'] = 28590
            $distribution['plugin-release-hygiene.Tests.ps1'] = 3154
            $distribution['run-pester-sharded.Tests.ps1'] = 32794
            $distribution['session-cleanup-detector.Tests.ps1'] = 15305

            $derived = Get-PesterFanOutWidth -DurationMs $distribution

            $derived.SequentialTotalMs | Should -Be $recordSequentialMs
            $derived.ParallelTotalMs | Should -Be $recordParallelTotalMs
            $derived.ParallelMaxMs | Should -Be $recordParallelMaxMs
            $derived.Width | Should -Be 10 -Because 'ceil(parallel total / longest parallel suite) is the width past which another worker cannot shorten the run'
            $derived.MakespanFloorMs | Should -Be ($recordSequentialMs + $recordParallelMaxMs)
            $derived.MakespanAtWidthMs | Should -Be $derived.MakespanFloorMs -Because 'at the derived width the run already sits on its floor'
        }

        It 'S5b: the derivation discriminates — a different distribution gives a different width' {
            # A derivation that returned the same number for any input would be
            # a citation, not a derivation.
            $flat = @{}
            1..20 | ForEach-Object { $flat["flat$_.Tests.ps1"] = 1000 }
            (Get-PesterFanOutWidth -DurationMs $flat).Width | Should -Be 20 `
                -Because 'when every suite costs the same, every extra worker still shortens the run'

            $dominated = @{ 'giant.Tests.ps1' = 100000 }
            1..20 | ForEach-Object { $dominated["small$_.Tests.ps1"] = 100 }
            (Get-PesterFanOutWidth -DurationMs $dominated).Width | Should -Be 2 `
                -Because 'one suite on the critical path caps what fan-out can buy'

            (Get-PesterFanOutWidth -DurationMs @{ 'only.Tests.ps1' = 5000 }).Width | Should -Be 1
        }

        It 'S5c: the width actually reaches the shard dispatcher' {
            # A derived number nothing consumes is decoration.
            $result = Invoke-PesterSharded -SuitePath $script:CleanSelection -MinTestCount 0 -FanOutWidth 4 -Output 'None'
            $result.FanOutWidth | Should -Be 4
        }
    }

    Context 'S6: the gate itself is configured the way this work requires' {

        BeforeAll {
            $script:GateYmlPath = Join-Path $script:RepoRoot '.github/workflows/pester.yml'
            Import-Module powershell-yaml -ErrorAction SilentlyContinue
            $script:GateYml = ConvertFrom-Yaml (Get-Content -LiteralPath $script:GateYmlPath -Raw)
            $script:GateRun = ($script:GateYml.jobs.pester.steps |
                Where-Object { $_.run -and $_.run -match 'Get-CISuiteSelection' } | Select-Object -First 1).run
        }

        It 'S6a: the gate hands its own selection to the sharded runner and never lets it glob' {
            $script:GateRun | Should -Not -BeNullOrEmpty
            $script:GateRun | Should -Match 'Invoke-PesterSharded' -Because 'the parent pinned the route to the runner already in the repository'
            $script:GateRun | Should -Match '-SuitePath\s+\$selection\.Selected' -Because 'the gate''s own selection must drive the run'
            $script:GateRun | Should -Not -Match '-TestsPath' -Because 'TestsPath globs, and the glob includes every quarantined suite the selection exists to exclude'
        }

        It 'S6b: the gate''s fan-out width is the derived one' {
            $match = [regex]::Match($script:GateRun, '-FanOutWidth\s+(?<w>\d+)')
            $match.Success | Should -BeTrue -Because 'a gate that passes no width silently takes the runner''s default'
            [int]$match.Groups['w'].Value | Should -Be 10 -Because 'this is the width S5a derives from the measured distribution'
        }

        It 'S6c: the gate''s job is bounded, well below the platform''s own ceiling' {
            $limit = $script:GateYml.jobs.pester['timeout-minutes']
            $limit | Should -Not -BeNullOrEmpty -Because 'without this a suite that never returns holds the gate to GitHub''s 360-minute job ceiling on every pull request'
            [int]$limit | Should -BeGreaterThan 0
            # A limit at or above the platform ceiling discharges nothing.
            [int]$limit | Should -BeLessThan 360
            # And it is a bound rather than a formality: the gate's own measured
            # wall clock before this change was 2m11s, and the whole 254-suite
            # corpus #1036 promotes into is roughly a five-minute CPU-bound floor.
            [int]$limit | Should -BeLessOrEqual 30 -Because 'a bound many multiples above any plausible run is the platform ceiling with extra steps'
        }

        It 'S6d: the disclosure''s figures are derived at run time, not typed into the workflow' {
            # A count typed here reads as a disclosure and is false the next time
            # anyone touches the registry — which is exactly what #1036 is
            # chartered to do next.
            $script:GateRun | Should -Match '::notice' -Because 'an annotation renders on the checks surface; a plain host line renders only inside the step log'
            $script:GateRun | Should -Match '\$selection\.Selected\.Count' -Because 'the disclosed count must be the one this run derived'
            $script:GateRun | Should -Match '\$excludedNames' -Because 'the excluded count must be derived from the selection too'
            $script:GateRun | Should -Match 'Sort-Object -Unique' -Because 'the excluded count is over DISTINCT file names: the registry has no duplicate-entry check, and counting raw entries inflated the denominator'
            $script:GateRun | Should -Match 'GITHUB_STEP_SUMMARY' -Because 'the excluded set and its classes must be reachable from the check, not buried in the log'
            # Registry text is untrusted: the registry is a file a pull request
            # can edit, and its `reason` renders into a maintainer-facing table.
            $script:GateRun | Should -Match 'Format-RegistryCell' -Because 'every interpolated registry value must go through one escaper, not an ad-hoc pipe replace'
        }

        It 'S6e: this suite is the one entry the gate now selects, and it was not promoted by being new' {
            . (Join-Path $script:RepoRoot '.github/scripts/lib/ci-suite-selection-core.ps1')
            $selection = Get-CISuiteSelection `
                -TestsRoot (Join-Path $script:RepoRoot '.github/scripts/Tests') `
                -QuarantinePath (Join-Path $script:RepoRoot '.github/scripts/Tests/ci-quarantine.json')

            $selection.HasDrift | Should -BeFalse
            $selection.SelectedNames | Should -Contain 'run-pester-sharded.Tests.ps1' `
                -Because 'the assertions in this file are only a guard if the gate executes them'
            @($selection.Quarantined | Where-Object { $_.file -eq 'run-pester-sharded.Tests.ps1' }) |
                Should -BeNullOrEmpty -Because 'a new file in this directory is auto-selected by the glob, which would satisfy "the gate executes my assertions" while leaving the recursion control quarantined'
        }
    }

    Context 'S7: the runner''s other consumers and its own floors still behave' {

        It 'S7a: the floor the gate runs under is satisfiable, and reads the executed test count' {
            # Discriminating in both directions at one commit.
            $overFloor = Invoke-PesterSharded -SuitePath $script:CleanSelection -MinTestCount 3 -Output 'None'
            $overFloor.TestsExecuted | Should -Be 3
            $overFloor.ExitCode | Should -Be 0 -Because 'three tests executed meets a floor of three'

            $underFloor = Invoke-PesterSharded -SuitePath $script:CleanSelection -MinTestCount 4 -Output 'None'
            $underFloor.ExitCode | Should -Be 1 -Because 'the floor must still fire when fewer tests ran than it demands'
        }

        It 'S7b: the goal-contract validator''s gate predicate reads a field this work touches' {
            # Re-derived, not copied: the second programmatic consumer of the
            # runner's result contract. Its verdict must be unchanged, and it
            # must be shown to DEPEND on the fields redefined here, or an
            # unchanged verdict would be a foregone conclusion.
            $validator = Join-Path $script:RepoRoot '.github/scripts/lib/goal-contract-validate-core.ps1'
            $validator | Should -Exist
            . $validator

            $green = [pscustomobject]@{ ExitCode = 0; TotalPassed = 12; TotalFailed = 0; SuitesNotPassed = 0; Reconciled = $true }
            Test-GCSuiteGatePass -Result $green | Should -BeTrue

            # A crashed worker: under the corrected counting the failure TOTAL is
            # 0, so the clause that used to catch it no longer does. The exit
            # code does, and the suite-level field does independently.
            $crashed = [pscustomobject]@{ ExitCode = 1; TotalPassed = 12; TotalFailed = 0; SuitesNotPassed = 1; Reconciled = $true }
            Test-GCSuiteGatePass -Result $crashed | Should -BeFalse

            # And the fields this work introduced are genuinely load-bearing:
            # flipping either one alone flips the verdict.
            $unpassed = [pscustomobject]@{ ExitCode = 0; TotalPassed = 12; TotalFailed = 0; SuitesNotPassed = 1; Reconciled = $true }
            Test-GCSuiteGatePass -Result $unpassed | Should -BeFalse `
                -Because 'a suite that crashed fails no tests, so a consumer reading only test counts would call that run green'

            $unreconciled = [pscustomobject]@{ ExitCode = 0; TotalPassed = 12; TotalFailed = 0; SuitesNotPassed = 0; Reconciled = $false }
            Test-GCSuiteGatePass -Result $unreconciled | Should -BeFalse `
                -Because 'a run that did not account for its selection must not be read as green by a consumer either'

            # Present-but-wrong is rejected, not coerced. `[bool]` on any
            # non-empty string is true, so the string 'false' passed a guard
            # whose own comment said it would not.
            $stringly = [pscustomobject]@{ ExitCode = 0; TotalPassed = 12; TotalFailed = 0; SuitesNotPassed = 0; Reconciled = 'false' }
            Test-GCSuiteGatePass -Result $stringly | Should -BeFalse `
                -Because 'the string "false" is not a reconciled run, and [bool] on it is $true'

            # The absent-tolerant branch, which nothing the gate selects tested
            # before: a worktree holding a pre-#1037 copy of the runner emits
            # neither field, and this predicate must not start failing closed on
            # a shape it accepted for good reason.
            $legacy = [pscustomobject]@{ ExitCode = 0; TotalPassed = 12; TotalFailed = 0 }
            Test-GCSuiteGatePass -Result $legacy | Should -BeTrue `
                -Because 'a pre-#1037 result shape carries neither new field and must still be judged on the original three clauses'
            $legacyRed = [pscustomobject]@{ ExitCode = 1; TotalPassed = 12; TotalFailed = 0 }
            Test-GCSuiteGatePass -Result $legacyRed | Should -BeFalse
        }

        It 'S7c: the suite-level fields are wired in source at both ends of the process boundary (cheap smoke check, not proof)' {
            # D3: the child launcher wrote both fields and the parent's return
            # rebuild dropped them, so the two clauses above were dead on the
            # only production path while a comment claimed otherwise.
            #
            # NOT PROOF. Demonstrated by mutation during this chunk's own
            # review: delete the rebuild's return path entirely (make the
            # whole nine-property object unreachable dead code) and every
            # `Should -Match` below still passes, because they match SOURCE
            # TEXT, not an executed effect -- the exact "a test asserting a
            # name appears in a script pins nothing" failure mode this
            # methodology names. The authoritative test is
            # `goal-contract-validate-core.Tests.ps1`'s "carries
            # SuitesNotPassed and Reconciled across the real process boundary"
            # case, which drives Invoke-GCSuitePhase through a real child pwsh
            # process and asserts on the RETURNED VALUE. Kept here only as a
            # fast source-presence check that fails loudly (wrong file, wrong
            # property name) before the slower behavioral test even runs.
            $validatorSource = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github/scripts/lib/goal-contract-validate-core.ps1') -Raw

            # The child writes them...
            $validatorSource | Should -Match 'SuitesNotPassed = `\$r\.SuitesNotPassed' `
                -Because 'the launcher must serialize the suite-level count across the process boundary'
            $validatorSource | Should -Match 'Reconciled      = `\$r\.Reconciliation\.Ok' `
                -Because 'the launcher must serialize the reconciliation verdict'

            # ...and the parent must hand them on. This is the site that dropped
            # them: a seven-property rebuild between the JSON and the predicate.
            $validatorSource | Should -Match 'SuitesNotPassed = \$suitesNotPassed' `
                -Because 'the parent rebuild must carry the field through, or the predicate never sees it'
            $validatorSource | Should -Match 'Reconciled      = \$reconciled' `
                -Because 'same for the reconciliation verdict'
        }
    }
}
