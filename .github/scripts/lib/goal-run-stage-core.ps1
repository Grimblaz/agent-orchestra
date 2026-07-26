#Requires -Version 7.0
<#
.SYNOPSIS
    Stage-machine, mutex, crash-atomicity, and loop->chain seam primitives
    for the goal-run harness (issue #874, plan step 4, AC1 command + stage-
    machine half).
.DESCRIPTION
    Deterministic mechanics ONLY -- the orchestration PROSE that tells a
    Claude session what to do and in what order lives in
    agents/Goal-Run.agent.md. This file owns the testable decision logic
    that prose calls into, mirroring the split already established by
    goal-run-halt-core.ps1 (schema-validating emit primitive) and
    goal-run-worktree-core.ps1 (provision/teardown primitive).

    Sections, in file order:

      1. Stage vocabulary + resume precedence (pure)
         $script:GoalRunStageOrder, Resolve-GoalRunResumeStage

      2. Chain-stage marker body build/parse (pure) + gh-backed read/write
         New-GoalRunStageMarkerBody, ConvertFrom-GoalRunStageMarkerBody,
         Get-GoalRunStageMarker, Set-GoalRunStageMarker

      3. Mutex (M8): marker-first-then-provision ordering + reconcile
         New-GoalRunInflightMarkerBody, ConvertFrom-GoalRunInflightMarkerBody,
         Get-GoalRunIssueComments, New-GoalRunIssueComment,
         New-GoalRunInflightMarker, Get-GoalRunInflightMarkers,
         Set-GoalRunInflightMarkerResolved,
         Set-GoalRunInflightMarkerAdopted (#912 step 4: mutate-and-verify
         adoption primitive),
         Resolve-GoalRunInflightMutexOutcome (pure tiebreak),
         Resolve-GoalRunInflightMarkerForResolution (#912 step 4: re-fetch
         helper for later resolution sites, lowest-unresolved-comment-id
         selection),
         Invoke-GoalRunMutexLaunch (orchestrates the above)

      4. Crash-atomicity + second-invocation triage
         Test-GoalRunInflightAppearsDead (pure),
         Resolve-GoalRunInvocationAction (pure)

      5. Control-return-then-read (M13): bounded retry then a distinct
         diagnostic halt
         Invoke-GoalRunAwaitStatusVerdict, Resolve-GoalRunControlReturn

      6. Loop->chain seam (M16) + terminal-emissions seam (step 6)
         New-GoalRunExecutorSessionHandle, Invoke-GoalRunLaunchChain,
         Test-GoalRunTerminalEmissionsVerified

      7. Operator-initiated restart (#912 D6, step 5): capture-then-clear
         New-GoalRunRestartReportBody, ConvertFrom-GoalRunRestartReportBody,
         Clear-GoalRunStageMarker (the first comment-DELETE primitive in
         this codebase -- no clear/remove primitive existed before this
         step), Clear-GoalRunActiveState, Invoke-GoalRunRestart
         (orchestrates the liveness gate then capture-before-clear)

    Chain-stage marker vocabulary (new in this step -- no earlier #874 step
    defined it): a single `<!-- goal-run-stage-{Issue} -->` comment, upserted
    in place (never appended-to), always reflecting the LATEST completed
    top-level stage: pre-loop | loop-launched | loop-released |
    chain-dispatched. This is deliberately the minimal top-level enum the
    resumer switches on -- NOT the finer-grained chain-internal markers
    later #874 steps (s5-s7) will add. Full per-attempt history (why a run
    deviated, what it checkpointed) lives in the typed run log and the
    goal-run-inflight marker, not here.

    Halt-reason enum note (M13): skills/goal-run/schemas/goal-halt-report.schema.json
    is a CLOSED five-value halt_reason enum (unachievable-target,
    invariant-conflict, budget-exhausted, gate-input-needed,
    chain-stage-failure) inherited verbatim from the goal-contract schema.
    There is no sixth enum value available for a "verdict-not-flushed"
    condition. Resolve-GoalRunControlReturn therefore still emits
    halt_reason: 'chain-stage-failure' (the semantically closest bucket --
    a stalled loop->chain transition IS a chain-stage failure) but makes
    the failure mode diagnosable via evidence[]/plan_remediation text that
    names the exact condition ("goal_status verdict did not appear in
    transcript within N retries after loop completion") rather than a
    generic "chain failed" string -- satisfying the requirement contract
    "not silently folded into a generic bucket" instruction within the
    schema closed-enum constraint.
#>

. (Join-Path $PSScriptRoot 'goal-run-status-core.ps1')
. (Join-Path $PSScriptRoot 'goal-run-halt-core.ps1')
. (Join-Path $PSScriptRoot 'goal-run-worktree-core.ps1')

# ---------------------------------------------------------------------------
# 1. Stage vocabulary + resume precedence
# ---------------------------------------------------------------------------

$script:GoalRunStageOrder = @('pre-loop', 'loop-launched', 'loop-released', 'chain-dispatched')

function Resolve-GoalRunResumeStage {
    <#
    .SYNOPSIS
        Pure state-detection precedence: given the durable artifacts a
        /goal-run invocation can observe, returns the first incomplete
        stage to resume at.
    .DESCRIPTION
        Precedence (highest wins, mirrors the requirement contract
        "durable state it reads, in stage order"):
          1. -ContractHashVerified = $false -> 'blocked' (cannot run at all)
          2. -TerminalEmissionsVerified = $true -> 'complete'
          3. -ExplicitStageMarker (the goal-run-stage-{Issue} marker
             latest recorded value) -- authoritative when present
          4. -RunLogHasCheckpoint -- a checkpoint/deviation/experience-
             observation entry proves the loop ran even without an
             explicit stage marker (e.g. a crash between loop-launch and
             the next marker write)
          5. -ActiveStatePresent -- goal-run-active.json exists, so the
             worktree was provisioned but the loop was never launched
          6. -InflightMarkerPresent -- a mutex marker was posted but
             nothing was provisioned yet (crash mid pre-loop)
          7. Nothing present -> 'pre-loop' (fresh launch)
    .OUTPUTS
        [pscustomobject]@{ ResumeStage; Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool]$ContractHashVerified,
        [bool]$InflightMarkerPresent = $false,
        [bool]$ActiveStatePresent = $false,
        [bool]$RunLogHasCheckpoint = $false,
        [ValidateSet('loop-launched', 'loop-released', 'chain-dispatched', $null)]
        [string]$ExplicitStageMarker = $null,
        [bool]$TerminalEmissionsVerified = $false
    )

    if (-not $ContractHashVerified) {
        return [pscustomobject]@{ ResumeStage = 'blocked'; Reason = 'contract-hash-unverified' }
    }
    if ($TerminalEmissionsVerified) {
        return [pscustomobject]@{ ResumeStage = 'complete'; Reason = 'terminal-emissions-verified' }
    }
    if ($ExplicitStageMarker -eq 'chain-dispatched') {
        return [pscustomobject]@{ ResumeStage = 'chain-dispatched'; Reason = 'awaiting-terminal-emissions' }
    }
    if ($ExplicitStageMarker -eq 'loop-released') {
        return [pscustomobject]@{ ResumeStage = 'chain-dispatched'; Reason = 'loop-released-chain-not-dispatched' }
    }
    if ($ExplicitStageMarker -eq 'loop-launched') {
        return [pscustomobject]@{ ResumeStage = 'loop-interrupted'; Reason = 'loop-launched-awaiting-release' }
    }
    if ($RunLogHasCheckpoint) {
        return [pscustomobject]@{ ResumeStage = 'loop-interrupted'; Reason = 'run-log-implies-loop-launched-no-explicit-marker' }
    }
    if ($ActiveStatePresent) {
        return [pscustomobject]@{ ResumeStage = 'loop-launched'; Reason = 'worktree-provisioned-loop-not-launched' }
    }
    if ($InflightMarkerPresent) {
        return [pscustomobject]@{ ResumeStage = 'pre-loop'; Reason = 'marker-posted-not-provisioned' }
    }
    return [pscustomobject]@{ ResumeStage = 'pre-loop'; Reason = 'fresh-launch' }
}

# ---------------------------------------------------------------------------
# 2. Chain-stage marker: build/parse (pure) + gh-backed read/write
# ---------------------------------------------------------------------------

