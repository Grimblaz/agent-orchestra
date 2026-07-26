#Requires -Version 7.0

<#
.SYNOPSIS
    Marker-anchored GitHub-comment transport primitives (issue #893, plan
    slice s2).

.DESCRIPTION
    Promoted (byte-identical behavior; only the name loses its PPL prefix
    and the implementation moves here so a future marker-write caller and
    skills/session-memory-contract/scripts/persist-phase-ledger-core.ps1's
    own PPL-prefixed names -- now kept as one-line delegators to these, see
    that file's comments -- share one implementation instead of two
    drifting copies):
      - Find-CommentIdByExactMarker  (was Find-PPLCommentIdByExactMarker)
      - Get-CommentBodyById          (was Get-PPLCommentBodyById)
      - Set-CommentBodyDirect        (was Set-PPLCommentBodyDirect)
      - Get-CommentIdFromUrl         (was Get-PPLCommentIdFromUrl)
      - Set-PointerLineAfterMarker   (was Set-PPLPointerLineAfterMarker;
        generalized to take the pointer line text itself instead of a
        phase-containment-ledger-specific -SiblingId, so a future
        marker-write path can reuse the same CRLF-safe insertion logic for
        its own, differently-shaped pointer line -- duplicating that logic
        would risk re-opening the shipped bug class its fallback branch
        guards against: prepending a duplicate marker on a body whose
        marker line uses CRLF line endings.)

    Net-new (nothing shipped before this file expresses either):
      - New-MarkerComment
        Create-only POST primitive: no search, no upsert semantics
        (contrast Find-OrUpsertComment, .github/scripts/lib/find-or-upsert-comment.ps1,
        which always lists and searches first). Explicit non-goal: this
        file does not modify or wrap Find-OrUpsertComment.
      - Find-AllCommentsByExactMarker
        Paginated full-enumeration selector, used ONLY by the new
        persist-marker path (a later slice). Find-CommentIdByExactMarker
        above remains the un-paginated, single-result selector every
        existing PPL caller uses today. Queries the unified REST endpoint
        `repos/{Owner}/{Repo}/issues/{IssueNumber}/comments` directly (both
        issue and PR comments live on this same endpoint -- surface
        agnostic), NOT `gh issue view --json comments` (whose single-page
        JSON payload `Find-CommentIdByExactMarker` reads). `--paginate`
        follows every page with no early-exit and no page cap; a page
        request failing partway through the walk makes the whole `gh`
        invocation exit non-zero, which this function turns into a thrown
        exception rather than a silently empty/partial result.

    Like its promoted source, this file does NOT dot-source
    find-or-upsert-comment.ps1 itself. Find-CommentIdByExactMarker assumes
    Get-RestCommentId (find-or-upsert-comment.ps1) is already in the
    caller's scope, exactly as persist-phase-ledger-core.ps1 always
    required -- callers are responsible for dot-sourcing
    find-or-upsert-comment.ps1 before this file when they call
    Find-CommentIdByExactMarker. Find-AllCommentsByExactMarker has no such
    dependency: the unified REST endpoint's own `id` field is already the
    numeric REST id (unlike `gh issue view --json comments`'s GraphQL node
    id), so no id-extraction helper is needed there.

.NOTES
    Non-goals (explicit, per the requirement contract this file
    implements): no change to Find-OrUpsertComment
    (.github/scripts/lib/find-or-upsert-comment.ps1, the separate #429-era
    upsert helper); no GraphQL anywhere in this file.
#>

