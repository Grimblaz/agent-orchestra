#Requires -Version 7.0
<#
.SYNOPSIS
    Renders the derived portfolio tracker for issue #692 (control tower issue).

.DESCRIPTION
    Implements the Renderer Contract:
      - ConvertFrom-SequenceSpec  : parse flat YAML sequence spec (no ConvertFrom-Yaml)
      - Get-PortfolioBuckets      : classify issues into Now/Next/Blocked/RecentlyClosed/Triage
      - Format-PortfolioMarkdown  : render bucket model to Markdown
      - Get-SplicedBody           : idempotent splice into issue body
      - Invoke-PortfolioRender    : full pipeline end-to-end

    Test helper functions (New-ValidSpecYaml, New-IssueState) are co-located here so
    that Pester 5 BeforeAll dot-source makes them available in It blocks.

.PARAMETER specPath
    Path to the sequence.yaml spec file. Defaults to Documents/Planning/sequence.yaml.
#>

param(
    [string]$specPath = 'Documents/Planning/sequence.yaml'
)

# ---------------------------------------------------------------------------
# Marker constants (used by Invoke-PortfolioRender)
# ---------------------------------------------------------------------------
$MARKER_BEGIN = '<!-- portfolio-tracker:begin -->'
$MARKER_END   = '<!-- portfolio-tracker:end -->'

# ---------------------------------------------------------------------------
# Pure helper functions (no I/O)
# ---------------------------------------------------------------------------

# Returns $true when the fetched connection was truncated (totalCount exceeds fetched
# node count). Compares against the raw fetched nodes — never a filtered/derived set.
# Null nodes => no data, not overflow.
function Test-ConnectionOverflow {
    param([int]$TotalCount, $Nodes)
    if ($null -eq $Nodes) { return $false }
    return $TotalCount -gt @($Nodes).Count
}

# Returns a sort-key integer for priority labels: lower = higher priority.
function Get-PriorityKey {
    param([string[]]$labels)
    if ($labels -contains 'priority: high')   { return 0 }
    if ($labels -contains 'priority: medium') { return 1 }
    if ($labels -contains 'priority: low')    { return 2 }
    return 3  # unlabeled / last
}

# Returns -Ticks for descending createdAt sort, or 0 when createdAt is absent/unparseable.
function Get-CreatedAtSortTicks {
    param([string]$createdAt)
    if ($createdAt) {
        try { return -[datetimeoffset]::Parse($createdAt).UtcTicks } catch { }
    }
    return 0
}

# Returns the count of $items, or 0 when $items is $null.
function Get-BucketTotal {
    param([array]$items)
    if ($null -ne $items) { return $items.Count }
    return 0
}

# Returns the numeric model property $propName when present, otherwise $renderedCount.
function Get-ModelTotal {
    param([object]$model, [string]$propName, [int]$renderedCount)
    $prop = $model.PSObject.Properties[$propName]
    if ($null -ne $prop) {
        return [int]$prop.Value
    }
    return $renderedCount
}

