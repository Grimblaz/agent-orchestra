#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int]$Port
)

. "$PSScriptRoot/lib/check-port-core.ps1"

$result = Invoke-CheckPort -Port $Port
$result | ConvertTo-Json -Compress
