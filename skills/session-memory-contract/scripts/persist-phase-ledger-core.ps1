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

    Three modes (issue #951 added the third):
      brief  -- same sibling/pointer lifecycle as plan (both share
                Resolve-PPLLedgerSibling), but writes a `brief_dispositions:`
                authorizing head instead of a judge-rulings block, and refuses
                head content carrying judge vocabulary. This is the lawful
                judge-free emission path for a chunk brief's prosecution-only
                review, which before #951 had no way to record its findings
                except by borrowing a judge vocabulary that did not apply.
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
      (a)-(b),(d) Find-PPLCommentIdByExactMarker, Get-PPLCommentIdFromUrl,
          and Get-PPLCommentBodyById (issue #893, plan slice s2): promoted
          to .github/scripts/lib/marker-transport-core.ps1 as
          Find-CommentIdByExactMarker, Get-CommentIdFromUrl, and
          Get-CommentBodyById -- byte-identical behavior, same call shapes,
          same single-result lowest-REST-id tie-break. The PPL-prefixed
          names below are now one-line delegators to those, kept only so
          this file's own internal call sites and
          .github/scripts/Tests/persist-phase-ledger.Tests.ps1's mocked
          assertions never had to change. Set-PPLPointerLineAfterMarker was
          promoted alongside them, generalized to Set-PointerLineAfterMarker
          (a future marker-write path needs its CRLF-safe insertion logic
          for its own, differently-shaped pointer line).
      (c) Set-PPLJudgeRulingsBlockOnComment's span-replace branch -- locates and
          replaces the existing `<!-- judge-rulings ... -->` head+entries
          span in place on re-persist (Add-JudgeRulingsBlock is
          append-only by contract and must never be used for this).

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
        One-line delegator (issue #893, plan slice s2) to the promoted
        Get-CommentIdFromUrl (.github/scripts/lib/marker-transport-core.ps1)
        -- byte-identical behavior, kept under this name so every existing
        internal call site in this file needs no change.
    .OUTPUTS
        [long] or $null. See Get-CommentIdFromUrl for the full contract.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)
    return Get-CommentIdFromUrl @PSBoundParameters
}

function script:Get-PPLCommentBodyById {
    <#
    .SYNOPSIS
        One-line delegator (issue #893, plan slice s2) to the promoted
        Get-CommentBodyById (.github/scripts/lib/marker-transport-core.ps1)
        -- byte-identical behavior, kept under this name so every existing
        internal call site in this file needs no change.
    .OUTPUTS
        [string] or $null. See Get-CommentBodyById for the full contract.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId
    )
    return Get-CommentBodyById @PSBoundParameters
}

function script:Set-PPLCommentBodyDirect {
    <#
    .SYNOPSIS
        One-line delegator (issue #893, plan slice s2) to the promoted
        Set-CommentBodyDirect (.github/scripts/lib/marker-transport-core.ps1)
        -- byte-identical behavior, kept under this name so every existing
        internal call site in this file needs no change.
    .OUTPUTS
        [PSCustomObject] with Success [bool] and Reason [string]. See
        Set-CommentBodyDirect for the full contract.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewBody
    )
    return Set-CommentBodyDirect @PSBoundParameters
}

function script:Find-PPLCommentIdByExactMarker {
    <#
    .SYNOPSIS
        One-line delegator (issue #893, plan slice s2) to the promoted
        Find-CommentIdByExactMarker
        (.github/scripts/lib/marker-transport-core.ps1) -- byte-identical
        behavior (same `gh issue view` call shape, same single-result
        lowest-REST-id tie-break), kept under this name so every existing
        internal call site in this file and
        .github/scripts/Tests/persist-phase-ledger.Tests.ps1's mocked
        assertions needed no change.
    .OUTPUTS
        [PSCustomObject] with Id [long] and Body [string], or $null. See
        Find-CommentIdByExactMarker for the full contract.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$Marker
    )
    return Find-CommentIdByExactMarker @PSBoundParameters
}

function script:Set-PPLPointerLineAfterMarker {
    <#
    .SYNOPSIS
        One-line delegator (issue #893, plan slice s2) to the promoted,
        generalized Set-PointerLineAfterMarker
        (.github/scripts/lib/marker-transport-core.ps1) -- byte-identical
        behavior. The promoted function takes an arbitrary -PointerLine
        instead of this function's phase-containment-ledger-specific
        -SiblingId, so this delegator builds the exact same
        `<!-- phase-containment-ledger-ref: {id} -->` text this function
        always produced and forwards it, keeping every existing internal
        call site in this file unchanged.
    .OUTPUTS
        [string] the new plan-comment body. See Set-PointerLineAfterMarker
        for the full contract (CRLF-safe insertion, fallback semantics).
    #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][long]$SiblingId
    )
    return Set-PointerLineAfterMarker -Body $Body -Marker $Marker -PointerLine "<!-- phase-containment-ledger-ref: $SiblingId -->"
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

function script:Set-PPLBriefHeadBlockOnComment {
    <#
    .SYNOPSIS
        Issue #951: writes the brief-review `brief_dispositions:` authorizing
        head onto a known comment id — append when no head exists yet,
        span-replace when one already does. Structurally parallel to
        Set-PPLJudgeRulingsBlockOnComment above.
    .DESCRIPTION
        WHAT THIS REFUSES, and why refusing is the point. The whole reason
        issue #951 exists is that a run with no judge stage could reach for
        the judge vocabulary and nothing stopped it. A writer that would
        cheerfully persist judge content under a brief head would leave that
        path open at the one place best positioned to close it, so this
        function fails loud on:
          - content that is not a conformant brief head (no
            `brief_dispositions:` key at a real line-start key position);
          - content carrying ANY judge vocabulary — a `judge-rulings` head or a
            `judge_ruling:` field. There is no legitimate reason for either to
            appear in a brief's authorizing record, and D6's reader-side
            contradiction check should never be the first thing to notice;
          - content with no machine-readable `convergence_filter_ran`
            assertion, which the emission check requires and would otherwise
            render could-not-verify AFTER the write had already landed.
        A caller that cannot satisfy these has nothing lawful to write, and
        the honest outcome is a refusal plus no ledger rows — which is exactly
        what `own-run-ledger-emission-951` asks a blocked run to do.
    .OUTPUTS
        [PSCustomObject] Success [bool], Reason [string], Action [string]
        ('written' | 'replaced'; $null when Success=$false).
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [Parameter(Mandatory)][string]$BriefHeadContent
    )

    # HOW MANY HEADS, not just whether there is one (post-fix review, finding
    # M2). Counting here is the ONLY guard that catches a payload carrying two
    # concatenated `brief_dispositions:` heads, and that case is inside the
    # accepted criterion for #963's item-3+7 ("second head in one payload not
    # writer-refused"). Every other check below is structurally blind to it:
    # the preamble scan truncates at the FIRST head's `findings:` key, so the
    # second head's fields are out of scope and both uniqueness counts still
    # read 1; and the column-0 check's `[regex]::Replace` is global, so on a
    # two-head payload it strips BOTH key lines and collapses to the last
    # head's body, which is fully indented and passes. Measured before this
    # guard existed: a two-head payload was accepted and written, then read
    # back `ParseStatus=could-not-verify Reason=duplicate-head` — the
    # write-then-fail sequence this whole function exists to prevent.
    #
    # Deliberately ADDITIVE. Do not instead tighten the `[regex]::Replace`
    # below to a single-replacement form: that global replace is precisely
    # what makes the flat-head (column-0) check work, and narrowing it trades
    # this defect for that one.
    $headKeyMatches = @([regex]::Matches($BriefHeadContent, '(?m)^brief_dispositions[ \t]*:[ \t]*\r?$'))
    if ($headKeyMatches.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent carries no line-start `brief_dispositions:` head; refusing to write a head no reader will recognize'; Action = $null }
    }
    if ($headKeyMatches.Count -gt 1) {
        return [PSCustomObject]@{ Success = $false; Reason = "BriefHeadContent carries $($headKeyMatches.Count) line-start ``brief_dispositions:`` heads; this payload is two or more heads concatenated into one string. The reader fails loud on a duplicate head (DD3) and would render could-not-verify after this write had already landed. Refusing rather than writing one head's worth of a multi-head payload"; Action = $null }
    }
    if ([regex]::IsMatch($BriefHeadContent, '(?m)^[ \t]*<!--\s*judge-rulings(?:\s|-->|$)') -or
        [regex]::IsMatch($BriefHeadContent, '(?m)^\s*(?:-\s+)?judge_ruling\s*:')) {
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent carries judge vocabulary (a judge-rulings head or a judge_ruling field). A brief review has no judge stage, so no judge ruling can describe it; refusing to write the exact false provenance issue #951 exists to remove'; Action = $null }
    }
    # The writer's refusal list must be a SUPERSET of what the reader requires
    # (#963 review, finding J). It previously checked three things while the
    # reader enforced five, so a head missing `filtered_count`, or declaring
    # the filter did not run, or carrying its assertion only inside a finding
    # entry, was written cheerfully and THEN rendered could-not-verify — the
    # precise outcome this function's docstring says it exists to prevent.
    #
    # Scoped to the head's own preamble, mirroring the reader: a field nested
    # under `findings:` is that finding's, not the head's, and accepting it
    # here would let the reader and writer disagree about what was asserted.
    $headPreamble = $BriefHeadContent
    foreach ($p in @('(?m)^[ \t]*findings[ \t]*:', '(?m)^[ \t]*-[ \t]+')) {
        $m = [regex]::Match($headPreamble, $p)
        if ($m.Success) { $headPreamble = $headPreamble.Substring(0, $m.Index) }
    }
    # AMBIGUITY IS ALSO A COULD-NOT-VERIFY CAUSE (#963 review, item 3+7). The
    # original superset check verified PRESENCE — it never verified UNIQUENESS.
    # A head with a duplicated assertion, a duplicated filtered_count, or an
    # unrecognised disposition value wrote successfully here and then rendered
    # could-not-verify at read time, exactly the write-then-fail sequence this
    # function's docstring says it prevents. `-gt 1` refuses ambiguity the
    # same way the reader's own `head-corrupt`/`unknown-disposition-value`
    # paths do, rather than picking a match and hoping it was the right one.
    $assertionMatches = @([regex]::Matches($headPreamble, '(?m)^[ \t]*convergence_filter_ran[ \t]*:[ \t]*(true|false)[ \t]*\r?$'))
    if ($assertionMatches.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent carries no machine-readable `convergence_filter_ran: true|false` assertion as a key of the head itself; the emission check requires it and would render could-not-verify after this write had already landed'; Action = $null }
    }
    if ($assertionMatches.Count -gt 1) {
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent carries more than one `convergence_filter_ran` assertion; the reader fails loud on this ambiguity (DD3) and would render could-not-verify after this write had already landed. Refusing rather than picking one'; Action = $null }
    }
    if ($assertionMatches[0].Groups[1].Value -ne 'true') {
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent declares `convergence_filter_ran: false`. That is an honest declaration and it is why this is a refusal rather than a silent write: prosecution output no convergence filter narrowed cannot authorize a count, so persisting blocks against it would create rows no reader will ever count. Run the convergence filter, or record the review outcome in prose and emit no rows'; Action = $null }
    }
    $filteredCountMatches = @([regex]::Matches($headPreamble, '(?m)^[ \t]*filtered_count[ \t]*:[ \t]*\d+[ \t]*\r?$'))
    if ($filteredCountMatches.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent declares the filter ran but carries no `filtered_count` as a key of the head itself; the emission check consumes that count and would render could-not-verify after this write had already landed'; Action = $null }
    }
    if ($filteredCountMatches.Count -gt 1) {
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent carries more than one `filtered_count` line; the reader treats a duplicated count as corruption (DD3) and would render could-not-verify after this write had already landed. Refusing rather than picking one'; Action = $null }
    }
    if ([regex]::IsMatch($headPreamble, '(?m)^[ \t]*-?[ \t]*(?:finding_id|disposition)[ \t]*:[ \t]*\S')) {
        # A `disposition:`/`finding_id:` line in the PREAMBLE (before the
        # `findings:` key or the first list item) means the caller's payload
        # is malformed in a way the region split above cannot correct for.
        #
        # SCOPE, corrected by the post-fix review (finding M2). This check was
        # originally described as catching "two heads concatenated". It does
        # not, and cannot: the preamble is truncated at the FIRST head's
        # `findings:` key, so a well-formed second head lies entirely outside
        # the scanned region. Two-head payloads are caught by the head-key
        # occurrence count at the top of this function; what this check
        # actually catches is a head whose OWN preamble carries finding
        # fields that belong under `findings:` — including the degenerate
        # case of a second head flattened to column 0 so that its fields land
        # in the first head's preamble.
        #
        # The `-?` alternative is NOT dead, though it is narrow: the list-item
        # truncation pattern above is `^[ \t]*-[ \t]+` and REQUIRES whitespace
        # after the hyphen, so a `-finding_id: X` line written without that
        # space survives truncation and is caught only here.
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent carries a `disposition:` or `finding_id:` line in the head''s own preamble, before its `findings:` key. Those fields belong to a finding entry, not to the head. Refusing — the reader would not attribute them as this head intends and would render a count the caller did not mean to assert'; Action = $null }
    }
    # A head whose body is not fully indented cannot be safely REPLACED on
    # re-persist (#963 review, item 16). The span-replace below is bounded by
    # the first following column-0 line, so a column-0 sub-key (a flat head)
    # loses only its `brief_dispositions:` line on re-persist — every field
    # after it survives, unindented, directly below the new head. Both count
    # cross-checks then double together and ParseStatus stays `ok`: a SILENT
    # doubling of the authorizing record's SustainedCount/DismissedCount, in
    # the exact instrument #951 exists to make trustworthy. Refusing a flat
    # head here is cheaper and more honest than making the span-replace
    # correct for every possible indentation shape.
    $headBodyAfterKey = [regex]::Replace($BriefHeadContent, '(?s)^.*?^brief_dispositions[ \t]*:[ \t]*\r?$\r?\n?', '', 'Multiline')
    if ([regex]::IsMatch($headBodyAfterKey, '(?m)^\S')) {
        return [PSCustomObject]@{ Success = $false; Reason = 'BriefHeadContent carries a column-0 (un-indented) line after `brief_dispositions:`; the head must be a single indented block so a re-persist''s span-replace always covers the WHOLE head. An un-indented head silently doubles the ledger''s counts on re-persist rather than replacing them'; Action = $null }
    }

    $currentBody = script:Get-PPLCommentBodyById -Owner $Owner -Repo $Repo -CommentId $CommentId
    if ($null -eq $currentBody) {
        return [PSCustomObject]@{ Success = $false; Reason = "Could not read comment $CommentId body before writing the brief head"; Action = $null }
    }
    if (-not $currentBody.Contains($ExpectedMarker)) {
        return [PSCustomObject]@{ Success = $false; Reason = "Comment does not contain expected marker '$ExpectedMarker' — refusing to write the brief head onto an unrelated comment"; Action = $null }
    }

    # Span-replace an existing brief head, so a re-persist replaces its own
    # head rather than stacking a second one — two heads on one sibling is an
    # ambiguity the reader is required to fail loud on.
    $headMatch = [regex]::Match($currentBody, '(?ms)^brief_dispositions[ \t]*:[ \t]*\r?$.*?(?=^\S|\z)')
    $newBody = if ($headMatch.Success) {
        $currentBody.Substring(0, $headMatch.Index) + $BriefHeadContent + "`n" + $currentBody.Substring($headMatch.Index + $headMatch.Length)
    }
    else {
        $currentBody.TrimEnd() + "`n`n" + $BriefHeadContent + "`n"
    }

    $writeResult = script:Set-PPLCommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $CommentId -NewBody $newBody
    if (-not $writeResult.Success) {
        return [PSCustomObject]@{ Success = $false; Reason = $writeResult.Reason; Action = $null }
    }
    return [PSCustomObject]@{ Success = $true; Reason = $null; Action = $(if ($headMatch.Success) { 'replaced' } else { 'written' }) }
}

function script:Resolve-PPLLedgerSibling {
    <#
    .SYNOPSIS
        Issue #951: resolves (finding or creating) the
        `<!-- phase-containment-ledger-{ID} -->` sibling comment for an issue
        and ensures the plan comment carries its pointer.
    .DESCRIPTION
        Extracted verbatim from plan mode so brief mode can reuse it rather
        than grow a second copy. The sibling/pointer lifecycle is identical
        for both shapes — only WHAT gets written onto the sibling differs —
        and two copies of this logic would drift, with the divergence showing
        up as lost ledger data rather than as a test failure.
    .OUTPUTS
        [PSCustomObject] Success [bool], Reason [string], SiblingId [long].
        Mutates the supplied $Artifacts manifest's Sibling/Pointer fields.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][object]$Artifacts
    )

    $planMarker = "<!-- plan-issue-$IssueNumber -->"
    $ledgerMarker = "<!-- phase-containment-ledger-$IssueNumber -->"
    $artifacts = $Artifacts

    $planComment = script:Find-PPLCommentIdByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -Marker $planMarker
    if ($null -eq $planComment) {
        return [PSCustomObject]@{ Success = $false; Reason = "Plan comment carrying marker '$planMarker' not found (line-anchored, whole-line match) on issue $IssueNumber"; SiblingId = $null }
    }
    $planCommentId = $planComment.Id
    $planBody = $planComment.Body

    $pointerMatch = [regex]::Match($planBody, '(?m)^[ \t]*<!--\s*phase-containment-ledger-ref:\s*(\d+)\s*-->[ \t]*\r?$')
    if ($pointerMatch.Success) {
        $siblingId = [long]$pointerMatch.Groups[1].Value
        $artifacts.Sibling = 'reused'
        $artifacts.Pointer = 'already-present'
        return [PSCustomObject]@{ Success = $true; Reason = $null; SiblingId = $siblingId }
    }

    $existingSibling = script:Find-PPLCommentIdByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -Marker $ledgerMarker
    if ($null -ne $existingSibling) {
        $siblingId = $existingSibling.Id
        $artifacts.Sibling = 'reused'
    }
    else {
        $createdUrl = Find-OrUpsertComment -Type 'issue' -Number $IssueNumber -Marker $ledgerMarker -Body $ledgerMarker -Owner $Owner -Repo $Repo
        if ($null -eq $createdUrl) {
            $artifacts.Sibling = 'failed'
            return [PSCustomObject]@{ Success = $false; Reason = 'Failed to create the phase-containment-ledger sibling comment (Find-OrUpsertComment returned $null)'; SiblingId = $null }
        }
        $siblingId = script:Get-PPLCommentIdFromUrl -Url $createdUrl
        if ($null -eq $siblingId) {
            $artifacts.Sibling = 'failed'
            return [PSCustomObject]@{ Success = $false; Reason = "Could not extract a numeric comment id from the created sibling's url '$createdUrl'"; SiblingId = $null }
        }
        $artifacts.Sibling = 'created'
    }

    $newPlanBody = script:Set-PPLPointerLineAfterMarker -Body $planBody -Marker $planMarker -SiblingId $siblingId
    $pointerResult = script:Set-PPLCommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $planCommentId -NewBody $newPlanBody
    if (-not $pointerResult.Success) {
        $artifacts.Pointer = 'failed'
        return [PSCustomObject]@{ Success = $false; Reason = "Failed to insert the phase-containment-ledger-ref pointer into the plan comment: $($pointerResult.Reason)"; SiblingId = $null }
    }
    $artifacts.Pointer = 'written'
    return [PSCustomObject]@{ Success = $true; Reason = $null; SiblingId = $siblingId }
}