# ---------------------------------------------------------------------------
# ConvertFrom-SequenceSpec
# Parse a flat-YAML sequence spec string using regex only (no ConvertFrom-Yaml).
# Returns a PSCustomObject or $null on validation failure.
# ---------------------------------------------------------------------------
function ConvertFrom-SequenceSpec {
    param([string]$yamlText)

    try {
        # Reject block-style issues list (issues on separate lines with leading dash)
        if ($yamlText -match "issues:\s*\r?\n\s+-") {
            return $null
        }

        # Require schema_version as integer
        if ($yamlText -notmatch '(?m)^\s*schema_version:\s*(\d+)') { return $null }
        $schema_version = [int]$Matches[1]

        # Reject quoted control_tower
        if ($yamlText -match '(?m)^\s*control_tower:\s*"') { return $null }

        # Require control_tower as unquoted integer
        if ($yamlText -notmatch '(?m)^\s*control_tower:\s*(\d+)') { return $null }
        $control_tower = [int]$Matches[1]

        # Require recently_closed_days as integer
        if ($yamlText -notmatch '(?m)^\s*recently_closed_days:\s*(\d+)') { return $null }
        $recently_closed_days = [int]$Matches[1]

        # Parse rounds — each round block: "- lane: X\n    round: N\n    issues: [...]"
        $rounds = @()
        $roundMatches = [regex]::Matches(
            $yamlText,
            '-\s+lane:\s*(\S+)\s+round:\s*(\d+)\s+issues:\s*\[([^\]]*)\]'
        )
        foreach ($m in $roundMatches) {
            $lane      = $m.Groups[1].Value.Trim()
            $round     = [int]$m.Groups[2].Value
            $rawList   = $m.Groups[3].Value
            $issueNums = $rawList -split ',' |
                         ForEach-Object { $_.Trim() } |
                         Where-Object   { $_ -match '^\d+$' } |
                         ForEach-Object { [int]$_ } |
                         Where-Object   { $_ -gt 0 }
            $rounds += [PSCustomObject]@{
                lane   = $lane
                round  = $round
                issues = @($issueNums)
            }
        }

        # Validate: each "- lane:" block must produce exactly one parsed round
        $expectedRoundCount = ([regex]::Matches($yamlText, '(?m)^\s*-\s+lane:')).Count
        if ($expectedRoundCount -gt 0 -and $rounds.Count -ne $expectedRoundCount) {
            Write-Error ("sequence.yaml: round parse mismatch — found {0} '- lane:' blocks but only {1} parsed correctly. " +
                "Each round must have lane:, round:, and issues: on consecutive lines." -f $expectedRoundCount, $rounds.Count)
            return $null
        }

        return [PSCustomObject]@{
            schema_version       = $schema_version
            control_tower        = $control_tower
            recently_closed_days = $recently_closed_days
            rounds               = $rounds
        }
    }
    catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Get-PortfolioBuckets
# Classifies issueStateObjects into Now/Next/Blocked/RecentlyClosed/Triage.
#
# issueStateObjects fields:
#   .number (int), .state ('OPEN'/'CLOSED'), .title (string), .labels (string[])
#   .blockedBy (int[]), .blockerInPlan (bool), .closedAt (string ISO or $null)
#   .totalCount (int)
# ---------------------------------------------------------------------------
function Get-PortfolioBuckets {
    param(
        $spec,
        $issueStateObjects,
        # s3 parameters — KnownChildSet is an array of issue numbers that are
        # children of sequenced umbrellas. OpenLeafCandidates and ClosedLeafItems
        # come from s2's repo-wide scans and are passed through for RecentlyClosed.
        $KnownChildSet      = $null,   # array of child issue numbers (from sequenced umbrellas)
        $OpenLeafCandidates = $null,   # array of open-scan issue objects (unused in pure derivation)
        $ClosedLeafItems    = $null    # array of closed-scan issue objects (for RecentlyClosed)
    )

    # Multi-lane guard (CR8): the per-lane Now/Next/Blocked derivation required
    # by the portfolio contract is not yet implemented — this function flattens
    # all rounds and derives a single global flow. That is correct only for a
    # single-lane spec. Rather than silently merge multiple lanes into one
    # board (the silently-wrong-board failure this tracker exists to kill),
    # fail loud until per-lane derivation lands.
    $distinctLanes = @($spec.rounds | ForEach-Object { $_.lane } | Sort-Object -Unique)
    if ($distinctLanes.Count -gt 1) {
        throw "Multi-lane specs are not yet supported by bucket derivation (found lanes: $($distinctLanes -join ', ')). Per-lane Now/Next/Blocked derivation is tracked separately; refusing to render to avoid silently merging lanes into one board."
    }

    # All umbrella numbers: every issue listed in any round of sequence.yaml.
    $allIssueNumbers = @(
        $spec.rounds | ForEach-Object { $_.issues } | Sort-Object -Unique
    )

    # Sorted rounds for active-round detection.
    $sortedRounds = @($spec.rounds | Sort-Object round)

    # Known child set: build a lookup set for O(1) membership checks.
    # KnownChildSet from tests is a plain array of issue numbers.
    $knownChildNumbers = [System.Collections.Generic.HashSet[int]]::new()
    if ($null -ne $KnownChildSet) {
        foreach ($item in $KnownChildSet) {
            if ($item -is [int] -or $item -is [long] -or ($item -is [string] -and $item -match '^\d+$')) {
                $null = $knownChildNumbers.Add([int]$item)
            }
            elseif ($null -ne $item -and $null -ne $item.PSObject.Properties['number']) {
                $null = $knownChildNumbers.Add([int]$item.number)
            }
        }
    }

    # Umbrella number → round index lookup.
    $umbrellaToRoundIdx = @{}
    for ($ri = 0; $ri -lt $sortedRounds.Count; $ri++) {
        foreach ($num in $sortedRounds[$ri].issues) {
            $umbrellaToRoundIdx[[int]$num] = $ri
        }
    }

    # KnownChildSet round-affiliation: when items are plain ints (no parent-umbrella info),
    # we default their round index to 1 (non-active). This correctly routes non-active-round
    # spine children (e.g. children of round-2 umbrellas) to Next rather than Now.
    # When items are PSCustomObjects with RoundIndex or UmbrellaNumber, we use that directly.
    $cutoff = [datetimeoffset](Get-Date -AsUTC).AddDays(-$spec.recently_closed_days)

    $closedWithinWindow = [System.Collections.Generic.List[object]]::new()
    $openBlocked        = [System.Collections.Generic.List[object]]::new()
    $openUnblocked      = [System.Collections.Generic.List[object]]::new()
    $triage             = [System.Collections.Generic.List[object]]::new()

    # When ClosedLeafItems is provided (repo-wide closed scan), source RecentlyClosed
    # from it directly — filtering out umbrella numbers (AC9 requires leaf closures only).
    # This replaces the per-issueStateObjects CLOSED detection for RecentlyClosed.
    if ($null -ne $ClosedLeafItems) {
        foreach ($leaf in $ClosedLeafItems) {
            if ($allIssueNumbers -contains [int]$leaf.number) { continue }
            if ($leaf.closedAt) {
                [datetimeoffset]$leafClosedDate = [datetimeoffset]::MinValue
                if ([datetimeoffset]::TryParse($leaf.closedAt, [ref]$leafClosedDate)) {
                    if ($leafClosedDate -ge $cutoff) {
                        $closedWithinWindow.Add($leaf)
                    }
                }
            }
        }
    }

    # Build per-child round affiliation from KnownChildSet.
    # Support two formats:
    #   1. Array of int/string → child number only; round affiliation unknown → "spine-next"
    #   2. Array of PSCustomObject with .number and .UmbrellaNumber/.RoundIndex → use parent info
    $childRoundIndex = @{}   # child number → round index (0 = active, 1+ = non-active)
    $childToUmbrella = @{}   # child number → parent umbrella number (rich-object path only)
    if ($null -ne $KnownChildSet) {
        foreach ($item in $KnownChildSet) {
            $childNum = $null
            $roundIdx = -1   # -1 = unknown
            $umbNum   = $null

            if ($item -is [int] -or $item -is [long]) {
                $childNum = [int]$item
            }
            elseif ($item -is [string] -and $item -match '^\d+$') {
                $childNum = [int]$item
            }
            elseif ($null -ne $item) {
                $props = $item.PSObject.Properties
                if ($null -ne $props['number']) {
                    $childNum = [int]$item.number
                }
                if ($null -ne $props['RoundIndex']) {
                    $roundIdx = [int]$item.RoundIndex
                }
                elseif ($null -ne $props['UmbrellaNumber']) {
                    $umbNum = [int]$item.UmbrellaNumber
                    if ($umbrellaToRoundIdx.ContainsKey($umbNum)) {
                        $roundIdx = $umbrellaToRoundIdx[$umbNum]
                    }
                }
                if ($null -ne $props['UmbrellaNumber']) {
                    $umbNum = [int]$item.UmbrellaNumber
                }
            }

            if ($null -ne $childNum) {
                # If round index is unknown, default to 1 (non-active — round 1+ heuristic).
                # This handles flat int array passing convention from tests.
                if ($roundIdx -lt 0) { $roundIdx = 1 }
                $childRoundIndex[[int]$childNum] = $roundIdx
                if ($null -ne $umbNum) {
                    $childToUmbrella[[int]$childNum] = [int]$umbNum
                }
            }
        }
    }

    foreach ($issue in $issueStateObjects) {
        if ($issue.state -eq 'CLOSED') {
            # Only add to RecentlyClosed from issueStateObjects when ClosedLeafItems is not
            # provided (legacy path). When ClosedLeafItems is provided, RecentlyClosed is
            # sourced from the repo-wide scan above (excluding umbrella closures per AC9).
            if ($null -eq $ClosedLeafItems -and $issue.closedAt) {
                [datetimeoffset]$closedDate = [datetimeoffset]::MinValue
                if ([datetimeoffset]::TryParse($issue.closedAt, [ref]$closedDate)) {
                    if ($closedDate -ge $cutoff) {
                        $closedWithinWindow.Add($issue)
                    }
                }
            }
            continue
        }

        # Determine classification for this open issue.
        $isUmbrella     = $allIssueNumbers -contains $issue.number
        $isSpineChild   = $childRoundIndex.ContainsKey([int]$issue.number)
        $hasTriageLabel = $issue.labels -contains 'triage'

        # Triage: triage-labeled issues always go to Triage.
        if ($hasTriageLabel) {
            $triage.Add($issue)
            continue
        }

        # Legacy path (KnownChildSet not provided): unsequenced open issues → Triage.
        # When KnownChildSet is $null, the caller is using the old API convention where
        # only sequenced issues were passed in issueStateObjects and any unsequenced
        # issue (not in any round) belongs in Triage. This preserves backward compatibility
        # with existing tests that don't pass KnownChildSet.
        if ($null -eq $KnownChildSet -and (-not $isUmbrella) -and (-not $isSpineChild)) {
            $triage.Add($issue)
            continue
        }

        # Determine isFloat: open, not an umbrella, NOT in KnownChildSet
        # (Only applies when KnownChildSet is provided — floats land in Now)
        $isFloat = (-not $isUmbrella) -and (-not $isSpineChild)

        # Determine inProgress: has 'in progress' label
        $isInProgress = $issue.labels -contains 'in progress'

        # Attach derived properties
        $issue | Add-Member -NotePropertyName 'isFloat'    -NotePropertyValue $isFloat    -Force
        $issue | Add-Member -NotePropertyName 'inProgress' -NotePropertyValue $isInProgress -Force

        # Check blockers: blocked if blockedBy is non-empty (open blockers only — already filtered by Invoke-PortfolioRender)
        $hasBlockers = $issue.blockedBy -and $issue.blockedBy.Count -gt 0

        if ($hasBlockers) {
            # Build per-blocker annotations (CR7)
            $annotations = $issue.blockedBy | ForEach-Object {
                $blockerNum = $_
                if ($allIssueNumbers -notcontains $blockerNum) {
                    "blocked by #$blockerNum (out of plan)"
                }
                else {
                    "blocked by #$blockerNum"
                }
            }
            $issue | Add-Member -NotePropertyName 'blockerAnnotations' `
                                -NotePropertyValue ($annotations -join ', ') `
                                -Force
            $openBlocked.Add($issue)
        }
        else {
            $openUnblocked.Add($issue)
        }
    }

    # Determine active round index: lowest round that has open issues (blocked or unblocked)
    $allOpenIssues = @($openBlocked) + @($openUnblocked)
    $nowRoundIdx   = -1
    for ($i = 0; $i -lt $sortedRounds.Count; $i++) {
        $roundUmbrellaNums = $sortedRounds[$i].issues
        $hasOpenUmbrella   = $allOpenIssues | Where-Object { $roundUmbrellaNums -contains $_.number }
        if ($hasOpenUmbrella) {
            $nowRoundIdx = $i
            break
        }
    }

    $nowIssues  = [System.Collections.Generic.List[object]]::new()
    $nextIssues = [System.Collections.Generic.List[object]]::new()

    if ($nowRoundIdx -ge 0) {
        $nowRoundNums = @($sortedRounds[$nowRoundIdx].issues)

        # Partition open unblocked issues into Now/Next/float buckets.
        foreach ($issue in $openUnblocked) {
            $num = [int]$issue.number

            if ($nowRoundNums -contains $num) {
                # Active-round umbrella: container only — do not render as a work item
                continue
            }
            elseif ($childRoundIndex.ContainsKey($num)) {
                # Spine child — route by round index
                $childRound = $childRoundIndex[$num]
                if ($childRound -le $nowRoundIdx) {
                    # Active-round spine child → Now
                    $nowIssues.Add($issue)
                }
                else {
                    # Non-active-round spine child → Next
                    $nextIssues.Add($issue)
                }
            }
            elseif ($allIssueNumbers -contains $num) {
                # Non-active-round umbrella: container only — do not render as a work item
                continue
            }
            else {
                # Float (not umbrella, not spine child, not triage) → Now
                $nowIssues.Add($issue)
            }
        }

    }
    else {
        # No active round found — all open unblocked issues are floats → Now
        foreach ($issue in $openUnblocked) {
            $nowIssues.Add($issue)
        }
    }

    # Apply ordering to Now: current-round-spine-first → createdAt desc → priority-label tiebreak → number asc
    # Current-round spine: issues in nowRoundNums (not float)
    # Floats: issues with isFloat=$true
    $nowSorted = @(
        $nowIssues | Sort-Object -Property `
            @{ Expression = { if ($_.isFloat) { 1 } else { 0 } } },
            @{ Expression = { Get-CreatedAtSortTicks $_.createdAt } },
            @{ Expression = { Get-PriorityKey $_.labels } },
            @{ Expression = { $_.number } }
    )

    # Apply ordering to Next: createdAt desc → priority → number asc
    $nextSorted = @(
        $nextIssues | Sort-Object -Property `
            @{ Expression = { Get-CreatedAtSortTicks $_.createdAt } },
            @{ Expression = { Get-PriorityKey $_.labels } },
            @{ Expression = { $_.number } }
    )

    # CoverageGaps (AC7): for each active-round umbrella, if it has 0 open sub-issues
    # in KnownChildSet that are in Now-eligible (unblocked), emit a CoverageGaps entry.
    $coverageGaps = [System.Collections.Generic.List[object]]::new()
    if ($nowRoundIdx -ge 0) {
        $activeUmbrellaSet = @($sortedRounds[$nowRoundIdx].issues)
        # Build set of child numbers that route to Now (active-round spine children, unblocked)
        $activeChildNums = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($childNum in $childRoundIndex.Keys) {
            $roundIdx = $childRoundIndex[$childNum]
            if ($roundIdx -le $nowRoundIdx) {
                # Check not blocked
                $childIssue = $allOpenIssues | Where-Object { $_.number -eq $childNum }
                if ($childIssue -and -not ($childIssue.blockedBy -and $childIssue.blockedBy.Count -gt 0)) {
                    $null = $activeChildNums.Add($childNum)
                }
            }
        }

        foreach ($umbrellaNum in $activeUmbrellaSet) {
            $umbrellaHasChildren = $false
            if ($childToUmbrella.Count -gt 0) {
                # Rich-object path: check if any child is attributed to THIS specific umbrella
                # and is active-round eligible. This is per-umbrella accurate.
                foreach ($childNum in $childToUmbrella.Keys) {
                    if ($childToUmbrella[$childNum] -eq [int]$umbrellaNum) {
                        $cRoundIdx = if ($childRoundIndex.ContainsKey([int]$childNum)) { $childRoundIndex[[int]$childNum] } else { -1 }
                        if ($cRoundIdx -le $nowRoundIdx -and $cRoundIdx -ge 0) {
                            $umbrellaHasChildren = $true
                            break
                        }
                    }
                }
            }
            else {
                # Flat-int fallback: no per-umbrella association available; check if any
                # KnownChildSet member is active-round eligible (conservative approximation).
                foreach ($childNum in $knownChildNumbers) {
                    $cRoundIdx = if ($childRoundIndex.ContainsKey([int]$childNum)) { $childRoundIndex[[int]$childNum] } else { -1 }
                    if ($cRoundIdx -le $nowRoundIdx -and $cRoundIdx -ge 0) {
                        $umbrellaHasChildren = $true
                        break
                    }
                }
            }

            if (-not $umbrellaHasChildren) {
                $coverageGaps.Add([PSCustomObject]@{
                    umbrella = $umbrellaNum
                    note     = 'no leaves modeled yet'
                })
            }
        }
    }

    $blockedSorted        = @($openBlocked        | Sort-Object number)
    $recentlyClosedSorted = @($closedWithinWindow  | Sort-Object number)
    $triageSorted         = @($triage              | Sort-Object number)

    return [PSCustomObject]@{
        Now                      = $nowSorted
        NowTotalCount            = Get-BucketTotal $nowSorted
        Next                     = $nextSorted
        NextTotalCount           = Get-BucketTotal $nextSorted
        Blocked                  = $blockedSorted
        BlockedTotalCount        = Get-BucketTotal $blockedSorted
        RecentlyClosed           = $recentlyClosedSorted
        RecentlyClosedTotalCount = Get-BucketTotal $recentlyClosedSorted
        Triage                   = $triageSorted
        TriageTotalCount         = Get-BucketTotal $triageSorted
        CoverageGaps             = @($coverageGaps)
    }
}

# ---------------------------------------------------------------------------
# Format-PortfolioMarkdown
# Renders bucket model to Markdown string.
# Bucket order: Now / Next / Blocked / Recently closed / Triage
# Footer: "as of {timestamp} — rendered by render-portfolio.ps1"
# Pagination: (+N more) when totalCount > rendered count.
# ---------------------------------------------------------------------------
function Format-PortfolioMarkdown {
    param($bucketModel, [string]$timestamp, [int[]]$UnresolvedNums = @(), [int[]]$BlockedByOverflowNums = @())

    $sb = [System.Text.StringBuilder]::new()

    # --- Now ---
    # Cap-floor constant (AC10): max float items to render before (+M more).
    $floatCap = 15

    $null = $sb.AppendLine('## Now')
    # Consume producer ordering verbatim — do NOT Sort-Object number (AC3).
    $nowItems = if ($bucketModel.Now) { @($bucketModel.Now) } else { @() }
    if ($nowItems.Count -gt 0) {
        # Separate spine items (isFloat=$false) from float items (isFloat=$true).
        $spineItems = @($nowItems | Where-Object { -not ($_.PSObject.Properties['isFloat'] -and $_.isFloat -eq $true) })
        $floatItems = @($nowItems | Where-Object {       $_.PSObject.Properties['isFloat'] -and $_.isFloat -eq $true  })

        # Render ALL spine items with tags.
        foreach ($issue in $spineItems) {
            $tags = ''
            if ($issue.PSObject.Properties['inProgress'] -and $issue.inProgress -eq $true) {
                $tags += ' (in progress)'
            }
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)$tags")
        }

        # Render top N=15 float items with tags; compute total overflow.
        $floatCount    = $floatItems.Count
        $floatToRender = if ($floatCount -gt $floatCap) { $floatCap } else { $floatCount }
        for ($fi = 0; $fi -lt $floatToRender; $fi++) {
            $issue = $floatItems[$fi]
            $tags = ' (unsequenced)'
            if ($issue.PSObject.Properties['inProgress'] -and $issue.inProgress -eq $true) {
                $tags += ' (in progress)'
            }
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)$tags")
        }

        # Overflow: combine cap-floor float overflow with NowTotalCount overflow.
        # NowTotalCount may exceed Now.Count when the caller has more items than
        # were passed in the Now array (pagination from the model).
        $totalRendered   = $spineItems.Count + $floatToRender
        $nowTotal        = Get-ModelTotal $bucketModel 'NowTotalCount' $nowItems.Count
        $totalToAccount  = [math]::Max($nowTotal, $nowItems.Count)
        $totalOverflow   = $totalToAccount - $totalRendered
        if ($totalOverflow -gt 0) {
            $null = $sb.AppendLine("(+$totalOverflow more)")
        }
    }
    else {
        $blockedCount = if ($bucketModel.Blocked) { @($bucketModel.Blocked).Count } else { 0 }
        $emptyMsg     = if ($blockedCount -gt 0) {
            '*(no unblocked items — all current-round items are blocked)*'
        } else {
            '*(no current-round work)*'
        }
        $null = $sb.AppendLine($emptyMsg)
    }
    # CoverageGaps (AC7): render after Now content, even when Now is empty.
    if ($bucketModel.CoverageGaps) {
        foreach ($gap in $bucketModel.CoverageGaps) {
            $null = $sb.AppendLine("- (#$($gap.umbrella): $($gap.note))")
        }
    }
    $null = $sb.AppendLine('')

    # --- Next ---
    $null = $sb.AppendLine('## Next')
    $nextItems = if ($bucketModel.Next) { @($bucketModel.Next | Sort-Object number) } else { @() }
    if ($nextItems.Count -gt 0) {
        foreach ($issue in $nextItems) {
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)")
        }
        $nextTotal = Get-ModelTotal $bucketModel 'NextTotalCount' $nextItems.Count
        if ($nextTotal -gt $nextItems.Count) {
            $overflow = $nextTotal - $nextItems.Count
            $null = $sb.AppendLine("(+$overflow more)")
        }
    }
    else {
        $null = $sb.AppendLine('*(none)*')
    }
    $null = $sb.AppendLine('')

    # --- Blocked ---
    $null = $sb.AppendLine('## Blocked')
    $blockedItems = if ($bucketModel.Blocked) { @($bucketModel.Blocked | Sort-Object number) } else { @() }
    if ($blockedItems.Count -gt 0) {
        foreach ($issue in $blockedItems) {
            $annotation = if ($issue.PSObject.Properties['blockerAnnotations']) {
                " ($($issue.blockerAnnotations))"
            } else { '' }
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)$annotation")
        }
        $blockedTotal = Get-ModelTotal $bucketModel 'BlockedTotalCount' $blockedItems.Count
        if ($blockedTotal -gt $blockedItems.Count) {
            $overflow = $blockedTotal - $blockedItems.Count
            $null = $sb.AppendLine("(+$overflow more)")
        }
    }
    else {
        $null = $sb.AppendLine('*(none)*')
    }
    $null = $sb.AppendLine('')

    # --- Recently closed ---
    $null = $sb.AppendLine('## Recently closed')
    $rcItems = if ($bucketModel.RecentlyClosed) { @($bucketModel.RecentlyClosed | Sort-Object number) } else { @() }
    if ($rcItems.Count -gt 0) {
        foreach ($issue in $rcItems) {
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)")
        }
        $rcTotal = Get-ModelTotal $bucketModel 'RecentlyClosedTotalCount' $rcItems.Count
        if ($rcTotal -gt $rcItems.Count) {
            $overflow = $rcTotal - $rcItems.Count
            $null = $sb.AppendLine("(+$overflow more)")
        }
    }
    else {
        $null = $sb.AppendLine('*(none)*')
    }
    $null = $sb.AppendLine('')

    # --- Triage ---
    $null = $sb.AppendLine('## Triage')
    $triageItems = if ($bucketModel.Triage) { @($bucketModel.Triage | Sort-Object number) } else { @() }
    if ($triageItems.Count -gt 0) {
        foreach ($issue in $triageItems) {
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)")
        }
        $triageTotal = Get-ModelTotal $bucketModel 'TriageTotalCount' $triageItems.Count
        if ($triageTotal -gt $triageItems.Count) {
            $overflow = $triageTotal - $triageItems.Count
            $null = $sb.AppendLine("(+$overflow more)")
        }
    }
    else {
        $null = $sb.AppendLine('*(none)*')
    }
    $null = $sb.AppendLine('')

    # --- Footer ---
    $null = $sb.AppendLine("portfolio content unchanged since $timestamp — rendered by render-portfolio.ps1")

    if ($BlockedByOverflowNums -and $BlockedByOverflowNums.Count -gt 0) {
        foreach ($n in $BlockedByOverflowNums) {
            $null = $sb.AppendLine("⚠️ Issue #${n}: blockedBy overflow — excluded from startable routing (blocker list truncated at 50)")
        }
    }

    if ($UnresolvedNums -and $UnresolvedNums.Count -gt 0) {
        foreach ($n in $UnresolvedNums) {
            $null = $sb.AppendLine("⚠️ Warning: issue #$n not found in GitHub — remove from sequence.yaml")
        }
    }

    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Get-SplicedBody
