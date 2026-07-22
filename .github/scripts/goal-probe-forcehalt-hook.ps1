#Requires -Version 7.0
<#
.SYNOPSIS
    Minimal Stop-hook stub for the goal-run capability probe's leg (e)
    (issue #874). Attempts a supervisor-side force-halt via the documented
    universal `continue: false` field when registered through
    `Get-GoalProbeForceHaltSettingsFragment` in a probe worktree's
    `.claude/settings.json`.
.DESCRIPTION
    This is a STUB the probe owner must review before leg (e), not a
    production harness component -- the harness itself is later #874 scope.
    Leg (e) has never been run, so nothing below is `observed`.

    ## Read this first: on `Stop`, "block" is the OPPOSITE of a halt

    An earlier revision of this stub emitted `{"decision":"block"}` and
    exited 2, believing either channel would terminate the loop. Both are
    wrong, and wrong in the same direction. Per the vendor hooks reference
    (https://code.claude.com/docs/en/hooks), evidence label `documented`:

      - Stop decision control: `decision: "block"` **"prevents Claude from
        stopping"**; you **"omit to allow Claude to stop"**. A block keeps
        the conversation going -- it is a continuation signal.
      - Exit-code-2 behaviour per event, `Stop` row: exit 2 **"Prevents
        Claude from stopping, continues the conversation"**. Same direction.
      - Channel exclusivity: "You must choose one approach per hook, not
        both: either use exit codes alone for signaling, or exit 0 and print
        JSON for structured control. Claude Code only processes JSON on exit
        0. If you exit 2, any JSON is ignored." The old stub did both, so its
        JSON was dead and only the (also-inverted) exit 2 took effect.

    ## The channel this stub actually uses

    The documented way for a hook to terminate is the *universal* `continue`
    field, not the event-specific `decision` field:

      - `continue`: "If `false`, Claude stops processing entirely after the
        hook runs. Takes precedence over any event-specific decision fields."
      - `stopReason`: "Message shown to the user when `continue` is `false`.
        Not shown to Claude."
      - The reference's own worked example is titled "To stop Claude entirely
        regardless of event type" and shows exactly
        `{ "continue": false, "stopReason": "..." }`.
      - The decision-control table's TeammateIdle row states that
        `{"continue": false, "stopReason": "..."}` "stops the teammate
        entirely, **matching `Stop` hook behavior**" -- a direct statement
        that this shape halts on `Stop`.

    So this stub exits 0 and writes ONLY that JSON object to stdout. It must
    not print anything else on stdout, or JSON parsing fails.

    ## The part the docs do NOT answer (why leg (e) is still a real question)

    Under `/goal`, the goal loop continues *because the goal evaluator is
    itself a session-scoped prompt-based Stop hook* whose `ok: false` result
    is, per the reference, converted into `decision: "block"` on `Stop`. So a
    supervisor hook attempting a force-halt is racing a sibling Stop hook
    that is blocking on the very same event.

    The reference documents cross-hook merge semantics for exactly one event:
    "For `PreToolUse` permission decisions, the most restrictive answer
    applies, in the order `deny`, `defer`, `ask`, `allow`." It documents that
    `additionalContext` from every hook is concatenated. It documents NO
    precedence rule for `Stop` when one hook returns `continue: false` and a
    sibling returns `decision: "block"`. The `continue` field's own wording --
    "takes precedence over any event-specific decision fields" -- is not
    scoped to same-hook-versus-cross-hook either way.

    Therefore: `continue: false` is the only documented force-halt channel and
    is the right thing to attempt, but whether it beats the `/goal`
    evaluator's concurrent block is UNVERIFIED. Do not record a leg-(e) win
    without live evidence of the loop actually terminating.

    Unconditional posture: this stub attempts the halt on every Stop by
    design (leg (e) needs a hook that reliably fires so the win/loss rig has
    something to detect). Do not register this in any non-probe worktree.
#>

[CmdletBinding()]
param()

$stopReason = 'goal-probe leg (e) force-halt stub: unconditional continue:false for capability-probe measurement. Not a production decision -- see .github/scripts/README-goal-probe.md leg (e).'

$forceHalt = [pscustomobject]@{
    continue   = $false
    stopReason = $stopReason
}

# Exit-0 + JSON is the structured-control channel; stdout must contain only
# this object, and the exit code must be 0 or the JSON is discarded.
$forceHalt | ConvertTo-Json -Compress | Write-Output

exit 0
