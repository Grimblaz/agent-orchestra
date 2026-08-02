#Requires -Version 7.0
<#
.SYNOPSIS
    Per-dispatch token attribution report over a session subagents directory (issue #975).
.DESCRIPTION
    Thin entry point over lib/dispatch-attribution.ps1. Reads every
    agent-*.jsonl transcript in the given directory, deduplicates streaming
    usage rows per API message, and emits a per-dispatch Markdown table plus
    an optional JSON dump for downstream comparison.
.EXAMPLE
    pwsh .github/scripts/extract-dispatch-attribution.ps1 -TranscriptDir "$HOME/.claude/projects/{slug}/{sessionId}/subagents"
.EXAMPLE
    pwsh .github/scripts/extract-dispatch-attribution.ps1 -TranscriptDir ./subagents -Since 2026-08-02T00:00:00Z -JsonOut run.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TranscriptDir,

    [Parameter(Mandatory = $false)]
    [string]$Since,

    [Parameter(Mandatory = $false)]
    [string]$OutFile,

    [Parameter(Mandatory = $false)]
    [string]$JsonOut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/dispatch-attribution.ps1')

$getParams = @{ TranscriptDir = $TranscriptDir }
if ($Since) { $getParams.Since = $Since }
$records = Get-DispatchAttribution @getParams

$table = Format-DispatchAttributionTable -Records $records

if ($OutFile) {
    Set-Content -LiteralPath $OutFile -Value $table -Encoding utf8NoBOM
}
if ($JsonOut) {
    # prompt_text is bulky; keep the JSON dump lean but sufficient for AC evidence
    $lean = @($records | Select-Object -ExcludeProperty prompt_text -Property *)
    $lean | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonOut -Encoding utf8NoBOM
}

Write-Output $table
