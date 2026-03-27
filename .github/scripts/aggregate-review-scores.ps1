#Requires -Version 7.0
<#
.SYNOPSIS
    Aggregates pipeline-metrics from merged PRs and computes a time-weighted
    calibration profile for the prosecution/defense/judge review pipeline.

.DESCRIPTION
    Reads merged PRs from the current (or specified) GitHub repository via the
    gh CLI, extracts <!-- pipeline-metrics --> blocks from PR bodies, and
    computes exponentially-decayed aggregate statistics.

    This script is primarily read-only. It writes prosecution_depth_state and time-decay re-activation events to the calibration file when present.

.PARAMETER DecayLambda
    Exponential decay parameter. Default: 0.023 (half-life ≈ 30 days).

.PARAMETER Limit
    Maximum number of merged PRs to fetch. Default: 100.

.PARAMETER Repo
    Repository in owner/name format. If omitted, auto-detected via
    'gh repo view --json nameWithOwner'.

.PARAMETER CalibrationFile
    Path to the local calibration JSON file produced by write-calibration-entry.ps1.
    Default: .copilot-tracking/calibration/review-data.json
    When the file does not exist, the script falls back to PR-body-only mode.
#>
[CmdletBinding()]
param(
    [double]$DecayLambda = 0.023,
    [int]$Limit = 100,
    [string]$Repo = '',
    [string]$CalibrationFile = '.copilot-tracking/calibration/review-data.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. gh CLI availability check
# ---------------------------------------------------------------------------
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Output "error: gh CLI not found. Install from https://cli.github.com/ and authenticate with 'gh auth login'."
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Resolve repository
# ---------------------------------------------------------------------------
if ($Repo -eq '') {
    # CWD must be the repository root for auto-detection to work correctly.
    $repoJson = gh repo view --json nameWithOwner
    if ($LASTEXITCODE -ne 0) {
        Write-Output "error: Failed to detect repository (gh exit code $LASTEXITCODE): $repoJson"
        exit 1
    }
    try {
        $Repo = ($repoJson | ConvertFrom-Json).nameWithOwner
    }
    catch {
        Write-Output "error: Failed to parse repository response: $_"
        exit 1
    }
}
$repoArgs = @('--repo', $Repo)

# ---------------------------------------------------------------------------
# 3. Fetch merged PRs
# ---------------------------------------------------------------------------
$prListJson = gh pr list --state merged --limit $Limit --json 'number,mergedAt,body' @repoArgs
if ($LASTEXITCODE -ne 0) {
    Write-Output "error: Failed to fetch merged PR list (gh exit code $LASTEXITCODE): $prListJson"
    exit 1
}
try {
    $mergedPRs = $prListJson | ConvertFrom-Json
}
catch {
    Write-Output "error: Failed to parse merged PR list: $_"
    exit 1
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

if ($null -eq $mergedPRs -or $mergedPRs.Count -eq 0) {
    Write-Output "data_source: $dataSource"
    Write-Output "insufficient_data: true"
    Write-Output "effective_sample_size: 0"
    Write-Output "issues_analyzed: 0"
    Write-Output "skipped_prs: 0"
    Write-Output 'message: "Minimum effective sample size of 5 required (current: 0.00)"'
    exit 0
}

# ---------------------------------------------------------------------------
# Shared helper: safe property read for PSCustomObject/hashtable
# ---------------------------------------------------------------------------
function Get-FlexProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) { return $Object[$Name] }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
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
                # $null means no differences → arrays are identical
                return $true
            }
        }
    }
    return $false
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
    }
    catch {
        Write-Warning "CalibrationFile '$CalibrationFile' could not be parsed: $_ — proceeding with GitHub data only."
        $localEntries = @{}
        $dataSource = 'github'
    }
}

# ---------------------------------------------------------------------------
# Shared helpers (Get-YamlField, Get-FindingsArray)
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'lib\pipeline-metrics-helpers.ps1')

