#Requires -Version 7.0
<#
.SYNOPSIS
    Shared frame adapter discovery, lightweight frontmatter parsing helpers, and predicate evaluator surface.
#>

$script:FrameSharedDiscoveryLibDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $PSScriptRoot }
$script:FrameSharedPredicateCorePath = Join-Path -Path $script:FrameSharedDiscoveryLibDir -ChildPath 'frame-predicate-core.ps1'
$script:FrameSharedPredicateSurface = New-Module -Name 'FrameSharedPredicateSurface' -ArgumentList $script:FrameSharedPredicateCorePath -ScriptBlock {
    param([Parameter(Mandatory)][string]$PredicateCorePath)

    . $PredicateCorePath

    Export-ModuleMember -Function @(
        'ConvertTo-FVPredicate',
        'Test-FVParseError',
        'Test-FVPredicateAgainstChangeset'
    )
}
Import-Module $script:FrameSharedPredicateSurface -Global -Force

function Get-FrameAdapterFile {
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

function Get-FrameYamlValueBeforeComment {
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

function ConvertFrom-FrameYamlDoubleQuotedScalar {
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

function Test-FrameYamlBlockScalarIndicator {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    return [regex]::IsMatch($Value, '^[|>][+-]?$')
}

function ConvertFrom-FrameYamlScalar {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }

    $trimmed = (Get-FrameYamlValueBeforeComment -Value $Value).Trim()
    if ($trimmed.Length -lt 2) { return $trimmed }

    if ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace("''", "'")
    }

    if ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        return (ConvertFrom-FrameYamlDoubleQuotedScalar -Value $trimmed.Substring(1, $trimmed.Length - 2))
    }

    return $trimmed
}

function Split-FrameInlineValue {
    param([Parameter(Mandatory)][string]$Value)

    $trimmed = (Get-FrameYamlValueBeforeComment -Value $Value).Trim()
    if ($trimmed -eq '[]') { return [string[]]@() }

    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        return [string[]]@((ConvertFrom-FrameYamlScalar -Value $trimmed))
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
            $item = ConvertFrom-FrameYamlScalar -Value $builder.ToString()
            if ($item.Length -gt 0) { $values.Add($item) }
            $null = $builder.Clear()
            continue
        }

        [void]$builder.Append($character)
    }

    $lastItem = ConvertFrom-FrameYamlScalar -Value $builder.ToString()
    if ($lastItem.Length -gt 0) { $values.Add($lastItem) }

    return $values.ToArray()
}

function Test-FrameTopLevelFrontmatterKey {
    param([Parameter(Mandatory)][string]$Line)

    return [regex]::IsMatch($Line, '^[A-Za-z0-9_-]+:\s*')
}

function Get-FrameIndentedListValue {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $values = [System.Collections.Generic.List[string]]::new()
    for ($lineIndex = $StartIndex; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        if (Test-FrameTopLevelFrontmatterKey -Line $line) { break }

        $match = [regex]::Match($line, '^\s*-\s*(?<value>.*?)\s*$')
        if ($match.Success) {
            $value = ConvertFrom-FrameYamlScalar -Value $match.Groups['value'].Value
            if ($value.Length -gt 0) { $values.Add($value) }
        }
    }

    return $values.ToArray()
}

function Get-FrameIndentedScalarValue {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    for ($lineIndex = $StartIndex; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if (Test-FrameTopLevelFrontmatterKey -Line $line) { break }

        $part = $line.Trim()
        if ($part.Length -gt 0) { $parts.Add($part) }
    }

    return ($parts -join ' ').Trim()
}

function Get-FrameProvidesDeclarationValue {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][int]$LineIndex,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $normalizedValue = (Get-FrameYamlValueBeforeComment -Value $Value).Trim()
    if ($normalizedValue.Length -gt 0) {
        return [string[]]@(Split-FrameInlineValue -Value $normalizedValue)
    }

    return [string[]]@(Get-FrameIndentedListValue -Lines $Lines -StartIndex ($LineIndex + 1))
}

function Get-FrameAppliesWhenDeclarationValue {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][int]$LineIndex,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    $normalizedValue = (Get-FrameYamlValueBeforeComment -Value $Value).Trim()
    if (Test-FrameYamlBlockScalarIndicator -Value $normalizedValue) {
        return (Get-FrameIndentedScalarValue -Lines $Lines -StartIndex ($LineIndex + 1))
    }

    return (ConvertFrom-FrameYamlScalar -Value $normalizedValue)
}

function Get-FrameAdapterFrontmatter {
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
            foreach ($providedPort in @(Get-FrameProvidesDeclarationValue -Lines $lines -LineIndex $lineIndex -Value $value)) {
                if ($providedPort.Length -gt 0) { $provides.Add($providedPort) }
            }

            continue
        }

        if ($key -eq 'applies-when') {
            $appliesWhen.Add((Get-FrameAppliesWhenDeclarationValue -Lines $lines -LineIndex $lineIndex -Value $value))
        }
    }

    $metadata.Provides = [string[]]$provides.ToArray()
    $metadata.AppliesWhen = [string[]]$appliesWhen.ToArray()

    return $metadata
}