#Requires -Version 7.0
<#
.SYNOPSIS
    goal_status session-transcript reader for the goal-run harness (issue
    #874, plan step 1, AC2 foundation for AC1).
.DESCRIPTION
    Reads the platform-emitted `goal_status` attachment event from a session
    transcript file (never stdout -- per the goal-loop-capability-probe
    finding recorded in Documents/Design/goal-loop-capability-probe.md,
    `goal_status` never reaches the `stream-json` stdout stream on either
    the interactive or headless surface; it is transcript-only on both).

    Two event shapes (both `{"type":"attachment","attachment":{...}}`):

      start marker      -- attachment fields: met (false), sentinel (true),
                            condition. No reason/iterations/durationMs/tokens.
      evaluator verdict  -- attachment fields: met (true or false), condition,
                            reason, iterations, durationMs, tokens. No
                            sentinel field at all.

    Release = an evaluator-verdict event with met: true.

    Every extracted event field is run through the allow-list extractor
    (Select-GoalRunAllowedFields, goal-run-transcript-core.ps1) before it is
    returned, and any free-text fields (condition/reason) are additionally
    run through the secret-redaction pass (Get-GoalRunRedactedText) before
    being returned -- so a caller that embeds .Event.Fields.condition or
    .Event.Fields.reason directly into a durable artifact never leaks raw
    transcript text or a secret.

    Get-GoalRunStatusEvent distinguishes four states, not collapsed into one:

      status-absent      -- no goal_status attachment event exists in the
                             transcript at all (including transcript-not-found,
                             transcript-read-error, and transcript-empty --
                             see .Reason for which).
      wrong-shape         -- a goal_status-typed attachment event exists but
                             matches neither the start-marker nor the
                             evaluator-verdict shape.
      present-met-false   -- a goal_status event genuinely exists with
                             met: false (either shape).
      present-met-true    -- an evaluator-verdict event exists with
                             met: true -- release.

    Malformed/partial-tail JSONL lines are silently skipped (never thrown),
    mirroring the established tolerance of goal-probe-usage-reader.ps1.

    M15 fix (stale-release contamination): Get-GoalRunStatusEvent used to
    return present-met-true on ANY evaluator-verdict event with met: true
    found anywhere in the transcript, with no binding to the CURRENT run --
    a met: true verdict left over from an earlier goal in the same
    long-lived transcript file would falsely release a fresh run. The
    optional -LaunchedAt parameter binds the release check to the current
    run: when supplied, an evaluator-verdict met: true event only counts
    toward release when its own top-level `timestamp` field (the same field
    cost-walker.ps1 already reads off real Claude Code transcript JSONL
    events -- not a field inside the nested `attachment` object) parses to
    a value at or after -LaunchedAt. An event with a missing or unparseable
    timestamp, or an unparseable -LaunchedAt value itself, is treated
    conservatively as NOT the current run release (fail closed against a
    false release) rather than silently falling back to the pre-fix
    unbounded acceptance. When -LaunchedAt is omitted entirely, behavior is
    unchanged from before this fix (no binding applied) -- existing callers
    that do not yet thread a launch timestamp through are not regressed.
#>

. (Join-Path $PSScriptRoot 'goal-run-transcript-core.ps1')

# The allow-list is deliberately the union of BOTH shapes' fields -- the
# extractor drops whichever of these keys is absent from a given event, so
# one shared list is sufficient (no need for two separate allow-lists).
$script:GoalRunStatusAllowList = @('met', 'sentinel', 'condition', 'reason', 'iterations', 'durationMs', 'tokens')

function Get-GoalRunStatusEvent {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TranscriptPath,
        [string]$LaunchedAt
    )

    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        return [pscustomobject]@{ State = 'status-absent'; Reason = 'transcript-not-found'; ShapeKind = $null; Event = $null }
    }

    $readError = $null
    $rawLines = @(Get-Content -LiteralPath $TranscriptPath -Encoding utf8 -ErrorAction SilentlyContinue -ErrorVariable readError)

    if ($readError -and $readError.Count -gt 0) {
        return [pscustomobject]@{ State = 'status-absent'; Reason = 'transcript-read-error'; ShapeKind = $null; Event = $null }
    }

    if ($rawLines.Count -eq 0) {
        return [pscustomobject]@{ State = 'status-absent'; Reason = 'transcript-empty'; ShapeKind = $null; Event = $null }
    }

    # M15 fix: when -LaunchedAt is supplied, bind the release check to the
    # CURRENT run by its launch timestamp. An unparseable -LaunchedAt value
    # still activates the binding (fail closed -- see below) rather than
    # silently degrading to the pre-fix unbounded behavior.
    $launchedAtBindingActive = -not [string]::IsNullOrWhiteSpace($LaunchedAt)
    $launchedAtParsed = $null
    if ($launchedAtBindingActive) {
        try {
            $launchedAtParsed = ([datetime]$LaunchedAt).ToUniversalTime()
        }
        catch {
            $launchedAtParsed = $null
        }
    }

    $lastClassified = $null
    $releasedEvent = $null

    foreach ($rawLine in $rawLines) {
        $trimmed = $rawLine.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }

        $evt = $null
        try {
            $evt = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            # Malformed or partial/mid-write tail line: skip silently, same
            # tolerance convention as goal-probe-usage-reader.ps1.
            continue
        }

        if ($null -eq $evt -or $evt -isnot [System.Collections.IDictionary]) { continue }
        if ($evt['type'] -ne 'attachment') { continue }

        $attachment = $evt['attachment']
        if ($null -eq $attachment -or $attachment -isnot [System.Collections.IDictionary]) { continue }
        if ($attachment['type'] -ne 'goal_status') { continue }

        $classified = script:ConvertTo-GoalRunStatusShape -Attachment $attachment
        $lastClassified = $classified

        if ($classified.ShapeKind -eq 'evaluator-verdict' -and $classified.Event.Fields.PSObject.Properties['met'] -and $classified.Event.Fields.met -eq $true) {
            $countsAsCurrentRunRelease = $true
            if ($launchedAtBindingActive) {
                # M15: only a met:true event whose OWN top-level timestamp
                # (not nested under `attachment`) is at or after the current
                # run launch counts as this run release. A missing/
                # unparseable event timestamp, or an unparseable
                # -LaunchedAt, is treated as NOT verifiably current -- fail
                # closed against a stale-release false positive rather than
                # trusting an unverifiable event.
                $eventTimestamp = $null
                if ($evt.ContainsKey('timestamp') -and $evt['timestamp']) {
                    try { $eventTimestamp = ([datetime]$evt['timestamp']).ToUniversalTime() } catch { $eventTimestamp = $null }
                }
                if ($null -eq $launchedAtParsed -or $null -eq $eventTimestamp -or $eventTimestamp -lt $launchedAtParsed) {
                    $countsAsCurrentRunRelease = $false
                }
            }

            if ($countsAsCurrentRunRelease) {
                $releasedEvent = $classified
            }
        }
    }

    if ($null -ne $releasedEvent) {
        return [pscustomobject]@{ State = 'present-met-true'; Reason = $null; ShapeKind = 'evaluator-verdict'; Event = $releasedEvent.Event }
    }

    if ($null -eq $lastClassified) {
        return [pscustomobject]@{ State = 'status-absent'; Reason = 'no-goal-status-event'; ShapeKind = $null; Event = $null }
    }

    if ($lastClassified.ShapeKind -eq 'wrong-shape') {
        return [pscustomobject]@{ State = 'wrong-shape'; Reason = 'unrecognized-goal-status-shape'; ShapeKind = 'wrong-shape'; Event = $lastClassified.Event }
    }

    return [pscustomobject]@{ State = 'present-met-false'; Reason = $null; ShapeKind = $lastClassified.ShapeKind; Event = $lastClassified.Event }
}

