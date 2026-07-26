#Requires -Version 7.0

<#
.SYNOPSIS
    Family-registry-driven marker-write core (issue #893, plan slice s3).
    Exports Get-MarkerFamilyRegistry, ConvertTo-MarkerNormalizedText, and
    Invoke-PersistMarkerWrite.

.DESCRIPTION
    This file composes the s2 transport primitives
    (.github/scripts/lib/marker-transport-core.ps1: Find-AllCommentsByExactMarker,
    New-MarkerComment, Get-CommentIdFromUrl, Get-CommentBodyById,
    Set-CommentBodyDirect) into the two write shapes the design phase
    settled on (893-D2): post-new and upsert. Callers are responsible for
    dot-sourcing marker-transport-core.ps1 before this file, exactly as
    that file's own header documents for its callers.

    Scope (s3 Requirement Contract, ac-refs AC1/AC3/AC11) -- explicit
    non-goals carried forward from the plan: no post-steps/preserve-logic
    (s5 -- PostStep is a registry field name only, never invoked here).

    s4 addition (ac-refs AC2): wires per-family ValidatorAdapter dispatch
    plus the 893-D7 payload-hygiene checks, both run on the
    marker-COMPOSED CANDIDATE (the exact bytes about to be written) --
    never the raw payload -- immediately before any network write, inside
    Invoke-PersistMarkerWrite. Three new registry rows (engagement-record,
    review-dispositions, credit-input) were added so their named adapters
    have a family to attach to, per 893-D3's full family table; the
    existing review-judge-produced row's ValidatorAdapter is now
    'sentinel-empty'. Full 9-family population (frame-slices,
    design-phase-complete's finding_dispositions check, design-issue) is
    not this slice's scope -- see s5/s6/s9 for the remaining rows and
    consolidation. Refusal message shape (893-D6):
    "persist-marker: REFUSED ({family}, {target}): {detail}", with every
    echoed value length-bounded by $script:MarkerRefusalEchoCap so a
    refusal can never dump an oversized or sensitive field verbatim.
    Adapter infrastructure failure (missing module, non-zero exit,
    unparseable result) is fail-closed: refused with a diagnosable
    message, never treated as "no findings". This is pre-write blocking
    scoped to this script's own writes only -- the standalone validators'
    own read-side warn-only SMC-23 contracts are unchanged, and this is
    not a reversal of the #617 decision against a centralized
    prevention-at-persist hook (that rejection was a different, broader
    mechanism).

    Known v1 scope gap (accepted, not solved in this slice): the
    engagement-record family's real surface is issue for every phase
    except 'review', which is PR-keyed (893-D3). The registry below
    declares TargetSurface='issue' for the whole family; a 'review'-phase
    engagement-record write would be refused by the surface preflight.
    Resolving per-phase surface selection is out of scope for s4's
    validator-wiring requirement contract.

    Write shapes:
      post-new -- enumerates all marker matches via
        Find-AllCommentsByExactMarker and compares the composed candidate
        against the LATEST (highest REST id) match only. A candidate that
        matches a SUPERSEDED (non-latest) match still posts -- this is
        deliberate: post-new preserves latest-comment-wins write intent
        (design finding F5).
      upsert -- selects the CANONICAL match (earliest / lowest REST id,
        never --edit-last) for comparison, and re-finds that canonical
        target immediately before PATCH rather than reusing the id from the
        earlier find (893-D2 concurrency posture: single-writer assumption,
        pre-PATCH re-find, residual race between re-find and PATCH is an
        accepted risk -- there is no shipped primitive to make the
        find-then-PATCH pair atomic against the REST API).

    Normalization: ConvertTo-MarkerNormalizedText is the ONE shared
    normalization function (LF line endings, per-line trailing-whitespace
    strip, outer trim -- nothing else), used identically by both the
    write-shape idempotency comparison and the post-write read-back
    comparison (Test-MarkerReadBack), so the two checks can never silently
    drift apart on what counts as "unchanged".

    Read-back: Test-MarkerReadBack's PRIMARY gate is normalized equality,
    not the inherited >=50%-length truncation guard alone -- that guard
    cannot prove byte-faithfulness because mojibake corruption LENGTHENS
    text rather than shortening it (design challenge finding, resolves the
    893-D2-vs-893-D11 contradiction in favor of the strict reading, plan
    step 6). The truncation guard is retained as a SECONDARY check, used
    only to produce a more specific failure message when the mismatch is
    also a gross truncation -- either branch is already a hard failure once
    normalized equality has failed. Test-MarkerReadBack throws (loud, never
    silently swallowed) on any failure -- an unreadable comment or a
    normalized mismatch -- and the two write-shape functions below catch
    that and convert it into their own Success=$false result, so a bad
    read-back is always reported as a failed write, never as success.

    Surface preflight: before any write, Invoke-PersistMarkerWrite compares
    the caller's declared -TargetSurface against the registry row's
    declared TargetSurface. This is necessarily a declared-vs-declared
    comparison, not a live lookup -- the unified GitHub comments REST
    endpoint (repos/{Owner}/{Repo}/issues/{Number}/comments) accepts either
    an issue or a pull-request number silently, so there is no live way to
    ask the endpoint itself which surface a number belongs to. A
    wrong-surface write would otherwise report success while the intended
    reader looks at the other surface entirely.

.NOTES
    Non-goals (explicit, per s4's requirement contract): design-phase-complete
    finding_dispositions validator wiring (deferred -- see this file's
    top-of-file s4 addition note); dot-sourcing
    .github/scripts/lib/frame-engagement-record-core.ps1 before this file
    is the CALLER's responsibility (mirrors the existing
    marker-transport-core.ps1 convention) -- Invoke-EngagementRecordValidatorAdapter
    calls Read-EngagementRecords unqualified and fails closed with a
    diagnosable message if it is not in scope.

    s5 addition (ac-refs AC5): populates the previously-always-$null
    PostStep registry field for two families and implements the two named
    post-steps:
      - 'plan-issue-write-back-preserve' (plan-issue family, runs BEFORE
        hygiene/validator/write, mutating the candidate Body): on a
        re-persist, carries forward every artifact class from the
        migration-inventory's Section 2 (.tmp/issue-893/migration-inventory.md)
        that the incoming payload omits but the existing canonical comment
        carries -- the phase-containment-ledger-ref pointer (live-checked
        against its target before preserving; dropped on a stale/forged
        pointer, falling through to persist-phase-ledger-core.ps1's own M1
        self-heal), the frame-spine slice_comment_id scalar (same
        live-check discipline against the frame-slices-{ID} sibling), and
        for legacy pre-863 plans (no ledger pointer at all) the
        judge-rulings head, phase-containment blocks, and the
        `**Plan Stress-Test**` heading/section. A -NoPreserve switch lets a
        maintainer deliberately clear a bad pointer instead of having it
        carried forward.
      - 'frame-slices-spine-splice' (frame-slices family, runs AFTER a
        successful write): writes the just-written sibling's comment id
        back into the plan comment's frame-spine block as slice_comment_id
        via a TARGETED SCALAR SPLICE (script:Set-MarkerSpineScalarValue --
        never a full-body recompose), guarded by a marker-identity
        precondition (refuses when the plan comment does not carry the
        expected `<!-- plan-issue-{ID} -->` marker) and by generated_at
        EQUALITY between the plan's frame-spine block and the sibling's own
        `frame-slices-generated-at` stamp (a stale-generation sibling is
        refused, not silently spliced in). A splice-back failure makes the
        overall Invoke-PersistMarkerWrite result Success=$false even though
        the sibling write itself already landed -- loud, never swallowed.
      Both post-steps dot-source .github/scripts/lib/frame-spine-core.ps1's
      Get-FSCSpineBlock and script:Get-FSCScalarValue to read the frame-spine
      block (this file calls that parser, per its own non-goal, and never
      reimplements or modifies its parsing logic). script:Set-MarkerSpineScalarValue
      is restricted via -ValidateSet to the exact four keys legal at
      frame-spine-core.ps1:224 (spine_schema_version|generated_at|coverage|
      slice_comment_id) and is never used to widen that allowlist.

    s6 addition (ac-refs AC4/AC12): adds scratch-root path bounding, a
    GitHub 65,536-char comment-cap size refusal, and ordered multi-write
    burst support, all consumed by the new thin wrapper
    skills/session-memory-contract/scripts/persist-marker.ps1 (mirrors
    persist-phase-ledger.ps1's wrapper/core split):
      - Get-MarkerScratchRoot / Resolve-MarkerScratchBoundedPath /
        Read-MarkerScratchBoundedBodyFile: resolve the CONSUMER repo's
        scratch root ('.tmp/') from the live CWD (git-rev-parse with a CWD
        fallback -- never $PSScriptRoot, which would resolve into this
        PLUGIN's own bundled tree instead; see persist-phase-ledger.ps1's
        header for why $PSScriptRoot is right there and wrong here) and
        enforce REAL path-containment via Resolve-Path canonicalization
        (symlink- and traversal-aware), never a raw string-prefix test on
        the unresolved input.
      - script:Test-MarkerCandidatePreflight: extracts the network-free
        checks Invoke-PersistMarkerWrite already ran (registry lookup,
        surface-declaration match, the new size-cap refusal, 893-D7
        hygiene, and the family's ValidatorAdapter) into one shared helper,
        so Invoke-PersistMarkerBurst's whole-manifest preflight runs the
        EXACT SAME validation a single write already ran, on every burst
        entry, before any network write -- this is what makes "a manifest
        containing any invalid payload writes nothing at all" true at
        INVOCATION scope. Deliberately does NOT re-run the
        'plan-issue-write-back-preserve' PostStep (that step performs its
        own live GET calls and is therefore not network-free); a PostStep's
        live mutation stays a per-write, execution-time concern exercised
        by the write itself, not predicted by this preflight.
      - Invoke-PersistMarkerBurst / Invoke-PersistMarkerBurstFromManifest:
        ordered multi-write burst. Preflights every entry first (zero
        writes on any refusal), then executes Invoke-PersistMarkerWrite per
        entry in manifest order, halting on the first execution failure.
        Re-run convergence after a mid-burst halt relies entirely on
        Invoke-PersistMarkerWrite's own s3 write-shape idempotency (a
        previously-landed entry's re-attempt is reported as a no-op, not
        re-posted) -- this file adds no separate dedup bookkeeping.
        Returns a per-entry landed/not-attempted/failed artifact manifest
        (ordered dictionary keyed 'entry-N'), mirroring the shape of
        persist-phase-ledger-core.ps1's own
        script:New-PPLPersistPhaseLedgerArtifactManifest.
#>

# ---------------------------------------------------------------------------
# Family registry.
# ---------------------------------------------------------------------------

function Get-MarkerFamilyRegistry {
    <#
    .SYNOPSIS
        Returns the declarative marker-family registry: one row per durable
        marker family, driving which surface a family's target number must
        be and which of the two write shapes it uses.
    .DESCRIPTION
        PostStep is a reserved field name that names a post-step function to
        run (see Invoke-PersistMarkerWrite's PostStep dispatch, s5): $null
        for every family with no post-step (hygiene/validator-only).
        's5 populates two rows: plan-issue carries
        'plan-issue-write-back-preserve' (a pre-write candidate transform)
        and frame-slices carries 'frame-slices-spine-splice' (a post-write
        side effect). ValidatorAdapter is now populated for the families
        s4's requirement contract names an adapter for (own-marker/
        cross-marker hygiene runs unconditionally regardless of this
        field's value; see Test-MarkerPayloadHygiene and
        Invoke-MarkerValidatorAdapter below).

        Rows are grounded in already-documented marker families (this
        repo's own CLAUDE.md, skills/session-memory-contract/references/handoff-markers.md,
        and 893-D3's family table) rather than invented: plan-issue,
        design-phase-complete, and frame-slices (s5) are upsert (all three
        are found-or-created once, then repeatedly patched -- plan-issue
        and design-phase-complete as persist-phase-ledger-core.ps1's own
        plan/design modes already do today; frame-slices per
        handoff-markers.md's frame-slices-{ID} row: "re-persist reuses the
        existing sibling ... rather than creating a second one", which
        post-new's superseded-match-still-posts semantics would violate);
        experience-owner-complete, review-judge-produced, engagement-record,
        review-dispositions, and credit-input are post-new (freshly posted
        completion/sentinel/deferred-emission comments -- CLAUDE.md
        documents review-judge-produced as "written as a separate PR
        comment"; skills/frame-credit-emission/SKILL.md documents
        credit-input as posted "immediately after the agent's completion
        marker comment").
    .OUTPUTS
        [PSCustomObject[]] one row per family: Family [string], MarkerTemplate
        [string] (placeholder tokens such as '{ID}'/'{PR}'/'{phase}'/'{port}'
        for the numeric issue/PR id or other runtime-substituted segment --
        schema documentation only, never programmatically substituted here,
        though Test-MarkerPayloadHygiene's cross-family scan does wildcard
        them when building its detection regex), TargetSurface
        ['issue'|'pull-request'], WriteShape ['post-new'|'upsert'],
        ValidatorAdapter [string or $null -- one of $null (no adapter,
        hygiene-only), 'sentinel-empty', 'engagement-record',
        'review-dispositions', 'credit-input'; see
        Invoke-MarkerValidatorAdapter's dispatch switch], PostStep [string
        or $null -- one of $null (no post-step), 'plan-issue-write-back-preserve',
        'frame-slices-spine-splice'; see Invoke-PersistMarkerWrite's
        PostStep dispatch].
    #>
    return @(
        [PSCustomObject]@{
            Family            = 'plan-issue'
            MarkerTemplate    = '<!-- plan-issue-{ID} -->'
            TargetSurface     = 'issue'
            WriteShape        = 'upsert'
            # 893-D3: "payload-hygiene checks only (v1)" -- the universal
            # Test-MarkerPayloadHygiene checks (own-family / cross-family
            # marker-at-line-start) already run unconditionally for every
            # family, so this row needs no additional named adapter.
            ValidatorAdapter  = $null
            # s5: on re-persist, carries forward artifact classes the fresh
            # payload omits but the existing canonical comment carries --
            # see script:Invoke-PlanIssueWriteBackPreserve.
            PostStep          = 'plan-issue-write-back-preserve'
        }
        [PSCustomObject]@{
            Family            = 'design-phase-complete'
            MarkerTemplate    = '<!-- design-phase-complete-{ID} -->'
            TargetSurface     = 'issue'
            WriteShape        = 'upsert'
            # 893-D3 also names a finding_dispositions schema check "when
            # block present" for this family -- deferred, not this slice's
            # scope (s4's requirement contract names only the
            # engagement-record, review-dispositions, and credit-input
            # adapters).
            ValidatorAdapter  = $null
            PostStep          = $null
        }
        [PSCustomObject]@{
            Family            = 'experience-owner-complete'
            MarkerTemplate    = '<!-- experience-owner-complete-{ID} -->'
            TargetSurface     = 'issue'
            WriteShape        = 'post-new'
            # 893-D3: "none (prose)" -- free-form completion narrative,
            # arbitrary content is expected and allowed.
            ValidatorAdapter  = $null
            PostStep          = $null
        }
        [PSCustomObject]@{
            Family            = 'review-judge-produced'
            MarkerTemplate    = '<!-- review-judge-produced-{PR} -->'
            TargetSurface     = 'pull-request'
            WriteShape        = 'post-new'
            # 893-D3: "none (sentinel)" -- distinct from the prose families
            # above: a sentinel carries no content of its own, so this
            # pins an empty (marker-only) payload rather than accepting
            # arbitrary content.
            ValidatorAdapter  = 'sentinel-empty'
            PostStep          = $null
        }
        [PSCustomObject]@{
            Family            = 'engagement-record'
            MarkerTemplate    = '<!-- engagement-record-{phase}-{ID} -->'
            # Real surface is issue for every phase except 'review' (PR-keyed);
            # see this file's top-of-file "Known v1 scope gap" note.
            TargetSurface     = 'issue'
            WriteShape        = 'post-new'
            ValidatorAdapter  = 'engagement-record'
            PostStep          = $null
        }
        [PSCustomObject]@{
            Family            = 'review-dispositions'
            MarkerTemplate    = '<!-- review-dispositions-{PR} -->'
            TargetSurface     = 'pull-request'
            WriteShape        = 'post-new'
            ValidatorAdapter  = 'review-dispositions'
            PostStep          = $null
        }
        [PSCustomObject]@{
            Family            = 'credit-input'
            MarkerTemplate    = '<!-- credit-input-{port}-{ID} -->'
            TargetSurface     = 'issue'
            WriteShape        = 'post-new'
            ValidatorAdapter  = 'credit-input'
            PostStep          = $null
        }
        [PSCustomObject]@{
            # s5: first family population for frame-slices (deferred at s4 --
            # see this file's top-of-file s4 addition note). Upsert, not
            # post-new (handoff-markers.md: "re-persist reuses the existing
            # sibling ... rather than creating a second one").
            Family            = 'frame-slices'
            MarkerTemplate    = '<!-- frame-slices-{ID} -->'
            TargetSurface     = 'issue'
            WriteShape        = 'upsert'
            # 893-D3-equivalent: no payload-shape adapter for this slice --
            # the universal hygiene checks cover the identity-marker
            # concern; per-slice frame-slice schema validation is out of
            # this row's scope (s5's requirement contract names only the
            # write-back-preserve and spine-splice post-steps).
            ValidatorAdapter  = $null
            # s5: after a successful write, splices the sibling's own
            # comment id back onto the plan comment's frame-spine block as
            # slice_comment_id -- see script:Invoke-FrameSlicesSpineSplice.
            PostStep          = 'frame-slices-spine-splice'
        }
    )
}

# ---------------------------------------------------------------------------
# Shared normalization + read-back.
# ---------------------------------------------------------------------------

function ConvertTo-MarkerNormalizedText {
    <#
    .SYNOPSIS
        The ONE shared normalization function (893 design finding F3): LF
        line endings, per-line trailing-whitespace strip, outer trim --
        nothing else. Used identically by both the write-shape idempotency
        comparison and Test-MarkerReadBack's post-write comparison, so the
        two checks can never silently drift apart on what counts as
        "unchanged".
    .OUTPUTS
        [string]
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lf = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $strippedLines = ($lf -split "`n") | ForEach-Object { $_ -replace '[ \t]+$', '' }
    return ($strippedLines -join "`n").Trim()
}

function script:Test-MarkerReadBack {
    <#
    .SYNOPSIS
        Post-write verification shared by both write shapes: GETs the
        comment's current body and compares it against the body just
        written using normalized equality (ConvertTo-MarkerNormalizedText)
        as the PRIMARY gate -- not the inherited >=50%-length truncation
        guard alone, which cannot prove byte-faithfulness because mojibake
        corruption LENGTHENS text rather than shortening it.
    .DESCRIPTION
        Throws (loud, never silently swallowed) on any failure: the GET
        itself failing (cannot verify at all), or the normalized bodies not
        matching (corruption or an unfaithful write detected). Callers
        (Invoke-MarkerPostNewWrite / Invoke-MarkerUpsertWrite) catch this
        and convert it into their own Success=$false result, so the write
        is always reported failed on a bad read-back, never reported
        success.

        The truncation guard below is retained as a SECONDARY check, used
        only to produce a more specific failure message when the mismatch
        is also a gross truncation -- either branch is already a hard
        failure; normalized equality has already failed by the time either
        runs.
    .OUTPUTS
        $true on success. Throws on any failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedBody
    )
    $actualBody = Get-CommentBodyById -Owner $Owner -Repo $Repo -CommentId $CommentId
    if ($null -eq $actualBody) {
        throw "persist-marker-core: read-back GET failed for comment $CommentId -- cannot verify the write"
    }

    $normalizedActual = ConvertTo-MarkerNormalizedText -Text $actualBody
    $normalizedExpected = ConvertTo-MarkerNormalizedText -Text $ExpectedBody
    if ($normalizedActual -eq $normalizedExpected) {
        return $true
    }

    $expectedMinLength = [int]($ExpectedBody.Length * 0.5)
    if ($actualBody.Length -lt $expectedMinLength) {
        throw "persist-marker-core: read-back FAILED for comment $CommentId -- normalized verify body does not equal the normalized written body, and the raw verify body ($($actualBody.Length) chars) is dramatically shorter than the written body ($($ExpectedBody.Length) chars)"
    }
    throw "persist-marker-core: read-back FAILED for comment $CommentId -- normalized verify body does not equal the normalized written body"
}

# ---------------------------------------------------------------------------
# Refusal formatting (893-D6).
# ---------------------------------------------------------------------------

# Refusal messages never echo a raw field/value/offset longer than this many
# characters -- a refusal must be diagnosable without risking an oversized or
# sensitive field being dumped verbatim (s4 requirement contract).
$script:MarkerRefusalEchoCap = 80

function script:ConvertTo-MarkerRefusalEcho {
    <#
    .SYNOPSIS
        Length-bounds a value before it is echoed inside a refusal message.
        Pinned cap: $script:MarkerRefusalEchoCap (80 chars) -- long enough to
        diagnose the offending field, short enough that a refusal can never
        dump an oversized or sensitive field verbatim.
    .OUTPUTS
        [string]
    #>
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '<null>' }
    if ($Value.Length -le $script:MarkerRefusalEchoCap) { return $Value }
    $overflow = $Value.Length - $script:MarkerRefusalEchoCap
    return "$($Value.Substring(0, $script:MarkerRefusalEchoCap))...(+$overflow more chars, truncated)"
}

function script:New-MarkerRefusal {
    <#
    .SYNOPSIS
        Builds the standard pre-write refusal result. Message shape (893-D6,
        exact prefix -- tests assert this): "persist-marker: REFUSED
        ({family}, {target}): {detail}". Callers must have already
        length-bounded any echoed value in -Detail via
        ConvertTo-MarkerRefusalEcho.
    .OUTPUTS
        [PSCustomObject] Success=$false, Family, CommentId=$null,
        Action=$null, Confirmation=$null, Reason (carries the formatted
        message).
    #>
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Detail
    )
    $reason = "persist-marker: REFUSED ($Family, $Target): $Detail"
    return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = $reason }
}

# ---------------------------------------------------------------------------
# Payload hygiene (893-D7, s9 amendment: BOTH rules below refuse, neither
# warns -- see this file's top-of-file s4 addition note).
# ---------------------------------------------------------------------------

function script:Get-MarkerLineStartMatchIndexes {
    <#
    .SYNOPSIS
        Returns the 0-based line indexes at which -Literal appears at line
        start (optional leading whitespace only) inside -Body. A REAL
        line-start check, not a substring search -- a mid-line mention never
        matches.
    .OUTPUTS
        [int[]] (possibly empty; array identity preserved via the unary
        comma so a single-element result is never unrolled to a scalar).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][string]$Literal
    )
    $normalized = ($Body -replace "`r`n", "`n") -replace "`r", "`n"
    $lines = $normalized -split "`n"
    $pattern = '^\s*' + [regex]::Escape($Literal)
    $indexes = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $indexes.Add($i)
        }
    }
    return , @($indexes)
}

