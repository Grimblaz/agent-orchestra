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
$script:CostAttributionPortMap.Add('GitHub Copilot Chat', 'orchestrator-overhead')
$script:CostAttributionPortMap.Add('general-purpose', 'dispatches.general_purpose')
$script:CostAttributionPortMap.Add('claude-code-guide', 'orchestrator-overhead')

function Get-NormalizedCostProvider {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$Provider,
        [string]$Default = 'claude'
    )

    if ($null -eq $Provider -or [string]::IsNullOrWhiteSpace([string]$Provider)) {
        return $Default.ToLowerInvariant()
    }

    return ([string]$Provider).ToLowerInvariant()
}

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

function New-ProviderCostBucket {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        tokens               = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
        dispatch_count       = 0
        prompt_size_chars    = 0
        cost_estimate_usd    = 0.0
        cache_read_hit_ratio = 0.0
        null_cost_events     = 0
        mixed_regime         = $false
    }
}

function Get-OrAddProviderCostBucket {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Bucket,
        [Parameter(Mandatory)][string]$ProviderName
    )

    if (-not $Bucket.ContainsKey('providers') -or -not ($Bucket['providers'] -is [hashtable])) {
        $Bucket['providers'] = @{}
    }
    if (-not $Bucket['providers'].ContainsKey($ProviderName)) {
        $Bucket['providers'][$ProviderName] = New-ProviderCostBucket
    }

    return $Bucket['providers'][$ProviderName]
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

function Get-EventProvider {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Evt
    )

    $provider = $Evt['provider']
    if ($null -ne $provider -and -not [string]::IsNullOrWhiteSpace([string]$provider)) {
        return Get-NormalizedCostProvider -Provider $provider
    }

    $cwd = $Evt['cwd']
    if ($null -ne $cwd -and [string]$cwd -like 'copilot-otel://*') {
        return 'copilot'
    }

    $agentType = $Evt['agentType']
    if ($null -ne $agentType -and [string]$agentType -eq 'GitHub Copilot Chat') {
        return 'copilot'
    }

    return 'claude'
}

function Test-EventCacheMetricUnavailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Evt,
        [Parameter(Mandatory)][string]$Provider
    )

    if ((Get-NormalizedCostProvider -Provider $Provider) -ne 'copilot') { return $false }

    $msg = $Evt['message']
    if ($null -eq $msg) { return $true }

    $usage = $msg['usage']
    if ($null -eq $usage) { return $true }

    if (-not $usage.ContainsKey('cache_creation_input_tokens') -or -not $usage.ContainsKey('cache_read_input_tokens')) { return $true }
    return ($null -eq $usage['cache_creation_input_tokens'] -or $null -eq $usage['cache_read_input_tokens'])
}

function Get-CostRateLookupKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Model
    )

    return "$((Get-NormalizedCostProvider -Provider $Provider))`n$Model"
}

function New-CostRateTableEntry {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ModelKey,
        [Parameter(Mandatory)][hashtable]$RateEntry,
        [Parameter(Mandatory)][hashtable]$TableJson
    )

    $entryProvider = Get-NormalizedCostProvider -Provider $RateEntry['provider']
    $entryModel = if ($RateEntry.ContainsKey('model') -and -not [string]::IsNullOrWhiteSpace([string]$RateEntry['model'])) { [string]$RateEntry['model'] } else { $ModelKey }

    return @{
        provider                 = $entryProvider
        model                    = $entryModel
        input_per_mtok           = ConvertTo-NullableRateValue -Value $RateEntry['input_per_mtok']
        output_per_mtok          = ConvertTo-NullableRateValue -Value $RateEntry['output_per_mtok']
        cache_creation_per_mtok  = ConvertTo-NullableRateValue -Value $RateEntry['cache_creation_per_mtok']
        cache_read_per_mtok      = ConvertTo-NullableRateValue -Value $RateEntry['cache_read_per_mtok']
        rate_source_url          = if ($RateEntry.ContainsKey('rate_source_url')) { $RateEntry['rate_source_url'] } else { $TableJson['rate_source_url'] }
    }
}

