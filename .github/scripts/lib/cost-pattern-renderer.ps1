#Requires -Version 7.0
<#
.SYNOPSIS
    Cost pattern renderer for cost-telemetry (issue #467, Step 8).
.DESCRIPTION
    Format-CostPatternMarkdown: renders the ## Cost Pattern section including the
    header and the per-port markdown table. Pure formatting — no file I/O.

    Format-CostPatternYaml: renders the <!-- cost-pattern-data ... --> YAML block.
    Pure formatting — no file I/O.
#>

# Canonical port ordering for the table (ports not in this list appear in insertion order after)
$script:CostRendererPortOrder = @(
    'experience', 'design', 'plan',
    'implement-code', 'implement-test', 'implement-refactor', 'implement-docs',
    'review', 'process-review'
)

# Ports that are skill-driven and folded into orchestrator-overhead (shown as combined row with footnote)
$script:CostRendererSkillDrivenPorts = [System.Collections.Generic.HashSet[string]]@(
    'ce-gate-cli', 'release-hygiene', 'plugin-release-hygiene'
)

#region ---- Formatting helpers -------------------------------------------------

function script:Format-TokenCount {
    <#
    .SYNOPSIS Formats an integer token count with thousands separators (invariant culture). #>
    [OutputType([string])]
    param([int]$Value)
    return $Value.ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function script:Format-Cost {
    <#
    .SYNOPSIS Formats a USD cost with dollar sign and 4 decimal places (invariant culture). #>
    [OutputType([string])]
    param([double]$Value)
    $formatted = $Value.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture)
    return "`$$formatted"
}

function script:Format-CostYaml {
    <#
    .SYNOPSIS Formats a USD cost as a bare double string for YAML (invariant culture, 4 decimal places). #>
    [OutputType([string])]
    param([double]$Value)
    return $Value.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture)
}

function script:Format-Ratio {
    <#
    .SYNOPSIS Formats a ratio (0.0-1.0) as a percentage string. #>
    [OutputType([string])]
    param([double]$Value)
    $pct = [int][Math]::Round($Value * 100)
    return "$pct%"
}

function script:Format-RatioYaml {
    <#
    .SYNOPSIS Formats a ratio (0.0-1.0) for YAML (3 decimal places, invariant culture). #>
    [OutputType([string])]
    param([double]$Value)
    return $Value.ToString('0.000', [System.Globalization.CultureInfo]::InvariantCulture)
}

#endregion

#region ---- Header builder -----------------------------------------------------

function script:Build-CostPatternHeader {
    <#
    .SYNOPSIS
        Returns the header line for the ## Cost Pattern section.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Completeness,
        [AllowEmptyCollection()][hashtable[]]$AnomalyFlags = @(),
        [hashtable]$RollingMeta = $null
    )

    $completenessValue = $Completeness['completeness']
    $excluded = $Completeness['excluded_from_rolling_baseline']
    $excludeReason = $Completeness['exclude_reason']
    $stopReason = $Completeness['stop_reason']

    # partial session
    if ($completenessValue -eq 'partial') {
        $reason = if ($stopReason) { $stopReason } else { 'unknown stop reason' }
        return "## Cost Pattern `u{26A0} session incomplete ($reason); cost-fields show partial data; this run is excluded from rolling-history aggregation"
    }

    # unknown session
    if ($completenessValue -eq 'unknown') {
        $reason = if ($stopReason) { $stopReason } else { 'no assistant events' }
        return "## Cost Pattern `u{26A0} session not found or unrecognized ($reason); cost-fields unavailable; this run is excluded from rolling-history aggregation"
    }

    # rolling-history timed out
    if ($null -ne $RollingMeta -and $RollingMeta['timed_out'] -eq $true) {
        return "## Cost Pattern `u{26A0} rolling-history fetch timed out — anomaly review unavailable for this run; per-port table shown below"
    }

    # complete session, excluded (outlier-PR annotation)
    if ($excluded -and $null -ne $excludeReason -and $excludeReason -ne '' -and $completenessValue -eq 'complete') {
        return "## Cost Pattern `u{26A0} this PR is annotated $excludeReason; excluded from rolling-history aggregation by future PRs"
    }

    # complete, anomaly flags present
    if ($null -ne $AnomalyFlags -and $AnomalyFlags.Count -gt 0) {
        $n = $AnomalyFlags.Count
        return "## Cost Pattern ($n anomalies vs rolling baseline)"
    }

    # complete, clean
    return "## Cost Pattern — within rolling baseline"
}