# ---------------------------------------------------------------------------
# 4. Per-PR processing
# ---------------------------------------------------------------------------
$now = Get-Date
$requiredFindingFields = @('id', 'category', 'judge_ruling')

# Accumulators
$effectiveSampleSize = 0.0
$issuesAnalyzed = 0
$skippedPRs = 0
$totalFindings = 0

$weightedAccepted = 0.0   # judge_ruling = sustained
$weightedTotal = 0.0   # all findings with non-n/a category (code prosecution)

# Per-category accumulators: category -> @{ findings=0; effectiveCount=0.0; sustained=0.0 }
$categoryData = @{}

# Per-review-stage accumulators: stage -> @{ findings=0; sustained=0 }
$stageData = @{}
$reviewStageUntagged = 0   # findings where review_stage was absent and defaulted to 'main'

# Defense accumulators
$defenseTotal = 0.0   # weighted sum of findings where defense was involved (has defense_verdict)
$defenseTotalCount = 0     # raw count of findings where defense verdicts were emitted
$defenseSustained = 0.0   # defense-sustained (defense_verdict = sustained)
$defenseOverreach = 0.0   # defense claimed disproved but judge sustained prosecution anyway
$defenseChallengedTotal = 0.0   # weighted count of findings where defense claimed disproved (overreach denominator)
# v2 tracking
$v2IssuesAnalyzed = 0
# Known category taxonomy (mirrors the emit section — defined here so $accumulateFinding
# can reference it before the output section runs)
$knownCategories = @(
    'architecture', 'security', 'performance', 'pattern',
    'simplicity', 'script-automation', 'documentation-audit'
)
$systemicActive = $false   # true only inside the local-calibration findings loop

# Systemic fix pattern accumulators: fix_type -> category -> @{ count; sustained_count; prs; evidence }
$knownSystemicFixTypes = @('instruction', 'skill', 'agent-prompt', 'plan-template')
$systemicPatterns = @{}
foreach ($ft in $knownSystemicFixTypes) { $systemicPatterns[$ft] = @{} }

# Judge confidence calibration: level -> @{ count=0; effectiveCount=0.0; sustained=0.0 }
$confidenceData = @{
    high   = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
    medium = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
    low    = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
}

