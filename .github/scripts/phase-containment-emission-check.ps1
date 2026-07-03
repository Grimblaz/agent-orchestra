#Requires -Version 7.0
<#
.SYNOPSIS
    Phase-containment emission-check sweep orchestrator (issue #782).
.DESCRIPTION
    Warn-only backstop that flags adversarial-review sustained findings that
    are missing their paired <!-- phase-containment-{ID} --> ledger blocks.

    Trust posture: this is a warn-only maintainer advisory (DD2/DD1-secondary
    framing). Comment authorship is NOT filtered — any comment matching the
    marker shapes is trusted at face value. Residual risk accepted at this
    tier; do not treat this script's silence as a compliance guarantee.

    Modeled on .github/scripts/frame-credit-ledger.ps1's conventions:
      - lib-load failures are wrapped in try/catch and fail OPEN in warn mode
        ([Console]::Error.WriteLine + exit 0) — never block any caller flow.
      - fail-loud WITHIN the report: could-not-verify rows always render as
        "COULD NOT VERIFY — treat as gap", never silently omitted (DD3).
      - dot-source detection via $MyInvocation.InvocationName -eq '.'
        (frame-credit-ledger.ps1:1844 idiom) — NOT -ImportMode, which
        belongs to the unrelated reporting-economy family.

    Two run modes:
      Single-target (-Pr or -Issue): computes the gap for one PR/issue and
        upserts a report comment via Find-OrUpsertComment, marker
        `<!-- pc-emission-check-report -->` — deliberately OUTSIDE the
        phase-containment- prefix namespace (M9) so a posted report can
        never be re-parsed as a phantom phase-containment block by a later
        sweep. The report never emits a live block-marker literal; marker
        names render as plain code-span text with the HTML-comment brackets
        stripped.
      Corpus (-WindowDays, default 90): calls the shared discovery helper
        (Get-PhaseContainmentCommentCorpus in phase-containment-rolling-
        history-core.ps1) and renders a per-surface gap table to stdout.
        Every run — including clean runs — prints the positive-coverage
        line `Surfaces scanned: N | Sustained counted: M | Blocks matched: K`
        per surface (M6), so a fail-open abort (which prints none of this)
        is observationally distinct from a verified-clean run.

    -ScaffoldBackfill renders ready-to-paste phase-containment blocks per
    gap, with BOTH the open and closing tags (M7 — an unclosed block
    silently stops the core scanner), introduced_phase/catchable_phase set
    to TODO-human placeholders (fail the schema enum on purpose), and
    escape_distance: -1 (fails the schema minimum:0 on purpose) — so the
    scaffold stays paste-safe until a human sets the phases and recomputes
    escape_distance = projection(caught_stage) - ordinal(catchable_phase).

.PARAMETER Pr
    Single-target mode: check this PR number (code-review surface). Mutually
    exclusive with -Issue and with corpus mode (-WindowDays is ignored when
    -Pr or -Issue is supplied).
.PARAMETER Issue
    Single-target mode: check this issue number (design-challenge and
    plan-stress-test surfaces are both probed; whichever marker is present
    determines the surface). Mutually exclusive with -Pr.
.PARAMETER WindowDays
    Corpus mode: number of past days to scan. Default: 90. Ignored when -Pr
    or -Issue is supplied.
.PARAMETER Mode
    'warn' (default) or 'enforce'. Enforce is RESERVED/unimplemented per
    DD2 — passing 'enforce' is accepted for forward-compatibility but the
    script still behaves as warn-only in this release.
.PARAMETER RepoOwner
    GitHub repository owner. Live for the discovery/fetch side ONLY (M12) —
    threaded into Get-PhaseContainmentCommentCorpus exactly as
    phase-containment-report.ps1 threads it into Get-PhaseContainmentHistory.
    Resolved via 'gh repo view' if not supplied.
.PARAMETER RepoName
    GitHub repository name. Same scoping as -RepoOwner.
.PARAMETER Token
    GitHub token. Live for the discovery/fetch side only; currently unused
    by the underlying gh-CLI calls (ambient auth). Reserved for future use.
    Comment WRITES always use ambient `gh` auth with owner/repo derived from
    the git remote (the Find-OrUpsertComment convention) — these params
    never scope writes.
.PARAMETER ScaffoldBackfill
    When set, single-target mode additionally renders ready-to-paste
    phase-containment scaffold blocks (open+close tags, TODO-human phase
    placeholders, escape_distance: -1) for each currently-missing block.
.PARAMETER PostTo
    Corpus mode: upsert the corpus report as a comment on issue N (e.g. the
    umbrella tracking issue) instead of only printing to stdout.
.EXAMPLE
    pwsh ./.github/scripts/phase-containment-emission-check.ps1 -Pr 775
.EXAMPLE
    pwsh ./.github/scripts/phase-containment-emission-check.ps1 -Issue 782
.EXAMPLE
    pwsh ./.github/scripts/phase-containment-emission-check.ps1 -WindowDays 90
.EXAMPLE
    pwsh ./.github/scripts/phase-containment-emission-check.ps1 -WindowDays 90 -PostTo 761
#>

[CmdletBinding(DefaultParameterSetName = 'Corpus')]
param(
    [Parameter(ParameterSetName = 'SinglePr', Mandatory)][int]$Pr,
    [Parameter(ParameterSetName = 'SingleIssue', Mandatory)][int]$Issue,
    [Parameter(ParameterSetName = 'Corpus')][int]$WindowDays = 90,
    [string]$Mode = 'warn',
    [string]$RepoOwner = '',
    [string]$RepoName = '',
    [string]$Token = '',
    [switch]$ScaffoldBackfill,
    [int]$PostTo = 0
)

# Manual validation of -Mode (ValidateSet attribute-binding failures do not
# set $LASTEXITCODE — see frame-credit-ledger.ps1's identical rationale).
if ($Mode -notin @('warn', 'enforce')) {
    [Console]::Error.WriteLine("phase-containment-emission-check: Cannot validate argument on parameter 'Mode'. The argument '$Mode' does not belong to the set 'warn,enforce' specified by the ValidateSet attribute. Supply an argument that is in the set and then try the command again.")
    exit 2
}

# Mark warn-mode early so the lib-load try/catch below can decide its exit
# code without re-parsing $Mode if a lib file has a parse-time error.
$script:WarnModeOnly = ($Mode -eq 'warn')

# ---------------------------------------------------------------------------
# Library dot-sources (wrapped: a parse-time error in any lib file would
# crash the script before this try/catch engages, bypassing warn-mode
# fail-open semantics — same rationale as frame-credit-ledger.ps1:44-62).
# ---------------------------------------------------------------------------
try {
    . (Join-Path $PSScriptRoot 'lib/phase-containment-core.ps1')
    . (Join-Path $PSScriptRoot 'lib/phase-containment-emission-check-core.ps1')
    . (Join-Path $PSScriptRoot 'lib/phase-containment-rolling-history-core.ps1')
    . (Join-Path $PSScriptRoot 'lib/find-or-upsert-comment.ps1')
}
catch {
    [Console]::Error.WriteLine("phase-containment-emission-check: library load failed: $($_.Exception.Message)")
    if ($script:WarnModeOnly) {
        exit 0
    }
    exit 5
}

# ---------------------------------------------------------------------------
# Rendering hygiene (M9): render a marker name as inert code-span text — the
# report must never emit a live HTML-comment marker literal, so a posted
# report can never be re-parsed as a phantom phase-containment block by a
# later sweep. Strips '<!--' / '-->' and wraps in backticks.
# ---------------------------------------------------------------------------
function script:Format-InertMarkerLabel {
    param([Parameter(Mandatory)][string]$MarkerText)
    $stripped = $MarkerText -replace '<!--\s*', '' -replace '\s*-->', ''
    return "``$stripped``"
}

# ---------------------------------------------------------------------------
# Render a single gap row. $Gap is the PSCustomObject from Get-EmissionGap
# (SustainedCount, BlockCount, Gap, ParseStatus) plus the caller-supplied
# Surface/Id for the label.
# ---------------------------------------------------------------------------
function script:Format-EmissionGapLine {
    param(
        [Parameter(Mandatory)][string]$Surface,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][PSCustomObject]$Gap
    )

    if ($Gap.ParseStatus -eq 'could-not-verify') {
        # M13 fix (issue #782 post-review): could-not-verify means the
        # sustained/blocks numbers reflect only the bodies that DID parse —
        # a skimming maintainer could otherwise mistake a small-looking
        # count for a trustworthy one. Qualify the numbers explicitly rather
        # than presenting them at face value.
        return "  ${Surface} #${Id}: COULD NOT VERIFY -- treat as gap (partial, do not trust: sustained=$($Gap.SustainedCount), blocks=$($Gap.BlockCount))"
    }
    if ($Gap.Gap -gt 0) {
        return "  ${Surface} #${Id}: GAP -- sustained=$($Gap.SustainedCount) blocks=$($Gap.BlockCount) missing=$($Gap.Gap)"
    }
    return "  ${Surface} #${Id}: clean -- sustained=$($Gap.SustainedCount) blocks=$($Gap.BlockCount)"
}

