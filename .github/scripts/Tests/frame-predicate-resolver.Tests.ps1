#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for predicate resolver extensions (issue #441, Steps 4a–4d).
#
# Step 4a: changeset.touchesAny(['glob1','glob2']) DSL extension
# Step 4b: changeset.touchesPluginEntryPoint — verification-only contract test
# Step 4c: review.sustainedCriticalOrHigh resolver (findings → boolean)
# Step 4d: express-lane carve-out layer on top of 4c

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:PredicateCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1'
    if (Test-Path $script:PredicateCoreLib) {
        . $script:PredicateCoreLib
    }

    # Resolve-SustainedCriticalOrHigh lives in frame-predicate-core.ps1 (extracted lib,
    # issue #441 Step 4c/4d). No need to dot-source frame-credit-ledger.ps1 here.

    # Helper: build a minimal changeset hashtable.
    function script:New-CS {
        param(
            [string[]]$Files = @(),
            [int]$TotalLines = 10,
            [bool]$IsReReview = $false,
            [bool]$IsProxyGithub = $false,
            [object]$JudgeScore = $null
        )
        return @{
            ChangedFiles   = $Files
            TotalLines     = $TotalLines
            IsReReview     = $IsReReview
            IsProxyGithub  = $IsProxyGithub
            JudgeScore     = $JudgeScore
        }
    }

    # Helper: build a judge-score object.
    function script:New-JudgeScore {
        param([object[]]$Findings = @())
        return [pscustomobject]@{
            Ruling   = 'passed'
            Findings = $Findings
        }
    }

    # Helper: build a finding object.
    function script:New-Finding {
        param(
            [string]$Severity,
            [string]$Ruling,
            [bool]$ExpressLane = $false
        )
        return [pscustomobject]@{
            Severity   = $Severity
            Ruling     = $Ruling
            ExpressLane = $ExpressLane
        }
    }
}

# ---------------------------------------------------------------------------
# Step 4a — changeset.touchesAny([list]) DSL extension
# ---------------------------------------------------------------------------