function ConvertTo-NullableRateValue {
    [OutputType([object])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    return [double]$Value
}

function Get-CostRateTableFreshness {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RatesAsOf,
        [string]$Provider = 'claude',
        [string]$Now = ''
    )

    $providerName = Get-NormalizedCostProvider -Provider $Provider
    $staleAfterDays = if ($providerName -eq 'copilot') { 30 } else { 90 }
    $nowValue = if ([string]::IsNullOrWhiteSpace($Now)) { (Get-Date).ToUniversalTime() } else { ([datetime]$Now).ToUniversalTime() }
    $ratesDate = ([datetime]$RatesAsOf).ToUniversalTime()
    $ageDays = [int][Math]::Floor(($nowValue - $ratesDate).TotalDays)

    return @{
        provider         = $providerName
        rates_as_of      = $RatesAsOf
        age_days         = $ageDays
        stale_after_days = $staleAfterDays
        is_stale         = ($ageDays -gt $staleAfterDays)
    }
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

function Add-TokensToProviderAccumulator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Accumulator,
        [Parameter(Mandatory)][hashtable]$Usage,
        [bool]$CacheMetricUnavailable = $false
    )

    $Accumulator['input'] += $Usage['input']
    $Accumulator['output'] += $Usage['output']

    if ($CacheMetricUnavailable) {
        $Accumulator['cache_creation'] = $null
        $Accumulator['cache_read'] = $null
        return
    }

    if ($null -eq $Accumulator['cache_creation']) { $Accumulator['cache_creation'] = 0 }
    if ($null -eq $Accumulator['cache_read']) { $Accumulator['cache_read'] = 0 }
    $Accumulator['cache_creation'] += $Usage['cache_creation']
    $Accumulator['cache_read'] += $Usage['cache_read']
}

function Get-CostEstimateFromUsage {
    <#
    .SYNOPSIS
        Computes the USD cost estimate for one usage/rate pair.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][hashtable]$Usage,
        [Parameter(Mandatory)][hashtable]$Rates
    )

    foreach ($field in @('input_per_mtok', 'output_per_mtok', 'cache_creation_per_mtok', 'cache_read_per_mtok')) {
        if ($null -eq $Rates[$field]) { return $null }
    }

    return (
        $Usage['input'] * $Rates['input_per_mtok'] +
        $Usage['output'] * $Rates['output_per_mtok'] +
        $Usage['cache_creation'] * $Rates['cache_creation_per_mtok'] +
        $Usage['cache_read'] * $Rates['cache_read_per_mtok']
    ) / 1000000.0
}

function Add-CostAttributionWarning {
    param(
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][System.Collections.Generic.List[string]]$WarningMessages = $null
    )

    if ($null -ne $WarningMessages) {
        $WarningMessages.Add($Message)
        return
    }

    Write-Warning $Message
}

function Add-NullCostEventToBucket {
    param(
        [Parameter(Mandatory)][hashtable]$Bucket,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][System.Collections.Generic.List[string]]$WarningMessages = $null
    )

    Add-CostAttributionWarning -Message $Message -WarningMessages $WarningMessages
    $Bucket['null_cost_events'] += 1
    if ($Bucket['cost_estimate_usd'] -eq 0.0) { $Bucket['cost_estimate_usd'] = $null }
}

function Write-CostAttributionWarningRecord {
    param(
        [AllowEmptyCollection()][System.Collections.Generic.List[string]]$WarningMessages,
        [AllowNull()][string]$WarningVariableName = $null
    )

    foreach ($warningMessage in $WarningMessages) {
        Write-Warning $warningMessage
    }

    if ([string]::IsNullOrWhiteSpace($WarningVariableName)) { return }

    $append = $WarningVariableName.StartsWith('+')
    $variableName = $WarningVariableName.TrimStart('+')
    if ([string]::IsNullOrWhiteSpace($variableName)) { return }

    $warningValues = @($WarningMessages.ToArray())
    foreach ($scope in @(1, 2)) {
        try {
            if ($append) {
                $existing = @(Get-Variable -Name $variableName -Scope $scope -ValueOnly -ErrorAction SilentlyContinue)
                Set-Variable -Name $variableName -Value @($existing + $warningValues) -Scope $scope -ErrorAction SilentlyContinue
            }
            else {
                Set-Variable -Name $variableName -Value $warningValues -Scope $scope -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Verbose "cost-attribution: warning variable scope mirror failed: $_"
        }
    }
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
        [string]$Provider = 'claude',
        [Parameter(Mandatory)][hashtable]$RatesByProviderModel,
        [AllowNull()][System.Collections.Generic.List[string]]$WarningMessages = $null
    )

    if ($null -eq $Model -or [string]::IsNullOrWhiteSpace($Model)) {
        Add-NullCostEventToBucket -Bucket $Bucket -Message "cost-attribution: unknown model '$Model' for provider '$Provider' — cost contribution is null; incrementing null_cost_events" -WarningMessages $WarningMessages
        return
    }

    $lookupKey = Get-CostRateLookupKey -Provider $Provider -Model $Model
    if (-not $RatesByProviderModel.ContainsKey($lookupKey)) {
        Add-NullCostEventToBucket -Bucket $Bucket -Message "cost-attribution: unknown model '$Model' for provider '$Provider' — cost contribution is null; incrementing null_cost_events" -WarningMessages $WarningMessages
        return
    }

    $rates = $RatesByProviderModel[$lookupKey]
    $costEstimate = Get-CostEstimateFromUsage -Usage $Usage -Rates $rates
    if ($null -eq $costEstimate) {
        Add-NullCostEventToBucket -Bucket $Bucket -Message "cost-attribution: rate unavailable for provider '$Provider' model '$Model' — cost contribution is null; incrementing null_cost_events" -WarningMessages $WarningMessages
        return
    }

    if ($null -eq $Bucket['cost_estimate_usd']) { $Bucket['cost_estimate_usd'] = 0.0 }
    $Bucket['cost_estimate_usd'] += $costEstimate
}

