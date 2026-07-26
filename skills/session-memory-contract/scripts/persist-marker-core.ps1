#Requires -Version 7.0

<#
.SYNOPSIS
    Family-registry-driven marker-write core (issue #893, plan slice s3).
    Exports Get-MarkerFamilyRegistry, ConvertTo-MarkerNormalizedText, and
    Invoke-PersistMarkerWrite.

.DESCRIPTION
    This file composes the s2 transport primitives
    (.github/scripts/lib/marker-transport-core.ps1: Find-AllCommentsByExactMarker,
    New-MarkerComment, Get-CommentIdFromUrl, Get-CommentBodyById,
    Set-CommentBodyDirect) into the two write shapes the design phase
    settled on (893-D2): post-new and upsert. Callers are responsible for
    dot-sourcing marker-transport-core.ps1 before this file, exactly as
    that file's own header documents for its callers.

    Scope (s3 Requirement Contract, ac-refs AC1/AC3/AC11) -- explicit
    non-goals carried forward from the plan: no validator wiring (s4 --
    ValidatorAdapter is a registry field name only, never invoked here) and
    no post-steps/preserve-logic (s5 -- PostStep is a registry field name
    only, never invoked here). The family registry below is a v1 scaffold
    sized to exercise both write shapes and both target surfaces; full
    9-family population is s1's inventory feeding s4/s6, not this slice.

    Write shapes:
      post-new -- enumerates all marker matches via
        Find-AllCommentsByExactMarker and compares the composed candidate
        against the LATEST (highest REST id) match only. A candidate that
        matches a SUPERSEDED (non-latest) match still posts -- this is
        deliberate: post-new preserves latest-comment-wins write intent
        (design finding F5).
      upsert -- selects the CANONICAL match (earliest / lowest REST id,
        never --edit-last) for comparison, and re-finds that canonical
        target immediately before PATCH rather than reusing the id from the
        earlier find (893-D2 concurrency posture: single-writer assumption,
        pre-PATCH re-find, residual race between re-find and PATCH is an
        accepted risk -- there is no shipped primitive to make the
        find-then-PATCH pair atomic against the REST API).

    Normalization: ConvertTo-MarkerNormalizedText is the ONE shared
    normalization function (LF line endings, per-line trailing-whitespace
    strip, outer trim -- nothing else), used identically by both the
    write-shape idempotency comparison and the post-write read-back
    comparison (Test-MarkerReadBack), so the two checks can never silently
    drift apart on what counts as "unchanged".

    Read-back: Test-MarkerReadBack's PRIMARY gate is normalized equality,
    not the inherited >=50%-length truncation guard alone -- that guard
    cannot prove byte-faithfulness because mojibake corruption LENGTHENS
    text rather than shortening it (design challenge finding, resolves the
    893-D2-vs-893-D11 contradiction in favor of the strict reading, plan
    step 6). The truncation guard is retained as a SECONDARY check, used
    only to produce a more specific failure message when the mismatch is
    also a gross truncation -- either branch is already a hard failure once
    normalized equality has failed. Test-MarkerReadBack throws (loud, never
    silently swallowed) on any failure -- an unreadable comment or a
    normalized mismatch -- and the two write-shape functions below catch
    that and convert it into their own Success=$false result, so a bad
    read-back is always reported as a failed write, never as success.

    Surface preflight: before any write, Invoke-PersistMarkerWrite compares
    the caller's declared -TargetSurface against the registry row's
    declared TargetSurface. This is necessarily a declared-vs-declared
    comparison, not a live lookup -- the unified GitHub comments REST
    endpoint (repos/{Owner}/{Repo}/issues/{Number}/comments) accepts either
    an issue or a pull-request number silently, so there is no live way to
    ask the endpoint itself which surface a number belongs to. A
    wrong-surface write would otherwise report success while the intended
    reader looks at the other surface entirely.

.NOTES
    Non-goals (explicit, per this slice's requirement contract): no
    validator adapter implementation or stubbing (s4); no post-step /
    write-back-preserve logic (s5).
#>

# ---------------------------------------------------------------------------
# Family registry.
# ---------------------------------------------------------------------------

function Get-MarkerFamilyRegistry {
    <#
    .SYNOPSIS
        Returns the declarative marker-family registry: one row per durable
        marker family, driving which surface a family's target number must
        be and which of the two write shapes it uses.
    .DESCRIPTION
        ValidatorAdapter and PostStep are carried as reserved field names
        (currently $null for every row) so s4 (validator wiring) and s5
        (post-steps / write-back-preserve) have a stable place to assign
        concrete adapter/post-step names -- this file never reads or
        invokes either field. Populating them with guessed names now would
        risk contradicting whatever s4/s5's own requirement contracts
        settle on; the field's presence, not its value, is this slice's
        scope.

        Rows are grounded in already-documented marker families (this
        repo's own CLAUDE.md and skills/session-memory-contract/references/handoff-markers.md)
        rather than invented: plan-issue and design-phase-complete are
        upsert (both are found-or-created once, then repeatedly patched, as
        persist-phase-ledger-core.ps1's own plan/design modes already do
        today); experience-owner-complete and review-judge-produced are
        post-new (freshly posted completion/sentinel comments -- CLAUDE.md
        documents review-judge-produced as "written as a separate PR
        comment").
    .OUTPUTS
        [PSCustomObject[]] one row per family: Family [string], MarkerTemplate
        [string] ('{ID}' placeholder for the numeric issue/PR id -- schema
        only in this slice, not programmatically substituted here),
        TargetSurface ['issue'|'pull-request'], WriteShape
        ['post-new'|'upsert'], ValidatorAdapter [string, always $null in
        this slice], PostStep [string, always $null in this slice].
    #>
    return @(
        [PSCustomObject]@{
            Family            = 'plan-issue'
            MarkerTemplate    = '<!-- plan-issue-{ID} -->'
            TargetSurface     = 'issue'
            WriteShape        = 'upsert'
            ValidatorAdapter  = $null
            PostStep          = $null
        }
        [PSCustomObject]@{
            Family            = 'design-phase-complete'
            MarkerTemplate    = '<!-- design-phase-complete-{ID} -->'
            TargetSurface     = 'issue'
            WriteShape        = 'upsert'
            ValidatorAdapter  = $null
            PostStep          = $null
        }
        [PSCustomObject]@{
            Family            = 'experience-owner-complete'
            MarkerTemplate    = '<!-- experience-owner-complete-{ID} -->'
            TargetSurface     = 'issue'
            WriteShape        = 'post-new'
            ValidatorAdapter  = $null
            PostStep          = $null
        }
        [PSCustomObject]@{
            Family            = 'review-judge-produced'
            MarkerTemplate    = '<!-- review-judge-produced-{PR} -->'
            TargetSurface     = 'pull-request'
            WriteShape        = 'post-new'
            ValidatorAdapter  = $null
            PostStep          = $null
        }
    )
}

# ---------------------------------------------------------------------------
# Shared normalization + read-back.
# ---------------------------------------------------------------------------

function ConvertTo-MarkerNormalizedText {
    <#
    .SYNOPSIS
        The ONE shared normalization function (893 design finding F3): LF
        line endings, per-line trailing-whitespace strip, outer trim --
        nothing else. Used identically by both the write-shape idempotency
        comparison and Test-MarkerReadBack's post-write comparison, so the
        two checks can never silently drift apart on what counts as
        "unchanged".
    .OUTPUTS
        [string]
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lf = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $strippedLines = ($lf -split "`n") | ForEach-Object { $_ -replace '[ \t]+$', '' }
    return ($strippedLines -join "`n").Trim()
}

function script:Test-MarkerReadBack {
    <#
    .SYNOPSIS
        Post-write verification shared by both write shapes: GETs the
        comment's current body and compares it against the body just
        written using normalized equality (ConvertTo-MarkerNormalizedText)
        as the PRIMARY gate -- not the inherited >=50%-length truncation
        guard alone, which cannot prove byte-faithfulness because mojibake
        corruption LENGTHENS text rather than shortening it.
    .DESCRIPTION
        Throws (loud, never silently swallowed) on any failure: the GET
        itself failing (cannot verify at all), or the normalized bodies not
        matching (corruption or an unfaithful write detected). Callers
        (Invoke-MarkerPostNewWrite / Invoke-MarkerUpsertWrite) catch this
        and convert it into their own Success=$false result, so the write
        is always reported failed on a bad read-back, never reported
        success.

        The truncation guard below is retained as a SECONDARY check, used
        only to produce a more specific failure message when the mismatch
        is also a gross truncation -- either branch is already a hard
        failure; normalized equality has already failed by the time either
        runs.
    .OUTPUTS
        $true on success. Throws on any failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedBody
    )
    $actualBody = Get-CommentBodyById -Owner $Owner -Repo $Repo -CommentId $CommentId
    if ($null -eq $actualBody) {
        throw "persist-marker-core: read-back GET failed for comment $CommentId -- cannot verify the write"
    }

    $normalizedActual = ConvertTo-MarkerNormalizedText -Text $actualBody
    $normalizedExpected = ConvertTo-MarkerNormalizedText -Text $ExpectedBody
    if ($normalizedActual -eq $normalizedExpected) {
        return $true
    }

    $expectedMinLength = [int]($ExpectedBody.Length * 0.5)
    if ($actualBody.Length -lt $expectedMinLength) {
        throw "persist-marker-core: read-back FAILED for comment $CommentId -- normalized verify body does not equal the normalized written body, and the raw verify body ($($actualBody.Length) chars) is dramatically shorter than the written body ($($ExpectedBody.Length) chars)"
    }
    throw "persist-marker-core: read-back FAILED for comment $CommentId -- normalized verify body does not equal the normalized written body"
}

# ---------------------------------------------------------------------------
# Write shapes.
# ---------------------------------------------------------------------------

function script:Invoke-MarkerPostNewWrite {
    <#
    .SYNOPSIS
        post-new write shape: compares the candidate against the LATEST
        (highest REST id) marker match only, per Find-AllCommentsByExactMarker's
        ascending-id ordering; a candidate matching a superseded, non-latest
        match still posts.
    .DESCRIPTION
        Author-blind risk (accepted, per this slice's requirement contract
        rule 7): Find-AllCommentsByExactMarker's matches carry no comment
        author -- the unified REST comments endpoint response this function
        consumes is not filtered by author anywhere in this call chain. A
        same-marker comment posted by ANY author (not just this script's own
        invoking identity) counts as "the latest match" for the idempotency
        comparison above. Restricting candidates to the invoking identity
        would require threading an expected-author identity through the
        registry and every call site -- out of scope for this slice; this
        comment records it as an accepted risk rather than silently ignoring
        it (a design-challenge-sustained finding, disposition: incorporate
        as accepted risk, s3 author policy).
    .OUTPUTS
        [PSCustomObject] Success [bool], Family [string], CommentId
        [long or $null], Action ['posted'|'no-op'|$null], Confirmation
        [string or $null], Reason [string or $null].
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][ValidateSet('issue', 'pr')][string]$Type,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )

    $existing = Find-AllCommentsByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $Number -Marker $Marker
    if ($existing.Count -gt 0) {
        # Ascending REST-id order (Find-AllCommentsByExactMarker's own
        # contract) -- the last element is the latest (highest id) match.
        # See this function's own .DESCRIPTION for the author-blind risk
        # this selector accepts.
        $latest = $existing[-1]
        $normalizedExisting = ConvertTo-MarkerNormalizedText -Text $latest.Body
        $normalizedCandidate = ConvertTo-MarkerNormalizedText -Text $Body
        if ($normalizedExisting -eq $normalizedCandidate) {
            $confirmation = "persist-marker-core: family '$Family' comment $($latest.Id) no-op (already matches latest)"
            Write-Host $confirmation
            return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $latest.Id; Action = 'no-op'; Confirmation = $confirmation; Reason = $null }
        }
    }

    $postResult = New-MarkerComment -Type $Type -Owner $Owner -Repo $Repo -Number $Number -Body $Body
    if ($null -eq $postResult) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "New-MarkerComment failed to create the comment for family '$Family'" }
    }
    $newId = Get-CommentIdFromUrl -Url $postResult
    if ($null -eq $newId) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "Could not extract a numeric comment id from the created comment's url '$postResult' for family '$Family'" }
    }

    try {
        $null = script:Test-MarkerReadBack -Owner $Owner -Repo $Repo -CommentId $newId -ExpectedBody $Body
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $newId; Action = $null; Confirmation = $null; Reason = $_.Exception.Message }
    }

    $confirmation = "persist-marker-core: family '$Family' comment $newId posted"
    Write-Host $confirmation
    return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $newId; Action = 'posted'; Confirmation = $confirmation; Reason = $null }
}

