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
             latest recorded value) -- authoritative when present. The
             three recorded marker values map to three DIFFERENT resume
             stages, not straight through 1:1:
               - 'chain-dispatched' -> 'chain-dispatched' (awaiting
                 terminal emissions)
               - 'loop-released' -> 'chain-dispatched' (the loop already
                 finished; only the chain dispatch itself is outstanding)
               - 'loop-launched' -> 'loop-interrupted' (the loop was
                 launched but never recorded release -- the run must be
                 resumed as an in-progress loop, not restarted as a fresh
                 launch)
          4. -RunLogHasCheckpoint -- a checkpoint/deviation/experience-
             observation entry proves the loop ran even without an
             explicit stage marker (e.g. a crash between loop-launch and
             the next marker write) -> 'loop-interrupted', the same
             resume stage the 'loop-launched' explicit marker above maps
             to -- both mean "the loop is known to have started and has
             no recorded release", just from different evidence.
          5. -ActiveStatePresent -- goal-run-active.json exists, so the
             worktree was provisioned but the loop was never launched ->
             'loop-launched' (the resume stage that (re)launches the
             loop -- distinct from the 'loop-interrupted' ResumeStage
             above, which resumes an ALREADY-launched loop instead of
             relaunching it)
          6. -InflightMarkerPresent -- a mutex marker was posted but
             nothing was provisioned yet (crash mid pre-loop) -> 'pre-loop'
          7. Nothing present -> 'pre-loop' (fresh launch)
    .OUTPUTS
        [pscustomobject]@{ ResumeStage; Reason }
        ResumeStage is one of: 'blocked' | 'complete' | 'chain-dispatched' |
        'loop-interrupted' | 'loop-launched' | 'pre-loop'.
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

function script:Get-GRSMarkerWholeLinePattern {
    <#
    .SYNOPSIS
        #912 external-review fix (G7): "the marker appears as its own
        standalone line" detection regex, shared by every marker-matching
        reader in this file (Get-GoalRunStageMarker,
        Get-GoalRunInflightMarkers, Clear-GoalRunStageMarker).
    .DESCRIPTION
        Every marker reader in this file used `-like "*$marker*"` before
        this fix -- a raw SUBSTRING match, so a comment that merely
        MENTIONS the marker in prose (a maintainer explaining the
        convention, a pasted diagnostic message) counted as a real marker-
        carrying comment. On the read paths that mis-selects the wrong
        comment; on Clear-GoalRunStageMarker's DELETE path it is worse in
        both directions at once -- the extra prose match either pushes the
        matched set to 2+ and permanently wedges restart on its
        `marker-ambiguous` refusal, or (with the real marker absent) makes
        a prose comment itself the DELETE target. Every marker this file
        writes is emitted as the body's own first line
        (New-GoalRunStageMarkerBody / New-GoalRunInflightMarkerBody), so a
        line-anchored match is the exact shape those writers produce.

        Pattern shape is deliberately identical to the shipped shared
        helper Get-MarkerWholeLinePattern
        (.github/scripts/lib/marker-transport-core.ps1) rather than a
        newly-invented one. That file is NOT dot-sourced here: its first
        top-level statement mutates [Console]::OutputEncoding process-wide
        at dot-source time (marker-transport-core.ps1:96-101, deliberate
        and documented there), which would impose a global console-encoding
        side effect on every caller and test of this stage lib in exchange
        for one pure single-expression regex builder. The narrower
        alternative -- Find-AllCommentsByExactMarker from the same file --
        was rejected on behavior, not packaging: it throws on gh failure,
        requires Mandatory -Owner/-Repo with no ambient fallback, and
        issues its own gh call, and all three conflict with this file's
        fail-open, ambient-capable, already-fetched-comments design.
    .OUTPUTS
        [string] a multiline-anchored regex matching -Marker as a whole
        line, modulo surrounding whitespace.
    #>
    param([Parameter(Mandatory)][string]$Marker)
    return "(?m)^\s*$([regex]::Escape($Marker))\s*`$"
}

