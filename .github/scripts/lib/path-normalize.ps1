#Requires -Version 7.0
<#
.SYNOPSIS
    Cross-platform CWD path normalizer for cost-telemetry per-event cwd+gitBranch filter (issue #467, D11).
.DESCRIPTION
    Converts Windows (backslash, forward-slash, and drive-letter) path forms to the
    canonical /drive/rest form used by cost-walker.ps1 for per-event cwd matching.
    Idempotent. Thread-safe (pure function, no state).
#>
function Get-NormalizedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    # Empty string passes through unchanged
    if ($Path.Length -eq 0) {
        return ''
    }

    # Step 1: Strip trailing \ or /
    $result = $Path.TrimEnd('\', '/')

    # Step 2: Convert all \ to /
    $result = $result.Replace('\', '/')

    # Step 3: Canonicalize drive-letter forms to lowercase /drive/rest
    # Matches patterns like C:/rest or C: (bare)
    if ($result -match '^([A-Za-z]):(/.*)?$') {
        $driveLetter = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2]  # may be $null if bare drive letter
        if ($null -ne $rest -and $rest.Length -gt 0) {
            $result = "/$driveLetter$rest"
        }
        else {
            $result = "/$driveLetter"
        }
    }

    return $result
}
