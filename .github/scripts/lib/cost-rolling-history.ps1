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

function script:ConvertFrom-CostPatternYamlScalar {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text -eq '' -or $text -eq 'null') { return $null }
    if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
        return $text.Substring(1, $text.Length - 2)
    }
    if ($text -eq 'true') { return $true }
    if ($text -eq 'false') { return $false }

    $intValue = 0
    if ([int]::TryParse($text, [ref]$intValue)) { return $intValue }

    $doubleValue = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue)) {
        return $doubleValue
    }

    return $text
}

function script:ConvertFrom-CostPatternYamlArray {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return @() }
    $text = ([string]$Value).Trim()
    if ($text.StartsWith('[') -and $text.EndsWith(']')) {
        $text = $text.Substring(1, $text.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $items = $text -split ',' | ForEach-Object {
        $item = $_.Trim()
        if (($item.StartsWith('"') -and $item.EndsWith('"')) -or ($item.StartsWith("'") -and $item.EndsWith("'"))) {
            $item = $item.Substring(1, $item.Length - 2)
        }
        $item
    } | Where-Object { $_ -ne '' }

    return , @($items)
}

function script:New-CostPatternTokenBucket {
    return @{ input = 0; output = 0; cache_creation = 0; cache_read = 0 }
}

function script:Get-CostPatternTokenBucket {
    param([Parameter(Mandatory)][hashtable]$Bucket)

    if (-not $Bucket.ContainsKey('tokens')) {
        $Bucket['tokens'] = (script:New-CostPatternTokenBucket)
    }

    return $Bucket['tokens']
}

function script:Set-CostPatternTokenField {
    param(
        [Parameter(Mandatory)][hashtable]$Bucket,
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Value
    )

    $tokens = script:Get-CostPatternTokenBucket -Bucket $Bucket
    $tokens[$Field] = [int](script:ConvertFrom-CostPatternYamlScalar -Value $Value)
}

function script:Set-CostPatternPortDefaults {
    param([Parameter(Mandatory)][hashtable]$PortEntry)

    $null = script:Get-CostPatternTokenBucket -Bucket $PortEntry

    $defaults = @{
        dispatch_count       = 0
        cost_estimate_usd    = 0.0
        cache_read_hit_ratio = 0.0
        prompt_size_chars    = 0
        null_cost_events     = 0
    }

    foreach ($field in $defaults.Keys) {
        if (-not $PortEntry.ContainsKey($field)) {
            $PortEntry[$field] = $defaults[$field]
        }
    }
}

function script:Set-CostPatternNumericField {
    param(
        [Parameter(Mandatory)][hashtable]$Bucket,
        [Parameter(Mandatory)][string]$Field,
        [AllowNull()][object]$Value
    )

    $scalar = script:ConvertFrom-CostPatternYamlScalar -Value $Value
    if ($null -eq $scalar) {
        $Bucket[$Field] = $null
    }
    else {
        $Bucket[$Field] = $scalar
    }
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
            coverage                       = 'claude-only'
            install_status                 = 'ok'
            unmapped_session_count         = 0
            provider_support               = @('claude')
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

            if ($line -match '^provider_support\s*:\s*(.+)$') {
                $result['provider_support'] = script:ConvertFrom-CostPatternYamlArray -Value $Matches[1]
            }

            if ($line -match '^coverage\s*:\s*(.+)$') {
                $result['coverage'] = [string](script:ConvertFrom-CostPatternYamlScalar -Value $Matches[1])
            }

            if ($line -match '^install_status\s*:\s*(.+)$') {
                $result['install_status'] = [string](script:ConvertFrom-CostPatternYamlScalar -Value $Matches[1])
            }

            if ($line -match '^unmapped_session_count\s*:\s*(.+)$') {
                $result['unmapped_session_count'] = [int](script:ConvertFrom-CostPatternYamlScalar -Value $Matches[1])
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
                $inProviders = $false
                $currentProvider = $null
                $currentTokenTarget = $null
                while ($j -lt $lines.Count) {
                    $subLine = $lines[$j]
                    if ($subLine -match '^\s*$') { $j++; continue }
                    # Top-level key at zero indent = end of ports block
                    if ($subLine -match '^[a-z_A-Z]' -and $subLine -notmatch '^\s') { break }
                    # New port entry
                    if ($subLine -match '^\s*-\s*name\s*:\s*(.+)$') {
                        if ($null -ne $currentPort) { $portsList.Add($currentPort) }
                        $currentPort = @{ name = $Matches[1].Trim() }
                        $inProviders = $false
                        $currentProvider = $null
                        $currentTokenTarget = $null
                    }
                    elseif ($null -ne $currentPort) {
                        if ($subLine -match '^\s+providers\s*:\s*$') {
                            if (-not $currentPort.ContainsKey('providers')) {
                                $currentPort['providers'] = @{}
                            }
                            $inProviders = $true
                            $currentProvider = $null
                            $currentTokenTarget = $null
                        }
                        elseif ($inProviders -and $subLine -match '^\s+(claude|copilot)\s*:\s*$') {
                            $currentProvider = @{ tokens = @{} }
                            $currentPort['providers'][$Matches[1]] = $currentProvider
                            $currentTokenTarget = $null
                        }
                        elseif ($inProviders -and $null -ne $currentProvider) {
                            if ($subLine -match '^\s+tokens\s*:\s*$') {
                                if (-not $currentProvider.ContainsKey('tokens')) { $currentProvider['tokens'] = @{} }
                                $currentTokenTarget = $currentProvider['tokens']
                            }
                            elseif ($subLine -match '^\s+(input|output|cache_creation|cache_read)\s*:\s*(.+)$') {
                                if ($null -eq $currentTokenTarget) {
                                    if (-not $currentProvider.ContainsKey('tokens')) { $currentProvider['tokens'] = @{} }
                                    $currentTokenTarget = $currentProvider['tokens']
                                }
                                $currentTokenTarget[$Matches[1]] = script:ConvertFrom-CostPatternYamlScalar -Value $Matches[2]
                            }
                            elseif ($subLine -match '^\s+(dispatch_count|prompt_size_chars|null_cost_events)\s*:\s*(.+)$') {
                                $currentProvider[$Matches[1]] = [int](script:ConvertFrom-CostPatternYamlScalar -Value $Matches[2])
                                $currentTokenTarget = $null
                            }
                            elseif ($subLine -match '^\s+(cost_estimate_usd|cache_read_hit_ratio)\s*:\s*(.+)$') {
                                $currentProvider[$Matches[1]] = script:ConvertFrom-CostPatternYamlScalar -Value $Matches[2]
                                $currentTokenTarget = $null
                            }
                            elseif ($subLine -match '^\s+(mixed_regime|cache_metric_unavailable|rate_unavailable|per_token_rates_published)\s*:\s*(.+)$') {
                                $currentProvider[$Matches[1]] = [bool](script:ConvertFrom-CostPatternYamlScalar -Value $Matches[2])
                                $currentTokenTarget = $null
                            }
                        }
                        elseif ($subLine -match '^\s+cost_estimate_usd\s*:\s*(.+)$') {
                            script:Set-CostPatternNumericField -Bucket $currentPort -Field 'cost_estimate_usd' -Value $Matches[1]
                        }
                        elseif ($subLine -match '^\s+dispatch_count\s*:\s*(.+)$') {
                            $currentPort['dispatch_count'] = [int]$Matches[1].Trim()
                        }
                        elseif ($subLine -match '^\s+prompt_size_chars\s*:\s*(.+)$') {
                            $currentPort['prompt_size_chars'] = [int]$Matches[1].Trim()
                        }
                        # cache_read_hit_ratio (Fix Pass1-F1: per-port cache-hit anomaly metric was
                        # silently reading 0.0 because the parser never matched this field;
                        # rendered by cost-pattern-renderer.ps1 line 453, consumed by cost-anomaly).
                        elseif ($subLine -match '^\s+cache_read_hit_ratio\s*:\s*(.+)$') {
                            script:Set-CostPatternNumericField -Bucket $currentPort -Field 'cache_read_hit_ratio' -Value $Matches[1]
                        }
                        # null_cost_events (Fix Pass3-F4: parser must round-trip this field so
                        # rolling-history entries reflect unknown-model events).
                        elseif ($subLine -match '^\s+null_cost_events\s*:\s*(.+)$') {
                            $currentPort['null_cost_events'] = [int]$Matches[1].Trim()
                        }
                        elseif ($subLine -match '^\s+provider_support\s*:\s*(.+)$') {
                            $currentPort['provider_support'] = script:ConvertFrom-CostPatternYamlArray -Value $Matches[1]
                        }
                        # tokens sub-block (Fix Pass1-F10: parse token fields for anomaly baseline)
                        elseif ($subLine -match '^\s+tokens\s*:\s*$') {
                            $null = script:Get-CostPatternTokenBucket -Bucket $currentPort
                        }
                        elseif ($subLine -match '^\s{6,}(input|output|cache_creation|cache_read)\s*:\s*(.+)$') {
                            script:Set-CostPatternTokenField -Bucket $currentPort -Field $Matches[1] -Value $Matches[2]
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
                        script:Set-CostPatternPortDefaults -PortEntry $portEntry
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
                    tokens               = (script:New-CostPatternTokenBucket)
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
                    if ($subLine -match '^\s{4,}(input|output|cache_creation|cache_read)\s*:\s*(.+)$') {
                        $oo['tokens'][$Matches[1]] = [int](script:ConvertFrom-CostPatternYamlScalar -Value $Matches[2])
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
        # Fix Pass2-F4: project the body to a small set of structured
        # sub-issue references rather than stashing the entire (multi-KB)
        # comment body in every cache entry. We extract `#NNNN` tokens with
        # a word-boundary regex so the downstream -SubIssue filter does an
        # exact list-membership test instead of a fuzzy substring/regex
        # match (the prior `[regex]::Escape('#469')` matched inside `#4690`).
        if (-not $parsed.ContainsKey('sub_issue_refs')) {
            $refs = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($m in [regex]::Matches([string]$body, '(?<![\w])#(\d+)(?![\w])')) {
                $null = $refs.Add('#' + $m.Groups[1].Value)
            }
            $parsed['sub_issue_refs'] = @($refs)
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
        [int]$Limit = 30,
        [string]$CachePath = '',
        [switch]$ForceRefresh,
        [int]$TimeoutSeconds = 10,
        [string]$RepoRoot = ''
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
            $cacheRaw = Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop
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

    $repoViewJson = & gh repo view --json owner, name 2>&1
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
        $name = $repoInfo['name']
    }
    catch {
        Write-Warning "cost-rolling-history: failed to parse repo view response: $_"
        return @{ timed_out = $false; entries = @() }
    }

    # ---- Try GraphQL first ----
    $gqlQueryStr = "{ search(query: `"repo:$owner/$name is:pr is:merged`", type: ISSUE, first: $Limit) { nodes { ... on PullRequest { number comments(first: 100) { nodes { body } } } } } }"
    $graphqlOutput = & gh api graphql -f "query=$gqlQueryStr" 2>&1

    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "cost-rolling-history: timed out after GraphQL call"
        return @{ timed_out = $true; entries = @() }
    }

    $useRest = $false
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
                    # Fix Pass3-F9: return entries fetched so far rather than discarding them.
                    # A partial baseline is more useful than an empty one for anomaly detection,
                    # and the partial_fetch flag lets callers decide whether to trust the result.
                    $partialEntries = script:ConvertTo-CostRollingEntries -Bodies $commentBodies.ToArray()
                    Write-Warning "cost-rolling-history: timed out during REST pr comments fetch — returning $($partialEntries.Count) partial entries from $($commentBodies.Count) comment bodies fetched so far"
                    return @{ timed_out = $true; entries = $partialEntries; partial_fetch = $true }
                }

                $prNum = $pr['number']
                $prCommentsOutput = & gh pr view $prNum --json comments 2>&1
                if ($LASTEXITCODE -ne 0) { continue }

                try {
                    $prData = ($prCommentsOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
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

    # ---- Write cache (Fix Pass1-F4: skip cache write when entries is empty) ----
    # A transient gh outage (GraphQL throttle, REST timeout, or zero matched
    # comments after parse-failure) can produce entries=[]. Writing that to
    # the cache file with a fresh generated_at would mask recovery for up to
    # the 1-hour TTL — every subsequent call within the hour would return
    # the empty list rather than retrying. Only persist non-empty results.
    if ($entries.Count -gt 0) {
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
    }

    return @{ timed_out = $false; entries = $entries }
}
