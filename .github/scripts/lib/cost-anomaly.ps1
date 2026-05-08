#Requires -Version 7.0
<#
.SYNOPSIS
    Anomaly metric set computation for cost-telemetry (issue #467, Step 4).
.DESCRIPTION
    Takes a Get-CostAttribution result (ThisRun), a rolling history of prior attribution
    results, and an optional regime checkpoint. Computes per-metric anomaly flags against
    BOTH baselines using the D4 dual-rule threshold and returns a structured flags array.

    Pure logic function — no file I/O, no gh calls.
#>

$script:DefaultCostCoverageClass = 'claude-only'

#region ---- Statistical helpers -----------------------------------------------

function script:Get-Mean {
    [OutputType([double])]
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return 0.0 }
    $sum = 0.0
    foreach ($v in $Values) { $sum += $v }
    return $sum / $Values.Count
}

function script:Get-Median {
    [OutputType([double])]
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return 0.0 }
    $sorted = $Values | Sort-Object
    $n = $sorted.Count
    if ($n % 2 -eq 1) {
        return [double]$sorted[($n - 1) / 2]
    }
    else {
        return ([double]$sorted[$n / 2 - 1] + [double]$sorted[$n / 2]) / 2.0
    }
}

function script:Get-Stddev {
    [OutputType([double])]
    param([double[]]$Values)
    if ($Values.Count -lt 2) { return 0.0 }
    $mean = script:Get-Mean -Values $Values
    $sumSq = 0.0
    foreach ($v in $Values) {
        $diff = $v - $mean
        $sumSq += $diff * $diff
    }
    return [Math]::Sqrt($sumSq / $Values.Count)
}

#endregion

#region ---- Metric extraction from attribution entry --------------------------

function script:Get-MetricBaseKey {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$MetricKey)

    $bracketIdx = $MetricKey.IndexOf('[')
    if ($bracketIdx -ge 0) { return $MetricKey.Substring(0, $bracketIdx) }
    return $MetricKey
}

function script:ConvertTo-NullableMetricDouble {
    [OutputType([object])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and ([string]::IsNullOrWhiteSpace($Value) -or [string]$Value -eq 'null')) { return $null }
    return [double]$Value
}

function script:Get-MetricValue {
    <#
    .SYNOPSIS
        Extracts a single metric value from a Get-CostAttribution hashtable entry.
    .OUTPUTS
        [double] or $null if the metric cannot be extracted.
    #>
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [Parameter(Mandatory)][string]$MetricKey,
        [AllowEmptyString()][string]$Port = ''
    )

    # Parse the base key (part before '[') to handle per-port metric keys cleanly.
    # Square brackets are character class wildcards in PowerShell -like, so we split instead.
    $baseKey = script:Get-MetricBaseKey -MetricKey $MetricKey

    if ($MetricKey -match '^ports\[(?<port>[^\]]+)\]\.tokens\.(?<kind>input|output)$') {
        $portName = if ($Port) { $Port } else { $Matches['port'] }
        if (-not $portName -or -not $Entry.ports.ContainsKey($portName)) { return $null }
        return [double]$Entry.ports[$portName].tokens[$Matches['kind']]
    }

    if ($baseKey -eq 'dispatches.per_port') {
        if (-not $Port -or -not $Entry.ports.ContainsKey($Port)) { return $null }
        return [double]$Entry.ports[$Port].dispatch_count
    }
    elseif ($baseKey -eq 'tokens.per_dispatch.avg.output') {
        if (-not $Port -or -not $Entry.ports.ContainsKey($Port)) { return $null }
        $dc = $Entry.ports[$Port].dispatch_count
        if ($dc -gt 0) { return [double]$Entry.ports[$Port].tokens.output / [double]$dc }
        return $null
    }
    elseif ($baseKey -eq 'tokens.per_dispatch.avg.input') {
        if (-not $Port -or -not $Entry.ports.ContainsKey($Port)) { return $null }
        $dc = $Entry.ports[$Port].dispatch_count
        if ($dc -gt 0) { return [double]$Entry.ports[$Port].tokens.input / [double]$dc }
        return $null
    }
    elseif ($baseKey -eq 'prompt_size.per_dispatch.avg.chars') {
        if (-not $Port -or -not $Entry.ports.ContainsKey($Port)) { return $null }
        $dc = $Entry.ports[$Port].dispatch_count
        if ($dc -gt 0) { return [double]$Entry.ports[$Port].prompt_size_chars / [double]$dc }
        return $null
    }
    elseif ($baseKey -eq 'cache_read.hit_ratio') {
        if (-not $Port -or -not $Entry.ports.ContainsKey($Port)) { return $null }
        return script:ConvertTo-NullableMetricDouble -Value $Entry.ports[$Port].cache_read_hit_ratio
    }
    elseif ($baseKey -eq 'cost_estimate_usd' -and $Port) {
        if (-not $Entry.ports.ContainsKey($Port)) { return $null }
        return script:ConvertTo-NullableMetricDouble -Value $Entry.ports[$Port].cost_estimate_usd
    }
    elseif ($MetricKey -eq 'orchestrator_overhead.tokens.input') {
        return [double]$Entry.orchestrator_overhead.tokens.input
    }
    elseif ($MetricKey -eq 'orchestrator_overhead.cache_read.hit_ratio') {
        return script:ConvertTo-NullableMetricDouble -Value $Entry.orchestrator_overhead.cache_read_hit_ratio
    }
    elseif ($MetricKey -eq 'dispatches.general_purpose.count') {
        return [double]$Entry.dispatches.general_purpose_count
    }
    elseif ($MetricKey -eq 'cost_estimate_usd.total') {
        return script:ConvertTo-NullableMetricDouble -Value $Entry.totals.cost_estimate_usd
    }

    return $null
}

