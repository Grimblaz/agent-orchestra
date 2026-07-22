#Requires -Version 7.0
<#
.SYNOPSIS
    Force-halt win/loss detection rig for the goal-run capability probe
    (issue #874, plan step 1, leg e).
.DESCRIPTION
    This rig's job is NOT to deliver a force-halt live -- that is an
    owner-executed step later in the plan. Its job is the win/loss detection
    logic: given a description of how a goal-loop session ended, determine
    whether a Stop-hook stop-decision WON (terminated the loop by beating the
    goal evaluator's own continuation decision) versus the loop ending for any
    other reason (natural completion, wall-clock cutoff, budget cutoff,
    external kill, or a Stop hook that fired but did not actually block).

    CRITICAL POLARITY NOTE (`documented`, vendor hooks reference at
    https://code.claude.com/docs/en/hooks): on the `Stop` event,
    `decision: "block"` **prevents Claude from stopping and continues the
    conversation** -- it is the OPPOSITE of a force-halt. Exit code 2 on
    `Stop` does the same thing. The only documented channel by which a hook
    can terminate is the universal `continue: false` field ("Claude stops
    processing entirely after the hook runs"), emitted on exit 0 as JSON.
    An earlier revision of this rig scored `StopHookDecision = 'block'` as a
    WIN; under the real contract that input means the loop KEPT RUNNING, so
    it is now scored as its own distinct loss outcome
    ('block-does-not-halt') rather than silently as an ordinary loss.

    "Beating the evaluator's own continuation decision" is read literally: a
    Stop-hook force-halt only counts as a win when the goal evaluator's own
    concurrent decision was 'continue' -- i.e. the loop would have kept going
    absent the hook. When the hook force-halts AND the evaluator had
    independently already decided to halt, the hook cannot be credited with
    beating anything; that case is reported as its own distinct outcome
    ('concurrent-halt-not-a-win'), not silently folded into either a clean win
    or an ordinary loss.

    Whether a supervisor hook's `continue: false` actually beats a sibling
    Stop hook's block is UNDOCUMENTED. Under `/goal` the evaluator is itself a
    prompt-based Stop hook whose 'keep going' verdict becomes
    `decision: "block"` on the same event, and the vendor reference documents
    cross-hook merge precedence for `PreToolUse` only. This rig therefore
    detects a win from evidence; it does not assert the mechanism works.

    Also includes a small registration helper/documentation stub
    (Get-GoalProbeForceHaltSettingsFragment) showing how a Stop hook would be
    registered via a WORKTREE-LOCAL `.claude/settings.json` -- deliberately
    NOT the plugin `hooks/hooks.json` (that surface is out of scope for this
    plan and would trigger the plugin-release-hygiene version-bump nudge for
    an unrelated capability probe).

    IMPORTANT -- there is NO per-session marker-based gating at the
    hook-dispatch level. Claude Code's Stop event does not support a
    `matcher` field at all (any value placed there is silently ignored by
    the dispatcher); this rig does not attempt to fake that capability by
    emitting one. The ONLY real containment this probe has against the hook
    firing outside its intended session is the worktree-local file
    location itself: a hook registered in `$probeWorktree/.claude/settings.json`
    only ever runs for sessions started inside that worktree, because that
    is where Claude Code looks for worktree-local settings. That is a
    location-based guarantee, not a marker-based one.

    A separate, genuinely real guard exists on the scripted-detector side
    of this rig: `Test-GoalProbeForceHaltWin`'s own `ArmedProbeMarker` /
    `ProbeMarker` check rejects a session-end description whose marker
    doesn't match what this rig instance was armed for. That check is real
    and still enforced -- it is just enforced in this function's own
    win/loss-detection logic, not by the hook dispatcher.
#>

function Test-GoalProbeForceHaltWin {
    <#
    .SYNOPSIS
        Determines whether a described goal-loop session end was a genuine
        Stop-hook win.
    .PARAMETER SessionEndDescription
        Hashtable describing how the session ended:
          ProbeMarker                        [string] the probe marker/id recorded on the ended session
          EndReason                          [string] 'stop-hook' | 'natural-completion' | 'wall-clock-cutoff' | 'budget-cutoff' | 'external-kill' | other
          StopHookDecision                   [string] 'continue-false' | 'block' | 'allow' (only meaningful when EndReason -eq 'stop-hook').
                                                      'continue-false' = the hook emitted {"continue":false,...} on exit 0, the
                                                      only documented force-halt channel. 'block' = the hook emitted
                                                      decision:"block" (or exited 2), which PREVENTS stopping -- never a halt.
                                                      'allow' = the hook fired but expressed no decision.
          GoalEvaluatorContinuationDecision  [string] 'continue' | 'halt' (only meaningful when EndReason -eq 'stop-hook' and StopHookDecision -eq 'continue-false')
    .PARAMETER ArmedProbeMarker
        The marker/id this rig instance is armed for. A session whose own
        ProbeMarker does not match is rejected before any win/loss logic runs
        -- the scope guard.
    .OUTPUTS
        [pscustomobject] Won [bool], Outcome [string]
        ('stop-hook-win'|'loss'|'block-does-not-halt'|
        'concurrent-halt-not-a-win'|'evaluator-decision-indeterminate'|
        'scope-guard-rejected'), Reason [string].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$SessionEndDescription,
        [Parameter(Mandatory)][string]$ArmedProbeMarker
    )

    $sessionMarker = [string]$SessionEndDescription['ProbeMarker']
    if ([string]::IsNullOrEmpty($sessionMarker) -or $sessionMarker -cne $ArmedProbeMarker) {
        return [pscustomobject]@{
            Won     = $false
            Outcome = 'scope-guard-rejected'
            Reason  = "session ProbeMarker ('$sessionMarker') does not match this rig's armed marker ('$ArmedProbeMarker') -- rig never activates for a non-probe loop"
        }
    }

    $endReason = [string]$SessionEndDescription['EndReason']
    if ($endReason -ne 'stop-hook') {
        return [pscustomobject]@{
            Won     = $false
            Outcome = 'loss'
            Reason  = "end reason was '$endReason', not a Stop-hook termination"
        }
    }

    $stopHookDecision = [string]$SessionEndDescription['StopHookDecision']
    if ($stopHookDecision -eq 'block') {
        return [pscustomobject]@{
            Won     = $false
            Outcome = 'block-does-not-halt'
            Reason  = "Stop hook emitted decision 'block', which on the Stop event PREVENTS Claude from stopping and continues the conversation -- the opposite of a force-halt. The loop kept running, so this cannot be a stop-hook termination. The only documented force-halt channel is exit 0 with {`"continue`":false,...} (StopHookDecision = 'continue-false')."
        }
    }

    if ($stopHookDecision -ne 'continue-false') {
        return [pscustomobject]@{
            Won     = $false
            Outcome = 'loss'
            Reason  = "Stop hook fired but its decision was '$stopHookDecision', not 'continue-false' -- it did not attempt, let alone achieve, a termination"
        }
    }

    $evaluatorDecision = [string]$SessionEndDescription['GoalEvaluatorContinuationDecision']
    if ([string]::IsNullOrEmpty($evaluatorDecision)) {
        return [pscustomobject]@{
            Won     = $false
            Outcome = 'evaluator-decision-indeterminate'
            Reason  = "the Stop hook force-halted (continue:false) and the loop ended, but the goal evaluator's own concurrent continuation decision was never observed/recorded for this session end -- this is NOT a claim about what the evaluator decided, only that it is unknown"
        }
    }

    if ($evaluatorDecision -eq 'continue') {
        return [pscustomobject]@{
            Won     = $true
            Outcome = 'stop-hook-win'
            Reason  = "Stop hook's continue:false terminated a loop the goal evaluator itself had voted to continue"
        }
    }

    return [pscustomobject]@{
        Won     = $false
        Outcome = 'concurrent-halt-not-a-win'
        Reason  = "the goal evaluator's own continuation decision was '$evaluatorDecision', not 'continue' -- the hook did not beat anything, it agreed with a decision the evaluator had already made, so this end is not evidence that continue:false can win the race"
    }
}

function Get-GoalProbeForceHaltSettingsFragment {
    <#
    .SYNOPSIS
        Documentation/registration-shape stub: the worktree-local
        `.claude/settings.json` fragment that would register a probe-scoped
        Stop hook.
    .DESCRIPTION
        Returns the shape only -- this rig does not write settings.json
        itself, and delivering a live force-halt remains an owner-executed
        step. Deliberately targets the WORKTREE-LOCAL settings.json, never
        the plugin-distributed hooks/hooks.json.

        -ArmedProbeMarker is accepted for API symmetry with
        Test-GoalProbeForceHaltWin and to make the caller's intent explicit,
        but it is NOT emitted into the fragment as a hook `matcher` --
        Claude Code's Stop event does not support matchers at all (any
        value there is silently ignored by the dispatcher), so a `matcher`
        field here would be a false containment claim. The only real
        containment for this fragment is that it is written to
        `$probeWorktree/.claude/settings.json`: a hook registered there
        only ever fires for sessions started inside that worktree. Marker
        scoping for the probe is enforced separately and for real by
        Test-GoalProbeForceHaltWin's own ArmedProbeMarker/ProbeMarker
        check on the scripted-detector side.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ArmedProbeMarker,
        [string]$StopHookCommand = 'pwsh -NoProfile -File .github/scripts/goal-probe-forcehalt-hook.ps1'
    )

    return @{
        hooks = @{
            Stop = @(
                @{
                    hooks = @(
                        @{
                            type    = 'command'
                            command = $StopHookCommand
                        }
                    )
                }
            )
        }
    }
}
