#Requires -Version 7.0
<#
.SYNOPSIS
    Vendor /goal loop predicate evaluator (issue #874, M1 fix): the live
    predicate command a goal-run session hands to the vendor loop, now
    actually invoking the launch-pinned contract-hash check
    (Test-GoalRunContractHashPinned, goal-run-prompt-core.ps1) on every
    iteration instead of rendering the raw validator script directly as
    the predicate command with no pin check ever wired in front of it.
.DESCRIPTION
    Invoke-GoalRunPredicateEvaluate -Issue <int> -RepoRoot <string>
                                     [-Marker <string>] [-Repo <string>]
                                     [-Owner <string>] [-GhCliPath <string>]
                                     [-GitCliPath <string>] [-PwshCliPath <string>]
                                     [-ValidatorScriptPath <string>]
                                     [-ActiveStateReader <scriptblock>]
                                     [-PredicateResolver <scriptblock>]
                                     [-HaltEmitter <scriptblock>]

    -RepoRoot is the provisioned goal-run worktree. It is both the
    validation target and the location goal-run-active.json
    (goal-run-worktree-core.ps1, Get-GoalRunActiveState) is read from for
    the launch-pinned contract_hash value the pin check compares against.
    This function reads the state file itself, then delegates to
    Resolve-GoalRunLoopPredicate (goal-run-prompt-core.ps1) for the actual
    pin-check-then-validate composition -- it does not reimplement that
    ordering, it only supplies the missing piece (the state-file read) the
    vendor loop predicate command needs, and translates the result into an
    exit code the vendor loop understands.

    Exit-code translation (874-D3, see Documents/Design/goal-loop-
    capability-probe.md, "Exit-3 release path risk"): 874-D3 already
    documents that a flag-bearing validator exit 3 must be interpreted as
    satisfied at the application level, not through a vendor-loop
    multi-code contract -- the risk that doc names is that rendering the
    RAW validator script directly as the predicate command (the bug this
    file fixes) never performs that translation, so a vendor loop that only
    understands the plain exit-0-means-met / nonzero-means-not-met
    shell-predicate convention would never see a flag-bearing exit 3 as
    release. This function is that missing translation layer: every
    'satisfied' Disposition (raw validator exit 0, or a non-infra-error raw
    exit 3) becomes wrapper ExitCode 0; 'not-satisfied' becomes ExitCode 1;
    'halt' becomes ExitCode 2. The 1-versus-2 split is diagnostic only, for
    a human reading process logs -- the vendor loop is assumed to treat
    every nonzero value identically as not-met, since no documented vendor
    contract distinguishes between them.

    On a 'halt' Disposition (launch-pinned hash mismatch, or the validator
    itself refusing or hitting an infra error), this function also posts
    the goal-halt-report-{issue} comment (Invoke-GoalRunHaltEmit,
    goal-run-halt-core.ps1) before returning, because the vendor loop has
    no halt-reporting mechanism of its own -- it will only ever see this
    function ExitCode and keep iterating on any nonzero value.
    Invoke-GoalRunHaltEmit upserts against a fixed per-issue marker, so
    when this function runs again on a later loop iteration while the halt
    condition still holds, re-emitting the same report updates the same
    comment in place rather than posting a growing pile of duplicates.

    TOCTOU note (M21, honest and accepted, not eliminated): once the pin
    check passes, Resolve-GoalRunLoopPredicate invokes the validator as a
    separate subprocess, and that subprocess independently re-fetches the
    live contract comment a second time. A contract edit landing in the
    narrow window between the pin check fetch and the validator fetch is a
    known residual race this function does not close -- closing it would
    require re-architecting the validator fetch path, which is out of
    scope here. The pin check still closes the much larger window between
    LAUNCH time and this iteration, which is the actual M1 threat model.
.OUTPUTS
    [pscustomobject]@{ ExitCode; Disposition; HaltReason; Reason;
    HaltEmitted; ValidatorRan }
#>

. (Join-Path $PSScriptRoot 'goal-run-chain-core.ps1')
. (Join-Path $PSScriptRoot 'goal-run-worktree-core.ps1')

function Invoke-GoalRunPredicateEvaluate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Marker,
        [string]$Repo,
        [string]$Owner,
        [string]$GhCliPath = 'gh',
        [string]$GitCliPath = 'git',
        [string]$PwshCliPath = 'pwsh',
        [string]$ValidatorScriptPath,
        [scriptblock]$ActiveStateReader,
        [scriptblock]$PredicateResolver,
        [scriptblock]$HaltEmitter
    )

    if (-not $ActiveStateReader) {
        $ActiveStateReader = {
            param($WorktreePath)
            Get-GoalRunActiveState -WorktreePath $WorktreePath
        }
    }
    if (-not $PredicateResolver) {
        $PredicateResolver = {
            param($Issue, $RepoRoot, $LaunchPinnedHash, $Marker, $Repo, $GhCliPath, $GitCliPath, $PwshCliPath, $ValidatorScriptPath)
            Resolve-GoalRunLoopPredicate -Issue $Issue -RepoRoot $RepoRoot -LaunchPinnedHash $LaunchPinnedHash -Marker $Marker -Repo $Repo -GhCliPath $GhCliPath -GitCliPath $GitCliPath -PwshCliPath $PwshCliPath -ValidatorScriptPath $ValidatorScriptPath
        }
    }
    if (-not $HaltEmitter) {
        $HaltEmitter = {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            Invoke-GoalRunHaltEmit -Report $Report -Issue $Issue -RepoRoot $RepoRoot -Owner $Owner -Repo $Repo
        }
    }

    $state = & $ActiveStateReader $RepoRoot
    $pinnedHash = if ($state) { [string]$state.contract_hash } else { $null }

    if ([string]::IsNullOrWhiteSpace($pinnedHash)) {
        # Should never happen against a genuinely launched run -- the state
        # file is always written (New-GoalRunActiveState) before the loop
        # is ever launched. Fail closed rather than skip the pin check
        # silently: shape this as the same 'halt' Disposition the resolver
        # itself would return, so it flows through the SAME halt-report
        # emission and exit-code translation below rather than a separate,
        # hand-rolled early return -- the predicate command must never
        # exit silently on this branch either.
        $result = [pscustomobject]@{
            Disposition  = 'halt'
            HaltReason   = 'chain-stage-failure'
            Reason       = 'goal-run-active-state-unreadable'
            ValidatorRan = $false
        }
    }
    else {
        $result = & $PredicateResolver $Issue $RepoRoot $pinnedHash $Marker $Repo $GhCliPath $GitCliPath $PwshCliPath $ValidatorScriptPath
    }

    $haltEmitted = $false
    if ($result.Disposition -eq 'halt') {
        $remediation = if ($result.HaltReason -eq 'invariant-conflict') {
            'The live goal-contract changed after this run launch-pinned hash was recorded. Confirm whether the edit was intentional: restore the originally approved contract text to resume this run, or stop this run and launch a fresh /goal-run invocation against the updated contract.'
        }
        elseif ($result.Reason -eq 'goal-run-active-state-unreadable') {
            'goal-run-active.json could not be read from the provisioned worktree, so the launch-pinned contract hash is unavailable. Investigate the worktree state directly -- this indicates the run own provisioning state is missing or corrupted, not a resolvable-by-looping-again condition.'
        }
        else {
            'The validator itself could not complete an assessment (refused, or hit an infra error). Investigate the validator failure directly -- looping again will not resolve a precondition failure.'
        }

        $evidence = if ([string]::IsNullOrWhiteSpace([string]$result.Reason)) { @() } else { @([string]$result.Reason) }
        $report = New-GoalRunChainHaltReport -Issue $Issue -HaltReason $result.HaltReason -Stage 'loop' -PlanRemediation $remediation -Evidence $evidence
        & $HaltEmitter $report $Issue $RepoRoot $Owner $Repo | Out-Null
        $haltEmitted = $true
    }

    $exitCode = switch ($result.Disposition) {
        'satisfied' { 0 }
        'not-satisfied' { 1 }
        'halt' { 2 }
        default { 2 }
    }

    return [pscustomobject]@{
        ExitCode     = $exitCode
        Disposition  = $result.Disposition
        HaltReason   = $result.HaltReason
        Reason       = $result.Reason
        HaltEmitted  = $haltEmitted
        ValidatorRan = $result.ValidatorRan
    }
}
