#Requires -Version 7.0

<#
.SYNOPSIS
    Core, testable logic for Invoke-PersistPhaseLedger (issue #878, plan
    slice s5). GREEN counterpart to s4's RED Pester suite
    (.github/scripts/Tests/persist-phase-ledger.Tests.ps1).

.DESCRIPTION
    Persists a judge-rulings machine block plus zero or more
    phase-containment blocks onto their durable GitHub-comment surface, per
    the writer contract in skills/plan-authoring/SKILL.md's "Phase-containment
    emission" and "Judge-rulings machine block" sections.

    This file does NOT dot-source the hub primitives it composes
    (Find-OrUpsertComment, Add-CommentBlocks, Add-JudgeRulingsBlock,
    Get-RestCommentId, Get-DispositionTally). That is the paired wrapper's
    job (persist-phase-ledger.ps1) so this core file stays directly
    dot-sourceable by Pester against real primitive functions already present
    in the caller's scope, exactly as
    .github/scripts/Tests/persist-phase-ledger.Tests.ps1 does.

    Two modes:
      plan   -- writes onto the `<!-- phase-containment-ledger-{ID} -->`
                sibling comment, creating it (and a
                `<!-- phase-containment-ledger-ref: {id} -->` pointer on the
                plan comment, immediately after `<!-- plan-issue-{ID} -->`)
                on first persist, reusing both via the pointer on re-persist.
      design -- appends/replaces directly on the caller-supplied
                `-DesignCommentId` (the `<!-- design-phase-complete-{ID} -->`
                comment). No search, no sibling, no pointer, no plan-comment
                interaction.

    Plan-mode ordering (writer contract, plan-authoring/SKILL.md rule 4 +
    863-D4 co-location gate): the judge-rulings block is always written
    BEFORE any phase-containment blocks, so every partial-failure
    intermediate state still satisfies the emission-check-core.ps1
    co-location gate (a body with blocks but no head fails that gate;
    head-first avoids ever landing in that state).

    Net-new glue this file builds (no shipped primitive expresses these --
    see .github/scripts/lib/find-or-upsert-comment.ps1 and
    .github/scripts/lib/phase-containment-emission-check-core.ps1 for what
    IS shipped):
      (a) Find-PPLCommentIdByExactMarker -- a find-only selector matching the
          marker LINE-ANCHORED AND WHOLE, never Find-OrUpsertComment's -like
          substring match (which would select a prose mention of the
          marker).
      (b) Get-PPLCommentIdFromUrl -- extracts the numeric REST id from a plain
          html_url STRING (Get-RestCommentId only accepts a comment OBJECT
          with .url/.id properties and would silently yield $null for a bare
          string).
      (c) Set-PPLJudgeRulingsBlockOnComment's span-replace branch -- locates and
          replaces the existing `<!-- judge-rulings ... -->` head+entries
          span in place on re-persist (Add-JudgeRulingsBlock is
          append-only by contract and must never be used for this).
      (d) Get-PPLCommentBodyById -- reads a comment's current body, feeding both
          the finding_key dedup decision and the span-replacement above;
          nothing in the shipped primitives returns a body for a known id.

    Dedup rule for phase-containment blocks (finding_key-keyed): a block
    whose finding_key is not yet present in the sibling is appended (via
    Add-CommentBlocks); a block whose finding_key IS already present but
    whose full text differs is replaced in place (manual span-replace, never
    Add-CommentBlocks, which never truncates or overwrites); a block whose
    finding_key is present with byte-identical text is a no-op.
#>

# ---------------------------------------------------------------------------
# Private helpers (script-scoped, matching the convention already
# established by phase-containment-emission-check-core.ps1's private
# helpers -- dot-sourcing merges these into the caller's scope, so they
# remain callable from the exported function below regardless of who
# dot-sources this file).
# ---------------------------------------------------------------------------

function script:Get-PPLCommentIdFromUrl {
    <#
    .SYNOPSIS
        Net-new glue (b): extracts the numeric REST comment id from a plain
        html_url STRING (e.g. Find-OrUpsertComment's return value on the
        create path). Get-RestCommentId (find-or-upsert-comment.ps1:64-67)
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

function script:Get-PPLCommentBodyById {
    <#
    .SYNOPSIS
        Net-new glue (d): reads a comment's current body by numeric REST id.
        No shipped primitive returns a body for a known id without also
        mutating it (Add-CommentBlocks/Add-JudgeRulingsBlock's internal GET
        is not exposed to callers).
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
        [Console]::Error.WriteLine("persist-phase-ledger: gh api GET $getPath failed (exit $LASTEXITCODE)")
        return $null
    }
    try {
        $obj = $getOutput | ConvertFrom-Json -ErrorAction Stop
        return [string]$obj.body
    }
    catch {
        [Console]::Error.WriteLine("persist-phase-ledger: failed to parse GET response for comment ${CommentId}: $($_.Exception.Message)")
        return $null
    }
}

