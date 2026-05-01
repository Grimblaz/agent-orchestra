#Requires -Version 7.0
<#
.SYNOPSIS
    Regime checkpoint CLI — captures a rolling-mean snapshot after a
    cost-reduction sub-issue lands and stabilizes (issue #467, Step 6).
.DESCRIPTION
    Cache-bust ordering (M5):
      1. Delete the rolling-history cache file.
      2. Call Get-CostRollingHistory -ForceRefresh to fetch fresh data.
      3. If -SubIssue given: filter entries whose comment body contains the
         sub-issue number string.
      4. Exclude the most recently fetched entries per -ExcludeMostRecent
         (default 1 — skips the most recently merged PR in the result set).
      5. Compute rolling-mean snapshot per metric per port from filtered entries.
      6. Append checkpoint entry to cost-regime-checkpoints.yaml.
.PARAMETER Reason
    Human-readable reason for the checkpoint (required).
.PARAMETER Note
    Optional free-text annotation.
.PARAMETER SubIssue
    Sub-issue reference to filter (e.g. "#469"). PRs whose comment body
    contains this string are excluded from the rolling-mean computation.
.PARAMETER ExcludeMostRecent
    Number of most-recently fetched PRs to exclude. Defaults to 1.
.PARAMETER CheckpointsPath
    Path to the checkpoints YAML file. Defaults to
    .github/scripts/cost-regime-checkpoints.yaml relative to repo root.
.PARAMETER CacheFilePath
    Path to the rolling-history cache file. Defaults to
    .github/scripts/cache/cost-rolling-history.json relative to repo root.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Reason,

    [string]$Note = '',

    [string]$SubIssue = '',

    [int]$ExcludeMostRecent = 1,

    [string]$CheckpointsPath = '',

    [string]$CacheFilePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Dot-source dependencies ----
. "$PSScriptRoot/lib/cost-rolling-history.ps1"
. "$PSScriptRoot/lib/cost-checkpoint-core.ps1"

# ---- Resolve default paths relative to repo root ----
$repoRoot = & git rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}
else {
    $repoRoot = ($repoRoot | Select-Object -First 1).Trim()
}

if ([string]::IsNullOrEmpty($CheckpointsPath)) {
    $CheckpointsPath = Join-Path $repoRoot '.github/scripts/cost-regime-checkpoints.yaml'
}

if ([string]::IsNullOrEmpty($CacheFilePath)) {
    $CacheFilePath = Join-Path $repoRoot '.github/scripts/cache/cost-rolling-history.json'
}

# ---- M5 Step 1: Delete cache file before fetch ----
Remove-Item -LiteralPath $CacheFilePath -Force -ErrorAction SilentlyContinue

# ---- M5 Step 2: Fetch fresh rolling history ----
$historyResult = Get-CostRollingHistory -ForceRefresh -CachePath $CacheFilePath -RepoRoot $repoRoot

if ($historyResult.timed_out) {
    Write-Warning "cost-regime-checkpoint: rolling history fetch timed out — aborting checkpoint."
    exit 1
}

$entries = @($historyResult.entries)

# ---- M5 Step 3: Filter entries mentioning -SubIssue ----
if (-not [string]::IsNullOrEmpty($SubIssue)) {
    $entries = @($entries | Where-Object {
        $body = ''
        if ($_.ContainsKey('comment_body')) { $body = [string]$_['comment_body'] }
        -not ($body -match [regex]::Escape($SubIssue))
    })
}

# ---- M5 Step 4: Exclude most-recent N entries ----
if ($ExcludeMostRecent -gt 0 -and $entries.Count -gt $ExcludeMostRecent) {
    $entries = @($entries | Select-Object -Skip $ExcludeMostRecent)
}
elseif ($ExcludeMostRecent -gt 0 -and $entries.Count -le $ExcludeMostRecent) {
    $entries = @()
}

# ---- M5 Step 5: Compute rolling-mean snapshot ----
# Aggregate per-port cost_estimate_usd and dispatch_count, plus orchestrator overhead
$metrics = @{}

