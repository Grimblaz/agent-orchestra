#Requires -Version 7.0
<#!
.SYNOPSIS
    Thin wrapper for the file-granular parallel sharded Pester runner (issue #740).

.DESCRIPTION
    Entry-point guard + param declaration. All logic lives in lib/pester-sharded-core.ps1.
    Tests dot-source the core directly; this wrapper is for CLI invocation.

.PARAMETER TestsPath
    Path to the directory containing .Tests.ps1 files.
    Defaults to .github/scripts/Tests relative to the repo root.

.PARAMETER DeterminismCheck
    When set, runs the full shard set twice and diffs pass/fail outcomes per file.
    Fails if any file flips between runs.

.PARAMETER MinTestCount
    Soft minimum total test count. Fails if fewer tests were executed.
    Default: 200.

.PARAMETER Output
    Pester output verbosity. Default: Minimal.
#>
[CmdletBinding()]
param(
    [string]$TestsPath = (Join-Path $PSScriptRoot '../../.github/scripts/Tests'),
    [switch]$DeterminismCheck,
    [int]$MinTestCount = 200,
    [string]$Output = 'Minimal'
)

$isDotSourced = $MyInvocation.InvocationName -eq '.'

. "$PSScriptRoot/lib/pester-sharded-core.ps1"

if (-not $isDotSourced) {
    $result = Invoke-PesterSharded `
        -TestsPath $TestsPath `
        -DeterminismCheck:$DeterminismCheck `
        -MinTestCount $MinTestCount `
        -Output $Output
    exit $result.ExitCode
}