Describe 'changeset.touchesAny (Step 4a)' {

    It 'returns true when a changed file matches the first glob in the array' {
        $ast = ConvertTo-FVPredicate -Predicate "changeset.touchesAny(['plugin.json', '.claude-plugin/plugin.json'])"
        $ast | Should -Not -BeNullOrEmpty
        $ast.Kind | Should -Not -Be 'ParseError'

        $cs = script:New-CS -Files @('plugin.json')
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when a changed file matches the second glob in the array' {
        $ast = ConvertTo-FVPredicate -Predicate "changeset.touchesAny(['plugin.json', '.claude-plugin/plugin.json'])"

        $cs = script:New-CS -Files @('.claude-plugin/plugin.json')
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns false when no changed file matches any glob in the array' {
        $ast = ConvertTo-FVPredicate -Predicate "changeset.touchesAny(['plugin.json', '.claude-plugin/plugin.json'])"

        $cs = script:New-CS -Files @('Documents/Design/foo.md')
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'returns false when the changed files list is empty' {
        $ast = ConvertTo-FVPredicate -Predicate "changeset.touchesAny(['plugin.json', '.claude-plugin/plugin.json'])"

        $cs = script:New-CS -Files @()
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'parses the array-arg call without returning ParseError' {
        $ast = ConvertTo-FVPredicate -Predicate "changeset.touchesAny(['agents/*', 'skills/*', 'commands/*'])"
        $ast | Should -Not -BeNullOrEmpty
        $ast.Kind | Should -Not -Be 'ParseError'
        $ast.Name | Should -Be 'changeset.touchesAny'
    }

    It 'does not emit the unknown/unsupported-identifier result for touchesAny' {
        $ast = ConvertTo-FVPredicate -Predicate "changeset.touchesAny(['agents/*'])"
        $cs = script:New-CS -Files @('agents/Code-Smith.agent.md')
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Not -Be 'unknown'
    }
}

# ---------------------------------------------------------------------------
# Step 4b — changeset.touchesPluginEntryPoint contract test (no code change)
# ---------------------------------------------------------------------------

Describe 'changeset.touchesPluginEntryPoint contract (Step 4b)' {

    It 'returns true when agents/ files change' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesPluginEntryPoint'
        $cs = script:New-CS -Files @('agents/Code-Smith.agent.md')
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when plugin.json changes' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesPluginEntryPoint'
        $cs = script:New-CS -Files @('plugin.json')
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns true when a .claude-plugin/ file changes' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesPluginEntryPoint'
        $cs = script:New-CS -Files @('.claude-plugin/plugin.json')
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
    }

    It 'returns false when only test files change' {
        $ast = ConvertTo-FVPredicate -Predicate 'changeset.touchesPluginEntryPoint'
        $cs = script:New-CS -Files @('.github/scripts/Tests/some.Tests.ps1')
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'does NOT emit deferred-predicate-identifier for touchesPluginEntryPoint' {
        # Contract: this identifier must not appear in the DeferredCreditReference list.
        $deferred = Get-FVDeferredCreditReferenceIdentifiers
        $deferred | Should -Not -Contain 'changeset.touchesPluginEntryPoint'

        $supported = Get-FVSupportedChangesetIdentifiers
        $supported | Should -Contain 'changeset.touchesPluginEntryPoint'
    }
}

# ---------------------------------------------------------------------------
# Step 4c — review.sustainedCriticalOrHigh resolver (no express-lane yet)
# ---------------------------------------------------------------------------

Describe 'Resolve-SustainedCriticalOrHigh (Step 4c)' {

    It 'returns true when findings contain a Critical+uphold entry' {
        $findings = @(
            script:New-Finding -Severity 'Critical' -Ruling 'uphold'
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings
        $result | Should -Be $true
    }

    It 'returns true when findings contain a High+uphold entry' {
        $findings = @(
            script:New-Finding -Severity 'High' -Ruling 'uphold'
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings
        $result | Should -Be $true
    }

    It 'returns false when no findings exist' {
        $result = Resolve-SustainedCriticalOrHigh -Findings @()
        $result | Should -Be $false
    }

    It 'returns false when findings exist but none are Critical/High uphold (Medium only)' {
        $findings = @(
            script:New-Finding -Severity 'Medium' -Ruling 'uphold'
            script:New-Finding -Severity 'Low' -Ruling 'uphold'
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings
        $result | Should -Be $false
    }

    It 'returns false when a Critical finding is overridden (ruling=override), not upheld' {
        $findings = @(
            script:New-Finding -Severity 'Critical' -Ruling 'override'
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings
        $result | Should -Be $false
    }

    It 'returns false when a Critical finding is inconclusive' {
        $findings = @(
            script:New-Finding -Severity 'Critical' -Ruling 'inconclusive'
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings
        $result | Should -Be $false
    }

    It 'returns true with mixed findings where at least one is Critical+uphold' {
        $findings = @(
            script:New-Finding -Severity 'Medium' -Ruling 'uphold'
            script:New-Finding -Severity 'Critical' -Ruling 'uphold'
            script:New-Finding -Severity 'Low' -Ruling 'override'
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings
        $result | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# Step 4d — Express-lane carve-out composition
# ---------------------------------------------------------------------------

Describe 'Resolve-SustainedCriticalOrHigh with express-lane carve-out (Step 4d)' {

    It 'returns false when the only qualifying finding carries ExpressLane=true' {
        $findings = @(
            script:New-Finding -Severity 'Critical' -Ruling 'uphold' -ExpressLane $true
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings -ApplyExpressLaneCarveOut $true
        $result | Should -Be $false
    }

    It 'returns true when at least one qualifying finding has ExpressLane=false' {
        $findings = @(
            script:New-Finding -Severity 'Critical' -Ruling 'uphold' -ExpressLane $true
            script:New-Finding -Severity 'High' -Ruling 'uphold' -ExpressLane $false
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings -ApplyExpressLaneCarveOut $true
        $result | Should -Be $true
    }

    It 'returns true when all qualifying findings have ExpressLane=false' {
        $findings = @(
            script:New-Finding -Severity 'Critical' -Ruling 'uphold' -ExpressLane $false
            script:New-Finding -Severity 'High' -Ruling 'uphold' -ExpressLane $false
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings -ApplyExpressLaneCarveOut $true
        $result | Should -Be $true
    }

    It 'returns true (ignoring express-lane) when ApplyExpressLaneCarveOut is false' {
        # Opt-out of the carve-out: all-express-laned should still return true.
        $findings = @(
            script:New-Finding -Severity 'Critical' -Ruling 'uphold' -ExpressLane $true
        )
        $result = Resolve-SustainedCriticalOrHigh -Findings $findings -ApplyExpressLaneCarveOut $false
        $result | Should -Be $true
    }

    It 'review.sustainedCriticalOrHigh predicate resolves via changeset JudgeScore when present' {
        # When the changeset carries JudgeScore data with a Critical+uphold finding,
        # the predicate evaluator should return 'true' instead of 'unknown'.
        $js = script:New-JudgeScore -Findings @(
            script:New-Finding -Severity 'Critical' -Ruling 'uphold'
        )
        $cs = script:New-CS -Files @('agents/Code-Smith.agent.md') -JudgeScore $js

        $ast = ConvertTo-FVPredicate -Predicate 'review.sustainedCriticalOrHigh == true'
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'true'
        # Must NOT emit deferred-credit-reference-identifier when JudgeScore present.
        $r.Result | Should -Not -Be 'unknown'
    }

    It 'review.sustainedCriticalOrHigh returns false when JudgeScore has no qualifying findings' {
        $js = script:New-JudgeScore -Findings @(
            script:New-Finding -Severity 'Medium' -Ruling 'uphold'
        )
        $cs = script:New-CS -Files @('agents/Code-Smith.agent.md') -JudgeScore $js

        $ast = ConvertTo-FVPredicate -Predicate 'review.sustainedCriticalOrHigh == true'
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'false'
    }

    It 'review.sustainedCriticalOrHigh still returns unknown when no JudgeScore in changeset' {
        # Without JudgeScore, the evaluator falls back to deferred-unknown behavior.
        $cs = script:New-CS -Files @('agents/Code-Smith.agent.md')
        $ast = ConvertTo-FVPredicate -Predicate 'review.sustainedCriticalOrHigh == true'
        $r = Test-FVPredicateAgainstChangeset -Ast $ast -Changeset $cs
        $r.Result | Should -Be 'unknown'
    }
}