function New-GoalRunStageMarkerBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        # M17 fix: 'pre-loop' is deliberately EXCLUDED from this writer own
        # allowed set -- the Goal-Run.agent.md pre-loop stage-machine section
        # already documents that pre-loop is the implicit starting state
        # and no marker is ever posted for it on its own (Set-GoalRunStageMarker
        # is first called once the loop actually launches). Dropping it here
        # (rather than adding it to the reader ExplicitStageMarker
        # ValidateSet in Resolve-GoalRunResumeStage) reconciles the two
        # ValidateSets against the vocabulary that is actually ever written,
        # touching less surrounding logic than adding a new resume branch.
        [Parameter(Mandatory)][ValidateSet('loop-launched', 'loop-released', 'chain-dispatched')]
        [string]$Stage,
        [Parameter(Mandatory)][string]$ContractHash,
        [Parameter(Mandatory)][string]$UpdatedAt,
        # M10 fix: the provisioned worktree path, so a resuming invocation
        # can read it directly from this durable marker instead of an
        # undefined "most recent worktree" filesystem glob. Optional so a
        # caller that genuinely does not have a worktree path yet (there is
        # none -- every stage this marker is ever written for happens after
        # provisioning) is not forced to pass an empty placeholder string.
        [string]$WorktreePath
    )

    $lines = @(
        "<!-- goal-run-stage-$Issue -->",
        '## Goal-run stage marker',
        '',
        '- **schema_version**: 1',
        "- **issue**: $Issue",
        "- **stage**: $Stage",
        "- **contract_hash**: $ContractHash",
        "- **updated_at**: $UpdatedAt"
    )
    if ($WorktreePath) {
        $lines += "- **worktree_path**: $WorktreePath"
    }
    return ($lines -join "`n")
}

function ConvertFrom-GoalRunStageMarkerBody {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    if ($Body -notmatch '<!-- goal-run-stage-(\d+) -->') {
        return [pscustomobject]@{ Parsed = $false; Issue = $null; Stage = $null; ContractHash = $null; UpdatedAt = $null; WorktreePath = $null }
    }

    $issue = [int]$Matches[1]
    $stage = if ($Body -match '(?m)^-\s+\*\*stage\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $contractHash = if ($Body -match '(?m)^-\s+\*\*contract_hash\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $updatedAt = if ($Body -match '(?m)^-\s+\*\*updated_at\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    # M10 fix: optional worktree_path field -- absent on any marker written
    # before this fix, or by a caller that genuinely had none.
    $worktreePath = if ($Body -match '(?m)^-\s+\*\*worktree_path\*\*:\s*(.+)$') { $Matches[1].Trim() } else { $null }

    return [pscustomobject]@{ Parsed = $true; Issue = $issue; Stage = $stage; ContractHash = $contractHash; UpdatedAt = $updatedAt; WorktreePath = $worktreePath }
}

function Get-GoalRunIssueComments {
    <#
    .SYNOPSIS
        Paginated issue-comments reader for every mutex/stage/inflight
        marker lookup in this file. Fail-open: returns an empty array
        (never throws) on any gh/parse failure.
    .DESCRIPTION
        M19 fix: `gh issue view --json comments` -- the call this function
        used before this fix -- caps at the first 100 comments (a known
        gh/GraphQL page-size limit; this repo own established gotcha class,
        see frame-credit-ledger-core.ps1 own Get-IssueComments for the prior
        fix of the exact same bug shape, issue #794 Bug 1). On a comment-
        heavy goal-run issue, a mutex/stage/inflight marker posted past
        comment 100 would silently vanish from every reader built on this
        function. `gh issue view --json comments --paginate` is not valid
        (--paginate is a `gh api`-only flag), so the default path here
        switches to `gh api repos/{owner}/{repo}/issues/{Issue}/comments
        --paginate --slurp`, which walks every page and returns an array-
        of-page-arrays that this function flattens -- mirroring the
        exemplar at frame-credit-ledger-core.ps1 lines ~2739-2757.

        The REST shape differs from the GraphQL shape `gh issue view --json
        comments` used to return (`html_url` vs `url`; a real numeric `id`
        instead of a GraphQL node-id string) -- every comment is normalized
        to the same `{ id; url; body }` shape this file own callers
        (Get-GoalRunStageMarker, Get-GoalRunInflightMarkers) already expect,
        so neither needed to change.

        `gh api` requires an explicit owner/repo in the URL path (unlike
        `gh issue view`, which infers the ambient repo without -R); when
        -Owner/-Repo are not supplied, this resolves them via `gh repo
        view` first and a `git remote get-url origin` parse as a fallback,
        mirroring emit-pipeline-metrics-v4-core.ps1 own Resolve-EmitV4Repo.
    .PARAMETER CommentsReader
        Injectable for testability -- defaults to the real paginated-gh
        implementation described above. A test-supplied scriptblock returns
        the already-flattened, already-normalized comment array directly
        (receiving $Issue, $Owner, $Repo, $GhCliPath), mirroring the
        -PrReader convention Test-GoalRunPrEmissionsVerified already uses,
        so tests never need gh on PATH or a live network call.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Owner,
        [string]$Repo,
        [string]$GhCliPath = 'gh',
        [scriptblock]$CommentsReader
    )

    if ($CommentsReader) {
        return @(& $CommentsReader $Issue $Owner $Repo $GhCliPath)
    }

    $ownerRepo = $null
    if ($Owner -and $Repo) {
        $ownerRepo = "$Owner/$Repo"
    }
    else {
        try {
            $viewed = & $GhCliPath repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($viewed)) {
                $ownerRepo = $viewed.Trim()
            }
        }
        catch {
            # Falls through to the git-remote parse below.
        }
        if (-not $ownerRepo) {
            try {
                $remoteUrl = git remote get-url origin 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteUrl)) {
                    $match = [regex]::Match($remoteUrl, 'github\.com[:/](.+?)(?:\.git)?/?$')
                    if ($match.Success) { $ownerRepo = $match.Groups[1].Value.Trim() }
                }
            }
            catch {
                # No fallback left -- reported below via the empty-array return.
            }
        }
    }

    if (-not $ownerRepo) {
        [Console]::Error.WriteLine("Get-GoalRunIssueComments: could not resolve owner/repo for issue $Issue")
        return @()
    }

    $raw = & $GhCliPath api "repos/$ownerRepo/issues/$Issue/comments" --paginate --slurp 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Get-GoalRunIssueComments: gh api repos/$ownerRepo/issues/$Issue/comments failed (exit $LASTEXITCODE)")
        return @()
    }
    if (-not $raw) { return @() }

    try {
        $pages = $raw | ConvertFrom-Json -ErrorAction Stop
        # --paginate --slurp returns an array-of-page-arrays; flatten it into
        # a flat array of comment objects before normalizing (mirroring
        # frame-credit-ledger-core.ps1 own flatten step).
        $flat = if ($pages -is [array] -and $pages.Count -gt 0 -and $pages[0] -is [array]) {
            @($pages | ForEach-Object { $_ })
        }
        else {
            @($pages)
        }
        return @($flat | ForEach-Object {
                [pscustomobject]@{
                    id        = $_.id
                    url       = $_.html_url
                    body      = $_.body
                    # #912 s7: the REST comment payload already carries
                    # created_at/updated_at -- surfaced here (additive field,
                    # existing callers only read id/url/body) so the
                    # exhaustion-halt recency guard in
                    # Resolve-GoalRunControlReturn can discriminate an
                    # existing halt-report comment's age without a second
                    # gh round-trip or a new schema field on the report body
                    # itself (the schema is closed; see
                    # goal-run-halt-core.ps1).
                    updatedAt = $_.updated_at
                }
            })
    }
    catch {
        [Console]::Error.WriteLine("Get-GoalRunIssueComments: failed to parse comments JSON: $($_.Exception.Message)")
    }
    return @()
}

function Get-GoalRunStageMarker {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Owner,
        [string]$Repo
    )

    $marker = "<!-- goal-run-stage-$Issue -->"
    $comments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $matched = @($comments | Where-Object { $_.body -and ($_.body -like "*$marker*") })
    if ($matched.Count -eq 0) {
        return [pscustomobject]@{ Found = $false; Stage = $null; ContractHash = $null; UpdatedAt = $null; WorktreePath = $null }
    }

    # This marker is always upserted in place (Set-GoalRunStageMarker below
    # uses Find-OrUpsertComment), so at most one live comment should ever
    # match -- Select-Object -Last defends against a legacy duplicate.
    $latest = $matched | Select-Object -Last 1
    $parsed = ConvertFrom-GoalRunStageMarkerBody -Body $latest.body
    return [pscustomobject]@{ Found = $parsed.Parsed; Stage = $parsed.Stage; ContractHash = $parsed.ContractHash; UpdatedAt = $parsed.UpdatedAt; WorktreePath = $parsed.WorktreePath }
}

