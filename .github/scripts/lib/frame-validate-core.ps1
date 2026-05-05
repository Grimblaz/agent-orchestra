#Requires -Version 7.0
<#
.SYNOPSIS
    Library for frame adapter validation. Dot-source and call Invoke-FrameValidate.
#>

$script:FVLibDir = Split-Path -Parent $PSCommandPath
. (Join-Path -Path $script:FVLibDir -ChildPath 'frame-shared-discovery.ps1')

function New-FVCheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [AllowNull()][string]$Detail
    )

    return [PSCustomObject]@{
        Name   = $Name
        Passed = $Passed
        Detail = if ($null -eq $Detail) { '' } else { $Detail }
    }
}

function New-FVAggregateResult {
    param([AllowNull()][object[]]$Results)

    $normalizedResults = if ($null -eq $Results) { @() } else { @($Results) }
    $passCount = @($normalizedResults | Where-Object { $_.Passed -eq $true }).Count
    $failCount = @($normalizedResults | Where-Object { $_.Passed -eq $false }).Count
    $totalCount = $normalizedResults.Count
    $exitCode = if ($failCount -gt 0) { 1 } else { 0 }

    return [PSCustomObject]@{
        Results    = [object[]]$normalizedResults
        PassCount  = [int]$passCount
        FailCount  = [int]$failCount
        TotalCount = [int]$totalCount
        ExitCode   = [int]$exitCode
    }
}

function Resolve-FVRootPath {
    param([AllowNull()][string]$RootPath)

    if ($RootPath) {
        return (Resolve-Path -LiteralPath $RootPath).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path -Path $script:FVLibDir -ChildPath '../../..')).Path
}

function Get-FVRelativePath {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$Path
    )

    return ([System.IO.Path]::GetRelativePath($RootPath, $Path) -replace '\\', '/')
}

function Get-FVPortCatalog {
    param([Parameter(Mandatory)][string]$RootPath)

    $portsPath = Join-Path -Path $RootPath -ChildPath 'frame' -AdditionalChildPath 'ports'
    if (-not (Test-Path -LiteralPath $portsPath)) {
        return [PSCustomObject]@{
            Exists = $false
            Path   = $portsPath
            Names  = [string[]]@()
        }
    }

    $names = @(
        Get-ChildItem -LiteralPath $portsPath -Filter '*.yaml' -File |
            ForEach-Object { $_.BaseName } |
            Sort-Object
    )

    return [PSCustomObject]@{
        Exists = $true
        Path   = $portsPath
        Names  = [string[]]$names
    }
}

function Get-FVAdapterFiles {
    param([Parameter(Mandatory)][string]$RootPath)

    return (Get-FrameAdapterFile -RootPath $RootPath)
}

function Get-FVAdapterFrontmatter {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    return (Get-FrameAdapterFrontmatter -File $File)
}

function Get-FVAdapterMetadata {
    param([Parameter(Mandatory)][string]$RootPath)

    return @(
        foreach ($file in @(Get-FrameAdapterFile -RootPath $RootPath)) {
            Get-FrameAdapterFrontmatter -File $file
        }
    )
}

