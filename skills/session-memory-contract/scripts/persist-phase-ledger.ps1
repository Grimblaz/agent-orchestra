#Requires -Version 7.0

<#
.SYNOPSIS
    Thin CLI/production wrapper for Invoke-PersistPhaseLedger (issue #878,
    plan slice s5).
.DESCRIPTION
    Owns the dot-source of the hub primitives this feature composes:
    find-or-upsert-comment.ps1 (Find-OrUpsertComment, Get-RestCommentId) and
    phase-containment-emission-check-core.ps1 (Add-CommentBlocks,
    Add-JudgeRulingsBlock, Get-DispositionTally;
    phase-containment-emission-check-core.ps1's own line 24 (`. (Join-Path
    $PSScriptRoot 'phase-containment-core.ps1')`) transitively dot-sources
    phase-containment-core.ps1, so no third dot-source line is needed
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
    'plan' or 'design'. See persist-phase-ledger-core.ps1's
    Invoke-PersistPhaseLedger for the full parameter surface this selects
    between.
.PARAMETER IssueNumber
    Required when -Mode plan.
.PARAMETER DesignCommentId
    Required when -Mode design.
.PARAMETER JudgeRulingsContent
    The complete `<!-- judge-rulings ... -->` bare-head block text.
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
    [Parameter(Mandatory)][ValidateSet('plan', 'design')][string]$Mode,
    [int]$IssueNumber,
    [long]$DesignCommentId,
    [Parameter(Mandatory)][string]$JudgeRulingsContent,
    [string[]]$PhaseContainmentBlocks = @()
)

. (Join-Path $PSScriptRoot '../../../.github/scripts/lib/find-or-upsert-comment.ps1')
. (Join-Path $PSScriptRoot '../../../.github/scripts/lib/phase-containment-emission-check-core.ps1')
. (Join-Path $PSScriptRoot 'persist-phase-ledger-core.ps1')

$result = Invoke-PersistPhaseLedger -Owner $Owner -Repo $Repo -Mode $Mode `
    -IssueNumber $IssueNumber -DesignCommentId $DesignCommentId `
    -JudgeRulingsContent $JudgeRulingsContent -PhaseContainmentBlocks $PhaseContainmentBlocks

# M12 fix (issue #878 judge-sustained review, AC2): surface the landed/
# not-landed artifact manifest alongside the top-level Success/Reason on
# both the failure and success paths, so a caller reading this wrapper's
# stdout/stderr can tell what happened at each step, not just the name of
# the step that ultimately failed.
function script:Format-PersistPhaseLedgerArtifacts {
    param($Artifacts)
    if ($null -eq $Artifacts) { return '(no artifact manifest)' }
    return ($Artifacts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
}

if (-not $result.Success) {
    [Console]::Error.WriteLine("persist-phase-ledger (mode=$Mode): FAILED -- $($result.Reason)")
    [Console]::Error.WriteLine("persist-phase-ledger (mode=$Mode): artifacts -- $(script:Format-PersistPhaseLedgerArtifacts -Artifacts $result.Artifacts)")
    exit 1
}

Write-Output "persist-phase-ledger (mode=$Mode): success"
Write-Output "persist-phase-ledger (mode=$Mode): artifacts -- $(script:Format-PersistPhaseLedgerArtifacts -Artifacts $result.Artifacts)"
exit 0
