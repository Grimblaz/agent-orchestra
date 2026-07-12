#Requires -Version 7.0

<#
.SYNOPSIS
    Core helper library for the Filing Approval Gate durable-record spine (issue #837, plan step 1 / slice s1).

.DESCRIPTION
    Three building blocks used by the gate methodology (safe-operations SKILL.md §2e):

      1. Get-FollowupRecordKey
         Collision-safe, lowercase, fixed-length `followup-`-prefixed key derivation
         from a raw identity string (the stable_finding_key of a finding, or the
         canonical title of a non-adjudicated proposal).

      2. New-ProposedFollowupsComment / Read-ProposedFollowupsComment /
         Set-ProposedFollowupsCommentState / Write-ProposedFollowupsComment
         Build, parse, and transition the `<!-- proposed-followups-{ID} -->`
         headless-queue comment payload. The actual GitHub write/edit reuses
         the Find-OrUpsertComment function from find-or-upsert-comment.ps1
         rather than a new gh call path.

      3. Merge-FollowupRecords (plus its Get-FollowupPriorMarkerBodies and
         Get-FollowupKeysFromRawText helpers)
         Reads prior `followup-`-prefixed engagement-record entries via
         Read-EngagementRecords (frame-engagement-record-core.ps1), through an
         uncapped `gh api ... --paginate` read (never the 100-comment-capped
         `gh ... --json comments` fetch), unions them with the decisions of the
         current batch (current-batch wins on key conflict; among prior entries the
         most-recently-created marker wins), and enforces an unbroken-chain
         guard: the merged result must be a superset of every `followup-` key
         seen in the raw text of every prior marker read, or a loud
         Write-Warning fires.

.NOTES
    Dot-sources frame-engagement-record-core.ps1 and find-or-upsert-comment.ps1
    from this same directory (matches the established sibling dot-source
    convention, e.g. gate-reconciliation-core.ps1 / release-gate-core.ps1).
#>

. (Join-Path $PSScriptRoot 'frame-engagement-record-core.ps1')
. (Join-Path $PSScriptRoot 'find-or-upsert-comment.ps1')

# ---------------------------------------------------------------------------
# 1. Get-FollowupRecordKey
# ---------------------------------------------------------------------------

function Get-FollowupRecordKey {
    <#
    .SYNOPSIS
        Derives a collision-safe, lowercase, fixed-length `followup-` key from a raw identity string.

    .PARAMETER RawKey
        The raw identity to hash: the stable_finding_key of a finding for adjudicated
        findings, or the canonical title for non-adjudicated proposals. Must not
        be null, empty, or whitespace-after-trim.

    .OUTPUTS
        [string] `followup-` followed by the first 16 characters of the
        lowercase hex SHA256 digest of -RawKey. Always exactly 25 characters
        and always satisfies the engagement-record slug regex
        `^[a-z][a-z0-9-]{0,62}[a-z0-9]\z` (Test-EngagementRecordSlug).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RawKey
    )

    if ([string]::IsNullOrWhiteSpace($RawKey)) {
        throw [System.ArgumentException]::new(
            'Get-FollowupRecordKey: -RawKey must not be null, empty, or whitespace-after-trim.',
            'RawKey'
        )
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($RawKey)
        $hashBytes = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }

    # [System.BitConverter]::ToString() renders uppercase hex ("A1-B2-...");
    # the case-sensitive engagement-record slug regex (Test-EngagementRecordSlug,
    # frame-engagement-record-core.ps1:53/379) requires lowercase, so we
    # explicitly lowercase-invariant rather than relying on default rendering.
    $hex = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    $shortHex = $hex.Substring(0, 16)

    return "followup-$shortHex"
}

# ---------------------------------------------------------------------------
# 2. Proposed-followups queue comment: build / parse / transition / write
# ---------------------------------------------------------------------------

# Marker + state contract (three literal state values only).
$script:ProposedFollowupsMarkerPattern = '(?m)^\s*<!--\s*proposed-followups-(\d+)\s*-->'
$script:ProposedFollowupsStatePattern = '(?m)^(\s*state:\s*)(proposed|claimed|consumed)(\s*)$'
$script:ProposedFollowupsStateOrder = @{ proposed = 0; claimed = 1; consumed = 2 }

