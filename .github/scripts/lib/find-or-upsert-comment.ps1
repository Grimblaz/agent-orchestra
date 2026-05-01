#Requires -Version 7.0
<#
.SYNOPSIS
    Find a GitHub issue/PR comment by marker and either update it or create a new one.

.DESCRIPTION
    Find-OrUpsertComment lists comments on the given issue or pull-request,
    searches for the supplied marker via substring containment, and either:

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
    The HTML-comment marker (or any substring) used to recognise prior
    upsert output. Substring-contained, not whole-line equality.

.PARAMETER Body
    The new body text to write. Replaces the existing body verbatim on the
    PATCH path; sent as the body of a new comment on the POST path.

.OUTPUTS
    [string] The html_url of the upserted comment on success, or $null when
    any underlying gh call fails.
#>
function Find-OrUpsertComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('pr', 'issue')][string]$Type,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )

    # --- Derive owner/repo from the git remote (does not depend on gh). ---
    $remoteUrl = $null
    try {
        $remoteUrl = (& git config --get remote.origin.url) 2>$null
    }
    catch {
        $remoteUrl = $null
    }

    $owner = $null
    $repo = $null
    if ($remoteUrl -and ($remoteUrl -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?\s*$')) {
        $owner = $Matches[1]
        $repo = $Matches[2]
    }

    # Optional: surface the repos/<owner>/<repo> probe so callers (and the
    # test mock) see the resolved coordinates. Result is informational only;
    # we already have $owner/$repo from the git remote.
    #
    # We deliberately do NOT mutate $global:LASTEXITCODE here. The probe's
    # exit code is irrelevant to the caller — only the list/post/patch calls
    # below need their exit codes inspected, and each one is checked
    # immediately after invocation (so a stale $LASTEXITCODE from this probe
    # cannot leak past those checks).
    if ($owner -and $repo) {
        $null = & gh api "repos/$owner/$repo" --jq '.full_name' 2>$null
    }

    # --- 1. List comments on the issue/PR. ---
    $listJson = & gh issue view $Number --json comments 2>$null
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

    # --- 2. Filter via substring containment. ---
    $matchedComments = @($comments | Where-Object {
            $_.body -and ($_.body -like "*$Marker*")
        })

    # --- 3. Branch on match count. ---
    if ($matchedComments.Count -eq 0) {
        # POST a new comment via the appropriate verb.
        $verb = if ($Type -eq 'pr') { 'pr' } else { 'issue' }
        $postOutput = & gh $verb comment $Number --body $Body 2>$null
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("Find-OrUpsertComment: gh $verb comment failed (exit $LASTEXITCODE)")
            return $null
        }
        return ($postOutput | Out-String).Trim()
    }

    # 1+ matches: pick lowest REST (numeric) id, warn on duplicates.
    # gh issue view --json comments returns GraphQL node IDs (e.g. IC_kwDO...) in
    # the `id` field, not the numeric REST comment ID that the PATCH endpoint
    # requires.  Extract the REST ID from the comment's `url` field when present
    # (the URL always ends in #issuecomment-<numeric-id>), falling back to a
    # direct [int] cast for callers that supply pre-resolved numeric IDs.
    function script:Get-RestCommentId([object]$c) {
        if ($c.url -and ($c.url -match '#issuecomment-(\d+)$')) { return [long]$Matches[1] }
        try { return [long]$c.id } catch { return $null }
    }

    $sorted = @($matchedComments |
        Where-Object { $null -ne (script:Get-RestCommentId $_) } |
        Sort-Object -Property { script:Get-RestCommentId $_ })
    if ($sorted.Count -eq 0) {
        [Console]::Error.WriteLine("Find-OrUpsertComment: matched comment(s) have no resolvable REST id; posting new comment.")
        $verb = if ($Type -eq 'pr') { 'pr' } else { 'issue' }
        $postOutput = & gh $verb comment $Number --body $Body 2>$null
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("Find-OrUpsertComment: gh $verb comment failed (exit $LASTEXITCODE)")
            return $null
        }
        return ($postOutput | Out-String).Trim()
    }
    $target = $sorted[0]
    $targetRestId = script:Get-RestCommentId $target
    if ($sorted.Count -gt 1) {
        $dupIds = ($sorted | Select-Object -Skip 1 | ForEach-Object { script:Get-RestCommentId $_ }) -join ', '
        [Console]::Error.WriteLine("Find-OrUpsertComment: multiple comments match marker '$Marker' (duplicates: $dupIds); patching earliest id $targetRestId")
    }

    if (-not ($owner -and $repo)) {
        [Console]::Error.WriteLine("Find-OrUpsertComment: unable to determine owner/repo from git remote; cannot PATCH comment.")
        return $null
    }

    $patchPath = "repos/$owner/$repo/issues/comments/$targetRestId"
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