# Splices contentBlock into existingBody using portfolio-tracker markers.
# Idempotency rule: strip footer line before comparing; if regions match -> $null.
# Returns new body string or $null (no write needed).
# ---------------------------------------------------------------------------
function Get-SplicedBody {
    param([string]$existingBody, [string]$contentBlock)

    # Hardcoded markers — do not rely on module-level variables for scope safety
    $begin = '<!-- portfolio-tracker:begin -->'
    $end   = '<!-- portfolio-tracker:end -->'

    # Pattern to strip the footer timestamp line (with optional CRLF).
    # Use [^\n]* between the timestamp and "rendered" to tolerate encoding
    # differences when the em dash (U+2014) is round-tripped through the gh CLI
    # on Windows (which can produce mojibake variants of the em dash character).
    $footerPattern = 'portfolio content unchanged since \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z[^\n]*rendered by render-portfolio\.ps1\r?\n?'

    $hasBegin = $existingBody -match [regex]::Escape($begin)
    $hasEnd   = $existingBody -match [regex]::Escape($end)
    if ($hasBegin -xor $hasEnd) {
        throw "Control tower body has only one portfolio marker — region is malformed (begin=$hasBegin, end=$hasEnd)."
    }

    if ($hasBegin) {
        # Extract the region between markers in both bodies
        $betweenPattern = [regex]::Escape($begin) + '([\s\S]*?)' + [regex]::Escape($end)

        $existingMatch = [regex]::Match($existingBody, $betweenPattern)
        $newMatch      = [regex]::Match($contentBlock, $betweenPattern)

        $existingBetween = $existingMatch.Groups[1].Value
        $newBetween      = $newMatch.Groups[1].Value

        # Strip timestamps for idempotency comparison
        $existingBetweenStripped = $existingBetween -replace $footerPattern, ''
        $newBetweenStripped      = $newBetween      -replace $footerPattern, ''

        if ($existingBetweenStripped -eq $newBetweenStripped) {
            return $null  # Idempotent — no write needed
        }

        # Replace the old block (including markers) with the new content block.
        # In [regex]::Replace, the replacement string uses $ for group refs, so
        # escape literal $ in the content by doubling: '$' -> '$$'
        $safeReplacement = $contentBlock.Replace('$', '$$')
        $newBody = [regex]::Replace(
            $existingBody,
            [regex]::Escape($begin) + '[\s\S]*?' + [regex]::Escape($end),
            $safeReplacement
        )
        return $newBody
    }
    else {
        # Markers absent — append portfolio block
        return $existingBody.TrimEnd() + "`n`n" + $contentBlock
    }
}