function ConvertTo-FollowupYamlString {
    <#
    .SYNOPSIS
        Double-quotes and escapes a scalar for embedding in the proposed-followups YAML payload.

    .DESCRIPTION
        Replicates the exact escaping ConvertTo-CanonicalFollowupTitle /
        Add-FollowUpIssue.ps1:117-128 already uses for the ac_cross_check YAML
        block: backslash -> \\, doublequote -> \". Canonical titles contain a
        leading `[` (YAML flow-sequence indicator) and an embedded `: `
        (YAML mapping indicator), so every free-text field is always
        double-quoted rather than left as a bare scalar.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        $Value
    )
    $strValue = if ($null -eq $Value) { '' } else { [string]$Value }
    $escaped = $strValue.Replace('\', '\\').Replace('"', '\"')
    # R11: escape embedded newlines (CRLF, LF, and bare CR) as the YAML
    # double-quoted \n escape sequence so free-text fields with embedded
    # newlines round-trip exactly instead of triggering YAML block-folding
    # or losing fidelity. Must run after the backslash/quote escaping above
    # so the backslashes this introduces are not themselves re-escaped.
    $escaped = $escaped.Replace("`r`n", '\n').Replace("`n", '\n').Replace("`r", '\n')
    return "`"$escaped`""
}

function New-ProposedFollowupsComment {
    <#
    .SYNOPSIS
        Builds the `<!-- proposed-followups-{ID} -->` headless-queue comment body.

    .PARAMETER Id
        The PR or issue number the queue comment lives on.

    .PARAMETER Proposals
        Array of proposal objects (hashtable or PSCustomObject), each with
        canonical_title, rationale, disposition, severity, board_position,
        followup_key, originating_head_sha, ruling_link, and optional
        target_repo (omitted from output when absent/blank).

    .PARAMETER State
        One of 'proposed' | 'claimed' | 'consumed'. Defaults to 'proposed'.

    .OUTPUTS
        [string] the full comment body text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Id,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Proposals = @(),

        [Parameter(Mandatory = $false)]
        [ValidateSet('proposed', 'claimed', 'consumed')]
        [string]$State = 'proposed'
    )

    if ($null -eq $Proposals) { $Proposals = @() }

    $lines = @()
    $lines += "<!-- proposed-followups-$Id -->"
    $lines += ''
    $lines += "state: $State"
    $lines += ''
    $lines += '```yaml'
    $lines += 'schema_version: 1'
    if ($Proposals.Count -eq 0) {
        $lines += 'proposals: []'
    } else {
        $lines += 'proposals:'
        foreach ($p in $Proposals) {
            $lines += "  - canonical_title: $(ConvertTo-FollowupYamlString $p.canonical_title)"
            $lines += "    rationale: $(ConvertTo-FollowupYamlString $p.rationale)"
            $lines += "    disposition: $(ConvertTo-FollowupYamlString $p.disposition)"
            $lines += "    severity: $(ConvertTo-FollowupYamlString $p.severity)"
            $lines += "    board_position: $(ConvertTo-FollowupYamlString $p.board_position)"
            $lines += "    followup_key: $(ConvertTo-FollowupYamlString $p.followup_key)"
            $lines += "    originating_head_sha: $(ConvertTo-FollowupYamlString $p.originating_head_sha)"
            $lines += "    ruling_link: $(ConvertTo-FollowupYamlString $p.ruling_link)"
            if ($null -ne $p.target_repo -and -not [string]::IsNullOrWhiteSpace([string]$p.target_repo)) {
                $lines += "    target_repo: $(ConvertTo-FollowupYamlString $p.target_repo)"
            }
        }
    }
    $lines += '```'

    return ($lines -join "`n")
}

