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
#>
[CmdletBinding()]
param(
    [double]$DecayLambda = 0.023,
    [int]$Limit = 100,
    [string]$Repo = ''
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
$repoArgs = @()
if ($Repo -ne '') {
    $repoArgs = @('--repo', $Repo)
}
else {
    $repoJson = gh repo view --json nameWithOwner 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output "error: Failed to detect repository (gh exit code $LASTEXITCODE): $repoJson"
        exit 1
    }
    try {
        $repoInfo = $repoJson | ConvertFrom-Json
        $Repo = $repoInfo.nameWithOwner
    }
    catch {
        Write-Output "error: Failed to parse repository response: $_"
        exit 1
    }
    $repoArgs = @('--repo', $Repo)
}

# ---------------------------------------------------------------------------
# 3. Fetch merged PRs
# ---------------------------------------------------------------------------
$prListJson = gh pr list --state merged --limit $Limit --json number,mergedAt @repoArgs 2>&1
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

if ($null -eq $mergedPRs -or $mergedPRs.Count -eq 0) {
    Write-Output "insufficient_data: true"
    Write-Output "effective_sample_size: 0"
    Write-Output "issues_analyzed: 0"
    Write-Output 'message: "Minimum effective sample size of 5 required (current: 0.00)"'
    exit 0
}

