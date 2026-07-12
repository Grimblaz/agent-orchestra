#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Regression test for issue #824 post-review fix (Group 1, judge-sustained,
# empirically reproduced twice): the harvest's real dependency chain, exactly
# as documented in skills/session-startup/platforms/claude.md Step 7d, must
# actually let Invoke-CostSessionRender run its own real logic.
#
# Before this fix, the documented Step 7d dot-source list (5 files) left 18
# script:-scoped FCL helper functions (trapped inside frame-credit-ledger.ps1's
# own script scope — only 10 of them were originally identified by review;
# grepping the actual call graph found 8 more transitive dependencies) AND 7
# whole lib files (path-normalize.ps1, cost-walker-copilot.ps1,
# cost-attribution.ps1, cost-anomaly.ps1, cost-checkpoint-core.ps1,
# cost-completeness.ps1, cost-pattern-renderer.ps1) unreachable. Every FCL
# call threw CommandNotFoundException, caught by Invoke-CostSessionRender's
# own internal fail-open try/catch, silently returning an empty CostSection.
# The harvest mechanism (issue #824's Mechanism 2) shipped as a permanent,
# invisible no-op.
#
# This is a genuine integration test — no FCL functions are mocked, and no
# Invoke-CostSessionRender internals are mocked. The only two functions
# mocked are the external I/O boundary (the transcript walkers,
# Invoke-CostTranscriptWalk/Invoke-CostCopilotWalk) so the test is
# deterministic, fast, and does not scan this machine's real
# ~/.claude/projects transcript history. Everything downstream of that
# boundary (all 18 relocated FCL helpers, cost attribution, session
# completeness, baseline eligibility, and rendering) runs for real, against
# both the OLD (pre-fix) and CORRECTED (post-fix) dot-source lists, so this
# test demonstrates a genuine RED-then-GREEN transition.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    # A minimal but schema-shaped fixture event (matches what
    # Invoke-CostTranscriptWalk normally returns — see cost-attribution.ps1's
    # Get-EventProvider / Get-CostAttribution for the consumed shape).
    $script:FixtureEventsScript = {
        @(
            @{
                type      = 'assistant'
                gitBranch = 'feature/issue-824-fixture'
                provider  = 'claude'
                message   = @{
                    usage   = @{ input_tokens = 120; output_tokens = 40; cache_creation_input_tokens = 0; cache_read_input_tokens = 0 }
                    content = @()
                }
            }
        )
    }
}

