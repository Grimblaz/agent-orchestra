#Requires -Version 7.0
<#
.SYNOPSIS
    Library for frame adapter validation. Dot-source and call Invoke-FrameValidate.
#>

$script:FVLibDir = Split-Path -Parent $PSCommandPath
. (Join-Path -Path $script:FVLibDir -ChildPath 'frame-predicate-core.ps1')

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

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    $agentsPath = Join-Path -Path $RootPath -ChildPath 'agents'
    if (Test-Path -LiteralPath $agentsPath) {
        foreach ($file in @(Get-ChildItem -LiteralPath $agentsPath -Filter '*.agent.md' -File)) {
            $files.Add($file)
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $agentsPath -Filter '*.md' -File | Where-Object { $_.Name -notlike '*.agent.md' })) {
            $files.Add($file)
        }
    }

    $skillsPath = Join-Path -Path $RootPath -ChildPath 'skills'
    if (Test-Path -LiteralPath $skillsPath) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $skillsPath -Directory)) {
            $skillFile = Join-Path -Path $directory.FullName -ChildPath 'SKILL.md'
            if (Test-Path -LiteralPath $skillFile) {
                $files.Add((Get-Item -LiteralPath $skillFile))
            }

            $adaptersPath = Join-Path -Path $directory.FullName -ChildPath 'adapters'
            if (Test-Path -LiteralPath $adaptersPath) {
                foreach ($file in @(Get-ChildItem -LiteralPath $adaptersPath -Filter '*.md' -File)) {
                    $files.Add($file)
                }
            }
        }
    }

    $commandsPath = Join-Path -Path $RootPath -ChildPath 'commands'
    if (Test-Path -LiteralPath $commandsPath) {
        foreach ($file in @(Get-ChildItem -LiteralPath $commandsPath -Filter '*.md' -File)) {
            $files.Add($file)
        }
    }

    return @($files.ToArray() | Sort-Object -Property FullName)
}

function Remove-FVYamlTrailingComment {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }

    $quote = [char]0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]

        if ($quote -ne [char]0) {
            if ($quote -eq [char]34 -and $character -eq [char]92) {
                $index++
                continue
            }

            if ($character -eq $quote) {
                if ($quote -eq [char]39 -and $index + 1 -lt $Value.Length -and $Value[$index + 1] -eq [char]39) {
                    $index++
                    continue
                }

                $quote = [char]0
            }

            continue
        }

        if ($character -eq [char]34 -or $character -eq [char]39) {
            $quote = $character
            continue
        }

        if ($character -eq [char]'#' -and ($index -eq 0 -or [char]::IsWhiteSpace($Value[$index - 1]))) {
            return $Value.Substring(0, $index).TrimEnd()
        }
    }

    return $Value.TrimEnd()
}

function ConvertFrom-FVYamlDoubleQuotedScalar {
    param([Parameter(Mandatory)][string]$Value)

    $builder = [System.Text.StringBuilder]::new()
    $index = 0
    while ($index -lt $Value.Length) {
        $character = $Value[$index]
        if ($character -eq [char]92 -and $index + 1 -lt $Value.Length) {
            $next = $Value[$index + 1]
            switch ([string]$next) {
                '"' { [void]$builder.Append([char]34) }
                '\' { [void]$builder.Append([char]92) }
                '/' { [void]$builder.Append('/') }
                'n' { [void]$builder.Append("`n") }
                'r' { [void]$builder.Append("`r") }
                't' { [void]$builder.Append("`t") }
                default { [void]$builder.Append($next) }
            }

            $index += 2
            continue
        }

        [void]$builder.Append($character)
        $index++
    }

    return $builder.ToString()
}

function Test-FVYamlBlockScalarIndicator {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    return [regex]::IsMatch($Value, '^[|>][+-]?$')
}

function ConvertFrom-FVYamlScalar {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }

    $trimmed = (Remove-FVYamlTrailingComment -Value $Value).Trim()
    if ($trimmed.Length -lt 2) { return $trimmed }

    if ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace("''", "'")
    }

    if ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        return (ConvertFrom-FVYamlDoubleQuotedScalar -Value $trimmed.Substring(1, $trimmed.Length - 2))
    }

    return $trimmed
}

