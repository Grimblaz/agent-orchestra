#Requires -Version 7.0
<#
.SYNOPSIS
    Core helper library for regime checkpoint management (issue #467, Step 6).
.DESCRIPTION
    Provides Get-MostRecentRegimeCheckpoint and Add-RegimeCheckpoint for reading
    and writing to the cost-regime-checkpoints.yaml accumulation file.

    The loader uses simple YAML line-parsing — no external module required.
    Since checkpoints accumulate by append, the most-recent entry is determined
    by comparing timestamp values.
#>

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function script:ConvertFrom-EscapedYamlScalar {
    <#
    .SYNOPSIS
        Strips outer double-quotes and unescapes `\"` and `\\` from a YAML
        double-quoted scalar value. Pairs with the escape pass in
        Add-RegimeCheckpoint (Fix Pass3-F7).
    #>
    param([string]$Raw)
    if ($null -eq $Raw) { return '' }
    $trimmed = $Raw.Trim()
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        $trimmed = $trimmed.Substring(1, $trimmed.Length - 2)
    }
    # Unescape in reverse order: `\"` first (so the `\\` pass doesn't see them
    # as already-escaped sequences), then `\\` → `\`.
    $trimmed = $trimmed -replace '\\"', '"'
    $trimmed = $trimmed -replace '\\\\', '\'
    return $trimmed
}

