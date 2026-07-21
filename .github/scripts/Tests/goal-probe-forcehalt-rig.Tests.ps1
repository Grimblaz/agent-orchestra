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
}

Describe 'Test-GoalProbeForceHaltWin' {

    Context 'win detection' {
        It 'declares a win when the Stop hook blocked a continuation the goal evaluator itself would have allowed' {
            $desc = @{
                ProbeMarker                       = $script:ArmedMarker
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'block'
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

        It 'does not declare a win when the Stop hook fired but its decision was allow, not block' {
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
                StopHookDecision                  = 'block'
                GoalEvaluatorContinuationDecision = 'halt'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'concurrent-halt-not-a-win'
        }
    }

    Context 'evaluator-decision-indeterminate' {
        It 'reports evaluator-decision-indeterminate (not concurrent-halt-not-a-win) when the Stop hook blocked but the evaluator continuation decision was never recorded' {
            $desc = @{
                ProbeMarker      = $script:ArmedMarker
                EndReason        = 'stop-hook'
                StopHookDecision = 'block'
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
                StopHookDecision                  = 'block'
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
                StopHookDecision                  = 'block'
                GoalEvaluatorContinuationDecision = 'continue'
            }
            $result = Test-GoalProbeForceHaltWin -SessionEndDescription $desc -ArmedProbeMarker $script:ArmedMarker
            $result.Won | Should -Be $false
            $result.Outcome | Should -Be 'scope-guard-rejected'
        }

        It 'rejects a session missing a ProbeMarker entirely' {
            $desc = @{
                EndReason                         = 'stop-hook'
                StopHookDecision                  = 'block'
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
                StopHookDecision                  = 'block'
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
