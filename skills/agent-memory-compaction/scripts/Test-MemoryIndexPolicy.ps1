#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Reports whether a memory store's recall index conforms to the agent-memory-compaction policy.

.DESCRIPTION
    A read-only diagnostic. It has no trigger and no schedule: it runs when a person or a
    session runs it, and it never writes to the index or anywhere else.

    Three axes are reported:

      1. header        - is the policy header present in the index, before any pointer line,
                         and textually complete (case-sensitively) against the reference copy?
      2. hooks         - how many linked subjects carry no recall hook (R1)?
      3. shared notes  - how many lines put one note over a run of subjects that carry no
                         hooks of their own (R2)?

    Refusals come before any count is printed, so that input the check does not fully
    understand gets a loud failure instead of a plausible wrong verdict:

      - the index or the reference copy cannot be read
      - the reference copy is missing its canonical-policy markers, or that block contains a
        section heading (which would make the index-side header boundary ambiguous)
      - the index has no section heading, or no pointer line at all
      - a link-like construct could not be parsed, so some subject would be judged silently
      - no linked entry matches the entry-kind vocabulary the policy names

    Both count axes are syntactic proxies for questions about meaning. Novel filler evades
    the hook axis; a pointer whose words are absent from its filename passes it while saying
    nothing; the shared-note axis recognizes a note only when it leads or trails a run of
    subjects left bare. It is a floor, not a judge.

    This file is a thin entry point: the logic lives in lib/memory-index-policy-core.ps1 so
    the whole surface is reachable in-process from the regression suite,
    .github/scripts/Tests/memory-index-policy.Tests.ps1.

.PARAMETER IndexPath
    Path to the index file to check.

.PARAMETER PolicyReferencePath
    Path to the SKILL.md carrying the canonical policy text between its
    policy-canonical-begin and policy-canonical-end markers. Defaults to the SKILL.md beside
    this script. Because that default sits inside a per-version plugin install directory, a
    store whose policy text was adapted should keep its reference copy elsewhere and pass it
    here. The 'Adapting this to your store' section is outside the markers and is therefore
    excluded from the comparison by construction.

.PARAMETER Json
    Emit the report as a single JSON object instead of human-readable lines. Honored on
    every terminal path, including refusals and usage errors.

.OUTPUTS
    Exit 0 - clean. Exit 1 - defects found. Exit 2 - refused. Exit 3 - usage error.

.EXAMPLE
    pwsh Test-MemoryIndexPolicy.ps1 -IndexPath ~/.claude/projects/my-project/memory/MEMORY.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IndexPath,

    [Parameter()]
    [string]$PolicyReferencePath,

    [Parameter()]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'memory-index-policy-core.ps1')

$report = Invoke-MemoryIndexPolicyCheck -IndexPath $IndexPath -PolicyReferencePath $PolicyReferencePath
Format-MemoryIndexPolicyReport -Report $report -AsJson:$Json | Write-Output
exit $report.ExitCode
