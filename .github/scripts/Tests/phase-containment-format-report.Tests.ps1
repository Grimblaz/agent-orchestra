#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for Format-PhaseContainmentReport (issue #772, D5b).
#
# File under test: .github/scripts/lib/phase-containment-rolling-history-core.ps1
#   (Format-PhaseContainmentReport, Get-PhaseContainmentRollup)
#
# This spec gates the production renderer directly — it calls the real
# Get-PhaseContainmentRollup + Format-PhaseContainmentReport functions, not a
# re-implementation. It replaces the retired standalone harness
# Tests/Invoke-CEGate762.ps1, whose inline copy of the display logic had
# drifted from production (its DataUntrustworthy branch rendered
# "N/A (data untrustworthy)" and was never reachable by its own fixtures —
# it never passed -SustainedCounts to Get-PhaseContainmentRollup).
#
# Fixture entries mirror the retired harness's four scenario buckets:
#   code-review      : 4 entries (n=4 < 5)   -> INSUFFICIENT DATA        (AC8)
#   plan-stress-test : 6 clean entries (n=6)  -> EscapeRate=0, ELIGIBLE   (AC3/AC4)
#   design-challenge : 7 entries, 2 escaped   -> EscapeRate~0.29, NOT ELIGIBLE (AC4/AC12)
#   experience-catchable : 1 entry            -> leakage matrix only, no stage bucket
#
# NOTE: Do NOT import powershell-yaml or use ConvertFrom-Yaml in this file.