# ---------------------------------------------------------------------------
# Shared finding accumulation — dot-sourced at each call site.
# Expects $finding (hashtable with string values) and $weight (double) in scope.
# ---------------------------------------------------------------------------
$accumulateFinding = {
    $totalFindings++
    $category = $finding['category'].ToLowerInvariant()
    $judgeRuling = $finding['judge_ruling'].ToLowerInvariant()
    $judgeConfidence = if ($finding.ContainsKey('judge_confidence')) { $finding['judge_confidence'].ToLowerInvariant() } else { '' }
    $defenseVerdict = if ($finding.ContainsKey('defense_verdict')) { $finding['defense_verdict'].ToLowerInvariant() } else { '' }
    if (-not $finding.ContainsKey('review_stage')) { $reviewStageUntagged++ }
    $reviewStage = if ($finding.ContainsKey('review_stage')) { $finding['review_stage'].ToLowerInvariant() } else { 'main' }
    $isSustained = ($judgeRuling -eq 'sustained' -or $judgeRuling -eq 'finding-sustained')

    if ($category -ne 'n/a') {
        $weightedTotal += $weight
        if ($isSustained) { $weightedAccepted += $weight }
        if (-not $categoryData.ContainsKey($category)) {
            $categoryData[$category] = @{ findings = 0; effectiveCount = 0.0; sustained = 0.0 }
        }
        $categoryData[$category].findings++
        $categoryData[$category].effectiveCount += $weight
        if ($isSustained) { $categoryData[$category].sustained += $weight }
    }
    if (-not $stageData.ContainsKey($reviewStage)) {
        $stageData[$reviewStage] = @{ findings = 0; sustained = 0; effectiveCount = 0.0; effectiveSustained = 0.0 }
    }
    $stageData[$reviewStage].findings++
    $stageData[$reviewStage].effectiveCount += $weight
    if ($isSustained) {
        $stageData[$reviewStage].sustained++
        $stageData[$reviewStage].effectiveSustained += $weight
    }
    if ($category -ne 'n/a' -and $defenseVerdict -ne '') {
        $defenseTotal += $weight
        $defenseTotalCount++
        if ($judgeRuling -eq 'defense-sustained') { $defenseSustained += $weight }
        if ($defenseVerdict -eq 'disproved') {
            $defenseChallengedTotal += $weight
            if ($isSustained) { $defenseOverreach += $weight }
        }
    }
    if ($category -ne 'n/a' -and $confidenceData.ContainsKey($judgeConfidence)) {
        $confidenceData[$judgeConfidence].count++
        $confidenceData[$judgeConfidence].effectiveCount += $weight
        if ($isSustained) { $confidenceData[$judgeConfidence].sustained += $weight }
    }
    # Systemic fix pattern accumulation (calibration path only — $systemicActive guards this)
    $systemicFixType = if ($finding.ContainsKey('systemic_fix_type')) { $finding['systemic_fix_type'].ToLowerInvariant() } else { 'none' }
    if ($systemicActive -and $systemicFixType -ne 'none' -and $knownSystemicFixTypes -contains $systemicFixType -and $category -ne 'n/a' -and $knownCategories -contains $category) {
        if (-not $systemicPatterns.ContainsKey($systemicFixType)) { $systemicPatterns[$systemicFixType] = @{} }
        if (-not $systemicPatterns[$systemicFixType].ContainsKey($category)) {
            $systemicPatterns[$systemicFixType][$category] = @{
                count           = 0
                sustained_count = 0
                prs             = [System.Collections.Generic.HashSet[int]]::new()
                evidence        = [System.Collections.Generic.List[object]]::new()
            }
        }
        $systemicPatterns[$systemicFixType][$category].count++
        if ($isSustained) {
            $systemicPatterns[$systemicFixType][$category].sustained_count++
            [void]$systemicPatterns[$systemicFixType][$category].prs.Add($prNumber)
            [void]$systemicPatterns[$systemicFixType][$category].evidence.Add(@{ pr = $prNumber; finding = $finding['id'] })
        }
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

    $body = if ($pr.body) { $pr.body } else { '' }

    # Extract <!-- pipeline-metrics ... --> block
    $metricsMatch = [regex]::Match($body, '(?s)<!--\s*pipeline-metrics\s*(.*?)-->')

    if (-not $metricsMatch.Success) {
        # Union merge: fall back to local calibration entry if GitHub PR body has no metrics block
        if ($localEntries.ContainsKey($prNumber)) {
            $localEntry = $localEntries[$prNumber]
            $issuesAnalyzed++
            $effectiveSampleSize += $weight
            $v2IssuesAnalyzed++
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
        continue
    }

    $block = $metricsMatch.Groups[1].Value

    $issuesAnalyzed++
    $effectiveSampleSize += $weight

    # Detect format version
    $versionVal = Get-YamlField -Block $block -FieldName 'metrics_version'
    $isV2 = ($null -ne $versionVal -and $versionVal -ne '')

    if (-not $isV2) {
        # v1: flat fields only — contribute to effectiveSampleSize but no per-finding data
        continue
    }

    $v2IssuesAnalyzed++

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
}

# Compute max merged PR number (used for re-activation event expiry checks)
$maxMergedPrNumber = 0
foreach ($pr in $mergedPRs) {
    $prNum = [int]$pr.number
    if ($prNum -gt $maxMergedPrNumber) { $maxMergedPrNumber = $prNum }
}

# ---------------------------------------------------------------------------
# 5. Apply tiered thresholds and emit output
# ---------------------------------------------------------------------------
$overallSufficient = $effectiveSampleSize -ge 5.0

if (-not $overallSufficient) {
    $essFmt = '{0:F2}' -f $effectiveSampleSize
    Write-Output "data_source: $dataSource"
    Write-Output "insufficient_data: true"
    Write-Output "effective_sample_size: $essFmt"
    Write-Output "issues_analyzed: $issuesAnalyzed"
    Write-Output "skipped_prs: $skippedPRs"
    Write-Output "message: `"Minimum effective sample size of 5 required (current: ${essFmt})`""
    exit 0
}

# Compute rates
$overallSustainRate = if ($weightedTotal -gt 0) { $weightedAccepted / $weightedTotal } else { 0.0 }

$defenseSuccessRate = if ($defenseTotal -gt 0) { $defenseSustained / $defenseTotal } else { 0.0 }
$defenseChallengeRate = if ($defenseTotal -gt 0) { $defenseChallengedTotal / $defenseTotal } else { 0.0 }
$overreachRate = if ($defenseChallengedTotal -gt 0) { $defenseOverreach / $defenseChallengedTotal } else { 0.0 }

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
    'simplicity', 'script-automation', 'documentation-audit'
)

# ---------------------------------------------------------------------------
# 6. Emit YAML calibration profile
# ---------------------------------------------------------------------------
$generated = $now.ToString('yyyy-MM-dd')

Write-Output "data_source: $dataSource"
Write-Output "calibration:"
Write-Output "  generated: $generated"
Write-Output "  issues_analyzed: $issuesAnalyzed"
Write-Output "  v2_issues_analyzed: $v2IssuesAnalyzed"
Write-Output "  skipped_prs: $skippedPRs"
Write-Output "  total_findings: $totalFindings"
Write-Output ("  effective_sample_size: {0:F1}" -f $effectiveSampleSize)
Write-Output "  decay_lambda: $DecayLambda"
Write-Output "  prosecutor:"
Write-Output ("    overall_sustain_rate: {0:F2}" -f $overallSustainRate)
Write-Output "    sufficient_data: $($overallSufficient.ToString().ToLower())"
if ($v2IssuesAnalyzed -gt 0) {
    Write-Output "    by_category:"

    foreach ($cat in $knownCategories) {
        Write-Output "      ${cat}:"
        if ($categoryData.ContainsKey($cat)) {
            $cd = $categoryData[$cat]
            $catSustainRate = if ($cd.effectiveCount -gt 0) { $cd.sustained / $cd.effectiveCount } else { 0.0 }
            $catSufficient = $cd.effectiveCount -ge 15.0
            Write-Output "        findings: $($cd.findings)"
            Write-Output ("        effective_count: {0:F1}" -f $cd.effectiveCount)
            Write-Output ("        sustain_rate: {0:F2}" -f $catSustainRate)
            Write-Output "        sufficient_data: $($catSufficient.ToString().ToLower())"
        }
        else {
            Write-Output "        findings: 0"
            Write-Output "        effective_count: 0.0"
            Write-Output "        sustain_rate: 0.00"
            Write-Output "        sufficient_data: false"
        }
    }

    Write-Output "  defense:"
    Write-Output "    defense_findings_count: $defenseTotalCount"
    Write-Output ("    defense_effective_count: {0:F1}" -f $defenseTotal)
    $defenseSufficientData = $defenseTotal -ge 5.0
    Write-Output "    defense_sufficient_data: $($defenseSufficientData.ToString().ToLower())"
    Write-Output ("    defense_success_rate: {0:F2}" -f $defenseSuccessRate)
    Write-Output ("    defense_challenge_rate: {0:F2}" -f $defenseChallengeRate)
    Write-Output ("    overreach_rate: {0:F2}" -f $overreachRate)
    Write-Output "  judge:"
    Write-Output "    confidence_calibration:"

    foreach ($level in @('high', 'medium', 'low')) {
        $cd = $confidenceData[$level]
        # sustain_rate: renamed from 'accuracy' which was misleading
        $sustainRate = if ($cd.effectiveCount -gt 0) { $cd.sustained / $cd.effectiveCount } else { 0.0 }
        $levelSufficient = $cd.effectiveCount -ge 5
        Write-Output "      ${level}:"
        Write-Output "        sufficient_data: $($levelSufficient.ToString().ToLower())"
        Write-Output ("        sustain_rate: {0:F2}" -f $sustainRate)
        Write-Output "        count: $($cd.count)"
        Write-Output ("        effective_count: {0:F1}" -f $cd.effectiveCount)
    }

    Write-Output "    bias_direction: $biasDirection"
    Write-Output "  by_review_stage:"
    Write-Output "    review_stage_untagged: $reviewStageUntagged"
    $knownStages = @('main', 'postfix', 'ce')
    foreach ($stage in $knownStages) {
        Write-Output "    ${stage}:"
        if ($stageData.ContainsKey($stage)) {
            $sd = $stageData[$stage]
            $stageSustainRate = if ($sd.effectiveCount -gt 0) { $sd.effectiveSustained / $sd.effectiveCount } else { 0.0 }
            Write-Output "      findings: $($sd.findings)"
            Write-Output "      sustained: $($sd.sustained)"
            Write-Output ("      effective_count: {0:F1}" -f $sd.effectiveCount)
            Write-Output ("      sustain_rate: {0:F2}" -f $stageSustainRate)
        }
        else {
            Write-Output "      findings: 0"
            Write-Output "      sustained: 0"
            Write-Output "      effective_count: 0.0"
            Write-Output "      sustain_rate: 0.00"
        }
    }
    foreach ($stage in ($stageData.Keys | Where-Object { $knownStages -notcontains $_ } | Sort-Object)) {
        Write-Output "    ${stage}:"
        $sd = $stageData[$stage]
        $stageSustainRate = if ($sd.effectiveCount -gt 0) { $sd.effectiveSustained / $sd.effectiveCount } else { 0.0 }
        Write-Output "      findings: $($sd.findings)"
        Write-Output "      sustained: $($sd.sustained)"
        Write-Output ("      effective_count: {0:F1}" -f $sd.effectiveCount)
        Write-Output ("      sustain_rate: {0:F2}" -f $stageSustainRate)
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

    Write-Output "  prosecution_depth:"
    Write-Output "    override_active: $($overrideActive.ToString().ToLower())"

    foreach ($cat in $knownCategories) {
        # Read per-category depth state once (used by time-decay and state tracking)
        $catState = Get-FlexProperty $prosecutionDepthState $cat

        # Gather per-category stats
        $catEffective = 0.0
        $catSustainRate = 0.0
        if ($categoryData.ContainsKey($cat)) {
            $cd = $categoryData[$cat]
            $catEffective = $cd.effectiveCount
            $catSustainRate = if ($cd.effectiveCount -gt 0) { $cd.sustained / $cd.effectiveCount } else { 0.0 }
        }

        $recommendation = 'full'
        $reActivated = $false
        # ≥20 threshold for depth recommendation (higher bar than by_category ≥15 — depth changes have
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
                    # Unparseable date — ignore, fall through
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

        Write-Output "    ${cat}:"
        Write-Output "      recommendation: $recommendation"
        Write-Output ("      sustain_rate: {0:F2}" -f $catSustainRate)
        Write-Output ("      effective_count: {0:F1}" -f $catEffective)
        Write-Output "      sufficient_data: $($sufficientData.ToString().ToLower())"
        Write-Output "      re_activated: $($reActivated.ToString().ToLower())"
    }

    # Accumulate newly threshold-met unproposed patterns into proposals_emitted.
    # Must run after systemic pattern accumulation and before the write-back block
    # so $proposalsChanged correctly gates the atomic calibration file update.
    # Snapshot prior proposals first: $priorProposalsEmitted drives the previously_proposed
    # output field (only patterns proposed in a PRIOR run count as previously_proposed: true).
    $priorProposalsEmitted = @($proposalsEmitted)
    foreach ($ft in $knownSystemicFixTypes) {
        foreach ($cat in $systemicPatterns[$ft].Keys) {
            $spEntry = $systemicPatterns[$ft][$cat]
            $sustainedCnt = $spEntry.sustained_count
            $distinctPrs = $spEntry.prs.Count
            if ($sustainedCnt -ge 2 -and $distinctPrs -ge 2) {
                $patternKey = "${ft}:${cat}"
                $evidencePrs = @($spEntry.prs | Sort-Object)
                $alreadyProposed = Test-PatternProposed $proposalsEmitted $patternKey $evidencePrs
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
    if (($depthStateChanged -or $proposalsChanged) -and
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
            if ($proposalsChanged) {
                $calibContent | Add-Member -NotePropertyName 'proposals_emitted' -NotePropertyValue @($proposalsEmitted) -Force
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

    # systemic_patterns: aggregated fix-type x category patterns from sustained findings
    $patternsMeetingThreshold = 0
    $patternsPreviouslyProposed = 0
    $fixTypesWithData = $knownSystemicFixTypes | Where-Object { $systemicPatterns[$_].Count -gt 0 }
    if ($fixTypesWithData) {
        Write-Output "  systemic_patterns:"
        foreach ($ft in $knownSystemicFixTypes) {
            if ($systemicPatterns[$ft].Count -eq 0) {
                Write-Output "    ${ft}: {}"
            }
            else {
                Write-Output "    ${ft}:"
                foreach ($cat in ($systemicPatterns[$ft].Keys | Sort-Object)) {
                    $entry = $systemicPatterns[$ft][$cat]
                    $sustainedCnt = $entry.sustained_count
                    $distinctPrs = $entry.prs.Count
                    $meetsThreshold = ($sustainedCnt -ge 2 -and $distinctPrs -ge 2)
                    $patternKey = "${ft}:${cat}"
                    $evidencePrs = @($entry.prs | Sort-Object)
                    $prevProposed = Test-PatternProposed $priorProposalsEmitted $patternKey $evidencePrs
                    Write-Output "      ${cat}:"
                    Write-Output "        count: $($entry.count)"
                    Write-Output "        sustained_count: ${sustainedCnt}"
                    Write-Output "        distinct_prs: ${distinctPrs}"
                    Write-Output "        meets_threshold: $($meetsThreshold.ToString().ToLower())"
                    if ($entry.evidence.Count -gt 0) {
                        Write-Output "        evidence:"
                        foreach ($ev in $entry.evidence) {
                            Write-Output "          - pr: $($ev.pr), finding: $($ev.finding)"
                        }
                    }
                    if ($meetsThreshold) { $patternsMeetingThreshold++ }
                    if ($prevProposed -and $meetsThreshold) { $patternsPreviouslyProposed++ }
                    Write-Output "        previously_proposed: $($prevProposed.ToString().ToLower())"
                }
            }
        }
    }
    # kaizen_metric: aggregated calibration effectiveness metric
    $kaizenRate = if ($categoriesWithSufficientData -gt 0) {
        ($categoriesAtSkip + $categoriesAtLight) / [double]$categoriesWithSufficientData
    }
    else { 0.0 }
    Write-Output "  kaizen_metric:"
    Write-Output "    categories_with_sufficient_data: $categoriesWithSufficientData"
    Write-Output "    categories_at_skip_depth: $categoriesAtSkip"
    Write-Output "    categories_at_light_depth: $categoriesAtLight"
    Write-Output ("    kaizen_rate: {0:F2}" -f $kaizenRate)
    Write-Output "    patterns_meeting_threshold: $patternsMeetingThreshold"
    Write-Output "    patterns_previously_proposed: $patternsPreviouslyProposed"
}
else {
    Write-Output "  has_finding_data: false"
    Write-Output "  note: `"All analyzed PRs use v1 metrics format (no per-finding data). Upgrade to metrics_version: 2 to enable calibration.`""
}
