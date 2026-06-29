#Requires -Version 7.0
<#
.SYNOPSIS
    Rolling-history fetch for phase-containment escape-rate ledger (issue #762).
.DESCRIPTION
    Walks two surfaces:
      Surface A: GitHub issue comments — scans issues that have design-phase-complete
                 or plan-issue markers for phase-containment-{ID} blocks.
      Surface B: Merged PR comments — scans merged PRs that have judge-rulings blocks
                 for phase-containment-{ID} blocks.

    Uses a 1-hour two-sided cache. Falls back from GraphQL to REST when GraphQL fails.
    Paginates both surfaces using pageInfo.hasNextPage cursor pagination.

    SECURITY: Do NOT import powershell-yaml or use ConvertFrom-Yaml.
    All parsing delegates to phase-containment-core.ps1.
#>

. (Join-Path $PSScriptRoot 'phase-containment-core.ps1')

Set-StrictMode -Version Latest

# -------------------------------------------------------------------------
# Public helper: Test-PhaseContainmentCacheFresh
# Exposed so tests can call it directly.
# Two-sided freshness guard: reject if generated_at is in the future OR if age >= 1h.
# -------------------------------------------------------------------------

function Test-PhaseContainmentCacheFresh {
    <#
    .SYNOPSIS
        Returns $true when a cache timestamp is valid (past, within 1 hour).
    .DESCRIPTION
        Two-sided guard:
          - Rejects if generated_at is in the future (even 1 second ahead).
          - Rejects if age is >= 1 hour (strictly less than 1h to be fresh).
        Returns $false on any parse failure.
    .PARAMETER GeneratedAtUtcString
        ISO 8601 string representing the cache generation time.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$GeneratedAtUtcString
    )

    try {
        $parsed = [datetime]::Parse(
            $GeneratedAtUtcString,
            $null,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        $parsedUtc = $parsed.Kind -eq [System.DateTimeKind]::Utc `
            ? $parsed `
            : $parsed.ToUniversalTime()

        $now = (Get-Date).ToUniversalTime()
        $age = $now - $parsedUtc

        # Future-dated: reject (two-sided guard)
        if ($parsedUtc -gt $now) {
            return $false
        }

        # Stale: reject if age >= 1 hour
        if ($age.TotalHours -ge 1.0) {
            return $false
        }

        return $true
    }
    catch {
        Write-Warning "phase-containment-rolling-history-core: failed to parse cache timestamp '$GeneratedAtUtcString': $_"
        return $false
    }
}

# -------------------------------------------------------------------------
# Public helper: Invoke-PhaseContainmentDedup
# Dedup by finding_key — keep entry with the latest createdAt.
# -------------------------------------------------------------------------

function Invoke-PhaseContainmentDedup {
    <#
    .SYNOPSIS
        Deduplicates phase-containment entries by finding_key, keeping the latest createdAt.
    .DESCRIPTION
        SMC-20 convention: when the same finding_key appears multiple times (e.g., a
        re-annotated block), keep the entry with the most recent createdAt timestamp.
    .PARAMETER RawEntries
        Array of PSCustomObject or hashtable entries, each with finding_key and createdAt fields.
    .OUTPUTS
        [array] Deduplicated entries.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawEntries
    )

    if ($RawEntries.Count -eq 0) {
        return , @()
    }

    $best = [System.Collections.Generic.Dictionary[string, object]]::new()

    foreach ($entry in $RawEntries) {
        $key = if ($entry -is [hashtable]) { [string]$entry['finding_key'] } else { [string]$entry.finding_key }
        $createdAtStr = if ($entry -is [hashtable]) { [string]$entry['createdAt'] } else { [string]$entry.createdAt }

        if (-not $best.ContainsKey($key)) {
            $best[$key] = $entry
            continue
        }

        # Parse both timestamps and keep the newer one
        $existingCreatedAtStr = if ($best[$key] -is [hashtable]) { [string]$best[$key]['createdAt'] } else { [string]$best[$key].createdAt }

        try {
            $existingDt = [datetime]::Parse($existingCreatedAtStr, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $candidateDt = [datetime]::Parse($createdAtStr, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)

            if ($candidateDt -gt $existingDt) {
                $best[$key] = $entry
            }
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: failed to compare timestamps for key '$key': $_"
        }
    }

    return , @($best.Values)
}

# -------------------------------------------------------------------------
# Public helper: Invoke-PhaseContainmentCommentScan
# Scan an array of comment bodies for phase-containment-{ID} blocks.
# Exposed so tests can call it with mock data without real API calls.
# -------------------------------------------------------------------------

function Invoke-PhaseContainmentCommentScan {
    <#
    .SYNOPSIS
        Scans an array of comment bodies for phase-containment-{ID} blocks.
    .DESCRIPTION
        For each body, calls Get-PhaseContainmentBlock with the given ID.
        Valid blocks are parsed via ConvertFrom-PhaseContainmentYaml and
        validated via Test-PhaseContainmentEntry. Invalid entries emit a
        warning and are skipped. Returns array of entry hashtables with
        additional metadata fields appended.
    .PARAMETER CommentBodies
        Array of comment body strings to scan.
    .PARAMETER IssueOrPrNumber
        The issue or PR number used as the ID for Get-PhaseContainmentBlock.
    .PARAMETER Surface
        Optional surface label to attach to each entry. Default: 'unknown'.
    .PARAMETER CreatedAtValues
        Optional parallel array of createdAt strings (ISO 8601), one per body.
        If not supplied, entries get an empty string for createdAt.
    .OUTPUTS
        [array] Parsed, validated entry hashtables with appended metadata.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CommentBodies,
        [Parameter(Mandatory)][int]$IssueOrPrNumber,
        [string]$Surface = 'unknown',
        [AllowEmptyCollection()][string[]]$CreatedAtValues = @()
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()
    $id      = [string]$IssueOrPrNumber

    for ($i = 0; $i -lt $CommentBodies.Count; $i++) {
        $body = $CommentBodies[$i]
        $createdAt = if ($i -lt $CreatedAtValues.Count) { $CreatedAtValues[$i] } else { '' }

        $yamlText = Get-PhaseContainmentBlock -Text $body -Id $id
        if ($null -eq $yamlText) { continue }

        $parsed = ConvertFrom-PhaseContainmentYaml -Yaml $yamlText
        if ($null -eq $parsed) {
            Write-Warning "phase-containment-rolling-history-core: failed to parse block in comment $i for ID $id"
            continue
        }

        $validation = Test-PhaseContainmentEntry -Entry $parsed
        if (-not $validation.IsValid) {
            Write-Warning "phase-containment-rolling-history-core: invalid phase-containment block in comment $i for ID $id — $($validation.Errors -join '; ')"
            continue
        }

        # Derive finding_key using cross-surface format
        $stablePart    = if ($null -ne $parsed['finding_key'] -and $parsed['finding_key'] -ne '') { $parsed['finding_key'] } else { "$id:unknown" }
        $derivedKey    = Get-PhaseContainmentFindingKey -Surface $Surface -StableFindingKey $stablePart

        # Build the output entry — use the parsed finding_key directly (it may already be prefixed)
        # The finding_key stored in the block is authoritative; we preserve it as-is per the core contract.
        $entry = $parsed.Clone()
        $entry['finding_key']      = $parsed['finding_key']
        $entry['surface']          = $Surface
        $entry['issueOrPrNumber']  = $IssueOrPrNumber
        $entry['createdAt']        = $createdAt
        $entry['seed']             = [bool]$parsed['seed']
        $entry['apparatus_meta']   = [bool]$parsed['apparatus_meta']

        $results.Add($entry)
    }

    return , $results.ToArray()
}

# -------------------------------------------------------------------------
# Private: load cache from file
# -------------------------------------------------------------------------

function script:Read-PhaseContainmentCache {
    param(
        [Parameter(Mandatory)][string]$CachePath
    )
    try {
        if (-not (Test-Path -LiteralPath $CachePath)) { return $null }
        $raw  = Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop
        $data = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($null -eq $data -or -not $data.ContainsKey('generated_at')) { return $null }

        $isFresh = Test-PhaseContainmentCacheFresh -GeneratedAtUtcString ([string]$data['generated_at'])
        if (-not $isFresh) { return $null }

        return $data
    }
    catch {
        Write-Warning "phase-containment-rolling-history-core: failed to read/parse cache at '$CachePath': $_"
        return $null
    }
}

# -------------------------------------------------------------------------
# Private: write cache to file
# -------------------------------------------------------------------------

function script:Write-PhaseContainmentCache {
    param(
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)][array]$Entries
    )
    try {
        $cacheDir = Split-Path -Parent $CachePath
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        $payload = @{
            generated_at = (Get-Date).ToUniversalTime().ToString('o')
            entries      = $Entries
        }
        $payload | ConvertTo-Json -Depth 20 | Set-Content -Path $CachePath -Encoding UTF8
    }
    catch {
        Write-Warning "phase-containment-rolling-history-core: failed to write cache to '$CachePath': $_"
    }
}

