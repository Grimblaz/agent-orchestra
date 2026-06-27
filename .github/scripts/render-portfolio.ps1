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
        # Require schema_version as integer
        if ($yamlText -notmatch '(?m)^\s*schema_version:\s*(\d+)\s*$') {
            return $null
        }
        $schema_version = [int]$Matches[1]

        # v1 is no longer supported
        if ($schema_version -eq 1) {
            Write-Error "sequence.yaml: schema_version 1 is no longer supported; migrate to schema_version 2"
            return $null
        }

        # Reject quoted control_tower
        if ($yamlText -match '(?m)^\s*control_tower:\s*"') { return $null }

        # Require control_tower as unquoted integer
        if ($yamlText -notmatch '(?m)^\s*control_tower:\s*(\d+)\s*$') { return $null }
        $control_tower = [int]$Matches[1]

        # Require recently_closed_days as integer
        if ($yamlText -notmatch '(?m)^\s*recently_closed_days:\s*(\d+)\s*$') { return $null }
        $recently_closed_days = [int]$Matches[1]

        # Stray rounds: key is a schema violation in v2
        if ($yamlText -match '(?m)^\s*rounds\s*:') {
            Write-Error "sequence.yaml: stray 'rounds:' key found in schema_version 2 document; remove it and use 'umbrellas:' instead"
            return $null
        }

        # Require umbrellas: key
        if ($yamlText -notmatch '(?m)^\s*umbrellas\s*:') {
            return $null
        }

        # Reject block-style umbrellas (items on separate lines with leading dash)
        if ($yamlText -match '(?m)^\s*umbrellas\s*:\s*\r?\n\s*-') {
            return $null
        }

        # Parse inline umbrellas list: umbrellas: [N, N, ...]
        if ($yamlText -notmatch '(?m)^\s*umbrellas\s*:\s*\[([^\]]*)\]\s*$') {
            return $null
        }
        $rawList = $Matches[1].Trim()

        # Empty list
        if ($rawList -eq '') {
            Write-Error "sequence.yaml: umbrellas list is empty; at least one umbrella is required"
            return $null
        }

        # Parse and validate each entry
        $umbrellas = [System.Collections.Generic.List[int]]::new()
        $entries = $rawList -split ','
        foreach ($entry in $entries) {
            $token = $entry.Trim()
            # Reject quoted numbers
            if ($token -match '^".*"$' -or $token -match "^'.*'$") {
                Write-Error "sequence.yaml: quoted number '$token' in umbrellas list; all entries must be bare integers"
                return $null
            }
            # Must be a bare integer
            if ($token -notmatch '^\d+$') {
                throw "sequence.yaml: non-integer entry '$token' in umbrellas list"
            }
            $umbrellas.Add([int]$token)
        }

        # Reject duplicates
        $distinct = @($umbrellas | Sort-Object -Unique)
        if ($distinct.Count -ne $umbrellas.Count) {
            Write-Error "sequence.yaml: duplicate entries in umbrellas list"
            return $null
        }

        return [PSCustomObject]@{
            schema_version       = $schema_version
            control_tower        = $control_tower
            recently_closed_days = $recently_closed_days
            umbrellas            = $umbrellas.ToArray()
        }
    }
    catch {
        Write-Error "sequence.yaml: $_"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Get-SubIssueNodes
# Returns a proper object[] from subIssues.nodes, handling the PowerShell
# quirk where a single-element array stored in a hashtable value is unwrapped
# to the single element on retrieval (so .nodes may be a hashtable, not array).
# ---------------------------------------------------------------------------
function Get-SubIssueNodes {
    # Returns nodes from a subIssues hashtable as a proper object[], avoiding the
    # PowerShell function-return unwrap that strips single-element array wrappers.
    # Callers must use @(Get-SubIssueNodes ...) to force an array regardless of count.
    param($subIssues)
    if ($null -eq $subIssues -or $null -eq $subIssues.nodes) { return }
    $raw = $subIssues.nodes
    if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [System.Collections.IDictionary]) -and -not ($raw -is [string])) {
        # Already a proper collection (array/list) — enumerate to caller
        foreach ($n in $raw) { $n }
    } else {
        # Single item (hashtable unwrapped by PowerShell) or scalar — emit as-is
        $raw
    }
}

