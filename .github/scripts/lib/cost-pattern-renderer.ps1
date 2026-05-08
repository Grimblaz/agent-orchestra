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

function script:Format-CostRendererTokenCell {
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -ne $Value -and [int]$Value -gt 0) {
        return script:Format-TokenCount -Value ([int]$Value)
    }

    return '—'
}

function script:Format-CostRendererCostCell {
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -ne $Value -and [double]$Value -gt 0) {
        return script:Format-Cost -Value ([double]$Value)
    }

    return '—'
}

function script:Format-CostRendererRatioCell {
    [OutputType([string])]
    param(
        [int]$InputTokens,
        [int]$CacheCreationTokens,
        [int]$CacheReadTokens,
        [double]$Ratio
    )

    if (($InputTokens + $CacheCreationTokens + $CacheReadTokens) -gt 0) {
        return script:Format-Ratio -Value $Ratio
    }

    return '—'
}

function script:Format-CostYaml {
    <#
    .SYNOPSIS Formats a USD cost as a bare double string for YAML (invariant culture, 4 decimal places). #>
    [OutputType([string])]
    param([double]$Value)
    return $Value.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture)
}

function script:Format-CostRendererNullableCostYaml {
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    return script:Format-CostYaml -Value ([double]$Value)
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

function script:Test-CostRendererHasKey {
    param(
        [AllowNull()][object]$Bucket,
        [Parameter(Mandatory)][string]$Key
    )

    return ($Bucket -is [hashtable] -and $Bucket.ContainsKey($Key))
}

function script:Format-CostRendererYamlArray {
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]]$Values)

    $items = @($Values | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { '"' + [string]$_ + '"' })
    return '[' + ($items -join ', ') + ']'
}

function script:Test-CostRendererShouldEmitProviderSupport {
    [OutputType([bool])]
    param([AllowEmptyCollection()][object[]]$ProviderSupport)

    return ($ProviderSupport.Count -gt 0 -and -not ($ProviderSupport.Count -eq 1 -and [string]$ProviderSupport[0] -eq 'claude'))
}

function script:Get-CostRendererProviderNames {
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Providers)

    $providerNames = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @('claude', 'copilot')) {
        if ($Providers.ContainsKey($candidate)) { $providerNames.Add($candidate) }
    }
    foreach ($candidate in $Providers.Keys) {
        if (-not $providerNames.Contains([string]$candidate)) { $providerNames.Add([string]$candidate) }
    }

    return [string[]]$providerNames.ToArray()
}

function script:Format-CostRendererYamlScalar {
    [OutputType([string])]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return ($Value ? 'true' : 'false') }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return ([double]$Value).ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function script:Get-CostRendererProviderBucket {
    param(
        [AllowNull()][hashtable]$Bucket,
        [Parameter(Mandatory)][string]$Provider
    )

    if (script:Test-CostRendererHasKey -Bucket $Bucket -Key 'providers') {
        $providers = $Bucket['providers']
        if ($providers -is [hashtable] -and $providers.ContainsKey($Provider)) {
            return $providers[$Provider]
        }
    }

    return $null
}

function script:Test-CostRendererSupportsProvider {
    param(
        [AllowNull()][hashtable]$Bucket,
        [Parameter(Mandatory)][string]$Provider
    )

    if (script:Test-CostRendererHasKey -Bucket $Bucket -Key 'provider_support') {
        if (@($Bucket['provider_support']) -contains $Provider) { return $true }
    }

    if (script:Test-CostRendererHasKey -Bucket $Bucket -Key 'providers') {
        $providers = $Bucket['providers']
        if ($providers -is [hashtable] -and $providers.ContainsKey($Provider)) { return $true }
    }

    return $false
}

function script:Test-CostRendererMergedPort {
    param([AllowNull()][hashtable]$Bucket)

    return ((script:Test-CostRendererSupportsProvider -Bucket $Bucket -Provider 'claude') -and
        (script:Test-CostRendererSupportsProvider -Bucket $Bucket -Provider 'copilot'))
}

