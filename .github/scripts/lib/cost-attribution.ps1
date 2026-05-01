#Requires -Version 7.0
<#
.SYNOPSIS
    Cost attribution for cost-telemetry (issue #467, Step 3).
.DESCRIPTION
    Takes an array of events returned by Invoke-CostTranscriptWalk, attributes cost
    to ports via the D5 agentType->port mapping, computes orchestrator-overhead for
    non-port-attributed parent turns, and returns the structured attribution result.

    Relies only on the events array passed in — no file I/O beyond the rate table.
#>

# D5 agentType->port mapping table (case-insensitive keys)
$script:CostAttributionPortMap = [System.Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$script:CostAttributionPortMap.Add('agent-orchestra:Experience-Owner', 'experience')
$script:CostAttributionPortMap.Add('experience-owner', 'experience')
$script:CostAttributionPortMap.Add('agent-orchestra:Solution-Designer', 'design')
$script:CostAttributionPortMap.Add('solution-designer', 'design')
$script:CostAttributionPortMap.Add('agent-orchestra:Issue-Planner', 'plan')
$script:CostAttributionPortMap.Add('issue-planner', 'plan')
$script:CostAttributionPortMap.Add('agent-orchestra:Code-Smith', 'implement-code')
$script:CostAttributionPortMap.Add('code-smith', 'implement-code')
$script:CostAttributionPortMap.Add('agent-orchestra:Test-Writer', 'implement-test')
$script:CostAttributionPortMap.Add('test-writer', 'implement-test')
$script:CostAttributionPortMap.Add('agent-orchestra:Refactor-Specialist', 'implement-refactor')
$script:CostAttributionPortMap.Add('refactor-specialist', 'implement-refactor')
$script:CostAttributionPortMap.Add('agent-orchestra:Doc-Keeper', 'implement-docs')
$script:CostAttributionPortMap.Add('doc-keeper', 'implement-docs')
$script:CostAttributionPortMap.Add('agent-orchestra:Code-Critic', 'review')
$script:CostAttributionPortMap.Add('code-critic', 'review')
$script:CostAttributionPortMap.Add('agent-orchestra:Code-Review-Response', 'review')
$script:CostAttributionPortMap.Add('code-review-response', 'review')
$script:CostAttributionPortMap.Add('agent-orchestra:Process-Review', 'process-review')
$script:CostAttributionPortMap.Add('process-review', 'process-review')
$script:CostAttributionPortMap.Add('agent-orchestra:UI-Iterator', 'implement-code')
$script:CostAttributionPortMap.Add('ui-iterator', 'implement-code')
$script:CostAttributionPortMap.Add('agent-orchestra:Research-Agent', 'plan')
$script:CostAttributionPortMap.Add('research-agent', 'plan')
$script:CostAttributionPortMap.Add('agent-orchestra:Code-Conductor', 'orchestrator-overhead')
$script:CostAttributionPortMap.Add('code-conductor', 'orchestrator-overhead')
$script:CostAttributionPortMap.Add('Explore', 'orchestrator-overhead')
$script:CostAttributionPortMap.Add('general-purpose', 'dispatches.general_purpose')
$script:CostAttributionPortMap.Add('claude-code-guide', 'orchestrator-overhead')

function Get-AgentTypePort {
    <#
    .SYNOPSIS
        Maps an agentType string to a port name via the D5 table.
    .OUTPUTS
        [string] Port name, 'dispatches.general_purpose', 'orchestrator-overhead',
        or 'unattributed-dispatch' for unknowns.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$AgentType
    )

    $portValue = $null
    if ($script:CostAttributionPortMap.TryGetValue($AgentType, [ref]$portValue)) {
        return $portValue
    }
    return 'unattributed-dispatch'
}

function New-PortBucket {
    <#
    .SYNOPSIS
        Creates a zeroed port-level token/cost bucket.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        tokens                   = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
        cost_estimate_usd        = 0.0
        dispatch_count           = 0
        null_cost_events         = 0
        cache_read_hit_ratio     = 0.0
        parallel_dispatch_groups = 0
        mixed_regime             = $false
        prompt_size_chars        = 0
    }
}

function New-OverheadBucket {
    <#
    .SYNOPSIS
        Creates a zeroed orchestrator-overhead bucket (no dispatch_count).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        tokens               = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
        cost_estimate_usd    = 0.0
        null_cost_events     = 0
        cache_read_hit_ratio = 0.0
    }
}

