#Requires -Version 7.0
<#!
.SYNOPSIS
    Thin wrapper for the post-port acceptance delta gate (issue #818 / s7).

.DESCRIPTION
    Entry-point guard + param declaration. All logic lives in
    lib/pester6-baseline-delta-core.ps1. Tests dot-source the core directly;
    this wrapper is for CLI invocation.

    This is a one-time acceptance-evidence tool for the #818 Pester 5->6
    migration, not a standing CI job.

.PARAMETER BaselinePath
    Path to the baseline `capture-pester6-baseline.ps1` JSON artifact
    (the pre-port / accepted-failures reference).

.PARAMETER CandidatePath
    Path to the candidate `capture-pester6-baseline.ps1` JSON artifact
    (the run being evaluated against the baseline).

.PARAMETER OutputJsonPath
    Path to write the full delta result as JSON. Optional.

.PARAMETER OutputMarkdownPath
    Path to write the PR-evidence Markdown verdict report. Optional.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BaselinePath,

    [Parameter(Mandatory)]
    [string]$CandidatePath,

    [string]$OutputJsonPath,

    [string]$OutputMarkdownPath
)

$isDotSourced = $MyInvocation.InvocationName -eq '.'

. "$PSScriptRoot/lib/pester6-baseline-delta-core.ps1"

if (-not $isDotSourced) {
    $result = Invoke-Pester6BaselineDelta `
        -BaselinePath $BaselinePath `
        -CandidatePath $CandidatePath `
        -OutputJsonPath $OutputJsonPath `
        -OutputMarkdownPath $OutputMarkdownPath

    if ($null -ne $result.Result) {
        Write-Host ("Verdict: {0} — {1}" -f $result.Result.verdict, $result.Result.verdictReason)
        Write-Host ("  newFailures={0} reasonChanged={1} resolved={2} identityDrift(missing={3}, new={4})" -f `
            @($result.Result.newFailures).Count, `
            @($result.Result.reasonChanged).Count, `
            @($result.Result.resolved).Count, `
            @($result.Result.identityDrift.missingFromCandidate).Count, `
            @($result.Result.identityDrift.newInCandidate).Count)
    }

    exit $result.ExitCode
}