function script:Test-CostRendererCopilotOnlyRow {
    param([AllowNull()][hashtable]$Bucket)

    return ((script:Test-CostRendererSupportsProvider -Bucket $Bucket -Provider 'copilot') -and
        -not (script:Test-CostRendererSupportsProvider -Bucket $Bucket -Provider 'claude'))
}

function script:Test-CostRendererCopilotCacheUnavailable {
    param([AllowNull()][hashtable]$Bucket)

    if ((script:Test-CostRendererHasKey -Bucket $Bucket -Key 'cache_metric_unavailable') -and $Bucket['cache_metric_unavailable'] -eq $true) {
        return $true
    }

    $copilot = script:Get-CostRendererProviderBucket -Bucket $Bucket -Provider 'copilot'
    return ((script:Test-CostRendererHasKey -Bucket $copilot -Key 'cache_metric_unavailable') -and $copilot['cache_metric_unavailable'] -eq $true)
}

function script:Test-CostRendererCopilotRateUnavailable {
    param([AllowNull()][hashtable]$Bucket)

    if ((script:Test-CostRendererHasKey -Bucket $Bucket -Key 'rate_unavailable') -and $Bucket['rate_unavailable'] -eq $true) {
        return $true
    }

    $copilot = script:Get-CostRendererProviderBucket -Bucket $Bucket -Provider 'copilot'
    return ((script:Test-CostRendererHasKey -Bucket $copilot -Key 'rate_unavailable') -and $copilot['rate_unavailable'] -eq $true)
}

function script:Get-CostRendererCoverage {
    param([Parameter(Mandatory)][hashtable]$Attribution)

    if ($Attribution.ContainsKey('coverage') -and -not [string]::IsNullOrWhiteSpace([string]$Attribution['coverage'])) {
        return [string]$Attribution['coverage']
    }

    return ''
}

function script:Test-CostRendererCrossToolCoverage {
    param([AllowEmptyString()][string]$Coverage)

    return @('claude+copilot', 'copilot-only', 'claude-only-with-copilot-fallback-warning') -contains $Coverage
}

function script:Test-CostRendererFallbackWarning {
    param(
        [Parameter(Mandatory)][hashtable]$Attribution,
        [AllowEmptyString()][string]$Coverage
    )

    if ($Coverage -eq 'claude-only-with-copilot-fallback-warning') { return $true }
    return ($Attribution.ContainsKey('install_status') -and [string]$Attribution['install_status'] -eq 'missing-or-fallback')
}

