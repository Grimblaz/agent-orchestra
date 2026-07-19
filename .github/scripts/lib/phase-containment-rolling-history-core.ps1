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
            [System.Globalization.CultureInfo]::InvariantCulture,
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
# Private: Get-PCEffectiveTimestamp
# Issue #863 s4: resolves the comparison timestamp an entry should dedup
# on — block-level appended_at when present and well-formed, else the
# comment-level createdAt. Centralizing this in one place keeps the
# malformed-vs-absent distinction consistent between the first-seen path
# and the comparison path in Invoke-PhaseContainmentDedup below.
# -------------------------------------------------------------------------

function script:Get-PCEffectiveTimestamp {
    <#
    .SYNOPSIS
        Resolves the dedup comparison timestamp for a phase-containment entry.
    .DESCRIPTION
        Prefers appended_at when present and non-empty. appended_at must match
        the strict Z-suffixed ISO-8601 literal (mirrors
        frame-spine-core.ps1:107's generated_at validation) — this is a
        RUNTIME check because the JSON Schema pattern alone is never read by
        any runtime validator. A malformed-but-present appended_at is
        reported via IsMalformed=$true rather than silently falling back, so
        the caller can route the drop into InvalidEntryCount instead of an
        uninspected Write-Warning (issue #863 M14). Falls back to the
        comment-level createdAt when appended_at is absent or empty, so the
        historic (pre-appended_at) blocks keep deduping unchanged.
    .PARAMETER Entry
        A single hashtable or PSCustomObject entry.
    .OUTPUTS
        [PSCustomObject] with TimestampStr [string] and IsMalformed [bool].
        When IsMalformed is $true, TimestampStr is $null.
    #>
    param(
        [Parameter(Mandatory)]$Entry
    )

    # F4 fix (PR #868 review): under this file's Set-StrictMode -Version
    # Latest, both raw dotted access on a PSCustomObject missing the
    # property AND unconditional `.Value` on a PSObject.Properties[...]
    # miss (itself $null when absent) throw PropertyNotFoundException — so
    # the property lookup must be null-checked before reading .Value.
    $appendedAt = if ($Entry -is [hashtable]) {
        $Entry['appended_at']
    }
    else {
        $prop = $Entry.PSObject.Properties['appended_at']
        if ($null -ne $prop) { $prop.Value } else { $null }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$appendedAt)) {
        if ([string]$appendedAt -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$') {
            return [PSCustomObject]@{ TimestampStr = $null; IsMalformed = $true }
        }
        # F6 fix (issue #868 review): the regex above only checks lexical
        # shape — a calendar-invalid date like '2026-02-30T00:00:00Z'
        # matches the pattern but throws on Parse. Route that case through
        # the same IsMalformed=$true path so both the first-seen shortcut
        # and the comparison path in Invoke-PhaseContainmentDedup below
        # (the single choke point both flow through) drop it into
        # InvalidEntryCount instead of an uninspected downstream throw.
        try {
            [datetime]::Parse(
                [string]$appendedAt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            ) | Out-Null
        }
        catch {
            return [PSCustomObject]@{ TimestampStr = $null; IsMalformed = $true }
        }
        return [PSCustomObject]@{ TimestampStr = [string]$appendedAt; IsMalformed = $false }
    }

    $createdAt = if ($Entry -is [hashtable]) {
        [string]$Entry['createdAt']
    }
    else {
        $createdAtProp = $Entry.PSObject.Properties['createdAt']
        if ($null -ne $createdAtProp) { [string]$createdAtProp.Value } else { '' }
    }
    return [PSCustomObject]@{ TimestampStr = $createdAt; IsMalformed = $false }
}

# -------------------------------------------------------------------------
# Public helper: Invoke-PhaseContainmentDedup
# Dedup by finding_key — keep entry with the latest effective timestamp
# (appended_at when present and well-formed, else comment-level createdAt).
# -------------------------------------------------------------------------

function Invoke-PhaseContainmentDedup {
    <#
    .SYNOPSIS
        Deduplicates phase-containment entries by finding_key, keeping the latest.
    .DESCRIPTION
        SMC-20 convention: when the same finding_key appears multiple times (e.g., a
        re-annotated block), keep the entry with the most recent timestamp.
        Issue #863 s4: comparison now prefers each entry's block-level
        appended_at over the comment-level createdAt, because GitHub does not
        advance a comment's createdAt on edit (Add-CommentBlocks is a PATCH),
        so a re-annotated block could otherwise lose to a stale block sitting
        in a later-created sibling comment. Both sides of the comparison are
        normalized with .ToUniversalTime() before -gt, since [datetime]
        comparison operators compare raw Ticks without normalizing Kind — an
        offset-form or Unspecified-Kind value can otherwise invert against a
        'Z'-form (Kind=Utc) value even when both parse successfully.
    .PARAMETER RawEntries
        Array of PSCustomObject or hashtable entries, each with finding_key and createdAt fields.
    .PARAMETER InvalidEntryCount
        Optional [ref] counter incremented once per entry dropped because its
        appended_at is present but does not match the strict Z-suffixed
        format (issue #863 M14 — malformed must not silently revert to
        first-seen via an uninspected Write-Warning).
    .OUTPUTS
        [array] Deduplicated entries.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawEntries,
        [ref]$InvalidEntryCount
    )

    if ($RawEntries.Count -eq 0) {
        return , @()
    }

    $best = [System.Collections.Generic.Dictionary[string, object]]::new()

    foreach ($entry in $RawEntries) {
        $key = if ($entry -is [hashtable]) { [string]$entry['finding_key'] } else { [string]$entry.finding_key }

        $effective = script:Get-PCEffectiveTimestamp -Entry $entry
        if ($effective.IsMalformed) {
            Write-Warning "phase-containment-rolling-history-core: malformed appended_at for key '$key' — dropping entry rather than silently reverting to first-seen."
            if ($null -ne $InvalidEntryCount) { $InvalidEntryCount.Value++ }
            continue
        }
        $createdAtStr = $effective.TimestampStr

        if (-not $best.ContainsKey($key)) {
            $best[$key] = $entry
            continue
        }

        # Parse both timestamps and keep the newer one
        $existingEffective = script:Get-PCEffectiveTimestamp -Entry $best[$key]
        $existingCreatedAtStr = $existingEffective.TimestampStr

        try {
            $existingDt = [datetime]::Parse($existingCreatedAtStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            $candidateDt = [datetime]::Parse($createdAtStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()

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
# Private: Get-PhaseContainmentCommentAuthorLogin
# Issue #854 s4 (M8): the corpus previously selected only body/createdAt
# with no author, so any account that could comment could forge a
# well-formed coverage record. Both GraphQL (`author { login }`, added to
# all six comments() sites below) and REST (`gh issue/pr view --json
# comments`, which already returns an `author.login` field on every
# comment object with no extra selection needed) surface an `author`
# hashtable with a `login` key; this helper centralizes the null-safe
# extraction (deleted GitHub accounts return `author: null` from GraphQL)
# so all eight fetch sites (six GraphQL, two REST) share one path instead
# of duplicating the ContainsKey/null checks.
# -------------------------------------------------------------------------

function script:Get-PhaseContainmentCommentAuthorLogin {
    <#
    .SYNOPSIS
        Extracts a comment node's author login, defaulting to '' when the
        author field is absent or null.
    .PARAMETER CommentNode
        A single comment node hashtable (from ConvertFrom-Json -AsHashtable).
    .OUTPUTS
        [string] the author's login, or '' when unresolvable.
    #>
    param([AllowNull()]$CommentNode)

    if ($null -eq $CommentNode -or $CommentNode -isnot [hashtable]) { return '' }
    if (-not $CommentNode.ContainsKey('author')) { return '' }
    $author = $CommentNode['author']
    if ($null -eq $author -or $author -isnot [hashtable]) { return '' }
    if (-not $author.ContainsKey('login')) { return '' }
    return [string]$author['login']
}

# -------------------------------------------------------------------------
# Public function: Test-PhaseContainmentCommentAuthoredByJudge
# Issue #854 s4 (M8) — the comparison primitive future gate consumers use
# to decide whether a comment's coverage/internal_match data is trustworthy.
# -------------------------------------------------------------------------

function Test-PhaseContainmentCommentAuthoredByJudge {
    <#
    .SYNOPSIS
        Compares a comment's author login against the judge identity.
    .DESCRIPTION
        Any account that can comment on an issue/PR can otherwise post a
        well-formed `<!-- review-dispositions-{PR} -->` body carrying a
        forged `external_sources_reconciled` / `internal_match` record and
        silently unlock ELIGIBLE. Coverage records and internal_match
        values must be honored ONLY from the body the judge itself posted.

        Normalization mirrors skills/code-review-intake/SKILL.md's
        reviewer_source rule: lowercase(login) with a trailing `[bot]`
        suffix stripped, so `github-actions` and `github-actions[bot]`
        compare equal. This is a DISTINCT axis from reviewer_source (a
        writer-supplied value inside the body text) — never conflate the
        two. An empty/unresolvable AuthorLogin (deleted account, or a REST/
        GraphQL response that omitted author) never matches any judge
        login — fail-closed by construction.
    .PARAMETER AuthorLogin
        The comment's raw author login (may be '' when unresolvable).
    .PARAMETER JudgeLogin
        The expected judge identity's login — e.g. the repo's known CI
        poster identity (`github-actions[bot]`) or the authenticated
        identity that posted the PR's review-dispositions marker. Caller-
        supplied; this function does not discover it.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$AuthorLogin,
        [Parameter(Mandatory)][AllowEmptyString()][string]$JudgeLogin
    )

    if ([string]::IsNullOrWhiteSpace($AuthorLogin) -or [string]::IsNullOrWhiteSpace($JudgeLogin)) {
        return $false
    }

    $normalized = ($AuthorLogin.ToLowerInvariant() -replace '\[bot\]$', '')
    $normalizedJudge = ($JudgeLogin.ToLowerInvariant() -replace '\[bot\]$', '')
    return $normalized -eq $normalizedJudge
}

# -------------------------------------------------------------------------
# Public function: Select-PhaseContainmentJudgeAuthoredBodies
# Issue #854 s4 (M8) — the filtering primitive future gate consumers use so
# a non-judge-authored body carrying a well-formed dispositions marker
# contributes ZERO coverage: exclude it BEFORE it ever reaches a parser
# (Get-DispositionTally), rather than parsing it and trying to discard its
# output afterward.
# -------------------------------------------------------------------------

function Select-PhaseContainmentJudgeAuthoredBodies {
    <#
    .SYNOPSIS
        Filters a corpus tuple's Bodies down to those authored by the judge
        identity.
    .DESCRIPTION
        Index-paired with AuthorLogins the same way CreatedAtValues is
        index-paired with Bodies (Get-PhaseContainmentCommentCorpus's tuple
        contract). A body with no resolvable author (empty AuthorLogin) is
        excluded, matching Test-PhaseContainmentCommentAuthoredByJudge's
        fail-closed default.
    .PARAMETER Bodies
        The tuple's Bodies[] array.
    .PARAMETER AuthorLogins
        The tuple's AuthorLogins[] array, index-paired with Bodies.
    .PARAMETER JudgeLogin
        The expected judge identity's login.
    .OUTPUTS
        [string[]] the subset of Bodies authored by the judge, in original order.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Bodies,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AuthorLogins,
        [Parameter(Mandatory)][AllowEmptyString()][string]$JudgeLogin
    )

    $selected = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Bodies.Count; $i++) {
        $authorLogin = if ($i -lt $AuthorLogins.Count) { $AuthorLogins[$i] } else { '' }
        if (Test-PhaseContainmentCommentAuthoredByJudge -AuthorLogin $authorLogin -JudgeLogin $JudgeLogin) {
            $selected.Add($Bodies[$i])
        }
    }
    return , $selected.ToArray()
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
        Issue #772/#831 M4: Get-PhaseContainmentBlock's own D6 pair-match
        skip (a malformed/unclosed block dropped before it is even
        returned here) is threaded in via its -SkippedCount [ref] parameter
        and folded into InvalidEntryCount too, so parser-layer drops are
        not invisible to callers that trust this count as the complete
        picture of scan-time data loss.
    .PARAMETER CommentBodies
        Array of comment body strings to scan.
    .PARAMETER IssueOrPrNumber
        The issue or PR number used as the ID for Get-PhaseContainmentBlock.
    .PARAMETER Surface
        Optional surface label to attach to each entry. Default: 'unknown'.
    .PARAMETER CreatedAtValues
        Optional parallel array of createdAt strings (ISO 8601), one per body.
        If not supplied, entries get an empty string for createdAt.
    .PARAMETER AuthorLogins
        Optional parallel array of comment author logins, one per body
        (Get-PhaseContainmentCommentCorpus's tuple contract). Index-paired
        with CommentBodies the same way CreatedAtValues is.
    .PARAMETER JudgeLogin
        G-CR3 fix (PR #859 GitHub-review post-fix, security): when supplied
        (non-empty), every body is gated through
        Test-PhaseContainmentCommentAuthoredByJudge against AuthorLogins
        BEFORE it is scanned for phase-containment-{ID} blocks — a
        non-judge-authored body contributes ZERO entries, closing the
        forged-block vector (any account that can comment could otherwise
        post a well-formed post-review-observer block claiming
        catchable_phase: experience/design to satisfy all-phase
        reconciliation while leaving the real implementation-scoped escape
        count untouched). Wires up Select-PhaseContainmentJudgeAuthoredBodies's
        filtering primitive (previously dead code with zero production
        callers) at the point entries are actually built, mirroring the same
        authorship discipline phase-containment-report.ps1's
        Get-PhaseContainmentTerminalObservation already applies to the
        coverage/dispositions tally. Left empty (the default), no gating is
        applied — preserves this function's existing behavior for callers
        that do not carry author provenance.
    .OUTPUTS
        [PSCustomObject] with:
          Entries             [array] — parsed, validated entry hashtables with appended metadata.
          InvalidEntryCount   [int]   — count of blocks dropped (parse failure + every validation failure).
          Matched             [int]   — count of bodies that passed the author gate and were scanned
                                        for phase-containment blocks (issue #842 M8). Equals
                                        CommentBodies.Count when -JudgeLogin is not supplied (no gate).
          AuthorFilteredCount [int]   — count of bodies dropped by the author gate before ever being
                                        scanned (issue #842 M8), so a caller can distinguish "the judge
                                        filter matched nothing" from "genuinely empty window."
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CommentBodies,
        [Parameter(Mandatory)][int]$IssueOrPrNumber,
        [string]$Surface = 'unknown',
        [AllowEmptyCollection()][string[]]$CreatedAtValues = @(),
        [AllowEmptyCollection()][string[]]$AuthorLogins = @(),
        [AllowEmptyString()][string]$JudgeLogin = ''
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()
    $id      = [string]$IssueOrPrNumber
    $invalidEntryCount = 0
    $matched = 0
    $authorFilteredCount = 0
    $gateOnAuthor = -not [string]::IsNullOrWhiteSpace($JudgeLogin)

    for ($i = 0; $i -lt $CommentBodies.Count; $i++) {
        $body = $CommentBodies[$i]
        $createdAt = if ($i -lt $CreatedAtValues.Count) { $CreatedAtValues[$i] } else { '' }

        if ($gateOnAuthor) {
            $authorLogin = if ($i -lt $AuthorLogins.Count) { $AuthorLogins[$i] } else { '' }
            if (-not (Test-PhaseContainmentCommentAuthoredByJudge -AuthorLogin $authorLogin -JudgeLogin $JudgeLogin)) {
                $authorFilteredCount++
                continue
            }
        }

        $matched++

        # M4 fix (issue #772/#831 post-fix review): thread the D6 pair-match
        # skip count out of Get-PhaseContainmentBlock so a malformed/
        # unclosed block that never reaches this loop still counts toward
        # InvalidEntryCount, alongside the parse-failure and
        # validation-failure drops below.
        $parserSkippedCount = 0
        $yamlBlocks = Get-PhaseContainmentBlock -Text $body -Id $id -SkippedCount ([ref]$parserSkippedCount)
        $invalidEntryCount += $parserSkippedCount
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
        Entries             = $results.ToArray()
        InvalidEntryCount   = $invalidEntryCount
        Matched             = $matched
        AuthorFilteredCount = $authorFilteredCount
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
        [int]$InvalidEntryCount = 0,
        # Issue #842 M2 fix: persist the window-level author-gate accounting
        # so a subsequent cache-hit run can restore it instead of hardcoding
        # both fields to 0 (which previously rendered "Judge filter: matched
        # 0 of 0" beside a non-empty, cache-served stage render).
        [int]$Matched = 0,
        [int]$AuthorFilteredCount = 0
    )
    try {
        $cacheDir = Split-Path -Parent $CachePath
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        $payload = @{
            generated_at          = (Get-Date).ToUniversalTime().ToString('o')
            entries               = $Entries
            invalid_entry_count   = $InvalidEntryCount
            matched               = $Matched
            author_filtered_count = $AuthorFilteredCount
        }
        # M7 fix (issue #842 post-review): the cache filename embeds
        # $JudgeLogin verbatim (see Get-PhaseContainmentHistory's CachePath
        # resolution above) and Read-PhaseContainmentCache reads it back via
        # -LiteralPath. Set-Content -Path interprets wildcard characters --
        # a bracketed identity like 'github-actions[bot]' makes the path a
        # (silently non-matching) wildcard pattern, so the write here would
        # otherwise silently no-op. Use -LiteralPath for consistency with
        # the reader.
        $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CachePath -Encoding UTF8
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
          nodes { author { login } body createdAt }
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
                $commentAuthorLogins = [System.Collections.Generic.List[string]]::new()

                $commentBlock = $issueNode['comments']
                $commentNodes = @($commentBlock['nodes'])

                foreach ($cn in $commentNodes) {
                    if ($null -ne $cn) {
                        $commentBodies.Add([string]$cn['body'])
                        $cnCreatedAt = if ($cn.ContainsKey('createdAt')) { script:ConvertTo-PhaseContainmentIsoString -Value $cn['createdAt'] } else { '' }
                        $commentCreatedAt.Add($cnCreatedAt)
                        $commentAuthorLogins.Add((script:Get-PhaseContainmentCommentAuthorLogin -CommentNode $cn))
                    }
                }

                # Check whether this issue has a design-phase-complete or plan-issue marker
                $allBodiesText = $commentBodies -join "`n"
                $hasMarker = ($allBodiesText -match "(?m)^\s*<!--\s*design-phase-complete-$issueNum\s*-->") -or
                             ($allBodiesText -match "(?m)^\s*<!--\s*plan-issue-$issueNum\s*-->")

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
        nodes { author { login } body createdAt }
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
                                    $cnCreatedAtHunt = if ($cn.ContainsKey('createdAt')) { script:ConvertTo-PhaseContainmentIsoString -Value $cn['createdAt'] } else { '' }
                                    $commentCreatedAt.Add($cnCreatedAtHunt)
                                    $commentAuthorLogins.Add((script:Get-PhaseContainmentCommentAuthorLogin -CommentNode $cn))
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
                        $hasMarker = ($allBodiesText -match "(?m)^\s*<!--\s*design-phase-complete-$issueNum\s*-->") -or
                                     ($allBodiesText -match "(?m)^\s*<!--\s*plan-issue-$issueNum\s*-->")
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
        nodes { author { login } body createdAt }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"@
                    # PF2-F2 fix: see the Surface A search-page call above for
                    # the same stderr/ConvertFrom-Json rationale.
                    $pageOutput = & gh api graphql -f "query=$pageQuery" 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        # M1 fix (issue #772/#831 post-fix review): a gh
                        # failure here silently truncates the UNBOUNDED
                        # post-marker-find collection pass — the marker was
                        # already confirmed present, so a break here can drop
                        # a later phase-containment-{N} block without ever
                        # flagging the run as degraded. Match the sibling
                        # timeout exit above.
                        Write-Warning "phase-containment-rolling-history-core: post-marker-find pagination gh call failed for issue #$issueNum (exit $LASTEXITCODE)"
                        $truncated = $true
                        break
                    }

                    try {
                        $pageParsed = ($pageOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $pageComments = $pageParsed['data']['repository']['issue']['comments']
                        foreach ($cn in @($pageComments['nodes'])) {
                            if ($null -ne $cn) {
                                $commentBodies.Add([string]$cn['body'])
                                $cnCreatedAt2 = if ($cn.ContainsKey('createdAt')) { script:ConvertTo-PhaseContainmentIsoString -Value $cn['createdAt'] } else { '' }
                                $commentCreatedAt.Add($cnCreatedAt2)
                                $commentAuthorLogins.Add((script:Get-PhaseContainmentCommentAuthorLogin -CommentNode $cn))
                            }
                        }
                        $pi = $pageComments['pageInfo']
                        $cursor = if ([bool]$pi['hasNextPage']) { [string]$pi['endCursor'] } else { $null }
                    }
                    catch {
                        # M1 fix: same rationale as the gh-exit-failure branch
                        # above — a parse failure here silently truncates the
                        # unbounded post-marker-find collection pass.
                        Write-Warning "phase-containment-rolling-history-core: failed to parse pagination response for issue #${issueNum}: $_"
                        $truncated = $true
                        break
                    }
                }

                # Record the discovered per-number tuple (raw bodies — no scan/parse here).
                $tuples.Add(@{
                    Number           = $issueNum
                    Surface          = 'issue'
                    Bodies           = $commentBodies.ToArray()
                    CreatedAtValues  = $commentCreatedAt.ToArray()
                    AuthorLogins     = $commentAuthorLogins.ToArray()
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
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [AllowEmptyString()][string]$JudgeLogin = ''
    )

    $corpusResult = script:Get-SurfaceACorpusGraphQL `
        -Owner $Owner -Repo $Repo -WindowDays $WindowDays `
        -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($corpusResult.IsError) {
        return [PSCustomObject]@{ Entries = @(); Truncated = $false; InvalidEntryCount = 0; Matched = 0; AuthorFilteredCount = 0; IsError = $true }
    }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $invalidEntryCount = 0
    $matched = 0
    $authorFilteredCount = 0
    foreach ($tuple in $corpusResult.Tuples) {
        # M7 fix (issue #782 post-review): restore per-item isolation. A
        # single malformed tuple (e.g. Number/Bodies/CreatedAtValues that
        # cannot bind to Invoke-PhaseContainmentCommentScan's typed
        # parameters) must degrade that ONE tuple, not abort every other
        # tuple in this loop — the original per-item try/catch this
        # extraction moved away from.
        try {
            # G-CR3 fix: thread AuthorLogins/JudgeLogin through so a
            # non-judge-authored body contributes zero entries.
            $scanResult = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues'] `
                -AuthorLogins @($tuple['AuthorLogins']) `
                -JudgeLogin $JudgeLogin

            foreach ($e in $scanResult.Entries) { $entries.Add($e) }
            $invalidEntryCount += $scanResult.InvalidEntryCount
            $matched += $scanResult.Matched
            $authorFilteredCount += $scanResult.AuthorFilteredCount
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: Surface A tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return [PSCustomObject]@{
        Entries             = $entries.ToArray()
        Truncated           = $corpusResult.Truncated
        InvalidEntryCount   = $invalidEntryCount
        Matched             = $matched
        AuthorFilteredCount = $authorFilteredCount
        IsError             = $false
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
          nodes { author { login } body createdAt }
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
                $commentAuthorLogins = [System.Collections.Generic.List[string]]::new()

                $commentBlock = $prNode['comments']
                $commentNodes = @($commentBlock['nodes'])

                foreach ($cn in $commentNodes) {
                    if ($null -ne $cn) {
                        $commentBodies.Add([string]$cn['body'])
                        $cnCreatedAtB = if ($cn.ContainsKey('createdAt')) { script:ConvertTo-PhaseContainmentIsoString -Value $cn['createdAt'] } else { '' }
                        $commentCreatedAt.Add($cnCreatedAtB)
                        $commentAuthorLogins.Add((script:Get-PhaseContainmentCommentAuthorLogin -CommentNode $cn))
                    }
                }

                # Check whether this PR has a judge-rulings block (marks review pipeline)
                $allBodiesText = $commentBodies -join "`n"
                $hasJudgeRulings = ($allBodiesText -match '(?m)^\s*<!--\s*judge-rulings')

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
        nodes { author { login } body createdAt }
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
                                    $cnCreatedAtBHunt = if ($cn.ContainsKey('createdAt')) { script:ConvertTo-PhaseContainmentIsoString -Value $cn['createdAt'] } else { '' }
                                    $commentCreatedAt.Add($cnCreatedAtBHunt)
                                    $commentAuthorLogins.Add((script:Get-PhaseContainmentCommentAuthorLogin -CommentNode $cn))
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
                        $hasJudgeRulings = ($allBodiesText -match '(?m)^\s*<!--\s*judge-rulings')
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
        nodes { author { login } body createdAt }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
"@
                    # PF2-F2 fix: see the Surface A search-page call for the
                    # same stderr/ConvertFrom-Json rationale.
                    $pageOutput = & gh api graphql -f "query=$pageQuery" 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        # M1 fix (issue #772/#831 post-fix review): see the
                        # identical Surface A rationale above — a gh failure
                        # here silently truncates the UNBOUNDED post-marker-
                        # find collection pass.
                        Write-Warning "phase-containment-rolling-history-core: post-marker-find pagination gh call failed for PR #$prNum (exit $LASTEXITCODE)"
                        $truncated = $true
                        break
                    }

                    try {
                        $pageParsed = ($pageOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $pageComments = $pageParsed['data']['repository']['pullRequest']['comments']
                        foreach ($cn in @($pageComments['nodes'])) {
                            if ($null -ne $cn) {
                                $commentBodies.Add([string]$cn['body'])
                                $cnCreatedAtB2 = if ($cn.ContainsKey('createdAt')) { script:ConvertTo-PhaseContainmentIsoString -Value $cn['createdAt'] } else { '' }
                                $commentCreatedAt.Add($cnCreatedAtB2)
                                $commentAuthorLogins.Add((script:Get-PhaseContainmentCommentAuthorLogin -CommentNode $cn))
                            }
                        }
                        $pi = $pageComments['pageInfo']
                        $cursor = if ([bool]$pi['hasNextPage']) { [string]$pi['endCursor'] } else { $null }
                    }
                    catch {
                        # M1 fix: see the identical Surface A rationale above.
                        Write-Warning "phase-containment-rolling-history-core: failed to parse pagination response for PR #${prNum}: $_"
                        $truncated = $true
                        break
                    }
                }

                # Record the discovered per-number tuple (raw bodies — no scan/parse here).
                $tuples.Add(@{
                    Number           = $prNum
                    Surface          = 'pr'
                    Bodies           = $commentBodies.ToArray()
                    CreatedAtValues  = $commentCreatedAt.ToArray()
                    AuthorLogins     = $commentAuthorLogins.ToArray()
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
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [AllowEmptyString()][string]$JudgeLogin = ''
    )

    $corpusResult = script:Get-SurfaceBCorpusGraphQL `
        -Owner $Owner -Repo $Repo -WindowDays $WindowDays `
        -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    if ($corpusResult.IsError) {
        return [PSCustomObject]@{ Entries = @(); Truncated = $false; InvalidEntryCount = 0; Matched = 0; AuthorFilteredCount = 0; IsError = $true }
    }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $invalidEntryCount = 0
    $matched = 0
    $authorFilteredCount = 0
    foreach ($tuple in $corpusResult.Tuples) {
        # M7 fix (issue #782 post-review): see Get-SurfaceAEntriesGraphQL's
        # identical per-item try/catch for the rationale.
        try {
            # G-CR3 fix: thread AuthorLogins/JudgeLogin through so a
            # non-judge-authored body contributes zero entries.
            $scanResult = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues'] `
                -AuthorLogins @($tuple['AuthorLogins']) `
                -JudgeLogin $JudgeLogin

            foreach ($e in $scanResult.Entries) { $entries.Add($e) }
            $invalidEntryCount += $scanResult.InvalidEntryCount
            $matched += $scanResult.Matched
            $authorFilteredCount += $scanResult.AuthorFilteredCount
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: Surface B tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return [PSCustomObject]@{
        Entries             = $entries.ToArray()
        Truncated           = $corpusResult.Truncated
        InvalidEntryCount   = $invalidEntryCount
        Matched             = $matched
        AuthorFilteredCount = $authorFilteredCount
        IsError             = $false
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
                    if ($LASTEXITCODE -ne 0) {
                        # M2 fix (issue #772/#831 post-fix review): a per-item
                        # view failure silently dropped this issue's comments
                        # from the corpus without ever flagging the run as
                        # degraded.
                        Write-Warning "phase-containment-rolling-history-core: REST failed to fetch issue #$num comments (exit $LASTEXITCODE)"
                        $truncated = $true
                        continue
                    }
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
                        # Issue #854 s4 (M8): `gh issue view --json comments`
                        # already returns an `author.login` field on every
                        # comment object with no extra field selection needed
                        # (empirically confirmed by cost-baseline-harvest.ps1's
                        # identical `.author.login` read off the same `--json
                        # comments` shape) — unlike the GraphQL path, no query
                        # change is required here, only extraction.
                        $commentAuthorLogins = [System.Collections.Generic.List[string]]::new()
                        foreach ($c in $comments) {
                            if ($null -ne $c) {
                                $commentBodies.Add([string]$c['body'])
                                $cCreatedAt = if ($c.ContainsKey('createdAt')) { script:ConvertTo-PhaseContainmentIsoString -Value $c['createdAt'] } else { '' }
                                $commentCreatedAt.Add($cCreatedAt)
                                $commentAuthorLogins.Add((script:Get-PhaseContainmentCommentAuthorLogin -CommentNode $c))
                            }
                        }
                        $bodies          = $commentBodies.ToArray()
                        $createdAtValues = $commentCreatedAt.ToArray()
                        $authorLogins    = $commentAuthorLogins.ToArray()
                        # GH-8 fix: apply the same marker-presence gate the
                        # GraphQL path uses (Get-SurfaceACorpusGraphQL) before
                        # including this issue's tuple in the returned
                        # corpus. Without this, the REST fallback included
                        # every closed issue's comments unconditionally,
                        # unlike the GraphQL path which only includes issues
                        # carrying a design-phase-complete-{N} or
                        # plan-issue-{N} marker.
                        $allBodiesText = $bodies -join "`n"
                        $hasMarker = ($allBodiesText -match "(?m)^\s*<!--\s*design-phase-complete-$num\s*-->") -or
                                     ($allBodiesText -match "(?m)^\s*<!--\s*plan-issue-$num\s*-->")
                        if (-not $hasMarker) { continue }
                        $tuples.Add(@{ Number = $num; Surface = 'issue'; Bodies = $bodies; CreatedAtValues = $createdAtValues; AuthorLogins = $authorLogins })
                    }
                    catch {
                        # M2 fix: same rationale as the view-failure branch
                        # above — a per-item parse failure silently dropped
                        # this issue without flagging the run as degraded.
                        Write-Warning "phase-containment-rolling-history-core: REST failed to parse issue #$num comments: $_"
                        $truncated = $true
                    }
                }
            }
            catch {
                # M2 fix: a list-level parse failure silently dropped the
                # ENTIRE Surface A REST corpus without flagging the run as
                # degraded — same failure class as the per-item drops above.
                Write-Warning "phase-containment-rolling-history-core: REST issue list parse failed: $_"
                $truncated = $true
            }
        }
        else {
            # M2 fix: the `gh issue list` call itself failing (non-zero
            # exit) previously fell through this `if` with no `else` at
            # all — silently returning zero Surface A tuples with no
            # warning and no Truncated flag.
            Write-Warning "phase-containment-rolling-history-core: REST issue list call failed (exit $LASTEXITCODE)"
            $truncated = $true
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
                    if ($LASTEXITCODE -ne 0) {
                        # M2 fix (issue #772/#831 post-fix review): see the
                        # identical Surface A rationale above.
                        Write-Warning "phase-containment-rolling-history-core: REST failed to fetch PR #$num comments (exit $LASTEXITCODE)"
                        $truncated = $true
                        continue
                    }
                    try {
                        $data     = ($viewOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $comments = @($data['comments'])
                        # #772 D3: single aligned pass — see the Surface A
                        # rationale above (identical desync risk applies here).
                        $commentBodies    = [System.Collections.Generic.List[string]]::new()
                        $commentCreatedAt = [System.Collections.Generic.List[string]]::new()
                        # Issue #854 s4 (M8): see the Surface A REST rationale
                        # above — `gh pr view --json comments` also already
                        # returns `author.login` with no extra selection.
                        $commentAuthorLogins = [System.Collections.Generic.List[string]]::new()
                        foreach ($c in $comments) {
                            if ($null -ne $c) {
                                $commentBodies.Add([string]$c['body'])
                                $cCreatedAt = if ($c.ContainsKey('createdAt')) { script:ConvertTo-PhaseContainmentIsoString -Value $c['createdAt'] } else { '' }
                                $commentCreatedAt.Add($cCreatedAt)
                                $commentAuthorLogins.Add((script:Get-PhaseContainmentCommentAuthorLogin -CommentNode $c))
                            }
                        }
                        $bodies          = $commentBodies.ToArray()
                        $createdAtValues = $commentCreatedAt.ToArray()
                        $authorLogins    = $commentAuthorLogins.ToArray()
                        # Only scan PRs that have judge-rulings
                        if (-not (($bodies -join "`n") -match '(?m)^\s*<!--\s*judge-rulings')) { continue }
                        $tuples.Add(@{ Number = $num; Surface = 'pr'; Bodies = $bodies; CreatedAtValues = $createdAtValues; AuthorLogins = $authorLogins })
                    }
                    catch {
                        # M2 fix: see the identical Surface A rationale above.
                        Write-Warning "phase-containment-rolling-history-core: REST failed to parse PR #$num comments: $_"
                        $truncated = $true
                    }
                }
            }
            catch {
                # M2 fix: see the identical Surface A list-level rationale above.
                Write-Warning "phase-containment-rolling-history-core: REST PR list parse failed: $_"
                $truncated = $true
            }
        }
        else {
            # M2 fix: see the identical Surface A list-level rationale above.
            Write-Warning "phase-containment-rolling-history-core: REST PR list call failed (exit $LASTEXITCODE)"
            $truncated = $true
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
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [AllowEmptyString()][string]$JudgeLogin = ''
    )

    $corpusResult = script:Get-PhaseContainmentCorpusRest `
        -WindowDays $WindowDays -Stopwatch $Stopwatch -TimeoutSeconds $TimeoutSeconds

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $invalidEntryCount = 0
    $matched = 0
    $authorFilteredCount = 0
    foreach ($tuple in $corpusResult.Tuples) {
        # M7 fix (issue #782 post-review): see Get-SurfaceAEntriesGraphQL's
        # identical per-item try/catch for the rationale.
        try {
            # G-CR3 fix: thread AuthorLogins/JudgeLogin through so a
            # non-judge-authored body contributes zero entries.
            $scanResult = Invoke-PhaseContainmentCommentScan `
                -CommentBodies $tuple['Bodies'] `
                -IssueOrPrNumber $tuple['Number'] `
                -Surface $tuple['Surface'] `
                -CreatedAtValues $tuple['CreatedAtValues'] `
                -AuthorLogins @($tuple['AuthorLogins']) `
                -JudgeLogin $JudgeLogin

            foreach ($e in $scanResult.Entries) { $entries.Add($e) }
            $invalidEntryCount += $scanResult.InvalidEntryCount
            $matched += $scanResult.Matched
            $authorFilteredCount += $scanResult.AuthorFilteredCount
        }
        catch {
            Write-Warning "phase-containment-rolling-history-core: REST tuple scan failed for Number='$($tuple['Number'])': $_"
        }
    }

    return [PSCustomObject]@{
        Entries             = $entries.ToArray()
        Truncated           = $corpusResult.Truncated
        InvalidEntryCount   = $invalidEntryCount
        Matched             = $matched
        AuthorFilteredCount = $authorFilteredCount
        IsError             = $false
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

        Issue #854 s4 (M8): tuples also now carry a per-comment AuthorLogins
        array, index-paired with Bodies/CreatedAtValues the same way. All six
        GraphQL comments() query sites (issue base/hunt/page, PR base/hunt/
        page) select `author { login }` alongside `body createdAt`; both
        REST fallback surfaces extract the same field from `gh issue/pr view
        --json comments`, which already returns author.login with no extra
        selection. This closes the forged-coverage vector: without an author
        on record, any account that could comment on an issue/PR could post
        a well-formed dispositions marker and forge a coverage record. See
        Test-PhaseContainmentCommentAuthoredByJudge and
        Select-PhaseContainmentJudgeAuthoredBodies (above) for the
        comparison/filtering primitives future gate consumers use against
        this field.
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
          Tuples    [array]  — each entry: @{ Number; Surface ('issue'|'pr'); Bodies [string[]]; CreatedAtValues [string[]]; AuthorLogins [string[]] (issue #854 s4; index-paired with Bodies, '' when unresolvable) }
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
        [System.IO.Path]::GetTempPath()\.phase-containment-cache-{RepoOwner}-{RepoName}-{JudgeLogin}.json
    .PARAMETER TimeoutSeconds
        Per-run budget in seconds. Default: 30.
    .PARAMETER JudgeLogin
        G-CR3 fix (PR #859 GitHub-review post-fix, security): threaded
        through to Invoke-PhaseContainmentCommentScan (via the three
        Get-Surface*Entries* wrappers below) so a body not authored by this
        identity contributes zero phase-containment entries, matching the
        same authorship discipline phase-containment-report.ps1's
        Get-PhaseContainmentTerminalObservation already applies to the
        coverage/dispositions tally. Left empty (the default), no gating is
        applied — existing direct callers/tests that do not pass a judge
        identity keep their prior unfiltered behavior.
    .PARAMETER SkipCacheWrite
        Issue #842 M5 fix: when set, suppresses the 1-hour cache write this
        function otherwise performs after a successful, non-truncated fetch.
        Intended for callers that construct a throwaway/bypass CachePath
        (e.g. a GUID-named path under $env:TEMP used to force a same-run-
        fresh fetch) -- without this switch, every such bypass run still
        wrote a full-content orphan cache JSON to that throwaway path with
        no cleanup, on every default run. Does not affect cache reads.
    .OUTPUTS
        PSCustomObject with Entries, FetchedAt, Source, CacheAge, Truncated,
        InvalidEntryCount, Matched, AuthorFilteredCount. Truncated/
        InvalidEntryCount/Matched/AuthorFilteredCount are always present
        (issue #772 D1, extended by issue #842 M11) so StrictMode consumers
        never throw reading them. Matched/AuthorFilteredCount (issue #842
        M8) are the window-level totals aggregated across every scanned
        surface; a degradation path that never attempted a scan (timeout,
        repo-resolution-failed) reports both as 0. A cache hit restores
        both from the persisted payload (issue #842 M2), defaulting to 0
        only for a legacy cache file written before that field existed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$RepoOwner    = '',
        [string]$RepoName     = '',
        [int]$WindowDays      = 90,
        [string]$Token        = '',
        [string]$CachePath    = '',
        [int]$TimeoutSeconds  = 30,
        [AllowEmptyString()][string]$JudgeLogin = '',
        [switch]$SkipCacheWrite
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ---- Resolve repo owner/name ----
    if (-not $RepoOwner -or -not $RepoName) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before repo resolution"
            return [PSCustomObject]@{
                Entries             = @()
                FetchedAt           = (Get-Date)
                Source              = 'timeout'
                CacheAge            = [timespan]::Zero
                Truncated           = $false
                InvalidEntryCount   = 0
                Matched             = 0
                AuthorFilteredCount = 0
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
                Entries             = @()
                FetchedAt           = (Get-Date)
                Source              = 'repo-resolution-failed'
                CacheAge            = [timespan]::Zero
                Truncated           = $false
                InvalidEntryCount   = 0
                Matched             = 0
                AuthorFilteredCount = 0
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
                Entries             = @()
                FetchedAt           = (Get-Date)
                Source              = 'repo-resolution-failed'
                CacheAge            = [timespan]::Zero
                Truncated           = $false
                InvalidEntryCount   = 0
                Matched             = 0
                AuthorFilteredCount = 0
            }
        }
    }

    # ---- Resolve cache path ----
    # Issue #842: the identity component is part of the cache key -- without
    # it, a later run under a DIFFERENT -JudgeLogin would silently read back
    # cache entries computed and author-filtered under a PRIOR identity
    # (cache poisoning across judge identities).
    if (-not $CachePath) {
        $CachePath = Join-Path ([System.IO.Path]::GetTempPath()) ".phase-containment-cache-$RepoOwner-$RepoName-$JudgeLogin.json"  # host-path-ok
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
        # M2 fix (issue #842 post-review): restore the persisted Matched/
        # AuthorFilteredCount window-level totals on a cache hit. Default to
        # 0 only when reading a LEGACY cache file written before this field
        # existed (ContainsKey guard), not for a fresh write.
        $cachedMatched = 0
        if ($cacheData.ContainsKey('matched') -and $null -ne $cacheData['matched']) {
            $cachedMatched = [int]$cacheData['matched']
        }
        $cachedAuthorFilteredCount = 0
        if ($cacheData.ContainsKey('author_filtered_count') -and $null -ne $cacheData['author_filtered_count']) {
            $cachedAuthorFilteredCount = [int]$cacheData['author_filtered_count']
        }
        # Compute cache age
        try {
            $genAt = [datetime]::Parse((script:ConvertTo-PhaseContainmentIsoString -Value $cacheData['generated_at']), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $genAtUtc = $genAt.Kind -eq [System.DateTimeKind]::Utc ? $genAt : $genAt.ToUniversalTime()
            $cacheAge = (Get-Date).ToUniversalTime() - $genAtUtc
        }
        catch {
            $cacheAge = [timespan]::Zero
        }
        return [PSCustomObject]@{
            Entries             = $cachedEntries
            FetchedAt           = (Get-Date)
            Source              = 'cache'
            CacheAge            = $cacheAge
            # A truncated run is never cached (see the cache-write guard
            # below), so a cache hit is by construction a complete snapshot.
            Truncated           = $false
            InvalidEntryCount   = $cachedInvalidEntryCount
            # M2 fix (issue #842 post-review): restored from the cache
            # payload (see above) rather than hardcoded to 0 -- a legacy
            # cache file written before this field existed still degrades
            # to 0 via the ContainsKey guard above.
            Matched             = $cachedMatched
            AuthorFilteredCount = $cachedAuthorFilteredCount
        }
    }

    # ---- GraphQL fetch ----
    $useRest             = $false
    $rawEntries          = [System.Collections.Generic.List[hashtable]]::new()
    $truncated           = $false
    $invalidEntryCount   = 0
    $matched             = 0
    $authorFilteredCount = 0

    if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        Write-Warning "phase-containment-rolling-history-core: timed out before GraphQL fetch"
        return [PSCustomObject]@{
            Entries             = @()
            FetchedAt           = (Get-Date)
            Source              = 'timeout'
            CacheAge            = [timespan]::Zero
            Truncated           = $false
            InvalidEntryCount   = 0
            Matched             = 0
            AuthorFilteredCount = 0
        }
    }

    $surfaceAResult = script:Get-SurfaceAEntriesGraphQL `
        -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
        -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds -JudgeLogin $JudgeLogin

    if ($surfaceAResult.IsError) {
        $useRest = $true
    }
    else {
        foreach ($e in $surfaceAResult.Entries) { $rawEntries.Add($e) }
        if ($surfaceAResult.Truncated) { $truncated = $true }
        $invalidEntryCount   += $surfaceAResult.InvalidEntryCount
        $matched             += $surfaceAResult.Matched
        $authorFilteredCount += $surfaceAResult.AuthorFilteredCount
    }

    if (-not $useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            # T1 (issue #772 P4): Surface A already succeeded and fetched
            # data — preserve those partials (and their InvalidEntryCount)
            # instead of discarding them, using the fetch path's own Source
            # rather than the empty 'timeout' shape.
            Write-Warning "phase-containment-rolling-history-core: timed out before Surface B fetch — returning Surface A partials (Truncated)"
            $dedupedPartial = Invoke-PhaseContainmentDedup -RawEntries $rawEntries.ToArray() -InvalidEntryCount ([ref]$invalidEntryCount)
            return [PSCustomObject]@{
                Entries             = $dedupedPartial
                FetchedAt           = (Get-Date)
                Source              = 'graphql'
                CacheAge            = [timespan]::Zero
                Truncated           = $true
                InvalidEntryCount   = $invalidEntryCount
                Matched             = $matched
                AuthorFilteredCount = $authorFilteredCount
            }
        }

        $surfaceBResult = script:Get-SurfaceBEntriesGraphQL `
            -Owner $RepoOwner -Repo $RepoName -WindowDays $WindowDays `
            -Stopwatch $stopwatch -TimeoutSeconds $TimeoutSeconds -JudgeLogin $JudgeLogin

        if ($surfaceBResult.IsError) {
            $useRest = $true
            $rawEntries.Clear()
        }
        else {
            foreach ($e in $surfaceBResult.Entries) { $rawEntries.Add($e) }
            if ($surfaceBResult.Truncated) { $truncated = $true }
            $invalidEntryCount   += $surfaceBResult.InvalidEntryCount
            $matched             += $surfaceBResult.Matched
            $authorFilteredCount += $surfaceBResult.AuthorFilteredCount
        }
    }

    # ---- REST fallback ----
    $sourceLabel = 'graphql'
    if ($useRest) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            Write-Warning "phase-containment-rolling-history-core: timed out before REST fallback"
            return [PSCustomObject]@{
                Entries             = @()
                FetchedAt           = (Get-Date)
                Source              = 'timeout'
                CacheAge            = [timespan]::Zero
                Truncated           = $false
                InvalidEntryCount   = 0
                Matched             = 0
                AuthorFilteredCount = 0
            }
        }

        $restResult = script:Get-PhaseContainmentEntriesRest `
            -WindowDays $WindowDays `
            -Stopwatch $stopwatch `
            -TimeoutSeconds $TimeoutSeconds `
            -JudgeLogin $JudgeLogin

        # M2 (reset-on-discard): $rawEntries/$truncated/$invalidEntryCount
        # accumulated from a discarded GraphQL surface are intentionally
        # overwritten here, not combined — the REST run owns its own state.
        $rawEntries.Clear()
        foreach ($e in $restResult.Entries) { $rawEntries.Add($e) }
        $truncated           = $restResult.Truncated
        $invalidEntryCount   = $restResult.InvalidEntryCount
        $matched             = $restResult.Matched
        $authorFilteredCount = $restResult.AuthorFilteredCount
        $sourceLabel         = 'rest'
    }

    # ---- Dedup ----
    $dedupedEntries = Invoke-PhaseContainmentDedup -RawEntries $rawEntries.ToArray() -InvalidEntryCount ([ref]$invalidEntryCount)

    # ---- Write cache (only if non-empty AND not truncated AND not a bypass run) ----
    # P7: a truncated run must not poison the 1-hour cache with an incomplete
    # snapshot — skipping the write here is what lets M2's reset-on-discard
    # actually matter (a fully-completed REST run after a discarded
    # truncated GraphQL attempt reports Truncated=$false and DOES cache).
    # M5 fix (issue #842 post-review): -SkipCacheWrite suppresses the write
    # entirely for a caller-signaled bypass/throwaway CachePath, so that path
    # is never populated with an orphan cache JSON.
    if ($dedupedEntries.Count -gt 0 -and -not $truncated -and -not $SkipCacheWrite) {
        script:Write-PhaseContainmentCache -CachePath $CachePath -Entries $dedupedEntries -InvalidEntryCount $invalidEntryCount -Matched $matched -AuthorFilteredCount $authorFilteredCount
    }

    return [PSCustomObject]@{
        Entries             = $dedupedEntries
        FetchedAt           = (Get-Date)
        Source              = $sourceLabel
        CacheAge            = [timespan]::Zero
        Truncated           = $truncated
        InvalidEntryCount   = $invalidEntryCount
        Matched             = $matched
        AuthorFilteredCount = $authorFilteredCount
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
          - RelaxationEligible signal. G-CR12 fix (PR #859 GitHub-review
            post-fix): this line previously described the retired
            single-arm rule ("requires N>=5, IrreducibleRate~0, no critical
            severity"). The shipped rule is two-arm: catch-side requires
            N>=5, EscapeRate < 5%, and no sustained critical OR high
            severity finding in the window (the veto also names 'high', not
            just 'critical' — issue #854 M4/AC4); for the code-review stage
            specifically, RelaxationEligible additionally requires a
            passing escape-side terminal observation (coverage measured,
            escape-arm reconciliation ok, unique-catch rate < 5% —
            TerminalObservation-gated, below) before it can be $true.
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
        Issue #854 M36: entries with caught_stage='post-review-observer' are excluded from
        the observed count before comparison, so a caller that has not yet started supplying
        observer-inclusive expectations does not spuriously fail closed once observer entries
        start appearing in the corpus.
    .PARAMETER TerminalObservation
        Optional hashtable, mirroring the $SustainedCounts idiom (optional, $null default,
        ContainsKey-guarded per key), carrying the pre-aggregated escape-side (post-review-
        observer) measurement for the code-review stage only. Issue #854 (governing principle:
        "coverage means measurement, not presence") - when $null, or when any contained guard
        fails, the code-review stage's RelaxationEligible is forced to $false (never upgraded
        by this parameter, only ever downgraded) whenever the catch-side computation above
        would otherwise have set it to $true. Design-challenge and plan-stress-test are
        unaffected; they have no downstream observer.

        All keys are optional; a missing key defaults as noted. Scoping rules below are the
        Seam Specification (binding on s3/s5/s6/s7) and are the CALLER's responsibility to
        honor when building this hashtable - this function consumes already-scoped counts,
        it does not re-derive them from raw finding records.

          CoObservedPRCount              [int]  N - total PR tuples observed in the code-review
                                                 window (every PR code-review already covers,
                                                 whether or not a review-dispositions record was
                                                 ever posted for it). This is NOT DD3's narrower
                                                 "co-observed" population (M12 fix) -- it is used
                                                 only as the denominator for the K-of-N coverage-
                                                 ratio display below. Default 0.
          MeasuredCoveragePRCount        [int]  K - PRs counting toward coverage AND DD3's
                                                 actual "co-observed" population: those with a
                                                 judge-authored, cleanly-parsed review-
                                                 dispositions record carrying an
                                                 ExternalSourcesReconciled coverage record (M9 -
                                                 a head-present, clean parse with zero entries IS
                                                 a legal coverage record; coverage means
                                                 measurement, not >=1 finding -- M5 fix removed
                                                 the earlier >=1-resolved-finding requirement).
                                                 InternalCoObservedCatchCount (n1) and the
                                                 Chapman estimator's n2/m are scoped to THIS
                                                 population, never to CoObservedPRCount's whole-
                                                 window N (M2/M12 fix). Default 0.
          DispositionsNovelExternalCount [int]  Dispositions-recorded external findings with
                                                 internal_match.match_status='novel', compared
                                                 against the emitted post-review-observer
                                                 blocks this function counts directly from
                                                 $Entries (M13 escape-arm reconciliation). The
                                                 review-dispositions record carries no
                                                 catchable_phase field, so this count spans ALL
                                                 catchable_phase values; the reconciliation
                                                 comparison below counts observer blocks the same
                                                 catchable_phase-blind way (M6 fix) -- only the
                                                 unique-catch-rate numerator stays scoped to
                                                 catchable_phase='implementation' per the Seam
                                                 Specification. Omitted -> reconciliation cannot
                                                 be verified and fails closed.
          InternalCoObservedCatchCount   [int]  n1 - caught_stage='code-review' AND
                                                 catchable_phase='implementation' entries,
                                                 restricted to MeasuredCoveragePRCount's PR set
                                                 (DD3's co-observed population), not
                                                 CoObservedPRCount's whole-window population
                                                 (M2/M12 fix). Default 0.
          ExternalCatchCount             [int]  n2 - external sustained findings on co-observed
                                                 PRs, excluding match_status 'ambiguous' and
                                                 'unresolved'. Default 0.
          DuplicateCount                 [int]  m - external sustained findings with
                                                 match_status 'duplicate' (the catch/escape
                                                 overlap). Default 0.
          ObserverEscapeCount            [int]  Numerator for the unique-catch rate. Defaults
                                                 to the observer-block count this function
                                                 derives from $Entries when omitted, scoped to
                                                 catchable_phase='implementation' per the Seam
                                                 Specification.
          ValueCacheOk                   [bool] Seam Specification -ValueCacheOk coherence
                                                 rule - $false withholds the escape arm
                                                 entirely. Default $true.
          CorpusTruncated                [bool] M8 fix: whether the review-cost comment CORPUS
                                                 fetch (distinct from the -Truncated switch
                                                 below, which reflects the separate VALUE fetch)
                                                 truncated. $true withholds the escape arm --
                                                 novel-carrying PRs may have silently dropped
                                                 from this derivation while K still reads >=5.
                                                 Default $false.
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
        [hashtable]$TerminalObservation = $null,
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
        # M36 (issue #854 s5): observer-caught entries (caught_stage=
        # 'post-review-observer') are excluded from the observed count
        # before comparing against $SustainedCounts. Those expectations are
        # derived from judge-rulings sustained counts that predate the
        # observer surface, so leaving them in would spuriously fail
        # closed for every caller that has not yet started supplying
        # observer-inclusive expectations.
        $observerCaughtCount = 0
        foreach ($e in $nonApparatusEntries) {
            $eCaughtStage = if ($e -is [hashtable]) { [string]$e['caught_stage'] } else { [string]$e.caught_stage }
            if ($eCaughtStage -eq 'post-review-observer') { $observerCaughtCount++ }
        }
        $nExcludingObserver = $n - $observerCaughtCount

        $dataUntrustworthy       = $false
        $dataUntrustworthyReason = $null
        if ($null -ne $SustainedCounts -and $SustainedCounts.ContainsKey($stage)) {
            $expectedCount = [int]$SustainedCounts[$stage]
            if ($nExcludingObserver -ne $expectedCount) {
                $dataUntrustworthy       = $true
                # Byte-identical to the pre-#854 message when no observer
                # entries are present (phase-containment-format-report.Tests.ps1
                # pins the exact "expected N sustained findings for 'stage',
                # observed M." wording); the observer-exclusion note is only
                # appended when it actually changed the observed count.
                $dataUntrustworthyReason = "Entry count mismatch: expected $expectedCount sustained findings for '$stage', observed $nExcludingObserver."
                if ($observerCaughtCount -gt 0) {
                    $entryWord = if ($observerCaughtCount -eq 1) { 'entry' } else { 'entries' }
                    $dataUntrustworthyReason = "Entry count mismatch: expected $expectedCount sustained findings for '$stage', observed $nExcludingObserver (excluding $observerCaughtCount observer-caught $entryWord)."
                }
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
        $relaxationEligible   = $null
        $criticalFindingCount = 0
        $highFindingCount     = 0
        if (-not $insufficientData -and -not $denominatorZero -and -not $dataUntrustworthy) {
            # Relaxation-eligible when escape_rate < 0.05 (effectively zero escapes) and no
            # critical- OR high-severity finding in the window. See #762 design notes for the
            # threshold rationale. Issue #854 M4: the catch-side veto previously checked only
            # 'critical', silently letting a sustained 'high' finding render ELIGIBLE -- AC4
            # requires the veto to cover critical/high and the render to name both counts and
            # severity, so both counts are tallied here (not a bare boolean) for the renderer.

            foreach ($e in $nonApparatusEntries) {
                $sev = if ($e -is [hashtable]) { [string]$e['severity'] } else { [string]$e.severity }
                if ($sev -eq 'critical') {
                    $criticalFindingCount++
                }
                elseif ($sev -eq 'high') {
                    $highFindingCount++
                }
            }

            $hasSeverityVeto = ($criticalFindingCount -gt 0) -or ($highFindingCount -gt 0)

            if ($null -ne $escapeRate -and $escapeRate -lt 0.05 -and -not $hasSeverityVeto) {
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

        # ---------------------------------------------------------------
        # Issue #854 s5: terminal-observation escape-side guard (M4/M7/M13).
        # INSERTION POINT IS EXACT: this runs AFTER the reason reset directly
        # above and BEFORE the C11 truncation override directly below.
        # Inserting it earlier would let this block's own reason be nulled
        # by the reset; inserting it later (inside/after C11) would let a
        # truncation override silently swallow an escape-side finding.
        #
        # Applies only to the code-review stage - the sole stage with a
        # downstream observer. "Coverage means measurement" (governing
        # principle): the escape-side stats below are computed and exposed
        # on the Stage object regardless of the catch-side verdict, so a
        # WITHHELD/NOT-ELIGIBLE catch side can still render an honest
        # escape-side arm (CE Gate S1/S3). The RelaxationEligible flag
        # itself is only ever DOWNGRADED here, never upgraded: catch-side
        # $true is a precondition of, never a consequence of, the escape
        # side passing (M10 precedence - both arms required for ELIGIBLE).
        # ---------------------------------------------------------------
        $coverageK                     = $null
        $coverageN                     = $null
        $coverageOk                    = $null
        $reconciliationOk              = $null
        $observerBlockCount            = $null
        $observerBlockCountAllPhases   = $null
        $dispositionsNovelCount        = $null
        $uniqueCatchRate               = $null
        $uniqueCatchRateAssessable     = $false
        $chapmanBothMissedEstimate     = $null
        $chapmanState                  = $null
        $escapeArmWithheld             = $false
        $escapeArmWithheldReason       = $null

        if ($stage -eq 'code-review') {
            if ($null -eq $TerminalObservation) {
                $escapeArmWithheld       = $true
                $escapeArmWithheldReason = 'terminal observation unavailable — escape-side coverage was not measured'
                if ($relaxationEligible -eq $true) {
                    $relaxationEligible       = $false
                    $relaxationEligibleReason = $escapeArmWithheldReason
                }
            }
            elseif ($TerminalObservation.ContainsKey('ValueCacheOk') -and -not [bool]$TerminalObservation['ValueCacheOk']) {
                $escapeArmWithheld       = $true
                $escapeArmWithheldReason = 'escape arm withheld — cached value population cannot be joined to a same-run corpus'
                if ($relaxationEligible -eq $true) {
                    $relaxationEligible       = $false
                    $relaxationEligibleReason = $escapeArmWithheldReason
                }
            }
            elseif ($TerminalObservation.ContainsKey('CorpusTruncated') -and [bool]$TerminalObservation['CorpusTruncated']) {
                # M8 fix: the review-cost comment CORPUS fetch truncated --
                # a DIFFERENT, independent fetch from the value fetch this
                # rollup's own -Truncated switch already gates on. A
                # truncated corpus can silently drop novel-carrying PRs
                # while K still reads >=5, undercounting misses toward a
                # false ELIGIBLE. Fail the escape arm closed here rather
                # than rely on a non-gating prose warning elsewhere.
                $escapeArmWithheld       = $true
                $escapeArmWithheldReason = 'escape arm withheld — the review-cost comment corpus fetch was truncated, so novel-carrying PRs may have silently dropped'
                if ($relaxationEligible -eq $true) {
                    $relaxationEligible       = $false
                    $relaxationEligibleReason = $escapeArmWithheldReason
                }
            }
            else {
                $coverageN  = if ($TerminalObservation.ContainsKey('CoObservedPRCount'))      { [int]$TerminalObservation['CoObservedPRCount'] }      else { 0 }
                $coverageK  = if ($TerminalObservation.ContainsKey('MeasuredCoveragePRCount')) { [int]$TerminalObservation['MeasuredCoveragePRCount'] } else { 0 }
                $coverageOk = ($coverageK -ge 5)

                if (-not $coverageOk) {
                    if ($relaxationEligible -eq $true) {
                        $relaxationEligible       = $false
                        $relaxationEligibleReason = "coverage insufficient: $coverageK of $coverageN co-observed PRs measured (need >=5)"
                    }
                }
                else {
                    # Escape-arm reconciliation (M13): the dispositions-
                    # recorded novel-external count is caller-supplied
                    # (dispositions data lives outside this ledger); the
                    # emitted observer-block count is counted directly from
                    # $Entries, which already carries any post-review-
                    # observer blocks fetched for this window. Comparing
                    # both explicitly - never inferring one from the other -
                    # is what keeps "0 misses" distinguishable from "0
                    # blocks emitted".
                    $dispositionsNovelCount = if ($TerminalObservation.ContainsKey('DispositionsNovelExternalCount')) { [int]$TerminalObservation['DispositionsNovelExternalCount'] } else { $null }

                    # M6 fix: the review-dispositions record carries no
                    # catchable_phase field at all, so DispositionsNovelExternalCount
                    # (above) is inherently catchable_phase-blind -- it counts every
                    # novel external finding the judge recorded, regardless of which
                    # bucket (design-challenge/plan-stress-test/code-review) the
                    # resulting observer block eventually routes to (AC7: observer
                    # entries route by catchable_phase and only ever ADD escapes to
                    # design/plan buckets, conservative, never irreducible).
                    # Reconciliation must compare the SAME population on both sides,
                    # so $observerBlockCountAllPhases (below) counts every emitted
                    # post-review-observer block regardless of catchable_phase. This
                    # is intentionally a DIFFERENT, wider count than $observerBlockCount
                    # (implementation-scoped, used below ONLY as the unique-catch-rate
                    # numerator default per the Seam Specification's "observer escapes
                    # in the numerator are scoped to catchable_phase: implementation"
                    # rule) -- a design/plan-catchable novel finding must not be
                    # misread as a reconciliation mismatch just because it is outside
                    # the unique-catch-rate's own, narrower scope.
                    $observerBlockCount          = 0
                    $observerBlockCountAllPhases = 0
                    foreach ($e in $Entries) {
                        $eCaughtStage    = if ($e -is [hashtable]) { [string]$e['caught_stage'] }    else { [string]$e.caught_stage }
                        $eCatchablePhase = if ($e -is [hashtable]) { [string]$e['catchable_phase'] }  else { [string]$e.catchable_phase }
                        if ($eCaughtStage -eq 'post-review-observer') {
                            $observerBlockCountAllPhases++
                            if ($eCatchablePhase -eq 'implementation') {
                                $observerBlockCount++
                            }
                        }
                    }

                    if ($null -eq $dispositionsNovelCount) {
                        $reconciliationOk = $false
                        if ($relaxationEligible -eq $true) {
                            $relaxationEligible       = $false
                            $relaxationEligibleReason = 'terminal observation incomplete — dispositions-recorded novel count unavailable for reconciliation'
                        }
                    }
                    elseif ($dispositionsNovelCount -ne $observerBlockCountAllPhases) {
                        $reconciliationOk = $false
                        if ($relaxationEligible -eq $true) {
                            $relaxationEligible       = $false
                            $relaxationEligibleReason = "escape-arm reconciliation failed: $dispositionsNovelCount dispositions-recorded novel finding(s) vs $observerBlockCountAllPhases emitted observer block(s)"
                        }
                    }
                    else {
                        $reconciliationOk = $true

                        # Unique-catch rate (M6, NaN-guarded): observer
                        # escapes / (internal co-observed catches + observer
                        # escapes). Denominator 0 -> $null, NEVER
                        # [double]::NaN - a naive division by zero returns
                        # NaN, and NaN satisfies neither -lt nor -ge, so a
                        # downstream "-not ($rate -ge 0.05)" check would read
                        # NaN as ELIGIBLE (verified live: `$nan -lt 0.05` and
                        # `$nan -ge 0.05` are both $false in PowerShell).
                        # Rejecting $null/IsNaN BEFORE any comparison is
                        # mandatory, not optional.
                        $n1              = if ($TerminalObservation.ContainsKey('InternalCoObservedCatchCount')) { [int]$TerminalObservation['InternalCoObservedCatchCount'] } else { 0 }
                        $observerEscapes = if ($TerminalObservation.ContainsKey('ObserverEscapeCount'))          { [int]$TerminalObservation['ObserverEscapeCount'] }          else { $observerBlockCount }
                        $uniqueCatchDenominator = $n1 + $observerEscapes

                        # M18 fix (post-fix judge-sustained review): widened
                        # from -eq 0 to -le 0 as defensive hardening. Not
                        # reachable from the current shipped caller (n1 and
                        # observerEscapes are both structurally non-negative
                        # int counts, so their sum can never be negative
                        # here), but this file's own doctrine elsewhere
                        # treats a denominator guard as mandatory, not
                        # optional, and -eq 0 alone would silently let a
                        # future negative-denominator regression divide
                        # through instead of routing to the not-assessable
                        # branch below.
                        if ($uniqueCatchDenominator -le 0) {
                            $uniqueCatchRate           = $null
                            $uniqueCatchRateAssessable = $false
                        }
                        else {
                            $uniqueCatchRate           = [double]$observerEscapes / [double]$uniqueCatchDenominator
                            $uniqueCatchRateAssessable = -not [double]::IsNaN($uniqueCatchRate)
                        }

                        if ((-not $uniqueCatchRateAssessable) -or ($null -eq $uniqueCatchRate)) {
                            $uniqueCatchRate           = $null
                            $uniqueCatchRateAssessable = $false
                            if ($relaxationEligible -eq $true) {
                                $relaxationEligible       = $false
                                $relaxationEligibleReason = 'escape-side unique-catch rate not assessable (no co-observed internal or observer catches)'
                            }
                        }
                        elseif ($uniqueCatchRate -ge 0.05) {
                            if ($relaxationEligible -eq $true) {
                                $relaxationEligible       = $false
                                $relaxationEligibleReason = "escape-side unique-catch rate too high ({0:P1} >= 5%)" -f $uniqueCatchRate
                            }
                        }
                        # else: escape side is clean; $relaxationEligible stands (unchanged).

                        # Chapman estimator (M11/M14) - informational, does
                        # NOT gate RelaxationEligible. Renders N-hat MINUS
                        # (n1+n2-m) under the "both missed" label - N-hat
                        # alone is the TOTAL population estimate, not what
                        # both reviewers missed. n2/m are caller-scoped per
                        # the Seam Specification (n2 excludes ambiguous and
                        # unresolved; m counts duplicate only).
                        $n2 = if ($TerminalObservation.ContainsKey('ExternalCatchCount')) { [int]$TerminalObservation['ExternalCatchCount'] } else { 0 }
                        $m  = if ($TerminalObservation.ContainsKey('DuplicateCount'))      { [int]$TerminalObservation['DuplicateCount'] }      else { 0 }

                        if ($m -lt 1) {
                            $chapmanState = 'sparse'
                        }
                        elseif ($m -gt [Math]::Min($n1, $n2)) {
                            $chapmanState = 'unavailable'
                        }
                        else {
                            $nHat = ((([double]$n1 + 1) * ([double]$n2 + 1)) / ([double]$m + 1)) - 1
                            $chapmanBothMissedEstimate = $nHat - ([double]$n1 + [double]$n2 - [double]$m)
                            $chapmanState              = 'estimate'
                        }
                    }
                }
            }
        }

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
            CriticalFindingCount      = $criticalFindingCount
            HighFindingCount          = $highFindingCount
            DataUntrustworthy         = $dataUntrustworthy
            DataUntrustworthyReason   = $dataUntrustworthyReason
            CoverageK                 = $coverageK
            CoverageN                 = $coverageN
            CoverageOk                = $coverageOk
            ReconciliationOk          = $reconciliationOk
            DispositionsNovelExternalCount = $dispositionsNovelCount
            ObserverBlockCount        = $observerBlockCount
            ObserverBlockCountAllPhases = $observerBlockCountAllPhases
            UniqueCatchRate           = $uniqueCatchRate
            UniqueCatchRateAssessable = $uniqueCatchRateAssessable
            ChapmanBothMissedEstimate = $chapmanBothMissedEstimate
            ChapmanState              = $chapmanState
            EscapeArmWithheld         = $escapeArmWithheld
            EscapeArmWithheldReason   = $escapeArmWithheldReason
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
          Rollup              [PSCustomObject] — Get-PhaseContainmentRollup return object
          Source              [string]         — 'graphql' | 'rest' | 'timeout' | 'repo-resolution-failed'
          Truncated           [bool]
          WindowDays          [int]
          FetchedAt           [datetime]
          InvalidEntryCount   [int]
          Matched             [int]    — issue #842 M22: window-level count of comment bodies that
                                         passed the judge-authorship gate. Default 0 (inert no-op) when
                                         omitted, matching every pre-existing caller of this function.
          CommentBodyCount    [int]    — window-level total comment bodies fetched (Matched +
                                         AuthorFilteredCount). Default 0 when omitted.
          AuthorFilteredCount [int]    — window-level count of bodies dropped by the judge-authorship
                                         gate. Default 0 when omitted.
          JudgeLogin          [string] — the judge identity the gate compared against. Default
                                         'github-actions[bot]' when omitted.
          JudgeLoginSource    [string] — provenance of JudgeLogin ('resolved from gh auth' or
                                         'from -JudgeLogin'). Default 'resolved from gh auth' when omitted.
    .OUTPUTS
        [string[]] — the report lines.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object]$Context
    )

    # Normalize field access for both hashtable and PSCustomObject
    $rollup             = if ($Context -is [hashtable]) { $Context['Rollup'] }              else { $Context.Rollup }
    $source             = if ($Context -is [hashtable]) { $Context['Source'] }              else { $Context.Source }
    $truncated          = if ($Context -is [hashtable]) { $Context['Truncated'] }           else { $Context.Truncated }
    $windowDays         = if ($Context -is [hashtable]) { $Context['WindowDays'] }          else { $Context.WindowDays }
    $fetchedAt          = if ($Context -is [hashtable]) { $Context['FetchedAt'] }           else { $Context.FetchedAt }
    $invalidEntryCount  = if ($Context -is [hashtable]) { $Context['InvalidEntryCount'] }   else { $Context.InvalidEntryCount }
    # Issue #842 M22: always-on judge-filter disclosure fields. Every field
    # below defaults to an inert value when the caller (any pre-existing
    # caller of this function) does not supply it.
    # Issue #842 M9 fix: these five fields are the NEWER Context members --
    # a PSCustomObject Context built before this disclosure feature existed
    # (or any fixture that omits them) has no such property at all. Bare
    # dot-access on a PSCustomObject missing a property throws
    # PropertyNotFoundException under this file's Set-StrictMode -Version
    # Latest, contradicting this function's own docstring claim that these
    # fields are an inert no-op when omitted -- that claim was only true for
    # the hashtable branch (indexer returns $null on a missing key). Route
    # every PSCustomObject read through a PSObject.Properties presence check
    # so a missing field degrades to $null (then to the 0/default literals
    # below), matching the hashtable branch's behavior instead of throwing.
    $matched             = if ($Context -is [hashtable]) { $Context['Matched'] }             else { $prop = $Context.PSObject.Properties['Matched'];             if ($null -ne $prop) { $prop.Value } else { $null } }
    $commentBodyCount    = if ($Context -is [hashtable]) { $Context['CommentBodyCount'] }    else { $prop = $Context.PSObject.Properties['CommentBodyCount'];    if ($null -ne $prop) { $prop.Value } else { $null } }
    $authorFilteredCount = if ($Context -is [hashtable]) { $Context['AuthorFilteredCount'] } else { $prop = $Context.PSObject.Properties['AuthorFilteredCount']; if ($null -ne $prop) { $prop.Value } else { $null } }
    $judgeLogin          = if ($Context -is [hashtable]) { $Context['JudgeLogin'] }          else { $prop = $Context.PSObject.Properties['JudgeLogin'];          if ($null -ne $prop) { $prop.Value } else { $null } }
    $judgeLoginSource    = if ($Context -is [hashtable]) { $Context['JudgeLoginSource'] }    else { $prop = $Context.PSObject.Properties['JudgeLoginSource'];    if ($null -ne $prop) { $prop.Value } else { $null } }

    if ($null -eq $matched) { $matched = 0 }
    if ($null -eq $commentBodyCount) { $commentBodyCount = 0 }
    if ($null -eq $authorFilteredCount) { $authorFilteredCount = 0 }
    if ([string]::IsNullOrEmpty($judgeLogin)) { $judgeLogin = 'github-actions[bot]' }
    if ([string]::IsNullOrEmpty($judgeLoginSource)) { $judgeLoginSource = 'resolved from gh auth' }

    $lines = [System.Collections.Generic.List[string]]::new()

    # ---- Render header ----

    $headerSuffix = if ($truncated) { ' (TRUNCATED — results incomplete)' } else { '' }

    $lines.Add('')
    $lines.Add('Phase-Containment Escape-Rate Ledger')
    $lines.Add("Window: ${windowDays}d | Fetched: $($fetchedAt.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC | Source: $source$headerSuffix")
    $lines.Add("Total entries processed: $($rollup.WindowEntryCount) | Apparatus-meta entries: $($rollup.ApparatusMetaCount)")
    if ($invalidEntryCount -gt 0) {
        # Issue #842 s6 (Task 4): no workflow runs this report -- there are no
        # "gh Action run logs" to see. Re-running the command locally is the
        # only way a maintainer can actually inspect the dropped bodies.
        $lines.Add("WARNING: $invalidEntryCount phase-containment block(s) dropped as invalid/unparseable during this fetch — re-run this command locally to inspect the dropped comment bodies.")
    }
    $lines.Add("Judge filter: matched $matched of $commentBodyCount comment bodies (identity: $judgeLogin, $judgeLoginSource)")
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

            # Issue #842 M7/M9: four-state discrimination of the
            # DenominatorZero branch. Precedence matters -- checked in this
            # exact order:
            #   1. matched==0 AND AuthorFilteredCount>0 -> FILTERED-EMPTY
            #      (the judge filter itself matched nothing; checked FIRST
            #      so it wins over a coincidentally-nonzero InvalidEntryCount
            #      or a contradictory CommentBodyCount).
            #   2. entries==0 (this branch) AND InvalidEntryCount>0 AND the
            #      WINDOW itself is empty ($rollup.WindowEntryCount -eq 0) ->
            #      INVALID-EMPTY. Keyed on InvalidEntryCount, NEVER on
            #      matched>0 alone -- a null Get-PhaseContainmentBlock return
            #      (zero blocks found) increments no counter, so matched>0
            #      alone would misrender "zero blocks found" as "all
            #      rejected".
            #      M3 fix (issue #842 post-review): $invalidEntryCount and
            #      $commentBodyCount are WINDOW-level totals read once above
            #      the per-stage loop, not scoped to this stage. Without the
            #      WindowEntryCount==0 guard, a stage that is empty purely
            #      from DATA ABSENCE (real entries exist in a SIBLING stage,
            #      plus an unrelated invalid block dropped somewhere else in
            #      the window) would falsely render "every parsed block
            #      failed validation" for a stage that never had any block
            #      to begin with. When the window has entries elsewhere,
            #      this stage's own emptiness is legitimate data-absence --
            #      fall through to the bare, unqualified WITHHELD below
            #      rather than explaining it via invalid/filtered accounting
            #      that does not actually belong to this stage.
            #   3. CommentBodyCount>0 (bodies were fetched, matched
            #      something, nothing dropped) AND the window itself is
            #      empty -> the honest genuinely-measured-but-empty state:
            #      bare "WITHHELD (denominator=0)" gains an appended
            #      matched/N detail suffix. Same M3 window-emptiness guard
            #      as state 2, for the same reason -- CommentBodyCount>0
            #      does not imply THIS stage was the one measured empty.
            #   4. CommentBodyCount==0 -> the pre-existing, UNCHANGED bare
            #      "WITHHELD (denominator=0)" (no bodies fetched at all).
            if ($matched -eq 0 -and $authorFilteredCount -gt 0) {
                $lines.Add("  Relaxation signal:  FILTERED-EMPTY — judge filter matched $matched of $commentBodyCount bodies (looked for '$judgeLogin'); check -JudgeLogin")
            }
            elseif ($invalidEntryCount -gt 0 -and $rollup.WindowEntryCount -eq 0) {
                $lines.Add("  Relaxation signal:  INVALID-EMPTY — $matched of $commentBodyCount bodies matched but every parsed block failed validation ($invalidEntryCount dropped); see WARNINGs above")
            }
            elseif ($commentBodyCount -gt 0 -and $rollup.WindowEntryCount -eq 0) {
                $lines.Add("  Relaxation signal:  WITHHELD (denominator=0) — $matched of $commentBodyCount bodies matched; none carried a phase-containment block")
            }
            else {
                $lines.Add("  Relaxation signal:  WITHHELD (denominator=0)")
            }
        }
        elseif ($stage.InsufficientData) {
            $lines.Add("  Escape rate:        INSUFFICIENT DATA (n=$($stage.N) < 5)")
            $lines.Add("  Irreducible rate:   INSUFFICIENT DATA")
            $lines.Add("  Relaxation signal:  WITHHELD (n<5)")
            if ($authorFilteredCount -gt 0) {
                # Issue #842 M22: a filter-induced drop below n=5 must not
                # read as an innocuous "we need more data" -- disclose the
                # filtered count here too, not just in the header.
                $lines.Add("  ($authorFilteredCount comment body/bodies filtered by the judge-authorship gate)")
            }
        }
        elseif ($stage.DataUntrustworthy) {
            $escapeDisplay      = if ($null -ne $stage.EscapeRate)      { '{0:P1}' -f $stage.EscapeRate }      else { 'N/A' }
            $irreducibleDisplay = if ($null -ne $stage.IrreducibleRate) { '{0:P1}' -f $stage.IrreducibleRate } else { 'N/A' }
            $lines.Add("  Escape rate:        $escapeDisplay")
            $lines.Add("  Irreducible rate:   $irreducibleDisplay")
            $lines.Add("  Relaxation signal:  WITHHELD (data untrustworthy)")
            if ($authorFilteredCount -gt 0) {
                # Issue #842 M10 fix: InsufficientData and the clean render
                # both carry this always-on M22 disclosure line; DataUntrustworthy
                # was the one sibling branch missing it.
                $lines.Add("  ($authorFilteredCount comment body/bodies filtered by the judge-authorship gate)")
            }
        }
        else {
            $escapeCount      = [int][Math]::Round($stage.EscapeRate      * $stage.Denominator)
            $irreducibleCount = [int][Math]::Round($stage.IrreducibleRate * $stage.Denominator)

            $escapeDisplay      = '{0:F2} ({1} of {2} escaped)' -f $stage.EscapeRate, $escapeCount, $stage.Denominator
            $irreducibleDisplay = '{0:F2} ({1} of {2} irreducible)' -f $stage.IrreducibleRate, $irreducibleCount, $stage.Denominator

            $lines.Add("  Escape rate:        $escapeDisplay")
            $lines.Add("  Irreducible rate:   $irreducibleDisplay")

            if ($authorFilteredCount -gt 0) {
                # Issue #842 M22: a 16-body window with 10 identity-dropped
                # must not silently narrow the denominator without
                # disclosure, even on a clean-looking non-empty render.
                $lines.Add("  ($authorFilteredCount comment body/bodies filtered by the judge-authorship gate)")
            }

            if ($null -eq $stage.RelaxationEligible) {
                $lines.Add("  Relaxation signal:  WITHHELD")
            }
            elseif ($stage.RelaxationEligible -eq $true) {
                $lines.Add("  Relaxation signal:  ELIGIBLE (escape_rate ~0, no critical/high findings)")
            }
            elseif ($stage.RelaxationEligibleReason -eq 'fetch truncated') {
                # P9: checked BEFORE the EscapeRate reason-guess below so a
                # truncated run never falls through to the misleading
                # "NOT ELIGIBLE (escape_rate > 0)" text.
                $lines.Add("  Relaxation signal:  WITHHELD (fetch truncated)")
            }
            elseif ($stage.RelaxationEligibleReason -like 'escape-side unique-catch rate too high*') {
                # G-CR4 fix (PR #859 GitHub-review post-fix): this reason is
                # a genuinely MEASURED assessed-high escape rate (M6's
                # $uniqueCatchRate -ge 0.05 branch), not an unavailable/
                # withheld assessment -- rendering it as WITHHELD mislabels a
                # real escape-side failure as "not measured." The reason text
                # already carries the measured percentage; this branch just
                # gives it the matching escape-side NOT ELIGIBLE headline
                # instead of the generic WITHHELD one below.
                $lines.Add("  Relaxation signal:  NOT ELIGIBLE ($($stage.RelaxationEligibleReason))")
            }
            elseif ($null -ne $stage.RelaxationEligibleReason) {
                # Issue #854 s6 reason-ladder extension: check the reason
                # field BEFORE falling through to the two-branch escape-
                # rate/critical-severity guess below, mirroring the P9
                # 'fetch truncated' precedent immediately above. Without
                # this check, a downgrade set by the code-review escape-
                # side guard in Get-PhaseContainmentRollup (coverage
                # insufficient, reconciliation failure, unassessable
                # unique-catch rate) mis-renders as the generic "critical
                # severity finding in window" guess, since RelaxationEligible
                # is $false either way and the guess below cannot tell the
                # two situations apart.
                $lines.Add("  Relaxation signal:  WITHHELD ($($stage.RelaxationEligibleReason))")
            }
            else {
                # Determine reason
                if ($stage.EscapeRate -ge 0.05) {
                    $lines.Add("  Relaxation signal:  NOT ELIGIBLE (escape_rate > 0)")
                }
                else {
                    # Issue #854 M4: the catch-side veto now fires for a
                    # sustained 'high'-severity finding the same as
                    # 'critical' (AC4), so the render must name both counts
                    # and the severities that triggered the block instead of
                    # a bare "critical severity finding in window" guess.
                    $lines.Add("  Relaxation signal:  NOT ELIGIBLE ($($stage.CriticalFindingCount) critical, $($stage.HighFindingCount) high severity finding(s) in window)")
                }
            }
        }

        $lines.Add('')

        # -----------------------------------------------------------------
        # Issue #854 s6 (M21): the code-review row renders an independent
        # escape-side (post-review-observer) arm, regardless of which
        # catch-side branch above fired (denominator=0, n<5, data
        # untrustworthy, or the normal reason-ladder render) — the previous
        # short-circuit chain returned before ever reaching escape-side
        # data, so a coverage-insufficient or reconciliation-failed window
        # was indistinguishable from a genuinely clean one. Upstream stages
        # (design-challenge, plan-stress-test) have no downstream observer
        # and are unaffected — this block only ever fires for code-review.
        # -----------------------------------------------------------------
        if ($stageName -eq 'code-review') {
            $lines.Add("  Escape-side (post-review observer):")

            if ($stage.EscapeArmWithheld) {
                $lines.Add("    Coverage:           NOT ASSESSABLE ($($stage.EscapeArmWithheldReason))")
            }
            elseif ($null -eq $stage.CoverageK -or $null -eq $stage.CoverageN) {
                # Defensive fallback -- should only be reachable if a future
                # caller supplies a TerminalObservation shape this renderer
                # does not yet know how to read.
                $lines.Add("    Coverage:           NOT ASSESSABLE (escape-side data unavailable)")
            }
            elseif (-not $stage.CoverageOk) {
                $lines.Add("    Coverage:           $($stage.CoverageK) of $($stage.CoverageN) co-observed PRs measured (need >=5)")
                $lines.Add("    Escape-side signal: NOT ASSESSABLE (coverage insufficient)")
            }
            else {
                $lines.Add("    Coverage:           $($stage.CoverageK) of $($stage.CoverageN) co-observed PRs measured")

                if ($stage.ReconciliationOk -eq $false) {
                    $novelDisplay = if ($null -ne $stage.DispositionsNovelExternalCount) { [string]$stage.DispositionsNovelExternalCount } else { 'unavailable' }
                    # M6 fix: render the SAME catchable_phase-blind count the
                    # reconciliation check actually compared against
                    # ($ObserverBlockCountAllPhases), not the narrower
                    # catchable_phase=implementation-only $ObserverBlockCount
                    # (that field is reserved for the unique-catch-rate's own
                    # miss-count display below) -- otherwise the rendered
                    # numbers would not match the comparison that actually
                    # failed.
                    $lines.Add("    Escape-side signal: NOT ASSESSABLE (escape-arm reconciliation failed: $novelDisplay dispositions-recorded novel finding(s) vs $($stage.ObserverBlockCountAllPhases) emitted observer block(s))")
                }
                else {
                    $lines.Add("    Miss count (observer blocks): $($stage.ObserverBlockCount)")

                    if (-not $stage.UniqueCatchRateAssessable -or $null -eq $stage.UniqueCatchRate) {
                        $lines.Add("    Unique-catch rate:  NOT ASSESSABLE (no co-observed internal or observer catches)")
                    }
                    else {
                        $lines.Add(("    Unique-catch rate:  {0:P1}" -f $stage.UniqueCatchRate))
                    }

                    switch ($stage.ChapmanState) {
                        'estimate' { $lines.Add(("    Chapman (both-missed est.): {0:F1}" -f $stage.ChapmanBothMissedEstimate)) }
                        'sparse' { $lines.Add("    Chapman (both-missed est.): overlap too sparse") }
                        'unavailable' { $lines.Add("    Chapman (both-missed est.): estimate unavailable -- overlap exceeds observed population") }
                        default { $lines.Add("    Chapman (both-missed est.): not computed") }
                    }

                    $lines.Add("    Caveat: this is a lower-bound, correlated-blind-spot estimate -- both the pipeline and the external reviewer may share systemic blind spots this corpus cannot detect.")
                }
            }

            $lines.Add('')
        }
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
