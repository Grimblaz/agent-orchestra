#Requires -Version 7.0
<#
.SYNOPSIS
    Corpus-measurement classifier for the Grounding Evidence sentinel/heading
    pair (issue #866 AC7).

.DESCRIPTION
    Classifies a design-issue body into exactly one of three buckets:

      canonical:     the <!-- grounding-evidence --> sentinel is immediately
                      followed (blank lines allowed, nothing else) by the
                      **Grounding Evidence** bold heading, with BOTH
                      occurrences outside any fenced code block (``` or ~~~)
                      and outside any inline code span (single backticks).
      non-canonical: some OTHER Grounding Evidence heading shape is present
                      (a bare H2 `## Grounding Evidence` heading, OR a
                      `**Grounding Evidence**` bold heading with no adjacent
                      sentinel), outside code spans, but not the canonical
                      adjacent pair.
      absent:        neither of the above -- including the case where the
                      sentinel and/or bold literal appear only inside code
                      spans, or appear in prose but not adjacent to each
                      other, or do not appear at all.

    Detection is structural (span-aware pattern matching), not
    substring-counting -- a body that merely MENTIONS the sentinel or bold
    literal in prose (e.g. quoting the contract itself) must not be counted
    as a real persisted block. See
    .github/scripts/Tests/grounding-evidence-corpus-check.Tests.ps1 fixture 5
    for the load-bearing anti-vacuity regression case this guards against.

    Top-level/CLI execution below is guarded behind the
    `$MyInvocation.InvocationName -eq '.'` idiom (matching
    .github/scripts/phase-containment-emission-check.ps1:475) -- dot-sourcing
    this file only makes Get-GroundingEvidenceBucket (and its private
    helpers) available; it never parses CLI args, calls gh, or exits.

    ==========================================================================
    HONESTY DISCLOSURE (load-bearing -- read before trusting any output below)
    ==========================================================================
    This script is an END-STATE measurement only. It classifies whatever is
    CURRENTLY persisted in an issue body/comment right now -- it cannot
    distinguish a Grounding Evidence block a designer persisted live at
    Solution-Designer Stage 4 from one a human backfilled later at a
    downstream checkpoint (both #863 and #842 are real examples of the
    latter). A high canonical rate reported by this script is ALSO
    consistent with "designers still drop the block and a downstream lens
    (e.g. the Issue-Planner grounding-evidence standards check) catches and
    backfills it" -- do NOT read a high canonical rate here as proof that the
    upstream fix (issue #866) worked. This script intentionally implements
    NO backfill-detection heuristic (rejected as fragile in the #866 plan);
    this disclosure is the chosen mitigation instead.
    ==========================================================================

.PARAMETER IssueNumbers
    CLI mode only. Explicit cohort of issue numbers to classify.

.PARAMETER Discover
    CLI mode only. Builds a candidate cohort via
    `gh search issues 'design-phase-complete in:comments' --repo {owner}/{repo}`,
    then VERIFIES each candidate actually carries a
    `<!-- design-phase-complete-{N} -->` marker comment before including it --
    the search endpoint is a best-effort, paginated superset that also
    matches prose mentions of the phrase, not just real markers (a live probe
    during planning found #571, #866, #648, #253 among false positives for
    this exact query). -Discover is a convenience for finding candidates, not
    a completeness guarantee -- it will not necessarily find every issue that
    ever carried the marker.

.PARAMETER Since
    CLI mode only. Filters the (explicit or discovered) cohort by the
    `design-phase-complete` marker createdAt timestamp belonging to the
    COMMENT itself (NOT the createdAt belonging to the issue) -- so a
    post-fix cohort can be separated from a pre-fix baseline. Interpreted as
    UTC: the supplied clock time is treated as a UTC instant (not converted
    from the local timezone of the runner), and compared against the
    createdAt of the marker parsed as UTC.

.PARAMETER Owner
    CLI mode only. GitHub repository owner. Resolved via
    `git remote get-url origin` when not supplied.

.PARAMETER Repo
    CLI mode only. GitHub repository name. Resolved via
    `git remote get-url origin` when not supplied.

.PARAMETER GhCliPath
    Path to the gh CLI executable. Defaults to 'gh'. Overridable for test
    injection.

.OUTPUTS
    CLI mode prints the honesty disclosure, a per-issue bucket line, and an
    aggregate "N of M canonical" summary to stdout.

.EXAMPLE
    pwsh ./.github/scripts/grounding-evidence-corpus-check.ps1 -IssueNumbers 863,842
.EXAMPLE
    pwsh ./.github/scripts/grounding-evidence-corpus-check.ps1 -Discover -Since '2026-07-01'

.NOTES
    Read-only by design: every gh invocation in this script is a read
    (`gh search issues`, `gh issue view --json body,comments`). No writes, no
    comments, no labels -- this is a maintainer diagnostic, never a gate. No
    CI wiring, no session-startup wiring.
#>

[CmdletBinding()]
param(
    [int[]]$IssueNumbers = @(),
    [switch]$Discover,
    [Nullable[datetime]]$Since = $null,
    [string]$Owner = '',
    [string]$Repo = '',
    [string]$GhCliPath = 'gh'
)

# =============================================================================
# Get-GroundingEvidenceBucket and private span-detection helpers.
# Safe to dot-source in isolation -- no side effects at this scope level.
# =============================================================================

$script:GroundingEvidenceSentinelLiteral = '<!-- grounding-evidence -->'
$script:GroundingEvidenceBoldLiteral     = '**Grounding Evidence**'

function script:Test-GroundingEvidenceIndexInSpan {
    <#
    .SYNOPSIS
        Reports whether a character offset falls inside any of the supplied
        [Start,End) spans. Same idiom as
        Test-IndexInBlockScalarSpan in lib/phase-containment-core.ps1, reused
        here for markdown code-span exclusion instead of YAML block scalars.
    #>
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Spans
    )
    foreach ($span in $Spans) {
        if ($Index -ge $span.Start -and $Index -lt $span.End) {
            return $true
        }
    }
    return $false
}

function script:Get-GroundingEvidenceCodeSpans {
    <#
    .SYNOPSIS
        Computes every fenced-code-block and inline-code-span character
        range in a markdown body, so callers can exclude structural-looking
        substrings that fall inside code (fences or backtick spans) from
        being treated as real markdown structure. Same
        compute-spans-then-position-check technique as
        Get-BlockScalarSpans / Test-IndexInBlockScalarSpan in
        lib/phase-containment-core.ps1 (that helper handles YAML block
        scalars; this one handles markdown fences/backticks).
    .PARAMETER Text
        The text to scan.
    .OUTPUTS
        Array of [PSCustomObject]@{ Start; End } character-offset spans
        (End exclusive). Empty array when none found.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $spans = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ([string]::IsNullOrEmpty($Text)) {
        return , $spans.ToArray()
    }

    # --- Fenced code blocks (``` or ~~~), optionally indented up to 3 spaces ---
    $fenceLinePattern = '(?m)^[ \t]{0,3}(`{3,}|~{3,})[^\r\n]*$'
    $fenceMatches = [regex]::Matches($Text, $fenceLinePattern)
    $i = 0
    while ($i -lt $fenceMatches.Count) {
        $openMatch = $fenceMatches[$i]
        $fenceChar = $openMatch.Groups[1].Value[0]
        $fenceLen  = $openMatch.Groups[1].Value.Length
        $spanStart = $openMatch.Index
        $closeIdx  = -1
        for ($j = $i + 1; $j -lt $fenceMatches.Count; $j++) {
            $candidate = $fenceMatches[$j]
            if ($candidate.Groups[1].Value[0] -eq $fenceChar -and $candidate.Groups[1].Value.Length -ge $fenceLen) {
                $closeIdx = $j
                break
            }
        }
        if ($closeIdx -ge 0) {
            $closeMatch = $fenceMatches[$closeIdx]
            $spans.Add([PSCustomObject]@{ Start = $spanStart; End = ($closeMatch.Index + $closeMatch.Length) })
            $i = $closeIdx + 1
        }
        else {
            # Unclosed fence: per CommonMark, extends to end of document.
            $spans.Add([PSCustomObject]@{ Start = $spanStart; End = $Text.Length })
            break
        }
    }
    $fenceSpans = $spans.ToArray()

    # --- Inline code spans: runs of N backticks, closed by the next run of
    #     exactly N backticks that is not itself already inside a fenced
    #     block AND is not separated from the open run by a blank line. Per
    #     CommonMark, an inline code span cannot contain a blank line /
    #     paragraph break -- a close-run candidate on the far side of one is
    #     rejected (skipped past), not treated as a valid close. A run with
    #     no matching close is literal text (CommonMark), not a code span,
    #     and is skipped. ---
    $runMatches = [regex]::Matches($Text, '`+')
    $k = 0
    while ($k -lt $runMatches.Count) {
        $openRun = $runMatches[$k]
        if (script:Test-GroundingEvidenceIndexInSpan -Index $openRun.Index -Spans $fenceSpans) {
            $k++
            continue
        }
        $runLen   = $openRun.Length
        $closeIdx = -1
        for ($m = $k + 1; $m -lt $runMatches.Count; $m++) {
            $candidate = $runMatches[$m]
            if (script:Test-GroundingEvidenceIndexInSpan -Index $candidate.Index -Spans $fenceSpans) { continue }
            if ($candidate.Length -ne $runLen) { continue }
            $betweenStart = $openRun.Index + $openRun.Length
            $betweenText  = $Text.Substring($betweenStart, $candidate.Index - $betweenStart)
            if ($betweenText -match '(?s)\r?\n[ \t]*\r?\n') {
                # Paragraph break between open run and this candidate --
                # not a valid close per CommonMark. Skip past it; any later
                # candidate is even further past the same break.
                continue
            }
            $closeIdx = $m
            break
        }
        if ($closeIdx -ge 0) {
            $closeRun = $runMatches[$closeIdx]
            $spans.Add([PSCustomObject]@{ Start = $openRun.Index; End = ($closeRun.Index + $closeRun.Length) })
            $k = $closeIdx + 1
        }
        else {
            $k++
        }
    }

    return , $spans.ToArray()
}

function Get-GroundingEvidenceBucket {
    <#
    .SYNOPSIS
        Classifies the Grounding Evidence heading shape of a body.
    .PARAMETER BodyText
        The full issue/comment body text to classify.
    .OUTPUTS
        [string] one of the literal strings 'canonical', 'non-canonical',
        'absent'.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BodyText
    )

    if ([string]::IsNullOrEmpty($BodyText)) {
        return 'absent'
    }

    # Normalize line endings ONCE, here at the public entry point, before any
    # span computation or pattern matching. A real GitHub API body is
    # CRLF-terminated; in .NET, multiline `$` anchors immediately before `\n`
    # and `[^\r\n]*` stops before `\r`, so every `$`-anchored pattern in this
    # file (fence-line detection, H2 heading detection) would silently never
    # match against unnormalized CRLF text. Normalizing once here -- rather
    # than patching each regex -- keeps character-offset math (spans computed
    # against normalized text, matched against normalized text) internally
    # consistent. Private helpers below intentionally do NOT normalize so
    # they stay reusable with whatever text a caller passes them.
    $BodyText = $BodyText -replace "`r`n", "`n" -replace "`r", "`n"

    $codeSpans = script:Get-GroundingEvidenceCodeSpans -Text $BodyText

    # --- canonical: sentinel immediately followed (blank lines allowed,
    #     nothing else) by the bold heading, both outside code spans. ---
    $sentinelEsc = [regex]::Escape($script:GroundingEvidenceSentinelLiteral)
    $boldEsc     = [regex]::Escape($script:GroundingEvidenceBoldLiteral)
    $adjacencyPattern = "$sentinelEsc[ \t]*\n\s*($boldEsc)"
    $adjMatches = [regex]::Matches($BodyText, $adjacencyPattern)
    foreach ($adjMatch in $adjMatches) {
        $sentinelIdx = $adjMatch.Index
        $boldIdx     = $adjMatch.Groups[1].Index
        $sentinelInSpan = script:Test-GroundingEvidenceIndexInSpan -Index $sentinelIdx -Spans $codeSpans
        $boldInSpan     = script:Test-GroundingEvidenceIndexInSpan -Index $boldIdx -Spans $codeSpans
        if (-not $sentinelInSpan -and -not $boldInSpan) {
            return 'canonical'
        }
    }

    # --- non-canonical: a bare H2-H4 heading (case-insensitive heading
    #     text), or a bold heading with no canonical adjacent sentinel,
    #     either outside code spans. ---
    $h2Pattern  = '(?im)^[ \t]{0,3}#{2,4}[ \t]+Grounding Evidence\b'
    $h2Matches  = [regex]::Matches($BodyText, $h2Pattern)
    foreach ($h2Match in $h2Matches) {
        if (-not (script:Test-GroundingEvidenceIndexInSpan -Index $h2Match.Index -Spans $codeSpans)) {
            return 'non-canonical'
        }
    }

    # --- bold heading shape: `**Grounding Evidence**` anchored to the start
    #     of a line (leading whitespace allowed), consistent with the
    #     definition in the docstring of this bucket as a heading shape -- a
    #     mid-sentence prose mention (e.g. "...the **Grounding Evidence**
    #     block...") must not trigger this bucket. ---
    $boldHeadingPattern = "(?m)^[ \t]*($boldEsc)"
    $boldMatches = [regex]::Matches($BodyText, $boldHeadingPattern)
    foreach ($boldMatch in $boldMatches) {
        $boldIdx = $boldMatch.Groups[1].Index
        if (-not (script:Test-GroundingEvidenceIndexInSpan -Index $boldIdx -Spans $codeSpans)) {
            return 'non-canonical'
        }
    }

    return 'absent'
}

# =============================================================================
# CLI-only helpers (not exercised by the Pester fixtures -- require live gh).
# =============================================================================

function script:Resolve-GroundingEvidenceRepoSlug {
    <#
    .SYNOPSIS
        Resolves an 'owner/repo' slug from explicit -Owner/-Repo params, or
        falls back to parsing `git remote get-url origin` (as the regex idiom
        used by the Read-FindingDispositionIds function in
        lib/gate-reconciliation-core.ps1).
    .OUTPUTS
        [string] 'owner/repo', or '' if unresolvable.
    #>
    param(
        [string]$OwnerParam,
        [string]$RepoParam
    )
    if ($OwnerParam -and $RepoParam) {
        return "$OwnerParam/$RepoParam"
    }
    $remoteUrl = git remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
        return ''
    }
    $match = [regex]::Match($remoteUrl, 'github\.com[:/](.+?)(?:\.git)?$')
    if (-not $match.Success) {
        return ''
    }
    return $match.Groups[1].Value
}

