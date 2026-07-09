#Requires -Version 7.0
<#!
.SYNOPSIS
    Pure-logic library for the post-port acceptance delta gate (issue #818 / s7).

.DESCRIPTION
    Consumes two `capture-pester6-baseline.ps1` (s2) JSON artifacts — a baseline
    and a candidate — and computes the machine-checked AC1 delta the plan's
    stress-test (M4/M11/M9) required: `acceptance_failures subset-of
    baseline_failures`, made reason-aware so a same-test reason-change cannot
    silently launder a new defect into an existing #566 entry.

    Four classifications, all keyed on the baseline runner's per-test
    `identity` string (`<relFile> :: <Describe > Context > It>`):

      - newFailures    : Failed/DiscoveryError in candidate, Passed/Skipped/
                         NotRun/absent in baseline. This is the AC1 violation
                         set; it must be empty for the gate to PASS.
      - reasonChanged   : Failed/DiscoveryError in BOTH artifacts, but the
                         (normalized) failure reason differs. The #566-
                         laundering guard from stress-test finding M9 — a test
                         red for reason A must not silently become red for
                         reason B and get waved through as pre-existing. Must
                         also be empty for PASS.
      - resolved        : Failed/DiscoveryError in baseline, Passed/Skipped/
                         NotRun/absent in candidate. Informational only —
                         improvements never fail the gate.
      - identityDrift   : identity strings present in one artifact's records
                         but entirely absent from the other, independent of
                         status. Renamed `It` names (s4's angle-bracket-token
                         rephrasing) surface here rather than as a spurious
                         newFailure/resolved pair on an unrelated identity.
                         Informational — annotated against a known-rename file
                         allowlist for reviewer convenience, but never gates
                         the verdict on its own.

    Verdict is PASS iff newFailures.Count -eq 0 AND reasonChanged.Count -eq 0.

    Exposes:
      - ConvertTo-Pester6NormalizedReason : strip volatile substrings (ISO8601
        timestamps, GUIDs) from a failure-reason string before comparison
      - Compare-Pester6BaselineRecords    : pure-logic delta over two record
        arrays (used directly by the Pester test with small synthetic fixtures)
      - Invoke-Pester6BaselineDelta       : I/O wrapper — loads two baseline
        JSON artifacts by path, runs the comparison, and optionally persists
        the JSON delta + a Markdown verdict report
#>

# ---------------------------------------------------------------------------
# ConvertTo-Pester6NormalizedReason
# ---------------------------------------------------------------------------
function ConvertTo-Pester6NormalizedReason {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Reason
    )

    if ([string]::IsNullOrEmpty($Reason)) {
        return ''
    }

    $normalized = $Reason

    # ISO8601-ish timestamps, e.g. 2026-07-09T01:38:10.7318036Z or with offsets.
    $normalized = [regex]::Replace($normalized, '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?', '<timestamp>')

    # GUIDs (with or without dashes, case-insensitive).
    $normalized = [regex]::Replace($normalized, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid>')

    # Collapse CRLF/LF and repeated whitespace so line-ending drift alone
    # cannot register as a reason change.
    $normalized = $normalized -replace '\r\n', "`n"
    $normalized = ($normalized -replace '\s+', ' ').Trim()

    return $normalized
}

# ---------------------------------------------------------------------------
# Internal: failing-status predicate. A test/discovery-error record counts as
# "failing" for delta purposes when its status is Failed or DiscoveryError;
# Passed, Skipped, and NotRun are all "non-failing".
# ---------------------------------------------------------------------------
function script:Test-Pester6RecordIsFailing {
    param([Parameter(Mandatory)][AllowNull()]$Record)
    if ($null -eq $Record) { return $false }
    return @('Failed', 'DiscoveryError') -contains [string]$Record.status
}

# ---------------------------------------------------------------------------
# Internal: build an identity -> record lookup. Duplicate identities within a
# single artifact's records are a LOUD error, not last-write-wins: after the
# M1 fix (pester6-baseline-core.ps1's launcher now builds identity from
# Pester's per-instance-expanded `ExpandedPath` instead of the unexpanded
# `Path`) PLUS the follow-up ordinal-tiebreaker fix (the launcher now detects
# genuinely colliding `ExpandedPath` groups -- e.g. a -ForEach case whose It
# name has no templated token referencing the varying data -- and appends a
# synthetic "[instance N of M]" disambiguator to every instance in that
# group), a genuine -ForEach data-driven test collision reaching this map
# builder is no longer possible for legitimate capture artifacts: two
# distinct Pester test instances can never share one identity string. This
# throw stays as a defensive invariant check, not a live guard against an
# expected condition. A collision reaching this function now indicates a
# real identity-construction defect (or corrupted/hand-built artifact) that
# should fail fast and name the exact colliding identity, rather than
# silently overwriting one record with another and hiding a coverage gap.
# ---------------------------------------------------------------------------
function script:ConvertTo-Pester6RecordMap {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    $map = [ordered]@{}
    foreach ($r in $Records) {
        if ($null -eq $r -or [string]::IsNullOrEmpty([string]$r.identity)) { continue }
        $identity = [string]$r.identity
        if ($map.Contains($identity)) {
            throw "Duplicate test identity found while building the baseline/candidate record map: '$identity'. This should be impossible after the M1 ExpandedPath-based identity fix; investigate the capture artifact instead of silently keeping the last record."
        }
        $map[$identity] = $r
    }
    return $map
}

# ---------------------------------------------------------------------------
# Compare-Pester6BaselineRecords
# ---------------------------------------------------------------------------
function Compare-Pester6BaselineRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$BaselineRecords,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$CandidateRecords,

        # Files with deliberate s4 It-name rephrasing; identity drift confined
        # to these files is expected, not a coverage-loss signal. Passing no
        # list simply means every drift is reported as "unexpected" — the
        # comparison logic itself is unaffected either way.
        [string[]]$KnownRenameFiles = @()
    )

    $baselineMap = script:ConvertTo-Pester6RecordMap -Records $BaselineRecords
    $candidateMap = script:ConvertTo-Pester6RecordMap -Records $CandidateRecords

    $newFailures = [System.Collections.Generic.List[object]]::new()
    $reasonChanged = [System.Collections.Generic.List[object]]::new()
    $resolved = [System.Collections.Generic.List[object]]::new()

    foreach ($identity in $candidateMap.Keys) {
        $candidateRecord = $candidateMap[$identity]
        $baselineRecord = if ($baselineMap.Contains($identity)) { $baselineMap[$identity] } else { $null }

        $candidateFailing = script:Test-Pester6RecordIsFailing -Record $candidateRecord
        $baselineFailing = script:Test-Pester6RecordIsFailing -Record $baselineRecord

        if ($candidateFailing -and -not $baselineFailing) {
            $newFailures.Add([ordered]@{
                identity        = $identity
                file            = [string]$candidateRecord.file
                status          = [string]$candidateRecord.status
                reason          = [string]$candidateRecord.reason
                baselineStatus  = if ($null -ne $baselineRecord) { [string]$baselineRecord.status } else { $null }
            }) | Out-Null
        }
        elseif ($candidateFailing -and $baselineFailing) {
            $normalizedBaselineReason = ConvertTo-Pester6NormalizedReason -Reason ([string]$baselineRecord.reason)
            $normalizedCandidateReason = ConvertTo-Pester6NormalizedReason -Reason ([string]$candidateRecord.reason)
            if ($normalizedBaselineReason -ne $normalizedCandidateReason) {
                $reasonChanged.Add([ordered]@{
                    identity        = $identity
                    file            = [string]$candidateRecord.file
                    baselineReason  = [string]$baselineRecord.reason
                    candidateReason = [string]$candidateRecord.reason
                }) | Out-Null
            }
        }
    }

    foreach ($identity in $baselineMap.Keys) {
        $baselineRecord = $baselineMap[$identity]
        $candidateRecord = if ($candidateMap.Contains($identity)) { $candidateMap[$identity] } else { $null }

        $baselineFailing = script:Test-Pester6RecordIsFailing -Record $baselineRecord
        $candidateFailing = script:Test-Pester6RecordIsFailing -Record $candidateRecord

        if ($baselineFailing -and -not $candidateFailing) {
            $resolved.Add([ordered]@{
                identity        = $identity
                file            = [string]$baselineRecord.file
                baselineStatus  = [string]$baselineRecord.status
                candidateStatus = if ($null -ne $candidateRecord) { [string]$candidateRecord.status } else { $null }
            }) | Out-Null
        }
    }

    # Identity drift: symmetric difference of identity keys, independent of
    # status — this is the lens that catches a rename (old identity vanishes,
    # new identity appears) that the failing/non-failing joins above would
    # otherwise miss entirely (a rename between two Passed tests never
    # touches newFailures/resolved).
    $missingFromCandidate = [System.Collections.Generic.List[object]]::new()
    foreach ($identity in $baselineMap.Keys) {
        if (-not $candidateMap.Contains($identity)) {
            $r = $baselineMap[$identity]
            $file = [string]$r.file
            $missingFromCandidate.Add([ordered]@{
                identity           = $identity
                file               = $file
                baselineStatus     = [string]$r.status
                expectedRenameFile = [bool]($KnownRenameFiles -contains $file)
            }) | Out-Null
        }
    }

    $newInCandidate = [System.Collections.Generic.List[object]]::new()
    foreach ($identity in $candidateMap.Keys) {
        if (-not $baselineMap.Contains($identity)) {
            $r = $candidateMap[$identity]
            $file = [string]$r.file
            $newInCandidate.Add([ordered]@{
                identity           = $identity
                file               = $file
                candidateStatus    = [string]$r.status
                expectedRenameFile = [bool]($KnownRenameFiles -contains $file)
            }) | Out-Null
        }
    }

    $verdict = if ($newFailures.Count -eq 0 -and $reasonChanged.Count -eq 0) { 'Pass' } else { 'Fail' }
    $verdictReason = if ($verdict -eq 'Pass') {
        'newFailures and reasonChanged are both empty.'
    }
    else {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($newFailures.Count -gt 0) { $parts.Add("$($newFailures.Count) new failure(s)") | Out-Null }
        if ($reasonChanged.Count -gt 0) { $parts.Add("$($reasonChanged.Count) reason-change(s) on already-red test(s)") | Out-Null }
        ($parts -join '; ')
    }

    return [ordered]@{
        verdict       = $verdict
        verdictReason = $verdictReason
        newFailures   = @($newFailures)
        reasonChanged = @($reasonChanged)
        resolved      = @($resolved)
        identityDrift = [ordered]@{
            missingFromCandidate = @($missingFromCandidate)
            newInCandidate       = @($newInCandidate)
        }
    }
}

