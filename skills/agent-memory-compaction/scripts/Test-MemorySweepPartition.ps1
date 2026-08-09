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
    Exit 0 - everything accounted for.
    Exit 1 - something left recall without a record, or a record could not be read.
    Exit 2 - could not verify: the store records no admitted dates, so presence cannot be
             established per life. Reported rather than answered, because on such a store the
             name-keyed answer and the life-keyed answer are the same operation and only one of
             them is trustworthy.
    Exit 3 - usage error: the artifact is not an enumeration, or its fields do not parse.

.EXAMPLE
    pwsh Test-MemorySweepPartition.ps1 -InventoryPath .tmp/sweep-inventory.json -IndexPath ~/.claude/projects/p/memory/MEMORY.md
#>

[CmdletBinding()]
param(
    # Not Mandatory - see Get-MemorySweepInventory.ps1: a mandatory parameter prompts, and an
    # unattended sweep blocks on the prompt instead of reporting.
    [Parameter()]
    [string]$InventoryPath,

    [Parameter()]
    [string]$IndexPath,

    [Parameter()]
    [string]$LedgerPath,

    [Parameter()]
    [string]$ArchivePath,

    [Parameter()]
    [string]$SlatePath,

    [Parameter()]
    [datetime]$AsOf = [datetime]::Today,

    [Parameter()]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'memory-sweep-core.ps1')

foreach ($required in @(@{ p = $InventoryPath; what = 'enumeration artifact' }, @{ p = $IndexPath; what = 'index file' })) {
    if ([string]::IsNullOrWhiteSpace($required.p)) {
        Write-Output "RESULT: usage-error`nreason: the $($required.what) path is required"
        exit 3
    }
    if (-not (Test-Path -LiteralPath $required.p -PathType Leaf)) {
        Write-Output "RESULT: usage-error`nreason: no $($required.what) at '$($required.p)'"
        exit 3
    }
}

# Resolved against the PowerShell location for the same reason the inventory writer resolves its
# output path: the .NET reader would otherwise look in the process CWD.
$absoluteInventory = (Resolve-Path -LiteralPath $InventoryPath).ProviderPath
$inventory = $null
try { $inventory = [System.IO.File]::ReadAllText($absoluteInventory) | ConvertFrom-Json }
catch { $inventory = $null }

# "Your input was not an enumeration artifact" and "something left recall without a record" are
# different answers and must not share an exit code. Without this the second one is what a caller
# sees when it passes the wrong file, which is the loudest possible way to be wrong.
foreach ($required in @('subjects', 'enumerated_on', 'source')) {
    if ($null -eq $inventory -or $inventory.PSObject.Properties.Name -notcontains $required) {
        Write-Output "RESULT: usage-error`nreason: '$InventoryPath' is not an enumeration artifact - it does not carry '$required'. Produce one with Get-MemorySweepInventory.ps1 -OutputPath."
        exit 3
    }
}

$report = Test-MSPartition -Inventory $inventory -IndexPath $IndexPath -LedgerPath $LedgerPath -ArchivePath $ArchivePath -SlatePath $SlatePath -AsOf $AsOf

if ($Json) {
    Write-Output ($report | ConvertTo-Json -Depth 6)
}
else {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("RESULT: $($report.result)")
    $lines.Add("enumerated: $($report.subjects_checked) subject(s) on $($report.enumerated_on), from $($report.enumerated_from)")
    $lines.Add("accounted: $(@($report.accounted).Count)")
    $lines.Add("unaccounted: $(@($report.unaccounted).Count)")
    $lines.Add("unverifiable: $(@($report.unverifiable).Count)")
    foreach ($u in @($report.unaccounted)) { $lines.Add("  - $($u.identity) [$($u.population)] - $($u.why)") }
    foreach ($u in @($report.unverifiable)) { $lines.Add("  ? $($u.identity) [$($u.population)] - $($u.why)") }
    foreach ($m in @($report.record_problems)) { $lines.Add("  - $m") }
    if (@($report.unverifiable).Count -gt 0) {
        $lines.Add('')
        $lines.Add('This store records no admitted dates, so presence cannot be established per life.')
        $lines.Add('Landing the admission rule - the third limb of the split shape - is what makes this')
        $lines.Add('check able to tell one life of a re-earned name from another.')
    }
    Write-Output ($lines -join "`n")
}

# 0 accounted - 1 something left without a record, or a record could not be read
# 2 could not verify, reporting no verdict rather than a plausible wrong one - 3 usage error
exit $(switch ($report.result) { 'accounted' { 0 } 'unaccounted' { 1 } 'unverifiable' { 2 } default { 3 } })
