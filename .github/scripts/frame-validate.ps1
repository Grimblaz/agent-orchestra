#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RootPath
)

. "$PSScriptRoot/lib/frame-validate-core.ps1"

$result = Invoke-FrameValidate @PSBoundParameters

foreach ($check in @($result.Results)) {
    $prefix = if ($check.Passed) { '[PASS]' } else { '[FAIL]' }
    $detail = if ($check.Detail) { " - $($check.Detail)" } else { '' }
    Write-Output "$prefix $($check.Name)$detail"
}

Write-Output "Frame-validate: $($result.PassCount)/$($result.TotalCount) checks passed"
exit $result.ExitCode
