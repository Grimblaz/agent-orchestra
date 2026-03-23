#Requires -Version 7.0
<#
.SYNOPSIS
    Aggregates pipeline-metrics from merged PRs and computes a time-weighted
    calibration profile for the prosecution/defense/judge review pipeline.

.DESCRIPTION
    Reads merged PRs from the current (or specified) GitHub repository via the
    gh CLI, extracts <!-- pipeline-metrics --> blocks from PR bodies, and
    computes exponentially-decayed aggregate statistics.

    This script is READ-ONLY. It makes no mutations to PRs, repos, or files.

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
    $category        = $finding['category'].ToLowerInvariant()
    $judgeRuling     = $finding['judge_ruling'].ToLowerInvariant()
    $judgeConfidence = if ($finding.ContainsKey('judge_confidence')) { $finding['judge_confidence'].ToLowerInvariant() } else { '' }
    $defenseVerdict  = if ($finding.ContainsKey('defense_verdict'))  { $finding['defense_verdict'].ToLowerInvariant()  } else { '' }
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
}
else {
    Write-Output "  has_finding_data: false"
    Write-Output "  note: `"All analyzed PRs use v1 metrics format (no per-finding data). Upgrade to metrics_version: 2 to enable calibration.`""
}
