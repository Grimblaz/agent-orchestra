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

        $yamlBlocks = Get-PhaseContainmentBlock -Text $body -Id $id
        if ($null -eq $yamlBlocks) { continue }

        foreach ($yamlText in $yamlBlocks) {
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

            # Build the output entry — use the parsed finding_key directly (it may already be prefixed)
            # The finding_key stored in the block is authoritative; we preserve it as-is per the core contract.
            $entry = @{}
            foreach ($parsedKey in $parsed.Keys) { $entry[$parsedKey] = $parsed[$parsedKey] }
            $entry['finding_key']      = $parsed['finding_key']
            $entry['surface']          = $Surface
            $entry['issueOrPrNumber']  = $IssueOrPrNumber
            $entry['createdAt']        = $createdAt
            $entry['seed']             = [bool]$parsed['seed']
            $entry['apparatus_meta']   = [bool]$parsed['apparatus_meta']

            $results.Add($entry)
        }
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
# Private: Surface A discovery+fetch via GraphQL (issue comments)
# Shared seam (#782 M11): returns raw per-number corpus tuples — the same
# discovery predicate (search query shape, marker-presence check, comment
# pagination) that both the existing entry-scanning walker (below) and the
# new phase-containment-emission-check.ps1 sweep (via the public
# Get-PhaseContainmentCommentCorpus wrapper) consume. $null return signals a
# GraphQL-level error so callers fall back to REST.
# -------------------------------------------------------------------------