function Split-FVInlineValues {
    param([Parameter(Mandatory)][string]$Value)

    $trimmed = (Remove-FVYamlTrailingComment -Value $Value).Trim()
    if ($trimmed -eq '[]') { return [string[]]@() }

    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        return [string[]]@((ConvertFrom-FVYamlScalar -Value $trimmed))
    }

    $inner = $trimmed.Substring(1, $trimmed.Length - 2)
    $values = [System.Collections.Generic.List[string]]::new()
    $builder = [System.Text.StringBuilder]::new()
    $quote = [char]0

    foreach ($character in $inner.ToCharArray()) {
        if ($quote -ne [char]0) {
            [void]$builder.Append($character)
            if ($character -eq $quote) { $quote = [char]0 }
            continue
        }

        if ($character -eq [char]34 -or $character -eq [char]39) {
            $quote = $character
            [void]$builder.Append($character)
            continue
        }

        if ($character -eq [char]',') {
            $item = ConvertFrom-FVYamlScalar -Value $builder.ToString()
            if ($item.Length -gt 0) { $values.Add($item) }
            $null = $builder.Clear()
            continue
        }

        [void]$builder.Append($character)
    }

    $lastItem = ConvertFrom-FVYamlScalar -Value $builder.ToString()
    if ($lastItem.Length -gt 0) { $values.Add($lastItem) }

    return $values.ToArray()
}

function Test-FVTopLevelFrontmatterKey {
    param([Parameter(Mandatory)][string]$Line)

    return [regex]::IsMatch($Line, '^[A-Za-z0-9_-]+:\s*')
}

function Get-FVIndentedListValues {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $values = [System.Collections.Generic.List[string]]::new()
    for ($lineIndex = $StartIndex; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        if (Test-FVTopLevelFrontmatterKey -Line $line) { break }

        $match = [regex]::Match($line, '^\s*-\s*(?<value>.*?)\s*$')
        if ($match.Success) {
            $value = ConvertFrom-FVYamlScalar -Value $match.Groups['value'].Value
            if ($value.Length -gt 0) { $values.Add($value) }
        }
    }

    return $values.ToArray()
}

function Get-FVIndentedScalarValue {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    for ($lineIndex = $StartIndex; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if (Test-FVTopLevelFrontmatterKey -Line $line) { break }

        $part = $line.Trim()
        if ($part.Length -gt 0) { $parts.Add($part) }
    }

    return ($parts -join ' ').Trim()
}

function Get-FVProvidesDeclarationValues {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][int]$LineIndex,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $normalizedValue = (Remove-FVYamlTrailingComment -Value $Value).Trim()
    if ($normalizedValue.Length -gt 0) {
        return [string[]]@(Split-FVInlineValues -Value $normalizedValue)
    }

    return [string[]]@(Get-FVIndentedListValues -Lines $Lines -StartIndex ($LineIndex + 1))
}

function Get-FVAppliesWhenDeclarationValue {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][int]$LineIndex,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $normalizedValue = (Remove-FVYamlTrailingComment -Value $Value).Trim()
    if (Test-FVYamlBlockScalarIndicator -Value $normalizedValue) {
        return (Get-FVIndentedScalarValue -Lines $Lines -StartIndex ($LineIndex + 1))
    }

    return (ConvertFrom-FVYamlScalar -Value $normalizedValue)
}

function Get-FVAdapterFrontmatter {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    $metadata = [PSCustomObject]@{
        File        = $File
        Provides    = [string[]]@()
        AppliesWhen = [string[]]@()
    }

    $content = Get-Content -LiteralPath $File.FullName -Raw
    $match = [regex]::Match($content, '(?ms)\A---\r?\n(?<yaml>.*?)\r?\n---(?:\r?\n|\z)')
    if (-not $match.Success) { return $metadata }

    $lines = [string[]]($match.Groups['yaml'].Value -split "`r?`n")
    $provides = [System.Collections.Generic.List[string]]::new()
    $appliesWhen = [System.Collections.Generic.List[string]]::new()

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }

        $keyMatch = [regex]::Match($line, '^(?<key>[A-Za-z0-9_-]+):(?<value>.*)$')
        if (-not $keyMatch.Success) { continue }

        $key = $keyMatch.Groups['key'].Value
        $value = $keyMatch.Groups['value'].Value.Trim()

        if ($key -eq 'provides') {
            foreach ($providedPort in @(Get-FVProvidesDeclarationValues -Lines $lines -LineIndex $lineIndex -Value $value)) {
                if ($providedPort.Length -gt 0) { $provides.Add($providedPort) }
            }

            continue
        }

        if ($key -eq 'applies-when') {
            $appliesWhen.Add((Get-FVAppliesWhenDeclarationValue -Lines $lines -LineIndex $lineIndex -Value $value))
        }
    }

    $metadata.Provides = [string[]]$provides.ToArray()
    $metadata.AppliesWhen = [string[]]$appliesWhen.ToArray()

    return $metadata
}

function Get-FVAdapterMetadata {
    param([Parameter(Mandatory)][string]$RootPath)

    return @(
        foreach ($file in @(Get-FVAdapterFiles -RootPath $RootPath)) {
            Get-FVAdapterFrontmatter -File $file
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
