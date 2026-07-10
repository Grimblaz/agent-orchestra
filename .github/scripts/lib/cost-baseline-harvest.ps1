#Requires -Version 7.0
<#
.SYNOPSIS
    Bounded, fail-open, Claude-only startup harvest that upgrades mid-session
    baseline captures to exact end-of-session numbers (issue #824, Step 4 part B).
.DESCRIPTION
    Invoke-CostBaselineHarvest: finds merged PRs whose cost-pattern-data comment
    is still labeled `capture_point: pr-creation-mid-session`, re-walks their
    session using the extracted Invoke-CostSessionRender entry point (issue #824
    s4a), and — only when the re-walk is safe to trust — promotes the comment
    in place to `capture_point: end-of-session` with exact numbers.

    This file supplies the harvest FUNCTION only. It is invoked from a
    session-startup step in a later, separate slice (issue #824 s5) — that step
    owns the fail-open wiring/prose; this function owns the mechanics.

    Every failure path is silent no-op (fail-open): a failed `gh` call, no
    candidates, a verify-then-select miss, or a re-walk error all leave the
    harvest a no-op rather than throwing or blocking whatever invoked it.

    Dependencies (must already be dot-sourced by the caller — this file does
    not dot-source them itself, matching cost-session-render.ps1's own
    caller-owns-dependencies convention):
      - Get-CostRollingHistory        (cost-rolling-history.ps1)
      - Test-CostWalkerSessionTranscriptExists, Get-CostTranscriptSlug
                                       (cost-walker.ps1)
      - Invoke-CostSessionRender      (cost-session-render.ps1)
      - Find-OrUpsertComment          (find-or-upsert-comment.ps1)
#>

# ---------------------------------------------------------------------------
# Private helpers (script-scope so tests can dot-source and call them)
# ---------------------------------------------------------------------------

function script:Get-CostBaselineHarvestPortsTokenSum {
    <#
    .SYNOPSIS
        Sums token counts across a parsed rolling-history entry's `ports` dict.
    .DESCRIPTION
        Mirrors the ports-only $priorTokenSum derivation in
        cost-session-render.ps1 (issue #824 s3): a rolling-history entry parsed
        via ConvertFrom-CostPatternYaml has no `totals.tokens` (the parser never
        extracts it — see cost-session-render.ps1's own comment on this), so the
        comparable token sum for a PERSISTED candidate is the sum across its
        per-port `tokens` buckets. This is the "persisted" side of the token
        no-downgrade guard; the "re-walk" side comes straight from
        Invoke-CostSessionRender's totals-first TokenSum.
    #>
    param([AllowNull()]$Ports)

    [long]$sum = 0
    if ($null -eq $Ports) { return $sum }

    $portValues = if ($Ports -is [hashtable]) { $Ports.Values } elseif ($Ports -is [array]) { $Ports } else { @() }
    foreach ($portBucket in $portValues) {
        if ($null -eq $portBucket -or $portBucket -isnot [hashtable] -or -not $portBucket.ContainsKey('tokens')) { continue }
        $tokens = $portBucket['tokens']
        if ($null -eq $tokens -or $tokens -isnot [hashtable]) { continue }
        foreach ($tokenField in @('input', 'output', 'cache_creation', 'cache_read')) {
            if ($tokens.ContainsKey($tokenField) -and $null -ne $tokens[$tokenField]) {
                $sum += [long]$tokens[$tokenField]
            }
        }
    }
    return $sum
}

function script:ConvertTo-CostBaselineHarvestUtcDate {
    <#
    .SYNOPSIS
        Parses a rolling-history entry's `generated_at` value to a UTC [datetime].
    .OUTPUTS
        [datetime] on success, or $null when the value is missing/unparseable.
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        return ($Value.Kind -eq [System.DateTimeKind]::Utc) ? $Value : $Value.ToUniversalTime()
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try {
        $parsed = [datetime]::Parse($text, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return ($parsed.Kind -eq [System.DateTimeKind]::Utc) ? $parsed : $parsed.ToUniversalTime()
    }
    catch {
        return $null
    }
}

function script:Select-CostBaselineHarvestCandidates {
    <#
    .SYNOPSIS
        Filters already-fetched rolling-history entries down to harvest candidates.
    .DESCRIPTION
        Reuses Get-CostRollingHistory's existing scan (its own cache/timeout
        budget already applies) rather than reimplementing PR enumeration.
        A candidate must:
          - carry capture_point == 'pr-creation-mid-session'
          - NOT already carry a non-empty upgrade_attempted_at stamp (a prior
            re-walk attempt that did not promote it — terminal/deprioritized)
          - have a generated_at within the HorizonDays window
          - carry a usable session_id and pr (required to act on it at all)
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object[]]$Entries,
        [Parameter(Mandatory)][int]$HorizonDays
    )

    $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-1 * $HorizonDays)
    $candidates = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry -or $entry -isnot [hashtable]) { continue }
        if ([string]$entry['capture_point'] -ne 'pr-creation-mid-session') { continue }

        if ($entry.ContainsKey('upgrade_attempted_at') -and -not [string]::IsNullOrWhiteSpace([string]$entry['upgrade_attempted_at'])) {
            continue
        }

        $generatedAtUtc = script:ConvertTo-CostBaselineHarvestUtcDate -Value $entry['generated_at']
        if ($null -eq $generatedAtUtc -or $generatedAtUtc -lt $cutoffUtc) { continue }

        if ([string]::IsNullOrWhiteSpace([string]$entry['session_id'])) { continue }
        if ($null -eq $entry['pr']) { continue }

        $candidates.Add($entry)
    }

    return , $candidates.ToArray()
}