function Set-GoalRunStageMarker {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        # M17 fix: see the matching ValidateSet comment on
        # New-GoalRunStageMarkerBody above -- 'pre-loop' is deliberately
        # excluded here too, for the same reason.
        [Parameter(Mandatory)][ValidateSet('loop-launched', 'loop-released', 'chain-dispatched')]
        [string]$Stage,
        [Parameter(Mandatory)][string]$ContractHash,
        # M10 fix: threaded through to New-GoalRunStageMarkerBody so a
        # resuming invocation can read the worktree path back from this
        # marker directly.
        [string]$WorktreePath,
        [string]$Owner,
        [string]$Repo
    )

    # Dot-sourced lazily -- mirrors the goal-run-halt-core.ps1
    # Invoke-GoalRunHaltEmit convention -- so pure-decision callers/tests in
    # this file never need the comment-posting lib loaded.
    . (Join-Path $PSScriptRoot 'find-or-upsert-comment.ps1')

    $marker = "<!-- goal-run-stage-$Issue -->"
    $updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $body = New-GoalRunStageMarkerBody -Issue $Issue -Stage $Stage -ContractHash $ContractHash -UpdatedAt $updatedAt -WorktreePath $WorktreePath

    $upsertParams = @{ Type = 'issue'; Number = $Issue; Marker = $marker; Body = $body }
    if ($Owner -and $Repo) {
        $upsertParams.Owner = $Owner
        $upsertParams.Repo = $Repo
    }

    $url = Find-OrUpsertComment @upsertParams
    return [pscustomobject]@{ Success = [bool]$url; Url = $url; Stage = $Stage; UpdatedAt = $updatedAt; WorktreePath = $WorktreePath }
}

# ---------------------------------------------------------------------------
# 3. Mutex (M8): marker-first-then-provision ordering + reconcile
# ---------------------------------------------------------------------------

function New-GoalRunInflightMarkerBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$ContractHash,
        [Parameter(Mandatory)][string]$LaunchedAt,
        # #912 step 4: 'adopted' is a distinct status value from both
        # 'unresolved' and 'resolved' -- the mutation an adoption performs
        # (see Set-GoalRunInflightMarkerAdopted below) transitions to this
        # value rather than reusing 'resolved', so a body diff/status read
        # can tell "adopted, run in progress under a new session" apart
        # from "resolved, marker withdrawn/completed".
        [ValidateSet('unresolved', 'resolved', 'adopted')][string]$Status = 'unresolved',
        [string]$ResolvedReason,
        # #912 step 4: the owner/session field an adoption mutation stamps
        # onto the body. Only meaningful when -Status 'adopted'; a caller
        # building an 'unresolved' or 'resolved' body has no reason to pass
        # it.
        [string]$AdoptedBySessionId
    )

    $lines = @(
        "<!-- goal-run-inflight-$Issue -->",
        '## Goal-run in-flight marker',
        '',
        '- **schema_version**: 1',
        "- **issue**: $Issue",
        "- **status**: $Status",
        "- **contract_hash**: $ContractHash",
        "- **launched_at**: $LaunchedAt"
    )
    if ($ResolvedReason) {
        $lines += "- **resolved_reason**: $ResolvedReason"
    }
    if ($AdoptedBySessionId) {
        $lines += "- **adopted_by_session_id**: $AdoptedBySessionId"
    }
    return ($lines -join "`n")
}

function ConvertFrom-GoalRunInflightMarkerBody {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    if ($Body -notmatch '<!-- goal-run-inflight-(\d+) -->') {
        return [pscustomobject]@{ Parsed = $false; Issue = $null; Status = $null; ContractHash = $null; LaunchedAt = $null; ResolvedReason = $null; AdoptedBySessionId = $null }
    }

    $issue = [int]$Matches[1]
    $status = if ($Body -match '(?m)^-\s+\*\*status\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $contractHash = if ($Body -match '(?m)^-\s+\*\*contract_hash\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $launchedAt = if ($Body -match '(?m)^-\s+\*\*launched_at\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $resolvedReason = if ($Body -match '(?m)^-\s+\*\*resolved_reason\*\*:\s*(.+)$') { $Matches[1].Trim() } else { $null }
    # #912 step 4: optional owner/session field an adoption mutation stamps
    # onto the body -- absent on any marker never adopted.
    $adoptedBySessionId = if ($Body -match '(?m)^-\s+\*\*adopted_by_session_id\*\*:\s*(\S+)') { $Matches[1] } else { $null }

    return [pscustomobject]@{ Parsed = $true; Issue = $issue; Status = $status; ContractHash = $contractHash; LaunchedAt = $launchedAt; ResolvedReason = $resolvedReason; AdoptedBySessionId = $adoptedBySessionId }
}

function New-GoalRunIssueComment {
    <#
    .SYNOPSIS
        Always posts a NEW comment (never upserts). Required for the mutex
        race: two concurrent /goal-run invocations must each get their own
        comment id so the reconcile step below can tell them apart.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$Body,
        [string]$Owner,
        [string]$Repo
    )

    $postArgs = @('issue', 'comment', $Issue, '--body', $Body)
    if ($Owner -and $Repo) { $postArgs += @('-R', "$Owner/$Repo") }
    $output = & gh @postArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("New-GoalRunIssueComment: gh issue comment failed (exit $LASTEXITCODE)")
        return [pscustomobject]@{ Success = $false; CommentId = $null; Url = $null }
    }

    $url = ($output | Out-String).Trim()
    $commentId = $null
    if ($url -match '#issuecomment-(\d+)$') { $commentId = [long]$Matches[1] }
    return [pscustomobject]@{ Success = $true; CommentId = $commentId; Url = $url }
}

function New-GoalRunInflightMarker {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$ContractHash,
        [string]$Owner,
        [string]$Repo
    )

    $launchedAt = (Get-Date).ToUniversalTime().ToString('o')
    $body = New-GoalRunInflightMarkerBody -Issue $Issue -ContractHash $ContractHash -LaunchedAt $launchedAt -Status 'unresolved'
    $post = New-GoalRunIssueComment -Issue $Issue -Body $body -Owner $Owner -Repo $Repo

    return [pscustomobject]@{
        Success    = $post.Success
        CommentId  = $post.CommentId
        Url        = $post.Url
        LaunchedAt = $launchedAt
    }
}

function Get-GoalRunInflightMarkers {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Owner,
        [string]$Repo
    )

    $marker = "<!-- goal-run-inflight-$Issue -->"
    $comments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $matched = @($comments | Where-Object { $_.body -and ($_.body -like "*$marker*") })

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($c in $matched) {
        $commentId = $null
        if ($c.url -and ($c.url -match '#issuecomment-(\d+)$')) { $commentId = [long]$Matches[1] }
        elseif ($c.id) { try { $commentId = [long]$c.id } catch { $commentId = $null } }

        $parsed = ConvertFrom-GoalRunInflightMarkerBody -Body $c.body
        $results.Add([pscustomobject]@{
                CommentId          = $commentId
                Status             = $parsed.Status
                ContractHash       = $parsed.ContractHash
                LaunchedAt         = $parsed.LaunchedAt
                ResolvedReason     = $parsed.ResolvedReason
                # #912 step 4: carried through for symmetry with the other
                # ConvertFrom-GoalRunInflightMarkerBody fields -- not yet
                # consumed by any reader in this file.
                AdoptedBySessionId = $parsed.AdoptedBySessionId
            }) | Out-Null
    }
    return $results.ToArray()
}

function Set-GoalRunInflightMarkerResolved {
    <#
    .SYNOPSIS
        M12 fix: -Owner/-Repo are now optional. When omitted, the PATCH
        path uses the gh api own {owner}/{repo} template placeholders, which
        gh resolves from the ambient repo context the same way
        New-GoalRunIssueComment already falls back to ambient `gh` context
        when -Owner/-Repo are not supplied for posting.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$ContractHash,
        [Parameter(Mandatory)][string]$LaunchedAt,
        [string]$ResolvedReason = 'yielded-to-lower-comment-id',
        [string]$Owner,
        [string]$Repo
    )

    $body = New-GoalRunInflightMarkerBody -Issue $Issue -ContractHash $ContractHash -LaunchedAt $LaunchedAt -Status 'resolved' -ResolvedReason $ResolvedReason
    $ownerSegment = if ($Owner) { $Owner } else { '{owner}' }
    $repoSegment = if ($Repo) { $Repo } else { '{repo}' }
    $patchPath = "repos/$ownerSegment/$repoSegment/issues/comments/$CommentId"

    $tempFile = $null
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $payload = @{ body = $body } | ConvertTo-Json -Depth 4 -Compress
        Set-Content -LiteralPath $tempFile -Value $payload -Encoding UTF8 -NoNewline
        & gh api -X PATCH $patchPath --input $tempFile 2>$null | Out-Null
    }
    finally {
        if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Set-GoalRunInflightMarkerResolved: gh api PATCH $patchPath failed (exit $LASTEXITCODE)")
        return $false
    }
    return $true
}

function script:Find-GRSInflightMarkerCommentById {
    <#
    .SYNOPSIS
        Private helper: finds the single comment matching -TargetCommentId
        in an already-fetched Get-GoalRunIssueComments result set, by
        either the normalized numeric `id` field or the `#issuecomment-N`
        suffix on `url`. Shared by Set-GoalRunInflightMarkerAdopted's
        pre-check and verification reads so both use the same match logic.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]$Comments,
        [Parameter(Mandatory)][long]$TargetCommentId
    )
    return @($Comments) | Where-Object {
        ($_.id -and ([long]$_.id -eq $TargetCommentId)) -or
        ($_.url -and ($_.url -match "#issuecomment-$TargetCommentId$"))
    } | Select-Object -First 1
}

