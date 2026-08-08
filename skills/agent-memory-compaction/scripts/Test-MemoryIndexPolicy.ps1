#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Reports whether a memory store's recall index conforms to the agent-memory-compaction policy.

.DESCRIPTION
    A read-only diagnostic. It has no trigger and no schedule: it runs when a person or a
    session runs it, and it never writes to the index or anywhere else.

    Four axes are reported:

      1. policy        - is this store's policy text where it should be and textually complete
                         (case-sensitively) against the reference copy? A legacy store carries
                         it as the index's own header; a split store carries a stanza in the
                         index and the policy text in a file beside it, and both are compared.
      2. size          - how large is the index, in characters, against a budget of
                         fraction x the freshest limit observation the store records?
      3. hooks         - how many linked subjects carry no recall hook (R1)?
      4. shared notes  - how many lines put one note over a run of subjects that carry no
                         hooks of their own (R2)?

    The size axis is data-driven. It is evaluated only for a store that records budget inputs;
    a store that records none reports 'not evaluated', because the legacy shape has nowhere to
    record them and an axis that fired anyway would be migration pressure, not a measurement.
    A store recording inputs the check cannot use reports 'could not verify' on that axis
    alone, with the other three still counted.

    Refusals come before any count is printed, so that input the check does not fully
    understand gets a loud failure instead of a plausible wrong verdict:

      - the index, the reference copy, or a split store's policy file cannot be read, or
        something that is not a file sits where the policy file should be
      - the reference copy is missing its canonical-policy or canonical-stanza markers, or
        either block contains a section heading (which would make the index-side header
        boundary ambiguous)
      - a split store's policy file is missing its canonical-policy markers
      - the index declares the split shape with a stanza that is never closed above the first
        section heading, is empty, names no policy file, or names a path that cannot resolve to
        a file beside the index
      - the index has no section heading, or no pointer line at all
      - a link-like construct could not be parsed, so some subject would be judged silently -
        including links nested inside one another, where which subject owns a clause has no
        answer
      - no linked entry matches the entry-kind vocabulary the policy names, AND this store's
        own policy text was available to read (a half-migrated store's is not, so it is
        reported rather than refused)

    A split store whose policy file does not exist yet is half-migrated: a defect with its own
    wording, deliberately NOT the same verdict as a policy file that exists and cannot be read,
    nor as a stanza whose declared path could never name a file beside the index.

    The stanza is looked for ONLY above the index's first section heading and ONLY at column 0.
    Both bounds exist so that an index which quotes this skill's own adoption instructions does
    not thereby change the shape the check reads it as.

    Both count axes are syntactic proxies for questions about meaning. Novel filler evades
    the hook axis; a pointer whose words are absent from its filename passes it while saying
    nothing; the shared-note axis recognizes a note only when it leads or trails a run of
    subjects left bare. The size axis is exact about the file and only as good as the limit
    observation behind it. It is a floor, not a judge.

    This file is a thin entry point: the logic lives in lib/memory-index-policy-core.ps1 so
    the whole surface is reachable in-process from the regression suite,
    .github/scripts/Tests/memory-index-policy.Tests.ps1.

.PARAMETER IndexPath
    Path to the index file to check.

.PARAMETER PolicyReferencePath
    Path to the SKILL.md carrying the two compared texts: the canonical policy between its
    policy-canonical-begin and policy-canonical-end markers, and the hot-index stanza between
    stanza-canonical-begin and stanza-canonical-end. Defaults to the SKILL.md beside this
    script. Because that default sits inside a per-version plugin install directory, a store
    whose policy text was adapted should keep its reference copy elsewhere and pass it here.
    The 'Adapting this to your store' section is outside the markers and is therefore excluded
    from the comparison by construction.

    A store that has not adopted this version's policy can keep a clean verdict by passing the
    preserved pre-supersession text, shipped beside this script at
    ../templates/policy-pre-supersession.md.

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
