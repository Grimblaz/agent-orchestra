#Requires -Version 7.0
<#
.SYNOPSIS
    Partial-session detection and re-emission preservation for cost telemetry (issue #467, Step 7).
.DESCRIPTION
    Get-SessionCompleteness: classifies a session's event array as complete, partial, or unknown
    by walking events in reverse to find the last assistant event with a stop_reason.

    Resolve-CostDataPreservation: implements the re-emission preservation rule (D10) — prevents
    overwriting a prior complete render with a partial re-run result.
#>

# Partial stop reasons — any of these on the last assistant event → partial
$script:CostCompletenessPartialReasons = [System.Collections.Generic.HashSet[string]]@(
    'refusal', 'pause_turn', 'max_tokens', 'stop_sequence'
)

function script:Test-CostPhaseMarkerOnlySession {
    param(
        [AllowEmptyCollection()][object[]]$Events,
        [string]$Branch = ''
    )

    if ([string]::IsNullOrWhiteSpace($Branch) -or $null -eq $Events -or $Events.Count -eq 0) {
        return $false
    }

    $hasAssistantEvents = $false
    $hasCurrentBranchEvents = $false

    foreach ($evt in $Events) {
        if ($null -eq $evt) { continue }

        if ($evt['type'] -eq 'assistant') {
            $hasAssistantEvents = $true
        }

        $evtBranch = $evt['gitBranch']
        if ($null -ne $evtBranch -and [string]$evtBranch -eq $Branch) {
            $hasCurrentBranchEvents = $true
        }
    }

    return ($hasAssistantEvents -and -not $hasCurrentBranchEvents)
}

function Get-SessionCompleteness {
    <#
    .SYNOPSIS
        Classifies session event array completeness and flags rolling-baseline exclusion.
    .DESCRIPTION
        Walks events in reverse to find the last assistant event with a stop_reason.
        Returns completeness: 'complete' | 'partial' | 'unknown', the stop_reason from
        the last assistant event, and excluded_from_rolling_baseline / exclude_reason.

        For tool_use stop_reason: complete only if a matching tool_result exists in events.
        For end_turn: complete.
        For refusal / pause_turn / max_tokens / stop_sequence / null: partial.
        No assistant events found or empty array: unknown.

        excluded_from_rolling_baseline is true for:
          - partial or unknown sessions (always)
          - phase-marker-only sessions with assistant events but no events on -Branch
          - complete sessions when -ExcludeReason is provided (outlier-PR annotation)
    .PARAMETER Events
        Array of event hashtables (as returned by Invoke-CostTranscriptWalk or similar).
    .PARAMETER ExcludeReason
        When set, marks excluded_from_rolling_baseline: true with this reason even for
        complete sessions (used to annotate outlier PRs such as the foundational #467).
    .PARAMETER Branch
        Current git branch. When supplied, complete sessions with assistant events but no
        event whose gitBranch matches this branch are treated as phase-marker-only and
        excluded from rolling-baseline aggregation while preserving completeness.
    .OUTPUTS
        [hashtable] @{
            completeness:                   'complete' | 'partial' | 'unknown'
            stop_reason:                    <string or $null>
            excluded_from_rolling_baseline: $true | $false
            exclude_reason:                 <string or $null>
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()][object[]]$Events,
        [string]$ExcludeReason = '',
        [string]$Branch = ''
    )

    # Default result
    $completeness = 'unknown'
    $stopReason = $null

    if ($null -ne $Events -and $Events.Count -gt 0) {
        # Walk in reverse to find the last assistant event
        for ($i = $Events.Count - 1; $i -ge 0; $i--) {
            $evt = $Events[$i]
            if ($null -eq $evt) { continue }
            $evtType = $evt['type']
            if ($evtType -ne 'assistant') { continue }

            # Found the last assistant event — extract stop_reason
            # Check message.stop_reason first, then top-level stop_reason
            $msg = $evt['message']
            if ($null -ne $msg) {
                $msgStop = $msg['stop_reason']
                if ($null -ne $msgStop) {
                    $stopReason = [string]$msgStop
                }
            }
            if ($null -eq $stopReason) {
                $topStop = $evt['stop_reason']
                if ($null -ne $topStop) {
                    $stopReason = [string]$topStop
                }
            }

            # Classify based on stop_reason
            if ($null -eq $stopReason -or $stopReason -eq '') {
                $completeness = 'partial'
            }
            elseif ($stopReason -eq 'end_turn') {
                $completeness = 'complete'
            }
            elseif ($stopReason -eq 'tool_use') {
                # Complete only if there is a matching tool_result in the events array
                $hasToolResult = $false

                # Collect all tool_use ids from the last assistant event's message content
                $toolUseIds = [System.Collections.Generic.HashSet[string]]::new()
                if ($null -ne $msg) {
                    $content = $msg['content']
                    if ($null -ne $content) {
                        foreach ($item in $content) {
                            if ($null -eq $item) { continue }
                            if ($item['type'] -eq 'tool_use') {
                                $itemId = $item['id']
                                if ($null -ne $itemId) {
                                    $null = $toolUseIds.Add([string]$itemId)
                                }
                            }
                        }
                    }
                }

                # Search all events for a matching tool_result
                if ($toolUseIds.Count -gt 0) {
                    foreach ($searchEvt in $Events) {
                        if ($null -eq $searchEvt) { continue }
                        # tool_result can be in user event content
                        $searchContent = $searchEvt['content']
                        if ($null -ne $searchContent) {
                            foreach ($item in $searchContent) {
                                if ($null -eq $item) { continue }
                                if ($item['type'] -eq 'tool_result') {
                                    $toolUseId = $item['tool_use_id']
                                    if ($null -ne $toolUseId -and $toolUseIds.Contains([string]$toolUseId)) {
                                        $hasToolResult = $true
                                        break
                                    }
                                }
                            }
                        }
                        if ($hasToolResult) { break }
                    }
                }

                $completeness = if ($hasToolResult) { 'complete' } else { 'partial' }
            }
            elseif ($script:CostCompletenessPartialReasons.Contains($stopReason)) {
                $completeness = 'partial'
            }
            else {
                # Unknown stop_reason value — treat as partial (safe default)
                $completeness = 'partial'
            }

            break  # We only care about the last assistant event
        }
    }

    # Determine excluded_from_rolling_baseline
    $excluded = $false
    $reason = $null
    $phaseMarkerOnly = $false

    if ($completeness -eq 'complete') {
        $phaseMarkerOnly = script:Test-CostPhaseMarkerOnlySession -Events $Events -Branch $Branch
    }

    if ($completeness -eq 'partial' -or $completeness -eq 'unknown') {
        $excluded = $true
        $reason = "session completeness: $completeness"
    }
    elseif ($phaseMarkerOnly) {
        $excluded = $true
        $reason = 'phase-marker-only attribution; rolling-history excluded'
    }
    elseif ($ExcludeReason -ne '') {
        $excluded = $true
        $reason = $ExcludeReason
    }

    return @{
        completeness                   = $completeness
        stop_reason                    = $stopReason
        excluded_from_rolling_baseline = $excluded
        exclude_reason                 = $reason
    }
}

function Resolve-CostDataPreservation {
    <#
    .SYNOPSIS
        Implements the re-emission preservation rule (D10) for cost telemetry.
    .DESCRIPTION
        Given the current completeness result and an optional prior render's completeness
        result, determines whether to use prior data (to avoid overwriting a complete render
        with a partial re-run) or use the current data.

        Populated predicate (token-magnitude, issue #777 s2):
          A populated block (sum of per-port tokens > 0) is never replaced by an empty/zeros
          block regardless of completeness or write order. This prevents CI empty runs from
          clobbering a prior populated local render.
          If current is populated and prior is empty → use current.
          If current is empty and prior is populated → use prior (protect real data).
          Both populated or both empty → fall through to completeness-based logic.

        State combinations (completeness fallback, 9 cases):
          Current = complete                      → use current (fresh data wins)
          Current = partial/unknown, prior = complete → use prior (preserve complete render)
          Both partial/unknown                    → use current (most-recent wins)
          Prior = none                            → use current

        Returns @{ use_prior: bool; notice: string-or-null }
        notice is populated (with prior rendered_at timestamp) when use_prior is true.
    .PARAMETER Current
        Hashtable with at least a 'completeness' key (from Get-SessionCompleteness).
    .PARAMETER Prior
        Optional prior render's completeness hashtable. Pass $null or omit when no prior exists.
    .PARAMETER CurrentTokenSum
        Sum of all per-port token counts (input + output + cache_creation + cache_read) for the
        current session. Used by the populated predicate. Default 0.
    .PARAMETER PriorTokenSum
        Sum of all per-port token counts for the prior render. Used by the populated predicate.
        Default 0.
    .OUTPUTS
        [hashtable] @{ use_prior: $true | $false; notice: <string or $null> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Current,
        [hashtable]$Prior = $null,
        [long]$CurrentTokenSum = 0,
        [long]$PriorTokenSum = 0
    )

    # Populated predicate: token-magnitude takes precedence over completeness string
    # populated = sum(per-port tokens) > 0; a populated block is never replaced by an empty one
    $currentPopulated = $CurrentTokenSum -gt 0
    $priorPopulated = $PriorTokenSum -gt 0

    if ($currentPopulated -and -not $priorPopulated) {
        # Current has real data; prior is empty/zeros → current wins regardless of completeness
        return @{ use_prior = $false; notice = $null }
    }

    if (-not $currentPopulated -and $priorPopulated) {
        # Current is empty; prior has real data → protect the populated prior
        $priorTimestamp = if ($null -ne $Prior) { $Prior['rendered_at'] } else { $null }
        $noticeText = 'Re-emission preservation (populated): current session has no token data; prior populated render'
        if ($null -ne $priorTimestamp -and $priorTimestamp -ne '') {
            $noticeText += " (rendered_at: $priorTimestamp)"
        }
        $noticeText += ' was kept to avoid losing real cost data.'
        return @{ use_prior = $true; notice = $noticeText }
    }

    # Both populated or both empty: fall through to completeness-based logic
    $currentCompleteness = $Current['completeness']

    # Current = complete → always use current (fresh data wins regardless of prior)
    if ($currentCompleteness -eq 'complete') {
        return @{ use_prior = $false; notice = $null }
    }

    # Current is partial or unknown
    if ($null -ne $Prior) {
        $priorCompleteness = $Prior['completeness']

        if ($priorCompleteness -eq 'complete') {
            # Preserve the prior complete render
            $priorTimestamp = $Prior['rendered_at']
            $noticeText = "Re-emission preservation: current session is $currentCompleteness; prior complete render"
            if ($null -ne $priorTimestamp -and $priorTimestamp -ne '') {
                $noticeText += " (rendered_at: $priorTimestamp)"
            }
            $noticeText += ' was kept to avoid contaminating rolling baselines.'
            return @{ use_prior = $true; notice = $noticeText }
        }
    }

    # Both partial/unknown, or prior = none → most-recent (current) wins
    return @{ use_prior = $false; notice = $null }
}
