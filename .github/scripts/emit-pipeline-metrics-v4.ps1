#Requires -Version 7.0
<#
.SYNOPSIS
    Emit a canonical v4 pipeline-metrics PR body (issue #769 s2).

.DESCRIPTION
    Thin CLI wrapper. Dot-sources lib/emit-pipeline-metrics-v4-core.ps1 and calls
    Invoke-PipelineMetricsV4Emit, then translates the returned ExitCode to a
    process exit code. All logic lives in the core library so tests can dot-source
    it and call the function in-process (the #257 script-safety contract forbids
    spawning a child pwsh per test).

    Called BEFORE gh pr create with the output path as the --body-file argument.
    See lib/emit-pipeline-metrics-v4-core.ps1 for the three outcome cases (M5)
    and the M8/M21 sentinel invariants.

.PARAMETER BodyFile
    Path to write the completed PR body file.

.PARAMETER V3BaseYaml
    v3 base fields as plain YAML (no pipeline-metrics wrapper).

.PARAMETER Credits
    Array of credit-row pscustomobjects from the frame accumulator.

.PARAMETER DispatchCostSamples
    Array of dispatch-cost-sample pscustomobjects.

.PARAMETER IssueNumber
    When > 0 and Credits is empty, harvest credits from the s-acc file-based
    accumulator (.tmp/issue-{N}/fclcredits.jsonl).

.PARAMETER RichBody
    Optional full markdown PR body already composed by the conductor (summary,
    changed files, Closes #N, review table, etc.). When provided, the v4 block is
    appended to it so the final file contains both the human-readable PR content
    AND the metrics block. On failure the rich body is still written followed by
    the sentinel so Closes #N always survives in the shipped PR body.

.PARAMETER Repo
    Repository in 'owner/name' form, used for the marker-harvest branch's gh
    calls (issue #794 s2). When not supplied, derived via 'gh repo view' then
    via 'git remote get-url origin' parsing.

.PARAMETER GhCliPath
    Path to the gh CLI executable. Defaults to 'gh'. Overridable for test
    injection.

.PARAMETER SkipMarkerHarvest
    Bypasses the SMC-17 marker-harvest branch entirely.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BodyFile,
    [string]$V3BaseYaml = '',
    [pscustomobject[]]$Credits = @(),
    [pscustomobject[]]$DispatchCostSamples = @(),
    [int]$IssueNumber = 0,
    [string]$RichBody = '',
    [string]$Repo = '',
    [string]$GhCliPath = 'gh',
    [switch]$SkipMarkerHarvest
)

. (Join-Path $PSScriptRoot 'lib/emit-pipeline-metrics-v4-core.ps1')

$result = Invoke-PipelineMetricsV4Emit `
    -BodyFile $BodyFile `
    -V3BaseYaml $V3BaseYaml `
    -Credits $Credits `
    -DispatchCostSamples $DispatchCostSamples `
    -IssueNumber $IssueNumber `
    -RichBody $RichBody `
    -Repo $Repo `
    -GhCliPath $GhCliPath `
    -SkipMarkerHarvest:$SkipMarkerHarvest

exit $result.ExitCode