#endregion

#region ---- Table builder ------------------------------------------------------

function script:Get-PortAnomalyNames {
    <#
    .SYNOPSIS
        Returns a display string for anomaly metric names applicable to a given port.
        Returns ' — ' when there are no anomalies for the port.
    #>
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][hashtable[]]$AnomalyFlags,
        [AllowEmptyString()][string]$PortName
    )

    if ($null -eq $AnomalyFlags -or $AnomalyFlags.Count -eq 0) {
        return ' — '
    }

    $portFlags = @($AnomalyFlags | Where-Object {
            $flagPort = $_['port']
            ($null -ne $flagPort -and $flagPort -eq $PortName) -or
            ($null -eq $flagPort -and [string]::IsNullOrEmpty($PortName))
        })

    if ($portFlags.Count -eq 0) {
        return ' — '
    }

    # Extract short metric name (last segment after dot or bracket)
    $names = $portFlags | ForEach-Object {
        $metric = $_['metric']
        # Strip port qualifier e.g. "dispatches.per_port[experience]" -> "dispatches"
        if ($metric -match '^([^.\[]+)') {
            $Matches[1]
        }
        else {
            $metric
        }
    } | Select-Object -Unique

    return (' ' + ($names -join ', ') + ' ').TrimEnd()
}

function script:Build-CostPatternTable {
    <#
    .SYNOPSIS Builds the markdown table for the cost pattern section. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Attribution,
        [AllowEmptyCollection()][hashtable[]]$AnomalyFlags = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    # Header row
    $lines.Add('| Port | Dispatches | Input Tokens | Output Tokens | Cache Creation | Cache Read | Cache Hit% | Cost (USD) | Anomalies |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|')

    $ports = $Attribution['ports']
    $overhead = $Attribution['orchestrator_overhead']
    $dispatches = $Attribution['dispatches']
    $totals = $Attribution['totals']

    # Determine which ports to show: canonical order + any extras not in canonical list
    $allPortNames = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $script:CostRendererPortOrder) {
        $allPortNames.Add($p)
    }
    # Add ports present in attribution that aren't in canonical order (except special ones)
    foreach ($p in $ports.Keys) {
        if ($allPortNames -notcontains $p -and
            $p -ne 'orchestrator-overhead' -and
            $p -ne 'dispatches.general_purpose' -and
            $p -ne 'unattributed-dispatch' -and
            -not $script:CostRendererSkillDrivenPorts.Contains($p)) {
            $allPortNames.Add($p)
        }
    }

    # Check for skill-driven ports that rolled into overhead
    $hasSkillDriven = $false
    foreach ($p in $ports.Keys) {
        if ($script:CostRendererSkillDrivenPorts.Contains($p)) {
            $hasSkillDriven = $true
            break
        }
    }

    # Per-port rows
    foreach ($portName in $allPortNames) {
        if ($ports.ContainsKey($portName)) {
            $bucket = $ports[$portName]
            $dc = $bucket['dispatch_count']
            $tok = $bucket['tokens']
            $inputTok = $tok['input']
            $outputTok = $tok['output']
            $cc = $tok['cache_creation']
            $cr = $tok['cache_read']
            $ratio = $bucket['cache_read_hit_ratio']
            $cost = $bucket['cost_estimate_usd']

            $inputStr = if ($inputTok -gt 0) { script:Format-TokenCount -Value $inputTok } else { '—' }
            $outputStr = if ($outputTok -gt 0) { script:Format-TokenCount -Value $outputTok } else { '—' }
            $ccStr = if ($cc -gt 0) { script:Format-TokenCount -Value $cc } else { '—' }
            $crStr = if ($cr -gt 0) { script:Format-TokenCount -Value $cr } else { '—' }
            $ratioStr = if (($inputTok + $cc + $cr) -gt 0) { script:Format-Ratio -Value $ratio } else { '—' }
            $costStr = if ($cost -gt 0) { script:Format-Cost -Value $cost } else { '—' }
            $anomStr = script:Get-PortAnomalyNames -AnomalyFlags $AnomalyFlags -PortName $portName

            $lines.Add("| $portName | $dc | $inputStr | $outputStr | $ccStr | $crStr | $ratioStr | $costStr |$anomStr|")
        }
        else {
            # Port not in attribution — zero dispatches, dashes for everything
            $anomStr = script:Get-PortAnomalyNames -AnomalyFlags $AnomalyFlags -PortName $portName
            $lines.Add("| $portName | 0 | — | — | — | — | — | — |$anomStr|")
        }
    }

    # dispatches.general_purpose row
    if ($ports.ContainsKey('dispatches.general_purpose')) {
        $bucket = $ports['dispatches.general_purpose']
        $dc = $dispatches['general_purpose_count']
        $tok = $bucket['tokens']
        $inputTok = $tok['input']
        $outputTok = $tok['output']
        $cc = $tok['cache_creation']
        $cr = $tok['cache_read']
        $ratio = $bucket['cache_read_hit_ratio']
        $cost = $bucket['cost_estimate_usd']

        $inputStr = if ($inputTok -gt 0) { script:Format-TokenCount -Value $inputTok } else { '—' }
        $outputStr = if ($outputTok -gt 0) { script:Format-TokenCount -Value $outputTok } else { '—' }
        $ccStr = if ($cc -gt 0) { script:Format-TokenCount -Value $cc } else { '—' }
        $crStr = if ($cr -gt 0) { script:Format-TokenCount -Value $cr } else { '—' }
        $ratioStr = if (($inputTok + $cc + $cr) -gt 0) { script:Format-Ratio -Value $ratio } else { '—' }
        $costStr = if ($cost -gt 0) { script:Format-Cost -Value $cost } else { '—' }
        $lines.Add("| dispatches.general_purpose | $dc | $inputStr | $outputStr | $ccStr | $crStr | $ratioStr | $costStr | — |")
    }
    else {
        $gpCount = $dispatches['general_purpose_count']
        $lines.Add("| dispatches.general_purpose | $gpCount | — | — | — | — | — | — | — |")
    }

    # unattributed-dispatch row
    $uaCount = $dispatches['unattributed_count']
    if ($ports.ContainsKey('unattributed-dispatch')) {
        $bucket = $ports['unattributed-dispatch']
        $dc = $uaCount
        $tok = $bucket['tokens']
        $inputStr = if ($tok['input'] -gt 0) { script:Format-TokenCount -Value $tok['input'] } else { '—' }
        $outputStr = if ($tok['output'] -gt 0) { script:Format-TokenCount -Value $tok['output'] } else { '—' }
        $ccStr = if ($tok['cache_creation'] -gt 0) { script:Format-TokenCount -Value $tok['cache_creation'] } else { '—' }
        $crStr = if ($tok['cache_read'] -gt 0) { script:Format-TokenCount -Value $tok['cache_read'] } else { '—' }
        $costStr = if ($bucket['cost_estimate_usd'] -gt 0) { script:Format-Cost -Value $bucket['cost_estimate_usd'] } else { '—' }
        $lines.Add("| unattributed-dispatch | $dc | $inputStr | $outputStr | $ccStr | $crStr | — | $costStr | — |")
    }
    else {
        $lines.Add("| unattributed-dispatch | $uaCount | — | — | — | — | — | — | — |")
    }

    # orchestrator-overhead row
    $ohTok = $overhead['tokens']
    $ohInput = $ohTok['input']
    $ohOutput = $ohTok['output']
    $ohCC = $ohTok['cache_creation']
    $ohCR = $ohTok['cache_read']
    $ohRatio = $overhead['cache_read_hit_ratio']
    $ohCost = $overhead['cost_estimate_usd']

    $ohInputStr = if ($ohInput -gt 0) { script:Format-TokenCount -Value $ohInput } else { '—' }
    $ohOutputStr = if ($ohOutput -gt 0) { script:Format-TokenCount -Value $ohOutput } else { '—' }
    $ohCCStr = if ($ohCC -gt 0) { script:Format-TokenCount -Value $ohCC } else { '—' }
    $ohCRStr = if ($ohCR -gt 0) { script:Format-TokenCount -Value $ohCR } else { '—' }
    $ohRatioStr = if (($ohInput + $ohCC + $ohCR) -gt 0) { script:Format-Ratio -Value $ohRatio } else { '—' }
    $ohCostStr = if ($ohCost -gt 0) { script:Format-Cost -Value $ohCost } else { '—' }
    $ohFootnote = if ($hasSkillDriven) { ' *' } else { '' }
    $lines.Add("| orchestrator-overhead$ohFootnote | — | $ohInputStr | $ohOutputStr | $ohCCStr | $ohCRStr | $ohRatioStr | $ohCostStr | — |")

    # Totals row
    $totTok = $totals['tokens']
    $totDisp = 0
    foreach ($p in $ports.Keys) {
        if ($ports[$p].ContainsKey('dispatch_count')) {
            $totDisp += $ports[$p]['dispatch_count']
        }
    }
    $totDisp += $dispatches['general_purpose_count']
    $totDisp += $dispatches['unattributed_count']

    $totInput = $totTok['input']
    $totOutput = $totTok['output']
    $totCC = $totTok['cache_creation']
    $totCR = $totTok['cache_read']
    $totCost = $totals['cost_estimate_usd']

    $totInputStr = if ($totInput -gt 0) { script:Format-TokenCount -Value $totInput } else { '—' }
    $totOutputStr = if ($totOutput -gt 0) { script:Format-TokenCount -Value $totOutput } else { '—' }
    $totCCStr = if ($totCC -gt 0) { script:Format-TokenCount -Value $totCC } else { '—' }
    $totCRStr = if ($totCR -gt 0) { script:Format-TokenCount -Value $totCR } else { '—' }
    $totCostStr = if ($totCost -gt 0) { script:Format-Cost -Value $totCost } else { '—' }

    $lines.Add("| **TOTAL** | **$totDisp** | **$totInputStr** | **$totOutputStr** | **$totCCStr** | **$totCRStr** | — | **$totCostStr** | |")

    if ($hasSkillDriven) {
        $lines.Add('')
        $lines.Add('*rolled into orchestrator-overhead')
    }

    return $lines -join "`n"
}

