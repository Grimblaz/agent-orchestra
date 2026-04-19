#Requires -Version 7.0
<#
.SYNOPSIS
    Plugin preflight validation — run manually before plugin releases.

.DESCRIPTION
    Verifies that plugin.json accurately describes the repository:
    - Placeholder author/repository values have been replaced
    - All declared agent, skill, and command paths exist on disk
    - Declared counts match filesystem counts
    - Command count is exactly 9 (no /release)

    Run from any directory — paths resolve relative to the repo root.

.EXAMPLE
    pwsh -NoProfile -File .github/scripts/validate-plugin-preflight.ps1
#>

$ErrorActionPreference = 'Stop'

$libFile = Join-Path $PSScriptRoot 'lib\validate-plugin-preflight-core.ps1'
. $libFile

$result = Invoke-PluginPreflight
exit $result.ExitCode