# ---------------------------------------------------------------------------
# Render ready-to-paste scaffold blocks for a gap (paste-safe until a human
# sets the phases). One block per missing finding (Gap count).
#
# Issue #782 post-review Fix A (M2 defense-in-depth): open/close tag lines
# render via Format-InertMarkerLabel rather than live
# <!-- phase-containment-{ID} --> / <!-- /phase-containment-{ID} --> HTML
# comment literals. Fix A's schema-validation gate in Get-EmissionGap
# (escape_distance: -1 always fails Test-PhaseContainmentEntry) already
# structurally prevents this scaffold from ever counting toward a real gap
# even if pasted verbatim with live markers restored — this inert rendering
# is a second, independent layer so the posted REPORT comment itself never
# carries a live phase-containment marker literal that a later sweep could
# misparse, matching the hygiene already applied to the trailer mention
# (M9/Format-InertMarkerLabel). A human backfilling for real strips the
# backticks and restores the live `<!--`/`-->` HTML-comment syntax by hand
# after setting the TODO-human phases, exactly as they must already rewrite
# every TODO-human placeholder.
# ---------------------------------------------------------------------------
function script:Format-BackfillScaffold {
    param(
        [Parameter(Mandatory)][string]$Surface,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][int]$MissingCount
    )

    if ($MissingCount -le 0) { return '' }

    $openLabel = script:Format-InertMarkerLabel -MarkerText "<!-- phase-containment-$Id -->"
    $closeLabel = script:Format-InertMarkerLabel -MarkerText "<!-- /phase-containment-$Id -->"

    $lines = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -le $MissingCount; $i++) {
        $lines.Add($openLabel)
        $lines.Add("finding_key: ${Surface}:${Id}:TODO-human-$i")
        $lines.Add('introduced_phase: TODO-human')
        $lines.Add('catchable_phase: TODO-human')
        $lines.Add("caught_stage: $Surface")
        $lines.Add('escape_distance: -1')
        $lines.Add('severity: TODO-human')
        $lines.Add('systemic_fix_type: TODO-human')
        $lines.Add('category: TODO-human')
        $lines.Add('apparatus_meta: false')
        $lines.Add('seed: false')
        $lines.Add($closeLabel)
    }
    return ($lines -join "`n")
}

