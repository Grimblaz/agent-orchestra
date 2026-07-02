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
        internal parsers use for each surface, so head detection here can
        never diverge from head detection there:
          code-review / plan-stress-test: bare `<!-- judge-rulings` or
            attributed `<!-- judge-rulings pr=N -->`
          design-challenge: `finding_dispositions:` YAML key

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
    $headMatch = [regex]::Match($Body, '<!--\s*judge-rulings(?:\s|-->|$)')
    if (-not $headMatch.Success) { return $false }
    $windowEnd = [Math]::Min($Body.Length, $headMatch.Index + $headMatch.Length + $lookaheadWindow)
    $window = $Body.Substring($headMatch.Index, $windowEnd - $headMatch.Index)
    return [regex]::IsMatch($window, '(?m)(?:^\s*|[{,]\s*)(disposition|judge_ruling|verdict|finding_key)\s*:')
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
        return Get-DesignChallengeSustainedCountInternal -Body $Body
    }

    # code-review and plan-stress-test share the judge-rulings marker shape.
    return Get-JudgeRulingsSustainedCountInternal -Body $Body
}

#endregion

#region Get-JudgeRulingsSustainedCountInternal (private)

function script:Get-JudgeRulingsSustainedCountInternal {
    param(
        [Parameter(Mandatory)][string]$Body
    )

    # Isolate the authoritative marker region first. Match both marker-head
    # forms observed live:
    #   - attributed, self-closing: `<!-- judge-rulings pr=N -->` (PR #778) —
    #     the tag closes immediately; YAML content follows the tag.
    #   - bare, unclosed on the head line: `<!-- judge-rulings` (PRs #775/#781)
    #     — the tag's `-->` closes only at the END of the YAML content.
    $attributedHeadMatch = [regex]::Match($Body, '<!--\s*judge-rulings\s+pr=\d+\s*-->')
    # M9 fix: see Test-EmissionMarkerPresent's identical fix for the
    # superstring-marker-name rationale (e.g. '<!-- judge-rulings-report -->'
    # must never match this real judge-rulings head).
    $bareHeadMatch = [regex]::Match($Body, '<!--\s*judge-rulings(?:\s|-->|$)')

    $headMatch = $null
    if ($attributedHeadMatch.Success) {
        $headMatch = $attributedHeadMatch
    }
    elseif ($bareHeadMatch.Success) {
        $headMatch = $bareHeadMatch
    }

    if (-not $headMatch -or -not $headMatch.Success) {
        return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    $regionStart = $headMatch.Index + $headMatch.Length
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
        return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
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
        if ([regex]::IsMatch($between, '(?m)(?:^\s*|[{,]\s*)(disposition|judge_ruling|verdict|finding_key)\s*:')) {
            return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
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
    $keyAnchor = '(?:^\s*|[{,]\s*)'
    $hasDismiss = $region -match "(?m)${keyAnchor}disposition\s*:\s*Dismiss\b"
    $hasFixNow = $region -match "(?m)${keyAnchor}disposition\s*:\s*(Fix-now|Fix-in-PR|Defer)\b"
    $hasReviewModeIntake = $region -match "review_mode\s*:\s*['""]?github-intake-proxy-prosecution"
    $hasAcceptReject = $region -match "(?m)${keyAnchor}disposition\s*:\s*(accept|reject)\b"
    $hasJudgeRuling = $region -match '(?m)judge_ruling\s*:\s*\S'

    if ($hasDismiss -or $hasFixNow) {
        # Four-value variant: sustained = every finding whose disposition is not Dismiss.
        $dispositionMatches = [regex]::Matches($region, "(?m)${keyAnchor}disposition\s*:\s*(Fix-now|Fix-in-PR|Defer|Dismiss)\b")
        if ($dispositionMatches.Count -eq 0) {
            return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $sustained = @($dispositionMatches | Where-Object { $_.Groups[1].Value -ne 'Dismiss' })
        return [PSCustomObject]@{ SustainedCount = $sustained.Count; ParseStatus = 'ok' }
    }

    if ($hasReviewModeIntake -or $hasAcceptReject) {
        # Intake-mode variant: sustained iff disposition: accept, counted only
        # inside the findings: list (region already excludes required_fixes:).
        $findingsMatch = [regex]::Match($region, '(?ms)^findings\s*:\s*$(.*)')
        if (-not $findingsMatch.Success) {
            return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $findingsRegion = $findingsMatch.Groups[1].Value
        $dispositionMatches = [regex]::Matches($findingsRegion, "(?m)${keyAnchor}disposition\s*:\s*(accept|reject)\b")
        if ($dispositionMatches.Count -eq 0) {
            return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $sustained = @($dispositionMatches | Where-Object { $_.Groups[1].Value -eq 'accept' })
        return [PSCustomObject]@{ SustainedCount = $sustained.Count; ParseStatus = 'ok' }
    }

    if ($hasJudgeRuling) {
        # Canonical judge-rulings variant: sustained iff judge_ruling: sustained
        # (NOT defense-sustained). judge_ruling is a closed 2-value enum per
        # skills/review-judgment/SKILL.md:150 ('sustained' or 'defense-sustained');
        # any other value is unrecognized vocabulary -> could-not-verify (DD3),
        # never silently treated as "not sustained".
        $rulingMatches = [regex]::Matches($region, '(?m)judge_ruling\s*:\s*(\S+)')
        $unrecognized = @($rulingMatches | Where-Object {
                $val = $_.Groups[1].Value.TrimEnd(',')
                $val -ne 'sustained' -and $val -ne 'defense-sustained'
            })
        if ($unrecognized.Count -gt 0) {
            return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
        }
        $sustained = @($rulingMatches | Where-Object { $_.Groups[1].Value.TrimEnd(',') -eq 'sustained' })
        return [PSCustomObject]@{ SustainedCount = $sustained.Count; ParseStatus = 'ok' }
    }

    # Marker present but vocabulary unrecognized.
    return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
}

#endregion

#region Get-DesignChallengeSustainedCountInternal (private)

function script:Get-DesignChallengeSustainedCountInternal {
    param(
        [Parameter(Mandatory)][string]$Body
    )

    $headMatch = [regex]::Match($Body, '(?m)^finding_dispositions\s*:\s*$')
    if (-not $headMatch.Success) {
        return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    $regionStart = $headMatch.Index + $headMatch.Length
    $closeFenceIdx = $Body.IndexOf('```', $regionStart, [System.StringComparison]::Ordinal)
    $region = if ($closeFenceIdx -ge 0) {
        $Body.Substring($regionStart, $closeFenceIdx - $regionStart)
    }
    else {
        $Body.Substring($regionStart)
    }

    $dispositionMatches = [regex]::Matches($region, '(?m)disposition\s*:\s*(incorporate|escalate|dismiss)\b')
    if ($dispositionMatches.Count -eq 0) {
        return [PSCustomObject]@{ SustainedCount = 0; ParseStatus = 'could-not-verify' }
    }

    $sustained = @($dispositionMatches | Where-Object { $_.Groups[1].Value -ne 'dismiss' })
    return [PSCustomObject]@{ SustainedCount = $sustained.Count; ParseStatus = 'ok' }
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
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Bodies,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][ValidateSet('code-review', 'design-challenge', 'plan-stress-test')][string]$Surface
    )

    $totalSustained = 0
    $totalBlocks = 0
    $anyCouldNotVerify = $false

    foreach ($body in $Bodies) {
        $bodyHasMarker = Test-EmissionMarkerPresent -Surface $Surface -Body $body

        if ($bodyHasMarker) {
            $sustainedResult = Get-SustainedFindingCount -Surface $Surface -Body $body
            if ($sustainedResult.ParseStatus -eq 'could-not-verify') {
                $anyCouldNotVerify = $true
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

    return [PSCustomObject]@{
        SustainedCount = $totalSustained
        BlockCount     = $totalBlocks
        Gap            = $gap
        ParseStatus    = $parseStatus
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
