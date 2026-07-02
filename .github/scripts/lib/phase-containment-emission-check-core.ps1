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

# -Surface uses the core's stage names exactly (StageProjections keys).
# id-domain per surface:
#   code-review                -> Id = PR number,    blocks live on PR comments
#   design-challenge            -> Id = issue number, blocks live on issue comments (design-phase-complete-{ID})
#   plan-stress-test            -> Id = issue number, blocks live on issue comments (plan-issue-{ID})
# Callers must pass the matching domain; this module does not verify it.
$script:ValidEmissionCheckSurfaces = @('code-review', 'design-challenge', 'plan-stress-test')

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

    if ($Surface -eq 'design-challenge') {
        return [regex]::IsMatch($Body, '(?m)^finding_dispositions\s*:\s*$')
    }

    # code-review and plan-stress-test share the judge-rulings marker head.
    return [regex]::IsMatch($Body, '<!--\s*judge-rulings\b')
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
    $bareHeadMatch = [regex]::Match($Body, '<!--\s*judge-rulings\b')

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

    $region = $Body.Substring($regionStart, $regionEnd - $regionStart)

    # required_fixes: is a parallel decoy list present in the intake variant
    # (PR #775). Strip it (and everything after it) before scanning, so its
    # `id:`/nested keys can never be miscounted as findings.
    $requiredFixesMatch = [regex]::Match($region, '(?m)^required_fixes\s*:\s*$')
    if ($requiredFixesMatch.Success) {
        $region = $region.Substring(0, $requiredFixesMatch.Index)
    }

    # Detect vocabulary in priority order: four-value variant > intake variant > canonical.
    $hasDismiss = $region -match '(?m)disposition\s*:\s*Dismiss\b'
    $hasFixNow = $region -match '(?m)disposition\s*:\s*(Fix-now|Fix-in-PR|Defer)\b'
    $hasReviewModeIntake = $region -match "review_mode\s*:\s*['""]?github-intake-proxy-prosecution"
    $hasAcceptReject = $region -match '(?m)disposition\s*:\s*(accept|reject)\b'
    $hasJudgeRuling = $region -match '(?m)judge_ruling\s*:\s*\S'

    if ($hasDismiss -or $hasFixNow) {
        # Four-value variant: sustained = every finding whose disposition is not Dismiss.
        $dispositionMatches = [regex]::Matches($region, '(?m)disposition\s*:\s*(Fix-now|Fix-in-PR|Defer|Dismiss)\b')
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
        $dispositionMatches = [regex]::Matches($findingsRegion, '(?m)disposition\s*:\s*(accept|reject)\b')
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
        if (Test-EmissionMarkerPresent -Surface $Surface -Body $body) {
            $sustainedResult = Get-SustainedFindingCount -Surface $Surface -Body $body
            if ($sustainedResult.ParseStatus -eq 'could-not-verify') {
                $anyCouldNotVerify = $true
            }
            $totalSustained += $sustainedResult.SustainedCount
        }
        # else: no recognizable marker head in this body — ordinary PR/issue
        # chatter, not a judge-rulings surface. Skip it (0 contribution,
        # does not poison ParseStatus). See Get-EmissionGap's .DESCRIPTION.

        $blocks = Get-PhaseContainmentBlock -Text $body -Id $Id
        if ($blocks) {
            $totalBlocks += $blocks.Count
        }
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
          5. Post-write verify: GET again and assert the original body is a
             byte-identical prefix of the new body (encoding round-trip guard).

        Any mismatch at any step is fail-loud: the function returns
        Success=$false with a Reason describing the failure, and performs no
        further action. This function never truncates or overwrites existing
        comment content.
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

    # --- 5. Post-write verify: GET again and assert byte-identical prefix. ---
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
    if (-not $verifyBody.StartsWith($originalBody, [System.StringComparison]::Ordinal)) {
        [Console]::Error.WriteLine("Add-CommentBlocks: post-write verify FAILED — original body is not a byte-identical prefix of the new body for comment $CommentId.")
        return [PSCustomObject]@{ Success = $false; Reason = 'Post-write verify failed: original body is not a byte-identical prefix of the new body' }
    }

    return [PSCustomObject]@{ Success = $true; Reason = $null }
}

#endregion