function script:Invoke-MarkerUpsertWrite {
    <#
    .SYNOPSIS
        upsert write shape: selects the CANONICAL match (earliest / lowest
        REST id) for comparison, and re-finds that canonical target
        immediately before PATCH -- never --edit-last, always a fresh
        numeric REST comment id.
    .OUTPUTS
        [PSCustomObject] Success [bool], Family [string], CommentId
        [long or $null], Action ['created'|'updated'|'no-op'|$null],
        Confirmation [string or $null], Reason [string or $null].
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][ValidateSet('issue', 'pr')][string]$Type,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )

    $existing = Find-AllCommentsByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $Number -Marker $Marker
    if ($existing.Count -eq 0) {
        $postResult = New-MarkerComment -Type $Type -Owner $Owner -Repo $Repo -Number $Number -Body $Body
        if ($null -eq $postResult) {
            return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "New-MarkerComment failed to create the comment for family '$Family'" }
        }
        $newId = Get-CommentIdFromUrl -Url $postResult
        if ($null -eq $newId) {
            return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "Could not extract a numeric comment id from the created comment's url '$postResult' for family '$Family'" }
        }
        try {
            $null = script:Test-MarkerReadBack -Owner $Owner -Repo $Repo -CommentId $newId -ExpectedBody $Body
        }
        catch {
            return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $newId; Action = $null; Confirmation = $null; Reason = $_.Exception.Message }
        }
        $confirmation = "persist-marker-core: family '$Family' comment $newId created"
        Write-Host $confirmation
        return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $newId; Action = 'created'; Confirmation = $confirmation; Reason = $null }
    }

    # Canonical target = earliest (lowest REST id) match -- ascending order
    # per Find-AllCommentsByExactMarker's own contract, so [0] is earliest.
    $canonical = $existing[0]
    $normalizedExisting = ConvertTo-MarkerNormalizedText -Text $canonical.Body
    $normalizedCandidate = ConvertTo-MarkerNormalizedText -Text $Body
    if ($normalizedExisting -eq $normalizedCandidate) {
        $confirmation = "persist-marker-core: family '$Family' comment $($canonical.Id) no-op (already matches canonical)"
        Write-Host $confirmation
        return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $canonical.Id; Action = 'no-op'; Confirmation = $confirmation; Reason = $null }
    }

    # Re-find the canonical target immediately before PATCH -- never
    # --edit-last, always a fresh numeric REST comment id (893-D2
    # concurrency posture: single-writer assumption, pre-PATCH re-find,
    # residual race between this re-find and the PATCH below is an accepted
    # risk).
    $refound = Find-AllCommentsByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $Number -Marker $Marker
    if ($refound.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "Canonical comment for family '$Family' disappeared between find and PATCH" }
    }
    $targetId = $refound[0].Id

    $patchResult = Set-CommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $targetId -NewBody $Body
    if (-not $patchResult.Success) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $targetId; Action = $null; Confirmation = $null; Reason = $patchResult.Reason }
    }

    try {
        $null = script:Test-MarkerReadBack -Owner $Owner -Repo $Repo -CommentId $targetId -ExpectedBody $Body
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $targetId; Action = $null; Confirmation = $null; Reason = $_.Exception.Message }
    }

    $confirmation = "persist-marker-core: family '$Family' comment $targetId updated"
    Write-Host $confirmation
    return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $targetId; Action = 'updated'; Confirmation = $confirmation; Reason = $null }
}