function script:Set-PPLCommentBodyDirect {
    <#
    .SYNOPSIS
        Raw full-body PATCH for a known numeric comment id. Used only for
        in-place span replacement (judge-rulings re-persist, same-key/
        different-content phase-containment block replacement, and plan
        comment pointer insertion) -- never for the append-only paths, which
        go through Add-CommentBlocks/Add-JudgeRulingsBlock instead.
    .OUTPUTS
        [PSCustomObject] with Success [bool] and Reason [string] (populated
        only when Success=$false) -- same shape as the Add-* primitives.
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
        [Console]::Error.WriteLine("persist-phase-ledger: gh api PATCH $patchPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "PATCH failed (exit $LASTEXITCODE)" }
    }

    # M11 fix (issue #878 judge-sustained review): this function used to
    # check only $LASTEXITCODE, unlike Add-CommentBlocks' GET-after-PATCH
    # positive-proof verify. A lightweight version of that same pattern --
    # re-GET and confirm the write actually landed -- catches a PATCH that
    # exit-0'd but silently truncated or corrupted the body (the same class
    # Add-CommentBlocks' own post-write verify exists to catch).
    $verifyOutput = & gh api $patchPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("persist-phase-ledger: post-write verify GET $patchPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify GET failed (exit $LASTEXITCODE)" }
    }
    try {
        $verifyObj = $verifyOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("persist-phase-ledger: failed to parse post-write verify JSON for comment ${CommentId}: $($_.Exception.Message)")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify response is not valid JSON: $($_.Exception.Message)" }
    }
    $verifyBody = [string]$verifyObj.body

    # Exact match is the common case; GitHub's API can benignly normalize
    # some whitespace on write/read (trailing whitespace, blank-line-run
    # collapsing -- the same behavior Add-CommentBlocks documents for its
    # own post-write verify), so an ordinal mismatch alone is not proof of
    # corruption. Fall back to the same gross-truncation guard
    # Add-CommentBlocks uses: a benignly-normalized body trims at most a
    # handful of characters, never a large fraction of the body.
    if ($verifyBody -ne $NewBody) {
        $expectedMinLength = [int]($NewBody.Length * 0.5)
        if ($verifyBody.Length -lt $expectedMinLength) {
            [Console]::Error.WriteLine("persist-phase-ledger: post-write verify FAILED -- verify body ($($verifyBody.Length) chars) is dramatically shorter than the written body ($($NewBody.Length) chars) for comment $CommentId.")
            return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: verify body ($($verifyBody.Length) chars) is dramatically shorter than expected ($($NewBody.Length) chars written)" }
        }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

function script:Find-PPLCommentIdByExactMarker {
    <#
    .SYNOPSIS
        Net-new glue (a): find-only comment selector. Lists comments on the
        issue and returns the numeric REST id of the one whose body carries
        the given marker LINE-ANCHORED AND WHOLE (the entire line, modulo
        surrounding whitespace, must equal the marker exactly).
    .DESCRIPTION
        Deliberately NOT Find-OrUpsertComment's -like substring match
        (find-or-upsert-comment.ps1:129-131), which would select a comment
        that merely quotes the marker in prose (e.g. inside backticks
        mid-sentence) -- backticks do not neutralize either reader's raw-text
        scan (plan-authoring/SKILL.md rule 5), so a prose mention is a real
        false-positive risk for a substring matcher, not a hypothetical one.
        Ties (multiple genuine line-anchored matches) resolve to the lowest
        REST id, mirroring Find-OrUpsertComment's own earliest-id
        convention. Id extraction reuses Get-RestCommentId
        (find-or-upsert-comment.ps1) since the LIST payload's `.id` field is
        a GraphQL node id, not the numeric REST id the PATCH endpoint needs.
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

    # M15 fix (issue #878 judge-sustained review): pass -R explicitly, same
    # as this file's sibling gh-calling functions (Get-PPLCommentBodyById,
    # Set-PPLCommentBodyDirect) already do. Without it, this call's repo
    # targeting is derived from cwd instead of the caller-supplied
    # -Owner/-Repo, so it can silently target the wrong repo when the
    # current working directory does not match.
    $listJson = & gh issue view $IssueNumber --json comments -R "$Owner/$Repo" 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("persist-phase-ledger: gh issue view $IssueNumber failed (exit $LASTEXITCODE)")
        return $null
    }

    $comments = @()
    if ($listJson) {
        try {
            $parsed = $listJson | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -and $parsed.comments) { $comments = @($parsed.comments) }
        }
        catch {
            [Console]::Error.WriteLine("persist-phase-ledger: failed to parse comments JSON for issue ${IssueNumber}: $($_.Exception.Message)")
            return $null
        }
    }

    $linePattern = "(?m)^\s*$([regex]::Escape($Marker))\s*`$"
    $matched = @($comments | Where-Object { $_.body -and ([regex]::IsMatch([string]$_.body, $linePattern)) })
    if ($matched.Count -eq 0) { return $null }

    $pairs = @($matched |
        ForEach-Object { [PSCustomObject]@{ Comment = $_; RestId = Get-RestCommentId $_ } } |
        Where-Object { $null -ne $_.RestId })
    if ($pairs.Count -eq 0) { return $null }

    $target = @($pairs | Sort-Object -Property RestId)[0]
    return [PSCustomObject]@{ Id = $target.RestId; Body = [string]$target.Comment.body }
}

