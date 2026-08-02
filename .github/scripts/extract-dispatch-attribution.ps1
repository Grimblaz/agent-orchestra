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
    pwsh .github/scripts/extract-dispatch-attribution.ps1 -TranscriptDir ./subagents -Since 2026-08-02T00:00:00Z -JsonOut .tmp/issue-975/dispatch-attribution.json
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
    [string]$JsonOut,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeToolCallInputs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/dispatch-attribution.ps1')

$getParams = @{ TranscriptDir = $TranscriptDir }
if ($Since) { $getParams.Since = $Since }
# @(...) at the call site: a function returning an empty collection unrolls to
# nothing, so a plain assignment leaves $records $null and the table call below
# fails to bind — the zero-record run would die before ever reaching -JsonOut.
$records = @(Get-DispatchAttribution @getParams)

$table = Format-DispatchAttributionTable -Records $records

if ($OutFile) {
    Set-Content -LiteralPath $OutFile -Value $table -Encoding utf8NoBOM
}
if ($JsonOut) {
    # prompt_text is bulky; keep the JSON dump lean but sufficient for AC evidence
    $lean = @($records | Select-Object -ExcludeProperty prompt_text -Property *)
    if (-not $IncludeToolCallInputs) {
        # A tool_call `input` is a verbatim command/url/prompt fragment. This dump
        # is an evidence artifact that gets attached to issues and PRs, so the
        # fragments are reduced to tool names unless the caller opts in. Counts
        # and per-dispatch totals — what the attribution is for — are unaffected.
        foreach ($rec in $lean) {
            if ($null -ne $rec.tool_calls) {
                $rec.tool_calls = @($rec.tool_calls | ForEach-Object {
                        [pscustomobject]@{ tool = $_.tool }
                    })
            }
        }
    }
    # -InputObject, not the pipeline: piping unrolls the collection, so one
    # record would serialize as a bare object and zero records would emit
    # nothing at all — Set-Content would never run and the file would silently
    # not exist while the script still exited 0. Zero records is reachable
    # whenever -Since filters everything out, and this file is the AC4 evidence
    # artifact. -InputObject on an already-array value preserves array shape at
    # every count; adding -AsArray on top of it wraps a second time and emits
    # [[...]] (measured on pwsh 7.6.3), so it is deliberately not used here.
    $json = ConvertTo-Json -InputObject $lean -Depth 6
    Set-Content -LiteralPath $JsonOut -Value $json -Encoding utf8NoBOM
}

Write-Output $table