#endregion

#region ---- Public functions ---------------------------------------------------

function Format-CostPatternMarkdown {
    <#
    .SYNOPSIS
        Renders the full ## Cost Pattern section as a markdown string.
    .DESCRIPTION
        Returns the header line plus the per-port table. Pure formatting — no I/O.
    .PARAMETER Attribution
        Get-CostAttribution output hashtable.
    .PARAMETER Completeness
        Get-SessionCompleteness output hashtable.
    .PARAMETER AnomalyFlags
        Array of anomaly flag hashtables from Get-CostAnomalyFlags. Defaults to empty.
    .PARAMETER RollingMeta
        Optional hashtable with a 'timed_out' boolean key.
    .PARAMETER Pr
        PR number (informational; not rendered in markdown body but available for callers).
    .PARAMETER Branch
        Branch name (informational).
    .OUTPUTS
        [string] Full ## Cost Pattern markdown section.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Attribution,
        [Parameter(Mandatory)][hashtable]$Completeness,
        [AllowEmptyCollection()][hashtable[]]$AnomalyFlags = @(),
        [hashtable]$RollingMeta = $null,
        [int]$Pr = 0,
        [string]$Branch = ''
    )

    $header = script:Build-CostPatternHeader -Completeness $Completeness -AnomalyFlags $AnomalyFlags -RollingMeta $RollingMeta
    $table = script:Build-CostPatternTable  -Attribution $Attribution -AnomalyFlags $AnomalyFlags

    # Fix Pass3-F4: surface null_cost_events when nonzero so unknown-model
    # cost undercounting is visible in the rendered markdown, not just buried
    # in the embedded YAML. Sums across ports and orchestrator overhead.
    $nullEventTotal = 0
    $ports = $Attribution['ports']
    if ($ports -is [hashtable]) {
        foreach ($pName in $ports.Keys) {
            $b = $ports[$pName]
            if ($b -is [hashtable] -and $b.ContainsKey('null_cost_events')) {
                $nullEventTotal += [int]$b['null_cost_events']
            }
        }
    }
    $oh = $Attribution['orchestrator_overhead']
    if ($oh -is [hashtable] -and $oh.ContainsKey('null_cost_events')) {
        $nullEventTotal += [int]$oh['null_cost_events']
    }

    $body = "$header`n`n$table"
    if ($nullEventTotal -gt 0) {
        $body += "`n`n> **Note**: $nullEventTotal cost event(s) had unknown models not present in ``cost-rate-table.json`` and contributed null to the cost estimate. Update the rate table to include the missing model(s) for accurate attribution."
    }
    return $body
}