function script:Set-PPLPointerLineAfterMarker {
    <#
    .SYNOPSIS
        Inserts the `<!-- phase-containment-ledger-ref: {id} -->` pointer
        line immediately after the plan-issue marker line, preserving the
        rest of the body byte-identical (plan-authoring/SKILL.md:373,
        863-D11). Adds exactly one blank line on each side of the pointer,
        matching the existing marker-to-body blank-line convention.
    .OUTPUTS
        [string] the new plan-comment body.
    #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][long]$SiblingId
    )
    # Trailing whitespace is deliberately restricted to spaces/tabs only
    # (never `\s`, which also matches newlines): `\s*$` would let the
    # greedy-then-backtracking engine swallow the marker's own trailing
    # blank line into the match itself, shifting $insertPos past it and
    # silently dropping a newline from the reconstructed body. Stopping the
    # match at the marker's own line keeps $after starting exactly at the
    # first newline after the marker, so the blank-line count on each side
    # of the inserted pointer is fully controlled by this function, not by
    # how much of the original whitespace the match happened to consume.
    # M2 fix (issue #878 judge-sustained review): `[ \t]*` alone cannot
    # bridge a `\r` before `(?m)`'s `$` (which anchors immediately before
    # `\n`, not before `\r\n`), so a CRLF body (any web-UI-edited comment)
    # fell through to the "should be unreachable" fallback below, which
    # prepends a duplicate marker instead of inserting the pointer in place.
    # `\r?` immediately before the closing `` `$ `` absorbs that single
    # optional carriage return -- it is the marker line's own line-ending,
    # not part of a following blank line, so this stays consistent with the
    # comment above: the match still never crosses into the marker's
    # trailing blank line.
    $markerLineMatch = [regex]::Match($Body, "(?m)^\s*$([regex]::Escape($Marker))[ \t]*\r?`$")
    if (-not $markerLineMatch.Success) {
        # Defensive fallback (should be unreachable -- the caller already
        # confirmed the marker's presence via Find-PPLCommentIdByExactMarker).
        return "$Marker`n`n<!-- phase-containment-ledger-ref: $SiblingId -->`n`n$Body"
    }
    $insertPos = $markerLineMatch.Index + $markerLineMatch.Length
    $before = $Body.Substring(0, $insertPos)
    $after = $Body.Substring($insertPos) -replace '^(\r?\n)+', ''
    return $before + "`n`n<!-- phase-containment-ledger-ref: $SiblingId -->`n`n" + $after
}

function script:Set-PPLJudgeRulingsBlockOnComment {
    <#
    .SYNOPSIS
        Net-new glue (c): writes the judge-rulings block onto a known
        comment id -- append (via Add-JudgeRulingsBlock) when no head exists
        yet, span-replace (manual read + in-place substitution + raw PATCH)
        when one already does, since Add-JudgeRulingsBlock's own contract is
        append-only and must never be used to satisfy re-persist's
        replace-own-block rule (plan-authoring/SKILL.md rule 4).
    .OUTPUTS
        [PSCustomObject] with Success [bool], Reason [string], and Action
        [string] ('written' when appended fresh, 'replaced' when an
        existing head was span-replaced -- M12 fix, issue #878
        judge-sustained review: feeds the caller's landed/not-landed
        artifact manifest; Action is $null when Success=$false).
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [Parameter(Mandatory)][string]$JudgeRulingsContent
    )

    $currentBody = script:Get-PPLCommentBodyById -Owner $Owner -Repo $Repo -CommentId $CommentId
    if ($null -eq $currentBody) {
        return [PSCustomObject]@{ Success = $false; Reason = "Could not read comment $CommentId body before writing the judge-rulings block"; Action = $null }
    }

    # M6 fix (issue #878 judge-sustained review): anchored to this file's own
    # established idiom (Find-PPLCommentIdByExactMarker's line-anchored,
    # whole-line marker match above), matching the shape already used by
    # phase-containment-emission-check-core.ps1's $script:JudgeRulingsHeadPattern
    # (`(?m)^[ \t]*<!--\s*judge-rulings`) -- an unanchored match here could
    # select a prose/backtick judge-rulings mention preceding the real block
    # in the sibling body as the replace target instead of the real head.
    $headMatch = [regex]::Match($currentBody, '(?m)^[ \t]*<!--\s*judge-rulings.*?-->', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($headMatch.Success) {
        # F4 fix (issue #878 review): the append path already refuses to
        # write when $ExpectedMarker is missing from the fetched body (via
        # Add-JudgeRulingsBlock's own guard) -- this replace branch used to
        # have no equivalent check, so it would overwrite the first
        # judge-rulings head it found even on a comment that never carried
        # $ExpectedMarker (e.g. the wrong comment).
        if (-not $currentBody.Contains($ExpectedMarker)) {
            return [PSCustomObject]@{ Success = $false; Reason = "Comment does not contain expected marker '$ExpectedMarker' — refusing to replace judge-rulings block to avoid overwriting an unrelated comment"; Action = $null }
        }
        $newBody = $currentBody.Substring(0, $headMatch.Index) + $JudgeRulingsContent + $currentBody.Substring($headMatch.Index + $headMatch.Length)
        $replaceResult = script:Set-PPLCommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $CommentId -NewBody $newBody
        if (-not $replaceResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = $replaceResult.Reason; Action = $null }
        }
        return [PSCustomObject]@{ Success = $true; Reason = $null; Action = 'replaced' }
    }

    $appendResult = Add-JudgeRulingsBlock -Owner $Owner -Repo $Repo -CommentId $CommentId -ExpectedMarker $ExpectedMarker -NewContent "`n`n$JudgeRulingsContent"
    if (-not $appendResult.Success) {
        return [PSCustomObject]@{ Success = $false; Reason = $appendResult.Reason; Action = $null }
    }
    return [PSCustomObject]@{ Success = $true; Reason = $null; Action = 'written' }
}

