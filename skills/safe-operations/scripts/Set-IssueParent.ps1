#Requires -Version 7.0
<#
.SYNOPSIS
    Attaches an already-existing child issue to an already-existing parent
    issue via GitHub's GraphQL sub-issues API, failing loudly (non-zero
    exit) instead of silently degrading when the attach cannot be completed.

.DESCRIPTION
    Standalone counterpart to Add-FollowUpIssue.ps1 for the "attach an
    existing child" case (plan-issue-800 Fork 1: extracted into a separate
    script rather than a new param on the shared file, so the four existing
    dot-source consumers of Add-FollowUpIssue.ps1 are unaffected — AC5).

    Ported from Add-FollowUpIssue.ps1:158-208: the GraphQL Node-ID
    resolution, the addSubIssue mutation, and the 2-attempt retry loop
    (including the `$parsed.errors` check for GraphQL errors returned with
    HTTP/exit-code 0). Intentional divergence from the source: the source
    function only Write-Warnings on a failed attach (issue creation itself
    still "succeeds" either way); this script treats a failed attach as the
    whole operation failing and exits non-zero, because attaching an
    existing issue IS the entire operation here — there is no "created
    issue" fallback value to return.

    Adds, beyond the ported block:
      - A self-reference guard (ParentIssueNumber == ChildIssueNumber).
      - A pre-check (via `gh api graphql`, since `gh issue view --json`
        has no `parent` field) that reads the child's current parent before
        attempting anything: already-correct is idempotent success,
        already-different is a loud failure (parent-mismatch *resolution*
        is out of scope here — deferred to a future issue).
      - On an unrecoverable failure, an idempotent splice of a
        "Parent: #N" claim line plus a
        <!-- parent-link-mode: text-fallback --> marker into the child
        issue's body, so the render-portfolio OrphanClaimWarnings detector
        can flag it. Re-running a failed attach replaces rather than
        duplicates the claim/marker.
      - On success (attach or already-correct pre-check), strips any stale
        claim/marker a prior failed run left behind, since success clears
        it (marker hygiene).

.PARAMETER ParentIssueNumber
    The issue number of the parent to attach the child to.

.PARAMETER ChildIssueNumber
    The issue number of the already-existing child issue to attach.
#>

param(
    [Parameter(Mandatory = $true)]
    [int]$ParentIssueNumber,

    [Parameter(Mandatory = $true)]
    [int]$ChildIssueNumber
)

# Literal marker/claim shared with the render-portfolio OrphanClaimWarnings
# detector contract (skills/safe-operations/SKILL.md). Keep in sync.
$script:TextFallbackMarker = '<!-- parent-link-mode: text-fallback -->'
# Matches a leading "Parent: #N" claim line only when it is literally the
# first line of the body (line-boundary lookahead), so a coincidental
# "Parent: #N" mention elsewhere in the body is never touched.
$script:LeadingClaimPattern = '^Parent: #\d+(?=\r?\n|$)\r?\n?(\r?\n)?'
$script:TrailingMarkerPattern = '(\r?\n)?' + [regex]::Escape($script:TextFallbackMarker) + '\s*$'

function Remove-StaleParentClaim {
    <#
    .SYNOPSIS
        Marker hygiene: idempotently strip a leading "Parent: #N" claim line
        and a trailing text-fallback marker left by a prior failed run.
        Safe to call on a body with no stale claim/marker (no-op).

    .DESCRIPTION
        Gated on the text-fallback marker's presence (M2 fix): the leading
        claim line is only ever stripped together with the marker, never on
        its own. This preserves a permanent "Parent: #N" first line written
        by Add-FollowUpIssue.ps1 on a successful attach (which never carries
        the text-fallback marker) and, as a side effect, avoids a
        functionless TrimEnd()-only body diff when there is nothing stale to
        remove (M5 fix): when the marker is absent this function returns the
        body unchanged instead of reaching the TrimEnd() call.
    #>
    param([string]$Body)

    if ([string]::IsNullOrEmpty($Body)) { return $Body }
    if ($Body -notmatch [regex]::Escape($script:TextFallbackMarker)) { return $Body }

    $result = $Body -replace $script:LeadingClaimPattern, ''
    $result = $result -replace $script:TrailingMarkerPattern, ''
    return $result.TrimEnd()
}

