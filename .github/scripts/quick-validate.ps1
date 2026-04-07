#Requires -Version 7.0
[CmdletBinding()]
param()

. "$PSScriptRoot/lib/quick-validate-core.ps1"

$result = Invoke-QuickValidate
exit $result.ExitCode
