#Requires -Version 7.0
<#
.SYNOPSIS
    Helper script to create follow-up issues and parent them via GraphQL.
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

        [string[]]$CriterionId
    )

    # Prepend human-readable parentage text reference to the body per D2 transition rule
    $parentRef = "Parent: #$ParentIssue"
    $bodyWithParent = "$parentRef`n`n$Body"

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
        # Fail silent, handled by the loop
    }

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
        $success = $false
        $attempts = 0
        while (-not $success -and $attempts -lt 2) {
            $attempts++
            try {
                $result = gh api graphql -H "GraphQL-Features: sub_issues" -f query=$mutation 2>$null
                if ($LASTEXITCODE -eq 0 -and $result) {
                    $success = $true
                }
            } catch {
                # Try again
            }
        }

        if (-not $success) {
            Write-Warning "Failed to link issue #$childNumber to parent issue #$ParentIssue via GitHub GraphQL sub-issues after 2 attempts."
        }
    } else {
        Write-Warning "Could not retrieve GraphQL Node IDs for parent #$ParentIssue or child #$childNumber."
    }

    return $issueUrl
}