function script:ConvertFrom-CheckpointYaml {
    <#
    .SYNOPSIS
        Parses the checkpoints array from a cost-regime-checkpoints.yaml file.
        Returns an array of hashtables, one per checkpoint entry.
    .DESCRIPTION
        Handles top-level scalar entry fields (id, timestamp, sub_issue,
        reason, note) and one level of nested key/value blocks for `metrics:`
        and `exclusions:`. The writer in Add-RegimeCheckpoint emits nested
        blocks at 6-space indent (entry list items at 2-space; entry fields
        at 4-space; nested values at 6-space), so this parser tracks indent
        depth to know when a sub-block ends.
    #>
    param([string]$Content)

    $lines = $Content -split '\r?\n'
    $checkpoints = [System.Collections.Generic.List[hashtable]]::new()

    $inCheckpoints = $false
    $current = $null
    $subBlockKey = $null   # name of the active nested block (e.g. 'metrics')
    $subBlockIndent = -1     # indent of the sub-block opener line ('    metrics:')

    foreach ($line in $lines) {
        # Detect the start of the checkpoints array
        if ($line -match '^\s*checkpoints\s*:\s*(\[\s*\])?\s*$') {
            $inCheckpoints = $true
            if ($line -match '\[\s*\]') { $inCheckpoints = $false }
            continue
        }

        if (-not $inCheckpoints) { continue }

        $leadingSpaces = 0
        if ($line -match '^(\s*)') { $leadingSpaces = $Matches[1].Length }

        # New entry starts with a list item "  - id:" or "  - timestamp:" etc.
        if ($line -match '^\s+-\s+(\w+)\s*:\s*(.*)$') {
            if ($null -ne $current) { $checkpoints.Add($current) }
            $current = @{}
            $subBlockKey = $null
            $subBlockIndent = -1
            $key = $Matches[1].Trim()
            $val = script:ConvertFrom-EscapedYamlScalar -Raw $Matches[2]
            $current[$key] = $val
            continue
        }

        # If we're inside a sub-block, only consume lines at strictly greater
        # indent than the opener; any line at <= the opener indent ends the
        # block and we fall through to the normal entry-field handling.
        if ($null -ne $subBlockKey -and $null -ne $current) {
            if ($leadingSpaces -gt $subBlockIndent -and $line -match '^\s+([\w.\-]+)\s*:\s*(.*)$') {
                $sk = $Matches[1].Trim()
                $sv = script:ConvertFrom-EscapedYamlScalar -Raw $Matches[2]
                $current[$subBlockKey][$sk] = $sv
                continue
            }
            # Indent dropped — sub-block closed. Fall through.
            $subBlockKey = $null
            $subBlockIndent = -1
        }

        # Continuation key inside an entry (scalar fields OR sub-block opener)
        if ($null -ne $current -and $line -match '^\s+(\w[^:]*)\s*:\s*(.*)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()
            # Sub-block sentinel checks must use raw (un-unescaped) value
            # since `{}` and empty-string are structural, not strings.
            $unescaped = script:ConvertFrom-EscapedYamlScalar -Raw $Matches[2]
            if ($val -eq '' -or $val -eq '{}') {
                # Sub-block opener — initialize hashtable and start tracking
                if ($val -eq '{}') {
                    $current[$key] = @{}
                }
                else {
                    $current[$key] = @{}
                    $subBlockKey = $key
                    $subBlockIndent = $leadingSpaces
                }
            }
            else {
                $current[$key] = $unescaped
            }
            continue
        }
    }

    if ($null -ne $current) { $checkpoints.Add($current) }

    return , $checkpoints.ToArray()
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function Get-MostRecentRegimeCheckpoint {
    <#
    .SYNOPSIS
        Reads cost-regime-checkpoints.yaml and returns the entry with the most
        recent timestamp, or $null if the file is absent or has no entries.
    .PARAMETER Path
        Absolute path to the checkpoints YAML file.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    $entries = script:ConvertFrom-CheckpointYaml -Content $content
    if ($null -eq $entries -or $entries.Count -eq 0) {
        return $null
    }

    # Find the entry with the greatest timestamp (ISO-8601 lexicographic sort is correct)
    $best = $null
    foreach ($entry in $entries) {
        if ($null -eq $best) {
            $best = $entry
            continue
        }
        $bestTs = [string]$best['timestamp']
        $curTs = [string]$entry['timestamp']
        if ([string]::Compare($curTs, $bestTs, [System.StringComparison]::Ordinal) -gt 0) {
            $best = $entry
        }
    }

    return $best
}

function Add-RegimeCheckpoint {
    <#
    .SYNOPSIS
        Appends a checkpoint entry to the YAML file.
        Creates the file with a schema_version header if absent.
    .PARAMETER Path
        Absolute path to the checkpoints YAML file.
    .PARAMETER Entry
        Hashtable describing the checkpoint. Expected keys:
            id, timestamp, sub_issue, reason, note, metrics, exclusions
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Entry
    )

    # Ensure parent directory exists
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Bootstrap file if absent
    if (-not (Test-Path -LiteralPath $Path)) {
        @"
schema_version: 1
checkpoints: []
"@ | Set-Content -Path $Path -Encoding UTF8 -NoNewline:$false
    }

    # Build the YAML block for this entry
    $id = [string]$Entry['id']
    $timestamp = [string]$Entry['timestamp']
    $subIssue = if ($Entry.ContainsKey('sub_issue') -and -not [string]::IsNullOrEmpty($Entry['sub_issue'])) { [string]$Entry['sub_issue'] } else { '' }
    $reason = [string]$Entry['reason']
    $note = if ($Entry.ContainsKey('note') -and -not [string]::IsNullOrEmpty([string]$Entry['note'])) { [string]$Entry['note'] } else { '' }

    $metricsLines = ''
    if ($Entry.ContainsKey('metrics') -and $Entry['metrics'] -is [hashtable] -and $Entry['metrics'].Count -gt 0) {
        $metricsLines = ($Entry['metrics'].GetEnumerator() | Sort-Object Key | ForEach-Object {
                "      $($_.Key): $($_.Value)"
            }) -join "`n"
    }

    $exclusionsLines = ''
    if ($Entry.ContainsKey('exclusions') -and $Entry['exclusions'] -is [hashtable] -and $Entry['exclusions'].Count -gt 0) {
        $exclusionsLines = ($Entry['exclusions'].GetEnumerator() | Sort-Object Key | ForEach-Object {
                "      $($_.Key): $($_.Value)"
            }) -join "`n"
    }

    # Fix Pass3-F7: YAML-escape user-supplied strings before interpolating
    # into double-quoted scalars. Without this, a -Reason value containing a
    # `"` or `\` produces invalid YAML that the parser at line 84 cannot read
    # back correctly (it splits on the first `:` and Trim('"') leaves quotes
    # mid-value). Backslashes must be escaped first to avoid double-escaping
    # the replacement we add for quotes.
    #
    # Spawned-task fix: the replacement string `'\\'` is two literal backslashes
    # (PowerShell single-quote does no escaping). In .NET regex replacement,
    # `\` is NOT a special character — only `$` is — so `'\\'` outputs exactly
    # two backslashes per match. The previous `'\\\\'` (four chars) output four
    # backslashes per match, which the reader's `\\` → `\` unescape only halved,
    # leaving each input `\` doubled after a round-trip.
    $escId = ($id -replace '\\', '\\') -replace '"', '\"'
    $escTimestamp = ($timestamp -replace '\\', '\\') -replace '"', '\"'
    $escSubIssue = ($subIssue -replace '\\', '\\') -replace '"', '\"'
    $escReason = ($reason -replace '\\', '\\') -replace '"', '\"'
    $escNote = ($note -replace '\\', '\\') -replace '"', '\"'

    # Build YAML entry block
    $entryLines = [System.Collections.Generic.List[string]]::new()
    $entryLines.Add("  - id: `"$escId`"")
    $entryLines.Add("    timestamp: `"$escTimestamp`"")
    if (-not [string]::IsNullOrEmpty($subIssue)) {
        $entryLines.Add("    sub_issue: `"$escSubIssue`"")
    }
    $entryLines.Add("    reason: `"$escReason`"")
    if (-not [string]::IsNullOrEmpty($note)) {
        $entryLines.Add("    note: `"$escNote`"")
    }
    if (-not [string]::IsNullOrEmpty($metricsLines)) {
        $entryLines.Add('    metrics:')
        $entryLines.Add($metricsLines)
    }
    else {
        $entryLines.Add('    metrics: {}')
    }
    if (-not [string]::IsNullOrEmpty($exclusionsLines)) {
        $entryLines.Add('    exclusions:')
        $entryLines.Add($exclusionsLines)
    }
    else {
        $entryLines.Add('    exclusions: {}')
    }

    $entryBlock = $entryLines -join "`n"

    # Read existing file, strip trailing blank lines, then splice the new entry
    # after the checkpoints: [] or at the end of the checkpoints array.
    $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($existing)) {
        $existing = "schema_version: 1`ncheckpoints: []`n"
    }

    # Normalize line endings
    $existing = $existing -replace '\r\n', "`n" -replace '\r', "`n"

    # Replace "checkpoints: []" with the new entry in the array, or append to existing array
    if ($existing -match 'checkpoints:\s*\[\s*\]') {
        # Bootstrap case: replace empty array with list containing first entry.
        # Fix issue #492 Step 2: escape $ in $replacement before passing to -replace.
        # PowerShell's -replace operator treats $1, $&, $$ etc. as substitution
        # metacharacters in the replacement string. Pre-escaping each $ to $$ means
        # the outer -replace sees $$ (literal $) wherever the caller intended $.
        # `'$$$$'` (4 chars) emits two $ — the inner -replace pass produces a $$
        # for each input $, which the outer -replace then collapses back to a
        # single $.
        $replacement = "checkpoints:`n$entryBlock"
        $escapedReplacement = $replacement -replace '\$', '$$$$'
        $result = $existing -replace 'checkpoints:\s*\[\s*\]', $escapedReplacement
    }
    else {
        # Append case: add new entry before any trailing newlines at end of file
        $result = $existing.TrimEnd("`n", "`r") + "`n" + $entryBlock + "`n"
    }

    Set-Content -Path $Path -Value $result -Encoding UTF8 -NoNewline
}

function Invoke-CostRegimeCheckpoint {
    <#
    .SYNOPSIS
        Captures a rolling-mean cost-regime checkpoint from prior PR ledger
        comments and appends it to the checkpoints YAML file (issue #467, Step 6).
    .DESCRIPTION
        This function holds the full CLI flow that was previously inlined in
        cost-regime-checkpoint.ps1. The CLI script is now a thin shim that
        dot-sources its dependencies and calls this function with bound
        parameters, so tests can exercise the same flow in-process via
        dot-source rather than spawning a child pwsh per assertion.

        Cache-bust ordering (M5):
          1. Delete the rolling-history cache file.
          2. Call Get-CostRollingHistory -ForceRefresh to fetch fresh data.
          3. If -SubIssue given: exclude entries whose comment body contains
             the sub-issue number string.
          4. Exclude the most recently fetched entries per -ExcludeMostRecent
             (default 1).
          5. Compute rolling-mean snapshot per metric per port from filtered
             entries.
          6. Append checkpoint entry to cost-regime-checkpoints.yaml.

        Get-CostRollingHistory is expected to be loaded in the caller's scope;
        the CLI script dot-sources cost-rolling-history.ps1 before calling
        this function, and tests do the same in BeforeAll.
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
    .PARAMETER RepoRoot
        Optional repo-root override. When empty, resolved via
        `git rev-parse --show-toplevel`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Reason,

        [string]$Note = '',

        [string]$SubIssue = '',

        [int]$ExcludeMostRecent = 1,

        [string]$CheckpointsPath = '',

        [string]$CacheFilePath = '',

        [string]$RepoRoot = ''
    )

    # ---- Resolve repo root and default paths ----
    if ([string]::IsNullOrEmpty($RepoRoot)) {
        $repoRootRaw = & git rev-parse --show-toplevel 2>&1
        if ($LASTEXITCODE -eq 0) {
            $RepoRoot = ($repoRootRaw | Select-Object -First 1).Trim()
        }
        else {
            $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        }
    }

    if ([string]::IsNullOrEmpty($CheckpointsPath)) {
        $CheckpointsPath = Join-Path $RepoRoot '.github/scripts/cost-regime-checkpoints.yaml'
    }

    if ([string]::IsNullOrEmpty($CacheFilePath)) {
        $CacheFilePath = Join-Path $RepoRoot '.github/scripts/cache/cost-rolling-history.json'
    }

    # ---- M5 Step 1: Delete cache file before fetch ----
    Remove-Item -LiteralPath $CacheFilePath -Force -ErrorAction SilentlyContinue

    # ---- M5 Step 2: Fetch fresh rolling history ----
    $historyResult = Get-CostRollingHistory -ForceRefresh -CachePath $CacheFilePath -RepoRoot $RepoRoot

    if ($historyResult.timed_out) {
        Write-Warning "cost-regime-checkpoint: rolling history fetch timed out — aborting checkpoint."
        return $null
    }

    $entries = @($historyResult.entries)

    # ---- M5 Step 3: Filter entries mentioning -SubIssue ----
    # Fix Pass2-F4: filter against the structured sub_issue_refs list
    # (extracted by ConvertTo-CostRollingEntries with word-boundary regex)
    # so that -SubIssue '#469' does NOT match inside '#4690' and we don't
    # carry multi-KB comment bodies through the cache. Falls back to the
    # legacy comment_body match for any cache entries from before this fix.
    if (-not [string]::IsNullOrEmpty($SubIssue)) {
        $entries = @($entries | Where-Object {
                if ($_.ContainsKey('sub_issue_refs')) {
                    $refs = @($_['sub_issue_refs'])
                    # Exact membership test — exclude when this PR cited the sub-issue.
                    return ($refs -notcontains $SubIssue)
                }
                # Legacy fallback for older cache shapes that stashed comment_body.
                if ($_.ContainsKey('comment_body')) {
                    $body = [string]$_['comment_body']
                    # Word-boundary regex prevents '#469' from matching '#4690'.
                    return -not ($body -match ('(?<![\w])' + [regex]::Escape($SubIssue) + '(?![\w])'))
                }
                return $true   # No reference data available → don't exclude.
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
    $metrics = @{}

    if ($entries.Count -gt 0) {
        $portAccum = @{}
        $portCounts = @{}
        $ooCostTotal = 0.0
        $ooCount = 0

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
                    $pName = $p.Name
                    $bucket = $p.Bucket
                    if ([string]::IsNullOrEmpty($pName) -or $null -eq $bucket -or -not ($bucket -is [hashtable])) { continue }
                    if (-not $bucket.ContainsKey('cost_estimate_usd')) { continue }
                    if (-not $portAccum.ContainsKey($pName)) {
                        $portAccum[$pName] = 0.0
                        $portCounts[$pName] = 0
                    }
                    $portAccum[$pName] += [double]$bucket['cost_estimate_usd']
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
    $nowUtc = (Get-Date).ToUniversalTime()
    $cpId = "cp-$($nowUtc.ToString('yyyyMMdd-HHmmss'))"
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

    return $cpId
}
