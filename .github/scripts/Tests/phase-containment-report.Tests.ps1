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
            Mock Get-PhaseContainmentCommentCorpus { throw 'simulated corpus fetch failure' }

            $output = Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token ''
            $joined = $output -join "`n"

            $joined | Should -Match 'Phase-Containment Escape-Rate Ledger'
            $joined | Should -Match 'Stage: code-review'
            $joined | Should -Match 'cost section unavailable: simulated corpus fetch failure'
            # The degraded cost path must not print the normal cost section header.
            $joined | Should -Not -Match 'Review Cost \(presentation-only\)'
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

    Context 'AC3: presentation-only value-block byte-identical regression (issue #768 s6, judge-sustained M5 -- load-bearing)' {
        BeforeEach {
            Mock Get-PhaseContainmentHistory { New-FixedHistoryResult }
        }

        It 'renders a byte-identical value-block region whether the cost path succeeds or is entirely absent, holding FetchedAt and cache mode constant' {
            # Independently compute the expected value block via the exact
            # same (mocked, fixed) inputs the CLI function uses -- this is
            # the pin's ground truth, not a second call to the CLI itself.
            $expectedRollup = Get-PhaseContainmentRollup -Entries $script:FixedEntries -WindowLabel '90d' -Truncated:$false
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

            # Run 1: cost path present and succeeding.
            Mock Get-PhaseContainmentCommentCorpus { New-FixedCorpusResult }
            $withCost = @(Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '')

            # Run 2: cost path entirely absent/failing (mocked-absent).
            Mock Get-PhaseContainmentCommentCorpus { throw 'cost fixture intentionally absent' }
            $withoutCost = @(Invoke-PhaseContainmentReportCli -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -WindowDays 90 -Token '')

            $withCost.Count | Should -BeGreaterOrEqual $n
            $withoutCost.Count | Should -BeGreaterOrEqual $n

            $withCostValueBlock = $withCost[0..($n - 1)]
            $withoutCostValueBlock = $withoutCost[0..($n - 1)]

            # Byte-for-byte (line-for-line) comparison of the value-block
            # region only -- the trailing content legitimately differs (the
            # cost section vs. the degradation line), which is expected and
            # is NOT part of this pin.
            for ($i = 0; $i -lt $n; $i++) {
                $withCostValueBlock[$i] | Should -BeExactly $expectedValueBlock[$i]
                $withoutCostValueBlock[$i] | Should -BeExactly $expectedValueBlock[$i]
            }
        }
    }
}

Describe 'structural guard: RelaxationEligible computation path never receives a cost-related parameter (issue #768 s6)' {
    It 'the CLI file''s Get-PhaseContainmentRollup call site passes only value-path parameters' {
        $cliText = Get-Content -Raw $script:CliPath
        $rollupCallLine = ($cliText -split "`r?`n") | Where-Object { $_ -match 'Get-PhaseContainmentRollup\s+-Entries' }

        $rollupCallLine | Should -Not -BeNullOrEmpty
        $rollupCallLine | Should -Not -Match '(?i)cost'
    }
}