# ---------------------------------------------------------------------------
# Public dispatcher.
# ---------------------------------------------------------------------------

function Invoke-PersistMarkerWrite {
    <#
    .SYNOPSIS
        Looks up -Family in the family registry, preflights the declared
        -TargetSurface against the registry row's declared surface, and
        dispatches to the row's write shape (post-new or upsert).
    .PARAMETER Family
        Registry key (Get-MarkerFamilyRegistry's Family field).
    .PARAMETER TargetSurface
        The CALLER's declared surface for -Number ('issue' or
        'pull-request'). Compared against the registry row's declared
        TargetSurface before any write -- see this file's header for why
        this must be a declared-vs-declared comparison rather than a live
        lookup.
    .PARAMETER Marker
        The exact marker line the composed -Body carries (used for the
        Find-AllCommentsByExactMarker search). The caller composes both
        -Marker and -Body; this file never composes payload content.
    .PARAMETER Body
        The full comment body to write, already carrying -Marker. Never
        logged or echoed separately from the confirmation line (which names
        only family, comment id, and action -- not payload content).
    .OUTPUTS
        [PSCustomObject] Success [bool], Family [string], CommentId
        [long or $null], Action [string or $null], Confirmation
        [string or $null], Reason [string or $null] (populated only when
        Success=$false).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][ValidateSet('issue', 'pull-request')][string]$TargetSurface,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )

    $row = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq $Family })
    if ($row.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "Unknown marker family '$Family' -- not present in the family registry" }
    }
    $familyRow = $row[0]

    # Surface preflight -- see this file's header for why this compares
    # declared surfaces rather than performing a live lookup.
    if ($familyRow.TargetSurface -ne $TargetSurface) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "Surface mismatch for family '$Family': registry declares '$($familyRow.TargetSurface)' but this write was targeted at '$TargetSurface' (number $Number)" }
    }

    $ghType = if ($TargetSurface -eq 'pull-request') { 'pr' } else { 'issue' }

    switch ($familyRow.WriteShape) {
        'post-new' { return script:Invoke-MarkerPostNewWrite -Owner $Owner -Repo $Repo -Family $Family -Type $ghType -Number $Number -Marker $Marker -Body $Body }
        'upsert' { return script:Invoke-MarkerUpsertWrite -Owner $Owner -Repo $Repo -Family $Family -Type $ghType -Number $Number -Marker $Marker -Body $Body }
        default { return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "Unknown write shape '$($familyRow.WriteShape)' for family '$Family'" } }
    }
}