function script:Get-PPLPhaseContainmentBlockId {
    <#
    .SYNOPSIS
        Extracts the `{ID}` token from a single candidate block's own
        opening `<!-- phase-containment-{ID} -->` tag.
    .OUTPUTS
        [string] or $null when the block carries no recognizable opening tag.
    #>
    param([Parameter(Mandatory)][string]$BlockText)
    $m = [regex]::Match($BlockText, '<!--\s*phase-containment-([A-Za-z0-9_-]+)\s*-->')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function script:Find-PPLPhaseContainmentBlockSpanByFindingKey {
    <#
    .SYNOPSIS
        Locates the full `<!-- phase-containment-{Id} --> ... <!--
        /phase-containment-{Id} -->` span in $Body whose finding_key line
        equals $FindingKey.
    .OUTPUTS
        [PSCustomObject] with Index [int], Length [int], Text [string], or
        $null when no matching block is found.
    #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$FindingKey,
        [Parameter(Mandatory)][string]$Id
    )
    $escapedId = [regex]::Escape($Id)
    $pattern = "<!--\s*phase-containment-$escapedId\s*-->.*?<!--\s*/phase-containment-$escapedId\s*-->"
    $keyPattern = "(?m)^finding_key:\s*$([regex]::Escape($FindingKey))\s*`$"
    foreach ($m in [regex]::Matches($Body, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        if ([regex]::IsMatch($m.Value, $keyPattern)) {
            return [PSCustomObject]@{ Index = $m.Index; Length = $m.Length; Text = $m.Value }
        }
    }
    return $null
}

function script:Remove-PPLPhaseContainmentAppendedAtLine {
    <#
    .SYNOPSIS
        Strips any `appended_at: ...` line from a single phase-containment
        block's text, for CONTENT-comparison purposes only (M14 fix, issue
        #878 judge-sustained review) -- never applied to content that is
        actually written to a comment.
    .DESCRIPTION
        The persisted span a re-persist compares against always carries a
        write-time `appended_at:` stamp (M5, this file's Set-CommentBlocksOnComment
        replace path), but the caller's freshly-authored candidate block
        never includes one -- an un-normalized comparison would never
        converge to a true no-op for logically-unchanged content.
    .OUTPUTS
        [string]
    #>
    param([Parameter(Mandatory)][string]$BlockText)
    return [regex]::Replace($BlockText, '(?m)^[ \t]*appended_at\s*:.*\r?\n?', '')
}

function script:Test-PPLPhaseContainmentCandidate {
    <#
    .SYNOPSIS
        Shared write-time preflight for a single phase-containment candidate
        block (issue #886 plan slice s4 consolidation): validates that the
        raw block text is well-formed (gated-parser, -SkippedCount tracked)
        and that its parsed entry passes schema validation. Replaces the
        identical preflight logic previously duplicated in
        Set-PPLPhaseContainmentBlocksOnComment's append and replace branches
        (both introduced by #887 F1, issue #878 review).
    .DESCRIPTION
        OUTPUT-STREAM DISCIPLINE (F2, issue #886 review): every intermediate
        expression below is assigned or [void]-suppressed, and the pass path
        ends with an explicit `return $null` -- an uncaptured expression
        inside this helper would leak into the function's output stream,
        turning `return $null` into a non-null one-or-more-element array and
        flipping BOTH call sites' `if ($null -ne $r) { return $r }` guard to
        falsely refuse every candidate.
    .PARAMETER Kind
        'Append' or 'Replacement' (not 'Replace') -- the exact word used
        verbatim in the Reason string, preserving the pre-existing
        "Append candidate for finding_key '...'" / "Replacement candidate
        for finding_key '...'" wording byte-for-byte.
    .OUTPUTS
        $null on pass, or [PSCustomObject] with Success=$false, Reason
        [string], and Action=$null on fail (same shape as this file's other
        Set-*OnComment failure returns).
    #>
    param(
        [Parameter(Mandatory)][string]$Block,
        [Parameter(Mandatory)][string]$BlockId,
        [Parameter(Mandatory)][string]$FindingKey,
        [Parameter(Mandatory)][ValidateSet('Append', 'Replacement')][string]$Kind
    )

    $skippedCount = 0
    $gatedBlocks = Get-PhaseContainmentBlock -Text $Block -Id $BlockId -SkippedCount ([ref]$skippedCount)
    if ($skippedCount -gt 0 -or $null -eq $gatedBlocks -or $gatedBlocks.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Reason = "$Kind candidate for finding_key '$FindingKey' (phase-containment-$BlockId) is unclosed or malformed ($skippedCount skipped)"; Action = $null }
    }
    foreach ($rawBlock in $gatedBlocks) {
        $entry = ConvertFrom-PhaseContainmentYaml -Yaml $rawBlock
        $validation = Test-PhaseContainmentEntry -Entry $entry
        if (-not $validation.IsValid) {
            return [PSCustomObject]@{ Success = $false; Reason = "$Kind candidate for finding_key '$FindingKey' (phase-containment-$BlockId) fails schema validation: $($validation.Errors -join '; ')"; Action = $null }
        }
    }
    return $null
}

function script:Set-PPLPhaseContainmentBlocksOnComment {
    <#
    .SYNOPSIS
        Writes the caller's phase-containment blocks onto a known comment
        id, deduped by finding_key: a new key is appended, an existing key
        with DIFFERENT text is replaced in place, and an existing key with
        byte-identical text (modulo the appended_at stamp and surrounding
        whitespace -- M14 fix) is a no-op for that block.
    .DESCRIPTION
        F1 fix (issue #878 review, gh-3610106812): every candidate block --
        both replacement AND append candidates -- is now preflight-validated
        (gated-parser well-formedness via Get-PhaseContainmentBlock, then
        schema via Test-PhaseContainmentEntry) BEFORE any write is
        committed, and the fully-merged result ($workingBody, with both
        replace splices and append content folded in) is written via a
        SINGLE Set-PPLCommentBodyDirect PATCH. Previously the replace path
        alone was preflighted and its Set-PPLCommentBodyDirect write committed
        immediately, while append candidates were validated only inside a
        separate, later Add-CommentBlocks call -- so a validation failure or
        transport failure on the append half left a replace that had already
        landed, an unrecoverable partial-write state. Now either every
        block in this call validates and the one PATCH lands, or nothing
        writes and Success=$false names the failing block's finding_key.
    .OUTPUTS
        [PSCustomObject] with Success [bool], Reason [string], and Action
        [string] -- one of 'appended', 'replaced', 'appended+replaced', or
        'no-op' (M12 fix, issue #878 judge-sustained review: feeds the
        caller's landed/not-landed artifact manifest; Action is $null when
        Success=$false).
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [Parameter(Mandatory)][string[]]$Blocks
    )

    $currentBody = script:Get-PPLCommentBodyById -Owner $Owner -Repo $Repo -CommentId $CommentId
    if ($null -eq $currentBody) {
        return [PSCustomObject]@{ Success = $false; Reason = "Could not read comment $CommentId body before writing phase-containment blocks"; Action = $null }
    }

    # F1 fix (issue #878 review): this function used to rely entirely on
    # Add-CommentBlocks' own ExpectedMarker guard for the append half of its
    # work. Now that both halves fold into one Set-PPLCommentBodyDirect PATCH
    # (Add-CommentBlocks is no longer called from this function at all),
    # this guard is checked here directly, against the same $currentBody
    # every subsequent preflight step below reasons about.
    if (-not $currentBody.Contains($ExpectedMarker)) {
        return [PSCustomObject]@{ Success = $false; Reason = "Expected marker '$ExpectedMarker' not found in comment $CommentId body; refusing to write phase-containment blocks"; Action = $null }
    }

    $toAppend = [System.Collections.Generic.List[string]]::new()
    $workingBody = $currentBody
    # M13 fix (issue #878 judge-sustained review): tracks finding_keys
    # already queued for append EARLIER IN THIS SAME CALL. $workingBody
    # alone cannot detect this class -- it is mutated only on a REPLACE
    # below, never on an append (append content is not actually persisted
    # until it is folded into $workingBody after this loop). Without this
    # set, two blocks sharing a not-yet-persisted finding_key in one
    # $Blocks array both fell into the $null -eq $existingSpan branch and
    # both got queued -- a real duplicate landing on the comment.
    $appendedKeysThisCall = [System.Collections.Generic.HashSet[string]]::new()
    $replaceStamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    foreach ($block in $Blocks) {
        $keyMatch = [regex]::Match($block, '(?m)^finding_key:\s*(\S+)\s*$')
        if (-not $keyMatch.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = 'A PhaseContainmentBlocks entry is missing a finding_key field'; Action = $null }
        }
        $findingKey = $keyMatch.Groups[1].Value
        $blockId = script:Get-PPLPhaseContainmentBlockId -BlockText $block
        if ($null -eq $blockId) {
            return [PSCustomObject]@{ Success = $false; Reason = 'A PhaseContainmentBlocks entry is missing a recognizable opening tag'; Action = $null }
        }

        if ($appendedKeysThisCall.Contains($findingKey)) {
            # M13: already queued for append earlier in this same call.
            continue
        }

        $existingSpan = script:Find-PPLPhaseContainmentBlockSpanByFindingKey -Body $workingBody -FindingKey $findingKey -Id $blockId

        if ($null -eq $existingSpan) {
            # F1 fix (issue #878 review): append candidates now get the SAME
            # write-time preflight the replace branch below already has --
            # gated-parser well-formedness (Get-PhaseContainmentBlock,
            # -SkippedCount tracked) then schema validation
            # (Test-PhaseContainmentEntry) -- BEFORE being queued into
            # $toAppend. Previously this candidate's validation happened
            # only inside Add-CommentBlocks, in a separate call issued AFTER
            # any replace write above had already committed.
            # s4 consolidation (issue #886): both this branch and the replace
            # branch below now delegate that identical preflight to the
            # shared Test-PPLPhaseContainmentCandidate helper instead of each
            # reimplementing it inline.
            $appendCandidateFailure = script:Test-PPLPhaseContainmentCandidate -Block $block -BlockId $blockId -FindingKey $findingKey -Kind 'Append'
            if ($null -ne $appendCandidateFailure) { return $appendCandidateFailure }
            $toAppend.Add($block)
            [void]$appendedKeysThisCall.Add($findingKey)
            continue
        }

        # M14 fix: compare with the persisted span's write-time
        # `appended_at:` line stripped from both sides (M5 below now stamps
        # that field at write time, which the caller's freshly-authored
        # $block never carries) and with surrounding whitespace trimmed, so
        # logically-unchanged content converges to a true no-op instead of
        # perpetually re-replacing itself on every re-persist.
        $normalizedExisting = (script:Remove-PPLPhaseContainmentAppendedAtLine -BlockText $existingSpan.Text).Trim()
        $normalizedCandidate = (script:Remove-PPLPhaseContainmentAppendedAtLine -BlockText $block).Trim()
        if ($normalizedExisting -eq $normalizedCandidate) {
            continue
        }

        # F1 fix (issue #878 CE Gate review): a same-finding_key replacement
        # candidate must pass the SAME write-time preflight the append path
        # already gets for free via Add-CommentBlocks (phase-containment-
        # emission-check-core.ps1:3037-3088) before it is ever spliced into
        # $workingBody -- this branch used to check only finding_key
        # presence and opening-tag recognizability, then splice
        # unconditionally, so a schema-invalid or unclosed/malformed
        # replacement candidate landed on the comment untouched. Reuse the
        # same gated parser (Get-PhaseContainmentBlock, -SkippedCount
        # tracked) and the same schema validator (Test-PhaseContainmentEntry)
        # the append path calls -- not a bespoke reimplementation -- and
        # refuse BEFORE splicing when:
        #   - SkippedCount > 0 or zero blocks parsed (unclosed/malformed), OR
        #   - a parsed block fails Test-PhaseContainmentEntry's schema rules.
        # Fail loud with the same shape the append path uses: Success=$false
        # and a Reason naming the finding_key and the specific failure.
        # s4 consolidation (issue #886): delegates to the shared
        # Test-PPLPhaseContainmentCandidate helper (same one the append
        # branch above calls) instead of reimplementing this preflight.
        $replaceCandidateFailure = script:Test-PPLPhaseContainmentCandidate -Block $block -BlockId $blockId -FindingKey $findingKey -Kind 'Replacement'
        if ($null -ne $replaceCandidateFailure) { return $replaceCandidateFailure }

        # M5 fix: stamp appended_at into the replacement content the same
        # way Add-CommentBlocks stamps a freshly-appended block (reusing its
        # own Add-AppendedAtStampToPhaseContainmentBlocks helper, in scope
        # via this file's paired wrapper's dot-source order), so a genuine
        # content replace does not silently drop the field from the
        # comment's persisted surface -- the raw splice used to write the
        # caller's block byte-for-byte, appended_at included or not.
        $replacementBlock = Add-AppendedAtStampToPhaseContainmentBlocks -Text $block -Timestamp $replaceStamp
        $workingBody = $workingBody.Substring(0, $existingSpan.Index) + $replacementBlock + $workingBody.Substring($existingSpan.Index + $existingSpan.Length)
    }

    # $didReplace reflects only the in-loop replace splices above (identical
    # to the pre-F1 semantics) -- computed BEFORE append content is folded
    # in below, so it stays a true signal of "a replace actually happened"
    # rather than being trivially true whenever any append occurs too.
    $didAppend = ($toAppend.Count -gt 0)
    $didReplace = ($workingBody -ne $currentBody)

    # F1 fix (issue #878 review): fold append content into $workingBody here,
    # in memory, stamped the same way Add-CommentBlocks stamps a freshly
    # appended block (Add-AppendedAtStampToPhaseContainmentBlocks), instead
    # of handing it to a second, separate Add-CommentBlocks call/PATCH after
    # the replace write above already committed.
    if ($didAppend) {
        $stampedAppend = ($toAppend | ForEach-Object { Add-AppendedAtStampToPhaseContainmentBlocks -Text $_ -Timestamp $replaceStamp }) -join "`n`n"
        $workingBody = $workingBody + "`n`n" + $stampedAppend
    }

    if ($workingBody -ne $currentBody) {
        $writeResult = script:Set-PPLCommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $CommentId -NewBody $workingBody
        if (-not $writeResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = $writeResult.Reason; Action = $null }
        }
    }

    $action = if ($didAppend -and $didReplace) { 'appended+replaced' }
    elseif ($didAppend) { 'appended' }
    elseif ($didReplace) { 'replaced' }
    else { 'no-op' }

    return [PSCustomObject]@{ Success = $true; Reason = $null; Action = $action }
}

function script:New-PPLPersistPhaseLedgerArtifactManifest {
    <#
    .SYNOPSIS
        Default landed/not-landed artifact manifest (M12 fix, issue #878
        judge-sustained review: AC2 requires "a landed/not-landed artifact
        report", not just {Success;Reason}).
    .DESCRIPTION
        Every early-return failure path in the two mode functions below (and
        Invoke-PersistPhaseLedger's own top-level validation failures) starts
        from this same all-not-attempted shape, then overwrites only the
        keys it actually attempts before returning -- so a caller can always
        read .Artifacts on ANY result, success or failure, without a
        $null-check.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] with keys
        Sibling, Pointer, JudgeRulings, PhaseContainmentBlocks, each starting
        'not-attempted'.
    #>
    return [ordered]@{
        Sibling                = 'not-attempted'
        Pointer                = 'not-attempted'
        JudgeRulings           = 'not-attempted'
        PhaseContainmentBlocks = 'not-attempted'
    }
}

function script:Invoke-PPLPersistPhaseLedgerPlanMode {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$JudgeRulingsContent,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PhaseContainmentBlocks
    )

    $planMarker = "<!-- plan-issue-$IssueNumber -->"
    $ledgerMarker = "<!-- phase-containment-ledger-$IssueNumber -->"
    $artifacts = script:New-PPLPersistPhaseLedgerArtifactManifest

    $planComment = script:Find-PPLCommentIdByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -Marker $planMarker
    if ($null -eq $planComment) {
        return [PSCustomObject]@{ Success = $false; Reason = "Plan comment carrying marker '$planMarker' not found (line-anchored, whole-line match) on issue $IssueNumber"; Artifacts = $artifacts }
    }
    $planCommentId = $planComment.Id
    $planBody = $planComment.Body

    # F3 fix (issue #878 review): anchored to a standalone line, matching
    # this file's own established anchored-marker idiom (e.g.
    # Set-PPLPointerLineAfterMarker's line-anchored match above, and
    # Find-PPLCommentIdByExactMarker's whole-line marker match). The prior
    # unanchored regex would match a prose mention of the pointer shape
    # anywhere in the plan body and wrongly trust its captured id as the
    # real sibling comment id. Outer whitespace is restricted to `[ \t]*`
    # (never `\s*`, which also matches newlines) with an explicit `\r?`
    # before the multiline `$` -- the same M2-fix precedent already applied
    # to Set-PPLPointerLineAfterMarker's own line-anchored match in this file,
    # so a CRLF-bodied comment cannot make this regex's greedy whitespace
    # swallow past the line boundary.
    $pointerMatch = [regex]::Match($planBody, '(?m)^[ \t]*<!--\s*phase-containment-ledger-ref:\s*(\d+)\s*-->[ \t]*\r?$')
    if ($pointerMatch.Success) {
        $siblingId = [long]$pointerMatch.Groups[1].Value
        $artifacts.Sibling = 'reused'
        $artifacts.Pointer = 'already-present'
    }
    else {
        # M1 fix (issue #878 judge-sustained review): the pointer can go
        # missing on the plan comment (e.g. a routine plan re-persist that
        # rewrites the plan comment body without this helper's
        # previously-inserted pointer line) even though the ledger sibling
        # itself still exists, still full of accumulated content.
        # Find-OrUpsertComment's PATCH path replaces a matched comment's
        # body VERBATIM -- calling it directly here, with no prior existence
        # check, would silently wipe that sibling back down to just
        # $ledgerMarker. Always look for an existing sibling by its own
        # durable marker FIRST (the same find-only, line-anchored selector
        # already used for the plan comment lookup above), and only fall
        # through to Find-OrUpsertComment's create-or-PATCH path when the
        # sibling genuinely does not exist yet.
        $existingSibling = script:Find-PPLCommentIdByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -Marker $ledgerMarker
        if ($null -ne $existingSibling) {
            $siblingId = $existingSibling.Id
            $artifacts.Sibling = 'reused'
        }
        else {
            # F2 fix (issue #878 review): thread -Owner/-Repo explicitly, same
            # as this file's other gh-calling helpers (Get-PPLCommentBodyById,
            # Set-PPLCommentBodyDirect, Find-PPLCommentIdByExactMarker) already do.
            # Without them, Find-OrUpsertComment derived owner/repo from the
            # ambient git remote instead of the caller-supplied -Owner/-Repo,
            # so it could silently create the sibling comment in the wrong
            # repo when cwd's remote did not match.
            $createdUrl = Find-OrUpsertComment -Type 'issue' -Number $IssueNumber -Marker $ledgerMarker -Body $ledgerMarker -Owner $Owner -Repo $Repo
            if ($null -eq $createdUrl) {
                $artifacts.Sibling = 'failed'
                return [PSCustomObject]@{ Success = $false; Reason = 'Failed to create the phase-containment-ledger sibling comment (Find-OrUpsertComment returned $null)'; Artifacts = $artifacts }
            }
            $siblingId = script:Get-PPLCommentIdFromUrl -Url $createdUrl
            if ($null -eq $siblingId) {
                $artifacts.Sibling = 'failed'
                return [PSCustomObject]@{ Success = $false; Reason = "Could not extract a numeric comment id from the created sibling's url '$createdUrl'"; Artifacts = $artifacts }
            }
            $artifacts.Sibling = 'created'
        }

        # M1: the pointer must be (re-)inserted whether the sibling was just
        # created OR found pre-existing without a pointer -- both share the
        # exact same "plan comment currently has no pointer line" starting
        # condition.
        $newPlanBody = script:Set-PPLPointerLineAfterMarker -Body $planBody -Marker $planMarker -SiblingId $siblingId
        $pointerResult = script:Set-PPLCommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $planCommentId -NewBody $newPlanBody
        if (-not $pointerResult.Success) {
            $artifacts.Pointer = 'failed'
            return [PSCustomObject]@{ Success = $false; Reason = "Failed to insert the phase-containment-ledger-ref pointer into the plan comment: $($pointerResult.Reason)"; Artifacts = $artifacts }
        }
        $artifacts.Pointer = 'written'
    }

    # Plan-mode ordering: judge-rulings FIRST, then phase-containment blocks.
    $judgeResult = script:Set-PPLJudgeRulingsBlockOnComment -Owner $Owner -Repo $Repo -CommentId $siblingId -ExpectedMarker $ledgerMarker -JudgeRulingsContent $JudgeRulingsContent
    if (-not $judgeResult.Success) {
        $artifacts.JudgeRulings = 'failed'
        return [PSCustomObject]@{ Success = $false; Reason = $judgeResult.Reason; Artifacts = $artifacts }
    }
    $artifacts.JudgeRulings = $judgeResult.Action

    if ($PhaseContainmentBlocks.Count -gt 0) {
        $blockResult = script:Set-PPLPhaseContainmentBlocksOnComment -Owner $Owner -Repo $Repo -CommentId $siblingId -ExpectedMarker $ledgerMarker -Blocks $PhaseContainmentBlocks
        if (-not $blockResult.Success) {
            $artifacts.PhaseContainmentBlocks = 'failed'
            return [PSCustomObject]@{ Success = $false; Reason = $blockResult.Reason; Artifacts = $artifacts }
        }
        $artifacts.PhaseContainmentBlocks = $blockResult.Action
    }
    else {
        $artifacts.PhaseContainmentBlocks = 'skipped-empty'
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null; Artifacts = $artifacts }
}

function script:Invoke-PPLPersistPhaseLedgerDesignMode {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$DesignCommentId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PhaseContainmentBlocks
    )

    # Partial-literal marker (no {ID} -- design mode receives the comment id
    # directly and never resolves an issue number), sufficient for the
    # Add-*'s .Contains() identity check per plan-authoring/SKILL.md's
    # design-phase-complete convention (agents/Solution-Designer.agent.md:99).
    $designMarker = '<!-- design-phase-complete-'
    $artifacts = script:New-PPLPersistPhaseLedgerArtifactManifest

    # Deliberately no Set-PPLJudgeRulingsBlockOnComment call here (and no
    # -JudgeRulingsContent parameter on this inner function at all -- see
    # Invoke-PersistPhaseLedger's own comment on why it still accepts and
    # discards the value at the public boundary). Design-challenge review
    # (skills/adversarial-review/adapters/design-challenge.md) is
    # prosecution-only -- "Defense and judge stages are intentionally
    # absent" -- so there is no judge_ruling: sustained|defense-sustained
    # data that could ever legitimately exist for the design surface; the
    # concept does not apply here. Design-mode is Add-CommentBlocks-only
    # routing per plan-issue-878 comment 5013462111's step 5 Requirement
    # Contract, and the live `<!-- design-phase-complete-878 -->` comment on
    # issue #878 is the durable proof: it carries a `finding_dispositions:`
    # block but never a `<!-- judge-rulings ... -->` block. Sibling/Pointer/
    # JudgeRulings stay 'not-attempted' in the returned manifest for this
    # entire mode -- none of those concepts apply on the design surface.
    if ($PhaseContainmentBlocks.Count -gt 0) {
        $blockResult = script:Set-PPLPhaseContainmentBlocksOnComment -Owner $Owner -Repo $Repo -CommentId $DesignCommentId -ExpectedMarker $designMarker -Blocks $PhaseContainmentBlocks
        if (-not $blockResult.Success) {
            $artifacts.PhaseContainmentBlocks = 'failed'
            return [PSCustomObject]@{ Success = $false; Reason = $blockResult.Reason; Artifacts = $artifacts }
        }
        $artifacts.PhaseContainmentBlocks = $blockResult.Action
    }
    else {
        $artifacts.PhaseContainmentBlocks = 'skipped-empty'
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null; Artifacts = $artifacts }
}