function script:Get-CostBaselineHarvestCompositeComment {
    <#
    .SYNOPSIS
        Fetches the composite `<!-- frame-credit-ledger-$Pr -->` comment body for a PR.
    .OUTPUTS
        [hashtable] @{ Found = [bool]; Body = [string]; Marker = [string] }
    #>
    param([Parameter(Mandatory)][int]$Pr)

    $marker = "<!-- frame-credit-ledger-$Pr -->"
    $notFound = @{ Found = $false; Body = ''; Marker = $marker }

    $commentsJson = $null
    try { $commentsJson = & gh pr view $Pr --json comments 2>$null }
    catch { return $notFound }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commentsJson)) { return $notFound }

    $parsed = $null
    try { $parsed = ($commentsJson | Out-String) | ConvertFrom-Json -ErrorAction Stop }
    catch { return $notFound }

    if ($null -eq $parsed -or $null -eq $parsed.comments) { return $notFound }

    $matching = @($parsed.comments | Where-Object { $null -ne $_ -and [string]$_.body -like "*$marker*" }) | Select-Object -Last 1
    if ($null -eq $matching) { return $notFound }

    return @{ Found = $true; Body = [string]$matching.body; Marker = $marker }
}

function script:Add-CostBaselineHarvestUpgradeAttemptedStamp {
    <#
    .SYNOPSIS
        Additively stamps `upgrade_attempted_at` onto an existing cost-pattern-data section.
    .DESCRIPTION
        Mirrors the additive-scalar-before-`ports:` placement rule s2 established
        for capture_point/session_id/head_ref/pr (ConvertFrom-CostPatternYaml's
        ports-block scanner terminates on the next top-level key it encounters,
        so a new top-level scalar must land before `ports:`). This does not
        re-render the section — it stamps the row's EXISTING (persisted) section
        verbatim, since a stably-incomplete re-walk must not overwrite the
        visible content, only mark the row so future scans skip it.
    #>
    param(
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$TimestampIso
    )

    if ($Section -match '(?m)^ports\s*:\s*$') {
        return ($Section -replace '(?m)^ports\s*:\s*$', "upgrade_attempted_at: $TimestampIso`nports:")
    }

    # Fallback: no ports: line found (unexpected shape) — stamp just before the closing '-->'.
    return ($Section -replace '-->\s*$', "upgrade_attempted_at: $TimestampIso`n-->")
}

# ---------------------------------------------------------------------------
# Public function
# ---------------------------------------------------------------------------

