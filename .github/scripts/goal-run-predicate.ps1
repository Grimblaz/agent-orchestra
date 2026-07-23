#Requires -Version 7.0
<#!
.SYNOPSIS
    Thin CLI entry-guard wrapper for the goal-run vendor loop predicate
    (issue #874, M1 fix). This is the command a live /goal-run session
    renders as the vendor loop predicate (New-GoalRunPromptText,
    goal-run-prompt-core.ps1) instead of the raw validator script.

.DESCRIPTION
    Entry-point guard + param declaration, mirroring the pattern at
    goal-contract-validate.ps1. All logic lives in
    lib/goal-run-predicate-core.ps1 (public entry point
    Invoke-GoalRunPredicateEvaluate); this wrapper dot-sources that core
    and exits on the resulting verdict exit code when invoked directly
    (never when dot-sourced by a test).

    Exit-code contract for the vendor /goal loop predicate command is the
    standard shell-predicate convention: exit 0 means the condition is
    met (release); any nonzero exit means not met (keep looping). See the
    core file header comment for the full 874-D3 rationale behind that
    choice and the meaning of exit 1 versus exit 2.

.PARAMETER Issue
    The GitHub issue number carrying the approved goal-contract.

.PARAMETER RepoRoot
    Path to the provisioned goal-run worktree. Also where
    goal-run-active.json is read from for the launch-pinned contract hash.

.PARAMETER Repo
    Optional `owner/repo` override for the GitHub API read. Defaults to the
    `origin` remote resolved from RepoRoot when omitted.

.PARAMETER Owner
    Optional owner override, paired with -Repo, used when posting a halt
    report.

.PARAMETER GhCliPath
    Optional override for the `gh` CLI executable path. Defaults to `gh`.

.PARAMETER GitCliPath
    Optional override for the `git` CLI executable path. Defaults to `git`.

.PARAMETER PwshCliPath
    Optional override for the `pwsh` CLI executable path used to invoke the
    validator subprocess. Defaults to `pwsh`.

.PARAMETER ValidatorScriptPath
    Optional override for the validator script path. Defaults to
    `.github/scripts/goal-contract-validate.ps1` under -RepoRoot.

.OUTPUTS
    Writes the JSON-serialized verdict object to stdout, then exits with
    the verdict ExitCode: 0=satisfied, 1=not-satisfied, 2=halt.
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
    [string]$Owner,

    [Parameter(Mandatory = $false)]
    [string]$GhCliPath,

    [Parameter(Mandatory = $false)]
    [string]$GitCliPath,

    [Parameter(Mandatory = $false)]
    [string]$PwshCliPath,

    [Parameter(Mandatory = $false)]
    [string]$ValidatorScriptPath
)

$isDotSourced = $MyInvocation.InvocationName -eq '.'

. (Join-Path $PSScriptRoot 'lib/goal-run-predicate-core.ps1')

if (-not $isDotSourced) {
    $invokeArgs = @{
        Issue    = $Issue
        RepoRoot = $RepoRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($Repo)) { $invokeArgs['Repo'] = $Repo }
    if (-not [string]::IsNullOrWhiteSpace($Owner)) { $invokeArgs['Owner'] = $Owner }
    if (-not [string]::IsNullOrWhiteSpace($GhCliPath)) { $invokeArgs['GhCliPath'] = $GhCliPath }
    if (-not [string]::IsNullOrWhiteSpace($GitCliPath)) { $invokeArgs['GitCliPath'] = $GitCliPath }
    if (-not [string]::IsNullOrWhiteSpace($PwshCliPath)) { $invokeArgs['PwshCliPath'] = $PwshCliPath }
    if (-not [string]::IsNullOrWhiteSpace($ValidatorScriptPath)) { $invokeArgs['ValidatorScriptPath'] = $ValidatorScriptPath }

    $result = Invoke-GoalRunPredicateEvaluate @invokeArgs

    # Defense-in-depth against a future refactor, mirroring the same guard
    # in goal-contract-validate.ps1: fail CLOSED (exit 2) rather than
    # throw an uncaught exception or fall through to exit 0, which
    # would be release-permitting and therefore the wrong direction to
    # fail in.
    if ($null -eq $result -or $null -eq $result.ExitCode) { exit 2 }

    $result | ConvertTo-Json -Depth 10 | Write-Output

    exit $result.ExitCode
}
