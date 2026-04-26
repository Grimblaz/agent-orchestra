#Requires -Version 7.0
[CmdletBinding()]
param(
    [int]$PrCount = 30,
    [datetime]$Since,
    [int[]]$PrList = @(),
    [ValidateSet('json', 'markdown', 'text')][string]$OutputFormat = 'text',
    [int]$EraSplitPivotPr = 356,
    [string]$Repo = 'Grimblaz/agent-orchestra',
    [string]$GhCliPath = 'gh',
    [string]$PortsDir,
    [string]$CacheDir,
    [switch]$NoCache
)

. "$PSScriptRoot/lib/frame-audit-report-core.ps1"

$result = Invoke-FrameAuditReport @PSBoundParameters

if ($result.Output) {
    Write-Output $result.Output
}

if ($result.Error) {
    Write-Error $result.Error -ErrorAction Continue
}

exit $result.ExitCode