function script:ConvertTo-MarkerFamilyLineStartPattern {
    <#
    .SYNOPSIS
        Builds a line-start detection regex from a registry MarkerTemplate,
        wildcarding its '{ID}'/'{PR}'/'{phase}'/'{port}'-style placeholder
        tokens (schema documentation only, per Get-MarkerFamilyRegistry's
        own convention) so the cross-family scan below catches ANY concrete
        id/phase/port value that family's live marker could carry, not one
        hardcoded instance.
    .DESCRIPTION
        Requires the literal '<!--'/'-->' HTML-comment delimiter bytes to be
        present at line start to count as a match. This is what makes the
        false-positive (inert-rendered mention) guard correct without any
        extra special-casing: an HTML-entity-escaped mention
        ('&lt;!-- ... --&gt;', the repo's established inert-render
        convention -- see Format-InertMarkerLabel and
        skills/session-memory-contract/references/handoff-markers.md
        "Writing about markers safely") never contains the literal '<!--'
        bytes this pattern anchors on, so it never matches.
    .OUTPUTS
        [string] a regex pattern (multiline, '(?m)^\s*' anchored).
    #>
    param([Parameter(Mandatory)][string]$MarkerTemplate)
    $escaped = [regex]::Escape($MarkerTemplate)
    # [regex]::Escape escapes the opening '{' (quantifier-significant in
    # .NET regex) but leaves a lone '}' unescaped (not special outside a
    # quantifier) -- so the escaped placeholder token reads '\{ID}', never
    # '\{ID\}'. Matching only the opening escape here is deliberate, not a
    # typo.
    $withWildcards = $escaped -replace '\\\{[A-Za-z]+\}', '[\w-]+'
    return '(?m)^\s*' + $withWildcards
}

