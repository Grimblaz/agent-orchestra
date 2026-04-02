#Requires -Version 7.0
<#
.SYNOPSIS
    Measures directive complexity of agent files and compares against configurable ceilings.

.DESCRIPTION
    Counts directive keywords (MUST, NEVER, ALWAYS, REQUIRED, MANDATORY) and checklist
    items in .agent.md files. Fenced code blocks are excluded. Outputs JSON to stdout.
    Always exits 0 — ceilings are advisory (soft).

.PARAMETER ConfigPath
    Path to guidance-complexity.json config. Defaults to .github/config/guidance-complexity.json.
    Missing file is handled gracefully (built-in default ceiling of 150 is used).

.PARAMETER AgentsPath
    Glob/path to agent files. Defaults to .github/agents/*.agent.md.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '.github/config/guidance-complexity.json',
    [string]$AgentsPath = '.github/agents/*.agent.md'
)

. "$PSScriptRoot/lib/measure-guidance-complexity-core.ps1"

try {
    $result = Invoke-MeasureGuidanceComplexity @PSBoundParameters
    if ($result.Output) { Write-Output $result.Output }
}
catch {
    Write-Output '{"config_source":"error","agents_over_ceiling":[],"agents":[]}'
}
exit 0
