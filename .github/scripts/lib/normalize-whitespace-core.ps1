#Requires -Version 7.0
<#
.SYNOPSIS
    Library for normalize-whitespace logic. Dot-source this file and call Invoke-NormalizeWhitespace.
#>

function Test-NWAllowlistedPath {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedPath
    )

    $fileName = [System.IO.Path]::GetFileName($ResolvedPath)
    $extension = [System.IO.Path]::GetExtension($ResolvedPath)

    return $fileName -in @('.gitignore', '.gitattributes', '.editorconfig') -or
    $extension -in @('.json', '.jsonc', '.yml', '.yaml', '.psd1', '.txt')
}

function Test-NWBinaryLikeContent {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    return $Bytes -contains 0
}

function Get-NWNewlineSequence {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $match = [regex]::Match($Content, "`r`n|(?<!`r)`n|`r")
    if ($match.Success) {
        return $match.Value
    }

    return "`n"
}

function Invoke-NormalizeWhitespace {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return @{ ExitCode = 0; Output = ''; Error = "normalize-whitespace skipped missing file: $Path" }
        }

        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        if (-not (Test-NWAllowlistedPath -ResolvedPath $resolvedPath)) {
            return @{ ExitCode = 0; Output = ''; Error = "normalize-whitespace skipped unsupported file type: $resolvedPath" }
        }

        $originalBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
        if (Test-NWBinaryLikeContent -Bytes $originalBytes) {
            return @{ ExitCode = 0; Output = ''; Error = "normalize-whitespace skipped binary-like content: $resolvedPath" }
        }

        $hasUtf8Bom = $originalBytes.Length -ge 3 -and
        $originalBytes[0] -eq 0xEF -and
        $originalBytes[1] -eq 0xBB -and
        $originalBytes[2] -eq 0xBF

        if (-not $hasUtf8Bom) {
            try {
                [System.Text.UTF8Encoding]::new($false, $true).GetString($originalBytes) | Out-Null
            }
            catch {
                return @{ ExitCode = 0; Output = ''; Error = "normalize-whitespace skipped non-UTF-8-safe content: $resolvedPath" }
            }
        }

        $reader = [System.IO.StreamReader]::new($resolvedPath, $true)
        try {
            $current = $reader.ReadToEnd()
            $encoding = $reader.CurrentEncoding
        }
        finally {
            $reader.Dispose()
        }

        $newline = Get-NWNewlineSequence -Content $current
        $normalized = [regex]::Replace($current, '[ \t]+(?=(?:\r\n|\n|\r)|$)', '')
        $normalized = [regex]::Replace($normalized, '(?:\r\n|\n|\r)+\z', '')
        $normalized += $newline

        if ($normalized -ceq $current) {
            return @{ ExitCode = 0; Output = ''; Error = '' }
        }

        if ($encoding.WebName -eq 'utf-8') {
            $encoding = [System.Text.UTF8Encoding]::new($hasUtf8Bom)
        }

        $tempPath = [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($resolvedPath),
            [System.IO.Path]::GetRandomFileName()
        )
        $wroteOk = $false
        try {
            $tempWriter = [System.IO.StreamWriter]::new($tempPath, $false, $encoding)
            try {
                $tempWriter.Write($normalized)
            }
            finally {
                $tempWriter.Dispose()
            }
            [System.IO.File]::Move($tempPath, $resolvedPath, $true)
            $wroteOk = $true
        }
        finally {
            if (-not $wroteOk -and (Test-Path -LiteralPath $tempPath)) {
                Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
            }
        }

        return @{ ExitCode = 0; Output = ''; Error = '' }
    }
    catch {
        return @{ ExitCode = 1; Output = ''; Error = "normalize-whitespace failed for ${Path}: $($_.Exception.Message)" }
    }
}