function Get-EventUsage {
    <#
    .SYNOPSIS
        Extracts usage token counts from an event hashtable.
    .OUTPUTS
        [hashtable] with input, output, cache_creation, cache_read (all ints, defaulting to 0).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Evt
    )

    $msg = $Evt['message']
    if ($null -eq $msg) {
        return @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
    }

    $usage = $msg['usage']
    if ($null -eq $usage) {
        return @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
    }

    $inputTok = [int]($usage['input_tokens'] ?? 0)
    $outputTok = [int]($usage['output_tokens'] ?? 0)
    $cacheCreation = [int]($usage['cache_creation_input_tokens'] ?? 0)
    $cacheRead = [int]($usage['cache_read_input_tokens'] ?? 0)

    return @{ input = $inputTok; output = $outputTok; cache_creation = $cacheCreation; cache_read = $cacheRead }
}

function Get-EventModel {
    <#
    .SYNOPSIS
        Extracts the model name from an event. Checks message.model and message.usage.model.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Evt
    )

    $msg = $Evt['message']
    if ($null -eq $msg) { return $null }

    $modelName = $msg['model']
    if ($null -ne $modelName -and $modelName -ne '') { return [string]$modelName }

    $usage = $msg['usage']
    if ($null -ne $usage) {
        $usageModel = $usage['model']
        if ($null -ne $usageModel -and $usageModel -ne '') { return [string]$usageModel }
    }

    return $null
}

function Add-TokensToAccumulator {
    <#
    .SYNOPSIS
        Adds token counts from a usage hashtable into an accumulator hashtable in-place.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Accumulator,
        [Parameter(Mandatory)][hashtable]$Usage
    )

    $Accumulator['input'] += $Usage['input']
    $Accumulator['output'] += $Usage['output']
    $Accumulator['cache_creation'] += $Usage['cache_creation']
    $Accumulator['cache_read'] += $Usage['cache_read']
}

function Add-CostToBucket {
    <#
    .SYNOPSIS
        Computes cost for one event's tokens and adds it to the bucket's cost_estimate_usd.
        Increments null_cost_events when the model is unknown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Bucket,
        [Parameter(Mandatory)][hashtable]$Usage,
        [AllowNull()][string]$Model,
        [Parameter(Mandatory)][hashtable]$RatesByModel
    )

    if ($null -eq $Model -or -not $RatesByModel.ContainsKey($Model)) {
        Write-Warning "cost-attribution: unknown model '$Model' — cost contribution is null; incrementing null_cost_events"
        $Bucket['null_cost_events'] += 1
        return
    }

    $rates = $RatesByModel[$Model]
    $cost = (
        $Usage['input'] * $rates['input_per_mtok'] +
        $Usage['output'] * $rates['output_per_mtok'] +
        $Usage['cache_creation'] * $rates['cache_creation_per_mtok'] +
        $Usage['cache_read'] * $rates['cache_read_per_mtok']
    ) / 1000000.0

    $Bucket['cost_estimate_usd'] += $cost
}

function Set-CacheHitRatio {
    <#
    .SYNOPSIS
        Computes cache_read_hit_ratio for a bucket in-place.
        Formula: cache_read / (cache_read + cache_creation + input) — output excluded per D4.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Bucket
    )

    $tokens = $Bucket['tokens']
    $denom = $tokens['cache_read'] + $tokens['cache_creation'] + $tokens['input']
    if ($denom -gt 0) {
        $Bucket['cache_read_hit_ratio'] = [double]$tokens['cache_read'] / [double]$denom
    }
    else {
        $Bucket['cache_read_hit_ratio'] = 0.0
    }
}