function script:Find-GroundingEvidenceDiscoveredIssues {
    <#
    .SYNOPSIS
        Best-effort discovery of candidate issue numbers via
        `gh search issues`, then verifies each candidate actually carries a
        real `<!-- design-phase-complete-{N} -->` marker comment before
        returning it -- the search endpoint is a prose-matching superset,
        not a marker-verified list (live probe during planning found #571,
        #866, #648, #253 as false positives for this exact query).
    .NOTES
        `gh search issues` is best-effort and paginated by gh itself -- this
        is a convenience for finding candidates, not a completeness
        guarantee.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoSlug,
        [Parameter(Mandatory)][string]$GhCliPath
    )
    $verified = [System.Collections.Generic.List[int]]::new()

    $searchOutput = & $GhCliPath search issues 'design-phase-complete in:comments' --repo $RepoSlug --json number --limit 200 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($searchOutput)) {
        Write-Warning "grounding-evidence-corpus-check: gh search issues failed or returned nothing for $RepoSlug"
        return , $verified.ToArray()
    }

    $candidates = @()
    try {
        $candidates = @(($searchOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop | ForEach-Object { [int]$_['number'] })
    }
    catch {
        Write-Warning "grounding-evidence-corpus-check: could not parse gh search issues output: $($_.Exception.Message)"
        return , $verified.ToArray()
    }

    foreach ($candidateNumber in $candidates) {
        $marker = "<!-- design-phase-complete-$candidateNumber -->"
        $viewOutput = & $GhCliPath issue view $candidateNumber --repo $RepoSlug --json comments 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($viewOutput)) { continue }
        try {
            $viewParsed = ($viewOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            continue
        }
        $hasRealMarker = $false
        foreach ($commentNode in @($viewParsed['comments'])) {
            if ($null -eq $commentNode) { continue }
            try {
                $commentBody = [string]$commentNode['body']
            }
            catch {
                Write-Warning "grounding-evidence-corpus-check: could not read comment body for candidate #$candidateNumber ($($_.Exception.Message)); skipping comment"
                continue
            }
            if ($commentBody -like "*$marker*") {
                $hasRealMarker = $true
                break
            }
        }
        if ($hasRealMarker) {
            $verified.Add($candidateNumber)
        }
    }

    return , $verified.ToArray()
}