function Test-CostContributionRateUnavailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Usage,
        [AllowNull()][string]$Model,
        [string]$Provider = 'claude',
        [Parameter(Mandatory)][hashtable]$RatesByProviderModel
    )

    if ($null -eq $Model -or [string]::IsNullOrWhiteSpace($Model)) { return $true }

    $lookupKey = Get-CostRateLookupKey -Provider $Provider -Model $Model
    if (-not $RatesByProviderModel.ContainsKey($lookupKey)) { return $true }

    return ($null -eq (Get-CostEstimateFromUsage -Usage $Usage -Rates $RatesByProviderModel[$lookupKey]))
}

function Add-ProviderContributionToPortBucket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Bucket,
        [Parameter(Mandatory)][hashtable]$Usage,
        [AllowNull()][string]$Model,
        [string]$Provider = 'claude',
        [bool]$CacheMetricUnavailable = $false,
        [int]$DispatchCount = 0,
        [int]$PromptSizeChars = 0,
        [bool]$MixedRegime = $false,
        [Parameter(Mandatory)][hashtable]$RatesByProviderModel
    )

    $providerName = Get-NormalizedCostProvider -Provider $Provider
    $providerBucket = Get-OrAddProviderCostBucket -Bucket $Bucket -ProviderName $providerName
    Add-TokensToProviderAccumulator -Accumulator $providerBucket['tokens'] -Usage $Usage -CacheMetricUnavailable:$CacheMetricUnavailable
    $providerBucket['dispatch_count'] += $DispatchCount
    $providerBucket['prompt_size_chars'] += $PromptSizeChars
    if ($MixedRegime) { $providerBucket['mixed_regime'] = $true }

    $providerWarnings = [System.Collections.Generic.List[string]]::new()
    Add-CostToBucket -Bucket $providerBucket -Usage $Usage -Model $Model -Provider $providerName -RatesByProviderModel $RatesByProviderModel -WarningMessages $providerWarnings

    if ($CacheMetricUnavailable) {
        $providerBucket['cache_metric_unavailable'] = $true
    }
    if ($providerName -eq 'copilot') {
        $rateUnavailable = Test-CostContributionRateUnavailable -Usage $Usage -Model $Model -Provider $providerName -RatesByProviderModel $RatesByProviderModel
        $providerBucket['rate_unavailable'] = $rateUnavailable
        $providerBucket['per_token_rates_published'] = -not $rateUnavailable
    }
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

function Set-ProviderCacheHitRatio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Bucket
    )

    $tokens = $Bucket['tokens']
    if ($null -eq $tokens['cache_read'] -or $null -eq $tokens['cache_creation']) {
        $Bucket['cache_read_hit_ratio'] = $null
        return
    }

    Set-CacheHitRatio -Bucket $Bucket
}

function Get-OrderedCostProviders {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Providers)

    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @('claude', 'copilot')) {
        if ($Providers.ContainsKey($candidate)) { $ordered.Add($candidate) }
    }
    foreach ($providerName in $Providers.Keys) {
        if (-not $ordered.Contains($providerName)) { $ordered.Add([string]$providerName) }
    }

    return [string[]]$ordered.ToArray()
}