#endregion

#region ---- Coverage-class helpers -------------------------------------------

function script:Get-EffectiveCoverageClass {
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Entry)

    if ($Entry.ContainsKey('install_status') -and [string]$Entry['install_status'] -eq 'missing-or-fallback') {
        return $script:DefaultCostCoverageClass
    }

    if ($Entry.ContainsKey('coverage') -and -not [string]::IsNullOrWhiteSpace([string]$Entry['coverage'])) {
        return [string]$Entry['coverage']
    }

    return $script:DefaultCostCoverageClass
}

function script:Test-CoverageSensitiveMetric {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$MetricKey)

    $baseKey = script:Get-MetricBaseKey -MetricKey $MetricKey

    if ($MetricKey -match '^ports\[[^\]]+\]\.tokens\.(input|output)$') { return $true }

    return @(
        'orchestrator_overhead.tokens.input',
        'orchestrator_overhead.cache_read.hit_ratio',
        'cost_estimate_usd.total'
    ) -contains $baseKey
}

#endregion

#region ---- Threshold evaluation ----------------------------------------------

function script:Test-AnomalyRules {
    <#
    .SYNOPSIS
        Evaluates Rule A and Rule B for a single metric value against an array of baseline values.
    .OUTPUTS
        [hashtable] @{ RuleA=[bool]; RuleB=[bool]; Mean=[double]; Median=[double]; Stddev=[double]; N=[int] }
    #>
    [OutputType([hashtable])]
    param(
        [double]$ThisValue,
        [double[]]$BaselineValues
    )

    $n = $BaselineValues.Count
    $mean = script:Get-Mean   -Values $BaselineValues
    $median = script:Get-Median -Values $BaselineValues
    $stddev = script:Get-Stddev -Values $BaselineValues

    # Rule A: |this - mean| > 2 * stddev AND N >= 10 AND stddev > 0
    $ruleA = ($n -ge 10) -and ($stddev -gt 0) -and ([Math]::Abs($ThisValue - $mean) -gt (2 * $stddev))

    # Rule B: |this - median| > 0.5 * median AND N >= 5 AND median != 0
    $ruleB = ($n -ge 5) -and ($median -ne 0) -and ([Math]::Abs($ThisValue - $median) -gt (0.5 * [Math]::Abs($median)))

    return @{
        RuleA  = $ruleA
        RuleB  = $ruleB
        Mean   = $mean
        Median = $median
        Stddev = $stddev
        N      = $n
    }
}

function script:Get-Confidence {
    param([bool]$RuleA, [bool]$RuleB)
    if ($RuleA -and $RuleB) { return 'high' }
    return 'medium'
}

#endregion

#region ---- Checkpoint single-value comparison --------------------------------