# ---------------------------------------------------------------------------
# Helper: extract a flat YAML field value from a text block
# ---------------------------------------------------------------------------
function Get-YamlField {
    param([string]$Block, [string]$FieldName)
    $m = [regex]::Match($Block, "(?m)^${FieldName}:\s*(.+)$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# ---------------------------------------------------------------------------
# Helper: parse the findings: array from a v2 metrics block
# ---------------------------------------------------------------------------
function Get-FindingsArray {
    param([string]$Block)

    $findings = [System.Collections.Generic.List[hashtable]]::new()

    # Locate start of findings: section
    $startMatch = [regex]::Match($Block, '(?m)^findings:\s*$')
    if (-not $startMatch.Success) { return $findings }

    $blockLines = $Block -split "`n"
    $inFindings = $false
    $current = $null

    foreach ($line in $blockLines) {
        if (-not $inFindings) {
            if ($line -match '^findings:\s*$') {
                $inFindings = $true
            }
            continue
        }

        # New finding entry
        if ($line -match '^\s+-\s+id:\s*(.+)$') {
            if ($null -ne $current) { $findings.Add($current) }
            $current = @{ id = $Matches[1].Trim() }
            continue
        }

        # Stop if we hit a top-level key (no leading spaces)
        if ($line -match '^[a-z_]+:\s') {
            if ($null -ne $current) { $findings.Add($current) }
            $current = $null
            break
        }

        # Field within current entry
        if ($null -ne $current -and $line -match '^\s{2,}([a-z_]+):\s*(.*)$') {
            $current[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }

    if ($null -ne $current) { $findings.Add($current) }
    return $findings
}

# ---------------------------------------------------------------------------
# 4. Per-PR processing
# ---------------------------------------------------------------------------
$now = Get-Date
$requiredFindingFields = @('id', 'category', 'judge_ruling', 'judge_confidence')

# Accumulators
$effectiveSampleSize  = 0.0
$issuesAnalyzed       = 0
$skippedPRs           = 0
$totalFindings        = 0

$weightedAccepted     = 0.0   # judge_ruling = sustained
$weightedTotal        = 0.0   # all findings with non-n/a category (code prosecution)

# Per-category accumulators: category -> @{ findings=0; effectiveCount=0.0; sustained=0.0 }
$categoryData = @{}

# Per-review-stage accumulators: stage -> @{ findings=0; sustained=0 }
$stageData = @{}
$reviewStageUntagged = 0   # findings where review_stage was absent and defaulted to 'main'

# Defense accumulators
$defenseTotal            = 0.0   # weighted sum of findings where defense was involved (has defense_verdict)
$defenseTotalCount       = 0     # raw count of findings where defense verdicts were emitted
$defenseSustained        = 0.0   # defense-sustained (defense_verdict = sustained)
$defenseOverreach        = 0.0   # defense claimed disproved but judge sustained prosecution anyway
$defenseChallengedTotal  = 0.0   # weighted count of findings where defense claimed disproved (overreach denominator)

# Judge confidence calibration: level -> @{ count=0; effectiveCount=0.0; sustained=0.0 }
$confidenceData = @{
    high   = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
    medium = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
    low    = @{ count = 0; effectiveCount = 0.0; sustained = 0.0 }
}

foreach ($pr in $mergedPRs) {
    $prNumber  = $pr.number
    $mergedAt  = $pr.mergedAt

    # Compute decay weight
    try {
        $mergedDate = [datetime]::Parse($mergedAt)
        $daysSince  = ($now - $mergedDate).TotalDays
        if ($daysSince -lt 0) { $daysSince = 0 }
        $weight = [Math]::Exp(-$DecayLambda * $daysSince)
    }
    catch {
        Write-Warning "PR #${prNumber}: failed to parse mergedAt '${mergedAt}', skipping."
        $skippedPRs++
        continue
    }

    # Fetch PR body
    $body = $null
    $prViewJson = gh pr view $prNumber --json body @repoArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "PR #${prNumber}: gh returned exit code $LASTEXITCODE — skipping."
        $skippedPRs++
        continue
    }
    try {
        $prView = $prViewJson | ConvertFrom-Json
        $body   = $prView.body
    }
    catch {
        Write-Warning "PR #${prNumber}: failed to parse PR body — $_"
        $skippedPRs++
        continue
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        continue
    }

    # Extract <!-- pipeline-metrics ... --> block
    $metricsMatch = [regex]::Match($body, '(?s)<!--\s*pipeline-metrics\s*(.*?)-->')
    if (-not $metricsMatch.Success) {
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

    # v2: parse per-finding array
    $findings = Get-FindingsArray -Block $block

    foreach ($finding in $findings) {
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

        $totalFindings++

        $category        = $finding['category'].ToLower()
        $judgeRuling     = $finding['judge_ruling'].ToLower()
        $judgeConfidence = $finding['judge_confidence'].ToLower()
        $defenseVerdict  = if ($finding.ContainsKey('defense_verdict')) { $finding['defense_verdict'].ToLower() } else { '' }
        if (-not $finding.ContainsKey('review_stage')) { $reviewStageUntagged++ }
        $reviewStage     = if ($finding.ContainsKey('review_stage')) { $finding['review_stage'].ToLower() } else { 'main' }

        $isSustained = ($judgeRuling -eq 'sustained')

        # Per-category (skip n/a — non-code prosecution)
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

        # Per-stage aggregation (all findings, including n/a)
        if (-not $stageData.ContainsKey($reviewStage)) {
            $stageData[$reviewStage] = @{ findings = 0; sustained = 0 }
        }
        $stageData[$reviewStage].findings++
        if ($isSustained) { $stageData[$reviewStage].sustained++ }

        # Defense analysis (gate on code prosecution only — skip n/a category)
        if ($category -ne 'n/a' -and $defenseVerdict -ne '') {
            $defenseTotal += $weight
            $defenseTotalCount++
            if ($judgeRuling -eq 'defense-sustained') {
                $defenseSustained += $weight
            }
            # Overreach: defense claimed disproved but judge still sustained prosecution
            if ($defenseVerdict -eq 'disproved') {
                $defenseChallengedTotal += $weight
                if ($isSustained) {
                    $defenseOverreach += $weight
                }
            }
        }

        # Judge confidence calibration (gate on code prosecution only — skip n/a category)
        if ($category -ne 'n/a' -and $confidenceData.ContainsKey($judgeConfidence)) {
            $confidenceData[$judgeConfidence].count++
            $confidenceData[$judgeConfidence].effectiveCount += $weight
            if ($isSustained) {
                $confidenceData[$judgeConfidence].sustained += $weight
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Apply tiered thresholds and emit output
# ---------------------------------------------------------------------------
$overallSufficient = $effectiveSampleSize -ge 5.0

if (-not $overallSufficient) {
    $essFmt = '{0:F2}' -f $effectiveSampleSize
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
$overreachRate      = if ($defenseChallengedTotal -gt 0) { $defenseOverreach / $defenseChallengedTotal } else { 0.0 }

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

Write-Output "calibration:"
Write-Output "  generated: $generated"
Write-Output "  issues_analyzed: $issuesAnalyzed"
Write-Output "  skipped_prs: $skippedPRs"
Write-Output "  total_findings: $totalFindings"
Write-Output ("  effective_sample_size: {0:F1}" -f $effectiveSampleSize)
Write-Output "  decay_lambda: $DecayLambda"
Write-Output "  prosecutor:"
Write-Output ("    overall_sustain_rate: {0:F2}" -f $overallSustainRate)
Write-Output "    sufficient_data: $($overallSufficient.ToString().ToLower())"
Write-Output "    by_category:"

foreach ($cat in $knownCategories) {
    Write-Output "      ${cat}:"
    if ($categoryData.ContainsKey($cat)) {
        $cd = $categoryData[$cat]
        $catSustainRate = if ($cd.effectiveCount -gt 0) { $cd.sustained / $cd.effectiveCount } else { 0.0 }
        $catSufficient  = $cd.effectiveCount -ge 15.0
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
Write-Output "    defense_total: $defenseTotalCount"
$defenseSufficientData = $defenseTotalCount -ge 5
Write-Output "    defense_sufficient_data: $($defenseSufficientData.ToString().ToLower())"
Write-Output ("    overall_success_rate: {0:F2}" -f $defenseSuccessRate)
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
        Write-Output "      findings: $($sd.findings)"
        Write-Output "      sustained: $($sd.sustained)"
    }
    else {
        Write-Output "      findings: 0"
        Write-Output "      sustained: 0"
    }
}