# ---------------------------------------------------------------------------
# Invoke-Pester6BaselineDelta
# ---------------------------------------------------------------------------
function Invoke-Pester6BaselineDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaselinePath,

        [Parameter(Mandatory)]
        [string]$CandidatePath,

        [string[]]$KnownRenameFiles = @(
            'NamingRegisterLivingSurface.Tests.ps1',
            'frame-predicate-never-identifier.Tests.ps1',
            'migration-scan-enforcement.Tests.ps1',
            'frame-credit-ledger-core.Tests.ps1',
            'post-merge-cleanup.Tests.ps1',
            'frame-credit-ledger-orchestrator.Tests.ps1'
        ),

        [string]$OutputJsonPath,

        [string]$OutputMarkdownPath
    )

    $ErrorActionPreference = 'Continue'

    if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
        Write-Error "BaselinePath not found: $BaselinePath"
        return [pscustomobject]@{ ExitCode = 1; Result = $null }
    }
    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
        Write-Error "CandidatePath not found: $CandidatePath"
        return [pscustomobject]@{ ExitCode = 1; Result = $null }
    }

    try {
        $baselineArtifact = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
        $candidateArtifact = Get-Content -LiteralPath $CandidatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse baseline/candidate JSON: $($_.Exception.Message)"
        return [pscustomobject]@{ ExitCode = 1; Result = $null }
    }

    $baselineRecords = @($baselineArtifact.records)
    $candidateRecords = @($candidateArtifact.records)

    $delta = Compare-Pester6BaselineRecords -BaselineRecords $baselineRecords -CandidateRecords $candidateRecords -KnownRenameFiles $KnownRenameFiles

    $result = [ordered]@{
        baselinePath      = $BaselinePath
        candidatePath     = $CandidatePath
        baselineVersion   = [string]$baselineArtifact.requiredVersion
        candidateVersion  = [string]$candidateArtifact.requiredVersion
        baselineSummary   = $baselineArtifact.summary
        candidateSummary  = $candidateArtifact.summary
        verdict           = $delta.verdict
        verdictReason     = $delta.verdictReason
        newFailures       = $delta.newFailures
        reasonChanged     = $delta.reasonChanged
        resolved          = $delta.resolved
        identityDrift     = $delta.identityDrift
        comparedAt        = (Get-Date).ToUniversalTime().ToString('o')
    }

    if ($OutputJsonPath) {
        $outDir = Split-Path -Parent $OutputJsonPath
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        ($result | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $OutputJsonPath -Encoding UTF8
    }

    if ($OutputMarkdownPath) {
        $outDir = Split-Path -Parent $OutputMarkdownPath
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $md = Get-Pester6BaselineDeltaMarkdown -Result $result
        Set-Content -LiteralPath $OutputMarkdownPath -Value $md -Encoding UTF8
    }

    $exitCode = if ($delta.verdict -eq 'Pass') { 0 } else { 1 }
    return [pscustomobject]@{ ExitCode = $exitCode; Result = $result }
}