function script:Get-GRSInertMarkerLabel {
    <#
    .SYNOPSIS
        #912 external-review fix (G6): renders a marker for human-facing
        prose (stderr text an operator may paste into the issue) with the
        <!-- / --> HTML-comment delimiters STRIPPED.
    .DESCRIPTION
        Per skills/session-memory-contract/references/handoff-markers.md
        § Writing about markers safely, a complete delimited marker literal
        is live to every raw-text marker scan -- backticks do not
        neutralize it. Emitting the delimited literal inside an ambiguity-
        refusal message means pasting that message into the issue creates a
        SECOND marker-carrying comment, which makes the very ambiguity the
        message reports permanent. Stripping the delimiters genuinely
        breaks the match because the anchors the patterns key on are no
        longer present in the text at all.
    .OUTPUTS
        [string] the marker text with '<!--' / '-->' removed and trimmed.
    #>
    param([Parameter(Mandatory)][string]$Marker)
    return ($Marker -replace '^<!--\s*', '' -replace '\s*-->$', '').Trim()
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
    .PARAMETER RepoRoot
        #912 review fix (M18): when -Owner/-Repo are not supplied, the
        owner/repo resolution below previously ALWAYS resolved against the
        process CWD (`gh repo view` / bare `git remote get-url origin`,
        neither pointed at any particular directory) -- wrong whenever a
        caller with a worktree path different from the process cwd (e.g.
        the goal-run harness) needs comments for a repo other than
        whatever the process happens to be sitting in. When supplied, this
        resolves owner/repo from THIS path's git remote instead, mirroring
        Get-GCPinnedCommentBody's own -RepoRoot-aware `git -C` resolution
        (goal-contract-validate-core.ps1). Optional -- omitted, this
        preserves pre-fix behavior (resolve from process cwd).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Owner,
        [string]$Repo,
        [string]$RepoRoot,
        [string]$GhCliPath = 'gh',
        [string]$GitCliPath = 'git',
        [scriptblock]$CommentsReader
    )

    if ($CommentsReader) {
        return @(& $CommentsReader $Issue $Owner $Repo $GhCliPath)
    }

    $ownerRepo = $null
    if ($Owner -and $Repo) {
        $ownerRepo = "$Owner/$Repo"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        # M18 fix: resolve from THIS worktree's git remote rather than the
        # ambient-cwd paths below, which is wrong whenever -RepoRoot
        # differs from the process cwd.
        try {
            $remoteUrl = & $GitCliPath -C $RepoRoot remote get-url origin 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteUrl)) {
                $match = [regex]::Match($remoteUrl, 'github\.com[:/](.+?)(?:\.git)?/?$')
                if ($match.Success) { $ownerRepo = $match.Groups[1].Value.Trim() }
            }
        }
        catch {
            # Falls through to the ambient-cwd resolution below.
        }
    }
    if (-not $ownerRepo) {
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
                $remoteUrl = & $GitCliPath remote get-url origin 2>$null
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

    # #912 external-review fix (G9): a missing or unresolvable -GhCliPath makes
    # the `&` call operator throw a terminating CommandNotFoundException, which
    # propagates straight past this function's documented never-throw contract
    # (every other failure here returns an empty array). $LASTEXITCODE is never
    # even reached on that path. Catch it and return the same typed empty-array
    # failure the exit-code branch below already returns. Guarded with a plain
    # try/catch rather than by importing Test-MarkerNativeLaunchFailure from
    # marker-transport-core.ps1 -- that file mutates [Console]::OutputEncoding
    # process-wide at dot-source time, the same reason
    # Get-GRSMarkerWholeLinePattern re-implements its regex locally.
    $raw = $null
    try {
        $raw = & $GhCliPath api "repos/$ownerRepo/issues/$Issue/comments" --paginate --slurp 2>$null
    }
    catch {
        [Console]::Error.WriteLine("Get-GoalRunIssueComments: gh api invocation failed for repos/$ownerRepo/issues/$Issue/comments ($($_.Exception.Message))")
        return @()
    }
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
    # #912 external-review fix (G7): line-anchored, not substring. A prose
    # comment merely MENTIONING this marker would otherwise be picked up here
    # -- and because the selection below is `-Last 1`, a later prose mention
    # would win over the real marker and hand the caller a garbage
    # Stage/WorktreePath (or a Found = $false parse) for a run that genuinely
    # has a marker. See Get-GRSMarkerWholeLinePattern.
    $markerPattern = Get-GRSMarkerWholeLinePattern -Marker $marker
    $comments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $matched = @($comments | Where-Object { $_.body -and ($_.body -match $markerPattern) })
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
    # #912 external-review fix (G9, same family as the four `gh api` sites): a
    # missing `gh` throws CommandNotFoundException past this function's typed
    # Success = $false failure shape. Guarded to return that shape instead.
    $output = $null
    try {
        $output = & gh @postArgs 2>$null
    }
    catch {
        [Console]::Error.WriteLine("New-GoalRunIssueComment: gh issue comment invocation failed ($($_.Exception.Message))")
        return [pscustomobject]@{ Success = $false; CommentId = $null; Url = $null }
    }
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
    # #912 external-review fix (G7): line-anchored, not substring -- a prose
    # comment mentioning this marker would otherwise be parsed as a real
    # mutex marker and (with a null Status) silently join or distort the
    # live-marker set every admission/tiebreak decision reads.
    $markerPattern = Get-GRSMarkerWholeLinePattern -Marker $marker
    $comments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $matched = @($comments | Where-Object { $_.body -and ($_.body -match $markerPattern) })

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
    catch {
        # #912 external-review fix (G9): this try had a finally but no catch, so
        # a terminating error thrown inside it propagated straight past the
        # documented [bool] contract. Two independent throwers live in here: a
        # missing/unresolvable `gh` (CommandNotFoundException from the `&` call
        # operator, before $LASTEXITCODE is ever set) and
        # [System.IO.Path]::GetTempFileName() itself (IOException once the temp
        # directory holds 65535 files, UnauthorizedAccessException when it is
        # not writable). Both mean the PATCH did not land, which is exactly
        # what $false already reports. The finally below still runs on this
        # path, so the temp file is cleaned up either way.
        [Console]::Error.WriteLine("Set-GoalRunInflightMarkerResolved: gh api PATCH $patchPath invocation failed ($($_.Exception.Message))")
        return $false
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
        # #912 external-review fix (G12): guard the [long] cast the same way
        # its two siblings in this file already do (Get-GoalRunInflightMarkers
        # and Clear-GoalRunStageMarker both use
        # `try { [long]$c.id } catch { $null }`). Unguarded, a non-numeric
        # `id` made the cast throw -- and because `-or` evaluates
        # left-to-right, the throw happened BEFORE the `url` fallback on the
        # right was ever evaluated. That made the fallback unreachable in
        # exactly the case it exists to cover.
        $numericId = $null
        if ($_.id) { try { $numericId = [long]$_.id } catch { $numericId = $null } }
        ($null -ne $numericId -and $numericId -eq $TargetCommentId) -or
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

        #912 external-review fix (G3): that pre-check now admits ONLY a
        freshly-read status of exactly 'unresolved'. It previously refused
        only on 'adopted', so a marker the owning run had RESOLVED in the
        window between the caller's admission read and this pre-check fell
        through and got PATCHed back to 'adopted' -- destroying its
        resolved_reason and re-arming a duplicate resume of an already-
        finished run. Neither the verification read nor the M7 reconfirm
        read below could catch that, because both inspect the body this
        function itself just wrote. 'resolved' now refuses as
        'already-resolved', and a marker-carrying body whose status line is
        absent or unrecognized refuses as 'marker-status-unrecognized'.

        NOTE (forensics-only scope): the -ContractHash value threaded
        through to the adopted body is carried through UNCHANGED from the
        pre-adoption marker and is NOT reconciled against the
        launch-pinned contract hash anywhere in this function. That
        reconciliation is explicitly out of scope for this primitive --
        the field on an adopted marker is forensics only (it records what
        the marker said at adoption time, nothing more).

        #912 review fix (M7): the pre-check-then-PATCH sequence above is
        itself check-then-act (TOCTOU) with no compare-and-set -- two
        invocations can both pass the pre-check (neither yet sees the
        other's adoption) and both PATCH, with the second silently
        clobbering the first. The single verification read immediately
        after OUR OWN PATCH cannot detect a concurrent PATCH that lands
        AFTER that read succeeds. This function now adds a SECOND,
        reconfirmation read after -ReconfirmDelayMs (mirroring
        Invoke-GoalRunMutexLaunch's own reconfirm-after-delay mechanism for
        the exact same eventual-consistency/race class) that re-checks the
        comment still shows OUR SessionId. A losing concurrent adopter
        detects the loss here (Reason = 'lost-to-concurrent-adopter')
        instead of falsely believing it holds the marker.

        #912 review fix (M7): -preBody now uses the ACTUALLY-FETCHED
        pre-adoption body (already read into $preCheckMatch.body above)
        rather than a synthetically reconstructed one. A reconstructed
        body only matches the real one when the caller's inputs are
        byte-identical to what generated the real body (field order,
        whitespace, optional fields) -- any drift would make the
        'verification-body-unchanged' comparison silently wrong (a false
        negative OR positive) in a way that has nothing to do with whether
        the mutation actually landed.
    .OUTPUTS
        [pscustomobject]@{ Success; Verified; Reason; AdoptedBySessionId }
        Reason is one of: 'adopted-and-verified' | 'already-adopted' |
        'already-resolved' | 'marker-status-unrecognized' |
        'patch-failed' | 'verification-comment-not-found' |
        'verification-body-unchanged' | 'verification-status-mismatch' |
        'reconfirm-comment-not-found' | 'lost-to-concurrent-adopter'.
        Success is truthful (never $true when Verified is $false) --
        Verified remains the more specific field for "the PATCH call itself
        succeeded but the mutation could not be confirmed".
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
        [string]$Repo,
        # #912 review fix (M7): injectable to 0 for tests, mirroring
        # Invoke-GoalRunMutexLaunch's -ReconfirmDelayMs convention.
        # Production callers should leave the default so the reconfirm
        # read has a real chance to observe a concurrent adopter's PATCH
        # that had not yet landed at the first verification read.
        [int]$ReconfirmDelayMs = 1500
    )

    $preCheckComments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $preCheckMatch = Find-GRSInflightMarkerCommentById -Comments $preCheckComments -TargetCommentId $CommentId
    if ($preCheckMatch) {
        $preCheckParsed = ConvertFrom-GoalRunInflightMarkerBody -Body $preCheckMatch.body
        # #912 external-review fix (G3): the gate is now "the freshly-read
        # status must be EXACTLY 'unresolved' to proceed", not "must not be
        # 'adopted'". Before this fix a marker the owning run RESOLVED in the
        # window between the admission read and this pre-check fell straight
        # through the `-eq 'adopted'` test, and this function then PATCHed
        # that completed marker back to status = 'adopted' -- destroying its
        # resolved_reason and re-arming a duplicate resume of a run that had
        # already finished. The corruption was self-concealing: both the
        # verification read and the M7 reconfirm read below inspect the body
        # THIS function just wrote, so both confirmed the overwrite as a
        # successful adoption.
        if ($preCheckParsed.Parsed -and $preCheckParsed.Status -ne 'unresolved') {
            $refusalReason = switch ($preCheckParsed.Status) {
                'adopted' { 'already-adopted' }
                'resolved' { 'already-resolved' }
                # A body that carries the marker but whose status line is
                # missing/hand-edited/truncated parses to Parsed = $true with
                # Status = $null. That is no evidence the marker is safe to
                # adopt either, and PATCHing over it would silently discard
                # whatever a maintainer put there -- refuse rather than
                # mislabel it as one of the two known states above.
                default { 'marker-status-unrecognized' }
            }
            return [pscustomobject]@{ Success = $false; Verified = $false; Reason = $refusalReason; AdoptedBySessionId = $preCheckParsed.AdoptedBySessionId }
        }
    }

    # #912 review fix (M7): use the actually-fetched pre-adoption body when
    # the pre-check read found the comment; only fall back to a
    # synthetically reconstructed body in the edge case where the pre-check
    # read itself could not locate the comment at all (nothing real to use).
    $preBody = if ($preCheckMatch) { $preCheckMatch.body } else {
        New-GoalRunInflightMarkerBody -Issue $Issue -ContractHash $ContractHash -LaunchedAt $LaunchedAt -Status 'unresolved'
    }
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
    catch {
        # #912 external-review fix (G9): same missing-catch defect as
        # Set-GoalRunInflightMarkerResolved above, and the same two independent
        # throwers (a missing `gh`, and GetTempFileName itself). Reuses the
        # existing 'patch-failed' Reason rather than widening the documented
        # enum -- a throw IS a PATCH failure, and the exception text goes to
        # stderr where the diagnostic detail belongs. Verified stays $false
        # because nothing was confirmed to land.
        [Console]::Error.WriteLine("Set-GoalRunInflightMarkerAdopted: gh api PATCH $patchPath invocation failed ($($_.Exception.Message))")
        return [pscustomobject]@{ Success = $false; Verified = $false; Reason = 'patch-failed'; AdoptedBySessionId = $SessionId }
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

    # #912 review fix (M18): Success must be truthful -- a verification
    # failure means the mutation this function exists to confirm did NOT
    # observably land, which is not a success by this function's own
    # contract, even though the PATCH call itself returned exit 0. Verified
    # remains the more specific field for that distinction.
    if (-not $verifyMatch) {
        return [pscustomobject]@{ Success = $false; Verified = $false; Reason = 'verification-comment-not-found'; AdoptedBySessionId = $SessionId }
    }
    if ($verifyMatch.body -eq $preBody) {
        return [pscustomobject]@{ Success = $false; Verified = $false; Reason = 'verification-body-unchanged'; AdoptedBySessionId = $SessionId }
    }

    $parsedVerify = ConvertFrom-GoalRunInflightMarkerBody -Body $verifyMatch.body
    if ($parsedVerify.Status -ne 'adopted' -or $parsedVerify.AdoptedBySessionId -ne $SessionId) {
        return [pscustomobject]@{ Success = $false; Verified = $false; Reason = 'verification-status-mismatch'; AdoptedBySessionId = $SessionId }
    }

    # #912 review fix (M7): TOCTOU reconfirmation -- the verification read
    # above proves OUR PATCH landed, but not that a concurrent adopter's
    # PATCH did not land immediately afterward. Re-read after a brief delay
    # to give a same-window concurrent adopter time to have already
    # clobbered this comment, mirroring Invoke-GoalRunMutexLaunch's own
    # reconfirm-after-delay pattern for the identical race class.
    if ($ReconfirmDelayMs -gt 0) {
        Start-Sleep -Milliseconds $ReconfirmDelayMs
    }
    $reconfirmComments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $reconfirmMatch = Find-GRSInflightMarkerCommentById -Comments $reconfirmComments -TargetCommentId $CommentId

    if (-not $reconfirmMatch) {
        return [pscustomobject]@{ Success = $false; Verified = $false; Reason = 'reconfirm-comment-not-found'; AdoptedBySessionId = $SessionId }
    }
    $parsedReconfirm = ConvertFrom-GoalRunInflightMarkerBody -Body $reconfirmMatch.body
    if ($parsedReconfirm.Status -ne 'adopted' -or $parsedReconfirm.AdoptedBySessionId -ne $SessionId) {
        return [pscustomobject]@{ Success = $false; Verified = $false; Reason = 'lost-to-concurrent-adopter'; AdoptedBySessionId = $parsedReconfirm.AdoptedBySessionId }
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

function script:ConvertTo-GRSParsedUtcDateTimeOrNull {
    <#
    .SYNOPSIS
        #912 review fix (M6): shared parse guard -- attempts to parse
        -Value as a [datetime] and returns $null on ANY failure (empty,
        whitespace, or genuinely unparseable garbage such as "TBD"),
        rather than letting a bare [datetime] cast throw. Used everywhere a
        LaunchedAt-shaped value needs a typed refusal instead of an
        unguarded cast blowing up downstream (Delegation Instead Of
        Duplication -- implementation-discipline methodology -- rather than
        re-deriving this guard at each call site).
    .DESCRIPTION
        Accepts either an already-parsed [datetime] (passed straight
        through, no string round-trip that could lose Kind) or a string
        (parsed via [datetime]::TryParse with RoundtripKind so a Z-suffixed
        UTC string parses as Kind=Utc rather than Kind=Local -- consistent
        with the M6/#874 fix already applied to Test-GoalRunInflightAppearsDead
        just above).
    .OUTPUTS
        [Nullable[datetime]] -- $null on any parse failure or empty input.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    $asString = [string]$Value
    if ([string]::IsNullOrWhiteSpace($asString)) { return $null }

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParse(
        $asString,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )
    if (-not $ok) { return $null }

    # #912 post-fix defense (F4): RoundtripKind preserves an explicit Z/
    # offset suffix's Kind (Utc or Local), but a NAIVE (no timezone
    # suffix) timestamp parses to Kind=Unspecified -- neither Utc nor
    # Local. A later .ToUniversalTime() call on an Unspecified value
    # treats it as LOCAL time (the same underlying .NET behavior the M6
    # fix elsewhere in this file documents for a bare [datetime] cast),
    # which on a positive-UTC-offset host can make a genuinely live run's
    # LaunchedAt/heartbeat read as further in the past than it really is
    # -- exactly the wrong direction for a liveness gate that must fail
    # closed (it can make a still-live run look dead and get adopted out
    # from under itself). This function's own name and docstring already
    # promise UTC normalization, and every production writer in this
    # codebase emits UTC-suffixed strings, so this closes the one gap
    # those writers never produce but a hand-edited/test-supplied naive
    # value still could.
    if ($parsed.Kind -eq [System.DateTimeKind]::Unspecified) {
        $parsed = [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
    }
    return $parsed
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
        the lowest comment id among the LIVE (unresolved OR adopted)
        markers wins. Resolve-GoalRunInflightMutexOutcome itself applies
        no status filter -- the live-set Where-Object that feeds it
        belongs to Invoke-GoalRunMutexLaunch (the caller, not a property
        of the pure tiebreak function), so this function applies its OWN
        unresolved-or-adopted filter here rather than assuming one is
        inherited from elsewhere.

        Returns a typed, non-throwing refusal (Found = $false) in two
        cases: no live (unresolved or adopted) marker exists at all, or
        the winning marker's body parsed with Parsed = $true but one or
        more of the Mandatory-consumed fields (ContractHash, LaunchedAt)
        came back $null. The second case matters because
        ConvertFrom-GoalRunInflightMarkerBody can report Parsed = $true
        while still returning per-field $null for a hand-edited or
        truncated marker body -- passing those nulls straight into a
        Mandatory non-nullable parameter on a downstream consumer (for
        example Set-GoalRunInflightMarkerAdopted's -ContractHash/
        -LaunchedAt) would throw an unguarded parameter-binding error
        rather than a caller-actionable refusal. This function is the
        guard point that turns that into 'marker-fields-unparseable'
        instead.

        #912 post-fix defense (F1/F6): the output now also surfaces the
        winning marker's own `Status` and `AdoptedBySessionId` fields, so
        a caller (Goal-Run.agent.md's Invocation Contract step 2) can
        make session-identity-aware decisions -- see
        Resolve-GoalRunInvocationAction's `resume-own-adopted` rung --
        without a second live re-fetch. The `Reason` values are also
        renamed here: this function's own diagnostic strings previously
        said "unresolved" only even though the M1 fix above already
        widened its live-marker filter to also match `adopted` markers,
        which was misleading to any caller reading `Reason` back.
        'no-unresolved-marker' becomes 'no-live-marker' and
        'resolved-lowest-unresolved-comment-id' becomes
        'resolved-lowest-live-comment-id'.
    .OUTPUTS
        [pscustomobject]@{ Found; CommentId; ContractHash; LaunchedAt; Status; AdoptedBySessionId; Reason }
        Reason is one of: 'resolved-lowest-live-comment-id' |
        'no-live-marker' | 'marker-fields-unparseable'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Owner,
        [string]$Repo
    )

    $allMarkers = Get-GoalRunInflightMarkers -Issue $Issue -Owner $Owner -Repo $Repo
    # This site's OWN live-marker filter -- see .DESCRIPTION above for why
    # it is not inherited from Resolve-GoalRunInflightMutexOutcome or from
    # Invoke-GoalRunMutexLaunch's own Where-Object. #912 review fix (M1):
    # 'adopted' is a live/held status (a run in progress under a new
    # session), not a resolved one -- a marker this session itself just
    # adopted must still be findable here so that session's own later
    # resolution call (at its own ending) can locate it. Excluding it (the
    # pre-fix `-eq 'unresolved'`-only filter) made every already-adopted
    # marker invisible to this function.
    $live = @($allMarkers | Where-Object { ($_.Status -eq 'unresolved' -or $_.Status -eq 'adopted') -and $null -ne $_.CommentId })

    if ($live.Count -eq 0) {
        return [pscustomobject]@{ Found = $false; CommentId = $null; ContractHash = $null; LaunchedAt = $null; Status = $null; AdoptedBySessionId = $null; Reason = 'no-live-marker' }
    }

    $winner = $live | Sort-Object -Property CommentId | Select-Object -First 1

    # #912 review fix (M6): IsNullOrEmpty alone only catches an EMPTY
    # LaunchedAt -- a field containing non-whitespace garbage (e.g. "TBD"
    # on a hand-edited marker) passed this guard before the fix and then
    # threw downstream at the exact Mandatory [datetime] parameter binding
    # this guard's own docstring claims to prevent reaching. Attempting an
    # actual parse (via the shared ConvertTo-GRSParsedUtcDateTimeOrNull
    # guard, same helper Invoke-GoalRunRestart's M17 fix below now also
    # uses) turns that into the same typed refusal empty already gets.
    $parsedLaunchedAt = ConvertTo-GRSParsedUtcDateTimeOrNull -Value $winner.LaunchedAt
    if ([string]::IsNullOrEmpty($winner.ContractHash) -or $null -eq $parsedLaunchedAt) {
        return [pscustomobject]@{ Found = $false; CommentId = $winner.CommentId; ContractHash = $null; LaunchedAt = $null; Status = $winner.Status; AdoptedBySessionId = $winner.AdoptedBySessionId; Reason = 'marker-fields-unparseable' }
    }

    return [pscustomobject]@{ Found = $true; CommentId = $winner.CommentId; ContractHash = $winner.ContractHash; LaunchedAt = $winner.LaunchedAt; Status = $winner.Status; AdoptedBySessionId = $winner.AdoptedBySessionId; Reason = 'resolved-lowest-live-comment-id' }
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
        2. Re-fetches all live (unresolved OR adopted -- see the M1 fix
           comment on the live-set filter below) inflight markers and
           tiebreaks via Resolve-GoalRunInflightMutexOutcome. The higher comment-id
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
    # #912 review fix (M1): 'adopted' is a live/held marker, not a resolved
    # one -- a marker held by a concurrent invocation that has already
    # adopted it must still count in the tiebreak set, otherwise a second
    # invocation racing against an adopted (in-progress) run would see it
    # as absent and wrongly proceed to provision a duplicate worktree.
    $liveIds = @($allMarkers | Where-Object { $_.Status -eq 'unresolved' -or $_.Status -eq 'adopted' } | ForEach-Object { $_.CommentId } | Where-Object { $null -ne $_ })
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
    # #912 review fix (M1): same live-set fix as the reconcile read above --
    # an adopted marker must still be visible on reconfirm.
    $reconfirmLiveIds = @($reconfirmMarkers | Where-Object { $_.Status -eq 'unresolved' -or $_.Status -eq 'adopted' } | ForEach-Object { $_.CommentId } | Where-Object { $null -ne $_ })
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
        Reason is one of: 'marker-already-resolved' |
        'heartbeat-unparseable-assumed-live' (#912 external-review fix G4 --
        a non-null but unparseable -HeartbeatAt, refused fail-closed) |
        'stale-no-terminal-outcome' | 'within-stale-threshold'.
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

    # #912 review fix (M1): short-circuit ONLY on a genuinely resolved
    # marker. Before this fix, this checked `-ne 'unresolved'`, which also
    # matched 'adopted' and reported it via the SAME 'marker-already-
    # resolved' reason -- a false claim, since an adopted marker is a run
    # still in progress under a new session, not a withdrawn/completed one
    # (see the Status enum note on New-GoalRunInflightMarkerBody). An
    # adopted marker must fall through to the same elapsed-time staleness
    # computation an unresolved marker gets.
    if ($MarkerStatus -eq 'resolved') {
        return [pscustomobject]@{ AppearsDead = $false; Reason = 'marker-already-resolved'; ElapsedMinutes = $null; LastSeenAt = $null; TerminalOutcomePresent = $terminalOutcomePresent }
    }

    # #912 external-review fix (G4): -HeartbeatAt now routes through the same
    # shared parse guard every other LaunchedAt-shaped value in this file uses
    # (ConvertTo-GRSParsedUtcDateTimeOrNull) instead of a bare
    # `[datetime]$HeartbeatAt` cast. The bare cast had two failure modes, both
    # reachable from the live restart lever and the admission-gate triage:
    #   (a) a malformed non-null heartbeat threw a raw cast error straight out
    #       of this pure decision function, where every caller expects a typed
    #       verdict object;
    #   (b) a NAIVE (no timezone suffix) heartbeat cast to Kind=Unspecified,
    #       and the .ToUniversalTime() below then treats Unspecified as LOCAL
    #       -- on a positive-UTC-offset host that shifts LastSeenAt further
    #       into the past and can report a genuinely LIVE run as dead, which
    #       is the fail-OPEN direction for a liveness gate whose $true verdict
    #       authorizes clearing another run's markers. The shared guard
    #       SpecifyKind's Unspecified to Utc, closing (b) for every caller.
    # An UNPARSEABLE non-null heartbeat is refused fail-CLOSED (AppearsDead =
    # $false, "assume live") rather than silently falling back to -LaunchedAt:
    # that fallback moves LastSeenAt strictly further into the past, i.e.
    # toward the destructive verdict, and Core Principles (agents/Goal-Run.agent.md)
    # require failing closed on ambiguity. Absence stays the documented safe
    # case it already was -- fall back to -LaunchedAt.
    $lastSeen = $LaunchedAt
    if ($HeartbeatAt) {
        $parsedHeartbeat = ConvertTo-GRSParsedUtcDateTimeOrNull -Value $HeartbeatAt
        if ($null -eq $parsedHeartbeat) {
            return [pscustomobject]@{ AppearsDead = $false; Reason = 'heartbeat-unparseable-assumed-live'; ElapsedMinutes = $null; LastSeenAt = $null; TerminalOutcomePresent = $terminalOutcomePresent }
        }
        $lastSeen = $parsedHeartbeat
    }

    # M6 fix: a Z-suffixed UTC string cast to [datetime] (either via the
    # -HeartbeatAt parse above or via the PowerShell parameter-
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
        invocation while a live (unresolved or adopted) marker exists
        refuses to launch a new run and instead offers resume/triage.
    .DESCRIPTION
        #912 D2-D4/AC15, extended by the #912 post-fix defense pass
        (F1/D1): exhaustive precedence, highest wins --
          (i)   -ExistingUnresolvedMarker is $null -> 'launch-new'.
          (ii)  -MarkerStatus is 'adopted' AND -AdoptedBySessionId equals
                -CurrentSessionId -> 'resume-own-adopted' -- the SAME
                session continuing its own already-adopted run (e.g. a
                crash before provisioning ever completed), not a
                concurrent launch. This closes a deterministic self-yield
                livelock: without this rung, the admission gate saw no
                'unresolved' marker (only its own 'adopted' one), fell
                through to 'launch-new', posted a brand-new marker, and
                that new marker (a strictly higher comment id) always lost
                the mutex tiebreak to the session's own already-adopted
                marker -- forever. This rung sits ahead of -ForceAdopt: an
                operator re-typing `adopt` against a marker this session
                already holds should still resume in place, not attempt a
                redundant re-adoption.
          (iii) -ForceAdopt is set -> 'adopt-and-resume' (the explicit
                override lever always wins once a live marker exists and
                is not this session's own already-adopted marker, even
                over a fresh/non-dead marker).
          (iv)  -AppearsDead is $false (heartbeat fresh) ->
                'refuse-resume-existing' -- the live-run protection is
                never inferred from an absent terminal outcome. When
                -MarkerStatus is 'adopted' (necessarily held by a
                DIFFERENT session here, since rung (ii) already claimed
                the same-session case), `Reason` is the distinguishing
                'adopted-by-other-session' rather than the generic
                'unresolved-marker-present'.
          (v)   -AppearsDead is $true AND -TerminalOutcomePresent is $true
                -> 'resolve-and-report-complete'.
          (vi)  -AppearsDead is $true, no terminal outcome ->
                'adopt-and-resume' -- the sole action once staleness is
                confirmed with nothing terminal recorded; there is no
                separate report-only dead-run outcome anymore.
    .PARAMETER MarkerStatus
        #912 post-fix defense (F1/D1): the existing marker's own `Status`
        field ('unresolved' | 'adopted'), when known -- e.g. from
        Resolve-GoalRunInflightMarkerForResolution's own `Status` field.
        Optional; omitted (the pre-fix caller shape), rung (ii) can never
        trigger and every pre-fix caller's behavior is unchanged.
    .PARAMETER AdoptedBySessionId
        #912 post-fix defense (F1/D1): the existing marker's own
        `AdoptedBySessionId` field, meaningful only when -MarkerStatus is
        'adopted'.
    .PARAMETER CurrentSessionId
        #912 post-fix defense (F1/D1): the CURRENT invocation's own
        session id, compared against -AdoptedBySessionId at rung (ii).
    .OUTPUTS
        [pscustomobject]@{ Action; Reason }
        Action is one of: 'launch-new' | 'resume-own-adopted' |
        'refuse-resume-existing' | 'adopt-and-resume' |
        'resolve-and-report-complete'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        $ExistingUnresolvedMarker,
        [Parameter(Mandatory)][bool]$AppearsDead,
        [bool]$TerminalOutcomePresent = $false,
        [bool]$ForceAdopt = $false,
        [string]$MarkerStatus,
        [string]$AdoptedBySessionId,
        [string]$CurrentSessionId
    )

    if ($null -eq $ExistingUnresolvedMarker) {
        return [pscustomobject]@{ Action = 'launch-new'; Reason = 'no-unresolved-marker' }
    }
    if ($MarkerStatus -eq 'adopted' -and -not [string]::IsNullOrEmpty($AdoptedBySessionId) -and -not [string]::IsNullOrEmpty($CurrentSessionId) -and $AdoptedBySessionId -eq $CurrentSessionId) {
        return [pscustomobject]@{ Action = 'resume-own-adopted'; Reason = 'adopted-by-own-session' }
    }
    if ($ForceAdopt) {
        return [pscustomobject]@{ Action = 'adopt-and-resume'; Reason = 'force-adopt-requested' }
    }
    if (-not $AppearsDead) {
        $reason = if ($MarkerStatus -eq 'adopted') { 'adopted-by-other-session' } else { 'unresolved-marker-present' }
        return [pscustomobject]@{ Action = 'refuse-resume-existing'; Reason = $reason }
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

        #912 review fix (M18): the recency-guard comment fetch now passes
        -RepoRoot through to Get-GoalRunIssueComments (this function
        already receives -RepoRoot as a Mandatory parameter, but never used
        it for this call before this fix -- the fetch silently resolved
        owner/repo from the PROCESS CWD instead) and exposes its own
        -CommentsReader injectable, matching this file's existing
        injectable-reader convention (Get-GoalRunIssueComments's own
        -CommentsReader, Test-GoalRunPrEmissionsVerified's -PrReader) so
        tests can substitute a fixture reader without needing gh on PATH.
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
        [string]$Repo,
        # #912 review fix (M18): injectable reader for the recency-guard's
        # own comment fetch below -- passed straight through to
        # Get-GoalRunIssueComments's existing -CommentsReader parameter.
        [scriptblock]$CommentsReader
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
        #
        # #912 review fix (M3): a Z-suffixed -LaunchedAt string cast via
        # plain [datetime] lands Kind=Local (the SAME .NET behavior the M6
        # fix on Test-GoalRunInflightAppearsDead, ~200 lines above,
        # documents and fixes for LaunchedAt/HeartbeatAt) -- but
        # $candidate.updatedAt arrives from ConvertFrom-Json already
        # Kind=Utc. Comparing a Kind=Local value against a Kind=Utc value
        # with a plain `-gt` skews the verdict by the host machine's local
        # UTC offset, exactly the M6 bug shape. .ToUniversalTime() is the
        # same fix applied here: a correct no-op on an already-Utc value, a
        # correct reverse-conversion on a Local-tagged one.
        $launchedTimestamp = $null
        try { $launchedTimestamp = ([datetime]$LaunchedAt).ToUniversalTime() } catch { $launchedTimestamp = $null }

        if ($launchedTimestamp) {
            $haltMarker = "<!-- goal-halt-report-$Issue -->"
            # #912 review fix (M18): thread -RepoRoot and the injectable
            # -CommentsReader through so this fetch resolves owner/repo from
            # the target worktree (or a test fixture) instead of always the
            # process CWD.
            $existingComments = @(Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo -RepoRoot $RepoRoot -CommentsReader $CommentsReader)
            # #912 external-review follow-up (G7 sibling): this recency guard
            # used the same raw `-like "*$marker*"` SUBSTRING match every other
            # reader in this file was line-anchored away from. Shipping two
            # different marker-matching conventions in one file is how the next
            # reader picks the wrong one. Reuse the shared helper. See
            # Get-GRSMarkerWholeLinePattern.
            #
            # #912 post-fix defense (F1) -- do NOT read this guard as read-only.
            # An earlier revision of this comment claimed "the worst case is
            # suppressing a genuine exhaustion halt". That is wrong: failing to
            # suppress routes control into Invoke-GoalRunHaltEmit ->
            # Find-OrUpsertComment, whose target selection is still an
            # unanchored `-like "*$Marker*"` over whole comment bodies, with an
            # earliest-REST-id tie-break that actively prefers the wrong comment.
            # So a prose comment that merely MENTIONS the halt-report marker is
            # no longer suppressed here, and can be selected and PATCHed away
            # there. Anchoring this reader is still correct -- the suppression it
            # removed was itself a false-negative on halt reporting, and the
            # same clobber is already reachable unguarded from the
            # per-iteration halt emit in goal-run-predicate-core.ps1 -- but the
            # writer-side selector is the real fix and is out of scope here.
            # See Documents/Design/marker-reader-inventory.md
            # "## Comment-selector class (Find-OrUpsertComment and the `-like`
            # cluster)", which scopes that replacement to the s5 slice of #885.
            $haltMarkerPattern = Get-GRSMarkerWholeLinePattern -Marker $haltMarker
            $existingMatches = @($existingComments | Where-Object { $_.body -and ($_.body -match $haltMarkerPattern) })

            if ($existingMatches.Count -gt 0) {
                $latestExistingTimestamp = $null
                foreach ($candidate in $existingMatches) {
                    $candidateTimestamp = $null
                    try { $candidateTimestamp = ([datetime]$candidate.updatedAt).ToUniversalTime() } catch { $candidateTimestamp = $null }
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

        #912 review fix (M8): before deleting anything, refuses outright
        (deletes NOTHING) when 2+ comments carry the marker, rather than
        hard-DELETEing every match. This repo already established the
        contrary precedent for exactly this ambiguity shape --
        Get-GCPinnedCommentBody (goal-contract-validate-core.ps1) treats
        2+ marker-pinned matches as unresolvable and refuses to guess
        rather than acting on any candidate. A single unambiguous match
        still deletes normally.
    .OUTPUTS
        [pscustomobject]@{ Success; DeletedCommentIds; FailedCommentIds; Reason }
        Success is $true only when every matched comment id was deleted
        (or there were zero matches to delete in the first place). Reason
        is $null on the normal path, or 'marker-ambiguous' when 2+ matches
        caused a full refusal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string]$Owner,
        [string]$Repo
    )

    $marker = "<!-- goal-run-stage-$Issue -->"
    # #912 external-review fix (G7): line-anchored, not substring. This is
    # the DELETE path, so a loose substring match is destructive in both
    # directions -- a comment merely mentioning the marker in prose either
    # pushes the matched set to 2+ and permanently wedges restart on the
    # ambiguity refusal below, or (real marker already gone) becomes the
    # DELETE target itself. See Get-GRSMarkerWholeLinePattern.
    $markerPattern = Get-GRSMarkerWholeLinePattern -Marker $marker
    $comments = Get-GoalRunIssueComments -Issue $Issue -Owner $Owner -Repo $Repo
    $matched = @($comments | Where-Object { $_.body -and ($_.body -match $markerPattern) })

    if ($matched.Count -gt 1) {
        # M8 fix: refuse-on-ambiguity, mirroring Get-GCPinnedCommentBody's
        # own precedent -- deleting every match risked destroying a
        # legitimate different marker instance with no way to know which
        # one the caller actually intended.
        #
        # #912 external-review fix (G6): the marker is named here in its
        # INERT (delimiter-stripped) form. The delimited literal is live to
        # this function's own reader, so an operator pasting this refusal
        # message into the issue would create the second marker-carrying
        # comment that makes this very ambiguity permanent. See
        # Get-GRSInertMarkerLabel and
        # skills/session-memory-contract/references/handoff-markers.md
        # § Writing about markers safely.
        $inertMarker = Get-GRSInertMarkerLabel -Marker $marker
        [Console]::Error.WriteLine("Clear-GoalRunStageMarker: $($matched.Count) comments on issue $Issue carry marker '$inertMarker' (HTML-comment delimiters stripped so this message is safe to paste); refusing to guess (ambiguous).")
        return [pscustomobject]@{
            Success           = $false
            DeletedCommentIds = @()
            FailedCommentIds  = @()
            Reason            = 'marker-ambiguous'
        }
    }

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
        # #912 external-review fix (G9): a missing `gh` threw
        # CommandNotFoundException out of the whole loop, so the typed
        # {Success; DeletedCommentIds; FailedCommentIds; Reason} result was
        # never returned at all and any comment already deleted earlier in the
        # loop went unreported. Catching per-iteration records the id as failed
        # (which is truthful -- the DELETE did not land) and lets the remaining
        # ids be attempted, so the returned ledger stays complete.
        $deleteThrew = $false
        try {
            & gh api -X DELETE $deletePath 2>$null | Out-Null
        }
        catch {
            [Console]::Error.WriteLine("Clear-GoalRunStageMarker: gh api DELETE $deletePath invocation failed ($($_.Exception.Message))")
            $deleteThrew = $true
        }
        if (-not $deleteThrew -and $LASTEXITCODE -eq 0) {
            $deleted.Add($commentId)
        }
        elseif ($deleteThrew) {
            $failed.Add($commentId)
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
        Reason            = $null
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
        the stage marker comment and the goal-run-active.json file inside
        that worktree.
    .DESCRIPTION
        Capture-then-clear is the single most load-bearing ordering this
        function exists to guarantee (see the requirement contract): the
        stage marker is the only durable carrier of the worktree path, and
        New-GoalRunWorktree always mints a fresh GUID-suffixed branch, so
        clearing the marker before recording the branch would orphan every
        commit the interrupted loop made with no way to find it again.
        This function only ever runs from the explicit operator `restart`
        argument text (see the Operator Restart section in
        agents/Goal-Run.agent.md) -- never inferred from any halt or
        harness state.

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

        #912 post-fix defense (F3): "required, not optional" above does
        NOT mean the two clears run unconditionally in sequence -- the
        active-state clear is now gated on the stage-marker clear's own
        success. Before this fix, an ambiguous-match refusal on the
        stage-marker clear (Clear-GoalRunStageMarker's own `marker-
        ambiguous` Reason, ClearedStageMarker = $false) still let the
        active-state clear proceed unconditionally, producing an
        unrecoverable half-clear: goal-run-active.json gone but the stage
        marker -- the only durable carrier of the worktree path -- still
        present. When the stage-marker clear itself fails,
        ClearedActiveState now stays $false and Clear-GoalRunActiveState
        is never even called, matching the existing
        'restarted-partial-marker-clear-failed' outcome this function
        already returns in that case.

        Never deletes the worktree directory itself -- restart's non-goals
        explicitly exclude worktree teardown; the operator recovers
        committed work from the reported branch by hand.

        #912 review fix (M6/M17): the -LaunchedAt liveness check now routes
        through the SAME shared parse guard (ConvertTo-GRSParsedUtcDateTimeOrNull)
        Resolve-GoalRunInflightMarkerForResolution's M6 fix uses, rather
        than a bare `[datetime]$LaunchedAt` cast that throws on garbage
        input. This also closes the M17 fail-OPEN gap: a genuinely
        ABSENT -LaunchedAt (the documented "prior restart already cleared
        the active-state file" case) still proceeds -- there is nothing
        live to protect against -- but a NON-NULL, UNPARSEABLE -LaunchedAt
        (the active-state file exists but could not be read/parsed) now
        fails CLOSED with a distinct refusal (Outcome =
        'refused-unparseable-state') instead of being silently treated as
        "appears dead" and permitted to clear a possibly-live run's
        markers. These are deliberately different signals: absence is
        confirmed-safe evidence, corruption is NO evidence either way.

        #912 review fix (M18): the branch-name capture now also reports
        whether the resolved value is a REAL branch name via
        -BranchNameResolved, rather than letting a degenerate result
        (git's own 'unknown'/'could not determine' answer of the literal
        string 'HEAD' on a detached-HEAD worktree) be recorded as if it
        were authoritative.

        #912 review fix (M18): the final Outcome is no longer 'restarted'
        unconditionally -- when Clear-GoalRunStageMarker itself reports
        failure, this returns 'restarted-partial-marker-clear-failed'
        instead, so a caller/report cannot mistake a partially-completed
        restart for a fully clean one.

        #912 external-review fix (G2): the same honesty now extends to the
        SECOND clear. A failed Clear-GoalRunActiveState after a SUCCESSFUL
        stage-marker clear used to be invisible -- Outcome was derived
        solely from $clearedMarker.Success and still said 'restarted' --
        and the agent body resolved the mutex marker on that word. It now
        returns the distinct 'restarted-partial-active-state-clear-failed'.
        The two partial outcomes are NOT interchangeable: the marker-clear
        failure cleared NOTHING (so the mutex marker must stay held),
        whereas this one genuinely deleted the stage marker and posted the
        capture report, leaving only a stale goal-run-active.json in an
        already-abandoned worktree for the operator to remove by hand.

        #912 external-review fix (G4): -HeartbeatAt is resolved through the
        SAME ConvertTo-GRSParsedUtcDateTimeOrNull guard as -LaunchedAt
        BEFORE the liveness call, with the same absent-vs-unparseable
        split: absent falls back to -LaunchedAt (unchanged), while a
        non-null unparseable value refuses with Outcome =
        'refused-unparseable-state' and Reason = 'heartbeat-at-unparseable'.
        Previously it was handed raw to Test-GoalRunInflightAppearsDead's
        bare [datetime] cast, which threw on garbage and mis-zoned a naive
        (no-suffix) timestamp as local -- the latter able to report a LIVE
        run as dead and authorize clearing its markers on a positive-UTC-
        offset host.
    .OUTPUTS
        [pscustomobject]@{ Outcome; Reason; ReportUrl; BranchName;
        BranchNameResolved; WorktreePath; ClearedStageMarker;
        ClearedActiveState }
        Outcome is one of: 'refused-live-run' | 'refused-unparseable-state'
        | 'report-post-failed' | 'restarted' |
        'restarted-partial-marker-clear-failed' |
        'restarted-partial-active-state-clear-failed'.
        Reason on 'refused-unparseable-state' distinguishes which input was
        unparseable: 'launched-at-unparseable' or 'heartbeat-at-unparseable'.
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

    # #912 external-review fix (G4): -HeartbeatAt gets the SAME absent-vs-
    # unparseable treatment -LaunchedAt already got from the M6/M17 fix,
    # resolved BEFORE the liveness call rather than being handed raw to
    # Test-GoalRunInflightAppearsDead. Two failures were reachable through
    # this operator lever before the fix: a malformed non-null heartbeat threw
    # a raw [datetime] cast error out of the restart command entirely, and a
    # naive (no timezone suffix) heartbeat parsed Kind=Unspecified and was
    # then treated as LOCAL time by the elapsed-time math -- skewing the
    # verdict by the host's UTC offset, which on a positive-offset host makes
    # a LIVE run read as dead and lets restart clear its markers. Absence
    # remains the documented safe case (fall back to -LaunchedAt inside the
    # liveness call, exactly as before); a NON-NULL unparseable value is no
    # evidence either way and refuses with the same typed
    # 'refused-unparseable-state' outcome -LaunchedAt uses.
    $heartbeatForLivenessCheck = $null
    if ($HeartbeatAt) {
        $heartbeatForLivenessCheck = ConvertTo-GRSParsedUtcDateTimeOrNull -Value $HeartbeatAt
        if ($null -eq $heartbeatForLivenessCheck) {
            return [pscustomobject]@{
                Outcome            = 'refused-unparseable-state'
                Reason             = 'heartbeat-at-unparseable'
                ReportUrl          = $null
                BranchName         = $null
                BranchNameResolved = $false
                WorktreePath       = $WorktreePath
                ClearedStageMarker = $false
                ClearedActiveState = $false
            }
        }
    }

    if ($null -eq $LaunchedAt) {
        # Genuinely absent evidence -- e.g. a prior restart attempt already
        # cleared the active-state file but the marker delete failed. There
        # is nothing live to refuse against.
        $appearsDead = $true
    }
    else {
        $parsedLaunchedAt = ConvertTo-GRSParsedUtcDateTimeOrNull -Value $LaunchedAt
        if ($null -eq $parsedLaunchedAt) {
            # M17 fix: a NON-NULL but unparseable -LaunchedAt means the
            # active-state file exists but could not be read/parsed -- this
            # carries no assurance the run is safe to treat as dead. Fail
            # CLOSED rather than falling through to the old fail-open
            # $appearsDead = $true behavior.
            return [pscustomobject]@{
                Outcome             = 'refused-unparseable-state'
                Reason              = 'launched-at-unparseable'
                ReportUrl           = $null
                BranchName          = $null
                BranchNameResolved  = $false
                WorktreePath        = $WorktreePath
                ClearedStageMarker  = $false
                ClearedActiveState  = $false
            }
        }
        # G4: pass the ALREADY-PARSED, Kind-normalized heartbeat (or $null for
        # the absent case, which the liveness function falls back to
        # -LaunchedAt for), never the raw value.
        $appears = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $parsedLaunchedAt `
            -HeartbeatAt $heartbeatForLivenessCheck -HaltReportExists $false -PrExists $false -Now $Now -StaleThresholdMinutes $StaleThresholdMinutes
        $appearsDead = $appears.AppearsDead
    }

    if (-not $appearsDead) {
        return [pscustomobject]@{
            Outcome            = 'refused-live-run'
            Reason             = 'fresh-heartbeat'
            ReportUrl          = $null
            BranchName         = $null
            BranchNameResolved = $false
            WorktreePath       = $WorktreePath
            ClearedStageMarker = $false
            ClearedActiveState = $false
        }
    }

    # Capture BEFORE clearing anything -- resolve the branch name live from
    # the still-intact worktree (restart never deletes the worktree itself).
    $branchName = $null
    $branchNameResolved = $false
    try {
        $branchOutput = & $GitCliPath -C $WorktreePath rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branchOutput)) {
            $candidateBranchName = ($branchOutput | Out-String).Trim()
            # M18 fix: `git rev-parse --abbrev-ref HEAD` returns the literal
            # string 'HEAD' on a detached-HEAD worktree -- that is git's own
            # "could not determine a branch name" answer, not a real branch.
            # Recording it as if authoritative would present a non-answer as
            # the recovery path.
            if ($candidateBranchName -ne 'HEAD') {
                $branchName = $candidateBranchName
                $branchNameResolved = $true
            }
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
            BranchNameResolved = $branchNameResolved
            WorktreePath       = $WorktreePath
            ClearedStageMarker = $false
            ClearedActiveState = $false
        }
    }

    # Only clear once the report has landed -- capture-then-clear, never the
    # reverse, per the requirement contract's single most load-bearing rule.
    $clearedMarker = Clear-GoalRunStageMarker -Issue $Issue -Owner $Owner -Repo $Repo

    # #912 post-fix defense (F3): the two clears are NOT independent --
    # gate the second on the first's own success. Before this fix both ran
    # unconditionally in sequence, so an ambiguous-match refusal on the
    # stage-marker clear (Reason = 'marker-ambiguous') still let the
    # active-state clear proceed, producing an unrecoverable half-clear:
    # goal-run-active.json gone but the stage marker (the only durable
    # carrier of the worktree path) survives. When the stage-marker clear
    # itself did not succeed, do not proceed to clear the active-state
    # file at all -- the 'restarted-partial-marker-clear-failed' outcome
    # below already reports this honestly, and ClearedActiveState stays
    # $false to match.
    $clearedState = if ($clearedMarker.Success) { Clear-GoalRunActiveState -WorktreePath $WorktreePath } else { $false }

    # M18 fix: an honest outcome distinguishes a fully-completed restart
    # from one where the stage-marker clear itself did not actually succeed
    # -- the pre-fix code returned 'restarted' unconditionally here.
    #
    # #912 external-review fix (G2): the outcome was derived SOLELY from
    # $clearedMarker.Success, so a FAILED Clear-GoalRunActiveState after a
    # SUCCESSFUL marker clear still reported a clean 'restarted' -- and the
    # agent body's step 4 then resolved the mutex marker on the strength of
    # that word, with no signal anywhere that goal-run-active.json had in
    # fact survived. The stage marker (deleted) and the active-state file
    # (surviving) are different artifacts with different failure
    # consequences, so they get different outcomes rather than sharing one.
    $outcome = if (-not $clearedMarker.Success) {
        'restarted-partial-marker-clear-failed'
    }
    elseif (-not $clearedState) {
        'restarted-partial-active-state-clear-failed'
    }
    else {
        'restarted'
    }
    $reason = if (-not $clearedMarker.Success) {
        'stage-marker-clear-failed'
    }
    elseif (-not $clearedState) {
        'active-state-clear-failed'
    }
    else {
        'operator-restart'
    }

    return [pscustomobject]@{
        Outcome            = $outcome
        Reason             = $reason
        ReportUrl          = $report.Url
        BranchName         = $branchName
        BranchNameResolved = $branchNameResolved
        WorktreePath       = $WorktreePath
        ClearedStageMarker = $clearedMarker.Success
        ClearedActiveState = $clearedState
    }
}