if ($entries.Count -gt 0) {
    # Per-port means
    $portAccum    = @{}
    $portCounts   = @{}
    $ooCostTotal  = 0.0
    $ooCount      = 0

    foreach ($e in $entries) {
        # Ports — Get-CostRollingHistory returns ports as a hashtable keyed by
        # port name (per Pass1-F10 structural fix). Defensive fallback for
        # older shapes that may still emit an array of {name, ...} records.
        if ($e.ContainsKey('ports') -and $null -ne $e['ports']) {
            $portsObj = $e['ports']
            $portIter = @()
            if ($portsObj -is [hashtable]) {
                foreach ($pName in $portsObj.Keys) {
                    $portIter += [pscustomobject]@{ Name = [string]$pName; Bucket = $portsObj[$pName] }
                }
            }
            else {
                foreach ($port in @($portsObj)) {
                    if ($null -eq $port -or -not ($port -is [hashtable])) { continue }
                    $portIter += [pscustomobject]@{ Name = [string]$port['name']; Bucket = $port }
                }
            }
            foreach ($p in $portIter) {
                $pName  = $p.Name
                $bucket = $p.Bucket
                if ([string]::IsNullOrEmpty($pName) -or $null -eq $bucket -or -not ($bucket -is [hashtable])) { continue }
                if (-not $bucket.ContainsKey('cost_estimate_usd')) { continue }
                if (-not $portAccum.ContainsKey($pName)) {
                    $portAccum[$pName]  = 0.0
                    $portCounts[$pName] = 0
                }
                $portAccum[$pName]  += [double]$bucket['cost_estimate_usd']
                $portCounts[$pName] += 1
            }
        }

        # Orchestrator overhead
        if ($e.ContainsKey('orchestrator_overhead') -and $null -ne $e['orchestrator_overhead']) {
            $oo = $e['orchestrator_overhead']
            if ($oo -is [hashtable] -and $oo.ContainsKey('cost_estimate_usd')) {
                $ooCostTotal += [double]$oo['cost_estimate_usd']
                $ooCount++
            }
        }
    }

    foreach ($pName in $portAccum.Keys) {
        $mean = $portAccum[$pName] / $portCounts[$pName]
        $metrics["port.$pName.cost_estimate_usd.mean"] = [math]::Round($mean, 6)
    }

    if ($ooCount -gt 0) {
        $metrics['orchestrator_overhead.cost_estimate_usd.mean'] = [math]::Round($ooCostTotal / $ooCount, 6)
    }
}

# ---- Build checkpoint entry ----
$nowUtc    = (Get-Date).ToUniversalTime()
$cpId      = "cp-$($nowUtc.ToString('yyyyMMdd-HHmmss'))"
$timestamp = $nowUtc.ToString('o')

$exclusions = @{ recent_count = $ExcludeMostRecent }
if (-not [string]::IsNullOrEmpty($SubIssue)) {
    $exclusions['sub_issue'] = $SubIssue
}

$cpEntry = @{
    id         = $cpId
    timestamp  = $timestamp
    reason     = $Reason
    note       = $Note
    metrics    = $metrics
    exclusions = $exclusions
}

if (-not [string]::IsNullOrEmpty($SubIssue)) {
    $cpEntry['sub_issue'] = $SubIssue
}

# ---- M5 Step 6: Append checkpoint entry ----
Add-RegimeCheckpoint -Path $CheckpointsPath -Entry $cpEntry

Write-Host "Checkpoint written: $cpId to $CheckpointsPath"
Write-Host "  Timestamp:  $timestamp"
Write-Host "  Reason:     $Reason"
if (-not [string]::IsNullOrEmpty($SubIssue)) {
    Write-Host "  SubIssue:   $SubIssue"
}
Write-Host "  Metrics:    $($metrics.Count) computed"
Write-Host "  Excluded:   $ExcludeMostRecent most-recent entries"