function Read-ProposedFollowupsComment {
    <#
    .SYNOPSIS
        Parses a `<!-- proposed-followups-{ID} -->` comment body back into structured data.

    .PARAMETER CommentBody
        The raw comment body text (as produced by New-ProposedFollowupsComment,
        or fetched live from GitHub by the caller).

    .OUTPUTS
        [PSCustomObject] with Id, State, SchemaVersion, and Proposals (array of
        PSCustomObject, field-for-field matching the input shape).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CommentBody
    )

    if ([string]::IsNullOrWhiteSpace($CommentBody)) {
        throw [System.ArgumentException]::new(
            'Read-ProposedFollowupsComment: -CommentBody must not be null, empty, or whitespace.',
            'CommentBody'
        )
    }

    if ($CommentBody -notmatch $script:ProposedFollowupsMarkerPattern) {
        throw [System.ArgumentException]::new(
            "Read-ProposedFollowupsComment: no '<!-- proposed-followups-{ID} -->' marker found in the supplied comment body.",
            'CommentBody'
        )
    }
    $id = [int]$Matches[1]

    if ($CommentBody -notmatch $script:ProposedFollowupsStatePattern) {
        throw [System.InvalidOperationException]::new(
            "Read-ProposedFollowupsComment: no valid 'state:' line found (must be one of proposed|claimed|consumed)."
        )
    }
    $state = $Matches[2]

    # R4: the closing fence must be anchored to a line that is EXACTLY ``` (optional
    # trailing whitespace) at the start of a line -- not just the next ``` occurrence
    # anywhere in the body. Free-text fields (rationale/title) can legitimately contain
    # a literal "```" substring mid-line; an unanchored non-greedy match would stop at
    # that embedded sequence and silently truncate the YAML block. This is fence-aware
    # extraction rather than mutating user content in ConvertTo-FollowupYamlString.
    # F3 (post-fix): .NET multiline `$` anchors before `\n` only, so a CRLF body
    # whose closing fence is followed by a trailing `\r` (not yet consumed) would
    # fail to match. Tolerate an optional trailing `\r` at the closing anchor.
    if ($CommentBody -notmatch '(?ms)^```yaml[ \t]*\r?\n(.*?)\r?\n^```[ \t]*\r?$') {
        throw [System.InvalidOperationException]::new(
            'Read-ProposedFollowupsComment: no fenced yaml block found in the supplied comment body.'
        )
    }
    $yamlContent = $Matches[1].Trim()

    try {
        Import-Module powershell-yaml -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("powershell-yaml module is required but could not be loaded: $_")
    }

    try {
        $parsed = ConvertFrom-Yaml -Yaml $yamlContent
    } catch {
        throw [System.InvalidOperationException]::new("Read-ProposedFollowupsComment: failed to parse YAML payload: $($_.Exception.Message)")
    }

    $proposals = @()
    if ($null -ne $parsed -and $null -ne $parsed.proposals) {
        foreach ($p in @($parsed.proposals)) {
            $proposals += [PSCustomObject]@{
                canonical_title      = $p.canonical_title
                rationale            = $p.rationale
                disposition          = $p.disposition
                severity             = $p.severity
                board_position       = $p.board_position
                followup_key         = $p.followup_key
                originating_head_sha = $p.originating_head_sha
                ruling_link          = $p.ruling_link
                target_repo          = $p.target_repo
            }
        }
    }

    return [PSCustomObject]@{
        Id            = $id
        State         = $state
        SchemaVersion = if ($parsed) { $parsed.schema_version } else { $null }
        Proposals     = $proposals
    }
}

function Set-ProposedFollowupsCommentState {
    <#
    .SYNOPSIS
        Transitions the `state:` head line of the comment body among proposed -> claimed -> consumed.

    .PARAMETER CommentBody
        The current comment body text.

    .PARAMETER NewState
        One of 'proposed' | 'claimed' | 'consumed'. Must be strictly forward of
        the current state (no same-state or backward transitions).

    .OUTPUTS
        [string] the comment body text with the state line updated.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommentBody,

        [Parameter(Mandatory = $true)]
        [ValidateSet('proposed', 'claimed', 'consumed')]
        [string]$NewState
    )

    if ($CommentBody -notmatch $script:ProposedFollowupsStatePattern) {
        throw [System.InvalidOperationException]::new(
            "Set-ProposedFollowupsCommentState: no valid 'state:' line found in the supplied comment body."
        )
    }
    $currentState = $Matches[2]

    $currentIndex = $script:ProposedFollowupsStateOrder[$currentState]
    $newIndex = $script:ProposedFollowupsStateOrder[$NewState]
    if ($newIndex -ne $currentIndex + 1) {
        throw [System.ArgumentException]::new(
            "Set-ProposedFollowupsCommentState: invalid transition '$currentState' -> '$NewState'; only a single forward step (proposed -> claimed or claimed -> consumed) is permitted -- state skips (e.g. proposed -> consumed) bypass the claimed ownership step and are rejected.",
            'NewState'
        )
    }

    return ($CommentBody -replace $script:ProposedFollowupsStatePattern, "`${1}$NewState`${3}")
}

