#Requires -Version 7.0

<#
.SYNOPSIS
    Thin CLI/production wrapper for Invoke-PersistPhaseLedger (issue #878,
    plan slice s5).
.DESCRIPTION
    Owns the dot-source of the hub primitives this feature composes:
    find-or-upsert-comment.ps1 (Find-OrUpsertComment, Get-RestCommentId),
    marker-transport-core.ps1 (issue #893, plan slice s2 -- the promoted
    Find-CommentIdByExactMarker/Get-CommentBodyById/Set-CommentBodyDirect/
    Get-CommentIdFromUrl/Set-PointerLineAfterMarker that
    persist-phase-ledger-core.ps1's PPL-prefixed names now delegate to),
    and phase-containment-emission-check-core.ps1 (Add-CommentBlocks,
    Add-JudgeRulingsBlock, Get-DispositionTally;
    phase-containment-emission-check-core.ps1's own line 24 (`. (Join-Path
    $PSScriptRoot 'phase-containment-core.ps1')`) transitively dot-sources
    phase-containment-core.ps1, so no fourth dot-source line is needed
    here). persist-phase-ledger-core.ps1 does NOT
    dot-source these itself -- it assumes they are already in scope, which
    lets Pester dot-source the core directly against the real primitives
    without ever loading this wrapper (see
    .github/scripts/Tests/persist-phase-ledger.Tests.ps1's BeforeEach).

    Dot-sourcing .github/scripts/lib directly from a skill script is a
    deliberate first for this repo -- no other skill script does it. It is
    safe HERE specifically because .github/scripts/lib ships bundled
    alongside this very script at a FIXED relative offset inside our own
    checkout (whether that checkout is the Agent Orchestra hub repo itself
    or an installed plugin-cache copy): $PSScriptRoot always resolves to
    skills/session-memory-contract/scripts, so
    $PSScriptRoot/../../../.github/scripts/lib always resolves to OUR OWN
    bundled libs at the SAME version as this wrapper -- the two can never
    drift out of lockstep with each other, because they are the same
    install.

    Contrast with the DIFFERENT, unrelated problem documented at
    skills/session-startup/scripts/session-cleanup-detector.ps1:21-22: that
    warning is about resolving a CONSUMER repo's root from $PSScriptRoot
    (which points at the plugin install directory, not the repo the session
    is operating on -- deriving a consumer path via
    $PSScriptRoot/../../.. would silently resolve into the plugin cache
    instead of the user's project). This wrapper never targets a consumer
    repo at all; every path below stays inside this plugin's own bundled
    tree. A future reader should not "fix" this dot-source by adding a
    git-rev-parse-style consumer-root lookup -- that would solve a problem
    this file does not have.

    Forward slashes in the Join-Path child-path argument, per
    .github/architecture-rules.md's Join-Path child-path separator rule.
.PARAMETER Owner
    Repository owner.
.PARAMETER Repo
    Repository name.
.PARAMETER Mode
    'plan', 'design', or 'brief' (issue #951 chunk #956 added 'brief' — a
    brief review's judge-free authorizing record). See
    persist-phase-ledger-core.ps1's Invoke-PersistPhaseLedger for the full
    parameter surface this selects between.
.PARAMETER IssueNumber
    Required when -Mode plan.
.PARAMETER DesignCommentId
    Required when -Mode design.
.PARAMETER JudgeRulingsContent
    The complete `<!-- judge-rulings ... -->` bare-head block text. Required
    for -Mode plan and -Mode design. Under -Mode brief it is accepted and
    silently discarded, NOT rejected -- there is no mode gate on this
    parameter. A brief review has no judge stage, so nothing here can be
    written; the real refusal is content-shaped and lives in the writer, which
    rejects judge vocabulary found inside -BriefHeadContent itself.
.PARAMETER BriefHeadContent
    The complete `brief_dispositions:` authorizing head text. Required for,
    and only meaningful under, -Mode brief.
.PARAMETER PhaseContainmentBlocks
    Zero or more complete phase-containment block strings. Defaults to an
    empty array (the legal zero-sustained-findings clean path).
.EXAMPLE
    pwsh ./skills/session-memory-contract/scripts/persist-phase-ledger.ps1 `
        -Owner Grimblaz -Repo agent-orchestra -Mode plan -IssueNumber 878 `
        -JudgeRulingsContent $judgeText -PhaseContainmentBlocks @($block1, $block2)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][ValidateSet('plan', 'design', 'brief')][string]$Mode,
    [int]$IssueNumber,
    [long]$DesignCommentId,
    # Issue #951 added -Mode brief, whose authorizing record is a
    # `brief_dispositions:` head rather than a judge-rulings block — a brief
    # review has no judge stage, so there is no judge ruling that could
    # describe it. -JudgeRulingsContent is therefore no longer unconditionally
    # Mandatory: requiring it under -Mode brief would force every caller to
    # invent judge content for a mode that refuses judge content, which is the
    # false-provenance shape #951 exists to remove. It stays required for plan
    # and design (design accepts and discards it, per the long-standing
    # signature-uniformity note in the core), enforced below rather than by the
    # attribute.
    [string]$JudgeRulingsContent = '',
    [string]$BriefHeadContent = '',
    [string[]]$PhaseContainmentBlocks = @()
)

. (Join-Path $PSScriptRoot '../../../.github/scripts/lib/find-or-upsert-comment.ps1')
. (Join-Path $PSScriptRoot '../../../.github/scripts/lib/marker-transport-core.ps1')
. (Join-Path $PSScriptRoot '../../../.github/scripts/lib/phase-containment-emission-check-core.ps1')
. (Join-Path $PSScriptRoot 'persist-phase-ledger-core.ps1')

# Per-mode companion-parameter validation, moved off the [Parameter(Mandatory)]
# attributes because the requirement now differs by mode. Kept at the wrapper
# so a CLI caller gets the same refusal the library would give.
if ($Mode -ne 'brief' -and [string]::IsNullOrWhiteSpace($JudgeRulingsContent)) {
    Write-Error "persist-phase-ledger: -Mode $Mode requires -JudgeRulingsContent."
    exit 1
}
if ($Mode -eq 'brief' -and [string]::IsNullOrWhiteSpace($BriefHeadContent)) {
    Write-Error 'persist-phase-ledger: -Mode brief requires -BriefHeadContent (the `brief_dispositions:` authorizing head). A brief review has no judge stage, so -JudgeRulingsContent cannot substitute for it.'
    exit 1
}

$result = Invoke-PersistPhaseLedger -Owner $Owner -Repo $Repo -Mode $Mode `
    -IssueNumber $IssueNumber -DesignCommentId $DesignCommentId `
    -JudgeRulingsContent $JudgeRulingsContent -BriefHeadContent $BriefHeadContent `
    -PhaseContainmentBlocks $PhaseContainmentBlocks

# M12 fix (issue #878 judge-sustained review, AC2): surface the landed/
# not-landed artifact manifest alongside the top-level Success/Reason on
# both the failure and success paths, so a caller reading this wrapper's
# stdout/stderr can tell what happened at each step, not just the name of
# the step that ultimately failed.
function script:Format-PPLPersistPhaseLedgerArtifacts {
    param($Artifacts)
    if ($null -eq $Artifacts) { return '(no artifact manifest)' }
    return ($Artifacts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
}

if (-not $result.Success) {
    [Console]::Error.WriteLine("persist-phase-ledger (mode=$Mode): FAILED -- $($result.Reason)")
    [Console]::Error.WriteLine("persist-phase-ledger (mode=$Mode): artifacts -- $(script:Format-PPLPersistPhaseLedgerArtifacts -Artifacts $result.Artifacts)")
    exit 1
}

Write-Output "persist-phase-ledger (mode=$Mode): success"
Write-Output "persist-phase-ledger (mode=$Mode): artifacts -- $(script:Format-PPLPersistPhaseLedgerArtifacts -Artifacts $result.Artifacts)"
exit 0