# ---------------------------------------------------------------------------
# Get-PortfolioBuckets v2
# Classifies issueStateObjects into the v2 model:
#   ActiveUmbrella, ActiveChildren, RankedUmbrellas, Triage, TriageResidualCount,
#   DriftWarnings, IntegrityWarnings, RecentlyClosed
#
# issueStateObjects fields (v2):
#   .number (int), .state ('OPEN'/'CLOSED'), .title (string), .labels (string[])
#   .blockedBy (int[]), .closedAt (string ISO or $null), .createdAt (string ISO)
#   .parent (hashtable {number} | $null), .subIssues (hashtable {totalCount, nodes[{number,state}]} | $null)
# ---------------------------------------------------------------------------
function Get-PortfolioBuckets {
    param(
        $spec,               # v2 PSCustomObject: .umbrellas (int[]), .control_tower, .recently_closed_days
        $issueStateObjects   # array of issue objects
    )

    if ($null -eq $spec) {
        Write-Error 'Get-PortfolioBuckets: $spec is null'
        return $null
    }

    $umbrellaList    = @($spec.umbrellas)
    $umbrellaSet     = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($u in $umbrellaList) { $null = $umbrellaSet.Add([int]$u) }

    $driftWarnings     = [System.Collections.Generic.List[string]]::new()
    $integrityWarnings = [System.Collections.Generic.List[string]]::new()
    $driftWarnedNums   = [System.Collections.Generic.HashSet[int]]::new()

    # Build lookup: number → issue state object
    $issueByNumber = @{}
    foreach ($issue in $issueStateObjects) {
        $issueByNumber[[int]$issue.number] = $issue
    }

    # ---------------------------------------------------------------------------
    # ActiveUmbrella (AC3): first OPEN umbrella in spec list order
    # ---------------------------------------------------------------------------
    $activeUmbrella = $null
    foreach ($umbNum in $umbrellaList) {
        $umbIssue = $issueByNumber[[int]$umbNum]
        if ($null -eq $umbIssue) { continue }
        if ($umbIssue.state -eq 'OPEN') {
            $activeUmbrella = $umbIssue
            break
        }
        else {
            # CLOSED listed umbrella → DriftWarning (deduplicated)
            if ($driftWarnedNums.Add([int]$umbNum)) {
                $driftWarnings.Add("⚠️ listed umbrella #$umbNum is closed")
            }
        }
    }

    # ---------------------------------------------------------------------------
    # DriftWarnings (AC7): open issue with totalCount>0 not in umbrella list
    # Also: CLOSED listed umbrella (already emitted above for pre-active ones;
    # emit for any remaining CLOSED listed umbrellas not yet warned)
    # ---------------------------------------------------------------------------
    foreach ($issue in $issueStateObjects) {
        # Open issue that looks like an umbrella (has subIssues.totalCount > 0) but not listed
        if ($issue.state -eq 'OPEN') {
            $subIssuesTotalCount = 0
            if ($null -ne $issue.subIssues -and $null -ne $issue.subIssues.totalCount) {
                $subIssuesTotalCount = [int]$issue.subIssues.totalCount
            }
            if ($subIssuesTotalCount -gt 0 -and -not $umbrellaSet.Contains([int]$issue.number)) {
                $driftWarnings.Add("⚠️ open umbrella #$($issue.number) not in ranked list")
            }
        }
        # CLOSED listed umbrella not yet warned
        if ($issue.state -eq 'CLOSED' -and $umbrellaSet.Contains([int]$issue.number)) {
            if ($driftWarnedNums.Add([int]$issue.number)) {
                $driftWarnings.Add("⚠️ listed umbrella #$($issue.number) is closed")
            }
        }
    }

    # ---------------------------------------------------------------------------
    # IntegrityWarnings (AC8): totalCount != returned nodes count
    # ---------------------------------------------------------------------------
    foreach ($umbNum in $umbrellaList) {
        $umbIssue = $issueByNumber[[int]$umbNum]
        if ($null -eq $umbIssue) { continue }
        if ($null -ne $umbIssue.subIssues) {
            $tc    = if ($null -ne $umbIssue.subIssues.totalCount) { [int]$umbIssue.subIssues.totalCount } else { 0 }
            $nodes = @(Get-SubIssueNodes $umbIssue.subIssues)
            if ($tc -ne $nodes.Count) {
                $integrityWarnings.Add("⚠️ umbrella #${umbNum}: subIssues.totalCount=$tc but only $($nodes.Count) nodes returned (possible truncation)")
            }
        }
    }

    # ---------------------------------------------------------------------------
    # ActiveChildren (AC4): open direct sub-issues of ActiveUmbrella, ordered
    # Sort: priority-label key → createdAt desc → number asc (mandatory tiebreak)
    # ---------------------------------------------------------------------------
    $activeChildren = @()
    if ($null -ne $activeUmbrella -and $null -ne $activeUmbrella.subIssues) {
        $allChildNodes  = @(Get-SubIssueNodes $activeUmbrella.subIssues)
        $openChildNodes = @($allChildNodes | Where-Object { $_.state -eq 'OPEN' })
        $enrichedChildren = [System.Collections.Generic.List[object]]::new()
        foreach ($childNode in $openChildNodes) {
            # Get full issue object from issueStateObjects if available; else use node directly
            $childObj = $issueByNumber[[int]$childNode.number]
            if ($null -eq $childObj) {
                # Construct minimal object from node data
                $childObj = [PSCustomObject]@{
                    number    = $childNode.number
                    state     = $childNode.state
                    title     = if ($null -ne $childNode.title) { $childNode.title } else { "Issue $($childNode.number)" }
                    labels    = @()
                    blockedBy = @()
                    createdAt = $null
                }
            }
            # Blocked annotation
            if ($childObj.blockedBy -and $childObj.blockedBy.Count -gt 0) {
                $annotation = ($childObj.blockedBy | ForEach-Object { "#$_" }) -join ', '
                $childObj | Add-Member -NotePropertyName 'BlockedAnnotation' `
                                       -NotePropertyValue "⛔ blocked by $annotation" `
                                       -Force
            }
            $enrichedChildren.Add($childObj)
        }
        $activeChildren = @(
            $enrichedChildren | Sort-Object -Property `
                @{ Expression = { Get-PriorityKey $_.labels } },
                @{ Expression = { Get-CreatedAtSortTicks $_.createdAt } },
                @{ Expression = { [int]$_.number } }
        )
    }

    # ---------------------------------------------------------------------------
    # RankedUmbrellas (AC5): all listed umbrellas in spec order with Done/Total
    # Done/Total from direct children (.subIssues.nodes) only
    # ---------------------------------------------------------------------------
    $rankedUmbrellas = [System.Collections.Generic.List[object]]::new()
    foreach ($umbNum in $umbrellaList) {
        $umbIssue = $issueByNumber[[int]$umbNum]
        $title    = if ($null -ne $umbIssue) { $umbIssue.title } else { "Issue $umbNum" }
        $state    = if ($null -ne $umbIssue) { $umbIssue.state } else { 'UNKNOWN' }
        $isActive = ($null -ne $activeUmbrella -and [int]$activeUmbrella.number -eq [int]$umbNum)

        $done  = 0
        $total = 0
        $doneTotalLabel = '0/0 (no children linked)'

        if ($null -ne $umbIssue -and $null -ne $umbIssue.subIssues) {
            $nodes = @(Get-SubIssueNodes $umbIssue.subIssues)
            $total = $nodes.Count
            $done  = @($nodes | Where-Object { $_.state -eq 'CLOSED' }).Count
            if ($total -gt 0) {
                $doneTotalLabel = "$done/$total"
            }
            # else: zero children → keep '0/0 (no children linked)'
        }

        $rankedUmbrellas.Add([PSCustomObject]@{
            Number        = [int]$umbNum
            Title         = $title
            State         = $state
            Done          = $done
            Total         = $total
            DoneTotalLabel = $doneTotalLabel
            IsActive      = $isActive
        })
    }

    # ---------------------------------------------------------------------------
    # Triage (AC6): open ∧ parent==null ∧ subIssues.totalCount==0 ∧ not in umbrella list
    # Sort: priority-label key → createdAt desc → number asc; cap at 5
    # NO inversion fallback (judge finding M4)
    # ---------------------------------------------------------------------------
    $triageCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($issue in $issueStateObjects) {
        if ($issue.state -ne 'OPEN') { continue }
        if ($umbrellaSet.Contains([int]$issue.number)) { continue }

        # parent must be null (the .parent field is null/absent)
        $parentIsNull = $true
        if ($null -ne $issue.PSObject.Properties['parent'] -and $null -ne $issue.parent) {
            $parentIsNull = $false
        }
        if (-not $parentIsNull) { continue }

        # subIssues.totalCount must be 0
        $subTotalCount = 0
        if ($null -ne $issue.subIssues -and $null -ne $issue.subIssues.totalCount) {
            $subTotalCount = [int]$issue.subIssues.totalCount
        }
        if ($subTotalCount -ne 0) { continue }

        $triageCandidates.Add($issue)
    }

    $triageSorted = @(
        $triageCandidates | Sort-Object -Property `
            @{ Expression = { Get-PriorityKey $_.labels } },
            @{ Expression = { Get-CreatedAtSortTicks $_.createdAt } },
            @{ Expression = { [int]$_.number } }
    )

    $triageCap = 5
    $triageIssues    = @($triageSorted | Select-Object -First $triageCap)
    $residualCount   = [math]::Max(0, $triageSorted.Count - $triageCap)

    # ---------------------------------------------------------------------------
    # RecentlyClosed: issues in issueStateObjects closed within recently_closed_days
    # ---------------------------------------------------------------------------
    $cutoff = [datetimeoffset](Get-Date -AsUTC).AddDays(-$spec.recently_closed_days)
    $recentlyClosed = [System.Collections.Generic.List[object]]::new()
    foreach ($issue in $issueStateObjects) {
        if ($issue.state -ne 'CLOSED') { continue }
        if ($issue.closedAt) {
            [datetimeoffset]$closedDate = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($issue.closedAt, [ref]$closedDate)) {
                if ($closedDate -ge $cutoff) {
                    $recentlyClosed.Add($issue)
                }
            }
        }
    }

    return [PSCustomObject]@{
        ActiveUmbrella      = $activeUmbrella
        ActiveChildren      = $activeChildren
        RankedUmbrellas     = $rankedUmbrellas.ToArray()
        Triage              = $triageIssues
        TriageResidualCount = $residualCount
        DriftWarnings       = $driftWarnings.ToArray()
        IntegrityWarnings   = $integrityWarnings.ToArray()
        RecentlyClosed      = $recentlyClosed.ToArray()
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
    param($bucketModel, [string]$timestamp, [int[]]$UnresolvedNums = @())

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
    $unresolvedNums = @()

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
        nodes { number }
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
        $allBlockers  = $issueData.blockedBy.nodes
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
        $allBlockers  = $issueData.blockedBy.nodes
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
    #    remains pure (no I/O). (v2 signature: spec + issueStateObjects only)
    $buckets = Get-PortfolioBuckets `
        -spec $spec `
        -issueStateObjects $issueStates.ToArray()

    # 6. Format content block
    $timestamp    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $innerContent = Format-PortfolioMarkdown -bucketModel $buckets -timestamp $timestamp -UnresolvedNums $unresolvedNums
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
        [int]    $SchemaVersion      = 2,
        [int]    $ControlTower       = 704,
        [int]    $RecentlyClosedDays = 14,
        [int[]]  $Umbrellas          = @(476, 571),
        [string] $LegacyRoundsBlock  = $null
    )
    if (-not [string]::IsNullOrEmpty($LegacyRoundsBlock)) {
        return @"
schema_version: 1
control_tower: $ControlTower
recently_closed_days: $RecentlyClosedDays
$LegacyRoundsBlock
"@
    }
    $umbrellaList = $Umbrellas -join ', '
    return @"
schema_version: $SchemaVersion
control_tower: $ControlTower
recently_closed_days: $RecentlyClosedDays
umbrellas: [$umbrellaList]
"@
}

function New-IssueState {
    param(
        [int]       $Number,
        [string]    $State        = 'OPEN',
        [string[]]  $Labels       = @(),
        [int[]]     $BlockedBy    = @(),
        [bool]      $BlockerInPlan = $true,
        [string]    $Title        = "Issue $Number",
        [string]    $ClosedAt     = $null,
        [string]    $CreatedAt    = '2025-01-01T00:00:00Z',
        [hashtable] $Parent       = $null,
        [hashtable] $SubIssues    = $null
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
        parent        = $Parent
        subIssues     = $SubIssues
    }
}

# ---------------------------------------------------------------------------
# Direct invocation entry point
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PortfolioRender -specPath $specPath
}
