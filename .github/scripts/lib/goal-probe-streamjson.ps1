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
                             success subtype.
      judged-impossible   -- same tag convention, status=impossible.
      stopped             -- everything else: a `claude` CLI error subtype
                             (error_max_turns, error_during_execution, ...),
                             an error result with no goal-status tag, or a
                             success result that never emitted the tag at all
                             (protocol violation -- treated as an unclassified
                             stop rather than guessed as satisfied).

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
        ('satisfied'|'judged-impossible'|'stopped'), Subtype, IsError -- or
        $null when the line is malformed, a partial/truncated tail line, or
        not a `result`-type event.
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

    if ($null -eq $evt -or $evt['type'] -ne 'result') { return $null }

    $subtype = [string]$evt['subtype']
    $isError = [bool]$evt['is_error']
    $resultText = [string]$evt['result']

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
    if (-not $isError -and $subtype -eq 'success' -and -not [string]::IsNullOrEmpty($resultText)) {
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