function Set-GoalRunInflightMarkerAdopted {
    <#
    .SYNOPSIS
        #912 D2/D5 (step 4): adopts an inflight marker -- PATCHes the
        existing goal-run-inflight-{Issue} comment identified by
        -CommentId to status = 'adopted' plus an owner/session field
        (-SessionId), then performs a verification read to confirm the
        mutation actually landed, rather than trusting the PATCH call's
        exit code alone.
    .DESCRIPTION
        Set-GoalRunInflightMarkerResolved (above) PATCHes with no ETag or
        If-Match, and an adopted marker keeps the SAME comment id it had
        while unresolved -- there is no new artifact a second invocation
        could use to distinguish "already adopted" from "still
        unresolved". Without an OBSERVABLE body mutation, the
        post-adoption body could be byte-identical to the pre-adoption
        body in every field a second reader inspects, and that second
        invocation would go on to adopt the same marker. This function
        makes the mutation observable two ways: (1) the status field
        transitions from 'unresolved' to the distinct value 'adopted'
        (never reusing 'resolved', which means something different --
        withdrawn/completed, not "run in progress under a new session");
        and (2) an owner/session field (-SessionId) is stamped onto the
        body. It then re-fetches the same comment via
        Get-GoalRunIssueComments and confirms the returned body actually
        differs from the pre-adoption body and parses back to status =
        'adopted' with the same SessionId.

        Concurrent-adoption guard: before mutating, this function reads
        the CURRENT live body of -CommentId. Two invocations can race to
        adopt the same still-unresolved marker; without this pre-check
        both would PATCH the same comment id and the second PATCH would
        silently clobber the first adopter's SessionId (same
        no-ETag/If-Match gap Set-GoalRunInflightMarkerResolved already
        has). When the live body already parses to status = 'adopted',
        this function refuses outright (Reason = 'already-adopted')
        instead of re-PATCHing over an existing adoption.

        NOTE (forensics-only scope): the -ContractHash value threaded
        through to the adopted body is carried through UNCHANGED from the
        pre-adoption marker and is NOT reconciled against the
        launch-pinned contract hash anywhere in this function. That
        reconciliation is explicitly out of scope for this primitive --
        the field on an adopted marker is forensics only (it records what
        the marker said at adoption time, nothing more).
    .OUTPUTS
        [pscustomobject]@{ Success; Verified; Reason; AdoptedBySessionId }
        Reason is one of: 'adopted-and-verified' | 'already-adopted' |
        'patch-failed' | 'verification-comment-not-found' |
        'verification-body-unchanged' | 'verification-status-mismatch'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$ContractHash,
        [Parameter(Mandatory)][string]$LaunchedAt,
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Owner,
        [string]$Repo
    )

    $preCheckComments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $preCheckMatch = Find-GRSInflightMarkerCommentById -Comments $preCheckComments -TargetCommentId $CommentId
    if ($preCheckMatch) {
        $preCheckParsed = ConvertFrom-GoalRunInflightMarkerBody -Body $preCheckMatch.body
        if ($preCheckParsed.Parsed -and $preCheckParsed.Status -eq 'adopted') {
            return [pscustomobject]@{ Success = $false; Verified = $false; Reason = 'already-adopted'; AdoptedBySessionId = $preCheckParsed.AdoptedBySessionId }
        }
    }

    $preBody = New-GoalRunInflightMarkerBody -Issue $Issue -ContractHash $ContractHash -LaunchedAt $LaunchedAt -Status 'unresolved'
    $adoptedBody = New-GoalRunInflightMarkerBody -Issue $Issue -ContractHash $ContractHash -LaunchedAt $LaunchedAt -Status 'adopted' -AdoptedBySessionId $SessionId
    $ownerSegment = if ($Owner) { $Owner } else { '{owner}' }
    $repoSegment = if ($Repo) { $Repo } else { '{repo}' }
    $patchPath = "repos/$ownerSegment/$repoSegment/issues/comments/$CommentId"

    $tempFile = $null
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $payload = @{ body = $adoptedBody } | ConvertTo-Json -Depth 4 -Compress
        Set-Content -LiteralPath $tempFile -Value $payload -Encoding UTF8 -NoNewline
        & gh api -X PATCH $patchPath --input $tempFile 2>$null | Out-Null
    }
    finally {
        if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Set-GoalRunInflightMarkerAdopted: gh api PATCH $patchPath failed (exit $LASTEXITCODE)")
        return [pscustomobject]@{ Success = $false; Verified = $false; Reason = 'patch-failed'; AdoptedBySessionId = $SessionId }
    }

    # Verification read -- see .DESCRIPTION above for why the PATCH exit
    # code alone is not trusted as proof of an observable mutation.
    $verifyComments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $verifyMatch = Find-GRSInflightMarkerCommentById -Comments $verifyComments -TargetCommentId $CommentId

    if (-not $verifyMatch) {
        return [pscustomobject]@{ Success = $true; Verified = $false; Reason = 'verification-comment-not-found'; AdoptedBySessionId = $SessionId }
    }
    if ($verifyMatch.body -eq $preBody) {
        return [pscustomobject]@{ Success = $true; Verified = $false; Reason = 'verification-body-unchanged'; AdoptedBySessionId = $SessionId }
    }

    $parsedVerify = ConvertFrom-GoalRunInflightMarkerBody -Body $verifyMatch.body
    if ($parsedVerify.Status -ne 'adopted' -or $parsedVerify.AdoptedBySessionId -ne $SessionId) {
        return [pscustomobject]@{ Success = $true; Verified = $false; Reason = 'verification-status-mismatch'; AdoptedBySessionId = $SessionId }
    }

    return [pscustomobject]@{ Success = $true; Verified = $true; Reason = 'adopted-and-verified'; AdoptedBySessionId = $SessionId }
}

function Resolve-GoalRunInflightMutexOutcome {
    <#
    .SYNOPSIS
        Pure mutex tiebreak: the lowest (earliest-posted) live comment id
        wins; every other live marker yields.
    .PARAMETER LiveMarkerCommentIds
        The full current set of unresolved marker comment ids observed on
        reconcile. Own id is auto-included if the caller omitted it from
        this set.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][long]$OwnCommentId,
        [AllowEmptyCollection()][long[]]$LiveMarkerCommentIds = @()
    )

    $ids = @($LiveMarkerCommentIds)
    if ($ids -notcontains $OwnCommentId) { $ids += $OwnCommentId }
    $lowest = ($ids | Measure-Object -Minimum).Minimum
    $outcome = if ($OwnCommentId -eq $lowest) { 'proceed' } else { 'yield' }

    return [pscustomobject]@{
        Outcome              = $outcome
        WinningCommentId     = $lowest
        LiveMarkerCommentIds = @($ids | Sort-Object -Unique)
    }
}

function Resolve-GoalRunInflightMarkerForResolution {
    <#
    .SYNOPSIS
        #912 D2/D5 (step 4): re-fetch helper for the resolution sites later
        steps (5-6) will call -- the pre-loop launch-pin halt, the
        chain-boundary halts, Stage-1 halts, and Stage-5 completion. Each
        of those sites needs CommentId/ContractHash/LaunchedAt for the
        marker it is about to resolve or adopt, and this function is the
        single place that answers "which marker, and is it safe to act
        on".
    .DESCRIPTION
        Selection mirrors Resolve-GoalRunInflightMutexOutcome's tiebreak:
        the lowest comment id among the LIVE (unresolved) markers wins.
        Resolve-GoalRunInflightMutexOutcome itself applies no status
        filter -- the unresolved-only Where-Object that feeds it belongs
        to Invoke-GoalRunMutexLaunch (the caller, not a property of the
        pure tiebreak function), so this function applies its OWN
        unresolved-only filter here rather than assuming one is inherited
        from elsewhere.

        Returns a typed, non-throwing refusal (Found = $false) in two
        cases: no unresolved marker exists at all, or the winning marker's
        body parsed with Parsed = $true but one or more of the
        Mandatory-consumed fields (ContractHash, LaunchedAt) came back
        $null. The second case matters because
        ConvertFrom-GoalRunInflightMarkerBody can report Parsed = $true
        while still returning per-field $null for a hand-edited or
        truncated marker body -- passing those nulls straight into a
        Mandatory non-nullable parameter on a downstream consumer (for
        example Set-GoalRunInflightMarkerAdopted's -ContractHash/
        -LaunchedAt) would throw an unguarded parameter-binding error
        rather than a caller-actionable refusal. This function is the
        guard point that turns that into 'marker-fields-unparseable'
        instead.
    .OUTPUTS
        [pscustomobject]@{ Found; CommentId; ContractHash; LaunchedAt; Reason }
        Reason is one of: 'resolved-lowest-unresolved-comment-id' |
        'no-unresolved-marker' | 'marker-fields-unparseable'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Owner,
        [string]$Repo
    )

    $allMarkers = Get-GoalRunInflightMarkers -Issue $Issue -Owner $Owner -Repo $Repo
    # This site's OWN unresolved-only filter -- see .DESCRIPTION above for
    # why it is not inherited from Resolve-GoalRunInflightMutexOutcome or
    # from Invoke-GoalRunMutexLaunch's :~658 Where-Object.
    $unresolved = @($allMarkers | Where-Object { $_.Status -eq 'unresolved' -and $null -ne $_.CommentId })

    if ($unresolved.Count -eq 0) {
        return [pscustomobject]@{ Found = $false; CommentId = $null; ContractHash = $null; LaunchedAt = $null; Reason = 'no-unresolved-marker' }
    }

    $winner = $unresolved | Sort-Object -Property CommentId | Select-Object -First 1

    if ([string]::IsNullOrEmpty($winner.ContractHash) -or [string]::IsNullOrEmpty($winner.LaunchedAt)) {
        return [pscustomobject]@{ Found = $false; CommentId = $winner.CommentId; ContractHash = $null; LaunchedAt = $null; Reason = 'marker-fields-unparseable' }
    }

    return [pscustomobject]@{ Found = $true; CommentId = $winner.CommentId; ContractHash = $winner.ContractHash; LaunchedAt = $winner.LaunchedAt; Reason = 'resolved-lowest-unresolved-comment-id' }
}