# Read-side UTF-8 pin (CE Gate live-run fix, issue #893 S1/S3(a)): every
# function below that captures `gh api` stdout via the `&` call operator --
# Get-CommentBodyById, Get-CommentBodyByIdWithStatus, Set-CommentBodyDirect
# (its own post-write verify GET), and Find-AllCommentsByExactMarker --
# otherwise decodes that captured output through [Console]::OutputEncoding,
# which defaults to the host's legacy OEM/DOS code page (e.g. CP437 on
# Windows), not UTF-8. Any non-ASCII byte in a marker-family body (emoji,
# accented characters, an em-dash, a homoglyph) then round-trips corrupted,
# which fails Test-MarkerReadBack's normalized-equality gate and -- because
# the corrupted read-back never matches the write candidate either --
# defeats post-new/upsert idempotency, so a re-run posts a duplicate comment
# instead of converging (CE Gate S1 and S3(a)).
#
# This is the SAME process-wide-static class of bug already fixed at
# .github/scripts/frame-credit-ledger.ps1:63 and
# .github/scripts/orchestra-spine.ps1:15 (see also the C2 relocation history
# in .github/scripts/lib/cost-baseline-harvest.ps1:1575). Those fixes pin at
# each TOP-LEVEL ENTRY POINT; this file has no single entry point of its
# own -- it is dot-sourced directly by multiple wrappers
# (skills/session-memory-contract/scripts/persist-marker.ps1 AND
# skills/session-memory-contract/scripts/persist-phase-ledger.ps1, the
# latter carrying no OutputEncoding pin of its own anywhere in its own call
# chain today) and is documented (this file's own .DESCRIPTION) as safe to
# dot-source directly, bypassing any wrapper. Pinning only in one wrapper
# would leave every other caller -- present or future -- silently exposed
# again, exactly the fragility class the cost-baseline-harvest.ps1 C2 fix
# already had to correct once. Pinning HERE, as this file's own first
# top-level statement, fires at dot-source time regardless of which caller
# loads it, before any of this file's functions can run, and needs no
# per-caller opt-in.
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch {
    [Console]::Error.WriteLine("marker-transport-core: console UTF-8 pin failed: $($_.Exception.Message)")
}

# ---------------------------------------------------------------------------
# Promoted (byte-identical behavior vs. the PPL-prefixed originals; see
# persist-phase-ledger-core.ps1's own comments for the delegators that now
# call these).
# ---------------------------------------------------------------------------

function Get-MarkerWholeLinePattern {
    <#
    .SYNOPSIS
        Shared "marker appears as a whole, standalone line" detection regex
        (s10 consolidation): byte-identical construction previously
        duplicated between Find-CommentIdByExactMarker and
        Find-AllCommentsByExactMarker.
    .OUTPUTS
        [string] a multiline-anchored regex pattern matching -Marker at line
        start, modulo surrounding whitespace, through end of line.
    #>
    param([Parameter(Mandatory)][string]$Marker)
    return "(?m)^\s*$([regex]::Escape($Marker))\s*`$"
}

function Get-CommentIdFromUrl {
    <#
    .SYNOPSIS
        Extracts the numeric REST comment id from a plain html_url STRING
        (e.g. Find-OrUpsertComment's or New-MarkerComment's return value on
        the create path). Get-RestCommentId (find-or-upsert-comment.ps1)
        only accepts a comment OBJECT exposing .url/.id and would silently
        cast a bare string to $null via its [long]$c.id fallback.
    .OUTPUTS
        [long] or $null when the url does not carry a trailing
        #issuecomment-{id} fragment.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)
    if ($Url -match '#issuecomment-(\d+)\s*$') { return [long]$Matches[1] }
    return $null
}

function Get-CommentBodyById {
    <#
    .SYNOPSIS
        Reads a comment's current body by numeric REST id. No shipped
        primitive returns a body for a known id without also mutating it.
    .OUTPUTS
        [string] or $null on any gh/parse failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId
    )
    $getPath = "repos/$Owner/$Repo/issues/comments/$CommentId"
    $getOutput = & gh api $getPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("marker-transport-core: gh api GET $getPath failed (exit $LASTEXITCODE)")
        return $null
    }
    try {
        $obj = $getOutput | ConvertFrom-Json -ErrorAction Stop
        return [string]$obj.body
    }
    catch {
        [Console]::Error.WriteLine("marker-transport-core: failed to parse GET response for comment ${CommentId}: $($_.Exception.Message)")
        return $null
    }
}