function script:Test-MarkerPayloadHygiene {
    <#
    .SYNOPSIS
        893-D7 payload hygiene, run on the marker-COMPOSED CANDIDATE (the
        exact bytes about to be written) -- never the raw payload. Two
        distinct rules, both refuse (s9 amends 893-D7, which originally
        warned on the second rule):
          1. own-family: the candidate carries its OWN family's marker at a
             line-start position OTHER than line 1 -- a legitimate candidate
             carries the marker exactly once, on line 1 (the line the
             caller composed it on); any additional line-start occurrence
             signals accidental double-marker emission.
          2. cross-family: the candidate carries any OTHER registered
             family's live marker literal at line start (the recorded
             self-DoS class -- a live marker literal inside prose makes an
             issue carry two matching comments for that OTHER family).
        Inert-rendered mentions (no literal '<!--'/'-->' bytes present, e.g.
        an HTML-entity-escaped example inside a code fence) never trigger
        either rule -- see ConvertTo-MarkerFamilyLineStartPattern.
    .OUTPUTS
        [string] a refusal detail message, or $null when the candidate is
        clean.
    #>
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Registry
    )

    $ownIndexes = @(script:Get-MarkerLineStartMatchIndexes -Body $Body -Literal $Marker | Where-Object { $_ -gt 0 })
    if ($ownIndexes.Count -gt 0) {
        $lineNumber = $ownIndexes[0] + 1
        return "candidate carries its own family's marker at a non-line-1 position (line $lineNumber) -- the script emits the marker exactly once; this indicates accidental double-marker emission"
    }

    foreach ($row in $Registry) {
        if ($row.Family -eq $Family) { continue }
        if ([string]::IsNullOrWhiteSpace($row.MarkerTemplate)) { continue }
        $pattern = script:ConvertTo-MarkerFamilyLineStartPattern -MarkerTemplate $row.MarkerTemplate
        if ($Body -match $pattern) {
            $echoed = script:ConvertTo-MarkerRefusalEcho -Value $Matches[0].Trim()
            return "candidate carries another registered family's ('$($row.Family)') live marker literal at line start: $echoed"
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Validator adapters (s4 requirement contract).
# ---------------------------------------------------------------------------

function script:Get-MarkerYamlPayload {
    <#
    .SYNOPSIS
        Extracts the YAML content of a marker-composed candidate, matching
        the extraction convention already established by
        frame-engagement-record-core.ps1 and
        review-dispositions-validator-core.ps1: prefer a fenced ```yaml
        block; otherwise fall back to everything after the marker's closing
        '-->'.
    .OUTPUTS
        [string] (possibly empty).
    #>
    param([Parameter(Mandatory)][string]$Body)
    if ($Body -match '```yaml\s*([\s\S]*?)```') {
        return $Matches[1].Trim()
    }
    $closeIdx = $Body.IndexOf('-->')
    if ($closeIdx -ge 0) {
        return $Body.Substring($closeIdx + 3).Trim()
    }
    return $Body.Trim()
}

function script:Invoke-SentinelEmptyValidatorAdapter {
    <#
    .SYNOPSIS
        893-D3 "none (sentinel)" families carry no content of their own --
        pin an empty (marker-only) payload rather than accepting arbitrary
        content.
    .OUTPUTS
        [PSCustomObject] a refusal result, or $null when the candidate is
        exactly the marker (normalized).
    #>
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )
    $normalizedBody = ConvertTo-MarkerNormalizedText -Text $Body
    $normalizedMarker = ConvertTo-MarkerNormalizedText -Text $Marker
    if ($normalizedBody -eq $normalizedMarker) {
        return $null
    }
    $remainder = ($normalizedBody -replace [regex]::Escape($normalizedMarker), '').Trim()
    $echoed = script:ConvertTo-MarkerRefusalEcho -Value $remainder
    return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "sentinel family requires an empty (marker-only) payload; found extra content: $echoed"
}

function script:Invoke-EngagementRecordValidatorAdapter {
    <#
    .SYNOPSIS
        Validates the marker-composed candidate via the payload-only path
        Read-EngagementRecords -InMemoryMarkers (short-circuits gh --
        .github/scripts/lib/frame-engagement-record-core.ps1:95-99). Per-marker
        malformations are demoted to Write-Warning + skip by that function,
        so this adapter captures the warning stream (-WarningVariable) and
        converts any warning into a structured refusal -- a warning always
        indicates a real finding on this call path (the only warning this
        function can emit via -InMemoryMarkers is a malformed-marker/
        malformed-YAML skip; its gh-path-only warnings, e.g. repo
        resolution, are unreachable here).
    .DESCRIPTION
        Fail-closed: an uncaught throw from Read-EngagementRecords (missing
        powershell-yaml module, unknown schema_version, or the function
        itself not being in scope because frame-engagement-record-core.ps1
        was not dot-sourced by the caller) is caught here and converted to a
        refusal rather than propagating or being silently treated as "no
        findings".

        Echo-cap scope note: the captured warning text is Read-EngagementRecords'
        OWN already-bounded diagnostic prose (a fixed template plus one
        interpolated field, authored by reviewed library code) -- passed
        through here VERBATIM, uncapped, so the offending field/value it
        names (893-D6) stays legible. $script:MarkerRefusalEchoCap governs
        values THIS file echoes directly from raw payload content (see
        Invoke-CreditInputValidatorAdapter, Test-MarkerPayloadHygiene,
        Invoke-SentinelEmptyValidatorAdapter) or unpredictable exception
        text (the infrastructure-failure branch below), not a trusted
        library's own formatted message.
    .OUTPUTS
        [PSCustomObject] a refusal result, or $null when the candidate
        parses clean.
    #>
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Body
    )
    $warnings = $null
    try {
        $null = Read-EngagementRecords -IssueNumber $Number -InMemoryMarkers @($Body) -WarningVariable warnings -WarningAction SilentlyContinue -ErrorAction Stop
    }
    catch {
        $echoed = script:ConvertTo-MarkerRefusalEcho -Value $_.Exception.Message
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "engagement-record validator adapter infrastructure failure: $echoed"
    }
    $warningList = @($warnings)
    if ($warningList.Count -gt 0) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "engagement-record validator flagged the candidate: $([string]$warningList[0])"
    }
    return $null
}

# Resolved once at file load: the review-dispositions validator is a
# top-level executable script (not a function library), so it is invoked
# in-process via the call operator at call time rather than dot-sourced --
# see Invoke-ReviewDispositionsValidatorAdapter below.
$script:ReviewDispositionsValidatorScriptPath = Join-Path $PSScriptRoot '../../../.github/scripts/lib/review-dispositions-validator-core.ps1'

function script:Invoke-ReviewDispositionsValidatorAdapter {
    <#
    .SYNOPSIS
        Invokes .github/scripts/lib/review-dispositions-validator-core.ps1
        IN-PROCESS via the call operator (amends 893-D3, see s9): that
        script declares [string[]]$InMemoryMarkers as a top-level parameter
        (~line 53), and a `pwsh -File` subprocess cannot bind an array
        parameter that way -- the recorded #866 flattening trap. In-process
        `&` invocation runs the script in a child scope of THIS runspace
        (no new process), which both sidesteps the flattening trap and
        correctly runs the script under its own #Requires gate (~line 2)
        and $ErrorActionPreference = 'Stop' (~line 56).
    .DESCRIPTION
        Because that script terminates on its own errors, the try/catch
        below is MANDATORY containment, not defensive style: an uncaught
        error inside the target script would otherwise propagate into and
        crash this caller's runspace. The validator's own contract is
        warn-only (SMC-23, never throws by design) -- any finding it
        returns is converted here into a hard pre-write refusal, which is a
        property of THIS write path only; the standalone script's own
        read-side warn-only contract is unchanged.
    .OUTPUTS
        [PSCustomObject] a refusal result, or $null when the candidate
        parses clean with zero findings.
    #>
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Body
    )
    if (-not (Test-Path -LiteralPath $script:ReviewDispositionsValidatorScriptPath)) {
        $echoed = script:ConvertTo-MarkerRefusalEcho -Value $script:ReviewDispositionsValidatorScriptPath
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "review-dispositions validator adapter infrastructure failure: script not found at $echoed"
    }
    try {
        $result = & $script:ReviewDispositionsValidatorScriptPath -PullRequestNumber $Number -InMemoryMarkers @($Body)
    }
    catch {
        $echoed = script:ConvertTo-MarkerRefusalEcho -Value $_.Exception.Message
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "review-dispositions validator adapter infrastructure failure: $echoed"
    }
    if ($null -eq $result) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail 'review-dispositions validator adapter returned an unparseable (null) result'
    }
    # Echo-cap scope note: findings[0].message is review-dispositions-validator-core.ps1's
    # OWN already-bounded diagnostic prose (Add-RdvFinding's fixed
    # templates), passed through verbatim so the offending field/value it
    # names (893-D6) stays legible -- see Invoke-EngagementRecordValidatorAdapter's
    # identical rationale.
    $findings = @($result.findings)
    if ($findings.Count -gt 0) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "review-dispositions validator flagged the candidate: $([string]$findings[0].message)"
    }
    return $null
}

# credit-input-{port}-{ID} port enum (893-D3; skills/frame-credit-emission/SKILL.md
# "Credit-Input Marker Schema"): the pipeline-entry phases that post a
# deferred-emission credit-input marker.
$script:CreditInputPortEnum = @('experience', 'design', 'plan', 'orchestration')

function script:Invoke-CreditInputValidatorAdapter {
    <#
    .SYNOPSIS
        In-core credit-input-{port}-{ID} shape validator (893-D3: "YAML
        shape (port/adapter/evidence keys; port enum) -- small new
        validator") -- lives directly in this file, no external script.
    .DESCRIPTION
        Requires port/adapter/evidence keys, port to be one of
        $script:CreditInputPortEnum, and evidence to be a flat string.
        skills/frame-credit-emission/SKILL.md "Field requirements" documents
        that a nested YAML mapping for evidence is silently dropped by
        Code-Conductor's flat key-value harvester, so this refuses that
        shape pre-write instead of shipping a payload the harvester would
        silently truncate.
    .OUTPUTS
        [PSCustomObject] a refusal result, or $null when the candidate
        parses clean.
    #>
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Body
    )
    $yamlContent = script:Get-MarkerYamlPayload -Body $Body
    if ([string]::IsNullOrWhiteSpace($yamlContent)) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail 'credit-input payload has no YAML content after the marker'
    }
    try {
        Import-Module powershell-yaml -ErrorAction Stop
        $payload = ConvertFrom-Yaml -Yaml $yamlContent
    }
    catch {
        $echoed = script:ConvertTo-MarkerRefusalEcho -Value $_.Exception.Message
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "credit-input validator adapter infrastructure failure: $echoed"
    }
    if ($null -eq $payload) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail 'credit-input payload parsed to an empty YAML document'
    }
    if ([string]::IsNullOrWhiteSpace([string]$payload.port)) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail 'credit-input payload missing required field: port'
    }
    if ($payload.port -notin $script:CreditInputPortEnum) {
        $echoed = script:ConvertTo-MarkerRefusalEcho -Value ([string]$payload.port)
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "credit-input payload has invalid port '$echoed' (must be one of: $($script:CreditInputPortEnum -join ', '))"
    }
    if ([string]::IsNullOrWhiteSpace([string]$payload.adapter)) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail 'credit-input payload missing required field: adapter'
    }
    if ($null -eq $payload.evidence -or [string]::IsNullOrWhiteSpace([string]$payload.evidence)) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail 'credit-input payload missing required field: evidence'
    }
    $evidenceIsNested = ($payload.evidence -is [System.Collections.IDictionary]) -or
        (($payload.evidence -is [System.Collections.IEnumerable]) -and ($payload.evidence -isnot [string]))
    if ($evidenceIsNested) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail 'credit-input evidence must be a flat string, not a nested mapping or list (the harvester silently drops nested fields)'
    }
    return $null
}

function script:Invoke-MarkerValidatorAdapter {
    <#
    .SYNOPSIS
        Dispatches to the named validator adapter by the registry row's
        ValidatorAdapter field. $null / unrecognized -> no adapter beyond
        the universal payload-hygiene checks (covers 893-D3's "none
        (prose)" and "payload-hygiene checks only" rows).
    .OUTPUTS
        [PSCustomObject] a refusal result, or $null when the family has no
        adapter or the adapter passed.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ValidatorAdapter,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][int]$Number
    )
    switch ($ValidatorAdapter) {
        'sentinel-empty' { return script:Invoke-SentinelEmptyValidatorAdapter -Family $Family -Target $Target -Marker $Marker -Body $Body }
        'engagement-record' { return script:Invoke-EngagementRecordValidatorAdapter -Family $Family -Target $Target -Number $Number -Body $Body }
        'review-dispositions' { return script:Invoke-ReviewDispositionsValidatorAdapter -Family $Family -Target $Target -Number $Number -Body $Body }
        'credit-input' { return script:Invoke-CreditInputValidatorAdapter -Family $Family -Target $Target -Body $Body }
        default { return $null }
    }
}

# ---------------------------------------------------------------------------
# Post-steps (s5 requirement contract, ac-refs AC5). Dot-source
# .github/scripts/lib/frame-spine-core.ps1 before this file for
# Get-FSCSpineBlock / script:Get-FSCScalarValue to be in scope -- the
# CALLER's responsibility, mirroring this file's existing
# marker-transport-core.ps1 / frame-engagement-record-core.ps1 convention.
# ---------------------------------------------------------------------------

function script:ConvertTo-MarkerLFBody {
    <#
    .SYNOPSIS
        CRLF/CR -> LF only, no trimming -- distinct from
        ConvertTo-MarkerNormalizedText (which also strips per-line trailing
        whitespace and outer whitespace, unsuitable here because these
        helpers need the ORIGINAL interior content preserved for extraction
        and only need line-ending convention neutralized so `(?m)^...$`-style
        detection regexes cannot miss a match solely because the source body
        happens to use CRLF).
    .OUTPUTS
        [string]
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text -replace "`r`n", "`n") -replace "`r", "`n"
}

function script:Set-MarkerSpineScalarValue {
    <#
    .SYNOPSIS
        Bounded scalar splice (s5): sets an existing top-level scalar key's
        value inside a comment body's `<!-- frame-spine ... -->` block in
        place, or inserts it (immediately after `generated_at:` when
        present, otherwise at the top of the block) when the key is
        currently absent -- NEVER a full-body recompose, and never any edit
        outside the matched scalar line itself. Every other byte of the
        body, including the rest of the frame-spine block, is untouched.
    .DESCRIPTION
        -Name is restricted via -ValidateSet to the exact four keys legal
        per frame-spine-core.ps1:224's top-level key allowlist regex
        (`^(spine_schema_version|generated_at|coverage|slice_comment_id):`)
        -- this helper must never be used, now or later, to write a key
        outside that set; doing so would silently widen the allowlist by a
        side door instead of the allowlist regex itself, which this slice's
        non-goal explicitly forbids touching.
    .OUTPUTS
        [string] the updated comment body, or the original body unchanged
        when no `frame-spine` block is found.
    #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][ValidateSet('spine_schema_version', 'generated_at', 'coverage', 'slice_comment_id')][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $blockMatch = [regex]::Match($Body, '(?s)<!--\s*frame-spine\s*\r?\n(?<payload>.*?)-->')
    if (-not $blockMatch.Success) { return $Body }

    $payloadGroup = $blockMatch.Groups['payload']
    $payload = $payloadGroup.Value
    $scalarPattern = "(?m)^$Name\s*:.*?(?<eol>\r?\n|$)"
    $scalarMatch = [regex]::Match($payload, $scalarPattern)

    if ($scalarMatch.Success) {
        $eol = if ($scalarMatch.Groups['eol'].Success -and $scalarMatch.Groups['eol'].Value.Length -gt 0) { $scalarMatch.Groups['eol'].Value } else { "`n" }
        $newLine = "$Name`: $Value$eol"
        $newPayload = $payload.Substring(0, $scalarMatch.Index) + $newLine + $payload.Substring($scalarMatch.Index + $scalarMatch.Length)
    }
    else {
        $newLine = "$Name`: $Value`n"
        $genAtMatch = [regex]::Match($payload, '(?m)^generated_at\s*:.*?(\r?\n|$)')
        if ($genAtMatch.Success) {
            $insertPos = $genAtMatch.Index + $genAtMatch.Length
            $newPayload = $payload.Substring(0, $insertPos) + $newLine + $payload.Substring($insertPos)
        }
        else {
            $newPayload = $newLine + $payload
        }
    }

    return $Body.Substring(0, $payloadGroup.Index) + $newPayload + $Body.Substring($payloadGroup.Index + $payloadGroup.Length)
}

function script:Test-MarkerSiblingIdentity {
    <#
    .SYNOPSIS
        Shared "live-fetch a comment by id and confirm it carries the
        expected identity marker as a whole, standalone line" check (s10
        consolidation): byte-identical shape previously duplicated between
        script:Invoke-PlanIssueWriteBackPreserve's phase-containment-ledger-ref
        pointer live-check and its frame-spine slice_comment_id live-check.
    .DESCRIPTION
        Callers keep their own preconditions (e.g. confirming the candidate
        id string is numeric before casting to [long]) -- this helper only
        centralizes the GET + line-anchored marker match that both call
        sites performed identically.
    .OUTPUTS
        [bool] $true only when the comment exists and its LF-normalized body
        carries -ExpectedMarker as a whole, standalone line.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker
    )
    $siblingBody = Get-CommentBodyById -Owner $Owner -Repo $Repo -CommentId $CommentId
    return ($null -ne $siblingBody) -and
        [regex]::IsMatch((script:ConvertTo-MarkerLFBody -Text $siblingBody), '(?m)^[ \t]*' + [regex]::Escape($ExpectedMarker) + '[ \t]*$')
}

