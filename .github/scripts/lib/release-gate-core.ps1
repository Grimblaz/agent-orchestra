#Requires -Version 7.0
<#
.SYNOPSIS
    Side-effect-free library for the CI release gate. Dot-source this file.
    All logic is in functions; no top-level executable statements.
#>

. (Join-Path $PSScriptRoot 'frame-predicate-core.ps1')

function Test-ReleaseGateEntryPointTouched {
    param([string[]]$ChangedFiles)
    $patterns = Get-FVPluginEntryPointPatterns
    foreach ($file in $ChangedFiles) {
        foreach ($pattern in $patterns) {
            if ($file -like $pattern) {
                return $true
            }
        }
    }
    return $false
}

function Get-PluginVersionFromString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    if ($Content -match '"version":\s*"([\d.]+)"') {
        $versionString = $matches[1]
    } else {
        return $null
    }
    if ($versionString -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
        return $null
    }
    return $versionString
}

function Get-PluginVersion {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $content = Get-Content -Path $Path -Raw -ErrorAction Stop
    } catch {
        return $null
    }
    return Get-PluginVersionFromString -Content $content
}

function Compare-PluginVersionIsGreater {
    param(
        [Parameter(Mandatory)][string]$NewVersion,
        [Parameter(Mandatory)][string]$BaseVersion
    )
    return ([System.Version]$NewVersion -gt [System.Version]$BaseVersion)
}

function Test-ChangelogSectionPresent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ChangelogContent,
        [Parameter(Mandatory)][string]$Version
    )
    $escaped = [regex]::Escape($Version)
    $pattern = "(?m)^##\s+\[$escaped\]"
    return [bool]([regex]::IsMatch($ChangelogContent, $pattern))
}

function Get-ReleaseGateWaiver {
    param([string]$CommitMessage)
    if ($CommitMessage -match '(?m)^Skip-Release-Check:\s*all\b') { return 'all' }
    if ($CommitMessage -match '(?m)^Skip-Release-Check:\s*changelog-only\b') { return 'changelog-only' }
    return $null
}

function Invoke-ReleaseGateEvaluation {
    param(
        [Parameter(Mandatory)][string]$HeadVersion,
        [Parameter(Mandatory)][string]$BaseVersion,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ChangelogContent,
        [string]$HeadCommitMessage = ''
    )

    $waiver = Get-ReleaseGateWaiver -CommitMessage $HeadCommitMessage

    $bumpPass = Compare-PluginVersionIsGreater -NewVersion $HeadVersion -BaseVersion $BaseVersion
    if ($waiver -eq 'all') {
        $bumpPass = $true
    }

    $changelogPass = Test-ChangelogSectionPresent -ChangelogContent $ChangelogContent -Version $HeadVersion
    if ($waiver -eq 'changelog-only' -or $waiver -eq 'all') {
        $changelogPass = $true
    }

    $failedLegs = @()
    if (-not $bumpPass) { $failedLegs += 'bump' }
    if (-not $changelogPass) { $failedLegs += 'changelog' }

    $pass = $failedLegs.Count -eq 0

    return @{
        Pass          = $pass
        FailedLegs    = $failedLegs
        WaiverApplied = $waiver
        ExitCode      = if ($pass) { 0 } else { 1 }
    }
}