function Write-ProposedFollowupsComment {
    <#
    .SYNOPSIS
        Posts or updates the proposed-followups queue comment via the existing
        find-or-upsert-comment.ps1 primitive (does not open a new gh call path).

    .PARAMETER Type
        'pr' or 'issue'.

    .PARAMETER Id
        The PR or issue number.

    .PARAMETER Body
        The comment body (as produced by New-ProposedFollowupsComment or
        Set-ProposedFollowupsCommentState).

    .OUTPUTS
        [string] the html_url of the upserted comment, or $null on gh failure
        (the fail-open contract of Find-OrUpsertComment).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('pr', 'issue')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [int]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    $marker = "<!-- proposed-followups-$Id -->"
    return Find-OrUpsertComment -Type $Type -Number $Id -Marker $marker -Body $Body
}

# ---------------------------------------------------------------------------
# 3. Merge-FollowupRecords
# ---------------------------------------------------------------------------

function Get-FollowupKeysFromRawText {
    <#
    .SYNOPSIS
        Independently scans raw marker text for `followup-` decision_id keys.

    .DESCRIPTION
        Defense-in-depth truth source for the unbroken-chain guard: a plain
        regex scan survives even when structured YAML parsing fails for a
        given marker (e.g. an unknown schema_version throw), so the guard can
        still detect a key that would otherwise be silently dropped.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $pattern = 'decision_id:\s*[\x22\x27]?(followup-[0-9a-f]{16})[\x22\x27]?'
    $found = [regex]::Matches($Text, $pattern)
    return @($found | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}

function Get-FollowupPriorMarkerBodies {
    <#
    .SYNOPSIS
        Fetches ALL comments for an issue or PR via an uncapped `gh api ... --paginate` read.

    .DESCRIPTION
        `gh issue view --json comments` / `gh pr view --json comments` (used by
        Read-EngagementRecords' own gh path) cap at 100 comments. The REST
        issues/comments endpoint — shared by issues and PRs, since PRs are
        issues under the hood, the same unification find-or-upsert-comment.ps1
        relies on for `gh issue view` — supports `--paginate`, which `gh api`
        auto-concatenates across pages into one JSON array. This is the
        uncapped read path so a busy PR/issue cannot shadow older markers.

    .OUTPUTS
        [PSCustomObject[]] each with Body, CreatedAt, and Id (the GitHub
        comment id, used by Merge-FollowupRecords as the R17 deterministic
        CreatedAt tie-break), in ascending (oldest-first) creation order.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('issue', 'pr')]
        [string]$Type = 'issue',

        [Parameter(Mandatory = $true)]
        [int]$Number,

        [Parameter(Mandatory = $false)]
        [string]$Repo,

        [Parameter(Mandatory = $false)]
        [string]$GhCliPath = 'gh'
    )

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        try {
            $remoteUrl = & git config --get remote.origin.url 2>$null
            if ($remoteUrl -and $remoteUrl -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?\s*$') {
                $Repo = "$($Matches[1])/$($Matches[2])"
            }
        } catch {
            $Repo = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($Repo)) {
        Write-Warning 'Get-FollowupPriorMarkerBodies: could not resolve owner/repo from git remote; returning no prior markers.'
        return @()
    }

    $apiPath = "repos/$Repo/issues/$Number/comments"
    try {
        $rawJson = & $GhCliPath api $apiPath --paginate 2>$null
    } catch {
        Write-Warning "Get-FollowupPriorMarkerBodies: gh api $apiPath --paginate threw an exception: $($_.Exception.Message)"
        return @()
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Get-FollowupPriorMarkerBodies: gh api $apiPath --paginate failed (exit $LASTEXITCODE)."
        return @()
    }
    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        return @()
    }

    try {
        $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Get-FollowupPriorMarkerBodies: failed to parse gh api response: $($_.Exception.Message)"
        return @()
    }

    return @(@($parsed) | ForEach-Object {
        $createdAtRaw = $_.created_at
        $createdAt = [DateTime]::MinValue
        if ($createdAtRaw) {
            try {
                $createdAt = [DateTime]::Parse($createdAtRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            } catch {
                $createdAt = [DateTime]::MinValue
            }
        }
        [PSCustomObject]@{
            Body      = $_.body
            CreatedAt = $createdAt
            Id        = $_.id
        }
    })
}