# ---------------------------------------------------------------------------
# Single-target mode: compute the gap for one PR/issue and upsert a report
# comment. Returns the composed report body (for testability / stdout echo).
# ---------------------------------------------------------------------------
function Invoke-PhaseContainmentEmissionCheckSingleTarget {
    [CmdletBinding()]
    param(
        [string]$PrNumber,
        [string]$IssueNumber,
        [switch]$ScaffoldBackfill,
        [string]$RepoOwner = '',
        [string]$RepoName = '',
        [string]$Token = ''
    )

    $isPr = -not [string]::IsNullOrWhiteSpace($PrNumber)
    $targetId = if ($isPr) { [int]$PrNumber } else { [int]$IssueNumber }
    $type = if ($isPr) { 'pr' } else { 'issue' }

    # -RepoOwner/-RepoName/-Token (M12) thread through the shared discovery
    # helper for CORPUS mode only (Get-PhaseContainmentCommentCorpus). This
    # single-target path's `gh pr/issue view` calls always resolve against
    # the ambient CWD repo (gh CLI convention, same as Find-OrUpsertComment),
    # so the params are accepted on this function for parameter-surface
    # parity but are not separately threaded here — write calls also resolve
    # owner/repo from the git remote independently.
    # GH-7 fix (issue #782 GitHub-review response loop, PR #789): use
    # 2>$null, not 2>&1. Merging stderr into the stream later piped to
    # ConvertFrom-Json means any benign gh notice (deprecation, auth) on
    # stderr corrupts the JSON parse and silently false-aborts the whole
    # check. Matches the convention already used elsewhere in this codebase
    # (Find-OrUpsertComment, phase-containment-rolling-history-core.ps1's
    # REST/GraphQL paths).
    $viewArgs = @($targetId, '--json', 'comments')
    if ($isPr) {
        $viewOutput = & gh pr view @viewArgs 2>$null
    }
    else {
        $viewOutput = & gh issue view @viewArgs 2>$null
    }

    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("phase-containment-emission-check: gh $type view $targetId failed (exit $LASTEXITCODE)")
        return $null
    }

    $bodies = @()
    try {
        $viewObj = ($viewOutput | Out-String) | ConvertFrom-Json -ErrorAction Stop
        $bodies = @($viewObj.comments | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.body })
    }
    catch {
        [Console]::Error.WriteLine("phase-containment-emission-check: failed to parse comments for $type $targetId : $($_.Exception.Message)")
        return $null
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Phase-Containment Emission Check')
    $lines.Add('')
    $lines.Add('Warn-only maintainer advisory (DD1-secondary framing) -- comment authorship is not filtered.')
    $lines.Add('')

    $surfacesToCheck = if ($isPr) { @('code-review') } else { @('design-challenge', 'plan-stress-test') }
    $scannedCount = 0
    $sustainedTotal = 0
    $blocksTotal = 0
    $anyGapRendered = $false

    foreach ($surface in $surfacesToCheck) {
        $gap = Get-EmissionGap -Bodies $bodies -Id $targetId -Surface $surface
        $scannedCount++
        $sustainedTotal += $gap.SustainedCount
        $blocksTotal += $gap.BlockCount

        $lines.Add((script:Format-EmissionGapLine -Surface $surface -Id $targetId -Gap $gap))
        $anyGapRendered = $true

        if ($ScaffoldBackfill -and $gap.ParseStatus -eq 'ok' -and $gap.Gap -gt 0) {
            $scaffold = script:Format-BackfillScaffold -Surface $surface -Id $targetId -MissingCount $gap.Gap
            if ($scaffold) {
                $lines.Add('')
                $lines.Add("Backfill scaffold for ${surface}:")
                $lines.Add('```yaml')
                $lines.Add($scaffold)
                $lines.Add('```')
            }
        }
    }

    $lines.Add('')
    $lines.Add("Surfaces scanned: $scannedCount | Sustained counted: $sustainedTotal | Blocks matched: $blocksTotal")
    $lines.Add('')
    $markerLabel = script:Format-InertMarkerLabel -MarkerText "<!-- phase-containment-$targetId -->"
    $lines.Add("(Ledger blocks use the $markerLabel marker; this report intentionally avoids emitting a live marker literal.)")

    if (-not $anyGapRendered) {
        # Defensive: should be unreachable given $surfacesToCheck is always
        # non-empty, but keep the positive-coverage contract airtight.
        $lines.Add('No surfaces were scanned.')
    }

    $reportBody = "<!-- pc-emission-check-report -->`n" + ($lines -join "`n")

    try {
        $null = Find-OrUpsertComment -Type $type -Number $targetId -Marker '<!-- pc-emission-check-report -->' -Body $reportBody
    }
    catch {
        [Console]::Error.WriteLine("phase-containment-emission-check: upsert failed: $($_.Exception.Message)")
    }

    return $reportBody
}