function script:Invoke-PlanIssueWriteBackPreserve {
    <#
    .SYNOPSIS
        's5 pre-write post-step for the plan-issue family (runs BEFORE
        hygiene/validator/write, inside Invoke-PersistMarkerWrite, and
        mutates the candidate -Body): on a re-persist, carries forward
        every artifact class from the migration-inventory's Section 2
        (.tmp/issue-893/migration-inventory.md, s1's authoritative
        preserve-set source -- not a guess) that the incoming payload omits
        but the existing canonical plan-issue comment carries.
    .DESCRIPTION
        No-op (nothing to preserve from) on a first persist -- Find-AllCommentsByExactMarker
        returns zero matches. Four artifact classes, each preserved only
        when the CANDIDATE lacks it and the EXISTING canonical comment (the
        earliest/lowest-REST-id match, matching Invoke-MarkerUpsertWrite's
        own canonical selection) has it:
          1. The `phase-containment-ledger-ref` pointer line -- live-checked
             (a real GET, not assumed) against its target sibling's own
             identity marker before being preserved; a stale or forged
             pointer is DROPPED (never carried forward), falling through to
             persist-phase-ledger-core.ps1's own M1 self-heal (which
             re-discovers a real existing sibling by identity marker when
             the pointer is missing).
          2. The frame-spine `slice_comment_id` scalar -- same live-check
             discipline against the `frame-slices-{ID}` sibling's identity
             marker, spliced back via script:Set-MarkerSpineScalarValue (a
             bounded scalar edit, never a full-body recompose). Absence of
             a value on the EXISTING comment is a valid legacy state and is
             never fabricated.
          3.-4. Legacy pre-863 content (only relevant when the existing
             comment carries NO ledger pointer at all -- the 811-D1 legacy
             population): the `judge-rulings` head and any `phase-containment`
             blocks living directly on the plan comment, and the
             `**Plan Stress-Test**` heading/section. These are direct
             content, not pointers, so no live-check applies -- they are
             appended verbatim when the candidate omits them entirely.
        Detection regexes run against an LF-normalized copy of the existing
        body (script:ConvertTo-MarkerLFBody) so a CRLF-bodied comment cannot
        cause a false "not present" miss; content appended into the
        candidate is joined with plain `n`, matching this file's own
        established LF-write convention (ConvertTo-MarkerNormalizedText).
    .OUTPUTS
        [PSCustomObject] with Body [string] (the possibly-merged candidate)
        and PreservedClasses [string[]] (human-readable names of every
        artifact class actually preserved, for the confirmation message --
        empty array, never $null, when nothing was preserved).
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )

    $preservedClasses = [System.Collections.Generic.List[string]]::new()
    # No extra @() wrap: Find-AllCommentsByExactMarker's own contract already
    # guarantees array identity via its internal `return , @(...)` (see that
    # function's own .OUTPUTS doc) -- wrapping its result in a second @()
    # here would double-wrap a single-element array output into a 1-element
    # array WHOSE element is the original array, corrupting .Count and
    # element access. Every other caller in this file (e.g.
    # Invoke-MarkerUpsertWrite) assigns the return value directly for the
    # same reason.
    $existing = Find-AllCommentsByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $Number -Marker $Marker
    if ($existing.Count -eq 0) {
        return [PSCustomObject]@{ Body = $Body; PreservedClasses = [string[]]@() }
    }

    # Canonical = earliest (lowest REST id) match -- same selector
    # Invoke-MarkerUpsertWrite itself uses for the upsert comparison target.
    $existingBody = script:ConvertTo-MarkerLFBody -Text $existing[0].Body
    $mergedBody = $Body

    # --- 1. phase-containment-ledger-ref pointer (live-checked). ---
    $pointerPattern = '(?m)^[ \t]*<!--\s*phase-containment-ledger-ref:\s*(?<id>\d+)\s*-->[ \t]*$'
    $pointerMatch = [regex]::Match($existingBody, $pointerPattern)
    $candidateHasPointer = [regex]::IsMatch((script:ConvertTo-MarkerLFBody -Text $mergedBody), $pointerPattern)
    if ($pointerMatch.Success -and -not $candidateHasPointer) {
        $siblingId = [long]$pointerMatch.Groups['id'].Value
        $expectedSiblingMarker = "<!-- phase-containment-ledger-$Number -->"
        $siblingValid = script:Test-MarkerSiblingIdentity -Owner $Owner -Repo $Repo -CommentId $siblingId -ExpectedMarker $expectedSiblingMarker
        if ($siblingValid) {
            $mergedBody = Set-PointerLineAfterMarker -Body $mergedBody -Marker $Marker -PointerLine "<!-- phase-containment-ledger-ref: $siblingId -->"
            $preservedClasses.Add('phase-containment-ledger-ref pointer') | Out-Null
        }
        # else: stale/forged pointer -- DROP it; fall through to
        # persist-phase-ledger-core.ps1's own M1 self-heal on its next run.
    }

    # --- 2. frame-spine slice_comment_id scalar (live-checked). ---
    $existingSpineBlock = Get-FSCSpineBlock -CommentBody $existingBody
    if ($null -ne $existingSpineBlock) {
        $existingSliceCommentId = script:Get-FSCScalarValue -Block $existingSpineBlock -Name 'slice_comment_id'
        if (-not [string]::IsNullOrWhiteSpace($existingSliceCommentId)) {
            $candidateSpineBlock = Get-FSCSpineBlock -CommentBody (script:ConvertTo-MarkerLFBody -Text $mergedBody)
            $candidateSliceCommentId = $null
            if ($null -ne $candidateSpineBlock) {
                $candidateSliceCommentId = script:Get-FSCScalarValue -Block $candidateSpineBlock -Name 'slice_comment_id'
            }
            if ($null -ne $candidateSpineBlock -and [string]::IsNullOrWhiteSpace($candidateSliceCommentId)) {
                $expectedSiblingMarker = "<!-- frame-slices-$Number -->"
                $siblingValid = $false
                if ($existingSliceCommentId -match '^\d+$') {
                    $siblingValid = script:Test-MarkerSiblingIdentity -Owner $Owner -Repo $Repo -CommentId ([long]$existingSliceCommentId) -ExpectedMarker $expectedSiblingMarker
                }
                if ($siblingValid) {
                    $mergedBody = script:Set-MarkerSpineScalarValue -Body $mergedBody -Name 'slice_comment_id' -Value $existingSliceCommentId
                    $preservedClasses.Add('slice_comment_id (frame-spine)') | Out-Null
                }
                # else: stale/forged slice_comment_id -- DROP it; the
                # frame-slices post-step's own spine-splice self-heals this
                # on the next frame-slices persist.
            }
        }
        # else: existing comment genuinely has no slice_comment_id (a valid
        # legacy state) -- never fabricated.
    }

    # --- 3.-4. Legacy pre-863 content: only when the EXISTING comment
    # carries no ledger pointer at all (811-D1 legacy population). ---
    $existingHasLedgerPointer = [regex]::IsMatch($existingBody, $pointerPattern)
    if (-not $existingHasLedgerPointer) {
        $legacyJudgeMatch = [regex]::Match($existingBody, '(?s)^[ \t]*<!--\s*judge-rulings.*?-->', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $candidateHasJudge = [regex]::IsMatch((script:ConvertTo-MarkerLFBody -Text $mergedBody), '(?m)^[ \t]*<!--\s*judge-rulings')
        if ($legacyJudgeMatch.Success -and -not $candidateHasJudge) {
            $mergedBody = $mergedBody.TrimEnd() + "`n`n" + $legacyJudgeMatch.Value.Trim()
            $preservedClasses.Add('legacy judge-rulings head') | Out-Null
        }

        $legacyContainmentMatches = [regex]::Matches($existingBody, '(?s)<!--\s*phase-containment-[A-Za-z0-9_-]+\s*-->.*?<!--\s*/phase-containment-[A-Za-z0-9_-]+\s*-->')
        $candidateHasContainment = [regex]::IsMatch((script:ConvertTo-MarkerLFBody -Text $mergedBody), '<!--\s*phase-containment-[A-Za-z0-9_-]+\s*-->')
        if ($legacyContainmentMatches.Count -gt 0 -and -not $candidateHasContainment) {
            $blockText = (@($legacyContainmentMatches | ForEach-Object { $_.Value.Trim() })) -join "`n`n"
            $mergedBody = $mergedBody.TrimEnd() + "`n`n" + $blockText
            $preservedClasses.Add('legacy phase-containment blocks') | Out-Null
        }
    }

    # --- The **Plan Stress-Test** heading/section (writer rule 8: the
    # heading literal is load-bearing -- do not let it drift). ---
    $stressTestPattern = '(?ms)^\*\*Plan Stress-Test\*\*.*?(?=^\*\*[A-Za-z]|\z)'
    $stressTestMatch = [regex]::Match($existingBody, $stressTestPattern)
    $candidateHasStressTestHeading = [regex]::IsMatch((script:ConvertTo-MarkerLFBody -Text $mergedBody), '(?m)^\*\*Plan Stress-Test\*\*')
    if ($stressTestMatch.Success -and -not $candidateHasStressTestHeading) {
        $mergedBody = $mergedBody.TrimEnd() + "`n`n" + $stressTestMatch.Value.Trim()
        $preservedClasses.Add('**Plan Stress-Test** heading/section') | Out-Null
    }

    return [PSCustomObject]@{ Body = $mergedBody; PreservedClasses = [string[]]$preservedClasses.ToArray() }
}