function Get-CommentBodyByIdWithStatus {
    <#
    .SYNOPSIS
        M19 fix (issue #893 s11): richer sibling of Get-CommentBodyById that
        distinguishes a confirmed-absent/wrong target (HTTP 404) from any
        OTHER GET failure (network blip, rate limit, auth, transient 5xx,
        etc.) -- Get-CommentBodyById's own "$null on any failure" contract
        collapses both into the identical signal, which let
        Test-MarkerSiblingIdentity (persist-marker-core.ps1) silently treat
        a transient GET failure exactly the same as "this pointer's target
        genuinely doesn't carry the expected marker", dropping a LIVE
        sibling pointer on nothing more than a network blip.
    .DESCRIPTION
        Captures `gh`'s stderr (rather than discarding it via `2>$null` like
        Get-CommentBodyById does) so a genuine HTTP 404 ("Not Found") can be
        distinguished, by message content, from every other non-zero-exit
        failure. `gh api`'s own error text for a missing resource always
        includes the literal HTTP status, so this is a real signal, not a
        guess.
    .OUTPUTS
        [PSCustomObject] Status ['ok'|'not-found'|'error'], Body [string or
        $null] (populated only when Status='ok'), ErrorMessage [string or
        $null] (populated only when Status='error').
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId
    )
    $getPath = "repos/$Owner/$Repo/issues/comments/$CommentId"
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $getOutput = & gh api $getPath 2>$stderrFile
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $stderrText = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
            if ($null -eq $stderrText) { $stderrText = '' }
            if ($stderrText -match '(?i)HTTP 404|Not Found \(HTTP 404\)|404 Not Found') {
                return [PSCustomObject]@{ Status = 'not-found'; Body = $null; ErrorMessage = $null }
            }
            [Console]::Error.WriteLine("marker-transport-core: gh api GET $getPath failed (exit $exitCode): $stderrText")
            return [PSCustomObject]@{ Status = 'error'; Body = $null; ErrorMessage = "gh api GET $getPath failed (exit ${exitCode}): $stderrText" }
        }
        try {
            $obj = $getOutput | ConvertFrom-Json -ErrorAction Stop
            return [PSCustomObject]@{ Status = 'ok'; Body = [string]$obj.body; ErrorMessage = $null }
        }
        catch {
            [Console]::Error.WriteLine("marker-transport-core: failed to parse GET response for comment ${CommentId}: $($_.Exception.Message)")
            return [PSCustomObject]@{ Status = 'error'; Body = $null; ErrorMessage = "failed to parse GET response for comment ${CommentId}: $($_.Exception.Message)" }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stderrFile) {
            Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-CommentBodyDirect {
    <#
    .SYNOPSIS
        Raw full-body PATCH for a known numeric comment id, with a
        post-write verify GET guarding against a PATCH that exit-0'd but
        silently truncated or corrupted the body.
    .OUTPUTS
        [PSCustomObject] with Success [bool] and Reason [string] (populated
        only when Success=$false).
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewBody
    )
    $patchPath = "repos/$Owner/$Repo/issues/comments/$CommentId"
    $patchTempFile = $null
    try {
        $patchTempFile = [System.IO.Path]::GetTempFileName()
        $patchPayload = @{ body = $NewBody } | ConvertTo-Json -Depth 4 -Compress
        Set-Content -LiteralPath $patchTempFile -Value $patchPayload -Encoding UTF8 -NoNewline
        $null = & gh api -X PATCH $patchPath --input $patchTempFile 2>$null
    }
    finally {
        if ($null -ne $patchTempFile -and (Test-Path -LiteralPath $patchTempFile)) {
            Remove-Item -LiteralPath $patchTempFile -Force -ErrorAction SilentlyContinue
        }
    }
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("marker-transport-core: gh api PATCH $patchPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "PATCH failed (exit $LASTEXITCODE)" }
    }

    # Positive-proof verify: re-GET and confirm the write actually landed,
    # catching a PATCH that exit-0'd but silently truncated or corrupted the
    # body.
    $verifyOutput = & gh api $patchPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("marker-transport-core: post-write verify GET $patchPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify GET failed (exit $LASTEXITCODE)" }
    }
    try {
        $verifyObj = $verifyOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("marker-transport-core: failed to parse post-write verify JSON for comment ${CommentId}: $($_.Exception.Message)")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify response is not valid JSON: $($_.Exception.Message)" }
    }
    $verifyBody = [string]$verifyObj.body

    # Exact match is the common case; GitHub's API can benignly normalize
    # some whitespace on write/read, so an ordinal mismatch alone is not
    # proof of corruption. Fall back to a gross-truncation guard: a
    # benignly-normalized body trims at most a handful of characters, never
    # a large fraction of the body.
    if ($verifyBody -ne $NewBody) {
        $expectedMinLength = [int]($NewBody.Length * 0.5)
        if ($verifyBody.Length -lt $expectedMinLength) {
            [Console]::Error.WriteLine("marker-transport-core: post-write verify FAILED -- verify body ($($verifyBody.Length) chars) is dramatically shorter than the written body ($($NewBody.Length) chars) for comment $CommentId.")
            return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: verify body ($($verifyBody.Length) chars) is dramatically shorter than expected ($($NewBody.Length) chars written)" }
        }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

function Find-CommentIdByExactMarker {
    <#
    .SYNOPSIS
        Find-only comment selector: lists comments on the issue (or PR --
        both surfaces share the unified `gh issue view` comments listing)
        and returns the numeric REST id of the one whose body carries the
        given marker LINE-ANCHORED AND WHOLE (the entire line, modulo
        surrounding whitespace, must equal the marker exactly).
    .DESCRIPTION
        Deliberately NOT Find-OrUpsertComment's -like substring match,
        which would select a comment that merely quotes the marker in
        prose (e.g. inside backticks mid-sentence). Ties (multiple genuine
        line-anchored matches) resolve to the lowest REST id, mirroring
        Find-OrUpsertComment's own earliest-id convention. Id extraction
        reuses Get-RestCommentId (find-or-upsert-comment.ps1), assumed
        already in the caller's scope -- see this file's header.
    .OUTPUTS
        [PSCustomObject] with Id [long] and Body [string], or $null when no
        comment's body carries the marker as a whole, standalone line.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$Marker
    )

    $listJson = & gh issue view $IssueNumber --json comments -R "$Owner/$Repo" 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("marker-transport-core: gh issue view $IssueNumber failed (exit $LASTEXITCODE)")
        return $null
    }

    $comments = @()
    if ($listJson) {
        try {
            $parsed = $listJson | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -and $parsed.comments) { $comments = @($parsed.comments) }
        }
        catch {
            [Console]::Error.WriteLine("marker-transport-core: failed to parse comments JSON for issue ${IssueNumber}: $($_.Exception.Message)")
            return $null
        }
    }

    $linePattern = Get-MarkerWholeLinePattern -Marker $Marker
    $matched = @($comments | Where-Object { $_.body -and ([regex]::IsMatch([string]$_.body, $linePattern)) })
    if ($matched.Count -eq 0) { return $null }

    $pairs = @($matched |
        ForEach-Object { [PSCustomObject]@{ Comment = $_; RestId = Get-RestCommentId $_ } } |
        Where-Object { $null -ne $_.RestId })
    if ($pairs.Count -eq 0) { return $null }

    $target = @($pairs | Sort-Object -Property RestId)[0]
    return [PSCustomObject]@{ Id = $target.RestId; Body = [string]$target.Comment.body }
}

