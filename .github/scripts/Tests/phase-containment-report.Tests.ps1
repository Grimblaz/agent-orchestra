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
