#Requires -Version 7.0
<#
.SYNOPSIS
    Antigravity bootstrap script — resolves all Agent Orchestra specialist roles into Antigravity subagent definitions.

.DESCRIPTION
    Parses the thin-shell metadata and combines it with canonical agent bodies to construct system prompts and capabilities.
    Outputs the subagent definitions in structured JSON.

.PARAMETER OutputPath
    Optional. The path to save the generated subagents JSON file. If omitted, the JSON is outputted to stdout.

.EXAMPLE
    pwsh -NoProfile -File .github/scripts/bootstrap-antigravity.ps1
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# Resolve absolute path to the core library
$libFile = Join-Path $PSScriptRoot 'lib/bootstrap-antigravity-core.ps1'
if (-not (Test-Path $libFile)) {
    Write-Error "Core parsing library not found at: $libFile"
}

. $libFile

try {
    # Resolve the repository root directory
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $canonicalRepoRoot = [System.IO.Path]::GetFullPath($repoRoot)

    # Validate OutputPath for path traversal security
    if ($OutputPath) {
        $resolvedOutputPath = $OutputPath
        if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
            $resolvedOutputPath = Join-Path -Path $repoRoot -ChildPath $OutputPath
        }
        $canonicalOutputPath = [System.IO.Path]::GetFullPath($resolvedOutputPath)
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $prefix = $canonicalRepoRoot + $separator
        if (-not $canonicalOutputPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Path traversal detected! OutputPath must reside inside the repository root."
        }
    }

    Write-Verbose "Bootstrapping Antigravity subagents for workspace: $repoRoot"

    # Get the resolved subagent definitions
    $subagents = Get-AntigravitySubagents -RootPath $repoRoot

    if ($null -eq $subagents -or $subagents.Count -eq 0) {
        throw "Zero subagents resolved. Bootstrapping failed."
    }

    # Convert the PSCustomObject collection to JSON
    $json = ConvertTo-Json -InputObject $subagents -Depth 10

    if ($OutputPath) {
        $absOutputPath = $canonicalOutputPath
        # Ensure parent directory exists
        $parentDir = Split-Path -Parent $absOutputPath
        if (-not (Test-Path $parentDir)) {
            New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
        }
        Set-Content -Path $absOutputPath -Value $json -Encoding utf8
        Write-Host "Successfully generated Antigravity subagents JSON at: $absOutputPath"
    }
    else {
        # Output directly to stdout for immediate consumption
        Write-Output $json
    }

    exit 0
}
catch {
    Write-Error "Antigravity bootstrap execution failed: $_"
    exit 1
}