function script:Invoke-FrameSlicesSpineSplice {
    <#
    .SYNOPSIS
        's5 post-write post-step for the frame-slices family (runs AFTER a
        successful write, inside Invoke-PersistMarkerWrite): splices the
        just-written frame-slices sibling's own comment id back onto the
        plan comment's frame-spine block as slice_comment_id.
    .DESCRIPTION
        Marker-identity precondition: refuses when the issue carries no
        comment matching `<!-- plan-issue-{Number} -->` (never guesses a
        plan comment by any other selector). Generation-equality guard:
        refuses when the plan's frame-spine `generated_at` does not
        EQUAL -SiblingBody's own `frame-slices-generated-at` stamp (a
        stale-generation sibling is refused, not silently spliced in) --
        mere presence of a stamp is not sufficient. No-op when the plan
        already carries the correct slice_comment_id. Otherwise, performs a
        TARGETED SCALAR SPLICE (script:Set-MarkerSpineScalarValue) and
        writes it via Set-CommentBodyDirect, which already performs its own
        post-write verify GET -- no separate Test-MarkerReadBack call here,
        matching persist-phase-ledger-core.ps1's own established splice
        convention for its analogous pointer/block writes.
    .OUTPUTS
        [PSCustomObject] with Success [bool], Reason [string or $null], and
        Action [string or $null] -- one of 'no-op' or 'spliced' when
        Success=$true.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][long]$SiblingCommentId,
        [Parameter(Mandatory)][string]$SiblingBody
    )

    $planMarker = "<!-- plan-issue-$Number -->"
    # See script:Invoke-PlanIssueWriteBackPreserve's identical comment: no
    # extra @() wrap around Find-AllCommentsByExactMarker's own
    # array-identity-preserving return.
    $planMatches = Find-AllCommentsByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $Number -Marker $planMarker
    if ($planMatches.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Reason = "frame-slices spine-splice REFUSED: no comment carrying marker '$planMarker' found on issue $Number"; Action = $null }
    }
    # Canonical = earliest match, matching this file's other upsert-target selectors.
    $planComment = $planMatches[0]

    $planSpineBlock = Get-FSCSpineBlock -CommentBody $planComment.Body
    if ($null -eq $planSpineBlock) {
        return [PSCustomObject]@{ Success = $false; Reason = "frame-slices spine-splice REFUSED: plan comment $($planComment.Id) carries no frame-spine block"; Action = $null }
    }
    $planGeneratedAt = script:Get-FSCScalarValue -Block $planSpineBlock -Name 'generated_at'

    $siblingGeneratedAtMatch = [regex]::Match($SiblingBody, '<!--\s*frame-slices-generated-at\s*:\s*(?<value>.*?)\s*-->')
    $siblingGeneratedAt = if ($siblingGeneratedAtMatch.Success) { $siblingGeneratedAtMatch.Groups['value'].Value } else { $null }

    if ([string]::IsNullOrWhiteSpace($planGeneratedAt) -or [string]::IsNullOrWhiteSpace($siblingGeneratedAt) -or $planGeneratedAt -ne $siblingGeneratedAt) {
        return [PSCustomObject]@{ Success = $false; Reason = "frame-slices spine-splice REFUSED: generated_at mismatch (plan spine='$planGeneratedAt', sibling stamp='$siblingGeneratedAt') -- refusing to splice a stale-generation slice_comment_id"; Action = $null }
    }

    $existingSliceCommentId = script:Get-FSCScalarValue -Block $planSpineBlock -Name 'slice_comment_id'
    if ($existingSliceCommentId -eq "$SiblingCommentId") {
        return [PSCustomObject]@{ Success = $true; Reason = $null; Action = 'no-op' }
    }

    $splicedBody = script:Set-MarkerSpineScalarValue -Body $planComment.Body -Name 'slice_comment_id' -Value "$SiblingCommentId"
    $writeResult = Set-CommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $planComment.Id -NewBody $splicedBody
    if (-not $writeResult.Success) {
        return [PSCustomObject]@{ Success = $false; Reason = "frame-slices spine-splice: failed to write slice_comment_id onto plan comment $($planComment.Id): $($writeResult.Reason)"; Action = $null }
    }
    return [PSCustomObject]@{ Success = $true; Reason = $null; Action = 'spliced' }
}