function Invoke-GoalRunMutexLaunch {
    <#
    .SYNOPSIS
        Marker-first-then-provision launch orchestration (M8).
    .DESCRIPTION
        1. Posts the goal-run-inflight-{Issue} marker BEFORE provisioning.
           A post failure aborts the launch entirely -- New-GoalRunWorktree
           is never called on this path, so a running worktree with no
           mutex marker can never happen.
        2. Re-fetches all live (unresolved) inflight markers and tiebreaks
           via Resolve-GoalRunInflightMutexOutcome. The higher comment-id
           yields: it withdraws (marks resolved) its own marker and aborts
           without provisioning.
        3. M16 fix: a single reconcile read is vulnerable to GitHub
           comment-list eventual consistency -- two near-simultaneous
           launches can each miss the other own just-posted marker in that
           one read, and both would otherwise proceed to provision. Before
           finalizing a 'proceed' outcome, this does ONE brief, cheap
           re-confirmation read after -ReconfirmDelayMs and re-runs the
           SAME tiebreak against the newly observed set -- a narrow-window
           mitigation, not a full distributed-lock replacement. When the
           reconfirmed set changes the outcome to yield, the later read
           wins and this run withdraws its own marker instead of
           provisioning.
        4. Only a reconcile winner that also survives reconfirmation calls
           New-GoalRunWorktree.
    .PARAMETER ReconfirmDelayMs
        Delay before the reconfirmation read in step 3. Injectable to 0 for
        tests; production callers should leave the default so the
        reconfirm read has a real chance to observe a just-posted marker
        that had not yet propagated on the first read.
    .OUTPUTS
        [pscustomobject]@{ Outcome; CommentId; Worktree }
        Outcome is one of: 'abort-marker-post-failed' | 'yielded' |
        'launch-failed-provisioning' | 'launched'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ContractHash,
        [string]$WorktreeRoot,
        [string]$Owner,
        [string]$Repo,
        [int]$ReconfirmDelayMs = 1500
    )

    $posted = New-GoalRunInflightMarker -Issue $Issue -ContractHash $ContractHash -Owner $Owner -Repo $Repo
    if (-not $posted.Success) {
        return [pscustomobject]@{ Outcome = 'abort-marker-post-failed'; CommentId = $null; Worktree = $null }
    }

    $allMarkers = Get-GoalRunInflightMarkers -Issue $Issue -Owner $Owner -Repo $Repo
    $liveIds = @($allMarkers | Where-Object { $_.Status -eq 'unresolved' } | ForEach-Object { $_.CommentId } | Where-Object { $null -ne $_ })
    $tiebreak = Resolve-GoalRunInflightMutexOutcome -OwnCommentId $posted.CommentId -LiveMarkerCommentIds $liveIds

    if ($tiebreak.Outcome -eq 'yield') {
        # M12 fix: always attempt to resolve the own marker on yield,
        # regardless of whether -Owner/-Repo were explicitly supplied.
        # Set-GoalRunInflightMarkerResolved falls back to the gh api ambient
        # {owner}/{repo} placeholders when they are omitted, the same way
        # posting already works fine via ambient `gh` context.
        Set-GoalRunInflightMarkerResolved -CommentId $posted.CommentId -Issue $Issue -ContractHash $ContractHash `
            -LaunchedAt $posted.LaunchedAt -ResolvedReason 'yielded-to-lower-comment-id' -Owner $Owner -Repo $Repo | Out-Null
        return [pscustomobject]@{ Outcome = 'yielded'; CommentId = $posted.CommentId; Worktree = $null }
    }

    # M16 fix: brief re-confirmation before trusting a 'proceed' verdict.
    if ($ReconfirmDelayMs -gt 0) {
        Start-Sleep -Milliseconds $ReconfirmDelayMs
    }
    $reconfirmMarkers = Get-GoalRunInflightMarkers -Issue $Issue -Owner $Owner -Repo $Repo
    $reconfirmLiveIds = @($reconfirmMarkers | Where-Object { $_.Status -eq 'unresolved' } | ForEach-Object { $_.CommentId } | Where-Object { $null -ne $_ })
    $reconfirmTiebreak = Resolve-GoalRunInflightMutexOutcome -OwnCommentId $posted.CommentId -LiveMarkerCommentIds $reconfirmLiveIds

    if ($reconfirmTiebreak.Outcome -eq 'yield') {
        Set-GoalRunInflightMarkerResolved -CommentId $posted.CommentId -Issue $Issue -ContractHash $ContractHash `
            -LaunchedAt $posted.LaunchedAt -ResolvedReason 'yielded-to-lower-comment-id-on-reconfirm' -Owner $Owner -Repo $Repo | Out-Null
        return [pscustomobject]@{ Outcome = 'yielded'; CommentId = $posted.CommentId; Worktree = $null }
    }

    $worktree = New-GoalRunWorktree -RepoRoot $RepoRoot -IssueNumber $Issue -WorktreeRoot $WorktreeRoot
    if (-not $worktree.Success) {
        # F2 fix: self-resolve this run own just-posted inflight marker before
        # returning, exactly as the two yield branches above already do.
        # New-GoalRunWorktree failing (e.g. a dirty-tree refusal) after the
        # mutex marker was posted would otherwise leave that marker unresolved,
        # blocking an immediate retry until it aged out. Falls back to the gh
        # api ambient {owner}/{repo} placeholders when -Owner/-Repo are omitted,
        # the same way the marker POST itself already does.
        Set-GoalRunInflightMarkerResolved -CommentId $posted.CommentId -Issue $Issue -ContractHash $ContractHash `
            -LaunchedAt $posted.LaunchedAt -ResolvedReason 'launch-failed-provisioning' -Owner $Owner -Repo $Repo | Out-Null
        return [pscustomobject]@{ Outcome = 'launch-failed-provisioning'; CommentId = $posted.CommentId; Worktree = $worktree }
    }

    return [pscustomobject]@{ Outcome = 'launched'; CommentId = $posted.CommentId; Worktree = $worktree }
}

# ---------------------------------------------------------------------------
# 4. Crash-atomicity + second-invocation triage
# ---------------------------------------------------------------------------

function Test-GoalRunInflightAppearsDead {
    <#
    .SYNOPSIS
        An inflight marker with no terminal outcome (no halt report, no PR)
        is a first-class detectable state. Pure given the already-fetched
        evidence the caller supplies -- no gh/git calls here.
    .DESCRIPTION
        #912 D3/D4: AppearsDead is purely elapsed-time-computed -- it is
        NEVER short-circuited to $false just because a halt report or PR
        (a terminal outcome) already exists. Whether a terminal outcome is
        present is surfaced instead as the additive TerminalOutcomePresent
        output, so Resolve-GoalRunInvocationAction's precedence can compose
        "stale" with "terminal outcome present" as two independent signals
        rather than the terminal-outcome check pre-empting staleness
        detection entirely.
    .OUTPUTS
        [pscustomobject]@{ AppearsDead; Reason; ElapsedMinutes; LastSeenAt;
        TerminalOutcomePresent }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$MarkerStatus,
        [Parameter(Mandatory)][datetime]$LaunchedAt,
        $HeartbeatAt,
        [Parameter(Mandatory)][bool]$HaltReportExists,
        [Parameter(Mandatory)][bool]$PrExists,
        [Parameter(Mandatory)][datetime]$Now,
        [int]$StaleThresholdMinutes = 60
    )

    $terminalOutcomePresent = [bool]($HaltReportExists -or $PrExists)

    if ($MarkerStatus -ne 'unresolved') {
        return [pscustomobject]@{ AppearsDead = $false; Reason = 'marker-already-resolved'; ElapsedMinutes = $null; LastSeenAt = $null; TerminalOutcomePresent = $terminalOutcomePresent }
    }

    $lastSeen = if ($HeartbeatAt) { [datetime]$HeartbeatAt } else { $LaunchedAt }

    # M6 fix: a Z-suffixed UTC string cast to [datetime] (either via the
    # [datetime]$HeartbeatAt cast above or via the PowerShell parameter-
    # binding coercion of -LaunchedAt/-Now) lands with Kind=Local -- the
    # .NET default parse of a 'Z' string converts it to local wall-clock
    # time and tags it Local, it does not keep it Utc. Subtracting that
    # directly against a genuinely Utc -Now (raw Ticks arithmetic, no
    # Kind-aware conversion happens automatically) then skews the result by
    # the local UTC offset of the running machine -- empirically a freshly
    # launched run reported ElapsedMinutes=240 on a UTC-4 host.
    # .ToUniversalTime() is Kind-aware: it is a correct no-op on an
    # already-Utc value and a correct reverse-conversion on a Local-tagged
    # value, so normalizing both operands through it here makes the
    # subtraction correct regardless of which Kind either side arrived with.
    $elapsed = ($Now.ToUniversalTime() - $lastSeen.ToUniversalTime()).TotalMinutes
    $appearsDead = $elapsed -ge $StaleThresholdMinutes

    return [pscustomobject]@{
        AppearsDead            = $appearsDead
        Reason                 = if ($appearsDead) { 'stale-no-terminal-outcome' } else { 'within-stale-threshold' }
        ElapsedMinutes         = [math]::Round($elapsed, 1)
        LastSeenAt             = $lastSeen
        TerminalOutcomePresent = $terminalOutcomePresent
    }
}

function Resolve-GoalRunInvocationAction {
    <#
    .SYNOPSIS
        Decides what a /goal-run {issue} invocation should do given the
        current mutex state, per the requirement contract: a second
        invocation while an unresolved marker exists refuses to launch a
        new run and instead offers resume/triage.
    .DESCRIPTION
        #912 D2-D4/AC15: exhaustive precedence, highest wins --
          (i)   -ExistingUnresolvedMarker is $null -> 'launch-new'.
          (ii)  -ForceAdopt is set -> 'adopt-and-resume' (the explicit
                override lever always wins once a marker exists, even over
                a fresh/non-dead marker).
          (iii) -AppearsDead is $false (heartbeat fresh) ->
                'refuse-resume-existing' -- the live-run protection is
                never inferred from an absent terminal outcome.
          (iv)  -AppearsDead is $true AND -TerminalOutcomePresent is $true
                -> 'resolve-and-report-complete'.
          (v)   -AppearsDead is $true, no terminal outcome ->
                'adopt-and-resume' (triage-dead-run retired).
    .OUTPUTS
        [pscustomobject]@{ Action; Reason }
        Action is one of: 'launch-new' | 'refuse-resume-existing' |
        'adopt-and-resume' | 'resolve-and-report-complete'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        $ExistingUnresolvedMarker,
        [Parameter(Mandatory)][bool]$AppearsDead,
        [bool]$TerminalOutcomePresent = $false,
        [bool]$ForceAdopt = $false
    )

    if ($null -eq $ExistingUnresolvedMarker) {
        return [pscustomobject]@{ Action = 'launch-new'; Reason = 'no-unresolved-marker' }
    }
    if ($ForceAdopt) {
        return [pscustomobject]@{ Action = 'adopt-and-resume'; Reason = 'force-adopt-requested' }
    }
    if (-not $AppearsDead) {
        return [pscustomobject]@{ Action = 'refuse-resume-existing'; Reason = 'unresolved-marker-present' }
    }
    if ($TerminalOutcomePresent) {
        return [pscustomobject]@{ Action = 'resolve-and-report-complete'; Reason = 'stale-marker-with-terminal-outcome' }
    }
    return [pscustomobject]@{ Action = 'adopt-and-resume'; Reason = 'inflight-marker-appears-dead' }
}

# ---------------------------------------------------------------------------
# 5. Control-return-then-read (M13): bounded retry then a distinct halt
# ---------------------------------------------------------------------------

function Invoke-GoalRunAwaitStatusVerdict {
    <#
    .SYNOPSIS
        Bounded retry over the goal_status transcript reader. The live
        pre-termination flush window is unvalidated (open question from the
        AC5 probe), so a not-yet-present verdict gets a handful of short-
        interval re-reads before the caller treats it as exhausted.
    .PARAMETER StatusReader
        Injectable for testability -- defaults to a thin wrapper over
        Get-GoalRunStatusEvent (dot-sourced at file top via
        goal-run-status-core.ps1). Tests can substitute a scriptblock that
        simulates "not yet present" for N reads then returns a release.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TranscriptPath,
        [int]$MaxRetries = 5,
        [int]$RetryDelayMs = 2000,
        # M15 fix: threaded through to Get-GoalRunStatusEvent so a stale
        # met:true event left over from an earlier goal in the same
        # transcript file cannot falsely release THIS run. Optional --
        # omitted, this preserves pre-fix behavior (no binding).
        [string]$LaunchedAt,
        [scriptblock]$StatusReader = { param($Path, $LaunchedAtArg) Get-GoalRunStatusEvent -TranscriptPath $Path -LaunchedAt $LaunchedAtArg }
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $evt = & $StatusReader $TranscriptPath $LaunchedAt
        if ($evt -and $evt.State -eq 'present-met-true') {
            return [pscustomobject]@{ Outcome = 'released'; Event = $evt.Event; Attempts = $attempt }
        }
        if ($attempt -lt $MaxRetries) {
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }
    return [pscustomobject]@{ Outcome = 'retry-exhausted'; Event = $null; Attempts = $MaxRetries }
}

function Resolve-GoalRunControlReturn {
    <#
    .SYNOPSIS
        The validated Arm-I sequence (M13): loop completes -> control
        returns to the harness session -> harness reads the now-flushed
        goal_status verdict -> caller launches the chain. On retry
        exhaustion, emits a distinct diagnostic halt via
        Invoke-GoalRunHaltEmit rather than a generic chain-stage-failure --
        see this file header .NOTES on the closed halt_reason enum.
    .DESCRIPTION
        #912 s7 fix: the exhaustion-halt emit upserts against the fixed
        per-issue `goal-halt-report-{Issue}` marker (Invoke-GoalRunHaltEmit),
        which would otherwise silently overwrite ANY prior halt report on
        the same issue -- including a genuinely different, later run's
        report -- with this run's "transcript flush delay" diagnosis. A
        bare existence check would be worse than the overwrite it prevents:
        it would mean a later run's genuine exhaustion could never post once
        any halt report exists for the issue. Instead, when -LaunchedAt is
        supplied, this function fetches the existing goal-halt-report-{Issue}
        comment (if any) via Get-GoalRunIssueComments and compares its
        `updatedAt` GitHub-comment metadata (the halt-report schema is
        closed and carries no timestamp field of its own -- see
        goal-run-halt-core.ps1 / skills/goal-run/schemas/goal-halt-report.schema.json)
        against this run's -LaunchedAt:
          - Existing report strictly NEWER than this run's launch -> it
            belongs to a different, later run. Do not overwrite; HaltResult
            reports Suppressed = $true instead of a false Success claim.
          - Existing report at or before this run's launch (or absent, or
            unparseable) -> stale or nonexistent; proceed with the emit as
            before.
        -LaunchedAt is optional and preserves pre-fix behavior when omitted
        (no existing-report fetch, always emits) -- mirroring the M15
        -LaunchedAt convention already documented below.
    .OUTPUTS
        [pscustomobject]@{ Outcome; Event; Attempts; HaltResult }
        Outcome is one of: 'released' | 'halted-verdict-not-flushed'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TranscriptPath,
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$MaxRetries = 5,
        [int]$RetryDelayMs = 2000,
        # M15 fix: pass-through to Invoke-GoalRunAwaitStatusVerdict/
        # Get-GoalRunStatusEvent -- the current run launch timestamp,
        # available from the goal-run-active.json launched_at field via
        # Get-GoalRunActiveState. Optional -- omitted, this preserves
        # pre-fix behavior (no stale-release binding).
        [string]$LaunchedAt,
        [scriptblock]$StatusReader = { param($Path, $LaunchedAtArg) Get-GoalRunStatusEvent -TranscriptPath $Path -LaunchedAt $LaunchedAtArg },
        [string]$Owner,
        [string]$Repo
    )

    $await = Invoke-GoalRunAwaitStatusVerdict -TranscriptPath $TranscriptPath -MaxRetries $MaxRetries -RetryDelayMs $RetryDelayMs -LaunchedAt $LaunchedAt -StatusReader $StatusReader

    if ($await.Outcome -eq 'released') {
        return [pscustomobject]@{ Outcome = 'released'; Event = $await.Event; Attempts = $await.Attempts; HaltResult = $null }
    }

    $report = @{
        schema_version         = 1
        issue                  = $Issue
        halt_reason            = 'chain-stage-failure'
        target_ref             = $null
        plan_remediation       = 'goal_status verdict did not appear in transcript within the retry window after loop completion. Inspect the transcript manually for a delayed flush; if a met:true verdict is present, resume via /goal-run {issue}. If genuinely absent, investigate the executor session before re-launching.'
        evidence                = @(
            "goal_status verdict did not appear in transcript within $MaxRetries retries after loop completion",
            "transcript_path: $TranscriptPath"
        )
        recommended_next_owner = 'maintainer'
        arm                    = 'in-session'
        stage                  = 'loop'
        claim_provenance       = 'harness'
        budget_snapshot        = @{}
    }

    # #912 s7: recency-discriminated don't-overwrite guard. Only runs when a
    # -LaunchedAt is supplied -- omitting it preserves pre-fix behavior
    # (always emit), matching the existing M15 -LaunchedAt convention above.
    $suppressAsNewerReportExists = $false
    if (-not [string]::IsNullOrWhiteSpace($LaunchedAt)) {
        # Plain [datetime] cast (not a manual ::Parse with an explicit
        # culture/style) so this works uniformly whether the value arrives as
        # a raw ISO-8601 string (-LaunchedAt) or as an already-parsed
        # [datetime] (Get-GoalRunIssueComments' updatedAt, since
        # ConvertFrom-Json auto-parses ISO-looking JSON string values).
        $launchedTimestamp = $null
        try { $launchedTimestamp = [datetime]$LaunchedAt } catch { $launchedTimestamp = $null }

        if ($launchedTimestamp) {
            $haltMarker = "<!-- goal-halt-report-$Issue -->"
            $existingComments = @(Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo)
            $existingMatches = @($existingComments | Where-Object { $_.body -and ($_.body -like "*$haltMarker*") })

            if ($existingMatches.Count -gt 0) {
                $latestExistingTimestamp = $null
                foreach ($candidate in $existingMatches) {
                    $candidateTimestamp = $null
                    try { $candidateTimestamp = [datetime]$candidate.updatedAt } catch { $candidateTimestamp = $null }
                    if ($candidateTimestamp -and (-not $latestExistingTimestamp -or $candidateTimestamp -gt $latestExistingTimestamp)) {
                        $latestExistingTimestamp = $candidateTimestamp
                    }
                }

                if ($latestExistingTimestamp -and $latestExistingTimestamp -gt $launchedTimestamp) {
                    # The existing report postdates this run's launch -- it is
                    # a different, newer run's report. A bare existence check
                    # would suppress ALL future exhaustion halts once any
                    # report exists; comparing recency instead lets a
                    # genuinely stale (pre-launch) report be replaced below.
                    $suppressAsNewerReportExists = $true
                }
            }
        }
    }

    $haltResult = $null
    if ($suppressAsNewerReportExists) {
        [Console]::Error.WriteLine("Resolve-GoalRunControlReturn: existing goal-halt-report-$Issue comment postdates this run's launch ($LaunchedAt); not overwriting a newer run's report.")
        $haltResult = [pscustomobject]@{ Success = $false; Url = $null; Body = $null; Suppressed = $true }
    }
    else {
        try {
            $haltResult = Invoke-GoalRunHaltEmit -Report $report -Issue $Issue -RepoRoot $RepoRoot -Owner $Owner -Repo $Repo
        }
        catch {
            [Console]::Error.WriteLine("Resolve-GoalRunControlReturn: Invoke-GoalRunHaltEmit failed -- $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{ Outcome = 'halted-verdict-not-flushed'; Event = $null; Attempts = $await.Attempts; HaltResult = $haltResult }
}

# ---------------------------------------------------------------------------
# 6. Loop->chain seam (M16) + terminal-emissions seam (step 6)
# ---------------------------------------------------------------------------

function New-GoalRunExecutorSessionHandle {
    <#
    .SYNOPSIS
        The executor-session handle shape (M16a): whatever session identity
        data is needed to poll/read that session transcript. Arm I
        populates this from the current in-session executor; a future PR-2
        Arm H implementation can populate the SAME shape from an externally
        polled `claude -p` process instead, without changing any consumer
        of this handle.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$TranscriptPath,
        [ValidateSet('in-session', 'manual', 'headless')][string]$Arm = 'in-session'
    )

    return [pscustomobject]@{ SessionId = $SessionId; TranscriptPath = $TranscriptPath; Arm = $Arm }
}

function Invoke-GoalRunLaunchChain {
    <#
    .SYNOPSIS
        SEAM -- #874 plan step 6 owns the real chain body. "Launch chain
        against committed state" (M16b): takes ONLY durable artifacts as
        input (Issue, RepoRoot, ContractHash, WorktreePath, and the
        executor-session handle) -- never live conversation context -- so a
        future PR-2 Arm H implementation can swap out HOW it supervises the
        executor without rewriting this transition.
    .OUTPUTS
        [pscustomobject]@{ Launched; Reason; Issue; ContractHash; WorktreePath }
        Launched is always $false in this PR -- Reason names the owning
        future step.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ContractHash,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)]$ExecutorSessionHandle
    )

    return [pscustomobject]@{
        Launched     = $false
        Reason       = 'not-implemented-pending-step6'
        Issue        = $Issue
        ContractHash = $ContractHash
        WorktreePath = $WorktreePath
    }
}

function Test-GoalRunTerminalEmissionsVerified {
    <#
    .SYNOPSIS
        SEAM -- #874 plan step 6 owns the real implementation: verify the
        goal-run label and pipeline-metrics credit rows on the terminal PR
        via `gh`. Always reports not-verified here so the stage machine
        never falsely claims a run is complete before step 6 lands.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$PrNumber
    )

    return [pscustomobject]@{ Verified = $false; Reason = 'not-implemented-pending-step6' }
}

# ---------------------------------------------------------------------------
# 7. Operator-initiated restart (#912 D6, step 5): capture-then-clear
# ---------------------------------------------------------------------------

function New-GoalRunRestartReportBody {
    <#
    .SYNOPSIS
        #912 D6 (step 5): the durable capture-before-clear report body.
        Posted via New-GoalRunIssueComment (always POSTs a new comment,
        never upserts) so a history of restarts survives across repeated
        invocations -- the same always-post rationale the inflight mutex
        marker already relies on for the concurrent-launch audit trail.
    .DESCRIPTION
        This is the ONLY durable record of the branch name once the stage
        marker is cleared: New-GoalRunWorktree mints a fresh GUID-suffixed
        branch per launch (goal-run-worktree-core.ps1:279-281) and neither
        goal-run-active.json nor the inflight marker ever store it. The
        branch name is resolved live, from the still-intact worktree, by
        the caller (Invoke-GoalRunRestart below) BEFORE this body is built.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$WorktreePath,
        [string]$BranchName,
        [Parameter(Mandatory)][string]$ClearedAt
    )

    $branchDisplay = if ([string]::IsNullOrWhiteSpace($BranchName)) { 'unknown' } else { $BranchName }

    $lines = @(
        "<!-- goal-run-restart-report-$Issue -->",
        '## Goal-run restart report',
        '',
        '- **schema_version**: 1',
        "- **issue**: $Issue",
        "- **worktree_path**: $WorktreePath",
        "- **branch_name**: $branchDisplay",
        "- **cleared_at**: $ClearedAt",
        '',
        'This run was restarted by an explicit operator `/goal-run {issue} restart` command. The worktree above was NOT deleted -- recover any committed work by hand from the branch name recorded here, then relaunch with a plain `/goal-run {issue}`.'
    )
    return ($lines -join "`n")
}

