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
    that loop and Invoke-CostBaselineHarvest promote/stamp machinery are
    untouched. See Invoke-CostAttributionRepair doc comment for the full
    contract.

    Every failure path is silent no-op (fail-open): a failed `gh` call, no
    candidates, a verify-then-select miss, or a re-walk error all leave the
    harvest a no-op rather than throwing or blocking whatever invoked it.

    Dependencies (must already be dot-sourced by the caller — this file does
    not dot-source them itself, matching cost-session-render.ps1
    caller-owns-dependencies convention):
      - Get-CostRollingHistory        (cost-rolling-history.ps1)
      - Test-CostWalkerSessionTranscriptExists, Get-CostTranscriptSlug
                                       (cost-walker.ps1)
      - Invoke-CostSessionRender      (cost-session-render.ps1 — see that
                                       file .NOTES for its full
                                       transitive dependency list)
      - Find-OrUpsertComment          (find-or-upsert-comment.ps1)
      - script:Get-FCLTokenSumFromBucket, $script:FCLCostPatternSectionRegex
                                       (cost-fcl-helpers.ps1 — issue #824
                                       post-review fix M13/M18: this file
                                       calls these directly, in addition to
                                       Invoke-CostSessionRender
                                       transitive need for the rest of that
                                       lib file contents)
      - Read-PRMetricsBlock, Test-FCLYamlSane, script:Escape-FCLScalar,
        script:Get-FCLScalar, script:Get-FCLNestedScalar
                                       (frame-credit-ledger-core.ps1 — issue
                                       #489 s2: the reader, validator, and
                                       scalar-escaper that s3 shared
                                       cost-summary transform and s5
                                       body-refresh/reconcile paths need are
                                       reachable only once this file is
                                       dot-sourced ahead of
                                       cost-fcl-helpers.ps1; previously
                                       absent from the harvest chain, which
                                       reproduced the #824 silent-no-op
                                       mechanism for any core-lib call.
                                       script:Get-FCLScalar/
                                       script:Get-FCLNestedScalar are s5
                                       own additions to this list: the
                                       reconcile path readers for the
                                       comment gated Cost Pattern section
                                       and the PR body advisory-only
                                       cost_summary.capture_point)
      - script:Set-FCLPrBodyCostSummary, script:Update-FCLPrBodyCostSummary
                                       (cost-fcl-helpers.ps1 — issue #489 s3
                                       pure transform and effectful writer;
                                       s5 calls both directly from
                                       script:Invoke-CostBaselineHarvestBodySummaryWrite
                                       for the refresh-on-promotion and
                                       reconcile paths)
      - script:Get-Median               (cost-anomaly.ps1 — issue #467
                                       existing statistical-median helper,
                                       reused (not reimplemented) by
                                       script:Get-CostBaselineHarvestRollingBaseline
                                       below, issue #489 CE Gate follow-up)

    NOTE (issue #824 post-review fix M6): this file private
    script:Get-CostBaselineHarvestRestCommentId deliberately MIRRORS (rather
    than dot-source-depends-on) find-or-upsert-comment.ps1 file-scope
    Get-RestCommentId — same two-line REST-id extraction algorithm, kept in
    sync by comment cross-reference. A hard dependency on that name was
    rejected: find-or-upsert-comment.ps1 also defines the real
    Find-OrUpsertComment, and pulling that definition into the same
    dot-source scope as this file functions silently shadows Pester
    per-test `Find-OrUpsertComment` mocks (a nearer-scope function
    definition wins over a same-named `function global:` override). See
    Get-CostBaselineHarvestCompositeComment doc comment for why the
    selection rule must still match Find-OrUpsertComment exactly.
#>

# ---------------------------------------------------------------------------
# Private helpers (script-scope so tests can dot-source and call them)
# ---------------------------------------------------------------------------

# F1 (issue #824 post-fix cycle 2): the composite `<!-- frame-credit-ledger-
# $Pr -->` comment is posted by frame-enforce.yml
# frame-credit-ledger.ps1 run under secrets.GITHUB_TOKEN, so its real
# author.login is always this repo CI identity — empirically
# confirmed via `gh pr view --json comments` against real merged PRs
# (#829, #822, #815). See Get-CostBaselineHarvestCompositeComment
# .DESCRIPTION for the full threat model this identity check protects.
$script:CostBaselineHarvestKnownAutomationLogins = @('github-actions')

function script:Get-CostBaselineHarvestPortsTokenSum {
    <#
    .SYNOPSIS
        Sums token counts across a parsed rolling-history entry `ports` dict.
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
        compared a totals-first re-walk sum (Invoke-CostSessionRender TokenSum,
        which includes orchestrator overhead + unattributed tokens outside any
        port bucket) against a ports-only persisted sum — a structural mismatch
        that made the guard pass almost unconditionally, defeating its purpose.

        cost-rolling-history.ps1 ConvertFrom-CostPatternYaml now parses
        totals.tokens (M4, same fix set), so this function mirrors the exact
        totals-first-with-ports-fallback derivation already used at the capture
        site (cost-session-render.ps1 $currentTokenSum/$priorTokenSum
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
        Parses a rolling-history entry `generated_at` value to a UTC [datetime].
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
        Reuses Get-CostRollingHistory existing scan (its own cache/timeout
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
        Deliberately mirrors find-or-upsert-comment.ps1 file-scope
        Get-RestCommentId — see this file top .NOTES for why this is a
        local mirror rather than a dot-source dependency on that name. Keep
        the two in sync: both extract the numeric id from the `#issuecomment-
        <id>` suffix of the comment `url`, falling back to a direct [long]
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
        C2 (issue #489 post-review fix): the original M2 (issue #824
        post-review fix) [Console]::OutputEncoding UTF-8 pin used to be set
        HERE, guarding only calls that go through this function. That
        scoping regressed once other `gh`-invoking call sites in this file
        (Test-CostBaselineHarvestCandidateGate combined `gh pr view`
        fetch, the s5 reconcile pass direct `gh pr view` calls) could
        execute before this function ever ran in the same process — most
        commonly when the reconcile pass runs first and finds zero
        candidates. The pin is now set UNCONDITIONALLY near the top of
        Invoke-CostBaselineHarvest (the main entry function), before ANY
        `gh`-invoking call in this file execution path — see that
        function .DESCRIPTION for the relocated rationale comment.

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
        Resolve-FCLOverrideMarker (frame-credit-ledger-core.ps1) — that
        function gates a human-authored override *directive* embedded in a
        comment body, so requiring OWNER/MEMBER/COLLABORATOR is the right
        bar for a human to assert. This gate instead reads a *data* comment
        that `.github/workflows/frame-enforce.yml` posts itself (via
        frame-credit-ledger.ps1 -> Find-OrUpsertComment) under
        `secrets.GITHUB_TOKEN`, so its real, legitimate author is the
        repo `github-actions` automation identity with
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
        matches the repo known CI poster identity, `github-actions`
        (the trusted automation actually posting this comment). Anyone
        else — including any other NONE-association human commenter — is
        still treated as not-found (fail-closed).
    .OUTPUTS
        [hashtable] @{ Found = [bool]; Body = [string]; Marker = [string] }
    #>
    param([Parameter(Mandatory)][int]$Pr)

    $marker = "<!-- frame-credit-ledger-$Pr -->"
    $notFound = @{ Found = $false; Body = ''; Marker = $marker }

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
    # F1 (issue #824 post-fix cycle 2): recognize the repo known CI
    # poster identity explicitly instead of widening authorizedAssociations
    # to include NONE — see this function .DESCRIPTION for why NONE alone
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
        Invoke-CostBaselineHarvest per-candidate loop body to keep that function
        under the size/complexity guidance in refactoring-methodology).
    .DESCRIPTION
        Pure gate check: no budget-cap bookkeeping and no re-walk side effect —
        the caller still owns deciding what "Passed" means for its own
        Attempted/Pr state and for spending the one-re-walk-per-startup budget.
    .PARAMETER CandidatePr
        The candidate persisted PR number (already parsed by the caller).
    .PARAMETER CandidateSessionId
        The candidate persisted session_id (verify-then-select target).
    .PARAMETER CandidateHeadRefHint
        The candidate persisted head_ref — used only as a hint for the local
        transcript-existence check, never as authorization (see M16 below).
    .PARAMETER ParentCwd
        The harvesting session parent cwd, passed through to
        Test-CostWalkerSessionTranscriptExists.
    .PARAMETER RepoRoot
        The harvesting session repo root, passed through to
        Test-CostWalkerSessionTranscriptExists.
    .PARAMETER ProjectsRoot
        Root directory containing project slug directories, passed through to
        Test-CostWalkerSessionTranscriptExists.
    .PARAMETER Slug
        The harvesting session cost-transcript slug, passed through to
        Test-CostWalkerSessionTranscriptExists so its verify-then-select check
        can reach the same worktree-glob and primary-slug-fallback directory
        set the session_id writer (Get-CostWalkerCurrentSessionId) used at
        capture time (M3 fix, issue #824 post-review). Omitting this reverts
        to the narrower identity-only resolution and silently reintroduces
        the worktree-origin blind spot M3 exists to close.
    .OUTPUTS
        [hashtable] @{ Passed = [bool]; LiveHeadRef = [string]; LiveBody = [string] }
        LiveHeadRef and LiveBody are only meaningful when Passed is $true.
        LiveBody (issue #489 s5) rides the SAME `gh pr view` call that
        already fetches state/mergedAt/mergeCommit/headRefName here — a
        zero-round-trip addition, matching the combined-fetch convention
        this codebase already uses twice (:881 in this file,
        frame-credit-ledger.ps1:906-910) — so the caller can pass it
        straight to the s5 refresh-on-promotion write without a second
        `gh pr view` call.
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

    $failedGate = @{ Passed = $false; LiveHeadRef = ''; LiveBody = '' }

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
    # comment) as the walk key below.
    $liveJson = $null
    try { $liveJson = & gh pr view $CandidatePr --json 'state,mergedAt,mergeCommit,headRefName,body' 2>$null }
    catch { $liveJson = $null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($liveJson)) { return $failedGate }

    $liveInfo = $null
    try { $liveInfo = ($liveJson | Out-String) | ConvertFrom-Json -ErrorAction Stop }
    catch { $liveInfo = $null }
    if ($null -eq $liveInfo -or [string]$liveInfo.state -ne 'MERGED') { return $failedGate }

    $liveHeadRef = [string]$liveInfo.headRefName
    if ([string]::IsNullOrWhiteSpace($liveHeadRef)) { return $failedGate }

    return @{ Passed = $true; LiveHeadRef = $liveHeadRef; LiveBody = [string]$liveInfo.body }
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
        for capture_point/session_id/head_ref/pr (ConvertFrom-CostPatternYaml
        ports-block scanner terminates on the next top-level key it encounters,
        so a new top-level scalar must land before `ports:`). This does not
        re-render the section — it stamps the row EXISTING (persisted) section
        verbatim, since a stably-incomplete re-walk must not overwrite the
        visible content, only mark the row so future scans skip it.

        M8 (issue #824 post-review fix, part b): idempotent stamp — replace
        an existing `upgrade_attempted_at` line in place instead of
        inserting a second one. A stale local rolling-history cache entry
        (pre-refresh) can re-surface a candidate whose composite-comment
        section was ALREADY stamped by an earlier write — this function
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
# Rolling-baseline visible-line clause (issue #489 CE Gate follow-up, S4/AC5):
# closes the "cost trend answerable from GitHub alone" intent gap the CE
# judge and prosecution both flagged at PASS/partial — the visible cost
# headline showed only the current PR dollar figure, with no baseline
# to judge it against. The two CostSummary constructors below already run
# inside Invoke-CostBaselineHarvest, which has ALREADY fetched the rolling-
# history entries (Get-CostRollingHistory, used for the s4 candidate
# selection and s5 reconcile scan) — this reuses that same in-memory data
# rather than a second fetch.
# ---------------------------------------------------------------------------

# Minimum usable-entry sample size before a median is trusted enough to show
# on the visible line. 3 is deliberately small: early in a project
# lifetime (or right after this feature ships) there may be only a handful
# of merged, cost-tracked PRs at all, and a 1- or 2-PR "median" is really
# just one PR number wearing a statistical label — noise, not a trend. 3
# is the smallest sample where "median" stops being a synonym for "the last
# PR cost" (with 2 entries the median is the mean of the only two points;
# with 3, the middle value is at least chosen FROM the data rather than
# averaged across it). This is intentionally far below cost-anomaly.ps1
# own N thresholds (Rule A needs N>=10, Rule B needs N>=5) — those gate a
# STATISTICAL ANOMALY CLAIM ("this run is unusual"), a much stronger claim
# than this feature "here is roughly what recent PRs have cost, for
# context" framing.
$script:CostBaselineHarvestRollingBaselineMinimumSampleSize = 3

function script:Get-CostBaselineHarvestRollingBaseline {
    <#
    .SYNOPSIS
        Computes the rolling_baseline_usd structured value (median cost +
        sample size) from already-fetched rolling-history entries (issue
        #489 CE Gate follow-up).
    .DESCRIPTION
        Reuses script:Get-Median (cost-anomaly.ps1, issue #467) rather than
        reimplementing median math — matches this codebase one existing
        statistical-baseline convention instead of inventing a second one.

        Excludes the entry (if any) belonging to $ExcludePr — the rolling
        history returned by Get-CostRollingHistory can legitimately already
        contain the very PR being harvested (e.g. a re-run after an earlier
        promotion). Entries with no parsed totals.cost_estimate_usd are
        skipped rather than folded in as $0.00, which would silently
        understate the median. That covers three cases: the key is absent,
        it carries the renderer "genuinely unknown" null
        (cost-pattern-renderer.ps1 Format-CostRendererNullableCostYaml),
        or the value is present but does not culture-invariantly parse as a
        number (guards against untrusted rolling-history data that has been
        corrupted or hand-edited).

        Returns $null (never a zero-sample hashtable) when fewer than
        $MinimumSampleSize usable entries remain after exclusion/filtering,
        so callers can omit rolling_baseline_usd entirely — the same
        graceful-degradation shape this file already uses for every other
        optional CostSummary field.
    .OUTPUTS
        [hashtable] @{ median_usd = [double]; sample_size = [int] } or $null
    #>
    param(
        [AllowNull()][object[]]$Entries,
        [int]$ExcludePr = 0,
        [int]$MinimumSampleSize = $script:CostBaselineHarvestRollingBaselineMinimumSampleSize
    )

    $costs = [System.Collections.Generic.List[double]]::new()
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry -or $entry -isnot [hashtable]) { continue }

        # F6 (issue #489 lite re-verification, judge-sustained): only
        # end-of-session captures are eligible for rolling-baseline
        # aggregation. Mid-session ('pr-creation-mid-session'), degraded
        # ('unavailable'), and explicitly-excluded ('n/a') captures all carry
        # real-but-INELIGIBLE costs that would contaminate the customer-facing
        # trend baseline — the C13 rule documented both in
        # script:Test-CostBaselineHarvestBodySummaryStale below and in
        # cost-pattern-data-schema.md ('capture_point: n/a' == "excluded from
        # rolling-baseline aggregation"). Allowlisting the single eligible
        # value ('end-of-session', the only capture_point the completeness
        # gate ever stamps as eligible — Resolve-BaselineEligibility,
        # cost-completeness.ps1) rather than denylisting the known-bad ones
        # also excludes an absent/unknown capture_point by default, which is
        # the safe direction for an untrusted rolling-history cache.
        if ([string]$entry['capture_point'] -ne 'end-of-session') { continue }

        if ($ExcludePr -gt 0 -and $entry.ContainsKey('pr') -and $null -ne $entry['pr']) {
            $entryPr = 0
            if ([int]::TryParse([string]$entry['pr'], [ref]$entryPr) -and $entryPr -eq $ExcludePr) { continue }
        }

        $totals = $entry['totals']
        if ($null -eq $totals -or $totals -isnot [hashtable]) { continue }
        if (-not $totals.ContainsKey('cost_estimate_usd') -or $null -eq $totals['cost_estimate_usd']) { continue }

        [double]$parsedCost = 0.0
        if (-not [double]::TryParse([string]$totals['cost_estimate_usd'], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedCost)) { continue }
        $costs.Add($parsedCost)
    }

    if ($costs.Count -lt $MinimumSampleSize) { return $null }

    return @{
        median_usd  = script:Get-Median -Values $costs.ToArray()
        sample_size = $costs.Count
    }
}

# ---------------------------------------------------------------------------
# PR body refresh-on-promotion + reconcile (issue #489 s5)
# ---------------------------------------------------------------------------

function script:ConvertTo-CostBaselineHarvestSummaryFromRenderResult {
    <#
    .SYNOPSIS
        Builds the script:Update-FCLPrBodyCostSummary CostSummary hashtable
        from a fresh Invoke-CostSessionRender result (issue #489 s5
        refresh-on-promotion).
    .DESCRIPTION
        Sourced entirely from the SAME re-walk that already promoted the
        composite comment above — never a second re-count, never the
        untrusted PR body. Missing/absent Attribution or Completeness
        sub-keys degrade to zero/empty defaults rather than throwing, since
        some render-result shapes (including several existing test doubles)
        omit them.

        C6 companion fix (issue #489 post-review fix): distinguishes an
        ABSENT `cost_estimate_usd` key (degrades to 0.0, per the
        missing/absent convention above) from a key that is PRESENT but
        explicitly `$null` — the render pipeline "genuinely unknown
        cost" representation (mirrors cost-pattern-renderer.ps1
        Format-CostRendererNullableCostYaml, which renders exactly that
        `$null` as the YAML literal `null`). A present-but-null value is
        preserved as `$null` in the returned hashtable rather than
        collapsed to a false-confident 0.0, matching
        script:Set-FCLPrBodyCostSummary C7 costUnknown handling so
        this constructor and the writer agree on what "unknown" means.

        Issue #489 CE Gate follow-up: -Pr/-RollingHistoryEntries are
        optional. When both are supplied, script:Get-CostBaselineHarvestRollingBaseline
        computes a median+sample-size baseline from the caller already-
        fetched rolling history and — only when the sample clears the
        minimum size — the returned hashtable carries an additional
        rolling_baseline_usd key. Omitting either parameter (or supplying
        too little history) leaves that key absent entirely, matching this
        constructor existing degrade-to-absent convention.
    .OUTPUTS
        [hashtable] shaped for script:Set-FCLPrBodyCostSummary /
        script:Update-FCLPrBodyCostSummary -CostSummary parameter.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$RenderResult,
        [int]$Pr = 0,
        [AllowNull()][object[]]$RollingHistoryEntries = $null
    )

    $attribution = $RenderResult['Attribution']
    $totals = if ($null -ne $attribution -and $attribution -is [hashtable] -and $attribution['totals'] -is [hashtable]) { $attribution['totals'] } else { @{} }
    $tokens = if ($totals['tokens'] -is [hashtable]) { $totals['tokens'] } else { @{} }

    $completeness = $RenderResult['Completeness']
    $sessionCompleteness = if ($completeness -is [hashtable] -and $null -ne $completeness['completeness']) { [string]$completeness['completeness'] } else { '' }
    $capturePoint = if ($completeness -is [hashtable] -and $null -ne $completeness['capture_point']) { [string]$completeness['capture_point'] } else { '' }

    $costUsdTotal = 0.0
    $costUnknown = $false
    if ($totals.ContainsKey('cost_estimate_usd')) {
        if ($null -eq $totals['cost_estimate_usd']) {
            $costUnknown = $true
        }
        else {
            $costUsdTotal = [double]$totals['cost_estimate_usd']
        }
    }

    $summary = @{
        cost_usd_total        = if ($costUnknown) { $null } else { $costUsdTotal }
        tokens                = @{
            input          = if ($null -ne $tokens['input']) { [long]$tokens['input'] } else { 0L }
            output         = if ($null -ne $tokens['output']) { [long]$tokens['output'] } else { 0L }
            cache_creation = if ($null -ne $tokens['cache_creation']) { [long]$tokens['cache_creation'] } else { 0L }
            cache_read     = if ($null -ne $tokens['cache_read']) { [long]$tokens['cache_read'] } else { 0L }
        }
        session_completeness  = $sessionCompleteness
        capture_point         = $capturePoint
    }

    $rollingBaseline = script:Get-CostBaselineHarvestRollingBaseline -Entries $RollingHistoryEntries -ExcludePr $Pr
    if ($null -ne $rollingBaseline) {
        $summary['rolling_baseline_usd'] = $rollingBaseline
    }

    return $summary
}

function script:ConvertTo-CostBaselineHarvestLongOrDefault {
    <#
    .SYNOPSIS
        TryParse-defensive [long] parse for a raw YAML scalar string (issue
        #489 post-review fix, C6 companion).
    .DESCRIPTION
        script:ConvertTo-CostBaselineHarvestSummaryFromSection token
        fields shared the identical bare-`[long]` cast pattern that made
        that same function cost field throw on the renderer literal
        `null` YAML value (see that function C6 doc note). The
        renderer never actually emits `null` for a token count (only
        cost_estimate_usd uses Format-CostRendererNullableCostYaml — token
        fields always render as plain integers), so this helper has no
        `null`-recognition branch; it exists purely to replace the bare
        cast with a graceful TryParse so a malformed/non-numeric token
        value degrades to this function existing blank -> 0L convention
        instead of throwing and failing the whole candidate.
    .OUTPUTS
        [long]
    #>
    param([AllowNull()][string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return 0L }

    [long]$parsed = 0L
    if ([long]::TryParse($Raw, [ref]$parsed)) { return $parsed }
    return 0L
}

function script:ConvertTo-CostBaselineHarvestSummaryFromSection {
    <#
    .SYNOPSIS
        Builds the script:Update-FCLPrBodyCostSummary CostSummary hashtable
        from an already-gated composite comment Cost Pattern section text
        (issue #489 s5 reconcile path).
    .DESCRIPTION
        Reuses the hoisted script:Get-FCLScalar / script:Get-FCLNestedScalar
        readers (reachable via s2 dot-source chain extension) against the
        exact YAML shape Format-CostPatternYaml emits (cost-pattern-
        renderer.ps1): session_completeness/capture_point are flat
        top-level scalars, and totals.tokens.{input,output,cache_creation,
        cache_read} plus totals.cost_estimate_usd sit one level under the
        terminal totals: block. Spends no re-count budget: this reads the
        comment OWN already-computed numbers — never a re-walk, never the
        untrusted PR body.

        C6 (issue #489 post-review fix, judge-sustained, AC6): cost_estimate_
        usd can legitimately carry the literal YAML string `null`
        (case-sensitive; cost-pattern-renderer.ps1
        Format-CostRendererNullableCostYaml) when the cost genuinely
        could not be computed (e.g. a Copilot rate-unavailable session). A
        bare `[double]` cast on that literal throws
        ("Cannot convert value 'null' to type 'System.Double'"). This
        function caller (script:Invoke-CostBaselineHarvestReconcileCandidate)
        catches that exception per-candidate and logs it as a failure — but
        no reconcile-attempt marker exists, so the SAME candidate is
        retried forever on every startup, permanently blocking the PR from
        ever reconciling and violating this issue AC6 ("the reconcile
        path completes failed refreshes on later scans"). The literal
        `null` now maps to an explicit `$null` in the returned hashtable
        (never a thrown exception, never a silent 0) — the "genuinely
        unknown" state script:Set-FCLPrBodyCostSummary C7 fix already
        knows how to render honestly as "unknown". Any OTHER malformed,
        non-numeric, non-`null` value degrades to this function existing
        blank-value convention (0.0) via TryParse rather than throwing —
        the same graceful-degradation shape already established for blank
        values, just extended to cover malformed ones too.

        Issue #489 CE Gate follow-up: -Pr/-RollingHistoryEntries are
        optional, mirroring the sibling FromRenderResult constructor
        addition — see that function doc comment for the full contract.
    .OUTPUTS
        [hashtable] shaped for script:Set-FCLPrBodyCostSummary /
        script:Update-FCLPrBodyCostSummary -CostSummary parameter.
    #>
    param(
        [Parameter(Mandatory)][string]$Section,
        [int]$Pr = 0,
        [AllowNull()][object[]]$RollingHistoryEntries = $null
    )

    $costUsdTotalRaw = script:Get-FCLNestedScalar -Block $Section -ParentKey 'totals' -ChildKey 'cost_estimate_usd'
    $inputRaw = script:Get-FCLNestedScalar -Block $Section -ParentKey 'totals' -ChildKey 'input'
    $outputRaw = script:Get-FCLNestedScalar -Block $Section -ParentKey 'totals' -ChildKey 'output'
    $cacheCreationRaw = script:Get-FCLNestedScalar -Block $Section -ParentKey 'totals' -ChildKey 'cache_creation'
    $cacheReadRaw = script:Get-FCLNestedScalar -Block $Section -ParentKey 'totals' -ChildKey 'cache_read'

    # C6: exact case-sensitive match against the renderer literal 'null'
    # (Format-CostRendererNullableCostYaml returns the bare word 'null',
    # lowercase, four characters — never quoted, never any other casing).
    $costUsdTotal =
    if ($costUsdTotalRaw -cne 'null' -and -not [string]::IsNullOrWhiteSpace($costUsdTotalRaw)) {
        [double]$parsedCost = 0.0
        if ([double]::TryParse($costUsdTotalRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedCost)) {
            $parsedCost
        }
        else {
            # F7 (issue #489 lite re-verification, judge-sustained): a
            # MALFORMED, non-numeric, non-'null' value is genuinely unknown,
            # NOT free. Returning 0.0 here rendered a corrupted/garbage cost
            # as a confident "$0.00" headline (reads as "free session"),
            # while the literal-'null' branch below already renders honestly
            # as "unknown". Map malformed to the same explicit $null so the
            # existing unknown-cost rendering (script:Set-FCLPrBodyCostSummary
            # C7 "unknown" path) stays honest for corrupted values too. Only a
            # genuinely BLANK/absent value keeps the 0.0 default below.
            $null
        }
    }
    elseif ($costUsdTotalRaw -ceq 'null') {
        $null
    }
    else {
        0.0
    }

    $summary = @{
        cost_usd_total        = $costUsdTotal
        tokens                = @{
            input          = script:ConvertTo-CostBaselineHarvestLongOrDefault -Raw $inputRaw
            output         = script:ConvertTo-CostBaselineHarvestLongOrDefault -Raw $outputRaw
            cache_creation = script:ConvertTo-CostBaselineHarvestLongOrDefault -Raw $cacheCreationRaw
            cache_read     = script:ConvertTo-CostBaselineHarvestLongOrDefault -Raw $cacheReadRaw
        }
        session_completeness  = [string](script:Get-FCLScalar -Block $Section -Name 'session_completeness')
        capture_point         = [string](script:Get-FCLScalar -Block $Section -Name 'capture_point')
    }

    $rollingBaseline = script:Get-CostBaselineHarvestRollingBaseline -Entries $RollingHistoryEntries -ExcludePr $Pr
    if ($null -ne $rollingBaseline) {
        $summary['rolling_baseline_usd'] = $rollingBaseline
    }

    return $summary
}

function script:Get-CostBaselineHarvestBodyCostSummaryField {
    <#
    .SYNOPSIS
        Shared fence-aware pipeline-metrics cost_summary child-key reader
        (issue #489 refactor pass — extracted from
        script:Get-CostBaselineHarvestBodyCapturePoint and
        script:Get-CostBaselineHarvestBodySourceComment below, which each
        carried an identical copy of this fence-redaction + block-match +
        nested-scalar-read sequence, differing only in which cost_summary
        child key they read).
    .DESCRIPTION
        Locates the pipeline-metrics block with the same fence-agnostic
        marker regex Read-PRMetricsBlock uses (frame-credit-ledger-
        core.ps1:750), then reads the requested nested cost_summary.<ChildKey>
        scalar via the hoisted script:Get-FCLNestedScalar reader. Returns
        $null when the pipeline-metrics block itself is absent, when no
        cost_summary subtree exists inside it (the watchdog-kill,
        first-write-lost case the reconcile detector exists to catch), or
        when the requested child key is present but blank.

        TRUST BOUNDARY (issue #489 s5, load-bearing): the PR body is
        untrusted input — one author, potentially an arbitrary external
        contributor on a fork PR. The value returned here is ADVISORY ONLY.
        See each wrapper function .DESCRIPTION for how it uses its
        specific field; neither treats this return value as authoritative
        or writes it back into the body unvalidated.

        C10 (issue #489 post-review fix): applies the same fence-aware
        marker lookup discipline the writer already uses
        (cost-fcl-helpers.ps1 Set-FCLPrBodyCostSummary) — redacts
        ```-fenced regions to a same-length filler before searching for the
        pipeline-metrics marker, so a fenced documentation example of a
        pipeline-metrics block earlier in the body can never be mismatched
        as the real block. This is now the ONE place in this file that
        technique lives for body-side reads (the writer copy in
        Set-FCLPrBodyCostSummary remains a separate, cross-file mirror per
        this file top .NOTES on script:Get-CostBaselineHarvestRestCommentId
        mirror-not-depend choice — that choice is about avoiding a
        cross-file dot-source dependency that would shadow Pester mocks,
        which does not apply to this intra-file, same-scope extraction).
    .OUTPUTS
        [string] or $null
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][string]$ChildKey
    )

    if ([string]::IsNullOrEmpty($PrBody)) { return $null }

    $normalized = $PrBody -replace "`r`n", "`n" -replace "`r", "`n"

    # ---- Fence-aware marker lookup: redact fenced regions to a same-length
    # filler (so byte offsets stay aligned with $normalized) before searching
    # for the pipeline-metrics marker — mirrors cost-fcl-helpers.ps1
    # Set-FCLPrBodyCostSummary exactly (F8: both mirror sites broadened
    # identically; see that function for why the two copies stay file-local
    # rather than being hoisted to a shared $script: helper). ----
    #
    # F8 (issue #489 lite re-verification, judge-sustained): the fence
    # delimiter is a run of 3-or-more backticks OR 3-or-more tildes, closed by
    # a run of the same character and length (\1 backreference). The prior
    # exactly-three-backtick pattern left tilde (~~~) fences and 4+-backtick
    # fences un-redacted, so a `<!-- pipeline-metrics -->` example inside such
    # a fence could be mis-anchored as the real block. Same-char/same-length
    # is a pragmatic CommonMark approximation (a longer-than-open closing
    # fence is not matched) — sufficient for the realistic documentation-
    # example cases, and it preserves the same-length-filler byte-offset
    # invariant the marker Substring below relies on.
    $fencePattern = '(?s)(`{3,}|~{3,}).*?\1'
    $redacted = [regex]::Replace($normalized, $fencePattern, { param($m) [string]::new('x', $m.Value.Length) })

    $blockMatch = [regex]::Match($redacted, '(?s)<!--\s*pipeline-metrics\s*(?<block>.*?)\s*-->')
    if (-not $blockMatch.Success) { return $null }

    $blockGroup = $blockMatch.Groups['block']
    $blockText = $normalized.Substring($blockGroup.Index, $blockGroup.Length)

    return script:Get-FCLNestedScalar -Block $blockText -ParentKey 'cost_summary' -ChildKey $ChildKey
}

function script:Get-CostBaselineHarvestBodyCapturePoint {
    <#
    .SYNOPSIS
        Advisory-only read of a PR body cost_summary.capture_point (issue
        #489 s5 reconcile detector).
    .DESCRIPTION
        Thin wrapper over script:Get-CostBaselineHarvestBodyCostSummaryField
        (issue #489 refactor pass) — see that function for the shared
        fence-aware block-location mechanics and trust-boundary contract.

        The value returned here decides whether a reconcile write is
        attempted, and is NEVER treated as authoritative and NEVER written
        back into the body. The totals a reconcile write actually uses
        always come from the composite comment fail-closed-gated data
        (mirrors the forgery threat model
        Get-CostBaselineHarvestCompositeComment .DESCRIPTION
        documents).
    .OUTPUTS
        [string] or $null
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PrBody)

    return script:Get-CostBaselineHarvestBodyCostSummaryField -PrBody $PrBody -ChildKey 'capture_point'
}

function script:Get-CostBaselineHarvestBodySourceComment {
    <#
    .SYNOPSIS
        Advisory-only read of a PR body EXISTING cost_summary.source_comment
        (issue #489 post-review fix, F1, judge-sustained).
    .DESCRIPTION
        Thin wrapper over script:Get-CostBaselineHarvestBodyCostSummaryField
        (issue #489 refactor pass) — see that function for the shared
        fence-aware block-location mechanics and trust-boundary contract.

        Used by script:Invoke-CostBaselineHarvestBodySummaryWrite to preserve
        an existing "full breakdown" link across a full-subtree cost_summary
        replace: script:Set-FCLPrBodyCostSummary only re-emits
        source_comment when the incoming CostSummary hashtable itself
        already carries that key, so a caller that never read the PRIOR
        body link would silently erase it on every write. Returns $null
        when the pipeline-metrics block, the cost_summary subtree, or the
        source_comment child key itself is absent — the caller treats a
        $null/blank result as "nothing to preserve", never as an error.
    .OUTPUTS
        [string] or $null
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PrBody)

    return script:Get-CostBaselineHarvestBodyCostSummaryField -PrBody $PrBody -ChildKey 'source_comment'
}

function script:Test-CostBaselineHarvestSourceCommentUrl {
    <#
    .SYNOPSIS
        Validates a PR-body-derived cost_summary.source_comment URL before it
        is re-emitted into a regenerated cost_summary (issue #489 lite
        re-verification fix, F9, judge-sustained).
    .DESCRIPTION
        The source_comment read by script:Get-CostBaselineHarvestBodySourceComment
        comes from the UNTRUSTED PR body (one author, potentially an arbitrary
        external fork-PR contributor). script:Invoke-CostBaselineHarvestBodySummaryWrite
        seeds it onto the outgoing CostSummary when the fresh summary lacks
        one, and script:Set-FCLPrBodyCostSummary re-emits it through
        Escape-FCLScalar (YAML-escape only) — no URL-shape or same-repo/same-PR
        check. Re-emitting it unvalidated would let an author plant an
        arbitrary "full breakdown" link into the trusted-looking cost_summary
        on every refresh/reconcile pass, contradicting this file
        trust-boundary discipline (see Get-CostBaselineHarvestBodyCostSummaryField
        TRUST BOUNDARY note).

        A legitimate source_comment is always the html_url of THIS repo
        cost-breakdown comment for THIS PR — shaped exactly like
        https://github.com/<owner>/<repo>/(pull|issues)/<Pr>#issuecomment-<id>
        (Find-OrUpsertComment returned html_url; see frame-credit-ledger.ps1
        own C11 sibling validation). This predicate requires that exact shape:

          - an absolute https://github.com/ URL with no embedded whitespace
            and no ')' (which would break a markdown [text](url) link),
          - whose <owner>/<repo> segment matches THIS repo (resolved from the
            git remote, locally, without a gh call — same derivation as
            find-or-upsert-comment.ps1), and
          - whose PR number matches $Pr (this PR comment namespace).

        Fail-safe: if the repo cannot be resolved from the git remote, the URL
        is treated as un-validatable and REJECTED (omit rather than propagate
        an unconfirmable author-controlled link).
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Url,
        [Parameter(Mandatory)][int]$Pr
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    # Basic shape gate: absolute github.com https URL, no whitespace, no ')'.
    if ($Url -notmatch '(?i)^https://github\.com/\S+$') { return $false }
    if ($Url -match '\)') { return $false }

    # Resolve THIS repo owner/repo from the git remote (local, no gh) —
    # mirrors find-or-upsert-comment.ps1 derivation regex exactly.
    $remoteUrl = $null
    try { $remoteUrl = (& git config --get remote.origin.url) 2>$null } catch { $remoteUrl = $null }
    $ownerRepo = $null
    if ($remoteUrl -and ([string]$remoteUrl -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?\s*$')) {
        $ownerRepo = "$($Matches[1])/$($Matches[2])"
    }
    if ([string]::IsNullOrWhiteSpace($ownerRepo)) { return $false }

    # Must be this repo PR/issue comment namespace for THIS PR.
    $expected = '(?i)^https://github\.com/' + [regex]::Escape($ownerRepo) + '/(pull|issues)/' + [string]$Pr + '(#issuecomment-\d+)?$'
    return ($Url -match $expected)
}

function script:Test-CostBaselineHarvestBodySummaryStale {
    <#
    .SYNOPSIS
        Reconcile eligibility predicate (issue #489 s5): does a PR body
        advisory-only cost_summary.capture_point look stale against a
        comment that already reads end-of-session?
    .DESCRIPTION
        Mirrors the shape of the existing
        script:Test-CostBaselineHarvestSectionStillCurrent precedent (a
        single, narrowly-scoped predicate) rather than folding this check
        into a larger function. "Stale" covers four cases: a
        never-refreshed mid-session value, the degraded-write sentinel
        (`unavailable`), the documented `n/a` value (issue #489
        post-review fix, C13 — `capture_point: n/a` means "excluded from
        rolling-baseline aggregation" per cost-pattern-data-schema.md, and a
        body stamped `n/a` under an already-promoted comment is equally
        eligible for reconcile as any other non-current value), and the
        block-absent case — no cost_summary subtree at all, the
        watchdog-kill first-write-lost scenario.
    .OUTPUTS
        [bool]
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PrBody)

    $bodyCapturePoint = script:Get-CostBaselineHarvestBodyCapturePoint -PrBody $PrBody
    if ([string]::IsNullOrWhiteSpace($bodyCapturePoint)) { return $true }

    return $bodyCapturePoint -in @('pr-creation-mid-session', 'unavailable', 'n/a')
}

function script:Get-CostBaselineHarvestLivePrBody {
    <#
    .SYNOPSIS
        Fetches a PR current body via `gh pr view --json body`, fail-open
        (issue #489 lite re-verification fix, F2/F10 support).
    .DESCRIPTION
        A single cheap `gh pr view <pr> --json body` round-trip, parsed the
        same way script:Invoke-CostBaselineHarvestReconcileCandidate parses its
        own body fetch. Used by script:Invoke-CostBaselineHarvestBodySummaryWrite
        to re-read the live body IMMEDIATELY before the write so a concurrent
        edit during the caller snapshot->write window is not clobbered.
        Returns $null on any failure (gh non-zero, empty/unparseable JSON) so
        the caller can fall back to its own snapshot rather than skipping the
        write. The [Console]::OutputEncoding UTF-8 pin established at the top
        of Invoke-CostBaselineHarvest already covers this `gh` call.
    .OUTPUTS
        [string] the live PR body, or $null on failure.
    #>
    param([Parameter(Mandatory)][int]$Pr)

    $liveJson = $null
    try { $liveJson = & gh pr view $Pr --json 'body' 2>$null } catch { return $null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($liveJson)) { return $null }

    $liveInfo = $null
    try { $liveInfo = ($liveJson | Out-String) | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $liveInfo) { return $null }

    return [string]$liveInfo.body
}

function script:Invoke-CostBaselineHarvestBodySummaryWrite {
    <#
    .SYNOPSIS
        Shared body-only cost_summary write wrapper for the s5
        refresh-on-promotion and reconcile paths (issue #489 s5).
    .DESCRIPTION
        Both callers write real (non-degraded) totals sourced from an
        already-gated composite comment or a fresh re-walk — never from the
        untrusted PR body (see this file other s5 functions'
        .DESCRIPTIONs for the trust boundary). This is the single place
        both paths call script:Update-FCLPrBodyCostSummary (the s3 writer)
        from, so the mandated one-line stderr audit record — naming the PR
        and the outcome (refreshed / reconciled / skipped-no-op /
        failed: {reason}) — is emitted exactly once per attempted write.

        Previews the transform via script:Set-FCLPrBodyCostSummary (pure,
        no I/O) SOLELY to classify the audit outcome. This is not a
        duplicate gate: script:Update-FCLPrBodyCostSummary is still always
        called when the preview shows a real change, and ITS OWN no-op
        guard (issue #489 s3) remains the one thing deciding whether the
        `gh pr edit` call actually fires — this function never
        short-circuits that decision differently than the writer would.

        Resets $global:LASTEXITCODE immediately before calling the writer
        (only on the non-no-op path) so the post-call check reflects THIS
        call `gh pr edit`, not a stale exit code left over from an
        earlier native command in the same loop iteration (the composite
        comment fetch, Find-OrUpsertComment) — the writer itself never
        surfaces gh exit code to its caller.

        Fail-open in both directions: any exception here — including one
        from a malformed CostSummary hashtable or a test double standing in
        for the writer — is caught and logged, never rethrown. This must
        never revert, block, or un-stamp a prior successful comment
        promotion, and must never surface an error at startup (stderr only).

        F1 (issue #489 post-review fix, judge-sustained): neither
        ConvertTo-CostBaselineHarvestSummaryFromRenderResult nor
        ConvertTo-CostBaselineHarvestSummaryFromSection ever populates
        source_comment, and script:Set-FCLPrBodyCostSummary does a full
        cost_summary subtree REPLACE, re-emitting source_comment only when
        the incoming CostSummary hashtable carries it — so an un-enriched
        write here silently erases an existing "full breakdown" link on
        every refresh/reconcile pass. Before the preview call, this function
        reads the LIVE PrBody EXISTING cost_summary.source_comment
        (via script:Get-CostBaselineHarvestBodySourceComment) and, when
        present and the caller-supplied CostSummary does not already carry
        the key, seeds it onto CostSummary. Enrichment happens BEFORE the
        preview so the no-op classification and the real write see the
        identical, already-enriched summary — enriching only before the
        real write (after the preview) would let the preview no-op
        decision diverge from what actually gets written. A $null
        CostSummary (the degraded-with-nothing-else-to-report case) is left
        untouched — this never fabricates a summary hashtable just to carry
        a link.
    #>
    param(
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrBody,
        [Parameter(Mandatory)][hashtable]$CostSummary,
        [Parameter(Mandatory)][ValidateSet('refreshed', 'reconciled')][string]$Outcome
    )

    try {
        # F2/F10 (issue #489 lite re-verification, judge-sustained): re-fetch
        # the live PR body IMMEDIATELY before the write. The caller $PrBody
        # snapshot was captured BEFORE a long Invoke-CostSessionRender re-walk
        # (refresh path: snapshot at the candidate gate, write after the
        # re-walk) or a composite-comment fetch (reconcile path), so a
        # concurrent human/automation PR-body edit during that window would be
        # silently clobbered by Update-FCLPrBodyCostSummary whole-body
        # `gh pr edit --body-file` replace. The comment-write path already has
        # a pre-write concurrency guard (Test-CostBaselineHarvestSectionStillCurrent);
        # this body-write path had none. Re-transform against the FRESH body
        # (option a — the summary still lands, and any concurrent edit
        # elsewhere in the body survives; matches frame-credit-ledger.ps1
        # Step 7 "re-fetch immediately before write" shape) rather than
        # aborting. Fail-open: if the re-fetch itself fails, fall back to the
        # caller snapshot rather than skipping the useful write.
        $writeBody = $PrBody
        $freshBody = script:Get-CostBaselineHarvestLivePrBody -Pr $Pr
        if ($null -ne $freshBody) { $writeBody = $freshBody }

        # F1 + F9 (issue #489, judge-sustained): preserve an existing "full
        # breakdown" link across the full-subtree cost_summary replace, but
        # ONLY when it validates as THIS repo comment URL for THIS PR
        # (F9 — the PR body is untrusted input; an author-controlled off-repo,
        # malformed, or wrong-PR link must not be re-emitted into the
        # trusted-looking cost_summary). An invalid link is dropped, exactly
        # like the "nothing to preserve" path. Read the source_comment from
        # the SAME fresh body the write targets, so what is preserved matches
        # what is written.
        $existingSourceComment = script:Get-CostBaselineHarvestBodySourceComment -PrBody $writeBody
        if (-not [string]::IsNullOrWhiteSpace($existingSourceComment) -and
            $null -ne $CostSummary -and
            -not $CostSummary.ContainsKey('source_comment') -and
            (script:Test-CostBaselineHarvestSourceCommentUrl -Url $existingSourceComment -Pr $Pr)) {
            $CostSummary['source_comment'] = $existingSourceComment
        }

        $preview = script:Set-FCLPrBodyCostSummary -PrBody $writeBody -Degraded $false -CostSummary $CostSummary
        if ($preview -eq $writeBody) {
            [Console]::Error.WriteLine("cost-baseline-harvest: PR body cost-summary write for #$Pr — skipped-no-op")
            return
        }

        # F2 (issue #489 post-review fix, judge-sustained): capture and
        # discard Update-FCLPrBodyCostSummary { Outcome = ... } return
        # value — mirrors frame-credit-ledger.ps1 identical sibling call
        # site. An uncaptured bare call here leaks the hashtable into this
        # wrapper implicit output, which propagates uncaptured through
        # every remaining call layer and corrupts Invoke-CostBaselineHarvest
        # documented single-hashtable `return $result` contract.
        $global:LASTEXITCODE = 0
        $null = script:Update-FCLPrBodyCostSummary -Pr $Pr -PrBody $writeBody -Degraded $false -CostSummary $CostSummary

        if ($global:LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("cost-baseline-harvest: PR body cost-summary write for #$Pr — failed: gh pr edit exited $global:LASTEXITCODE")
        }
        else {
            [Console]::Error.WriteLine("cost-baseline-harvest: PR body cost-summary write for #$Pr — $Outcome")
        }
    }
    catch {
        [Console]::Error.WriteLine("cost-baseline-harvest: PR body cost-summary write for #$Pr — failed: $($_.Exception.Message)")
    }
}

function script:Select-CostBaselineHarvestReconcileCandidates {
    <#
    .SYNOPSIS
        Filters already-fetched rolling-history entries down to the s5
        reconcile candidate class (issue #489 s5) — a SEPARATE, additive
        population from script:Select-CostBaselineHarvestCandidates' own
        promotion-eligibility filter. Does NOT call, modify, or otherwise
        touch that function.
    .DESCRIPTION
        script:Select-CostBaselineHarvestCandidates filters TO
        capture_point == 'pr-creation-mid-session' and excludes any entry
        already carrying a non-empty upgrade_attempted_at — so a PR whose
        comment was ALREADY promoted to end-of-session (in this run or a
        prior one) can never appear in that function output. This
        function is the deliberate mirror: it filters TO capture_point ==
        'end-of-session' and does not consult upgrade_attempted_at at all,
        since a promoted comment is exactly the population whose body may
        still be stale.

        This is a cheap, UNGATED shortlist only — cost-rolling-history.ps1
        applies no authorship check when it parses PR comments (unlike
        script:Get-CostBaselineHarvestCompositeComment below). It exists
        solely to avoid a `gh` call per merged PR in the horizon. The
        caller MUST still re-fetch and re-validate each shortlisted PR
        through the fail-closed script:Get-CostBaselineHarvestCompositeComment
        gate before trusting anything about it — never trust this
        shortlist capture_point or totals values directly.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object[]]$Entries,
        [Parameter(Mandatory)][int]$HorizonDays
    )

    $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-1 * $HorizonDays)
    $candidates = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry -or $entry -isnot [hashtable]) { continue }
        if ([string]$entry['capture_point'] -ne 'end-of-session') { continue }

        $generatedAtUtc = script:ConvertTo-CostBaselineHarvestUtcDate -Value $entry['generated_at']
        if ($null -eq $generatedAtUtc -or $generatedAtUtc -lt $cutoffUtc) { continue }

        if ($null -eq $entry['pr']) { continue }

        $candidates.Add($entry)
    }

    return , $candidates.ToArray()
}

function script:Invoke-CostBaselineHarvestReconcileCandidate {
    <#
    .SYNOPSIS
        Reconciles ONE shortlisted PR body against its own composite
        comment (issue #489 s5).
    .DESCRIPTION
        C9 (issue #489 post-review fix): fetches and checks the PR body
        own (advisory-only) staleness FIRST — a single cheap `gh pr view
        --json body` round-trip — before ever fetching the composite
        comment. The prior ordering paid the composite comment full
        authorship-gated `gh pr view --json comments` round-trip even when
        the body already agreed with the comment (nothing to reconcile),
        doubling the cost of the common already-current case for every
        candidate. The trust model is UNCHANGED: the write still only ever
        uses the composite comment fail-closed-gated data (re-fetched
        through the SAME authorship gate every other write path in this
        file uses — the rolling-history shortlist that selected this PR
        carries no such gate, see
        script:Select-CostBaselineHarvestReconcileCandidates), never the
        untrusted body values — the body is read only to decide
        WHETHER to fetch/act, both before and after this reorder. Only when
        the body looks stale, AND the gated section confirms capture_point:
        end-of-session, is a reconcile write attempted — reusing that SAME
        gated section already-computed totals. Spends no re-count
        budget: never calls Invoke-CostSessionRender. Fully fail-open: any
        failure along this path (gh call failure, unparseable JSON, no
        matching section) is a silent no-op, never a throw.

        Issue #489 CE Gate follow-up: -RollingHistoryEntries is optional —
        threaded straight through to script:ConvertTo-CostBaselineHarvestSummaryFromSection
        so the reconcile write can also populate rolling_baseline_usd from
        the SAME already-fetched rolling history the caller (script:Invoke-CostBaselineHarvestReconcilePass)
        already holds; never a second Get-CostRollingHistory fetch.
    #>
    param(
        [Parameter(Mandatory)][int]$Pr,
        [AllowNull()][object[]]$RollingHistoryEntries = $null,
        [AllowNull()][System.Diagnostics.Stopwatch]$Stopwatch = $null,
        [int]$TimeoutSeconds = 0
    )

    # F11: cooperative per-pass wall-clock budget check, evaluated before each
    # of this candidate `gh` calls (matching cost-rolling-history.ps1
    # between-call check granularity). When the pass budget is exhausted this
    # candidate is deferred to a later scan rather than starting more `gh`
    # work. A $null Stopwatch / non-positive TimeoutSeconds disables the check
    # (direct callers and tests that do not thread a budget).
    $isBudgetExhausted = {
        return ($null -ne $Stopwatch -and $TimeoutSeconds -gt 0 -and $Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds)
    }
    if (& $isBudgetExhausted) {
        [Console]::Error.WriteLine("cost-baseline-harvest: reconcile for #$Pr — deferred: pass wall-clock budget (${TimeoutSeconds}s) exhausted")
        return
    }

    $liveJson = $null
    try { $liveJson = & gh pr view $Pr --json 'body' 2>$null } catch { $liveJson = $null }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($liveJson)) {
        [Console]::Error.WriteLine("cost-baseline-harvest: reconcile for #$Pr — failed: gh pr view (body) failed")
        return
    }

    $liveInfo = $null
    try { $liveInfo = ($liveJson | Out-String) | ConvertFrom-Json -ErrorAction Stop } catch { $liveInfo = $null }
    if ($null -eq $liveInfo) {
        [Console]::Error.WriteLine("cost-baseline-harvest: reconcile for #$Pr — failed: unparseable gh pr view response")
        return
    }
    $liveBody = [string]$liveInfo.body

    if (-not (script:Test-CostBaselineHarvestBodySummaryStale -PrBody $liveBody)) { return }

    # F11: re-check the pass budget before the heavier authorship-gated
    # composite-comment fetch (`gh pr view --json comments`).
    if (& $isBudgetExhausted) {
        [Console]::Error.WriteLine("cost-baseline-harvest: reconcile for #$Pr — deferred: pass wall-clock budget (${TimeoutSeconds}s) exhausted")
        return
    }

    $fetchResult = script:Get-CostBaselineHarvestCompositeComment -Pr $Pr
    if ($null -eq $fetchResult -or -not $fetchResult['Found']) { return }

    $sectionMatch = [regex]::Match($fetchResult['Body'], $script:FCLCostPatternSectionRegex)
    if (-not $sectionMatch.Success) { return }

    $section = $sectionMatch.Groups['section'].Value
    if ((script:Get-FCLScalar -Block $section -Name 'capture_point') -ne 'end-of-session') { return }

    $costSummary = script:ConvertTo-CostBaselineHarvestSummaryFromSection -Section $section -Pr $Pr -RollingHistoryEntries $RollingHistoryEntries
    script:Invoke-CostBaselineHarvestBodySummaryWrite -Pr $Pr -PrBody $liveBody -CostSummary $costSummary -Outcome 'reconciled'
}

# F11 (issue #489 lite re-verification, judge-sustained): bound the reconcile
# pass so a large merge history or a stalled `gh` CLI cannot block session
# startup — the function documented bounded/fail-open contract.
#
# (a) Per-pass candidate CAP: a hard, deterministic upper bound on how many
#     candidates one pass processes. A reconcile is a cheap body-only write
#     (no expensive re-walk), so 5 lets a single startup catch up on a small
#     backlog of stale PR bodies while bounding the worst-case `gh`-call count
#     to a handful of candidates (each does up to 3 sequential `gh` calls).
#     Remaining candidates are left for a later startup scan.
# (b) Per-pass wall-clock BUDGET: a cooperative [Stopwatch] budget checked
#     before each candidate AND (threaded into the candidate) between that
#     candidate `gh` calls. This is the established gh-bounding
#     convention in this codebase — cost-rolling-history.ps1 and
#     phase-containment-rolling-history-core.ps1 both check a Stopwatch
#     between `gh` calls rather than hard-killing a single in-flight call
#     (no per-command hard-kill wrapper exists anywhere in this repo). It
#     bounds how much wall-clock the pass spends starting new `gh` work; a
#     single already-hung call is a pre-existing, repo-wide limitation of the
#     cooperative model, not introduced here. 20s matches the order of
#     magnitude of cost-rolling-history.ps1 single-pass fetch budget.
$script:CostBaselineHarvestReconcileMaxCandidatesPerPass = 5
$script:CostBaselineHarvestReconcilePassBudgetSeconds = 20

function script:Invoke-CostBaselineHarvestReconcilePass {
    <#
    .SYNOPSIS
        Runs the s5 reconcile candidate class over already-fetched
        rolling-history entries (issue #489 s5), bounded per F11.
    .DESCRIPTION
        Additive to the promotion path one-re-walk-per-call budget (it is a
        SEPARATE candidate class) but itself bounded by a per-pass candidate
        cap and a cooperative wall-clock budget (F11 — see the constants
        above). Each candidate is processed independently and fail-open, so
        one candidate failure never blocks another, and hitting the cap or
        the budget simply defers the remaining candidates to a later startup
        scan rather than throwing.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object[]]$Entries,
        [Parameter(Mandatory)][int]$HorizonDays
    )

    $reconcileCandidates = script:Select-CostBaselineHarvestReconcileCandidates -Entries $Entries -HorizonDays $HorizonDays

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $processed = 0
    foreach ($candidate in $reconcileCandidates) {
        if ($processed -ge $script:CostBaselineHarvestReconcileMaxCandidatesPerPass) {
            $deferred = @($reconcileCandidates).Count - $processed
            [Console]::Error.WriteLine("cost-baseline-harvest: reconcile pass hit per-pass cap ($script:CostBaselineHarvestReconcileMaxCandidatesPerPass); $deferred candidate(s) deferred to a later scan")
            break
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $script:CostBaselineHarvestReconcilePassBudgetSeconds) {
            [Console]::Error.WriteLine("cost-baseline-harvest: reconcile pass hit wall-clock budget ($($script:CostBaselineHarvestReconcilePassBudgetSeconds)s); remaining candidate(s) deferred to a later scan")
            break
        }

        $candidatePr = 0
        if (-not [int]::TryParse([string]$candidate['pr'], [ref]$candidatePr)) { continue }

        try {
            script:Invoke-CostBaselineHarvestReconcileCandidate -Pr $candidatePr -RollingHistoryEntries $Entries -Stopwatch $stopwatch -TimeoutSeconds $script:CostBaselineHarvestReconcilePassBudgetSeconds
        }
        catch {
            [Console]::Error.WriteLine("cost-baseline-harvest: reconcile for #$candidatePr — failed: $($_.Exception.Message)")
        }
        $processed++
    }
}

# ---------------------------------------------------------------------------
# Public function
# ---------------------------------------------------------------------------

function Invoke-CostBaselineHarvest {
    <#
    .SYNOPSIS
        Runs the bounded startup baseline-eligibility harvest (issue #824 s4).
    .DESCRIPTION
        1. Selects candidates from Get-CostRollingHistory already-fetched scan
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
           AND its TokenSum >= the persisted candidate ports-derived token
           sum. Otherwise — whether the re-walk produced real (non-empty)
           data that just did not qualify, or found nothing usable at all
           (issue #824 post-review fix M11) — the row is stamped
           `upgrade_attempted_at` (idempotently; a pre-existing stamp line is
           replaced, not duplicated — M8 part b) so it exits future scans
           instead of re-consuming the one-re-walk-per-startup budget
           forever.
        6. Refreshes the rolling-history cache after a successful promotion
           AND after a successful stamp write (issue #824 post-review fix
           M8 part a — a stamped candidate must not re-qualify within the
           cache TTL). Immediately before either write, re-confirms the
           composite comment still contains the exact section matched
           earlier; a changed section is treated as a failed write and
           skipped rather than risking a last-write-wins clobber of a
           concurrent change (issue #824 post-review fix M15).
        7. Refresh-on-promotion (issue #489 s5): after step 5 successfully
           promotes a candidate composite comment, mirrors that SAME
           re-walk upgraded totals into the candidate PR body (the s3
           cost_summary transform/writer), sourcing the body from the
           SAME `gh pr view` call step 3 already made — no extra
           round-trip. Fail-open in both directions: a failed body write
           never reverts, blocks, or un-stamps the comment promotion in
           step 5, and never surfaces an error at startup (stderr only).
        8. Reconcile pass (issue #489 s5): on every call, independent of
           steps 1-7 outcome, runs a SEPARATE, additive candidate class
           over PRs whose comment already reads capture_point:
           end-of-session (already promoted, possibly by a prior run) but
           whose body cost_summary.capture_point still reads a stale
           mid-session value, reads `unavailable` (the degraded-write
           case), or is missing entirely (a watchdog kill lost the very
           first write). Spends no re-count budget — reuses the comment
           own already-computed totals for a body-only write. The PR
           body capture_point value is read-only advisory input that
           decides whether to fire this reconcile; it is never treated as
           authoritative and never echoed back into the body.

        Every failure path is fail-open: this function never throws to its
        caller and never leaves a partial/corrupt write.
    .PARAMETER ParentCwd
        The current (harvesting) session parent cwd — used to resolve
        the local transcript-existence check in step 2, and passed through to
        Invoke-CostSessionRender in step 4.
    .PARAMETER RepoRoot
        The current session repo root — used for slug/identity
        resolution and passed through to Invoke-CostSessionRender.
    .PARAMETER Slug
        The current session cost-transcript slug. When omitted, resolved
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

    # C2 (issue #489 post-review fix), relocated from
    # script:Get-CostBaselineHarvestCompositeComment (originally M2, issue
    # #824 post-review fix): sets [Console]::OutputEncoding to UTF-8 — the
    # established repo-wide guard (see orchestra-spine.ps1:15) against
    # Windows silently decoding a `gh` child process UTF-8 stdout via the
    # OEM code page, which corrupts non-ASCII characters (—, ⚠, etc.) on
    # every write-back. Fires UNCONDITIONALLY here, before ANY
    # `gh`-invoking call anywhere in this function execution path —
    # scoping the pin to only the composite-comment fetcher regressed once
    # Test-CostBaselineHarvestCandidateGate combined `gh pr view`
    # fetch and the s5 reconcile pass direct `gh pr view` calls could
    # both run before the composite-comment fetcher ever fired in the same
    # process (most commonly: the reconcile pass runs first and finds zero
    # candidates, then the promotion-gate fetch runs unpinned).
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

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

        # s5: additive reconcile pass — always runs when there are entries at
        # all, independent of the promotion outcome below (it is a SEPARATE
        # candidate class, not another slot in the one-re-walk-per-call
        # budget), and is itself fully fail-open — see
        # script:Invoke-CostBaselineHarvestReconcilePass.
        try {
            script:Invoke-CostBaselineHarvestReconcilePass -Entries $entries -HorizonDays $HorizonDays
        }
        catch {
            [Console]::Error.WriteLine("cost-baseline-harvest: reconcile pass failed (fail-open, no-op): $($_.Exception.Message)")
        }

        $candidates = script:Select-CostBaselineHarvestCandidates -Entries $entries -HorizonDays $HorizonDays
        if ($candidates.Count -eq 0) { return $result }

        foreach ($candidate in $candidates) {
            $candidatePr = 0
            if (-not [int]::TryParse([string]$candidate['pr'], [ref]$candidatePr)) { continue }

            # Verify-then-select (M14) + untrusted read-back (M16) — see
            # script:Test-CostBaselineHarvestCandidateGate docstring.
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
            $liveBody = $gate['LiveBody']

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
                # Get-CostRollingHistory one-entry-per-block-bearing-body scan).
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

                    # s5: refresh-on-promotion — mirror the upgraded totals
                    # into the PR body via the shared writer wrapper. Wrapped
                    # separately (not relying on the outer function-level
                    # catch) so an unexpected failure here can NEVER revert
                    # $result.Promoted back to $false or un-stamp the
                    # comment promotion that already succeeded above.
                    try {
                        $costSummary = script:ConvertTo-CostBaselineHarvestSummaryFromRenderResult -RenderResult $renderResult -Pr $candidatePr -RollingHistoryEntries $entries
                        script:Invoke-CostBaselineHarvestBodySummaryWrite -Pr $candidatePr -PrBody $liveBody -CostSummary $costSummary -Outcome 'refreshed'
                    }
                    catch {
                        [Console]::Error.WriteLine("cost-baseline-harvest: PR body refresh for #$candidatePr — failed: $($_.Exception.Message)")
                    }
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
        candidate loop — that function, and the rest of Invoke-CostBaselineHarvest
        own promote/stamp machinery, are untouched by this function. This is a
        standalone entry point for a single, maintainer-named PR:

          1. Resolves the PR REAL head ref via a fresh `gh pr view
             --json state,headRefName,body,createdAt,mergedAt` — never the
             persisted block `branch:` field, which the CI-written
             targets carry as the literal string `HEAD` (M2/M15, empirically
             confirmed on #814/#815) — and confirms the PR is genuinely
             MERGED before acting. The same call also fetches `createdAt`/
             `mergedAt` (no extra API call) for step 3 corroboration
             window.
          2. Fetches the composite `<!-- frame-credit-ledger-$Pr -->` comment
             (script:Get-CostBaselineHarvestCompositeComment — same
             fail-closed authorship gate Invoke-CostBaselineHarvest uses) and
             locates its Cost Pattern section. Only proceeds when the
             persisted section reads `session_completeness: unknown` — this
             function repairs exactly that degraded shape; a populated block
             is left untouched (it is not this function job to re-render an
             already-populated session).
          3. Re-walks via Invoke-CostSessionRender with
             -AdmitCorroboratedFallback ON for this call only — turns on the
             s1 Tier-2 corroborated-fallback trust ladder (cost-walker.ps1)
             for this one targeted repair; the live PR-creation path never
             sets this (M10). -CorroborationWindowStart/-End are passed as
             this PR `createdAt`/`mergedAt` (issue #825 s3 post-review
             fix, M8 wiring gap) — without this, Tier-2 admission ran
             unbounded on the one path that actually ships in this issue
             (the automatic-drain path where this would also matter is
             deferred to #841), leaving the M8 same-repo reused-branch-name
             collision guard inert. An unparseable timestamp degrades that
             one bound to $null (unenforced) rather than blocking the repair
             — matching the walker "a $null bound is not enforced"
             contract.
          4. Acceptance = populated-beats-empty-unknown: the composite
             comment Cost Pattern section is section-spliced (never a
             full-body replace, never a new sibling comment) with the
             re-walk rendered section — which already carries its own
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
        This (repairing) session parent cwd — the machine performing
        the repair must hold the target PR transcripts. Passed through to
        Invoke-CostSessionRender.
    .PARAMETER RepoRoot
        This session repo root — used for slug/identity resolution and
        passed through to Invoke-CostSessionRender.
    .PARAMETER Slug
        This session cost-transcript slug. Resolved from RepoRoot via
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
        # round-trip) for step 3 M8 corroboration-window bound.
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

        # M8 corroboration-window bound (issue #825 s3/s4 post-review fix, C4): the PR
        # own first-branch-appearance -> merge lifetime. "First branch appearance" is the
        # earliest commit authoredDate, NOT the PR createdAt — createdAt only reflects
        # when the PR object itself was opened on GitHub, which can trail the branch real
        # start by the bulk of a multi-day session (the #814 flagship case: session ran
        # 2026-07-04T16:20Z, PR was not opened until 2026-07-06T05:12Z near the very end).
        # Using createdAt as the window start would silently exclude nearly all real
        # activity from corroboration. Falls back to createdAt only when the commits list
        # is empty or unparseable. An unparseable/absent timestamp still degrades that one
        # bound to $null (unenforced), matching the walker "a $null bound is not
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

        # 2. Locate the composite comment Cost Pattern section; only act on a
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
        # degraded silently to an UNENFORCED window (the walker "a $null bound
        # is not enforced" contract) — this repair path must never proceed with an
        # unenforced corroboration window, since an unenforced window is exactly what
        # lets a same-repo reused-branch collision outside this PR real lifetime
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
        # bounded to this PR createdAt->mergedAt window (M8 wiring gap fix).
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

        # Data-loss guard (issue #825 CE Gate): Invoke-CostSessionRender step-6g
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

        # M15-style cheap concurrency mitigation, reused from the harvest
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
