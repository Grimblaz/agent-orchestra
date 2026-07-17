#Requires -Version 7.0
<#
.SYNOPSIS
    Bounded, fail-open, Claude-only startup harvest that upgrades mid-session
    baseline captures to exact end-of-session numbers (issue #824, Step 4 part B).
.DESCRIPTION
    Invoke-CostBaselineHarvest: finds merged PRs whose cost-pattern-data comment
    is still labeled `capture_point: pr-creation-mid-session`, re-walks their
    session using the extracted Invoke-CostSessionRender entry point (issue #824
    s4a), and — only when the re-walk is safe to trust — promotes the comment
    in place to `capture_point: end-of-session` with exact numbers.

    This file supplies the harvest FUNCTION only. It is invoked from a
    session-startup step in a later, separate slice (issue #824 s5) — that step
    owns the fail-open wiring/prose; this function owns the mechanics.

    This file also supplies Invoke-CostAttributionRepair (issue #825, Step 3),
    a second, independent public function: a maintainer-invoked, single-PR
    targeted re-attribution repair for a merged PR whose block reads
    `session_completeness: unknown`. It is NOT an extension of
    script:Select-CostBaselineHarvestCandidates' automatic candidate loop —
    that loop and Invoke-CostBaselineHarvest's own promote/stamp machinery are
    untouched. See Invoke-CostAttributionRepair's own doc comment for the full
    contract.

    Every failure path is silent no-op (fail-open): a failed `gh` call, no
    candidates, a verify-then-select miss, or a re-walk error all leave the
    harvest a no-op rather than throwing or blocking whatever invoked it.

    Dependencies (must already be dot-sourced by the caller — this file does
    not dot-source them itself, matching cost-session-render.ps1's own
    caller-owns-dependencies convention):
      - Get-CostRollingHistory        (cost-rolling-history.ps1)
      - Test-CostWalkerSessionTranscriptExists, Get-CostTranscriptSlug
                                       (cost-walker.ps1)
      - Invoke-CostSessionRender      (cost-session-render.ps1 — see that
                                       file's own .NOTES for its full
                                       transitive dependency list)
      - Find-OrUpsertComment          (find-or-upsert-comment.ps1)
      - script:Get-FCLTokenSumFromBucket, $script:FCLCostPatternSectionRegex
                                       (cost-fcl-helpers.ps1 — issue #824
                                       post-review fix M13/M18: this file
                                       calls these directly, in addition to
                                       Invoke-CostSessionRender's own
                                       transitive need for the rest of that
                                       lib file's contents)
      - Read-PRMetricsBlock, Test-FCLYamlSane, script:Escape-FCLScalar
                                       (frame-credit-ledger-core.ps1 — issue
                                       #489 s2: the reader, validator, and
                                       scalar-escaper that s3's shared
                                       cost-summary transform and s5's
                                       body-refresh/reconcile paths need are
                                       reachable only once this file is
                                       dot-sourced ahead of
                                       cost-fcl-helpers.ps1; previously
                                       absent from the harvest's chain, which
                                       reproduced the #824 silent-no-op
                                       mechanism for any core-lib call)

    NOTE (issue #824 post-review fix M6): this file's own private
    script:Get-CostBaselineHarvestRestCommentId deliberately MIRRORS (rather
    than dot-source-depends-on) find-or-upsert-comment.ps1's file-scope
    Get-RestCommentId — same two-line REST-id extraction algorithm, kept in
    sync by comment cross-reference. A hard dependency on that name was
    rejected: find-or-upsert-comment.ps1 also defines the real
    Find-OrUpsertComment, and pulling that definition into the same
    dot-source scope as this file's own functions silently shadows Pester's
    per-test `Find-OrUpsertComment` mocks (a nearer-scope function
    definition wins over a same-named `function global:` override). See
    Get-CostBaselineHarvestCompositeComment's own doc comment for why the
    selection rule must still match Find-OrUpsertComment's exactly.
#>

# ---------------------------------------------------------------------------
# Private helpers (script-scope so tests can dot-source and call them)
# ---------------------------------------------------------------------------

# F1 (issue #824 post-fix cycle 2): the composite `<!-- frame-credit-ledger-
# $Pr -->` comment is posted by frame-enforce.yml's own
# frame-credit-ledger.ps1 run under secrets.GITHUB_TOKEN, so its real
# author.login is always this repo's own CI identity — empirically
# confirmed via `gh pr view --json comments` against real merged PRs
# (#829, #822, #815). See Get-CostBaselineHarvestCompositeComment's
# .DESCRIPTION for the full threat model this identity check protects.
$script:CostBaselineHarvestKnownAutomationLogins = @('github-actions')

function script:Get-CostBaselineHarvestPortsTokenSum {
    <#
    .SYNOPSIS
        Sums token counts across a parsed rolling-history entry's `ports` dict.
    .DESCRIPTION
        Ports-only sum. Used as the fallback leg of
        script:Get-CostBaselineHarvestPersistedTokenSum below when a persisted
        entry predates the totals.tokens parser field (M4 fix) or never
        recorded one. Delegates per-bucket summation to the relocated shared
        script:Get-FCLTokenSumFromBucket (lib/cost-fcl-helpers.ps1, M13) so
        this sum and the totals-side sum cannot drift out of sync.
    #>
    param([AllowNull()]$Ports)

    [long]$sum = 0
    if ($null -eq $Ports) { return $sum }

    $portValues = if ($Ports -is [hashtable]) { $Ports.Values } elseif ($Ports -is [array]) { $Ports } else { @() }
    foreach ($portBucket in $portValues) {
        if ($null -eq $portBucket -or $portBucket -isnot [hashtable] -or -not $portBucket.ContainsKey('tokens')) { continue }
        $tokens = $portBucket['tokens']
        if ($null -eq $tokens -or $tokens -isnot [hashtable]) { continue }
        $sum += script:Get-FCLTokenSumFromBucket -Bucket $tokens
    }
    return $sum
}

function script:Get-CostBaselineHarvestPersistedTokenSum {
    <#
    .SYNOPSIS
        Totals-first-with-ports-fallback token sum for a persisted rolling-history entry.
    .DESCRIPTION
        M4 fix (issue #824 post-review): the token no-downgrade guard originally
        compared a totals-first re-walk sum (Invoke-CostSessionRender's TokenSum,
        which includes orchestrator overhead + unattributed tokens outside any
        port bucket) against a ports-only persisted sum — a structural mismatch
        that made the guard pass almost unconditionally, defeating its purpose.

        cost-rolling-history.ps1's ConvertFrom-CostPatternYaml now parses
        totals.tokens (M4, same fix set), so this function mirrors the exact
        totals-first-with-ports-fallback derivation already used at the capture
        site (cost-session-render.ps1's own $currentTokenSum/$priorTokenSum
        pattern): prefer the parsed totals.tokens bucket; fall back to the
        ports-only sum only for entries that predate the parser fix or never
        recorded a totals block.
    #>
    param([AllowNull()][hashtable]$Entry)

    if ($null -eq $Entry) { return [long]0 }

    $totals = $Entry['totals']
    if ($null -ne $totals -and $totals -is [hashtable] -and $totals.ContainsKey('tokens')) {
        $totalsTokens = $totals['tokens']
        if ($null -ne $totalsTokens -and $totalsTokens -is [hashtable]) {
            return [long](script:Get-FCLTokenSumFromBucket -Bucket $totalsTokens)
        }
    }

    return [long](script:Get-CostBaselineHarvestPortsTokenSum -Ports $Entry['ports'])
}

function script:ConvertTo-CostBaselineHarvestUtcDate {
    <#
    .SYNOPSIS
        Parses a rolling-history entry's `generated_at` value to a UTC [datetime].
    .OUTPUTS
        [datetime] on success, or $null when the value is missing/unparseable.
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        return ($Value.Kind -eq [System.DateTimeKind]::Utc) ? $Value : $Value.ToUniversalTime()
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try {
        $parsed = [datetime]::Parse($text, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return ($parsed.Kind -eq [System.DateTimeKind]::Utc) ? $parsed : $parsed.ToUniversalTime()
    }
    catch {
        return $null
    }
}

function script:Select-CostBaselineHarvestCandidates {
    <#
    .SYNOPSIS
        Filters already-fetched rolling-history entries down to harvest candidates.
    .DESCRIPTION
        Reuses Get-CostRollingHistory's existing scan (its own cache/timeout
        budget already applies) rather than reimplementing PR enumeration.
        A candidate must:
          - carry capture_point == 'pr-creation-mid-session'
          - NOT already carry a non-empty upgrade_attempted_at stamp (a prior
            re-walk attempt that did not promote it — terminal/deprioritized)
          - have a generated_at within the HorizonDays window
          - carry a usable session_id and pr (required to act on it at all)
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object[]]$Entries,
        [Parameter(Mandatory)][int]$HorizonDays
    )

    $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-1 * $HorizonDays)
    $candidates = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry -or $entry -isnot [hashtable]) { continue }
        if ([string]$entry['capture_point'] -ne 'pr-creation-mid-session') { continue }

        if ($entry.ContainsKey('upgrade_attempted_at') -and -not [string]::IsNullOrWhiteSpace([string]$entry['upgrade_attempted_at'])) {
            continue
        }

        $generatedAtUtc = script:ConvertTo-CostBaselineHarvestUtcDate -Value $entry['generated_at']
        if ($null -eq $generatedAtUtc -or $generatedAtUtc -lt $cutoffUtc) { continue }

        if ([string]::IsNullOrWhiteSpace([string]$entry['session_id'])) { continue }
        if ($null -eq $entry['pr']) { continue }

        $candidates.Add($entry)
    }

    return , $candidates.ToArray()
}

function script:Get-CostBaselineHarvestRestCommentId {
    <#
    .SYNOPSIS
        Extracts the numeric REST comment id from a `gh ... --json comments`
        comment object (issue #824 post-review fix M6).
    .DESCRIPTION
        Deliberately mirrors find-or-upsert-comment.ps1's file-scope
        Get-RestCommentId — see this file's own top .NOTES for why this is a
        local mirror rather than a dot-source dependency on that name. Keep
        the two in sync: both extract the numeric id from the `#issuecomment-
        <id>` suffix of the comment's `url`, falling back to a direct [long]
        cast of `id` for callers that already supply a resolved numeric id.
    #>
    param([object]$Comment)

    if ($Comment.url -and ([string]$Comment.url -match '#issuecomment-(\d+)$')) { return [long]$Matches[1] }
    try { return [long]$Comment.id } catch { return $null }
}

function script:Get-CostBaselineHarvestCompositeComment {
    <#
    .SYNOPSIS
        Fetches the composite `<!-- frame-credit-ledger-$Pr -->` comment body for a PR.
    .DESCRIPTION
        M2 (issue #824 post-review fix): sets [Console]::OutputEncoding to
        UTF-8 before reading gh's stdout — the established repo-wide guard
        (see orchestra-spine.ps1:15) against Windows silently decoding a
        `gh` child process's UTF-8 stdout via the OEM code page, which
        corrupts non-ASCII characters (—, ⚠, etc.) in the composite
        comment's untouched sections on every write-back.

        M6 (issue #824 post-review fix): on a marker-matching duplicate,
        selects the SAME comment Find-OrUpsertComment will actually PATCH —
        the earliest (lowest REST id) match — via the same REST-id
        extraction algorithm Find-OrUpsertComment itself uses (see
        script:Get-CostBaselineHarvestRestCommentId above), so the two
        selection rules cannot drift apart. Falls back to the first raw
        (encounter-order) match only in the same no-resolvable-id edge case
        where Find-OrUpsertComment itself gives up on patching and posts a
        new comment instead.

        M19 (issue #824 post-review fix), corrected by the post-fix cycle 2
        F1 fix: fail-closed authorship check on the composite comment. This
        gate protects a different threat model than
        Resolve-FCLOverrideMarker's (frame-credit-ledger-core.ps1) — that
        function gates a human-authored override *directive* embedded in a
        comment body, so requiring OWNER/MEMBER/COLLABORATOR is the right
        bar for a human to assert. This gate instead reads a *data* comment
        that `.github/workflows/frame-enforce.yml` posts itself (via
        frame-credit-ledger.ps1 -> Find-OrUpsertComment) under
        `secrets.GITHUB_TOKEN`, so its real, legitimate author is the
        repo's own `github-actions` automation identity with
        `authorAssociation: NONE` — empirically confirmed via `gh pr view
        --json comments` against real merged PRs (#829, #822, #815).
        Requiring OWNER/MEMBER/COLLABORATOR here rejected every real
        candidate outright (association NONE never satisfies that set),
        permanently starving the one-per-startup budget against real
        production data. The real threat this gate defends against is an
        arbitrary human PR commenter forging a look-alike
        `<!-- frame-credit-ledger-$Pr -->` marker with a fabricated
        capture_point/pr pair to steer the harvest — so the gate accepts a
        comment when EITHER its authorAssociation is in
        OWNER/MEMBER/COLLABORATOR (a trusted human) OR its author.login
        matches the repo's own known CI poster identity, `github-actions`
        (the trusted automation actually posting this comment). Anyone
        else — including any other NONE-association human commenter — is
        still treated as not-found (fail-closed).
    .OUTPUTS
        [hashtable] @{ Found = [bool]; Body = [string]; Marker = [string] }
    #>
    param([Parameter(Mandatory)][int]$Pr)

    $marker = "<!-- frame-credit-ledger-$Pr -->"
    $notFound = @{ Found = $false; Body = ''; Marker = $marker }

    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

    $commentsJson = $null
    try { $commentsJson = & gh pr view $Pr --json comments 2>$null }
    catch { return $notFound }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commentsJson)) { return $notFound }

    $parsed = $null
    try { $parsed = ($commentsJson | Out-String) | ConvertFrom-Json -ErrorAction Stop }
    catch { return $notFound }

    if ($null -eq $parsed -or $null -eq $parsed.comments) { return $notFound }

    $matching = @($parsed.comments | Where-Object { $null -ne $_ -and [string]$_.body -like "*$marker*" })
    if ($matching.Count -eq 0) { return $notFound }

    $withIds = @($matching |
        ForEach-Object { [PSCustomObject]@{ Comment = $_; RestId = script:Get-CostBaselineHarvestRestCommentId -Comment $_ } } |
        Where-Object { $null -ne $_.RestId })
    $selected = if ($withIds.Count -gt 0) {
        (@($withIds | Sort-Object -Property RestId))[0].Comment
    }
    else {
        $matching[0]
    }

    $authorizedAssociations = @('OWNER', 'MEMBER', 'COLLABORATOR')
    $authorAssociation = if ($selected.PSObject.Properties['authorAssociation']) { [string]$selected.authorAssociation } else { '' }
    $authorLogin = if ($selected.PSObject.Properties['author'] -and $null -ne $selected.author -and $selected.author.PSObject.Properties['login']) { [string]$selected.author.login } else { '' }

    $isAuthorizedAssociation = (-not [string]::IsNullOrWhiteSpace($authorAssociation)) -and ($authorAssociation.ToUpperInvariant() -in $authorizedAssociations)
    # F1 (issue #824 post-fix cycle 2): recognize the repo's own known CI
    # poster identity explicitly instead of widening authorizedAssociations
    # to include NONE — see this function's .DESCRIPTION for why NONE alone
    # is not safe to accept (would also accept an arbitrary human
    # commenter, since NONE is common to both).
    $isKnownAutomationIdentity = $authorLogin -in $script:CostBaselineHarvestKnownAutomationLogins

    if (-not ($isAuthorizedAssociation -or $isKnownAutomationIdentity)) {
        [Console]::Error.WriteLine("cost-baseline-harvest: composite comment for PR $Pr matched marker but author '$authorLogin' (association: '$authorAssociation') is neither OWNER/MEMBER/COLLABORATOR nor the known CI poster identity — treated as not found (fail-closed)")
        return $notFound
    }

    return @{ Found = $true; Body = [string]$selected.body; Marker = $marker }
}

function script:Test-CostBaselineHarvestCandidateGate {
    <#
    .SYNOPSIS
        Runs the verify-then-select (M14) and untrusted-read-back (M16) gates for
        one harvest candidate (issue #824 refactor pass — extracted from
        Invoke-CostBaselineHarvest's per-candidate loop body to keep that function
        under the size/complexity guidance in refactoring-methodology).
    .DESCRIPTION
        Pure gate check: no budget-cap bookkeeping and no re-walk side effect —
        the caller still owns deciding what "Passed" means for its own
        Attempted/Pr state and for spending the one-re-walk-per-startup budget.
    .PARAMETER CandidatePr
        The candidate's persisted PR number (already parsed by the caller).
    .PARAMETER CandidateSessionId
        The candidate's persisted session_id (verify-then-select target).
    .PARAMETER CandidateHeadRefHint
        The candidate's persisted head_ref — used only as a hint for the local
        transcript-existence check, never as authorization (see M16 below).
    .PARAMETER ParentCwd
        The harvesting session's own parent cwd, passed through to
        Test-CostWalkerSessionTranscriptExists.
    .PARAMETER RepoRoot
        The harvesting session's own repo root, passed through to
        Test-CostWalkerSessionTranscriptExists.
    .PARAMETER ProjectsRoot
        Root directory containing project slug directories, passed through to
        Test-CostWalkerSessionTranscriptExists.
    .PARAMETER Slug
        The harvesting session's own cost-transcript slug, passed through to
        Test-CostWalkerSessionTranscriptExists so its verify-then-select check
        can reach the same worktree-glob and primary-slug-fallback directory
        set the session_id writer (Get-CostWalkerCurrentSessionId) used at
        capture time (M3 fix, issue #824 post-review). Omitting this reverts
        to the narrower identity-only resolution and silently reintroduces
        the worktree-origin blind spot M3 exists to close.
    .OUTPUTS
        [hashtable] @{ Passed = [bool]; LiveHeadRef = [string] }
        LiveHeadRef is only meaningful when Passed is $true.
    #>
    param(
        [Parameter(Mandatory)][int]$CandidatePr,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CandidateSessionId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CandidateHeadRefHint,
        [Parameter(Mandatory)][string]$ParentCwd,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProjectsRoot,
        [AllowEmptyString()][string]$Slug = ''
    )

    $failedGate = @{ Passed = $false; LiveHeadRef = '' }

    # Verify-then-select (M14): a session id with no local transcript on
    # this machine is skipped WITHOUT spending a gh call or the re-walk
    # budget — cheap candidates keep moving until one is actionable.
    $transcriptExists = $false
    try {
        $transcriptExists = Test-CostWalkerSessionTranscriptExists `
            -SessionId $CandidateSessionId `
            -Branch $CandidateHeadRefHint `
            -ParentCwd $ParentCwd `
            -RepoRoot $RepoRoot `
            -ProjectsRoot $ProjectsRoot `
            -Slug $Slug
    }
    catch { $transcriptExists = $false }
    if (-not $transcriptExists) { return $failedGate }

    # Untrusted read-back (M16): the persisted head_ref is only a hint
    # for the local check above — bind to a live merge-commit/state
    # check before acting, and use the LIVE headRefName (not the
    # comment's) as the walk key below.
    $liveJson = $null
    try { $liveJson = & gh pr view $CandidatePr --json 'state,mergedAt,mergeCommit,headRefName' 2>$null }
    catch { $liveJson = $null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($liveJson)) { return $failedGate }

    $liveInfo = $null
    try { $liveInfo = ($liveJson | Out-String) | ConvertFrom-Json -ErrorAction Stop }
    catch { $liveInfo = $null }
    if ($null -eq $liveInfo -or [string]$liveInfo.state -ne 'MERGED') { return $failedGate }

    $liveHeadRef = [string]$liveInfo.headRefName
    if ([string]::IsNullOrWhiteSpace($liveHeadRef)) { return $failedGate }

    return @{ Passed = $true; LiveHeadRef = $liveHeadRef }
}

function script:Merge-CostBaselineHarvestSection {
    <#
    .SYNOPSIS
        Splices a replacement Cost Pattern section into a composite comment body
        at a previously matched section location (issue #824 refactor pass —
        shared by the promote and stamp outcomes below, which previously each
        rebuilt this same substring-splice inline).
    .OUTPUTS
        [string] The composite comment body with the section replaced.
    #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][System.Text.RegularExpressions.Match]$SectionMatch,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Replacement
    )

    return $Body.Substring(0, $SectionMatch.Index) +
        $Replacement +
        $Body.Substring($SectionMatch.Index + $SectionMatch.Length)
}

function script:Add-CostBaselineHarvestUpgradeAttemptedStamp {
    <#
    .SYNOPSIS
        Additively stamps `upgrade_attempted_at` onto an existing cost-pattern-data section.
    .DESCRIPTION
        Mirrors the additive-scalar-before-`ports:` placement rule s2 established
        for capture_point/session_id/head_ref/pr (ConvertFrom-CostPatternYaml's
        ports-block scanner terminates on the next top-level key it encounters,
        so a new top-level scalar must land before `ports:`). This does not
        re-render the section — it stamps the row's EXISTING (persisted) section
        verbatim, since a stably-incomplete re-walk must not overwrite the
        visible content, only mark the row so future scans skip it.

        M8 (issue #824 post-review fix, part b): idempotent stamp — replace
        an existing `upgrade_attempted_at` line in place instead of
        inserting a second one. A stale local rolling-history cache entry
        (pre-refresh) can re-surface a candidate whose composite-comment
        section was ALREADY stamped by an earlier write — this function's
        caller always re-fetches the composite comment fresh via `gh pr
        view` (live GitHub state, not the stale cache), so the section it
        receives here may already carry the line.
    #>
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$TimestampIso
    )

    if ($Section -match '(?m)^upgrade_attempted_at\s*:\s*.*$') {
        return ($Section -replace '(?m)^upgrade_attempted_at\s*:\s*.*$', "upgrade_attempted_at: $TimestampIso")
    }

    if ($Section -match '(?m)^ports\s*:\s*$') {
        return ($Section -replace '(?m)^ports\s*:\s*$', "upgrade_attempted_at: $TimestampIso`nports:")
    }

    # Fallback: no ports: line found (unexpected shape) — stamp just before the closing '-->'.
    return ($Section -replace '-->\s*$', "upgrade_attempted_at: $TimestampIso`n-->")
}

function script:Test-CostBaselineHarvestSectionStillCurrent {
    <#
    .SYNOPSIS
        M15 (issue #824 post-review fix): cheap concurrency mitigation.
    .DESCRIPTION
        A single re-check immediately before the final write — not a lock or
        retry loop. Re-fetches the composite comment one more time and
        confirms it still contains the exact section text matched earlier;
        if it does not (someone/something else already changed it since our
        read), the caller treats this the same as a failed write: skip the
        write, signal, do not retry, do not corrupt.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][string]$ExpectedSectionText
    )

    $refetch = script:Get-CostBaselineHarvestCompositeComment -Pr $Pr
    if ($null -eq $refetch -or -not $refetch['Found']) { return $false }

    return $refetch['Body'].Contains($ExpectedSectionText)
}

# ---------------------------------------------------------------------------
# Public function
# ---------------------------------------------------------------------------

function Invoke-CostBaselineHarvest {
    <#
    .SYNOPSIS
        Runs the bounded startup baseline-eligibility harvest (issue #824 s4).
    .DESCRIPTION
        1. Selects candidates from Get-CostRollingHistory's already-fetched scan
           (capture_point == 'pr-creation-mid-session', within HorizonDays, no
           prior upgrade_attempted_at stamp).
        2. Verify-then-select: skips a candidate whose persisted session_id has
           no matching transcript file on THIS machine (never selects on a
           comment claim alone).
        3. Untrusted read-back: before acting, confirms via a fresh `gh pr view`
           that the candidate is genuinely MERGED; uses the LIVE headRefName as
           the walk key (the persisted head_ref is only ever used as a hint for
           the local-transcript check above, never as authorization).
        4. Re-walks via Invoke-CostSessionRender, capped at one expensive
           re-walk per call — the first candidate that passes both the
           verify-then-select and live-merge-check gates consumes the budget,
           whatever the outcome.
        5. Promotes (section-splices the composite ledger comment in place)
           only when the re-walk classifies capture_point == 'end-of-session'
           AND its TokenSum >= the persisted candidate's ports-derived token
           sum. Otherwise — whether the re-walk produced real (non-empty)
           data that just didn't qualify, or found nothing usable at all
           (issue #824 post-review fix M11) — the row is stamped
           `upgrade_attempted_at` (idempotently; a pre-existing stamp line is
           replaced, not duplicated — M8 part b) so it exits future scans
           instead of re-consuming the one-re-walk-per-startup budget
           forever.
        6. Refreshes the rolling-history cache after a successful promotion
           AND after a successful stamp write (issue #824 post-review fix
           M8 part a — a stamped candidate must not re-qualify within the
           cache's TTL). Immediately before either write, re-confirms the
           composite comment still contains the exact section matched
           earlier; a changed section is treated as a failed write and
           skipped rather than risking a last-write-wins clobber of a
           concurrent change (issue #824 post-review fix M15).

        Every failure path is fail-open: this function never throws to its
        caller and never leaves a partial/corrupt write.
    .PARAMETER ParentCwd
        The current (harvesting) session's own parent cwd — used to resolve
        the local transcript-existence check in step 2, and passed through to
        Invoke-CostSessionRender in step 4.
    .PARAMETER RepoRoot
        The current session's own repo root — used for slug/identity
        resolution and passed through to Invoke-CostSessionRender.
    .PARAMETER Slug
        The current session's own cost-transcript slug. When omitted, resolved
        from RepoRoot via Get-CostTranscriptSlug.
    .PARAMETER ProjectsRoot
        Root directory containing project slug directories. Defaults to
        ~/.claude/projects (see Test-CostWalkerSessionTranscriptExists).
    .PARAMETER HorizonDays
        Candidate age window in days. Default: 14.
    .OUTPUTS
        [hashtable] @{ Attempted = [bool]; Promoted = [bool]; Pr = [Nullable[int]]; Signal = [string] }
        Attempted is $true only once a candidate has passed both gates and the
        one-per-startup re-walk has actually been invoked. Signal carries the
        exactly-one-line success/expected-but-failed text (or $null when no
        candidate ever reached that point).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ParentCwd,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Slug = '',
        [string]$ProjectsRoot = '',
        [int]$HorizonDays = 14
    )

    $result = @{ Attempted = $false; Promoted = $false; Pr = $null; Signal = $null }

    try {
        if ([string]::IsNullOrWhiteSpace($Slug)) {
            try { $Slug = Get-CostTranscriptSlug -CwdPath $RepoRoot } catch { $Slug = '' }
        }

        $rollingResult = $null
        try { $rollingResult = Get-CostRollingHistory }
        catch { return $result }

        if ($null -eq $rollingResult -or [bool]$rollingResult['timed_out']) { return $result }

        $entries = @($rollingResult['entries'])
        if ($entries.Count -eq 0) { return $result }

        $candidates = script:Select-CostBaselineHarvestCandidates -Entries $entries -HorizonDays $HorizonDays
        if ($candidates.Count -eq 0) { return $result }

        foreach ($candidate in $candidates) {
            $candidatePr = 0
            if (-not [int]::TryParse([string]$candidate['pr'], [ref]$candidatePr)) { continue }

            # Verify-then-select (M14) + untrusted read-back (M16) — see
            # script:Test-CostBaselineHarvestCandidateGate's docstring.
            $gate = script:Test-CostBaselineHarvestCandidateGate `
                -CandidatePr $candidatePr `
                -CandidateSessionId ([string]$candidate['session_id']) `
                -CandidateHeadRefHint ([string]$candidate['head_ref']) `
                -ParentCwd $ParentCwd `
                -RepoRoot $RepoRoot `
                -ProjectsRoot $ProjectsRoot `
                -Slug $Slug
            if (-not $gate['Passed']) { continue }
            $liveHeadRef = $gate['LiveHeadRef']

            # Budget cap: this candidate is now selected. Exactly one expensive
            # re-walk fires per Invoke-CostBaselineHarvest call, whatever the
            # eventual outcome — no other candidate is tried after this point.
            $result.Attempted = $true
            $result.Pr = $candidatePr

            $renderResult = $null
            try {
                $renderResult = Invoke-CostSessionRender `
                    -Pr $candidatePr `
                    -Branch $liveHeadRef `
                    -Slug $Slug `
                    -ParentCwd $ParentCwd `
                    -RepoRoot $RepoRoot
            }
            catch { $renderResult = $null }

            $reWalkCostSection = if ($null -ne $renderResult) { [string]$renderResult['CostSection'] } else { '' }
            # M11 (issue #824 post-review fix): an empty re-walk (transcript
            # unavailable / re-walk found nothing usable) can never promote —
            # there is no rendered section to splice in — but it must still
            # reach the SAME terminal-state stamp path below as "still
            # partial" / "lower token count", so the candidate exits future
            # scans. Previously this returned early with only a Signal set
            # and no write, permanently re-consuming the
            # one-re-walk-per-startup budget on a candidate that had
            # genuinely been tried and starving every candidate behind it.
            $reWalkIsEmpty = [string]::IsNullOrWhiteSpace($reWalkCostSection)

            # F2 (issue #824 post-fix cycle 2): guarded the same way as the
            # TokenSum access a few lines below — $renderResult is $null
            # whenever Invoke-CostSessionRender threw and was caught above,
            # and indexing into $null throws unconditionally (not only
            # under strict mode). An unguarded throw here escapes to the
            # function-level catch, which fail-opens as a silent no-op and
            # resets Attempted to $false — recreating the M11
            # budget-starvation bug for this specific sub-case.
            $reWalkCompleteness = if ($null -ne $renderResult) { $renderResult['Completeness'] } else { $null }
            $reWalkCapturePoint = if ($null -ne $reWalkCompleteness -and $reWalkCompleteness -is [hashtable] -and $reWalkCompleteness.ContainsKey('capture_point')) {
                [string]$reWalkCompleteness['capture_point']
            }
            else { 'n/a' }

            [long]$persistedTokenSum = script:Get-CostBaselineHarvestPersistedTokenSum -Entry $candidate
            [long]$reWalkTokenSum = 0
            if ($null -ne $renderResult -and $renderResult.ContainsKey('TokenSum') -and $null -ne $renderResult['TokenSum']) {
                $reWalkTokenSum = [long]$renderResult['TokenSum']
            }

            $shouldPromote = (-not $reWalkIsEmpty) -and ($reWalkCapturePoint -eq 'end-of-session') -and ($reWalkTokenSum -ge $persistedTokenSum)

            # F3 (issue #824 post-fix cycle 2): these two early-return paths
            # cannot use the in-comment upgrade_attempted_at stamp (there is
            # no comment, or no matched section, to splice a stamp into).
            # Neither path is durably recorded across process runs — the
            # harvest already accepts best-effort/re-attempted-next-startup
            # for every other failure class, and a comment-not-found or a
            # regex-format-drift condition is exactly the kind of transient
            # or externally-caused state that is reasonable to keep
            # retrying rather than build local persistence for. What DOES
            # matter is that these two paths are no longer silently
            # indistinguishable from each other (or from a routine
            # "transcript unavailable" outcome) in the Signal text, since
            # they point at different root causes an operator would
            # investigate differently: a deleted/missing comment (self-
            # healing on its own once the comment reappears) versus a
            # comment-format drift (needs an actual investigation/fix).
            $fetchResult = script:Get-CostBaselineHarvestCompositeComment -Pr $candidatePr
            if ($null -eq $fetchResult -or -not $fetchResult['Found']) {
                $result.Signal = "upgrade expected for #$candidatePr — composite comment not found (may be deleted; will retry)"
                return $result
            }

            $compositeBody = $fetchResult['Body']
            $sectionMatch = [regex]::Match($compositeBody, $script:FCLCostPatternSectionRegex)
            if (-not $sectionMatch.Success) {
                $result.Signal = "upgrade expected for #$candidatePr — cost section format mismatch (needs investigation)"
                return $result
            }

            if ($shouldPromote) {
                # Section-splice (M2): replace ONLY the Cost Pattern section —
                # never a full-body replace (would clobber the port/credit
                # reports elsewhere in the composite comment) and never a new
                # sibling comment (would double-count this PR in
                # Get-CostRollingHistory's one-entry-per-block-bearing-body scan).
                $newBody = script:Merge-CostBaselineHarvestSection -Body $compositeBody -SectionMatch $sectionMatch -Replacement $reWalkCostSection.TrimEnd()

                # M15 (issue #824 post-review fix): cheap concurrency
                # mitigation — a single re-check immediately before the
                # write. If the composite comment no longer contains the
                # exact section we matched, someone/something else already
                # changed it since our read; skip the write and treat it the
                # same as a failed write rather than risk a last-write-wins
                # clobber of that concurrent change.
                if (-not (script:Test-CostBaselineHarvestSectionStillCurrent -Pr $candidatePr -ExpectedSectionText $sectionMatch.Value)) {
                    $result.Signal = "upgrade expected for #$candidatePr — composite comment write failed"
                    return $result
                }

                $upserted = $false
                try {
                    $null = Find-OrUpsertComment -Type 'pr' -Number $candidatePr -Marker $fetchResult['Marker'] -Body $newBody
                    $upserted = $true
                }
                catch { $upserted = $false }

                if ($upserted) {
                    try { $null = Get-CostRollingHistory -ForceRefresh } catch { }
                    $result.Promoted = $true
                    $result.Signal = "upgraded #$candidatePr to end-of-session"
                }
                else {
                    $result.Signal = "upgrade expected for #$candidatePr — composite comment write failed"
                }
            }
            else {
                # Terminal-state handling (M3, extended by M11): a re-walk
                # that produced real data but did not qualify for promotion
                # (still partial, OR complete-but-lower-token), OR an empty
                # re-walk that found nothing usable at all, is stamped so it
                # exits future scans instead of re-consuming the
                # one-re-walk-per-startup budget on a row that may never
                # promote (e.g. a null-tail/cross-tool row, or a transcript
                # that has genuinely gone missing).
                $reason =
                if ($reWalkIsEmpty) { 'transcript unavailable' }
                elseif ($reWalkCapturePoint -ne 'end-of-session') { 'still partial' }
                else { 'token count lower than persisted' }

                $timestampIso = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                $stampedSection = script:Add-CostBaselineHarvestUpgradeAttemptedStamp -Section $sectionMatch.Groups['section'].Value -TimestampIso $timestampIso

                $newBody = script:Merge-CostBaselineHarvestSection -Body $compositeBody -SectionMatch $sectionMatch -Replacement $stampedSection

                # M15: same pre-write staleness re-check as the promote path.
                if (-not (script:Test-CostBaselineHarvestSectionStillCurrent -Pr $candidatePr -ExpectedSectionText $sectionMatch.Value)) {
                    $result.Signal = "upgrade expected for #$candidatePr — composite comment write failed"
                    return $result
                }

                $stampUpserted = $false
                try {
                    $null = Find-OrUpsertComment -Type 'pr' -Number $candidatePr -Marker $fetchResult['Marker'] -Body $newBody
                    $stampUpserted = $true
                }
                catch { $stampUpserted = $false }

                # M8 (issue #824 post-review fix, part a): refresh the
                # rolling-history cache after a successful STAMP write too,
                # not only after promotion — otherwise a stamped candidate
                # can re-qualify within the 1-hour TTL, re-spending the
                # harvest budget and appending duplicate stamps (mitigated
                # further by the idempotent-stamp fix, part b, above).
                if ($stampUpserted) {
                    try { $null = Get-CostRollingHistory -ForceRefresh } catch { }
                }

                $result.Signal = "upgrade expected for #$candidatePr — $reason"
            }

            return $result
        }

        # No candidate ever passed both gates — fail-open no-op, no signal.
        return $result
    }
    catch {
        [Console]::Error.WriteLine("cost-baseline-harvest: harvest failed (fail-open, no-op): $($_.Exception.Message)")
        return @{ Attempted = $false; Promoted = $false; Pr = $null; Signal = $null }
    }
}

function Invoke-CostAttributionRepair {
    <#
    .SYNOPSIS
        Targeted, maintainer-invoked re-attribution repair for ONE merged PR
        whose persisted cost-pattern-data block reads
        `session_completeness: unknown` (issue #825, Step 3).
    .DESCRIPTION
        NOT an extension of script:Select-CostBaselineHarvestCandidates' automatic
        candidate loop — that function, and the rest of Invoke-CostBaselineHarvest's
        own promote/stamp machinery, are untouched by this function. This is a
        standalone entry point for a single, maintainer-named PR:

          1. Resolves the PR's REAL head ref via a fresh `gh pr view
             --json state,headRefName,body,createdAt,mergedAt` — never the
             persisted block's own `branch:` field, which the CI-written
             targets carry as the literal string `HEAD` (M2/M15, empirically
             confirmed on #814/#815) — and confirms the PR is genuinely
             MERGED before acting. The same call also fetches `createdAt`/
             `mergedAt` (no extra API call) for step 3's corroboration
             window.
          2. Fetches the composite `<!-- frame-credit-ledger-$Pr -->` comment
             (script:Get-CostBaselineHarvestCompositeComment — same
             fail-closed authorship gate Invoke-CostBaselineHarvest uses) and
             locates its Cost Pattern section. Only proceeds when the
             persisted section reads `session_completeness: unknown` — this
             function repairs exactly that degraded shape; a populated block
             is left untouched (it is not this function's job to re-render an
             already-populated session).
          3. Re-walks via Invoke-CostSessionRender with
             -AdmitCorroboratedFallback ON for this call only — turns on the
             s1 Tier-2 corroborated-fallback trust ladder (cost-walker.ps1)
             for this one targeted repair; the live PR-creation path never
             sets this (M10). -CorroborationWindowStart/-End are passed as
             this PR's own `createdAt`/`mergedAt` (issue #825 s3 post-review
             fix, M8 wiring gap) — without this, Tier-2 admission ran
             unbounded on the one path that actually ships in this issue
             (the automatic-drain path where this would also matter is
             deferred to #841), leaving the M8 same-repo reused-branch-name
             collision guard inert. An unparseable timestamp degrades that
             one bound to $null (unenforced) rather than blocking the repair
             — matching the walker's own "a $null bound is not enforced"
             contract.
          4. Acceptance = populated-beats-empty-unknown: the composite
             comment's Cost Pattern section is section-spliced (never a
             full-body replace, never a new sibling comment) with the
             re-walk's own rendered section — which already carries its own
             honest completeness label and the M6 coverage annotation when
             the walker rejected any corroborated directory — ONLY when the
             re-walk actually produced a non-empty section. When the machine
             holds no matching transcripts, this reports honestly and writes
             nothing: no `upgrade_attempted_at` stamp, no budget bookkeeping —
             that machinery belongs to the deferred automatic startup-drain
             follow-up (issue #841), out of scope here.

        Every failure path (gh failure, not-MERGED, no composite comment, no
        matching section, non-unknown persisted block, empty re-walk, a
        concurrent-change race on the pre-write re-check) returns
        Upserted=$false with a Signal describing why, and never throws to its
        caller.
    .PARAMETER Pr
        The merged PR number to re-attribute. Maintainer-supplied.
    .PARAMETER ParentCwd
        This (repairing) session's own parent cwd — the machine performing
        the repair must hold the target PR's transcripts. Passed through to
        Invoke-CostSessionRender.
    .PARAMETER RepoRoot
        This session's own repo root — used for slug/identity resolution and
        passed through to Invoke-CostSessionRender.
    .PARAMETER Slug
        This session's own cost-transcript slug. Resolved from RepoRoot via
        Get-CostTranscriptSlug when omitted.
    .OUTPUTS
        [hashtable] @{ Attempted = [bool]; Upserted = [bool]; Pr = [int]; Signal = [string] }
        Attempted is $true only once the persisted block has been confirmed
        `session_completeness: unknown` and the re-walk has actually been
        invoked. Upserted is $true only when the composite comment was
        successfully rewritten with populated data.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][string]$ParentCwd,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Slug = ''
    )

    $result = @{ Attempted = $false; Upserted = $false; Pr = $Pr; Signal = $null }

    try {
        if ([string]::IsNullOrWhiteSpace($Slug)) {
            try { $Slug = Get-CostTranscriptSlug -CwdPath $RepoRoot } catch { $Slug = '' }
        }

        # 1. Live merge-state + REAL head ref — never the persisted `branch:` field (M2/M15).
        # createdAt/mergedAt/commits ride along on this same call (no extra API
        # round-trip) for step 3's M8 corroboration-window bound.
        $liveJson = $null
        try { $liveJson = & gh pr view $Pr --json 'state,headRefName,body,createdAt,mergedAt,commits' 2>$null } catch { $liveJson = $null }
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($liveJson)) {
            $result.Signal = "repair skipped for #$Pr — gh pr view failed"
            return $result
        }

        $liveInfo = $null
        try { $liveInfo = ($liveJson | Out-String) | ConvertFrom-Json -ErrorAction Stop } catch { $liveInfo = $null }
        if ($null -eq $liveInfo -or [string]$liveInfo.state -ne 'MERGED') {
            $result.Signal = "repair skipped for #$Pr — not MERGED"
            return $result
        }

        $liveHeadRef = [string]$liveInfo.headRefName
        if ([string]::IsNullOrWhiteSpace($liveHeadRef)) {
            $result.Signal = "repair skipped for #$Pr — live headRefName unresolvable"
            return $result
        }
        $prBody = [string]$liveInfo.body

        # M8 corroboration-window bound (issue #825 s3/s4 post-review fix, C4): the PR's
        # own first-branch-appearance -> merge lifetime. "First branch appearance" is the
        # earliest commit's authoredDate, NOT the PR's createdAt — createdAt only reflects
        # when the PR object itself was opened on GitHub, which can trail the branch's real
        # start by the bulk of a multi-day session (the #814 flagship case: session ran
        # 2026-07-04T16:20Z, PR wasn't opened until 2026-07-06T05:12Z near the very end).
        # Using createdAt as the window start would silently exclude nearly all real
        # activity from corroboration. Falls back to createdAt only when the commits list
        # is empty or unparseable. An unparseable/absent timestamp still degrades that one
        # bound to $null (unenforced), matching the walker's own "a $null bound is not
        # enforced" contract — never blocks the repair.
        [Nullable[datetime]]$corroborationWindowStart = $null
        [Nullable[datetime]]$corroborationWindowEnd = $null
        try {
            $earliestCommitDate = $null
            if ($null -ne $liveInfo.commits -and @($liveInfo.commits).Count -gt 0) {
                $authoredDates = @(
                    $liveInfo.commits | ForEach-Object {
                        try { [datetime]$_.authoredDate } catch { $null }
                    } | Where-Object { $null -ne $_ }
                )
                if ($authoredDates.Count -gt 0) {
                    $earliestCommitDate = ($authoredDates | Sort-Object)[0]
                }
            }
            if ($null -ne $earliestCommitDate) {
                $corroborationWindowStart = $earliestCommitDate
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$liveInfo.createdAt)) {
                $corroborationWindowStart = [datetime]$liveInfo.createdAt
            }
        }
        catch { $corroborationWindowStart = $null }
        try { if (-not [string]::IsNullOrWhiteSpace([string]$liveInfo.mergedAt)) { $corroborationWindowEnd = [datetime]$liveInfo.mergedAt } } catch { $corroborationWindowEnd = $null }

        # 2. Locate the composite comment's Cost Pattern section; only act on a
        # persisted session_completeness: unknown block.
        $fetchResult = script:Get-CostBaselineHarvestCompositeComment -Pr $Pr
        if ($null -eq $fetchResult -or -not $fetchResult['Found']) {
            $result.Signal = "repair skipped for #$Pr — composite comment not found"
            return $result
        }

        $compositeBody = $fetchResult['Body']
        $sectionMatch = [regex]::Match($compositeBody, $script:FCLCostPatternSectionRegex)
        if (-not $sectionMatch.Success) {
            $result.Signal = "repair skipped for #$Pr — cost section format mismatch"
            return $result
        }

        if ($sectionMatch.Groups['section'].Value -notmatch '(?m)^session_completeness\s*:\s*unknown\s*$') {
            $result.Signal = "repair skipped for #$Pr — persisted block is not session_completeness: unknown"
            return $result
        }

        # L9 (issue #825 post-review fix): a null/unparseable bound previously
        # degraded silently to an UNENFORCED window (the walker's own "a $null bound
        # is not enforced" contract) — this repair path must never proceed with an
        # unenforced corroboration window, since an unenforced window is exactly what
        # lets a same-repo reused-branch collision outside this PR's real lifetime
        # slip through the Tier-2 corroborated-fallback ladder this repair turns on.
        # Checked here — after the cheaper composite-comment/session_completeness
        # gates above, which take priority when they alone already explain a skip —
        # and before $result.Attempted is set, so an unresolvable window is reported
        # honestly instead of proceeding with an unenforced repair.
        if ($null -eq $corroborationWindowStart -or $null -eq $corroborationWindowEnd) {
            $result.Signal = "repair skipped for #$Pr — corroboration window could not be resolved"
            return $result
        }

        $result.Attempted = $true

        # 3. Re-walk with the Tier-2 corroborated-fallback ladder ON — this call only (M10) —
        # bounded to this PR's own createdAt->mergedAt window (M8 wiring gap fix).
        $renderResult = $null
        try {
            $renderResult = Invoke-CostSessionRender `
                -Pr $Pr `
                -Branch $liveHeadRef `
                -Slug $Slug `
                -ParentCwd $ParentCwd `
                -RepoRoot $RepoRoot `
                -PrBody $prBody `
                -AdmitCorroboratedFallback `
                -CorroborationWindowStart $corroborationWindowStart `
                -CorroborationWindowEnd $corroborationWindowEnd
        }
        catch { $renderResult = $null }

        $reWalkCostSection = if ($null -ne $renderResult) { [string]$renderResult['CostSection'] } else { '' }
        # C1 fix (issue #825 post-review): the honest-unknown renderer always returns a
        # non-empty, populated-looking section even on a zero-event walk, so gating on
        # IsNullOrWhiteSpace($reWalkCostSection) never fires on the real "no matching
        # transcripts" path. Gate on actual walk activity instead — CostEventsCount is the
        # ground truth the render result already carries.
        $reWalkEventsCount = if ($null -ne $renderResult) { [int]$renderResult['CostEventsCount'] } else { 0 }
        if ($null -eq $renderResult -or $reWalkEventsCount -le 0) {
            $result.Signal = "repair found no activity for #$Pr — machine holds no matching transcripts; nothing written"
            return $result
        }

        # Data-loss guard (issue #825 CE Gate): Invoke-CostSessionRender's step-6g
        # budget-exhaustion edge (cost-session-render.ps1 line ~479) can return
        # CostEventsCount > 0 but an empty CostSection when the render budget runs out
        # before the section is composed. Splicing that empty replacement over the
        # matched block below would DELETE the persisted Cost Pattern section, because
        # Merge-CostBaselineHarvestSection is a pure substring splice. Kept DISTINCT
        # from the events<=0 "no matching transcripts" signal above: here the machine
        # DID hold activity, so the honest, actionable signal is to enlarge the budget
        # (FRAME_CREDIT_LEDGER_TEST_COST_BUDGET_SECONDS) and retry — never a silent
        # write, never a false "repaired".
        if ([string]::IsNullOrWhiteSpace($reWalkCostSection)) {
            $result.Signal = "repair found activity for #$Pr but the re-walk exhausted its render budget before composing the cost section; existing block left intact — retry with a larger cost budget"
            return $result
        }

        # 4. Populated-beats-empty-unknown: upsert only when the re-walk found activity.
        $newBody = script:Merge-CostBaselineHarvestSection -Body $compositeBody -SectionMatch $sectionMatch -Replacement $reWalkCostSection.TrimEnd()

        # M15-style cheap concurrency mitigation, reused from the harvest's own
        # pre-write re-check: skip the write (rather than risk a last-write-wins
        # clobber) if the section changed since it was matched above.
        if (-not (script:Test-CostBaselineHarvestSectionStillCurrent -Pr $Pr -ExpectedSectionText $sectionMatch.Value)) {
            $result.Signal = "repair for #$Pr — composite comment write failed (concurrent change)"
            return $result
        }

        $upserted = $false
        try {
            $null = Find-OrUpsertComment -Type 'pr' -Number $Pr -Marker $fetchResult['Marker'] -Body $newBody
            $upserted = $true
        }
        catch { $upserted = $false }

        if ($upserted) {
            $result.Upserted = $true
            $result.Signal = "repaired #$Pr — attribution re-walked and upserted"
        }
        else {
            $result.Signal = "repair for #$Pr — composite comment write failed"
        }

        return $result
    }
    catch {
        [Console]::Error.WriteLine("cost-baseline-harvest: attribution repair failed (fail-open, no write): $($_.Exception.Message)")
        return @{ Attempted = $false; Upserted = $false; Pr = $Pr; Signal = $null }
    }
}