# -------------------------------------------------------------------------
# Private: paginated GraphQL comment fetch for a single issue or PR number
# -------------------------------------------------------------------------

function script:Invoke-GraphQLCommentPageFetch {
    <#
    .SYNOPSIS
        Fetches all comment bodies for a given issue/PR number via paginated GraphQL.
    .OUTPUTS
        [string[]] All comment body strings, or $null on error.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$NodeType,   # 'Issue' or 'PullRequest'
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $bodies  = [System.Collections.Generic.List[string]]::new()
    $cursor  = $null
    $hasNext = $true

    while ($hasNext) {
        if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out fetching comments for $NodeType #$Number"
            return $null
        }

        $afterClause = if ($null -ne $cursor) { ", after: \`"$cursor\`"" } else { '' }
        $query = @"
{
  repository(owner: "$Owner", name: "$Repo") {
    issueOrPullRequest: $($NodeType.ToLower())(number: $Number) {
      ... on $NodeType {
        comments(first: 100$afterClause) {
          nodes { body createdAt }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
"@

        $output = & gh api graphql -f "query=$query" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "phase-containment-rolling-history-core: GraphQL error fetching comments for $NodeType #$Number (exit $LASTEXITCODE)"
            return $null
        }

        try {
            $parsed = ($output | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop

            if ($parsed.ContainsKey('errors') -and $null -ne $parsed['errors'] -and @($parsed['errors']).Count -gt 0) {
                Write-Warning "phase-containment-rolling-history-core: GraphQL returned errors for $NodeType #$Number"
                return $null
            }

            $repo         = $parsed['data']['repository']
            $issueOrPr    = $repo['issueOrPullRequest']
            $commentBlock = $issueOrPr['comments']
            $nodes        = @($commentBlock['nodes'])
            $pageInfo     = $commentBlock['pageInfo']

            foreach ($node in $nodes) {
                if ($null -ne $node -and $null -ne $node['body']) {
                    $bodies.Add([string]$node['body'])
                }
            }

            $hasNext = [bool]$pageInfo['hasNextPage']
            $cursor  = if ($hasNext) { [string]$pageInfo['endCursor'] } else { $null }
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: failed to parse GraphQL response for $NodeType #${Number}: $_"
            return $null
        }
    }

    return , $bodies.ToArray()
}

# -------------------------------------------------------------------------
# Private: collect Surface A entries via GraphQL (issue comments)
# -------------------------------------------------------------------------

function script:Get-SurfaceAEntriesGraphQL {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $entries = [System.Collections.Generic.List[hashtable]]::new()

    # Search for recently-closed issues in the window
    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')
    $query = @"
{
  search(query: "repo:$Owner/$Repo is:issue is:closed closed:>$since", type: ISSUE, first: 50) {
    nodes {
      ... on Issue {
        number
        comments(first: 100) {
          nodes { body createdAt }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
"@

    if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return , $entries.ToArray() }

    $output = & gh api graphql -f "query=$query" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "phase-containment-rolling-history-core: Surface A GraphQL search failed (exit $LASTEXITCODE)"
        return $null   # signal error for fallback
    }

    try {
        $parsed = ($output | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($parsed.ContainsKey('errors') -and $null -ne $parsed['errors'] -and @($parsed['errors']).Count -gt 0) {
            Write-Warning "phase-containment-rolling-history-core: Surface A GraphQL returned errors"
            return $null
        }

        $nodes = @($parsed['data']['search']['nodes'])

        foreach ($issueNode in $nodes) {
            if ($null -eq $issueNode) { continue }
            $issueNum = [int]$issueNode['number']

            # Collect all comment bodies from the initial page
            $commentBodies   = [System.Collections.Generic.List[string]]::new()
            $commentCreatedAt = [System.Collections.Generic.List[string]]::new()

            $commentBlock = $issueNode['comments']
            $commentNodes = @($commentBlock['nodes'])

            foreach ($cn in $commentNodes) {
                if ($null -ne $cn) {
                    $commentBodies.Add([string]$cn['body'])
                    $cnCreatedAt = if ($cn.ContainsKey('createdAt')) { [string]$cn['createdAt'] } else { '' }
                    $commentCreatedAt.Add($cnCreatedAt)
                }
            }

            # Check whether this issue has a design-phase-complete or plan-issue marker
            $allBodiesText = $commentBodies -join "`n"
            $hasMarker = ($allBodiesText -match "<!--\s*design-phase-complete-$issueNum\s*-->") -or
                         ($allBodiesText -match "<!--\s*plan-issue-$issueNum\s*-->")
            if (-not $hasMarker) { continue }

            # Paginate if needed
            $pageInfo = $commentBlock['pageInfo']
            $cursor   = if ([bool]$pageInfo['hasNextPage']) { [string]$pageInfo['endCursor'] } else { $null }

            while ($null -ne $cursor) {
                if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    Write-Warning "phase-containment-rolling-history-core: timed out paginating issue #$issueNum"
                    break
                }

                $pageQuery = @"
{
  repository(owner: "$Owner", name: "$Repo") {
    issue(number: $issueNum) {
      comments(first: 100, after: "$cursor") {
        nodes { body createdAt }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"@
                $pageOutput = & gh api graphql -f "query=$pageQuery" 2>&1
                if ($LASTEXITCODE -ne 0) { break }

                try {
                    $pageParsed = ($pageOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    $pageComments = $pageParsed['data']['repository']['issue']['comments']
                    foreach ($cn in @($pageComments['nodes'])) {
                        if ($null -ne $cn) {
                            $commentBodies.Add([string]$cn['body'])
                            $cnCreatedAt2 = if ($cn.ContainsKey('createdAt')) { [string]$cn['createdAt'] } else { '' }
                            $commentCreatedAt.Add($cnCreatedAt2)
                        }
                    }
                    $pi = $pageComments['pageInfo']
                    $cursor = if ([bool]$pi['hasNextPage']) { [string]$pi['endCursor'] } else { $null }
                }
                catch {
                    Write-Warning "phase-containment-rolling-history-core: failed to parse pagination response for issue #${issueNum}: $_"
                    break
                }
            }

            # Scan all collected bodies
            $scanned = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $commentBodies.ToArray() `
                -IssueOrPrNumber $issueNum `
                -Surface 'issue' `
                -CreatedAtValues $commentCreatedAt.ToArray()

            foreach ($e in $scanned) { $entries.Add($e) }
        }
    }
    catch {
        Write-Warning "phase-containment-rolling-history-core: failed to parse Surface A GraphQL response: $_"
        return $null
    }

    return , $entries.ToArray()
}

# -------------------------------------------------------------------------
# Private: collect Surface B entries via GraphQL (merged PR comments)
# -------------------------------------------------------------------------

function script:Get-SurfaceBEntriesGraphQL {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $entries = [System.Collections.Generic.List[hashtable]]::new()

    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')
    $query = @"
{
  search(query: "repo:$Owner/$Repo is:pr is:merged merged:>$since", type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest {
        number
        comments(first: 100) {
          nodes { body createdAt }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
"@

    if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return , $entries.ToArray() }

    $output = & gh api graphql -f "query=$query" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "phase-containment-rolling-history-core: Surface B GraphQL search failed (exit $LASTEXITCODE)"
        return $null
    }

    try {
        $parsed = ($output | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($parsed.ContainsKey('errors') -and $null -ne $parsed['errors'] -and @($parsed['errors']).Count -gt 0) {
            Write-Warning "phase-containment-rolling-history-core: Surface B GraphQL returned errors"
            return $null
        }

        $nodes = @($parsed['data']['search']['nodes'])

        foreach ($prNode in $nodes) {
            if ($null -eq $prNode) { continue }
            $prNum = [int]$prNode['number']

            $commentBodies   = [System.Collections.Generic.List[string]]::new()
            $commentCreatedAt = [System.Collections.Generic.List[string]]::new()

            $commentBlock = $prNode['comments']
            $commentNodes = @($commentBlock['nodes'])

            foreach ($cn in $commentNodes) {
                if ($null -ne $cn) {
                    $commentBodies.Add([string]$cn['body'])
                    $cnCreatedAtB = if ($cn.ContainsKey('createdAt')) { [string]$cn['createdAt'] } else { '' }
                    $commentCreatedAt.Add($cnCreatedAtB)
                }
            }

            # Check whether this PR has a judge-rulings block (marks review pipeline)
            $allBodiesText = $commentBodies -join "`n"
            $hasJudgeRulings = ($allBodiesText -match '<!--\s*judge-rulings')
            if (-not $hasJudgeRulings) { continue }

            # Paginate if needed
            $pageInfo = $commentBlock['pageInfo']
            $cursor   = if ([bool]$pageInfo['hasNextPage']) { [string]$pageInfo['endCursor'] } else { $null }

            while ($null -ne $cursor) {
                if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    Write-Warning "phase-containment-rolling-history-core: timed out paginating PR #$prNum"
                    break
                }

                $pageQuery = @"
{
  repository(owner: "$Owner", name: "$Repo") {
    pullRequest(number: $prNum) {
      comments(first: 100, after: "$cursor") {
        nodes { body createdAt }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"@
                $pageOutput = & gh api graphql -f "query=$pageQuery" 2>&1
                if ($LASTEXITCODE -ne 0) { break }

                try {
                    $pageParsed = ($pageOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    $pageComments = $pageParsed['data']['repository']['pullRequest']['comments']
                    foreach ($cn in @($pageComments['nodes'])) {
                        if ($null -ne $cn) {
                            $commentBodies.Add([string]$cn['body'])
                            $cnCreatedAtB2 = if ($cn.ContainsKey('createdAt')) { [string]$cn['createdAt'] } else { '' }
                            $commentCreatedAt.Add($cnCreatedAtB2)
                        }
                    }
                    $pi = $pageComments['pageInfo']
                    $cursor = if ([bool]$pi['hasNextPage']) { [string]$pi['endCursor'] } else { $null }
                }
                catch {
                    Write-Warning "phase-containment-rolling-history-core: failed to parse pagination response for PR #${prNum}: $_"
                    break
                }
            }

            $scanned = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $commentBodies.ToArray() `
                -IssueOrPrNumber $prNum `
                -Surface 'pr' `
                -CreatedAtValues $commentCreatedAt.ToArray()

            foreach ($e in $scanned) { $entries.Add($e) }
        }
    }
    catch {
        Write-Warning "phase-containment-rolling-history-core: failed to parse Surface B GraphQL response: $_"
        return $null
    }

    return , $entries.ToArray()
}

# -------------------------------------------------------------------------
# Private: REST fallback — simplified scan via gh CLI
# -------------------------------------------------------------------------

function script:Get-PhaseContainmentEntriesRest {
    param(
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $limit   = 20

    # Surface A: recent closed issues
    if ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $issueListOutput = & gh issue list --state closed --limit $limit --json number 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                $issueList = @(($issueListOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
                foreach ($issue in $issueList) {
                    if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
                    $num = [int]$issue['number']
                    $viewOutput = & gh issue view $num --json comments 2>&1
                    if ($LASTEXITCODE -ne 0) { continue }
                    try {
                        $data     = ($viewOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $comments = @($data['comments'])
                        $bodies   = @($comments | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_['body'] })
                        $scanned  = Invoke-PhaseContainmentCommentScan -CommentBodies $bodies -IssueOrPrNumber $num -Surface 'issue'
                        foreach ($e in $scanned) { $entries.Add($e) }
                    }
                    catch {
                        Write-Warning "phase-containment-rolling-history-core: REST failed to parse issue #$num comments: $_"
                    }
                }
            }
            catch {
                Write-Warning "phase-containment-rolling-history-core: REST issue list parse failed: $_"
            }
        }
    }

    # Surface B: recent merged PRs
    if ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $prListOutput = & gh pr list --state merged --limit $limit --json number 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                $prList = @(($prListOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
                foreach ($pr in $prList) {
                    if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
                    $num = [int]$pr['number']
                    $viewOutput = & gh pr view $num --json comments 2>&1
                    if ($LASTEXITCODE -ne 0) { continue }
                    try {
                        $data     = ($viewOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $comments = @($data['comments'])
                        # Only scan PRs that have judge-rulings
                        $allText  = $comments | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_['body'] }
                        if (-not (($allText -join "`n") -match '<!--\s*judge-rulings')) { continue }
                        $bodies  = @($allText)
                        $scanned = Invoke-PhaseContainmentCommentScan -CommentBodies $bodies -IssueOrPrNumber $num -Surface 'pr'
                        foreach ($e in $scanned) { $entries.Add($e) }
                    }
                    catch {
                        Write-Warning "phase-containment-rolling-history-core: REST failed to parse PR #$num comments: $_"
                    }
                }
            }
            catch {
                Write-Warning "phase-containment-rolling-history-core: REST PR list parse failed: $_"
            }
        }
    }

    return , $entries.ToArray()
}

# -------------------------------------------------------------------------
# Public function: Get-PhaseContainmentHistory
# -------------------------------------------------------------------------

function Get-PhaseContainmentHistory {
    <#
    .SYNOPSIS
        Fetches rolling phase-containment escape-rate history from GitHub.
    .DESCRIPTION
        Walks two surfaces:
          Surface A: Issue comments (design-phase-complete or plan-issue markers)
          Surface B: Merged PR comments (judge-rulings markers)

        Uses 1-hour two-sided cache. Falls back from GraphQL to REST on error.
        On timeout, returns Source: 'timeout' with empty Entries.

    .PARAMETER RepoOwner
        GitHub repository owner (e.g., 'Grimblaz'). Resolved via 'gh repo view' if not supplied.
    .PARAMETER RepoName
        GitHub repository name (e.g., 'agent-orchestra'). Resolved via 'gh repo view' if not supplied.
    .PARAMETER WindowDays
        Number of past days to scan. Default: 90.
    .PARAMETER Token
        GitHub token. Currently unused (gh CLI uses ambient auth). Reserved for future use.
    .PARAMETER CachePath
        Absolute path to the cache file. Defaults to
        $env:TEMP\.phase-containment-cache-{RepoOwner}-{RepoName}.json
    .PARAMETER TimeoutSeconds
        Per-run budget in seconds. Default: 30.
    .OUTPUTS
        PSCustomObject with Entries, FetchedAt, Source, CacheAge.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoOwner    = '',
        [string]$RepoName     = '',
        [int]$WindowDays      = 90,
        [string]$Token        = '',
        [string]$CachePath    = '',
        [int]$TimeoutSeconds  = 30
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ---- Resolve repo owner/name ----
    if (-not $RepoOwner -or -not $RepoName) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before repo resolution"
            return [PSCustomObject]@{
                Entries   = @()
                FetchedAt = (Get-Date)
                Source    = 'timeout'
                CacheAge  = [timespan]::Zero
            }
        }
        $repoViewJson = & gh repo view --json 'owner,name' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "phase-containment-rolling-history-core: gh repo view failed: $repoViewJson"
            return [PSCustomObject]@{
                Entries   = @()
                FetchedAt = (Get-Date)
                Source    = 'rest'
                CacheAge  = [timespan]::Zero
            }
        }
        try {
            $repoInfo  = ($repoViewJson | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if (-not $RepoOwner) { $RepoOwner = [string]$repoInfo['owner']['login'] }
            if (-not $RepoName)  { $RepoName  = [string]$repoInfo['name'] }
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: failed to parse repo view: $_"
            return [PSCustomObject]@{
                Entries   = @()
                FetchedAt = (Get-Date)
                Source    = 'rest'
                CacheAge  = [timespan]::Zero
            }
        }
    }

    # ---- Resolve cache path ----
    if (-not $CachePath) {
        $CachePath = Join-Path $env:TEMP ".phase-containment-cache-$RepoOwner-$RepoName.json"  # host-path-ok
    }

    # ---- Cache hit ----
    $cacheData = script:Read-PhaseContainmentCache -CachePath $CachePath
    if ($null -ne $cacheData) {
        $cachedEntries = @()
        if ($cacheData.ContainsKey('entries') -and $null -ne $cacheData['entries']) {
            $cachedEntries = @($cacheData['entries'])
        }
        # Compute cache age
        try {
            $genAt = [datetime]::Parse([string]$cacheData['generated_at'], $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $genAtUtc = $genAt.Kind -eq [System.DateTimeKind]::Utc ? $genAt : $genAt.ToUniversalTime()
            $cacheAge = (Get-Date).ToUniversalTime() - $genAtUtc
        }
        catch {
            $cacheAge = [timespan]::Zero
        }
        return [PSCustomObject]@{
            Entries   = $cachedEntries
            FetchedAt = (Get-Date)
            Source    = 'cache'
            CacheAge  = $cacheAge
        }
    }

    # ---- GraphQL fetch ----
    $useRest      = $false
    $rawEntries   = [System.Collections.Generic.List[hashtable]]::new()

    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "phase-containment-rolling-history-core: timed out before GraphQL fetch"
        return [PSCustomObject]@{
            Entries   = @()
            FetchedAt = (Get-Date)
            Source    = 'timeout'
            CacheAge  = [timespan]::Zero
        }
    }

    $surfaceAEntries = script:Get-SurfaceAEntriesGraphQL `
        -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
        -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($null -eq $surfaceAEntries) {
        $useRest = $true
    }
    else {
        foreach ($e in $surfaceAEntries) { $rawEntries.Add($e) }
    }

    if (-not $useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before Surface B fetch"
            return [PSCustomObject]@{
                Entries   = @()
                FetchedAt = (Get-Date)
                Source    = 'timeout'
                CacheAge  = [timespan]::Zero
            }
        }

        $surfaceBEntries = script:Get-SurfaceBEntriesGraphQL `
            -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
            -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

        if ($null -eq $surfaceBEntries) {
            $useRest = $true
            $rawEntries.Clear()
        }
        else {
            foreach ($e in $surfaceBEntries) { $rawEntries.Add($e) }
        }
    }

    # ---- REST fallback ----
    $sourceLabel = 'graphql'
    if ($useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before REST fallback"
            return [PSCustomObject]@{
                Entries   = @()
                FetchedAt = (Get-Date)
                Source    = 'timeout'
                CacheAge  = [timespan]::Zero
            }
        }

        $restEntries = script:Get-PhaseContainmentEntriesRest `
            -WindowDays $WindowDays `
            -Stopwatch $stopwatch `
            -TimeoutSeconds $TimeoutSeconds

        $rawEntries.Clear()
        foreach ($e in $restEntries) { $rawEntries.Add($e) }
        $sourceLabel = 'rest'
    }

    # ---- Dedup ----
    $dedupedEntries = Invoke-PhaseContainmentDedup -RawEntries $rawEntries.ToArray()

    # ---- Write cache (only if non-empty) ----
    if ($dedupedEntries.Count -gt 0) {
        script:Write-PhaseContainmentCache -CachePath $CachePath -Entries $dedupedEntries
    }

    return [PSCustomObject]@{
        Entries   = $dedupedEntries
        FetchedAt = (Get-Date)
        Source    = $sourceLabel
        CacheAge  = [timespan]::Zero
    }
}