function Set-PointerLineAfterMarker {
    <#
    .SYNOPSIS
        Inserts the given pointer line immediately after a marker line,
        preserving the rest of the body byte-identical. Adds exactly one
        blank line on each side of the pointer, matching the existing
        marker-to-body blank-line convention.
    .DESCRIPTION
        Trailing whitespace on the marker-line match is deliberately
        restricted to spaces/tabs only (never `\s`, which also matches
        newlines): `\s*$` would let the greedy-then-backtracking engine
        swallow the marker's own trailing blank line into the match itself,
        shifting the insert position past it and silently dropping a
        newline from the reconstructed body. `\r?` immediately before the
        closing multiline `$` absorbs a CRLF body's own carriage return
        (`$` anchors immediately before `\n`, not before `\r\n`) -- without
        it, a CRLF-bodied comment (any web-UI-edited comment) falls through
        to the fallback branch below, which prepends a duplicate marker
        instead of inserting the pointer in place.
    .OUTPUTS
        [string] the new comment body.
    #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$PointerLine
    )
    $markerLineMatch = [regex]::Match($Body, "(?m)^\s*$([regex]::Escape($Marker))[ \t]*\r?`$")
    if (-not $markerLineMatch.Success) {
        # Defensive fallback (should be unreachable -- the caller already
        # confirmed the marker's presence via a prior find call).
        return "$Marker`n`n$PointerLine`n`n$Body"
    }
    $insertPos = $markerLineMatch.Index + $markerLineMatch.Length
    $before = $Body.Substring(0, $insertPos)
    $after = $Body.Substring($insertPos) -replace '^(\r?\n)+', ''
    return $before + "`n`n$PointerLine`n`n" + $after
}

# ---------------------------------------------------------------------------
# Net-new (nothing shipped before this file expresses either).
# ---------------------------------------------------------------------------