BeforeAll {
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'
    . (Join-Path $script:LibRoot 'phase-containment-rolling-history-core.ps1')
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    function script:New-PC772FixtureEntries {
        # Issue #842 s1: -OmitCodeReview drops the code-review bucket
        # entirely (code-review stage N=0 -> DenominatorZero) while leaving
        # the plan-stress-test and design-challenge buckets untouched, so
        # the four-state render-discrimination tests can exercise a single
        # zero'd stage alongside two normally-rendering stages in the SAME
        # report -- proving the new states don't leak across stages. Purely
        # additive: the no-args call below is byte-identical to before, so
        # every pre-existing pinned count/assertion is unaffected.
        param([switch]$OmitCodeReview)

        $entries = [System.Collections.Generic.List[hashtable]]::new()

        # code-review bucket (catchable_phase=implementation, n=4 -> InsufficientData)
        if (-not $OmitCodeReview) {
            foreach ($pair in @(
                @{ key = 'code-review:4832813258'; intro = 'design';         sev = 'high';   fix = 'instruction'; cat = 'pattern'               },
                @{ key = 'code-review:4832813940'; intro = 'implementation'; sev = 'medium'; fix = 'instruction'; cat = 'implementation-clarity' },
                @{ key = 'code-review:4832814488'; intro = 'plan';           sev = 'medium'; fix = 'skill';       cat = 'documentation-audit'   },
                @{ key = 'code-review:4832815057'; intro = 'design';         sev = 'medium'; fix = 'instruction'; cat = 'documentation-audit'   }
            )) {
                $entries.Add(@{
                    finding_key       = $pair.key
                    introduced_phase  = $pair.intro
                    catchable_phase   = 'implementation'
                    caught_stage      = 'code-review'
                    escape_distance   = 0
                    severity          = $pair.sev
                    systemic_fix_type = $pair.fix
                    category          = $pair.cat
                    apparatus_meta    = $false
                })
            }
        }

        # plan-stress-test bucket (catchable_phase=plan, n=6, all escape_distance=0 -> RelaxationEligible)
        for ($i = 1; $i -le 6; $i++) {
            $entries.Add(@{
                finding_key       = "plan-stress-test:772:plan-issue-772:P$i"
                introduced_phase  = 'design'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
            })
        }

        # design-challenge bucket (catchable_phase=design, n=7, 2 escaped -> EscapeRate~0.286)
        # 5 caught at design-challenge (escape_distance=0)
        for ($i = 1; $i -le 5; $i++) {
            $entries.Add(@{
                finding_key       = "design-challenge:772:design-phase-complete-772:F$i"
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'design-challenge'
                escape_distance   = 0
                severity          = 'low'
                systemic_fix_type = 'none'
                category          = 'pattern'
                apparatus_meta    = $false
            })
        }
        # 2 escaped design-challenge, caught at code-review (escape_distance=2)
        for ($i = 1; $i -le 2; $i++) {
            $entries.Add(@{
                finding_key       = "code-review:772:escaped-design-$i"
                introduced_phase  = 'design'
                catchable_phase   = 'design'
                caught_stage      = 'code-review'
                escape_distance   = 2
                severity          = 'high'
                systemic_fix_type = 'skill'
                category          = 'architecture'
                apparatus_meta    = $false
            })
        }

        # experience-catchable (leakage matrix only, no stage bucket)
        $entries.Add(@{
            finding_key       = 'code-review:772:experience-catchable-1'
            introduced_phase  = 'experience'
            catchable_phase   = 'experience'
            caught_stage      = 'code-review'
            escape_distance   = 3
            severity          = 'low'
            systemic_fix_type = 'skill'
            category          = 'pattern'
            apparatus_meta    = $false
        })

        return $entries.ToArray()
    }

    function script:New-PC772Context {
        param(
            [Parameter(Mandatory)][object]$Rollup,
            [bool]$Truncated = $false,
            [int]$InvalidEntryCount = 0,
            # Issue #842 s1: the always-on judge-filter disclosure fields.
            # Matched/CommentBodyCount/AuthorFilteredCount are window-level
            # (computed once per fetch, not per-stage) and feed both the
            # always-on header disclosure and the four-state
            # DenominatorZero-branch discrimination (FILTERED-EMPTY /
            # INVALID-EMPTY / genuinely-empty / N==0). Defaults (all 0,
            # default identity) are inert no-ops for every pre-existing
            # test in this file that does not pass them.
            [int]$Matched = 0,
            [int]$CommentBodyCount = 0,
            [int]$AuthorFilteredCount = 0,
            [string]$JudgeLogin = 'github-actions[bot]',
            [string]$JudgeLoginSource = 'resolved from gh auth'
        )
        return @{
            Rollup              = $Rollup
            Source              = 'graphql'
            Truncated           = $Truncated
            WindowDays          = 90
            FetchedAt           = [datetime]::new(2026, 7, 10, 0, 0, 0, [DateTimeKind]::Utc)
            InvalidEntryCount   = $InvalidEntryCount
            Matched             = $Matched
            CommentBodyCount    = $CommentBodyCount
            AuthorFilteredCount = $AuthorFilteredCount
            JudgeLogin          = $JudgeLogin
            JudgeLoginSource    = $JudgeLoginSource
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Production render against fixture rollup (AC3/AC4/AC8/AC12)
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — production render (AC3/AC4/AC8/AC12)' {
    BeforeAll {
        $script:Rollup     = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d'
        $script:Context    = New-PC772Context -Rollup $script:Rollup
        $script:ReportText = (Format-PhaseContainmentReport -Context $script:Context) -join "`n"
    }

    It 'renders INSUFFICIENT DATA escape rate for the code-review stage with n=4 (AC8)' {
        $script:ReportText.Contains('Escape rate:        INSUFFICIENT DATA (n=4 < 5)') | Should -BeTrue -Because (
            "code-review has only 4 non-apparatus entries, below the n>=5 statistical floor.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders WITHHELD (n<5) as the relaxation signal for the code-review stage (AC8)' {
        $script:ReportText.Contains('Relaxation signal:  WITHHELD (n<5)') | Should -BeTrue -Because (
            "an insufficient-data stage must withhold its relaxation signal.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders a 0.00 escape rate for the plan-stress-test stage with 0 of 6 escaped (AC4)' {
        $script:ReportText.Contains('Escape rate:        0.00 (0 of 6 escaped)') | Should -BeTrue -Because (
            "all 6 plan-stress-test fixture entries have escape_distance=0.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders ELIGIBLE as the relaxation signal for the plan-stress-test stage (AC3)' {
        $script:ReportText.Contains('Relaxation signal:  ELIGIBLE (escape_rate ~0, no critical/high findings)') | Should -BeTrue -Because (
            "plan-stress-test is clean (n=6, escape_rate=0, no critical severity).`nActual report:`n$script:ReportText"
        )
    }

    It 'renders a 0.29 escape rate for the design-challenge stage with 2 of 7 escaped (AC4/AC12)' {
        $script:ReportText.Contains('Escape rate:        0.29 (2 of 7 escaped)') | Should -BeTrue -Because (
            "2 of the 7 design-challenge fixture entries escaped to code-review.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders NOT ELIGIBLE as the relaxation signal for the design-challenge stage (AC4/AC12)' {
        $script:ReportText.Contains('Relaxation signal:  NOT ELIGIBLE (escape_rate > 0)') | Should -BeTrue -Because (
            "design-challenge escape_rate (~0.29) is above the 0.05 relaxation threshold.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders the leakage matrix header (AC12)' {
        $script:ReportText.Contains('Leakage matrix (introduced x caught combinations):') | Should -BeTrue -Because (
            "the fixture has entries in the window so the leakage matrix must render, not the empty-window fallback.`nActual report:`n$script:ReportText"
        )
    }

    It 'renders the per-stage denominators for all three stages (AC12)' {
        $script:ReportText.Contains('Denominator (catchable=implementation): 4') | Should -BeTrue -Because "code-review denominator must equal n=4.`nActual report:`n$script:ReportText"
        $script:ReportText.Contains('Denominator (catchable=plan): 6') | Should -BeTrue -Because "plan-stress-test denominator must equal n=6.`nActual report:`n$script:ReportText"
        $script:ReportText.Contains('Denominator (catchable=design): 7') | Should -BeTrue -Because "design-challenge denominator must equal n=7.`nActual report:`n$script:ReportText"
    }

    It 'renders the code-review escape-side arm as NOT ASSESSABLE (terminal observation unavailable) when no -TerminalObservation was supplied (issue #854 s6, M21)' {
        # This rollup (BeforeAll above) was built with NO -TerminalObservation
        # argument, so it defaults to $null -- the escape-side arm must
        # still render its own honest, independent state even though the
        # catch side above it already short-circuited to WITHHELD (n<5).
        $script:ReportText.Contains('Escape-side (post-review observer):') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        $script:ReportText.Contains('Coverage:           NOT ASSESSABLE (terminal observation unavailable — escape-side coverage was not measured)') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
    }
}

# ---------------------------------------------------------------------------
# 4b. Catch-side veto render names counts and severity (issue #854 M4) --
#     judge-sustained finding against the shipped #854 implementation. AC4
#     requires "critical/high catches render as an explicit veto naming
#     counts and severity"; the pre-fix render was a bare
#     "critical severity finding in window" guess with no counts, and the
#     veto logic itself checked only 'critical', silently letting a
#     sustained 'high'-only window render ELIGIBLE.
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — catch-side veto names counts and severity (issue #854 M4)' {
    BeforeAll {
        function script:New-PC854PlanEntry {
            param(
                [Parameter(Mandatory)][string]$FindingKey,
                [string]$Severity = 'low'
            )
            return @{
                finding_key       = $FindingKey
                introduced_phase  = 'plan'
                catchable_phase   = 'plan'
                caught_stage      = 'plan-stress-test'
                escape_distance   = 0
                severity          = $Severity
                systemic_fix_type = 'instruction'
                category          = 'architecture'
                apparatus_meta    = $false
            }
        }
    }

    Context 'high-only window (no criticals) -- the live bug this fix closes' {
        BeforeAll {
            $entries = @(
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4:F1' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4:F2' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4:F3' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4:F4' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4:F5' -Severity 'high'
            )
            $script:Rollup     = Get-PhaseContainmentRollup -Entries $entries -WindowLabel '90d'
            $script:ReportText = (Format-PhaseContainmentReport -Context (New-PC772Context -Rollup $script:Rollup)) -join "`n"
        }

        It 'blocks eligibility and names 0 critical, 1 high in the veto line' {
            $script:ReportText.Contains('ELIGIBLE (escape_rate ~0, no critical/high findings)') | Should -BeFalse -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('Relaxation signal:  NOT ELIGIBLE (0 critical, 1 high severity finding(s) in window)') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }
    }

    Context 'critical-only window' {
        BeforeAll {
            $entries = @(
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4c:F1' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4c:F2' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4c:F3' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4c:F4' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4c:F5' -Severity 'critical'
            )
            $script:Rollup     = Get-PhaseContainmentRollup -Entries $entries -WindowLabel '90d'
            $script:ReportText = (Format-PhaseContainmentReport -Context (New-PC772Context -Rollup $script:Rollup)) -join "`n"
        }

        It 'blocks eligibility and names 1 critical, 0 high in the veto line' {
            $script:ReportText.Contains('Relaxation signal:  NOT ELIGIBLE (1 critical, 0 high severity finding(s) in window)') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }
    }

    Context 'mixed critical and high window' {
        BeforeAll {
            $entries = @(
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4m:F1' -Severity 'low'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4m:F2' -Severity 'critical'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4m:F3' -Severity 'critical'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4m:F4' -Severity 'high'
                script:New-PC854PlanEntry -FindingKey 'plan-stress-test:854:M4m:F5' -Severity 'low'
            )
            $script:Rollup     = Get-PhaseContainmentRollup -Entries $entries -WindowLabel '90d'
            $script:ReportText = (Format-PhaseContainmentReport -Context (New-PC772Context -Rollup $script:Rollup)) -join "`n"
        }

        It 'blocks eligibility and names 2 critical, 1 high in the veto line' {
            $script:ReportText.Contains('Relaxation signal:  NOT ELIGIBLE (2 critical, 1 high severity finding(s) in window)') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Code-review two-arm render restructure (issue #854 s6, M21) -- the
#    escape-side (post-review-observer) arm renders independently of the
#    catch-side branch, with its own honest per-state text. Also exercises
#    the reason-ladder extension (issue #854 s6, item 3): RelaxationEligibleReason
#    is checked BEFORE the generic escape_rate/critical-severity guess, so a
#    coverage/reconciliation/unique-catch-rate downgrade renders its real
#    reason at the row level too.
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — code-review escape-side arm (issue #854 s6, M21)' {
    BeforeAll {
        function script:New-PC854CleanCodeReviewEntries {
            param([int]$Count = 5)
            $entries = [System.Collections.Generic.List[hashtable]]::new()
            for ($i = 1; $i -le $Count; $i++) {
                $entries.Add(@{
                        finding_key       = "code-review:854:clean:F$i"
                        introduced_phase  = 'implementation'
                        catchable_phase   = 'implementation'
                        caught_stage      = 'code-review'
                        escape_distance   = 0
                        severity          = 'low'
                        systemic_fix_type = 'instruction'
                        category          = 'implementation-clarity'
                        apparatus_meta    = $false
                    })
            }
            return $entries.ToArray()
        }

        function script:New-PC854ObserverEntries {
            param([int]$Count = 2)
            $entries = [System.Collections.Generic.List[hashtable]]::new()
            for ($i = 1; $i -le $Count; $i++) {
                $entries.Add(@{
                        finding_key       = "post-review-observer:854:854:O$i"
                        introduced_phase  = 'implementation'
                        catchable_phase   = 'implementation'
                        caught_stage      = 'post-review-observer'
                        escape_distance   = 1
                        severity          = 'medium'
                        systemic_fix_type = 'instruction'
                        category          = 'implementation-clarity'
                        apparatus_meta    = $false
                    })
            }
            return $entries.ToArray()
        }
    }

    Context 'coverage insufficient (CE Gate S1: renders NOT ASSESSABLE with its reason, never ELIGIBLE)' {
        BeforeAll {
            # n=5 clean catch-side entries -- deliberately NOT n<5, so the
            # code-review row does not short-circuit to "WITHHELD (n<5)"
            # before ever reaching the reason ladder (the exact masking CE
            # Gate S1 calls out).
            $script:Rollup = Get-PhaseContainmentRollup -Entries (New-PC854CleanCodeReviewEntries -Count 5) -WindowLabel '90d' -TerminalObservation @{
                CoObservedPRCount       = 10
                MeasuredCoveragePRCount = 2
            }
            $script:ReportText = (Format-PhaseContainmentReport -Context (New-PC772Context -Rollup $script:Rollup)) -join "`n"
        }

        It 'never renders ELIGIBLE for the code-review row' {
            @($script:ReportText -split "`n" | Where-Object { $_ -match '^Stage: code-review' }).Count | Should -Be 1
            $script:ReportText.Contains('ELIGIBLE (escape_rate ~0, no critical/high findings)') | Should -BeFalse -Because "Actual report:`n$script:ReportText"
        }

        It 'renders the coverage-insufficient reason at the row level, not the generic critical-severity guess (issue #854 s6, reason-ladder extension)' {
            $script:ReportText.Contains('Relaxation signal:  WITHHELD (coverage insufficient: 2 of 10 co-observed PRs measured (need >=5))') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('critical severity finding in window') | Should -BeFalse -Because "Actual report:`n$script:ReportText"
        }

        It 'renders the escape-side arm as NOT ASSESSABLE (coverage insufficient) with K of N' {
            $script:ReportText.Contains('Coverage:           2 of 10 co-observed PRs measured (need >=5)') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('Escape-side signal: NOT ASSESSABLE (coverage insufficient)') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }
    }

    Context 'escape-arm reconciliation failure' {
        BeforeAll {
            # 1 emitted observer block (from $Entries) vs 3 dispositions-
            # recorded novel findings (caller-supplied) -- a real mismatch.
            $entries = @(New-PC854CleanCodeReviewEntries -Count 5) + @(New-PC854ObserverEntries -Count 1)
            $script:Rollup = Get-PhaseContainmentRollup -Entries $entries -WindowLabel '90d' -TerminalObservation @{
                CoObservedPRCount              = 10
                MeasuredCoveragePRCount        = 5
                DispositionsNovelExternalCount = 3
            }
            $script:ReportText = (Format-PhaseContainmentReport -Context (New-PC772Context -Rollup $script:Rollup)) -join "`n"
        }

        It 'renders the escape-side arm as NOT ASSESSABLE with the reconciliation mismatch counts' {
            $script:ReportText.Contains('Escape-side signal: NOT ASSESSABLE (escape-arm reconciliation failed: 3 dispositions-recorded novel finding(s) vs 1 emitted observer block(s))') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }
    }

    Context 'clean full render: coverage ok, reconciliation ok, low unique-catch rate, m=0 sparse Chapman (CE Gate S3 m=0 path)' {
        BeforeAll {
            $script:Rollup = Get-PhaseContainmentRollup -Entries (New-PC854CleanCodeReviewEntries -Count 5) -WindowLabel '90d' -TerminalObservation @{
                CoObservedPRCount              = 8
                MeasuredCoveragePRCount        = 5
                DispositionsNovelExternalCount = 0
                InternalCoObservedCatchCount   = 20
                ExternalCatchCount             = 0
                DuplicateCount                 = 0
            }
            $script:ReportText = (Format-PhaseContainmentReport -Context (New-PC772Context -Rollup $script:Rollup)) -join "`n"
        }

        It 'renders ELIGIBLE at the row level when both arms pass' {
            $script:ReportText.Contains('Relaxation signal:  ELIGIBLE (escape_rate ~0, no critical/high findings)') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }

        It 'renders the miss count, an assessable unique-catch rate, and the sparse Chapman state with the caveat' {
            $script:ReportText.Contains('Coverage:           5 of 8 co-observed PRs measured') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('Miss count (observer blocks): 0') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $expectedRate = '{0:P1}' -f 0.0
            $script:ReportText.Contains("Unique-catch rate:  $expectedRate") | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('Chapman (both-missed est.): overlap too sparse') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('Caveat: this is a lower-bound, correlated-blind-spot estimate') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }
    }

    Context 'full render with an estimable Chapman value (CE Gate S3 m>=1 path)' {
        BeforeAll {
            $entries = @(New-PC854CleanCodeReviewEntries -Count 5) + @(New-PC854ObserverEntries -Count 2)
            $script:Rollup = Get-PhaseContainmentRollup -Entries $entries -WindowLabel '90d' -TerminalObservation @{
                CoObservedPRCount              = 8
                MeasuredCoveragePRCount        = 5
                DispositionsNovelExternalCount = 2
                InternalCoObservedCatchCount   = 9
                ExternalCatchCount             = 4
                DuplicateCount                 = 2
            }
            $script:ReportText = (Format-PhaseContainmentReport -Context (New-PC772Context -Rollup $script:Rollup)) -join "`n"
        }

        It 'renders a numeric Chapman both-missed estimate and its caveat, independent of the catch-side verdict' {
            # Catch side is NOT ELIGIBLE here (the 2 observer entries are
            # themselves catch-side escapes too), which is exactly the
            # point of M21: the escape-side arm below renders its own full,
            # independent state regardless.
            $script:ReportText.Contains('Relaxation signal:  NOT ELIGIBLE (escape_rate > 0)') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('Miss count (observer blocks): 2') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $expectedChapman = '{0:F1}' -f 4.666666666666667
            $script:ReportText.Contains("Chapman (both-missed est.): $expectedChapman") | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('Caveat: this is a lower-bound, correlated-blind-spot estimate') | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }
    }

    Context 'G-CR4 regression: assessed-high escape-side unique-catch rate renders NOT ELIGIBLE, not WITHHELD' {
        BeforeAll {
            # Catch side stays clean (5 escape_distance=0 code-review entries,
            # no critical/high severity, no real post-review-observer $Entries
            # -- so RelaxationEligible starts $true from the catch-side pass).
            # ObserverEscapeCount is supplied directly (overriding the
            # $Entries-derived default, per this function's own documented
            # contract) so the unique-catch rate computation alone is what
            # flips RelaxationEligible to $false: 2 / (3 + 2) = 40% >= 5%.
            # Reconciliation passes (DispositionsNovelExternalCount=0 matches
            # the zero observer blocks actually present in $Entries), so this
            # is a genuinely MEASURED high escape rate, not an unavailable
            # assessment -- before the G-CR4 fix this rendered as the
            # misleading generic "WITHHELD (escape-side unique-catch rate too
            # high (40.0% >= 5%))".
            $script:Rollup = Get-PhaseContainmentRollup -Entries (New-PC854CleanCodeReviewEntries -Count 5) -WindowLabel '90d' -TerminalObservation @{
                CoObservedPRCount              = 8
                MeasuredCoveragePRCount        = 5
                DispositionsNovelExternalCount = 0
                InternalCoObservedCatchCount   = 3
                ExternalCatchCount             = 0
                DuplicateCount                 = 0
                ObserverEscapeCount            = 2
            }
            $script:ReportText = (Format-PhaseContainmentReport -Context (New-PC772Context -Rollup $script:Rollup)) -join "`n"
        }

        It 'renders the row-level NOT ELIGIBLE headline with the measured rate, not WITHHELD' {
            $expectedRate = '{0:P1}' -f 0.4
            $script:ReportText.Contains("Relaxation signal:  NOT ELIGIBLE (escape-side unique-catch rate too high ($expectedRate >= 5%))") | Should -BeTrue -Because "Actual report:`n$script:ReportText"
            $script:ReportText.Contains('Relaxation signal:  WITHHELD (escape-side unique-catch rate too high') | Should -BeFalse -Because "Actual report:`n$script:ReportText"
        }

        It 'still renders the escape-side arm detail (unique-catch rate) unchanged' {
            $expectedRate = '{0:P1}' -f 0.4
            $script:ReportText.Contains("Unique-catch rate:  $expectedRate") | Should -BeTrue -Because "Actual report:`n$script:ReportText"
        }
    }
}

# ---------------------------------------------------------------------------
# 2. DataUntrustworthy branch — exercised for real via -SustainedCounts
#    mismatch (previously unreachable in the retired harness, which never
#    passed -SustainedCounts to Get-PhaseContainmentRollup).
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — DataUntrustworthy branch (SustainedCounts mismatch)' {
    BeforeAll {
        # Deliberate mismatch: the design-challenge fixture bucket has exactly
        # 7 non-apparatus entries (see New-PC772FixtureEntries); 99 is wrong
        # on purpose so DataUntrustworthy fires for real, not by assumption.
        $script:MismatchedRollup = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d' -SustainedCounts @{ 'design-challenge' = 99 }
        $script:MismatchedContext    = New-PC772Context -Rollup $script:MismatchedRollup
        $script:MismatchedReportText = (Format-PhaseContainmentReport -Context $script:MismatchedContext) -join "`n"
    }

    It 'sets DataUntrustworthy on the design-challenge stage when SustainedCounts disagrees with the observed count' {
        $script:MismatchedRollup.Stages['design-challenge'].DataUntrustworthy | Should -BeTrue -Because (
            'the fixture has 7 non-apparatus design-challenge entries but SustainedCounts asserts 99, so the completeness reconciliation must fail closed.'
        )
    }

    It 'renders the DATA UNTRUSTWORTHY banner with the entry-count-mismatch reason' {
        $script:MismatchedReportText.Contains('DATA UNTRUSTWORTHY -- relaxation signal withheld (entry count mismatch)') | Should -BeTrue -Because (
            "Actual report:`n$script:MismatchedReportText"
        )
        $script:MismatchedReportText.Contains("Reason: Entry count mismatch: expected 99 sustained findings for 'design-challenge', observed 7.") | Should -BeTrue -Because (
            "Actual report:`n$script:MismatchedReportText"
        )
    }

    It 'renders WITHHELD (data untrustworthy) as the relaxation signal' {
        $script:MismatchedReportText.Contains('Relaxation signal:  WITHHELD (data untrustworthy)') | Should -BeTrue -Because (
            "Actual report:`n$script:MismatchedReportText"
        )
    }

    It 'renders the actual computed escape-rate percentage, not the retired harness''s drifted N/A text' {
        # Production computes EscapeRate before checking DataUntrustworthy, so
        # a stage with n>=5 still has a real rate to show. The retired
        # Invoke-CEGate762.ps1 harness rendered a hardcoded "N/A (data
        # untrustworthy)" here — that text never reflected production.
        #
        # M8 fix (issue #772/#831 post-fix review): compute the expected
        # percentage with production's own culture-sensitive '{0:P1}' format
        # call (same as phase-containment-rolling-history-core.ps1's
        # DataUntrustworthy-branch escapeDisplay) instead of a hardcoded
        # en-US literal, so this assertion stays self-consistent on
        # non-en-US CI runners where '{0:P1}' renders with a different
        # decimal separator / percent-symbol placement.
        $expectedEscapeDisplay = '{0:P1}' -f $script:MismatchedRollup.Stages['design-challenge'].EscapeRate
        $script:MismatchedReportText.Contains("Escape rate:        $expectedEscapeDisplay") | Should -BeTrue -Because (
            "production formats the untrustworthy-branch rate as a percentage (P1 format) when EscapeRate is non-null.`nActual report:`n$script:MismatchedReportText"
        )
        $script:MismatchedReportText.Contains('N/A (data untrustworthy)') | Should -BeFalse -Because (
            "this is the retired harness's drifted literal; production never renders it when EscapeRate is available.`nActual report:`n$script:MismatchedReportText"
        )
    }
}

# ---------------------------------------------------------------------------
# 3. Truncated-path render — header suffix + per-stage withholding
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — truncated-path render' {
    BeforeAll {
        $script:TruncatedRollup     = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d' -Truncated
        $script:TruncatedContext    = New-PC772Context -Rollup $script:TruncatedRollup -Truncated $true
        $script:TruncatedReportText = (Format-PhaseContainmentReport -Context $script:TruncatedContext) -join "`n"
    }

    It 'renders the (TRUNCATED — results incomplete) header suffix' {
        $script:TruncatedReportText.Contains('(TRUNCATED — results incomplete)') | Should -BeTrue -Because (
            "Actual report:`n$script:TruncatedReportText"
        )
    }

    It 'renders WITHHELD (fetch truncated) for a stage that would otherwise be NOT ELIGIBLE' {
        # design-challenge would render "NOT ELIGIBLE (escape_rate > 0)" when
        # not truncated (see the first Describe block); a truncated fetch
        # must override that with the fail-closed truncation withholding.
        $script:TruncatedReportText.Contains('Relaxation signal:  WITHHELD (fetch truncated)') | Should -BeTrue -Because (
            "Actual report:`n$script:TruncatedReportText"
        )
        $script:TruncatedReportText.Contains('NOT ELIGIBLE (escape_rate > 0)') | Should -BeFalse -Because (
            "a truncated corpus must never present the design-challenge stage as a confident NOT ELIGIBLE verdict.`nActual report:`n$script:TruncatedReportText"
        )
    }

    It 'renders WITHHELD (fetch truncated) for a stage that would otherwise be ELIGIBLE' {
        # plan-stress-test would render "ELIGIBLE (escape_rate ~0, no critical
        # findings)" when not truncated; truncation must not let a clean-
        # looking stage present a relaxation signal either.
        $script:TruncatedReportText.Contains('ELIGIBLE (escape_rate ~0, no critical/high findings)') | Should -BeFalse -Because (
            "a truncated corpus must never present a clean relaxation signal, even for a stage whose visible data looks clean.`nActual report:`n$script:TruncatedReportText"
        )
    }
}

# ---------------------------------------------------------------------------
# 4. InvalidEntryCount warning render
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — InvalidEntryCount warning render' {
    BeforeAll {
        $script:BaselineRollup = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d'
    }

    It 'renders the WARNING line when InvalidEntryCount is nonzero' {
        $context     = New-PC772Context -Rollup $script:BaselineRollup -InvalidEntryCount 3
        $reportText  = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $reportText.Contains('WARNING: 3 phase-containment block(s) dropped as invalid/unparseable during this fetch — re-run this command locally to inspect the dropped comment bodies.') | Should -BeTrue -Because (
            "Actual report:`n$reportText"
        )
    }

    It 'omits the WARNING line when InvalidEntryCount is zero' {
        $context    = New-PC772Context -Rollup $script:BaselineRollup -InvalidEntryCount 0
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $reportText.Contains('phase-containment block(s) dropped as invalid/unparseable') | Should -BeFalse -Because (
            "a clean fetch must not render the invalid-entry warning.`nActual report:`n$reportText"
        )
    }
}

# ---------------------------------------------------------------------------
# Issue #842 s1 (RED): four-state DenominatorZero-branch discrimination,
# branch precedence, and always-on judge-filter disclosure. None of Matched/
# CommentBodyCount/AuthorFilteredCount/JudgeLogin/JudgeLoginSource are
# consulted by production Format-PhaseContainmentReport yet -- every
# assertion below is expected to be assertion-RED against today's generic
# "WITHHELD (denominator=0)" / no-header-disclosure render.
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — four-state DenominatorZero discrimination (issue #842 M7/M9)' {
    BeforeAll {
        function script:Get-PC842StageBlock {
            # Extracts a single stage's own rendered block (from its "Stage:
            # {name}" line up to, but not including, the next "Stage:" line
            # or the leakage-matrix header) so state-discrimination
            # assertions stay scoped to the stage under test and cannot be
            # satisfied by text belonging to a DIFFERENT stage's block.
            param([Parameter(Mandatory)][string]$ReportText, [Parameter(Mandatory)][string]$StageName)
            $allLines   = $ReportText -split "`n"
            $startIdx   = ($allLines | Select-String -Pattern "^Stage: $StageName$" | Select-Object -First 1).LineNumber
            if ($null -eq $startIdx) { return '' }
            $startIdx = $startIdx - 1
            $endIdx = $allLines.Count - 1
            for ($i = $startIdx + 1; $i -lt $allLines.Count; $i++) {
                if ($allLines[$i] -match '^Stage: ' -or $allLines[$i] -match '^Leakage matrix') {
                    $endIdx = $i - 1
                    break
                }
            }
            return ($allLines[$startIdx..$endIdx] -join "`n")
        }

        # code-review stage is zero'd (N=0 -> DenominatorZero); plan-stress-
        # test (n=6) and design-challenge (n=7) render normally alongside
        # it, so these tests also prove the new states don't leak across
        # stages.
        #
        # NOTE (issue #842 M3 post-review fix): this rollup's WINDOW is NOT
        # empty overall (design-challenge and plan-stress-test both carry
        # real entries) -- only the code-review STAGE is zero'd. That makes
        # this fixture the exact M3 boundary case: a stage that is empty
        # from DATA ABSENCE (a sibling stage has the real entries), not from
        # every parsed block failing validation. Use $script:FullyEmptyRollup
        # below for the true-positive INVALID-EMPTY / WITHHELD-detail cases
        # (window genuinely has zero entries anywhere).
        $script:ZeroedRollup = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries -OmitCodeReview) -WindowLabel '90d'

        # A window with ZERO entries in every stage (WindowEntryCount -eq 0)
        # -- the only shape where INVALID-EMPTY / WITHHELD-detail are
        # legitimately about THIS stage's own data, not a sibling's.
        $script:FullyEmptyRollup = Get-PhaseContainmentRollup -Entries @() -WindowLabel '90d'
    }

    It 'renders FILTERED-EMPTY when the judge filter matched 0 bodies but some were author-filtered' {
        $context = New-PC772Context -Rollup $script:ZeroedRollup -Matched 0 -CommentBodyCount 5 -AuthorFilteredCount 5 -JudgeLogin 'alice'
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

        $codeReviewBlock.Contains("Relaxation signal:  FILTERED-EMPTY — judge filter matched 0 of 5 bodies (looked for 'alice'); check -JudgeLogin") | Should -BeTrue -Because (
            "a judge filter that matched zero bodies must never be indistinguishable from a genuinely-empty window.`nActual code-review block:`n$codeReviewBlock"
        )
    }

    It 'renders INVALID-EMPTY when bodies matched but every parsed block failed validation, in a window that is genuinely empty everywhere' {
        # Uses $script:FullyEmptyRollup (WindowEntryCount -eq 0), not
        # $script:ZeroedRollup -- INVALID-EMPTY is only a legitimate
        # explanation for THIS stage's own emptiness when the whole window
        # has zero entries. See the M3 Describe block below for the
        # boundary case where a sibling stage has real entries.
        $context = New-PC772Context -Rollup $script:FullyEmptyRollup -Matched 3 -CommentBodyCount 3 -AuthorFilteredCount 0 -InvalidEntryCount 2
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

        $codeReviewBlock.Contains('Relaxation signal:  INVALID-EMPTY — 3 of 3 bodies matched but every parsed block failed validation (2 dropped); see WARNINGs above') | Should -BeTrue -Because (
            "a window where every parsed block failed validation must never render as an unqualified 'nothing here' -- the WARNINGs above must be pointed to explicitly.`nActual code-review block:`n$codeReviewBlock"
        )
    }

    It 'renders WITHHELD (denominator=0) with the matched/N detail when bodies matched but none carried a phase-containment block, in a window that is genuinely empty everywhere' {
        # Uses $script:FullyEmptyRollup for the same reason as the
        # INVALID-EMPTY test immediately above.
        $context = New-PC772Context -Rollup $script:FullyEmptyRollup -Matched 4 -CommentBodyCount 4 -AuthorFilteredCount 0 -InvalidEntryCount 0
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

        $codeReviewBlock.Contains('Relaxation signal:  WITHHELD (denominator=0) — 4 of 4 bodies matched; none carried a phase-containment block') | Should -BeTrue -Because (
            "a genuinely-measured-but-empty window is a DIFFERENT state from N==0 (no bodies fetched at all) and must say so.`nActual code-review block:`n$codeReviewBlock"
        )
    }

    It 'renders the UNCHANGED bare WITHHELD (denominator=0), with no appended detail, when N==0 (no comment bodies fetched at all)' {
        $context = New-PC772Context -Rollup $script:ZeroedRollup -Matched 0 -CommentBodyCount 0 -AuthorFilteredCount 0 -InvalidEntryCount 0
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

        $codeReviewBlock.Contains('Relaxation signal:  WITHHELD (denominator=0)') | Should -BeTrue -Because "Actual code-review block:`n$codeReviewBlock"
        $codeReviewBlock.Contains('WITHHELD (denominator=0) —') | Should -BeFalse -Because (
            "N==0 is the pre-existing, unchanged degenerate state -- it must NOT gain the new matched/N detail suffix (that suffix is reserved for the genuinely-measured-but-empty state).`nActual code-review block:`n$codeReviewBlock"
        )
    }

    Context 'M3 fix (issue #842 post-review): a stage that is empty from DATA ABSENCE (a sibling stage has the real entries in this window) must never render INVALID-EMPTY or the WITHHELD-with-detail variant' {
        It 'does NOT render INVALID-EMPTY for code-review when design-challenge/plan-stress-test carry real entries elsewhere in the SAME window, even though a window-wide invalid block was dropped' {
            # $script:ZeroedRollup: code-review N=0 (DenominatorZero), but
            # design-challenge (n=7) and plan-stress-test (n=6) both have
            # real entries -- WindowEntryCount is NOT 0. InvalidEntryCount=2
            # is a window-level total unrelated to code-review's own
            # emptiness. Before the M3 fix this falsely rendered
            # INVALID-EMPTY for code-review; the empty stage here is
            # legitimate data-absence, not a parse failure.
            $context = New-PC772Context -Rollup $script:ZeroedRollup -Matched 3 -CommentBodyCount 3 -AuthorFilteredCount 0 -InvalidEntryCount 2
            $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
            $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

            $codeReviewBlock.Contains('INVALID-EMPTY') | Should -BeFalse -Because (
                "code-review's own emptiness is data-absence (design-challenge/plan-stress-test carry the window's real entries), not a parse failure the WARNINGs above explain.`nActual code-review block:`n$codeReviewBlock"
            )
            $codeReviewBlock.Contains('Relaxation signal:  WITHHELD (denominator=0)') | Should -BeTrue -Because (
                "must fall through to the bare, unqualified WITHHELD instead.`nActual code-review block:`n$codeReviewBlock"
            )
        }

        It 'does NOT render the WITHHELD-with-detail variant for code-review when a sibling stage carries the window''s real entries' {
            # Same window shape as above, but with InvalidEntryCount=0 so
            # state 3 (CommentBodyCount>0, "none carried a phase-containment
            # block") would otherwise fire. WindowEntryCount is still
            # nonzero (design-challenge/plan-stress-test), so this must also
            # fall through to the bare WITHHELD, not the appended-detail form.
            $context = New-PC772Context -Rollup $script:ZeroedRollup -Matched 4 -CommentBodyCount 4 -AuthorFilteredCount 0 -InvalidEntryCount 0
            $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
            $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

            $codeReviewBlock.Contains('WITHHELD (denominator=0) —') | Should -BeFalse -Because (
                "the matched/N detail suffix implies this STAGE was measured empty, but the sibling stages carry the window's real entries -- this stage's emptiness is data-absence.`nActual code-review block:`n$codeReviewBlock"
            )
            $codeReviewBlock.Contains('Relaxation signal:  WITHHELD (denominator=0)') | Should -BeTrue -Because "Actual code-review block:`n$codeReviewBlock"
        }
    }

    It 'does not perturb the normally-rendering plan-stress-test and design-challenge stages while code-review is zeroed' {
        $context = New-PC772Context -Rollup $script:ZeroedRollup -Matched 0 -CommentBodyCount 5 -AuthorFilteredCount 5 -JudgeLogin 'alice'
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"

        $reportText.Contains('Relaxation signal:  ELIGIBLE (escape_rate ~0, no critical/high findings)') | Should -BeTrue -Because (
            "plan-stress-test (n=6, untouched by -OmitCodeReview) must still render its normal ELIGIBLE verdict.`nActual report:`n$reportText"
        )
        $reportText.Contains('Relaxation signal:  NOT ELIGIBLE (escape_rate > 0)') | Should -BeTrue -Because (
            "design-challenge (n=7, untouched by -OmitCodeReview) must still render its normal NOT ELIGIBLE verdict.`nActual report:`n$reportText"
        )
    }

    Context 'branch precedence (issue #842 M7/M9 -- state 1 checked before state 2, state 1 before state 4)' {
        It 'renders FILTERED-EMPTY, not the unchanged bare WITHHELD, when matched==0/AuthorFilteredCount>0 is asserted alongside a contradictory CommentBodyCount=0' {
            # Deliberately contradictory input (CommentBodyCount cannot
            # legitimately be 0 while AuthorFilteredCount is nonzero) --
            # this pins that the FILTERED-EMPTY check runs BEFORE the N==0
            # check, not the other way around.
            $context = New-PC772Context -Rollup $script:ZeroedRollup -Matched 0 -CommentBodyCount 0 -AuthorFilteredCount 3 -JudgeLogin 'alice'
            $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
            $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

            $codeReviewBlock.Contains("Relaxation signal:  FILTERED-EMPTY — judge filter matched 0 of 0 bodies (looked for 'alice'); check -JudgeLogin") | Should -BeTrue -Because (
                "Actual code-review block:`n$codeReviewBlock"
            )
        }

        It 'renders FILTERED-EMPTY, not INVALID-EMPTY, when both conditions are simultaneously true' {
            $context = New-PC772Context -Rollup $script:ZeroedRollup -Matched 0 -CommentBodyCount 4 -AuthorFilteredCount 4 -InvalidEntryCount 2 -JudgeLogin 'alice'
            $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
            $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

            $codeReviewBlock.Contains("Relaxation signal:  FILTERED-EMPTY — judge filter matched 0 of 4 bodies (looked for 'alice'); check -JudgeLogin") | Should -BeTrue -Because "Actual code-review block:`n$codeReviewBlock"
            $codeReviewBlock.Contains('INVALID-EMPTY') | Should -BeFalse -Because "Actual code-review block:`n$codeReviewBlock"
        }
    }
}

Describe 'Format-PhaseContainmentReport — always-on judge-filter disclosure (issue #842 M22)' {
    BeforeAll {
        $script:PopulatedRollup = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d'
    }

    It 'renders the header disclosure line unconditionally, naming the identity resolved from gh auth' {
        $context = New-PC772Context -Rollup $script:PopulatedRollup -Matched 8 -CommentBodyCount 10 -JudgeLogin 'github-actions[bot]' -JudgeLoginSource 'resolved from gh auth'
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"

        $reportText.Contains('Judge filter: matched 8 of 10 comment bodies (identity: github-actions[bot], resolved from gh auth)') | Should -BeTrue -Because (
            "a maintainer must always see how much of the fetched corpus was actually attributable to the judge, regardless of which relaxation branch renders below.`nActual report:`n$reportText"
        )
    }

    It 'renders the header disclosure line naming the identity from an explicit -JudgeLogin' {
        $context = New-PC772Context -Rollup $script:PopulatedRollup -Matched 8 -CommentBodyCount 10 -JudgeLogin 'alice' -JudgeLoginSource 'from -JudgeLogin'
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"

        $reportText.Contains('Judge filter: matched 8 of 10 comment bodies (identity: alice, from -JudgeLogin)') | Should -BeTrue -Because "Actual report:`n$reportText"
    }

    It 'discloses the filtered count inside the plan-stress-test stage''s own NON-EMPTY (ELIGIBLE) render, not just the header' {
        $context = New-PC772Context -Rollup $script:PopulatedRollup -Matched 6 -CommentBodyCount 16 -AuthorFilteredCount 10
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $planStressBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'plan-stress-test'

        $planStressBlock | Should -Match '(?i)filtered' -Because (
            "a 16-body window with 10 identity-dropped must not silently narrow the denominator without disclosure, even on a clean-looking ELIGIBLE stage.`nActual plan-stress-test block:`n$planStressBlock"
        )
        $planStressBlock | Should -Match '10' -Because "the disclosure must name the actual filtered count (10).`nActual plan-stress-test block:`n$planStressBlock"
    }

    It 'discloses the filtered count inside the code-review stage''s own INSUFFICIENT DATA (WITHHELD n<5) render, not just the header' {
        $context = New-PC772Context -Rollup $script:PopulatedRollup -Matched 4 -CommentBodyCount 14 -AuthorFilteredCount 10
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $codeReviewBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'code-review'

        $codeReviewBlock.Contains('Relaxation signal:  WITHHELD (n<5)') | Should -BeTrue -Because "Actual code-review block:`n$codeReviewBlock"
        $codeReviewBlock | Should -Match '(?i)filtered' -Because (
            "a filter-induced drop below n=5 must not read as an innocuous 'we need more data' -- the WITHHELD (n<5) branch must ALSO disclose the filtered count, not just the header.`nActual code-review block:`n$codeReviewBlock"
        )
        $codeReviewBlock | Should -Match '10' -Because "the disclosure must name the actual filtered count (10).`nActual code-review block:`n$codeReviewBlock"
    }
}

# ---------------------------------------------------------------------------
# Issue #842 M9 (post-review fix): a PSCustomObject Context lacking the five
# newer disclosure fields (Matched, CommentBodyCount, AuthorFilteredCount,
# JudgeLogin, JudgeLoginSource) must degrade to the same 0/default literals
# as an equivalent hashtable Context, not throw PropertyNotFoundException
# under this file's Set-StrictMode -Version Latest.
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — PSCustomObject Context missing the newer disclosure fields (issue #842 M9)' {
    BeforeAll {
        $script:M9Rollup = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d'

        # Deliberately built WITHOUT Matched/CommentBodyCount/AuthorFilteredCount/
        # JudgeLogin/JudgeLoginSource -- mirrors a Context built before the M22
        # disclosure feature existed (or any caller that omits them).
        $script:M9Context = [PSCustomObject]@{
            Rollup            = $script:M9Rollup
            Source            = 'graphql'
            Truncated         = $false
            WindowDays        = 90
            FetchedAt         = [datetime]::new(2026, 7, 10, 0, 0, 0, [DateTimeKind]::Utc)
            InvalidEntryCount = 0
        }
    }

    It 'does not throw when the PSCustomObject Context omits the five newer fields' {
        { Format-PhaseContainmentReport -Context $script:M9Context } | Should -Not -Throw
    }

    It 'renders the same inert-default header disclosure as the equivalent hashtable Context' {
        $reportText = (Format-PhaseContainmentReport -Context $script:M9Context) -join "`n"
        $reportText.Contains("Judge filter: matched 0 of 0 comment bodies (identity: github-actions[bot], resolved from gh auth)") | Should -BeTrue -Because (
            "a missing PSCustomObject property must degrade to the same 0/default literals the hashtable branch already uses for an omitted key.`nActual report:`n$reportText"
        )
    }
}

# ---------------------------------------------------------------------------
# Issue #842 M10 (post-review fix): the DataUntrustworthy branch is the one
# sibling of InsufficientData/clean-render missing the always-on M22
# filtered-count disclosure line.
# ---------------------------------------------------------------------------

Describe 'Format-PhaseContainmentReport — DataUntrustworthy branch filtered-count disclosure (issue #842 M10)' {
    BeforeAll {
        $script:M10Rollup = Get-PhaseContainmentRollup -Entries (New-PC772FixtureEntries) -WindowLabel '90d' -SustainedCounts @{ 'design-challenge' = 99 }
    }

    It 'discloses the filtered count inside the design-challenge stage''s own DATA UNTRUSTWORTHY render, matching InsufficientData/clean-render siblings' {
        $context = New-PC772Context -Rollup $script:M10Rollup -AuthorFilteredCount 10
        $reportText = (Format-PhaseContainmentReport -Context $context) -join "`n"
        $designChallengeBlock = Get-PC842StageBlock -ReportText $reportText -StageName 'design-challenge'

        $designChallengeBlock.Contains('Relaxation signal:  WITHHELD (data untrustworthy)') | Should -BeTrue -Because "Actual design-challenge block:`n$designChallengeBlock"
        $designChallengeBlock | Should -Match '(?i)filtered' -Because (
            "InsufficientData and the clean render both carry this always-on M22 disclosure line; DataUntrustworthy must not be the one sibling that omits it.`nActual design-challenge block:`n$designChallengeBlock"
        )
        $designChallengeBlock | Should -Match '10' -Because "the disclosure must name the actual filtered count (10).`nActual design-challenge block:`n$designChallengeBlock"
    }
}
