#Requires -Version 7.0
<#
.SYNOPSIS
    Renders the derived portfolio tracker for issue #704 (control tower issue).

.DESCRIPTION
    Implements the Renderer Contract:
      - ConvertFrom-SequenceSpec  : parse flat YAML sequence spec (no ConvertFrom-Yaml)
      - Get-PortfolioBuckets      : classify issues into ActiveUmbrella/ActiveChildren/RankedUmbrellas/Triage/RecentlyClosed/DriftWarnings/IntegrityWarnings/OrphanClaimWarnings
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
            # -ErrorAction Continue: keep this diagnostic non-terminating so the function
            # honors its "return $null on validation failure" contract even when the caller
            # runs under $ErrorActionPreference = 'Stop' (e.g. GitHub Actions shell: pwsh).
            Write-Error "sequence.yaml: schema_version 1 is no longer supported; migrate to schema_version 2" -ErrorAction Continue
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
            Write-Error "sequence.yaml: stray 'rounds:' key found in schema_version 2 document; remove it and use 'umbrellas:' instead" -ErrorAction Continue
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
            Write-Error "sequence.yaml: umbrellas list is empty; at least one umbrella is required" -ErrorAction Continue
            return $null
        }

        # Parse and validate each entry
        $umbrellas = [System.Collections.Generic.List[int]]::new()
        $entries = $rawList -split ','
        foreach ($entry in $entries) {
            $token = $entry.Trim()
            # Reject quoted numbers
            if ($token -match '^".*"$' -or $token -match "^'.*'$") {
                Write-Error "sequence.yaml: quoted number '$token' in umbrellas list; all entries must be bare integers" -ErrorAction Continue
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
            Write-Error "sequence.yaml: duplicate entries in umbrellas list" -ErrorAction Continue
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
        # Non-terminating so a thrown validation failure (e.g. non-integer umbrella entry)
        # resolves to the documented $null return even under $ErrorActionPreference = 'Stop'.
        Write-Error "sequence.yaml: $_" -ErrorAction Continue
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
#   DriftWarnings, IntegrityWarnings, OrphanClaimWarnings, RecentlyClosed
#
# issueStateObjects fields (v2):
#   .number (int), .state ('OPEN'/'CLOSED'), .title (string), .labels (string[])
#   .blockedBy (int[]), .closedAt (string ISO or $null), .createdAt (string ISO)
#   .parent (hashtable {number} | $null), .subIssues (hashtable {totalCount, nodes[{number,state}]} | $null)
#   .body (string or $null) — used only by OrphanClaimWarnings detection
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

    $driftWarnings       = [System.Collections.Generic.List[string]]::new()
    $integrityWarnings   = [System.Collections.Generic.List[string]]::new()
    $driftWarnedNums     = [System.Collections.Generic.HashSet[int]]::new()
    $orphanClaimWarnings = [System.Collections.Generic.List[string]]::new()

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
            $subIssuesTotalCount = [int]($issue.subIssues?.totalCount ?? 0)
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
    # OrphanClaimWarnings (B1 / #800): warn-only detector for OPEN issues whose
    # body claims a parent but have no actual sub-issue edge (.parent is $null).
    #
    # Per-producer regex discipline (design-challenge PF1 / plan-stress-test PF1
    # — a 5-pass adversarial plan stress-test caught this as a CRITICAL defect
    # in the original uniformly-anchored design):
    #   - `Parent: #N` is FIRST-LINE-ANCHORED: the Add-FollowUpIssue.ps1 /
    #     Set-IssueParent.ps1 text-fallback producer writes it as the body's
    #     literal first line, so anchoring here avoids false positives from
    #     prose mentions elsewhere in the body.
    #   - `placement=parent #N` is INTENTIONALLY UNANCHORED: the §2b-ter
    #     creation-time positioning-residue producer (skills/safe-operations/
    #     SKILL.md:163, format "Board positioning: priority=<h|m|l>;
    #     placement=parent #N; rationale=<one line>") writes it mid-line,
    #     never at column 0. Anchoring this pattern would silently miss the
    #     exact real-world Class-B incidents (#816/#817/#818) that motivated
    #     this detector.
    #   - The `<!-- parent-link-mode: text-fallback -->` marker is the primary,
    #     false-positive-free signal and is checked independently of both
    #     regexes.
    #
    # Interpolation safety: only the captured digit group is ever interpolated
    # into the warning message (never raw Match.Value, which could carry a
    # newline or other characters) — this guards against forging additional
    # workflow-command text into the CI ::warning:: output emitted downstream.
    # ---------------------------------------------------------------------------
    $firstLineParentPattern = '(?m)^Parent: #(\d+)'
    $placementParentPattern = 'placement=parent #(\d+)'
    $textFallbackMarker     = '<!-- parent-link-mode: text-fallback -->'

    foreach ($issue in $issueStateObjects) {
        if ($issue.state -ne 'OPEN') { continue }
        if ($null -ne $issue.parent) { continue }

        $body = $issue.body
        if ([string]::IsNullOrEmpty($body)) { continue }

        $hasMarker    = $body.Contains($textFallbackMarker)
        $firstLineHit = [regex]::Match($body, $firstLineParentPattern)
        $placementHit = [regex]::Match($body, $placementParentPattern)

        if (-not $hasMarker -and -not $firstLineHit.Success -and -not $placementHit.Success) { continue }

        # Digit-only interpolation: prefer the first-line producer's captured
        # group, then the placement-residue producer's; fall back to a safe
        # literal in the edge case where only the marker fired without either
        # regex matching (never interpolate raw match/body text).
        $claimedParent = if ($firstLineHit.Success) { $firstLineHit.Groups[1].Value }
                          elseif ($placementHit.Success) { $placementHit.Groups[1].Value }
                          else { 'unknown' }

        $orphanClaimWarnings.Add("⚠️ open issue #$($issue.number) claims a parent (#$claimedParent) but has no sub-issue link")
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
                    title     = $childNode.title ?? "Issue $($childNode.number)"
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

        # parent must be null (field is always present on reconstructed objects, absent == $null)
        if ($null -ne $issue.parent) { continue }

        # subIssues.totalCount must be 0
        $subTotalCount = [int]($issue.subIssues?.totalCount ?? 0)
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
        OrphanClaimWarnings = $orphanClaimWarnings.ToArray()
        RecentlyClosed      = $recentlyClosed.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Format-PortfolioMarkdown v2
# Renders v2 bucket model to Markdown string.
# Three-zone layout: Active / Umbrellas (ranked) / Triage / Recently closed
# Warnings (DriftWarnings + IntegrityWarnings + OrphanClaimWarnings) appear
# after zones, before footer.
# Footer: "portfolio content unchanged since {timestamp} — rendered by render-portfolio.ps1"
# Get-SplicedBody strips the footer line for idempotency comparison — do not move it.
# ---------------------------------------------------------------------------
function Format-PortfolioMarkdown {
    param($bucketModel, [string]$timestamp, [int[]]$UnresolvedNums = @(), [int[]]$BlockedByOverflowNums = @())

    $sb = [System.Text.StringBuilder]::new()

    # --- Active ---
    if ($null -ne $bucketModel.ActiveUmbrella) {
        $null = $sb.AppendLine("## 🎯 Active — #$($bucketModel.ActiveUmbrella.number) $($bucketModel.ActiveUmbrella.title)")
        # Children: consume verbatim, do NOT re-sort
        $children = if ($bucketModel.ActiveChildren) { @($bucketModel.ActiveChildren) } else { @() }
        foreach ($child in $children) {
            if ($child.BlockedAnnotation) {
                $null = $sb.AppendLine("- #$($child.number) $($child.title) $($child.BlockedAnnotation)")
            }
            else {
                $null = $sb.AppendLine("- #$($child.number) $($child.title)")
            }
        }
        $null = $sb.AppendLine('')
        # Done/total footer line
        $activeEntry = @($bucketModel.RankedUmbrellas | Where-Object { $_.IsActive })[0]
        if ($null -ne $activeEntry -and $activeEntry.Total -gt 0) {
            $null = $sb.AppendLine("── $($activeEntry.Done)/$($activeEntry.Total) done ──")
        }
        else {
            $null = $sb.AppendLine('── no children linked ──')
        }
    }
    else {
        $null = $sb.AppendLine('## 🎯 Active')
        $null = $sb.AppendLine('*(no active umbrella)*')
    }
    $null = $sb.AppendLine('')

    # --- Umbrellas (ranked) ---
    $null = $sb.AppendLine('## Umbrellas (ranked)')
    $rankedUmbrellas = if ($bucketModel.RankedUmbrellas) { @($bucketModel.RankedUmbrellas) } else { @() }
    foreach ($umb in $rankedUmbrellas) {
        $activeMarker = if ($umb.IsActive) { ' ◀ active' } else { '' }
        $null = $sb.AppendLine("- #$($umb.Number) $($umb.Title) $($umb.DoneTotalLabel)$activeMarker")
    }
    if ($rankedUmbrellas.Count -eq 0) {
        $null = $sb.AppendLine('*(none)*')
    }
    $null = $sb.AppendLine('')

    # --- Triage ---
    $null = $sb.AppendLine('## 🔥 Triage')
    $triageItems = if ($bucketModel.Triage) { @($bucketModel.Triage) } else { @() }
    if ($triageItems.Count -gt 0) {
        foreach ($issue in $triageItems) {
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)")
        }
        $residualCount = if ($null -ne $bucketModel.TriageResidualCount) { [int]$bucketModel.TriageResidualCount } else { 0 }
        if ($residualCount -gt 0) {
            $null = $sb.AppendLine("(+$residualCount more)")
        }
    }
    else {
        $null = $sb.AppendLine('*(none)*')
    }
    $null = $sb.AppendLine('')

    # --- Recently closed ---
    $null = $sb.AppendLine('## Recently closed')
    $rcItems = if ($bucketModel.RecentlyClosed) { @($bucketModel.RecentlyClosed) } else { @() }
    if ($rcItems.Count -gt 0) {
        foreach ($issue in $rcItems) {
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)")
        }
    }
    else {
        $null = $sb.AppendLine('*(none)*')
    }
    $null = $sb.AppendLine('')

    # --- Warnings (after zones, before footer) ---
    if ($bucketModel.DriftWarnings) {
        foreach ($warn in $bucketModel.DriftWarnings) {
            $null = $sb.AppendLine($warn)
        }
    }
    if ($bucketModel.IntegrityWarnings) {
        foreach ($warn in $bucketModel.IntegrityWarnings) {
            $null = $sb.AppendLine($warn)
        }
    }
    if ($bucketModel.OrphanClaimWarnings) {
        foreach ($warn in $bucketModel.OrphanClaimWarnings) {
            $null = $sb.AppendLine($warn)
        }
    }

    # --- BlockedByOverflowNums (truncated blocker list → excluded from startable routing) ---
    if ($BlockedByOverflowNums -and $BlockedByOverflowNums.Count -gt 0) {
        foreach ($n in $BlockedByOverflowNums) {
            $null = $sb.AppendLine("⚠️ Issue #${n}: blockedBy overflow — excluded from startable routing (blocker list truncated at 50)")
        }
    }

    # --- UnresolvedNums ---
    if ($UnresolvedNums -and $UnresolvedNums.Count -gt 0) {
        foreach ($n in $UnresolvedNums) {
            $null = $sb.AppendLine("⚠️ Warning: issue #$n could not be fully resolved (not found or incomplete blocker data) — verify it exists in GitHub and is still in sequence.yaml")
        }
    }

    # --- Footer ---
    # IMPORTANT: Get-SplicedBody strips this line for idempotency; do not move it.
    $null = $sb.AppendLine("portfolio content unchanged since $timestamp — rendered by render-portfolio.ps1")

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

    # 2. All umbrella numbers from the spec (v2: ordered list).
    $allIssueNums = @($spec.umbrellas)

    # Umbrella numbers + control tower (for leaf detection).
    $umbrellaNumbers = @(@($allIssueNums) + @($tower) | Sort-Object -Unique)

    # Step 0: Probe that parent + subIssues GraphQL fields are available.
    # v2 triage/drift model depends on parent-edge data; fail loud if unavailable.
    $probeQuery = @"
query {
  repository(owner: "Grimblaz", name: "agent-orchestra") {
    issue(number: $tower) {
      parent { number }
      subIssues(first: 1) { totalCount }
    }
  }
}
"@
    $probeRaw = gh api graphql -f query=$probeQuery
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Step 0 probe: GraphQL parent/subIssues fields unavailable (exit $LASTEXITCODE) — cannot render v2 board without parent-edge data." -ErrorAction Stop
    }
    $probeResponse = $null
    try { $probeResponse = $probeRaw | ConvertFrom-Json }
    catch {
        Write-Error "Step 0 probe: GraphQL returned non-JSON output despite exit 0 — cannot trust parent-edge data." -ErrorAction Stop
    }
    if ($null -eq $probeResponse) {
        Write-Error "Step 0 probe: GraphQL returned null/empty response — cannot trust parent-edge data." -ErrorAction Stop
    }
    if ($probeResponse.errors) {
        $errMsg = ($probeResponse.errors | ForEach-Object { $_.message }) -join '; '
        Write-Error "Step 0 probe: GraphQL parent/subIssues fields unavailable — $errMsg. Cannot render v2 board without parent-edge data." -ErrorAction Stop
    }

    # 2b. Bulk open scan (all open issues — data source for triage/drift classification).
    # Fail-loud: if this scan fails, the board must not be written in a partial
    # state. Hard-exit BEFORE any write step (gh issue edit) per AC8.
    # Write-Error -ErrorAction Stop raises a terminating error that propagates cleanly
    # through Pester's try/catch and terminates the script under direct invocation.
    $openIssuesRaw = gh issue list --repo Grimblaz/agent-orchestra --state open `
        --json number,title,labels,createdAt --limit $issueScanLimit
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch open issue list (exit $LASTEXITCODE)" -ErrorAction Stop
    }
    $openIssues = @()
    try {
        $openIssues = @($openIssuesRaw | ConvertFrom-Json)
    }
    catch {
        Write-Error "Failed to parse open issue list JSON: $_" -ErrorAction Stop
    }
    # Two-tier truncation contract: open/closed fail-loud (abort render).
    # count == limit is the only observable truncation signal; false-positive at exactly the ceiling is treated as truncation and accepted.
    if ($openIssues.Count -ge $issueScanLimit) {
        Write-Error "Open issue list returned $($openIssues.Count) results (limit $issueScanLimit) — refusing to render a potentially truncated board." -ErrorAction Stop
    }

    # 2c. Repo-wide closed scan (RecentlyClosed data source).
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

    # Step 2d (v1 triage-label scan) is REMOVED in v2.
    # Triage is now derived from parent-edge data in Get-PortfolioBuckets, not by label query.

    # 3. Query each umbrella via gh GraphQL.
    # v2: iterate $allIssueNums (spec.umbrellas) only; no $queryNums, no $triageNums.
    # Each umbrella query includes parent { number } and subIssues(first:50) so
    # Get-PortfolioBuckets v2 can detect ActiveChildren, drift, and triage.
    $issueStates    = [System.Collections.Generic.List[object]]::new()
    $unresolvedNums        = @()
    $blockedByOverflowNums = @()

    foreach ($num in $allIssueNums) {
        $query = @"
query {
  repository(owner: "Grimblaz", name: "agent-orchestra") {
    issue(number: $num) {
      number
      title
      state
      closedAt
      createdAt
      body
      labels(first: 50) { totalCount nodes { name } }
      blockedBy(first: 50) {
        totalCount
        nodes { number title state }
      }
      parent { number }
      subIssues(first: 50) {
        totalCount
        nodes { number state }
      }
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
        # subIssues overflow check runs before the blockedBy continue so the warning fires
        # even when blockedBy also overflows for the same umbrella (both must be observable, AC5).
        # v2: every iteration of this loop is an umbrella, so no $isUmbrella guard is needed —
        # only guard against a null subIssues field.
        if ($null -ne $issueData.subIssues -and
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

        # Build parent and subIssues fields for v2 Get-PortfolioBuckets
        $parentData    = if ($null -ne $issueData.parent) { @{ number = [int]$issueData.parent.number } } else { $null }
        $subIssueNodes = @($issueData.subIssues.nodes | ForEach-Object { @{ number = [int]$_.number; state = $_.state } })
        $subIssueData  = @{ totalCount = [int]$issueData.subIssues.totalCount; nodes = $subIssueNodes }

        $issueStates.Add([PSCustomObject]@{
            number              = $issueData.number
            title               = $issueData.title
            state               = $issueData.state
            closedAt            = $issueData.closedAt
            createdAt           = $issueData.createdAt
            body                = $issueData.body
            labels              = $labels
            blockedBy           = $openBlockers
            blockerInPlan       = $blockerInPlan
            blockedByTotalCount = $issueData.blockedBy.totalCount
            parent              = $parentData
            subIssues           = $subIssueData
        })
    }

    # 3b. Open-leaf detail pass: query ALL non-umbrella open issues from the open scan
    # with parent { number } and subIssues(first:1) { totalCount } so Get-PortfolioBuckets
    # can classify them as Triage (parent=null, totalCount=0) or DriftWarnings
    # (totalCount>0, not in umbrella list). Fail-loud: a leaf-query failure warns and skips.
    $alreadyQueried = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($q in $allIssueNums) { $null = $alreadyQueried.Add([int]$q) }
    $null = $alreadyQueried.Add([int]$tower)

    $openIssueCandidateNums = @(
        $openIssues |
        Where-Object {
            $n = [int]$_.number
            -not $alreadyQueried.Contains($n)
        } |
        ForEach-Object { [int]$_.number }
    )

    foreach ($num in $openIssueCandidateNums) {
        $query = @"
query {
  repository(owner: "Grimblaz", name: "agent-orchestra") {
    issue(number: $num) {
      number
      title
      state
      closedAt
      createdAt
      body
      labels(first: 50) { totalCount nodes { name } }
      blockedBy(first: 50) {
        totalCount
        nodes { number title state }
      }
      parent { number }
      subIssues(first: 1) { totalCount }
    }
  }
}
"@
        $rawJson = gh api graphql -f query=$query
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "GraphQL query failed for leaf #$num (exit $LASTEXITCODE) — skipping."
            continue
        }
        $response = $null
        try { $response = $rawJson | ConvertFrom-Json }
        catch { Write-Warning "Failed to parse GraphQL response for leaf #$num — skipping."; continue }
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

        # Build parent and subIssues for v2 triage/drift detection.
        # Only first:1 was requested so nodes = @() (totalCount is sufficient for drift detection).
        $parentData   = if ($null -ne $issueData.parent) { @{ number = [int]$issueData.parent.number } } else { $null }
        $subIssueData = @{ totalCount = [int]$issueData.subIssues.totalCount; nodes = @() }

        $issueStates.Add([PSCustomObject]@{
            number              = $issueData.number
            title               = $issueData.title
            state               = $issueData.state
            closedAt            = $issueData.closedAt
            createdAt           = $issueData.createdAt
            body                = $issueData.body
            labels              = $labels
            blockedBy           = $openBlockers
            blockerInPlan       = $blockerInPlan
            blockedByTotalCount = $issueData.blockedBy.totalCount
            parent              = $parentData
            subIssues           = $subIssueData
        })
    }

    # 3c. Add closed-scan results to issueStates for RecentlyClosed bucket.
    # Get-PortfolioBuckets v2 derives RecentlyClosed from issueStateObjects where
    # state == CLOSED and closedAt is within the window. The closed scan provides this data.
    $closedAlreadyQueried = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($s in $issueStates) { $null = $closedAlreadyQueried.Add([int]$s.number) }
    foreach ($cl in $closedLeaves) {
        $clNum = [int]$cl.number
        if ($closedAlreadyQueried.Contains($clNum)) { continue }
        $clLabels = @()
        if ($cl.PSObject.Properties['labels'] -and $null -ne $cl.labels) {
            $clLabels = @($cl.labels | ForEach-Object {
                if ($_ -is [string]) { $_ } elseif ($null -ne $_.name) { $_.name }
            })
        }
        $issueStates.Add([PSCustomObject]@{
            number              = $clNum
            title               = $cl.title ?? "Issue $clNum"
            state               = 'CLOSED'
            closedAt            = $cl.closedAt
            createdAt           = $cl.createdAt
            labels              = $clLabels
            blockedBy           = @()
            blockerInPlan       = $true
            blockedByTotalCount = 0
            parent              = $null
            subIssues           = $null
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

    # 5b. CI ::warning:: per OrphanClaimWarnings entry (B1 / #800). Get-PortfolioBuckets
    # stays pure (no I/O) — the warning strings it returns already interpolate only the
    # captured digit group (never raw body/match text), so it is safe to echo them
    # verbatim here as CI annotations.
    if ($env:GITHUB_ACTIONS -eq 'true' -and $buckets.OrphanClaimWarnings) {
        foreach ($warn in $buckets.OrphanClaimWarnings) {
            Write-Host "::warning::$warn"
        }
    }

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
        [hashtable] $SubIssues    = $null,
        [string]    $Body         = $null
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
        body          = $Body
    }
}

# ---------------------------------------------------------------------------
# Direct invocation entry point
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PortfolioRender -specPath $specPath
}