function New-MarkerComment {
    <#
    .SYNOPSIS
        Create-only POST primitive: creates a new issue/PR comment carrying
        the given body, with no search and no upsert semantics (contrast
        Find-OrUpsertComment, which always lists and searches for an
        existing match first).
    .DESCRIPTION
        M2 fix (issue #893 s11): the body is written to a temp file and
        passed via `--body-file`, mirroring Set-CommentBodyDirect's own
        `--input`-tempfile approach -- never inlined as a raw `--body`
        argv element. A body in the 32,768-65,536 char band (admitted by
        this file's own size cap, enforced by
        script:Test-MarkerCandidatePreflight) previously exceeded Windows'
        ~32,767-char command-line length limit when passed as a literal
        argv element, crashing the native process launch with an uncaught
        exception instead of the promised refusal/fail-open contract. The
        native invocation itself is now wrapped in try/catch so any launch
        failure (oversized argv or otherwise) becomes the SAME fail-open
        $null return every other failure path in this function already
        uses, never an uncaught exception.
    .OUTPUTS
        [string] the raw POST output (an html_url on current gh versions)
        on success, or $null when the POST fails (fail-open, matching this
        file's other gh-calling primitives).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('issue', 'pr')][string]$Type,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Body
    )
    $bodyTempFile = $null
    $postOutput = $null
    $launchFailed = $false
    try {
        $bodyTempFile = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $bodyTempFile -Value $Body -Encoding UTF8 -NoNewline
        $postArgs = @($Type, 'comment', $Number, '--body-file', $bodyTempFile, '-R', "$Owner/$Repo")
        try {
            $postOutput = & gh @postArgs 2>$null
        }
        catch {
            [Console]::Error.WriteLine("marker-transport-core: gh $Type comment $Number threw a native-process launch failure: $($_.Exception.Message)")
            $launchFailed = $true
        }
    }
    finally {
        if ($null -ne $bodyTempFile -and (Test-Path -LiteralPath $bodyTempFile)) {
            Remove-Item -LiteralPath $bodyTempFile -Force -ErrorAction SilentlyContinue
        }
    }
    if ($launchFailed) {
        return $null
    }
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("marker-transport-core: gh $Type comment $Number failed (exit $LASTEXITCODE)")
        return $null
    }
    return ($postOutput | Out-String).Trim()
}

function Find-AllCommentsByExactMarker {
    <#
    .SYNOPSIS
        Paginated full-enumeration selector, used ONLY by the new
        persist-marker path (a later slice) -- every existing caller keeps
        using the un-paginated, single-result Find-CommentIdByExactMarker
        above.
    .DESCRIPTION
        Uses `gh api --paginate` against the unified
        repos/{Owner}/{Repo}/issues/{IssueNumber}/comments REST endpoint
        (surface-agnostic for issues and PRs alike -- both comment kinds
        live on this same endpoint), NOT `gh issue view --json comments`
        (a single-page listing). `--paginate` follows every page with no
        early-exit and no page cap; `gh`'s own array auto-merge collapses
        the paginated, array-typed response into one JSON array on stdout,
        so this function issues exactly one external call and parses
        exactly one JSON payload.

        A pagination failure -- `gh` exits non-zero because a page request
        failed partway through the walk -- throws rather than returning an
        empty/partial result: silently returning "no matches" would be
        indistinguishable from a genuine zero-match outcome to every
        caller, and the marker-write path this selector feeds must never
        treat a transport failure as license to create a new comment.
    .OUTPUTS
        [PSCustomObject[]] with Id [long] and Body [string] for every
        matching comment, in ascending REST-id order. Empty array (never
        $null) when zero comments match. Throws on any gh/parse failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$Marker
    )

    $apiPath = "repos/$Owner/$Repo/issues/$IssueNumber/comments"
    $listOutput = & gh api --paginate $apiPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "marker-transport-core: gh api --paginate $apiPath failed (exit $LASTEXITCODE)"
    }

    $listText = ($listOutput | Out-String)
    $allComments = @()
    if ($listText -and $listText.Trim()) {
        try {
            $parsed = $listText | ConvertFrom-Json -ErrorAction Stop
            $allComments = @($parsed)
        }
        catch {
            throw "marker-transport-core: failed to parse --paginate response for ${apiPath}: $($_.Exception.Message)"
        }
    }

    $linePattern = Get-MarkerWholeLinePattern -Marker $Marker
    $matched = @($allComments | Where-Object { $_.body -and ([regex]::IsMatch([string]$_.body, $linePattern)) })

    # Explicit empty-array guard, PLUS the unary-comma return below: a
    # zero-iteration `foreach` assignment collapses to $null (not @()), and
    # -- separately -- PowerShell unrolls any array written to the output
    # stream into its individual elements, so a bare `return @(...)` still
    # hands the CALLER a scalar (0 or 1 elements) or a naturally-collected
    # array (2+ elements) rather than a guaranteed array, silently
    # violating the documented "[PSCustomObject[]] ... empty array, never
    # $null" contract (skills/implementation-discipline/SKILL.md's
    # `return , @(...)` array-identity convention). The `,` forces the
    # whole array through as a single output-stream object in every case.
    if ($matched.Count -eq 0) { return , @() }

    $results = foreach ($c in $matched) {
        [PSCustomObject]@{ Id = [long]$c.id; Body = [string]$c.body }
    }
    return , @($results | Sort-Object -Property Id)
}