function Format-CostPatternYaml {
    <#
    .SYNOPSIS
        Renders the <!-- cost-pattern-data ... --> embedded YAML block as a string.
    .DESCRIPTION
        Returns the complete comment block including opening/closing markers.
        Pure formatting — no I/O.
    .PARAMETER Attribution
        Get-CostAttribution output hashtable.
    .PARAMETER Completeness
        Get-SessionCompleteness output hashtable.
    .PARAMETER AnomalyFlags
        Array of anomaly flag hashtables from Get-CostAnomalyFlags. Defaults to empty.
    .PARAMETER Pr
        PR number.
    .PARAMETER Branch
        Branch name.
    .OUTPUTS
        [string] The <!-- cost-pattern-data ... --> block.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Attribution,
        [Parameter(Mandatory)][hashtable]$Completeness,
        [AllowEmptyCollection()][hashtable[]]$AnomalyFlags = @(),
        [int]$Pr = 0,
        [string]$Branch = ''
    )

    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    $completenessValue = $Completeness['completeness']
    $excluded = $Completeness['excluded_from_rolling_baseline']
    $excludedStr = if ($excluded) { 'true' } else { 'false' }
    $generatedAt = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)

    $ports = $Attribution['ports']
    $overhead = $Attribution['orchestrator_overhead']
    $dispatches = $Attribution['dispatches']
    $totals = $Attribution['totals']

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('<!-- cost-pattern-data')
    $null = $sb.AppendLine('version: 1')
    $null = $sb.AppendLine("session_completeness: $completenessValue")
    $null = $sb.AppendLine("excluded_from_rolling_baseline: $excludedStr")
    $null = $sb.AppendLine("generated_at: $generatedAt")
    $null = $sb.AppendLine("pr: $Pr")
    $null = $sb.AppendLine("branch: $Branch")

    # ports array
    $null = $sb.AppendLine('ports:')
    # Emit ports in canonical order for determinism
    $portKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $script:CostRendererPortOrder) {
        if ($ports.ContainsKey($p)) { $portKeys.Add($p) }
    }
    foreach ($p in $ports.Keys) {
        if ($portKeys -notcontains $p) { $portKeys.Add($p) }
    }
    foreach ($portName in $portKeys) {
        $bucket = $ports[$portName]
        $tok = $bucket['tokens']
        $cost = script:Format-CostYaml -Value ([double]$bucket['cost_estimate_usd'])
        $ratio = script:Format-RatioYaml -Value ([double]$bucket['cache_read_hit_ratio'])
        $mixed = if ($bucket['mixed_regime']) { 'true' } else { 'false' }
        $null = $sb.AppendLine("  - name: $portName")
        $null = $sb.AppendLine('    tokens:')
        $null = $sb.AppendLine("      input: $($tok['input'])")
        $null = $sb.AppendLine("      output: $($tok['output'])")
        $null = $sb.AppendLine("      cache_creation: $($tok['cache_creation'])")
        $null = $sb.AppendLine("      cache_read: $($tok['cache_read'])")
        $null = $sb.AppendLine("    dispatch_count: $($bucket['dispatch_count'])")
        $null = $sb.AppendLine("    prompt_size_chars: $($bucket['prompt_size_chars'])")
        $null = $sb.AppendLine("    cost_estimate_usd: $cost")
        $null = $sb.AppendLine("    cache_read_hit_ratio: $ratio")
        # Fix Pass3-F4: emit null_cost_events so downstream readers see when a
        # port had unknown-model cost events that produced no rate-table match.
        # Silent zero would mask cost undercounting whenever a new model variant
        # is introduced before cost-rate-table.json is updated.
        $nullEvents = if ($bucket.ContainsKey('null_cost_events')) { [int]$bucket['null_cost_events'] } else { 0 }
        $null = $sb.AppendLine("    null_cost_events: $nullEvents")
        $null = $sb.AppendLine("    mixed_regime: $mixed")
    }

    # orchestrator_overhead
    $ohTok = $overhead['tokens']
    $ohCost = script:Format-CostYaml -Value ([double]$overhead['cost_estimate_usd'])
    $ohRatio = script:Format-RatioYaml -Value ([double]$overhead['cache_read_hit_ratio'])
    $null = $sb.AppendLine('orchestrator_overhead:')
    $null = $sb.AppendLine('  tokens:')
    $null = $sb.AppendLine("    input: $($ohTok['input'])")
    $null = $sb.AppendLine("    output: $($ohTok['output'])")
    $null = $sb.AppendLine("    cache_creation: $($ohTok['cache_creation'])")
    $null = $sb.AppendLine("    cache_read: $($ohTok['cache_read'])")
    $null = $sb.AppendLine("  cost_estimate_usd: $ohCost")
    $null = $sb.AppendLine("  cache_read_hit_ratio: $ohRatio")
    # Fix Pass3-F4: same null_cost_events surface for orchestrator overhead.
    $ohNullEvents = if ($overhead.ContainsKey('null_cost_events')) { [int]$overhead['null_cost_events'] } else { 0 }
    $null = $sb.AppendLine("  null_cost_events: $ohNullEvents")

    # dispatches
    $null = $sb.AppendLine('dispatches:')
    $null = $sb.AppendLine("  general_purpose_count: $($dispatches['general_purpose_count'])")
    $null = $sb.AppendLine("  unattributed_count: $($dispatches['unattributed_count'])")

    # totals
    $totTok = $totals['tokens']
    $totCost = script:Format-CostYaml -Value ([double]$totals['cost_estimate_usd'])
    $null = $sb.AppendLine('totals:')
    $null = $sb.AppendLine('  tokens:')
    $null = $sb.AppendLine("    input: $($totTok['input'])")
    $null = $sb.AppendLine("    output: $($totTok['output'])")
    $null = $sb.AppendLine("    cache_creation: $($totTok['cache_creation'])")
    $null = $sb.AppendLine("    cache_read: $($totTok['cache_read'])")
    $null = $sb.AppendLine("  cost_estimate_usd: $totCost")

    # anomaly_flags
    if ($null -eq $AnomalyFlags -or $AnomalyFlags.Count -eq 0) {
        $null = $sb.AppendLine('anomaly_flags: []')
    }
    else {
        $null = $sb.AppendLine('anomaly_flags:')
        foreach ($flag in $AnomalyFlags) {
            $metric = $flag['metric']
            $flagPort = if ($null -ne $flag['port']) { $flag['port'] } else { 'null' }
            $dir = $flag['direction']
            $conf = $flag['confidence']
            $vsBase = $flag['vs_baseline']
            $thisVal = if ($null -ne $flag['this_value']) { ([double]$flag['this_value']).ToString('G', $inv) } else { 'null' }
            $bMean = if ($null -ne $flag['baseline_mean']) { ([double]$flag['baseline_mean']).ToString('G', $inv) }   else { 'null' }
            $bMedian = if ($null -ne $flag['baseline_median']) { ([double]$flag['baseline_median']).ToString('G', $inv) } else { 'null' }
            $bStddev = if ($null -ne $flag['baseline_stddev']) { ([double]$flag['baseline_stddev']).ToString('G', $inv) } else { 'null' }
            $bN = if ($null -ne $flag['baseline_n']) { $flag['baseline_n'] } else { 0 }
            $cpVal = if ($null -ne $flag['checkpoint_value']) { ([double]$flag['checkpoint_value']).ToString('G', $inv) } else { 'null' }
            $null = $sb.AppendLine("  - metric: $metric")
            $null = $sb.AppendLine("    port: $flagPort")
            $null = $sb.AppendLine("    this_value: $thisVal")
            $null = $sb.AppendLine("    baseline_mean: $bMean")
            $null = $sb.AppendLine("    baseline_median: $bMedian")
            $null = $sb.AppendLine("    baseline_stddev: $bStddev")
            $null = $sb.AppendLine("    baseline_n: $bN")
            $null = $sb.AppendLine("    checkpoint_value: $cpVal")
            $null = $sb.AppendLine("    vs_baseline: $vsBase")
            $null = $sb.AppendLine("    direction: $dir")
            $null = $sb.AppendLine("    confidence: $conf")
        }
    }

    $null = $sb.Append('-->')

    return $sb.ToString()
}

#endregion