function script:Test-CheckpointAnomaly {
    <#
    .SYNOPSIS
        Compares this_value against a checkpoint scalar value using Rules A and B
        (single-point checkpoint: treated as N=1, so only Rule B applies if
        checkpoint value qualifies).
    .DESCRIPTION
        The checkpoint is a single prior attribution snapshot, not a statistical
        distribution. We apply only Rule B logic against the checkpoint value
        (treat checkpoint as both mean and median for a single-point comparison).
    .OUTPUTS
        [bool] $true if checkpoint anomaly fires.
    #>
    [OutputType([bool])]
    param(
        [double]$ThisValue,
        [double]$CheckpointValue
    )
    # Single-point Rule B: |this - checkpoint| > 0.5 * |checkpoint| AND checkpoint != 0
    if ($CheckpointValue -eq 0) { return $false }
    return [Math]::Abs($ThisValue - $CheckpointValue) -gt (0.5 * [Math]::Abs($CheckpointValue))
}

#endregion

#region ---- Metric descriptor table ------------------------------------------

function script:Get-MetricDescriptors {
    <#
    .SYNOPSIS
        Returns the full list of metric descriptors to evaluate.
    .OUTPUTS
        [hashtable[]] Each with keys: MetricKey, Port (or $null), Direction, SubIssue
    #>
    [OutputType([hashtable[]])]
    param(
        [string[]]$ActivePorts,
        [bool]$IncludeReviewDispatch
    )

    $metrics = [System.Collections.Generic.List[hashtable]]::new()

    # Per-port metrics
    foreach ($port in $ActivePorts) {
        # Skip review port tokens.per_dispatch metrics unless opt-in present
        $skipTokensPerDispatch = ($port -eq 'review') -and (-not $IncludeReviewDispatch)

        $metrics.Add(@{ MetricKey = "dispatches.per_port[$port]"; Port = $port; Direction = 'shrink' })
        $metrics.Add(@{ MetricKey = "ports[$port].tokens.input"; Port = $port; Direction = 'shrink' })
        $metrics.Add(@{ MetricKey = "ports[$port].tokens.output"; Port = $port; Direction = 'shrink' })

        if (-not $skipTokensPerDispatch) {
            $metrics.Add(@{ MetricKey = "tokens.per_dispatch.avg.output[$port]"; Port = $port; Direction = 'shrink' })
            $metrics.Add(@{ MetricKey = "tokens.per_dispatch.avg.input[$port]"; Port = $port; Direction = 'shrink' })
        }

        $metrics.Add(@{ MetricKey = "prompt_size.per_dispatch.avg.chars[$port]"; Port = $port; Direction = 'shrink' })
        $metrics.Add(@{ MetricKey = "cache_read.hit_ratio[$port]"; Port = $port; Direction = 'grow' })
        $metrics.Add(@{ MetricKey = "cost_estimate_usd[$port]"; Port = $port; Direction = 'shrink' })
    }

    # Orchestrator-overhead metrics
    $metrics.Add(@{ MetricKey = 'orchestrator_overhead.tokens.input'; Port = $null; Direction = 'shrink' })
    $metrics.Add(@{ MetricKey = 'orchestrator_overhead.cache_read.hit_ratio'; Port = $null; Direction = 'grow' })
    $metrics.Add(@{ MetricKey = 'dispatches.general_purpose.count'; Port = $null; Direction = 'shrink' })

    # Cross-port cost metric
    $metrics.Add(@{ MetricKey = 'cost_estimate_usd.total'; Port = $null; Direction = 'shrink' })

    return $metrics.ToArray()
}

#endregion

#region ---- Public function ---------------------------------------------------

