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
        warning and are skipped. Returns a carrier object with the parsed
        entry hashtables plus a count of every dropped block (issue #772
        D1/P8 — both the parse-failure drop and every validation-failure
        drop, Rules 1-12, count toward InvalidEntryCount, not just Rule 12).
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
        [PSCustomObject] with:
          Entries           [array] — parsed, validated entry hashtables with appended metadata.
          InvalidEntryCount [int]   — count of blocks dropped (parse failure + every validation failure).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CommentBodies,
        [Parameter(Mandatory)][int]$IssueOrPrNumber,
        [string]$Surface = 'unknown',
        [AllowEmptyCollection()][string[]]$CreatedAtValues = @()
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()
    $id      = [string]$IssueOrPrNumber
    $invalidEntryCount = 0

    for ($i = 0; $i -lt $CommentBodies.Count; $i++) {
        $body = $CommentBodies[$i]
        $createdAt = if ($i -lt $CreatedAtValues.Count) { $CreatedAtValues[$i] } else { '' }

        $yamlBlocks = Get-PhaseContainmentBlock -Text $body -Id $id
        if ($null -eq $yamlBlocks) { continue }

        foreach ($yamlText in $yamlBlocks) {
            $parsed = ConvertFrom-PhaseContainmentYaml -Yaml $yamlText
            if ($null -eq $parsed) {
                Write-Warning "phase-containment-rolling-history-core: failed to parse block in comment $i for ID $id"
                $invalidEntryCount++
                continue
            }

            $validation = Test-PhaseContainmentEntry -Entry $parsed
            if (-not $validation.IsValid) {
                Write-Warning "phase-containment-rolling-history-core: invalid phase-containment block in comment $i for ID $id — $($validation.Errors -join '; ')"
                $invalidEntryCount++
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

    return [PSCustomObject]@{
        Entries           = $results.ToArray()
        InvalidEntryCount = $invalidEntryCount
    }
}

# -------------------------------------------------------------------------
# Private: normalize a cache-payload timestamp field back to a round-
# trippable ISO 8601 string.
#
# Bug fix (discovered while implementing #772 P7 cache-survival coverage):
# ConvertFrom-Json -AsHashtable auto-parses an ISO-8601-looking JSON string
# value (like the cache's `generated_at`) into a [datetime] with the correct
# Kind (Utc, for a 'Z'-suffixed literal). A naive [string] cast on THAT
# [datetime] uses the current-culture default format, which drops both the
# Kind marker and the timezone offset (e.g. "2026-07-10T15:11:00Z" becomes
# "07/10/2026 15:11:00"). Re-parsing that lossy string with
# DateTimeStyles.RoundtripKind then yields Kind=Unspecified, and every
# downstream `.ToUniversalTime()` call silently misinterprets it as LOCAL
# time — corrupting the value by the local UTC offset. On a non-UTC machine
# this makes a freshly-written cache read back as "future-dated" (or wildly
# stale, depending on offset direction) and rejected every time, silently
# defeating the entire 1-hour cache. Formatting an already-parsed [datetime]
# with the 'o' (round-trip) specifier preserves Kind/offset through the
# string round-trip.
# -------------------------------------------------------------------------

function script:ConvertTo-PhaseContainmentIsoString {
    param([AllowNull()]$Value)
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    return [string]$Value
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

        $isFresh = Test-PhaseContainmentCacheFresh -GeneratedAtUtcString (script:ConvertTo-PhaseContainmentIsoString -Value $data['generated_at'])
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
        [Parameter(Mandatory)][array]$Entries,
        [int]$InvalidEntryCount = 0
    )
    try {
        $cacheDir = Split-Path -Parent $CachePath
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        $payload = @{
            generated_at        = (Get-Date).ToUniversalTime().ToString('o')
            entries             = $Entries
            invalid_entry_count = $InvalidEntryCount
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
    $truncated = $false

    # Search for recently-closed issues in the window
    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    # Outer search pagination: accumulate nodes across all search result pages.
    $searchCursor   = $null
    $searchHasNext  = $true

    try {
        while ($searchHasNext) {
            if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-Warning "phase-containment-rolling-history-core: timed out paginating Surface A search"
                $truncated = $true
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

            # PF2-F2 fix (issue #782 post-fix prosecution pass): use 2>$null,
            # not 2>&1. Merging stderr into the stream later piped to
            # ConvertFrom-Json means a benign gh notice (deprecation/auth/
            # rate-limit) corrupts the JSON parse and silently false-aborts
            # this surface. Same vulnerability class GH-7 fixed in
            # phase-containment-emission-check.ps1 gh view calls; the GH-7
            # fix comment claimed this file already used this convention --
            # that claim was false at the time, and this line is one of the
            # sites that made it false.
            $output = & gh api graphql -f "query=$query" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "phase-containment-rolling-history-core: Surface A GraphQL search failed (exit $LASTEXITCODE)"
                return [PSCustomObject]@{ Tuples = @(); Truncated = $false; IsError = $true }   # signal error for fallback
            }

            $parsed = ($output | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($parsed.ContainsKey('errors') -and $null -ne $parsed['errors'] -and @($parsed['errors']).Count -gt 0) {
                Write-Warning "phase-containment-rolling-history-core: Surface A GraphQL returned errors"
                return [PSCustomObject]@{ Tuples = @(); Truncated = $false; IsError = $true }
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

                $pageInfo = $commentBlock['pageInfo']
                $cursor   = if ([bool]$pageInfo['hasNextPage']) { [string]$pageInfo['endCursor'] } else { $null }

                if (-not $hasMarker) {
                    # #772 D2: capped incremental marker hunt. Page 1 carried
                    # no marker — keep paginating up to K=5 ADDITIONAL pages
                    # (6 total incl. page 1), re-checking the marker over the
                    # accumulated bodies after each hunted page. As soon as
                    # the marker is found, stop hunting and fall through to
                    # the UNBOUNDED pagination below (P6 — the K=5 cap bounds
                    # only the markerless search, never post-find block
                    # collection; a phase-containment-{N} block can sit on
                    # any later page).
                    $huntPagesUsed = 0
                    $maxHuntPages  = 5
                    $huntTimedOut  = $false
                    $huntFailed    = $false

                    while (-not $hasMarker -and $huntPagesUsed -lt $maxHuntPages -and $null -ne $cursor) {
                        if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                            Write-Warning "phase-containment-rolling-history-core: timed out mid-hunt for issue #$issueNum"
                            $huntTimedOut = $true
                            break
                        }

                        $huntQuery = @"
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
                        # PF2-F2 fix: see the Surface A search-page call above
                        # for the same stderr/ConvertFrom-Json rationale.
                        $huntOutput = & gh api graphql -f "query=$huntQuery" 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            $huntFailed = $true
                            break
                        }

                        try {
                            $huntParsed   = ($huntOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                            $huntComments = $huntParsed['data']['repository']['issue']['comments']
                            foreach ($cn in @($huntComments['nodes'])) {
                                if ($null -ne $cn) {
                                    $commentBodies.Add([string]$cn['body'])
                                    $cnCreatedAtHunt = if ($cn.ContainsKey('createdAt')) { [string]$cn['createdAt'] } else { '' }
                                    $commentCreatedAt.Add($cnCreatedAtHunt)
                                }
                            }
                            $huntPi = $huntComments['pageInfo']
                            $cursor = if ([bool]$huntPi['hasNextPage']) { [string]$huntPi['endCursor'] } else { $null }
                        }
                        catch {
                            Write-Warning "phase-containment-rolling-history-core: failed to parse hunt pagination response for issue #${issueNum}: $_"
                            $huntFailed = $true
                            break
                        }

                        $huntPagesUsed++
                        $allBodiesText = $commentBodies -join "`n"
                        $hasMarker = ($allBodiesText -match "<!--\s*design-phase-complete-$issueNum\s*-->") -or
                                     ($allBodiesText -match "<!--\s*plan-issue-$issueNum\s*-->")
                    }

                    if (-not $hasMarker) {
                        # Possible-undercount signal (M6): a mid-hunt timeout,
                        # a hunt-page fetch/parse failure, or exhausting the
                        # K=5 cap while more pages remained unfetched. Natural
                        # exhaustion — the thread ran out of pages within the
                        # cap (or had none to begin with) — is NOT a
                        # truncation; there was nothing left to fetch, so the
                        # drop is a correct exclusion, not a degradation.
                        if ($huntTimedOut -or $huntFailed -or ($huntPagesUsed -ge $maxHuntPages -and $null -ne $cursor)) {
                            Write-Warning "phase-containment-rolling-history-core: capped marker hunt exhausted without a marker for issue #$issueNum — possible undercount"
                            $truncated = $true
                        }
                        continue
                    }
                }

                # Marker found (page 1 or via the capped hunt above) — resume
                # UNBOUNDED pagination to collect all remaining comment pages
                # (#772 P6): a phase-containment-{N} block can sit on any
                # page, not just near the marker, so the K=5 cap governs only
                # the markerless search above, never this collection pass.
                while ($null -ne $cursor) {
                    if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        Write-Warning "phase-containment-rolling-history-core: timed out paginating issue #$issueNum"
                        $truncated = $true
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
                    # PF2-F2 fix: see the Surface A search-page call above for
                    # the same stderr/ConvertFrom-Json rationale.
                    $pageOutput = & gh api graphql -f "query=$pageQuery" 2>$null
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
        return [PSCustomObject]@{ Tuples = @(); Truncated = $false; IsError = $true }
    }

    return [PSCustomObject]@{ Tuples = $tuples.ToArray(); Truncated = $truncated; IsError = $false }
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

    $corpusResult = script:Get-SurfaceACorpusGraphQL `
        -Owner $Owner -Repo $Repo -WindowDays $WindowDays `
        -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($corpusResult.IsError) {
        return [PSCustomObject]@{ Entries = @(); Truncated = $false; InvalidEntryCount = 0; IsError = $true }
    }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $invalidEntryCount = 0
    foreach ($tuple in $corpusResult.Tuples) {
        # M7 fix (issue #782 post-review): restore per-item isolation. A
        # single malformed tuple (e.g. Number/Bodies/CreatedAtValues that
        # cannot bind to Invoke-PhaseContainmentCommentScan's typed
        # parameters) must degrade that ONE tuple, not abort every other
        # tuple in this loop — the original per-item try/catch this
        # extraction moved away from.
        try {
            $scanResult = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues']

            foreach ($e in $scanResult.Entries) { $entries.Add($e) }
            $invalidEntryCount += $scanResult.InvalidEntryCount
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: Surface A tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return [PSCustomObject]@{
        Entries           = $entries.ToArray()
        Truncated         = $corpusResult.Truncated
        InvalidEntryCount = $invalidEntryCount
        IsError           = $false
    }
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
    $truncated = $false

    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    # Outer search pagination: accumulate nodes across all search result pages.
    $searchCursor   = $null
    $searchHasNext  = $true

    try {
        while ($searchHasNext) {
            if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Write-Warning "phase-containment-rolling-history-core: timed out paginating Surface B search"
                $truncated = $true
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

            # PF2-F2 fix: see Get-SurfaceACorpusGraphQL identical stderr/
            # ConvertFrom-Json rationale.
            $output = & gh api graphql -f "query=$query" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "phase-containment-rolling-history-core: Surface B GraphQL search failed (exit $LASTEXITCODE)"
                return [PSCustomObject]@{ Tuples = @(); Truncated = $false; IsError = $true }
            }

            $parsed = ($output | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($parsed.ContainsKey('errors') -and $null -ne $parsed['errors'] -and @($parsed['errors']).Count -gt 0) {
                Write-Warning "phase-containment-rolling-history-core: Surface B GraphQL returned errors"
                return [PSCustomObject]@{ Tuples = @(); Truncated = $false; IsError = $true }
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

                $pageInfo = $commentBlock['pageInfo']
                $cursor   = if ([bool]$pageInfo['hasNextPage']) { [string]$pageInfo['endCursor'] } else { $null }

                if (-not $hasJudgeRulings) {
                    # #772 D2: capped incremental marker hunt (Surface B
                    # mirror of the Surface A hunt above — see its comments
                    # for the full rationale). Page 1 carried no
                    # judge-rulings marker — keep paginating up to K=5
                    # ADDITIONAL pages, re-checking the marker after each
                    # hunted page. Found → fall through to UNBOUNDED
                    # pagination below (P6). Cap exhausted with more pages
                    # remaining, or a mid-hunt timeout/failure → drop + flag
                    # (M6). Natural exhaustion within the cap is not a
                    # truncation.
                    $huntPagesUsed = 0
                    $maxHuntPages  = 5
                    $huntTimedOut  = $false
                    $huntFailed    = $false

                    while (-not $hasJudgeRulings -and $huntPagesUsed -lt $maxHuntPages -and $null -ne $cursor) {
                        if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                            Write-Warning "phase-containment-rolling-history-core: timed out mid-hunt for PR #$prNum"
                            $huntTimedOut = $true
                            break
                        }

                        $huntQuery = @"
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
                        # PF2-F2 fix: see the Surface A search-page call for
                        # the same stderr/ConvertFrom-Json rationale.
                        $huntOutput = & gh api graphql -f "query=$huntQuery" 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            $huntFailed = $true
                            break
                        }

                        try {
                            $huntParsed   = ($huntOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                            $huntComments = $huntParsed['data']['repository']['pullRequest']['comments']
                            foreach ($cn in @($huntComments['nodes'])) {
                                if ($null -ne $cn) {
                                    $commentBodies.Add([string]$cn['body'])
                                    $cnCreatedAtBHunt = if ($cn.ContainsKey('createdAt')) { [string]$cn['createdAt'] } else { '' }
                                    $commentCreatedAt.Add($cnCreatedAtBHunt)
                                }
                            }
                            $huntPi = $huntComments['pageInfo']
                            $cursor = if ([bool]$huntPi['hasNextPage']) { [string]$huntPi['endCursor'] } else { $null }
                        }
                        catch {
                            Write-Warning "phase-containment-rolling-history-core: failed to parse hunt pagination response for PR #${prNum}: $_"
                            $huntFailed = $true
                            break
                        }

                        $huntPagesUsed++
                        $allBodiesText = $commentBodies -join "`n"
                        $hasJudgeRulings = ($allBodiesText -match '<!--\s*judge-rulings')
                    }

                    if (-not $hasJudgeRulings) {
                        # Possible-undercount signal (M6) — see the Surface A
                        # hunt's identical rationale. Natural exhaustion
                        # within the cap is not a truncation.
                        if ($huntTimedOut -or $huntFailed -or ($huntPagesUsed -ge $maxHuntPages -and $null -ne $cursor)) {
                            Write-Warning "phase-containment-rolling-history-core: capped marker hunt exhausted without a marker for PR #$prNum — possible undercount"
                            $truncated = $true
                        }
                        continue
                    }
                }

                # Marker found (page 1 or via the capped hunt above) — resume
                # UNBOUNDED pagination to collect all remaining comment pages
                # (#772 P6) — see the Surface A rationale above.
                while ($null -ne $cursor) {
                    if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        Write-Warning "phase-containment-rolling-history-core: timed out paginating PR #$prNum"
                        $truncated = $true
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
                    # PF2-F2 fix: see the Surface A search-page call for the
                    # same stderr/ConvertFrom-Json rationale.
                    $pageOutput = & gh api graphql -f "query=$pageQuery" 2>$null
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
        return [PSCustomObject]@{ Tuples = @(); Truncated = $false; IsError = $true }
    }

    return [PSCustomObject]@{ Tuples = $tuples.ToArray(); Truncated = $truncated; IsError = $false }
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

    $corpusResult = script:Get-SurfaceBCorpusGraphQL `
        -Owner $Owner -Repo $Repo -WindowDays $WindowDays `
        -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($corpusResult.IsError) {
        return [PSCustomObject]@{ Entries = @(); Truncated = $false; InvalidEntryCount = 0; IsError = $true }
    }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $invalidEntryCount = 0
    foreach ($tuple in $corpusResult.Tuples) {
        # M7 fix (issue #782 post-review): see Get-SurfaceAEntriesGraphQL's
        # identical per-item try/catch for the rationale.
        try {
            $scanResult = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues']

            foreach ($e in $scanResult.Entries) { $entries.Add($e) }
            $invalidEntryCount += $scanResult.InvalidEntryCount
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: Surface B tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return [PSCustomObject]@{
        Entries           = $entries.ToArray()
        Truncated         = $corpusResult.Truncated
        InvalidEntryCount = $invalidEntryCount
        IsError           = $false
    }
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
    $truncated = $false

    # GH-8 fix (issue #782 GitHub-review response loop, PR #789): compute
    # $since from $WindowDays the same way the GraphQL path does
    # (Get-SurfaceACorpusGraphQL / Get-SurfaceBCorpusGraphQL), so the REST
    # fallback is genuinely window-scoped rather than accepting -WindowDays
    # and silently dropping it.
    $since = (Get-Date).ToUniversalTime().AddDays(-$WindowDays).ToString('yyyy-MM-dd')

    # Surface A: recent closed issues
    if ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        # PF2-F2 fix: see Get-SurfaceACorpusGraphQL identical stderr/
        # ConvertFrom-Json rationale — applies equally to the REST surface.
        $issueListOutput = & gh issue list --state closed --search "closed:>$since" --limit $limit --json number 2>$null
        if ($LASTEXITCODE -eq 0) {
            try {
                $issueList = @(($issueListOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
                # C5: discovery-cap hit — a list returning exactly $limit rows
                # is a possible-undercount signal (more items may exist beyond
                # the cap the REST fallback cannot see).
                if ($issueList.Count -eq $limit) {
                    $truncated = $true
                }
                foreach ($issue in $issueList) {
                    if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        $truncated = $true
                        break
                    }
                    $num = [int]$issue['number']
                    # PF2-F2 fix: see Get-SurfaceACorpusGraphQL identical
                    # stderr/ConvertFrom-Json rationale.
                    $viewOutput = & gh issue view $num --json comments 2>$null
                    if ($LASTEXITCODE -ne 0) { continue }
                    try {
                        $data     = ($viewOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $comments = @($data['comments'])
                        # #772 D3: single aligned pass — extract body and
                        # createdAt together for every surviving (non-null)
                        # comment, mirroring the GraphQL comment loop
                        # (Get-SurfaceACorpusGraphQL above). Building the two
                        # arrays via independent pipelines was the desync
                        # risk this replaces: a comment dropped by one
                        # pipeline's filter but not the other would shift the
                        # index pairing between Bodies and CreatedAtValues.
                        $commentBodies    = [System.Collections.Generic.List[string]]::new()
                        $commentCreatedAt = [System.Collections.Generic.List[string]]::new()
                        foreach ($c in $comments) {
                            if ($null -ne $c) {
                                $commentBodies.Add([string]$c['body'])
                                $cCreatedAt = if ($c.ContainsKey('createdAt')) { [string]$c['createdAt'] } else { '' }
                                $commentCreatedAt.Add($cCreatedAt)
                            }
                        }
                        $bodies          = $commentBodies.ToArray()
                        $createdAtValues = $commentCreatedAt.ToArray()
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
                        $tuples.Add(@{ Number = $num; Surface = 'issue'; Bodies = $bodies; CreatedAtValues = $createdAtValues })
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
    else {
        # REST surface-budget skip: Surface A was skipped entirely because
        # the timeout budget was already exhausted before this block ran.
        $truncated = $true
    }

    # Surface B: recent merged PRs
    if ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        # PF2-F2 fix: see Get-SurfaceACorpusGraphQL identical stderr/
        # ConvertFrom-Json rationale — applies equally to the REST surface.
        $prListOutput = & gh pr list --state merged --search "merged:>$since" --limit $limit --json number 2>$null
        if ($LASTEXITCODE -eq 0) {
            try {
                $prList = @(($prListOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
                # C5: discovery-cap hit — see the Surface A rationale above.
                if ($prList.Count -eq $limit) {
                    $truncated = $true
                }
                foreach ($pr in $prList) {
                    if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        $truncated = $true
                        break
                    }
                    $num = [int]$pr['number']
                    # PF2-F2 fix: see Get-SurfaceACorpusGraphQL identical
                    # stderr/ConvertFrom-Json rationale.
                    $viewOutput = & gh pr view $num --json comments 2>$null
                    if ($LASTEXITCODE -ne 0) { continue }
                    try {
                        $data     = ($viewOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $comments = @($data['comments'])
                        # #772 D3: single aligned pass — see the Surface A
                        # rationale above (identical desync risk applies here).
                        $commentBodies    = [System.Collections.Generic.List[string]]::new()
                        $commentCreatedAt = [System.Collections.Generic.List[string]]::new()
                        foreach ($c in $comments) {
                            if ($null -ne $c) {
                                $commentBodies.Add([string]$c['body'])
                                $cCreatedAt = if ($c.ContainsKey('createdAt')) { [string]$c['createdAt'] } else { '' }
                                $commentCreatedAt.Add($cCreatedAt)
                            }
                        }
                        $bodies          = $commentBodies.ToArray()
                        $createdAtValues = $commentCreatedAt.ToArray()
                        # Only scan PRs that have judge-rulings
                        if (-not (($bodies -join "`n") -match '<!--\s*judge-rulings')) { continue }
                        $tuples.Add(@{ Number = $num; Surface = 'pr'; Bodies = $bodies; CreatedAtValues = $createdAtValues })
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
    else {
        # REST surface-budget skip: Surface B was skipped entirely because
        # the timeout budget was already exhausted before this block ran.
        $truncated = $true
    }

    return [PSCustomObject]@{ Tuples = $tuples.ToArray(); Truncated = $truncated; IsError = $false }
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

    $corpusResult = script:Get-PhaseContainmentCorpusRest `
        -WindowDays $WindowDays -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $invalidEntryCount = 0
    foreach ($tuple in $corpusResult.Tuples) {
        # M7 fix (issue #782 post-review): see Get-SurfaceAEntriesGraphQL's
        # identical per-item try/catch for the rationale.
        try {
            $scanResult = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues']

            foreach ($e in $scanResult.Entries) { $entries.Add($e) }
            $invalidEntryCount += $scanResult.InvalidEntryCount
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: REST tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return [PSCustomObject]@{
        Entries           = $entries.ToArray()
        Truncated         = $corpusResult.Truncated
        InvalidEntryCount = $invalidEntryCount
        IsError           = $false
    }
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

        M12 note (issue #782 post-review; corrected by issue #772 D3 — the
        original note below was factually wrong and is kept here, reworded,
        so a future maintainer has the real history): under the REST
        fallback path (Source = 'rest'), tuples now carry real per-comment
        CreatedAtValues. `gh issue/pr view --json comments` DOES return a
        createdAt field on every comment object — the pre-#772 REST
        discovery helper (script:Get-PhaseContainmentCorpusRest) simply
        never asked for/extracted it: it built each tuple's Bodies from the
        comment list and hardcoded CreatedAtValues = @(), unlike the GraphQL
        path's `comments(first: 100) { nodes { body createdAt } }` query,
        which always extracted both. #772 D3 closed that gap with a single
        aligned pass over the surviving (non-null) comments for both REST
        surfaces — mirroring the GraphQL comment loop — so body[] and
        createdAt[] stay index-paired and callers that rely on
        CreatedAtValues (e.g. Invoke-PhaseContainmentDedup's latest-wins
        comparison) now get real timestamps under REST fallback too, not
        just under GraphQL.
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
          Truncated [bool]   — issue #772 D1: true when any silent-truncation
                               site fired (pagination timeout, REST per-item
                               timeout, REST surface-budget skip, REST
                               discovery-cap hit). Always present so
                               StrictMode consumers never throw reading it.
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
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout'; Truncated = $false }
        }
        # PF2-F2 fix: use 2>$null, not 2>&1 — see Get-SurfaceACorpusGraphQL
        # stderr/ConvertFrom-Json rationale. The failure-path warning below no
        # longer echoes gh's stderr text (dropped, not merged); this matches
        # the GH-7 precedent in phase-containment-emission-check.ps1 gh
        # view failure branch, which also does not echo captured output.
        $repoViewJson = & gh repo view --json 'owner,name' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "phase-containment-rolling-history-core: gh repo view failed (exit $LASTEXITCODE)"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'repo-resolution-failed'; Truncated = $false }
        }
        try {
            $repoInfo = ($repoViewJson | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if (-not $RepoOwner) { $RepoOwner = [string]$repoInfo['owner']['login'] }
            if (-not $RepoName)  { $RepoName  = [string]$repoInfo['name'] }
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: failed to parse repo view: $_"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'repo-resolution-failed'; Truncated = $false }
        }
    }

    # ---- GraphQL fetch ----
    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "phase-containment-rolling-history-core: timed out before corpus GraphQL fetch"
        return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout'; Truncated = $false }
    }

    $useRest = $false
    $allTuples = [System.Collections.Generic.List[hashtable]]::new()
    $truncated = $false

    $surfaceAResult = script:Get-SurfaceACorpusGraphQL `
        -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
        -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($surfaceAResult.IsError) {
        $useRest = $true
    }
    else {
        foreach ($t in $surfaceAResult.Tuples) { $allTuples.Add($t) }
        if ($surfaceAResult.Truncated) { $truncated = $true }
    }

    if (-not $useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            # T1 (issue #772 P4): Surface A already succeeded and fetched
            # data — preserve those partials instead of discarding them, and
            # use the fetch path's own Source rather than the empty 'timeout'
            # shape (which is reserved for the pre-fetch guards below/above,
            # where no surface has produced data yet).
            Write-Warning "phase-containment-rolling-history-core: timed out before corpus Surface B fetch — returning Surface A partials (Truncated)"
            return [PSCustomObject]@{
                Tuples    = $allTuples.ToArray()
                FetchedAt = (Get-Date)
                Source    = 'graphql'
                Truncated = $true
            }
        }

        $surfaceBResult = script:Get-SurfaceBCorpusGraphQL `
            -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
            -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

        if ($surfaceBResult.IsError) {
            $useRest = $true
            $allTuples.Clear()
        }
        else {
            foreach ($t in $surfaceBResult.Tuples) { $allTuples.Add($t) }
            if ($surfaceBResult.Truncated) { $truncated = $true }
        }
    }

    # ---- REST fallback ----
    $sourceLabel = 'graphql'
    if ($useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before corpus REST fallback"
            return [PSCustomObject]@{ Tuples = @(); FetchedAt = (Get-Date); Source = 'timeout'; Truncated = $false }
        }

        $restResult = script:Get-PhaseContainmentCorpusRest `
            -WindowDays $WindowDays -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

        # M2 (reset-on-discard): any GraphQL-surface Truncated state
        # accumulated above is intentionally overwritten here, not combined
        # — the REST run owns its own truncation state from scratch.
        $allTuples.Clear()
        foreach ($t in $restResult.Tuples) { $allTuples.Add($t) }
        $truncated = $restResult.Truncated
        $sourceLabel = 'rest'
    }

    return [PSCustomObject]@{
        Tuples    = $allTuples.ToArray()
        FetchedAt = (Get-Date)
        Source    = $sourceLabel
        Truncated = $truncated
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
        PSCustomObject with Entries, FetchedAt, Source, CacheAge, Truncated,
        InvalidEntryCount. Truncated/InvalidEntryCount are always present
        (issue #772 D1) so StrictMode consumers never throw reading them.
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
                Entries           = @()
                FetchedAt         = (Get-Date)
                Source            = 'timeout'
                CacheAge          = [timespan]::Zero
                Truncated         = $false
                InvalidEntryCount = 0
            }
        }
        # PF2-F2 fix: use 2>$null, not 2>&1 — see Get-SurfaceACorpusGraphQL
        # stderr/ConvertFrom-Json rationale. The failure-path warning below no
        # longer echoes gh's stderr text (dropped, not merged); this matches
        # the GH-7 precedent in phase-containment-emission-check.ps1 gh
        # view failure branch, which also does not echo captured output.
        $repoViewJson = & gh repo view --json 'owner,name' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "phase-containment-rolling-history-core: gh repo view failed (exit $LASTEXITCODE)"
            return [PSCustomObject]@{
                Entries           = @()
                FetchedAt         = (Get-Date)
                Source            = 'repo-resolution-failed'
                CacheAge          = [timespan]::Zero
                Truncated         = $false
                InvalidEntryCount = 0
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
                Entries           = @()
                FetchedAt         = (Get-Date)
                Source            = 'repo-resolution-failed'
                CacheAge          = [timespan]::Zero
                Truncated         = $false
                InvalidEntryCount = 0
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
        # P7: cache-hit InvalidEntryCount — read from the cached payload so a
        # cache hit still surfaces prior rejections, defaulting to 0 only
        # when reading a legacy cache file written before this field existed.
        $cachedInvalidEntryCount = 0
        if ($cacheData.ContainsKey('invalid_entry_count') -and $null -ne $cacheData['invalid_entry_count']) {
            $cachedInvalidEntryCount = [int]$cacheData['invalid_entry_count']
        }
        # Compute cache age
        try {
            $genAt = [datetime]::Parse((script:ConvertTo-PhaseContainmentIsoString -Value $cacheData['generated_at']), $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $genAtUtc = $genAt.Kind -eq [System.DateTimeKind]::Utc ? $genAt : $genAt.ToUniversalTime()
            $cacheAge = (Get-Date).ToUniversalTime() - $genAtUtc
        }
        catch {
            $cacheAge = [timespan]::Zero
        }
        return [PSCustomObject]@{
            Entries           = $cachedEntries
            FetchedAt         = (Get-Date)
            Source            = 'cache'
            CacheAge          = $cacheAge
            # A truncated run is never cached (see the cache-write guard
            # below), so a cache hit is by construction a complete snapshot.
            Truncated         = $false
            InvalidEntryCount = $cachedInvalidEntryCount
        }
    }

    # ---- GraphQL fetch ----
    $useRest           = $false
    $rawEntries        = [System.Collections.Generic.List[hashtable]]::new()
    $truncated         = $false
    $invalidEntryCount = 0

    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "phase-containment-rolling-history-core: timed out before GraphQL fetch"
        return [PSCustomObject]@{
            Entries           = @()
            FetchedAt         = (Get-Date)
            Source            = 'timeout'
            CacheAge          = [timespan]::Zero
            Truncated         = $false
            InvalidEntryCount = 0
        }
    }

    $surfaceAResult = script:Get-SurfaceAEntriesGraphQL `
        -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
        -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($surfaceAResult.IsError) {
        $useRest = $true
    }
    else {
        foreach ($e in $surfaceAResult.Entries) { $rawEntries.Add($e) }
        if ($surfaceAResult.Truncated) { $truncated = $true }
        $invalidEntryCount += $surfaceAResult.InvalidEntryCount
    }

    if (-not $useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            # T1 (issue #772 P4): Surface A already succeeded and fetched
            # data — preserve those partials (and their InvalidEntryCount)
            # instead of discarding them, using the fetch path's own Source
            # rather than the empty 'timeout' shape.
            Write-Warning "phase-containment-rolling-history-core: timed out before Surface B fetch — returning Surface A partials (Truncated)"
            $dedupedPartial = Invoke-PhaseContainmentDedup -RawEntries $rawEntries.ToArray()
            return [PSCustomObject]@{
                Entries           = $dedupedPartial
                FetchedAt         = (Get-Date)
                Source            = 'graphql'
                CacheAge          = [timespan]::Zero
                Truncated         = $true
                InvalidEntryCount = $invalidEntryCount
            }
        }

        $surfaceBResult = script:Get-SurfaceBEntriesGraphQL `
            -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
            -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds

        if ($surfaceBResult.IsError) {
            $useRest = $true
            $rawEntries.Clear()
        }
        else {
            foreach ($e in $surfaceBResult.Entries) { $rawEntries.Add($e) }
            if ($surfaceBResult.Truncated) { $truncated = $true }
            $invalidEntryCount += $surfaceBResult.InvalidEntryCount
        }
    }

    # ---- REST fallback ----
    $sourceLabel = 'graphql'
    if ($useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before REST fallback"
            return [PSCustomObject]@{
                Entries           = @()
                FetchedAt         = (Get-Date)
                Source            = 'timeout'
                CacheAge          = [timespan]::Zero
                Truncated         = $false
                InvalidEntryCount = 0
            }
        }

        $restResult = script:Get-PhaseContainmentEntriesRest `
            -WindowDays $WindowDays `
            -Stopwatch $stopwatch `
            -TimeoutSeconds $TimeoutSeconds

        # M2 (reset-on-discard): $rawEntries/$truncated/$invalidEntryCount
        # accumulated from a discarded GraphQL surface are intentionally
        # overwritten here, not combined — the REST run owns its own state.
        $rawEntries.Clear()
        foreach ($e in $restResult.Entries) { $rawEntries.Add($e) }
        $truncated         = $restResult.Truncated
        $invalidEntryCount = $restResult.InvalidEntryCount
        $sourceLabel       = 'rest'
    }

    # ---- Dedup ----
    $dedupedEntries = Invoke-PhaseContainmentDedup -RawEntries $rawEntries.ToArray()

    # ---- Write cache (only if non-empty AND not truncated) ----
    # P7: a truncated run must not poison the 1-hour cache with an incomplete
    # snapshot — skipping the write here is what lets M2's reset-on-discard
    # actually matter (a fully-completed REST run after a discarded
    # truncated GraphQL attempt reports Truncated=$false and DOES cache).
    if ($dedupedEntries.Count -gt 0 -and -not $truncated) {
        script:Write-PhaseContainmentCache -CachePath $CachePath -Entries $dedupedEntries -InvalidEntryCount $invalidEntryCount
    }

    return [PSCustomObject]@{
        Entries           = $dedupedEntries
        FetchedAt         = (Get-Date)
        Source            = $sourceLabel
        CacheAge          = [timespan]::Zero
        Truncated         = $truncated
        InvalidEntryCount = $invalidEntryCount
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
    .PARAMETER Truncated
        Issue #772 C11: when set, forces RelaxationEligible=$false for every
        stage (regardless of any other guard) with
        RelaxationEligibleReason='fetch truncated'. This is the authoritative
        withholding decision — it happens here, in the rollup's own data
        object, not deferred to a renderer, so any non-renderer consumer
        reading the rollup also sees the correct withholding.
    .OUTPUTS
        PSCustomObject with Stages, LeakageMatrix, LeakageMatrixByFixType,
        ApparatusMetaCount, WindowEntryCount. Each Stages[stage] carries
        RelaxationEligibleReason alongside RelaxationEligible, mirroring the
        existing DataUntrustworthy/DataUntrustworthyReason pattern.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,
        [hashtable]$SustainedCounts = $null,
        [string]$WindowLabel = '',
        [switch]$Truncated
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

        # C11: a truncated fetch forces RelaxationEligible=$false for EVERY
        # stage, unconditionally — overriding whatever the guards above
        # computed. A truncated/partial corpus must never present a clean
        # relaxation signal regardless of insufficient-data/denominator-zero/
        # data-untrustworthy state, matching the design intent that no known
        # silent-degradation path can present a wrong number as clean.
        $relaxationEligibleReason = $null
        if ($Truncated) {
            $relaxationEligible       = $false
            $relaxationEligibleReason = 'fetch truncated'
        }

        $stages[$stage] = [PSCustomObject]@{
            Stage                     = $stage
            N                         = $n
            Denominator               = $denominator
            DenominatorZero           = $denominatorZero
            EscapeRate                = $escapeRate
            IrreducibleRate           = $irreducibleRate
            InsufficientData          = $insufficientData
            RelaxationEligible        = $relaxationEligible
            RelaxationEligibleReason  = $relaxationEligibleReason
            DataUntrustworthy         = $dataUntrustworthy
            DataUntrustworthyReason   = $dataUntrustworthyReason
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

# -------------------------------------------------------------------------
# Public function: Format-PhaseContainmentReport
# -------------------------------------------------------------------------

function Format-PhaseContainmentReport {
    <#
    .SYNOPSIS
        Renders the phase-containment escape-rate ledger report as text lines.
    .DESCRIPTION
        Issue #772 D5a: behavior-preserving extraction of the per-stage and
        leakage-matrix rendering previously inline in
        phase-containment-report.ps1. Takes a single context object carrying
        the already-computed rollup plus fetch metadata and returns the
        report body as an array of lines; the caller is responsible for
        writing them out (e.g. via Write-Output).
    .PARAMETER Context
        A hashtable or PSCustomObject with fields:
          Rollup            [PSCustomObject] — Get-PhaseContainmentRollup return object
          Source            [string]         — 'graphql' | 'rest' | 'timeout' | 'repo-resolution-failed'
          Truncated         [bool]
          WindowDays        [int]
          FetchedAt         [datetime]
          InvalidEntryCount [int]
    .OUTPUTS
        [string[]] — the report lines.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object]$Context
    )

    # Normalize field access for both hashtable and PSCustomObject
    $rollup            = if ($Context -is [hashtable]) { $Context['Rollup'] }            else { $Context.Rollup }
    $source            = if ($Context -is [hashtable]) { $Context['Source'] }            else { $Context.Source }
    $truncated         = if ($Context -is [hashtable]) { $Context['Truncated'] }         else { $Context.Truncated }
    $windowDays        = if ($Context -is [hashtable]) { $Context['WindowDays'] }        else { $Context.WindowDays }
    $fetchedAt         = if ($Context -is [hashtable]) { $Context['FetchedAt'] }         else { $Context.FetchedAt }
    $invalidEntryCount = if ($Context -is [hashtable]) { $Context['InvalidEntryCount'] } else { $Context.InvalidEntryCount }

    $lines = [System.Collections.Generic.List[string]]::new()

    # ---- Render header ----

    $headerSuffix = if ($truncated) { ' (TRUNCATED — results incomplete)' } else { '' }

    $lines.Add('')
    $lines.Add('Phase-Containment Escape-Rate Ledger')
    $lines.Add("Window: ${windowDays}d | Fetched: $($fetchedAt.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC | Source: $source$headerSuffix")
    $lines.Add("Total entries processed: $($rollup.WindowEntryCount) | Apparatus-meta entries: $($rollup.ApparatusMetaCount)")
    if ($invalidEntryCount -gt 0) {
        $lines.Add("WARNING: $invalidEntryCount phase-containment block(s) dropped as invalid/unparseable during this fetch — see gh Action run logs for details.")
    }
    $lines.Add('')

    # ---- Render per-stage results ----

    $stageOrder = @('design-challenge', 'plan-stress-test', 'code-review')

    foreach ($stageName in $stageOrder) {
        $stage = $rollup.Stages[$stageName]

        # Map stage name to catchable_phase label for clarity
        $catchableLabel = switch ($stageName) {
            'design-challenge' { 'catchable=design' }
            'plan-stress-test' { 'catchable=plan' }
            'code-review'      { 'catchable=implementation' }
        }

        $lines.Add("Stage: $stageName")
        $lines.Add("  Denominator ($catchableLabel): $($stage.Denominator)")

        if ($stage.DataUntrustworthy) {
            $lines.Add("  DATA UNTRUSTWORTHY -- relaxation signal withheld (entry count mismatch)")
            if ($null -ne $stage.DataUntrustworthyReason) {
                $lines.Add("  Reason: $($stage.DataUntrustworthyReason)")
            }
        }

        if ($stage.DenominatorZero) {
            $lines.Add("  Escape rate:        N/A (denominator=0)")
            $lines.Add("  Irreducible rate:   N/A")
            $lines.Add("  Relaxation signal:  WITHHELD (denominator=0)")
        }
        elseif ($stage.InsufficientData) {
            $lines.Add("  Escape rate:        INSUFFICIENT DATA (n=$($stage.N) < 5)")
            $lines.Add("  Irreducible rate:   INSUFFICIENT DATA")
            $lines.Add("  Relaxation signal:  WITHHELD (n<5)")
        }
        elseif ($stage.DataUntrustworthy) {
            $escapeDisplay      = if ($null -ne $stage.EscapeRate)      { '{0:P1}' -f $stage.EscapeRate }      else { 'N/A' }
            $irreducibleDisplay = if ($null -ne $stage.IrreducibleRate) { '{0:P1}' -f $stage.IrreducibleRate } else { 'N/A' }
            $lines.Add("  Escape rate:        $escapeDisplay")
            $lines.Add("  Irreducible rate:   $irreducibleDisplay")
            $lines.Add("  Relaxation signal:  WITHHELD (data untrustworthy)")
        }
        else {
            $escapeCount      = [int][Math]::Round($stage.EscapeRate      * $stage.Denominator)
            $irreducibleCount = [int][Math]::Round($stage.IrreducibleRate * $stage.Denominator)

            $escapeDisplay      = '{0:F2} ({1} of {2} escaped)' -f $stage.EscapeRate, $escapeCount, $stage.Denominator
            $irreducibleDisplay = '{0:F2} ({1} of {2} irreducible)' -f $stage.IrreducibleRate, $irreducibleCount, $stage.Denominator

            $lines.Add("  Escape rate:        $escapeDisplay")
            $lines.Add("  Irreducible rate:   $irreducibleDisplay")

            if ($null -eq $stage.RelaxationEligible) {
                $lines.Add("  Relaxation signal:  WITHHELD")
            }
            elseif ($stage.RelaxationEligible -eq $true) {
                $lines.Add("  Relaxation signal:  ELIGIBLE (escape_rate ~0, no critical findings)")
            }
            elseif ($stage.RelaxationEligibleReason -eq 'fetch truncated') {
                # P9: checked BEFORE the EscapeRate reason-guess below so a
                # truncated run never falls through to the misleading
                # "NOT ELIGIBLE (escape_rate > 0)" text.
                $lines.Add("  Relaxation signal:  WITHHELD (fetch truncated)")
            }
            else {
                # Determine reason
                if ($stage.EscapeRate -ge 0.05) {
                    $lines.Add("  Relaxation signal:  NOT ELIGIBLE (escape_rate > 0)")
                }
                else {
                    $lines.Add("  Relaxation signal:  NOT ELIGIBLE (critical severity finding in window)")
                }
            }
        }

        $lines.Add('')
    }

    # ---- Render leakage matrix ----

    $leakageMatrix = $rollup.LeakageMatrix
    if ($leakageMatrix.Count -gt 0) {
        $lines.Add('Leakage matrix (introduced x caught combinations):')

        # Sort by count descending, then key name
        $sorted = $leakageMatrix.GetEnumerator() |
            Sort-Object { -$_.Value }, { $_.Key }

        foreach ($pair in $sorted) {
            $lines.Add(('  {0,-45} {1} findings' -f "$($pair.Key -replace [char]0x00D7, ' -> '):", $pair.Value))
        }
    }
    else {
        $lines.Add('Leakage matrix: (no entries in window)')
    }

    $lines.Add('')

    return $lines.ToArray()
}