function ConvertFrom-GoalRunRestartReportBody {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    if ($Body -notmatch '<!-- goal-run-restart-report-(\d+) -->') {
        return [pscustomobject]@{ Parsed = $false; Issue = $null; WorktreePath = $null; BranchName = $null; ClearedAt = $null }
    }

    $issue = [int]$Matches[1]
    $worktreePath = if ($Body -match '(?m)^-\s+\*\*worktree_path\*\*:\s*(.+)$') { $Matches[1].Trim() } else { $null }
    $branchName = if ($Body -match '(?m)^-\s+\*\*branch_name\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $clearedAt = if ($Body -match '(?m)^-\s+\*\*cleared_at\*\*:\s*(\S+)') { $Matches[1] } else { $null }

    return [pscustomobject]@{ Parsed = $true; Issue = $issue; WorktreePath = $worktreePath; BranchName = $branchName; ClearedAt = $clearedAt }
}

function Clear-GoalRunStageMarker {
    <#
    .SYNOPSIS
        #912 D6 (step 5): deletes the goal-run-stage-{Issue} marker comment
        outright. Set-GoalRunStageMarker (above) only ever upserts in
        place -- no clear/remove primitive existed anywhere in this
        codebase before this step, and `gh api -X DELETE` appears nowhere
        under .github/scripts/lib/ prior to this function.
    .DESCRIPTION
        Finds every live comment whose body carries the
        <!-- goal-run-stage-{Issue} --> marker (Set-GoalRunStageMarker's
        upsert-in-place design means normally at most one exists -- this
        defends against a legacy duplicate the same way
        Get-GoalRunStageMarker's own `-Last 1` read does) and issues a
        `gh api -X DELETE repos/{owner}/{repo}/issues/comments/{id}` for
        each match. Fail-open per this file's existing gh-wrapper
        convention: a failed delete is reported to stderr and does not
        throw or stop the remaining deletes.
    .OUTPUTS
        [pscustomobject]@{ Success; DeletedCommentIds; FailedCommentIds }
        Success is $true only when every matched comment id was deleted
        (or there were zero matches to delete in the first place).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Owner,
        [string]$Repo
    )

    $marker = "<!-- goal-run-stage-$Issue -->"
    $comments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $matched = @($comments | Where-Object { $_.body -and ($_.body -like "*$marker*") })

    $deleted = [System.Collections.Generic.List[long]]::new()
    $failed = [System.Collections.Generic.List[long]]::new()
    $ownerSegment = if ($Owner) { $Owner } else { '{owner}' }
    $repoSegment = if ($Repo) { $Repo } else { '{repo}' }

    foreach ($c in $matched) {
        $commentId = $null
        if ($c.url -and ($c.url -match '#issuecomment-(\d+)$')) { $commentId = [long]$Matches[1] }
        elseif ($c.id) { try { $commentId = [long]$c.id } catch { $commentId = $null } }
        if (-not $commentId) { continue }

        $deletePath = "repos/$ownerSegment/$repoSegment/issues/comments/$commentId"
        & gh api -X DELETE $deletePath 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $deleted.Add($commentId)
        }
        else {
            [Console]::Error.WriteLine("Clear-GoalRunStageMarker: gh api DELETE $deletePath failed (exit $LASTEXITCODE)")
            $failed.Add($commentId)
        }
    }

    return [pscustomobject]@{
        Success           = ($failed.Count -eq 0)
        DeletedCommentIds = $deleted.ToArray()
        FailedCommentIds  = $failed.ToArray()
    }
}

