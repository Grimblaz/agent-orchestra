#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for Test-GoalProbeForceHaltWin and
    Get-GoalProbeForceHaltSettingsFragment (issue #874 plan step 1, leg e).
#>

BeforeAll {
    $script:LibPath = Join-Path $PSScriptRoot '..' 'lib' 'goal-probe-forcehalt-rig.ps1'
    . $script:LibPath
    $script:ArmedMarker = 'probe-874-worktree-marker'
    $script:HookPath = Join-Path $PSScriptRoot '..' 'goal-probe-forcehalt-hook.ps1'
}

Describe 'Test-GoalProbeForceHaltWin' {

    Context 'win detection' {
        It "declares a win when the Stop hook's continue:false terminated a loop the goal evaluator itself had voted to continue" {
            $desc = @{
                ProbeMarker                       = $script:ArmedMarker
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'continue-false'
                GoalEvaluatorContinuationDecision = 'continue'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $true
            $result.Outcome | Should -Be 'stop-hook-win'
        }
    }

    Context 'loss detection (non-Stop-hook end reasons)' {
        It 'does not declare a win for natural completion' {
            $desc = @{ ProbeMarker = $script:ArmedMarker; EndReason = 'natural-completion' }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'loss'
        }

        It 'does not declare a win for a wall-clock cutoff' {
            $desc = @{ ProbeMarker = $script:ArmedMarker; EndReason = 'wall-clock-cutoff' }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'loss'
        }

        It 'does not declare a win for a budget cutoff' {
            $desc = @{ ProbeMarker = $script:ArmedMarker; EndReason = 'budget-cutoff' }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'loss'
        }

        It 'does not declare a win for an external kill' {
            $desc = @{ ProbeMarker = $script:ArmedMarker; EndReason = 'external-kill' }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'loss'
        }

        It 'does not declare a win when the Stop hook fired but expressed no decision (allow)' {
            $desc = @{
                ProbeMarker      = $script:ArmedMarker
                EndReason        = 'stop-hook'
                StopHookDecision = 'allow'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'loss'
        }

        It 'does not declare a win when the hook and the goal evaluator independently agreed to halt (hook did not beat anything)' {
            $desc = @{
                ProbeMarker                       = $script:ArmedMarker
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'continue-false'
                GoalEvaluatorContinuationDecision = 'halt'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'concurrent-halt-not-a-win'
        }
    }

    Context 'Stop-event polarity (decision:block prevents stopping)' {
        It "never declares a win for StopHookDecision = 'block', because on Stop a block PREVENTS stopping and keeps the loop running" {
            $desc = @{
                ProbeMarker                       = $script:ArmedMarker
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'block'
                GoalEvaluatorContinuationDecision = 'continue'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'block-does-not-halt'
        }

        It "reports block-does-not-halt for StopHookDecision = 'block' regardless of the evaluator's decision" {
            foreach ($evaluatorDecision in @('continue', 'halt', '')) {
                $desc = @{
                    ProbeMarker                       = $script:ArmedMarker
                    EndReason                         = 'stop-hook'
                    StopHookDecision                  = 'block'
                    GoalEvaluatorContinuationDecision = $evaluatorDecision
                }
                $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
                $result.Won | Should -Be $false
                $result.Outcome | Should -Be 'block-does-not-halt'
            }
        }

        It "explains in its Reason that 'block' is the opposite of a force-halt and names the continue:false channel" {
            $desc = @{
                ProbeMarker      = $script:ArmedMarker
                EndReason        = 'stop-hook'
                StopHookDecision = 'block'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Reason | Should -Match 'PREVENTS Claude from stopping'
            $result.Reason | Should -Match 'continue'
        }
    }

    Context 'evaluator-decision-indeterminate' {
        It 'reports evaluator-decision-indeterminate (not concurrent-halt-not-a-win) when the Stop hook force-halted but the evaluator continuation decision was never recorded' {
            $desc = @{
                ProbeMarker      = $script:ArmedMarker
                EndReason        = 'stop-hook'
                StopHookDecision = 'continue-false'
                # GoalEvaluatorContinuationDecision intentionally absent.
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'evaluator-decision-indeterminate'
        }

        It 'reports evaluator-decision-indeterminate when GoalEvaluatorContinuationDecision is present but empty' {
            $desc = @{
                ProbeMarker                       = $script:ArmedMarker
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'continue-false'
                GoalEvaluatorContinuationDecision = ''
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'evaluator-decision-indeterminate'
        }
    }

    Context 'scope-guard' {
        It 'rejects a session whose ProbeMarker does not match the armed marker, even if it otherwise looks like a win' {
            $desc = @{
                ProbeMarker                       = 'some-other-unrelated-marker'
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'continue-false'
                GoalEvaluatorContinuationDecision = 'continue'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'scope-guard-rejected'
        }

        It 'rejects a session missing a ProbeMarker entirely' {
            $desc = @{
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'continue-false'
                GoalEvaluatorContinuationDecision = 'continue'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'scope-guard-rejected'
        }

        It 'rejects a session whose ProbeMarker differs from the armed marker only by case (exact-match scope guarding)' {
            $desc = @{
                ProbeMarker                       = $script:ArmedMarker.ToUpperInvariant()
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'continue-false'
                GoalEvaluatorContinuationDecision = 'continue'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'scope-guard-rejected'
        }
    }
}

Describe 'Get-GoalProbeForceHaltSettingsFragment' {
    It 'produces a worktree-local settings.json Stop-hook fragment with the documented structure (no matcher field -- Stop events do not support matchers)' {
        $fragment = Get-GoalProbeForceHaltSettingsFragment -ArmedProbeMarker $script:ArmedMarker
        $fragment.hooks.Stop[0].ContainsKey('matcher') | Should -Be $false
        $fragment.hooks.Stop[0].hooks[0].type | Should -Be 'command'
    }

    It 'is JSON-serializable (documentation stub is a realistic settings.json shape)' {
        $fragment = Get-GoalProbeForceHaltSettingsFragment -ArmedProbeMarker $script:ArmedMarker
        { $fragment | ConvertTo-Json -Depth 6 } | Should -Not -Throw
    }
}

Describe 'goal-probe-forcehalt-hook.ps1 signalling contract' {
    # Asserted structurally over the hook's AST rather than by executing it:
    # the hook calls `exit`, so it cannot be dot-sourced into the test runspace,
    # and the repo's script-safety contract forbids spawning a child pwsh.

    BeforeAll {
        $script:HookAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:HookPath, [ref]$null, [ref]$null)
        $script:HookExits = $script:HookAst.FindAll(
            { $args[0] -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
        $script:HookHashtables = $script:HookAst.FindAll(
            { $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $true)
        $script:HookKeys = @(
            foreach ($ht in $script:HookHashtables) {
                foreach ($pair in $ht.KeyValuePairs) { [string]$pair.Item1.Extent.Text }
            }
        )
    }

    It 'exits 0 on every path, because Claude Code discards hook JSON on any non-zero exit' {
        $script:HookExits | Should -Not -BeNullOrEmpty
        foreach ($exitStatement in $script:HookExits) {
            $script:HookExits.Count | Should -BeGreaterThan 0
            [string]$exitStatement.Pipeline.Extent.Text | Should -Be '0'
        }
    }

    It 'never exits 2, which on Stop would PREVENT stopping and keep the loop running' {
        @($script:HookExits | Where-Object { [string]$_.Pipeline.Extent.Text -eq '2' }) |
            Should -HaveCount 0
    }

    It 'emits the universal continue:false force-halt channel' {
        $script:HookKeys | Should -Contain 'continue'
        $script:HookKeys | Should -Contain 'stopReason'
        $continuePair = $script:HookHashtables.KeyValuePairs |
            Where-Object { [string]$_.Item1.Extent.Text -eq 'continue' }
        [string]$continuePair.Item2.Extent.Text | Should -Be '$false'
    }

    It "never emits a Stop-event 'decision' key, which is the inverted channel (block prevents stopping)" {
        $script:HookKeys | Should -Not -Contain 'decision'
    }
}