# ---------------------------------------------------------------------------
# Write shapes.
# ---------------------------------------------------------------------------

function script:Invoke-MarkerCreateComment {
    <#
    .SYNOPSIS
        Shared create-and-verify sequence (s10 consolidation): POSTs a new
        comment via New-MarkerComment, extracts its numeric REST id, and
        read-back-verifies it via script:Test-MarkerReadBack -- byte-
        identical logic previously duplicated between
        script:Invoke-MarkerPostNewWrite's fresh-post path and
        script:Invoke-MarkerUpsertWrite's first-persist (zero-match) path.
    .DESCRIPTION
        -Action names the caller's verb ('posted' for post-new,
        'created' for upsert's first persist) so each write shape's own
        Action/Confirmation text stays exactly what it was before this
        consolidation, while the create+verify mechanics -- and every
        failure-message wording -- are shared and can no longer drift
        between the two write shapes.
    .OUTPUTS
        [PSCustomObject] Success [bool], Family [string], CommentId
        [long or $null], Action [string or $null], Confirmation
        [string or $null], Reason [string or $null] -- the same result
        shape every write-shape function already returns.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][ValidateSet('issue', 'pr')][string]$Type,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Action
    )
    $postResult = New-MarkerComment -Type $Type -Owner $Owner -Repo $Repo -Number $Number -Body $Body
    if ($null -eq $postResult) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "New-MarkerComment failed to create the comment for family '$Family'" }
    }
    $newId = Get-CommentIdFromUrl -Url $postResult
    if ($null -eq $newId) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "Could not extract a numeric comment id from the created comment's url '$postResult' for family '$Family'" }
    }

    try {
        $null = script:Test-MarkerReadBack -Owner $Owner -Repo $Repo -CommentId $newId -ExpectedBody $Body
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $newId; Action = $null; Confirmation = $null; Reason = $_.Exception.Message }
    }

    $confirmation = "persist-marker-core: family '$Family' comment $newId $Action"
    Write-Host $confirmation
    return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $newId; Action = $Action; Confirmation = $confirmation; Reason = $null }
}

function script:Invoke-MarkerPostNewWrite {
    <#
    .SYNOPSIS
        post-new write shape: compares the candidate against the LATEST
        (highest REST id) marker match only, per Find-AllCommentsByExactMarker's
        ascending-id ordering; a candidate matching a superseded, non-latest
        match still posts.
    .DESCRIPTION
        Author-blind risk (accepted, per this slice's requirement contract
        rule 7): Find-AllCommentsByExactMarker's matches carry no comment
        author -- the unified REST comments endpoint response this function
        consumes is not filtered by author anywhere in this call chain. A
        same-marker comment posted by ANY author (not just this script's own
        invoking identity) counts as "the latest match" for the idempotency
        comparison above. Restricting candidates to the invoking identity
        would require threading an expected-author identity through the
        registry and every call site -- out of scope for this slice; this
        comment records it as an accepted risk rather than silently ignoring
        it (a design-challenge-sustained finding, disposition: incorporate
        as accepted risk, s3 author policy).
    .OUTPUTS
        [PSCustomObject] Success [bool], Family [string], CommentId
        [long or $null], Action ['posted'|'no-op'|$null], Confirmation
        [string or $null], Reason [string or $null].
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][ValidateSet('issue', 'pr')][string]$Type,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )

    $existing = Find-AllCommentsByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $Number -Marker $Marker
    if ($existing.Count -gt 0) {
        # Ascending REST-id order (Find-AllCommentsByExactMarker's own
        # contract) -- the last element is the latest (highest id) match.
        # See this function's own .DESCRIPTION for the author-blind risk
        # this selector accepts.
        $latest = $existing[-1]
        $normalizedExisting = ConvertTo-MarkerNormalizedText -Text $latest.Body
        $normalizedCandidate = ConvertTo-MarkerNormalizedText -Text $Body
        if ($normalizedExisting -eq $normalizedCandidate) {
            $confirmation = "persist-marker-core: family '$Family' comment $($latest.Id) no-op (already matches latest)"
            Write-Host $confirmation
            return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $latest.Id; Action = 'no-op'; Confirmation = $confirmation; Reason = $null }
        }
    }

    return script:Invoke-MarkerCreateComment -Owner $Owner -Repo $Repo -Family $Family -Type $Type -Number $Number -Body $Body -Action 'posted'
}

function script:Invoke-MarkerUpsertWrite {
    <#
    .SYNOPSIS
        upsert write shape: selects the CANONICAL match (earliest / lowest
        REST id) for comparison, and re-finds that canonical target
        immediately before PATCH -- never --edit-last, always a fresh
        numeric REST comment id.
    .OUTPUTS
        [PSCustomObject] Success [bool], Family [string], CommentId
        [long or $null], Action ['created'|'updated'|'no-op'|$null],
        Confirmation [string or $null], Reason [string or $null].
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][ValidateSet('issue', 'pr')][string]$Type,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )

    $existing = Find-AllCommentsByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $Number -Marker $Marker
    if ($existing.Count -eq 0) {
        return script:Invoke-MarkerCreateComment -Owner $Owner -Repo $Repo -Family $Family -Type $Type -Number $Number -Body $Body -Action 'created'
    }

    # Canonical target = earliest (lowest REST id) match -- ascending order
    # per Find-AllCommentsByExactMarker's own contract, so [0] is earliest.
    $canonical = $existing[0]
    $normalizedExisting = ConvertTo-MarkerNormalizedText -Text $canonical.Body
    $normalizedCandidate = ConvertTo-MarkerNormalizedText -Text $Body
    if ($normalizedExisting -eq $normalizedCandidate) {
        $confirmation = "persist-marker-core: family '$Family' comment $($canonical.Id) no-op (already matches canonical)"
        Write-Host $confirmation
        return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $canonical.Id; Action = 'no-op'; Confirmation = $confirmation; Reason = $null }
    }

    # Re-find the canonical target immediately before PATCH -- never
    # --edit-last, always a fresh numeric REST comment id (893-D2
    # concurrency posture: single-writer assumption, pre-PATCH re-find,
    # residual race between this re-find and the PATCH below is an accepted
    # risk).
    $refound = Find-AllCommentsByExactMarker -Owner $Owner -Repo $Repo -IssueNumber $Number -Marker $Marker
    if ($refound.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $null; Action = $null; Confirmation = $null; Reason = "Canonical comment for family '$Family' disappeared between find and PATCH" }
    }
    $targetId = $refound[0].Id

    $patchResult = Set-CommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $targetId -NewBody $Body
    if (-not $patchResult.Success) {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $targetId; Action = $null; Confirmation = $null; Reason = $patchResult.Reason }
    }

    try {
        $null = script:Test-MarkerReadBack -Owner $Owner -Repo $Repo -CommentId $targetId -ExpectedBody $Body
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $targetId; Action = $null; Confirmation = $null; Reason = $_.Exception.Message }
    }

    $confirmation = "persist-marker-core: family '$Family' comment $targetId updated"
    Write-Host $confirmation
    return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $targetId; Action = 'updated'; Confirmation = $confirmation; Reason = $null }
}

# ---------------------------------------------------------------------------
# Scratch-root bounding + size cap (s6 requirement contract, ac-refs
# AC4/AC12).
# ---------------------------------------------------------------------------

# GitHub's REST comment body cap (issues/PRs). Refused pre-write with a
# diagnosable message (see script:Test-MarkerCandidatePreflight) so an
# oversized composed candidate never surfaces as a raw transport/HTTP error
# from `gh`.
$script:MarkerBodySizeCap = 65536

function script:Get-MarkerScratchRoot {
    <#
    .SYNOPSIS
        Resolves the CONSUMER repo's scratch root ('.tmp/', the
        .gitignore-carved scratch convention -- see .gitignore's '.tmp/'
        entries) from the live CWD via git-rev-parse with a CWD fallback,
        mirroring session-cleanup-detector.ps1's identical
        resolve-from-CWD pattern.
    .DESCRIPTION
        Deliberately never $PSScriptRoot: that resolves to THIS PLUGIN's own
        bundled tree (see persist-phase-ledger.ps1's header for why
        $PSScriptRoot is the right anchor for dot-sourcing bundled libs and
        the wrong one here) -- the scratch root belongs to whatever consumer
        repo the caller's session is actually operating in, not the plugin
        install.
    .OUTPUTS
        [string] absolute path to '<repoRoot>/.tmp'. Does not require the
        directory to exist.
    #>
    $gitOutput = & git rev-parse --show-toplevel 2>$null
    $repoRoot = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitOutput)) {
        $gitOutput.Trim()
    }
    else {
        (Get-Location).Path
    }
    return (Join-Path $repoRoot '.tmp')
}