function Add-ParentClaimFallback {
    <#
    .SYNOPSIS
        Idempotently splice a "Parent: #N" claim line + the text-fallback
        marker into a body. Always strips any pre-existing claim/marker
        first, so a repeated failed run replaces rather than duplicates it.
    #>
    param(
        [string]$Body,
        [int]$ParentIssueNumber
    )

    $cleanBody = Remove-StaleParentClaim -Body $Body
    $claimLine = "Parent: #$ParentIssueNumber"

    $newBody = if ([string]::IsNullOrEmpty($cleanBody)) {
        $claimLine
    } else {
        "$claimLine`n`n$cleanBody"
    }

    return "$newBody`n$script:TextFallbackMarker"
}

# --- 1. Self-reference guard (PF17) — reject before any GitHub call. ----
if ($ParentIssueNumber -eq $ChildIssueNumber) {
    Write-Error "Cannot attach issue #$ChildIssueNumber to itself (ParentIssueNumber and ChildIssueNumber are the same)."
    exit 1
}

# --- 1b. Resolve the ambient gh repo once (M1) -------------------------
# `gh issue view` (used for the parent read) and every `gh issue edit`
# call already resolve against `gh`'s ambient cwd-repo. Resolving the same
# repo here, once, and reusing it in the pre-check GraphQL query keeps the
# read and write paths pinned to the same repo instead of a hardcoded
# owner/name literal that can silently drift in a fork or renamed repo.
$repoNwo = $null
$stderrText = ''
try {
    $repoViewMerged = gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>&1
    $repoNwo = (($repoViewMerged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String)).Trim()
    $stderrText = (($repoViewMerged | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { $_.ToString() }) -join "`n").Trim()
} catch {
    $repoNwo = $null
}
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoNwo)) {
    $suffix = if ($stderrText) { " stderr: $stderrText" } else { '' }
    Write-Error "Could not resolve the current repository via 'gh repo view' (owner/name).$suffix"
    exit 1
}
$repoParts = $repoNwo.Trim() -split '/', 2
$repoOwner = $repoParts[0]
$repoName = $repoParts[1]

# --- 2 & 3. Verify the child exists and pre-check its current parent. ---
# Combined into one GraphQL query: `gh issue view --json` has no `parent`
# field (PF3), so the parent read must go through `gh api graphql`
# regardless; folding the existence check (id) and body fetch into the
# same round trip avoids three separate `gh` calls.
$childQuery = @"
query {
  repository(owner: "$repoOwner", name: "$repoName") {
    issue(number: $ChildIssueNumber) {
      id
      body
      parent { number }
    }
  }
}
"@

$childId = $null
$childBody = $null
$currentParentNumber = $null
$precheckSuccess = $false
$precheckAttempts = 0
$childPrecheckStderr = ''
# M7: mirror the addSubIssue mutation's 2-attempt retry loop below instead
# of a single unretried try/catch.
while (-not $precheckSuccess -and $precheckAttempts -lt 2) {
    $precheckAttempts++
    try {
        # M4: carry the same GraphQL-Features header as the mutation, since
        # this query also reads the feature-gated `parent { number }` field.
        $childPrecheckMerged = gh api graphql -H "GraphQL-Features: sub_issues" -f "query=$childQuery" 2>&1
        $childRawJson = (($childPrecheckMerged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String)).Trim()
        $childPrecheckStderr = (($childPrecheckMerged | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { $_.ToString() }) -join "`n").Trim()
        if ($LASTEXITCODE -eq 0 -and $childRawJson) {
            $childResponse = $childRawJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            # M4: check for GraphQL-level errors returned with exit code 0,
            # mirroring the mutation's existing error-check pattern. Treat
            # this the same as an unresolved child (retry, then fail loud).
            if ($childResponse -and $childResponse.errors) {
                Write-Warning "GraphQL child pre-check returned errors: $($childResponse.errors | ConvertTo-Json -Compress)"
            } else {
                $childIssueData = $childResponse.data.repository.issue
                if ($childIssueData) {
                    $childId = $childIssueData.id
                    $childBody = $childIssueData.body
                    if ($childIssueData.parent) {
                        $currentParentNumber = $childIssueData.parent.number
                    }
                    $precheckSuccess = $true
                }
            }
        }
    } catch {
        # Try again
    }
}

# PF9: verify the child issue resolves to a real issue before writing
# anything to its body.
if (-not $childId) {
    $suffix = if ($childPrecheckStderr) { " stderr: $childPrecheckStderr" } else { '' }
    Write-Error "Child issue #$ChildIssueNumber could not be resolved (missing or inaccessible).$suffix"
    exit 1
}