function script:Get-GroundingEvidenceIssueRecord {
    <#
    .SYNOPSIS
        Fetches the body + comments belonging to one issue, resolves the
        createdAt belonging to the design-phase-complete marker comment
        (for -Since filtering), and classifies the ISSUE BODY (never the
        marker comment) into a bucket.
    .OUTPUTS
        [PSCustomObject]@{ IssueNumber; Bucket; MarkerCreatedAt } or $null
        when the issue/marker could not be resolved.
    #>
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$RepoSlug,
        [Parameter(Mandatory)][string]$GhCliPath
    )
    $viewOutput = & $GhCliPath issue view $IssueNumber --repo $RepoSlug --json body,comments 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($viewOutput)) {
        Write-Warning "grounding-evidence-corpus-check: gh issue view failed for #$IssueNumber"
        return $null
    }
    try {
        $parsed = ($viewOutput | Out-String) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        Write-Warning "grounding-evidence-corpus-check: could not parse gh issue view output for #$IssueNumber"
        return $null
    }

    # Per D7 placement, the Grounding Evidence block is always persisted in
    # the issue BODY at Stage 4; the design-phase-complete-{N} comment is a
    # separate short completion marker (phase-summary + finding_dispositions
    # YAML) that never carries the grounding table, so only its createdAt is
    # extracted here, never its body text.
    $marker          = "<!-- design-phase-complete-$IssueNumber -->"
    $markerCreatedAt = $null
    foreach ($commentNode in @($parsed['comments'])) {
        if ($null -eq $commentNode) { continue }
        try {
            $body = [string]$commentNode['body']
        }
        catch {
            Write-Warning "grounding-evidence-corpus-check: could not read comment body for #$IssueNumber ($($_.Exception.Message)); treating record as unresolvable"
            return $null
        }
        if ($body -like "*$marker*") {
            $markerCreatedAt = $commentNode['createdAt']
            break
        }
    }

    $bucket = Get-GroundingEvidenceBucket -BodyText ([string]$parsed['body'])

    return [PSCustomObject]@{
        IssueNumber     = $IssueNumber
        Bucket          = $bucket
        MarkerCreatedAt = $markerCreatedAt
    }
}