function script:Get-SurfaceACorpusGraphQL {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    # Each tuple: @{ Number = <int>; Surface = 'issue'; Bodies = <string[]>; CreatedAtValues = <string[]> }
    $tuples = [System.Collections.Generic.List[hashtable]]::new()

    # Search for recently-closed issues in the window
    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    # Outer search pagination: accumulate nodes across all search result pages.
    $searchCursor   = $null
    $searchHasNext  = $true

    try {
        while ($searchHasNext) {
            if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-Warning "phase-containment-rolling-history-core: timed out paginating Surface A search"
                break
            }

            $searchAfterClause = if ($null -ne $searchCursor) { ", after: `"$searchCursor`"" } else { '' }
            $query = @"
{
  search(query: "repo:$Owner/$Repo is:issue is:closed closed:>$since", type: ISSUE, first: 50$searchAfterClause) {
    pageInfo { hasNextPage endCursor }
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

            $output = & gh api graphql -f "query=$query" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "phase-containment-rolling-history-core: Surface A GraphQL search failed (exit $LASTEXITCODE)"
                return $null   # signal error for fallback
            }

            $parsed = ($output | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($parsed.ContainsKey('errors') -and $null -ne $parsed['errors'] -and @($parsed['errors']).Count -gt 0) {
                Write-Warning "phase-containment-rolling-history-core: Surface A GraphQL returned errors"
                return $null
            }

            $searchBlock = $parsed['data']['search']
            $nodes = @($searchBlock['nodes'])

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

                # Paginate comments if needed
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

                # Record the discovered per-number tuple (raw bodies — no scan/parse here).
                $tuples.Add(@{
                    Number           = $issueNum
                    Surface          = 'issue'
                    Bodies           = $commentBodies.ToArray()
                    CreatedAtValues  = $commentCreatedAt.ToArray()
                })
            }

            # Advance the outer search cursor
            $searchPageInfo = $searchBlock['pageInfo']
            $nextCursor     = if ($null -ne $searchPageInfo -and $searchPageInfo.ContainsKey('endCursor')) { [string]$searchPageInfo['endCursor'] } else { '' }
            if ([bool]$searchPageInfo['hasNextPage'] -and -not [string]::IsNullOrEmpty($nextCursor)) {
                $searchCursor  = $nextCursor
                $searchHasNext = $true
            }
            else {
                # hasNextPage with a missing/empty endCursor is a malformed page — stop rather than re-querying after: "" forever
                $searchCursor  = $null
                $searchHasNext = $false
            }
        }
    }
    catch {
        Write-Warning "phase-containment-rolling-history-core: failed to parse Surface A GraphQL response: $_"
        return $null
    }

    return , $tuples.ToArray()
}

# -------------------------------------------------------------------------
# Private: Surface A entries via GraphQL — thin wrapper over the shared
# corpus discovery seam. Preserves the pre-#782 public contract (an array of
# parsed, validated entry hashtables) for Get-PhaseContainmentHistory and its
# existing direct-call Pester coverage.
# -------------------------------------------------------------------------

function script:Get-SurfaceAEntriesGraphQL {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $tuples = script:Get-SurfaceACorpusGraphQL `
        -Owner $Owner -Repo $Repo -WindowDays $WindowDays `
        -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($null -eq $tuples) { return $null }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($tuple in $tuples) {
        # M7 fix (issue #782 post-review): restore per-item isolation. A
        # single malformed tuple (e.g. Number/Bodies/CreatedAtValues that
        # cannot bind to Invoke-PhaseContainmentCommentScan's typed
        # parameters) must degrade that ONE tuple, not abort every other
        # tuple in this loop — the original per-item try/catch this
        # extraction moved away from.
        try {
            $scanned = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues']

            foreach ($e in $scanned) { $entries.Add($e) }
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: Surface A tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return , $entries.ToArray()
}

# -------------------------------------------------------------------------
# Private: Surface B discovery+fetch via GraphQL (merged PR comments)
# Shared seam (#782 M11) — see Get-SurfaceACorpusGraphQL header comment.
# -------------------------------------------------------------------------

function script:Get-SurfaceBCorpusGraphQL {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    # Each tuple: @{ Number = <int>; Surface = 'pr'; Bodies = <string[]>; CreatedAtValues = <string[]> }
    $tuples = [System.Collections.Generic.List[hashtable]]::new()

    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    # Outer search pagination: accumulate nodes across all search result pages.
    $searchCursor   = $null
    $searchHasNext  = $true

    try {
        while ($searchHasNext) {
            if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-Warning "phase-containment-rolling-history-core: timed out paginating Surface B search"
                break
            }

            $searchAfterClause = if ($null -ne $searchCursor) { ", after: `"$searchCursor`"" } else { '' }
            $query = @"
{
  search(query: "repo:$Owner/$Repo is:pr is:merged merged:>$since", type: ISSUE, first: 50$searchAfterClause) {
    pageInfo { hasNextPage endCursor }
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

            $output = & gh api graphql -f "query=$query" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "phase-containment-rolling-history-core: Surface B GraphQL search failed (exit $LASTEXITCODE)"
                return $null
            }

            $parsed = ($output | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($parsed.ContainsKey('errors') -and $null -ne $parsed['errors'] -and @($parsed['errors']).Count -gt 0) {
                Write-Warning "phase-containment-rolling-history-core: Surface B GraphQL returned errors"
                return $null
            }

            $searchBlock = $parsed['data']['search']
            $nodes = @($searchBlock['nodes'])

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

                # Paginate comments if needed
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

                # Record the discovered per-number tuple (raw bodies — no scan/parse here).
                $tuples.Add(@{
                    Number           = $prNum
                    Surface          = 'pr'
                    Bodies           = $commentBodies.ToArray()
                    CreatedAtValues  = $commentCreatedAt.ToArray()
                })
            }

            # Advance the outer search cursor
            $searchPageInfo = $searchBlock['pageInfo']
            $nextCursor     = if ($null -ne $searchPageInfo -and $searchPageInfo.ContainsKey('endCursor')) { [string]$searchPageInfo['endCursor'] } else { '' }
            if ([bool]$searchPageInfo['hasNextPage'] -and -not [string]::IsNullOrEmpty($nextCursor)) {
                $searchCursor  = $nextCursor
                $searchHasNext = $true
            }
            else {
                # hasNextPage with a missing/empty endCursor is a malformed page — stop rather than re-querying after: "" forever
                $searchCursor  = $null
                $searchHasNext = $false
            }
        }
    }
    catch {
        Write-Warning "phase-containment-rolling-history-core: failed to parse Surface B GraphQL response: $_"
        return $null
    }

    return , $tuples.ToArray()
}

# -------------------------------------------------------------------------
# Private: Surface B entries via GraphQL — thin wrapper over the shared
# corpus discovery seam. Preserves the pre-#782 public contract (an array of
# parsed, validated entry hashtables) for Get-PhaseContainmentHistory and its
# existing direct-call Pester coverage.
# -------------------------------------------------------------------------

function script:Get-SurfaceBEntriesGraphQL {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $tuples = script:Get-SurfaceBCorpusGraphQL `
        -Owner $Owner -Repo $Repo -WindowDays $WindowDays `
        -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($null -eq $tuples) { return $null }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($tuple in $tuples) {
        # M7 fix (issue #782 post-review): see Get-SurfaceAEntriesGraphQL's
        # identical per-item try/catch for the rationale.
        try {
            $scanned = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues']

            foreach ($e in $scanned) { $entries.Add($e) }
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: Surface B tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return , $entries.ToArray()
}

# -------------------------------------------------------------------------
# Private: REST fallback discovery+fetch — simplified corpus scan via gh CLI.
# Shared seam (#782 M11) — see Get-SurfaceACorpusGraphQL header comment.
# -------------------------------------------------------------------------

function script:Get-PhaseContainmentCorpusRest {
    param(
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    # Each tuple: @{ Number = <int>; Surface = 'issue'|'pr'; Bodies = <string[]>; CreatedAtValues = <string[]> }
    $tuples = [System.Collections.Generic.List[hashtable]]::new()
    $limit  = 20

    # GH-8 fix (issue #782 GitHub-review response loop, PR #789): compute
    # $since from $WindowDays the same way the GraphQL path does
    # (Get-SurfaceACorpusGraphQL / Get-SurfaceBCorpusGraphQL), so the REST
    # fallback is genuinely window-scoped rather than accepting -WindowDays
    # and silently dropping it.
    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    # Surface A: recent closed issues
    if ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $issueListOutput = & gh issue list --state closed --search "closed:>$since" --limit $limit --json number 2>&1
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
                        # GH-8 fix: apply the same marker-presence gate the
                        # GraphQL path uses (Get-SurfaceACorpusGraphQL) before
                        # including this issue's tuple in the returned
                        # corpus. Without this, the REST fallback included
                        # every closed issue's comments unconditionally,
                        # unlike the GraphQL path which only includes issues
                        # carrying a design-phase-complete-{N} or
                        # plan-issue-{N} marker.
                        $allBodiesText = $bodies -join "`n"
                        $hasMarker = ($allBodiesText -match "<!--\s*design-phase-complete-$num\s*-->") -or
                                     ($allBodiesText -match "<!--\s*plan-issue-$num\s*-->")
                        if (-not $hasMarker) { continue }
                        $tuples.Add(@{ Number = $num; Surface = 'issue'; Bodies = $bodies; CreatedAtValues = @() })
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
        $prListOutput = & gh pr list --state merged --search "merged:>$since" --limit $limit --json number 2>&1
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
                        $bodies = @($allText)
                        $tuples.Add(@{ Number = $num; Surface = 'pr'; Bodies = $bodies; CreatedAtValues = @() })
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

    return , $tuples.ToArray()
}

# -------------------------------------------------------------------------
# Private: REST fallback entries — thin wrapper over the shared corpus
# discovery seam. Preserves the pre-#782 public contract (an array of
# parsed, validated entry hashtables) for Get-PhaseContainmentHistory.
# -------------------------------------------------------------------------

function script:Get-PhaseContainmentEntriesRest {
    param(
        [Parameter(Mandatory)][int]$WindowDays,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $tuples = script:Get-PhaseContainmentCorpusRest `
        -WindowDays $WindowDays -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($tuple in $tuples) {
        # M7 fix (issue #782 post-review): see Get-SurfaceAEntriesGraphQL's
        # identical per-item try/catch for the rationale.
        try {
            $scanned = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues']

            foreach ($e in $scanned) { $entries.Add($e) }
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: REST tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return , $entries.ToArray()
}

# -------------------------------------------------------------------------
# Public function: Get-PhaseContainmentCommentCorpus
# Shared discovery seam (#782 M11): surface-discovery + raw-comment-body
# fetch, consumed by BOTH Get-PhaseContainmentHistory (via the Entries
# wrappers above) and the phase-containment-emission-check.ps1 sweep, so
# #772's pagination/marker-presence hardening lands in one place instead of
# diverging across two copies.
# -------------------------------------------------------------------------

function Get-PhaseContainmentCommentCorpus {
    <#
    .SYNOPSIS
        Discovers phase-containment-relevant issues/PRs and returns their raw
        comment bodies, without parsing or validating phase-containment blocks.
    .DESCRIPTION
        Walks the same two surfaces as Get-PhaseContainmentHistory:
          Surface A: issue comments (design-phase-complete-{N} or plan-issue-{N} markers)
          Surface B: merged PR comments (judge-rulings markers)

        Unlike Get-PhaseContainmentHistory, this function performs NO block
        parsing/validation — it returns the raw per-surface tuples that
        callers doing their own analysis (e.g. the emission-check sweep's
        sustained-vs-block gap counting) need. Get-PhaseContainmentHistory's
        Entries output remains the validated, parsed phase-containment-block
        view; this function is the shared discovery/fetch layer beneath it.

        Falls back from GraphQL to REST on error, matching
        Get-PhaseContainmentHistory's fallback behavior. Does not use the
        1-hour cache (that cache stores parsed Entries, not raw bodies).

        M12 note (issue #782 post-review, informational only — no behavior
        change): under the REST fallback path (Source = 'rest'), every
        tuple's CreatedAtValues is always an empty array. The REST discovery
        helper (script:Get-PhaseContainmentCorpusRest) uses `gh issue/pr
        view --json comments`, whose comment objects do not carry a
        createdAt field the way the GraphQL path's `comments(first: 100) {
        nodes { body createdAt } }` query does, so REST-sourced tuples
        cannot populate per-comment timestamps. Callers that rely on
        CreatedAtValues (e.g. Invoke-PhaseContainmentDedup's latest-wins
        comparison) degrade gracefully under REST (empty string per entry),
        but should not expect real timestamps when Source = 'rest'.
    .PARAMETER RepoOwner
        GitHub repository owner (e.g., 'Grimblaz'). Resolved via 'gh repo view' if not supplied.
    .PARAMETER RepoName
        GitHub repository name (e.g., 'agent-orchestra'). Resolved via 'gh repo view' if not supplied.
    .PARAMETER WindowDays
        Number of past days to scan. Default: 90.
    .PARAMETER Token
        GitHub token. Currently unused (gh CLI uses ambient auth). Reserved for future use.
    .PARAMETER TimeoutSeconds
        Per-run budget in seconds. Default: 30.
    .OUTPUTS
        [PSCustomObject] with:
          Tuples    [array]  — each entry: @{ Number; Surface ('issue'|'pr'); Bodies [string[]]; CreatedAtValues [string[]] }
          FetchedAt [datetime]
          Source    [string] — 'graphql' | 'rest' | 'timeout' | 'repo-resolution-failed'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoOwner    = '',
        [string]$RepoName     = '',
        [int]$WindowDays      = 90,
        [string]$Token        = '',
        [int]$TimeoutSeconds  = 30
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ---- Resolve repo owner/name ----
    if (-not $RepoOwner -or -not $RepoName) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before repo resolution"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout' }
        }
        $repoViewJson = & gh repo view --json 'owner,name' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "phase-containment-rolling-history-core: gh repo view failed: $repoViewJson"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'repo-resolution-failed' }
        }
        try {
            $repoInfo = ($repoViewJson | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if (-not $RepoOwner) { $RepoOwner = [string]$repoInfo['owner']['login'] }
            if (-not $RepoName)  { $RepoName  = [string]$repoInfo['name'] }
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: failed to parse repo view: $_"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'repo-resolution-failed' }
        }
    }

    # ---- GraphQL fetch ----
    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "phase-containment-rolling-history-core: timed out before corpus GraphQL fetch"
        return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout' }
    }

    $useRest = $false
    $allTuples = [System.Collections.Generic.List[hashtable]]::new()

    $surfaceATuples = script:Get-SurfaceACorpusGraphQL `
        -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
        -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($null -eq $surfaceATuples) {
        $useRest = $true
    }
    else {
        foreach ($t in $surfaceATuples) { $allTuples.Add($t) }
    }

    if (-not $useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before corpus Surface B fetch"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout' }
        }

        $surfaceBTuples = script:Get-SurfaceBCorpusGraphQL `
            -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
            -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

        if ($null -eq $surfaceBTuples) {
            $useRest = $true
            $allTuples.Clear()
        }
        else {
            foreach ($t in $surfaceBTuples) { $allTuples.Add($t) }
        }
    }

    # ---- REST fallback ----
    $sourceLabel = 'graphql'
    if ($useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before corpus REST fallback"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout' }
        }

        $restTuples = script:Get-PhaseContainmentCorpusRest `
            -WindowDays $WindowDays -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

        $allTuples.Clear()
        foreach ($t in $restTuples) { $allTuples.Add($t) }
        $sourceLabel = 'rest'
    }

    return [PSCustomObject]@{
        Tuples    = $allTuples.ToArray()
        FetchedAt = (Get-Date)
        Source    = $sourceLabel
    }
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
                Source    = 'repo-resolution-failed'
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
                Source    = 'repo-resolution-failed'
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

# -------------------------------------------------------------------------
# Public function: Get-PhaseContainmentRollup
# -------------------------------------------------------------------------

function Get-PhaseContainmentRollup {
    <#
    .SYNOPSIS
        Aggregates phase-containment entries into per-stage escape/irreducible rates
        with statistical guards.
    .DESCRIPTION
        Takes the deduped entry list from Get-PhaseContainmentHistory.Entries and
        produces per-stage escape/irreducible rates with:
          - InsufficientData guard (N < 5, using cost-anomaly n<5 convention)
          - DenominatorZero guard
          - RelaxationEligible signal (requires N>=5, IrreducibleRate~0, no critical severity)
          - DataUntrustworthy flag (when SustainedCounts completeness reconciliation fails)
          - LeakageMatrix (introduced_phase x caught_stage counts)

        Denominator mapping (experience-catchable entries are observation-only):
          design-challenge  : catchable_phase == 'design'
          plan-stress-test  : catchable_phase == 'plan'
          code-review       : catchable_phase == 'implementation'

        apparatus_meta: true entries are excluded from N and Denominator counts
        but counted in ApparatusMetaCount and LeakageMatrix.
    .PARAMETER Entries
        Array of PSCustomObject (or hashtable) entries from Get-PhaseContainmentHistory.Entries.
        Already deduped by finding_key.
    .PARAMETER SustainedCounts
        Optional hashtable @{ 'design-challenge'=N; 'plan-stress-test'=N; 'code-review'=N }
        specifying expected count of sustained (non-apparatus_meta) findings per surface.
        When provided, actual count mismatch marks DataUntrustworthy=$true for that stage.
    .PARAMETER WindowLabel
        Optional label for the window (for display purposes only).
    .OUTPUTS
        PSCustomObject with Stages, LeakageMatrix, LeakageMatrixByFixType,
        ApparatusMetaCount, WindowEntryCount.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,
        [hashtable]$SustainedCounts = $null,
        [string]$WindowLabel = ''
    )

    # Stage → catchable_phase mapping
    $stageToCatchablePhase = @{
        'design-challenge' = 'design'
        'plan-stress-test' = 'plan'
        'code-review'      = 'implementation'
    }

    # Initialize per-stage accumulators
    # Each entry: @{ NonApparatus = List; Apparatus = List }
    $stageEntries = @{}
    foreach ($stage in $stageToCatchablePhase.Keys) {
        $stageEntries[$stage] = @{
            NonApparatus = [System.Collections.Generic.List[object]]::new()
            Apparatus    = [System.Collections.Generic.List[object]]::new()
        }
    }

    # Leakage matrix: introduced_phase x caught_stage counts
    $leakageMatrix = @{}
    # Leakage matrix by fix type
    $leakageMatrixByFixType = @{}

    $apparatusMetaTotal = 0
    $windowEntryCount   = $Entries.Count

    foreach ($entry in $Entries) {
        # Normalize field access for both hashtable and PSCustomObject
        $catchablePhase  = if ($entry -is [hashtable]) { [string]$entry['catchable_phase']  } else { [string]$entry.catchable_phase  }
        $introducedPhase = if ($entry -is [hashtable]) { [string]$entry['introduced_phase'] } else { [string]$entry.introduced_phase }
        $caughtStage     = if ($entry -is [hashtable]) { [string]$entry['caught_stage']     } else { [string]$entry.caught_stage     }
        $apparatusMeta   = if ($entry -is [hashtable]) { [bool]$entry['apparatus_meta']     } else { [bool]$entry.apparatus_meta     }
        $fixType         = if ($entry -is [hashtable]) { [string]$entry['systemic_fix_type'] } else { [string]$entry.systemic_fix_type }

        # Leakage matrix — all entries including apparatus_meta
        $matrixKey = "${introducedPhase}×${caughtStage}"
        if (-not $leakageMatrix.ContainsKey($matrixKey)) {
            $leakageMatrix[$matrixKey] = 0
        }
        $leakageMatrix[$matrixKey]++

        # Leakage matrix by fix type
        if (-not $leakageMatrixByFixType.ContainsKey($fixType)) {
            $leakageMatrixByFixType[$fixType] = @{}
        }
        if (-not $leakageMatrixByFixType[$fixType].ContainsKey($matrixKey)) {
            $leakageMatrixByFixType[$fixType][$matrixKey] = 0
        }
        $leakageMatrixByFixType[$fixType][$matrixKey]++

        if ($apparatusMeta) {
            $apparatusMetaTotal++
        }

        # Route to the correct stage bucket based on catchable_phase
        foreach ($stage in $stageToCatchablePhase.Keys) {
            if ($catchablePhase -eq $stageToCatchablePhase[$stage]) {
                if ($apparatusMeta) {
                    $stageEntries[$stage].Apparatus.Add($entry)
                }
                else {
                    $stageEntries[$stage].NonApparatus.Add($entry)
                }
                break
            }
        }
        # experience-catchable entries fall through to leakage matrix only (no stage bucket)
    }

    # Build per-stage results
    $stages = @{}
    foreach ($stage in $stageToCatchablePhase.Keys) {
        $nonApparatusEntries = @($stageEntries[$stage].NonApparatus)
        $n           = $nonApparatusEntries.Count
        $denominator = $n   # Denominator == N (entries with this catchable_phase, excluding apparatus_meta)

        $denominatorZero   = ($denominator -eq 0)
        $insufficientData  = $denominatorZero -or ($n -lt 5)

        # Completeness reconciliation (fail-closed, P14)
        $dataUntrustworthy       = $false
        $dataUntrustworthyReason = $null
        if ($null -ne $SustainedCounts -and $SustainedCounts.ContainsKey($stage)) {
            $expectedCount = [int]$SustainedCounts[$stage]
            if ($n -ne $expectedCount) {
                $dataUntrustworthy       = $true
                $dataUntrustworthyReason = "Entry count mismatch: expected $expectedCount sustained findings for '$stage', observed $n."
            }
        }

        $escapeRate      = $null
        $irreducibleRate = $null

        if (-not $denominatorZero -and -not $insufficientData) {
            # Count escapes (escape_distance > 0) and irreducibles (escape_distance == 0)
            $escapeCount      = 0
            $irreducibleCount = 0
            foreach ($e in $nonApparatusEntries) {
                $dist = if ($e -is [hashtable]) { [int]$e['escape_distance'] } else { [int]$e.escape_distance }
                if ($dist -gt 0) { $escapeCount++ }
                else             { $irreducibleCount++ }
            }
            $escapeRate      = [double]$escapeCount      / [double]$denominator
            $irreducibleRate = [double]$irreducibleCount / [double]$denominator
        }

        # Relaxation eligibility
        $relaxationEligible = $null
        if (-not $insufficientData -and -not $denominatorZero -and -not $dataUntrustworthy) {
            # Relaxation-eligible when escape_rate < 0.05 (effectively zero escapes) and no
            # critical-severity finding in the window. See #762 design notes for the threshold rationale.

            $hasCritical = $false
            foreach ($e in $nonApparatusEntries) {
                $sev = if ($e -is [hashtable]) { [string]$e['severity'] } else { [string]$e.severity }
                if ($sev -eq 'critical') {
                    $hasCritical = $true
                    break
                }
            }

            if ($null -ne $escapeRate -and $escapeRate -lt 0.05 -and -not $hasCritical) {
                $relaxationEligible = $true
            }
            else {
                $relaxationEligible = $false
            }
        }

        $stages[$stage] = [PSCustomObject]@{
            Stage                    = $stage
            N                        = $n
            Denominator              = $denominator
            DenominatorZero          = $denominatorZero
            EscapeRate               = $escapeRate
            IrreducibleRate          = $irreducibleRate
            InsufficientData         = $insufficientData
            RelaxationEligible       = $relaxationEligible
            DataUntrustworthy        = $dataUntrustworthy
            DataUntrustworthyReason  = $dataUntrustworthyReason
        }
    }

    return [PSCustomObject]@{
        Stages                  = $stages
        LeakageMatrix           = $leakageMatrix
        LeakageMatrixByFixType  = $leakageMatrixByFixType
        ApparatusMetaCount      = $apparatusMetaTotal
        WindowEntryCount        = $windowEntryCount
    }
}
