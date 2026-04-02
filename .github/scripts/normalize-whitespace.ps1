#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

. "$PSScriptRoot/lib/normalize-whitespace-core.ps1"

$result = Invoke-NormalizeWhitespace @PSBoundParameters
if ($result.Output) { Write-Output $result.Output }
if ($result.Error) { Write-Warning $result.Error }
exit $result.ExitCode
