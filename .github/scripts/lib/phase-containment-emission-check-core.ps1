#Requires -Version 7.0

# phase-containment-emission-check-core.ps1
# Core library for the phase-containment emission backstop (issue #782).
# Detects when adversarial-review sustained findings are missing their
# paired <!-- phase-containment-{ID} --> ledger blocks.
#
# SECURITY: Do NOT import powershell-yaml or use ConvertFrom-Yaml in this file.
# These are forbidden for parsing untrusted GitHub comment bodies (YamlDotNet
# billion-laughs risk). All parsing uses a hand-rolled line-regex parser only.
#
# Non-goals (s1 scope): Get-SustainedFindingCount and Get-EmissionGap are pure
# string -> result; they perform no GitHub fetching. Add-CommentBlocks is the
# one function in this file that does call `gh api` — it is the s4 backfill
# append primitive, explicitly co-located here by the frame-slice contract
# (read-modify-write comment append; never Find-OrUpsertComment for appends,
# since Find-OrUpsertComment's PATCH path replaces the body verbatim and would
# destroy the judge-rulings YAML that Code-Conductor's credits harvest reads).

Set-StrictMode -Version Latest

# Reuse Get-PhaseContainmentBlock for closed-block counting rather than
# re-implementing the block regex (delegation-instead-of-duplication).
. (Join-Path $PSScriptRoot 'phase-containment-core.ps1')

# Single source of truth for the general judge-rulings HEAD pattern (bare
# `<!-- judge-rulings` or attributed `<!-- judge-rulings pr=N -->` — the
# attributed form's `pr=N` prefix satisfies this pattern's `\s` alternative,
# so it matches both head shapes without a separate attributed-specific
# check). Four sites in this file need "does a real judge-rulings head exist
# here" (Test-EmissionMarkerPresent's vocab gate, the duplicate-head count in
# Get-JudgeRulingsSustainedCountInternal, its bare-head fallback match, and
# Get-EmissionGap's real-vs-fallback classification); a single named constant
# means a future change to the head shape touches one place instead of
# silently drifting across four inline copies (refactor 811-D1-refactor-1).
$script:JudgeRulingsHeadPattern = '<!--\s*judge-rulings(?:\s|-->|$)'

# Bounded lookahead window after a matched head, within which real marker
# content is expected to appear (shared by every vocab-gate scan in this
# file — Test-EmissionMarkerPresent, Get-JudgeRulingsSustainedCountInternal's
# duplicate-head guard and region-isolation, and Get-EmissionGap's
# hasRealHead classification).
$script:JudgeRulingsLookaheadWindow = 400

# Vocab-gate field-token pattern: a head match is only "real" (as opposed to
# a bare prose mention of the marker convention) when at least one of these
# tokens appears at a real YAML key position within the lookahead window.
$script:JudgeRulingsVocabGatePattern = '(?m)(?:^\s*(?:-\s+)?|[{,]\s*)(disposition|judge_ruling|verdict|finding_key)\s*:'

#region Valid surfaces / id-domain mapping

# -Surface uses the core's stage names exactly (StageProjections keys):
# 'code-review', 'design-challenge', 'plan-stress-test' — see the three
# [ValidateSet('code-review', 'design-challenge', 'plan-stress-test')]
# parameter attributes in this file for the single source of truth (M11:
# removed the redundant, never-referenced $script:ValidEmissionCheckSurfaces
# array — PowerShell's ValidateSet attribute requires compile-time constant
# values, so it cannot reference a script-scoped variable as a dynamic
# source without a custom IValidateSetValuesGenerator class, which is more
# machinery than three inline literal lists warrant here).
# id-domain per surface:
#   code-review                -> Id = PR number,    blocks live on PR comments
#   design-challenge            -> Id = issue number, blocks live on issue comments (design-phase-complete-{ID})
#   plan-stress-test            -> Id = issue number, blocks live on issue comments (plan-issue-{ID})
# Callers must pass the matching domain; this module does not verify it.

#endregion

#region Get-RealJudgeRulingsHeadMatches (private)

