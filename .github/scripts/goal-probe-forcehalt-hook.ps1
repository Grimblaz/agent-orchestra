#Requires -Version 7.0
<#
.SYNOPSIS
    Minimal Stop-hook stub for the goal-run capability probe's leg (e)
    (issue #874, plan step 1/2 fix batch, M7). Delivers a real force-halt
    block decision when registered via
    `Get-GoalProbeForceHaltSettingsFragment` in a probe worktree's
    `.claude/settings.json`.
.DESCRIPTION
    This is a STUB the probe owner must review and customize before leg
    (e), not a production harness component -- the harness itself is later
    #874 scope. It exists so leg (e) doesn't ask the owner to improvise a
    safety-critical hook's block-decision contract live.

    Block-decision contract (documented Claude Code Stop-hook behavior,
    reasonable-confidence best-effort -- this repo has no prior in-tree
    Stop hook to mirror, and this stub was authored without live access to
    verify against current CLI docs; the probe owner MUST confirm this
    still matches the installed CLI's actual behavior before relying on it
    for leg (e), e.g. via `claude --help` / hook documentation / a
    throwaway dry run):

      - Exit code 2, with the block reason written to stderr, is the
        canonical "block" signal for Stop hooks -- Claude Code treats a
        non-zero exit combined with stderr output as a blocking error and
        feeds the stderr content back to the agent instead of letting the
        turn end.
      - Alternatively (and preferably, since it is less exit-code-magic
        and more explicit), write a JSON object to stdout shaped
        `{"decision":"block","reason":"<why>"}` and exit 0. Only
        `"decision":"block"` actually prevents the stop; any other value,
        or an absent `decision` key, lets the turn end normally.

    This stub does BOTH (JSON on stdout AND exit 2 with the same reason on
    stderr) so it blocks under either contract interpretation -- verify
    live which one your installed CLI actually honors and simplify if you
    confirm only one is needed.

    Always-block posture: this stub blocks unconditionally by design (leg
    (e) needs a hook that reliably fires so the win/loss rig has something
    to detect). Do not register this in any non-probe worktree.
#>

[CmdletBinding()]
param()

$reason = 'goal-probe leg (e) force-halt stub: unconditional block for capability-probe measurement. Not a production decision -- see .github/scripts/README-goal-probe.md leg (e).'

$decision = [pscustomobject]@{
    decision = 'block'
    reason   = $reason
}

$decision | ConvertTo-Json -Compress | Write-Output

[Console]::Error.WriteLine($reason)
exit 2