function Get-CostAttribution {
    <#
    .SYNOPSIS
        Attributes cost to ports from cost-transcript events.
    .DESCRIPTION
        Takes an array of events (from Invoke-CostTranscriptWalk), maps each assistant
        event's Agent dispatches to ports via the D5 table, accumulates tokens and costs,
        and returns a structured attribution hashtable.
    .PARAMETER Events
        Array of event hashtables as returned by Invoke-CostTranscriptWalk.
    .PARAMETER RateTablePath
        Path to cost-rate-table.json. Defaults to cost-rate-table.json in same lib dir.
    .OUTPUTS
        [hashtable] with keys: ports, orchestrator_overhead, dispatches, totals
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [string]$RateTablePath = ''
    )

    # Resolve rate table path
    if (-not $RateTablePath) {
        $RateTablePath = Join-Path (Split-Path -Parent $PSCommandPath) 'cost-rate-table.json'
    }

    # Load rate table
    $ratesByModel = @{}
    if (Test-Path -LiteralPath $RateTablePath) {
        try {
            $tableJson = Get-Content -Path $RateTablePath -Raw | ConvertFrom-Json -AsHashtable
            $rawRates = $tableJson['rates']
            if ($null -ne $rawRates) {
                foreach ($modelKey in $rawRates.Keys) {
                    $rateEntry = $rawRates[$modelKey]
                    $ratesByModel[$modelKey] = @{
                        input_per_mtok          = [double]$rateEntry['input_per_mtok']
                        output_per_mtok         = [double]$rateEntry['output_per_mtok']
                        cache_creation_per_mtok = [double]$rateEntry['cache_creation_per_mtok']
                        cache_read_per_mtok     = [double]$rateEntry['cache_read_per_mtok']
                    }
                }
            }
        }
        catch {
            Write-Warning "cost-attribution: failed to load rate table from '$RateTablePath': $_"
        }
    }
    else {
        Write-Warning "cost-attribution: rate table not found at '$RateTablePath'"
    }

    # Result structure
    $ports = @{}
    $overhead = New-OverheadBucket
    $dispatches = @{ general_purpose_count = 0; unattributed_count = 0 }
    $totals = @{
        tokens            = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
        cost_estimate_usd = 0.0
    }

    # The cost-walker inserts subagent events immediately after the parent event that
    # triggered them. We track the "current context bucket" as we iterate: after a parent
    # event with a dispatch, subsequent subagent events (no cwd) inherit that bucket until
    # the next parent event resets it.
    $currentSubagentBuckets = $null  # list of buckets subagent events should feed into

    foreach ($evt in $Events) {
        $evtType = $evt['type']
        if ($evtType -ne 'assistant') { continue }

        $usage = Get-EventUsage -Evt $evt
        $model = Get-EventModel -Evt $evt

        # Determine if this is a parent (has cwd) or subagent (no cwd) event.
        # Subagent events are loaded from subagent transcripts and have no cwd/gitBranch.
        $hasCwd = ($null -ne $evt['cwd'])

        if ($hasCwd) {
            # Reset subagent context — we're at a new parent turn
            $currentSubagentBuckets = $null

            # Find all Agent tool_use items in message.content
            $msgContent = $evt['message']?['content']
            $agentDispatches = [System.Collections.Generic.List[hashtable]]::new()

            if ($null -ne $msgContent) {
                foreach ($item in $msgContent) {
                    if ($null -eq $item) { continue }
                    $itemType = $item['type']
                    $itemName = $item['name']
                    if ($itemType -eq 'tool_use' -and $itemName -eq 'Agent') {
                        $subagentType = $item['input']?['subagent_type']
                        if ($null -ne $subagentType) {
                            # Measure prompt size for D4 prompt_size.per_dispatch.avg.chars metric
                            $promptChars = 0
                            $dispatchInput = $item['input']
                            if ($null -ne $dispatchInput) {
                                $promptText = $dispatchInput['prompt']
                                if ($null -ne $promptText) {
                                    $promptChars = ([string]$promptText).Length
                                }
                            }
                            $agentDispatches.Add(@{
                                    subagent_type = [string]$subagentType
                                    id            = $item['id']
                                    prompt_chars  = $promptChars
                                })
                        }
                    }
                }
            }

            if ($agentDispatches.Count -eq 0) {
                # No dispatch — orchestrator-overhead
                Add-TokensToAccumulator -Accumulator $overhead['tokens'] -Usage $usage
                Add-CostToBucket -Bucket $overhead -Usage $usage -Model $model -RatesByModel $ratesByModel
                $currentSubagentBuckets = @($overhead)
            }
            else {
                # Map each dispatch to its port and increment dispatch_count
                $portNames = [System.Collections.Generic.List[string]]::new()
                $generalPurposeCount = 0
                $unattributedCount = 0

                foreach ($dispatch in $agentDispatches) {
                    $mappedPort = Get-AgentTypePort -AgentType $dispatch['subagent_type']

                    if ($mappedPort -eq 'dispatches.general_purpose') {
                        $generalPurposeCount++
                        $portNames.Add('dispatches.general_purpose')
                    }
                    elseif ($mappedPort -eq 'unattributed-dispatch') {
                        $unattributedCount++
                        $portNames.Add('unattributed-dispatch')
                    }
                    else {
                        if (-not $ports.ContainsKey($mappedPort)) {
                            $ports[$mappedPort] = New-PortBucket
                        }
                        $ports[$mappedPort]['dispatch_count'] += 1
                        # Accumulate prompt_size_chars per dispatch (D4 prompt_size metric)
                        $ports[$mappedPort]['prompt_size_chars'] += [int]$dispatch['prompt_chars']
                        $portNames.Add($mappedPort)
                    }
                }

                $dispatches['general_purpose_count'] += $generalPurposeCount
                $dispatches['unattributed_count'] += $unattributedCount

                # Determine the primary port for this parent turn's token attribution:
                # Use the first non-overhead, non-unattributed, non-general-purpose port.
                # If all are overhead/unattributed/general-purpose, treat accordingly.
                $primaryPort = $null
                foreach ($pName in $portNames) {
                    if ($pName -ne 'orchestrator-overhead' -and
                        $pName -ne 'unattributed-dispatch' -and
                        $pName -ne 'dispatches.general_purpose') {
                        $primaryPort = $pName
                        break
                    }
                }

                # Detect D13 parallel dispatch groups:
                # Multiple dispatches to the same port in one parent turn = parallel group.
                $portDispatchCounts = @{}
                foreach ($pName in $portNames) {
                    if ($pName -ne 'orchestrator-overhead' -and
                        $pName -ne 'unattributed-dispatch' -and
                        $pName -ne 'dispatches.general_purpose') {
                        if (-not $portDispatchCounts.ContainsKey($pName)) {
                            $portDispatchCounts[$pName] = 0
                        }
                        $portDispatchCounts[$pName] += 1
                    }
                }
                foreach ($pName in $portDispatchCounts.Keys) {
                    if ($portDispatchCounts[$pName] -gt 1) {
                        if (-not $ports.ContainsKey($pName)) {
                            $ports[$pName] = New-PortBucket
                        }
                        $ports[$pName]['parallel_dispatch_groups'] += 1
                        $ports[$pName]['mixed_regime'] = $true
                    }
                }

                if ($null -ne $primaryPort) {
                    if (-not $ports.ContainsKey($primaryPort)) {
                        $ports[$primaryPort] = New-PortBucket
                    }
                    Add-TokensToAccumulator -Accumulator $ports[$primaryPort]['tokens'] -Usage $usage
                    Add-CostToBucket -Bucket $ports[$primaryPort] -Usage $usage -Model $model -RatesByModel $ratesByModel
                    $currentSubagentBuckets = @($ports[$primaryPort])
                }
                elseif ($generalPurposeCount -gt 0) {
                    # general-purpose dispatch: tokens count under dispatches.general_purpose (not overhead)
                    if (-not $ports.ContainsKey('dispatches.general_purpose')) {
                        $ports['dispatches.general_purpose'] = New-PortBucket
                    }
                    Add-TokensToAccumulator -Accumulator $ports['dispatches.general_purpose']['tokens'] -Usage $usage
                    Add-CostToBucket -Bucket $ports['dispatches.general_purpose'] -Usage $usage -Model $model -RatesByModel $ratesByModel
                    $currentSubagentBuckets = @($ports['dispatches.general_purpose'])
                }
                else {
                    # All dispatches were to unattributed-dispatch — use overhead for parent tokens
                    Add-TokensToAccumulator -Accumulator $overhead['tokens'] -Usage $usage
                    Add-CostToBucket -Bucket $overhead -Usage $usage -Model $model -RatesByModel $ratesByModel
                    $currentSubagentBuckets = @($overhead)
                }
            }
        }
        else {
            # Subagent event — inherit the current port context from the last parent turn
            if ($null -ne $currentSubagentBuckets -and $currentSubagentBuckets.Count -gt 0) {
                # Attribute subagent tokens to the primary port bucket from parent's context
                $targetBucket = $currentSubagentBuckets[0]
                Add-TokensToAccumulator -Accumulator $targetBucket['tokens'] -Usage $usage
                Add-CostToBucket -Bucket $targetBucket -Usage $usage -Model $model -RatesByModel $ratesByModel
            }
            else {
                # No context established — attribute to overhead
                Add-TokensToAccumulator -Accumulator $overhead['tokens'] -Usage $usage
                Add-CostToBucket -Bucket $overhead -Usage $usage -Model $model -RatesByModel $ratesByModel
            }
        }

        # Accumulate into totals regardless of bucket
        Add-TokensToAccumulator -Accumulator $totals['tokens'] -Usage $usage
        if ($null -ne $model -and $ratesByModel.ContainsKey($model)) {
            $rates = $ratesByModel[$model]
            $totals['cost_estimate_usd'] += (
                $usage['input'] * $rates['input_per_mtok'] +
                $usage['output'] * $rates['output_per_mtok'] +
                $usage['cache_creation'] * $rates['cache_creation_per_mtok'] +
                $usage['cache_read'] * $rates['cache_read_per_mtok']
            ) / 1000000.0
        }
    }

    # Finalize cache_read_hit_ratio for all port buckets and overhead
    foreach ($portBucket in $ports.Values) {
        Set-CacheHitRatio -Bucket $portBucket
    }
    Set-CacheHitRatio -Bucket $overhead

    return @{
        ports                 = $ports
        orchestrator_overhead = $overhead
        dispatches            = $dispatches
        totals                = $totals
    }
}