function Invoke-PersistPhaseLedger {
    <#
    .SYNOPSIS
        Persists a judge-rulings block plus zero or more phase-containment
        blocks onto their durable GitHub-comment surface for either the
        plan-stress-test or design-challenge adversarial-review surface.
    .PARAMETER Owner
        Repository owner.
    .PARAMETER Repo
        Repository name.
    .PARAMETER Mode
        'plan' or 'design'. Selects the persistence surface and required
        companion parameter (-IssueNumber for plan, -DesignCommentId for
        design).
    .PARAMETER IssueNumber
        Required when -Mode plan. The issue carrying the `<!--
        plan-issue-{ID} -->` comment.
    .PARAMETER DesignCommentId
        Required when -Mode design. The numeric REST id of the existing
        `<!-- design-phase-complete-{ID} -->` comment.
    .PARAMETER JudgeRulingsContent
        The complete `<!-- judge-rulings ... -->` bare-head block text
        (plan-authoring/SKILL.md rule 3: atomic, one full block, including
        the zero-findings placeholder when there are no sustained findings).
        Required (Mandatory) for both -Mode values, but under -Mode design
        it is accepted and then deliberately discarded: design-challenge
        review (skills/adversarial-review/adapters/design-challenge.md) is
        prosecution-only with no judge stage, so there is no legitimate
        judge-rulings data for the design surface. Kept Mandatory here
        rather than made conditional so callers never have to branch on
        -Mode just to decide whether to supply it.
    .PARAMETER PhaseContainmentBlocks
        Zero or more complete `<!-- phase-containment-{ID} --> ... <!--
        /phase-containment-{ID} -->` block strings, one per sustained
        finding. An empty array is a legal, first-class input (the
        zero-sustained-findings clean path) -- Add-CommentBlocks is never
        invoked in that case.
    .OUTPUTS
        [PSCustomObject] with Success [bool], Reason [string] (populated only
        when Success=$false, naming the failing step where possible), and
        Artifacts (an ordered landed/not-landed manifest -- M12 fix, issue
        #878 judge-sustained review, AC2: Sibling, Pointer, JudgeRulings, and
        PhaseContainmentBlocks, each one of the values documented on
        New-PPLPersistPhaseLedgerArtifactManifest/the two mode functions'
        Set-*OnComment call sites -- present on every result, success or
        failure, so a caller can always tell what happened at each step, not
        just the name of the step that ultimately failed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][ValidateSet('plan', 'design')][string]$Mode,
        [int]$IssueNumber,
        [long]$DesignCommentId,
        [Parameter(Mandatory)][string]$JudgeRulingsContent,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PhaseContainmentBlocks
    )

    if ($Mode -eq 'design') {
        if ($DesignCommentId -le 0) {
            return [PSCustomObject]@{ Success = $false; Reason = 'Mode design requires a positive -DesignCommentId'; Artifacts = (script:New-PPLPersistPhaseLedgerArtifactManifest) }
        }
        # -JudgeRulingsContent is intentionally NOT forwarded to design mode.
        # It stays Mandatory on this public function (rather than becoming
        # conditionally-required per -Mode, or dropped from the public
        # surface) so the wrapper script's parameter set and every existing
        # call site -- including the plan-mode-only callers dispatching this
        # helper today -- do not have to branch on -Mode just to decide
        # whether to supply it. Design-mode callers pass a value here and it
        # is silently discarded at this boundary; see
        # Invoke-PPLPersistPhaseLedgerDesignMode's own comment for why the
        # design surface never writes a judge-rulings block.
        return script:Invoke-PPLPersistPhaseLedgerDesignMode -Owner $Owner -Repo $Repo -DesignCommentId $DesignCommentId -PhaseContainmentBlocks $PhaseContainmentBlocks
    }

    if ($IssueNumber -le 0) {
        return [PSCustomObject]@{ Success = $false; Reason = 'Mode plan requires a positive -IssueNumber'; Artifacts = (script:New-PPLPersistPhaseLedgerArtifactManifest) }
    }
    return script:Invoke-PPLPersistPhaseLedgerPlanMode -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -JudgeRulingsContent $JudgeRulingsContent -PhaseContainmentBlocks $PhaseContainmentBlocks
}
