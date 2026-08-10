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

    NOTE: this GLOBS. It is not the per-PR gate's population — the gate runs a
    glob MINUS the quarantine registry, so pointing this at the tests root
    measures every suite on disk including the quarantined ones. Pass -SuitePath
    to run a selected list instead.

.PARAMETER SuitePath
    An explicit list of suite files to run. When supplied, nothing is globbed
    and TestsPath is ignored. An empty list is an error, never a run over
    nothing.

.PARAMETER FanOutWidth
    How many suite processes run concurrently. Derive it with
    Get-PesterFanOutWidth rather than picking a number.

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
    [AllowEmptyCollection()][string[]]$SuitePath,
    [switch]$DeterminismCheck,
    [int]$MinTestCount = 200,
    [ValidateSet('None', 'Minimal', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Minimal',
    [ValidateRange(1, 256)][int]$FanOutWidth = 8
)

$isDotSourced = $MyInvocation.InvocationName -eq '.'

. "$PSScriptRoot/lib/pester-sharded-core.ps1"

if (-not $isDotSourced) {
    $forward = @{
        DeterminismCheck = $DeterminismCheck
        MinTestCount     = $MinTestCount
        Output           = $Output
        FanOutWidth      = $FanOutWidth
    }
    # -SuitePath is forwarded only when the caller actually supplied it: the
    # runner distinguishes "no list given, so glob" from "a list given that
    # happens to be empty, which is an error", and passing an unbound $null
    # through would collapse that distinction.
    if ($PSBoundParameters.ContainsKey('SuitePath')) { $forward['SuitePath'] = $SuitePath }
    else { $forward['TestsPath'] = $TestsPath }

    $result = Invoke-PesterSharded @forward
    exit $result.ExitCode
}
