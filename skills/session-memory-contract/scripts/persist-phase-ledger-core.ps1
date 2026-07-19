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
      (a) Find-CommentIdByExactMarker -- a find-only selector matching the
          marker LINE-ANCHORED AND WHOLE, never Find-OrUpsertComment's -like
          substring match (which would select a prose mention of the
          marker).
      (b) Get-CommentIdFromUrl -- extracts the numeric REST id from a plain
          html_url STRING (Get-RestCommentId only accepts a comment OBJECT
          with .url/.id properties and would silently yield $null for a bare
          string).
      (c) Set-JudgeRulingsBlockOnComment's span-replace branch -- locates and
          replaces the existing `<!-- judge-rulings ... -->` head+entries
          span in place on re-persist (Add-JudgeRulingsBlock is
          append-only by contract and must never be used for this).
      (d) Get-CommentBodyById -- reads a comment's current body, feeding both
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

function script:Get-CommentIdFromUrl {
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

function script:Get-CommentBodyById {
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

function script:Set-CommentBodyDirect {
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
    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

function script:Find-CommentIdByExactMarker {
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
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$Marker
    )

    $listJson = & gh issue view $IssueNumber --json comments 2>$null
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

function script:Set-PointerLineAfterMarker {
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
    $markerLineMatch = [regex]::Match($Body, "(?m)^\s*$([regex]::Escape($Marker))[ \t]*`$")
    if (-not $markerLineMatch.Success) {
        # Defensive fallback (should be unreachable -- the caller already
        # confirmed the marker's presence via Find-CommentIdByExactMarker).
        return "$Marker`n`n<!-- phase-containment-ledger-ref: $SiblingId -->`n`n$Body"
    }
    $insertPos = $markerLineMatch.Index + $markerLineMatch.Length
    $before = $Body.Substring(0, $insertPos)
    $after = $Body.Substring($insertPos) -replace '^(\r?\n)+', ''
    return $before + "`n`n<!-- phase-containment-ledger-ref: $SiblingId -->`n`n" + $after
}

function script:Set-JudgeRulingsBlockOnComment {
    <#
    .SYNOPSIS
        Net-new glue (c): writes the judge-rulings block onto a known
        comment id -- append (via Add-JudgeRulingsBlock) when no head exists
        yet, span-replace (manual read + in-place substitution + raw PATCH)
        when one already does, since Add-JudgeRulingsBlock's own contract is
        append-only and must never be used to satisfy re-persist's
        replace-own-block rule (plan-authoring/SKILL.md rule 4).
    .OUTPUTS
        [PSCustomObject] with Success [bool] and Reason [string].
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [Parameter(Mandatory)][string]$JudgeRulingsContent
    )

    $currentBody = script:Get-CommentBodyById -Owner $Owner -Repo $Repo -CommentId $CommentId
    if ($null -eq $currentBody) {
        return [PSCustomObject]@{ Success = $false; Reason = "Could not read comment $CommentId body before writing the judge-rulings block" }
    }

    $headMatch = [regex]::Match($currentBody, '<!--\s*judge-rulings.*?-->', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($headMatch.Success) {
        $newBody = $currentBody.Substring(0, $headMatch.Index) + $JudgeRulingsContent + $currentBody.Substring($headMatch.Index + $headMatch.Length)
        return script:Set-CommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $CommentId -NewBody $newBody
    }

    $appendResult = Add-JudgeRulingsBlock -Owner $Owner -Repo $Repo -CommentId $CommentId -ExpectedMarker $ExpectedMarker -NewContent "`n`n$JudgeRulingsContent"
    if (-not $appendResult.Success) {
        return [PSCustomObject]@{ Success = $false; Reason = $appendResult.Reason }
    }
    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

function script:Get-PhaseContainmentBlockId {
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

function script:Find-PhaseContainmentBlockSpanByFindingKey {
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

function script:Set-PhaseContainmentBlocksOnComment {
    <#
    .SYNOPSIS
        Writes the caller's phase-containment blocks onto a known comment
        id, deduped by finding_key: a new key is appended (Add-CommentBlocks,
        which never truncates existing content); an existing key with
        DIFFERENT text is replaced in place (manual span-replace, never
        Add-CommentBlocks); an existing key with byte-identical text is a
        no-op for that block.
    .OUTPUTS
        [PSCustomObject] with Success [bool] and Reason [string].
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [Parameter(Mandatory)][string[]]$Blocks
    )

    $currentBody = script:Get-CommentBodyById -Owner $Owner -Repo $Repo -CommentId $CommentId
    if ($null -eq $currentBody) {
        return [PSCustomObject]@{ Success = $false; Reason = "Could not read comment $CommentId body before writing phase-containment blocks" }
    }

    $toAppend = [System.Collections.Generic.List[string]]::new()
    $workingBody = $currentBody

    foreach ($block in $Blocks) {
        $keyMatch = [regex]::Match($block, '(?m)^finding_key:\s*(\S+)\s*$')
        if (-not $keyMatch.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = 'A PhaseContainmentBlocks entry is missing a finding_key field' }
        }
        $findingKey = $keyMatch.Groups[1].Value
        $blockId = script:Get-PhaseContainmentBlockId -BlockText $block
        if ($null -eq $blockId) {
            return [PSCustomObject]@{ Success = $false; Reason = 'A PhaseContainmentBlocks entry is missing a recognizable opening tag' }
        }

        $existingSpan = script:Find-PhaseContainmentBlockSpanByFindingKey -Body $workingBody -FindingKey $findingKey -Id $blockId

        if ($null -eq $existingSpan) {
            $toAppend.Add($block)
        }
        elseif ($existingSpan.Text -eq $block) {
            continue
        }
        else {
            $workingBody = $workingBody.Substring(0, $existingSpan.Index) + $block + $workingBody.Substring($existingSpan.Index + $existingSpan.Length)
        }
    }

    if ($workingBody -ne $currentBody) {
        $replaceResult = script:Set-CommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $CommentId -NewBody $workingBody
        if (-not $replaceResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = $replaceResult.Reason }
        }
    }

    if ($toAppend.Count -gt 0) {
        $newContent = "`n`n" + ($toAppend -join "`n`n")
        $appendResult = Add-CommentBlocks -Owner $Owner -Repo $Repo -CommentId $CommentId -ExpectedMarker $ExpectedMarker -NewContent $newContent
        if (-not $appendResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = $appendResult.Reason }
        }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

function script:Invoke-PersistPhaseLedgerPlanMode {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$JudgeRulingsContent,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PhaseContainmentBlocks
    )

    $planMarker = "<!-- plan-issue-$IssueNumber -->"
    $ledgerMarker = "<!-- phase-containment-ledger-$IssueNumber -->"

    $planComment = script:Find-CommentIdByExactMarker -IssueNumber $IssueNumber -Marker $planMarker
    if ($null -eq $planComment) {
        return [PSCustomObject]@{ Success = $false; Reason = "Plan comment carrying marker '$planMarker' not found (line-anchored, whole-line match) on issue $IssueNumber" }
    }
    $planCommentId = $planComment.Id
    $planBody = $planComment.Body

    $pointerMatch = [regex]::Match($planBody, '<!--\s*phase-containment-ledger-ref:\s*(\d+)\s*-->')
    if ($pointerMatch.Success) {
        $siblingId = [long]$pointerMatch.Groups[1].Value
    }
    else {
        $createdUrl = Find-OrUpsertComment -Type 'issue' -Number $IssueNumber -Marker $ledgerMarker -Body $ledgerMarker
        if ($null -eq $createdUrl) {
            return [PSCustomObject]@{ Success = $false; Reason = 'Failed to create the phase-containment-ledger sibling comment (Find-OrUpsertComment returned $null)' }
        }
        $siblingId = script:Get-CommentIdFromUrl -Url $createdUrl
        if ($null -eq $siblingId) {
            return [PSCustomObject]@{ Success = $false; Reason = "Could not extract a numeric comment id from the created sibling's url '$createdUrl'" }
        }

        $newPlanBody = script:Set-PointerLineAfterMarker -Body $planBody -Marker $planMarker -SiblingId $siblingId
        $pointerResult = script:Set-CommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $planCommentId -NewBody $newPlanBody
        if (-not $pointerResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = "Failed to insert the phase-containment-ledger-ref pointer into the plan comment: $($pointerResult.Reason)" }
        }
    }

    # Plan-mode ordering: judge-rulings FIRST, then phase-containment blocks.
    $judgeResult = script:Set-JudgeRulingsBlockOnComment -Owner $Owner -Repo $Repo -CommentId $siblingId -ExpectedMarker $ledgerMarker -JudgeRulingsContent $JudgeRulingsContent
    if (-not $judgeResult.Success) {
        return [PSCustomObject]@{ Success = $false; Reason = $judgeResult.Reason }
    }

    if ($PhaseContainmentBlocks.Count -gt 0) {
        $blockResult = script:Set-PhaseContainmentBlocksOnComment -Owner $Owner -Repo $Repo -CommentId $siblingId -ExpectedMarker $ledgerMarker -Blocks $PhaseContainmentBlocks
        if (-not $blockResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = $blockResult.Reason }
        }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

function script:Invoke-PersistPhaseLedgerDesignMode {
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

    # Deliberately no Set-JudgeRulingsBlockOnComment call here (and no
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
    # block but never a `<!-- judge-rulings ... -->` block.
    if ($PhaseContainmentBlocks.Count -gt 0) {
        $blockResult = script:Set-PhaseContainmentBlocksOnComment -Owner $Owner -Repo $Repo -CommentId $DesignCommentId -ExpectedMarker $designMarker -Blocks $PhaseContainmentBlocks
        if (-not $blockResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = $blockResult.Reason }
        }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null }
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
        [PSCustomObject] with Success [bool] and Reason [string] (populated
        only when Success=$false, naming the failing step where possible).
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
            return [PSCustomObject]@{ Success = $false; Reason = 'Mode design requires a positive -DesignCommentId' }
        }
        # -JudgeRulingsContent is intentionally NOT forwarded to design mode.
        # It stays Mandatory on this public function (rather than becoming
        # conditionally-required per -Mode, or dropped from the public
        # surface) so the wrapper script's parameter set and every existing
        # call site -- including the plan-mode-only callers dispatching this
        # helper today -- do not have to branch on -Mode just to decide
        # whether to supply it. Design-mode callers pass a value here and it
        # is silently discarded at this boundary; see
        # Invoke-PersistPhaseLedgerDesignMode's own comment for why the
        # design surface never writes a judge-rulings block.
        return script:Invoke-PersistPhaseLedgerDesignMode -Owner $Owner -Repo $Repo -DesignCommentId $DesignCommentId -PhaseContainmentBlocks $PhaseContainmentBlocks
    }

    if ($IssueNumber -le 0) {
        return [PSCustomObject]@{ Success = $false; Reason = 'Mode plan requires a positive -IssueNumber' }
    }
    return script:Invoke-PersistPhaseLedgerPlanMode -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -JudgeRulingsContent $JudgeRulingsContent -PhaseContainmentBlocks $PhaseContainmentBlocks
}
