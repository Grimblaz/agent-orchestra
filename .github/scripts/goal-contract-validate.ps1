#Requires -Version 7.0
<#!
.SYNOPSIS
    Thin CLI entry-guard wrapper for the goal-contract validator (issue #873,
    frame-slice s6).

.DESCRIPTION
    Entry-point guard + param declaration, mirroring the pattern at
    capture-pester6-baseline.ps1:40-42. All logic lives in
    lib/goal-contract-validate-core.ps1 (public entry point
    Invoke-GoalContractValidate); this wrapper dot-sources that core and
    exits on the resulting verdict's exit code when invoked directly
    (never when dot-sourced by a test).

    This wrapper's public CLI surface deliberately does NOT expose a
    -MinTestCount parameter. Invoke-GoalContractValidate accepts one
    internally so the fixture/test harness can override
    Invoke-PesterSharded's 200-test floor for a tiny fixture suite (Part
    E / frame-slice s6 RC item 5), but a real production validation run
    invoked through this CLI must never be able to weaken the s4
    green-floor gate -- the parameter simply is not declared here, so it
    is unreachable from the command line.

.PARAMETER Issue
    The GitHub issue number whose plan-issue-pinned comment (marker
    `<!-- plan-issue-{Issue} -->` by default) carries the approved
    goal-contract block to validate against committed code.

.PARAMETER RepoRoot
    Path to the repository root to validate. The validator refuses a dirty
    tree at this path before creating any disposable worktree (s2, AC2).

.PARAMETER Repo
    Optional `owner/repo` override for the GitHub API read. Defaults to the
    `origin` remote resolved from RepoRoot when omitted (see
    Get-GCPinnedCommentBody).

.PARAMETER GhCliPath
    Optional override for the `gh` CLI executable path. Defaults to `gh`.
    Unlike -MinTestCount, overriding this never weakens a validation floor,
    so it is exposed here (mainly useful for test/CI shims of the `gh`
    binary itself, not for weakening validator behavior).

.OUTPUTS
    Writes the JSON-serialized verdict object (see New-GCVerdictReport) to
    stdout, then exits with the verdict's ExitCode: 0=pass, 1=fail,
    2=refused, 3=pass-review-required (human review mandatory before
    merge -- see New-GCVerdictReport's exit-3 loop-contract doc comment).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$Issue,

    [Parameter(Mandatory)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $false)]
    [string]$Repo,

    [Parameter(Mandatory = $false)]
    [string]$GhCliPath
)

$isDotSourced = $MyInvocation.InvocationName -eq '.'

. (Join-Path $PSScriptRoot 'lib/goal-contract-validate-core.ps1')

if (-not $isDotSourced) {
    $invokeArgs = @{
        Issue    = $Issue
        RepoRoot = $RepoRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($Repo)) {
        $invokeArgs['Repo'] = $Repo
    }
    if (-not [string]::IsNullOrWhiteSpace($GhCliPath)) {
        $invokeArgs['GhCliPath'] = $GhCliPath
    }

    $result = Invoke-GoalContractValidate @invokeArgs

    # F2 (GH review PR #892): defense-in-depth against a future refactor.
    # $result is currently unreachable as $null/without an ExitCode -- every
    # Invoke-GoalContractValidate return path routes through
    # New-GCVerdictReport, which always sets ExitCode -- but if that ever
    # changes, this must fail CLOSED (exit 2, refused) rather than either
    # throwing an uncaught NullReferenceException on `$result.ExitCode` or
    # falling back to exit 3 (pass-review-required), which is merge-
    # permitting and therefore the wrong direction to fail in. This guard
    # must run before the ConvertTo-Json emit below so a $null result never
    # reaches stdout as the literal string "null".
    if ($null -eq $result -or $null -eq $result.ExitCode) { exit 2 }

    $result | ConvertTo-Json -Depth 10 | Write-Output

    exit $result.ExitCode
}