Describe 'cost-session-render harvest dependency chain (issue #824 post-review fix, Group 1)' {

    It 'RED (pre-fix reproduction): the original 5-file Step 7d list leaves Invoke-CostSessionRender unable to reach its FCL helpers' {
        $repoRoot = $script:RepoRoot
        $fixtureEventsScript = $script:FixtureEventsScript

        $captured = & {
            param($repoRoot, $fixtureEventsScript)
            $events = & $fixtureEventsScript

            # Exactly the PRE-FIX documented Step 7d set — deliberately omits
            # cost-fcl-helpers.ps1 and the 7 other transitively-required lib
            # files this fix added, reproducing the original defect.
            . (Join-Path $repoRoot '.github/scripts/lib/cost-rolling-history.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-walker.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-session-render.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/find-or-upsert-comment.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-baseline-harvest.ps1')

            function Invoke-CostTranscriptWalk {
                param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
                return $events
            }
            function Invoke-CostCopilotWalk {
                param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
                return @()
            }

            # Environment variables are process-global (unlike scoped
            # functions/variables) and persist across test FILES within the
            # same Invoke-Pester run — save/restore explicitly, matching the
            # existing $previousInline convention in cost-integration.Tests.ps1.
            $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'

            $stderrWriter = [System.IO.StringWriter]::new()
            $originalError = [Console]::Error
            [Console]::SetError($stderrWriter)
            $renderResult = $null
            try {
                $renderResult = Invoke-CostSessionRender -Pr 824001 -Branch 'feature/issue-824-fixture' -Slug 'fixture-slug' -ParentCwd $repoRoot -RepoRoot $repoRoot
            }
            finally {
                [Console]::SetError($originalError)
                $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
            }

            return @{
                Stderr       = $stderrWriter.ToString()
                Completeness = $renderResult.Completeness
                CostSection  = $renderResult.CostSection
            }
        } $repoRoot $fixtureEventsScript

        $captured.Stderr | Should -Match 'is not recognized as a name of a cmdlet' -Because 'the original defect throws a CommandNotFoundException inside Invoke-CostSessionRender''s own fail-open try/catch when an FCL helper is unreachable'
        $captured.Completeness | Should -BeNullOrEmpty -Because 'the caught exception fires before Get-SessionCompleteness/Resolve-BaselineEligibility ever run'
        $captured.CostSection | Should -BeNullOrEmpty -Because 'the harvest mechanism shipped as a silent no-op — this is the exact symptom this fix corrects'
    }

    It 'GREEN (post-fix): the corrected Step 7d dot-source list lets Invoke-CostSessionRender run its real logic with no CommandNotFoundException' {
        $repoRoot = $script:RepoRoot
        $fixtureEventsScript = $script:FixtureEventsScript

        $captured = & {
            param($repoRoot, $fixtureEventsScript)
            $events = & $fixtureEventsScript

            # Exactly the CORRECTED Step 7d set
            # (skills/session-startup/platforms/claude.md), mirroring
            # frame-credit-ledger.ps1's own "Cost pattern lib dot-sources"
            # block plus the two harvest-specific additions.
            . (Join-Path $repoRoot '.github/scripts/lib/path-normalize.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-walker.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-walker-copilot.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-attribution.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-anomaly.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-rolling-history.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-checkpoint-core.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-completeness.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-pattern-renderer.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-fcl-helpers.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-session-render.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/find-or-upsert-comment.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-baseline-harvest.ps1')

            function Invoke-CostTranscriptWalk {
                param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
                return $events
            }
            function Invoke-CostCopilotWalk {
                param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
                return @()
            }

            # Environment variables are process-global (unlike scoped
            # functions/variables) and persist across test FILES within the
            # same Invoke-Pester run — save/restore explicitly, matching the
            # existing $previousInline convention in cost-integration.Tests.ps1.
            $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'

            $stderrWriter = [System.IO.StringWriter]::new()
            $originalError = [Console]::Error
            [Console]::SetError($stderrWriter)
            $renderResult = $null
            try {
                $renderResult = Invoke-CostSessionRender -Pr 824002 -Branch 'feature/issue-824-fixture' -Slug 'fixture-slug' -ParentCwd $repoRoot -RepoRoot $repoRoot
            }
            finally {
                [Console]::SetError($originalError)
                $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
            }

            return @{
                Stderr       = $stderrWriter.ToString()
                Completeness = $renderResult.Completeness
                CostSection  = $renderResult.CostSection
                TokenSum     = $renderResult.TokenSum
            }
        } $repoRoot $fixtureEventsScript

        $captured.Stderr | Should -Not -Match 'is not recognized as a name of a cmdlet' -Because 'the corrected dependency chain must resolve every one of the 18 relocated FCL helpers'
        $captured.Completeness | Should -Not -BeNullOrEmpty -Because 'real Get-SessionCompleteness/Resolve-BaselineEligibility logic must have executed against the fixture event'
        $captured.Completeness['completeness'] | Should -Be 'partial' -Because 'the fixture event has no stop_reason signaling session end, so real (non-mocked) Get-SessionCompleteness classifies it as partial'
        $captured.CostSection | Should -Not -BeNullOrEmpty -Because 'a real cost section must have been rendered from the fixture event'
        $captured.TokenSum | Should -Be 160 -Because 'input(120) + output(40) from the fixture event, summed via the relocated script:Get-FCLTokenSumFromBucket — proves the relocated function is both reachable AND executing correctly, not just silently absent'
    }

    It 'M17 regression pin (L10, issue #825 post-review fix): $costEvents is guarded in the return block, so a StrictMode read never throws when an FCL helper call fails before $costEvents'' own first assignment' {
        # Reproduces the exact M17 gap: script:Get-FCLCostWalkerTimeoutSeconds (the
        # very first FCL call inside the try block, well before "$costEvents = @()"
        # is reached) throws — caught by Invoke-CostSessionRender's own outer
        # fail-open catch, which never assigns $costEvents. Without the costEvents
        # guard line in the pre-return block, "CostEventsCount = @($costEvents).Count"
        # in the final return statement throws under Set-StrictMode -Version Latest
        # (a genuinely unassigned variable read), defeating the fail-open contract
        # this whole guard block exists to preserve.
        #
        # Deliberately dot-sources the FULL, CORRECT (post-fix) dependency set —
        # exactly like the GREEN test above — and forces the failure with an
        # explicit override of script:Get-FCLCostWalkerTimeoutSeconds, rather than
        # reproducing it via an incomplete dot-source list. Unlike the RED test
        # above, a real cost-fcl-helpers.ps1 dot-source at "function script:X {}"
        # scope is sticky across Its within the same Pester file run, so an
        # omission-based repro run AFTER the GREEN test would silently inherit the
        # GREEN test's already-defined script-scope function and never reproduce
        # the throw at all — this explicit-override approach is immune to that
        # ordering hazard and targets the exact call site directly.
        $repoRoot = $script:RepoRoot
        $fixtureEventsScript = $script:FixtureEventsScript

        $captured = & {
            param($repoRoot, $fixtureEventsScript)
            $events = & $fixtureEventsScript

            # The CORRECTED Step 7d set (matches the GREEN test above).
            . (Join-Path $repoRoot '.github/scripts/lib/path-normalize.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-walker.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-walker-copilot.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-attribution.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-anomaly.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-rolling-history.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-checkpoint-core.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-completeness.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-pattern-renderer.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-fcl-helpers.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-session-render.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/find-or-upsert-comment.ps1')
            . (Join-Path $repoRoot '.github/scripts/lib/cost-baseline-harvest.ps1')

            function Invoke-CostTranscriptWalk {
                param([string]$Slug, [string]$Branch, [string]$ParentCwd, [Nullable[int]]$IssueNumber = $null)
                return $events
            }
            function Invoke-CostCopilotWalk {
                param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
                return @()
            }
            # Forces the exact M17 reproduction: the FIRST FCL call inside
            # Invoke-CostSessionRender's try block throws, well before
            # "$costEvents = @()" is ever reached.
            function script:Get-FCLCostWalkerTimeoutSeconds {
                param([string]$EnvironmentVariableName, [int]$DefaultSeconds)
                throw 'M17 regression pin: forced failure before $costEvents is assigned'
            }

            $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'

            # The load-bearing part of this test: force StrictMode Latest in THIS
            # scope so an unassigned $costEvents read in the return block would
            # actually throw if the guard were missing.
            Set-StrictMode -Version Latest

            $stderrWriter = [System.IO.StringWriter]::new()
            $originalError = [Console]::Error
            [Console]::SetError($stderrWriter)
            $renderResult = $null
            $threw = $false
            $thrownMessage = ''
            try {
                $renderResult = Invoke-CostSessionRender -Pr 824003 -Branch 'feature/issue-824-fixture' -Slug 'fixture-slug' -ParentCwd $repoRoot -RepoRoot $repoRoot
            }
            catch {
                $threw = $true
                $thrownMessage = $_.Exception.Message
            }
            finally {
                [Console]::SetError($originalError)
                $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
            }

            return @{
                Threw           = $threw
                ThrownMessage   = $thrownMessage
                Stderr          = $stderrWriter.ToString()
                CostEventsCount = $renderResult.CostEventsCount
            }
        } $repoRoot $fixtureEventsScript

        $captured.Stderr | Should -Match 'M17 regression pin: forced failure' -Because 'confirms the forced failure actually fired inside the try block, proving this is a real reproduction and not a no-op'
        $captured.Threw | Should -Be $false -Because "Invoke-CostSessionRender's own fail-open contract must hold under StrictMode even when an FCL helper fails before `$costEvents is first assigned; got: $($captured.ThrownMessage)"
        $captured.CostEventsCount | Should -Be 0 -Because 'the costEvents guard defaults it to an empty array before the return block reads @($costEvents).Count'
    }
}
