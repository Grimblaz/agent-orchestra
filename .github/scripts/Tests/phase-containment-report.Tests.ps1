#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for phase-containment-report.ps1 (issue #768 s6, TDD red-green).
#
# File under test: .github/scripts/phase-containment-report.ps1
#
# BeforeAll dot-sources ONLY the CLI script itself, never the individual lib
# files directly -- this is deliberate (issue #768 s6, judge-sustained M11):
# the point of this suite is to prove the CLI file is standalone-correct
# (its OWN dot-source order resolves Get-DispositionTally before the cost
# core calls it), not to pass only because some earlier test file in the
# same `Invoke-Pester` run already populated the global scope with these
# functions via its own dot-source.
#
# Dot-sourcing the CLI script does not perform a live `gh` fetch: the file's
# top-level auto-invoke guard (`if ($MyInvocation.InvocationName -ne '.')`)
# only calls Invoke-PhaseContainmentReportCli when the file is executed
# directly, not when dot-sourced.

BeforeAll {
    $script:CliPath = Join-Path $PSScriptRoot '..' 'phase-containment-report.ps1'
    . $script:CliPath

    # Issue #842 s1: Resolve-JudgeLogin does not exist in production yet.
    # Stub it as a placeholder BEFORE authoring the Mock below (M6) --
    # Pester throws CommandNotFoundException when Mock-ing a command
    # absent from scope entirely, which is an error-RED that proves
    # nothing, not the assertion-RED this suite needs. Once #842 GREEN
    # lands a real Resolve-JudgeLogin in phase-containment-report.ps1, this
    # placeholder is simply redefined by the dot-source above on every
    # subsequent test run and is safe to delete then.
    function script:Resolve-JudgeLogin {
        param([string]$JudgeLogin = '')
        return $JudgeLogin
    }

    # Default mock for the 12 pre-existing call sites below that omit
    # -JudgeLogin (:118,135,160,170,185,191,197,203,214,222,278,284) --
    # keeps them passing without shelling out to `gh` for identity
    # resolution. Do NOT add explicit -JudgeLogin to those sites; that
    # would delete the suite's only default-path coverage.
    Mock Resolve-JudgeLogin { 'github-actions[bot]' }

    $script:FixedFetchedAt = [datetime]::Parse('2026-01-01T00:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)

    # Minimal value-side entries: one design-challenge (issue-surfaced) entry
    # and one code-review (PR-surfaced) entry, so the value report has
    # non-empty per-stage buckets and the forward-gap computation has a
    # non-empty value-side PR set (PR 501) to work with.
    $script:FixedEntries = @(
        @{
            finding_key        = 'design-challenge:900:test:F1'
            introduced_phase   = 'design'
            catchable_phase    = 'design'
            caught_stage       = 'design-challenge'
            escape_distance    = 0
            severity           = 'medium'
            systemic_fix_type  = 'plan-template'
            category           = 'architecture'
            apparatus_meta     = $false
            surface            = 'issue'
            issueOrPrNumber    = 900
            createdAt          = '2026-01-01T00:00:00Z'
        },
        @{
            finding_key        = 'code-review:501:test:F1'
            introduced_phase   = 'implementation'
            catchable_phase    = 'implementation'
            caught_stage       = 'code-review'
            escape_distance    = 0
            severity           = 'low'
            systemic_fix_type  = 'instruction'
            category           = 'implementation-clarity'
            apparatus_meta     = $false
            surface            = 'pr'
            issueOrPrNumber    = 501
            createdAt          = '2026-01-01T00:00:00Z'
        }
    )

    function script:New-FixedHistoryResult {
        param([bool]$Truncated = $false)
        [PSCustomObject]@{
            Entries           = $script:FixedEntries
            FetchedAt         = $script:FixedFetchedAt
            Source            = 'graphql'
            Truncated         = $Truncated
            InvalidEntryCount = 0
        }
    }

    function script:New-FixedCorpusResult {
        param([bool]$Truncated = $false, [string]$Source = 'graphql')
        [PSCustomObject]@{
            Tuples    = @()
            FetchedAt = $script:FixedFetchedAt
            Source    = $Source
            Truncated = $Truncated
        }
    }

    function script:New-FixedSupplementalCorpusResult {
        param([bool]$Truncated = $false, [string]$Source = 'graphql')
        [PSCustomObject]@{
            Tuples    = @()
            FetchedAt = $script:FixedFetchedAt
            Source    = $Source
            Truncated = $Truncated
        }
    }

    # Issue #869 s4/s6: Invoke-PhaseContainmentReportCli now calls
    # Get-DispositionsLandingGapSupplementalCorpus (its own, separate GraphQL
    # fetch) unconditionally on every run, in its own isolated try/catch
    # (see the "Landing-gap path" region of phase-containment-report.ps1).
    # Without this default mock, every test in this file that invokes the
    # CLI would make a LIVE `gh repo view` / `gh api graphql` call against
    # the real Grimblaz/agent-orchestra repo (the RepoOwner/RepoName every
    # call site below passes) -- slow, network-dependent, and a genuine
    # sandbox/CI-flakiness risk this suite must not carry. Individual tests
    # that need to exercise the landing-gap section's own rendering (below)
    # override this default with their own Mock.
    Mock Get-DispositionsLandingGapSupplementalCorpus { New-FixedSupplementalCorpusResult }
}

Describe 'phase-containment-report.ps1 dot-source order (issue #768 s6, judge-sustained M11)' {
    It 'resolves every value- and cost-path function after dot-sourcing ONLY the CLI script' {
        (Get-Command Get-PhaseContainmentHistory -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Get-PhaseContainmentCommentCorpus -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Get-PhaseContainmentRollup -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Format-PhaseContainmentReport -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Get-DispositionTally -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Get-ReviewCostRollup -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Format-ReviewCostSection -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Invoke-PhaseContainmentReportCli -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        # Issue #869 s4/s6 landing-gap path.
        (Get-Command Get-DispositionsLandingGapSupplementalCorpus -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Get-DispositionsLandingGap -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Format-DispositionsLandingGapSection -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-PhaseContainmentReportCli' {

    Context 'cost-path exception isolation (issue #768 s6, judge-sustained M5/M8)' {
        BeforeEach {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
        }

        It 'still renders the value report AND shows the degradation line when the cost path throws' {
            # Issue #854 s6 (M2): the corpus fetch is now hoisted above the
            # rollup call, in its own try/catch. This test is the TDD-
            # required regression proving the #768 M5/M8 isolation invariant
            # survives that hoist -- it must stay green via the NEW
            # mechanism (the captured $corpusError re-thrown as the cost
            # path try block's first statement) rather than the old one
            # (the corpus fetch living inside that try block directly). A
            # fetch failure here also means -TerminalObservation $null was
            # passed to the rollup (fail-closed), so the code-review row's
            # escape-side arm must render its own "not assessable" state,
            # never a clean signal.
            Mock Get-PhaseContainmentCommentCorpus { throw 'simulated corpus fetch failure' }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            $joined = $output -join "`n"

            $joined | Should -Match 'Phase-Containment Escape-Rate Ledger'
            $joined | Should -Match 'Stage: code-review'
            $joined | Should -Match 'cost section unavailable: simulated corpus fetch failure'
            # The degraded cost path must not print the normal cost section header.
            $joined | Should -Not -Match 'Review Cost \(presentation-only\)'
            # Fail-closed (issue #854 s6 M2): a corpus-fetch failure must
            # never let the escape-side arm present a clean/eligible signal.
            $joined | Should -Match 'Escape-side \(post-review observer\):'
            $joined | Should -Match 'Coverage:\s+NOT ASSESSABLE \(terminal observation unavailable'
        }

        It 'renders both the value report AND the cost section when the cost path succeeds' {
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            $joined = $output -join "`n"

            $joined | Should -Match 'Phase-Containment Escape-Rate Ledger'
            $joined | Should -Match 'Review Cost \(presentation-only\)'
            $joined | Should -Not -Match 'cost section unavailable'
        }
    }

    Context 'G-CR6 regression: Corpus.Source failure without a thrown exception (PR #859 GitHub-review post-fix)' {
        # Get-PhaseContainmentCommentCorpus can return a non-null, non-
        # throwing result with Source='timeout'/'repo-resolution-failed' and
        # empty Tuples -- before this fix, the terminal-observation branch
        # only checked for a thrown exception (via $corpusError) or a $null
        # corpus, so this genuine failure mode derived K=0/N=0 from the
        # empty corpus and rendered the misleading "coverage insufficient (0
        # of 0 co-observed PRs measured, need >=5)" instead of the honest
        # "terminal observation unavailable" degradation.
        BeforeEach {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
        }

        It 'renders terminal-observation-unavailable, not coverage-insufficient, when Corpus.Source is timeout' {
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult -Source 'timeout' }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            $joined = $output -join "`n"

            $joined | Should -Match 'Coverage:\s+NOT ASSESSABLE \(terminal observation unavailable'
            $joined | Should -Not -Match '0 of 0 co-observed PRs measured'
        }

        It 'renders terminal-observation-unavailable, not coverage-insufficient, when Corpus.Source is repo-resolution-failed' {
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult -Source 'repo-resolution-failed' }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            $joined = $output -join "`n"

            $joined | Should -Match 'Coverage:\s+NOT ASSESSABLE \(terminal observation unavailable'
            $joined | Should -Not -Match '0 of 0 co-observed PRs measured'
        }
    }

    Context 'fetch coherence: -ValueCacheOk / -NoCache precedence (issue #768 s6, judge-sustained M8)' {
        BeforeEach {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
        }

        It 'bypasses the value cache and shows no caveat by default (neither switch supplied)' {
            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            ($output -join "`n") | Should -Not -Match 'CAVEAT: -ValueCacheOk was used'
            Should -Invoke Get-PhaseContainmentHistory -Times 1 -Exactly -ParameterFilter { $CachePath }
        }

        It 'emits the population-mismatch caveat when -ValueCacheOk is used alone' {
            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' -ValueCacheOk
            ($output -join "`n") | Should -Match 'CAVEAT: -ValueCacheOk was used'
            Should -Invoke Get-PhaseContainmentHistory -Times 1 -Exactly -ParameterFilter { -not $CachePath }
        }

        It 'treats -NoCache as winning over -ValueCacheOk: fresh fetch, no caveat, when both are supplied' {
            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' -NoCache -ValueCacheOk
            ($output -join "`n") | Should -Not -Match 'CAVEAT: -ValueCacheOk was used'
            Should -Invoke Get-PhaseContainmentHistory -Times 1 -Exactly -ParameterFilter { $CachePath }
        }

        It '-NoCache alone bypasses the cache with no caveat (unchanged pre-existing behavior)' {
            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' -NoCache
            ($output -join "`n") | Should -Not -Match 'CAVEAT: -ValueCacheOk was used'
            Should -Invoke Get-PhaseContainmentHistory -Times 1 -Exactly -ParameterFilter { $CachePath }
        }
    }

    Context 'CM16 fix (a): no orphaned temp file on cache-bypass (issue #842 s6)' {
        BeforeEach {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
        }

        It 'does not orphan a real 0-byte GetTempFileName() file when a default run bypasses the value cache' {
            # A prior version pointed $fetchParams['CachePath'] at
            # [System.IO.Path]::GetTempFileName() + '.nocache.json' -- since
            # GetTempFileName() creates a REAL file and returns its path, and
            # the appended suffix names a DIFFERENT path, the created file
            # (named 'tmp*.tmp' on this host) was orphaned on every single
            # default/-NoCache run. Snapshot the temp directory's matching
            # files before and after a default (bypass-cache) invocation and
            # assert no new one was left behind.
            $before = @(Get-ChildItem -Path $env:TEMP -Filter 'tmp*.tmp' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' | Out-Null
            $after = @(Get-ChildItem -Path $env:TEMP -Filter 'tmp*.tmp' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $newFiles = @($after | Where-Object { $before -notcontains $_ })
            $newFiles | Should -BeNullOrEmpty -Because "a default (bypass-cache) run must not orphan a real temp file; new tmp*.tmp file(s) found: $($newFiles -join ', ')"
        }
    }

    Context 'issue #876 F1: bypass CachePath construction survives $env:TEMP being unset (PowerShell Core / Linux / macOS)' {
        BeforeEach {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
            $script:SavedEnvTemp876 = $env:TEMP
            Remove-Item Env:\TEMP -ErrorAction SilentlyContinue
        }

        AfterEach {
            if ($null -ne $script:SavedEnvTemp876) {
                $env:TEMP = $script:SavedEnvTemp876
            }
            else {
                Remove-Item Env:\TEMP -ErrorAction SilentlyContinue
            }
        }

        It 'does not throw a null-binding error building the bypass CachePath when $env:TEMP is unset' {
            # Only Windows conventionally sets $env:TEMP; PowerShell Core on
            # Linux/macOS leaves it unset by default. A prior version called
            # `Join-Path $env:TEMP "..."`, which throws a terminating
            # parameter-binding error the instant $env:TEMP is $null --
            # reproducible even on this Windows host once the variable is
            # cleared (confirmed manually). [System.IO.Path]::GetTempPath()
            # resolves TMPDIR/TEMP/TMP cross-platform without ever needing
            # $env:TEMP directly.
            { Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' } | Should -Not -Throw
        }
    }

    Context 'Truncated-flag divergence (issue #768 s6, judge-sustained M8)' {
        It 'renders a population-divergence warning when the value and cost Truncated flags disagree' {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult -Truncated $false }
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult -Truncated $true }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            ($output -join "`n") | Should -Match 'WARNING:.*disagree'
        }

        It 'does not render the divergence warning when the two Truncated flags agree' {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult -Truncated $false }
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult -Truncated $false }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            ($output -join "`n") | Should -Not -Match 'disagree'
        }
    }

    Context 'AC3: presentation-only value-block byte-identical regression (issue #768 s6, judge-sustained M5; issue #854 s6 M3 re-pin)' {
        BeforeEach {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
            # Both runs below share this SAME corpus mock -- issue #854 s6
            # (M3) rewrites this pin to hold TerminalObservation CONSTANT
            # across runs, rather than holding the corpus fetch OUTCOME
            # constant (the pre-#854 pin's approach, which no longer
            # exercises the right invariant -- see the test body comment).
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
        }

        It 'renders a byte-identical value-block region whether the cost path succeeds or fails during rendering, holding TerminalObservation constant across both runs (issue #854 s6, M3)' {
            # M3 (judge-sustained, owner-approved `value-block-cost-
            # dependency-854`): the pre-#854 version of this pin varied the
            # CORPUS FETCH ITSELF between its two runs (mocking
            # Get-PhaseContainmentCommentCorpus to succeed in one run and
            # throw in the other) and asserted the value block never
            # changed. That is no longer the right way to exercise #768's
            # isolation invariant: #854 intentionally threads the corpus-
            # derived TerminalObservation into the value block's code-review
            # row, so varying the fetch OUTCOME now legitimately varies the
            # value block too -- that is the documented, owner-ruled
            # revision, not a regression.
            #
            # What #768's invariant actually protects -- a cost-SECTION-
            # RENDERING failure, occurring AFTER a successful corpus fetch,
            # must never perturb the value block -- still holds, and is what
            # this rewritten pin exercises: both runs below share the exact
            # same (mocked) successful corpus fetch, so TerminalObservation
            # is identical in both; only the downstream Get-ReviewCostRollup
            # call is made to fail in run 2.

            # Ground truth: derive TerminalObservation from the SAME fixed
            # corpus mock and Entries the CLI itself will use, independently
            # of the CLI call, to build the pin's own reference value block.
            $groundCorpus = New-FixedCorpusResult
            $groundTerminalObservation = Get-PhaseContainmentTerminalObservation -Corpus $groundCorpus -Entries $script:FixedEntries -JudgeLogin 'github-actions[bot]' -ValueCacheOk $true
            $expectedRollup = Get-PhaseContainmentRollup -Entries $script:FixedEntries -WindowLabel '90d' -Truncated:$false -TerminalObservation $groundTerminalObservation
            $expectedContext = @{
                Rollup            = $expectedRollup
                Source            = 'graphql'
                Truncated         = $false
                WindowDays        = 90
                FetchedAt         = $script:FixedFetchedAt
                InvalidEntryCount = 0
            }
            $expectedValueBlock = @(Format-PhaseContainmentReport -Context $expectedContext)
            $n = $expectedValueBlock.Count
            $n | Should -BeGreaterThan 0

            # Run 1: cost path present and succeeding end-to-end.
            $withCost = @(Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '')

            # Run 2: the SAME corpus fetch succeeds (TerminalObservation is
            # therefore identical to run 1's), but cost-section RENDERING
            # itself fails downstream of that successful fetch.
            Mock Get-ReviewCostRollup { throw 'simulated cost rendering failure' }
            $withFailedRendering = @(Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '')

            $withCost.Count | Should -BeGreaterOrEqual $n
            $withFailedRendering.Count | Should -BeGreaterOrEqual $n

            $withCostValueBlock = $withCost[0..($n - 1)]
            $withFailedRenderingValueBlock = $withFailedRendering[0..($n - 1)]

            # Byte-for-byte (line-for-line) comparison of the value-block
            # region only -- the trailing content legitimately differs (the
            # cost section vs. the degradation line), which is expected and
            # is NOT part of this pin.
            for ($i = 0; $i -lt $n; $i++) {
                $withCostValueBlock[$i] | Should -BeExactly $expectedValueBlock[$i]
                $withFailedRenderingValueBlock[$i] | Should -BeExactly $expectedValueBlock[$i]
            }
        }

    }

    Context 'Landing-gap section rendering and isolation (issue #869 s4/s6, Part 4)' {
        # The landing-gap path is wired into Invoke-PhaseContainmentReportCli
        # AFTER the cost section, in its own isolated try/catch (mirrors the
        # #768 s6 M5/M8 cost-path isolation invariant, extended one section
        # further). These tests prove the new section actually renders in
        # the full CLI output, and that a landing-gap-path failure never
        # suppresses the value report or the cost section that already
        # rendered before it.
        BeforeEach {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
        }

        It 'renders the Review-Dispositions Landing Gap section header with the WindowDays value when both fetches succeed' {
            Mock Get-DispositionsLandingGapSupplementalCorpus { New-FixedSupplementalCorpusResult }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            $joined = $output -join "`n"

            $joined | Should -Match 'Review-Dispositions Landing Gap \(presentation-only, 90d window\)' -Because (
                "Actual output:`n$joined"
            )
        }

        It 'still renders the value report AND the cost section when the landing-gap path throws' {
            Mock Get-DispositionsLandingGapSupplementalCorpus { throw 'simulated supplemental fetch failure' }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            $joined = $output -join "`n"

            $joined | Should -Match 'Phase-Containment Escape-Rate Ledger'
            $joined | Should -Match 'Review Cost \(presentation-only\)'
            $joined | Should -Match 'landing gap section unavailable: simulated supplemental fetch failure'
            # The degraded landing-gap path must not print its own normal section header.
            $joined | Should -Not -Match 'Review-Dispositions Landing Gap'
        }
    }
}

Describe 'structural guard: RelaxationEligible computation path never receives a cost-related parameter by an unlisted name (issue #768 s6; issue #854 s6 M15 re-pin)' {
    It 'the CLI file''s Get-PhaseContainmentRollup call site only ever passes the allow-listed parameter names' {
        # M15 (judge-sustained): the pre-#854 guard asserted the rollup call
        # line's TEXT does not contain the substring "cost" (case-
        # insensitive). Issue #854 s6 threads -TerminalObservation into that
        # SAME call -- a value that IS cost-corpus-derived -- and that
        # parameter name passes the old substring check textually while
        # defeating its actual purpose. A guard that silently stops
        # guarding is worse than no guard, so this replacement allow-lists
        # the EXACT parameter names the call may pass and fails if any
        # OTHER parameter appears -- catching a future maintainer who
        # threads a second cost-derived value through under some other
        # name that also happens not to contain "cost".
        $allowedParameterNames = @('Entries', 'WindowLabel', 'Truncated', 'TerminalObservation')

        $cliText = Get-Content -Raw $script:CliPath
        $rollupCallLine = ($cliText -split "`r?`n") | Where-Object { $_ -match 'Get-PhaseContainmentRollup\s+-Entries' }

        $rollupCallLine | Should -Not -BeNullOrEmpty

        # (?<=\s)- requires the dash to be preceded by whitespace, so the
        # "-PhaseContainmentRollup" substring inside the callee's own name
        # (Get-PhaseContainmentRollup) is never mistaken for a parameter.
        $actualParameterNames = @(
            [regex]::Matches($rollupCallLine, '(?<=\s)-([A-Za-z]+)(?::|\s|$)') | ForEach-Object { $_.Groups[1].Value }
        )
        $actualParameterNames.Count | Should -BeGreaterThan 0

        $unexpectedParameterNames = @($actualParameterNames | Where-Object { $_ -notin $allowedParameterNames })
        $unexpectedParameterNames | Should -BeNullOrEmpty -Because (
            "the rollup call site must only ever pass $($allowedParameterNames -join ', ') -- found unexpected parameter(s): $($unexpectedParameterNames -join ', '). " +
            "A future maintainer threading a second cost-derived value through under a name that doesn't literally contain 'cost' must still be caught here."
        )

        # Also assert every allow-listed name the current call site is
        # KNOWN to require is actually present, so this guard cannot be
        # satisfied by silently dropping -TerminalObservation either.
        foreach ($required in @('Entries', 'WindowLabel', 'Truncated', 'TerminalObservation')) {
            $actualParameterNames | Should -Contain $required -Because "the rollup call site must pass -$required."
        }
    }
}

# ---------------------------------------------------------------------------
# Get-PhaseContainmentTerminalObservation harness (issue #854 code-review
# escape-detection fix pass, M9). Before this harness, the ONLY existing
# invocation of this function anywhere in the suite (the AC3 byte-identical
# pin above) used a `Tuples = @()` fixture, so every per-tuple branch inside
# the derivation was dead code under test. This harness builds REAL Tuples:
# judge-authored and non-judge-authored bodies, dated and undated
# createdAt, v3 (reviewer_source only) and v4 (reviewer_source +
# internal_match) markers, zero-finding coverage records, and entries
# spanning every Disposition and internal_match.match_status value.
# ---------------------------------------------------------------------------

Describe 'Get-PhaseContainmentTerminalObservation (issue #854 code-review escape-detection fix pass, M9 harness)' {
    BeforeAll {
        $script:JudgeLogin = 'github-actions[bot]'

        # Builds a single per-entry YAML block for a review-dispositions
        # marker. -MatchStatus $null omits internal_match entirely (v3-
        # style marker; the Seam Specification defaults an absent
        # internal_match to 'ambiguous').
        function script:New-RdEntry {
            param(
                [Parameter(Mandatory)][string]$Key,
                [string]$Disposition = 'incorporate',
                [string]$ReviewerSource = 'local',
                [string]$MatchStatus = $null
            )
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("  - stable_finding_key: `"$Key`"")
            $lines.Add('    pass: 1')
            $lines.Add("    disposition: $Disposition")
            $lines.Add('    classification: routine')
            $lines.Add('    severity: medium')
            $lines.Add('    stage: code-review')
            $lines.Add("    reviewer_source: $ReviewerSource")
            if ($null -ne $MatchStatus) {
                # v4 shape: internal_match written before disposition_rationale (M42).
                $lines.Add('    internal_match:')
                $lines.Add("      match_status: $MatchStatus")
            }
            $lines.Add('    disposition_rationale: "fixture entry"')
            return ($lines -join "`n")
        }

        # Builds a single <!-- review-dispositions-{Pr} --> comment body.
        #   -Entries: an array of already-formatted YAML entry blocks (see
        #     script:New-RdEntry), or @() for a zero-entry marker.
        #   -ExternalSourcesReconciled: the PR-level field's raw YAML value
        #     (e.g. '[]' or '["gh-1"]'); $null OMITS the field entirely --
        #     distinct from a genuinely empty list (the M9 zero-finding
        #     legal-coverage case uses '[]', never $null).
        function script:New-RdBody {
            param(
                [Parameter(Mandatory)][int]$Pr,
                [string[]]$Entries = @(),
                # Post-fix batch 4 (issue #854 s6) fix: [object], not
                # [string]. A [string]-typed parameter coerces an explicitly
                # passed $null argument to '' (empty string) during
                # PowerShell parameter binding, NOT $null -- so
                # `-ExternalSourcesReconciled $null` never actually reached
                # the omission branch below despite this function's own
                # docstring promising it did. [object] preserves the caller's
                # literal $null, making the documented "$null OMITS the field
                # entirely" contract true for the first time (no prior test
                # exercised this call shape).
                [object]$ExternalSourcesReconciled = '[]',
                [int]$SchemaVersion = 4
            )
            $fence = '{0}{0}{0}' -f [char]96
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("<!-- review-dispositions-$Pr -->")
            $lines.Add('')
            $lines.Add("${fence}yaml")
            $lines.Add("schema_version: $SchemaVersion")
            $lines.Add('passes_run: [1]')
            $lines.Add('entries:')
            foreach ($e in $Entries) { $lines.Add($e) }
            if ($null -ne $ExternalSourcesReconciled) {
                $lines.Add("external_sources_reconciled: $ExternalSourcesReconciled")
            }
            $lines.Add($fence)
            return ($lines -join "`n")
        }

        # Builds a single PR-surface corpus tuple (the contract Get-
        # PhaseContainmentCommentCorpus produces: Number/Surface/Bodies/
        # AuthorLogins/CreatedAtValues, index-paired across the last three).
        function script:New-PrTuple {
            param(
                [Parameter(Mandatory)][int]$Number,
                [Parameter(Mandatory)][string[]]$Bodies,
                [Parameter(Mandatory)][string[]]$AuthorLogins,
                [string[]]$CreatedAtValues = $null
            )
            if ($null -eq $CreatedAtValues) {
                # Default: every body dated, one day apart, so latest-wins
                # ordering is deterministic when a test does not care about it.
                $CreatedAtValues = 1..$Bodies.Count | ForEach-Object { "2026-0$_-01T00:00:00Z" }
            }
            return @{
                Number          = $Number
                Surface         = 'pr'
                Bodies          = $Bodies
                AuthorLogins    = $AuthorLogins
                CreatedAtValues = $CreatedAtValues
            }
        }

        function script:New-CodeReviewValueEntry {
            param([int]$PrNumber, [bool]$ApparatusMeta = $false)
            return @{
                finding_key      = "code-review:${PrNumber}:internal-catch"
                introduced_phase = 'implementation'
                catchable_phase  = 'implementation'
                caught_stage     = 'code-review'
                escape_distance  = 0
                severity         = 'low'
                systemic_fix_type = 'none'
                category         = 'implementation-clarity'
                apparatus_meta   = $ApparatusMeta
                surface          = 'pr'
                issueOrPrNumber  = $PrNumber
                createdAt        = '2026-01-01T00:00:00Z'
            }
        }
    }

    Context 'M9: zero-finding coverage records are legal measurements' {
        It 'counts a judge-authored, cleanly-parsed, ZERO-entry review-dispositions record as legal coverage toward K' {
            $body = New-RdBody -Pr 1000 -Entries @() -ExternalSourcesReconciled '[]'
            $tuple = New-PrTuple -Number 1000 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.CoObservedPRCount       | Should -Be 1
            $result.MeasuredCoveragePRCount | Should -Be 1
        }

        It 'does NOT count a PR with no review-dispositions marker head at all (distinguishing "measured zero" from "never measured")' {
            $body = "Just an ordinary PR comment, no review-dispositions marker at all."
            $tuple = New-PrTuple -Number 1001 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.CoObservedPRCount       | Should -Be 1
            $result.MeasuredCoveragePRCount | Should -Be 0
        }
    }

    Context 'M5: coverage no longer requires >=1 resolved-external finding' {
        It 'counts a PR toward K even when its only external entry resolves to reviewer_source unresolved (all-unresolved no longer zeroes coverage)' {
            $entry = New-RdEntry -Key 'gh-1' -Disposition 'incorporate' -ReviewerSource 'unresolved' -MatchStatus $null
            $body = New-RdBody -Pr 2000 -Entries @($entry) -ExternalSourcesReconciled '[]'
            $tuple = New-PrTuple -Number 2000 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.MeasuredCoveragePRCount        | Should -Be 1
            $result.ExternalCatchCount             | Should -Be 0
            $result.DuplicateCount                 | Should -Be 0
            $result.DispositionsNovelExternalCount | Should -Be 0
        }

        It 'counts a PR toward K carrying only a "local" (pipeline-native) entry, same as an empty external review (regression: local-only was never gated by the old >=1 rule either)' {
            $entry = New-RdEntry -Key 'local-1' -Disposition 'incorporate' -ReviewerSource 'local' -MatchStatus $null
            $body = New-RdBody -Pr 2001 -Entries @($entry) -ExternalSourcesReconciled '[]'
            $tuple = New-PrTuple -Number 2001 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.MeasuredCoveragePRCount | Should -Be 1
        }
    }

    Context 'M3: dismissed external-source entries never count toward K-affecting tallies' {
        It 'excludes a dismissed novel-matched entry from DispositionsNovelExternalCount and ExternalCatchCount' {
            $entry = New-RdEntry -Key 'gh-dismissed' -Disposition 'dismiss' -ReviewerSource 'jdoe' -MatchStatus 'novel'
            $body = New-RdBody -Pr 2100 -Entries @($entry) -ExternalSourcesReconciled '["gh-dismissed"]'
            $tuple = New-PrTuple -Number 2100 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.DispositionsNovelExternalCount | Should -Be 0
            $result.ExternalCatchCount             | Should -Be 0
            # Coverage itself is unaffected by disposition (M5/M9) -- the PR
            # still had a judge-authored, cleanly-parsed coverage record.
            $result.MeasuredCoveragePRCount        | Should -Be 1
        }

        It 'excludes a dismissed duplicate-matched entry from DuplicateCount and ExternalCatchCount' {
            $entry = New-RdEntry -Key 'gh-dismissed-dup' -Disposition 'dismiss' -ReviewerSource 'jdoe' -MatchStatus 'duplicate'
            $body = New-RdBody -Pr 2101 -Entries @($entry) -ExternalSourcesReconciled '["gh-dismissed-dup"]'
            $tuple = New-PrTuple -Number 2101 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.DuplicateCount     | Should -Be 0
            $result.ExternalCatchCount | Should -Be 0
        }

        It 'counts non-dismissed sustained dispositions (incorporate, escalate, defer) toward the novel/duplicate tallies (only dismiss is excluded)' {
            $entries = @(
                (New-RdEntry -Key 'gh-incorporate' -Disposition 'incorporate' -ReviewerSource 'alice' -MatchStatus 'novel'),
                (New-RdEntry -Key 'gh-escalate' -Disposition 'escalate' -ReviewerSource 'bob' -MatchStatus 'novel'),
                (New-RdEntry -Key 'gh-defer' -Disposition 'defer' -ReviewerSource 'carol' -MatchStatus 'novel')
            )
            $body = New-RdBody -Pr 2102 -Entries $entries -ExternalSourcesReconciled '["gh-incorporate","gh-escalate","gh-defer"]'
            $tuple = New-PrTuple -Number 2102 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.DispositionsNovelExternalCount | Should -Be 3
            $result.ExternalCatchCount             | Should -Be 3
        }
    }

    Context 'internal_match.match_status coverage: duplicate / novel / ambiguous / absent (v3 vs v4 markers)' {
        It 'tallies duplicate, novel, and ambiguous entries into the correct buckets, and defaults an absent internal_match (v3 marker) to ambiguous' {
            $entries = @(
                (New-RdEntry -Key 'gh-dup' -ReviewerSource 'alice' -MatchStatus 'duplicate'),
                (New-RdEntry -Key 'gh-novel' -ReviewerSource 'bob' -MatchStatus 'novel'),
                (New-RdEntry -Key 'gh-ambiguous' -ReviewerSource 'carol' -MatchStatus 'ambiguous'),
                # v3-style entry: no internal_match block at all.
                (New-RdEntry -Key 'gh-v3-absent' -ReviewerSource 'dave' -MatchStatus $null)
            )
            $body = New-RdBody -Pr 2200 -Entries $entries -ExternalSourcesReconciled '["gh-dup","gh-novel"]' -SchemaVersion 3

            $tuple = New-PrTuple -Number 2200 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.DuplicateCount                 | Should -Be 1
            $result.DispositionsNovelExternalCount | Should -Be 1
            # ambiguous AND the absent-internal_match entry (defaults to
            # ambiguous) are both excluded from n2/m -- only duplicate(1) +
            # novel(1) = 2 count toward ExternalCatchCount.
            $result.ExternalCatchCount             | Should -Be 2
        }
    }

    Context 'judge-authored vs non-judge-authored bodies (forged-coverage vector, issue #854 s4/M8)' {
        It 'contributes ZERO coverage/catch data from a well-formed but non-judge-authored body' {
            $forgedEntry = New-RdEntry -Key 'gh-forged' -ReviewerSource 'mallory' -MatchStatus 'novel'
            $forgedBody = New-RdBody -Pr 2300 -Entries @($forgedEntry) -ExternalSourcesReconciled '["gh-forged"]'
            $tuple = New-PrTuple -Number 2300 -Bodies @($forgedBody) -AuthorLogins @('random-attacker')
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.MeasuredCoveragePRCount        | Should -Be 0
            $result.DispositionsNovelExternalCount | Should -Be 0
            # The window population (N) still counts the PR tuple itself --
            # only the judge-authorship-gated coverage/catch data is zeroed.
            $result.CoObservedPRCount              | Should -Be 1
        }
    }

    Context 'M13: a review-dispositions marker whose {N} does not match the tuple''s own PR number is skipped, not counted' {
        It 'excludes a body whose review-dispositions marker number mismatches the tuple''s own PR number (a judge-authored comment on PR 2600 that happens to quote PR 9999''s block)' {
            $entry = New-RdEntry -Key 'gh-wrong-pr' -ReviewerSource 'alice' -MatchStatus 'novel'
            $body = New-RdBody -Pr 9999 -Entries @($entry) -ExternalSourcesReconciled '["gh-wrong-pr"]'
            $tuple = New-PrTuple -Number 2600 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.MeasuredCoveragePRCount        | Should -Be 0
            $result.DispositionsNovelExternalCount | Should -Be 0
            $result.ExternalCatchCount             | Should -Be 0
        }

        It 'still counts a body whose review-dispositions marker number matches the tuple''s own PR number' {
            $entry = New-RdEntry -Key 'gh-right-pr' -ReviewerSource 'alice' -MatchStatus 'novel'
            $body = New-RdBody -Pr 2601 -Entries @($entry) -ExternalSourcesReconciled '["gh-right-pr"]'
            $tuple = New-PrTuple -Number 2601 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.MeasuredCoveragePRCount        | Should -Be 1
            $result.DispositionsNovelExternalCount | Should -Be 1
        }
    }

    Context 'dated createdAt latest-wins merge across two judge bodies on the same PR' {
        It 'keeps the LATER-createdAt body''s match_status for a repeated stable_finding_key' {
            $earlier = New-RdEntry -Key 'gh-samekey' -ReviewerSource 'alice' -MatchStatus 'ambiguous'
            $later   = New-RdEntry -Key 'gh-samekey' -ReviewerSource 'alice' -MatchStatus 'novel'
            $earlierBody = New-RdBody -Pr 2400 -Entries @($earlier) -ExternalSourcesReconciled '[]'
            $laterBody   = New-RdBody -Pr 2400 -Entries @($later) -ExternalSourcesReconciled '["gh-samekey"]'

            $tuple = New-PrTuple -Number 2400 `
                -Bodies @($earlierBody, $laterBody) `
                -AuthorLogins @($script:JudgeLogin, $script:JudgeLogin) `
                -CreatedAtValues @('2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z')
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            # The later body's 'novel' verdict wins over the earlier 'ambiguous' one.
            $result.DispositionsNovelExternalCount | Should -Be 1
            $result.ExternalCatchCount             | Should -Be 1
        }

        It 'does NOT let an undated later body overwrite an already-dated earlier body''s match_status for the same key (M11 fix: an undated candidate must never unconditionally displace a dated entry)' {
            $dated   = New-RdEntry -Key 'gh-samekey' -ReviewerSource 'alice' -MatchStatus 'novel'
            $undated = New-RdEntry -Key 'gh-samekey' -ReviewerSource 'alice' -MatchStatus 'ambiguous'
            $datedBody   = New-RdBody -Pr 2402 -Entries @($dated) -ExternalSourcesReconciled '["gh-samekey"]'
            $undatedBody = New-RdBody -Pr 2402 -Entries @($undated) -ExternalSourcesReconciled '[]'

            $tuple = New-PrTuple -Number 2402 `
                -Bodies @($datedBody, $undatedBody) `
                -AuthorLogins @($script:JudgeLogin, $script:JudgeLogin) `
                -CreatedAtValues @('2026-01-01T00:00:00Z', '')
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            # The dated body's 'novel' verdict must survive -- comment
            # ordering on GitHub is not guaranteed chronological, so an
            # undated (unparseable createdAt) later body must not win
            # against an already-dated entry for the same key.
            $result.DispositionsNovelExternalCount | Should -Be 1
            $result.ExternalCatchCount             | Should -Be 1
        }

        It 'still contributes coverage/catch data when CreatedAtValues is blank (undated body)' {
            $entry = New-RdEntry -Key 'gh-undated' -ReviewerSource 'alice' -MatchStatus 'novel'
            $body = New-RdBody -Pr 2401 -Entries @($entry) -ExternalSourcesReconciled '["gh-undated"]'
            $tuple = New-PrTuple -Number 2401 -Bodies @($body) -AuthorLogins @($script:JudgeLogin) -CreatedAtValues @('')

            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.MeasuredCoveragePRCount        | Should -Be 1
            $result.DispositionsNovelExternalCount | Should -Be 1
        }
    }

    Context 'M2/M12: n1 (InternalCoObservedCatchCount) is scoped to the coverage-record PR set, not the whole window' {
        It 'excludes an internal code-review/implementation catch on a PR that has NO review-dispositions coverage record, even though that PR is in the window' {
            # PR 2500 has a judge-authored coverage record (in K); PR 2501 is
            # merely present in the fetched window (a corpus tuple exists)
            # but carries no review-dispositions marker at all, so it is NOT
            # in K. Both PRs have an internal code-review/implementation
            # catch in the VALUE-side $Entries.
            $coveredBody = New-RdBody -Pr 2500 -Entries @() -ExternalSourcesReconciled '[]'
            $coveredTuple = New-PrTuple -Number 2500 -Bodies @($coveredBody) -AuthorLogins @($script:JudgeLogin)

            $uncoveredBody = 'Ordinary PR chatter, no review-dispositions marker.'
            $uncoveredTuple = New-PrTuple -Number 2501 -Bodies @($uncoveredBody) -AuthorLogins @($script:JudgeLogin)

            $corpus = [PSCustomObject]@{ Tuples = @($coveredTuple, $uncoveredTuple); Truncated = $false }

            $valueEntries = @(
                (New-CodeReviewValueEntry -PrNumber 2500),
                (New-CodeReviewValueEntry -PrNumber 2501)
            )

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries $valueEntries -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.CoObservedPRCount            | Should -Be 2   # M12: whole-window population (N)
            $result.MeasuredCoveragePRCount       | Should -Be 1   # M12: DD3's actual co-observed set (K)
            # M2: n1 counts ONLY the catch on the coverage-record PR (2500),
            # never the catch on PR 2501 (window-present but uncovered) --
            # before the fix, n1 would have counted BOTH (scoped to the
            # whole-window $coObservedPrNumbers), diluting the estimator.
            $result.InternalCoObservedCatchCount | Should -Be 1
        }
    }

    Context 'M8: threads the corpus fetch''s own Truncated flag through, distinct from the value fetch' {
        It 'reports CorpusTruncated=$true when the corpus itself truncated' {
            $corpus = [PSCustomObject]@{ Tuples = @(); Truncated = $true }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.CorpusTruncated | Should -Be $true
        }

        It 'reports CorpusTruncated=$false when the corpus did not truncate (regression guard)' {
            $corpus = [PSCustomObject]@{ Tuples = @(); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.CorpusTruncated | Should -Be $false
        }
    }

    Context 'Post-fix batch 4 (issue #854 s6): internal-only markers must not inflate K (MeasuredCoveragePRCount)' {
        It 'does NOT count a with-entries, judge-authored marker that never wrote external_sources_reconciled (internal-only pass) toward K' {
            $entry = New-RdEntry -Key 'local-only-1' -Disposition 'incorporate' -ReviewerSource 'local' -MatchStatus $null
            $body  = New-RdBody -Pr 3000 -Entries @($entry) -ExternalSourcesReconciled $null
            $tuple = New-PrTuple -Number 3000 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.CoObservedPRCount       | Should -Be 1
            # Before the fix, this counted toward K (ParseStatus was
            # unconditionally 'ok' for any with-entries body) -- the exact
            # false-clean coverage vector this fix closes.
            $result.MeasuredCoveragePRCount | Should -Be 0
        }

        It 'DOES count a with-entries, judge-authored marker that carries a real external_sources_reconciled field toward K (regression: genuine coverage still works)' {
            $entry = New-RdEntry -Key 'gh-real' -Disposition 'incorporate' -ReviewerSource 'alice' -MatchStatus 'duplicate'
            $body  = New-RdBody -Pr 3001 -Entries @($entry) -ExternalSourcesReconciled '["gh-real"]'
            $tuple = New-PrTuple -Number 3001 -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
            $corpus = [PSCustomObject]@{ Tuples = @($tuple); Truncated = $false }

            $result = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries @() -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

            $result.MeasuredCoveragePRCount | Should -Be 1
        }
    }

    # -----------------------------------------------------------------------
    # Post-fix batch 4 (issue #854 s6) — the single most important test in
    # this batch: an end-to-end reproduction of the exact reachable failure
    # the post-fix defense pass traced. Before this fix, a window with >=5
    # internal-only review-dispositions markers (real entries, but the writer
    # never reconciled an external review -- the M5-over-correction path,
    # DISTINCT from the original M9 ambiguous-default-matching vector) plus
    # <5 genuine external reconciliations, at least one real internal
    # co-observed catch (n1>=1), and zero observer escapes computed
    # unique-catch rate = 0/n1 = 0.0 < 0.05 -> escape arm CLEAN ->
    # RelaxationEligible=TRUE. That is a measured-looking zero that was never
    # actually measured: K was inflated entirely by markers that never
    # attempted external reconciliation. This test proves the fix renders the
    # rollup's escape-side gate correctly NOT eligible (coverage-insufficient)
    # instead. Nested in this Describe (not a standalone one) because it
    # depends on the script:-scoped New-RdEntry/New-RdBody/New-PrTuple/
    # New-CodeReviewValueEntry helpers and $script:JudgeLogin defined in this
    # Describe's own BeforeAll.
    # -----------------------------------------------------------------------
    Context 'Post-fix batch 4: reachable false-clean-via-internal-only-markers scenario no longer renders RelaxationEligible' {
    It 'sets RelaxationEligible != $true (coverage insufficient) when 5 internal-only markers would have inflated K past the 5-PR threshold, genuine external reconciliations number fewer than 5, n1 is at least 1, and there are 0 observer escapes' {
        # 5 internal-only PRs: real entries (reviewer_source: local), but the
        # PR-level external_sources_reconciled field is OMITTED entirely --
        # no external review was ever reconciled on these passes. This is
        # the normal, expected shape for a plain /orchestra:review pass.
        $internalOnlyTuples = 3100..3104 | ForEach-Object {
            $entry = New-RdEntry -Key "local-$_" -Disposition 'incorporate' -ReviewerSource 'local' -MatchStatus $null
            $body  = New-RdBody -Pr $_ -Entries @($entry) -ExternalSourcesReconciled $null
            New-PrTuple -Number $_ -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
        }

        # 2 genuinely-measured PRs (< 5): zero entries, but the PR-level
        # external_sources_reconciled field IS present -- the M9 legal
        # zero-finding coverage record. These are the ONLY PRs that should
        # count toward K after the fix.
        $genuineTuples = 3200, 3201 | ForEach-Object {
            $body = New-RdBody -Pr $_ -Entries @() -ExternalSourcesReconciled '[]'
            New-PrTuple -Number $_ -Bodies @($body) -AuthorLogins @($script:JudgeLogin)
        }

        $corpus = [PSCustomObject]@{ Tuples = @($internalOnlyTuples + $genuineTuples); Truncated = $false }

        # Value-side entries: 6 unrelated code-review/implementation catches
        # (independent catch-side N>=5 clean baseline for the overall
        # code-review escape rate) plus ONE genuine internal co-observed
        # catch on PR 3200 -- a PR that IS genuinely measured under BOTH the
        # old and the new logic, so this isolates the coverage-count
        # regression (K) as the only variable that changes; n1 is identical
        # before and after the fix.
        $catchSideEntries = 900..905 | ForEach-Object { New-CodeReviewValueEntry -PrNumber $_ }
        $n1Entry          = New-CodeReviewValueEntry -PrNumber 3200
        $valueEntries     = @($catchSideEntries) + @($n1Entry)

        $terminal = Get-PhaseContainmentTerminalObservation -Corpus $corpus -Entries $valueEntries -JudgeLogin $script:JudgeLogin -ValueCacheOk $true

        # Reader-fix assertion: only the 2 genuinely-measured PRs count
        # toward K -- the 5 internal-only markers must NOT inflate it.
        $terminal.MeasuredCoveragePRCount        | Should -Be 2
        $terminal.CoObservedPRCount              | Should -Be 7
        $terminal.InternalCoObservedCatchCount   | Should -Be 1
        $terminal.DispositionsNovelExternalCount | Should -Be 0

        $terminalObservationHash = @{
            CoObservedPRCount              = $terminal.CoObservedPRCount
            MeasuredCoveragePRCount        = $terminal.MeasuredCoveragePRCount
            DispositionsNovelExternalCount = $terminal.DispositionsNovelExternalCount
            InternalCoObservedCatchCount   = $terminal.InternalCoObservedCatchCount
            ExternalCatchCount             = $terminal.ExternalCatchCount
            DuplicateCount                 = $terminal.DuplicateCount
            ObserverEscapeCount            = 0
        }

        $rollup = Get-PhaseContainmentRollup -Entries $valueEntries -TerminalObservation $terminalObservationHash
        $stage  = $rollup.Stages['code-review']

        # The single most important assertion in this batch: with K=2 (<5),
        # the escape-side gate must fail closed on insufficient coverage --
        # it must never render ELIGIBLE off a K that was manufactured
        # entirely from internal-only markers that never reconciled against
        # an external review.
        $stage.RelaxationEligible       | Should -Not -Be $true
        $stage.RelaxationEligibleReason | Should -Match 'coverage insufficient'
        $stage.CoverageK                | Should -Be 2
        $stage.CoverageOk               | Should -Be $false
    }
    }
}

# ---------------------------------------------------------------------------
# M1 writer-contract regression guard (skills/review-judgment/SKILL.md).
# This is a documentation-only fix (the judge writes internal_match and
# external_sources_reconciled; no runtime code in this repo consumes the
# skill body directly), so its "test" is a content assertion pinning the
# writer instruction actually landed, rather than exercising a function.
# ---------------------------------------------------------------------------

Describe 'M1: review-judgment SKILL.md documents the internal_match/external_sources_reconciled writer contract (issue #854 code-review escape-detection fix pass)' {
    BeforeAll {
        $script:SkillPath = Join-Path $PSScriptRoot '..' '..' '..' 'skills' 'review-judgment' 'SKILL.md'
        $script:SkillText = Get-Content -Raw $script:SkillPath
    }

    It 'the SKILL.md file exists at the expected path' {
        Test-Path $script:SkillPath | Should -BeTrue
    }

    It 'documents a writer rule for internal_match.match_status, not just a consumer rule (DD2)' {
        $script:SkillText | Should -Match '(?m)^### `internal_match` Writer Rule'
        $script:SkillText | Should -Match 'the judge sets `internal_match\.match_status` on \*\*every\*\* external-source disposition entry'
    }

    It 'instructs emitting external_sources_reconciled even when empty (M9 legal zero-finding coverage record)' {
        $script:SkillText | Should -Match 'Emit it \*\*even when empty\*\*'
        $script:SkillText | Should -Match 'external_sources_reconciled: \[\]'
    }

    It 'bumps the disposition-recording examples to schema_version: 4 (no longer instructs schema_version: 3 as current)' {
        $script:SkillText | Should -Match 'Use `schema_version: 4` \(current emission format\)'
        $script:SkillText | Should -Match '(?m)^   schema_version: 4$'
        $script:SkillText | Should -Not -Match 'Use `schema_version: 3` \(current emission format\)'
    }
}

# ---------------------------------------------------------------------------
# Post-fix batch 4 (issue #854 s6): the M5 correction over-corrected --
# instructing the judge to ALWAYS emit external_sources_reconciled
# reconstituted the exact false-clean coverage bug #854 exists to eliminate,
# just via internal-only reviews instead of ambiguous-default matching (a
# purely internal /orchestra:review pass with real entries but no external
# reconciliation attempt was indistinguishable from a genuinely measured
# co-observed PR). This is a documentation-only fix (same posture as M1
# above): a content assertion pinning that the writer instruction is now
# correctly SCOPED to GitHub Review Mode passes, and that the field must be
# OMITTED (not emitted as []) on a purely internal-only pass.
# ---------------------------------------------------------------------------

Describe 'Post-fix batch 4: review-judgment SKILL.md scopes external_sources_reconciled emission to GitHub Review Mode (issue #854 s6)' {
    BeforeAll {
        $script:SkillPath = Join-Path $PSScriptRoot '..' '..' '..' 'skills' 'review-judgment' 'SKILL.md'
        $script:SkillText = Get-Content -Raw $script:SkillPath
    }

    It 'the SKILL.md file exists at the expected path' {
        Test-Path $script:SkillPath | Should -BeTrue
    }

    It 'references the existing GitHub Review Mode convention (skills/code-review-intake/SKILL.md) rather than inventing new terminology' {
        $script:SkillText | Should -Match 'GitHub Review Mode \(Proxy Prosecution Pipeline\)'
        $script:SkillText | Should -Match 'skills/code-review-intake/SKILL\.md.{0,40}GitHub Review Mode'
    }

    It 'scopes external_sources_reconciled emission to GitHub Review Mode passes, not every posted marker' {
        $script:SkillText | Should -Match 'only when this pass is GitHub Review Mode'
        $script:SkillText | Should -Match 'only on a GitHub Review Mode pass'
        # The old unconditional instruction must be gone -- this exact phrase
        # was the over-correction: "always emitted once per posted marker".
        $script:SkillText | Should -Not -Match 'is always emitted once per posted marker'
    }

    It 'instructs OMITTING the field entirely (not emitting external_sources_reconciled: []) on a purely internal-only pass' {
        $script:SkillText | Should -Match 'omit the field entirely'
        $script:SkillText | Should -Match 'Never emit the field on an internal-only pass, even as `\[\]`'
    }

    It 'no longer self-contradicts by pairing "always emit" with "an absent field is unmeasured" in the same breath' {
        # Before this fix, the v4-requirements paragraph said the field was
        # "always emitted once per posted marker" in one sentence, then
        # treated an absent field as a meaningful ("unmeasured PR") state in
        # the next -- an impossible branch if the field is truly always
        # emitted. The corrected text must tie "absent" to a real, reachable
        # writer behavior (an internal-only pass that never emits it).
        $script:SkillText | Should -Match 'An absent field means this pass never attempted external reconciliation'
        $script:SkillText | Should -Match 'the normal, expected state for a plain internal-only `/orchestra:review` pass'
    }
}

# ---------------------------------------------------------------------------
# Issue #842 s1 (RED): the report's honesty surface. Three sites resolve
# -JudgeLogin (script-scope :56/:60-581, the :582 unconditional forward, and
# the function-level :411 gate for direct callers), Resolve-JudgeLogin must
# never let an empty/whitespace identity flow through silently (M21), and
# matched/AuthorFilteredCount accounting must reach every aggregation layer.
# No production code exists for any of this yet -- every assertion below is
# expected to be assertion-RED (not error-RED, thanks to the stub above).
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentReportCli: function-level identity resolution gate (:411, issue #842 M4 -- direct function callers)' {
    BeforeEach {
        Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
        Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
        Mock Resolve-JudgeLogin { 'resolved-login' }
    }

    It 'invokes Resolve-JudgeLogin exactly once when called directly without -JudgeLogin' {
        Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' | Out-Null
        Should -Invoke Resolve-JudgeLogin -Times 1 -Exactly -Because (
            'a direct caller (e.g. a test or another script) that omits -JudgeLogin entirely must still get a resolved identity, not the bare hardcoded default literal.'
        )
    }

    It 'does NOT invoke Resolve-JudgeLogin when called directly WITH an explicit -JudgeLogin' {
        Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' -JudgeLogin 'explicit-login' | Out-Null
        Should -Invoke Resolve-JudgeLogin -Times 0 -Exactly -Because (
            'an explicit caller-supplied -JudgeLogin must win outright -- resolution must never override it.'
        )
    }

    It 'threads the resolved login into Get-PhaseContainmentHistory''s -JudgeLogin parameter, not the hardcoded default' {
        Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' | Out-Null
        Should -Invoke Get-PhaseContainmentHistory -Times 1 -Exactly -ParameterFilter { $JudgeLogin -eq 'resolved-login' } -Because (
            'the value-side fetch must see the resolved identity so a non-judge-authored phase-containment block is still gated correctly.'
        )
    }
}

Describe 'phase-containment-report.ps1: script-scope identity resolution gate (issue #842 M4, post-review fix)' {
    # Post-review fix (judge-sustained M4): the script-scope resolution
    # block previously ran UNCONDITIONALLY at dot-source/load time -- every
    # dot-source of this file (including this very suite's own BeforeAll,
    # before any Resolve-JudgeLogin mock existed) shelled out to a live
    # `gh api user` call. The block is now gated on the same
    # `$MyInvocation.InvocationName -ne '.'` check the auto-invoke guard at
    # the bottom of the file uses, so a mere dot-source never resolves at
    # all. These tests replace the pre-fix expectations (which asserted the
    # buggy unconditional-resolution behavior was correct) with the
    # corrected, gated behavior.
    BeforeEach {
        Mock Resolve-JudgeLogin { 'resolved-for-script-scope' }
    }

    It 'does NOT invoke Resolve-JudgeLogin when the script is merely dot-sourced without -JudgeLogin' {
        . $script:CliPath
        Should -Invoke Resolve-JudgeLogin -Times 0 -Exactly -Because (
            'dot-sourcing this file to reuse its functions (the entire purpose of the auto-invoke guard''s design, and exactly what this suite''s own BeforeAll does) must never resolve the judge identity or shell out to gh -- resolution only happens on the real pwsh -File execution path.'
        )
    }

    It 'does NOT invoke Resolve-JudgeLogin when the script is dot-sourced WITH an explicit -JudgeLogin either' {
        . $script:CliPath -JudgeLogin 'explicit-login'
        Should -Invoke Resolve-JudgeLogin -Times 0 -Exactly -Because (
            'a mere dot-source never resolves at all post-fix, regardless of whether -JudgeLogin was supplied to the dot-source call -- resolution is gated on the real-execution InvocationName check, not on ContainsKey alone.'
        )
    }

    It 'leaves script-scope $JudgeLogin at the static param() default when merely dot-sourced (no live resolution attempted)' {
        . $script:CliPath
        $JudgeLogin | Should -Be 'github-actions[bot]' -Because (
            'the script-scope resolution block never executes on a dot-source post-fix, so $JudgeLogin keeps its static default rather than acquiring a value that was never actually resolved.'
        )
    }
}

Describe 'phase-containment-report.ps1: dot-source never attempts a live gh call (issue #842 M4 fix -- proof)' {
    It 'does not invoke the gh CLI at all when the file is merely dot-sourced with no -JudgeLogin bound and no Resolve-JudgeLogin mock in place' {
        # Deliberately does NOT mock Resolve-JudgeLogin -- the whole point
        # of this proof is that the REAL Resolve-JudgeLogin function (which
        # shells out to `gh api user`) is never even CALLED during a mere
        # dot-source, so mocking the gh CLI itself (rather than the
        # wrapper function) is the tightest available assertion that no
        # live network call was attempted.
        Mock gh { throw 'gh must never be invoked by a mere dot-source of phase-containment-report.ps1' }

        { . $script:CliPath } | Should -Not -Throw

        Should -Invoke gh -Times 0 -Exactly -Because (
            'the M4 fix gates script-scope identity resolution on the real pwsh -File execution path -- dot-sourcing this file (Pester''s own BeforeAll, or any other consumer reusing its functions) must never shell out to gh api user.'
        )
    }
}

Describe 'Invoke-PhaseContainmentReportCli: JudgeLoginSource provenance override (issue #842 M1 fix -- proof)' {
    BeforeEach {
        Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
        Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
    }

    It 'labels the header "resolved from gh auth" -- never "from -JudgeLogin" -- when the caller forwards a concrete -JudgeLogin alongside -JudgeLoginSource ''resolved from gh auth'' (mirrors the script-scope auto-invoke forward)' {
        # Before the M1 fix, provenance was derived solely from
        # $PSBoundParameters.ContainsKey('JudgeLogin') -- always $true here
        # since a concrete value IS bound -- so the header always said
        # "from -JudgeLogin" even when the TRUE origin (as only the
        # script-scope auto-invoke path can know) was an auto-resolved
        # identity forwarded explicitly.
        $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' -JudgeLogin 'auto-resolved-login' -JudgeLoginSource 'resolved from gh auth'
        $joined = $output -join "`n"

        $joined | Should -Match ([regex]::Escape('identity: auto-resolved-login, resolved from gh auth'))
        $joined | Should -Not -Match 'from -JudgeLogin'
    }

    It 'still labels the header "from -JudgeLogin" when a direct caller supplies only -JudgeLogin with no -JudgeLoginSource override (unchanged direct-caller behavior)' {
        $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '' -JudgeLogin 'explicit-login'
        $joined = $output -join "`n"

        $joined | Should -Match ([regex]::Escape('identity: explicit-login, from -JudgeLogin'))
    }
}

Describe 'Resolve-JudgeLogin non-empty invariant: the CLI must fail loud, not silently disable the forgery gate (issue #842 M21)' {
    BeforeEach {
        Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
        Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
    }

    Context 'Resolve-JudgeLogin resolves to an empty string' {
        It 'throws naming -JudgeLogin instead of silently proceeding with a gate-disabling empty identity' {
            Mock Resolve-JudgeLogin { '' }
            {
                Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            } | Should -Throw -ExpectedMessage '*-JudgeLogin*' -Because (
                'an empty resolved login silently disables Test-PhaseContainmentCommentAuthoredByJudge''s gate for every body scanned -- this must fail loud, not degrade quietly, and the swallowing try/catch around Get-PhaseContainmentTerminalObservation (report.ps1:495-503) must never be the ONLY place this surfaces (a caught exception there is downgraded to a mere Write-Warning).'
            )
        }
    }

    Context 'Resolve-JudgeLogin resolves to a whitespace-only string' {
        It 'throws naming -JudgeLogin instead of silently proceeding with a gate-disabling whitespace identity' {
            Mock Resolve-JudgeLogin { '   ' }
            {
                Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            } | Should -Throw -ExpectedMessage '*-JudgeLogin*' -Because (
                'whitespace-only is the same silent-disable vector as empty -- both must be treated as a resolution failure.'
            )
        }
    }
}

Describe 'Invoke-PhaseContainmentCommentScan: matched/AuthorFilteredCount accounting (issue #842 M8, aggregation layer)' {
    BeforeAll {
        # A not-yet-existing property must read as $null under this file's
        # inherited Set-StrictMode -Version Latest (from dot-sourcing the
        # CLI script above), not throw PropertyNotFoundException -- this
        # helper is null-safe both for the missing-property case (today,
        # RED) and the present-property case (once #842 GREEN lands),
        # keeping every assertion below assertion-RED, never error-RED.
        function script:Get-PC842TestProperty {
            param([Parameter(Mandatory)][object]$InputObject, [Parameter(Mandatory)][string]$Name)
            $prop = $InputObject.PSObject.Properties[$Name]
            if ($null -eq $prop) { return $null }
            return $prop.Value
        }
    }

    It 'reports Matched and AuthorFilteredCount reflecting the author-gate split across three bodies' {
        $bodies  = @('<!-- phase-containment-1 -->', '<!-- phase-containment-1 -->', '<!-- phase-containment-1 -->')
        $authors = @('judge', 'mallory', 'mallory')

        $result = Invoke-PhaseContainmentCommentScan -CommentBodies $bodies -IssueOrPrNumber 1 -AuthorLogins $authors -JudgeLogin 'judge'

        Get-PC842TestProperty -InputObject $result -Name 'Matched'             | Should -Be 1 -Because "only the first body is authored by 'judge'; the other two must be tallied, not silently dropped by the 'continue' at :450."
        Get-PC842TestProperty -InputObject $result -Name 'AuthorFilteredCount' | Should -Be 2 -Because "the two 'mallory'-authored bodies were filtered by the author gate and must be counted, so a report consumer can distinguish 'filtered' from 'genuinely empty'."
    }

    It 'reports Matched equal to the full body count and AuthorFilteredCount=0 when no -JudgeLogin gate is supplied (unfiltered legacy behavior preserved)' {
        $bodies = @('some comment', 'another comment')

        $result = Invoke-PhaseContainmentCommentScan -CommentBodies $bodies -IssueOrPrNumber 1

        Get-PC842TestProperty -InputObject $result -Name 'Matched'             | Should -Be 2
        Get-PC842TestProperty -InputObject $result -Name 'AuthorFilteredCount' | Should -Be 0
    }
}

Describe 'structural guard: every Get-PhaseContainmentHistory return shape carries AuthorFilteredCount (issue #842 M11 -- StrictMode-safe degradation paths)' {
    It 'every return [PSCustomObject]@{...} block inside Get-PhaseContainmentHistory declares an AuthorFilteredCount key' {
        $libPath = Join-Path $PSScriptRoot '..' 'lib' 'phase-containment-rolling-history-core.ps1'
        $lines   = Get-Content $libPath

        $startIdx = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^function Get-PhaseContainmentHistory\s*\{') { $startIdx = $i; break }
        }
        $startIdx | Should -BeGreaterThan 0 -Because "Get-PhaseContainmentHistory must exist in the lib file."

        $depth  = 0
        $endIdx = $null
        for ($i = $startIdx; $i -lt $lines.Count; $i++) {
            $depth += ([regex]::Matches($lines[$i], '\{')).Count
            $depth -= ([regex]::Matches($lines[$i], '\}')).Count
            if ($depth -eq 0 -and $i -gt $startIdx) { $endIdx = $i; break }
        }
        $endIdx | Should -Not -BeNullOrEmpty -Because "the function body must have a matching closing brace."

        $body         = ($lines[$startIdx..$endIdx] -join "`n")
        $returnBlocks = [regex]::Matches($body, 'return \[PSCustomObject\]@\{[^}]*\}')

        $returnBlocks.Count | Should -BeGreaterOrEqual 8 -Because (
            "Get-PhaseContainmentHistory currently has (at least) 8 distinct early-return/degradation shapes; a future refactor must not silently drop below this floor. Found: $($returnBlocks.Count)"
        )

        $missingAuthorFilteredCount = @($returnBlocks | Where-Object { $_.Value -notmatch 'AuthorFilteredCount' })
        $missingAuthorFilteredCount.Count | Should -Be 0 -Because (
            "every return shape must carry AuthorFilteredCount so a StrictMode consumer never throws reading it off a degradation path (timeout, repo-resolution-failed, cache, partial). " +
            "$($missingAuthorFilteredCount.Count) of $($returnBlocks.Count) return blocks are missing it."
        )
    }
}

Describe 'structural guard: Get-PhaseContainmentHistory''s default CachePath includes the identity component of the cache key (issue #842, cache poisoning across judge identities)' {
    # Get-PhaseContainmentHistory calls its own cache helpers via explicit
    # script:-qualified names (script:Read-PhaseContainmentCache,
    # script:Get-SurfaceAEntriesGraphQL, etc.) -- a scope-qualified call site
    # resolves directly against the PowerShell scope table and is not
    # observable through Pester's ordinary command-shadowing Mock mechanism,
    # so a behavioral round-trip test through the live fetch path is neither
    # reliable nor fast (it falls through to a real, slow `gh` network call
    # instead of the intended mock). This structural check pins the same
    # requirement -- the identity component of the cache key -- without
    # depending on that unreliable interception.
    It 'the default CachePath construction interpolates $JudgeLogin, not just $RepoOwner/$RepoName' {
        $libPath       = Join-Path $PSScriptRoot '..' 'lib' 'phase-containment-rolling-history-core.ps1'
        $lines         = Get-Content $libPath
        $cachePathLine = $lines | Where-Object { $_ -match '\$CachePath\s*=\s*Join-Path' }

        $cachePathLine | Should -Not -BeNullOrEmpty -Because "the default CachePath construction line must exist in Get-PhaseContainmentHistory."
        $cachePathLine | Should -Match '\$JudgeLogin' -Because (
            "today's default CachePath is keyed only on `$RepoOwner/`$RepoName ('.phase-containment-cache-{owner}-{repo}.json') -- identical for every judge identity, " +
            "so a later run under a DIFFERENT -JudgeLogin silently reads back cache entries computed and author-filtered under a PRIOR identity (cache poisoning across judge identities). " +
            "The cache key must also vary with `$JudgeLogin.`nActual line:`n$cachePathLine"
        )
    }
}
