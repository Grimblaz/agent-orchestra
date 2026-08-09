#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Measures an exit destination in the memory store's own counting rule, and validates a
    measurement record against the four fields the sweep requires.

.DESCRIPTION
    Step 5 of skills/agent-memory-compaction/references/sweep-procedure.md. Read-only.

    A promotion's destination can itself be a bounded surface - for a Claude Code store, the
    user-global CLAUDE.md, loaded by every session and carrying the admission rule. The step
    exists so a sweep can say "this destination is filling up", and it needs a number that
    reproduces from the file on disk.

    The policy check will not produce it: it refuses a path that is not an index, by design. So
    the counting rule is applied here instead - UTF-8 decoded, CRLF and lone CR normalized to a
    single LF, length in UTF-16 code units - by the same function the size axis uses, so a
    destination measurement and an index measurement are comparable numbers.

    A record missing any of value, unit, date or surface cannot say the thing the step exists to
    say, and neither can a hand count nobody else can reproduce. -Validate is the polarity that
    catches one where it is written.

.PARAMETER Path
    The destination file to measure.

.PARAMETER Validate
    A measurement record to check instead of measuring anything: 'date | value | unit | surface |
    method'. Reports each missing or malformed field.

.PARAMETER AsOf
    The date recorded on the measurement. Defaults to today; passed explicitly by tests.

.PARAMETER Json
    Emit the measurement or the validation result as a single JSON object.

.OUTPUTS
    Exit 0 - measured, or the record validates. Exit 1 - the record does not conform. Exit 3 -
    usage error.

.EXAMPLE
    pwsh Measure-MemorySurface.ps1 -Path ~/.claude/CLAUDE.md

.EXAMPLE
    pwsh Measure-MemorySurface.ps1 -Validate '2026-08-08 | 2548 | characters | ~/.claude/CLAUDE.md | Measure-MemorySurface.ps1'
#>

[CmdletBinding(DefaultParameterSetName = 'Measure')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Measure')]
    [string]$Path,

    [Parameter(Mandatory = $true, ParameterSetName = 'Validate')]
    [string]$Validate,

    [Parameter()]
    [datetime]$AsOf = [datetime]::Today,

    [Parameter()]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'memory-sweep-core.ps1')

if ($PSCmdlet.ParameterSetName -eq 'Validate') {
    $verdict = Test-MSSurfaceMeasurement -Record $Validate
    if ($Json) {
        Write-Output ([pscustomobject]@{ result = $(if ($verdict.Conforming) { 'conforming' } else { 'non-conforming' }); problems = @($verdict.Problems) } | ConvertTo-Json -Depth 4)
    }
    else {
        $lines = @("RESULT: $(if ($verdict.Conforming) { 'conforming' } else { 'non-conforming' })")
        $lines += @($verdict.Problems | ForEach-Object { "  - $_" })
        Write-Output ($lines -join "`n")
    }
    exit $(if ($verdict.Conforming) { 0 } else { 1 })
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Output "RESULT: usage-error`nreason: no file at '$Path'"
    exit 3
}

$measurement = New-MSSurfaceMeasurement -Path $Path -AsOf $AsOf
if ($Json) {
    Write-Output ($measurement | ConvertTo-Json -Depth 4)
}
else {
    Write-Output (Format-MSSurfaceMeasurement -Measurement $measurement)
}
exit 0