function script:Invoke-PPLPersistPhaseLedgerBriefMode {
    <#
    .SYNOPSIS
        Issue #951: persists a brief-review authorizing head plus zero or more
        phase-containment blocks onto the issue's ledger sibling.
    .DESCRIPTION
        Deliberately a THIRD MODE rather than a parameterization of plan mode.
        Plan mode's contract is "a judge-rulings block first, then the blocks
        it authorizes"; brief mode's is "a brief_dispositions head first, then
        the blocks IT authorizes, and never a judge-rulings block at all".
        Threading a flag through plan mode would have left the judge-rulings
        write reachable from the brief path by omission — which is the same
        shape of defect as the `if design … else assume-plan` dispatch this
        change replaces.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$BriefHeadContent,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PhaseContainmentBlocks
    )

    $ledgerMarker = "<!-- phase-containment-ledger-$IssueNumber -->"
    $artifacts = script:New-PPLPersistPhaseLedgerArtifactManifest

    $sibling = script:Resolve-PPLLedgerSibling -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -Artifacts $artifacts
    if (-not $sibling.Success) {
        return [PSCustomObject]@{ Success = $false; Reason = $sibling.Reason; Artifacts = $artifacts }
    }

    $headResult = script:Set-PPLBriefHeadBlockOnComment -Owner $Owner -Repo $Repo -CommentId $sibling.SiblingId -ExpectedMarker $ledgerMarker -BriefHeadContent $BriefHeadContent
    if (-not $headResult.Success) {
        # The manifest field is named JudgeRulings for historical reasons and
        # is the generic "authorizing head" slot; brief mode writes no judge
        # ruling of any kind.
        $artifacts.JudgeRulings = 'failed'
        return [PSCustomObject]@{ Success = $false; Reason = $headResult.Reason; Artifacts = $artifacts }
    }
    $artifacts.JudgeRulings = $headResult.Action

    if ($PhaseContainmentBlocks.Count -gt 0) {
        $blockResult = script:Set-PPLPhaseContainmentBlocksOnComment -Owner $Owner -Repo $Repo -CommentId $sibling.SiblingId -ExpectedMarker $ledgerMarker -Blocks $PhaseContainmentBlocks
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

function script:Invoke-PPLPersistPhaseLedgerPlanMode {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$JudgeRulingsContent,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PhaseContainmentBlocks
    )

    $ledgerMarker = "<!-- phase-containment-ledger-$IssueNumber -->"
    $artifacts = script:New-PPLPersistPhaseLedgerArtifactManifest

    # Issue #951: the sibling/pointer lifecycle moved verbatim into
    # Resolve-PPLLedgerSibling so brief mode reuses it instead of copying it.
    # Every fix that logic already carries -- the F3 line-anchored pointer
    # match, the M1 find-sibling-by-marker-before-upsert guard that stops
    # Find-OrUpsertComment wiping an accumulated sibling, and the F2
    # explicit -Owner/-Repo threading -- now protects both shapes from one
    # place. Two copies would have drifted, and the drift would have shown up
    # as lost ledger data rather than as a failing test.
    $sibling = script:Resolve-PPLLedgerSibling -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -Artifacts $artifacts
    if (-not $sibling.Success) {
        return [PSCustomObject]@{ Success = $false; Reason = $sibling.Reason; Artifacts = $artifacts }
    }
    $siblingId = $sibling.SiblingId

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
        'plan', 'design', or 'brief'. Selects the persistence surface and
        required companion parameter (-IssueNumber for plan and brief,
        -DesignCommentId for design; -BriefHeadContent additionally for brief).
    .PARAMETER BriefHeadContent
        Required when -Mode brief (issue #951). The complete
        `brief_dispositions:` authorizing head — the judge-free record that
        authorizes counting a brief review's phase-containment blocks, carrying
        the mandatory `convergence_filter_ran` assertion and its
        `filtered_count`. -JudgeRulingsContent is accepted under this mode and
        never forwarded: a brief review has no judge stage, so there is no
        judge ruling that could describe it, and
        Set-PPLBriefHeadBlockOnComment additionally refuses head content
        carrying judge vocabulary. Same discard precedent as design mode
        below. (This sentence previously added "it is Mandatory on the shared
        signature" — false since #963 review finding B made
        -JudgeRulingsContent non-Mandatory with a '' default; corrected by the
        post-fix review, finding M8.)
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
        [Parameter(Mandatory)][ValidateSet('plan', 'design', 'brief')][string]$Mode,
        [int]$IssueNumber,
        [long]$DesignCommentId,
        # No longer [Parameter(Mandatory)] (#963 review, finding B): -Mode
        # brief has no judge ruling to supply, and forcing a caller to invent
        # one for a mode that refuses judge content is the false-provenance
        # shape this issue exists to remove. Required for plan and design,
        # enforced per-mode in the dispatch below.
        [string]$JudgeRulingsContent = '',
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PhaseContainmentBlocks,
        [string]$BriefHeadContent = ''
    )

    # ISSUE #951 — RESTRUCTURED, NOT APPENDED TO.
    #
    # This dispatch used to be `if ($Mode -eq 'design') { … }` followed by an
    # unguarded fall-through that ASSUMED plan. That shape has no room for a
    # third value: adding 'brief' to the ValidateSet would have routed every
    # brief call into plan-mode logic — including the `$IssueNumber -le 0`
    # guard, whose error message names plan, and the judge-rulings write a
    # brief must never perform. The failure would have been silent at the
    # dispatch and loud only much later, in the corpus.
    #
    # Now every mode is an explicit, named branch that validates its OWN
    # companion parameter, and an unrecognized mode throws rather than
    # defaulting into anyone's logic. A fourth review shape must add a branch
    # here; it cannot arrive by omission.
    switch ($Mode) {
        'design' { break }
        'plan'   { break }
        'brief'  { break }
        default  { throw "Invoke-PersistPhaseLedger: unhandled -Mode '$Mode'. Every mode must have an explicit branch below; a mode must never reach another mode's logic by fall-through." }
    }

    if ($Mode -eq 'brief') {
        if ($IssueNumber -le 0) {
            return [PSCustomObject]@{ Success = $false; Reason = 'Mode brief requires a positive -IssueNumber'; Artifacts = (script:New-PPLPersistPhaseLedgerArtifactManifest) }
        }
        if ([string]::IsNullOrWhiteSpace($BriefHeadContent)) {
            return [PSCustomObject]@{ Success = $false; Reason = 'Mode brief requires -BriefHeadContent (the `brief_dispositions:` authorizing head). A brief review has no judge stage, so -JudgeRulingsContent cannot substitute for it'; Artifacts = (script:New-PPLPersistPhaseLedgerArtifactManifest) }
        }
        return script:Invoke-PPLPersistPhaseLedgerBriefMode -Owner $Owner -Repo $Repo -IssueNumber $IssueNumber -BriefHeadContent $BriefHeadContent -PhaseContainmentBlocks $PhaseContainmentBlocks
    }

    if ($Mode -ne 'brief' -and [string]::IsNullOrWhiteSpace($JudgeRulingsContent)) {
        return [PSCustomObject]@{ Success = $false; Reason = "Mode $Mode requires -JudgeRulingsContent"; Artifacts = (script:New-PPLPersistPhaseLedgerArtifactManifest) }
    }

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