function Resolve-MarkerScratchBoundedPath {
    <#
    .SYNOPSIS
        Real path-containment check (893-s6 owner decision, security-
        critical -- this is what keeps the recommended
        `Bash(pwsh*persist-marker.ps1*)`-style allowlist entry safe rather
        than an arbitrary-file-read-to-public-comment primitive): resolves
        -Path via Resolve-Path (symlink-aware canonicalization; requires the
        target to exist -- every caller here needs to read the file's
        content anyway, so non-existence is itself a refusal) and checks
        segment-boundary containment inside the canonicalized -ScratchRoot.
    .DESCRIPTION
        Never a raw string-prefix test on the UNRESOLVED input -- that is
        spoofable both by relative-traversal payloads
        ('.tmp/../../secrets') and by same-string-prefix SIBLING
        directories ('.tmp-not-really/file') that a naive ".tmp" prefix
        check would wrongly admit. The trailing-separator comparison below
        (StartsWith($rootWithSep)) is what rejects the sibling-directory
        case even after both sides are canonicalized.
    .OUTPUTS
        [PSCustomObject] InBounds [bool], ResolvedPath [string or $null],
        Reason [string or $null] (populated only when InBounds=$false).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ScratchRoot
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return [PSCustomObject]@{ InBounds = $false; ResolvedPath = $null; Reason = "path does not exist: $(script:ConvertTo-MarkerRefusalEcho -Value $Path)" }
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $resolvedScratchRoot = [System.IO.Path]::GetFullPath($ScratchRoot).TrimEnd('/', '\')
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $rootWithSep = $resolvedScratchRoot + [System.IO.Path]::DirectorySeparatorChar
    $inBounds = $resolvedPath.Equals($resolvedScratchRoot, $comparison) -or $resolvedPath.StartsWith($rootWithSep, $comparison)
    if (-not $inBounds) {
        return [PSCustomObject]@{ InBounds = $false; ResolvedPath = $resolvedPath; Reason = "path resolves outside the scratch root '$resolvedScratchRoot': $(script:ConvertTo-MarkerRefusalEcho -Value $resolvedPath)" }
    }
    return [PSCustomObject]@{ InBounds = $true; ResolvedPath = $resolvedPath; Reason = $null }
}

function Read-MarkerScratchBoundedBodyFile {
    <#
    .SYNOPSIS
        Reads -BodyFile after confirming it resolves inside -ScratchRoot
        (Resolve-MarkerScratchBoundedPath). Refuses (never throws) on an
        out-of-bounds or missing path with a diagnosable message naming the
        offending path -- the size cap itself is enforced downstream by
        script:Test-MarkerCandidatePreflight (uniformly, for every write
        entry point, not only BodyFile-sourced ones).
    .OUTPUTS
        [PSCustomObject] Success [bool], Body [string or $null], Reason
        [string or $null].
    #>
    param(
        [Parameter(Mandatory)][string]$BodyFile,
        [Parameter(Mandatory)][string]$ScratchRoot
    )
    $bounded = Resolve-MarkerScratchBoundedPath -Path $BodyFile -ScratchRoot $ScratchRoot
    if (-not $bounded.InBounds) {
        return [PSCustomObject]@{ Success = $false; Body = $null; Reason = "persist-marker: REFUSED (-BodyFile out of bounds): $($bounded.Reason)" }
    }
    $body = Get-Content -LiteralPath $bounded.ResolvedPath -Raw -ErrorAction Stop
    if ($null -eq $body) { $body = '' }
    return [PSCustomObject]@{ Success = $true; Body = $body; Reason = $null }
}

function script:Resolve-MarkerFamilyRow {
    <#
    .SYNOPSIS
        Shared registry-lookup + surface-preflight helper (s10
        consolidation): looks up -Family in -Registry and validates
        -TargetSurface against the matched row's declared TargetSurface.
        Byte-identical logic previously duplicated between
        script:Test-MarkerCandidatePreflight and Invoke-PersistMarkerWrite
        (same unknown-family and surface-mismatch Detail message text in
        both) -- both callers now share this one lookup instead of two
        independently-maintained copies.
    .DESCRIPTION
        Invoke-PersistMarkerWrite still needs its OWN call to this helper
        (rather than only relying on Test-MarkerCandidatePreflight's later
        call) because it must read WriteShape/PostStep off the resolved row
        before the PostStep dispatch runs -- the PostStep can mutate the
        candidate Body, and Test-MarkerCandidatePreflight's own resolution
        happens afterward, against that TRUE final candidate. This helper
        does not change that two-call shape; it only removes the duplicated
        lookup/refusal logic each call site previously reimplemented.
    .OUTPUTS
        [PSCustomObject] with Row (the matched registry row, or $null) and
        Refusal (a script:New-MarkerRefusal result, or $null) -- exactly one
        of the two is non-null.
    #>
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][ValidateSet('issue', 'pull-request')][string]$TargetSurface,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Registry
    )
    $target = "$TargetSurface/$Number"
    $row = @($Registry | Where-Object { $_.Family -eq $Family })
    if ($row.Count -eq 0) {
        return [PSCustomObject]@{ Row = $null; Refusal = (script:New-MarkerRefusal -Family $Family -Target $target -Detail "unknown marker family '$Family' -- not present in the family registry") }
    }
    $familyRow = $row[0]
    if ($familyRow.TargetSurface -ne $TargetSurface) {
        return [PSCustomObject]@{ Row = $null; Refusal = (script:New-MarkerRefusal -Family $Family -Target $target -Detail "surface mismatch: registry declares '$($familyRow.TargetSurface)' but this write was targeted at '$TargetSurface'") }
    }
    return [PSCustomObject]@{ Row = $familyRow; Refusal = $null }
}

function script:Test-MarkerCandidatePreflight {
    <#
    .SYNOPSIS
        Network-free preflight (s6): registry lookup, surface-declaration
        match, the size-cap refusal, 893-D7 payload hygiene, and the
        family's ValidatorAdapter (if any) -- the checks
        Invoke-PersistMarkerWrite already runs before ever attempting a
        network write (s3/s4, size cap added s6).
    .DESCRIPTION
        Extracted so Invoke-PersistMarkerBurst's whole-manifest preflight
        can run the EXACT SAME validation a single write already runs, on
        every burst entry, without duplicating the logic and without also
        running the PostStep dispatch: 'plan-issue-write-back-preserve'
        performs its own live GET calls and is therefore NOT network-free,
        so it is deliberately excluded here. s6 scope: the whole-manifest
        preflight validates what s4's validator-adapter contract already
        guarantees is payload-only; a PostStep's live mutation stays a
        per-write, execution-time concern, exercised by the write itself
        (Invoke-PersistMarkerWrite), never predicted by this preflight.
    .OUTPUTS
        [PSCustomObject] a refusal result (script:New-MarkerRefusal shape),
        or $null when the candidate is clean.
    #>
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][ValidateSet('issue', 'pull-request')][string]$TargetSurface,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )
    $allRows = @(Get-MarkerFamilyRegistry)
    $resolved = script:Resolve-MarkerFamilyRow -Family $Family -TargetSurface $TargetSurface -Number $Number -Registry $allRows
    if ($null -ne $resolved.Refusal) {
        return $resolved.Refusal
    }
    $familyRow = $resolved.Row
    $target = "$TargetSurface/$Number"

    if ($Body.Length -gt $script:MarkerBodySizeCap) {
        return script:New-MarkerRefusal -Family $Family -Target $target -Detail "composed body is $($Body.Length) chars, exceeding GitHub's $($script:MarkerBodySizeCap)-char comment cap"
    }

    $hygieneDetail = script:Test-MarkerPayloadHygiene -Family $Family -Marker $Marker -Body $Body -Registry $allRows
    if ($null -ne $hygieneDetail) {
        return script:New-MarkerRefusal -Family $Family -Target $target -Detail $hygieneDetail
    }

    if (-not [string]::IsNullOrWhiteSpace($familyRow.ValidatorAdapter)) {
        $adapterRefusal = script:Invoke-MarkerValidatorAdapter -ValidatorAdapter $familyRow.ValidatorAdapter -Family $Family -Target $target -Marker $Marker -Body $Body -Number $Number
        if ($null -ne $adapterRefusal) {
            return $adapterRefusal
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Public dispatcher.
# ---------------------------------------------------------------------------

function Invoke-PersistMarkerWrite {
    <#
    .SYNOPSIS
        Looks up -Family in the family registry, preflights the declared
        -TargetSurface against the registry row's declared surface, runs
        893-D7 payload hygiene and the row's ValidatorAdapter (if any)
        against the marker-composed candidate, and -- only once all of that
        passes -- dispatches to the row's write shape (post-new or upsert).
        Every refusal (unknown family, surface mismatch, hygiene, or
        validator adapter) happens before any network write and returns
        Success=$false with a "persist-marker: REFUSED (...)"-shaped Reason
        (893-D6); see New-MarkerRefusal.
    .PARAMETER Family
        Registry key (Get-MarkerFamilyRegistry's Family field).
    .PARAMETER TargetSurface
        The CALLER's declared surface for -Number ('issue' or
        'pull-request'). Compared against the registry row's declared
        TargetSurface before any write -- see this file's header for why
        this must be a declared-vs-declared comparison rather than a live
        lookup.
    .PARAMETER Marker
        The exact marker line the composed -Body carries (used for the
        Find-AllCommentsByExactMarker search, the hygiene own-family check,
        and the sentinel-empty adapter). The caller composes both -Marker
        and -Body; this file never composes payload content.
    .PARAMETER Body
        The full comment body to write, already carrying -Marker -- i.e.
        the marker-COMPOSED CANDIDATE. This is what hygiene and every
        validator adapter validate; they never see a "raw payload" distinct
        from this. Never logged or echoed separately from the confirmation
        line (which names only family, comment id, and action -- not
        payload content) or a length-bounded refusal detail.
    .PARAMETER NoPreserve
        Escape hatch for the 'plan-issue-write-back-preserve' post-step
        (s5): when set, skips ALL write-back preservation for this call, so
        a maintainer can deliberately clear a bad pointer (or any other
        preserved artifact) instead of having it silently carried forward
        forever. No effect on any other family's PostStep.
    .OUTPUTS
        [PSCustomObject] Success [bool], Family [string], CommentId
        [long or $null], Action [string or $null], Confirmation
        [string or $null], Reason [string or $null] (populated only when
        Success=$false).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][ValidateSet('issue', 'pull-request')][string]$TargetSurface,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body,
        [switch]$NoPreserve
    )

    # Registry lookup + surface preflight -- see this file's header for why
    # this compares declared surfaces rather than performing a live lookup.
    $allRows = @(Get-MarkerFamilyRegistry)
    $resolved = script:Resolve-MarkerFamilyRow -Family $Family -TargetSurface $TargetSurface -Number $Number -Registry $allRows
    if ($null -ne $resolved.Refusal) {
        return $resolved.Refusal
    }
    $familyRow = $resolved.Row

    $target = "$TargetSurface/$Number"

    # s5 pre-write post-step: runs BEFORE hygiene/validator/write so both of
    # those see the TRUE final candidate, including anything this step
    # merges in. Only the plan-issue family's PostStep does anything here;
    # every other family's dispatch below is a no-op.
    $preservedArtifactClasses = [string[]]@()
    if ($familyRow.PostStep -eq 'plan-issue-write-back-preserve' -and -not $NoPreserve) {
        $preserveResult = script:Invoke-PlanIssueWriteBackPreserve -Owner $Owner -Repo $Repo -Number $Number -Marker $Marker -Body $Body
        $Body = $preserveResult.Body
        $preservedArtifactClasses = $preserveResult.PreservedClasses
    }

    # Size cap + 893-D7 payload hygiene + per-family validator adapter (s4
    # requirement contract; size cap added s6) -- s6 extracts this whole
    # network-free check sequence into script:Test-MarkerCandidatePreflight
    # so Invoke-PersistMarkerBurst's whole-manifest preflight can run the
    # EXACT SAME checks a single write already runs, on every burst entry,
    # before any network write. Behavior here is unchanged from s3/s4: every
    # check still runs unconditionally, after the PostStep above (so it sees
    # the TRUE final candidate, including anything write-back-preserve
    # merged in), and a refusal is still fail-closed.
    $preflightRefusal = script:Test-MarkerCandidatePreflight -Family $Family -TargetSurface $TargetSurface -Number $Number -Marker $Marker -Body $Body
    if ($null -ne $preflightRefusal) {
        return $preflightRefusal
    }

    $ghType = if ($TargetSurface -eq 'pull-request') { 'pr' } else { 'issue' }

    $writeResult = switch ($familyRow.WriteShape) {
        'post-new' { script:Invoke-MarkerPostNewWrite -Owner $Owner -Repo $Repo -Family $Family -Type $ghType -Number $Number -Marker $Marker -Body $Body }
        'upsert' { script:Invoke-MarkerUpsertWrite -Owner $Owner -Repo $Repo -Family $Family -Type $ghType -Number $Number -Marker $Marker -Body $Body }
        default { script:New-MarkerRefusal -Family $Family -Target $target -Detail "unknown write shape '$($familyRow.WriteShape)' for family '$Family'" }
    }

    # s5 post-write post-step: runs AFTER a successful write only. Only the
    # frame-slices family's PostStep does anything here. A splice-back
    # failure is reported loud -- it flips the overall result to
    # Success=$false even though the sibling write itself already landed
    # (mandatory, not best-effort, per this file's header note).
    if ($writeResult.Success -and $familyRow.PostStep -eq 'frame-slices-spine-splice') {
        $spliceResult = script:Invoke-FrameSlicesSpineSplice -Owner $Owner -Repo $Repo -Number $Number -SiblingCommentId $writeResult.CommentId -SiblingBody $Body
        if (-not $spliceResult.Success) {
            return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $writeResult.CommentId; Action = $writeResult.Action; Confirmation = $writeResult.Confirmation; Reason = $spliceResult.Reason }
        }
    }

    # Name every individual preserved artifact class in the confirmation
    # output (s5 requirement contract validation rule) rather than leaving
    # a silent preserve invisible to whoever reads the confirmation.
    if ($preservedArtifactClasses.Count -gt 0 -and $writeResult.Success -and $null -ne $writeResult.Confirmation) {
        $writeResult.Confirmation = "$($writeResult.Confirmation) (preserved: $($preservedArtifactClasses -join ', '))"
    }

    return $writeResult
}

