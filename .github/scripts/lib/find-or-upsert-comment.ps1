#Requires -Version 7.0
<#
.SYNOPSIS
    Find a GitHub issue/PR comment by marker and either update it or create a new one.

.DESCRIPTION
    Find-OrUpsertComment lists comments on the given issue or pull-request,
    selects the comment whose FIRST LINE is exactly the supplied marker
    (Test-CommentBodyMarkerLine1, marker-line1-selector.ps1), and either:

      * POSTs a new comment when no marker match exists,
      * PATCHes the existing comment when exactly one match exists,
      * PATCHes the earliest-id match (and warns about duplicates) when more
        than one match exists.

    All gh failures are fail-open: a stderr note is emitted via
    [Console]::Error.WriteLine(...) and the function returns $null. The caller
    decides whether the failure is fatal. (We use [Console]::Error.WriteLine
    rather than Write-Error to avoid Pester's error-handling failure mode in
    test mocks; see Step 2's report on issue #429.)

    Owner/repo are derived from `git config --get remote.origin.url` to avoid
    coupling to `gh repo view`. The mocked test surface for this library
    accepts the resulting `gh api repos/<owner>/<name> ...` and
    `gh api -X PATCH repos/<owner>/<name>/issues/comments/<id> ...` shapes.

.PARAMETER Type
    Either 'pr' or 'issue'. Determines which `gh ... comment` verb is used to
    POST a new comment on the zero-matches path. Listing always uses
    `gh issue view` (both PR and issue comments live on the unified issues
    endpoint in the GitHub API).

.PARAMETER Number
    The PR or issue number on the current repository.

.PARAMETER Marker
    The HTML-comment marker used to recognise prior upsert output. It must be
    the ENTIRE first line of the comment this function is meant to reach.
    Leading whitespace on that line disqualifies a match; trailing whitespace
    is immaterial on BOTH sides — the marker argument and the comment line are
    each TrimEnd-ed before comparison, so the test is reflexive. It is NOT a
    substring, a prefix, or a whole-line match anywhere in the body.

    A whitespace-only marker is refused at the top of the function, before
    any gh call, and the function returns $null. That guard is load-bearing
    rather than decorative: this parameter is a mandatory [string], which
    rejects the empty string but lets a whitespace-only one straight through,
    and the selection predicate then declines to match anything — which is
    the zero-match branch, which POSTs. Without the guard a degenerate marker
    produced a fresh comment on every run instead of a refusal.

    Issue #1031 (parent #1011 AC2) narrowed this from `-like "*$Marker*"`.
    Under the old rule a marker QUOTED IN PROSE — mid-line, inside backticks,
    or alone on its own line inside a fenced block — was enough to select an
    unrelated comment, whose body this function then REPLACED. The live
    corpus carried one such comment: the approved plan comment for issue #782
    (#issuecomment-4861653613) quotes `pc-emission-check-report` (delimiters
    intact there, stripped here) on its line 37, and was the only match on
    that issue, so the next emission-check post to #782 would have
    overwritten the plan.
    See marker-line1-selector.ps1 for the full rationale and for why a
    line anchor is not sufficient.

.PARAMETER Body
    The new body text to write. Replaces the existing body verbatim on the
    PATCH path; sent as the body of a new comment on the POST path.

.PARAMETER Owner
    Optional. Repository owner. When supplied together with -Repo, every
    underlying `gh` call is explicitly repo-targeted via `-R "$Owner/$Repo"`
    instead of relying on `gh`'s ambient-cwd repo resolution. F2 fix (issue
    #878 review): every other gh-calling helper in this file's sibling
    persist-phase-ledger-core.ps1 already threads explicit -Owner/-Repo, but
    this function alone derived owner/repo from `git config --get
    remote.origin.url` and issued every `gh` call with no `-R`, so a caller
    whose cwd's git remote did not match its intended target repo would
    silently create/patch a comment in the wrong repo.

.PARAMETER Repo
    Optional. Repository name. See -Owner.

.OUTPUTS
    [string] The html_url of the upserted comment on success, or $null when
    any underlying gh call fails.
#>

# The line-1-exact selection predicate (issue #1031). Its own file, with no
# side effects at dot-source time, so the two selectors that must reach the
# SAME comment this one reaches can import it without importing
# Find-OrUpsertComment (which shadows Pester mocks) or marker-transport-core
# (which mutates [Console]::OutputEncoding process-wide). See that file's
# .DESCRIPTION.
. (Join-Path $PSScriptRoot 'marker-line1-selector.ps1')

# ---------------------------------------------------------------------------
# Helper: Get-RestCommentId
# (issue #492 Step 5 — hoisted from inside Find-OrUpsertComment per plan D9)
#
# Extracts the numeric REST comment ID from a comment object returned by
# `gh issue view --json comments`. The GraphQL `id` field contains a node ID
# string (e.g. IC_kwDO...) rather than the numeric REST ID required by the
# PATCH endpoint. We extract the numeric ID from the `url` field when present
# (the URL always ends in #issuecomment-<numeric-id>), falling back to a
# direct [long] cast for callers that supply pre-resolved numeric IDs.
#
# Defined at file scope (not inside Find-OrUpsertComment) so that:
#   - It is resolvable after dot-sourcing the library, without calling
#     Find-OrUpsertComment first.
#   - It can be tested independently via Get-Command and AST inspection.
# ---------------------------------------------------------------------------

function Get-RestCommentId([object]$c) {
    if ($c.url -and ($c.url -match '#issuecomment-(\d+)$')) { return [long]$Matches[1] }
    try { return [long]$c.id } catch { return $null }
}

# ---------------------------------------------------------------------------
# Helper: Send-NewCommentViaBodyFile
# (M26 fix, issue #1035 review) — hardens the POST (zero-match) path the
# same way the PATCH path was hardened (Fix Pass3-F1 below): `gh issue
# comment`/`gh pr comment --body $Body` packs the entire comment body into a
# single argv element, which hits the ~32K Windows CreateProcess argv limit
# for large documents. A new caller (the full-glob CI audit, issue #1035)
# composes comments up to GitHub's 65,536-codepoint cap and, because its
# record markers embed a run id, every run necessarily takes THIS path --
# no prior comment ever exists to match, so there is no PATCH fallback to
# rely on. `--body-file` is the `gh issue/pr comment` CLI's own file-based
# equivalent of `gh api --input`, so this reuses that same temp-file
# mechanism rather than inventing a second one.
#
# Defined at file scope (mirrors Get-RestCommentId above) so both POST call
# sites inside Find-OrUpsertComment (zero-match, and the no-resolvable-id
# fallback) share one implementation instead of duplicating the temp-file
# lifecycle.
#
# NOTE ON $LASTEXITCODE: the caller inspects $LASTEXITCODE immediately after
# calling this helper. `Remove-Item` in the `finally` block below is a
# cmdlet, not a native executable, so it does not touch $LASTEXITCODE --
# the value set by `& gh @postArgs` survives the cleanup and is still
# current when this function returns.
# ---------------------------------------------------------------------------
function Send-NewCommentViaBodyFile {
    param(
        [Parameter(Mandatory)][string]$Verb,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Body,
        [bool]$ExplicitRepo,
        [string]$ResolvedOwner,
        [string]$ResolvedRepo
    )
    $bodyTempFile = $null
    $postOutput = $null
    try {
        $bodyTempFile = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $bodyTempFile -Value $Body -Encoding UTF8 -NoNewline
        $postArgs = @($Verb, 'comment', $Number, '--body-file', $bodyTempFile)
        if ($ExplicitRepo) { $postArgs += @('-R', "$ResolvedOwner/$ResolvedRepo") }
        $postOutput = & gh @postArgs 2>$null
    }
    finally {
        if ($null -ne $bodyTempFile -and (Test-Path -LiteralPath $bodyTempFile)) {
            Remove-Item -LiteralPath $bodyTempFile -Force -ErrorAction SilentlyContinue
        }
    }
    return $postOutput
}

function Find-OrUpsertComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('pr', 'issue')][string]$Type,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body,
        [string]$Owner,
        [string]$Repo
    )

    # Whitespace-only marker: refuse before any gh call (#1031, external
    # review). The predicate correctly declines to SELECT on such a marker,
    # but declining to select is the zero-match branch below, which POSTs a
    # new comment -- so a degenerate marker would have produced a fresh
    # comment on every run rather than a refusal. `[Parameter(Mandatory)]`
    # on a [string] rejects '' at binding and lets '   ' straight through,
    # so the binding is not the guard. Returns $null, matching the fail-open
    # contract every other failure path here uses.
    if ([string]::IsNullOrWhiteSpace($Marker)) {
        [Console]::Error.WriteLine('Find-OrUpsertComment: -Marker is whitespace-only; refusing rather than posting a new comment.')
        return $null
    }

    # F2 fix (issue #878 review): when the caller explicitly supplies both
    # -Owner and -Repo, use them for every gh call below via -R "$owner/$repo"
    # instead of deriving owner/repo from the ambient git remote. Existing
    # callers that omit these params (frame-credit-ledger.ps1,
    # phase-containment-emission-check.ps1) are unaffected -- $explicitRepo
    # is $false for them and the git-remote-derived behavior below is
    # unchanged.
    $explicitRepo = ($Owner -and $Repo)

    # --- Derive owner/repo from the git remote (does not depend on gh),
    #     unless the caller already supplied both explicitly above. ---
    # NOTE: these locals are named $resolvedOwner/$resolvedRepo (not
    # $owner/$repo) deliberately. PowerShell variable names are
    # case-insensitive, so a local named $owner is the SAME variable as the
    # -Owner parameter -- assigning $owner = $null here would null out the
    # caller-supplied $Owner parameter itself (P4 fix, post-#878-review
    # regression: this collision silently emptied both params on every call
    # that passed them explicitly).
    $resolvedOwner = $null
    $resolvedRepo = $null
    if ($explicitRepo) {
        $resolvedOwner = $Owner
        $resolvedRepo = $Repo
    }
    else {
        $remoteUrl = $null
        try {
            $remoteUrl = (& git config --get remote.origin.url) 2>$null
        }
        catch {
            $remoteUrl = $null
        }

        if ($remoteUrl -and ($remoteUrl -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?\s*$')) {
            $resolvedOwner = $Matches[1]
            $resolvedRepo = $Matches[2]
        }
    }

    # Optional: surface the repos/<owner>/<repo> probe so callers (and the
    # test mock) see the resolved coordinates. Result is informational only;
    # we already have $owner/$repo from either the explicit params or the
    # git remote.
    #
    # We deliberately do NOT mutate $global:LASTEXITCODE here. The probe's
    # exit code is irrelevant to the caller — only the list/post/patch calls
    # below need their exit codes inspected, and each one is checked
    # immediately after invocation (so a stale $LASTEXITCODE from this probe
    # cannot leak past those checks).
    if ($resolvedOwner -and $resolvedRepo) {
        $null = & gh api "repos/$resolvedOwner/$resolvedRepo" --jq '.full_name' 2>$null
    }

    # --- 1. List comments on the issue/PR. ---
    $listArgs = @('issue', 'view', $Number, '--json', 'comments')
    if ($explicitRepo) { $listArgs += @('-R', "$resolvedOwner/$resolvedRepo") }
    $listJson = & gh @listArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Find-OrUpsertComment: gh issue view $Number failed (exit $LASTEXITCODE)")
        return $null
    }

    $comments = @()
    if ($listJson) {
        try {
            $parsed = $listJson | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -and $parsed.comments) {
                $comments = @($parsed.comments)
            }
        }
        catch {
            [Console]::Error.WriteLine("Find-OrUpsertComment: failed to parse comments JSON: $($_.Exception.Message)")
            return $null
        }
    }

    # --- 2. Filter: the marker must be the comment's own line-1 payload. ---
    # Issue #1031 / parent #1011 AC2. Was `$_.body -like "*$Marker*"`, which
    # let a marker quoted anywhere in prose select a comment this function
    # then destroyed by the whole-body PATCH below. A line anchor would not
    # have been enough — see marker-line1-selector.ps1.
    $matchedComments = @($comments | Where-Object {
            $_.body -and (Test-CommentBodyMarkerLine1 -Body ([string]$_.body) -Marker $Marker)
        })

    # --- 3. Branch on match count. ---
    if ($matchedComments.Count -eq 0) {
        # POST a new comment via the appropriate verb. Body is streamed
        # through a temp file via --body-file (M26 fix, issue #1035 review)
        # rather than packed into a raw argv element -- see
        # Send-NewCommentViaBodyFile above for why.
        $verb = if ($Type -eq 'pr') { 'pr' } else { 'issue' }
        $postOutput = Send-NewCommentViaBodyFile -Verb $verb -Number $Number -Body $Body -ExplicitRepo $explicitRepo -ResolvedOwner $resolvedOwner -ResolvedRepo $resolvedRepo
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("Find-OrUpsertComment: gh $verb comment failed (exit $LASTEXITCODE; body_length_chars=$($Body.Length))")
            return $null
        }
        return ($postOutput | Out-String).Trim()
    }

    # 1+ matches: pick lowest REST (numeric) id, warn on duplicates.
    # gh issue view --json comments returns GraphQL node IDs (e.g. IC_kwDO...) in
    # the `id` field, not the numeric REST comment ID that the PATCH endpoint
    # requires. Get-RestCommentId (hoisted to file scope in issue #492 Step 5)
    # extracts the numeric ID from the comment's `url` field.
    #
    # Materialize (Comment, RestId) pairs up front to avoid calling
    # Get-RestCommentId twice per entry in Where-Object + Sort-Object.
    $pairs = @($matchedComments |
        ForEach-Object { [PSCustomObject]@{ Comment = $_; RestId = Get-RestCommentId $_ } } |
        Where-Object { $null -ne $_.RestId })
    $sorted = @($pairs | Sort-Object -Property RestId)
    if ($sorted.Count -eq 0) {
        [Console]::Error.WriteLine("Find-OrUpsertComment: matched comment(s) have no resolvable REST id; posting new comment.")
        # Same --body-file hardening as the zero-match POST path above (M26
        # fix, issue #1035 review) -- see Send-NewCommentViaBodyFile.
        $verb = if ($Type -eq 'pr') { 'pr' } else { 'issue' }
        $postOutput = Send-NewCommentViaBodyFile -Verb $verb -Number $Number -Body $Body -ExplicitRepo $explicitRepo -ResolvedOwner $resolvedOwner -ResolvedRepo $resolvedRepo
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("Find-OrUpsertComment: gh $verb comment failed (exit $LASTEXITCODE; body_length_chars=$($Body.Length))")
            return $null
        }
        return ($postOutput | Out-String).Trim()
    }
    $target = $sorted[0].Comment
    $targetRestId = $sorted[0].RestId
    if ($sorted.Count -gt 1) {
        $dupIds = ($sorted | Select-Object -Skip 1 | ForEach-Object { $_.RestId }) -join ', '
        [Console]::Error.WriteLine("Find-OrUpsertComment: multiple comments match marker '$Marker' (duplicates: $dupIds); patching earliest id $targetRestId")
    }

    if (-not ($resolvedOwner -and $resolvedRepo)) {
        [Console]::Error.WriteLine("Find-OrUpsertComment: unable to determine owner/repo from git remote; cannot PATCH comment.")
        return $null
    }

    $patchPath = "repos/$resolvedOwner/$resolvedRepo/issues/comments/$targetRestId"
    # Fix Pass3-F1: pass body via JSON file on stdin instead of `-f "body=$Body"`.
    # The -f form packs the entire payload into a single argv element, which on
    # Windows hits the 32K CreateProcess argv limit for large cost-pattern
    # ledgers (multi-KB markdown table + embedded YAML). The `--input -` form
    # streams the JSON body via stdin and is unaffected by argv length limits.
    # Also surface the body length on failure so silent fail-open at large
    # payloads is observable.
    $patchTempFile = $null
    try {
        $patchTempFile = [System.IO.Path]::GetTempFileName()
        $patchPayload = @{ body = $Body } | ConvertTo-Json -Depth 4 -Compress
        Set-Content -LiteralPath $patchTempFile -Value $patchPayload -Encoding UTF8 -NoNewline
        $patchOutput = & gh api -X PATCH $patchPath --input $patchTempFile 2>$null
    }
    finally {
        if ($null -ne $patchTempFile -and (Test-Path -LiteralPath $patchTempFile)) {
            Remove-Item -LiteralPath $patchTempFile -Force -ErrorAction SilentlyContinue
        }
    }
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Find-OrUpsertComment: gh api PATCH $patchPath failed (exit $LASTEXITCODE; body_length_chars=$($Body.Length))")
        return $null
    }

    try {
        $patchObj = $patchOutput | ConvertFrom-Json -ErrorAction Stop
        if ($patchObj -and $patchObj.html_url) {
            return [string]$patchObj.html_url
        }
    }
    catch {
        # fall through
    }
    return ($patchOutput | Out-String).Trim()
}
