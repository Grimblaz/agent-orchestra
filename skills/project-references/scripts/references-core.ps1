function ConvertTo-PRJson {
    param([Parameter(Mandatory)] $Value)
    return (($Value | ConvertTo-Json -Depth 20) -replace "`r`n", "`n" -replace "`r", "`n")
}

function Write-PRTextFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Content
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

function ConvertFrom-PRInlineArray {
    param([AllowNull()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
        $trimmed = $trimmed.Substring(1, $trimmed.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return @() }
    return @($trimmed -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })
}

function ConvertFrom-PRScalar {
    param([AllowNull()][string] $Value)
    if ($null -eq $Value) { return $null }
    $trimmed = $Value.Trim()
    if ($trimmed -eq 'null') { return $null }
    if ($trimmed -eq 'true') { return $true }
    if ($trimmed -eq 'false') { return $false }
    if ($trimmed -match '^\d+$') { return [int]$trimmed }
    return $trimmed.Trim('"').Trim("'")
}

function Get-PRDeclaredRootConfig {
    param([Parameter(Mandatory)][string] $Root)
    $configPath = Join-Path $Root '.agent-orchestra.yml'
    $roots = [System.Collections.Generic.List[string]]::new()
    $found = $false
    if (-not (Test-Path -LiteralPath $configPath)) {
        return [pscustomobject]@{ Found = $false; Roots = @() }
    }

    $inReferences = $false
    $inDeclaredRoots = $false
    foreach ($line in [System.IO.File]::ReadAllLines($configPath)) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -match '^references\s*:\s*$') {
            $inReferences = $true
            $inDeclaredRoots = $false
            continue
        }
        if (-not $inReferences) { continue }
        if ($line -match '^\S') {
            $inReferences = $false
            $inDeclaredRoots = $false
            continue
        }
        if ($line -match '^\s+declared_roots\s*:\s*(.*)$') {
            $found = $true
            $value = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                @(ConvertFrom-PRInlineArray $value) | ForEach-Object { $roots.Add([string]$_) }
                $inDeclaredRoots = $false
            } else {
                $inDeclaredRoots = $true
            }
            continue
        }
        if ($inDeclaredRoots -and $line -match '^\s+-\s*(.+)$') {
            $roots.Add([string](ConvertFrom-PRScalar $Matches[1]))
            continue
        }
        if ($inDeclaredRoots -and $line -match '^\s+\S') {
            $inDeclaredRoots = $false
        }
    }

    return [pscustomobject]@{ Found = $found; Roots = @($roots.ToArray()) }
}

function Read-PRSidecar {
    param([Parameter(Mandatory)][string] $Path)
    $metadata = [ordered]@{
        schema_version = 1
        triggers = @([ordered]@{ labels = @(); globs = @(); keywords = @(); critical = $false })
        sidecar_path = $Path
    }
    $inTriggers = $false
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -match '^\s*triggers\s*:\s*$') { $inTriggers = $true; continue }
        if ($line -match '^\s*-\s*([A-Za-z0-9_-]+)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2]
        } elseif ($line -match '^\s*([A-Za-z0-9_-]+)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2]
        } else {
            continue
        }
        if ($inTriggers -and $key -in @('labels', 'globs', 'keywords')) {
            $metadata.triggers[0][$key] = @(ConvertFrom-PRInlineArray $value)
            continue
        }
        if ($inTriggers -and $key -eq 'critical') {
            $metadata.triggers[0].critical = [bool](ConvertFrom-PRScalar $value)
            continue
        }
        if ($line -notmatch '^\s') { $inTriggers = $false }
        $metadata[$key] = ConvertFrom-PRScalar $value
    }
    if (-not $metadata.Contains('name') -or [string]::IsNullOrWhiteSpace([string]$metadata.name)) {
        $metadata.name = [System.IO.Path]::GetFileNameWithoutExtension(($Path -replace '\.ref\.yml$', ''))
    }
    if (-not $metadata.Contains('target_path')) {
        $metadata.target_path = [System.IO.Path]::GetFileName(($Path -replace '\.ref\.yml$', ''))
    }
    return [pscustomobject]$metadata
}

function Get-PRSidecarList {
    param([Parameter(Mandatory)][string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.ref.yml' | Sort-Object FullName)
}

function ConvertTo-PRIndexEntry {
    param([Parameter(Mandatory)] $Sidecar)
    return [pscustomobject][ordered]@{
        name = [string]$Sidecar.name
        target_path = [string]$Sidecar.target_path
        triggers = @($Sidecar.triggers | ForEach-Object {
            [ordered]@{
                labels = @($_.labels)
                globs = @($_.globs)
                keywords = @($_.keywords)
                critical = [bool]$_.critical
            }
        })
    }
}

function Get-PRTargetAbsolutePath {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $Entry
    )
    if ($Entry -is [System.Collections.IDictionary]) {
        $targetPath = if ($Entry.Contains('target_path')) { [string]$Entry['target_path'] } else { [string]$Entry['path'] }
    } else {
        $targetPath = if ($Entry.PSObject.Properties.Name -contains 'target_path') { [string]$Entry.target_path } else { [string]$Entry.path }
    }
    if ([System.IO.Path]::IsPathRooted($targetPath)) { return $targetPath }
    return (Join-Path $Root $targetPath)
}

function Test-PRGlobMatch {
    param([string[]] $Paths, [string[]] $Globs)
    foreach ($path in @($Paths)) {
        foreach ($glob in @($Globs)) {
            if ($path -like $glob) { return $true }
        }
    }
    return $false
}

function Get-PRJsonEntryList {
    param([Parameter(Mandatory)] $Index)
    if ($Index -is [array]) { return @($Index) }
    if ($Index.PSObject.Properties.Name -contains 'entries') { return @($Index.entries) }
    return @($Index)
}