# ---------------------------------------------------------------------------
# Burst dispatch (s6 requirement contract, ac-refs AC4/AC12).
# ---------------------------------------------------------------------------

function Invoke-PersistMarkerBurst {
    <#
    .SYNOPSIS
        Ordered multi-write burst. -Entries is an array of PSCustomObjects
        each carrying Family/Number/TargetSurface/Marker/Body/NoPreserve --
        Body already resolved from a scratch-bounded bodyFile by the caller
        (see Invoke-PersistMarkerBurstFromManifest; this function itself
        never reads a manifest file or a bodyFile).
    .DESCRIPTION
        WHOLE-MANIFEST validation preflight (script:Test-MarkerCandidatePreflight,
        run against every entry in order) happens BEFORE the first network
        write -- a manifest containing ANY invalid entry writes NOTHING at
        all. After preflight passes for every entry, executes writes in
        manifest order via Invoke-PersistMarkerWrite, halting on the first
        execution failure (a later entry is never attempted once an earlier
        one fails).

        Re-run convergence after a mid-burst halt is NOT separately tracked
        here -- it relies entirely on Invoke-PersistMarkerWrite's own s3
        write-shape idempotency: re-invoking this function with the SAME
        entries after a halt reports every already-landed entry as a no-op
        (Invoke-PersistMarkerWrite's own post-new/upsert comparison against
        the existing latest/canonical match) rather than posting a
        duplicate, so execution simply resumes past what already landed and
        retries what did not.
    .OUTPUTS
        [PSCustomObject] Success [bool], Reason [string or $null], Results
        [object[]] (one per ATTEMPTED entry, Invoke-PersistMarkerWrite's own
        result shape -- empty when preflight refused the whole manifest),
        Artifacts [ordered dictionary] keyed 'entry-1'..'entry-N' (1-based,
        manifest order), each value one of 'not-attempted' (preflight
        refused the whole manifest, or execution halted before this entry
        was reached), 'landed' (write succeeded), 'failed' (write attempted
        and failed) -- mirrors persist-phase-ledger-core.ps1's own
        landed/not-attempted artifact-manifest shape
        (script:New-PPLPersistPhaseLedgerArtifactManifest).
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries
    )

    $artifacts = [ordered]@{}
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $artifacts["entry-$($i + 1)"] = 'not-attempted'
    }

    if ($Entries.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Reason = 'persist-marker: REFUSED (burst manifest empty): manifest carries zero entries'; Results = [object[]]@(); Artifacts = $artifacts }
    }

    # --- Whole-manifest preflight: network-free, zero writes on any refusal. ---
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $entry = $Entries[$i]
        $refusal = script:Test-MarkerCandidatePreflight -Family $entry.Family -TargetSurface $entry.TargetSurface -Number $entry.Number -Marker $entry.Marker -Body $entry.Body
        if ($null -ne $refusal) {
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (burst preflight, entry $($i + 1) of $($Entries.Count), family '$($entry.Family)'): $($refusal.Reason)"; Results = [object[]]@(); Artifacts = $artifacts }
        }
    }

    # --- Execution: manifest order, halt-on-first-failure. ---
    $results = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $entry = $Entries[$i]
        $noPreserve = [bool]$entry.NoPreserve
        $writeResult = Invoke-PersistMarkerWrite -Family $entry.Family -Owner $Owner -Repo $Repo -Number $entry.Number `
            -TargetSurface $entry.TargetSurface -Marker $entry.Marker -Body $entry.Body -NoPreserve:$noPreserve
        $results.Add($writeResult)
        if ($writeResult.Success) {
            $artifacts["entry-$($i + 1)"] = 'landed'
        }
        else {
            $artifacts["entry-$($i + 1)"] = 'failed'
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: burst halted at entry $($i + 1) of $($Entries.Count), family '$($entry.Family)': $($writeResult.Reason)"; Results = [object[]]$results.ToArray(); Artifacts = $artifacts }
        }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null; Results = [object[]]$results.ToArray(); Artifacts = $artifacts }
}

function Invoke-PersistMarkerBurstFromManifest {
    <#
    .SYNOPSIS
        Public s6 entry point for -BurstManifest: reads and parses the JSON
        manifest file at -ManifestPath, resolves and scratch-bounds every
        entry's bodyFile, then delegates to Invoke-PersistMarkerBurst for
        the whole-manifest preflight and ordered execution.
    .DESCRIPTION
        A malformed manifest (unparseable JSON, a missing required field,
        an empty entry list) is refused HERE -- naming the manifest path
        and, for a per-entry problem, the 1-based entry index and the
        specific offending field -- before any bodyFile is even opened.
        Required fields per entry: family, number, targetSurface, marker,
        bodyFile; noPreserve is optional (defaults to $false).

        -ScratchRoot defaults to script:Get-MarkerScratchRoot's live-CWD
        resolution; callers (chiefly Pester) may override it to bind
        entries to an isolated test directory instead of the real
        '<repoRoot>/.tmp'.
    .OUTPUTS
        [PSCustomObject] see Invoke-PersistMarkerBurst's .OUTPUTS; a
        manifest-level refusal (before Invoke-PersistMarkerBurst is ever
        called) returns the same shape with Results=@() and
        Artifacts=[ordered]@{}.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$ScratchRoot = (script:Get-MarkerScratchRoot)
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (burst manifest not found): $(script:ConvertTo-MarkerRefusalEcho -Value $ManifestPath)"; Results = [object[]]@(); Artifacts = [ordered]@{} }
    }

    $rawManifest = Get-Content -LiteralPath $ManifestPath -Raw
    try {
        $parsed = $rawManifest | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $echoed = script:ConvertTo-MarkerRefusalEcho -Value $_.Exception.Message
        return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$ManifestPath'): not parseable JSON -- $echoed"; Results = [object[]]@(); Artifacts = [ordered]@{} }
    }

    $rawEntries = @($parsed)
    if ($rawEntries.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$ManifestPath'): manifest carries zero entries"; Results = [object[]]@(); Artifacts = [ordered]@{} }
    }

    $requiredFields = @('family', 'number', 'targetSurface', 'marker', 'bodyFile')
    $resolvedEntries = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $rawEntries.Count; $i++) {
        $entryIndex = $i + 1
        $rawEntry = $rawEntries[$i]
        foreach ($field in $requiredFields) {
            $value = $rawEntry.$field
            if ($null -eq $value -or ([string]$value).Trim().Length -eq 0) {
                return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$ManifestPath', entry $entryIndex): missing required field '$field'"; Results = [object[]]@(); Artifacts = [ordered]@{} }
            }
        }

        try {
            $number = [int]$rawEntry.number
        }
        catch {
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$ManifestPath', entry $entryIndex): field 'number' is not a valid integer ($(script:ConvertTo-MarkerRefusalEcho -Value ([string]$rawEntry.number)))"; Results = [object[]]@(); Artifacts = [ordered]@{} }
        }

        $bodyFileResult = Read-MarkerScratchBoundedBodyFile -BodyFile ([string]$rawEntry.bodyFile) -ScratchRoot $ScratchRoot
        if (-not $bodyFileResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (manifest '$ManifestPath', entry $entryIndex, family '$($rawEntry.family)'): $($bodyFileResult.Reason)"; Results = [object[]]@(); Artifacts = [ordered]@{} }
        }

        $resolvedEntries.Add([PSCustomObject]@{
                Family        = [string]$rawEntry.family
                Number        = $number
                TargetSurface = [string]$rawEntry.targetSurface
                Marker        = [string]$rawEntry.marker
                Body          = $bodyFileResult.Body
                NoPreserve    = [bool]$rawEntry.noPreserve
            }) | Out-Null
    }

    return Invoke-PersistMarkerBurst -Owner $Owner -Repo $Repo -Entries ([object[]]$resolvedEntries.ToArray())
}