function Get-CostAnomalyFlags {
    <#
    .SYNOPSIS
        Computes per-metric anomaly flags for a cost telemetry run.
    .DESCRIPTION
        Evaluates each metric in the D4 metric set against rolling history baselines
        and an optional regime checkpoint. Returns a structured flags array for any
        metrics that exceed Rule A (statistical) or Rule B (robust) thresholds.
    .PARAMETER ThisRun
        Output of Get-CostAttribution for the current PR.
    .PARAMETER RollingHistory
        Array of prior Get-CostAttribution outputs (may be empty).
    .PARAMETER RegimeCheckpoint
        Optional most-recent checkpoint attribution snapshot.
    .PARAMETER OptInLabels
        PR labels used to opt in to extended metric coverage
        (e.g., 'cost-target:review-discipline').
    .OUTPUTS
        [hashtable[]] Array of flag hashtables. Empty array when no anomalies detected.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)][hashtable]$ThisRun,
        [AllowEmptyCollection()][hashtable[]]$RollingHistory = @(),
        [hashtable]$RegimeCheckpoint = $null,
        [string[]]$OptInLabels = @()
    )

    $flags = [System.Collections.Generic.List[hashtable]]::new()

    # Determine which ports are present in ThisRun
    $activePorts = @($ThisRun.ports.Keys)

    # Determine if review port token metrics are opted in
    $includeReviewDispatch = $OptInLabels -contains 'cost-target:review-discipline'

    $descriptors = script:Get-MetricDescriptors -ActivePorts $activePorts -IncludeReviewDispatch $includeReviewDispatch
    $thisCoverageClass = script:Get-EffectiveCoverageClass -Entry $ThisRun

    foreach ($desc in $descriptors) {
        $metricKey = $desc.MetricKey
        $port = $desc.Port
        $direction = $desc.Direction
        $coverageSensitive = script:Test-CoverageSensitiveMetric -MetricKey $metricKey

        # Extract this run's value
        $thisValue = script:Get-MetricValue -Entry $ThisRun -MetricKey $metricKey -Port ($port ?? '')
        if ($null -eq $thisValue) { continue }

        # Extract rolling baseline values
        $baselineValues = [System.Collections.Generic.List[double]]::new()
        foreach ($histEntry in $RollingHistory) {
            if ($coverageSensitive -and (script:Get-EffectiveCoverageClass -Entry $histEntry) -ne $thisCoverageClass) {
                continue
            }

            $v = script:Get-MetricValue -Entry $histEntry -MetricKey $metricKey -Port ($port ?? '')
            if ($null -ne $v) {
                $baselineValues.Add($v)
            }
        }

        # Evaluate rolling baseline
        $rollingFires = $false
        $rollingStats = $null
        if ($baselineValues.Count -gt 0) {
            $rollingStats = script:Test-AnomalyRules -ThisValue $thisValue -BaselineValues $baselineValues.ToArray()
            $rollingFires = $rollingStats.RuleA -or $rollingStats.RuleB
        }

        # Evaluate checkpoint baseline
        $checkpointFires = $false
        $checkpointValue = $null
        if ($null -ne $RegimeCheckpoint) {
            $cpv = script:Get-MetricValue -Entry $RegimeCheckpoint -MetricKey $metricKey -Port ($port ?? '')
            if ($null -ne $cpv) {
                $checkpointValue = $cpv
                $checkpointFires = script:Test-CheckpointAnomaly -ThisValue $thisValue -CheckpointValue $cpv
            }
        }

        # Build flag if either baseline fires
        if (-not $rollingFires -and -not $checkpointFires) { continue }

        $vsBaseline = if ($rollingFires -and $checkpointFires) { 'both' }
        elseif ($rollingFires) { 'rolling' }
        else { 'checkpoint' }

        # Confidence derives from rolling stats (authoritative); fall back to medium for checkpoint-only
        $confidence = 'medium'
        if ($null -ne $rollingStats -and $rollingFires) {
            $confidence = script:Get-Confidence -RuleA $rollingStats.RuleA -RuleB $rollingStats.RuleB
        }

        $flag = @{
            metric           = $metricKey
            port             = $port
            this_value       = $thisValue
            baseline_mean    = if ($null -ne $rollingStats) { $rollingStats.Mean }   else { $null }
            baseline_median  = if ($null -ne $rollingStats) { $rollingStats.Median } else { $null }
            baseline_stddev  = if ($null -ne $rollingStats) { $rollingStats.Stddev } else { $null }
            baseline_n       = if ($null -ne $rollingStats) { $rollingStats.N }      else { 0 }
            checkpoint_value = $checkpointValue
            vs_baseline      = $vsBaseline
            direction        = $direction
            confidence       = $confidence
        }

        $flags.Add($flag)
    }

    return $flags.ToArray()
}

#endregion