function script:Get-RealJudgeRulingsHeadMatches {
    <#
    .SYNOPSIS
        Scans a body for ALL judge-rulings head candidates and returns only
        those that pass the vocab gate (real heads), preserving encounter
        order.
    .DESCRIPTION
        GH-3 fix (PR #815 review): every prior head-detection site in this
        file used a standalone first-match `[regex]::Match` call, which lets
        a vocab-gate-FAILING decoy head positioned textually before a real,
        vocab-gate-PASSING block suppress detection of the real block
        entirely (both a false could-not-verify on plan-stress-test and a
        silent false-clean on code-review). This helper is the single scan
        every head-detection call site now reuses: it walks every raw head
        match (not just the first) and keeps only the ones whose bounded
        lookahead window contains real field vocabulary, so callers can
        select "the first REAL head" instead of "the first RAW match."
    .PARAMETER Body
        The raw comment body text to scan.
    .OUTPUTS
        [System.Text.RegularExpressions.Match[]] — the subset of
        $script:JudgeRulingsHeadPattern matches that pass the vocab gate, in
        original encounter order. Empty array when none pass.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    $allHeadMatches = [regex]::Matches($Body, $script:JudgeRulingsHeadPattern)
    $realHeadMatches = [System.Collections.Generic.List[System.Text.RegularExpressions.Match]]::new()
    foreach ($candidateHead in $allHeadMatches) {
        $windowEnd = [Math]::Min($Body.Length, $candidateHead.Index + $candidateHead.Length + $script:JudgeRulingsLookaheadWindow)
        $window = $Body.Substring($candidateHead.Index, $windowEnd - $candidateHead.Index)
        if ([regex]::IsMatch($window, $script:JudgeRulingsVocabGatePattern)) {
            $realHeadMatches.Add($candidateHead)
        }
    }
    return , $realHeadMatches.ToArray()
}

#endregion

#region Test-EmissionMarkerPresent

function Test-EmissionMarkerPresent {
    <#
    .SYNOPSIS
        Reports whether a comment body contains a recognizable judge-rulings /
        finding_dispositions marker HEAD for the given surface, without
        attempting to parse or validate the marker's content.
    .DESCRIPTION
        Used by Get-EmissionGap to distinguish two cases that DD3's fail-loud
        invariant otherwise conflated (issue #782 live-validation correction):

          1. No marker head at all -> this body is ordinary PR/issue chatter
             (bot notices, "LGTM", unrelated replies) that was never meant to
             carry a phase-containment marker. It is NOT a could-not-verify
             condition; it simply contributes nothing.
          2. A marker head IS present -> this body claims to be an
             authoritative judge-rulings surface. Its content must then parse
             cleanly via Get-SustainedFindingCount, or the existing DD3
             fail-loud invariant applies (unparseable/ambiguous/unknown
             vocabulary is still could-not-verify, never silently zero).

        Matches the SAME marker-head patterns Get-SustainedFindingCount's
        internal parsers use for each surface:
          code-review / plan-stress-test: bare `<!-- judge-rulings` or
            attributed `<!-- judge-rulings pr=N -->`
          design-challenge: `finding_dispositions:` YAML key

        811-D1 INTENTIONAL DIVERGENCE (plan-stress-test surface only): head
        detection here can no longer be claimed to "never diverge" from
        Get-SustainedFindingCount's own head detection, and that is now
        deliberate rather than a bug. A plan comment can legitimately carry
        a prose-only "Plan Stress-Test" section (heading + narrative
        bullets) with no machine-readable judge-rulings block at all — every
        plan persisted before the 811 writer change is exactly this shape.
        Treating that as "no marker at all" (ordinary chatter, contributes
        0 per case 1 above) rendered a false `clean -- sustained=0 blocks=0`,
        indistinguishable from an issue with no stress-test history
        whatsoever. For plan-stress-test only, when the vocab-gated
        judge-rulings check above returns false, a second fallback check
        fires: if the body ALSO carries both a `<!-- plan-issue-` marker and
        a line-start `**Plan Stress-Test**` heading, this function reports
        the marker as present anyway, so Get-EmissionGap's caller renders an
        honest could-not-verify instead of a reassuring clean. This gate/
        counter divergence is surfaced downstream via Get-EmissionGap's
        `Reason` field: 'head-missing' when this fallback is what made the
        marker read as present (no real judge-rulings head exists at all);
        'head-corrupt' when a real head IS present elsewhere but failed to
        parse; 'ok' otherwise. code-review is unaffected by this
        plan-stress-test-specific fallback/Reason logic specifically — it
        never reaches the fallback branch above. The duplicate-head guard in
        Get-JudgeRulingsSustainedCountInternal (M1 fix) is vocab-gated and
        shared by BOTH surfaces, so a genuine duplicate real head on either
        surface still correctly fails loud; only a bare prose mention of the
        marker convention (no real vocabulary) is excluded from the count.
        design-challenge's marker-head detection and counting logic is
        entirely separate and cannot diverge from either surface.

        M6 fix (issue #782 post-review): a bare head-substring match alone
        used to be sufficient, which meant a maintainer describing the
        marker convention in ordinary prose (e.g. "this PR uses the
        standard <!-- judge-rulings pr=N --> marker for tracking review
        dispositions") forced the whole-PR aggregate to could-not-verify
        even when the real judge-rulings comment elsewhere on the PR parsed
        cleanly. The head match now must additionally anchor a region that
        looks like it is trying to be a real judge-rulings /
        finding_dispositions body: within a bounded lookahead window after
        the head, at least one recognizable field-vocabulary token
        (disposition/judge_ruling/verdict/finding_key for code-review and
        plan-stress-test; disposition/finding_id/schema_version for
        design-challenge) must appear as a YAML-shaped `key:` token. A bare
        mention with no such follow-on content is treated as ordinary prose,
        not a real marker.
    .PARAMETER Surface
        One of: code-review, design-challenge, plan-stress-test
    .PARAMETER Body
        The raw comment body text to scan.
    .OUTPUTS
        [bool] $true when a recognizable marker head is present, else $false.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('code-review', 'design-challenge', 'plan-stress-test')][string]$Surface,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $false
    }

    # Bounded lookahead window after a matched head, within which real
    # marker content is expected to appear. Generous enough to cover every
    # live fixture's head-to-first-field distance, small enough that a
    # single sentence of surrounding prose cannot accidentally satisfy it.
    $lookaheadWindow = 400

    if ($Surface -eq 'design-challenge') {
        $headMatch = [regex]::Match($Body, '(?m)^finding_dispositions\s*:\s*$')
        if (-not $headMatch.Success) { return $false }
        $windowEnd = [Math]::Min($Body.Length, $headMatch.Index + $headMatch.Length + $lookaheadWindow)
        $window = $Body.Substring($headMatch.Index, $windowEnd - $headMatch.Index)
        return [regex]::IsMatch($window, '(?m)^\s*(disposition|finding_id|schema_version)\s*:')
    }

    # code-review and plan-stress-test share the judge-rulings marker head.
    # M9 fix: \b is a non-word boundary, and a hyphen is ALSO a non-word
    # character, so a bare \b-anchored regex matched superstring marker
    # names like '<!-- judge-rulings-report -->' as if they were the real
    # judge-rulings head. Tightened so the head must be followed by
    # whitespace (the real marker's normal continuation), the closing
    # '-->' (immediate self-close), or end-of-string — never an unrelated
    # identifier character run like '-report'.
    #
    # GH-3 fix (PR #815 review): this used to be a standalone first-match
    # `[regex]::Match` + single vocab-gate check, which meant a vocab-gate-
    # FAILING decoy head positioned before a real, vocab-gate-PASSING block
    # made this function return $false without ever looking past the decoy
    # — a silent false-clean, since Get-EmissionGap then treats the whole
    # body as ordinary chatter and contributes 0. Reusing
    # Get-RealJudgeRulingsHeadMatches (the same scan-all-candidates helper
    # the M1 duplicate-head guard below uses) means ANY vocab-gate-passing
    # head anywhere in the body — not just the first raw match — is enough
    # to report the marker as present.
    # PF-F2 fix (issue #782 post-fix defense pass) note preserved: the vocab
    # gate's key-position anchor recognizes true line-start, a `- `
    # dash-space list-item prefix, and flow-mapping `{`/`,` position (see
    # $script:JudgeRulingsVocabGatePattern and Get-JudgeRulingsSustainedCountInternal's
    # $keyAnchor for the counting-side counterpart).
    $vocabGateResult = (Get-RealJudgeRulingsHeadMatches -Body $Body).Count -gt 0

    if ($vocabGateResult) {
        return $true
    }

    # 811-D1 plan-stress-test-surface-only fallback (M3/GB-F1): the vocab
    # gate above just said "no real judge-rulings marker here" — either no
    # head at all, or a head present but failing the vocab window (a
    # malformed/foreign head must NOT suppress this fallback; it keys off
    # the vocab gate's own boolean result, never a separate raw
    # head-substring re-test, so a present-but-broken head is still
    # correctly routed here rather than silently passing as "real"). For
    # plan-stress-test specifically, a body carrying BOTH a durable
    # `<!-- plan-issue-` marker (any issue number) AND a line-start
    # `**Plan Stress-Test**` heading is recognizably a plan's persisted
    # stress-test section, prose-only or otherwise, and must not collapse
    # into "ordinary chatter, contributes 0." Both conditions are required
    # together: a chatter comment that merely discusses the heading in
    # prose, with no `<!-- plan-issue-` marker, does not qualify (it truly
    # is ordinary discussion, not a plan's own persisted surface).
    if ($Surface -eq 'plan-stress-test') {
        $hasPlanIssueMarker = [regex]::IsMatch($Body, '<!--\s*plan-issue-')
        $hasPlanStressTestHeading = [regex]::IsMatch($Body, '(?m)^\*\*Plan Stress-Test\*\*')
        if ($hasPlanIssueMarker -and $hasPlanStressTestHeading) {
            return $true
        }
    }

    return $false
}

#endregion

#region Get-SustainedFindingCount

function Get-SustainedFindingCount {
    <#
    .SYNOPSIS
        Counts sustained findings inside a single comment body for a given surface.
    .DESCRIPTION
        Isolates the authoritative judge-rulings / finding_dispositions marker
        region first, then counts sustained findings only within it. Never
        counts prose or table decoys outside that region (uppercase "ACCEPT"
        badges, Markdown "Sustained" columns, required_fixes: parallel lists).

        Surface-specific sustained rules:
          code-review (canonical judge-rulings block):
            sustained iff judge_ruling: 'sustained' (NOT 'defense-sustained')
          code-review (GitHub-intake variant, review_mode: github-intake-proxy-prosecution):
            sustained iff disposition: 'accept' (not 'reject'), counted only
            inside the findings: list (required_fixes: is a decoy, never counted)
          code-review (four-value variant, e.g. Fix-now|Fix-in-PR|Defer|Dismiss):
            sustained = every listed finding whose disposition is not Dismiss
            (Defer findings ARE sustained — the finding was real, only the fix
            was deferred)
          design-challenge (finding_dispositions block):
            sustained iff disposition: is 'incorporate' or 'escalate' (i.e. not 'dismiss')
          plan-stress-test:
            same judge-rulings shape and rule as code-review (by-analogy; the
            plan surface persists judge rulings in the same shape as the
            code-review template)

        Marker-head matching: matches BOTH bare `<!-- judge-rulings` and
        attributed `<!-- judge-rulings pr=N -->` heads for code-review /
        plan-stress-test. design-challenge matches the `finding_dispositions:`
        YAML key.

        Fail-loud (DD3): any unparseable, ambiguous, or unknown-vocabulary
        body, or an unrecognized marker head, is a could-not-verify condition,
        never treated as zero. Zero sustained findings (marker present, no
        sustained entries) returns 0 with ParseStatus 'ok'.
    .PARAMETER Surface
        One of: code-review, design-challenge, plan-stress-test
    .PARAMETER Body
        The raw comment body text to scan.
    .OUTPUTS
        [PSCustomObject] with:
          SustainedCount [int]    — count of sustained findings (0 when none)
          ParseStatus    [string] — 'ok' or 'could-not-verify'
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('code-review', 'design-challenge', 'plan-stress-test')][string]$Surface,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    if ($Surface -eq 'design-challenge') {
        # issue #768 s3 (AC8): Get-DesignChallengeSustainedCountInternal now
        # additionally returns DefenseSustainedCount (consumed by the new
        # Get-DispositionTally, below). Re-project to the original two-field
        # shape here so this function's public output stays byte-identical.
        $internalResult = Get-DesignChallengeSustainedCountInternal -Body $Body
        return [PSCustomObject]@{ SustainedCount = $internalResult.SustainedCount; ParseStatus = $internalResult.ParseStatus }
    }

    # code-review and plan-stress-test share the judge-rulings marker shape.
    # Same re-projection as above (issue #768 s3, AC8): the internal now also
    # returns DefenseSustainedCount, but this function's public output must
    # stay byte-identical to its pre-#768 shape.
    $internalResult = Get-JudgeRulingsSustainedCountInternal -Body $Body
    return [PSCustomObject]@{ SustainedCount = $internalResult.SustainedCount; ParseStatus = $internalResult.ParseStatus }
}

#endregion

#region Get-DispositionTally

function Get-DispositionTally {
    <#
    .SYNOPSIS
        Per-entry segmented disposition tally for the phase-containment
        review-cost accounting (issue #768 s3). Sibling to
        Get-SustainedFindingCount; does not change that function's public
        output (AC8).
    .DESCRIPTION
        Unlike Get-SustainedFindingCount (which isolates ONE marker region and
        returns a single aggregate SustainedCount), this function SEGMENTS the
        marker payload into its individual entries first — splitting on
        entry-boundary dash-item starts (`- stable_finding_key:` for the
        code-review review-dispositions marker; `- finding_id:` for the
        judge-rulings / finding_dispositions markers) — and reads each entry's
        own keys only within that entry's own bounds. This is what makes a
        JOINT projection possible (e.g. code-review's per-reviewer-source x
        disposition table, AC2): a flat, region-wide regex count can only ever
        produce marginal counts, since it has no way to associate a
        `disposition:` value with the `reviewer_source:`/`stage:` that came
        from the SAME entry. Per-entry segmentation also closes two decoy
        vectors a flat count cannot: a `disposition_rationale` block-scalar
        value that quotes another finding's `disposition: dismiss` in prose,
        and an injected-newline field value that could otherwise be mistaken
        for a second entry.

        -Surface code-review parses the `<!-- review-dispositions-{PR} -->`
        marker (skills/solution-authoring/schemas/review-dispositions.schema.json)
        — a DIFFERENT marker than the PR-level judge-rulings verdict
        Get-SustainedFindingCount's code-review branch reads; both markers can
        legitimately co-exist on the same PR (the judge-rulings marker is the
        code-review pipeline's own sustained/defense-sustained verdict; the
        review-dispositions marker is the per-finding engineer-disposition
        ledger this function accounts). Returns a joint per-entry projection —
        one tuple per entry, `{StableFindingKey; Disposition; Stage;
        ReviewerSource}` — so callers can build both the AC1 per-stage
        dismiss/defer marginal and the AC2 per-source x disposition joint
        table from the same data. Entries are filtered to `stage ==
        'code-review'` (v1/v2 entries, which predate or omit the `stage`
        field, default to `code-review`); a `stage: ce` entry is excluded.

        -Surface design-challenge / plan-stress-test extend the two existing
        script-scoped internals (additive-return only; see
        Get-JudgeRulingsSustainedCountInternal and
        Get-DesignChallengeSustainedCountInternal above) and return the
        `(SustainedCount, DefenseSustainedCount)` pair those internals now
        compute. design-challenge's `finding_dispositions:` marker has no
        defense-sustained vocabulary at all (its `disposition` enum is
        incorporate|dismiss|escalate) — DefenseSustainedCount is always 0
        there.

        Fail-loud (DD3): any unparseable, ambiguous, or unknown-vocabulary
        body, or an unrecognized/absent marker head, is a could-not-verify
        condition, never treated as zero.
    .PARAMETER Surface
        One of: code-review, design-challenge, plan-stress-test
    .PARAMETER Body
        The raw comment body text to scan.
    .OUTPUTS
        [PSCustomObject]. For -Surface code-review:
          Surface     [string] — 'code-review'
          Entries     [PSCustomObject[]] — one per in-scope entry, each with
                      StableFindingKey, Disposition, Stage, ReviewerSource
          ParseStatus [string] — 'ok' or 'could-not-verify'
        For -Surface design-challenge / plan-stress-test:
          Surface               [string]
          SustainedCount        [int]
          DefenseSustainedCount [int]
          ParseStatus           [string] — 'ok' or 'could-not-verify'
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('code-review', 'design-challenge', 'plan-stress-test')][string]$Surface,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        if ($Surface -eq 'code-review') {
            return [PSCustomObject]@{ Surface = $Surface; Entries = @(); ParseStatus = 'could-not-verify' }
        }
        return [PSCustomObject]@{ Surface = $Surface; SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    if ($Surface -eq 'code-review') {
        $inner = Get-ReviewDispositionsTallyInternal -Body $Body
        # AC7 stage filter: only entries whose stage is 'code-review' are in
        # scope for this surface (v1/v2 entries, which predate or omit the
        # stage field, default to 'code-review' inside the internal parser
        # above and so pass this filter; a 'stage: ce' entry is excluded).
        $filteredEntries = @( if ($inner.ParseStatus -eq 'ok') { $inner.Entries | Where-Object { $_.Stage -eq 'code-review' } } )
        return [PSCustomObject]@{ Surface = $Surface; Entries = $filteredEntries; ParseStatus = $inner.ParseStatus }
    }

    if ($Surface -eq 'design-challenge') {
        $inner = Get-DesignChallengeSustainedCountInternal -Body $Body
        return [PSCustomObject]@{
            Surface               = $Surface
            SustainedCount        = $inner.SustainedCount
            DefenseSustainedCount = $inner.DefenseSustainedCount
            ParseStatus           = $inner.ParseStatus
        }
    }

    # plan-stress-test
    $inner = Get-JudgeRulingsSustainedCountInternal -Body $Body
    return [PSCustomObject]@{
        Surface               = $Surface
        SustainedCount        = $inner.SustainedCount
        DefenseSustainedCount = $inner.DefenseSustainedCount
        ParseStatus           = $inner.ParseStatus
    }
}

#endregion

#region Get-ReviewDispositionsTallyInternal (private)

function script:Get-ReviewDispositionsTallyInternal {
    <#
    .SYNOPSIS
        Per-entry segmented parser for the `<!-- review-dispositions-{PR} -->`
        marker (issue #768 s3). Private to Get-DispositionTally's code-review
        branch.
    .DESCRIPTION
        Head detection is vocab-gated (same convention as
        Get-RealJudgeRulingsHeadMatches above): the literal
        `<!-- review-dispositions-{N} -->` head substring alone is not
        sufficient — a bounded lookahead window after it must also contain
        real field vocabulary (`entries:`/`schema_version:`/
        `stable_finding_key:`), so a maintainer's prose sentence merely
        describing the marker convention is not mistaken for a real block.

        The marker's YAML payload lives inside a fenced ```yaml ... ``` code
        block immediately following the head (writer contract:
        skills/review-judgment/SKILL.md). Once that fenced region is
        isolated, entries are segmented on `- stable_finding_key:` /
        `- finding_id:` dash-item boundaries — never on any other key — so an
        injected-newline field value that happens to contain a bare-looking
        key line on its own line cannot be mistaken for a new entry.

        Within each entry's own bounds, `disposition:` and `reviewer_source:`
        are read via the FIRST key-anchored match only (same $keyAnchor
        convention as the judge-rulings/finding_dispositions detectors — real
        line-start, dash-item, or flow-mapping key position). Taking only the
        first match closes the decoy vector where a later
        `disposition_rationale` block-scalar value, or an injected-newline
        `reviewer_source` value, happens to contain a second `disposition:`-
        or `reviewer_source:`-shaped line further down the SAME entry: the
        real field is always written before those free-text fields per the
        schema/writer field order, so it always wins the first-match race.
        `reviewer_source` is matched on its own distinct key name, so it can
        never be confused with the unrelated nested `ac_cross_check.source`
        field (different literal key, not merely different position).

        Hand-rolled line-regex only — no ConvertFrom-Yaml / powershell-yaml
        (file-level SECURITY invariant at the top of this file).

        Fail-loud (DD3): no recognizable marker head, an unparseable/unclosed
        fenced region, zero segmentable entries, or an entry whose
        `disposition:` value is missing/unrecognized all return
        ParseStatus 'could-not-verify', never a silently empty/zero result.
    .PARAMETER Body
        The raw comment body text to scan.
    .OUTPUTS
        [PSCustomObject] with:
          Entries     [PSCustomObject[]] — one per entry (before the stage
                      filter Get-DispositionTally applies), each with
                      StableFindingKey, Disposition, Stage, ReviewerSource
          ParseStatus [string] — 'ok' or 'could-not-verify'
    #>
    param(
        [Parameter(Mandatory)][string]$Body
    )

    # Same key-anchor convention as Get-JudgeRulingsSustainedCountInternal's
    # and Get-DesignChallengeSustainedCountInternal's $keyAnchor (a real YAML
    # key position: true line-start, a `- ` dash-space list-item prefix, or
    # flow-mapping `{`/`,` position) — a fifth literal copy, tracked by the
    # 'Key-anchor pattern' drift-guard meta-test in this file's Tests.
    $keyAnchor = '(?:^\s*(?:-\s+)?|[{,]\s*)'

    $headPattern = '<!--\s*review-dispositions-\d+\s*-->'
    $headCandidates = [regex]::Matches($Body, $headPattern)
    if ($headCandidates.Count -eq 0) {
        return [PSCustomObject]@{ Entries = @(); ParseStatus = 'could-not-verify' }
    }

    $lookaheadWindow = 400
    $realHead = $null
    foreach ($candidate in $headCandidates) {
        $windowEnd = [Math]::Min($Body.Length, $candidate.Index + $candidate.Length + $lookaheadWindow)
        $window = $Body.Substring($candidate.Index, $windowEnd - $candidate.Index)
        if ([regex]::IsMatch($window, '(?m)^\s*(entries|schema_version|stable_finding_key)\s*:')) {
            $realHead = $candidate
            break
        }
    }
    if ($null -eq $realHead) {
        return [PSCustomObject]@{ Entries = @(); ParseStatus = 'could-not-verify' }
    }

    $searchFrom = $realHead.Index + $realHead.Length
    $openFenceIdx = $Body.IndexOf('```', $searchFrom, [System.StringComparison]::Ordinal)
    if ($openFenceIdx -lt 0) {
        return [PSCustomObject]@{ Entries = @(); ParseStatus = 'could-not-verify' }
    }
    $fenceLineEnd = $Body.IndexOf("`n", $openFenceIdx, [System.StringComparison]::Ordinal)
    if ($fenceLineEnd -lt 0) {
        return [PSCustomObject]@{ Entries = @(); ParseStatus = 'could-not-verify' }
    }
    $contentStart = $fenceLineEnd + 1
    $closeFenceIdx = $Body.IndexOf('```', $contentStart, [System.StringComparison]::Ordinal)
    if ($closeFenceIdx -lt 0) {
        return [PSCustomObject]@{ Entries = @(); ParseStatus = 'could-not-verify' }
    }
    $region = $Body.Substring($contentStart, $closeFenceIdx - $contentStart)

    # Per-entry segmentation: split ONLY on real `- stable_finding_key:` /
    # `- finding_id:` dash-item starts (entry-boundary markers) — never on
    # any other key, so an injected-newline field value cannot be mistaken
    # for a new entry.
    $entryBoundaryPattern = '(?m)^\s*-\s+(?:stable_finding_key|finding_id)\s*:'
    $entryStarts = [regex]::Matches($region, $entryBoundaryPattern)
    if ($entryStarts.Count -eq 0) {
        return [PSCustomObject]@{ Entries = @(); ParseStatus = 'could-not-verify' }
    }

    $entries = [System.Collections.Generic.List[PSCustomObject]]::new()
    for ($i = 0; $i -lt $entryStarts.Count; $i++) {
        $spanStart = $entryStarts[$i].Index
        $spanEnd = if ($i + 1 -lt $entryStarts.Count) { $entryStarts[$i + 1].Index } else { $region.Length }
        $entrySpan = $region.Substring($spanStart, $spanEnd - $spanStart)

        $stableKeyMatch = [regex]::Match($entrySpan, "(?m)${keyAnchor}stable_finding_key\s*:\s*(.+)")
        $stableFindingKey = if ($stableKeyMatch.Success) { $stableKeyMatch.Groups[1].Value.Trim().Trim('"') } else { $null }

        # First key-anchored match only (see .DESCRIPTION): the real
        # `disposition:` key is always written before disposition_rationale
        # per the schema/writer field order, so a block-scalar decoy quoting
        # a second "disposition: dismiss" later in the same entry can never
        # win this match.
        $dispositionMatch = [regex]::Match($entrySpan, "(?m)${keyAnchor}disposition\s*:\s*(incorporate|dismiss|escalate|defer)\b")
        if (-not $dispositionMatch.Success) {
            return [PSCustomObject]@{ Entries = @(); ParseStatus = 'could-not-verify' }
        }
        $disposition = $dispositionMatch.Groups[1].Value

        $stageMatch = [regex]::Match($entrySpan, "(?m)${keyAnchor}stage\s*:\s*(\S+)")
        # v1/v2 entries predate or omit the stage field; default to
        # 'code-review' (issue #768 s3, AC7).
        $stage = if ($stageMatch.Success) { $stageMatch.Groups[1].Value.TrimEnd(',') } else { 'code-review' }

        # reviewer_source is matched on its own distinct literal key name, so
        # it can never be confused with the nested ac_cross_check.source
        # field (a different key entirely, not merely a position collision).
        $reviewerSourceMatch = [regex]::Match($entrySpan, "(?m)${keyAnchor}reviewer_source\s*:\s*(.+)")
        $reviewerSource = if ($reviewerSourceMatch.Success) { $reviewerSourceMatch.Groups[1].Value.Trim().Trim('"') } else { $null }

        $entries.Add([PSCustomObject]@{
                StableFindingKey = $stableFindingKey
                Disposition      = $disposition
                Stage            = $stage
                ReviewerSource   = $reviewerSource
            })
    }

    return [PSCustomObject]@{ Entries = $entries.ToArray(); ParseStatus = 'ok' }
}

#endregion

#region Get-JudgeRulingsSustainedCountInternal (private)

function script:Get-JudgeRulingsSustainedCountInternal {
    param(
        [Parameter(Mandatory)][string]$Body
    )

    # 811-D1 owner decision (M1): fail loud when two or more judge-rulings
    # heads exist in one body, rather than silently picking one (latest-wins
    # was explicitly considered and rejected during plan stress-test — the
    # writer's replace-own-block already guarantees a single head on the
    # normal persist path, so a duplicate here signals a genuine anomaly
    # (e.g. a double-run backfill) that should be surfaced, not quietly
    # resolved). Count ALL head occurrences with the single general pattern
    # below: the attributed form `<!-- judge-rulings pr=N -->` is itself
    # matched by this same general pattern (its `pr=N` prefix satisfies the
    # `\s` alternative), so counting matches of the general pattern alone
    # gives the true head count without double-counting the same head under
    # both the attributed-specific and bare-general patterns.
    #
    # M1 fix (issue #811 post-fix adversarial pass): a raw head-pattern match
    # alone is not sufficient here, same as it is not sufficient for
    # Test-EmissionMarkerPresent's own head detection above. A prose sentence
    # that merely MENTIONS the marker convention (e.g. "this PR uses the
    # standard <!-- judge-rulings pr=778 --> marker for tracking") has no
    # real field vocabulary following it, yet still counted toward this
    # duplicate threshold when it co-occurred with one genuinely real block —
    # a false could-not-verify. Each candidate head is now vocab-gated via
    # Get-RealJudgeRulingsHeadMatches (the same scan-all-candidates helper
    # Test-EmissionMarkerPresent uses); only heads that pass this gate count
    # as "a real head" toward the 2+ duplicate threshold. Two genuinely real
    # blocks still correctly fail loud; a bare prose mention no longer does.
    $realHeadMatches = Get-RealJudgeRulingsHeadMatches -Body $Body
    if ($realHeadMatches.Count -ge 2) {
        return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    # GH-3 fix (PR #815 review): region-isolation used to re-run its OWN
    # standalone first-match `[regex]::Match` calls here, independent of the
    # M1 guard's vocab-gated scan above. That let a vocab-gate-FAILING decoy
    # head positioned before a real, vocab-gate-PASSING block win the
    # first-match race, isolate an empty/prose-only region at the decoy's
    # position, and return could-not-verify — even though the real block,
    # unexamined, would have parsed cleanly. Select the head to isolate from
    # $realHeadMatches (the SAME vocab-gated set the M1 guard just computed)
    # instead of a fresh raw scan, while still preferring the attributed form
    # `<!-- judge-rulings pr=N -->` over a bare form when BOTH are present
    # among the real (vocab-gate-passing) candidates — attributed-vs-bare
    # preference is now applied only among real heads, never used to
    # resurrect a vocab-gate-failing raw match.
    # NOTE: $script:JudgeRulingsHeadPattern's own match value stops at the
    # first whitespace/`-->`/end-of-string after "judge-rulings" (e.g. just
    # `<!-- judge-rulings ` for the attributed form), so it never spans
    # through the closing `-->` of an attributed head. Anchor the attributed
    # pattern (`\G` = "must match starting exactly here") at each
    # candidate's own start position within the full body, so a
    # vocab-gate-passing candidate that IS attributed is correctly detected
    # without resurrecting a match at some unrelated, possibly-earlier
    # occurrence of the same literal text elsewhere in a pathological body.
    # $regionIndex/$regionHeadLength (not a swapped-in Match object) are what
    # $regionStart below actually needs — the attributed match's full length
    # when a candidate is attributed, else the candidate's own head-pattern
    # length for a bare head.
    $attributedPattern = '\G<!--\s*judge-rulings\s+pr=\d+\s*-->'
    $regionIndex = -1
    $regionHeadLength = 0
    foreach ($candidate in $realHeadMatches) {
        $attributedAtCandidate = [regex]::Match($Body.Substring($candidate.Index), $attributedPattern)
        if ($attributedAtCandidate.Success) {
            $regionIndex = $candidate.Index
            $regionHeadLength = $attributedAtCandidate.Length
            break
        }
    }
    if ($regionIndex -lt 0 -and $realHeadMatches.Count -gt 0) {
        $regionIndex = $realHeadMatches[0].Index
        $regionHeadLength = $realHeadMatches[0].Length
    }

    if ($regionIndex -lt 0) {
        return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    $regionStart = $regionIndex + $regionHeadLength
    # The YAML region ends at the next `-->` (closing the HTML comment) or, for
    # the fenced-code-block variant (PR #778), at the closing ``` fence.
    $closeCommentIdx = $Body.IndexOf('-->', $regionStart, [System.StringComparison]::Ordinal)
    $closeFenceIdx = $Body.IndexOf('```', $regionStart, [System.StringComparison]::Ordinal)

    $regionEnd = -1
    if ($closeCommentIdx -ge 0 -and $closeFenceIdx -ge 0) {
        $regionEnd = [Math]::Min($closeCommentIdx, $closeFenceIdx)
    }
    elseif ($closeCommentIdx -ge 0) {
        $regionEnd = $closeCommentIdx
    }
    elseif ($closeFenceIdx -ge 0) {
        $regionEnd = $closeFenceIdx
    }

    if ($regionEnd -lt 0) {
        # Unclosed marker region — cannot safely isolate content.
        return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    # M8 fix (issue #782 post-review): region-end detection previously
    # trusted the FIRST '-->' or code-fence found after the head
    # unconditionally. A stray closer-like sequence inside ordinary prose
    # BEFORE the real closing marker (e.g. a sentence describing the
    # phase-flow notation "introduced --> catchable --> caught", which
    # contains the literal 3-char substring '-->' twice) truncated the
    # region early, silently dropping real disposition/judge_ruling lines
    # that appeared after those stray sequences — a silent under-count with
    # ParseStatus 'ok', exactly the failure mode DD3 exists to prevent.
    # Detect the ambiguity instead of guessing: walk forward through
    # consecutive candidate closers (bounded lookahead), and if recognizable
    # disposition/judge_ruling vocabulary is found strictly BETWEEN the
    # chosen close point and the NEXT candidate closer, the chosen boundary
    # was very likely a false positive (prose containing a stray closer-like
    # sequence, not the real marker boundary) — fail loud. Content found only
    # AFTER a run of closely-spaced candidate closers (e.g. a downstream,
    # unrelated phase-containment block that legitimately follows the real
    # close) does not trigger this: the scan stops walking once a gap
    # between consecutive candidates is large enough to look like ordinary
    # post-marker content rather than another stray in-region sequence.
    $ambiguityLookahead = 400
    $maxGapBetweenCandidates = 120
    $walkPos = $regionEnd + 3
    $walkBudgetEnd = [Math]::Min($Body.Length, $regionEnd + 3 + $ambiguityLookahead)
    while ($walkPos -lt $walkBudgetEnd) {
        $nextCloseCommentIdx = $Body.IndexOf('-->', $walkPos, [System.StringComparison]::Ordinal)
        $nextCloseFenceIdx = $Body.IndexOf('```', $walkPos, [System.StringComparison]::Ordinal)
        $nextCandidateCloser = -1
        if ($nextCloseCommentIdx -ge 0 -and $nextCloseFenceIdx -ge 0) {
            $nextCandidateCloser = [Math]::Min($nextCloseCommentIdx, $nextCloseFenceIdx)
        }
        elseif ($nextCloseCommentIdx -ge 0) {
            $nextCandidateCloser = $nextCloseCommentIdx
        }
        elseif ($nextCloseFenceIdx -ge 0) {
            $nextCandidateCloser = $nextCloseFenceIdx
        }
        if ($nextCandidateCloser -lt 0 -or $nextCandidateCloser - $walkPos -gt $maxGapBetweenCandidates) {
            break
        }
        $between = $Body.Substring($walkPos, $nextCandidateCloser - $walkPos)
        # PF-F2 fix: same dash-space list-item anchor extension as
        # Test-EmissionMarkerPresent's vocab window and $keyAnchor below —
        # this ambiguity-detector copy must stay in sync with both.
        if ([regex]::IsMatch($between, '(?m)(?:^\s*(?:-\s+)?|[{,]\s*)(disposition|judge_ruling|verdict|finding_key)\s*:')) {
            return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $walkPos = $nextCandidateCloser + 3
    }

    $region = $Body.Substring($regionStart, $regionEnd - $regionStart)

    # required_fixes: is a parallel decoy list present in the intake variant
    # (PR #775). Strip it (and everything after it) before scanning, so its
    # `id:`/nested keys can never be miscounted as findings.
    $requiredFixesMatch = [regex]::Match($region, '(?m)^required_fixes\s*:\s*$')
    if ($requiredFixesMatch.Success) {
        $region = $region.Substring(0, $requiredFixesMatch.Index)
    }

    # Detect vocabulary in priority order: four-value variant > intake variant > canonical.
    # M3 fix: anchor `disposition:` to a real YAML key position, not just
    # (?m) multiline mode alone. (?m) only anchors ^/$ to line boundaries; it
    # does NOT require the match to start there, so "disposition: Dismiss"
    # embedded mid-line inside free-text prose (e.g. a summary: string
    # quoting another finding's disposition) previously still matched and
    # could silently hijack detection into the wrong variant branch,
    # producing SustainedCount=0 despite real sustained findings (DD3
    # fail-loud violation). A real disposition key position is either at
    # true line-start (block-mapping style, e.g. PR #775) or immediately
    # after `{` / `,` (flow-mapping style, e.g. live PR #778's
    # `U1: {disposition: Fix-now, ...}` shape) — prose mentions inside a
    # summary/description string value are preceded by ordinary sentence
    # characters and are excluded by this anchor.
    # PF-F2 fix (issue #782 post-fix defense pass): also anchor after a
    # `- ` dash-space list-item prefix, so a YAML block-sequence item like
    # `- disposition: Fix-now` is recognized as a real key position. Without
    # this, dash-space-first findings were excluded from the disposition
    # counts here AND (via the identical literal in Test-EmissionMarkerPresent
    # and the ambiguity-walk detector above) from the vocab gate that decides
    # whether this function is even called — producing a silent Gap=0/ok
    # false-clean when a body's only field tokens are dash-space items. All
    # four copies of this pattern must be kept in sync (the fourth copy,
    # added by the later GH-5 fix, lives in
    # Get-DesignChallengeSustainedCountInternal below). A drift-catching
    # meta-test (Tests/phase-containment-emission-check-core.Tests.ps1)
    # asserts all four literal copies stay byte-identical.
    $keyAnchor = '(?:^\s*(?:-\s+)?|[{,]\s*)'
    $hasDismiss = $region -match "(?m)${keyAnchor}disposition\s*:\s*Dismiss\b"
    $hasFixNow = $region -match "(?m)${keyAnchor}disposition\s*:\s*(Fix-now|Fix-in-PR|Defer)\b"
    $hasReviewModeIntake = $region -match "review_mode\s*:\s*['""]?github-intake-proxy-prosecution"
    $hasAcceptReject = $region -match "(?m)${keyAnchor}disposition\s*:\s*(accept|reject)\b"
    $hasJudgeRuling = $region -match '(?m)judge_ruling\s*:\s*\S'

    if ($hasDismiss -or $hasFixNow) {
        # Four-value variant: sustained = every finding whose disposition is not Dismiss.
        $dispositionMatches = [regex]::Matches($region, "(?m)${keyAnchor}disposition\s*:\s*(Fix-now|Fix-in-PR|Defer|Dismiss)\b")
        if ($dispositionMatches.Count -eq 0) {
            return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $sustained = @($dispositionMatches | Where-Object { $_.Groups[1].Value -ne 'Dismiss' })
        # Additive (issue #768 s3, AC8): the four-value vocabulary
        # (Fix-now|Fix-in-PR|Defer|Dismiss) has no defense-sustained concept
        # at all — DefenseSustainedCount is always 0 here. Get-SustainedFindingCount
        # re-projects this away so its public output stays byte-identical.
        return [PSCustomObject]@{ SustainedCount = $sustained.Count; DefenseSustainedCount = 0; ParseStatus = 'ok' }
    }

    if ($hasReviewModeIntake -or $hasAcceptReject) {
        # Intake-mode variant: sustained iff disposition: accept, counted only
        # inside the findings: list (region already excludes required_fixes:).
        $findingsMatch = [regex]::Match($region, '(?ms)^findings\s*:\s*$(.*)')
        if (-not $findingsMatch.Success) {
            return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $findingsRegion = $findingsMatch.Groups[1].Value
        $dispositionMatches = [regex]::Matches($findingsRegion, "(?m)${keyAnchor}disposition\s*:\s*(accept|reject)\b")
        if ($dispositionMatches.Count -eq 0) {
            return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $sustained = @($dispositionMatches | Where-Object { $_.Groups[1].Value -eq 'accept' })
        # Additive (issue #768 s3, AC8): the intake accept/reject vocabulary
        # has no defense-sustained concept — DefenseSustainedCount is always
        # 0 here.
        return [PSCustomObject]@{ SustainedCount = $sustained.Count; DefenseSustainedCount = 0; ParseStatus = 'ok' }
    }

    if ($hasJudgeRuling) {
        # Canonical judge-rulings variant: sustained iff judge_ruling: sustained
        # (NOT defense-sustained). judge_ruling is a closed 2-value enum per
        # skills/review-judgment/SKILL.md:156 ('sustained' or 'defense-sustained');
        # any other value is unrecognized vocabulary -> could-not-verify (DD3),
        # never silently treated as "not sustained".
        $rulingMatches = [regex]::Matches($region, '(?m)judge_ruling\s*:\s*(\S+)')
        $unrecognized = @($rulingMatches | Where-Object {
                $val = $_.Groups[1].Value.TrimEnd(',')
                $val -ne 'sustained' -and $val -ne 'defense-sustained'
            })
        if ($unrecognized.Count -gt 0) {
            return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $sustained = @($rulingMatches | Where-Object { $_.Groups[1].Value.TrimEnd(',') -eq 'sustained' })
        # Additive (issue #768 s3, AC8): DefenseSustainedCount exposes the
        # judge_ruling: defense-sustained count alongside SustainedCount, for
        # Get-DispositionTally's judge-rulings-surface consumers (design-
        # challenge, plan-stress-test). Purely additive —
        # Get-SustainedFindingCount re-projects this away so its public
        # {SustainedCount; ParseStatus} shape stays byte-identical.
        $defenseSustained = @($rulingMatches | Where-Object { $_.Groups[1].Value.TrimEnd(',') -eq 'defense-sustained' })
        return [PSCustomObject]@{ SustainedCount = $sustained.Count; DefenseSustainedCount = $defenseSustained.Count; ParseStatus = 'ok' }
    }

    # Marker present but vocabulary unrecognized.
    return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
}

#endregion

#region Get-DesignChallengeSustainedCountInternal (private)

function script:Get-DesignChallengeSustainedCountInternal {
    param(
        [Parameter(Mandatory)][string]$Body
    )

    $headMatch = [regex]::Match($Body, '(?m)^finding_dispositions\s*:\s*$')
    if (-not $headMatch.Success) {
        return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    $regionStart = $headMatch.Index + $headMatch.Length
    $closeFenceIdx = $Body.IndexOf('```', $regionStart, [System.StringComparison]::Ordinal)
    $region = if ($closeFenceIdx -ge 0) {
        $Body.Substring($regionStart, $closeFenceIdx - $regionStart)
    }
    else {
        $Body.Substring($regionStart)
    }

    # GH-5 fix (issue #782 GitHub-review response loop, PR #789): anchor
    # `disposition:` to a real YAML key position, matching the code-review
    # surface's $keyAnchor pattern (line-start, dash-space list item, or
    # flow-mapping `{`/`,` position). Without this anchor, a free-text
    # disposition_rationale string quoting the substring "disposition:
    # incorporate" for an unrelated finding is miscounted as a real entry,
    # exactly the DD3 fail-loud violation the M3/PF-F2 fixes closed for the
    # code-review surface's equivalent detectors.
    $keyAnchor = '(?:^\s*(?:-\s+)?|[{,]\s*)'
    $dispositionMatches = [regex]::Matches($region, "(?m)${keyAnchor}disposition\s*:\s*(incorporate|escalate|dismiss)\b")
    if ($dispositionMatches.Count -eq 0) {
        return [PSCustomObject]@{ SustainedCount = 0; DefenseSustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    $sustained = @($dispositionMatches | Where-Object { $_.Groups[1].Value -ne 'dismiss' })
    # Additive (issue #768 s3, AC8): design-challenge's `finding_dispositions:`
    # marker has no defense-sustained vocabulary at all — its `disposition`
    # enum is incorporate|dismiss|escalate, with no separate defense pass
    # concept. DefenseSustainedCount is always 0 here; carried purely for
    # Get-DispositionTally's uniform (SustainedCount, DefenseSustainedCount)
    # return shape across its judge-rulings-style surfaces.
    return [PSCustomObject]@{ SustainedCount = $sustained.Count; DefenseSustainedCount = 0; ParseStatus = 'ok' }
}

#endregion

#region Get-EmissionGap

function Get-EmissionGap {
    <#
    .SYNOPSIS
        Computes the emission gap between sustained findings and posted
        phase-containment ledger blocks across a set of comment bodies.
    .DESCRIPTION
        Sums Get-SustainedFindingCount across all supplied bodies for the
        surface, sums the block count via the reused Get-PhaseContainmentBlock,
        and returns Gap = SustainedCount - BlockCount (floored at 0 is NOT
        applied — a negative gap, meaning more blocks than sustained findings,
        is preserved as signal rather than clamped, since callers treat any
        ParseStatus other than 'ok' as an unconditional gap regardless of the
        arithmetic result).

        Real PRs/issues have several comments; only one is expected to be the
        authoritative judge-rulings surface (M17 scope note) — the rest are
        ordinary chatter (bot notices, "LGTM", unrelated replies) that were
        never meant to carry a marker at all. Per body, Test-EmissionMarkerPresent
        gates whether Get-SustainedFindingCount is even called:
          - No marker head present -> the body is skipped entirely: it
            contributes 0 to SustainedCount and does NOT set could-not-verify.
            This is the issue #782 live-validation correction — marker-less
            chatter must not poison the whole-PR aggregate.
          - Marker head present -> Get-SustainedFindingCount parses it, and
            DD3's fail-loud invariant still applies in full: unparseable,
            ambiguous, or unknown-vocabulary content under a real marker head
            remains could-not-verify, never silently zero.

        If ANY body with a marker head present is could-not-verify, the
        aggregate ParseStatus is 'could-not-verify' and callers MUST treat the
        result as a gap, never as clean — even if the arithmetic Gap happens
        to compute to 0 or negative from the parseable bodies alone.
    .PARAMETER Bodies
        Array of raw comment body text (e.g. all comments on the target PR/issue).
    .PARAMETER Id
        PR number (code-review) or issue number (design-challenge, plan-stress-test).
    .PARAMETER Surface
        One of: code-review, design-challenge, plan-stress-test
    .OUTPUTS
        [PSCustomObject] with:
          SustainedCount [int]
          BlockCount     [int]
          Gap            [int]
          ParseStatus    [string] — 'ok' or 'could-not-verify'
          Reason         [string] — 'ok', 'head-missing', or 'head-corrupt'
                          (811-D1, plan-stress-test-relevant detail consumed
                          by the s2 wrapper render; see below)
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Bodies,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][ValidateSet('code-review', 'design-challenge', 'plan-stress-test')][string]$Surface
    )

    $totalSustained = 0
    $totalBlocks = 0
    $anyCouldNotVerify = $false
    # 811-D1 (M5): distinguishes WHY the aggregate went could-not-verify, for
    # s2's differentiated render. 'head-missing' means the 811 plan-stress-test
    # fallback fired for at least one body (a real machine judge-rulings head
    # was never present — the honest fallback is the only reason
    # Test-EmissionMarkerPresent returned true). 'head-corrupt' means a real
    # judge-rulings head WAS present somewhere but its content failed to parse
    # (DD3 fail-loud). head-corrupt takes priority when both occur across
    # different bodies in the same aggregation, since "a machine head exists
    # but is broken" is the more actionable/specific diagnosis.
    $sawFallbackFired = $false
    $sawRealHeadCorrupt = $false

    foreach ($body in $Bodies) {
        $bodyHasMarker = Test-EmissionMarkerPresent -Surface $Surface -Body $body

        if ($bodyHasMarker) {
            # 811-D1: determine whether this body's marker presence came from
            # a REAL judge-rulings/finding_dispositions head, or only from the
            # plan-stress-test honest fallback (no real head at all).
            #
            # GH-1 fix (PR #815 review, rider on GH-3): the non-design-challenge
            # branch used to be a bare, ungated [regex]::IsMatch against
            # $script:JudgeRulingsHeadPattern, so a vocab-gate-FAILING decoy
            # head alone could make this report $true, mislabeling the
            # could-not-verify Reason as 'head-corrupt' ("a real head exists
            # but its content failed to parse") when the accurate diagnosis is
            # "the parser was misled by a decoy, not by real-head corruption."
            # The prior comment claiming this "can never drift from what
            # Get-SustainedFindingCount considers a real head" was false for
            # exactly that reason — an ungated check can disagree with the
            # vocab-gated selection Get-SustainedFindingCount actually uses.
            # Now reuses Get-RealJudgeRulingsHeadMatches, the SAME vocab-gated
            # scan Test-EmissionMarkerPresent and
            # Get-JudgeRulingsSustainedCountInternal both use, so this
            # classification is now actually unable to drift from what a real
            # head means elsewhere in this file.
            $hasRealHead = if ($Surface -eq 'design-challenge') {
                [regex]::IsMatch($body, '(?m)^finding_dispositions\s*:\s*$')
            }
            else {
                (Get-RealJudgeRulingsHeadMatches -Body $body).Count -gt 0
            }

            $sustainedResult = Get-SustainedFindingCount -Surface $Surface -Body $body
            if ($sustainedResult.ParseStatus -eq 'could-not-verify') {
                $anyCouldNotVerify = $true
                if ($hasRealHead) {
                    $sawRealHeadCorrupt = $true
                }
                else {
                    $sawFallbackFired = $true
                }
            }
            $totalSustained += $sustainedResult.SustainedCount
        }
        # else: no recognizable marker head in this body — ordinary PR/issue
        # chatter, not a judge-rulings surface. Skip it (0 contribution,
        # does not poison ParseStatus). See Get-EmissionGap's .DESCRIPTION.

        # Fix A (issue #782 judge-required fixes, closes M1/M2/M4/M5):
        # a block only counts toward this surface's BlockCount when ALL of:
        #   1. Its body ALSO carries this surface's own authoritative marker
        #      head (M4) — closes the pure-chatter-with-injected-blocks
        #      vector (e.g. a scaffold-report re-sweep, M2).
        #   2. The individual block's finding_key is prefixed for THIS
        #      surface specifically (M1) — body-level marker co-location
        #      alone is not sufficient, since design-challenge and
        #      plan-stress-test marker heads can legitimately co-occur in
        #      the SAME issue body, and each block must be attributed to its
        #      own surface via its finding_key prefix
        #      ("design-challenge:...", "plan-stress-test:...",
        #      "code-review:...").
        #   3. The block passes Test-PhaseContainmentEntry schema validation
        #      (M2/M5) — TODO-human scaffolds (escape_distance: -1) and
        #      other invalid entries can never silently count as satisfied.
        if ($bodyHasMarker) {
            $rawBlocks = Get-PhaseContainmentBlock -Text $body -Id $Id
            if ($rawBlocks) {
                $surfacePrefix = "${Surface}:"
                foreach ($rawBlock in $rawBlocks) {
                    $parsedEntry = ConvertFrom-PhaseContainmentYaml -Yaml $rawBlock
                    $findingKey = [string]$parsedEntry['finding_key']
                    if (-not $findingKey.StartsWith($surfacePrefix, [System.StringComparison]::Ordinal)) {
                        continue
                    }
                    $validation = Test-PhaseContainmentEntry -Entry $parsedEntry
                    if (-not $validation.IsValid) {
                        continue
                    }
                    $totalBlocks++
                }
            }
        }
        # else: body carries no marker head for this surface — its blocks
        # (if any) do not count either. A bare phase-containment block with
        # no accompanying authoritative marker on the same body is exactly
        # the pure-chatter-with-injected-blocks vector M4 closes.
    }

    $parseStatus = if ($anyCouldNotVerify) { 'could-not-verify' } else { 'ok' }
    $gap = $totalSustained - $totalBlocks

    # 811-D1 (M5): head-corrupt takes priority over head-missing when both
    # occurred across different bodies (see field notes above); 'ok' when
    # ParseStatus is 'ok' (no could-not-verify body at all).
    $reason = if (-not $anyCouldNotVerify) {
        'ok'
    }
    elseif ($sawRealHeadCorrupt) {
        'head-corrupt'
    }
    elseif ($sawFallbackFired) {
        'head-missing'
    }
    else {
        # M8 fix (issue #811 post-fix adversarial pass): this branch is
        # defensive and, as of the current code path, unreachable in
        # practice. $anyCouldNotVerify is only ever set to $true at the one
        # site above (inside `if ($bodyHasMarker)`, immediately after
        # Get-SustainedFindingCount returns 'could-not-verify'), and that
        # same site always also sets exactly one of $sawRealHeadCorrupt /
        # $sawFallbackFired based on $hasRealHead — so by the time this
        # `else` is reached, at least one of the two preceding `elseif`
        # branches has already matched. (The previously cited "empty-body
        # AllowEmptyString could-not-verify" example cannot occur here:
        # Test-EmissionMarkerPresent returns $false for whitespace/empty
        # bodies, so $bodyHasMarker gates such a body out of this loop
        # entirely before Get-SustainedFindingCount is ever called.) This
        # `else` remains as a safety net against a future code change that
        # sets $anyCouldNotVerify from a new call site without also setting
        # one of the two flags; it falls back to the generic 'head-corrupt'
        # label rather than guessing a plan-stress-test-specific reason.
        'head-corrupt'
    }

    return [PSCustomObject]@{
        SustainedCount = $totalSustained
        BlockCount     = $totalBlocks
        Gap            = $gap
        ParseStatus    = $parseStatus
        Reason         = $reason
    }
}

#endregion

#region Add-CommentBlocks

function Add-CommentBlocks {
    <#
    .SYNOPSIS
        Appends new content to an existing GitHub comment via read-modify-write,
        never via Find-OrUpsertComment (whose PATCH path replaces the body
        verbatim and would destroy the preserved judge-rulings YAML).
    .DESCRIPTION
        Sequence (s4 backfill append primitive, M4):
          1. gh api GET the comment body by REST comment id.
          2. Verify the expected marker is present in the fetched body.
          3. Concatenate NewContent after the existing body.
          4. gh api PATCH the full combined body.
          5. Post-write verify: GET again and apply positive-proof
             verification (see below) instead of an exact-ordinal
             byte-prefix comparison.

        Any mismatch at any step is fail-loud: the function returns
        Success=$false with a Reason describing the failure, and performs no
        further action. This function never truncates or overwrites existing
        comment content.

        Why not an exact byte-prefix comparison (live-validation correction,
        #782 backfill against PRs #775/#778/#781): GitHub's API benignly
        normalizes some whitespace on write/read (observed: trailing
        whitespace and blank-line-run collapsing) that does not affect
        content integrity but breaks `$verifyBody.StartsWith($originalBody)`
        under ordinal comparison. That produced false negatives on every
        real-world write, training callers to ignore the fail-loud signal —
        exactly the failure mode this module exists to prevent. Rather than
        weaken the check into a normalized-whitespace prefix comparison
        (which still only proves "roughly the same text showed up," not
        "the specific new blocks landed intact"), post-write verify now
        does positive proof of both halves:
          (a) the ExpectedMarker string is still present in the verify body
              (the original content survived), and
          (b) every `<!-- phase-containment-{ID} -->` block referenced in
              NewContent is present, parses via the shared
              Get-PhaseContainmentBlock parser, and its raw YAML content
              matches what NewContent intended to append (the new content
              landed correctly, not merely "something" landed).
        This is stricter about the content that matters (markers, block
        parseability, block content) and tolerant of formatting the API is
        free to normalize. Truncation, a dropped marker, or a corrupted/
        unparseable new block all still fail loud with a specific Reason.
    .PARAMETER Owner
        Repository owner (e.g. from the git remote).
    .PARAMETER Repo
        Repository name.
    .PARAMETER CommentId
        The numeric REST comment id (not the GraphQL node id).
    .PARAMETER ExpectedMarker
        A substring that MUST be present in the fetched body before appending
        (e.g. '<!-- judge-rulings' or 'finding_dispositions:'). Guards against
        appending to the wrong comment.
    .PARAMETER NewContent
        The new content to append after the existing body.
    .OUTPUTS
        [PSCustomObject] with:
          Success [bool]
          Reason  [string] — populated only when Success=$false
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [Parameter(Mandatory)][string]$NewContent
    )

    $getPath = "repos/$Owner/$Repo/issues/comments/$CommentId"

    # --- 1. GET the current comment body. ---
    $getOutput = & gh api $getPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Add-CommentBlocks: gh api GET $getPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "GET failed (exit $LASTEXITCODE)" }
    }

    try {
        $getObj = $getOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("Add-CommentBlocks: failed to parse GET response JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ Success = $false; Reason = "GET response is not valid JSON: $($_.Exception.Message)" }
    }

    $originalBody = [string]$getObj.body

    # --- 2. Verify the expected marker is present. ---
    if (-not $originalBody.Contains($ExpectedMarker)) {
        [Console]::Error.WriteLine("Add-CommentBlocks: expected marker '$ExpectedMarker' not found in comment $CommentId; refusing to append.")
        return [PSCustomObject]@{ Success = $false; Reason = "Expected marker '$ExpectedMarker' not found in comment body" }
    }

    # --- 2b. M10 fix: refuse the no-op case up front. ---
    # NewContent carrying zero <!-- phase-containment-{ID} --> blocks means
    # there is nothing for the post-write positive-proof loop to verify —
    # step 5c's foreach over $newBlockIds is vacuously satisfied with zero
    # iterations, so the function previously reported Success=$true for a
    # write that appended content the caller never intended to be
    # unverifiable filler (or masked a caller bug, e.g. a backfill scaffold
    # that failed to render any blocks). Detect this before ever issuing the
    # PATCH, so a no-op never masquerades as a successful append.
    $preflightBlockIds = [regex]::Matches($NewContent, '<!--\s*phase-containment-([A-Za-z0-9_-]+)\s*-->')
    if ($preflightBlockIds.Count -eq 0) {
        [Console]::Error.WriteLine("Add-CommentBlocks: NewContent carries zero phase-containment blocks for comment $CommentId; refusing as a no-op.")
        return [PSCustomObject]@{ Success = $false; Reason = 'no-op: NewContent carries zero phase-containment blocks' }
    }

    # --- 3. Concatenate. ---
    $combinedBody = $originalBody + $NewContent

    # --- 4. PATCH the full combined body. ---
    $patchPath = "repos/$Owner/$Repo/issues/comments/$CommentId"
    $patchTempFile = $null
    try {
        $patchTempFile = [System.IO.Path]::GetTempFileName()
        $patchPayload = @{ body = $combinedBody } | ConvertTo-Json -Depth 4 -Compress
        Set-Content -LiteralPath $patchTempFile -Value $patchPayload -Encoding UTF8 -NoNewline
        $null = & gh api -X PATCH $patchPath --input $patchTempFile 2>$null
    }
    finally {
        if ($null -ne $patchTempFile -and (Test-Path -LiteralPath $patchTempFile)) {
            Remove-Item -LiteralPath $patchTempFile -Force -ErrorAction SilentlyContinue
        }
    }
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Add-CommentBlocks: gh api PATCH $patchPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "PATCH failed (exit $LASTEXITCODE)" }
    }

    # --- 5. Post-write verify: GET again and apply positive-proof checks. ---
    $verifyOutput = & gh api $getPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Add-CommentBlocks: post-write verify GET $getPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify GET failed (exit $LASTEXITCODE)" }
    }

    try {
        $verifyObj = $verifyOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("Add-CommentBlocks: failed to parse post-write verify JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify response is not valid JSON: $($_.Exception.Message)" }
    }

    $verifyBody = [string]$verifyObj.body

    # --- 5a. Gross-truncation guard. ---
    # A body that shrank dramatically relative to what was just written is
    # corruption/data-loss regardless of what the positive-proof checks below
    # find; catch it early with a clear reason. Benign normalization trims a
    # handful of characters at most, never a large fraction of the body.
    $expectedMinLength = [int]($combinedBody.Length * 0.5)
    if ($verifyBody.Length -lt $expectedMinLength) {
        [Console]::Error.WriteLine("Add-CommentBlocks: post-write verify FAILED — verify body ($($verifyBody.Length) chars) is dramatically shorter than the written body ($($combinedBody.Length) chars) for comment $CommentId.")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: verify body ($($verifyBody.Length) chars) is dramatically shorter than expected ($($combinedBody.Length) chars written)" }
    }

    # --- 5b. Positive proof #1: original content survived. ---
    if (-not $verifyBody.Contains($ExpectedMarker)) {
        [Console]::Error.WriteLine("Add-CommentBlocks: post-write verify FAILED — expected marker '$ExpectedMarker' missing from verify body for comment $CommentId.")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: expected marker '$ExpectedMarker' missing from verify body" }
    }

    # --- 5c. Positive proof #2: every new phase-containment block landed
    #          intact. Extract the IDs Add-CommentBlocks was asked to append
    #          from NewContent itself, then confirm each one is present,
    #          parseable, and content-identical in the verify body — reusing
    #          the shared parser rather than re-implementing block matching.
    $newBlockIds = [System.Collections.Generic.List[string]]::new()
    $idMatches = [regex]::Matches($NewContent, '<!--\s*phase-containment-([A-Za-z0-9_-]+)\s*-->')
    foreach ($m in $idMatches) {
        $id = $m.Groups[1].Value
        if (-not $newBlockIds.Contains($id)) { $newBlockIds.Add($id) }
    }

    foreach ($id in $newBlockIds) {
        $expectedBlocks = Get-PhaseContainmentBlock -Text $NewContent -Id $id
        $verifyBlocks = Get-PhaseContainmentBlock -Text $verifyBody -Id $id

        if ($null -eq $verifyBlocks) {
            [Console]::Error.WriteLine("Add-CommentBlocks: post-write verify FAILED — phase-containment-$id block(s) from NewContent did not parse out of the verify body for comment $CommentId.")
            return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: phase-containment-$id block(s) missing or unparseable in verify body" }
        }

        $expectedCount = if ($null -eq $expectedBlocks) { 0 } else { $expectedBlocks.Count }
        if ($verifyBlocks.Count -lt $expectedCount) {
            [Console]::Error.WriteLine("Add-CommentBlocks: post-write verify FAILED — phase-containment-$id expected $expectedCount block(s), found $($verifyBlocks.Count) in verify body for comment $CommentId.")
            return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: phase-containment-$id expected $expectedCount block(s), found $($verifyBlocks.Count)" }
        }

        # Every expected block's raw content must appear among the verify
        # body's parsed blocks for this id (order-independent — a caller may
        # append multiple blocks per id and GitHub's normalization does not
        # guarantee ordinal stability of unrelated whitespace runs between
        # them, even though the content itself is intact). Ordinal
        # comparison here (not PowerShell's default case-insensitive
        # -contains) so a corrupted value that differs only in case still
        # fails loud.
        $verifyBlocksSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$verifyBlocks, [System.StringComparer]::Ordinal)
        foreach ($expected in $expectedBlocks) {
            if (-not $verifyBlocksSet.Contains($expected)) {
                [Console]::Error.WriteLine("Add-CommentBlocks: post-write verify FAILED — a phase-containment-$id block from NewContent does not match any parsed block in the verify body for comment $CommentId.")
                return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: a phase-containment-$id block's content does not match the verify body" }
            }
        }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

#endregion

#region Add-JudgeRulingsBlock

function Add-JudgeRulingsBlock {
    <#
    .SYNOPSIS
        Appends a new <!-- judge-rulings ... --> machine block to an existing
        GitHub comment via read-modify-write, with entry-level fail-loud
        positive-proof (811-D1 s3 — sibling to Add-CommentBlocks, M17).
    .DESCRIPTION
        Sequence — the SAME read-modify-write append core as Add-CommentBlocks
        (preflight -> GET -> verify expected marker present -> concatenate ->
        PATCH -> re-fetch and verify), but with its OWN entry-level
        verification tuned to the judge-rulings payload shape rather than
        phase-containment blocks:
          1. Preflight no-op guard (M8/D5), run FIRST and before any network
             call: NewContent must carry at least one `judge_ruling:` entry.
             A judge-rulings HEAD with zero entries is refused before any
             write is attempted, so an empty append can never defeat the
             zero-findings placeholder contract (which always carries at
             least one `- finding_id: none` / `judge_ruling: defense-sustained`
             entry).
          2. gh api GET the comment body by REST comment id.
          3. Verify the expected marker is present in the fetched body.
          4. Concatenate NewContent after the existing body.
          5. gh api PATCH the full combined body.
          6. Post-write verify: GET again and apply positive-proof
             verification — critically, ENTRY-LEVEL, not merely a check that
             the literal head string `<!-- judge-rulings` reappears. Every
             individual `judge_ruling:` line present in NewContent must also
             be present, in matching multiplicity, in the re-fetched body.
             A truncated append (e.g. head + 3 of 11 entries landing) fails
             this count comparison and is reported as failure — the same
             failure mode Add-CommentBlocks' phase-containment loop guards
             against, adapted to a payload shape that has no per-entry ID
             marker pair to parse structurally.

        Any mismatch at any step is fail-loud: the function returns
        Success=$false with a Reason describing the failure, and performs no
        further action. This function never truncates or overwrites existing
        comment content.

        Hand-rolled regex only (file-level SECURITY note at the top of this
        file applies here too — no ConvertFrom-Yaml / powershell-yaml).

        This function is independent of Add-CommentBlocks: it does not call
        it, and Add-CommentBlocks is not modified by this addition. The two
        functions intentionally duplicate the outer GET/PATCH/verify shell
        rather than share a risky extracted helper, per the 811 plan's
        owner decision (M17) to protect Add-CommentBlocks' ~15 existing
        callers and its already-hardened preflight/positive-proof path.
    .PARAMETER Owner
        Repository owner (e.g. from the git remote).
    .PARAMETER Repo
        Repository name.
    .PARAMETER CommentId
        The numeric REST comment id (not the GraphQL node id).
    .PARAMETER ExpectedMarker
        A substring that MUST be present in the fetched body before
        appending (e.g. '<!-- plan-issue-811' or '<!-- judge-rulings').
        Guards against appending to the wrong comment.
    .PARAMETER NewContent
        The new content to append after the existing body. Must contain at
        least one `judge_ruling:` entry (see the no-op guard above).
    .OUTPUTS
        [PSCustomObject] with:
          Success [bool]
          Reason  [string] — populated only when Success=$false
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [Parameter(Mandatory)][string]$NewContent
    )

    # Entry-level anchor: one match per `judge_ruling:` field occurrence.
    # Deliberately independent of any per-entry ID field name (the writer
    # side, s4, is not yet implemented and different callers may key entries
    # as `id:` or `finding_id:`) — the judge_ruling field itself is the one
    # value both the review-judgment SKILL template and the 811 plan's
    # writer contract agree is present on every entry, sustained or
    # defense-sustained, including the zero-findings placeholder.
    $judgeRulingEntryPattern = '(?m)^\s*(?:-\s+)?judge_ruling\s*:\s*\S+'

    # --- 2b (preflight, ahead of any network call): refuse a zero-entry
    # judge-rulings head up front (M8/D5). Without this, a caller could
    # append a bare `<!-- judge-rulings -->` head with no entries at all,
    # and the entry-level positive-proof loop below would vacuously pass
    # (zero entries to verify => zero iterations => trivially "success"),
    # exactly the same no-op hazard Add-CommentBlocks' M10 fix closed for
    # phase-containment blocks — but worse here, since a silently-accepted
    # empty judge-rulings append could defeat the D5 zero-findings
    # placeholder contract, which must always carry at least one entry.
    $preflightEntryMatches = [regex]::Matches($NewContent, $judgeRulingEntryPattern)
    if ($preflightEntryMatches.Count -eq 0) {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: NewContent carries zero judge_ruling: entries for comment $CommentId; refusing as a no-op.")
        return [PSCustomObject]@{ Success = $false; Reason = 'no-op: NewContent carries zero judge_ruling: entries' }
    }

    $getPath = "repos/$Owner/$Repo/issues/comments/$CommentId"

    # --- 1. GET the current comment body. ---
    $getOutput = & gh api $getPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: gh api GET $getPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "GET failed (exit $LASTEXITCODE)" }
    }

    try {
        $getObj = $getOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: failed to parse GET response JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ Success = $false; Reason = "GET response is not valid JSON: $($_.Exception.Message)" }
    }

    $originalBody = [string]$getObj.body

    # --- 2. Verify the expected marker is present. ---
    if (-not $originalBody.Contains($ExpectedMarker)) {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: expected marker '$ExpectedMarker' not found in comment $CommentId; refusing to append.")
        return [PSCustomObject]@{ Success = $false; Reason = "Expected marker '$ExpectedMarker' not found in comment body" }
    }

    # --- 3. Concatenate. ---
    $combinedBody = $originalBody + $NewContent

    # --- 4. PATCH the full combined body. ---
    $patchPath = "repos/$Owner/$Repo/issues/comments/$CommentId"
    $patchTempFile = $null
    try {
        $patchTempFile = [System.IO.Path]::GetTempFileName()
        $patchPayload = @{ body = $combinedBody } | ConvertTo-Json -Depth 4 -Compress
        Set-Content -LiteralPath $patchTempFile -Value $patchPayload -Encoding UTF8 -NoNewline
        $null = & gh api -X PATCH $patchPath --input $patchTempFile 2>$null
    }
    finally {
        if ($null -ne $patchTempFile -and (Test-Path -LiteralPath $patchTempFile)) {
            Remove-Item -LiteralPath $patchTempFile -Force -ErrorAction SilentlyContinue
        }
    }
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: gh api PATCH $patchPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "PATCH failed (exit $LASTEXITCODE)" }
    }

    # --- 5. Post-write verify: GET again and apply positive-proof checks. ---
    $verifyOutput = & gh api $getPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: post-write verify GET $getPath failed (exit $LASTEXITCODE)")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify GET failed (exit $LASTEXITCODE)" }
    }

    try {
        $verifyObj = $verifyOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: failed to parse post-write verify JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify response is not valid JSON: $($_.Exception.Message)" }
    }

    $verifyBody = [string]$verifyObj.body

    # --- 5a. Gross-truncation guard (same rationale as Add-CommentBlocks:
    # GitHub's API benignly normalizes some whitespace on write/read, but a
    # body that shrank dramatically relative to what was just written is
    # corruption/data-loss regardless of what the entry-level check below
    # finds). ---
    $expectedMinLength = [int]($combinedBody.Length * 0.5)
    if ($verifyBody.Length -lt $expectedMinLength) {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: post-write verify FAILED — verify body ($($verifyBody.Length) chars) is dramatically shorter than the written body ($($combinedBody.Length) chars) for comment $CommentId.")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: verify body ($($verifyBody.Length) chars) is dramatically shorter than expected ($($combinedBody.Length) chars written)" }
    }

    # --- 5b. Positive proof #1: original content survived. ---
    if (-not $verifyBody.Contains($ExpectedMarker)) {
        [Console]::Error.WriteLine("Add-JudgeRulingsBlock: post-write verify FAILED — expected marker '$ExpectedMarker' missing from verify body for comment $CommentId.")
        return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: expected marker '$ExpectedMarker' missing from verify body" }
    }

    # --- 5c. Positive proof #2 (entry-level, per this function's contract):
    # EVERY judge_ruling: entry appended in NewContent must land in the
    # verify body — checked both by count AND by individual entry-value
    # content identity, not merely by the head string '<!-- judge-rulings'
    # reappearing. This is what distinguishes this function's positive-proof
    # from a head-only check: a truncated append (e.g. head + 3 of 11
    # entries) has a matching head substring but a short count, and must
    # fail loud here rather than reporting success because "the marker
    # reappeared". Content identity (not just count) also catches the case
    # where the RIGHT NUMBER of entries landed but one was corrupted into a
    # different value.
    #
    # M3 fix (issue #811 post-fix adversarial pass): the check below used to
    # compare the verify body's TOTAL occurrence count of each value against
    # only the newly-appended count, with no baseline subtraction. If
    # $originalBody already carried an identical block (e.g. left over from a
    # prior partial/failed run) and the PATCH silently no-op'd (verify body
    # == original body, unchanged — the new append never actually landed),
    # the pre-existing entries alone could satisfy $neededCount and this
    # function would report Success=$true despite nothing new having been
    # written. Establish a baseline count of each value's occurrences in
    # $originalBody BEFORE the append, and require the verify body to contain
    # at least baseline + needed — i.e. the pre-existing entries PLUS the
    # newly-appended ones, not just "enough total occurrences somewhere."
    $appendedEntryValues = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $preflightEntryMatches) { $appendedEntryValues.Add($m.Value.Trim()) }

    $baselineEntryMatches = [regex]::Matches($originalBody, $judgeRulingEntryPattern)
    $baselineEntryCounts = @{}
    foreach ($m in $baselineEntryMatches) {
        $val = $m.Value.Trim()
        if ($baselineEntryCounts.ContainsKey($val)) { $baselineEntryCounts[$val]++ } else { $baselineEntryCounts[$val] = 1 }
    }

    $verifyEntryMatches = [regex]::Matches($verifyBody, $judgeRulingEntryPattern)
    $verifyEntryCounts = @{}
    foreach ($m in $verifyEntryMatches) {
        $val = $m.Value.Trim()
        if ($verifyEntryCounts.ContainsKey($val)) { $verifyEntryCounts[$val]++ } else { $verifyEntryCounts[$val] = 1 }
    }

    $appendedEntryCounts = @{}
    foreach ($val in $appendedEntryValues) {
        if ($appendedEntryCounts.ContainsKey($val)) { $appendedEntryCounts[$val]++ } else { $appendedEntryCounts[$val] = 1 }
    }

    foreach ($val in $appendedEntryCounts.Keys) {
        $neededCount = $appendedEntryCounts[$val]
        $baselineCount = if ($baselineEntryCounts.ContainsKey($val)) { $baselineEntryCounts[$val] } else { 0 }
        $requiredCount = $baselineCount + $neededCount
        $foundCount = if ($verifyEntryCounts.ContainsKey($val)) { $verifyEntryCounts[$val] } else { 0 }
        if ($foundCount -lt $requiredCount) {
            [Console]::Error.WriteLine("Add-JudgeRulingsBlock: post-write verify FAILED — appended entry '$val' expected at least $requiredCount occurrence(s) (baseline $baselineCount + appended $neededCount), found $foundCount in verify body for comment $CommentId.")
            return [PSCustomObject]@{ Success = $false; Reason = "Post-write verify failed: appended judge_ruling entry '$val' expected at least $requiredCount occurrence(s) (baseline $baselineCount + appended $neededCount), found $foundCount" }
        }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

#endregion