function script:ConvertTo-GoalRunStatusShape {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Attachment
    )

    $hasSentinel = $Attachment.ContainsKey('sentinel')
    $hasBoolMet = $Attachment.ContainsKey('met') -and ($Attachment['met'] -is [bool])
    $hasCondition = $Attachment.ContainsKey('condition')

    if ($hasSentinel -and $Attachment['sentinel'] -eq $true -and $hasBoolMet -and $Attachment['met'] -eq $false -and $hasCondition) {
        $extracted = Select-GoalRunAllowedFields -Source $Attachment -AllowList $script:GoalRunStatusAllowList
        if ($extracted.Fields.PSObject.Properties['condition']) {
            $extracted.Fields.condition = Get-GoalRunRedactedText -Text ([string]$extracted.Fields.condition)
        }
        return [pscustomobject]@{ ShapeKind = 'start-marker'; Event = $extracted }
    }

    if (-not $hasSentinel -and $hasBoolMet -and $hasCondition) {
        $extracted = Select-GoalRunAllowedFields -Source $Attachment -AllowList $script:GoalRunStatusAllowList
        if ($extracted.Fields.PSObject.Properties['condition']) {
            $extracted.Fields.condition = Get-GoalRunRedactedText -Text ([string]$extracted.Fields.condition)
        }
        if ($extracted.Fields.PSObject.Properties['reason']) {
            $extracted.Fields.reason = Get-GoalRunRedactedText -Text ([string]$extracted.Fields.reason)
        }
        return [pscustomobject]@{ ShapeKind = 'evaluator-verdict'; Event = $extracted }
    }

    return [pscustomobject]@{ ShapeKind = 'wrong-shape'; Event = $null }
}