# ---------------------------------------------------------------------------
# Get-Pester6BaselineDeltaMarkdown — render the delta result as a PR-evidence
# Markdown report.
# ---------------------------------------------------------------------------
function Get-Pester6BaselineDeltaMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $verdictLabel = if ($Result.verdict -eq 'Pass') { 'PASS' } else { 'FAIL' }

    $lines.Add('# Issue #818 s7 — Post-port acceptance delta verdict') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add("**Verdict: $verdictLabel** — $($Result.verdictReason)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add("- Baseline: ``$($Result.baselinePath)`` (Pester $($Result.baselineVersion)) — total=$($Result.baselineSummary.totalTests) passed=$($Result.baselineSummary.passed) failed=$($Result.baselineSummary.failed) skipped=$($Result.baselineSummary.skipped) notRun=$($Result.baselineSummary.notRun) discoveryErrors=$($Result.baselineSummary.discoveryErrors)") | Out-Null
    $lines.Add("- Candidate: ``$($Result.candidatePath)`` (Pester $($Result.candidateVersion)) — total=$($Result.candidateSummary.totalTests) passed=$($Result.candidateSummary.passed) failed=$($Result.candidateSummary.failed) skipped=$($Result.candidateSummary.skipped) notRun=$($Result.candidateSummary.notRun) discoveryErrors=$($Result.candidateSummary.discoveryErrors)") | Out-Null
    $lines.Add("- Compared at: $($Result.comparedAt)") | Out-Null
    $lines.Add('') | Out-Null

    $lines.Add("## newFailures (AC1 violation set) — $(@($Result.newFailures).Count)") | Out-Null
    $lines.Add('') | Out-Null
    if (@($Result.newFailures).Count -eq 0) {
        $lines.Add('_None._') | Out-Null
    }
    else {
        foreach ($f in @($Result.newFailures)) {
            $lines.Add("- ``$($f.identity)`` — $($f.status): $($f.reason)") | Out-Null
        }
    }
    $lines.Add('') | Out-Null

    $lines.Add("## reasonChanged (#566-laundering guard) — $(@($Result.reasonChanged).Count)") | Out-Null
    $lines.Add('') | Out-Null
    if (@($Result.reasonChanged).Count -eq 0) {
        $lines.Add('_None._') | Out-Null
    }
    else {
        foreach ($f in @($Result.reasonChanged)) {
            $lines.Add("- ``$($f.identity)``") | Out-Null
            $lines.Add("  - baseline reason: $($f.baselineReason)") | Out-Null
            $lines.Add("  - candidate reason: $($f.candidateReason)") | Out-Null
        }
    }
    $lines.Add('') | Out-Null

    $lines.Add("## resolved (informational, never fails the gate) — $(@($Result.resolved).Count)") | Out-Null
    $lines.Add('') | Out-Null
    if (@($Result.resolved).Count -eq 0) {
        $lines.Add('_None._') | Out-Null
    }
    else {
        foreach ($f in @($Result.resolved)) {
            $lines.Add("- ``$($f.identity)`` — $($f.baselineStatus) -> $($f.candidateStatus)") | Out-Null
        }
    }
    $lines.Add('') | Out-Null

    $missing = @($Result.identityDrift.missingFromCandidate)
    $new = @($Result.identityDrift.newInCandidate)
    $lines.Add("## identityDrift (informational) — $($missing.Count) missing, $($new.Count) new") | Out-Null
    $lines.Add('') | Out-Null
    $unexpectedMissing = @($missing | Where-Object { -not $_.expectedRenameFile })
    $unexpectedNew = @($new | Where-Object { -not $_.expectedRenameFile })
    if ($unexpectedMissing.Count -gt 0 -or $unexpectedNew.Count -gt 0) {
        $lines.Add('**Unexpected drift outside the known s4 rename files — review individually:**') | Out-Null
        foreach ($f in $unexpectedMissing) {
            $lines.Add("- MISSING (was $($f.baselineStatus)): ``$($f.identity)``") | Out-Null
        }
        foreach ($f in $unexpectedNew) {
            $lines.Add("- NEW (is $($f.candidateStatus)): ``$($f.identity)``") | Out-Null
        }
        $lines.Add('') | Out-Null
    }
    $expectedMissing = @($missing | Where-Object { $_.expectedRenameFile })
    $expectedNew = @($new | Where-Object { $_.expectedRenameFile })
    if ($expectedMissing.Count -gt 0 -or $expectedNew.Count -gt 0) {
        $lines.Add('<details><summary>Expected drift from s4 It-name rephrasing</summary>') | Out-Null
        $lines.Add('') | Out-Null
        foreach ($f in $expectedMissing) {
            $lines.Add("- MISSING (was $($f.baselineStatus)): ``$($f.identity)``") | Out-Null
        }
        foreach ($f in $expectedNew) {
            $lines.Add("- NEW (is $($f.candidateStatus)): ``$($f.identity)``") | Out-Null
        }
        $lines.Add('') | Out-Null
        $lines.Add('</details>') | Out-Null
    }

    return ($lines -join "`n")
}