if ($null -ne $currentParentNumber) {
    if ($currentParentNumber -eq $ParentIssueNumber) {
        # Already attached to the requested parent — idempotent success.
        # Marker hygiene: strip any stale claim/marker a prior failed run left.
        $strippedBody = Remove-StaleParentClaim -Body $childBody
        if ($strippedBody -ne $childBody) {
            $editOutput = gh issue edit $ChildIssueNumber --body $strippedBody 2>&1
            if ($LASTEXITCODE -ne 0) {
                $stderrText = (($editOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Out-String)).Trim()
                $suffix = if ($stderrText) { " stderr: $stderrText" } else { '' }
                Write-Warning "Failed to strip stale parent-link-mode marker from issue #$ChildIssueNumber body.$suffix"
            }
        }
        exit 0
    } else {
        # Attached to a DIFFERENT parent — fail loud rather than silently
        # succeed (PF2). Resolving the mismatch is out of scope for this
        # script (deferred to a future issue).
        Write-Error "Child issue #$ChildIssueNumber is already attached to a different parent (#$currentParentNumber), not the requested parent (#$ParentIssueNumber)."
        exit 1
    }
}

# --- 4. Attempt the attach. ---------------------------------------------
# Ported from Add-FollowUpIssue.ps1:158-208 (GraphQL Node-ID resolution +
# addSubIssue mutation + 2-attempt retry). Divergence: on failure this
# script exits non-zero instead of only Write-Warning-ing.
$parentId = $null
$parentViewStderr = ''
try {
    $parentViewMerged = gh issue view $ParentIssueNumber --json id --jq .id 2>&1
    $parentId = (($parentViewMerged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String)).Trim()
    $parentViewStderr = (($parentViewMerged | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { $_.ToString() }) -join "`n").Trim()
} catch {
    $parentId = $null
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
    $mutationStderr = ''
    while (-not $graphqlSuccess -and $attempts -lt 2) {
        $attempts++
        try {
            $mutationMerged = gh api graphql -H "GraphQL-Features: sub_issues" -f "query=$mutation" 2>&1
            $result = (($mutationMerged | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String)).Trim()
            $mutationStderr = (($mutationMerged | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                ForEach-Object { $_.ToString() }) -join "`n").Trim()
            if ($LASTEXITCODE -eq 0 -and $result) {
                # Check for GraphQL-level errors returned with exit code 0.
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
        $suffix = if ($mutationStderr) { " stderr: $mutationStderr" } else { '' }
        Write-Warning "Failed to link issue #$ChildIssueNumber to parent issue #$ParentIssueNumber via GitHub GraphQL sub-issues after 2 attempts.$suffix"
    }
} else {
    $suffix = if ($parentViewStderr) { " stderr: $parentViewStderr" } else { '' }
    Write-Error "addSubIssue prerequisite failed: childId=$childId parentId=$parentId" -ErrorAction Continue
    Write-Warning "Could not retrieve GraphQL Node IDs for parent #$ParentIssueNumber or child #$ChildIssueNumber.$suffix"
}

# --- 5 / 6. Success: strip stale marker. Failure: splice fallback claim. -
if ($graphqlSuccess) {
    $strippedBody = Remove-StaleParentClaim -Body $childBody
    if ($strippedBody -ne $childBody) {
        $editOutput = gh issue edit $ChildIssueNumber --body $strippedBody 2>&1
        if ($LASTEXITCODE -ne 0) {
            $stderrText = (($editOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Out-String)).Trim()
            $suffix = if ($stderrText) { " stderr: $stderrText" } else { '' }
            Write-Warning "Failed to strip stale parent-link-mode marker from issue #$ChildIssueNumber body.$suffix"
        }
    }
    exit 0
} else {
    Write-Error "Failed to attach issue #$ChildIssueNumber to parent issue #$ParentIssueNumber."
    $fallbackBody = Add-ParentClaimFallback -Body $childBody -ParentIssueNumber $ParentIssueNumber
    $editOutput = gh issue edit $ChildIssueNumber --body $fallbackBody 2>&1
    if ($LASTEXITCODE -ne 0) {
        $stderrText = (($editOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Out-String)).Trim()
        $suffix = if ($stderrText) { " stderr: $stderrText" } else { '' }
        Write-Warning "Failed to write parent-link-mode text-fallback claim to issue #$ChildIssueNumber body.$suffix"
    }
    exit 1
}
