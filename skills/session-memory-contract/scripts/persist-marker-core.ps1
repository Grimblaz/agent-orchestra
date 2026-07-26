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
    Non-goals (explicit, per s4's requirement contract): no post-step /
    write-back-preserve logic (s5); no frame-slices or
    design-phase-complete finding_dispositions validator wiring (deferred
    -- see this file's top-of-file s4 addition note); dot-sourcing
    .github/scripts/lib/frame-engagement-record-core.ps1 before this file
    is the CALLER's responsibility (mirrors the existing
    marker-transport-core.ps1 convention) -- Invoke-EngagementRecordValidatorAdapter
    calls Read-EngagementRecords unqualified and fails closed with a
    diagnosable message if it is not in scope.
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
        PostStep is still carried as a reserved field name (always $null in
        this slice) so s5 (post-steps / write-back-preserve) has a stable
        place to assign concrete post-step names -- this file never reads
        or invokes it. ValidatorAdapter is now populated for the families
        s4's requirement contract names an adapter for (own-marker/
        cross-marker hygiene runs unconditionally regardless of this
        field's value; see Test-MarkerPayloadHygiene and
        Invoke-MarkerValidatorAdapter below).

        Rows are grounded in already-documented marker families (this
        repo's own CLAUDE.md, skills/session-memory-contract/references/handoff-markers.md,
        and 893-D3's family table) rather than invented: plan-issue and
        design-phase-complete are upsert (both are found-or-created once,
        then repeatedly patched, as persist-phase-ledger-core.ps1's own
        plan/design modes already do today); experience-owner-complete,
        review-judge-produced, engagement-record, review-dispositions, and
        credit-input are post-new (freshly posted completion/sentinel/
        deferred-emission comments -- CLAUDE.md documents
        review-judge-produced as "written as a separate PR comment";
        skills/frame-credit-emission/SKILL.md documents credit-input as
        posted "immediately after the agent's completion marker comment").
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
        Invoke-MarkerValidatorAdapter's dispatch switch], PostStep [string,
        always $null in this slice].
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
            PostStep          = $null
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
# Write shapes.
# ---------------------------------------------------------------------------

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

    $confirmation = "persist-marker-core: family '$Family' comment $newId posted"
    Write-Host $confirmation
    return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $newId; Action = 'posted'; Confirmation = $confirmation; Reason = $null }
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
        $confirmation = "persist-marker-core: family '$Family' comment $newId created"
        Write-Host $confirmation
        return [PSCustomObject]@{ Success = $true; Family = $Family; CommentId = $newId; Action = 'created'; Confirmation = $confirmation; Reason = $null }
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
        [Parameter(Mandatory)][string]$Body
    )

    $allRows = @(Get-MarkerFamilyRegistry)
    $row = @($allRows | Where-Object { $_.Family -eq $Family })
    if ($row.Count -eq 0) {
        return script:New-MarkerRefusal -Family $Family -Target "$TargetSurface/$Number" -Detail "unknown marker family '$Family' -- not present in the family registry"
    }
    $familyRow = $row[0]

    # Surface preflight -- see this file's header for why this compares
    # declared surfaces rather than performing a live lookup.
    if ($familyRow.TargetSurface -ne $TargetSurface) {
        return script:New-MarkerRefusal -Family $Family -Target "$TargetSurface/$Number" -Detail "surface mismatch: registry declares '$($familyRow.TargetSurface)' but this write was targeted at '$TargetSurface'"
    }

    $target = "$TargetSurface/$Number"

    # 893-D7 payload hygiene -- runs unconditionally for every family,
    # before any network write. See Test-MarkerPayloadHygiene's own
    # .SYNOPSIS for the two distinct refusal rules.
    $hygieneDetail = script:Test-MarkerPayloadHygiene -Family $Family -Marker $Marker -Body $Body -Registry $allRows
    if ($null -ne $hygieneDetail) {
        return script:New-MarkerRefusal -Family $Family -Target $target -Detail $hygieneDetail
    }

    # Per-family validator adapter (s4 requirement contract) -- validates
    # the marker-composed candidate (this -Body, already carrying -Marker),
    # never the raw payload. Runs before any network write; a refusal here
    # is fail-closed (adapter infrastructure failure is refused, never
    # treated as "no findings").
    if (-not [string]::IsNullOrWhiteSpace($familyRow.ValidatorAdapter)) {
        $adapterRefusal = script:Invoke-MarkerValidatorAdapter -ValidatorAdapter $familyRow.ValidatorAdapter -Family $Family -Target $target -Marker $Marker -Body $Body -Number $Number
        if ($null -ne $adapterRefusal) {
            return $adapterRefusal
        }
    }

    $ghType = if ($TargetSurface -eq 'pull-request') { 'pr' } else { 'issue' }

    switch ($familyRow.WriteShape) {
        'post-new' { return script:Invoke-MarkerPostNewWrite -Owner $Owner -Repo $Repo -Family $Family -Type $ghType -Number $Number -Marker $Marker -Body $Body }
        'upsert' { return script:Invoke-MarkerUpsertWrite -Owner $Owner -Repo $Repo -Family $Family -Type $ghType -Number $Number -Marker $Marker -Body $Body }
        default { return script:New-MarkerRefusal -Family $Family -Target $target -Detail "unknown write shape '$($familyRow.WriteShape)' for family '$Family'" }
    }
}
