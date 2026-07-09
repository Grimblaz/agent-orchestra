#Requires -Version 7.0
<#!
.SYNOPSIS
    Thin wrapper for the version-pinned, per-test-identity Pester baseline
    capture tool (issue #818 / s2).

.DESCRIPTION
    Entry-point guard + param declaration. All logic lives in
    lib/pester6-baseline-core.ps1. Tests dot-source the core directly; this
    wrapper is for CLI invocation.

    This is a one-time acceptance/baseline tool for the #818 Pester 5→6
    migration, not a standing CI job — it is deliberately not registered in
    pester.yml.

.PARAMETER TestsPath
    Path to the directory containing .Tests.ps1 files.
    Defaults to .github/scripts/Tests relative to the repo root.

.PARAMETER RequiredVersion
    The exact installed Pester version to run under (e.g. '5.7.1' or '6.0.0').
    Mandatory — never auto-resolved to "newest installed".

.PARAMETER OutputPath
    Path to write the JSON result artifact to.
    Defaults to .tmp/issue-818/baseline-<RequiredVersion>.json relative to the
    repo root (NOT Documents/Design/ — that was an earlier mistake in this
    plan's history that was explicitly corrected).
#>
[CmdletBinding()]
param(
    [string]$TestsPath = (Join-Path $PSScriptRoot 'Tests'),

    [Parameter(Mandatory)]
    [string]$RequiredVersion,

    [string]$OutputPath
)

$isDotSourced = $MyInvocation.InvocationName -eq '.'

. "$PSScriptRoot/lib/pester6-baseline-core.ps1"

if (-not $isDotSourced) {
    if (-not $OutputPath) {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $OutputPath = Join-Path $repoRoot ".tmp/issue-818/baseline-$RequiredVersion.json"
    }

    $result = Invoke-Pester6BaselineCapture `
        -TestsPath $TestsPath `
        -RequiredVersion $RequiredVersion `
        -OutputPath $OutputPath

    if ($result.ExitCode -eq 0) {
        Write-Host "Baseline captured: $OutputPath"
        Write-Host ("  Pester {0} — total={1} passed={2} failed={3} skipped={4} notRun={5} discoveryErrors={6}" -f `
            $result.Result.importedVersion, `
            $result.Result.summary.totalTests, `
            $result.Result.summary.passed, `
            $result.Result.summary.failed, `
            $result.Result.summary.skipped, `
            $result.Result.summary.notRun, `
            $result.Result.summary.discoveryErrors)
    }

    exit $result.ExitCode
}