# ---------------------------------------------------------------------------
# Invoke-PortfolioRender
# Full pipeline: parse spec -> query GitHub -> build buckets -> format -> splice -> write.
# ---------------------------------------------------------------------------
function Invoke-PortfolioRender {
    param(
        [string]$specPath       = 'Documents/Planning/sequence.yaml',
        [int]   $controlTower   = 0,     # 0 = read from spec
        # 2000 is ~9x the current open-issue count (226 as of 2026-06).
        # Crossing it means revisit the paginate decision (see #746-class pagination),
        # not just bump the number.
        [ValidateRange(1, [int]::MaxValue)]
        [int]   $issueScanLimit = 2000
    )

    # 1. Parse spec
    $specText = Get-Content $specPath -Raw -ErrorAction Stop
    $spec = ConvertFrom-SequenceSpec -yamlText $specText
    if ($null -eq $spec) {
        Write-Error "Failed to parse sequence spec at $specPath"
        exit 1
    }

    $tower = if ($controlTower -gt 0) { $controlTower } else { $spec.control_tower }

    # 2. Collect all umbrella numbers from all rounds (used for leaf detection and
    #    known-child-set building in steps 2c/2d).
    $allIssueNums = @(
        $spec.rounds | ForEach-Object { $_.issues } | Sort-Object -Unique
    )

    # Build the full set of umbrella numbers (sequenced umbrellas + control tower).
    # An issue is a "leaf" if its number does NOT appear in this set.
    $umbrellaNumbers = @(@($allIssueNums) + @($tower) | Sort-Object -Unique)

    # 2b. Bulk open-leaf scan (AC8 / AC4 data source).
    # Fail-loud: if this scan fails, the board must not be written in a partial
    # state. Hard-exit BEFORE any write step (gh issue edit) per AC8.
    # Use exit 1 (not throw) per the script's hard-exit contract; Write-Error
    # uses -ErrorAction Stop so the terminating error propagates cleanly through
    # Pester's try/catch without polluting the non-terminating error stream.
    $openLeavesRaw = gh issue list --repo Grimblaz/agent-orchestra --state open `
        --json number,title,labels,createdAt --limit $issueScanLimit
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch open issue list (exit $LASTEXITCODE)" -ErrorAction Stop
    }
    $openLeaves = @()
    try {
        $openLeaves = @($openLeavesRaw | ConvertFrom-Json)
    }
    catch {
        Write-Error "Failed to parse open issue list JSON: $_" -ErrorAction Stop
    }
    # Two-tier truncation contract: open/closed fail-loud (abort render); triage warn-and-continue (additive bucket).
    # count == limit is the only observable truncation signal; false-positive at exactly the ceiling is treated as truncation and accepted.
    if ($openLeaves.Count -ge $issueScanLimit) {
        Write-Error "Open issue list returned $($openLeaves.Count) results (limit $issueScanLimit) — refusing to render a potentially truncated board." -ErrorAction Stop
    }

    # 2c. Repo-wide closed-leaf scan (AC9 data source).
    # Fail-loud: same hard-exit pattern as the open scan.
    $cutoffDate    = (Get-Date).AddDays(-$spec.recently_closed_days).ToString('yyyy-MM-dd')
    # Closed scan uses --search, routing through the GitHub Search API (hard cap: 1000 results regardless of --limit).
    # Guard at min(issueScanLimit, 1000) so it can actually fire even when issueScanLimit > 1000.
    $closedCeiling = [Math]::Min($issueScanLimit, 1000)
    $closedRawJson = gh issue list --repo Grimblaz/agent-orchestra --state closed `
        --search "closed:>=$cutoffDate" --json number,title,closedAt,labels --limit $closedCeiling
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch closed issue list (exit $LASTEXITCODE)" -ErrorAction Stop
    }
    $closedLeaves = @()
    try {
        $closedLeaves = @($closedRawJson | ConvertFrom-Json)
    }
    catch {
        Write-Error "Failed to parse closed issue list JSON: $_" -ErrorAction Stop
    }
    # Fail-loud tier: abort render (same contract as open guard above).
    if ($closedLeaves.Count -ge $closedCeiling) {
        Write-Error "Closed issue list returned $($closedLeaves.Count) results (limit $closedCeiling — GitHub Search API hard cap) — refusing to render a potentially truncated RecentlyClosed section." -ErrorAction Stop
    }

    # 2d. Fetch open triage-labeled issues repo-wide (CR9 / d-triage-visibility,
    #     AC #5). The Triage bucket promises open `triage`-labeled issues that
    #     are NOT in any sequence round; those are never named in sequence.yaml,
    #     so without this independent query they would never be fetched and the
    #     bucket would silently stay empty. The query is additive: a failure
    #     warns and degrades (Triage may be incomplete) rather than aborting the
    #     whole render, consistent with the per-issue skip pattern below.
    $triageNums = @()
    $triageRaw  = gh issue list --repo Grimblaz/agent-orchestra --label triage --state open --limit $issueScanLimit --json number
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to list open triage-labeled issues (exit $LASTEXITCODE) — Triage bucket may be incomplete."
    }
    else {
        try {
            $triageNums = @(($triageRaw | ConvertFrom-Json) | ForEach-Object { $_.number })
        }
        catch {
            Write-Warning "Failed to parse triage issue list — Triage bucket may be incomplete."
        }
    }
    # Triage truncation is an accepted advisory degradation: a best-effort additive bucket
    # must not abort the whole render. count == limit is the only observable signal; a
    # false-positive at exactly the ceiling is documented here as accepted.
    if ($triageNums.Count -ge $issueScanLimit) {
        Write-Warning "Triage issue list returned $($triageNums.Count) results (limit $issueScanLimit) — Triage bucket may be incomplete."
    }

    # Query set = sequenced issues ∪ repo-wide triage issues (deduplicated).
    # Plan membership ($allIssueNums) stays sequence-only — triage issues are by
    # definition unsequenced and must NOT count as in-plan for blocker logic.
    $queryNums = @($allIssueNums + $triageNums | Sort-Object -Unique)

    # 3. Query each issue via gh GraphQL (first: 50 per connection)
    $issueStates    = [System.Collections.Generic.List[object]]::new()
    $unresolvedNums         = @()
    $blockedByOverflowNums  = @()

    # Build round-index map for umbrella numbers: used to tag KnownChildSet entries
    # with the correct RoundIndex so Get-PortfolioBuckets can route children correctly.
    $sortedRoundsForSpec = @($spec.rounds | Sort-Object round)
    $umbrellaRoundIdxMap = @{}
    for ($ri = 0; $ri -lt $sortedRoundsForSpec.Count; $ri++) {
        foreach ($rnum in $sortedRoundsForSpec[$ri].issues) {
            $umbrellaRoundIdxMap[[int]$rnum] = $ri
        }
    }

    # KnownChildSet: rich PSCustomObjects { number, UmbrellaNumber, RoundIndex } built
    # from per-umbrella subIssues GraphQL responses. Passed to Get-PortfolioBuckets so
    # float detection (AC4) and CoverageGaps (AC7) work correctly in the live pipeline.
    $knownChildSet = [System.Collections.Generic.List[object]]::new()

    foreach ($num in $queryNums) {
        $isUmbrella = $allIssueNums -contains $num
        $query = @"
query {
  repository(owner: "Grimblaz", name: "agent-orchestra") {
    issue(number: $num) {
      number
      title
      state
      closedAt
      createdAt
      labels(first: 50) { totalCount nodes { name } }
      blockedBy(first: 50) {
        totalCount
        nodes { number title state }
      }$(if ($isUmbrella) {
"
      subIssues(first: 50) {
        totalCount nodes { number }
      }"
      })
    }
  }
}
"@
        $rawJson = gh api graphql -f query=$query
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "GraphQL query failed for issue #$num (exit $LASTEXITCODE) — skipping."
            $unresolvedNums += $num
            continue
        }
        $response = $null
        try {
            $response = $rawJson | ConvertFrom-Json
        }
        catch {
            Write-Warning "Failed to parse GraphQL response for issue #$num — skipping."
            $unresolvedNums += $num
            continue
        }
        $issueData = $response.data.repository.issue

        if ($null -eq $issueData) {
            if ($response.errors) {
                Write-Warning "GraphQL errors for issue #$num (issue may not exist) — skipping."
            }
            $unresolvedNums += $num
            continue
        }
        # Partial-success: data present but with field-level errors (e.g. blockedBy requires Projects scope).
        # Treat as unresolved to avoid silently classifying an issue as startable with incomplete blocker data (AC2).
        if ($response.errors) {
            Write-Warning "GraphQL field errors for issue #$num (blockedBy may be incomplete) — treating as unresolved."
            $unresolvedNums += $num
            continue
        }

        $labels       = @($issueData.labels.nodes | ForEach-Object { $_.name })
        if (Test-ConnectionOverflow -TotalCount $issueData.labels.totalCount -Nodes $issueData.labels.nodes) {
            Write-Warning "Issue #${num}: labels truncated ($($issueData.labels.totalCount) total, 50 fetched) — bucket routing may be incomplete."
            if ($env:GITHUB_ACTIONS -eq 'true') {
                Write-Host "::warning::Issue #${num} labels connection truncated (>50)"
            }
        }
        # subIssues overflow check runs before blockedBy continue so warning fires even when
        # blockedBy also overflows for the same issue (both warnings must be observable, AC5).
        if ($isUmbrella -and $null -ne $issueData.subIssues -and
            (Test-ConnectionOverflow -TotalCount $issueData.subIssues.totalCount -Nodes $issueData.subIssues.nodes)) {
            Write-Warning "Issue #${num}: subIssues truncated ($($issueData.subIssues.totalCount) total, 50 fetched) — child list may be incomplete."
            if ($env:GITHUB_ACTIONS -eq 'true') {
                Write-Host "::warning::Issue #${num} subIssues connection truncated (>50)"
            }
        }
        $allBlockers  = $issueData.blockedBy.nodes
        if (Test-ConnectionOverflow -TotalCount $issueData.blockedBy.totalCount -Nodes $issueData.blockedBy.nodes) {
            Write-Warning "Issue #${num}: blockedBy truncated ($($issueData.blockedBy.totalCount) total, 50 fetched) — a dropped open blocker may misroute this issue as startable."
            if ($env:GITHUB_ACTIONS -eq 'true') {
                Write-Host "::warning::Issue #${num} blockedBy connection truncated (>50)"
            }
            $blockedByOverflowNums += $num
            continue
        }
        $openBlockers = @(
            $allBlockers |
            Where-Object { $_.state -eq 'OPEN' } |
            ForEach-Object { $_.number }
        )

        # blockerInPlan: true if every open blocker is in allIssueNums
        $blockerInPlan = $true
        foreach ($b in $openBlockers) {
            if ($allIssueNums -notcontains $b) {
                $blockerInPlan = $false
                break
            }
        }

        $issueStates.Add([PSCustomObject]@{
            number              = $issueData.number
            title               = $issueData.title
            state               = $issueData.state
            closedAt            = $issueData.closedAt
            createdAt           = $issueData.createdAt
            labels              = $labels
            blockedBy           = $openBlockers
            blockerInPlan       = $blockerInPlan
            blockedByTotalCount = $issueData.blockedBy.totalCount
        })

        # Collect sub-issue children for this umbrella into KnownChildSet (AC4/AC7).
        if ($isUmbrella -and $null -ne $issueData.subIssues) {
            $umbRoundIdx = if ($umbrellaRoundIdxMap.ContainsKey([int]$num)) { $umbrellaRoundIdxMap[[int]$num] } else { 0 }
            foreach ($child in $issueData.subIssues.nodes) {
                if ($child.number -gt 0) {
                    $knownChildSet.Add([PSCustomObject]@{
                        number        = [int]$child.number
                        UmbrellaNumber = [int]$num
                        RoundIndex     = $umbRoundIdx
                    })
                }
            }
        }
    }

    # 3b. Open-leaf detail pass (AC4): query full data for all non-umbrella open issues —
    # both spine children (KnownChildSet members) and floats. Get-PortfolioBuckets classifies
    # them: known children route to Now/Next/Blocked as spine; unknowns are floats (isFloat=$true).
    # Previously KnownChildSet members were excluded here, causing spine leaves to never enter
    # issueStates and never appear on the board. The exclusion was incorrect: we need full data
    # for BOTH categories so blockedBy, labels, and createdAt are populated for all leaf issues.
    # Fail-loud: a leaf-query failure warns and skips (same as per-issue skip pattern).
    $knownChildNums = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($child in $knownChildSet) { $null = $knownChildNums.Add([int]$child.number) }
    $alreadyQueried = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($q in $queryNums) { $null = $alreadyQueried.Add([int]$q) }

    $openLeafCandidateNums = @(
        $openLeaves |
        Where-Object {
            $n = [int]$_.number
            (-not ($umbrellaNumbers -contains $n)) -and (-not $alreadyQueried.Contains($n))
        } |
        ForEach-Object { [int]$_.number }
    )

    foreach ($num in $openLeafCandidateNums) {
        $query = @"
query {
  repository(owner: "Grimblaz", name: "agent-orchestra") {
    issue(number: $num) {
      number
      title
      state
      closedAt
      createdAt
      labels(first: 50) { totalCount nodes { name } }
      blockedBy(first: 50) {
        totalCount
        nodes { number title state }
      }
    }
  }
}
"@
        $rawJson = gh api graphql -f query=$query
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "GraphQL query failed for float #$num (exit $LASTEXITCODE) — skipping."
            continue
        }
        $response = $null
        try { $response = $rawJson | ConvertFrom-Json }
        catch { Write-Warning "Failed to parse GraphQL response for float #$num — skipping."; continue }
        $issueData = $response.data.repository.issue
        if ($null -eq $issueData) { continue }
        if ($response.errors) {
            Write-Warning "GraphQL field errors for leaf #$num (blockedBy may be incomplete) — treating as unresolved."
            $unresolvedNums += $num
            continue
        }

        $labels       = @($issueData.labels.nodes | ForEach-Object { $_.name })
        if (Test-ConnectionOverflow -TotalCount $issueData.labels.totalCount -Nodes $issueData.labels.nodes) {
            Write-Warning "Issue #${num}: labels truncated ($($issueData.labels.totalCount) total, 50 fetched) — bucket routing may be incomplete."
            if ($env:GITHUB_ACTIONS -eq 'true') {
                Write-Host "::warning::Issue #${num} labels connection truncated (>50)"
            }
        }
        $allBlockers  = $issueData.blockedBy.nodes
        if (Test-ConnectionOverflow -TotalCount $issueData.blockedBy.totalCount -Nodes $issueData.blockedBy.nodes) {
            Write-Warning "Issue #${num}: blockedBy truncated ($($issueData.blockedBy.totalCount) total, 50 fetched) — a dropped open blocker may misroute this issue as startable."
            if ($env:GITHUB_ACTIONS -eq 'true') {
                Write-Host "::warning::Issue #${num} blockedBy connection truncated (>50)"
            }
            $blockedByOverflowNums += $num
            continue
        }
        $openBlockers = @($allBlockers | Where-Object { $_.state -eq 'OPEN' } | ForEach-Object { $_.number })
        $blockerInPlan = $true
        foreach ($b in $openBlockers) {
            if ($allIssueNums -notcontains $b) { $blockerInPlan = $false; break }
        }
        $issueStates.Add([PSCustomObject]@{
            number              = $issueData.number
            title               = $issueData.title
            state               = $issueData.state
            closedAt            = $issueData.closedAt
            createdAt           = $issueData.createdAt
            labels              = $labels
            blockedBy           = $openBlockers
            blockerInPlan       = $blockerInPlan
            blockedByTotalCount = $issueData.blockedBy.totalCount
        })
    }

    # 4. Fetch current control tower body
    $ctRawJson = gh issue view $tower --repo Grimblaz/agent-orchestra --json body
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch control tower issue #$tower (exit $LASTEXITCODE)" -ErrorAction Stop
    }
    $ctData = $null
    try {
        $ctData = $ctRawJson | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse control tower issue body JSON: $_" -ErrorAction Stop
    }
    $existingBody = $ctData.body

    # 5. Derive buckets — pass fetched data as parameters so Get-PortfolioBuckets
    #    remains pure (no I/O).
    $buckets = Get-PortfolioBuckets `
        -spec $spec `
        -issueStateObjects $issueStates.ToArray() `
        -KnownChildSet $knownChildSet.ToArray() `
        -OpenLeafCandidates $openLeaves `
        -ClosedLeafItems $closedLeaves

    # 6. Format content block
    $timestamp    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $innerContent = Format-PortfolioMarkdown -bucketModel $buckets -timestamp $timestamp -UnresolvedNums $unresolvedNums -BlockedByOverflowNums $blockedByOverflowNums
    $fullContent  = "$MARKER_BEGIN`n$innerContent$MARKER_END"

    # 7. Splice into body
    $newBody = Get-SplicedBody -existingBody $existingBody -contentBlock $fullContent

    if ($null -eq $newBody) {
        Write-Host 'Idempotent — no write needed.'
        return
    }

    # 8. Write back to GitHub
    gh issue edit $tower --repo Grimblaz/agent-orchestra --body $newBody 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update control tower issue #$tower (exit $LASTEXITCODE)" -ErrorAction Stop
    }
    Write-Host "Rendered and wrote portfolio to issue #$tower"
}

