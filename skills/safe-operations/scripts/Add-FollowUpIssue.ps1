#Requires -Version 7.0
<#
.SYNOPSIS
    Helper script to create follow-up issues and parent them via GraphQL.

.DESCRIPTION
    M1: Writes the <!-- code-conductor-filed-followup --> sentinel into the
        filed issue body carrying matched criterion_id(s) and the originating
        PR. The sentinel is the AC8 contract and is written unconditionally
        (empty criterion_ids list and missing originating_pr are both legal).

    M3: Emits a defensive Write-Warning when any element of -Labels contains
        a comma, which would cause `gh issue create --label <csv>` to mis-split
        label boundaries. Per Agent-Orchestra label conventions this is rare,
        but the warning is the contract per the judge.

    M13: Appends a <!-- parent-link-mode: graphql|text-fallback --> marker as
         the last line of the filed body so calibration can measure GraphQL
         survival rate.

    M15: Emits Write-Error (ErrorAction Continue) when GraphQL parent/child
         Node IDs cannot be resolved so the "GraphQL skipped" path is
         machine-detectable on stderr instead of invisible.

    M16: When -AcCrossCheck is provided, appends a fenced YAML block before the
         sentinel block carrying the ac_cross_check provenance (AC4 contract).
#>

function ConvertTo-CanonicalFollowupTitle {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FindingSubject,
        [string[]]$CriterionIds
    )

    $crit = "structural"
    if ($CriterionIds -and $CriterionIds.Count -gt 0) {
        # Use first matched criterion ID, e.g. S-cross-cutting
        $crit = $CriterionIds[0]
    }

    # Clean up subject: trim, strip trailing periods and colons, normalize spaces
    $cleaned = $FindingSubject.Trim().TrimEnd('.', ':', ' ') -replace '\s+', ' '

    return "[Structural] ${crit}: $cleaned"
}

function New-FollowupSentinelBlock {
    <#
    .SYNOPSIS
        Build the AC8 outcome sentinel block (M1).
    #>
    param(
        [string[]]$CriterionIds,
        [string]$OriginatingPr
    )

    $ids = @()
    if ($CriterionIds) { $ids = @($CriterionIds | Where-Object { $_ }) }
    $idList = if ($ids.Count -gt 0) { "[" + ($ids -join ', ') + "]" } else { "[]" }

    $lines = @()
    $lines += '<!-- code-conductor-filed-followup'
    $lines += "criterion_ids: $idList"
    if ($OriginatingPr) {
        $lines += "originating_pr: $OriginatingPr"
    }
    $lines += '-->'
    return ($lines -join "`n")
}

