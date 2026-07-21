#Requires -Version 7.0
<#
.SYNOPSIS
    Reads last-turn (most-recent assistant event) usage from a LIVE,
    pre-termination goal-loop session transcript file for the goal-run
    capability probe (issue #874, plan step 1, leg f).
.DESCRIPTION
    This instrument's own job is narrow and deliberately does NOT reimplement
    per-event token extraction: .github/scripts/lib/cost-attribution.ps1's
    Get-EventUsage already does that (and, per issue #873, has been hardened
    against several Hashtable-vs-pscustomobject shape mismatches). This file
    dot-sources cost-attribution.ps1 and calls Get-EventUsage directly rather
    than re-deriving any of that logic.

    What this instrument DOES own: reading a transcript file that may still
    be mid-write (the session it belongs to has not terminated yet), and
    measuring how long that read takes -- Get-EventUsage has no file-I/O
    concept at all; it only operates on an already-parsed event hashtable.

    The result is a three-way discrimination the caller can trust NOT to
    silently collapse absence into zero (the issue #873 defect class):

      usage-unavailable    -- the usage field is absent, the transcript's
                               only readable content is a partial/mid-write
                               tail line, or the located event has the wrong
                               shape (message/usage present but not the
                               expected dictionary type). NEVER reported as
                               zero usage.
      usage-present-zero    -- a well-formed usage object was found and all
                               four token counts are genuinely 0.
      usage-present-nonzero -- a well-formed usage object was found with at
                               least one non-zero token count.

    A truncated/mid-write JSONL tail line (the physically-last non-empty line
    in the file failing to parse) is tolerated: the reader walks backward past
    it to the last well-formed 'assistant' event instead of throwing or
    reporting a false zero, and flags PartialTailDetected so the caller knows
    the very latest write was not yet reflected in the reading.
#>

. (Join-Path $PSScriptRoot 'cost-attribution.ps1')

function Get-GoalProbeLiveUsageReading {
    <#
    .SYNOPSIS
        Reads the last assistant event's per-turn usage from a live,
        possibly-mid-write JSONL transcript file (not summed across the
        session).
    .OUTPUTS
        [pscustomobject] State ('usage-unavailable'|'usage-present-zero'|
        'usage-present-nonzero'), Reason, LastTurnUsage (hashtable from
        Get-EventUsage for the most recent assistant event -- per-event,
        NOT summed across the session -- or $null), ReadLatencyMs,
        LinesRead, PartialTailDetected.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TranscriptPath
    )

    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        return [pscustomobject]@{
            State               = 'usage-unavailable'
            Reason              = 'transcript-not-found'
            LastTurnUsage       = $null
            ReadLatencyMs       = 0.0
            LinesRead           = 0
            PartialTailDetected = $false
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $readError = $null
    $rawLines = @(Get-Content -LiteralPath $TranscriptPath -Encoding utf8 -ErrorAction SilentlyContinue -ErrorVariable readError)
    $stopwatch.Stop()
    $readLatencyMs = $stopwatch.Elapsed.TotalMilliseconds

    # A locked/permission-denied file surfaces as a real error captured via
    # -ErrorVariable (SilentlyContinue only suppresses the terminal throw --
    # it does not discard the error record). Report this distinctly from a
    # genuinely empty transcript so the caller doesn't mistake "could not
    # read" for "nothing written yet".
    if ($readError -and $readError.Count -gt 0) {
        return [pscustomobject]@{
            State               = 'usage-unavailable'
            Reason              = 'transcript-read-error'
            LastTurnUsage       = $null
            ReadLatencyMs       = $readLatencyMs
            LinesRead           = 0
            PartialTailDetected = $false
        }
    }

    if ($rawLines.Count -eq 0) {
        return [pscustomobject]@{
            State               = 'usage-unavailable'
            Reason              = 'transcript-empty'
            LastTurnUsage       = $null
            ReadLatencyMs       = $readLatencyMs
            LinesRead           = 0
            PartialTailDetected = $false
        }
    }

    # Only a parse failure on the physically-last non-empty line counts as the
    # "partial tail" (mid-write) case; an earlier malformed line is unrelated
    # historical noise and is silently skipped the same way blank lines are.
    $lastNonEmptyIdx = -1
    for ($j = $rawLines.Count - 1; $j -ge 0; $j--) {
        if (-not [string]::IsNullOrEmpty($rawLines[$j].Trim())) { $lastNonEmptyIdx = $j; break }
    }

    $partialTailDetected = $false
    $lastGoodEvent = $null
    if ($lastNonEmptyIdx -ge 0) {
        for ($i = $lastNonEmptyIdx; $i -ge 0; $i--) {
            $trimmed = $rawLines[$i].Trim()
            if ([string]::IsNullOrEmpty($trimmed)) { continue }
            $parsed = $null
            try {
                $parsed = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            }
            catch {
                if ($i -eq $lastNonEmptyIdx) { $partialTailDetected = $true }
                continue
            }
            if ($parsed['type'] -eq 'assistant') {
                $lastGoodEvent = $parsed
                break
            }
        }
    }

    if ($null -eq $lastGoodEvent) {
        return [pscustomobject]@{
            State               = 'usage-unavailable'
            Reason              = if ($partialTailDetected) { 'partial-tail-only' } else { 'no-assistant-event' }
            LastTurnUsage       = $null
            ReadLatencyMs       = $readLatencyMs
            LinesRead           = $rawLines.Count
            PartialTailDetected = $partialTailDetected
        }
    }

    $msg = $lastGoodEvent['message']
    if ($null -eq $msg -or $msg -isnot [System.Collections.IDictionary]) {
        return [pscustomobject]@{
            State               = 'usage-unavailable'
            Reason              = 'wrong-event-shape: message'
            LastTurnUsage       = $null
            ReadLatencyMs       = $readLatencyMs
            LinesRead           = $rawLines.Count
            PartialTailDetected = $partialTailDetected
        }
    }

    if (-not $msg.ContainsKey('usage') -or $null -eq $msg['usage']) {
        return [pscustomobject]@{
            State               = 'usage-unavailable'
            Reason              = 'usage-field-absent'
            LastTurnUsage       = $null
            ReadLatencyMs       = $readLatencyMs
            LinesRead           = $rawLines.Count
            PartialTailDetected = $partialTailDetected
        }
    }

    if ($msg['usage'] -isnot [System.Collections.IDictionary]) {
        return [pscustomobject]@{
            State               = 'usage-unavailable'
            Reason              = 'wrong-event-shape: usage'
            LastTurnUsage       = $null
            ReadLatencyMs       = $readLatencyMs
            LinesRead           = $rawLines.Count
            PartialTailDetected = $partialTailDetected
        }
    }

    # A usage dict that is present but has none of the four canonical
    # token-count keys (e.g. renamed keys, or an empty {}) is a wrong-shape
    # event, not genuine zero usage -- Get-EventUsage silently defaults any
    # missing key to 0, so without this guard a renamed-key payload would
    # collapse into a false 'usage-present-zero' (issue #873 defect class).
    $usageDict = $msg['usage']
    $canonicalUsageKeys = @('input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')
    $hasAnyCanonicalKey = $false
    foreach ($key in $canonicalUsageKeys) {
        if ($usageDict.ContainsKey($key)) { $hasAnyCanonicalKey = $true; break }
    }
    if (-not $hasAnyCanonicalKey) {
        return [pscustomobject]@{
            State               = 'usage-unavailable'
            Reason              = 'wrong-event-shape: usage-keys'
            LastTurnUsage       = $null
            ReadLatencyMs       = $readLatencyMs
            LinesRead           = $rawLines.Count
            PartialTailDetected = $partialTailDetected
        }
    }

    # Delegate the actual per-event token extraction to Get-EventUsage
    # (cost-attribution.ps1) -- never reimplemented here.
    $usage = Get-EventUsage -Evt $lastGoodEvent
    $isZero = ($usage['input'] -eq 0 -and $usage['output'] -eq 0 -and $usage['cache_creation'] -eq 0 -and $usage['cache_read'] -eq 0)

    return [pscustomobject]@{
        State               = if ($isZero) { 'usage-present-zero' } else { 'usage-present-nonzero' }
        Reason              = $null
        LastTurnUsage       = $usage
        ReadLatencyMs       = $readLatencyMs
        LinesRead           = $rawLines.Count
        PartialTailDetected = $partialTailDetected
    }
}
