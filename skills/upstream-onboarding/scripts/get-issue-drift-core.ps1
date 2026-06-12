#Requires -Version 7.0
<#
.SYNOPSIS
    Library for issue-drift detection logic. Dot-source this file and call Get-IssueDrift.

.DESCRIPTION
    Scans merged PRs since an issue was created to identify which PRs touched files
    referenced in the issue body. Used by upstream-onboarding to surface drift context
    when resuming work on an existing issue.

    Call Get-IssueDrift directly with -IssueJsonOverride and -PrListJsonOverride for
    dependency-injection in tests; those parameters replace the live gh CLI calls.

.OUTPUTS
    Returns a PSCustomObject that the wrapper serializes to JSON.
    All paths return exit 0; errors are returned as {error: "..."} objects.
#>

function Get-IssueDrift {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IssueNumber,

        [int]$ThresholdDays = 7,

        [switch]$Force,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$Cap = 10,

        [string[]]$ExcludePaths = @(
            '.claude-plugin/',
            '.github/plugin/',
            'plugin.json',
            'marketplace.json',
            'CHANGELOG.md'
        ),

        [AllowNull()]
        [string]$IssueJsonOverride = $null,

        [AllowNull()]
        [string]$PrListJsonOverride = $null
    )

    # ----------------------------------------------------------------
    # Helper: return a structured error object
    # ----------------------------------------------------------------
    function New-DriftError {
        param([string]$Message)
        return [pscustomobject]@{ error = $Message }
    }

    # ----------------------------------------------------------------
    # STEP 1: Fetch issue JSON (DI-injectable)
    # ----------------------------------------------------------------
    $issueJson = $null
    if (-not [string]::IsNullOrWhiteSpace($IssueJsonOverride)) {
        $issueJson = $IssueJsonOverride
    }
    else {
        try {
            $rawOutput = & gh issue view $IssueNumber --json 'number,title,body,createdAt' 2>$null
            if ($LASTEXITCODE -ne 0) {
                return (New-DriftError "gh issue view failed for issue ${IssueNumber}: $rawOutput")
            }
            $issueJson = $rawOutput | Out-String
        }
        catch {
            return (New-DriftError "Exception fetching issue ${IssueNumber}: $($_.Exception.Message)")
        }
    }

    # ----------------------------------------------------------------
    # STEP 2: Parse issue JSON
    # ----------------------------------------------------------------
    $issueData = $null
    try {
        $issueData = $issueJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return (New-DriftError "Failed to parse issue JSON: $($_.Exception.Message)")
    }

    if ($null -eq $issueData -or [string]::IsNullOrWhiteSpace($issueData.createdAt)) {
        return (New-DriftError "Issue JSON is missing required field 'createdAt'")
    }

    $issueNumberInt = 0
    if ($null -eq $issueData.number -or -not [int]::TryParse([string]$issueData.number, [ref]$issueNumberInt)) {
        return (New-DriftError "Issue JSON is missing or has an invalid 'number' field")
    }

    $issueCreatedAt = $issueData.createdAt

    # ----------------------------------------------------------------
    # STEP 3: Age gate — MUST run before any gh pr list call
    # ----------------------------------------------------------------
    $createdAtOffset = $null
    try {
        $createdAtOffset = [DateTimeOffset]::Parse($issueCreatedAt)
    }
    catch {
        return (New-DriftError "Failed to parse createdAt timestamp '$issueCreatedAt': $($_.Exception.Message)")
    }

    $nowOffset = [DateTimeOffset]::UtcNow
    $ageHours = ($nowOffset - $createdAtOffset).TotalHours

    if (-not $Force -and ($ageHours -le ($ThresholdDays * 24))) {
        return [pscustomobject]@{ skipped = 'below-threshold' }
    }

    # ----------------------------------------------------------------
    # STEP 4: Fetch merged PR list (DI-injectable)
    # ----------------------------------------------------------------
    # Date-granular string for GitHub's merged: qualifier (date only, not datetime)
    $dateStr = $createdAtOffset.UtcDateTime.ToString('yyyy-MM-dd')

    $prJson = $null
    if (-not [string]::IsNullOrWhiteSpace($PrListJsonOverride)) {
        $prJson = $PrListJsonOverride
    }
    else {
        try {
            $rawOutput = & gh pr list --state merged --search "merged:>=$dateStr" --limit 200 --json 'number,title,mergedAt,files,changedFiles' 2>$null
            if ($LASTEXITCODE -ne 0) {
                return (New-DriftError "gh pr list failed: $rawOutput")
            }
            $prJson = $rawOutput | Out-String
        }
        catch {
            return (New-DriftError "Exception fetching PR list: $($_.Exception.Message)")
        }
    }

    # ----------------------------------------------------------------
    # STEP 5: Parse PR list JSON
    # ----------------------------------------------------------------
    $allPrs = $null
    try {
        $allPrs = $prJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return (New-DriftError "Failed to parse PR list JSON: $($_.Exception.Message)")
    }

    if ($null -eq $allPrs) {
        $allPrs = @()
    }

    # Ensure array (ConvertFrom-Json may return a single object for a 1-element list)
    $allPrs = @($allPrs)

    # Detect truncation: raw list hit the 200-limit ceiling
    $truncated = ($allPrs.Count -ge 200)

    # ----------------------------------------------------------------
    # STEP 6: Post-filter — UTC invariant using DateTimeOffset
    # Keep only PRs merged strictly after the issue createdAt timestamp.
    # Never compare against [DateTime]; always use [DateTimeOffset].
    # ----------------------------------------------------------------
    $filteredPrs = @($allPrs | Where-Object {
        if ([string]::IsNullOrWhiteSpace($_.mergedAt)) { return $false }
        try {
            $mergedOffset = [DateTimeOffset]::Parse($_.mergedAt)
            return $mergedOffset -gt $createdAtOffset
        }
        catch {
            return $false
        }
    })

    $totalMergedSince = $filteredPrs.Count
    $filesUnavailableCount = 0

    # ----------------------------------------------------------------
    # STEP 7: Token extraction from issue body
    # ----------------------------------------------------------------
    $issueBody = $issueData.body
    $tokens = @()

    if (-not [string]::IsNullOrWhiteSpace($issueBody)) {
        $tokenMatches = [regex]::Matches($issueBody, '`([^`]+)`')
        foreach ($match in $tokenMatches) {
            $raw = $match.Groups[1].Value

            # Normalize backslashes
            $raw = $raw.Replace('\', '/')

            # Strip line-suffix: trailing :NN and compound :NN/:MM
            # e.g. SKILL.md:309 -> SKILL.md, file.ps1:10/20 -> file.ps1
            $raw = $raw -replace ':\d+(/\d+)*$', ''

            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $tokens += $raw
            }
        }
    }

    # ----------------------------------------------------------------
    # STEP 8: Match PRs against tokens, apply ExcludePaths, rank
    # ----------------------------------------------------------------
    $candidates = @()

    foreach ($pr in $filteredPrs) {
        # Null-safety: treat missing/null files as files_truncated
        $filesTruncated = $false
        $prFiles = $null

        if ($null -eq $pr.files) {
            $filesTruncated = $true
        }
        elseif ($pr.files -is [System.Collections.IEnumerable] -and $pr.files -isnot [string]) {
            $prFiles = @($pr.files)
            # Check per-PR file truncation: files list shorter than changedFiles count
            $changedFilesCount = 0
            try { $changedFilesCount = [int]$pr.changedFiles } catch { $changedFilesCount = 0 }
            if ($prFiles.Count -lt $changedFilesCount) {
                $filesTruncated = $true
            }
        }
        else {
            $filesTruncated = $true
        }

        # If files are unavailable, we cannot do path-matching for this PR
        if ($filesTruncated -and $null -eq $prFiles) {
            $filesUnavailableCount++
            continue
        }

        if ($null -eq $prFiles -or $prFiles.Count -eq 0) {
            continue
        }

        # Collect file path strings from the PR (gh returns objects with .path)
        $prPaths = @($prFiles | ForEach-Object {
            $p = if ($_ -is [string]) { $_ } else { $_.path }
            if (-not [string]::IsNullOrWhiteSpace($p)) { $p.Replace('\', '/') }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        if ($tokens.Count -eq 0) {
            # No tokens — zero-match path; don't add candidates
            continue
        }

        # Match each token against each PR path
        $matchedPaths = [System.Collections.Generic.List[string]]::new()

        foreach ($candidatePath in $prPaths) {
            $matched = $false
            foreach ($token in $tokens) {
                # Leading-/ tokens: strip the slash and do exact/suffix match directly
                if ($token.StartsWith('/')) {
                    $tokenStripped = $token.TrimStart('/')
                    if ($candidatePath -eq $tokenStripped -or $candidatePath -like "*/$tokenStripped") {
                        $matched = $true
                        break
                    }
                    continue
                }

                # Directory prefix match: token ends with /
                if ($token.EndsWith('/')) {
                    if ($candidatePath -like "$token*") {
                        $matched = $true
                        break
                    }
                    continue
                }

                # Token has a slash — treat as repo-relative or partial path
                if ($token.Contains('/')) {
                    if ($candidatePath -eq $token -or $candidatePath -like "*/$token") {
                        $matched = $true
                        break
                    }
                }
                else {
                    # Basename-only token
                    $basename = [System.IO.Path]::GetFileName($candidatePath)
                    if ($basename -eq $token -or $candidatePath -eq $token -or $candidatePath -like "*/$token") {
                        $matched = $true
                        break
                    }
                }
            }

            if ($matched) {
                $matchedPaths.Add($candidatePath)
            }
        }

        if ($matchedPaths.Count -eq 0) {
            continue
        }

        # Apply ExcludePaths: exclude candidate only if ALL matched paths are in ExcludePaths.
        # Directory entries (trailing /) use prefix semantics; file entries use exact/basename
        # semantics to mirror inclusion matching and avoid prefix-collision false-positives.
        $nonExcludedMatchedPaths = @($matchedPaths | Where-Object {
            $mp = $_
            $isExcluded = $false
            foreach ($excl in $ExcludePaths) {
                if ($excl.EndsWith('/')) {
                    if ($mp -eq $excl.TrimEnd('/') -or $mp -like "$excl*") {
                        $isExcluded = $true
                        break
                    }
                }
                else {
                    $mpBasename = [System.IO.Path]::GetFileName($mp)
                    if ($mp -eq $excl -or $mpBasename -eq $excl -or $mp -like "*/$excl") {
                        $isExcluded = $true
                        break
                    }
                }
            }
            -not $isExcluded
        })

        if ($nonExcludedMatchedPaths.Count -eq 0) {
            continue
        }

        $candidates += [pscustomobject]@{
            number         = $pr.number
            title          = $pr.title
            mergedAt       = $pr.mergedAt
            overlap        = $nonExcludedMatchedPaths.Count
            files_truncated = $filesTruncated
            matched_paths  = @($nonExcludedMatchedPaths)
        }
    }

    # ----------------------------------------------------------------
    # STEP 9: Zero-match case (no candidates, including empty body)
    # ----------------------------------------------------------------
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            issue_number            = $issueNumberInt
            issue_created_at        = $issueCreatedAt
            total_merged_since      = $totalMergedSince
            truncated               = $truncated
            cap                     = $Cap
            intersection            = 'none'
            files_unavailable_count = $filesUnavailableCount
        }
    }

    # ----------------------------------------------------------------
    # STEP 10: Sort and cap
    # ----------------------------------------------------------------
    # Sort: overlap descending, then mergedAt descending
    $sorted = @($candidates | Sort-Object -Property @(
        @{ Expression = 'overlap'; Descending = $true },
        @{ Expression = 'mergedAt'; Descending = $true }
    ))

    $totalMatching = $sorted.Count
    $capped = @($sorted | Select-Object -First $Cap)
    $moreCount = [Math]::Max(0, $totalMatching - $Cap)

    return [pscustomobject]@{
        issue_number            = $issueNumberInt
        issue_created_at        = $issueCreatedAt
        total_merged_since      = $totalMergedSince
        truncated               = $truncated
        cap                     = $Cap
        more_count              = $moreCount
        files_unavailable_count = $filesUnavailableCount
        candidates              = $capped
    }
}