# ---------------------------------------------------------------------------
# Test helper functions
# Defined here so that Pester 5's BeforeAll dot-source makes them available
# in It blocks (Pester 5 file-level functions are discovery-only, not run-phase).
# ---------------------------------------------------------------------------

function New-ValidSpecYaml {
    param(
        [int]   $SchemaVersion      = 1,
        [int]   $ControlTower       = 704,
        [int]   $RecentlyClosedDays = 14,
        [string]$RoundsBlock        = "rounds:`n  - lane: main`n    round: 1`n    issues: [425, 571]"
    )
    return @"
schema_version: $SchemaVersion
control_tower: $ControlTower
recently_closed_days: $RecentlyClosedDays
$RoundsBlock
"@
}

function New-IssueState {
    param(
        [int]     $Number,
        [string]  $State        = 'OPEN',
        [string[]]$Labels       = @(),
        [int[]]   $BlockedBy    = @(),
        [bool]    $BlockerInPlan = $true,
        [string]  $Title        = "Issue $Number",
        [string]  $ClosedAt     = $null,
        [string]  $CreatedAt    = '2025-01-01T00:00:00Z'
    )
    return [PSCustomObject]@{
        number        = $Number
        state         = $State
        title         = $Title
        labels        = $Labels
        blockedBy     = $BlockedBy
        blockerInPlan = $BlockerInPlan
        closedAt      = $ClosedAt
        createdAt     = $CreatedAt
        totalCount    = 1  # default rendered count = totalCount (no overflow)
    }
}

# ---------------------------------------------------------------------------
# Direct invocation entry point
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PortfolioRender -specPath $specPath
}