function Invoke-CostBaselineHarvest {
    <#
    .SYNOPSIS
        Runs the bounded startup baseline-eligibility harvest (issue #824 s4).
    .DESCRIPTION
        1. Selects candidates from Get-CostRollingHistory's already-fetched scan
           (capture_point == 'pr-creation-mid-session', within HorizonDays, no
           prior upgrade_attempted_at stamp).
        2. Verify-then-select: skips a candidate whose persisted session_id has
           no matching transcript file on THIS machine (never selects on a
           comment claim alone).
        3. Untrusted read-back: before acting, confirms via a fresh `gh pr view`
           that the candidate is genuinely MERGED; uses the LIVE headRefName as
           the walk key (the persisted head_ref is only ever used as a hint for
           the local-transcript check above, never as authorization).
        4. Re-walks via Invoke-CostSessionRender, capped at one expensive
           re-walk per call — the first candidate that passes both the
           verify-then-select and live-merge-check gates consumes the budget,
           whatever the outcome.
        5. Promotes (section-splices the composite ledger comment in place)
           only when the re-walk classifies capture_point == 'end-of-session'
           AND its TokenSum >= the persisted candidate's ports-derived token
           sum. Otherwise, a re-walk that produced real (non-empty) data is
           stamped `upgrade_attempted_at` so it exits future scans instead of
           re-consuming the one-re-walk-per-startup budget forever; a re-walk
           that found nothing usable leaves the row completely untouched.
        6. Refreshes the rolling-history cache after a successful promotion.

        Every failure path is fail-open: this function never throws to its
        caller and never leaves a partial/corrupt write.
    .PARAMETER ParentCwd
        The current (harvesting) session's own parent cwd — used to resolve
        the local transcript-existence check in step 2, and passed through to
        Invoke-CostSessionRender in step 4.
    .PARAMETER RepoRoot
        The current session's own repo root — used for slug/identity
        resolution and passed through to Invoke-CostSessionRender.
    .PARAMETER Slug
        The current session's own cost-transcript slug. When omitted, resolved
        from RepoRoot via Get-CostTranscriptSlug.
    .PARAMETER ProjectsRoot
        Root directory containing project slug directories. Defaults to
        ~/.claude/projects (see Test-CostWalkerSessionTranscriptExists).
    .PARAMETER HorizonDays
        Candidate age window in days. Default: 14.
    .OUTPUTS
        [hashtable] @{ Attempted = [bool]; Promoted = [bool]; Pr = [Nullable[int]]; Signal = [string] }
        Attempted is $true only once a candidate has passed both gates and the
        one-per-startup re-walk has actually been invoked. Signal carries the
        exactly-one-line success/expected-but-failed text (or $null when no
        candidate ever reached that point).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ParentCwd,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Slug = '',
        [string]$ProjectsRoot = '',
        [int]$HorizonDays = 14
    )

    $result = @{ Attempted = $false; Promoted = $false; Pr = $null; Signal = $null }

    try {
        if ([string]::IsNullOrWhiteSpace($Slug)) {
            try { $Slug = Get-CostTranscriptSlug -CwdPath $RepoRoot } catch { $Slug = '' }
        }

        $rollingResult = $null
        try { $rollingResult = Get-CostRollingHistory }
        catch { return $result }

        if ($null -eq $rollingResult -or [bool]$rollingResult['timed_out']) { return $result }

        $entries = @($rollingResult['entries'])
        if ($entries.Count -eq 0) { return $result }

        $candidates = script:Select-CostBaselineHarvestCandidates -Entries $entries -HorizonDays $HorizonDays
        if ($candidates.Count -eq 0) { return $result }

        foreach ($candidate in $candidates) {
            $candidatePr = 0
            if (-not [int]::TryParse([string]$candidate['pr'], [ref]$candidatePr)) { continue }

            $candidateSessionId = [string]$candidate['session_id']
            $candidateHeadRefHint = [string]$candidate['head_ref']

            # Verify-then-select (M14): a session id with no local transcript on
            # this machine is skipped WITHOUT spending a gh call or the re-walk
            # budget — cheap candidates keep moving until one is actionable.
            $transcriptExists = $false
            try {
                $transcriptExists = Test-CostWalkerSessionTranscriptExists `
                    -SessionId $candidateSessionId `
                    -Branch $candidateHeadRefHint `
                    -ParentCwd $ParentCwd `
                    -RepoRoot $RepoRoot `
                    -ProjectsRoot $ProjectsRoot
            }
            catch { $transcriptExists = $false }
            if (-not $transcriptExists) { continue }

            # Untrusted read-back (M16): the persisted head_ref is only a hint
            # for the local check above — bind to a live merge-commit/state
            # check before acting, and use the LIVE headRefName (not the
            # comment's) as the walk key below.
            $liveJson = $null
            try { $liveJson = & gh pr view $candidatePr --json 'state,mergedAt,mergeCommit,headRefName' 2>$null }
            catch { $liveJson = $null }
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($liveJson)) { continue }

            $liveInfo = $null
            try { $liveInfo = ($liveJson | Out-String) | ConvertFrom-Json -ErrorAction Stop }
            catch { $liveInfo = $null }
            if ($null -eq $liveInfo -or [string]$liveInfo.state -ne 'MERGED') { continue }

            $liveHeadRef = [string]$liveInfo.headRefName
            if ([string]::IsNullOrWhiteSpace($liveHeadRef)) { continue }

            # Budget cap: this candidate is now selected. Exactly one expensive
            # re-walk fires per Invoke-CostBaselineHarvest call, whatever the
            # eventual outcome — no other candidate is tried after this point.
            $result.Attempted = $true
            $result.Pr = $candidatePr

            $renderResult = $null
            try {
                $renderResult = Invoke-CostSessionRender `
                    -Pr $candidatePr `
                    -Branch $liveHeadRef `
                    -Slug $Slug `
                    -ParentCwd $ParentCwd `
                    -RepoRoot $RepoRoot
            }
            catch { $renderResult = $null }

            $reWalkCostSection = if ($null -ne $renderResult) { [string]$renderResult['CostSection'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($reWalkCostSection)) {
                # Re-walk itself failed or found nothing usable — fail-open,
                # leave the persisted row completely untouched (no write).
                $result.Signal = "upgrade expected for #$candidatePr — transcript unavailable"
                return $result
            }

            $reWalkCompleteness = $renderResult['Completeness']
            $reWalkCapturePoint = if ($null -ne $reWalkCompleteness -and $reWalkCompleteness -is [hashtable] -and $reWalkCompleteness.ContainsKey('capture_point')) {
                [string]$reWalkCompleteness['capture_point']
            }
            else { 'n/a' }

            [long]$persistedTokenSum = script:Get-CostBaselineHarvestPortsTokenSum -Ports $candidate['ports']
            [long]$reWalkTokenSum = 0
            if ($null -ne $renderResult -and $renderResult.ContainsKey('TokenSum') -and $null -ne $renderResult['TokenSum']) {
                $reWalkTokenSum = [long]$renderResult['TokenSum']
            }

            $shouldPromote = ($reWalkCapturePoint -eq 'end-of-session') -and ($reWalkTokenSum -ge $persistedTokenSum)

            $fetchResult = script:Get-CostBaselineHarvestCompositeComment -Pr $candidatePr
            if ($null -eq $fetchResult -or -not $fetchResult['Found']) {
                $result.Signal = "upgrade expected for #$candidatePr — composite comment unavailable"
                return $result
            }

            $compositeBody = $fetchResult['Body']
            $sectionMatch = [regex]::Match($compositeBody, '(?ms)(?<section>^##\s+Cost Pattern\b.*?<!--\s*cost-pattern-data[\s\S]*?-->)')
            if (-not $sectionMatch.Success) {
                $result.Signal = "upgrade expected for #$candidatePr — composite comment cost section not found"
                return $result
            }

            if ($shouldPromote) {
                # Section-splice (M2): replace ONLY the Cost Pattern section —
                # never a full-body replace (would clobber the port/credit
                # reports elsewhere in the composite comment) and never a new
                # sibling comment (would double-count this PR in
                # Get-CostRollingHistory's one-entry-per-block-bearing-body scan).
                $newBody = $compositeBody.Substring(0, $sectionMatch.Index) +
                    $reWalkCostSection.TrimEnd() +
                    $compositeBody.Substring($sectionMatch.Index + $sectionMatch.Length)

                $upserted = $false
                try {
                    $null = Find-OrUpsertComment -Type 'pr' -Number $candidatePr -Marker $fetchResult['Marker'] -Body $newBody
                    $upserted = $true
                }
                catch { $upserted = $false }

                if ($upserted) {
                    try { $null = Get-CostRollingHistory -ForceRefresh } catch { }
                    $result.Promoted = $true
                    $result.Signal = "upgraded #$candidatePr to end-of-session"
                }
                else {
                    $result.Signal = "upgrade expected for #$candidatePr — composite comment write failed"
                }
            }
            else {
                # Terminal-state handling (M3): a re-walk that produced real
                # data but did not qualify for promotion (still partial, OR
                # complete-but-lower-token) is stamped so it exits future scans
                # instead of re-consuming the one-re-walk-per-startup budget on
                # a row that may never promote (e.g. a null-tail/cross-tool row).
                $reason = if ($reWalkCapturePoint -ne 'end-of-session') { 'still partial' } else { 'token count lower than persisted' }
                $timestampIso = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                $stampedSection = script:Add-CostBaselineHarvestUpgradeAttemptedStamp -Section $sectionMatch.Groups['section'].Value -TimestampIso $timestampIso

                $newBody = $compositeBody.Substring(0, $sectionMatch.Index) +
                    $stampedSection +
                    $compositeBody.Substring($sectionMatch.Index + $sectionMatch.Length)

                try { $null = Find-OrUpsertComment -Type 'pr' -Number $candidatePr -Marker $fetchResult['Marker'] -Body $newBody }
                catch { }

                $result.Signal = "upgrade expected for #$candidatePr — $reason"
            }

            return $result
        }

        # No candidate ever passed both gates — fail-open no-op, no signal.
        return $result
    }
    catch {
        [Console]::Error.WriteLine("cost-baseline-harvest: harvest failed (fail-open, no-op): $($_.Exception.Message)")
        return @{ Attempted = $false; Promoted = $false; Pr = $null; Signal = $null }
    }
}
