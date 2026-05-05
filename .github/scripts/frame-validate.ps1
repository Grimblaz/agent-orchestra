#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RootPath,
    [ValidateSet('default', 'plan')]
    [string]$Mode = 'default',
    [string]$CommentFile
)

. "$PSScriptRoot/lib/frame-validate-core.ps1"

$invokeParameters = @{} + $PSBoundParameters
if ($Mode -eq 'plan' -and -not $CommentFile) {
    $invokeParameters['CommentText'] = [Console]::In.ReadToEnd()
}

$result = Invoke-FrameValidate @invokeParameters

foreach ($check in @($result.Results)) {
    $prefix = if ($check.Passed) { '[PASS]' } else { '[FAIL]' }
    $detail = if ($check.Detail) { " - $($check.Detail)" } else { '' }
    Write-Output "$prefix $($check.Name)$detail"
}

Write-Output "Frame-validate: $($result.PassCount)/$($result.TotalCount) checks passed"
exit $result.ExitCode
