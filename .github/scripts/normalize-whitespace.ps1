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
        [byte[]]$Bytes
    )

    return $Bytes -contains 0
}

function Get-NewlineSequence {
    param(
        [Parameter(Mandatory)]
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

    $reader = [System.IO.StreamReader]::new($resolvedPath, $true)
    try {
        $current = $reader.ReadToEnd()
        $encoding = $reader.CurrentEncoding
    }
    finally {
        $reader.Dispose()
    }

    $newline = Get-NewlineSequence -Content $current
    $normalized = [regex]::Replace($current, '[ \t]+(?=(\r\n|\n|\r)|$)', '')
    $normalized = [regex]::Replace($normalized, '(?:\r\n|\n|\r)+\z', '')
    $normalized += $newline

    if ($normalized -ceq $current) {
        exit 0
    }

    if ($encoding.WebName -eq 'utf-8') {
        $encoding = [System.Text.UTF8Encoding]::new($hasUtf8Bom)
    }

    $writer = [System.IO.StreamWriter]::new($resolvedPath, $false, $encoding)
    try {
        $writer.Write($normalized)
    }
    finally {
        $writer.Dispose()
    }

    exit 0
}
catch {
    Write-Warning "normalize-whitespace failed for ${Path}: $($_.Exception.Message)"
    exit 0
}