# ---------------------------------------------------------------------------
# Corpus mode: scan the discovery corpus (shared seam) and render a
# per-surface gap table. Optionally upserts to -PostTo.
# ---------------------------------------------------------------------------
function Invoke-PhaseContainmentEmissionCheckCorpus {
    [CmdletBinding()]
    param(
        [int]$WindowDays = 90,
        [string]$RepoOwner = '',
        [string]$RepoName = '',
        [string]$Token = '',
        [int]$PostTo = 0
    )

    $corpusParams = @{ WindowDays = $WindowDays }
    if ($RepoOwner) { $corpusParams['RepoOwner'] = $RepoOwner }
    if ($RepoName) { $corpusParams['RepoName'] = $RepoName }
    if ($Token) { $corpusParams['Token'] = $Token }

    $corpus = Get-PhaseContainmentCommentCorpus @corpusParams

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Phase-Containment Emission Check -- Corpus Sweep')
    $lines.Add('')
    $lines.Add("Window: ${WindowDays}d | Source: $($corpus.Source)")
    $lines.Add('Warn-only maintainer advisory (DD1-secondary framing) -- comment authorship is not filtered.')
    $lines.Add('')

    if ($corpus.Source -eq 'timeout' -or $corpus.Source -eq 'repo-resolution-failed') {
        $lines.Add("Corpus fetch did not complete (source=$($corpus.Source)) -- no surfaces scanned. This is NOT a clean-run signal.")
        $reportBody = ($lines -join "`n")
        return $reportBody
    }

    $scannedCount = 0
    $sustainedGrandTotal = 0
    $blocksGrandTotal = 0

    foreach ($tuple in @($corpus.Tuples)) {
        $number = [int]$tuple['Number']
        $surfaceKind = [string]$tuple['Surface']
        $bodies = @($tuple['Bodies'])

        $surfacesToCheck = if ($surfaceKind -eq 'pr') { @('code-review') } else { @('design-challenge', 'plan-stress-test') }

        foreach ($surface in $surfacesToCheck) {
            $gap = Get-EmissionGap -Bodies $bodies -Id $number -Surface $surface
            $scannedCount++
            $sustainedGrandTotal += $gap.SustainedCount
            $blocksGrandTotal += $gap.BlockCount

            # Positive coverage is only meaningful for surfaces that actually
            # produced sustained findings or blocks; still render every
            # scanned tuple so silence is never the success signal.
            if ($gap.SustainedCount -gt 0 -or $gap.BlockCount -gt 0 -or $gap.ParseStatus -eq 'could-not-verify') {
                $lines.Add((script:Format-EmissionGapLine -Surface $surface -Id $number -Gap $gap))
            }
        }
    }

    $lines.Add('')
    $lines.Add("Surfaces scanned: $scannedCount | Sustained counted: $sustainedGrandTotal | Blocks matched: $blocksGrandTotal")

    $reportBody = ($lines -join "`n")

    if ($PostTo -gt 0) {
        $postBody = "<!-- pc-emission-check-report -->`n" + $reportBody
        try {
            $null = Find-OrUpsertComment -Type 'issue' -Number $PostTo -Marker '<!-- pc-emission-check-report -->' -Body $postBody
        }
        catch {
            [Console]::Error.WriteLine("phase-containment-emission-check: corpus-mode upsert to issue $PostTo failed: $($_.Exception.Message)")
        }
    }

    return $reportBody
}