function Test-FVAdapterSymmetry {
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [AllowNull()][object[]]$AdapterMetadata
    )

    $resolvedRoot = Resolve-FVRootPath -RootPath $RootPath
    $catalog = Get-FVPortCatalog -RootPath $resolvedRoot

    if (-not $catalog.Exists) {
        $relativePortsPath = Get-FVRelativePath -RootPath $resolvedRoot -Path $catalog.Path
        return (New-FVCheckResult -Name 'AdapterSymmetry' -Passed $true -Detail "$relativePortsPath missing; adapter symmetry skipped.")
    }

    $validPorts = [string[]]$catalog.Names
    $validPortSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$validPorts, [System.StringComparer]::Ordinal)
    $validPortDetail = if ($validPorts.Count -gt 0) { $validPorts -join ', ' } else { '(none)' }
    $violations = [System.Collections.Generic.List[string]]::new()
    $adapters = if ($PSBoundParameters.ContainsKey('AdapterMetadata')) { @($AdapterMetadata) } else { @(Get-FVAdapterMetadata -RootPath $resolvedRoot) }

    foreach ($adapter in $adapters) {
        $relativePath = Get-FVRelativePath -RootPath $resolvedRoot -Path $adapter.File.FullName
        foreach ($providedPort in @($adapter.Provides)) {
            if (-not $validPortSet.Contains($providedPort)) {
                $violations.Add("$relativePath provides '$providedPort'; valid ports: $validPortDetail")
            }
        }
    }

    if ($violations.Count -eq 0) {
        return (New-FVCheckResult -Name 'AdapterSymmetry' -Passed $true -Detail '')
    }

    return (New-FVCheckResult -Name 'AdapterSymmetry' -Passed $false -Detail "$($violations.Count) invalid provides declaration(s): $($violations -join '; ')")
}

function Test-FVPredicateParse {
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [AllowNull()][object[]]$AdapterMetadata
    )

    $resolvedRoot = Resolve-FVRootPath -RootPath $RootPath
    $violations = [System.Collections.Generic.List[string]]::new()
    $adapters = if ($PSBoundParameters.ContainsKey('AdapterMetadata')) { @($AdapterMetadata) } else { @(Get-FVAdapterMetadata -RootPath $resolvedRoot) }

    foreach ($adapter in $adapters) {
        $relativePath = Get-FVRelativePath -RootPath $resolvedRoot -Path $adapter.File.FullName
        foreach ($predicate in @($adapter.AppliesWhen)) {
            try {
                $result = ConvertTo-FVPredicate -Predicate $predicate
                if (Test-FVParseError -Value $result) {
                    $violations.Add("$relativePath applies-when '$predicate'; parse error at position $($result.Position): $($result.Message)")
                }
            }
            catch {
                $violations.Add("$relativePath applies-when '$predicate'; parse error at position 0: $_")
            }
        }
    }

    if ($violations.Count -eq 0) {
        return (New-FVCheckResult -Name 'PredicateParse' -Passed $true -Detail '')
    }

    return (New-FVCheckResult -Name 'PredicateParse' -Passed $false -Detail "$($violations.Count) applies-when parse error(s): $($violations -join '; ')")
}

function Invoke-FrameValidate {
    [CmdletBinding()]
    param([string]$RootPath)

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    try {
        $resolvedRoot = Resolve-FVRootPath -RootPath $RootPath
        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $adapterMetadataCache = [PSCustomObject]@{
            Loaded = $false
            Value  = [object[]]@()
        }
        $getAdapterMetadata = {
            if (-not $adapterMetadataCache.Loaded) {
                $adapterMetadataCache.Value = [object[]]@(Get-FVAdapterMetadata -RootPath $resolvedRoot)
                $adapterMetadataCache.Loaded = $true
            }

            return $adapterMetadataCache.Value
        }

        foreach ($check in @(
                @{ Name = 'AdapterSymmetry'; Script = { Test-FVAdapterSymmetry -RootPath $resolvedRoot -AdapterMetadata (& $getAdapterMetadata) } },
                @{ Name = 'PredicateParse'; Script = { Test-FVPredicateParse -RootPath $resolvedRoot -AdapterMetadata (& $getAdapterMetadata) } }
            )) {
            try {
                $results.Add((& $check.Script))
            }
            catch {
                $results.Add((New-FVCheckResult -Name $check.Name -Passed $false -Detail "Error: $_"))
            }
        }

        return (New-FVAggregateResult -Results $results.ToArray())
    }
    catch {
        return (New-FVAggregateResult -Results @((New-FVCheckResult -Name 'FrameValidate' -Passed $false -Detail "Error: $_")))
    }
}
