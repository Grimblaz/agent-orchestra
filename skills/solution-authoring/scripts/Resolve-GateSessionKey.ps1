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
    one presentation mechanism has no reliable trigger once the repository
    specifies no mechanism — so the derivation moved here, where it is reachable
    without the producer. The four L0 writers that interpolate the key are
    `agents/Code-Conductor.agent.md`, `commands/orchestra-review-judge.md`,
    `skills/review-judgment/SKILL.md`, and `skills/solution-authoring/SKILL.md`.

    Resolution order (first match wins):
      1. `-SessionId` when supplied and non-empty  -> `s-{sanitized}`
      2. current branch name                       -> `b-{slug}`
      3. short HEAD sha                            -> `sha-{sha}`
      4. literal `session`

.PARAMETER SessionId
    The host session identifier, when the caller has one. Optional.

.EXAMPLE
    . ./skills/solution-authoring/scripts/Resolve-GateSessionKey.ps1
    Resolve-GateSessionKey -SessionId $env:CLAUDE_SESSION_ID
#>

function Resolve-GateSessionKey {
    [CmdletBinding()]
    param(
        [string]$SessionId
    )

    # Prefer an explicit session id (stable within a session)
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return ("s-" + ($SessionId -replace '[^A-Za-z0-9._-]+', '-').TrimStart('-').TrimEnd('-'))
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