function Merge-FollowupRecords {
    <#
    .SYNOPSIS
        Unions prior `followup-`-prefixed engagement-record entries with the decisions of the current batch.

    .DESCRIPTION
        Reads prior entries via Read-EngagementRecords (frame-engagement-record-core.ps1),
        sourced from an uncapped read (Get-FollowupPriorMarkerBodies, or the
        -PriorMarkerBodies test/offline seam) rather than the capped
        `gh ... --json comments` fetch. Each prior marker is parsed
        individually (not as a single latest-wins-per-phase batch) so its own
        CreatedAt can be used for cross-marker tie-breaking, since followup-
        entries may ride design/plan/review markers whose phases differ.

        Precedence: the decision of the current batch wins over any decision from a prior
        marker for the same key; among prior entries, the most-recently-
        created marker wins.

        Unbroken-chain guard: the merged result must be a superset of every
        `followup-` key found (via an independent raw-text regex scan, so it
        survives structured-parse failures too) in any prior marker read. Any
        key that would be dropped triggers a loud Write-Warning rather than a
        silent drop.

    .PARAMETER CurrentBatch
        Array of hashtable/PSCustomObject decisions for the current gate
        batch. Each MUST expose a `decision_id` (or, failing that,
        `followup_key`) property carrying the `followup-` key.

    .PARAMETER Type
        'issue' or 'pr' — which comment thread prior markers live on.

    .PARAMETER Number
        The issue or PR number backing the live gh read, and (R9) the number
        every prior marker is re-validated against when -PriorMarkerBodies is
        supplied instead of performing the live read. Must be explicitly
        supplied (not left at its default 0) whenever -PriorMarkerBodies is
        used, or the function throws immediately rather than silently
        dropping every prior entry.

    .PARAMETER Repo
        Optional owner/repo. Auto-resolved from the git remote when omitted.

    .PARAMETER GhCliPath
        Optional path to the gh CLI. Defaults to 'gh'.

    .PARAMETER PriorMarkerBodies
        Test/offline seam: supply prior marker bodies directly (each a
        hashtable/PSCustomObject with Body + CreatedAt, and optionally Id for
        the R17 CreatedAt tie-break; Id defaults to 0 when omitted), bypassing
        the live gh fetch entirely. Requires an explicit -Number (R9).

    .OUTPUTS
        [object[]] the merged decision objects, sorted by key.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$CurrentBatch,

        [Parameter(Mandatory = $false)]
        [ValidateSet('issue', 'pr')]
        [string]$Type = 'issue',

        [Parameter(Mandatory = $false)]
        [int]$Number = 0,

        [Parameter(Mandatory = $false)]
        [string]$Repo,

        [Parameter(Mandatory = $false)]
        [string]$GhCliPath = 'gh',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$PriorMarkerBodies
    )

    if ($null -eq $CurrentBatch) { $CurrentBatch = @() }

    # R9/G5: -PriorMarkerBodies without a positive -Number silently degrades. Read-EngagementRecords
    # requires -IssueNumber/-PullRequestNumber > 0 and throws otherwise; that throw is caught below
    # (per-marker try/catch) and treated as "unparseable", which drops EVERY prior entry without a
    # clear error. Fail loud instead: require an explicit, positive -Number whenever -PriorMarkerBodies
    # is used -- this covers both the unbound-defaulting-to-0 case AND an explicit `-Number 0` (or any
    # non-positive value), since both would otherwise reach Read-EngagementRecords and silently drop
    # every prior entry behind only a Write-Warning.
    if ($null -ne $PriorMarkerBodies -and (-not $PSBoundParameters.ContainsKey('Number') -or $Number -le 0)) {
        throw [System.Management.Automation.PSArgumentException]::new(
            'Merge-FollowupRecords: -PriorMarkerBodies was supplied but -Number was left at its default (0) or ' +
            'set to a non-positive value. Read-EngagementRecords requires -IssueNumber/-PullRequestNumber > 0, ' +
            'so every prior marker would otherwise be silently rejected downstream and treated as unparseable, ' +
            'dropping ALL prior entries without a clear error. Supply an explicit, positive -Number (the issue ' +
            'or PR number the prior markers were read from) alongside -PriorMarkerBodies.',
            'Number'
        )
    }

    # Step 1: gather prior marker bodies via the uncapped read path.
    $markerBodies = @()
    if ($null -ne $PriorMarkerBodies) {
        $markerBodies = @($PriorMarkerBodies)
    } elseif ($Number -gt 0) {
        $markerBodies = @(Get-FollowupPriorMarkerBodies -Type $Type -Number $Number -Repo $Repo -GhCliPath $GhCliPath)
    }

    # Step 2: independent raw-text scan — the truth source for the unbroken-chain guard.
    $allPriorKeysSeen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($marker in $markerBodies) {
        foreach ($k in (Get-FollowupKeysFromRawText -Text $marker.Body)) {
            [void]$allPriorKeysSeen.Add($k)
        }
    }

    # Step 3: structured parse each marker individually via Read-EngagementRecords,
    # retaining its own CreatedAt for cross-marker/cross-phase tie-breaking.
    $priorEntriesByKey = @{}
    $priorEntriesCreatedAt = @{}
    $priorEntriesId = @{}

    foreach ($marker in $markerBodies) {
        $body = $marker.Body
        $createdAt = $marker.CreatedAt
        $markerId = if ($null -ne $marker.Id) { $marker.Id } else { 0 }
        if ([string]::IsNullOrWhiteSpace($body)) { continue }

        # R18: cheap pre-filter -- skip bodies that plainly are not engagement-record
        # markers at all (ordinary discussion comments) before paying for full
        # YAML/schema parsing via Read-EngagementRecords. Pure performance
        # optimization: the unbroken-chain guard's independent raw-text scan
        # (Step 2, above) still covers every body regardless of this filter.
        if (-not $body.Contains('engagement-record-')) { continue }

        # PR-path vs issue-path keying asymmetry is intentional, not a bug (R7):
        # the PR path forwards Phase='review' because followup- entries riding a
        # PR thread only ever arrive on engagement-record-review-{PR} markers (PR
        # threads only ever carry the review phase, by marker locality). The
        # issue path applies no phase filter because followup- entries riding an
        # issue thread can legitimately arrive on any of several issue-keyed
        # phases (experience/design/plan/orchestration), and a prior key must not
        # be lost just because it rode a different issue-keyed phase marker.
        $rerArgs = @{ InMemoryMarkers = @($body); AcceptLegacy = $true; WarningAction = 'SilentlyContinue' }
        if ($Type -eq 'pr') {
            $rerArgs['PullRequestNumber'] = $Number
            $rerArgs['Phase'] = 'review'
        } else {
            $rerArgs['IssueNumber'] = $Number
        }

        $decisions = $null
        try {
            $decisions = Read-EngagementRecords @rerArgs
        } catch {
            Write-Warning "Merge-FollowupRecords: skipping unparsable prior marker (createdAt=$createdAt): $($_.Exception.Message)"
            continue
        }

        foreach ($dec in @($decisions)) {
            $key = $dec.decision_id
            if ([string]::IsNullOrWhiteSpace($key) -or $key -notlike 'followup-*') { continue }

            $existingCreatedAt = $priorEntriesCreatedAt[$key]
            $shouldReplace = $false
            if ($null -eq $existingCreatedAt) {
                $shouldReplace = $true
            } elseif ($createdAt -gt $existingCreatedAt) {
                $shouldReplace = $true
            } elseif ($createdAt -eq $existingCreatedAt) {
                # R17: deterministic secondary tie-break. When CreatedAt is equal
                # (including the shared [DateTime]::MinValue two markers can both
                # receive after a created_at parse failure), prefer the marker
                # with the higher comment Id as a stable secondary key -- GitHub
                # comment IDs are monotonically increasing, so a higher Id
                # reliably reflects a later comment even when timestamp
                # resolution collides.
                $existingId = $priorEntriesId[$key]
                if ($null -eq $existingId -or $markerId -gt $existingId) {
                    $shouldReplace = $true
                }
            }

            if ($shouldReplace) {
                $priorEntriesByKey[$key] = $dec
                $priorEntriesCreatedAt[$key] = $createdAt
                $priorEntriesId[$key] = $markerId
            }
        }
    }

    # Step 4: union — current-batch decision wins over any prior entry for the same key.
    $merged = @{}
    foreach ($key in $priorEntriesByKey.Keys) {
        $merged[$key] = $priorEntriesByKey[$key]
    }
    foreach ($item in $CurrentBatch) {
        $key = if ($item.decision_id) { $item.decision_id } elseif ($item.followup_key) { $item.followup_key } else { $null }
        if ([string]::IsNullOrWhiteSpace($key)) {
            Write-Warning 'Merge-FollowupRecords: skipping current-batch item with no decision_id/followup_key.'
            continue
        }
        $merged[$key] = $item
    }

    # Step 5: unbroken-chain guard.
    $missingKeys = @($allPriorKeysSeen | Where-Object { -not $merged.ContainsKey($_) })
    if ($missingKeys.Count -gt 0) {
        Write-Warning "Merge-FollowupRecords: unbroken-chain guard tripped -- the following prior followup- keys were dropped from the merged result: $($missingKeys -join ', ')"
    }

    return @($merged.Keys | Sort-Object | ForEach-Object { $merged[$_] })
}
