#Requires -Version 7.0
<#
.SYNOPSIS
    Plugin preflight validation — run manually before plugin releases.

.DESCRIPTION
    Verifies that plugin.json accurately describes the repository:
    - Manifest exists at plugin.json (repo root) and parses
    - Placeholder author/repository values have been replaced
    - All declared agent and skill paths exist on disk
    - Agent count is 14, declared skill count matches filesystem
    - Manifest does not declare fields VS Code silently ignores (e.g. `commands`)

    Run from any directory — paths resolve relative to the repo root.

.EXAMPLE
    pwsh -NoProfile -File .github/scripts/validate-plugin-preflight.ps1
#>

$ErrorActionPreference = 'Stop'

$libFile = Join-Path $PSScriptRoot 'lib\validate-plugin-preflight-core.ps1'
. $libFile

$result = Invoke-PluginPreflight
exit $result.ExitCode
