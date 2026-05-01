#Requires -Version 7.0
<#
.SYNOPSIS
    Rolling-history fetch for cost telemetry baseline (issue #467, Step 5).
.DESCRIPTION
    Fetches rolling baseline data from the last N merged PRs' cost-pattern-data
    embedded YAML blocks. Uses a 1-hour cache. Falls back from GraphQL to REST
    when GraphQL fails. Returns an array of parsed attribution hashtables or a
    timed_out sentinel.
#>

# -------------------------------------------------------------------------
# Private helpers (script-scope so tests can dot-source and call them)
# -------------------------------------------------------------------------

function script:Get-CostPatternDataFromComment {
    <#
    .SYNOPSIS
        Extracts the YAML content from a <!-- cost-pattern-data ... --> block.
    #>
    param([string]$Body)
    if ($Body -notmatch '<!--\s*cost-pattern-data') {
        return $null
    }
    if ($Body -match '<!--\s*cost-pattern-data\s*\r?\n([\s\S]*?)\r?\n?-->') {
        return $Matches[1]
    }
    return $null
}

function script:ConvertFrom-CostPatternYaml {
    <#
    .SYNOPSIS
        Parses the YAML fields from a cost-pattern-data block into a hashtable.
    #>
    param([string]$Yaml)
    try {
        $result = @{
            ports                          = @()
            orchestrator_overhead          = @{}
            dispatches                     = @{}
            totals                         = @{}
            excluded_from_rolling_baseline = $false
            cost_pattern_data              = @{}
        }

        $lines = $Yaml -split '\r?\n'
        $i = 0

        while ($i -lt $lines.Count) {
            $line = $lines[$i]

            # excluded_from_rolling_baseline
            if ($line -match '^\s*excluded_from_rolling_baseline\s*:\s*(.+)$') {
                $val = $Matches[1].Trim()
                $result['excluded_from_rolling_baseline'] = ($val -eq 'true')
            }

            # cost_pattern_data block
            if ($line -match '^\s*cost_pattern_data\s*:\s*$') {
                $j = $i + 1
                $cpd = @{}
                while ($j -lt $lines.Count) {
                    $subLine = $lines[$j]
                    if ($subLine -match '^\s*$') { $j++; continue }
                    if (-not ($subLine -match '^\s')) { break }
                    if ($subLine -match '^\s+source\s*:\s*(.+)$') {
                        $cpd['source'] = $Matches[1].Trim()
                    }
                    if ($subLine -match '^\s+accessible\s*:\s*(.+)$') {
                        $rawAcc = $Matches[1].Trim()
                        $cpd['accessible'] = ($rawAcc -eq 'true')
                    }
                    $j++
                }
                $result['cost_pattern_data'] = $cpd
                $i = $j
                continue
            }

            # ports section (array)
            if ($line -match '^\s*ports\s*:\s*$') {
                $portsList = [System.Collections.Generic.List[hashtable]]::new()
                $j = $i + 1
                $currentPort = $null
                while ($j -lt $lines.Count) {
                    $subLine = $lines[$j]
                    if ($subLine -match '^\s*$') { $j++; continue }
                    # Top-level key at zero indent = end of ports block
                    if ($subLine -match '^[a-z_A-Z]' -and $subLine -notmatch '^\s') { break }
                    # New port entry
                    if ($subLine -match '^\s*-\s*name\s*:\s*(.+)$') {
                        if ($null -ne $currentPort) { $portsList.Add($currentPort) }
                        $currentPort = @{ name = $Matches[1].Trim() }
                    }
                    elseif ($null -ne $currentPort) {
                        if ($subLine -match '^\s+cost_estimate_usd\s*:\s*(.+)$') {
                            $currentPort['cost_estimate_usd'] = [double]$Matches[1].Trim()
                        }
                        if ($subLine -match '^\s+dispatch_count\s*:\s*(.+)$') {
                            $currentPort['dispatch_count'] = [int]$Matches[1].Trim()
                        }
                        if ($subLine -match '^\s+prompt_size_chars\s*:\s*(.+)$') {
                            $currentPort['prompt_size_chars'] = [int]$Matches[1].Trim()
                        }
                        # tokens sub-block (Fix Pass1-F10: parse token fields for anomaly baseline)
                        if ($subLine -match '^\s+tokens\s*:\s*$') {
                            if (-not $currentPort.ContainsKey('tokens')) {
                                $currentPort['tokens'] = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                            }
                        }
                        if ($subLine -match '^\s{6,}input\s*:\s*(.+)$') {
                            if (-not $currentPort.ContainsKey('tokens')) {
                                $currentPort['tokens'] = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                            }
                            $currentPort['tokens']['input'] = [int]$Matches[1].Trim()
                        }
                        if ($subLine -match '^\s{6,}output\s*:\s*(.+)$') {
                            if (-not $currentPort.ContainsKey('tokens')) {
                                $currentPort['tokens'] = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                            }
                            $currentPort['tokens']['output'] = [int]$Matches[1].Trim()
                        }
                        if ($subLine -match '^\s{6,}cache_creation\s*:\s*(.+)$') {
                            if (-not $currentPort.ContainsKey('tokens')) {
                                $currentPort['tokens'] = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                            }
                            $currentPort['tokens']['cache_creation'] = [int]$Matches[1].Trim()
                        }
                        if ($subLine -match '^\s{6,}cache_read\s*:\s*(.+)$') {
                            if (-not $currentPort.ContainsKey('tokens')) {
                                $currentPort['tokens'] = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                            }
                            $currentPort['tokens']['cache_read'] = [int]$Matches[1].Trim()
                        }
                    }
                    $j++
                }
                if ($null -ne $currentPort) { $portsList.Add($currentPort) }
                # Convert ports list to dictionary keyed by port name so rolling-history entries
                # match the Get-CostAttribution output structure expected by Get-MetricValue.
                $portsDict = @{}
                foreach ($portEntry in $portsList) {
                    $pName = $portEntry['name']
                    if ($null -ne $pName) {
                        # Ensure tokens sub-hashtable exists (zeroed if absent)
                        if (-not $portEntry.ContainsKey('tokens')) {
                            $portEntry['tokens'] = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                        }
                        # Ensure numeric fields exist with defaults
                        if (-not $portEntry.ContainsKey('dispatch_count'))    { $portEntry['dispatch_count']    = 0 }
                        if (-not $portEntry.ContainsKey('cost_estimate_usd')) { $portEntry['cost_estimate_usd'] = 0.0 }
                        if (-not $portEntry.ContainsKey('cache_read_hit_ratio')) { $portEntry['cache_read_hit_ratio'] = 0.0 }
                        if (-not $portEntry.ContainsKey('prompt_size_chars')) { $portEntry['prompt_size_chars'] = 0 }
                        $portsDict[$pName] = $portEntry
                    }
                }
                $result['ports'] = $portsDict
                $i = $j
                continue
            }

            # orchestrator_overhead block
            if ($line -match '^\s*orchestrator_overhead\s*:\s*$') {
                $oo = @{
                    tokens               = @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
                    cost_estimate_usd    = 0.0
                    cache_read_hit_ratio = 0.0
                }
                $j = $i + 1
                while ($j -lt $lines.Count) {
                    $subLine = $lines[$j]
                    if ($subLine -match '^\s*$') { $j++; continue }
                    if (-not ($subLine -match '^\s')) { break }
                    if ($subLine -match '^\s+cost_estimate_usd\s*:\s*(.+)$') {
                        $oo['cost_estimate_usd'] = [double]$Matches[1].Trim()
                    }
                    if ($subLine -match '^\s+cache_read_hit_ratio\s*:\s*(.+)$') {
                        $oo['cache_read_hit_ratio'] = [double]$Matches[1].Trim()
                    }
                    # tokens sub-block (Fix Pass1-F10)
                    if ($subLine -match '^\s{4,}input\s*:\s*(.+)$') {
                        $oo['tokens']['input'] = [int]$Matches[1].Trim()
                    }
                    if ($subLine -match '^\s{4,}output\s*:\s*(.+)$') {
                        $oo['tokens']['output'] = [int]$Matches[1].Trim()
                    }
                    if ($subLine -match '^\s{4,}cache_creation\s*:\s*(.+)$') {
                        $oo['tokens']['cache_creation'] = [int]$Matches[1].Trim()
                    }
                    if ($subLine -match '^\s{4,}cache_read\s*:\s*(.+)$') {
                        $oo['tokens']['cache_read'] = [int]$Matches[1].Trim()
                    }
                    $j++
                }
                $result['orchestrator_overhead'] = $oo
                $i = $j
                continue
            }

            # dispatches block
            if ($line -match '^\s*dispatches\s*:\s*$') {
                $disp = @{}
                $j = $i + 1
                while ($j -lt $lines.Count) {
                    $subLine = $lines[$j]
                    if ($subLine -match '^\s*$') { $j++; continue }
                    if (-not ($subLine -match '^\s')) { break }
                    if ($subLine -match '^\s+general_purpose_count\s*:\s*(.+)$') {
                        $disp['general_purpose_count'] = [int]$Matches[1].Trim()
                    }
                    if ($subLine -match '^\s+unattributed_count\s*:\s*(.+)$') {
                        $disp['unattributed_count'] = [int]$Matches[1].Trim()
                    }
                    $j++
                }
                $result['dispatches'] = $disp
                $i = $j
                continue
            }

            # totals block
            if ($line -match '^\s*totals\s*:\s*$') {
                $tot = @{}
                $j = $i + 1
                while ($j -lt $lines.Count) {
                    $subLine = $lines[$j]
                    if ($subLine -match '^\s*$') { $j++; continue }
                    if (-not ($subLine -match '^\s')) { break }
                    if ($subLine -match '^\s+cost_estimate_usd\s*:\s*(.+)$') {
                        $tot['cost_estimate_usd'] = [double]$Matches[1].Trim()
                    }
                    $j++
                }
                $result['totals'] = $tot
                $i = $j
                continue
            }

            $i++
        }

        return $result
    }
    catch {
        Write-Warning "cost-rolling-history: failed to parse YAML block: $_"
        return $null
    }
}

function script:Test-CostPatternShouldExclude {
    <#
    .SYNOPSIS
        Returns $true if an entry should be excluded from the rolling baseline.
    #>
    param([hashtable]$Parsed)

    # Exclusion 1: excluded_from_rolling_baseline: true
    if ($Parsed.ContainsKey('excluded_from_rolling_baseline') -and
        $Parsed['excluded_from_rolling_baseline'] -eq $true) {
        return $true
    }

    # Exclusion 2: cost_pattern_data.source = copilot AND accessible = false
    $cpd = $Parsed['cost_pattern_data']
    if ($null -ne $cpd -and $cpd -is [hashtable]) {
        $src = [string]$cpd['source']
        $acc = $cpd.ContainsKey('accessible') ? $cpd['accessible'] : $true
        if ($src -eq 'copilot' -and $acc -eq $false) {
            return $true
        }
    }

    return $false
}

function script:ConvertTo-CostRollingEntries {
    <#
    .SYNOPSIS
        Extracts and filters cost-pattern-data entries from an array of comment bodies.
    #>
    param([string[]]$Bodies)

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($body in $Bodies) {
        $yamlText = script:Get-CostPatternDataFromComment -Body $body
        if ($null -eq $yamlText) { continue }
        $parsed = script:ConvertFrom-CostPatternYaml -Yaml $yamlText
        if ($null -eq $parsed) { continue }
        if (script:Test-CostPatternShouldExclude -Parsed $parsed) { continue }
        # Stash the raw comment body so downstream callers (e.g.
        # cost-regime-checkpoint.ps1's -SubIssue filter) can match against
        # text that lives outside the cost-pattern-data YAML, such as the
        # PR body or any sub-issue marker line. Without this, a -SubIssue
        # filter has nothing to match against.
        if (-not $parsed.ContainsKey('comment_body')) {
            $parsed['comment_body'] = [string]$body
        }
        $entries.Add($parsed)
    }
    return , $entries.ToArray()
}

# -------------------------------------------------------------------------
# Public function
# -------------------------------------------------------------------------

function Get-CostRollingHistory {
    <#
    .SYNOPSIS
        Fetches rolling history of cost attribution data from merged PRs.
    .DESCRIPTION
        Queries GitHub for the last $Limit merged PRs in the repo, extracts
        <!-- cost-pattern-data ... --> YAML blocks from PR comments, and returns
        them as an array of attribution hashtables. Results are cached for 1 hour.

        Returns @{ timed_out: $false; entries: @(...) }
        OR on timeout: @{ timed_out: $true; entries: @() }
    .PARAMETER Limit
        Number of merged PRs to fetch. Default: 30.
    .PARAMETER CachePath
        Absolute path to the cache file. Defaults to
        .github/scripts/cache/cost-rolling-history.json relative to RepoRoot.
    .PARAMETER ForceRefresh
        When set, deletes the cache and fetches fresh data even if within TTL.
    .PARAMETER TimeoutSeconds
        Per-run budget in seconds. If the budget is exceeded at a yield point,
        returns the timed_out sentinel. Default: 10.
    .PARAMETER RepoRoot
        Absolute path to the repository root. Defaults to git rev-parse output.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$Limit           = 30,
        [string]$CachePath    = '',
        [switch]$ForceRefresh,
        [int]$TimeoutSeconds  = 10,
        [string]$RepoRoot     = ''
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ---- Resolve repo root ----
    if (-not $RepoRoot) {
        $gitOutput = & git rev-parse --show-toplevel 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "cost-rolling-history: could not determine repo root via git: $gitOutput"
            $RepoRoot = $PSScriptRoot
        }
        else {
            $RepoRoot = ($gitOutput | Select-Object -First 1).Trim()
        }
    }

    # ---- Resolve cache path ----
    if (-not $CachePath) {
        $CachePath = Join-Path $RepoRoot '.github/scripts/cache/cost-rolling-history.json'
    }

    # ---- ForceRefresh: delete cache ----
    if ($ForceRefresh -and (Test-Path -LiteralPath $CachePath)) {
        Remove-Item -LiteralPath $CachePath -Force -ErrorAction SilentlyContinue
    }

    # ---- Cache hit: return if fresh (< 1 hour old) ----
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $CachePath)) {
        try {
            $cacheRaw  = Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop
            $cacheData = $cacheRaw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($null -ne $cacheData -and $cacheData.ContainsKey('generated_at')) {
                # ConvertFrom-Json -AsHashtable may auto-parse the ISO-8601 string into a
                # [DateTime] object. Handle both string and DateTime inputs.
                $rawGeneratedAt = $cacheData['generated_at']
                $generatedAt = if ($rawGeneratedAt -is [datetime]) {
                    $rawGeneratedAt
                }
                else {
                    [datetime]::Parse(
                        [string]$rawGeneratedAt,
                        $null,
                        [System.Globalization.DateTimeStyles]::RoundtripKind
                    )
                }
                # Normalize to UTC for comparison
                $generatedAtUtc = $generatedAt.Kind -eq [System.DateTimeKind]::Utc `
                    ? $generatedAt `
                    : $generatedAt.ToUniversalTime()
                $age = (Get-Date).ToUniversalTime() - $generatedAtUtc
                if ($age.TotalHours -lt 1.0) {
                    $cachedEntries = @()
                    if ($cacheData.ContainsKey('entries') -and $null -ne $cacheData['entries']) {
                        $cachedEntries = @($cacheData['entries'])
                    }
                    return @{ timed_out = $false; entries = $cachedEntries }
                }
            }
        }
        catch {
            Write-Warning "cost-rolling-history: failed to read/parse cache at '$CachePath': $_"
        }
    }

    # ---- Resolve repo owner/name ----
    # Budget check before first API call
    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "cost-rolling-history: timed out before repo view"
        return @{ timed_out = $true; entries = @() }
    }

    $repoViewJson = & gh repo view --json owner,name 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "cost-rolling-history: gh repo view failed: $repoViewJson"
        return @{ timed_out = $false; entries = @() }
    }

    # Budget check after repo view (may have taken time)
    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "cost-rolling-history: timed out after repo view"
        return @{ timed_out = $true; entries = @() }
    }

    try {
        $repoInfo = ($repoViewJson | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $owner = $repoInfo['owner']['login']
        $name  = $repoInfo['name']
    }
    catch {
        Write-Warning "cost-rolling-history: failed to parse repo view response: $_"
        return @{ timed_out = $false; entries = @() }
    }

    # ---- Try GraphQL first ----
    $gqlQueryStr  = "{ search(query: `"repo:$owner/$name is:pr is:merged`", type: ISSUE, first: $Limit) { nodes { ... on PullRequest { number comments(first: 100) { nodes { body } } } } } }"
    $graphqlOutput = & gh api graphql -f "query=$gqlQueryStr" 2>&1

    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "cost-rolling-history: timed out after GraphQL call"
        return @{ timed_out = $true; entries = @() }
    }

    $useRest       = $false
    $commentBodies = [System.Collections.Generic.List[string]]::new()

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "cost-rolling-history: GraphQL exited $LASTEXITCODE — falling back to REST"
        $useRest = $true
    }
    else {
        try {
            $rawGql = $graphqlOutput | Out-String
            $gqlData = $rawGql | ConvertFrom-Json -AsHashtable -ErrorAction Stop

            # Non-empty errors[] => fallback
            if ($gqlData.ContainsKey('errors') -and
                $null -ne $gqlData['errors'] -and
                @($gqlData['errors']).Count -gt 0) {
                Write-Warning "cost-rolling-history: GraphQL response has errors — falling back to REST"
                $useRest = $true
            }
            # Missing data path => fallback
            elseif (-not $gqlData.ContainsKey('data') -or $null -eq $gqlData['data']) {
                Write-Warning "cost-rolling-history: GraphQL response missing data — falling back to REST"
                $useRest = $true
            }
            else {
                $searchData = $gqlData['data']['search']
                if ($null -eq $searchData) {
                    Write-Warning "cost-rolling-history: GraphQL response missing data.search — falling back to REST"
                    $useRest = $true
                }
                else {
                    $nodes = $searchData['nodes']
                    if ($null -eq $nodes) {
                        Write-Warning "cost-rolling-history: GraphQL response missing data.search.nodes — falling back to REST"
                        $useRest = $true
                    }
                    else {
                        # data.search.nodes:[] is a valid zero-PR result — NOT a fallback trigger (M19)
                        # Use @() to ensure array identity when single-element JSON is unwrapped by ConvertFrom-Json
                        foreach ($prNode in @($nodes)) {
                            if ($null -eq $prNode) { continue }
                            $prCommentContainer = $prNode['comments']
                            if ($null -eq $prCommentContainer) { continue }
                            # Use @() for single-element comment nodes
                            $prCommentNodes = @($prCommentContainer['nodes'])
                            foreach ($comment in $prCommentNodes) {
                                if ($null -eq $comment) { continue }
                                $body = [string]$comment['body']
                                if ($body -match '<!--\s*cost-pattern-data') {
                                    $commentBodies.Add($body)
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning "cost-rolling-history: GraphQL response parse failure: $_ — falling back to REST"
            $useRest = $true
        }
    }

    # ---- REST fallback ----
    if ($useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "cost-rolling-history: timed out before REST fallback"
            return @{ timed_out = $true; entries = @() }
        }

        $prListOutput = & gh pr list --state merged --limit $Limit --json number 2>&1

        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "cost-rolling-history: timed out after REST pr list"
            return @{ timed_out = $true; entries = @() }
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "cost-rolling-history: REST pr list failed: $prListOutput"
            return @{ timed_out = $false; entries = @() }
        }

        try {
            # Use @() to guarantee array identity when single-element JSON is unwrapped by ConvertFrom-Json
            $prList = @(($prListOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
            foreach ($pr in $prList) {
                if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    Write-Warning "cost-rolling-history: timed out during REST pr comments fetch"
                    return @{ timed_out = $true; entries = @() }
                }

                $prNum = $pr['number']
                $prCommentsOutput = & gh pr view $prNum --json comments 2>&1
                if ($LASTEXITCODE -ne 0) { continue }

                try {
                    $prData    = ($prCommentsOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    # Use @() to guarantee array identity (single-element JSON may be unwrapped)
                    $prComments = @($prData['comments'])
                    if ($prComments.Count -eq 0) { continue }
                    foreach ($comment in $prComments) {
                        if ($null -eq $comment) { continue }
                        $body = [string]$comment['body']
                        if ($body -match '<!--\s*cost-pattern-data') {
                            $commentBodies.Add($body)
                        }
                    }
                }
                catch {
                    Write-Warning "cost-rolling-history: failed to parse pr $prNum comments: $_"
                }
            }
        }
        catch {
            Write-Warning "cost-rolling-history: failed to parse pr list: $_"
        }
    }

    # ---- Extract entries ----
    $entries = script:ConvertTo-CostRollingEntries -Bodies $commentBodies.ToArray()

    # ---- Write cache ----
    try {
        $cacheDir = Split-Path -Parent $CachePath
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        $cachePayload = @{
            generated_at = (Get-Date).ToUniversalTime().ToString('o')
            entries      = $entries
        }
        $cachePayload | ConvertTo-Json -Depth 20 | Set-Content -Path $CachePath -Encoding UTF8
    }
    catch {
        Write-Warning "cost-rolling-history: failed to write cache to '$CachePath': $_"
    }

    return @{ timed_out = $false; entries = $entries }
}
