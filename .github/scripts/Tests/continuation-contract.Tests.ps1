#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for Code-Conductor Continuation Contract wording.

.DESCRIPTION
    Locks the issue #354 continuation contract in:
      - agents/Code-Conductor.agent.md

        The file must describe the same semantics for:
            - a Continuation Contract heading inside <critical_rules>
            - key continuation points where models commonly stall (validation, review, CE Gate, PR creation)
            - stopping rules that cover silent abandonment
            - an askQuestions fallback when uncertain whether to continue
            - the anti-pattern "premature silent stop" named as a protocol violation

        These tests lock the landed continuation-contract wording for issue #354 going forward; update them only when the contract semantics intentionally change.
#>

Describe 'continuation contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CodeConductor = Join-Path $script:RepoRoot 'agents\Code-Conductor.agent.md'

        $script:ReadContent = {
            param([string]$Path)

            return Get-Content -Path $Path -Raw
        }

        # Read full content once; extract scoped blocks for precise assertions
        $script:FullContent = & $script:ReadContent -Path $script:CodeConductor
        $script:CriticalRulesBlock = if ($script:FullContent -match '(?si)<critical_rules>(.*?)</critical_rules>') {
            $Matches[1]
        } else {
            ''
        }

        # Extract the <stopping_rules> block for scoped assertions
        $script:StoppingRulesBlock = if ($script:FullContent -match '(?si)<stopping_rules>(.*?)</stopping_rules>') {
            $Matches[1]
        } else {
            ''
        }

        # Test 1: Continuation Contract heading inside critical_rules
        $script:ContinuationHeadingPattern = '(?i)###\s+Continuation Contract'

        # Test 2: Key continuation points listed
        $script:ContinuationPointsPattern = '(?si)(validation).{0,400}(code review|review).{0,400}(CE Gate|customer.experience).{0,400}(PR creation|PR URL|create.{0,40}PR)'

        # Test 3: Stopping rules cover silent abandonment
        $script:SilentAbandonmentPattern = '(?si)(end a session|end.{0,40}session).{0,200}(PR URL|pull request).{0,120}(askQuestions|ask.{0,10}questions)'

        # Test 4: "When uncertain, ask" fallback
        $script:UncertainAskPattern = '(?si)(uncertain|not sure).{0,200}(askQuestions|ask.{0,10}questions)'

        # Test 5: Anti-pattern "premature silent stop" named
        $script:PrematureSilentStopPattern = '(?si)premature silent stop.{0,200}(protocol violation|violation|anti-pattern|forbidden)'
    }

    It 'requires Continuation Contract heading to exist inside critical_rules' {
        $script:CriticalRulesBlock | Should -Not -BeNullOrEmpty -Because 'issue #354 requires a <critical_rules> block to exist in Code-Conductor'
        $script:CriticalRulesBlock | Should -Match $script:ContinuationHeadingPattern -Because 'issue #354 requires a ### Continuation Contract heading inside <critical_rules>'
    }

    It 'requires key continuation points to be listed (validation, review, CE Gate, PR creation)' {
        $script:CriticalRulesBlock | Should -Match $script:ContinuationPointsPattern -Because 'issue #354 requires key continuation points inside <critical_rules> where models commonly stall: validation, review, CE Gate, and PR creation'
    }

    It 'requires stopping rules to cover silent abandonment' {
        $script:StoppingRulesBlock | Should -Not -BeNullOrEmpty -Because 'issue #354 requires a <stopping_rules> block to exist in Code-Conductor'
        $script:StoppingRulesBlock | Should -Match $script:SilentAbandonmentPattern -Because 'issue #354 requires stopping rules to cover ending a session without a PR URL or askQuestions call'
    }

    It 'requires a "when uncertain, ask" fallback using askQuestions' {
        $script:FullContent | Should -Match $script:UncertainAskPattern -Because 'issue #354 requires the uncertainty-as-stop-reason anti-pattern to be addressed with an askQuestions fallback'
    }

    It 'requires the anti-pattern "premature silent stop" to be named as a protocol violation' {
        $script:CriticalRulesBlock | Should -Match $script:PrematureSilentStopPattern -Because 'issue #354 requires the premature silent stop anti-pattern to be explicitly named inside <critical_rules> as a protocol violation'
    }
}
