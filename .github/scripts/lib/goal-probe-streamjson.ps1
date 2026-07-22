#Requires -Version 7.0
<#
.SYNOPSIS
    Parses a headless `claude -p --output-format stream-json` terminal `result`
    event for the goal-run capability probe (issue #874, plan step 1, leg d).
.DESCRIPTION
    A capability-probe instrument, not the production harness itself (that is
    later #874 scope). Its one job: given a single raw stream-json line that is
    expected to be the session's terminal `result` event, extract the fields a
    downstream budget/outcome decision needs (`total_cost_usd`, `num_turns`) and
    classify the session's terminal outcome into exactly one of:

      satisfied          -- the run's own final assistant text carries the
                             goal-loop protocol's structured status tag
                             (<goal-status>satisfied</goal-status>) AND the
                             claude CLI itself reported a clean, non-error
                             success subtype, meaning IsError is EXACTLY
                             $false. IsError $null (indeterminate) never
                             reaches this branch.
      judged-impossible   -- same tag convention, status=impossible; the same
                             IsError -eq $false requirement applies.
      stopped             -- everything else: a `claude` CLI error subtype
                             (error_max_turns, error_during_execution, ...),
                             an error result with no goal-status tag, a
                             success result that never emitted the tag at all
                             (protocol violation -- treated as an unclassified
                             stop rather than guessed as satisfied), or an
                             event whose is_error could not be determined
                             (IsError $null -- see .OUTPUTS below).

    IsError is TRI-STATE ($true | $false | $null). $null means "could not
    determine" (the is_error key was absent, or arrived non-Boolean) and is
    NOT a synonym for $false. Consumers must test `$r.IsError -eq $false`,
    never `-not $r.IsError` -- the latter coerces the indeterminate state
    into "no error", which is exactly the fail-open direction this
    instrument refuses to take.

    A malformed line (unparseable JSON -- including a truncated/mid-write
    partial JSONL tail line) or a well-formed non-`result`-type event is
    REJECTED (returns $null) rather than guessed at; a caller must not
    interpret $null as any of the three real outcomes.

    Goal-loop status-tag convention: this instrument assumes the goal-loop's
    own system prompt directs the evaluating agent to close its final turn
    with a literal `<goal-status>satisfied</goal-status>` or
    `<goal-status>impossible</goal-status>` tag. This is a probe-stage
    assumption, not yet a design-locked contract -- if the eventual harness
    plan settles on a different signaling convention,
    $script:GoalProbeStatusTagPattern is the single point of truth to update.
#>

$script:GoalProbeStatusTagPattern = '(?is)<goal-status>\s*(?<status>satisfied|impossible)\s*</goal-status>'

function Get-GoalProbeStreamJsonResult {
    <#
    .SYNOPSIS
        Parses one raw stream-json line as a terminal `result` event.
    .OUTPUTS
        [pscustomobject] with TotalCostUsd, NumTurns, Outcome
        ('satisfied'|'judged-impossible'|'stopped'), Subtype, and IsError
        ($true | $false | $null) -- or $null (the whole object) when the line
        is malformed, a partial/truncated tail line, or not a `result`-type
        event.

        IsError is tri-state: $true (CLI reported an error), $false (CLI
        reported no error), or $null meaning UNDETERMINABLE -- the is_error
        key was absent, or present with a non-Boolean value (e.g. the string
        "false"). $null is NOT equivalent to $false. Only IsError -eq $false
        can produce the 'satisfied' (or 'judged-impossible') outcome; an
        indeterminate event always classifies as 'stopped'. Test explicitly
        with `-eq $false`; `if (-not $r.IsError)` treats $null as "no error"
        and reintroduces the fail-open coercion this contract removes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $trimmed = $Line.Trim()
    $evt = $null
    try {
        $evt = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        # Malformed JSON -- including a truncated/mid-write partial JSONL tail
        # line -- is rejected, never guessed at.
        return $null
    }

    if ($null -eq $evt -or $evt -isnot [System.Collections.IDictionary] -or $evt['type'] -ne 'result') { return $null }

    $subtype = [string]$evt['subtype']
    $resultText = [string]$evt['result']

    # Hostile input for is_error must not silently default to $false --
    # that is the dangerous fail-open direction (it would classify an
    # indeterminate event as non-error and let it flow into the
    # 'satisfied' branch below). A missing key or a non-Boolean value
    # (e.g. the string "false") degrades to $null, meaning "could not
    # determine", mirroring this function's established hostile-input
    # convention for total_cost_usd/num_turns below.
    $isError = $null
    if ($evt.ContainsKey('is_error') -and $evt['is_error'] -is [bool]) {
        $isError = $evt['is_error']
    }

    # Hostile input (e.g. a wrong-typed field, such as total_cost_usd
    # arriving as a JSON object instead of a number) must degrade to $null
    # for that field rather than throwing -- consistent with this
    # instrument's general "hostile input degrades gracefully" posture.
    $totalCostUsd = $null
    if ($evt.ContainsKey('total_cost_usd') -and $null -ne $evt['total_cost_usd']) {
        try {
            $totalCostUsd = [double]$evt['total_cost_usd']
        }
        catch {
            $totalCostUsd = $null
        }
    }
    $numTurns = $null
    if ($evt.ContainsKey('num_turns') -and $null -ne $evt['num_turns']) {
        try {
            $numTurns = [int]$evt['num_turns']
        }
        catch {
            $numTurns = $null
        }
    }

    $outcome = 'stopped'
    if ($isError -eq $false -and $subtype -eq 'success' -and -not [string]::IsNullOrEmpty($resultText)) {
        # The documented convention is that the agent closes its FINAL turn
        # with the authoritative status tag; a result string can carry more
        # than one tag-shaped substring (e.g. quoted/echoed earlier text),
        # so the LAST match -- not the first -- is authoritative.
        $tagMatches = [regex]::Matches($resultText, $script:GoalProbeStatusTagPattern)
        if ($tagMatches.Count -gt 0) {
            $lastTagMatch = $tagMatches[$tagMatches.Count - 1]
            $outcome = if ($lastTagMatch.Groups['status'].Value.ToLowerInvariant() -eq 'satisfied') { 'satisfied' } else { 'judged-impossible' }
        }
    }

    return [pscustomobject]@{
        TotalCostUsd = $totalCostUsd
        NumTurns     = $numTurns
        Outcome      = $outcome
        Subtype      = $subtype
        IsError      = $isError
    }
}
