[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Test-AllowlistedWhitespacePath {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedPath
    )

    $fileName = [System.IO.Path]::GetFileName($ResolvedPath)
    $extension = [System.IO.Path]::GetExtension($ResolvedPath)

    return $fileName -in @('.gitignore', '.gitattributes', '.editorconfig') -or
    $extension -in @('.json', '.jsonc', '.yml', '.yaml', '.psd1', '.txt')
}

function Test-BinaryLikeContent {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    return $Bytes -contains 0
}

function Get-NewlineSequence {
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

try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warning "normalize-whitespace skipped missing file: $Path"
        exit 0
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if (-not (Test-AllowlistedWhitespacePath -ResolvedPath $resolvedPath)) {
        Write-Warning "normalize-whitespace skipped unsupported file type: $resolvedPath"
        exit 0
    }

    $originalBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    if (Test-BinaryLikeContent -Bytes $originalBytes) {
        Write-Warning "normalize-whitespace skipped binary-like content: $resolvedPath"
        exit 0
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
            Write-Warning "normalize-whitespace skipped non-UTF-8-safe content: $resolvedPath"
            exit 0
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

    $newline = Get-NewlineSequence -Content $current
    $normalized = [regex]::Replace($current, '[ \t]+(?=(?:\r\n|\n|\r)|$)', '')
    $normalized = [regex]::Replace($normalized, '(?:\r\n|\n|\r)+\z', '')
    $normalized += $newline

    if ($normalized -ceq $current) {
        exit 0
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

    exit 0
}
catch {
    Write-Warning "normalize-whitespace failed for ${Path}: $($_.Exception.Message)"
    exit 1
}