# CONTRACT — caller responsibility:
# The caller MUST run skills/safe-operations/SKILL.md § 2c (Deduplication Check) BEFORE invoking
# Add-FollowUpIssue. This helper performs no dedup of its own; it will create duplicate issues
# if invoked twice with the same title. Both the Code-Conductor follow-up filing path and the
# code-review-intake bot-review filing path must canonicalize the title (via the
# ConvertTo-CanonicalFollowupTitle helper or equivalent) and run §2c dedup-on-create against
# the canonicalized title before calling this function.
function Add-FollowUpIssue {
    param(
        [Parameter(Mandatory=$true)]
        $ParentIssue,

        [Parameter(Mandatory=$true)]
        [string]$Title,

        [Parameter(Mandatory=$true)]
        [string]$Body,

        [Parameter(Mandatory=$true)]
        [string[]]$Labels,

        [string[]]$CriterionId,

        # M1: criterion IDs persisted into the sentinel block.
        [string[]]$CriterionIds = @(),

        # M1: PR number/URL this follow-up was triggered from.
        [string]$OriginatingPr,

        # AC4: ac_cross_check object from Get-StructuralVerdict.
        # When provided, appended as a fenced YAML block in the issue body
        # before the sentinel block so the follow-up issue carries AC-provenance.
        [hashtable]$AcCrossCheck
    )

    # M1: Compose the body with parent ref, caller body, and sentinel block.
    # Layout: "Parent: #X\n\n<Body>\n\n<sentinel>"
    $parentRef = "Parent: #$ParentIssue"
    # If CriterionIds parameter is empty but the legacy -CriterionId alias is supplied, use that.
    $effectiveCriterionIds = if ($CriterionIds -and $CriterionIds.Count -gt 0) { $CriterionIds } elseif ($CriterionId) { $CriterionId } else { @() }
    $sentinel = New-FollowupSentinelBlock -CriterionIds $effectiveCriterionIds -OriginatingPr $OriginatingPr

    # AC4: append ac_cross_check YAML block when provided.
    $acBlock = ''
    if ($AcCrossCheck) {
        $yaml = ($AcCrossCheck.GetEnumerator() | Sort-Object Key | ForEach-Object {
            $v = if ($_.Value -is [bool]) {
                $_.Value.ToString().ToLower()
            } elseif ($null -eq $_.Value) {
                'null'
            } else {
                $escaped = ([string]$_.Value).Replace('\', '\\').Replace('"', '\"')
                "`"$escaped`""
            }
            "  $($_.Key): $v"
        }) -join "`n"
        $acBlock = "`n`n**AC Cross-Check**`n``````yaml`n$yaml`n``````"
    }

    $bodyWithParent = "$parentRef`n`n$Body$acBlock`n`n$sentinel"

    # M3: Warn on comma-bearing labels before constructing the CSV.
    foreach ($label in $Labels) {
        if ($label -and $label.Contains(',')) {
            Write-Warning "Label '$label' contains a comma; gh issue create may misinterpret label boundaries."
        }
    }

    # 1. Create the issue via gh
    $labelCsv = $Labels -join ','
    $issueUrl = gh issue create --title $Title --body $bodyWithParent --label $labelCsv

    if (-not $issueUrl) {
        Write-Error "gh issue create failed."
        return $null
    }

    # Extract new issue number from URL
    if ($issueUrl -match '/issues/(\d+)') {
        $childNumber = $Matches[1]
    } else {
        # Fall back to URL or exit
        Write-Warning "Could not extract child issue number from URL: $issueUrl"
        return $issueUrl
    }

    # 2. GraphQL Linkage with retry
    # Get parent and child GraphQL Node IDs
    $parentId = $null
    $childId = $null
    try {
        $parentId = gh issue view $ParentIssue --json id --jq .id 2>$null
        $childId = gh issue view $childNumber --json id --jq .id 2>$null
    } catch {
        Write-Warning "Failed to resolve GraphQL node IDs for parent #$ParentIssue or child #${childNumber}`: $($_.Exception.Message)"
    }

    $graphqlSuccess = $false

    if ($parentId -and $childId) {
        $mutation = @"
mutation {
  addSubIssue(input: {
    issueId: "$parentId",
    subIssueId: "$childId"
  }) {
    issue { title }
  }
}
"@
        $attempts = 0
        while (-not $graphqlSuccess -and $attempts -lt 2) {
            $attempts++
            try {
                $result = gh api graphql -H "GraphQL-Features: sub_issues" -f "query=$mutation" 2>$null
                if ($LASTEXITCODE -eq 0 -and $result) {
                    # G4: check for GraphQL-level errors returned with exit code 0
                    $parsed = $result | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($parsed -and $parsed.errors) {
                        Write-Warning "GraphQL addSubIssue returned errors: $($parsed.errors | ConvertTo-Json -Compress)"
                    } else {
                        $graphqlSuccess = $true
                    }
                }
            } catch {
                # Try again
            }
        }

        if (-not $graphqlSuccess) {
            Write-Warning "Failed to link issue #$childNumber to parent issue #$ParentIssue via GitHub GraphQL sub-issues after 2 attempts."
        }
    } else {
        # M15: machine-detectable structured failure.
        Write-Error "addSubIssue prerequisite failed: childId=$childId parentId=$parentId; fallback to text-only parenting" -ErrorAction Continue
        Write-Warning "Could not retrieve GraphQL Node IDs for parent #$ParentIssue or child #$childNumber."
    }

    # M13: append parent-link-mode marker AFTER sentinel as final body line.
    $linkMode = if ($graphqlSuccess) { 'graphql' } else { 'text-fallback' }
    $linkMarker = "<!-- parent-link-mode: $linkMode -->"
    $finalBody = "$bodyWithParent`n$linkMarker"

    try {
        gh issue edit $childNumber --body $finalBody 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to append parent-link-mode marker to issue #$childNumber body."
        }
    } catch {
        Write-Warning "Exception while appending parent-link-mode marker to issue #$childNumber."
    }

    return $issueUrl
}
