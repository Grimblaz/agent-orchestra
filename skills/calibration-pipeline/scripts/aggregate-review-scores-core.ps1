#Requires -Version 7.0
<#
.SYNOPSIS
    Library for aggregate-review-scores logic. Dot-source this file and call Invoke-AggregateReviewScores.
#>

# Capture library directory at dot-source time (before any function definitions)
$script:_ARSCoreLibDir = Split-Path -Parent $PSCommandPath
. "$script:_ARSCoreLibDir/pipeline-metrics-helpers.ps1"

# ---------------------------------------------------------------------------
# Shared helper: safe property read for PSCustomObject/IDictionary
# ---------------------------------------------------------------------------
function Get-FlexProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

# ---------------------------------------------------------------------------
# Shared helper: coerce PSCustomObject to hashtable
# ---------------------------------------------------------------------------
function ConvertTo-Hashtable {
    param([PSCustomObject]$InputObject)
    $h = @{}
    $InputObject.PSObject.Properties | ForEach-Object {
        $val = $_.Value
        if ($val -is [datetime]) {
            $val = $val.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $h[$_.Name] = $val
    }
    return $h
}

# ---------------------------------------------------------------------------
# Shared helper: emit extraction_agents YAML block
# ---------------------------------------------------------------------------
function Write-ExtractionAgentsYaml {
    param(
        [hashtable]$ComplexityOverCeilingHistory,
        [int]$PersistentThreshold,
        [System.Text.StringBuilder]$Builder
    )
    $candidates = @($ComplexityOverCeilingHistory.Keys | Where-Object {
            [int](Get-FlexProperty $ComplexityOverCeilingHistory[$_] 'consecutive_count') -ge $PersistentThreshold
        } | Sort-Object)
    if ($candidates.Count -eq 0) { return }
    [void]$Builder.AppendLine('extraction_agents:')
    foreach ($agent in $candidates) {
        $cnt = [int](Get-FlexProperty $ComplexityOverCeilingHistory[$agent] 'consecutive_count')
        [void]$Builder.AppendLine("  - file: $agent")
        [void]$Builder.AppendLine("    consecutive_over_ceiling: $cnt")
        [void]$Builder.AppendLine("    persistent_threshold: $PersistentThreshold")
    }
}

# ---------------------------------------------------------------------------
# Shared helper: check whether a pattern (key + evidence PRs) is already in
# a proposals list. Works with both hashtable and PSCustomObject elements.
# ---------------------------------------------------------------------------
function Test-PatternProposed {
    param([object[]]$Proposals, [string]$PatternKey, [int[]]$EvidencePrs)
    foreach ($prop in $Proposals) {
        $propKey = if ($prop -is [hashtable]) { $prop['pattern_key'] } else { $prop.pattern_key }
        $propPrs = if ($prop -is [hashtable]) { @($prop['evidence_prs']) } else { @($prop.evidence_prs) }
        if ($propKey -eq $PatternKey) {
            $sortedPropPrs = @($propPrs | ForEach-Object { [int]$_ } | Sort-Object)
            if ($null -eq (Compare-Object $EvidencePrs $sortedPropPrs)) {
                # $null means no differences -> arrays are identical
                return $true
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Private helper: Measure-WindowCategoryTotals
# Sums per-category wTotal/wAccepted across a PrContributions window.
# Used by Measure-FixEffectiveness for before/after window accumulation.
# ---------------------------------------------------------------------------
function Measure-WindowCategoryTotals {
    param([object[]]$Window, [string]$Category)
    $wt = 0.0; $wa = 0.0
    foreach ($c in $Window) {
        if ($null -ne $c.categories -and $c.categories.ContainsKey($Category)) {
            $wt += $c.categories[$Category].wTotal
            $wa += $c.categories[$Category].wAccepted
        }
    }
    return @{ wTotal = $wt; wAccepted = $wa; prCount = $Window.Count }
}

# ---------------------------------------------------------------------------
# Private helper: Measure-FixEffectiveness
# Computes before/after sustain rate splits per fix proposal (Phase 3).
# Pure function — no side effects, no gh calls, no file writes.
# ---------------------------------------------------------------------------
function Measure-FixEffectiveness {
    param(
        [object[]]$ProposalsEmitted,
        [object[]]$PrContributions,
        [double]$Deadzone = 0.05,
        [int]$MinPostFixPrs = 5
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $awaitingMerge = 0

    # Step A: Count awaiting-merge entries
    foreach ($entry in $ProposalsEmitted) {
        $fixIssueNum = Get-FlexProperty $entry 'fix_issue_number'
        $fixMerged = Get-FlexProperty $entry 'fix_merged_at'
        if ($null -ne $fixIssueNum -and ($null -eq $fixMerged -or $fixMerged -eq '')) {
            $awaitingMerge++
        }
    }

    # Step B: Group entries with fix_merged_at by pattern_key
    $mergedEntries = @($ProposalsEmitted | Where-Object {
            $fm = Get-FlexProperty $_ 'fix_merged_at'
            $null -ne $fm -and $fm -ne ''
        })

    if ($mergedEntries.Count -eq 0) {
        return @{
            Results            = @($results)
            AwaitingMergeCount = $awaitingMerge
        }
    }

    # Group by pattern_key, sort each group by fix_merged_at ascending
    $grouped = @{}
    foreach ($entry in $mergedEntries) {
        $pk = Get-FlexProperty $entry 'pattern_key'
        if (-not $grouped.ContainsKey($pk)) {
            $grouped[$pk] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$grouped[$pk].Add($entry)
    }
    foreach ($key in @($grouped.Keys)) {
        $grouped[$key] = @($grouped[$key] | Sort-Object { [datetime]::Parse((Get-FlexProperty $_ 'fix_merged_at')) })
    }

    # Step C: Process each fix entry
    foreach ($entry in $mergedEntries) {
        $patternKey = Get-FlexProperty $entry 'pattern_key'
        $parts = $patternKey -split ':', 2
        $fixType = $parts[0]
        $category = $parts[1]
        $fixMergedAt = Get-FlexProperty $entry 'fix_merged_at'
        $fixIssueNumber = Get-FlexProperty $entry 'fix_issue_number'
        $fixMergedAtDate = [datetime]::Parse($fixMergedAt)

        # Partition PrContributions
        $beforeWindow = @($PrContributions | Where-Object {
                [datetime]::Parse($_.mergedAt) -lt $fixMergedAtDate
            })
        $afterWindow = @($PrContributions | Where-Object {
                [datetime]::Parse($_.mergedAt) -ge $fixMergedAtDate
            })

        # Stacked-fix windowing (D-264-6): cap after-window at next fix's fix_merged_at
        $group = $grouped[$patternKey]
        if ($group.Count -gt 1) {
            $thisIndex = -1
            for ($i = 0; $i -lt $group.Count; $i++) {
                if ((Get-FlexProperty $group[$i] 'fix_issue_number') -eq $fixIssueNumber -and
                    (Get-FlexProperty $group[$i] 'fix_merged_at') -eq $fixMergedAt) {
                    $thisIndex = $i
                    break
                }
            }
            if ($thisIndex -ge 0 -and $thisIndex -lt ($group.Count - 1)) {
                $nextFixDate = [datetime]::Parse((Get-FlexProperty $group[$thisIndex + 1] 'fix_merged_at'))
                $afterWindow = @($PrContributions | Where-Object {
                        $d = [datetime]::Parse($_.mergedAt)
                        $d -ge $fixMergedAtDate -and $d -lt $nextFixDate
                    })
            }
        }

        # Count post-fix PRs
        $postFixCount = $afterWindow.Count

        if ($postFixCount -lt $MinPostFixPrs) {
            $resultEntry = @{
                pattern_key      = $patternKey
                category         = $category
                fix_type         = $fixType
                fix_issue_number = $fixIssueNumber
                before_rate      = $null
                after_rate       = $null
                delta            = $null
                indicator        = 'insufficient data'
                post_fix_prs     = $postFixCount
                before_prs       = $beforeWindow.Count
                min_post_fix_prs = $MinPostFixPrs
            }
            [void]$results.Add($resultEntry)
            continue
        }

        # Accumulate per-category data for before/after windows
        $before = Measure-WindowCategoryTotals -Window $beforeWindow -Category $category
        $after = Measure-WindowCategoryTotals -Window $afterWindow  -Category $category

        # Edge case: no before data
        if ($before.wTotal -eq 0) {
            $resultEntry = @{
                pattern_key      = $patternKey
                category         = $category
                fix_type         = $fixType
                fix_issue_number = $fixIssueNumber
                before_rate      = $null
                after_rate       = if ($after.wTotal -gt 0) { [Math]::Round($after.wAccepted / $after.wTotal, 4) } else { 0.0 }
                delta            = $null
                indicator        = 'no before data'
                post_fix_prs     = $postFixCount
                before_prs       = $before.prCount
            }
            [void]$results.Add($resultEntry)
            continue
        }

        # Compute rates and indicator
        $beforeRate = if ($before.wTotal -gt 0) { $before.wAccepted / $before.wTotal } else { 0.0 }
        $afterRate = if ($after.wTotal -gt 0) { $after.wAccepted / $after.wTotal } else { 0.0 }
        $delta = $afterRate - $beforeRate

        if ($after.wTotal -eq 0) {
            # Pattern eliminated — best outcome
            $indicator = 'improved'
        }
        elseif ($delta -lt (-$Deadzone)) {
            $indicator = 'improved'
        }
        elseif ($delta -gt $Deadzone) {
            $indicator = 'worsened'
        }
        else {
            $indicator = 'unchanged'
        }

        $resultEntry = @{
            pattern_key      = $patternKey
            category         = $category
            fix_type         = $fixType
            fix_issue_number = $fixIssueNumber
            before_rate      = [Math]::Round($beforeRate, 4)
            after_rate       = [Math]::Round($afterRate, 4)
            delta            = [Math]::Round($delta, 4)
            indicator        = $indicator
            post_fix_prs     = $postFixCount
            before_prs       = $before.prCount
        }
        [void]$results.Add($resultEntry)
    }

    return @{
        Results            = @($results)
        AwaitingMergeCount = $awaitingMerge
    }
}

# ---------------------------------------------------------------------------
# Private helper: Format-HealthReport
# ---------------------------------------------------------------------------
function Format-HealthReport {
    param(
        [hashtable]$Context
    )
    if ($null -eq $Context -or $Context.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine('# Pipeline Health Report')
    [void]$sb.AppendLine('')
    $metaLine = "Generated: {0}  |  Issues analyzed: {1}  |  Effective sample: {2:F1}" -f `
        $Context.Generated, $Context.IssuesAnalyzed, $Context.EffectiveSampleSize
    [void]$sb.AppendLine($metaLine)
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('## Overall Sustain Rate')
    [void]$sb.AppendLine('')
    $overallIndicator = '→'
    $indicatorDeadzone = 0.05  # D-259-17: threshold for ↑/↓ vs → directional indicator
    if ($Context.ContainsKey('NewerWindowRate') -and $Context.ContainsKey('OlderWindowRate') -and
        $null -ne $Context.NewerWindowRate -and $null -ne $Context.OlderWindowRate) {
        if ($Context.NewerWindowRate -gt ($Context.OlderWindowRate + $indicatorDeadzone)) { $overallIndicator = '↑' }
        elseif ($Context.NewerWindowRate -lt ($Context.OlderWindowRate - $indicatorDeadzone)) { $overallIndicator = '↓' }
    }
    [void]$sb.AppendLine(("Overall: {0}  {1}" -f ('{0:P0}' -f $Context.OverallSustainRate), $overallIndicator))
    [void]$sb.AppendLine('')

    if ($Context.CategoryData.Count -gt 0) {
        [void]$sb.AppendLine('## Category Hotspots')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Category | Effective Count | Sustain Rate | Trend |')
        [void]$sb.AppendLine('|----------|-----------------|--------------|-------|')
        $top3 = $Context.CategoryData.GetEnumerator() |
            Sort-Object { $_.Value['effectiveCount'] } -Descending |
            Select-Object -First 3
        foreach ($entry in $top3) {
            $eCount = $entry.Value['effectiveCount']
            $sRate = if ($eCount -gt 0) { $entry.Value['sustained'] / $eCount } else { 0.0 }
            # Per-category trend deferred (D-264-10 scope boundary) — shows — until OlderCategoryRates is threaded per category. Per-category wTotal/wAccepted data now available in $prContributions.categories (Phase 3 enrichment) — wiring into Hotspots trend is a separate scope decision.
            [void]$sb.AppendLine(("| {0} | {1:F1} | {2} | — |" -f $entry.Key, $eCount, ('{0:P0}' -f $sRate)))
        }
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('## Prosecution Depth')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Category | Effective Count | Sustain Rate | Depth |')
    [void]$sb.AppendLine('|----------|-----------------|--------------|-------|')
    foreach ($cat in $Context.KnownCategories) {
        $depth = if ($Context.ContainsKey('DepthRecommendations') -and $Context.DepthRecommendations.ContainsKey($cat)) {
            $Context.DepthRecommendations[$cat]
        }
        else { 'full' }
        if ($Context.CategoryData.ContainsKey($cat)) {
            $data = $Context.CategoryData[$cat]
            $eCount = $data['effectiveCount']
            $sRate = if ($eCount -gt 0) { $data['sustained'] / $eCount } else { 0.0 }
            [void]$sb.AppendLine(("| {0} | {1:F1} | {2} | {3} |" -f $cat, $eCount, ('{0:P0}' -f $sRate), $depth))
        }
        else {
            [void]$sb.AppendLine(("| {0} | — | — | {1} |" -f $cat, $depth))
        }
    }
    [void]$sb.AppendLine('')

    $d10Rows = @()
    if ($Context.ContainsKey('DepthRecommendations')) {
        foreach ($cat in $Context.KnownCategories) {
            $depth = if ($Context.DepthRecommendations.ContainsKey($cat)) { $Context.DepthRecommendations[$cat] } else { $null }
            if ($depth -eq 'light' -or $depth -eq 'skip') {
                $eCount = if ($Context.CategoryData.ContainsKey($cat)) { $Context.CategoryData[$cat]['effectiveCount'] } else { 0.0 }
                $d10Rows += [pscustomobject]@{ Category = $cat; Depth = $depth; EffectiveCount = $eCount }
            }
        }
    }
    if ($d10Rows.Count -gt 0) {
        [void]$sb.AppendLine('## D10 Alerts')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Category | Depth | Effective Count |')
        [void]$sb.AppendLine('|----------|-------|-----------------|')
        foreach ($row in ($d10Rows | Sort-Object EffectiveCount -Descending)) {
            [void]$sb.AppendLine(("| {0} | {1} | {2:F1} |" -f $row.Category, $row.Depth, $row.EffectiveCount))
        }
        [void]$sb.AppendLine('')
    }

    $alertRows = @()
    foreach ($ft in $Context.KnownSystemicFixTypes) {
        if (-not $Context.SystemicPatterns.ContainsKey($ft)) { continue }
        foreach ($cat in ($Context.SystemicPatterns[$ft].Keys | Sort-Object)) {
            $p = $Context.SystemicPatterns[$ft][$cat]
            if ($p['sustained_count'] -ge 2 -and $p['prs'].Count -ge 2) {
                $alertRows += @{ FixType = $ft; Category = $cat; SustainedCount = $p['sustained_count']; PRs = $p['prs'].Count }
            }
        }
    }
    if ($alertRows.Count -gt 0) {
        [void]$sb.AppendLine('## Systemic Pattern Alerts')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Fix Type | Category | Sustained | PRs |')
        [void]$sb.AppendLine('|----------|----------|-----------|-----|')
        foreach ($row in ($alertRows | Sort-Object { $_.SustainedCount } -Descending)) {
            [void]$sb.AppendLine(("| {0} | {1} | {2} | {3} |" -f $row.FixType, $row.Category, $row.SustainedCount, $row.PRs))
        }
        [void]$sb.AppendLine('')
    }

    # -------------------------------------------------------------------
    # Fix Effectiveness section (Phase 3 — D-264-1, D-264-5)
    # -------------------------------------------------------------------
    if ($Context.ContainsKey('FixEffectiveness') -and $null -ne $Context.FixEffectiveness) {
        $fe = $Context.FixEffectiveness
        $feResults = @($fe.Results)
        $feAwaiting = $fe.AwaitingMergeCount

        if ($feResults.Count -gt 0) {
            [void]$sb.AppendLine('## Fix Effectiveness')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('| Pattern | Fix | Before | After | Δ | PRs |')
            [void]$sb.AppendLine('|---------|-----|--------|-------|---|-----|')
            foreach ($row in $feResults) {
                if ($row.indicator -eq 'insufficient data') {
                    [void]$sb.AppendLine(("| {0} | #{1} | — | — | insufficient data ({2}/{3}) | {2} |" -f $row.pattern_key, $row.fix_issue_number, $row.post_fix_prs, $row.min_post_fix_prs))
                }
                elseif ($row.indicator -eq 'no before data') {
                    $afterPct = '{0:P0}' -f $row.after_rate
                    [void]$sb.AppendLine(("| {0} | #{1} | — | {2} | no before data | {3} |" -f $row.pattern_key, $row.fix_issue_number, $afterPct, $row.post_fix_prs))
                }
                else {
                    $beforePct = '{0:P0}' -f $row.before_rate
                    $afterPct = '{0:P0}' -f $row.after_rate
                    [void]$sb.AppendLine(("| {0} | #{1} | {2} | {3} | {4} | {5} |" -f $row.pattern_key, $row.fix_issue_number, $beforePct, $afterPct, $row.indicator, $row.post_fix_prs))
                }
            }
            [void]$sb.AppendLine('')
            if ($feAwaiting -gt 0) {
                [void]$sb.AppendLine(("Awaiting fix merge ({0} proposals pending)." -f $feAwaiting))
                [void]$sb.AppendLine('')
            }
        }
        elseif ($feAwaiting -gt 0) {
            [void]$sb.AppendLine('## Fix Effectiveness')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine(("Awaiting fix merge ({0} proposals pending)." -f $feAwaiting))
            [void]$sb.AppendLine('')
        }
    }

    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Expose: Invoke-AggregateReviewScores
# ---------------------------------------------------------------------------
function Invoke-AggregateReviewScores {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [double]$DecayLambda = 0.023,
        [int]$Limit = 100,
        [string]$Repo = '',
        [string]$CalibrationFile = '.copilot-tracking/calibration/review-data.json',
        [string]$ComplexityJsonPath = '',
        [string]$GhCliPath = 'gh',
        [switch]$HealthReport
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $out = [System.Text.StringBuilder]::new()

    # ---------------------------------------------------------------------------
    # 1. gh CLI availability check
    # ---------------------------------------------------------------------------
    if (-not (Get-Command $GhCliPath -ErrorAction SilentlyContinue)) {
        [void]$out.AppendLine("error: gh CLI not found. Install from https://cli.github.com/ and authenticate with 'gh auth login'.")
        return @{ ExitCode = 1; Output = $out.ToString(); Error = '' }
    }

    # ---------------------------------------------------------------------------
    # 2. Resolve repository
    # ---------------------------------------------------------------------------
    if ($Repo -eq '') {
        # CWD must be the repository root for auto-detection to work correctly.
        $repoJson = & $GhCliPath repo view --json nameWithOwner
        if ($LASTEXITCODE -ne 0) {
            [void]$out.AppendLine("error: Failed to detect repository (gh exit code $LASTEXITCODE): $repoJson")
            return @{ ExitCode = 1; Output = $out.ToString(); Error = '' }
        }
        try {
            $Repo = ($repoJson | ConvertFrom-Json).nameWithOwner
        }
        catch {
            [void]$out.AppendLine("error: Failed to parse repository response: $_")
            return @{ ExitCode = 1; Output = $out.ToString(); Error = '' }
        }
    }
    $repoArgs = @('--repo', $Repo)

    # ---------------------------------------------------------------------------
    # 3. Fetch merged PRs
    # ---------------------------------------------------------------------------
    $prListJson = & $GhCliPath pr list --state merged --limit $Limit --json 'number,mergedAt,body' @repoArgs
    if ($LASTEXITCODE -ne 0) {
        [void]$out.AppendLine("error: Failed to fetch merged PR list (gh exit code $LASTEXITCODE): $prListJson")
        return @{ ExitCode = 1; Output = $out.ToString(); Error = '' }
    }
    try {
        $mergedPRs = $prListJson | ConvertFrom-Json
    }
    catch {
        [void]$out.AppendLine("error: Failed to parse merged PR list: $_")
        return @{ ExitCode = 1; Output = $out.ToString(); Error = '' }
    }

    # $localEntries: dict of pr_number (int) -> calibration entry (PSObject)
    # $dataSource: 'github' | 'merged' — set based on whether any local entries contributed
    $localEntries = @{}
    $dataSource = 'github'

    # Prosecution depth defaults (overridden when calibration file is loaded)
    $prosecutionDepthOverride = $null
    $timeDecayDays = 90
    $prosecutionDepthState = @{}
    $reActivationEvents = @()
    $proposalsEmitted = @()
    $complexityOverCeilingHistory = @{}
    $consolidationEvents = @()
    $complexityHistoryChanged = $false

    if ($null -eq $mergedPRs -or $mergedPRs.Count -eq 0) {
        [void]$out.AppendLine("data_source: $dataSource")
        [void]$out.AppendLine("insufficient_data: true")
        [void]$out.AppendLine("effective_sample_size: 0")
        [void]$out.AppendLine("issues_analyzed: 0")
        [void]$out.AppendLine("skipped_prs: 0")
        [void]$out.AppendLine('message: "Minimum effective sample size of 5 required (current: 0.00)"')
        return @{ ExitCode = 0; Output = $out.ToString(); Error = ''; HealthReport = "# Pipeline Health Report`n`nNo data: no merged PRs found." }
    }

    # ---------------------------------------------------------------------------
    # 3b. Load local calibration file and build union merge lookup (non-orphan entries only)
    # ---------------------------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($CalibrationFile) -and (Test-Path $CalibrationFile)) {
        try {
            $calibJson = Get-Content -Path $CalibrationFile -Raw | ConvertFrom-Json
            # Build a set of GitHub merged PR numbers for orphan filtering
            $githubPrNumbersSet = [System.Collections.Generic.HashSet[int]]::new()
            foreach ($pr in $mergedPRs) { [void]$githubPrNumbersSet.Add([int]$pr.number) }
            # Keep only non-orphan entries (pr_number appears in the GitHub merged list)
            $totalLocalEntries = 0
            foreach ($entry in $calibJson.entries) {
                $totalLocalEntries++
                $entryPrNum = [int]$entry.pr_number
                if ($githubPrNumbersSet.Contains($entryPrNum)) {
                    $localEntries[$entryPrNum] = $entry
                }
                # else: orphan entry — skip (pr_number not in GitHub merged list)
            }
            if ($localEntries.Count -gt 0) { $dataSource = 'merged' }
            $droppedLocalEntries = $totalLocalEntries - $localEntries.Count
            if ($droppedLocalEntries -gt 0 -and $mergedPRs.Count -eq $Limit) {
                Write-Warning "$droppedLocalEntries calibration entries not found in GitHub fetch results. The fetch limit ($Limit PRs) may have excluded older PRs — increase -Limit for full coverage."
            }
            if ($localEntries.Count -eq 0 -and $totalLocalEntries -gt 0) {
                Write-Warning "All $totalLocalEntries calibration entries were orphaned (no matching PR in GitHub fetch results). Check -CalibrationFile path and -Repo values."
            }
            # Read prosecution-depth overlay fields from calibration
            $prosecutionDepthOverride = Get-FlexProperty $calibJson 'prosecution_depth_override'
            $v = Get-FlexProperty $calibJson 'time_decay_days'
            if ($v) { $timeDecayDays = [int]$v }
            $v = Get-FlexProperty $calibJson 'prosecution_depth_state'
            if ($v) {
                $prosecutionDepthState = $v
                # Ensure hashtable (ConvertFrom-Json without -AsHashtable yields PSCustomObject;
                # .Keys access under Set-StrictMode throws PropertyNotFoundException on PSCustomObject)
                if ($prosecutionDepthState -is [PSCustomObject]) {
                    $h = @{}
                    $prosecutionDepthState.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
                    $prosecutionDepthState = $h
                }
            }
            $v = Get-FlexProperty $calibJson 're_activation_events'
            if ($v) { $reActivationEvents = @($v) }
            $v = Get-FlexProperty $calibJson 'proposals_emitted'
            if ($v) { $proposalsEmitted = @($v) }
            $v = Get-FlexProperty $calibJson 'complexity_over_ceiling_history'
            if ($v) {
                $complexityOverCeilingHistory = $v
                if ($complexityOverCeilingHistory -is [PSCustomObject]) {
                    $complexityOverCeilingHistory = ConvertTo-Hashtable $complexityOverCeilingHistory
                }
            }
            $v = Get-FlexProperty $calibJson 'consolidation_events'
            if ($v) { $consolidationEvents = @($v) }
        }
        catch {
            Write-Warning "CalibrationFile '$CalibrationFile' could not be parsed: $_ — proceeding with GitHub data only."
            $localEntries = @{}
            $dataSource = 'github'
        }
    }

    # Read persistent_threshold from guidance-complexity config (Phase 2 D7)
    $persistentThreshold = 3  # default when config is absent or unreadable
    $complexityConfigPath = Join-Path $script:_ARSCoreLibDir '../assets/guidance-complexity.json'
    if (Test-Path $complexityConfigPath) {
        try {
            $complexityCfg = Get-Content $complexityConfigPath -Raw | ConvertFrom-Json
            if ($null -ne $complexityCfg.persistent_threshold -and [int]$complexityCfg.persistent_threshold -gt 0) {
                $persistentThreshold = [int]$complexityCfg.persistent_threshold
            }
            elseif ($null -ne $complexityCfg.persistent_threshold) {
                Write-Warning "persistent_threshold in guidance-complexity.json must be > 0 (got $($complexityCfg.persistent_threshold)); using default 3"
            }
        }
        catch {
            Write-Warning "Could not read persistent_threshold from guidance-complexity config: $_ — defaulting to $persistentThreshold"
        }
    }

    # ---------------------------------------------------------------------------
    # 4. Per-PR processing
    # ---------------------------------------------------------------------------
    $now = Get-Date
    $requiredFindingFields = @('id', 'category', 'judge_ruling')

    # Accumulators
    $skippedPRs = 0

    # Known category taxonomy (mirrors the emit section — defined here so $accumulateFinding
    # can reference it before the output section runs)
    $knownCategories = @(
        'architecture', 'security', 'performance', 'pattern',
        'implementation-clarity', 'script-automation', 'documentation-audit'
    )
    $systemicActive = $false   # true only inside the local-calibration findings loop

    # Systemic fix pattern accumulators: fix_type -> category -> @{ count; sustained_count; prs; evidence }
    $knownSystemicFixTypes = @('instruction', 'skill', 'agent-prompt', 'plan-template')

    # Context hashtable — holds all accumulator state mutated by $accumulateFinding
    $ctx = @{
        totalFindings          = 0
        weightedTotal          = 0.0
        weightedAccepted       = 0.0
        categoryData           = @{}
        stageData              = @{}
        reviewStageUntagged    = 0
        defenseTotal           = 0.0
        defenseTotalCount      = 0
        defenseSustained       = 0.0
        defenseOverreach       = 0.0
        defenseChallengedTotal = 0.0
        confidenceData         = @{
            high   = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
            medium = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
            low    = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
        }
        systemicPatterns       = @{}
        v2IssuesAnalyzed       = 0
        issuesAnalyzed         = 0
        effectiveSampleSize    = 0.0
    }
    foreach ($ft in $knownSystemicFixTypes) { $ctx.systemicPatterns[$ft] = @{} }

    # ---------------------------------------------------------------------------
    # Shared finding accumulation — dot-sourced at each call site.
    # Expects $finding (hashtable with string values) and $weight (double) in scope.
    # ---------------------------------------------------------------------------
    $accumulateFinding = {
        $ctx.totalFindings++
        $category = $finding['category'].ToLowerInvariant()
        if ($category -eq 'simplicity') {
            $category = 'implementation-clarity'
        }
        if ($category -eq 'documentation') {
            $category = 'documentation-audit'
        }
        $judgeRuling = $finding['judge_ruling'].ToLowerInvariant()
        $judgeConfidence = if ($finding.ContainsKey('judge_confidence')) { $finding['judge_confidence'].ToLowerInvariant() } else { '' }
        $defenseVerdict = if ($finding.ContainsKey('defense_verdict')) { $finding['defense_verdict'].ToLowerInvariant() } else { '' }
        if (-not $finding.ContainsKey('review_stage')) { $ctx.reviewStageUntagged++ }
        $reviewStage = if ($finding.ContainsKey('review_stage')) { $finding['review_stage'].ToLowerInvariant() } else { 'main' }
        $isSustained = ($judgeRuling -eq 'sustained' -or $judgeRuling -eq 'finding-sustained')

        if ($category -ne 'n/a') {
            $ctx.weightedTotal += $weight
            if ($isSustained) { $ctx.weightedAccepted += $weight }
            if (-not $ctx.categoryData.ContainsKey($category)) {
                $ctx.categoryData[$category] = @{ findings = 0; effectiveCount = 0.0; sustained = 0.0 }
            }
            $ctx.categoryData[$category].findings++
            $ctx.categoryData[$category].effectiveCount += $weight
            if ($isSustained) { $ctx.categoryData[$category].sustained += $weight }
        }
        if (-not $ctx.stageData.ContainsKey($reviewStage)) {
            $ctx.stageData[$reviewStage] = @{ findings = 0; sustained = 0; effectiveCount = 0.0; effectiveSustained = 0.0 }
        }
        $ctx.stageData[$reviewStage].findings++
        $ctx.stageData[$reviewStage].effectiveCount += $weight
        if ($isSustained) {
            $ctx.stageData[$reviewStage].sustained++
            $ctx.stageData[$reviewStage].effectiveSustained += $weight
        }
        if ($category -ne 'n/a' -and $defenseVerdict -ne '') {
            $ctx.defenseTotal += $weight
            $ctx.defenseTotalCount++
            if ($judgeRuling -eq 'defense-sustained') { $ctx.defenseSustained += $weight }
            if ($defenseVerdict -eq 'disproved') {
                $ctx.defenseChallengedTotal += $weight
                if ($isSustained) { $ctx.defenseOverreach += $weight }
            }
        }
        if ($category -ne 'n/a' -and $ctx.confidenceData.ContainsKey($judgeConfidence)) {
            $ctx.confidenceData[$judgeConfidence].count++
            $ctx.confidenceData[$judgeConfidence].effectiveCount += $weight
            if ($isSustained) { $ctx.confidenceData[$judgeConfidence].sustained += $weight }
        }
        # Systemic fix pattern accumulation (calibration path only — $systemicActive guards this)
        $systemicFixType = if ($finding.ContainsKey('systemic_fix_type')) { $finding['systemic_fix_type'].ToLowerInvariant() } else { 'none' }
        if ($systemicActive -and $systemicFixType -ne 'none' -and $knownSystemicFixTypes -contains $systemicFixType -and $category -ne 'n/a' -and $knownCategories -contains $category) {
            if (-not $ctx.systemicPatterns.ContainsKey($systemicFixType)) { $ctx.systemicPatterns[$systemicFixType] = @{} }
            if (-not $ctx.systemicPatterns[$systemicFixType].ContainsKey($category)) {
                $ctx.systemicPatterns[$systemicFixType][$category] = @{
                    count           = 0
                    sustained_count = 0
                    prs             = [System.Collections.Generic.HashSet[int]]::new()
                    evidence        = [System.Collections.Generic.List[object]]::new()
                }
            }
            $ctx.systemicPatterns[$systemicFixType][$category].count++
            if ($isSustained) {
                $ctx.systemicPatterns[$systemicFixType][$category].sustained_count++
                [void]$ctx.systemicPatterns[$systemicFixType][$category].prs.Add($prNumber)
                [void]$ctx.systemicPatterns[$systemicFixType][$category].evidence.Add(@{ pr = $prNumber; finding = $finding['id'] })
            }
        }
    }

    # Accumulate per-PR contribution for temporal split (Step 3 directional indicators)
    $prContributions = [System.Collections.Generic.List[object]]::new()
    # Dot-sourced scriptblock: captures this PR's weighted contribution into $prContributions.
    # Shares loop-local variables without parameter overhead; mirrors $accumulateFinding pattern.
    $captureContribution = {
        $prDeltaTotal = $ctx.weightedTotal - $prWtotalBefore
        $prDeltaAccepted = $ctx.weightedAccepted - $prWacceptedBefore
        if ($prDeltaTotal -gt 0) {
            # Per-category deltas (Phase 3 D-264-1)
            $catDeltas = @{}
            foreach ($catKey in @($ctx.categoryData.Keys)) {
                $catNow = $ctx.categoryData[$catKey]
                $catBefore = if ($prCatBefore.ContainsKey($catKey)) { $prCatBefore[$catKey] } else { @{ effectiveCount = 0.0; sustained = 0.0 } }
                $dTotal = $catNow.effectiveCount - $catBefore.effectiveCount
                $dAccepted = $catNow.sustained - $catBefore.sustained
                if ($dTotal -gt 0) {
                    $catDeltas[$catKey] = @{ wTotal = $dTotal; wAccepted = $dAccepted }
                }
            }
            [void]$prContributions.Add([pscustomobject]@{
                    mergedAt   = $mergedAt
                    wTotal     = $prDeltaTotal
                    wAccepted  = $prDeltaAccepted
                    categories = $catDeltas
                })
        }
    }

    foreach ($pr in $mergedPRs) {
        $prNumber = [int]$pr.number
        $mergedAt = $pr.mergedAt

        # Compute decay weight
        try {
            $mergedDate = [datetime]::Parse($mergedAt)
            $daysSince = ($now - $mergedDate).TotalDays
            if ($daysSince -lt 0) { $daysSince = 0 }
            $weight = [Math]::Exp(-$DecayLambda * $daysSince)
        }
        catch {
            Write-Warning "PR #${prNumber}: failed to parse mergedAt '${mergedAt}', skipping."
            $skippedPRs++
            continue
        }

        # Snapshot for temporal split (computed after $weight is known)
        $prWtotalBefore = $ctx.weightedTotal
        $prWacceptedBefore = $ctx.weightedAccepted

        # Snapshot per-category data for per-category enrichment (Phase 3 D-264-1)
        # Deep-copy scalar values — inner hashtables are mutable references (MF-1).
        $prCatBefore = @{}
        foreach ($catKey in @($ctx.categoryData.Keys)) {
            $catData = $ctx.categoryData[$catKey]
            $prCatBefore[$catKey] = @{ effectiveCount = $catData.effectiveCount; sustained = $catData.sustained }
        }

        $body = if ($pr.body) { $pr.body } else { '' }

        # Extract <!-- pipeline-metrics ... --> block
        $metricsMatch = [regex]::Match($body, '(?s)<!--\s*pipeline-metrics\s*(.*?)-->')

        if (-not $metricsMatch.Success) {
            # Union merge: fall back to local calibration entry if GitHub PR body has no metrics block
            if ($localEntries.ContainsKey($prNumber)) {
                $localEntry = $localEntries[$prNumber]
                $ctx.issuesAnalyzed++
                $ctx.effectiveSampleSize += $weight
                $ctx.v2IssuesAnalyzed++
                # Process local entry's findings array using GitHub's mergedAt-derived weight
                $systemicActive = $true
                foreach ($lf in $localEntry.findings) {
                    $finding = @{}
                    foreach ($prop in $lf.PSObject.Properties) { $finding[$prop.Name] = [string]$prop.Value }
                    # Express-lane findings (pre-v2.1) may legitimately omit judge_ruling — default it
                    if ($finding.ContainsKey('express_lane') -and $finding['express_lane'] -eq 'true' -and
                        (-not $finding.ContainsKey('judge_ruling') -or [string]::IsNullOrWhiteSpace($finding['judge_ruling']))) {
                        $finding['judge_ruling'] = 'finding-sustained'
                    }
                    $missingField = $false
                    foreach ($field in $requiredFindingFields) {
                        if (-not $finding.ContainsKey($field) -or [string]::IsNullOrWhiteSpace($finding[$field])) {
                            $missingField = $true; break
                        }
                    }
                    if ($missingField) { Write-Warning "Warning: local finding entry missing required fields, skipped."; continue }
                    . $accumulateFinding
                }
                $systemicActive = $false
            }
            # Capture per-PR contribution for temporal split
            . $captureContribution
            continue
        }

        $block = $metricsMatch.Groups[1].Value

        $ctx.issuesAnalyzed++
        $ctx.effectiveSampleSize += $weight

        # Detect format version
        $versionVal = Get-YamlField -Block $block -FieldName 'metrics_version'
        $isV2 = ($null -ne $versionVal -and $versionVal -ne '')

        if (-not $isV2) {
            # v1: flat fields only — contribute to effectiveSampleSize but no per-finding data
            continue
        }

        $ctx.v2IssuesAnalyzed++

        # v2: parse per-finding array
        $findings = Get-FindingsArray -Block $block

        # $systemicActive remains $false for v2 PR-body findings (D49 design decision):
        # systemic pattern accumulation is calibration-only. Local entries run with
        # $systemicActive = $true; v2 PR-body and local-calibration paths union-merge,
        # so restricting accumulation to local entries does not create a data gap.
        foreach ($finding in $findings) {
            # Express-lane findings (pre-v2.1) may legitimately omit judge_ruling — default it
            if ($finding.ContainsKey('express_lane') -and $finding['express_lane'] -eq 'true' -and
                (-not $finding.ContainsKey('judge_ruling') -or [string]::IsNullOrWhiteSpace($finding['judge_ruling']))) {
                $finding['judge_ruling'] = 'finding-sustained'
            }
            # Validate required fields
            $missingField = $false
            foreach ($field in $requiredFindingFields) {
                if (-not $finding.ContainsKey($field) -or [string]::IsNullOrWhiteSpace($finding[$field])) {
                    $missingField = $true
                    break
                }
            }
            if ($missingField) {
                Write-Warning "Warning: finding entry missing required fields, skipped."
                continue
            }
            . $accumulateFinding
        }
        # Capture per-PR contribution for temporal split
        . $captureContribution
    }

    # ---------------------------------------------------------------------------
    # Temporal split for directional indicators (D-259-17)
    # Sort processed PRs by mergedAt ascending, split at median.
    # < 4 PRs with contribution data → all indicators stay → (insufficient split).
    # ---------------------------------------------------------------------------
    $olderWindowRate = $null
    $newerWindowRate = $null
    if ($prContributions.Count -ge 4) {
        $sortedContribs = @($prContributions | Sort-Object { [datetime]::Parse($_.mergedAt) })
        $splitIdx = [Math]::Floor($sortedContribs.Count / 2)
        $olderHalf = @($sortedContribs[0..($splitIdx - 1)])
        $newerHalf = @($sortedContribs[$splitIdx..($sortedContribs.Count - 1)])
        $olderWt = 0.0; $olderWa = 0.0; $newerWt = 0.0; $newerWa = 0.0
        foreach ($c in $olderHalf) { $olderWt += $c.wTotal; $olderWa += $c.wAccepted }
        foreach ($c in $newerHalf) { $newerWt += $c.wTotal; $newerWa += $c.wAccepted }
        $olderWindowRate = if ($olderWt -gt 0) { $olderWa / $olderWt } else { 0.0 }
        $newerWindowRate = if ($newerWt -gt 0) { $newerWa / $newerWt } else { 0.0 }
    }

    # Compute max merged PR number (used for re-activation event expiry checks)
    $maxMergedPrNumber = 0
    foreach ($pr in $mergedPRs) {
        $prNum = [int]$pr.number
        if ($prNum -gt $maxMergedPrNumber) { $maxMergedPrNumber = $prNum }
    }

    # ---------------------------------------------------------------------------
    # Merge-date discovery loop (Phase 3 — Fix Effectiveness, D-264-6)
    # For proposals_emitted entries with fix_issue_number but no fix_merged_at,
    # query gh CLI to discover when the fix PR was merged.
    # Skipped in HealthReport mode (read-only, D-264-11).
    # ---------------------------------------------------------------------------
    $fixMergedAtChanged = $false
    if (-not $HealthReport.IsPresent -and $proposalsEmitted.Count -gt 0) {
        foreach ($entry in $proposalsEmitted) {
            $fixIssueNum = Get-FlexProperty $entry 'fix_issue_number'
            $fixMergedAt = Get-FlexProperty $entry 'fix_merged_at'
            if ($null -eq $fixIssueNum -or $null -ne $fixMergedAt) { continue }

            # Build search query with closes/fixes/resolves variants
            $searchQuery = "closes #$fixIssueNum OR fixes #$fixIssueNum OR resolves #$fixIssueNum"
            try {
                $ghOutput = & $GhCliPath pr list --repo $Repo --state merged --search $searchQuery --json 'number,mergedAt' --sort updated --limit 5 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "gh pr list failed for fix issue #$fixIssueNum (exit code $LASTEXITCODE): $ghOutput"
                    continue
                }
                $prResults = $ghOutput | ConvertFrom-Json -ErrorAction Stop
                if ($prResults -and $prResults.Count -gt 0) {
                    # Pick entry with latest mergedAt
                    $latest = $prResults | Sort-Object { [datetime]::Parse($_.mergedAt) } | Select-Object -Last 1
                    $latestMergedAt = $latest.mergedAt
                    # Normalize DateTime to UTC ISO 8601 string for stable JSON round-trip
                    if ($latestMergedAt -is [datetime]) {
                        $latestMergedAt = $latestMergedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    }
                    # Type-aware mutation (PSCustomObject vs hashtable)
                    if ($entry -is [System.Collections.IDictionary]) {
                        $entry['fix_merged_at'] = $latestMergedAt
                    }
                    else {
                        $entry | Add-Member -NotePropertyName 'fix_merged_at' -NotePropertyValue $latestMergedAt -Force
                    }
                    $fixMergedAtChanged = $true
                }
            }
            catch {
                Write-Warning "Fix merge-date discovery failed for fix_issue_number=$fixIssueNum — $_"
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Process complexity over-ceiling history (Phase 2 D7)
    # Runs only when -ComplexityJsonPath is provided and the file exists.
    # ---------------------------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($ComplexityJsonPath) -and (Test-Path $ComplexityJsonPath)) {
        try {
            $complexityJson = Get-Content $ComplexityJsonPath -Raw | ConvertFrom-Json
            $agentsOverCeiling = @()
            if ($null -ne $complexityJson.agents_over_ceiling) {
                $agentsOverCeiling = @($complexityJson.agents_over_ceiling)
            }
            $agentsOverCeilingSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($a in $agentsOverCeiling) { [void]$agentsOverCeilingSet.Add($a) }

            # Increment consecutive_count for agents currently over ceiling
            foreach ($agentFile in $agentsOverCeiling) {
                if ($complexityOverCeilingHistory.ContainsKey($agentFile)) {
                    $entry = $complexityOverCeilingHistory[$agentFile]
                    # Coerce PSCustomObject to hashtable for mutation
                    if ($entry -is [PSCustomObject]) {
                        $entry = ConvertTo-Hashtable $entry
                        $complexityOverCeilingHistory[$agentFile] = $entry
                    }
                    # Idempotency: skip increment if already processed for this max PR number
                    $entryLastPr = if ($entry.ContainsKey('last_pr_number')) { [int]$entry['last_pr_number'] } else { 0 }
                    if ($entryLastPr -eq $maxMergedPrNumber) { continue }
                    $entry['consecutive_count'] = [int]$entry['consecutive_count'] + 1
                    $entry['last_observed_at'] = $now.ToString('o')
                    $entry['last_pr_number'] = $maxMergedPrNumber
                    $complexityHistoryChanged = $true
                }
                else {
                    # First observation
                    $complexityOverCeilingHistory[$agentFile] = @{
                        consecutive_count = 1
                        first_observed_at = $now.ToString('o')
                        last_observed_at  = $now.ToString('o')
                        last_pr_number    = $maxMergedPrNumber
                    }
                    $complexityHistoryChanged = $true
                }
            }

            # Log consolidation events for agents that dropped below ceiling
            $agentsToRemove = @($complexityOverCeilingHistory.Keys | Where-Object { -not $agentsOverCeilingSet.Contains($_) })
            foreach ($agentFile in $agentsToRemove) {
                $entry = $complexityOverCeilingHistory[$agentFile]
                $prevCount = [int](Get-FlexProperty $entry 'consecutive_count')
                $consolidationEvents += @{
                    agent                = $agentFile
                    consolidated_at      = $now.ToString('o')
                    at_pr_number         = $maxMergedPrNumber
                    previous_consecutive = $prevCount
                }
                $complexityOverCeilingHistory.Remove($agentFile)
                $complexityHistoryChanged = $true
            }
        }
        catch {
            Write-Warning "Could not process complexity JSON '$ComplexityJsonPath': $_ — skipping complexity history update"
        }
    }

    # ---------------------------------------------------------------------------
    # 5. Apply tiered thresholds and emit output
    # ---------------------------------------------------------------------------
    $overallSufficient = $ctx.effectiveSampleSize -ge 5.0

    if (-not $overallSufficient) {
        $essFmt = '{0:F2}' -f $ctx.effectiveSampleSize
        [void]$out.AppendLine("data_source: $dataSource")
        [void]$out.AppendLine("insufficient_data: true")
        [void]$out.AppendLine("effective_sample_size: $essFmt")
        [void]$out.AppendLine("issues_analyzed: $($ctx.issuesAnalyzed)")
        [void]$out.AppendLine("skipped_prs: $skippedPRs")
        [void]$out.AppendLine("message: `"Minimum effective sample size of 5 required (current: ${essFmt})`"")
        # Flush complexity history write-back before insufficient-data exit
        if (-not $HealthReport.IsPresent -and $complexityHistoryChanged -and (Test-Path $CalibrationFile -PathType Leaf)) {
            $earlyTmp = $null
            try {
                $earlyCalib = Get-Content -Raw $CalibrationFile | ConvertFrom-Json
                $earlyCalib | Add-Member -Force -NotePropertyName 'complexity_over_ceiling_history' -NotePropertyValue $(if ($complexityOverCeilingHistory.Count -gt 0) { [PSCustomObject]($complexityOverCeilingHistory) } else { $null })
                $earlyCalib | Add-Member -Force -NotePropertyName 'consolidation_events' -NotePropertyValue $consolidationEvents
                $earlyTmp = "$CalibrationFile.$([System.Guid]::NewGuid().ToString('N')).tmp"
                $earlyCalib | ConvertTo-Json -Depth 10 | Set-Content -Path $earlyTmp -Encoding UTF8
                # Validate before promotion (mirrors write-calibration-entry.ps1 safety pattern)
                $null = Get-Content $earlyTmp -Raw | ConvertFrom-Json
                Move-Item -Path $earlyTmp -Destination $CalibrationFile -Force
            }
            catch {
                if ($null -ne $earlyTmp -and (Test-Path $earlyTmp)) { Remove-Item $earlyTmp -Force -ErrorAction SilentlyContinue }
                Write-Warning "Could not flush complexity history before early exit: $_"
            }
        }
        elseif (-not $HealthReport.IsPresent -and $complexityHistoryChanged -and -not (Test-Path $CalibrationFile -PathType Leaf)) {
            Write-Warning "complexity-tracking: calibration file not found at '$CalibrationFile' — consecutive_count cannot persist across runs. Complexity history will not advance toward extraction threshold until the calibration file exists."
        }
        # Emit extraction_agents in insufficient-data path if threshold met
        Write-ExtractionAgentsYaml -ComplexityOverCeilingHistory $complexityOverCeilingHistory -PersistentThreshold $persistentThreshold -Builder $out
        return @{ ExitCode = 0; Output = $out.ToString(); Error = ''; HealthReport = "# Pipeline Health Report`n`nInsufficient data: ${essFmt} effective issues (minimum 5.0 required)." }
    }

    # Compute rates
    $overallSustainRate = if ($ctx.weightedTotal -gt 0) { $ctx.weightedAccepted / $ctx.weightedTotal } else { 0.0 }

    $defenseSuccessRate = if ($ctx.defenseTotal -gt 0) { $ctx.defenseSustained / $ctx.defenseTotal } else { 0.0 }
    $defenseChallengeRate = if ($ctx.defenseTotal -gt 0) { $ctx.defenseChallengedTotal / $ctx.defenseTotal } else { 0.0 }
    $overreachRate = if ($ctx.defenseChallengedTotal -gt 0) { $ctx.defenseOverreach / $ctx.defenseChallengedTotal } else { 0.0 }

    $biasDirection = if ($overallSustainRate -gt 0.6) {
        'slightly_prosecution'
    }
    elseif ($overallSustainRate -lt 0.4) {
        'slightly_defense'
    }
    else {
        'balanced'
    }

    # Known category taxonomy (always emit, even if no data)
    $knownCategories = @(
        'architecture', 'security', 'performance', 'pattern',
        'implementation-clarity', 'script-automation', 'documentation-audit'
    )

    # ---------------------------------------------------------------------------
    # 6. Emit YAML calibration profile
    # ---------------------------------------------------------------------------
    $generated = $now.ToString('yyyy-MM-dd')

    [void]$out.AppendLine("data_source: $dataSource")
    [void]$out.AppendLine("calibration:")
    [void]$out.AppendLine("  generated: $generated")
    [void]$out.AppendLine("  issues_analyzed: $($ctx.issuesAnalyzed)")
    [void]$out.AppendLine("  v2_issues_analyzed: $($ctx.v2IssuesAnalyzed)")
    [void]$out.AppendLine("  skipped_prs: $skippedPRs")
    [void]$out.AppendLine("  total_findings: $($ctx.totalFindings)")
    [void]$out.AppendLine(("  effective_sample_size: {0:F1}" -f $ctx.effectiveSampleSize))
    [void]$out.AppendLine("  decay_lambda: $DecayLambda")
    [void]$out.AppendLine("  prosecutor:")
    [void]$out.AppendLine(("    overall_sustain_rate: {0:F2}" -f $overallSustainRate))
    [void]$out.AppendLine("    sufficient_data: $($overallSufficient.ToString().ToLower())")
    if ($ctx.v2IssuesAnalyzed -gt 0) {
        [void]$out.AppendLine("    by_category:")

        foreach ($cat in $knownCategories) {
            [void]$out.AppendLine("      ${cat}:")
            if ($ctx.categoryData.ContainsKey($cat)) {
                $cd = $ctx.categoryData[$cat]
                $catSustainRate = if ($cd.effectiveCount -gt 0) { $cd.sustained / $cd.effectiveCount } else { 0.0 }
                $catSufficient = $cd.effectiveCount -ge 15.0
                [void]$out.AppendLine("        findings: $($cd.findings)")
                [void]$out.AppendLine(("        effective_count: {0:F1}" -f $cd.effectiveCount))
                [void]$out.AppendLine(("        sustain_rate: {0:F2}" -f $catSustainRate))
                [void]$out.AppendLine("        sufficient_data: $($catSufficient.ToString().ToLower())")
            }
            else {
                [void]$out.AppendLine("        findings: 0")
                [void]$out.AppendLine("        effective_count: 0.0")
                [void]$out.AppendLine("        sustain_rate: 0.00")
                [void]$out.AppendLine("        sufficient_data: false")
            }
        }

        [void]$out.AppendLine("  defense:")
        [void]$out.AppendLine("    defense_findings_count: $($ctx.defenseTotalCount)")
        [void]$out.AppendLine(("    defense_effective_count: {0:F1}" -f $ctx.defenseTotal))
        $defenseSufficientData = $ctx.defenseTotal -ge 5.0
        [void]$out.AppendLine("    defense_sufficient_data: $($defenseSufficientData.ToString().ToLower())")
        [void]$out.AppendLine(("    defense_success_rate: {0:F2}" -f $defenseSuccessRate))
        [void]$out.AppendLine(("    defense_challenge_rate: {0:F2}" -f $defenseChallengeRate))
        [void]$out.AppendLine(("    overreach_rate: {0:F2}" -f $overreachRate))
        [void]$out.AppendLine("  judge:")
        [void]$out.AppendLine("    confidence_calibration:")

        foreach ($level in @('high', 'medium', 'low')) {
            $cd = $ctx.confidenceData[$level]
            # sustain_rate: renamed from 'accuracy' which was misleading
            $sustainRate = if ($cd.effectiveCount -gt 0) { $cd.sustained / $cd.effectiveCount } else { 0.0 }
            $levelSufficient = $cd.effectiveCount -ge 5
            [void]$out.AppendLine("      ${level}:")
            [void]$out.AppendLine("        sufficient_data: $($levelSufficient.ToString().ToLower())")
            [void]$out.AppendLine(("        sustain_rate: {0:F2}" -f $sustainRate))
            [void]$out.AppendLine("        count: $($cd.count)")
            [void]$out.AppendLine(("        effective_count: {0:F1}" -f $cd.effectiveCount))
        }

        [void]$out.AppendLine("    bias_direction: $biasDirection")
        [void]$out.AppendLine("  by_review_stage:")
        [void]$out.AppendLine("    review_stage_untagged: $($ctx.reviewStageUntagged)")
        $knownStages = @('main', 'postfix', 'ce')
        foreach ($stage in $knownStages) {
            [void]$out.AppendLine("    ${stage}:")
            if ($ctx.stageData.ContainsKey($stage)) {
                $sd = $ctx.stageData[$stage]
                $stageSustainRate = if ($sd.effectiveCount -gt 0) { $sd.effectiveSustained / $sd.effectiveCount } else { 0.0 }
                [void]$out.AppendLine("      findings: $($sd.findings)")
                [void]$out.AppendLine("      sustained: $($sd.sustained)")
                [void]$out.AppendLine(("      effective_count: {0:F1}" -f $sd.effectiveCount))
                [void]$out.AppendLine(("      sustain_rate: {0:F2}" -f $stageSustainRate))
            }
            else {
                [void]$out.AppendLine("      findings: 0")
                [void]$out.AppendLine("      sustained: 0")
                [void]$out.AppendLine("      effective_count: 0.0")
                [void]$out.AppendLine("      sustain_rate: 0.00")
            }
        }
        foreach ($stage in ($ctx.stageData.Keys | Where-Object { $knownStages -notcontains $_ } | Sort-Object)) {
            [void]$out.AppendLine("    ${stage}:")
            $sd = $ctx.stageData[$stage]
            $stageSustainRate = if ($sd.effectiveCount -gt 0) { $sd.effectiveSustained / $sd.effectiveCount } else { 0.0 }
            [void]$out.AppendLine("      findings: $($sd.findings)")
            [void]$out.AppendLine("      sustained: $($sd.sustained)")
            [void]$out.AppendLine(("      effective_count: {0:F1}" -f $sd.effectiveCount))
            [void]$out.AppendLine(("      sustain_rate: {0:F2}" -f $stageSustainRate))
        }

        # -------------------------------------------------------------------
        # prosecution_depth: per-category depth recommendation (7-step chain)
        # -------------------------------------------------------------------

        $overrideActive = ($prosecutionDepthOverride -ieq 'full')
        $depthStateChanged = $false
        $proposalsChanged = $false
        $categoriesWithSufficientData = 0
        $categoriesAtSkip = 0
        $categoriesAtLight = 0
        $depthRecommendations = @{}

        [void]$out.AppendLine("  prosecution_depth:")
        [void]$out.AppendLine("    override_active: $($overrideActive.ToString().ToLower())")

        foreach ($cat in $knownCategories) {
            # Read per-category depth state once (used by time-decay and state tracking)
            $catState = Get-FlexProperty $prosecutionDepthState $cat

            # Gather per-category stats
            $catEffective = 0.0
            $catSustainRate = 0.0
            if ($ctx.categoryData.ContainsKey($cat)) {
                $cd = $ctx.categoryData[$cat]
                $catEffective = $cd.effectiveCount
                $catSustainRate = if ($cd.effectiveCount -gt 0) { $cd.sustained / $cd.effectiveCount } else { 0.0 }
            }

            $recommendation = 'full'
            $reActivated = $false
            # >=20 threshold for depth recommendation (higher bar than by_category >=15 — depth changes have
            # direct behavioral consequences; statistical confidence for depth decisions requires more data)
            $sufficientData = $catEffective -ge 20.0

            # 7-step priority chain (evaluated top-down, first match wins)
            if ($overrideActive) {
                # Step 1: Global override forces full
                $recommendation = 'full'
            }
            elseif ($reActivationEvents.Count -gt 0) {
                $activeEvent = $reActivationEvents | Where-Object {
                    $_.category -eq $cat -and [int]$_.expires_at_pr -gt $maxMergedPrNumber
                }
                if ($activeEvent) {
                    # Step 2: Active re-activation event
                    $recommendation = 'full'
                    $reActivated = $true
                }
                else {
                    # Fall through to remaining steps
                    $recommendation = $null
                }
            }
            else {
                $recommendation = $null
            }

            if ($null -eq $recommendation) {
                # Step 3: Time-decay check
                $skipObservedAt = Get-FlexProperty $catState 'skip_first_observed_at'

                if ($null -ne $skipObservedAt -and $skipObservedAt -ne '') {
                    try {
                        $observedDate = [datetime]::Parse($skipObservedAt)
                        $daysSinceObserved = ($now - $observedDate).TotalDays
                        if ($daysSinceObserved -gt $timeDecayDays) {
                            # Step 3: Time-decay — re-activate from skip to light
                            $recommendation = 'light'
                            $reActivated = $true
                            # Write synthetic re-activation event
                            $reActivationEvents += @{
                                category        = $cat
                                triggered_at_pr = $maxMergedPrNumber
                                expires_at_pr   = $maxMergedPrNumber + 50
                                trigger_source  = 'time_decay'
                                created_at      = $now.ToString('o')
                            }
                            $depthStateChanged = $true
                        }
                    }
                    catch {
                        Write-Verbose "Skipping unparseable expiry date — non-fatal, continuing"
                    }
                }

                if ($null -eq $recommendation) {
                    if ($catEffective -lt 20.0) {
                        # Step 4: Insufficient data
                        $recommendation = 'full'
                        $sufficientData = $false
                    }
                    elseif ($catSustainRate -lt 0.05 -and $catEffective -ge 30.0) {
                        # Step 5: Skip threshold
                        $recommendation = 'skip'
                    }
                    elseif ($catSustainRate -lt 0.15 -and $catEffective -ge 20.0) {
                        # Step 6: Light threshold
                        $recommendation = 'light'
                    }
                    else {
                        # Step 7: Full (default)
                        $recommendation = 'full'
                    }
                }
            }

            # prosecution_depth_state tracking: record/clear skip_first_observed_at
            if ($recommendation -eq 'skip') {
                # Entering skip: record skip_first_observed_at if not already set
                $existingObserved = Get-FlexProperty $catState 'skip_first_observed_at'
                if ($null -eq $existingObserved -or $existingObserved -eq '') {
                    if ($prosecutionDepthState -isnot [hashtable]) {
                        $newState = @{}
                        $prosecutionDepthState.PSObject.Properties | ForEach-Object { $newState[$_.Name] = $_.Value }
                        $prosecutionDepthState = $newState
                    }
                    $prosecutionDepthState[$cat] = @{ skip_first_observed_at = $now.ToString('o') }
                    $depthStateChanged = $true
                }
            }
            else {
                # Clear skip_first_observed_at when leaving skip (including when re-activation forces full).
                # This intentionally resets the 90-day time-decay clock: the re-activation window
                # (5 PRs) is expected to produce fresh calibration data before the category returns
                # to skip, at which point the time-decay observation period restarts.
                if ($null -ne $catState) {
                    if ($prosecutionDepthState -is [hashtable]) {
                        $prosecutionDepthState.Remove($cat)
                    }
                    $depthStateChanged = $true
                }
            }

            if ($sufficientData) { $categoriesWithSufficientData++ }
            if ($recommendation -eq 'skip') { $categoriesAtSkip++ }
            elseif ($recommendation -eq 'light') { $categoriesAtLight++ }
            $depthRecommendations[$cat] = $recommendation

            [void]$out.AppendLine("    ${cat}:")
            [void]$out.AppendLine("      recommendation: $recommendation")
            [void]$out.AppendLine(("      sustain_rate: {0:F2}" -f $catSustainRate))
            [void]$out.AppendLine(("      effective_count: {0:F1}" -f $catEffective))
            [void]$out.AppendLine("      sufficient_data: $($sufficientData.ToString().ToLower())")
            [void]$out.AppendLine("      re_activated: $($reActivated.ToString().ToLower())")
        }

        # Accumulate newly threshold-met unproposed patterns into proposals_emitted.
        # Must run after systemic pattern accumulation and before the write-back block
        # so $proposalsChanged correctly gates the atomic calibration file update.
        # Snapshot prior proposals first: $priorProposalsEmitted drives the previously_proposed
        # output field (only patterns proposed in a PRIOR run count as previously_proposed: true).
        $priorProposalsEmitted = @($proposalsEmitted)
        foreach ($ft in $knownSystemicFixTypes) {
            foreach ($cat in $ctx.systemicPatterns[$ft].Keys) {
                $spEntry = $ctx.systemicPatterns[$ft][$cat]
                $sustainedCnt = $spEntry.sustained_count
                $distinctPrs = $spEntry.prs.Count
                if ($sustainedCnt -ge 2 -and $distinctPrs -ge 2) {
                    $patternKey = "${ft}:${cat}"
                    $evidencePrs = @($spEntry.prs | Sort-Object)
                    $alreadyProposed = Test-PatternProposed -Proposals $proposalsEmitted -PatternKey $patternKey -EvidencePrs $evidencePrs
                    if (-not $alreadyProposed) {
                        $proposalsEmitted += @{
                            pattern_key      = $patternKey
                            evidence_prs     = $evidencePrs
                            first_emitted_at = $now.ToString('o')
                        }
                        $proposalsChanged = $true
                    }
                }
            }
        }

        # Write updated prosecution_depth_state + re_activation_events + proposals_emitted
        if (-not $HealthReport.IsPresent -and ($depthStateChanged -or $proposalsChanged -or $fixMergedAtChanged -or $complexityHistoryChanged) -and
            -not [string]::IsNullOrWhiteSpace($CalibrationFile) -and
            (Test-Path $CalibrationFile)) {
            $tempPath = $null
            try {
                $calibContent = Get-Content -Path $CalibrationFile -Raw | ConvertFrom-Json
                # Convert prosecutionDepthState hashtable to PSCustomObject for JSON
                $stateObj = [ordered]@{}
                foreach ($k in $prosecutionDepthState.Keys) {
                    $stateObj[$k] = $prosecutionDepthState[$k]
                }
                $calibContent | Add-Member -NotePropertyName 'prosecution_depth_state' -NotePropertyValue ([PSCustomObject]$stateObj) -Force
                # Prune expired events before persisting (events still active: expires_at_pr > $maxMergedPrNumber)
                $reActivationEvents = @($reActivationEvents | Where-Object {
                        $exp = Get-FlexProperty $_ 'expires_at_pr'
                        $null -ne $exp -and [int]$exp -gt $maxMergedPrNumber
                    })
                $calibContent | Add-Member -NotePropertyName 're_activation_events' -NotePropertyValue @($reActivationEvents) -Force
                if ($proposalsChanged -or $fixMergedAtChanged) {
                    $calibContent | Add-Member -NotePropertyName 'proposals_emitted' -NotePropertyValue @($proposalsEmitted) -Force
                }
                if ($complexityHistoryChanged) {
                    if ($complexityOverCeilingHistory.Count -eq 0) {
                        # All agents dropped below ceiling — write null so the key reads back as $null
                        $calibContent | Add-Member -NotePropertyName 'complexity_over_ceiling_history' -NotePropertyValue $null -Force
                    }
                    else {
                        $histObj = [ordered]@{}
                        foreach ($k in ($complexityOverCeilingHistory.Keys | Sort-Object)) {
                            $entryVal = $complexityOverCeilingHistory[$k]
                            if ($entryVal -is [PSCustomObject]) {
                                $entryVal = ConvertTo-Hashtable $entryVal
                            }
                            $histObj[$k] = [PSCustomObject]$entryVal
                        }
                        $calibContent | Add-Member -NotePropertyName 'complexity_over_ceiling_history' -NotePropertyValue ([PSCustomObject]$histObj) -Force
                    }
                    $calibContent | Add-Member -NotePropertyName 'consolidation_events' -NotePropertyValue @($consolidationEvents) -Force
                }

                $tempPath = "$CalibrationFile.$([System.Guid]::NewGuid().ToString('N')).tmp"
                $calibContent | ConvertTo-Json -Depth 10 | Set-Content -Path $tempPath -Encoding UTF8
                # Validate before promotion (mirrors write-calibration-entry.ps1 safety pattern)
                $null = Get-Content $tempPath -Raw | ConvertFrom-Json
                Move-Item -Path $tempPath -Destination $CalibrationFile -Force
            }
            catch {
                if ($null -ne $tempPath -and (Test-Path $tempPath)) {
                    Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
                }
                Write-Warning "Failed to write calibration state to calibration file: $_"
                # Non-fatal — state write failure does not affect YAML output
            }
        }
        if (-not $HealthReport.IsPresent -and $complexityHistoryChanged -and -not (Test-Path $CalibrationFile -PathType Leaf)) {
            Write-Warning "complexity-tracking: calibration file not found at '$CalibrationFile' — consecutive_count cannot persist across runs. Complexity history will not advance toward extraction threshold until the calibration file exists."
        }

        # systemic_patterns: aggregated fix-type x category patterns from sustained findings
        $patternsMeetingThreshold = 0
        $patternsPreviouslyProposed = 0
        $fixTypesWithData = $knownSystemicFixTypes | Where-Object { $ctx.systemicPatterns[$_].Count -gt 0 }
        if ($fixTypesWithData) {
            [void]$out.AppendLine("  systemic_patterns:")
            foreach ($ft in $knownSystemicFixTypes) {
                if ($ctx.systemicPatterns[$ft].Count -eq 0) {
                    [void]$out.AppendLine("    ${ft}: {}")
                }
                else {
                    [void]$out.AppendLine("    ${ft}:")
                    foreach ($cat in ($ctx.systemicPatterns[$ft].Keys | Sort-Object)) {
                        $entry = $ctx.systemicPatterns[$ft][$cat]
                        $sustainedCnt = $entry.sustained_count
                        $distinctPrs = $entry.prs.Count
                        $meetsThreshold = ($sustainedCnt -ge 2 -and $distinctPrs -ge 2)
                        $patternKey = "${ft}:${cat}"
                        $evidencePrs = @($entry.prs | Sort-Object)
                        $prevProposed = Test-PatternProposed -Proposals $priorProposalsEmitted -PatternKey $patternKey -EvidencePrs $evidencePrs
                        [void]$out.AppendLine("      ${cat}:")
                        [void]$out.AppendLine("        count: $($entry.count)")
                        [void]$out.AppendLine("        sustained_count: ${sustainedCnt}")
                        [void]$out.AppendLine("        distinct_prs: ${distinctPrs}")
                        [void]$out.AppendLine("        meets_threshold: $($meetsThreshold.ToString().ToLower())")
                        if ($entry.evidence.Count -gt 0) {
                            [void]$out.AppendLine("        evidence:")
                            foreach ($ev in $entry.evidence) {
                                [void]$out.AppendLine("          - pr: $($ev.pr), finding: $($ev.finding)")
                            }
                        }
                        if ($meetsThreshold) { $patternsMeetingThreshold++ }
                        if ($prevProposed -and $meetsThreshold) { $patternsPreviouslyProposed++ }
                        [void]$out.AppendLine("        previously_proposed: $($prevProposed.ToString().ToLower())")
                    }
                }
            }
        }
        # kaizen_metric: aggregated calibration effectiveness metric
        $kaizenRate = if ($categoriesWithSufficientData -gt 0) {
            ($categoriesAtSkip + $categoriesAtLight) / [double]$categoriesWithSufficientData
        }
        else { 0.0 }
        [void]$out.AppendLine("  kaizen_metric:")
        [void]$out.AppendLine("    categories_with_sufficient_data: $categoriesWithSufficientData")
        [void]$out.AppendLine("    categories_at_skip_depth: $categoriesAtSkip")
        [void]$out.AppendLine("    categories_at_light_depth: $categoriesAtLight")
        [void]$out.AppendLine(("    kaizen_rate: {0:F2}" -f $kaizenRate))
        [void]$out.AppendLine("    patterns_meeting_threshold: $patternsMeetingThreshold")
        [void]$out.AppendLine("    patterns_previously_proposed: $patternsPreviouslyProposed")
    }
    else {
        [void]$out.AppendLine("  has_finding_data: false")
        [void]$out.AppendLine("  note: `"All analyzed PRs use v1 metrics format (no per-finding data). Upgrade to metrics_version: 2 to enable calibration.`"")
    }

    # ---------------------------------------------------------------------------
    # extraction_agents: per-agent extraction advisory (Phase 2 D7)
    # Emits agents where consecutive_over_ceiling >= persistent_threshold.
    # ---------------------------------------------------------------------------
    Write-ExtractionAgentsYaml -ComplexityOverCeilingHistory $complexityOverCeilingHistory -PersistentThreshold $persistentThreshold -Builder $out

    $healthReportContext = @{
        OverallSustainRate           = $overallSustainRate
        CategoryData                 = $ctx.categoryData
        KnownCategories              = $knownCategories
        ComplexityOverCeilingHistory = $complexityOverCeilingHistory
        PersistentThreshold          = $persistentThreshold
        SystemicPatterns             = $ctx.systemicPatterns
        KnownSystemicFixTypes        = $knownSystemicFixTypes
        ProposalsEmitted             = $proposalsEmitted
        Generated                    = $now.ToString('o')
        IssuesAnalyzed               = $ctx.issuesAnalyzed
        EffectiveSampleSize          = $ctx.effectiveSampleSize
        OlderWindowRate              = $olderWindowRate
        NewerWindowRate              = $newerWindowRate
        DepthRecommendations         = if ($ctx.v2IssuesAnalyzed -gt 0) { $depthRecommendations } else { @{} }
        FixEffectiveness             = (Measure-FixEffectiveness -ProposalsEmitted $proposalsEmitted -PrContributions $prContributions)
    }
    return @{ ExitCode = 0; Output = $out.ToString(); Error = ''; HealthReport = (Format-HealthReport $healthReportContext) }
}