function script:Format-CostRendererFallbackRemediationNote {
    [OutputType([string])]
    param()

    return '> **Copilot telemetry fallback**: Copilot telemetry may be incomplete or not included for this run. Run ``Initialize-CopilotCostCollection`` to configure Copilot-side collection before the next capture.'
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
        return "## Cost Pattern `u{26A0} no Claude or Copilot session activity recorded for this PR's branch; cross-tool collection is enabled — see ``Initialize-CopilotCostCollection`` if Copilot is installed but data is missing, or #488 for diagnostics. cost-fields unavailable; this run is excluded from rolling-history aggregation"
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

function script:Get-CostRendererIntValue {
    param(
        [AllowNull()][object]$Bucket,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Bucket -is [hashtable] -and $Bucket.ContainsKey($Key)) {
        return [int]$Bucket[$Key]
    }

    return 0
}

function script:Get-CostRendererNullEventTotal {
    param([Parameter(Mandatory)][hashtable]$Attribution)

    $nullEventTotal = 0
    $ports = $Attribution['ports']
    if ($ports -is [hashtable]) {
        foreach ($portName in $ports.Keys) {
            $nullEventTotal += script:Get-CostRendererIntValue -Bucket $ports[$portName] -Key 'null_cost_events'
        }
    }

    $nullEventTotal += script:Get-CostRendererIntValue -Bucket $Attribution['orchestrator_overhead'] -Key 'null_cost_events'
    return $nullEventTotal
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
    $hasCopilotCacheMetricFootnote = $false
    $hasCopilotRateFootnote = $false

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
            $displayPortName = if (script:Test-CostRendererMergedPort -Bucket $bucket) { "$portName (merged)" } else { $portName }
            $copilotOnlyRow = script:Test-CostRendererCopilotOnlyRow -Bucket $bucket
            $copilotCacheUnavailable = $copilotOnlyRow -and (script:Test-CostRendererCopilotCacheUnavailable -Bucket $bucket)
            $copilotRateUnavailable = $copilotOnlyRow -and (script:Test-CostRendererCopilotRateUnavailable -Bucket $bucket)

            $inputStr = script:Format-CostRendererTokenCell -Value $inputTok
            $outputStr = script:Format-CostRendererTokenCell -Value $outputTok
            $ccStr = if ($copilotCacheUnavailable) { 'n/a *' } else { script:Format-CostRendererTokenCell -Value $cc }
            $crStr = if ($copilotCacheUnavailable) { 'n/a *' } else { script:Format-CostRendererTokenCell -Value $cr }
            $ratioStr = if ($copilotCacheUnavailable) { 'n/a *' } else { script:Format-CostRendererRatioCell -InputTokens $inputTok -CacheCreationTokens $cc -CacheReadTokens $cr -Ratio $ratio }
            $costStr = if ($copilotRateUnavailable) { '' } else { script:Format-CostRendererCostCell -Value $cost }
            $anomStr = script:Get-PortAnomalyNames -AnomalyFlags $AnomalyFlags -PortName $portName

            if ($copilotCacheUnavailable) { $hasCopilotCacheMetricFootnote = $true }
            if ($copilotRateUnavailable) { $hasCopilotRateFootnote = $true }

            $lines.Add("| $displayPortName | $dc | $inputStr | $outputStr | $ccStr | $crStr | $ratioStr | $costStr |$anomStr|")
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

        $inputStr = script:Format-CostRendererTokenCell -Value $inputTok
        $outputStr = script:Format-CostRendererTokenCell -Value $outputTok
        $ccStr = script:Format-CostRendererTokenCell -Value $cc
        $crStr = script:Format-CostRendererTokenCell -Value $cr
        $ratioStr = script:Format-CostRendererRatioCell -InputTokens $inputTok -CacheCreationTokens $cc -CacheReadTokens $cr -Ratio $ratio
        $costStr = script:Format-CostRendererCostCell -Value $cost
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
        $inputStr = script:Format-CostRendererTokenCell -Value $tok['input']
        $outputStr = script:Format-CostRendererTokenCell -Value $tok['output']
        $ccStr = script:Format-CostRendererTokenCell -Value $tok['cache_creation']
        $crStr = script:Format-CostRendererTokenCell -Value $tok['cache_read']
        $costStr = script:Format-CostRendererCostCell -Value $bucket['cost_estimate_usd']
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

    $ohInputStr = script:Format-CostRendererTokenCell -Value $ohInput
    $ohOutputStr = script:Format-CostRendererTokenCell -Value $ohOutput
    $ohCCStr = script:Format-CostRendererTokenCell -Value $ohCC
    $ohCRStr = script:Format-CostRendererTokenCell -Value $ohCR
    $ohRatioStr = script:Format-CostRendererRatioCell -InputTokens $ohInput -CacheCreationTokens $ohCC -CacheReadTokens $ohCR -Ratio $ohRatio
    $ohCostStr = script:Format-CostRendererCostCell -Value $ohCost
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

    $totInputStr = script:Format-CostRendererTokenCell -Value $totInput
    $totOutputStr = script:Format-CostRendererTokenCell -Value $totOutput
    $totCCStr = script:Format-CostRendererTokenCell -Value $totCC
    $totCRStr = script:Format-CostRendererTokenCell -Value $totCR
    $totCostStr = script:Format-CostRendererCostCell -Value $totCost

    $lines.Add("| **TOTAL** | **$totDisp** | **$totInputStr** | **$totOutputStr** | **$totCCStr** | **$totCRStr** | — | **$totCostStr** | |")

    if ($hasSkillDriven) {
        $lines.Add('')
        $lines.Add('*rolled into orchestrator-overhead')
    }

    if ($hasCopilotCacheMetricFootnote) {
        $lines.Add('')
        $lines.Add('Copilot cache metrics are unavailable from Copilot telemetry; cache cells marked n/a * are excluded from cache-hit baselines.')
    }

    if ($hasCopilotRateFootnote) {
        $lines.Add('')
        $lines.Add('Copilot per-token rates not published; cost figures excluded for Copilot rows.')
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
    $coverage = script:Get-CostRendererCoverage -Attribution $Attribution

    $metadataLines = [System.Collections.Generic.List[string]]::new()
    if ($coverage) {
        $metadataLines.Add("coverage: $coverage")
    }
    if ((script:Test-CostRendererCrossToolCoverage -Coverage $coverage) -and
        $null -ne $RollingMeta -and
        $RollingMeta.ContainsKey('matching_coverage_history_count') -and
        [int]$RollingMeta['matching_coverage_history_count'] -lt 5) {
        $metadataLines.Add('⚠ building cross-tool baseline — matching-coverage history < 5 entries')
    }
    if ($coverage -eq 'claude-only-with-copilot-fallback-warning') {
        $metadataLines.Add('Coverage tags: claude+copilot = Claude and Copilot telemetry merged; claude-only = Claude telemetry only; copilot-only = Copilot telemetry only; claude-only-with-copilot-fallback-warning = Claude telemetry only while Copilot collection is missing or unmapped.')
    }

    # Fix Pass3-F4: surface null_cost_events when nonzero so unknown-model
    # cost undercounting is visible in the rendered markdown, not just buried
    # in the embedded YAML. Sums across ports and orchestrator overhead.
    $nullEventTotal = script:Get-CostRendererNullEventTotal -Attribution $Attribution

    $body = $header
    if ($metadataLines.Count -gt 0) {
        $body += "`n`n" + ($metadataLines -join "`n")
    }
    $body += "`n`n$table"
    if ($nullEventTotal -gt 0) {
        $body += "`n`n> **Note**: $nullEventTotal cost event(s) had unknown models not present in ``cost-rate-table.json`` and contributed null to the cost estimate. Update the rate table to include the missing model(s) for accurate attribution."
    }
    if ($Completeness['exclude_reason'] -eq 'phase-marker-only attribution; rolling-history excluded') {
        $body += "`n`n> **Note**: This Cost Pattern shows Claude-side phase-marker attribution. Copilot-side collection remains tracked by [#488](https://github.com/Grimblaz/agent-orchestra/issues/488)."
    }
    if (script:Test-CostRendererFallbackWarning -Attribution $Attribution -Coverage $coverage) {
        $body += "`n`n" + (script:Format-CostRendererFallbackRemediationNote)
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
    $coverage = script:Get-CostRendererCoverage -Attribution $Attribution
    [object[]]$providerSupport = if ($Attribution.ContainsKey('provider_support')) { @($Attribution['provider_support']) } else { @() }
    $shouldEmitProviderSupport = script:Test-CostRendererShouldEmitProviderSupport -ProviderSupport $providerSupport

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('<!-- cost-pattern-data')
    $null = $sb.AppendLine('version: 1')
    if ($shouldEmitProviderSupport) {
        $null = $sb.AppendLine('provider_support: ' + (script:Format-CostRendererYamlArray -Values $providerSupport))
    }
    if ($coverage) {
        $null = $sb.AppendLine("coverage: $coverage")
    }
    if ($Attribution.ContainsKey('install_status')) {
        $null = $sb.AppendLine("install_status: $($Attribution['install_status'])")
    }
    if ($Attribution.ContainsKey('unmapped_session_count')) {
        $null = $sb.AppendLine("unmapped_session_count: $($Attribution['unmapped_session_count'])")
    }
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
        $cost = script:Format-CostRendererNullableCostYaml -Value $bucket['cost_estimate_usd']
        $ratio = if ($null -ne $bucket['cache_read_hit_ratio']) { script:Format-RatioYaml -Value ([double]$bucket['cache_read_hit_ratio']) } else { 'null' }
        $mixed = if ($bucket['mixed_regime']) { 'true' } else { 'false' }
        $null = $sb.AppendLine("  - name: $portName")
        $null = $sb.AppendLine('    tokens:')
        $null = $sb.AppendLine('      input: ' + (script:Format-CostRendererYamlScalar -Value $tok['input']))
        $null = $sb.AppendLine('      output: ' + (script:Format-CostRendererYamlScalar -Value $tok['output']))
        $null = $sb.AppendLine('      cache_creation: ' + (script:Format-CostRendererYamlScalar -Value $tok['cache_creation']))
        $null = $sb.AppendLine('      cache_read: ' + (script:Format-CostRendererYamlScalar -Value $tok['cache_read']))
        $null = $sb.AppendLine("    dispatch_count: $($bucket['dispatch_count'])")
        $null = $sb.AppendLine("    prompt_size_chars: $($bucket['prompt_size_chars'])")
        $null = $sb.AppendLine("    cost_estimate_usd: $cost")
        $null = $sb.AppendLine("    cache_read_hit_ratio: $ratio")
        # Fix Pass3-F4: emit null_cost_events so downstream readers see when a
        # port had unknown-model cost events that produced no rate-table match.
        # Silent zero would mask cost undercounting whenever a new model variant
        # is introduced before cost-rate-table.json is updated.
        $nullEvents = script:Get-CostRendererIntValue -Bucket $bucket -Key 'null_cost_events'
        $null = $sb.AppendLine("    null_cost_events: $nullEvents")
        $null = $sb.AppendLine("    mixed_regime: $mixed")
        if ($bucket.ContainsKey('provider_support')) {
            [object[]]$portProviderSupport = @($bucket['provider_support'])
            if (script:Test-CostRendererShouldEmitProviderSupport -ProviderSupport $portProviderSupport) {
                $null = $sb.AppendLine('    provider_support: ' + (script:Format-CostRendererYamlArray -Values $portProviderSupport))
            }
        }
        if ($bucket.ContainsKey('providers') -and $bucket['providers'] -is [hashtable]) {
            $providers = $bucket['providers']

            $null = $sb.AppendLine('    providers:')
            foreach ($providerName in (script:Get-CostRendererProviderNames -Providers $providers)) {
                $provider = $providers[$providerName]
                $null = $sb.AppendLine("      $providerName`:")
                if ($provider.ContainsKey('tokens')) {
                    $providerTokens = $provider['tokens']
                    $null = $sb.AppendLine('        tokens:')
                    $null = $sb.AppendLine('          input: ' + (script:Format-CostRendererYamlScalar -Value $providerTokens['input']))
                    $null = $sb.AppendLine('          output: ' + (script:Format-CostRendererYamlScalar -Value $providerTokens['output']))
                    if ($providerTokens.ContainsKey('cache_creation')) {
                        $null = $sb.AppendLine('          cache_creation: ' + (script:Format-CostRendererYamlScalar -Value $providerTokens['cache_creation']))
                    }
                    if ($providerTokens.ContainsKey('cache_read')) {
                        $null = $sb.AppendLine('          cache_read: ' + (script:Format-CostRendererYamlScalar -Value $providerTokens['cache_read']))
                    }
                }
                foreach ($field in @('dispatch_count', 'prompt_size_chars', 'cost_estimate_usd', 'cache_read_hit_ratio', 'null_cost_events', 'mixed_regime', 'cache_metric_unavailable', 'rate_unavailable', 'per_token_rates_published')) {
                    if ($provider.ContainsKey($field)) {
                        $null = $sb.AppendLine("        $field`: " + (script:Format-CostRendererYamlScalar -Value $provider[$field]))
                    }
                }
            }
        }
    }

    # orchestrator_overhead
    $ohTok = $overhead['tokens']
    $ohCost = script:Format-CostRendererNullableCostYaml -Value $overhead['cost_estimate_usd']
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
    $ohNullEvents = script:Get-CostRendererIntValue -Bucket $overhead -Key 'null_cost_events'
    $null = $sb.AppendLine("  null_cost_events: $ohNullEvents")

    # dispatches
    $null = $sb.AppendLine('dispatches:')
    $null = $sb.AppendLine("  general_purpose_count: $($dispatches['general_purpose_count'])")
    $null = $sb.AppendLine("  unattributed_count: $($dispatches['unattributed_count'])")

    # totals
    $totTok = $totals['tokens']
    $totCost = script:Format-CostRendererNullableCostYaml -Value $totals['cost_estimate_usd']
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

    return ($sb.ToString() -replace "`r`n", "`n")
}

#endregion
