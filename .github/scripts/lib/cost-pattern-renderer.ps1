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
# Canonical port-display order for the cost-pattern Markdown table. Pipeline-entry ports appear first
# (experience, design, plan, orchestration) in semantic insertion order; implement-* and CE-Gate ports
# follow. Consumers MUST iterate by-name and MUST NOT positional-index (e.g., $arr[0..2] to mean "the
# upstream three") — the array semantics describe display ordering, not membership cohorts. Adding a new
# pipeline-entry port (#577 added 'orchestration') extends the prefix; positional consumers would silently
# include the new port in their slice.
$script:CostRendererPortOrder = @(
    'experience', 'design', 'plan', 'orchestration',
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

function script:Format-CostRendererSanitizedModelString {
    <#
    .SYNOPSIS
        Sanitizes an externally-sourced provider-qualified model string before it
        enters the null-event Note or the embedded cost-pattern-data YAML array
        (issue #487 s3, plan findings M2/M10/M11/M13).
    .DESCRIPTION
        Model strings originate from transcript telemetry and the Copilot OTEL
        walker (cost-walker-copilot.ps1) — neither source is validated, so this
        string is adversary-controlled by the time it reaches the renderer.

        Pipeline, in this exact order (load-bearing):
          1. Truncate to 128 characters FIRST. Neutralizing before truncating can
             bisect a multi-character replacement at the cut boundary, leaving a
             dangling partial-replacement artifact. Truncating first means
             whatever survives to the neutralization pass is neutralized in full.
          2. Neutralize by SUBSTITUTION, never escaping. The YAML consumer
             (ConvertFrom-CostPatternYamlScalar / ConvertFrom-CostPatternYamlArray
             in cost-rolling-history.ps1) strips outer quotes on read but has
             no unescape step anywhere, so an escaped sequence would read back as
             those literal characters, not the original — breaking the
             verbatim-string contract of the array. Do not reuse Format-CostRendererYamlArray:
             it performs zero escaping and is only safe for internally-controlled
             values.

        Neutralized (each replaced with a fixed-width safe placeholder that
        itself contains none of the other neutralized patterns):
          - CR, LF, and other C0/DEL control characters — a survivor forges a new
            top-level YAML field, since the parser splits on `\r?\n`
            (cost-rolling-history.ps1:156) with `^\s*`-anchored field matchers.
          - `,` (comma) — the array parser splits unconditionally and
            quote-blind (cost-rolling-history.ps1:64), so a survivor splits one
            array entry into two.
          - `<!--` / `-->` — can terminate or forge the enclosing
            cost-pattern-data block, which is extracted by a first-match,
            non-greedy regex (cost-rolling-history.ps1:22-29).
          - `` ` `` (backtick) — the Note wraps each sanitized string in a
            single backtick pair; GFM closes a Markdown code span at the next
            backtick, so a survivor lets adversary-controlled text (e.g. a
            Markdown link) escape the span and render live in the PR body
            (plan finding M1). Neutralized last, after the comment-marker
            substitutions, so the `(backtick)` placeholder text itself is
            never re-matched by an earlier rule.

        A literal double-quote is intentionally NOT in the neutralization set:
        ConvertFrom-CostPatternYamlArray only strips the outermost quote
        character of each split item (cost-rolling-history.ps1:66-68); an
        embedded quote round-trips correctly because the split already happened
        on (already-neutralized) commas, not on quotes.
    .PARAMETER Model
        Raw provider-qualified model string (e.g. "claude/claude-unknown-future-model").
    .OUTPUTS
        [string] Sanitized model string, safe to wrap in a Markdown code span or
        a quoted YAML array entry.
    #>
    [OutputType([string])]
    param([AllowNull()][string]$Model)

    if ([string]::IsNullOrEmpty($Model)) { return '' }

    # 1. Truncate first. Substring operates on UTF-16 code units, so a cut at
    # exactly 128 can bisect the surrogate pair of an astral-plane character
    # (high surrogate kept at index 127, low surrogate dropped at index 128),
    # leaving an unpaired surrogate that no later -replace targets (plan
    # finding M7). If the character at the cut boundary is a high surrogate,
    # back the cut up by one so the pair stays intact (or fully excluded).
    $truncateLength = 128
    if ($Model.Length -gt 128 -and [char]::IsHighSurrogate($Model[127])) {
        $truncateLength = 127
    }
    $truncated = if ($Model.Length -gt $truncateLength) { $Model.Substring(0, $truncateLength) } else { $Model }

    # 2. Neutralize by substitution (never escaping).
    $sanitized = $truncated `
        -replace '[\x00-\x1F\x7F]', ' ' `
        -replace ',', ' ' `
        -replace '<!--', '(comment-open)' `
        -replace '-->', '(comment-close)' `
        -replace '`', '(backtick)'

    return $sanitized
}

function script:Get-CostRendererDedupedSanitizedModels {
    <#
    .SYNOPSIS
        Sanitizes, dedups, and re-sorts the unknown_models list, WITHOUT
        capping it at 10. Callers that need the shared 10-entry cap should
        use Get-CostRendererSanitizedUnknownModels; callers that need to know
        whether genuine overflow exists (as opposed to a phantom count
        inflated by pre-sanitization duplicates/collisions — issue #487 F4)
        should use this uncapped form to compute the true unique count first.
    .DESCRIPTION
        Dedup and sort happen AFTER sanitization, not before (code-review
        findings M4/M9): the raw list is deduped and sorted on the
        pre-sanitization string, but the character substitutions from sanitization
        (e.g. comma/control-char -> space) can map two distinct raw strings
        to the same sanitized output, and can change collation order.
        Deduping and re-sorting post-sanitization guarantees the rendered
        Note and YAML array never show visible duplicates and are actually
        sorted.
    #>
    [OutputType([string[]])]
    param([AllowEmptyCollection()][object[]]$UnknownModels)

    $sanitized = @($UnknownModels | ForEach-Object { script:Format-CostRendererSanitizedModelString -Model ([string]$_) })
    return , @($sanitized | Select-Object -Unique | Sort-Object)
}

function script:Get-CostRendererSanitizedUnknownModels {
    <#
    .SYNOPSIS
        Sanitizes, dedups, re-sorts, and caps the unknown_models list at 10
        entries — the shared cap between the Note and the YAML array (plan
        finding M12: the Note-only "+N more" overflow suffix must never enter
        the machine-read array).
    #>
    [OutputType([string[]])]
    param([AllowEmptyCollection()][object[]]$UnknownModels)

    $dedupedSorted = script:Get-CostRendererDedupedSanitizedModels -UnknownModels $UnknownModels
    return , @($dedupedSorted | Select-Object -First 10)
}

function script:Format-CostRendererUnknownModelsYamlArray {
    <#
    .SYNOPSIS
        Renders the sanitized, capped unknown_models list as a YAML inline array.
        Never includes the Note-only "+N more" overflow suffix.
    #>
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]]$UnknownModels)

    $sanitizedModels = script:Get-CostRendererSanitizedUnknownModels -UnknownModels $UnknownModels
    $items = @($sanitizedModels | ForEach-Object { '"' + $_ + '"' })
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

function script:Test-CostRendererZeroActivityBucket {
    <#
    .SYNOPSIS
        True when a per-port row carries no attributed activity: zero
        dispatches, a zero-or-null cost estimate, and all four token counts
        at zero (issue #489 s1, AC3/AC4). Anomaly-flag status is deliberately
        NOT part of this predicate — callers combine it with their own
        anomaly check so a stage that should have run and did not (an
        anomaly-flagged zero row) is never treated as suppressible here.
    #>
    [OutputType([bool])]
    param(
        [int]$DispatchCount,
        [AllowNull()][object]$Cost,
        [int]$InputTokens,
        [int]$OutputTokens,
        [int]$CacheCreationTokens,
        [int]$CacheReadTokens
    )

    $costIsZeroOrNull = ($null -eq $Cost) -or ([double]$Cost -eq 0.0)

    return ($DispatchCount -eq 0) -and $costIsZeroOrNull -and
    ($InputTokens -eq 0) -and ($OutputTokens -eq 0) -and
    ($CacheCreationTokens -eq 0) -and ($CacheReadTokens -eq 0)
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

function script:Format-CostPatternCoverageAnnotation {
    <#
    .SYNOPSIS
        Renders the coverage-annotation suffix appended to a populated header
        when the walker Tier-2 corroboration rejected one or more candidate
        directories (issue #825 s2, M6). Returns '' when RejectedDirCount is
        not positive, so callers can unconditionally append the result.
    #>
    [OutputType([string])]
    param([int]$RejectedDirCount = 0)

    if ($RejectedDirCount -le 0) { return '' }
    return " (activity from $RejectedDirCount unverifiable location(s) may be excluded)"
}

function script:Format-CostPatternUnknownHeader {
    <#
    .SYNOPSIS
        Renders the unknown-completeness header across the four honest render
        states (issue #825 s2, M12; L11 issue #825 post-review fix added the
        4th, budget-exceeded, state). Pure — reads only the caller-computed
        -RenderContext, never $env: itself, so the sharded Pester runner stays
        deterministic. None of the four states asserts "no session activity"
        as settled fact: each names the real reason the walk found nothing, or
        that the walk could not run at all.
    .PARAMETER RenderContext
        Optional hashtable with IsCi / ProjectsRootPresent / DegradedReason.
        Missing IsCi/ProjectsRootPresent keys default to false (non-CI,
        projects root absent) — the more conservative "no local data" framing
        rather than a false honest-zero claim when the caller did not supply
        enough context. DegradedReason (L11) is read only when IsCi is false
        and ProjectsRootPresent is true — a local walker TIMEOUT
        (degraded_reason = 'budget-exceeded', set in cost-fcl-helpers.ps1)
        must not render the identical "searched and none matched" message a
        genuine empty walk (degraded_reason = 'no-transcript-found') gets —
        that collision loses the actionable "retry with a larger walker
        budget" signal.
    #>
    [OutputType([string])]
    param([hashtable]$RenderContext = $null)

    $isCi = $false
    $projectsRootPresent = $false
    $degradedReason = $null
    if ($null -ne $RenderContext) {
        if ($RenderContext.ContainsKey('IsCi')) { $isCi = [bool]$RenderContext['IsCi'] }
        if ($RenderContext.ContainsKey('ProjectsRootPresent')) { $projectsRootPresent = [bool]$RenderContext['ProjectsRootPresent'] }
        if ($RenderContext.ContainsKey('DegradedReason')) { $degradedReason = [string]$RenderContext['DegradedReason'] }
    }

    if ($isCi) {
        return "## Cost Pattern `u{26A0} CI cannot see local transcripts; a local re-walk will upgrade this block. cost-fields unavailable; this run is excluded from rolling-history aggregation"
    }

    if (-not $projectsRootPresent) {
        return "## Cost Pattern `u{26A0} no local session data on this machine; a re-walk from the machine holding the transcripts will upgrade this block. cost-fields unavailable; this run is excluded from rolling-history aggregation"
    }

    if ($degradedReason -eq 'budget-exceeded') {
        return "## Cost Pattern `u{26A0} the local walk exceeded its time budget or stopped before finishing searching this PR branch/session; if it was a timeout, retry the walk on this machine with a larger FRAME_CREDIT_LEDGER_TEST_COST_BUDGET_SECONDS override. cost-fields unavailable; this run is excluded from rolling-history aggregation"
    }

    return "## Cost Pattern `u{26A0} transcripts were searched on this machine and none matched this PR branch/session; possible causes: the walk ran where transcripts are unavailable, the local walk never ran or exited before the cost step, a since-deleted sibling worktree held the events, the branch was created mid-session outside the phase-marker windows, or the linked issue could not be resolved from the branch name. cost-fields unavailable; this run is excluded from rolling-history aggregation"
}

function script:Build-CostPatternHeader {
    <#
    .SYNOPSIS
        Returns the header line for the ## Cost Pattern section.
    .PARAMETER RenderContext
        Issue #825 s2. Optional hashtable with IsCi / ProjectsRootPresent
        booleans, used only for the unknown-completeness branch. See
        Format-CostPatternUnknownHeader.
    .PARAMETER RejectedDirCount
        Issue #825 s2, M6. Count of Tier-2 branch-matched candidate
        directories the walker rejected for failing corroboration. When
        greater than zero, a populated (non-unknown) header carries a
        coverage-annotation suffix naming the excluded location count.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Completeness,
        [AllowEmptyCollection()][hashtable[]]$AnomalyFlags = @(),
        [hashtable]$RollingMeta = $null,
        [hashtable]$RenderContext = $null,
        [int]$RejectedDirCount = 0
    )

    $completenessValue = $Completeness['completeness']
    $excluded = $Completeness['excluded_from_rolling_baseline']
    $excludeReason = $Completeness['exclude_reason']
    $stopReason = $Completeness['stop_reason']

    # unknown session (issue #825 s2, M12): no populated data exists, so this
    # branch returns directly — it is never decorated with the coverage
    # annotation below, which is scoped to populated blocks only.
    if ($completenessValue -eq 'unknown') {
        return script:Format-CostPatternUnknownHeader -RenderContext $RenderContext
    }

    $header = $null

    # eligible-partial session (issue #824 M6): a mid-session capture that
    # Resolve-BaselineEligibility promoted to baseline-eligible. Self-contained —
    # always carries the mid-session disclosure and appends its own anomaly-count
    # or timed-out qualifier here, so it never falls through to the excluded-partial
    # string below or the "within rolling baseline" string for complete sessions.
    if ($completenessValue -eq 'partial' -and $excluded -eq $false) {
        $disclosure = 'mid-session capture — baseline-eligible; totals may understate the final turn'
        if ($null -ne $RollingMeta -and $RollingMeta['timed_out'] -eq $true) {
            $header = "## Cost Pattern `u{26A0} $disclosure; rolling-history fetch timed out — anomaly review unavailable for this run; per-port table shown below"
        }
        elseif ($null -ne $AnomalyFlags -and $AnomalyFlags.Count -gt 0) {
            $n = $AnomalyFlags.Count
            $header = "## Cost Pattern `u{26A0} $disclosure ($n anomalies vs rolling baseline)"
        }
        else {
            $header = "## Cost Pattern `u{26A0} $disclosure"
        }
    }
    # partial session (excluded from rolling-baseline aggregation)
    elseif ($completenessValue -eq 'partial') {
        $reason = if ($stopReason) { $stopReason } else { 'unknown stop reason' }
        $header = "## Cost Pattern `u{26A0} session incomplete ($reason); cost-fields show partial data; this run is excluded from rolling-history aggregation"
    }
    # rolling-history timed out
    elseif ($null -ne $RollingMeta -and $RollingMeta['timed_out'] -eq $true) {
        $header = "## Cost Pattern `u{26A0} rolling-history fetch timed out — anomaly review unavailable for this run; per-port table shown below"
    }
    # complete session, excluded (outlier-PR annotation)
    elseif ($excluded -and $null -ne $excludeReason -and $excludeReason -ne '' -and $completenessValue -eq 'complete') {
        $header = "## Cost Pattern `u{26A0} this PR is annotated $excludeReason; excluded from rolling-history aggregation by future PRs"
    }
    # complete, anomaly flags present
    elseif ($null -ne $AnomalyFlags -and $AnomalyFlags.Count -gt 0) {
        $n = $AnomalyFlags.Count
        $header = "## Cost Pattern ($n anomalies vs rolling baseline)"
    }
    # complete, clean
    else {
        $header = "## Cost Pattern — within rolling baseline"
    }

    return $header + (script:Format-CostPatternCoverageAnnotation -RejectedDirCount $RejectedDirCount)
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
            $matchesPort = ($null -ne $flagPort -and $flagPort -eq $PortName) -or
            ($null -eq $flagPort -and [string]::IsNullOrEmpty($PortName))
            # C14: a null/blank metric cannot produce a real name — filter it out here
            # so it never contributes an empty entry to the joined name list below.
            # Without this, a port whose only "anomaly" is a malformed/blank metric
            # field would still read as "has an anomaly" downstream (via
            # Test-CostRendererPortHasAnomaly), incorrectly defeating zero-activity
            # suppression for an otherwise-inactive port.
            $matchesPort -and -not [string]::IsNullOrWhiteSpace([string]$_['metric'])
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

function script:Test-CostRendererPortHasAnomaly {
    <#
    .SYNOPSIS
        True when a port anomaly-display string carries a real anomaly name
        rather than the empty-anomaly sentinel returned by Get-PortAnomalyNames.
        Centralizes the sentinel comparison so both row-emitting branches in
        Build-CostPatternTable (in-attribution and not-in-attribution) derive
        "has an anomaly" the same way — used to override the issue #489 s1
        zero-activity suppression guard.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$AnomalyDisplay)

    return $AnomalyDisplay -ne ' — '
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

function script:Build-CostRendererNullEventNote {
    <#
    .SYNOPSIS
        Renders the per-reason null-cost-event Note naming addable unknown
        models (issue #487 s3, AC2). Callers only invoke this when the
        attribution result carries the unknown_models / null_cost_events_by_reason
        additive fields (issue #487 s2); older cached results fall back to the
        original count-only Note for backwards compatibility.
    .OUTPUTS
        [string] The blockquote Note text (no leading/trailing blank lines).
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Attribution)

    $unknownModels = @($Attribution['unknown_models'])
    $reasonCounts = $Attribution['null_cost_events_by_reason']

    $unknownKeyCount = script:Get-CostRendererIntValue -Bucket $reasonCounts -Key 'unknown_key'
    $rateUnavailableCount = script:Get-CostRendererIntValue -Bucket $reasonCounts -Key 'rate_unavailable'
    # Issue #487 CE-F2: rate_unavailable_malformed is an additive subset of rate_unavailable
    # (see Add-NullCostEventReason). Absent on pre-CE-F2 cached results, defaulting to 0 via
    # Get-CostRendererIntValue — in that case byDesignRateUnavailableCount equals the full
    # rate_unavailable total, preserving the original count-only "intentionally unpublished"
    # rendering exactly (backwards compatibility).
    $malformedRateCount = script:Get-CostRendererIntValue -Bucket $reasonCounts -Key 'rate_unavailable_malformed'
    $byDesignRateUnavailableCount = $rateUnavailableCount - $malformedRateCount
    $emptyModelCount = script:Get-CostRendererIntValue -Bucket $reasonCounts -Key 'empty_model'

    $clauses = [System.Collections.Generic.List[string]]::new()

    if ($unknownKeyCount -gt 0) {
        # Issue #487 F4: overflow is computed from the deduped-and-sanitized
        # identifier count, not the raw pre-sanitization array length —
        # sanitization can collapse distinct raw strings (or repeated raw
        # strings for the same unknown model) onto the same output, which
        # would otherwise inflate the raw count and produce a phantom
        # "+N more" suffix for models that are already fully shown.
        $dedupedModels = script:Get-CostRendererDedupedSanitizedModels -UnknownModels $unknownModels
        $sanitizedModels = @($dedupedModels | Select-Object -First 10)
        $modelList = ($sanitizedModels | ForEach-Object { '`' + $_ + '`' }) -join ', '
        $overflow = [Math]::Max(0, $dedupedModels.Count - 10)
        if ($overflow -gt 0) {
            $modelList += ", +$overflow more"
        }
        $clauses.Add("$unknownKeyCount event(s) from models missing from the rate table: $modelList — add rows to ``cost-rate-table.json`` (see ``cost-rate-table.md`` for the exact row format).")
    }

    if ($byDesignRateUnavailableCount -gt 0) {
        $clauses.Add("$byDesignRateUnavailableCount event(s) from models with intentionally unpublished rates.")
    }

    if ($malformedRateCount -gt 0) {
        # Issue #487 CE-F2: unlike the by-design clause above, this is NOT an intentional
        # gap — it is a partially-null rate-table row (an editing mistake), so the model is
        # named (reusing the same sanitize/dedup/sort/cap pipeline as unknown_key) and the
        # wording avoids the word "intentional".
        $malformedModels = @($Attribution['malformed_rate_models'])
        # Issue #487 F4: same fix as the unknown_key clause above — compute
        # overflow from the deduped-and-sanitized count, not raw length.
        $dedupedMalformedModels = script:Get-CostRendererDedupedSanitizedModels -UnknownModels $malformedModels
        $sanitizedMalformedModels = @($dedupedMalformedModels | Select-Object -First 10)
        $malformedModelList = ($sanitizedMalformedModels | ForEach-Object { '`' + $_ + '`' }) -join ', '
        $malformedOverflow = [Math]::Max(0, $dedupedMalformedModels.Count - 10)
        if ($malformedOverflow -gt 0) {
            $malformedModelList += ", +$malformedOverflow more"
        }
        $clauses.Add("$malformedRateCount event(s) from models with an incomplete rate-table row (some rate fields are null): $malformedModelList — check ``cost-rate-table.json``.")
    }

    if ($emptyModelCount -gt 0) {
        $clauses.Add("$emptyModelCount event(s) had no model identifier.")
    }

    return '> **Note**: ' + ($clauses -join ' ')
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
    $suppressedPortCount = 0

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
    # Add ports present in attribution that are not in canonical order (except special ones)
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
            $hasAnomaly = script:Test-CostRendererPortHasAnomaly -AnomalyDisplay $anomStr

            if ($copilotCacheUnavailable) { $hasCopilotCacheMetricFootnote = $true }
            if ($copilotRateUnavailable) { $hasCopilotRateFootnote = $true }

            # Issue #489 s1 (AC3/AC4): suppress a fully zero-activity in-attribution
            # row from the visible table. Guarded only here at the $lines.Add call —
            # never a `continue` at the loop top — so the Copilot footnote latches
            # above still fire even when the row itself ends up suppressed.
            $isZeroActivity = script:Test-CostRendererZeroActivityBucket `
                -DispatchCount $dc -Cost $cost `
                -InputTokens $inputTok -OutputTokens $outputTok `
                -CacheCreationTokens $cc -CacheReadTokens $cr

            if ($isZeroActivity -and -not $hasAnomaly) {
                $suppressedPortCount++
            }
            else {
                $lines.Add("| $displayPortName | $dc | $inputStr | $outputStr | $ccStr | $crStr | $ratioStr | $costStr |$anomStr|")
            }
        }
        else {
            # Port not in attribution — zero dispatches, dashes for everything.
            # Issue #489 s1: there is no bucket to read here, so suppress unless
            # an anomaly flag names this port (a stage that should have run and
            # did not is exactly the row a maintainer needs to see).
            $anomStr = script:Get-PortAnomalyNames -AnomalyFlags $AnomalyFlags -PortName $portName
            $hasAnomaly = script:Test-CostRendererPortHasAnomaly -AnomalyDisplay $anomStr

            if ($hasAnomaly) {
                $lines.Add("| $portName | 0 | — | — | — | — | — | — |$anomStr|")
            }
            else {
                $suppressedPortCount++
            }
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

    if ($suppressedPortCount -gt 0) {
        $lines.Add('')
        if ($suppressedPortCount -eq 1) {
            $lines.Add('1 port had zero dispatches, zero attributed cost, and zero token activity, and is omitted from this table.')
        }
        else {
            $lines.Add("$suppressedPortCount ports had zero dispatches, zero attributed cost, and zero token activity, and are omitted from this table.")
        }
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
    .PARAMETER RenderContext
        Issue #825 s2. Optional hashtable with IsCi / ProjectsRootPresent
        booleans, threaded to the unknown-completeness header. Pure — this
        function never reads $env: itself; the caller computes both flags.
    .PARAMETER RejectedDirCount
        Issue #825 s2, M6. Count of Tier-2 branch-matched candidate
        directories the walker rejected for failing corroboration; drives the
        coverage-annotation suffix on populated (non-unknown) headers.
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
        [string]$Branch = '',
        [hashtable]$RenderContext = $null,
        [int]$RejectedDirCount = 0
    )

    $header = script:Build-CostPatternHeader -Completeness $Completeness -AnomalyFlags $AnomalyFlags -RollingMeta $RollingMeta -RenderContext $RenderContext -RejectedDirCount $RejectedDirCount
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
        # Issue #487 s3: prefer the per-reason breakdown that names addable
        # unknown models when the attribution result carries the additive
        # unknown_models / null_cost_events_by_reason fields (issue #487 s2).
        # Absent fields (e.g. an older cached attribution result from before
        # this change) fall back to the original count-only Note — plan
        # Invariant, backwards compatibility.
        if ($Attribution.ContainsKey('unknown_models') -and $Attribution.ContainsKey('null_cost_events_by_reason')) {
            $body += "`n`n" + (script:Build-CostRendererNullEventNote -Attribution $Attribution)
        }
        else {
            $body += "`n`n> **Note**: $nullEventTotal cost event(s) had unknown models not present in ``cost-rate-table.json`` and contributed null to the cost estimate. Update the rate table to include the missing model(s) for accurate attribution."
        }
    }
    if ($Completeness['exclude_reason'] -eq 'phase-marker-only attribution; rolling-history excluded') {
        $body += "`n`n> **Note**: This Cost Pattern shows Claude-side phase-marker attribution. Copilot-side collection was not captured for this run."
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
    .PARAMETER SessionId
        Additive post-#824 field: the capture-time session identity (used by the s4
        harvest to re-walk and verify the originating transcript). Empty string when
        the caller has no session identity to persist.
    .PARAMETER HeadRef
        Additive post-#824 field: the capture-time head_ref (used by the s4 harvest
        as the walk key for a bounded next-session upgrade). Empty string when the
        caller has no head_ref to persist.
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
        [string]$Branch = '',
        [string]$SessionId = '',
        [string]$HeadRef = ''
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
    $null = $sb.AppendLine('phase_scope: branch-session-only')
    $null = $sb.AppendLine("pr: $Pr")
    $null = $sb.AppendLine("branch: $Branch")

    # Additive post-#824 baseline-eligibility fields (issue #824 s2). capture_point is
    # sourced from the eligibility result the caller passes in via $Completeness (added
    # in place by Resolve-BaselineEligibility); session_id/head_ref are capture-time
    # targeting keys the s4 harvest uses to re-walk and verify the originating transcript.
    # Must render before the ports: block — the parser ports loop treats the next
    # zero-indent top-level key as the end of the block.
    $capturePointValue = if ($Completeness.ContainsKey('capture_point')) { [string]$Completeness['capture_point'] } else { 'n/a' }
    $null = $sb.AppendLine("capture_point: $capturePointValue")
    $null = $sb.AppendLine("session_id: $SessionId")
    $null = $sb.AppendLine("head_ref: $HeadRef")

    # Additive post-#487 fields (issue #487 s3, plan finding M16). Must render
    # before the ports: block for the same reason as the baseline-eligibility
    # fields above — the parser ports loop treats the next zero-indent
    # top-level key as the end of the block (cost-rolling-history.ps1:266).
    # unknown_models carries at most 10 sanitized, verbatim provider-qualified
    # strings — never the Note-only "+N more" overflow suffix (M12). This field
    # has zero readers today, by design: an additive write-only disclosure
    # field, consistent with the existing matcher-less phase_scope/branch
    # fields (plan Decisions block).
    if ($Attribution.ContainsKey('unknown_models')) {
        $unknownModelsYaml = script:Format-CostRendererUnknownModelsYamlArray -UnknownModels @($Attribution['unknown_models'])
        $null = $sb.AppendLine("unknown_models: $unknownModelsYaml")
    }
    # Issue #487 CE-F2: additive sibling to unknown_models, reusing the same sanitize/
    # dedup/sort/cap array renderer. Names models whose rate-table row was partially
    # null (malformed), as opposed to fully-null-by-design rows (e.g. Copilot).
    if ($Attribution.ContainsKey('malformed_rate_models')) {
        $malformedRateModelsYaml = script:Format-CostRendererUnknownModelsYamlArray -UnknownModels @($Attribution['malformed_rate_models'])
        $null = $sb.AppendLine("malformed_rate_models: $malformedRateModelsYaml")
    }
    if ($Attribution.ContainsKey('null_cost_events_by_reason')) {
        $reasonCounts = $Attribution['null_cost_events_by_reason']
        $null = $sb.AppendLine('null_cost_events_by_reason:')
        $null = $sb.AppendLine("  unknown_key: $(script:Get-CostRendererIntValue -Bucket $reasonCounts -Key 'unknown_key')")
        $null = $sb.AppendLine("  rate_unavailable: $(script:Get-CostRendererIntValue -Bucket $reasonCounts -Key 'rate_unavailable')")
        # Issue #487 CE-F2: additive subset counter of rate_unavailable above (never a
        # replacement) — see Add-NullCostEventReason for the union-total invariant.
        $null = $sb.AppendLine("  rate_unavailable_malformed: $(script:Get-CostRendererIntValue -Bucket $reasonCounts -Key 'rate_unavailable_malformed')")
        $null = $sb.AppendLine("  empty_model: $(script:Get-CostRendererIntValue -Bucket $reasonCounts -Key 'empty_model')")
    }

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
