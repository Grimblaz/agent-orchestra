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
        INVOCATION scope. This helper itself stays network-free -- it never
        runs the 'plan-issue-write-back-preserve' PostStep internally.
        M11 fix (issue #893 s11): Invoke-PersistMarkerBurst's own preflight
        LOOP (not this helper) now runs script:Invoke-PlanIssueWriteBackPreserve
        itself (a live-read-only step -- it only performs GETs, never a
        write) for any plan-issue-family entry BEFORE calling this helper,
        and validates the PREVIEW-MERGED body rather than the raw entry
        body -- mirroring exactly what Invoke-PersistMarkerWrite itself does
        (PostStep merge, then preflight, in that order) so a preserve-
        triggered size/hygiene violation surfaces at whole-manifest-preflight
        time, before any earlier burst entry has been allowed to land,
        instead of only at execution time after earlier entries already
        wrote. Residual, accepted risk: if an EARLIER entry in the SAME
        burst mutates state this preview's live GET depends on (e.g. an
        earlier frame-slices entry creating the very sibling a later
        plan-issue entry's pointer-preserve check reads), the preview merge
        -- computed before any entry in the burst has written -- can
        diverge from what the real execution-time merge later observes.
        Invoke-PersistMarkerWrite's own preflight call always re-validates
        the TRUE final candidate at write time regardless of this preview,
        so a preview/execution divergence can at most produce a burst-
        preflight false PASS here (execution then still fails safely later,
        exactly as before this fix) -- it can never produce a false
        REFUSAL of an otherwise-valid burst FROM STATE DIVERGENCE.
        P10 fix (issue #893 s11 post-fix): a SEPARATE failure mode --
        a TRANSIENT transport error (network blip, rate limit) inside this
        preview's own live sibling-identity GETs -- WAS directly reachable
        and DID produce a false preflight REFUSAL (script:Test-MarkerSiblingIdentity,
        M19, throws rather than returning a confirmed-absent $false on a
        transport failure, and the preflight loop's try/catch turned that
        throw into a hard refusal). The preflight loop now catches that
        specific throw and proceeds with the unmerged candidate body
        instead, deferring to Invoke-PersistMarkerWrite's own
        execution-time re-check -- see the preflight loop's own comment for
        the narrow catch. With that fix in place, the "never a false
        REFUSAL" claim above holds again for both failure modes.
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
            # M9 fix (issue #893 s11): was 'upsert' -- real behavioral drift
            # against skills/session-memory-contract/references/handoff-markers.md:15,
            # which documents this family as post-new (append-only
            # completion-history, mirroring experience-owner-complete and
            # review-judge-produced). Confirmed against Solution-Designer's
            # own design-phase-complete usage
            # (agents/Solution-Designer.agent.md): the completion marker is
            # posted once per phase completion and persist-phase-ledger.ps1
            # -Mode design appends phase-containment blocks directly onto
            # the caller-supplied -DesignCommentId afterward -- nothing in
            # that flow re-persists/PATCHes the completion marker itself, so
            # post-new (never overwriting prior history) is the behavior the
            # design actually intends; upsert was the bug.
            WriteShape        = 'post-new'
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

# M22 fix (issue #893 s11): a SEPARATE, larger cap for a narrow class of
# values this file did not author -- a validator LIBRARY's own already-
# bounded, reviewed diagnostic prose (e.g. Read-EngagementRecords' or
# review-dispositions-validator-core.ps1's own formatted finding messages).
# Prior to this fix these sites were deliberately left completely uncapped
# (per this file's own now-superseded rationale that capping them at the
# standard 80-char field-value cap would truncate useful diagnostic
# legibility); the s11 prosecution/defense correctly identified that as a
# real 893-D6 inconsistency -- EVERY echoed value must be length-bounded,
# full stop. This wider cap (per the original s4 contract's own suggested
# resolution) keeps that legibility while still guaranteeing no site can
# dump an unbounded value verbatim.
$script:MarkerLibraryMessageEchoCap = 400

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

function script:ConvertTo-MarkerLibraryMessageEcho {
    <#
    .SYNOPSIS
        M22 fix (issue #893 s11): length-bounds a validator LIBRARY's own
        already-formatted diagnostic message before it is echoed inside a
        refusal, using the wider $script:MarkerLibraryMessageEchoCap (400
        chars) rather than the standard $script:MarkerRefusalEchoCap (80
        chars) -- long enough to preserve a reviewed library message's
        legibility, but never unbounded.
    .OUTPUTS
        [string]
    #>
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '<null>' }
    if ($Value.Length -le $script:MarkerLibraryMessageEchoCap) { return $Value }
    $overflow = $Value.Length - $script:MarkerLibraryMessageEchoCap
    return "$($Value.Substring(0, $script:MarkerLibraryMessageEchoCap))...(+$overflow more chars, truncated)"
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
    # M15 fix (issue #893 s11), REVERTED at s11 post-fix P1 (issue #893):
    # M15 widened this own-family anchor to also absorb `\p{Cf}` (Unicode
    # "format" category -- zero-width space U+200B, BOM/ZWNBSP U+FEFF,
    # etc.), not just `\s`. That widening was NOT mirrored onto
    # Get-MarkerWholeLinePattern (.github/scripts/lib/marker-transport-core.ps1,
    # the transport finder every write/read path actually uses to locate a
    # posted marker), which still anchors on `^\s*` only. The mismatch let a
    # ZWSP-prefixed marker pass THIS hygiene check as "present" while
    # remaining unfindable by the finder -- unbounded duplicate accretion on
    # every subsequent write, reopening M3's exact defect for that character
    # class. This anchor must stay byte-symmetric with the finder, so it
    # reverts to `^\s*`. The `\p{Cf}` widening remains correct and stays on
    # script:ConvertTo-MarkerFamilyLineStartPattern below (the cross-family
    # detector), a different use case that never needs to match what the
    # transport finder finds -- it only needs to catch a decoy marker before
    # it gets written, not locate an already-written one.
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
        [string] a regex pattern (multiline, '(?m)^[\s\p{Cf}]*' anchored).
    #>
    param([Parameter(Mandatory)][string]$MarkerTemplate)
    $escaped = [regex]::Escape($MarkerTemplate)
    # [regex]::Escape escapes the opening '{' (quantifier-significant in
    # .NET regex) but leaves a lone '}' unescaped (not special outside a
    # quantifier) -- so the escaped placeholder token reads '\{ID}', never
    # '\{ID\}'. Matching only the opening escape here is deliberate, not a
    # typo.
    $withWildcards = $escaped -replace '\\\{[A-Za-z]+\}', '[\w-]+'
    # M15 fix (issue #893 s11), KEPT here after the s11 post-fix P1 partial
    # revert (see script:Get-MarkerLineStartMatchIndexes above): this
    # detector only needs to catch a decoy marker literal BEFORE it gets
    # written -- it has no downstream finder counterpart to stay
    # byte-symmetric with, unlike the own-family anchor above -- so the
    # `\p{Cf}` widening (zero-width space U+200B, BOM/ZWNBSP U+FEFF, etc.,
    # which plain `\s` does not match) stays correct here.
    return '(?m)^[\s\p{Cf}]*' + $withWildcards
}

# M8 fix (issue #893 s11): cross-family hygiene must also protect markers
# that are LIVE today but carry no write-registry row of their own -- this
# file's own write path never posts either family (persist-phase-ledger.ps1
# writes phase-containment-ledger-{ID}; the pre-PR hook writes
# frame-credit-ledger-{PR}), so a candidate accidentally embedding one of
# these literals would otherwise pass hygiene clean and become a self-DoS on
# that family's next find-or-upsert read (the recorded self-DoS class this
# whole check exists to close). Defense-corrected scope (893 s11 M8):
# 'code-review-complete' is retired and 'design-issue' has no active writer
# on the current Claude pipeline, so neither is included here.
$script:MarkerHygieneOnlyFamilies = @(
    [PSCustomObject]@{ Family = 'frame-credit-ledger'; MarkerTemplate = '<!-- frame-credit-ledger-{PR} -->' }
    [PSCustomObject]@{ Family = 'phase-containment-ledger'; MarkerTemplate = '<!-- phase-containment-ledger-{ID} -->' }
)

function script:Test-MarkerPayloadHygiene {
    <#
    .SYNOPSIS
        893-D7 payload hygiene, run on the marker-COMPOSED CANDIDATE (the
        exact bytes about to be written) -- never the raw payload. Two
        distinct rules, both refuse (s9 amends 893-D7, which originally
        warned on the second rule):
          1. own-family: the candidate must carry its OWN family's marker
             EXACTLY ONCE, at line-start position 0 (line 1) -- refuses when
             the marker is missing entirely (M3, issue #893 s11 -- a
             marker-less candidate would post/patch unfindably, silently
             breaking idempotency), present but at the wrong line (missing
             from line 1), or present at line 1 plus at least one additional
             line-start occurrence (double-marker emission).
          2. cross-family: the candidate carries any OTHER registered
             family's live marker literal at line start (the recorded
             self-DoS class -- a live marker literal inside prose makes an
             issue carry two matching comments for that OTHER family). The
             cross-family scan covers both the caller-supplied write
             -Registry AND $script:MarkerHygieneOnlyFamilies (M8, issue #893
             s11) -- live marker families with no write-registry row of
             their own.
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

    # M7 fix (issue #893 s11): assign the function's return value to a
    # variable FIRST, then filter with Where-Object on the ASSIGNED
    # variable -- never pipe the function call directly into Where-Object.
    # Get-MarkerLineStartMatchIndexes returns via `return , @($indexes)` so
    # that exactly ONE pipeline object (the whole int[] array) is emitted at
    # the function-return boundary; piping that single-object emission
    # straight into `| Where-Object { $_ -gt 0 }` makes Where-Object's $_
    # bind to the WHOLE ARRAY once (not once per int), so `$_ -gt 0`
    # array-filters and, if any element is >0, Where-Object emits the
    # ENTIRE unfiltered array back out -- silently corrupting `$ownIndexes[0]`
    # into the array object itself (string-interpolated as a
    # space-joined garbage offset like "line 0 5 1") instead of an integer.
    # Assigning to $allOwnIndexes first, THEN piping that variable into
    # Where-Object, restores normal per-element pipeline enumeration.
    $allOwnIndexes = script:Get-MarkerLineStartMatchIndexes -Body $Body -Literal $Marker

    $hasLine1 = ($allOwnIndexes.Count -gt 0 -and $allOwnIndexes[0] -eq 0)
    if (-not $hasLine1) {
        if ($allOwnIndexes.Count -eq 0) {
            return 'candidate is missing its own family''s marker entirely -- a legitimate candidate carries the marker exactly once, at line 1; a marker-less body would post/patch unfindably, silently breaking idempotency'
        }
        $lineNumber = $allOwnIndexes[0] + 1
        return "candidate's own family marker is missing from line 1 -- found instead at line $lineNumber; a legitimate candidate carries the marker exactly once, on line 1"
    }
    if ($allOwnIndexes.Count -gt 1) {
        $extraLineNumber = $allOwnIndexes[1] + 1
        return "candidate carries its own family's marker more than once (also at line $extraLineNumber) -- the script emits the marker exactly once, on line 1; this indicates accidental double-marker emission"
    }

    $crossFamilyRows = @($Registry) + @($script:MarkerHygieneOnlyFamilies)
    foreach ($row in $crossFamilyRows) {
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
    .DESCRIPTION
        M24 fix (issue #893 s11): both the opening ` ```yaml ` and closing
        ` ``` ` fences are now anchored to LINE START (`(?m)^`), and the
        opening fence's leading-whitespace/newline-handling is explicit --
        the prior regex ( ` ```yaml\s*([\s\S]*?)``` ` ) was unanchored and
        matched the FIRST occurrence anywhere in the body, including inside
        an unrelated prose sentence or a decoy fence positioned earlier in
        the payload. Additionally: when the body carries MORE than one
        candidate fenced-yaml block, this now REFUSES (Ambiguous=$true)
        rather than silently picking whichever the regex happened to match
        first -- a decoy fence earlier in the payload must never cause the
        real, later block to be silently skipped.
    .OUTPUTS
        [PSCustomObject] Payload [string or $null] (possibly empty when
        Ambiguous=$false), Ambiguous [bool] (true when 2+ candidate fenced
        ```yaml blocks are present -- Payload is $null in that case; the
        caller must refuse rather than guess which block is authoritative).
    #>
    param([Parameter(Mandatory)][string]$Body)
    $fencePattern = '(?m)^```yaml[ \t]*\r?\n([\s\S]*?)^```[ \t]*\r?$'
    $fenceMatches = [regex]::Matches($Body, $fencePattern)
    if ($fenceMatches.Count -gt 1) {
        return [PSCustomObject]@{ Payload = $null; Ambiguous = $true }
    }
    if ($fenceMatches.Count -eq 1) {
        return [PSCustomObject]@{ Payload = $fenceMatches[0].Groups[1].Value.Trim(); Ambiguous = $false }
    }
    $closeIdx = $Body.IndexOf('-->')
    if ($closeIdx -ge 0) {
        return [PSCustomObject]@{ Payload = $Body.Substring($closeIdx + 3).Trim(); Ambiguous = $false }
    }
    return [PSCustomObject]@{ Payload = $Body.Trim(); Ambiguous = $false }
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

        Echo-cap scope note (M22 fix, issue #893 s11): the captured warning
        text is Read-EngagementRecords' OWN already-bounded diagnostic prose
        (a fixed template plus one interpolated field, authored by reviewed
        library code) -- routed through script:ConvertTo-MarkerLibraryMessageEcho,
        a WIDER dedicated cap than $script:MarkerRefusalEchoCap, so the
        offending field/value it names (893-D6) stays legible while still
        never being echoed unbounded (every echoed value must be
        length-bounded, no exceptions -- an uncapped site was itself the
        s11 finding). $script:MarkerRefusalEchoCap governs values THIS file
        echoes directly from raw payload content (see
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
        $echoedWarning = script:ConvertTo-MarkerLibraryMessageEcho -Value ([string]$warningList[0])
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "engagement-record validator flagged the candidate: $echoedWarning"
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
    # Echo-cap scope note (M22 fix, issue #893 s11): findings[0].message is
    # review-dispositions-validator-core.ps1's OWN already-bounded
    # diagnostic prose (Add-RdvFinding's fixed templates), routed through
    # script:ConvertTo-MarkerLibraryMessageEcho (a wider dedicated cap) so
    # the offending field/value it names (893-D6) stays legible while never
    # being echoed unbounded -- see Invoke-EngagementRecordValidatorAdapter's
    # identical rationale.
    $findings = @($result.findings)
    if ($findings.Count -gt 0) {
        $echoedFinding = script:ConvertTo-MarkerLibraryMessageEcho -Value ([string]$findings[0].message)
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail "review-dispositions validator flagged the candidate: $echoedFinding"
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
    $yamlExtraction = script:Get-MarkerYamlPayload -Body $Body
    # M24 fix (issue #893 s11): refuse (never silently pick one) when the
    # body carries more than one candidate fenced ```yaml block -- see
    # script:Get-MarkerYamlPayload's own doc comment.
    if ($yamlExtraction.Ambiguous) {
        return script:New-MarkerRefusal -Family $Family -Target $Target -Detail 'credit-input payload carries more than one fenced ```yaml block -- refusing rather than guessing which is authoritative'
    }
    $yamlContent = $yamlExtraction.Payload
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
    # M6 fix (issue #893 s11): the canonical parser
    # (frame-spine-core.ps1:67, script:Get-FSCCommentBlockPayloads) accepts
    # TWO legal block forms via alternation -- (1) a self-closing open tag
    # '<!-- frame-spine -->' followed by the payload as plain text up to a
    # trailing '-->', and (2) the 'open-tag-then-newline' form
    # '<!-- frame-spine\n...-->'. The old pattern here matched ONLY form
    # (2), so a form-(1) block would silently fail to match, returning the
    # body UNCHANGED while the caller still reported the splice as a
    # success. Both alternatives are mirrored here (never re-implemented
    # narrower) so this helper can never silently no-op against a shape
    # Get-FSCSpineBlock itself already accepts.
    #
    # P5 fix (issue #893 s11 post-fix): this mirror regex was missing the
    # canonical parser's `(?m)^[ \t]*` line-start anchor on the alternation
    # group, and ran against the raw, un-normalized $Body instead of the
    # canonical parser's own normalization step
    # (script:ConvertTo-FSCNormalizedText / this file's own
    # script:ConvertTo-MarkerLFBody, CRLF/CR -> LF only). Without the
    # anchor, this regex could match a PROSE MENTION of the block (e.g.
    # "the `<!-- frame-spine -->` block below") anywhere mid-line as a
    # decoy, ahead of the real block -- defense proved this live: the
    # unanchored regex matched at the decoy's index with an empty payload
    # capture instead of the real block further down. Anchoring to
    # `(?m)^[ \t]*`, exactly like the canonical parser, makes a mid-line
    # mention structurally unmatchable. `(?ms)` (not just `(?s)`) supplies
    # both the Multiline `^` behavior the anchor needs and the Singleline
    # `.`-matches-newline behavior the payload capture needs, mirroring
    # Get-FSCCommentBlockPayloads' own `(?m)` inline flag + separately
    # passed RegexOptions.Singleline.
    $normalizedBody = script:ConvertTo-MarkerLFBody -Text $Body
    $blockPattern = '(?ms)^[ \t]*(?:<!--\s*frame-spine\s*-->\s*\n(?<payload>.*?)\n\s*-->|<!--\s*frame-spine(?:\s*\n|\s+)(?<payload>.*?)\n?\s*-->)'
    $blockMatch = [regex]::Match($normalizedBody, $blockPattern)
    if (-not $blockMatch.Success) {
        # P6 fix (issue #893 s11 post-fix): the post-condition safety net
        # below (re-reading -Name back through the CANONICAL parser) used to
        # be unreachable on this early-return path, so a body the canonical
        # parser CAN see a frame-spine block in, but this mirror regex
        # cannot (the "third, currently-unknown block shape" the M6 comment
        # above already anticipated), silently returned the body unchanged
        # with no loud failure -- exactly the "matched-but-wrong" class of
        # bug this post-condition exists to catch, just reached from the
        # opposite direction (didn't-match-at-all rather than
        # matched-the-wrong-thing). Run the same canonical-parser check here
        # too: only return silently when the canonical parser also sees no
        # block (a genuine "nothing to splice" case); throw loud otherwise.
        $canonicalBlock = Get-FSCSpineBlock -CommentBody $normalizedBody
        if ($null -ne $canonicalBlock) {
            throw "persist-marker-core: Set-MarkerSpineScalarValue post-condition failed -- the canonical parser (Get-FSCSpineBlock) sees a frame-spine block in this body but this helper's own splice regex did not match it; refusing to silently no-op against an unrecognized block shape"
        }
        return $Body
    }

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

    # P5 fix (issue #893 s11 post-fix): splice into $normalizedBody, not the
    # raw $Body -- $blockMatch's Index/Length are offsets into the
    # normalized (LF-only) text the match ran against above, so splicing
    # them into the original, possibly-CRLF $Body would misalign on any
    # body that actually contains CRLF line endings.
    $updatedBody = $normalizedBody.Substring(0, $payloadGroup.Index) + $newPayload + $normalizedBody.Substring($payloadGroup.Index + $payloadGroup.Length)

    # M6 post-condition (issue #893 s11): re-read -Name back off the
    # UPDATED body through the CANONICAL parser (Get-FSCSpineBlock /
    # script:Get-FSCScalarValue -- never this file's own splice regex) and
    # fail loud if it does not equal -Value. This is the safety net for a
    # THIRD, currently-unknown block shape the canonical parser might accept
    # that neither alternation branch above matches: such a shape would
    # still turn into a loud failure here instead of a silent no-op.
    $verifyBlock = Get-FSCSpineBlock -CommentBody $updatedBody
    $verifyValue = if ($null -ne $verifyBlock) { script:Get-FSCScalarValue -Block $verifyBlock -Name $Name } else { $null }
    if ($verifyValue -ne $Value) {
        throw "persist-marker-core: Set-MarkerSpineScalarValue post-condition failed -- '$Name' reads back as '$(script:ConvertTo-MarkerRefusalEcho -Value $verifyValue)' after the splice, expected '$(script:ConvertTo-MarkerRefusalEcho -Value $Value)'"
    }

    return $updatedBody
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

        M19 fix (issue #893 s11): uses Get-CommentBodyByIdWithStatus (not
        Get-CommentBodyById) so a TRANSPORT failure (network blip, rate
        limit, auth, transient 5xx) can be distinguished from a confirmed
        HTTP 404 absence. The prior Get-CommentBodyById-based implementation
        collapsed both into the same "GET returned nothing" signal, so a
        live pointer got silently DROPPED (treated exactly like a
        genuinely-stale/forged one) on nothing more than a transient GET
        failure. Now: a confirmed-absent/wrong target still returns $false
        (the caller drops the pointer, correct behavior); a TRANSPORT
        failure instead THROWS, so the caller aborts the whole write rather
        than silently dropping a pointer it was never actually able to
        verify one way or the other.
    .OUTPUTS
        [bool] $true only when the comment exists and its LF-normalized body
        carries -ExpectedMarker as a whole, standalone line; $false when the
        comment is confirmed absent (HTTP 404) or exists but lacks the
        marker. Throws on a transport failure (never a confirmed absence).
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][long]$CommentId,
        [Parameter(Mandatory)][string]$ExpectedMarker
    )
    $fetchResult = Get-CommentBodyByIdWithStatus -Owner $Owner -Repo $Repo -CommentId $CommentId
    if ($fetchResult.Status -eq 'error') {
        throw "persist-marker-core: Test-MarkerSiblingIdentity transport failure fetching sibling comment $CommentId -- $(script:ConvertTo-MarkerRefusalEcho -Value $fetchResult.ErrorMessage)"
    }
    if ($fetchResult.Status -eq 'not-found') {
        return $false
    }
    return [regex]::IsMatch((script:ConvertTo-MarkerLFBody -Text $fetchResult.Body), '(?m)^[ \t]*' + [regex]::Escape($ExpectedMarker) + '[ \t]*$')
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
        [PSCustomObject] with Body [string] (the possibly-merged candidate),
        PreservedClasses [string[]] (human-readable names of every artifact
        class actually preserved, for the confirmation message -- empty
        array, never $null, when nothing was preserved), and Refusal
        [string or $null] (M14, issue #893 s11 -- populated only when a
        CANDIDATE-SUPPLIED pointer/scalar, not an inherited one, fails its
        own live sibling-identity check; the caller must refuse the whole
        write rather than proceed when this is non-null).
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body
    )

    $preservedClasses = [System.Collections.Generic.List[string]]::new()
    $mergedBody = $Body
    $pointerPattern = '(?m)^[ \t]*<!--\s*phase-containment-ledger-ref:\s*(?<id>\d+)\s*-->[ \t]*$'

    # --- Candidate-supplied-pointer validation (P7 fix, issue #893 s11
    # post-fix): HOISTED to run BEFORE the $existing.Count -eq 0
    # early-return below. Both checks below only need the CANDIDATE body
    # plus a live GET against the claimed sibling -- neither needs the
    # existing comment at all. M14 originally placed both checks AFTER the
    # early-return, so a forged/stale candidate-supplied pointer on the
    # very FIRST plan-issue write (no prior comment yet, so
    # $existing.Count -eq 0) wrote through completely unvalidated; only a
    # re-persist (an existing comment already present) was actually
    # protected. ---

    # --- 1a. phase-containment-ledger-ref candidate-supplied pointer. ---
    $candidatePointerMatch = [regex]::Match((script:ConvertTo-MarkerLFBody -Text $mergedBody), $pointerPattern)
    $candidateHasPointer = $candidatePointerMatch.Success
    if ($candidateHasPointer) {
        # M14 fix (issue #893 s11): a CANDIDATE-SUPPLIED pointer (already
        # present in the incoming payload, not inherited from the existing
        # comment) was never live-checked before -- only the
        # preserve-decision path below (which only fires when the candidate
        # OMITS the pointer) ran Test-MarkerSiblingIdentity. Run the exact
        # same live check here too and REFUSE (never silently write through)
        # a forged/stale candidate-supplied pointer.
        $candidateSiblingId = [long]$candidatePointerMatch.Groups['id'].Value
        $expectedCandidateSiblingMarker = "<!-- phase-containment-ledger-$Number -->"
        $candidateSiblingValid = script:Test-MarkerSiblingIdentity -Owner $Owner -Repo $Repo -CommentId $candidateSiblingId -ExpectedMarker $expectedCandidateSiblingMarker
        if (-not $candidateSiblingValid) {
            return [PSCustomObject]@{
                Body             = $Body
                PreservedClasses = [string[]]@()
                Refusal          = "candidate-supplied phase-containment-ledger-ref pointer ($candidateSiblingId) does not carry the expected sibling identity marker '$expectedCandidateSiblingMarker' -- refusing a forged/stale pointer rather than writing it through unvalidated"
            }
        }
    }

    # --- 1b. frame-spine slice_comment_id candidate-supplied scalar. ---
    # M14 fix (issue #893 s11): validate a CANDIDATE-SUPPLIED slice_comment_id
    # regardless of whether the existing comment carries one -- the prior
    # code only ever live-checked an INHERITED value (the preserve-decision
    # branch further below, which only runs when the candidate lacks a
    # value).
    $candidateSpineBlockForValidation = Get-FSCSpineBlock -CommentBody (script:ConvertTo-MarkerLFBody -Text $mergedBody)
    if ($null -ne $candidateSpineBlockForValidation) {
        $candidateSuppliedSliceCommentId = script:Get-FSCScalarValue -Block $candidateSpineBlockForValidation -Name 'slice_comment_id'
        if (-not [string]::IsNullOrWhiteSpace($candidateSuppliedSliceCommentId)) {
            $expectedSliceSiblingMarker = "<!-- frame-slices-$Number -->"
            $candidateSliceValid = $false
            if ($candidateSuppliedSliceCommentId -match '^\d+$') {
                $candidateSliceValid = script:Test-MarkerSiblingIdentity -Owner $Owner -Repo $Repo -CommentId ([long]$candidateSuppliedSliceCommentId) -ExpectedMarker $expectedSliceSiblingMarker
            }
            if (-not $candidateSliceValid) {
                return [PSCustomObject]@{
                    Body             = $Body
                    PreservedClasses = [string[]]@()
                    Refusal          = "candidate-supplied slice_comment_id ($candidateSuppliedSliceCommentId) does not carry the expected sibling identity marker '$expectedSliceSiblingMarker' -- refusing a forged/stale pointer rather than writing it through unvalidated"
                }
            }
        }
    }

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
        return [PSCustomObject]@{ Body = $Body; PreservedClasses = [string[]]@(); Refusal = $null }
    }

    # Canonical = earliest (lowest REST id) match -- same selector
    # Invoke-MarkerUpsertWrite itself uses for the upsert comparison target.
    $existingBody = script:ConvertTo-MarkerLFBody -Text $existing[0].Body

    # --- 1. phase-containment-ledger-ref pointer preserve-decision. Only
    # relevant when the candidate did NOT already supply its own pointer
    # (already validated above) -- an inherited pointer is preserved from
    # the existing comment instead. ---
    $pointerMatch = [regex]::Match($existingBody, $pointerPattern)
    if (-not $candidateHasPointer -and $pointerMatch.Success) {
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

    # --- 2. frame-spine slice_comment_id scalar preserve-decision
    # (inherited only -- a candidate-supplied value was already validated
    # above). ---
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
                    # M6 note (issue #893 s11): Set-MarkerSpineScalarValue
                    # can now throw on its own post-condition failure -- this
                    # is a pre-write MERGE step, not the write itself, so a
                    # splice failure here must not crash the whole write;
                    # treat it the same as a stale/forged pointer (drop the
                    # preservation for this artifact class, never fabricate
                    # a merge that didn't actually happen).
                    try {
                        $mergedBody = script:Set-MarkerSpineScalarValue -Body $mergedBody -Name 'slice_comment_id' -Value $existingSliceCommentId
                        $preservedClasses.Add('slice_comment_id (frame-spine)') | Out-Null
                    }
                    catch {
                        [Console]::Error.WriteLine("persist-marker-core: plan-issue-write-back-preserve could not splice slice_comment_id -- $($_.Exception.Message)")
                    }
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

    # M10 fix (issue #893 s11), PARTIALLY REVERTED at s11 post-fix P3 (issue
    # #893): M10 moved this **Plan Stress-Test** heading/section preserve
    # INSIDE the legacy (no-ledger-pointer) gate above, but
    # plan-authoring/SKILL.md rule 8 explicitly states "Post-split, the
    # heading and its prose bullets stay on the plan comment" for MODERN
    # (ledger-pointer-carrying) plans too, and the live reader at
    # phase-containment-emission-check-core.ps1's plan-stress-test honest
    # fallback depends on the heading being present regardless of pointer
    # generation. Gating this preserve to legacy-only caused a modern
    # re-persist that omitted the heading to silently drop it, collapsing
    # the emission-check gate to a false-clean. This preserve now runs
    # unconditionally again (matching pre-M10 scope), while KEEPING M10's
    # independently-correct bounded-capture-regex fix below: the pattern
    # stops at a `## ` Markdown heading or a `<!-- named-decisions:begin
    # -->` sentinel (in addition to the next `**Bold**` heading or
    # end-of-body), so it can no longer over-capture and duplicate
    # unrelated trailing content (e.g. `## Named Decisions`) the way the
    # pre-M10 unbounded capture did -- that bounding alone fully closes
    # M10's original over-capture complaint without the harmful
    # legacy-gating.
    $stressTestPattern = '(?ms)^\*\*Plan Stress-Test\*\*.*?(?=^\*\*[A-Za-z]|^##[ \t]|<!--\s*named-decisions:begin|\z)'
    $stressTestMatch = [regex]::Match($existingBody, $stressTestPattern)
    $candidateHasStressTestHeading = [regex]::IsMatch((script:ConvertTo-MarkerLFBody -Text $mergedBody), '(?m)^\*\*Plan Stress-Test\*\*')
    if ($stressTestMatch.Success -and -not $candidateHasStressTestHeading) {
        $mergedBody = $mergedBody.TrimEnd() + "`n`n" + $stressTestMatch.Value.Trim()
        $preservedClasses.Add('**Plan Stress-Test** heading/section') | Out-Null
    }

    return [PSCustomObject]@{ Body = $mergedBody; PreservedClasses = [string[]]$preservedClasses.ToArray(); Refusal = $null }
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
        TARGETED SCALAR SPLICE (script:Set-MarkerSpineScalarValue), writes
        it via Set-CommentBodyDirect (whose own post-write verify is the
        inherited >=50%-length truncation guard only), and THEN calls
        script:Test-MarkerReadBack for the stricter normalized-equality
        check (M5 fix, issue #893 s11) -- a throw from that call is
        converted to Success=$false, exactly like both write shapes above
        already do. This deliberately departs from
        persist-phase-ledger-core.ps1's own splice convention (which relies
        on the truncation guard alone): the truncation guard cannot prove
        byte-faithfulness, because mojibake corruption LENGTHENS text rather
        than shortening it.
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

    try {
        $splicedBody = script:Set-MarkerSpineScalarValue -Body $planComment.Body -Name 'slice_comment_id' -Value "$SiblingCommentId"
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Reason = "frame-slices spine-splice: $($_.Exception.Message)"; Action = $null }
    }
    $writeResult = Set-CommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $planComment.Id -NewBody $splicedBody
    if (-not $writeResult.Success) {
        return [PSCustomObject]@{ Success = $false; Reason = "frame-slices spine-splice: failed to write slice_comment_id onto plan comment $($planComment.Id): $($writeResult.Reason)"; Action = $null }
    }

    # M5 fix (issue #893 s11): Set-CommentBodyDirect's own post-write verify
    # is the inherited >=50%-length truncation guard ONLY -- it cannot prove
    # byte-faithfulness, because mojibake corruption LENGTHENS text rather
    # than shortening it (the same rationale that made Test-MarkerReadBack's
    # normalized-equality check the PRIMARY gate for both write shapes
    # above). Call it here too so the splice-back gets the identical
    # read-back discipline, converting a throw into Success=$false rather
    # than reporting the splice as landed on a corrupted write.
    try {
        $null = script:Test-MarkerReadBack -Owner $Owner -Repo $Repo -CommentId $planComment.Id -ExpectedBody $splicedBody
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Reason = "frame-slices spine-splice: $($_.Exception.Message)"; Action = $null }
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
        # M20 fix (issue #893 s11): a PERSISTENT normalized-body mismatch on
        # a freshly-created comment (as opposed to a merely transient GET
        # failure during THIS verify call, which self-heals on the caller's
        # next retry via Find-AllCommentsByExactMarker's own live
        # re-compare) leaves the corrupted comment sitting on the issue
        # forever. Every SUBSEQUENT external retry then compares the
        # candidate against that still-mismatched "latest"/"canonical"
        # match and posts yet ANOTHER new comment, accreting duplicates
        # without bound. Attempt exactly ONE same-call repair-PATCH of the
        # just-created comment (re-writing the intended -Body verbatim)
        # before giving up, so a genuinely corrupted write self-heals
        # immediately rather than requiring an unbounded number of external
        # retries, each adding one more duplicate.
        $originalReadBackMessage = $_.Exception.Message
        $repairSucceeded = $false
        # P11 fix (issue #893 s11 post-fix): capture the ACTUAL repair
        # failure detail instead of discarding it -- both the non-throwing
        # failure path ($repairPatch.Reason, when Set-CommentBodyDirect
        # itself returns Success=$false without throwing) and the
        # throwing path ($_.Exception.Message inside the nested catch,
        # when the post-repair Test-MarkerReadBack call throws). The
        # 893-D6 diagnosability standard this file otherwise follows
        # throughout requires every refusal to name a specific reason, not
        # a generic "also failed" with no why.
        $repairFailureDetail = $null
        try {
            $repairPatch = Set-CommentBodyDirect -Owner $Owner -Repo $Repo -CommentId $newId -NewBody $Body
            if ($repairPatch.Success) {
                $null = script:Test-MarkerReadBack -Owner $Owner -Repo $Repo -CommentId $newId -ExpectedBody $Body
                $repairSucceeded = $true
            }
            else {
                $repairFailureDetail = $repairPatch.Reason
            }
        }
        catch {
            $repairSucceeded = $false
            $repairFailureDetail = $_.Exception.Message
        }
        if ($repairSucceeded) {
            $confirmation = "persist-marker-core: family '$Family' comment $newId $Action (after a read-back-failure repair-PATCH)"
            Write-Host $confirmation
            return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $newId; Action = $Action; Confirmation = $confirmation; Reason = $null }
        }
        $repairDetailSuffix = if ([string]::IsNullOrWhiteSpace($repairFailureDetail)) { '' } else { " -- $repairFailureDetail" }
        return [PSCustomObject]@{ Success = $false; Family = $Family; CommentId = $newId; Action = $null; Confirmation = $null; Reason = "$originalReadBackMessage (repair-PATCH attempt also failed$repairDetailSuffix)" }
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

function script:Get-MarkerBodyCodepointCount {
    <#
    .SYNOPSIS
        M23 fix (issue #893 s11): counts -Body by Unicode CODEPOINT (a.k.a.
        Unicode scalar value / "rune"), not by .NET [string]::Length's raw
        UTF-16 CODE UNIT count. A character outside the Basic Multilingual
        Plane (most emoji, many CJK extension characters) is stored as a
        UTF-16 SURROGATE PAIR -- two code units for one real character --
        so the raw .Length-based size check previously refused an
        astral-plane/emoji-heavy body at roughly HALF its real allowance,
        working against AC1's non-ASCII-fidelity intent. Runs a single
        codepoint-count pass; a multi-codepoint grapheme cluster (e.g. a ZWJ
        emoji sequence or a flag) still counts as multiple codepoints here
        -- deliberately NOT grapheme-cluster ("text element") counting,
        which would be a MORE lenient count than this fix's scope covers
        and risks under-counting relative to whatever GitHub's own REST API
        actually enforces server-side.
    .OUTPUTS
        [int]
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    $count = 0
    $enumerator = $Body.EnumerateRunes()
    while ($enumerator.MoveNext()) { $count++ }
    return $count
}

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

function script:Test-MarkerPathSegmentIsReparsePoint {
    <#
    .SYNOPSIS
        M1 fix (issue #893 s11): true reparse-point (symlink/junction)
        detection for one path segment. Resolve-Path canonicalizes a
        *traversed* path string but does NOT dereference reparse points --
        a junction living INSIDE the scratch root whose TARGET is outside it
        still produces a resolved-path string that starts with the scratch
        root's own prefix, defeating the string-containment check alone.
    .DESCRIPTION
        `(Get-Item -Force).LinkType` is non-null/non-empty for a symbolic
        link or a directory junction (both are NTFS reparse points) and
        $null for an ordinary file or directory -- this is the cheap,
        built-in signal; no `fsutil` subprocess needed for this class.
    .OUTPUTS
        [bool] $true when -Segment is itself a reparse point.
    #>
    param([Parameter(Mandatory)][string]$Segment)
    if (-not (Test-Path -LiteralPath $Segment)) { return $false }
    $item = Get-Item -LiteralPath $Segment -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return (-not [string]::IsNullOrEmpty($item.LinkType))
}

function Resolve-MarkerScratchBoundedPath {
    <#
    .SYNOPSIS
        Real path-containment check (893-s6 owner decision, security-
        critical -- this is what keeps the recommended
        `Bash(pwsh*persist-marker.ps1*)`-style allowlist entry safe rather
        than an arbitrary-file-read-to-public-comment primitive): resolves
        -Path via Resolve-Path (traversal-aware canonicalization of '.'/'..'
        segments; requires the target to exist -- every caller here needs to
        read the file's content anyway, so non-existence is itself a
        refusal), checks segment-boundary containment inside the
        canonicalized -ScratchRoot, and then refuses on any symlink or
        junction -- checking -ScratchRoot ITSELF first (F1 fix, PR #917
        review), then walking every descendant path segment down to the leaf
        (893 s11 M1 fix -- see script:Test-MarkerPathSegmentIsReparsePoint).
    .DESCRIPTION
        Never a raw string-prefix test on the UNRESOLVED input -- that is
        spoofable both by relative-traversal payloads
        ('.tmp/../../secrets') and by same-string-prefix SIBLING
        directories ('.tmp-not-really/file') that a naive ".tmp" prefix
        check would wrongly admit. The trailing-separator comparison below
        (StartsWith($rootWithSep)) is what rejects the sibling-directory
        case even after both sides are canonicalized.

        Resolve-Path alone is NOT symlink-aware: it canonicalizes the
        TRAVERSED path string (collapsing '.'/'..' segments) without ever
        dereferencing a reparse point, so a junction placed INSIDE the
        scratch root (or the scratch root directory itself being a
        junction/symlink) whose target lives OUTSIDE it would still pass the
        string-containment check above undetected. What actually closes that
        gap is script:Test-MarkerPathSegmentIsReparsePoint applied to BOTH
        the scratch root itself (F1 fix, PR #917 review -- the root was
        previously exempt, checked nowhere) AND every descendant directory
        component between the scratch root and the leaf (893 s11 M1 fix),
        refused if either is a reparse point, regardless of where its target
        resolves.

        Known residual limitation (accepted, not solved here): a HARD LINK
        is not a reparse point (NTFS hard links are ordinary directory
        entries pointing at the same file record), so `LinkType` does not
        detect it. Cheaply detecting a hard link would require an
        `fsutil hardlink list` subprocess per read (or a native file-index
        comparison not available cross-platform via Get-Item alone) --
        deliberately not implemented in this slice; a hard-linked leaf file
        under the scratch root can still be read through this bound.
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

    # F1 fix (PR #917 review): the ROOT ITSELF must also be tested -- if
    # '.tmp' (or whatever -ScratchRoot resolves to) is itself a
    # junction/symlink to an outside directory, the string-containment check
    # above and the descendant-only walk below both pass unchanged (neither
    # dereferences the root's own reparse point), and a leaf file under it
    # is wrongly readable/publishable. This check runs BEFORE the
    # descendant-segment loop so it always fires, including when -Path
    # resolves to the root itself (Length equal, not greater).
    if (script:Test-MarkerPathSegmentIsReparsePoint -Segment $resolvedScratchRoot) {
        return [PSCustomObject]@{ InBounds = $false; ResolvedPath = $resolvedPath; Reason = "the scratch root itself is a symlink or junction at '$(script:ConvertTo-MarkerRefusalEcho -Value $resolvedScratchRoot)' -- reparse points are refused regardless of where their target resolves" }
    }

    # M1 (893 s11): walk every segment from the scratch root down to the
    # leaf, refusing on the first reparse point found -- a junction/symlink
    # anywhere along the path defeats the string-containment check above
    # regardless of depth.
    if ($resolvedPath.Length -gt $resolvedScratchRoot.Length) {
        $relative = $resolvedPath.Substring($resolvedScratchRoot.Length).TrimStart('/', '\')
        $relativeSegments = @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })
        $walked = $resolvedScratchRoot
        foreach ($segment in $relativeSegments) {
            $walked = Join-Path $walked $segment
            if (script:Test-MarkerPathSegmentIsReparsePoint -Segment $walked) {
                return [PSCustomObject]@{ InBounds = $false; ResolvedPath = $resolvedPath; Reason = "path traverses a symlink or junction at '$(script:ConvertTo-MarkerRefusalEcho -Value $walked)' -- reparse points are refused regardless of where their target resolves" }
            }
        }
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
    # M21 fix (issue #893 s11): this function documents "Refuses (never
    # throws)", but Get-Content -ErrorAction Stop DOES throw uncaught for a
    # directory path (a directory resolves inside the scratch root and
    # passes the bounds check above, but is not readable CONTENT) or a
    # permission/lock error -- neither is an out-of-bounds condition, so
    # neither was covered by the check above. Wrap the read so every failure
    # mode returns the documented refusal shape instead of propagating an
    # uncaught exception to the caller.
    try {
        $body = Get-Content -LiteralPath $bounded.ResolvedPath -Raw -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Body = $null; Reason = "persist-marker: REFUSED (-BodyFile could not be read): $(script:ConvertTo-MarkerRefusalEcho -Value $_.Exception.Message)" }
    }
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
        every burst entry, without duplicating the logic. This helper itself
        never runs the PostStep dispatch -- it validates whatever -Body it
        is given. M11 fix (issue #893 s11): Invoke-PersistMarkerBurst's own
        preflight loop now runs script:Invoke-PlanIssueWriteBackPreserve
        itself (live-read-only, before calling this helper) for a
        plan-issue-family entry and passes THIS FUNCTION the resulting
        preview-merged body, rather than skipping preserve prediction
        entirely -- see that loop's own comment for the full rationale and
        the residual, accepted preview/execution-divergence risk. This
        function's own contract is unchanged: it stays a pure, network-free
        validation of whatever -Body its caller supplies.
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

    # M23 fix (issue #893 s11): count by Unicode codepoint (script:Get-MarkerBodyCodepointCount),
    # not by [string]::Length's raw UTF-16 code-unit count -- see that
    # function's own doc comment for why a surrogate-pair-heavy body was
    # previously refused at roughly half its real allowance.
    $bodyCodepointCount = script:Get-MarkerBodyCodepointCount -Body $Body
    if ($bodyCodepointCount -gt $script:MarkerBodySizeCap) {
        return script:New-MarkerRefusal -Family $Family -Target $target -Detail "composed body is $bodyCodepointCount chars, exceeding GitHub's $($script:MarkerBodySizeCap)-char comment cap"
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
        # M19 fix (issue #893 s11): script:Test-MarkerSiblingIdentity (called
        # inside Invoke-PlanIssueWriteBackPreserve) now THROWS on a transport
        # failure rather than treating it the same as a confirmed-absent
        # sibling -- wrap the call so that throw becomes a diagnosable
        # refusal (aborting the write, per 893-D6) instead of an uncaught
        # exception crashing the caller (e.g. the single-write CLI wrapper,
        # which has no top-level try/catch of its own).
        try {
            $preserveResult = script:Invoke-PlanIssueWriteBackPreserve -Owner $Owner -Repo $Repo -Number $Number -Marker $Marker -Body $Body
        }
        catch {
            return script:New-MarkerRefusal -Family $Family -Target $target -Detail "write-back-preserve aborted: $($_.Exception.Message)"
        }
        # M14 fix (issue #893 s11): a non-null Refusal means the CANDIDATE
        # itself (not an inherited/preserved value) carried a
        # forged/stale phase-containment-ledger-ref pointer or
        # slice_comment_id scalar that failed its live sibling-identity
        # check -- refuse the whole write here rather than silently writing
        # it through unvalidated.
        if ($null -ne $preserveResult.Refusal) {
            return script:New-MarkerRefusal -Family $Family -Target $target -Detail $preserveResult.Refusal
        }
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
        and failed -- nothing landed), 'landed-postfix-failed' (M18, issue
        #893 s11 -- the underlying comment write itself DID land, but a
        PostStep that runs after it, e.g. frame-slices-spine-splice, failed;
        distinct from 'failed' so the operator can tell "nothing written"
        from "written but incomplete" without having to cross-reference
        Results[].CommentId/Reason by hand) -- mirrors persist-phase-ledger-core.ps1's
        own landed/not-attempted artifact-manifest shape
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

    # --- Whole-manifest preflight: read-only (may issue GETs for
    # plan-issue preserve preview), zero writes on any refusal. P9 fix
    # (issue #893 s11 post-fix): this comment previously said "network-free"
    # -- stale since M11 made the plan-issue preview path inside this
    # preflight issue real `gh api` GETs (Test-MarkerSiblingIdentity live
    # sibling-identity checks). ---
    # M4/N1 fix (issue #893 s11): a ValidateSet-binding failure on
    # -TargetSurface (or any other bound parameter) inside
    # Test-MarkerCandidatePreflight is a genuine PowerShell footgun -- it can
    # leave $refusal holding whatever it was on the PREVIOUS iteration
    # (silently un-assigned) rather than $null or a thrown exception,
    # because the assignment statement itself never completes. $refusal is
    # explicitly reset to $null at the TOP of every iteration, BEFORE the
    # call, so an un-assigned iteration can never inherit a stale prior
    # value; the call is also wrapped in try/catch so a binding (or any
    # other) failure becomes an explicit synthesized refusal instead of
    # either silently inheriting stale state or crashing uncaught.
    # M11 fix (issue #893 s11): resolve the registry once so the loop below
    # can tell whether a given entry's family carries the
    # 'plan-issue-write-back-preserve' PostStep -- see this file's top-of-
    # file s6 addition note and script:Test-MarkerCandidatePreflight's own
    # doc comment for the full rationale.
    $burstPreflightRegistry = @(Get-MarkerFamilyRegistry)
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $entry = $Entries[$i]
        $refusal = $null
        try {
            # M11 fix (issue #893 s11): for a plan-issue-family entry (unless
            # -NoPreserve is set), run the SAME write-back-preserve merge
            # Invoke-PersistMarkerWrite itself performs before its own
            # preflight, and validate the PREVIEW-MERGED body -- a
            # preserve-triggered size/hygiene violation now surfaces here,
            # before any earlier burst entry has been allowed to land,
            # instead of only at execution time. Read-only (GETs), never a
            # write, so this stays consistent with "zero writes on any
            # refusal". See this loop's own doc note above for the residual
            # preview/execution-divergence risk this accepts.
            $previewBody = $entry.Body
            $entryFamilyRow = @($burstPreflightRegistry | Where-Object { $_.Family -eq $entry.Family })
            $candidateSuppliedRefusal = $null
            if ($entryFamilyRow.Count -gt 0 -and $entryFamilyRow[0].PostStep -eq 'plan-issue-write-back-preserve' -and -not [bool]$entry.NoPreserve) {
                # P10 fix (issue #893 s11 post-fix): script:Test-MarkerSiblingIdentity
                # (M19) THROWS on a TRANSIENT transport failure (network
                # blip, rate limit) during this preview's live
                # sibling-identity GETs, distinct from a confirmed-absent
                # $false. Before M11 introduced this preview, the burst
                # preflight issued no GETs at all, so a transient GET
                # failure could never refuse an otherwise-valid burst at
                # preflight time -- defense proved this specific failure
                # mode directly reachable today. Catch it HERE, narrowly by
                # message match, and treat "couldn't verify during preview"
                # as "proceed with the unmerged candidate body, let
                # execution time re-check" -- Invoke-PersistMarkerWrite's
                # own preflight always re-validates the TRUE final
                # candidate at write time regardless of this preview, so
                # this can only ever soften a preflight-time false REFUSAL
                # into a (still safe) execution-time re-check, never widen
                # what ultimately gets written. Any OTHER (non-transient)
                # error re-throws, unchanged, to the outer catch below.
                try {
                    $preview = script:Invoke-PlanIssueWriteBackPreserve -Owner $Owner -Repo $Repo -Number $entry.Number -Marker $entry.Marker -Body $entry.Body
                    # M14 fix (issue #893 s11): a non-null Refusal means the
                    # entry's OWN candidate body carried a forged/stale
                    # phase-containment-ledger-ref pointer or slice_comment_id --
                    # surface that as a preflight refusal too, exactly mirroring
                    # Invoke-PersistMarkerWrite's own execution-time check.
                    if ($null -ne $preview.Refusal) {
                        $candidateSuppliedRefusal = script:New-MarkerRefusal -Family $entry.Family -Target "$($entry.TargetSurface)/$($entry.Number)" -Detail $preview.Refusal
                    }
                    else {
                        $previewBody = $preview.Body
                    }
                }
                catch {
                    if ($_.Exception.Message -notmatch 'Test-MarkerSiblingIdentity transport failure') { throw }
                    # Transient transport failure during preview -- proceed
                    # with the unmerged $entry.Body ($previewBody already
                    # defaults to it above); execution time re-checks for
                    # real.
                }
            }
            $refusal = if ($null -ne $candidateSuppliedRefusal) { $candidateSuppliedRefusal } else { script:Test-MarkerCandidatePreflight -Family $entry.Family -TargetSurface $entry.TargetSurface -Number $entry.Number -Marker $entry.Marker -Body $previewBody }
        }
        catch {
            $refusal = script:New-MarkerRefusal -Family "$($entry.Family)" -Target "$($entry.TargetSurface)/$($entry.Number)" -Detail "entry could not be validated -- $($_.Exception.Message)"
        }
        if ($null -ne $refusal) {
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (burst preflight, entry $($i + 1) of $($Entries.Count), family '$($entry.Family)'): $($refusal.Reason)"; Results = [object[]]@(); Artifacts = $artifacts }
        }
    }

    # --- Execution: manifest order, halt-on-first-failure. ---
    # M4/N1 fix (issue #893 s11): same root cause, executor-loop shape --
    # $writeResult is explicitly reset to $null at the top of every
    # iteration and the write call is wrapped in try/catch, so a
    # parameter-binding failure on any entry AFTER the first can never be
    # misread as the PRIOR entry's stale successful result (N1's exact
    # defect: a false 'landed' status and overall Success=$true for an
    # entry that never actually wrote).
    $results = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $entry = $Entries[$i]
        $noPreserve = [bool]$entry.NoPreserve
        $writeResult = $null
        try {
            $writeResult = Invoke-PersistMarkerWrite -Family $entry.Family -Owner $Owner -Repo $Repo -Number $entry.Number `
                -TargetSurface $entry.TargetSurface -Marker $entry.Marker -Body $entry.Body -NoPreserve:$noPreserve
        }
        catch {
            $writeResult = [PSCustomObject]@{ Success = $false; Family = "$($entry.Family)"; CommentId = $null; Action = $null; Confirmation = $null; Reason = "persist-marker: entry could not be written -- $($_.Exception.Message)" }
        }
        $results.Add($writeResult)
        if ($writeResult.Success) {
            $artifacts["entry-$($i + 1)"] = 'landed'
        }
        else {
            # M18 fix (issue #893 s11): a PostStep failure (e.g.
            # frame-slices-spine-splice) reports Success=$false but the
            # underlying comment write itself DID land -- Invoke-PersistMarkerWrite
            # signals this by populating a non-null Action alongside the
            # failure (every OTHER failure path in this file -- refusals,
            # read-back failures, PATCH/POST failures -- leaves Action=$null
            # on Success=$false). Record the distinct
            # 'landed-postfix-failed' status in that case so the operator
            # can tell "nothing written" from "written but incomplete"
            # without cross-referencing Results[].CommentId/Reason by hand.
            if ($null -ne $writeResult.Action) {
                $artifacts["entry-$($i + 1)"] = 'landed-postfix-failed'
            }
            else {
                $artifacts["entry-$($i + 1)"] = 'failed'
            }
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

    # M13 fix (issue #893 s11): -BurstManifest/-ManifestPath itself was
    # missing the same real path-containment bounding
    # (Resolve-MarkerScratchBoundedPath) that Read-MarkerScratchBoundedBodyFile
    # already applies to every -BodyFile / manifest bodyFile entry -- the
    # manifest path argument was an existence-oracle plus an unbounded
    # error-message path echo for any path on disk, arbitrary-file-outside-
    # the-scratch-root included. Bound it here BEFORE Test-Path (a plain
    # Test-Path on an unbounded path is itself part of the oracle this
    # closes), mirroring the exact same helper and refusal shape every other
    # scratch-bounded path in this file already uses.
    $manifestBounded = Resolve-MarkerScratchBoundedPath -Path $ManifestPath -ScratchRoot $ScratchRoot
    if (-not $manifestBounded.InBounds) {
        return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (-BurstManifest out of bounds): $($manifestBounded.Reason)"; Results = [object[]]@(); Artifacts = [ordered]@{} }
    }
    $ManifestPath = $manifestBounded.ResolvedPath
    # M22 fix (issue #893 s11): every refusal message below that echoes
    # $ManifestPath now routes through the same length-bounding helper
    # (893-D6 invariant) every other echoed value in this file already uses
    # -- $ManifestPath itself previously bypassed it, an inconsistency with
    # no principled reason (a resolved scratch-bounded path is not exempt
    # from the same "never dump an oversized field verbatim" contract).
    $echoedManifestPath = script:ConvertTo-MarkerRefusalEcho -Value $ManifestPath

    # F3 fix (PR #917 review): Get-Content itself must be inside the
    # try/catch, not just ConvertFrom-Json below. A directory path (or any
    # other unreadable target) previously reached Get-Content OUTSIDE any
    # try/catch: under the default $ErrorActionPreference=Continue it
    # emitted a non-terminating error and left $rawManifest = $null,
    # silently falling through to a misleading "manifest carries zero
    # entries" refusal (wrong stated cause); under the documented-legal
    # in-process `&` invocation mode (which callers may run with
    # EAP=Stop), the same Get-Content call throws uncaught instead. The
    # sibling Read-MarkerScratchBoundedBodyFile was already hardened for
    # exactly this class ("Refuses (never throws)") -- this closes the
    # same gap here.
    try {
        $rawManifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop
    }
    catch {
        $echoed = script:ConvertTo-MarkerRefusalEcho -Value $_.Exception.Message
        return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (manifest '$echoedManifestPath' could not be read): $echoed"; Results = [object[]]@(); Artifacts = [ordered]@{} }
    }
    try {
        $parsed = $rawManifest | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $echoed = script:ConvertTo-MarkerRefusalEcho -Value $_.Exception.Message
        return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath'): not parseable JSON -- $echoed"; Results = [object[]]@(); Artifacts = [ordered]@{} }
    }

    $rawEntries = @($parsed)
    if ($rawEntries.Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath'): manifest carries zero entries"; Results = [object[]]@(); Artifacts = [ordered]@{} }
    }

    $requiredFields = @('family', 'number', 'targetSurface', 'marker', 'bodyFile')
    $resolvedEntries = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $rawEntries.Count; $i++) {
        $entryIndex = $i + 1
        $rawEntry = $rawEntries[$i]
        foreach ($field in $requiredFields) {
            $value = $rawEntry.$field
            if ($null -eq $value -or ([string]$value).Trim().Length -eq 0) {
                return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath', entry $entryIndex): missing required field '$field'"; Results = [object[]]@(); Artifacts = [ordered]@{} }
            }
        }

        # M4 fix (issue #893 s11): explicit enum validation HERE, before
        # targetSurface ever reaches a ValidateSet-bound parameter
        # downstream (Test-MarkerCandidatePreflight / Invoke-PersistMarkerWrite)
        # -- this is what makes the common case (a malformed targetSurface
        # value on any entry, not just entry 1) a clean, diagnosable
        # manifest-level refusal instead of relying on exception containment
        # deeper in the call chain.
        $targetSurfaceValue = [string]$rawEntry.targetSurface
        if ($targetSurfaceValue -notin @('issue', 'pull-request')) {
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath', entry $entryIndex): field 'targetSurface' must be 'issue' or 'pull-request', got '$(script:ConvertTo-MarkerRefusalEcho -Value $targetSurfaceValue)'"; Results = [object[]]@(); Artifacts = [ordered]@{} }
        }

        # F5 fix (PR #917 review): a bare `[int]$rawEntry.number` cast
        # silently COERCES any numeric-shaped JSON value instead of
        # refusing it -- a JSON float like 123.5 rounds to 124 (writing to
        # a DIFFERENT issue number), a JSON boolean `true`/`false` casts to
        # 1/0, and non-positive integers were never rejected at all. The
        # try/catch alone only ever caught non-numeric STRINGS (the only
        # shape the cast actually throws on); it silently passed every one
        # of these numeric-but-wrong-shape values through uncaught.
        # Validate the raw JSON type/value BEFORE casting: refuse a
        # boolean, refuse any value with a fractional part, and refuse
        # non-positive results -- naming the entry index and the offending
        # value (length-bounded via the existing echo-cap convention)
        # rather than silently rounding/coercing.
        $rawNumberValue = $rawEntry.number
        if ($rawNumberValue -is [bool]) {
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath', entry $entryIndex): field 'number' must be a whole number, got a JSON boolean ($(script:ConvertTo-MarkerRefusalEcho -Value ([string]$rawNumberValue)))"; Results = [object[]]@(); Artifacts = [ordered]@{} }
        }
        elseif ($rawNumberValue -is [double] -or $rawNumberValue -is [single] -or $rawNumberValue -is [decimal]) {
            if ($rawNumberValue -ne [Math]::Truncate($rawNumberValue)) {
                return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath', entry $entryIndex): field 'number' must be a whole number, got a fractional value ($(script:ConvertTo-MarkerRefusalEcho -Value ([string]$rawNumberValue))) -- never silently rounded"; Results = [object[]]@(); Artifacts = [ordered]@{} }
            }
            $number = [int64]$rawNumberValue
        }
        else {
            try {
                $number = [int64]$rawNumberValue
            }
            catch {
                return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath', entry $entryIndex): field 'number' is not a valid integer ($(script:ConvertTo-MarkerRefusalEcho -Value ([string]$rawEntry.number)))"; Results = [object[]]@(); Artifacts = [ordered]@{} }
            }
        }
        if ($number -le 0) {
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath', entry $entryIndex): field 'number' must be a positive integer, got ($(script:ConvertTo-MarkerRefusalEcho -Value ([string]$rawNumberValue)))"; Results = [object[]]@(); Artifacts = [ordered]@{} }
        }

        $bodyFileResult = Read-MarkerScratchBoundedBodyFile -BodyFile ([string]$rawEntry.bodyFile) -ScratchRoot $ScratchRoot
        if (-not $bodyFileResult.Success) {
            return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (manifest '$echoedManifestPath', entry $entryIndex, family '$($rawEntry.family)'): $($bodyFileResult.Reason)"; Results = [object[]]@(); Artifacts = [ordered]@{} }
        }

        # M12 fix (issue #893 s11): noPreserve is optional (defaults $false
        # when absent/$null), but when present it must be a REAL JSON
        # boolean (ConvertFrom-Json already types `true`/`false` literals as
        # [bool]) or an explicit case-insensitive 'true'/'false' STRING --
        # never a bare `[bool]$value` cast on whatever JSON shape showed up.
        # A bare cast silently coerces ANY non-empty string (including the
        # realistic hand-authoring slip of JSON-quoting the boolean, e.g.
        # "noPreserve": "false") to $true, silently disabling all
        # write-back preservation with a Success=$true confirmation -- the
        # exact AC5 data-loss path the preserve post-step exists to prevent.
        # Refuse (naming the entry index and the offending value) on any
        # other shape (number, array, object, or an unrecognized string)
        # instead of guessing.
        $noPreserveValue = $false
        if ($null -ne $rawEntry.noPreserve) {
            if ($rawEntry.noPreserve -is [bool]) {
                $noPreserveValue = $rawEntry.noPreserve
            }
            elseif ($rawEntry.noPreserve -is [string] -and $rawEntry.noPreserve -match '(?i)^(true|false)$') {
                $noPreserveValue = ($rawEntry.noPreserve.ToLowerInvariant() -eq 'true')
            }
            else {
                # P12 fix (issue #893 s11 post-fix): this branch is already
                # nested inside `if ($null -ne $rawEntry.noPreserve)` above,
                # so $rawEntry.noPreserve can never be $null here -- the
                # dead `if ($null -eq $rawEntry.noPreserve) { 'null' }`
                # conditional was unreachable.
                $offendingType = $rawEntry.noPreserve.GetType().Name
                return [PSCustomObject]@{ Success = $false; Reason = "persist-marker: REFUSED (malformed manifest '$echoedManifestPath', entry $entryIndex): field 'noPreserve' must be a JSON boolean (or the case-insensitive string 'true'/'false'), got '$(script:ConvertTo-MarkerRefusalEcho -Value ([string]$rawEntry.noPreserve))' (type $offendingType)"; Results = [object[]]@(); Artifacts = [ordered]@{} }
            }
        }

        $resolvedEntries.Add([PSCustomObject]@{
                Family        = [string]$rawEntry.family
                Number        = $number
                TargetSurface = [string]$rawEntry.targetSurface
                Marker        = [string]$rawEntry.marker
                Body          = $bodyFileResult.Body
                NoPreserve    = $noPreserveValue
            }) | Out-Null
    }

    return Invoke-PersistMarkerBurst -Owner $Owner -Repo $Repo -Entries ([object[]]$resolvedEntries.ToArray())
}
