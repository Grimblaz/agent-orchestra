#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$PrNumber,
    [ValidateSet('json', 'yaml', 'text')][string]$OutputFormat = 'yaml',
    [string]$Repo = 'Grimblaz/agent-orchestra',
    [string]$GhCliPath = 'gh',
    [string]$PortsDir,
    [string]$CacheDir,
    [switch]$NoCache
)

. "$PSScriptRoot/lib/frame-back-derive-core.ps1"

$result = Invoke-FrameBackDerive @PSBoundParameters

if ($result.Output) {
    Write-Output $result.Output
}

if ($result.Error) {
    Write-Error $result.Error -ErrorAction Continue
}

exit $result.ExitCode