# =============================================================================
# Top-level execution (skipped when dot-sourced).
# Detect dot-source: when invoked via `. path -IssueNumbers 1`, InvocationName
# is '.' (frame-credit-ledger.ps1 / phase-containment-emission-check.ps1
# idiom).
# =============================================================================
$isDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $isDotSourced) {
    Write-Output '=============================================================================='
    Write-Output 'HONESTY DISCLOSURE: this is an END-STATE measurement. It cannot distinguish a'
    Write-Output 'Grounding Evidence block persisted live at design time from one backfilled'
    Write-Output 'later at a downstream checkpoint (#863, #842 are real examples of the latter).'
    Write-Output 'A high canonical rate is ALSO consistent with "designers still drop it and a'
    Write-Output 'downstream lens still catches it" -- this output is NOT proof issue #866 fixed'
    Write-Output 'anything on its own.'
    Write-Output '=============================================================================='

    $repoSlug = script:Resolve-GroundingEvidenceRepoSlug -OwnerParam $Owner -RepoParam $Repo
    if ([string]::IsNullOrWhiteSpace($repoSlug)) {
        [Console]::Error.WriteLine('grounding-evidence-corpus-check: could not resolve owner/repo (supply -Owner/-Repo or run inside a repo with an origin remote)')
        exit 1
    }

    $cohort = [System.Collections.Generic.List[int]]::new()
    foreach ($n in $IssueNumbers) {
        if ($cohort -notcontains $n) { $cohort.Add($n) }
    }

    if ($Discover) {
        $discovered = script:Find-GroundingEvidenceDiscoveredIssues -RepoSlug $repoSlug -GhCliPath $GhCliPath
        foreach ($d in $discovered) {
            if ($cohort -notcontains $d) { $cohort.Add($d) }
        }
    }

    if ($cohort.Count -eq 0) {
        Write-Output 'grounding-evidence-corpus-check: no issues to classify -- supply -IssueNumbers and/or -Discover.'
        exit 0
    }

    $records = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($issueNumber in $cohort) {
        $record = script:Get-GroundingEvidenceIssueRecord -IssueNumber $issueNumber -RepoSlug $repoSlug -GhCliPath $GhCliPath
        if ($null -eq $record) { continue }
        if ($null -ne $Since) {
            if ($null -eq $record.MarkerCreatedAt) {
                Write-Warning "grounding-evidence-corpus-check: #$issueNumber excluded from -Since filtering -- no design-phase-complete marker comment was found (distinct from being excluded by the date filter itself)"
                continue
            }
            try {
                # Parse as UTC explicitly: a GitHub API timestamp like
                # 2026-07-01T02:00:00Z cast via a bare [datetime] cast yields
                # DateTimeKind.Local (implicitly converted to the local time
                # of the machine), while -Since is DateTimeKind.Unspecified --
                # comparing the two mixes represented instants and shifts
                # the effective cutoff by the UTC offset of the runner.
                $createdAtDt = [datetime]::Parse(
                    $record.MarkerCreatedAt,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
                )
            }
            catch {
                Write-Warning "grounding-evidence-corpus-check: could not parse MarkerCreatedAt for #$issueNumber ($($_.Exception.Message)); treating record as unresolvable"
                continue
            }
            # -Since is interpreted as UTC (see parameter doc-comment):
            # reinterpret its clock value as UTC rather than converting from
            # the local offset of the runner, so both sides of the
            # comparison are the same represented instant.
            $sinceUtc = [datetime]::SpecifyKind($Since.Value, [System.DateTimeKind]::Utc)
            if ($createdAtDt -lt $sinceUtc) { continue }
        }
        $records.Add($record)
    }

    foreach ($record in $records) {
        Write-Output "#$($record.IssueNumber): $($record.Bucket)"
    }

    $canonicalCount = @($records | Where-Object { $_.Bucket -eq 'canonical' }).Count
    Write-Output "$canonicalCount of $($records.Count) canonical"

    exit 0
}
