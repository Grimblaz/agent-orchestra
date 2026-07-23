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
         Resolve-GoalRunInflightMutexOutcome (pure tiebreak),
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
        return [pscustomobject]@{ ResumeStage = 'loop-released'; Reason = 'loop-launched-awaiting-release' }
    }
    if ($RunLogHasCheckpoint) {
        return [pscustomobject]@{ ResumeStage = 'loop-released'; Reason = 'run-log-implies-loop-launched-no-explicit-marker' }
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
                    id   = $_.id
                    url  = $_.html_url
                    body = $_.body
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
        [ValidateSet('unresolved', 'resolved')][string]$Status = 'unresolved',
        [string]$ResolvedReason
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
    return ($lines -join "`n")
}

function ConvertFrom-GoalRunInflightMarkerBody {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    if ($Body -notmatch '<!-- goal-run-inflight-(\d+) -->') {
        return [pscustomobject]@{ Parsed = $false; Issue = $null; Status = $null; ContractHash = $null; LaunchedAt = $null; ResolvedReason = $null }
    }

    $issue = [int]$Matches[1]
    $status = if ($Body -match '(?m)^-\s+\*\*status\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $contractHash = if ($Body -match '(?m)^-\s+\*\*contract_hash\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $launchedAt = if ($Body -match '(?m)^-\s+\*\*launched_at\*\*:\s*(\S+)') { $Matches[1] } else { $null }
    $resolvedReason = if ($Body -match '(?m)^-\s+\*\*resolved_reason\*\*:\s*(.+)$') { $Matches[1].Trim() } else { $null }

    return [pscustomobject]@{ Parsed = $true; Issue = $issue; Status = $status; ContractHash = $contractHash; LaunchedAt = $launchedAt; ResolvedReason = $resolvedReason }
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
                CommentId      = $commentId
                Status         = $parsed.Status
                ContractHash   = $parsed.ContractHash
                LaunchedAt     = $parsed.LaunchedAt
                ResolvedReason = $parsed.ResolvedReason
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
    .OUTPUTS
        [pscustomobject]@{ AppearsDead; Reason; ElapsedMinutes; LastSeenAt }
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

    if ($MarkerStatus -ne 'unresolved') {
        return [pscustomobject]@{ AppearsDead = $false; Reason = 'marker-already-resolved'; ElapsedMinutes = $null; LastSeenAt = $null }
    }
    if ($HaltReportExists -or $PrExists) {
        return [pscustomobject]@{ AppearsDead = $false; Reason = 'terminal-outcome-present'; ElapsedMinutes = $null; LastSeenAt = $null }
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
        AppearsDead    = $appearsDead
        Reason         = if ($appearsDead) { 'stale-no-terminal-outcome' } else { 'within-stale-threshold' }
        ElapsedMinutes = [math]::Round($elapsed, 1)
        LastSeenAt     = $lastSeen
    }
}

function Resolve-GoalRunInvocationAction {
    <#
    .SYNOPSIS
        Decides what a /goal-run {issue} invocation should do given the
        current mutex state, per the requirement contract: a second
        invocation while an unresolved marker exists refuses to launch a
        new run and instead offers resume/triage.
    .OUTPUTS
        [pscustomobject]@{ Action; Reason }
        Action is one of: 'launch-new' | 'refuse-resume-existing' |
        'triage-dead-run'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        $ExistingUnresolvedMarker,
        [Parameter(Mandatory)][bool]$AppearsDead
    )

    if ($null -eq $ExistingUnresolvedMarker) {
        return [pscustomobject]@{ Action = 'launch-new'; Reason = 'no-unresolved-marker' }
    }
    if ($AppearsDead) {
        return [pscustomobject]@{ Action = 'triage-dead-run'; Reason = 'inflight-marker-appears-dead' }
    }
    return [pscustomobject]@{ Action = 'refuse-resume-existing'; Reason = 'unresolved-marker-present' }
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

    $haltResult = $null
    try {
        $haltResult = Invoke-GoalRunHaltEmit -Report $report -Issue $Issue -RepoRoot $RepoRoot -Owner $Owner -Repo $Repo
    }
    catch {
        [Console]::Error.WriteLine("Resolve-GoalRunControlReturn: Invoke-GoalRunHaltEmit failed -- $($_.Exception.Message)")
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
