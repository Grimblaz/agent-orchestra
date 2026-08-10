#Requires -Version 7.0
<#
.SYNOPSIS
    Derives the `{session_key}` filename component for the gate-decision event log.

.DESCRIPTION
    `SMC-21` designates this function as the key derivation for the gate-event
    stream. Agents emitting L0 gate-decision tokens interpolate the result into
    `memories/session/gate-events-{session_key}.jsonl`.

    This function used to live inside `gate-event-logger-hook.ps1`, the L1
    PostToolUse producer. That hook was retired in issue #1003 — a hook keyed to
    one presentation mechanism has no reliable trigger once the surfaces Claude
    loads specify no mechanism, and its output had not been written since
    2026-07-18 — so the derivation moved here, where it is reachable without the
    producer. The four L0 writers that interpolate the key are
    `agents/Code-Conductor.agent.md`, `commands/orchestra-review-judge.md`,
    `skills/review-judgment/SKILL.md`, and `skills/solution-authoring/SKILL.md`.

    Resolution order (first match wins):
      1. `-SessionId` when supplied and it sanitizes to a non-empty slug -> `s-{sanitized}`
      2. current branch name                                            -> `b-{slug}`
      3. short HEAD sha                                                 -> `sha-{sha}`
      4. literal `session`

    Rung 1 requires a non-empty slug, not merely a non-empty argument. A session id made
    entirely of characters the sanitizer strips (`'---'`, `'///'`) would otherwise collapse
    to the bare key `s-`, and every such session would share one `gate-events-s-.jsonl`.
    That degenerate output was the behavior of the retired hook this function came from; it
    is closed here rather than carried forward.

.PARAMETER SessionId
    The host session identifier, when the caller has one. Optional.

.EXAMPLE
    . ./skills/solution-authoring/scripts/Resolve-GateSessionKey.ps1
    Resolve-GateSessionKey -SessionId $env:CLAUDE_CODE_SESSION_ID

    On Claude Code the session id is in `CLAUDE_CODE_SESSION_ID`. There is no
    `CLAUDE_SESSION_ID`; passing it yields `$null`, which silently drops to the branch-slug
    rung and re-splits one conversation's log across branches. Where no session id is
    available at all, call with no argument and take the branch-slug rung deliberately.
#>

function Resolve-GateSessionKey {
    [CmdletBinding()]
    param(
        [string]$SessionId
    )

    # Prefer an explicit session id (stable within a session). The slug must survive
    # sanitizing: an all-punctuation id collapses to empty, and returning a bare "s-"
    # would merge every such session into one log file.
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $slug = ($SessionId -replace '[^A-Za-z0-9._-]+', '-').TrimStart('-').TrimEnd('-')
        if (-not [string]::IsNullOrWhiteSpace($slug)) {
            return "s-$slug"
        }
    }

    # Fallback 1: branch slug
    $branch = (git rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch)) {
        $slug = ($branch -replace '[^A-Za-z0-9._-]+', '-').TrimStart('-').TrimEnd('-')
        if (-not [string]::IsNullOrWhiteSpace($slug)) {
            return "b-$slug"
        }
    }

    # Fallback 2: short HEAD sha
    $sha = (git rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
        return "sha-$($sha.Trim())"
    }

    return 'session'
}
