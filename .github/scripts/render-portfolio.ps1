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
    param($spec, $issueStateObjects)

    # All issue numbers across all rounds (flat, unique, sorted)
    $allIssueNumbers = @(
        $spec.rounds | ForEach-Object { $_.issues } | Sort-Object -Unique
    )

    $cutoff = (Get-Date).AddDays(-$spec.recently_closed_days)

    $closedWithinWindow = [System.Collections.Generic.List[object]]::new()
    $openBlocked        = [System.Collections.Generic.List[object]]::new()
    $openUnblocked      = [System.Collections.Generic.List[object]]::new()
    $triage             = [System.Collections.Generic.List[object]]::new()

    foreach ($issue in $issueStateObjects) {
        if ($issue.state -eq 'CLOSED') {
            if ($issue.closedAt) {
                [datetime]$closedDate = [datetime]::MinValue
                if ([datetime]::TryParse($issue.closedAt, [ref]$closedDate)) {
                    if ($closedDate -ge $cutoff) {
                        $closedWithinWindow.Add($issue)
                    }
                }
            }
            continue
        }

        # Open issue — check triage label or unsequenced
        $inAnyRound     = $allIssueNumbers -contains $issue.number
        $hasTriageLabel = $issue.labels -contains 'triage'

        if ($hasTriageLabel -or (-not $inAnyRound)) {
            $triage.Add($issue)
            continue
        }

        # Open, sequenced — check blockers
        if ($issue.blockedBy -and $issue.blockedBy.Count -gt 0) {
            # Build per-blocker annotations
            $annotations = $issue.blockedBy | ForEach-Object {
                $blockerNum    = $_
                $blockerInPlan = $issue.blockerInPlan
                if ($blockerInPlan -eq $false) {
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

    # Determine Now and Next from sorted rounds
    $sortedRounds = @($spec.rounds | Sort-Object round)
    $nowRoundIdx  = -1
    $allOpenIssues = @($openBlocked) + @($openUnblocked)
    for ($i = 0; $i -lt $sortedRounds.Count; $i++) {
        $roundIssueNums = $sortedRounds[$i].issues
        $hasOpen        = $allOpenIssues | Where-Object { $roundIssueNums -contains $_.number }
        if ($hasOpen) {
            $nowRoundIdx = $i
            break
        }
    }

    $nowIssues  = @()
    $nextIssues = @()

    if ($nowRoundIdx -ge 0) {
        $nowRoundNums = $sortedRounds[$nowRoundIdx].issues
        $nowIssues    = @(
            $openUnblocked |
            Where-Object  { $nowRoundNums -contains $_.number } |
            Sort-Object   number
        )

        if (($nowRoundIdx + 1) -lt $sortedRounds.Count) {
            $nextRoundNums = $sortedRounds[$nowRoundIdx + 1].issues
            $nextIssues    = @(
                $openUnblocked |
                Where-Object  { $nextRoundNums -contains $_.number } |
                Sort-Object   number
            )
        }
    }

    # Helper: return actual bucket item count (no overflow unless bucket is explicitly capped)
    function Get-BucketTotal {
        param([array]$items)
        if ($null -ne $items) { return $items.Count }
        return 0
    }

    $blockedSorted        = @($openBlocked        | Sort-Object number)
    $recentlyClosedSorted = @($closedWithinWindow  | Sort-Object number)
    $triageSorted         = @($triage              | Sort-Object number)

    return [PSCustomObject]@{
        Now                      = $nowIssues
        NowTotalCount            = Get-BucketTotal $nowIssues
        Next                     = $nextIssues
        NextTotalCount           = Get-BucketTotal $nextIssues
        Blocked                  = $blockedSorted
        BlockedTotalCount        = Get-BucketTotal $blockedSorted
        RecentlyClosed           = $recentlyClosedSorted
        RecentlyClosedTotalCount = Get-BucketTotal $recentlyClosedSorted
        Triage                   = $triageSorted
        TriageTotalCount         = Get-BucketTotal $triageSorted
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

    # Helper: safe total count from model property (may be absent in test fixtures)
    function Get-ModelTotal {
        param([object]$model, [string]$propName, [int]$renderedCount)
        $prop = $model.PSObject.Properties[$propName]
        if ($null -ne $prop) {
            return [int]$prop.Value
        }
        return $renderedCount
    }

    # --- Now ---
    $null = $sb.AppendLine('## Now')
    $nowItems = if ($bucketModel.Now) { @($bucketModel.Now | Sort-Object number) } else { @() }
    if ($nowItems.Count -gt 0) {
        foreach ($issue in $nowItems) {
            $null = $sb.AppendLine("- #$($issue.number) $($issue.title)")
        }
        $nowTotal = Get-ModelTotal $bucketModel 'NowTotalCount' $nowItems.Count
        if ($nowTotal -gt $nowItems.Count) {
            $overflow = $nowTotal - $nowItems.Count
            $null = $sb.AppendLine("(+$overflow more)")
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
    $null = $sb.AppendLine("as of $timestamp — rendered by render-portfolio.ps1")

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
    $footerPattern = 'as of \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z[^\n]*rendered by render-portfolio\.ps1\r?\n?'

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
        [string]$specPath     = 'Documents/Planning/sequence.yaml',
        [int]   $controlTower = 0   # 0 = read from spec
    )

    # 1. Parse spec
    $specText = Get-Content $specPath -Raw -ErrorAction Stop
    $spec = ConvertFrom-SequenceSpec -yamlText $specText
    if ($null -eq $spec) {
        Write-Error "Failed to parse sequence spec at $specPath"
        exit 1
    }

    $tower = if ($controlTower -gt 0) { $controlTower } else { $spec.control_tower }

    # 2. Collect all issue numbers from all rounds
    $allIssueNums = @(
        $spec.rounds | ForEach-Object { $_.issues } | Sort-Object -Unique
    )

    # 3. Query each issue via gh GraphQL (first: 50 per connection)
    $issueStates    = [System.Collections.Generic.List[object]]::new()
    $unresolvedNums = @()

    foreach ($num in $allIssueNums) {
        $query = @"
query {
  repository(owner: "Grimblaz", name: "agent-orchestra") {
    issue(number: $num) {
      number
      title
      state
      closedAt
      labels(first: 50) { totalCount nodes { name } }
      blockedBy(first: 50) {
        totalCount
        nodes { number title state }
      }
    }
  }
}
"@
        $rawJson = gh api graphql -f query=$query 2>&1
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
        if ($response.errors) {
            Write-Warning "GraphQL errors for issue #$num — skipping."
            $unresolvedNums += $num
            continue
        }
        $issueData = $response.data.repository.issue

        if ($null -eq $issueData) {
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
            number             = $issueData.number
            title              = $issueData.title
            state              = $issueData.state
            closedAt           = $issueData.closedAt
            labels             = $labels
            blockedBy          = $openBlockers
            blockerInPlan      = $blockerInPlan
            blockedByTotalCount = $issueData.blockedBy.totalCount
        })
    }

    # 4. Fetch current control tower body
    $ctRawJson = gh issue view $tower --repo Grimblaz/agent-orchestra --json body 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch control tower issue #$tower (exit $LASTEXITCODE)"
        exit 1
    }
    $ctData = $null
    try {
        $ctData = $ctRawJson | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse control tower issue body JSON: $_"
        exit 1
    }
    $existingBody = $ctData.body

    # 5. Derive buckets
    $buckets = Get-PortfolioBuckets -spec $spec -issueStateObjects $issueStates.ToArray()

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
    gh issue edit $tower --repo Grimblaz/agent-orchestra --body $newBody 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update control tower issue #$tower (exit $LASTEXITCODE)"
        exit 1
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
        [string]  $ClosedAt     = $null
    )
    return [PSCustomObject]@{
        number        = $Number
        state         = $State
        title         = $Title
        labels        = $Labels
        blockedBy     = $BlockedBy
        blockerInPlan = $BlockerInPlan
        closedAt      = $ClosedAt
        totalCount    = 1  # default rendered count = totalCount (no overflow)
    }
}

# ---------------------------------------------------------------------------
# Direct invocation entry point
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PortfolioRender -specPath $specPath
}