function Clear-GoalRunActiveState {
    <#
    .SYNOPSIS
        #912 D6 (step 5): deletes goal-run-active.json at the worktree
        root, if present. Never throws -- mirrors Get-GoalRunActiveState's
        own never-throw-on-missing-file contract.
    .DESCRIPTION
        Clearing this file is not optional alongside the stage marker:
        Resolve-GoalRunResumeStage's -ActiveStatePresent rung 6 still
        resolves to 'loop-launched' on the very next invocation if this
        file survives, even with the stage marker gone -- restart would
        silently fail to reach 'pre-loop' otherwise. Uses the same
        $script:GoalRunActiveStateFileName constant goal-run-worktree-
        core.ps1 defines (visible here because this file dot-sources it
        at the top) rather than a second hardcoded literal.
    .OUTPUTS
        [bool] $true when the file is confirmed absent afterward
        (including when it never existed), $false when a delete was
        attempted and failed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $statePath = Join-Path $WorktreePath $script:GoalRunActiveStateFileName
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $true
    }
    try {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
        return -not (Test-Path -LiteralPath $statePath)
    }
    catch {
        [Console]::Error.WriteLine("Clear-GoalRunActiveState: failed to remove $statePath -- $($_.Exception.Message)")
        return $false
    }
}

function Invoke-GoalRunRestart {
    <#
    .SYNOPSIS
        #912 D6 (step 5): the operator-initiated `/goal-run {issue}
        restart` lever. Refuses while the run appears live (fresh
        heartbeat); otherwise captures the worktree path and branch into a
        durable report comment BEFORE clearing anything, then clears BOTH
        the stage marker comment and the worktree's goal-run-active.json
        file.
    .DESCRIPTION
        Capture-then-clear is the single most load-bearing ordering this
        function exists to guarantee (see the requirement contract): the
        stage marker is the only durable carrier of the worktree path, and
        New-GoalRunWorktree always mints a fresh GUID-suffixed branch, so
        clearing the marker before recording the branch would orphan every
        commit the interrupted loop made with no way to find it again.
        This function only ever runs from the explicit operator `restart`
        argument text (see agents/Goal-Run.agent.md's Operator Restart
        section) -- never inferred from any halt or harness state.

        Liveness reuses Test-GoalRunInflightAppearsDead's elapsed-time math
        (Delegation Instead Of Duplication -- see implementation-discipline
        methodology) rather than re-deriving a second stale-threshold
        calculation. -MarkerStatus is pinned to 'unresolved' and
        -HaltReportExists/-PrExists to $false because neither the "marker
        already resolved" bypass nor the terminal-outcome distinction that
        function's own callers need applies to a restart decision -- only
        the heartbeat-vs-now elapsed check matters here. When -LaunchedAt
        is omitted (the active-state file is already gone -- e.g. a prior
        restart attempt cleared it but the marker delete failed), there is
        no heartbeat evidence to protect against, so the liveness gate
        cannot refuse and this proceeds straight to capture-then-clear.

        Clearing BOTH artifacts is required, not optional: clearing only
        the stage marker still leaves Resolve-GoalRunResumeStage landing on
        'loop-launched' via -ActiveStatePresent (rung 6), because the
        active-state file alone is sufficient to fire that rung; only
        clearing both artifacts reaches the true 'pre-loop' resume state.

        Never deletes the worktree directory itself -- restart's non-goals
        explicitly exclude worktree teardown; the operator recovers
        committed work from the reported branch by hand.
    .OUTPUTS
        [pscustomobject]@{ Outcome; Reason; ReportUrl; BranchName;
        WorktreePath; ClearedStageMarker; ClearedActiveState }
        Outcome is one of: 'refused-live-run' | 'report-post-failed' |
        'restarted'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$WorktreePath,
        # Nullable by design -- see .DESCRIPTION for the no-active-state case.
        $LaunchedAt,
        $HeartbeatAt,
        [int]$StaleThresholdMinutes = 60,
        [string]$Owner,
        [string]$Repo,
        [string]$GitCliPath = 'git',
        [datetime]$Now = (Get-Date).ToUniversalTime()
    )

    if ($null -ne $LaunchedAt) {
        $appears = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt ([datetime]$LaunchedAt) `
            -HeartbeatAt $HeartbeatAt -HaltReportExists $false -PrExists $false -Now $Now -StaleThresholdMinutes $StaleThresholdMinutes
        $appearsDead = $appears.AppearsDead
    }
    else {
        # No active-state evidence at all -- nothing live to refuse against.
        $appearsDead = $true
    }

    if (-not $appearsDead) {
        return [pscustomobject]@{
            Outcome            = 'refused-live-run'
            Reason             = 'fresh-heartbeat'
            ReportUrl          = $null
            BranchName         = $null
            WorktreePath       = $WorktreePath
            ClearedStageMarker = $false
            ClearedActiveState = $false
        }
    }

    # Capture BEFORE clearing anything -- resolve the branch name live from
    # the still-intact worktree (restart never deletes the worktree itself).
    $branchName = $null
    try {
        $branchOutput = & $GitCliPath -C $WorktreePath rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branchOutput)) {
            $branchName = ($branchOutput | Out-String).Trim()
        }
    }
    catch {
        $branchName = $null
    }

    $clearedAt = $Now.ToString('o')
    $reportBody = New-GoalRunRestartReportBody -Issue $Issue -WorktreePath $WorktreePath -BranchName $branchName -ClearedAt $clearedAt
    $report = New-GoalRunIssueComment -Issue $Issue -Body $reportBody -Owner $Owner -Repo $Repo
    if (-not $report.Success) {
        return [pscustomobject]@{
            Outcome            = 'report-post-failed'
            Reason             = 'restart-report-post-failed'
            ReportUrl          = $null
            BranchName         = $branchName
            WorktreePath       = $WorktreePath
            ClearedStageMarker = $false
            ClearedActiveState = $false
        }
    }

    # Only clear once the report has landed -- capture-then-clear, never the
    # reverse, per the requirement contract's single most load-bearing rule.
    $clearedMarker = Clear-GoalRunStageMarker -Issue $Issue -Owner $Owner -Repo $Repo
    $clearedState = Clear-GoalRunActiveState -WorktreePath $WorktreePath

    return [pscustomobject]@{
        Outcome            = 'restarted'
        Reason             = 'operator-restart'
        ReportUrl          = $report.Url
        BranchName         = $branchName
        WorktreePath       = $WorktreePath
        ClearedStageMarker = $clearedMarker.Success
        ClearedActiveState = $clearedState
    }
}