function Set-PortProviderMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Bucket)

    if (-not $Bucket.ContainsKey('providers') -or -not ($Bucket['providers'] -is [hashtable])) { return }

    $providerNames = @(Get-OrderedCostProviders -Providers $Bucket['providers'])
    foreach ($providerName in $providerNames) {
        Set-ProviderCacheHitRatio -Bucket $Bucket['providers'][$providerName]
    }

    if ($providerNames.Count -eq 1 -and $providerNames[0] -eq 'claude') {
        $Bucket.Remove('providers')
        $Bucket.Remove('provider_support')
        return
    }

    $Bucket['provider_support'] = [string[]]$providerNames
}

function Get-PhaseMarkerAttributionTarget {
    <#
    .SYNOPSIS
        Maps a phase-marker port hint to its no-dispatch attribution target.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Evt
    )

    $markerPort = $Evt['_phase_marker_port']
    if ($null -eq $markerPort -or $markerPort -eq '') { return $null }

    $markerPortName = ([string]$markerPort).ToLowerInvariant()
    switch ($markerPortName) {
        { $_ -in @('experience', 'design', 'plan') } { return $markerPortName }
        'orchestrate' { return 'orchestrator-overhead' }
        'code-conductor' { return 'orchestrator-overhead' }
        default { return $null }
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
    $ratesByProviderModel = @{}
    if (Test-Path -LiteralPath $RateTablePath) {
        try {
            $tableJson = Get-Content -Path $RateTablePath -Raw | ConvertFrom-Json -AsHashtable
            $rawRates = $tableJson['rates']
            if ($null -ne $rawRates) {
                foreach ($modelKey in $rawRates.Keys) {
                    $rateEntry = $rawRates[$modelKey]
                    $normalizedEntry = New-CostRateTableEntry -ModelKey ([string]$modelKey) -RateEntry $rateEntry -TableJson $tableJson
                    $lookupKey = Get-CostRateLookupKey -Provider $normalizedEntry['provider'] -Model $normalizedEntry['model']
                    $ratesByProviderModel[$lookupKey] = $normalizedEntry
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
    $costAttributionWarnings = [System.Collections.Generic.List[string]]::new()

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
        $provider = Get-EventProvider -Evt $evt
        $cacheMetricUnavailable = Test-EventCacheMetricUnavailable -Evt $evt -Provider $provider

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
                $phaseMarkerTarget = Get-PhaseMarkerAttributionTarget -Evt $evt
                if ($phaseMarkerTarget -in @('experience', 'design', 'plan')) {
                    if (-not $ports.ContainsKey($phaseMarkerTarget)) {
                        $ports[$phaseMarkerTarget] = New-PortBucket
                    }
                    Add-TokensToAccumulator -Accumulator $ports[$phaseMarkerTarget]['tokens'] -Usage $usage
                    Add-CostToBucket -Bucket $ports[$phaseMarkerTarget] -Usage $usage -Model $model -Provider $provider -RatesByProviderModel $ratesByProviderModel -WarningMessages $costAttributionWarnings
                    Add-ProviderContributionToPortBucket -Bucket $ports[$phaseMarkerTarget] -Usage $usage -Model $model -Provider $provider -CacheMetricUnavailable:$cacheMetricUnavailable -RatesByProviderModel $ratesByProviderModel
                    $currentSubagentBuckets = @($ports[$phaseMarkerTarget])
                }
                else {
                    # No dispatch — orchestrator-overhead unless a phase marker maps elsewhere
                    Add-TokensToAccumulator -Accumulator $overhead['tokens'] -Usage $usage
                    Add-CostToBucket -Bucket $overhead -Usage $usage -Model $model -Provider $provider -RatesByProviderModel $ratesByProviderModel -WarningMessages $costAttributionWarnings
                    $currentSubagentBuckets = @($overhead)
                }
            }
            else {
                # Map each dispatch to its port and increment dispatch_count
                $portNames = [System.Collections.Generic.List[string]]::new()
                $generalPurposeCount = 0
                $unattributedCount = 0
                $portPromptChars = @{}

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
                        if (-not $portPromptChars.ContainsKey($mappedPort)) {
                            $portPromptChars[$mappedPort] = 0
                        }
                        $portPromptChars[$mappedPort] += [int]$dispatch['prompt_chars']
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
                    Add-CostToBucket -Bucket $ports[$primaryPort] -Usage $usage -Model $model -Provider $provider -RatesByProviderModel $ratesByProviderModel -WarningMessages $costAttributionWarnings
                    $primaryDispatchCount = if ($portDispatchCounts.ContainsKey($primaryPort)) { [int]$portDispatchCounts[$primaryPort] } else { 0 }
                    $primaryPromptChars = if ($portPromptChars.ContainsKey($primaryPort)) { [int]$portPromptChars[$primaryPort] } else { 0 }
                    Add-ProviderContributionToPortBucket -Bucket $ports[$primaryPort] -Usage $usage -Model $model -Provider $provider -CacheMetricUnavailable:$cacheMetricUnavailable -DispatchCount $primaryDispatchCount -PromptSizeChars $primaryPromptChars -MixedRegime:($ports[$primaryPort]['mixed_regime'] -eq $true) -RatesByProviderModel $ratesByProviderModel
                    $currentSubagentBuckets = @($ports[$primaryPort])
                }
                elseif ($generalPurposeCount -gt 0) {
                    # general-purpose dispatch: tokens count under dispatches.general_purpose (not overhead)
                    if (-not $ports.ContainsKey('dispatches.general_purpose')) {
                        $ports['dispatches.general_purpose'] = New-PortBucket
                    }
                    Add-TokensToAccumulator -Accumulator $ports['dispatches.general_purpose']['tokens'] -Usage $usage
                    Add-CostToBucket -Bucket $ports['dispatches.general_purpose'] -Usage $usage -Model $model -Provider $provider -RatesByProviderModel $ratesByProviderModel -WarningMessages $costAttributionWarnings
                    $currentSubagentBuckets = @($ports['dispatches.general_purpose'])
                }
                else {
                    # All dispatches were to unattributed-dispatch — use overhead for parent tokens
                    Add-TokensToAccumulator -Accumulator $overhead['tokens'] -Usage $usage
                    Add-CostToBucket -Bucket $overhead -Usage $usage -Model $model -Provider $provider -RatesByProviderModel $ratesByProviderModel -WarningMessages $costAttributionWarnings
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
                Add-CostToBucket -Bucket $targetBucket -Usage $usage -Model $model -Provider $provider -RatesByProviderModel $ratesByProviderModel -WarningMessages $costAttributionWarnings
                if ($targetBucket.ContainsKey('prompt_size_chars')) {
                    Add-ProviderContributionToPortBucket -Bucket $targetBucket -Usage $usage -Model $model -Provider $provider -CacheMetricUnavailable:$cacheMetricUnavailable -RatesByProviderModel $ratesByProviderModel
                }
            }
            else {
                # No context established — attribute to overhead
                Add-TokensToAccumulator -Accumulator $overhead['tokens'] -Usage $usage
                Add-CostToBucket -Bucket $overhead -Usage $usage -Model $model -Provider $provider -RatesByProviderModel $ratesByProviderModel -WarningMessages $costAttributionWarnings
            }
        }

        # Accumulate into totals regardless of bucket
        Add-TokensToAccumulator -Accumulator $totals['tokens'] -Usage $usage
        if ($null -ne $model -and -not [string]::IsNullOrWhiteSpace($model)) {
            $lookupKey = Get-CostRateLookupKey -Provider $provider -Model $model
            if ($ratesByProviderModel.ContainsKey($lookupKey)) {
                $rates = $ratesByProviderModel[$lookupKey]
                $costEstimate = Get-CostEstimateFromUsage -Usage $usage -Rates $rates
                if ($null -eq $costEstimate) {
                    if ($totals['cost_estimate_usd'] -eq 0.0) { $totals['cost_estimate_usd'] = $null }
                }
                else {
                    if ($null -eq $totals['cost_estimate_usd']) { $totals['cost_estimate_usd'] = 0.0 }
                    $totals['cost_estimate_usd'] += $costEstimate
                }
            }
        }
    }

    # Finalize cache_read_hit_ratio for all port buckets and overhead
    foreach ($portBucket in $ports.Values) {
        Set-CacheHitRatio -Bucket $portBucket
        Set-PortProviderMetadata -Bucket $portBucket
    }
    Set-CacheHitRatio -Bucket $overhead

    $warningVariableName = if ($PSBoundParameters.ContainsKey('WarningVariable')) { [string]$PSBoundParameters['WarningVariable'] } else { $null }
    Write-CostAttributionWarningRecord -WarningMessages $costAttributionWarnings -WarningVariableName $warningVariableName

    return @{
        ports                 = $ports
        orchestrator_overhead = $overhead
        dispatches            = $dispatches
        totals                = $totals
    }
}
