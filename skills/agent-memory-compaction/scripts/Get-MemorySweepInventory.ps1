#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Enumerates a memory store's corpus from disk, ordered as a sweep must take it, and records
    the enumeration as an artifact the partition check reads back.

.DESCRIPTION
    Step 1 of skills/agent-memory-compaction/references/sweep-procedure.md. Read-only.

    The index is read FROM DISK, never from a session's loaded view. A store large enough to be
    worth sweeping is one whose load may have been truncated, and a corpus enumerated from that
    view is already missing its tail - after which every reconciliation against it agrees
    perfectly, because both halves came from the same short list.

    The corpus is two populations: every linked subject on the index's pointer lines, and every
    entry file in the store directory no pointer points at. Orphan bodies are invisible to the
    policy check, whose whole subject is the index; they still hold lessons and can still be
    critical.

    Output ordering is step 2's: incomplete dispositions first, then every critical entry, then
    expired deferrals, then entries nobody has assessed, then the rest. The order comes from the
    slate state and never from where a line happens to sit in the file.

.PARAMETER IndexPath
    Path to the store's index file.

.PARAMETER SlatePath
    Path to SLATE.md. Defaults to SLATE.md beside the index.

.PARAMETER LedgerPath
    Path to LEDGER.md. Defaults to LEDGER.md beside the index.

.PARAMETER ArchivePath
    Path to ARCHIVE.md. Defaults to ARCHIVE.md beside the index. A store that has never demoted
    anything has none, which is reported rather than treated as a defect.

.PARAMETER OutputPath
    Where to write the enumeration artifact as JSON. Step 6 reads it back. Without it the
    artifact goes to standard output only, which is enough to look at and not enough to
    reconcile against later.

.PARAMETER AsOf
    The date deferral expiry is judged against. Defaults to today. Passed explicitly by tests so
    an expiry assertion cannot start passing or failing because time moved.

.OUTPUTS
    Exit 0 - enumerated. Exit 3 - usage error (a path that does not resolve).

.EXAMPLE
    pwsh Get-MemorySweepInventory.ps1 -IndexPath ~/.claude/projects/p/memory/MEMORY.md -OutputPath .tmp/sweep-inventory.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IndexPath,

    [Parameter()]
    [string]$SlatePath,

    [Parameter()]
    [string]$LedgerPath,

    [Parameter()]
    [string]$ArchivePath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [datetime]$AsOf = [datetime]::Today
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'memory-sweep-core.ps1')

if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
    Write-Output "RESULT: usage-error`nreason: no index file at '$IndexPath'"
    exit 3
}

$inventory = New-MSInventory -IndexPath $IndexPath -SlatePath $SlatePath -LedgerPath $LedgerPath -ArchivePath $ArchivePath -AsOf $AsOf
$json = $inventory | ConvertTo-Json -Depth 6

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # Resolved against the PowerShell location, not the process CWD. The .NET static file APIs
    # resolve a relative path against the process working directory, which a caller that has
    # Set-Location'd in-process has not changed - so the artifact lands in one directory while
    # every Test-Path beside it looks in another.
    $absoluteOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath }
    else { Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $OutputPath }
    [System.IO.File]::WriteAllText($absoluteOutput, $json)
}

Write-Output $json
exit 0
