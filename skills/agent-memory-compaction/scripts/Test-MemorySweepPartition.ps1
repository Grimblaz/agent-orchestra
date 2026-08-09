#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Reconciles a recorded pre-sweep enumeration against the post-sweep store, and names anything
    that left recall without a record.

.DESCRIPTION
    Step 6 of skills/agent-memory-compaction/references/sweep-procedure.md. Read-only.

    Every subject in the enumeration must be accounted for in exactly one of three ways: its
    pointer is still in the index (still hot), its pointer is in ARCHIVE.md (demoted), or an
    executed exit record in LEDGER.md carries its life key (exited with a record). An orphan body
    has no pointer to be still-hot, so it accounts as exited, demoted, or assessed in place.
    Anything else is unaccounted - it left without a record, which the first replacement rule
    forbids outright.

    The INPUT is the artifact written before any disposition was taken. That is what makes this
    check able to fail: a partition drawn from the sweep's own working list agrees with itself
    however the store actually ended up, and a list enumerated from a session's truncated view of
    the index is missing the tail before the check ever runs.

    A malformed ledger or slate record is reported here too. A record this parser cannot read is
    a third answer, not a quiet pass.

.PARAMETER InventoryPath
    The JSON artifact written by Get-MemorySweepInventory.ps1 before the sweep.

.PARAMETER IndexPath
    The store's index file, read as it now stands.

.PARAMETER LedgerPath
    Path to LEDGER.md. Defaults to LEDGER.md beside the index.

.PARAMETER ArchivePath
    Path to ARCHIVE.md. Defaults to ARCHIVE.md beside the index.

.PARAMETER SlatePath
    Path to SLATE.md. Defaults to SLATE.md beside the index.

.PARAMETER Json
    Emit the report as a single JSON object instead of human-readable lines.

.OUTPUTS
    Exit 0 - everything accounted for. Exit 1 - something is unaccounted for, or a record could
    not be read. Exit 3 - usage error.

.EXAMPLE
    pwsh Test-MemorySweepPartition.ps1 -InventoryPath .tmp/sweep-inventory.json -IndexPath ~/.claude/projects/p/memory/MEMORY.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InventoryPath,

    [Parameter(Mandatory = $true)]
    [string]$IndexPath,

    [Parameter()]
    [string]$LedgerPath,

    [Parameter()]
    [string]$ArchivePath,

    [Parameter()]
    [string]$SlatePath,

    [Parameter()]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'memory-sweep-core.ps1')

foreach ($required in @(@{ p = $InventoryPath; what = 'enumeration artifact' }, @{ p = $IndexPath; what = 'index file' })) {
    if (-not (Test-Path -LiteralPath $required.p -PathType Leaf)) {
        Write-Output "RESULT: usage-error`nreason: no $($required.what) at '$($required.p)'"
        exit 3
    }
}

$inventory = [System.IO.File]::ReadAllText($InventoryPath) | ConvertFrom-Json
$report = Test-MSPartition -Inventory $inventory -IndexPath $IndexPath -LedgerPath $LedgerPath -ArchivePath $ArchivePath -SlatePath $SlatePath

if ($Json) {
    Write-Output ($report | ConvertTo-Json -Depth 6)
}
else {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("RESULT: $($report.result)")
    $lines.Add("enumerated: $($report.subjects_checked) subject(s) on $($report.enumerated_on), from $($report.enumerated_from)")
    $lines.Add("accounted: $(@($report.accounted).Count)")
    $lines.Add("unaccounted: $(@($report.unaccounted).Count)")
    foreach ($u in @($report.unaccounted)) { $lines.Add("  - $($u.identity) [$($u.population)] - $($u.why)") }
    foreach ($m in @($report.ledger_malformed)) { $lines.Add("  - unreadable ledger record: $m") }
    foreach ($m in @($report.slate_malformed)) { $lines.Add("  - unreadable slate row: $m") }
    Write-Output ($lines -join "`n")
}

exit $(if ($report.result -eq 'accounted') { 0 } else { 1 })