# ---------------------------------------------------------------------------
# Top-level execution (skipped when dot-sourced)
# ---------------------------------------------------------------------------
# Detect dot-source: when invoked via `. path -WindowDays 1`, InvocationName
# is '.' (frame-credit-ledger.ps1:1844 idiom — NOT -ImportMode).
$isDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $isDotSourced) {
    $exitCode = 0
    try {
        if ($PSCmdlet.ParameterSetName -eq 'SinglePr') {
            $singleReport = Invoke-PhaseContainmentEmissionCheckSingleTarget `
                -PrNumber $Pr -ScaffoldBackfill:$ScaffoldBackfill `
                -RepoOwner $RepoOwner -RepoName $RepoName -Token $Token
            if ($null -ne $singleReport) { Write-Output $singleReport }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'SingleIssue') {
            $singleReport = Invoke-PhaseContainmentEmissionCheckSingleTarget `
                -IssueNumber $Issue -ScaffoldBackfill:$ScaffoldBackfill `
                -RepoOwner $RepoOwner -RepoName $RepoName -Token $Token
            if ($null -ne $singleReport) { Write-Output $singleReport }
        }
        else {
            $corpusReport = Invoke-PhaseContainmentEmissionCheckCorpus `
                -WindowDays $WindowDays -RepoOwner $RepoOwner -RepoName $RepoName -Token $Token -PostTo $PostTo
            if ($null -ne $corpusReport) { Write-Output $corpusReport }
        }
    }
    catch {
        [Console]::Error.WriteLine("phase-containment-emission-check: $($_.Exception.Message)")
        if ($Mode -eq 'enforce') {
            $exitCode = 5
        }
        else {
            $exitCode = 0
        }
    }

    exit $exitCode
}
