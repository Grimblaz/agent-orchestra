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

function ConvertFrom-PRByteSize {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int]) { return $Value }
    $text = ([string]$Value).Trim().Trim('"').Trim("'")
    if ($text -match '^(\d+)\s*KB$') { return ([int]$Matches[1] * 1024) }
    if ($text -match '^(\d+)\s*MB$') { return ([int]$Matches[1] * 1024 * 1024) }
    if ($text -match '^\d+$') { return [int]$text }
    return $null
}

function Resolve-PRRootContainedPath {
    param(
        [Parameter(Mandatory)][string] $Root,
        [AllowNull()][string] $TargetPath
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $null }
    $rootFullPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    try {
        $candidate = if ([System.IO.Path]::IsPathRooted($TargetPath)) {
            [System.IO.Path]::GetFullPath($TargetPath)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $rootFullPath $TargetPath))
        }
    } catch {
        return $null
    }

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $rootWithSeparator = $rootFullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($candidate.Equals($rootFullPath, $comparison) -or $candidate.StartsWith($rootWithSeparator, $comparison)) {
        return $candidate
    }
    return $null
}

function Get-PRRootRelativePath {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Path
    )
    $absolutePath = Resolve-PRRootContainedPath -Root $Root -TargetPath $Path
    if ($null -eq $absolutePath) { return $null }
    $rootFullPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path)
    return [System.IO.Path]::GetRelativePath($rootFullPath, $absolutePath).Replace('\', '/')
}

function Test-PRObjectProperty {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject.Contains($Name) }
    return ($InputObject.PSObject.Properties.Name -contains $Name)
}

function Get-PRObjectValue {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    if ($InputObject.PSObject.Properties.Name -contains $Name) { return $InputObject.$Name }
    return $null
}

function Get-PRDeclaredRootConfig {
    param([Parameter(Mandatory)][string] $Root)
    $configPath = Join-Path $Root '.agent-orchestra.yml'
    $roots = [System.Collections.Generic.List[string]]::new()
    $found = $false
    $docCountThreshold = 5
    $maxCriticalLoaded = 10
    $maxTotalLoadedBytes = 102400
    if (-not (Test-Path -LiteralPath $configPath)) {
        return [pscustomobject]@{ Found = $false; Roots = @(); DocCountThreshold = $docCountThreshold; MaxCriticalLoaded = $maxCriticalLoaded; MaxTotalLoadedBytes = $maxTotalLoadedBytes }
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
        if ($line -match '^\s+doc_count_threshold\s*:\s*(.+)$') {
            $value = ConvertFrom-PRScalar $Matches[1]
            if ($value -is [int] -and $value -gt 0) { $docCountThreshold = $value }
            continue
        }
        if ($line -match '^\s+max_critical_loaded\s*:\s*(.+)$') {
            $value = ConvertFrom-PRScalar $Matches[1]
            if ($value -is [int] -and $value -gt 0) { $maxCriticalLoaded = $value }
            continue
        }
        if ($line -match '^\s+max_total_loaded_bytes\s*:\s*(.+)$') {
            $value = ConvertFrom-PRByteSize (ConvertFrom-PRScalar $Matches[1])
            if ($value -is [int] -and $value -gt 0) { $maxTotalLoadedBytes = $value }
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

    return [pscustomobject]@{ Found = $found; Roots = @($roots.ToArray()); DocCountThreshold = $docCountThreshold; MaxCriticalLoaded = $maxCriticalLoaded; MaxTotalLoadedBytes = $maxTotalLoadedBytes }
}

function Get-PRReferenceRoot {
    param([Parameter(Mandatory)][string] $IndexJsonPath)
    $indexDirectory = Split-Path -Parent $IndexJsonPath
    if ((Split-Path -Leaf $indexDirectory) -eq '.references') {
        return (Split-Path -Parent $indexDirectory)
    }
    return $indexDirectory
}

function Test-PRReferenceConventionPresent {
    param([Parameter(Mandatory)][string] $Root)
    $indexPath = Join-Path $Root '.references/index.json'
    if (Test-Path -LiteralPath $indexPath) { return $true }
    return (@(Get-PRSidecarList -Root $Root).Count -gt 0)
}

function Get-PRMarkdownDocCount {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string[]] $DocRoots
    )
    if (-not (Test-Path -LiteralPath $Root)) { return 0 }
    $rootFullPath = (Resolve-Path -LiteralPath $Root).Path
    $docs = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.md' | Where-Object { $_.Name -notin @('INDEX.md', 'index.md') })
    $scopedDocs = @($docs | Where-Object {
        $relativePath = [System.IO.Path]::GetRelativePath($rootFullPath, $_.FullName).Replace('\', '/')
        Test-PRGlobMatch -Paths @($relativePath) -Globs $DocRoots
    })
    return $scopedDocs.Count
}

function Read-PRSidecar {
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Root
    )
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
        $targetCandidate = $Path -replace '\.ref\.yml$', ''
        $metadata.target_path = if ($Root) { Get-PRRootRelativePath -Root $Root -Path $targetCandidate } else { [System.IO.Path]::GetFileName($targetCandidate) }
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
    $entry = [ordered]@{
        name = [string]$Sidecar.name
        target_path = [string]$Sidecar.target_path
    }
    foreach ($field in @('description', 'load-when', 'load-priority', 'generated_by', 'generated_at')) {
        if (Test-PRObjectProperty -InputObject $Sidecar -Name $field) {
            $value = Get-PRObjectValue -InputObject $Sidecar -Name $field
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { $entry[$field] = $value }
        }
    }
    $entry.triggers = @($Sidecar.triggers | ForEach-Object {
            [ordered]@{
                labels = @($_.labels)
                globs = @($_.globs)
                keywords = @($_.keywords)
                critical = [bool]$_.critical
            }
        })
    return [pscustomobject]$entry
}

function Get-PRTargetAbsolutePath {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $Entry
    )
    $targetPath = if (Test-PRObjectProperty -InputObject $Entry -Name 'target_path') { [string](Get-PRObjectValue -InputObject $Entry -Name 'target_path') } else { [string](Get-PRObjectValue -InputObject $Entry -Name 'path') }
    return Resolve-PRRootContainedPath -Root $Root -TargetPath $targetPath
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

function Get-PRReferenceMatchToken {
    param([AllowNull()][object[]] $Values)
    $stopWords = @{
        and = $true; are = $true; doc = $true; docs = $true; document = $true; documents = $true; file = $true; files = $true; for = $true; from = $true
        generated = $true; load = $true; manual = $true; markdown = $true; md = $true; optional = $true; project = $true
        reference = $true; references = $true; the = $true; this = $true; touches = $true; when = $true; work = $true
    }
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        foreach ($match in [regex]::Matches([string]$value, '[A-Za-z0-9]+')) {
            $token = $match.Value.ToLowerInvariant()
            if ($token.Length -lt 3 -or $stopWords.ContainsKey($token)) { continue }
            if (-not $tokens.Contains($token)) { $tokens.Add($token) }
        }
    }
    return @($tokens.ToArray())
}

function Test-PRReferenceDeterministicMatch {
    param(
        [Parameter(Mandatory)] $Entry,
        [AllowNull()][string] $IssueText,
        [AllowNull()][string[]] $ChangedPaths
    )
    $targetPath = [string](Get-PRObjectValue -InputObject $Entry -Name 'target_path')
    $targetPath = if ([string]::IsNullOrWhiteSpace($targetPath)) { [string](Get-PRObjectValue -InputObject $Entry -Name 'path') } else { $targetPath }
    $normalizedTarget = $targetPath.Replace('\', '/').Trim('/').ToLowerInvariant()
    $targetLeaf = if ([string]::IsNullOrWhiteSpace($normalizedTarget)) { '' } else { @($normalizedTarget -split '/')[-1] }
    $targetStem = if ([string]::IsNullOrWhiteSpace($targetLeaf)) { '' } else { [System.IO.Path]::GetFileNameWithoutExtension($targetLeaf) }

    foreach ($changedPath in @($ChangedPaths)) {
        if ([string]::IsNullOrWhiteSpace($changedPath)) { continue }
        $normalizedChangedPath = ([string]$changedPath).Replace('\', '/').Trim('/').ToLowerInvariant()
        $changedLeaf = @($normalizedChangedPath -split '/')[-1]
        if (-not [string]::IsNullOrWhiteSpace($normalizedTarget) -and ($normalizedChangedPath -eq $normalizedTarget -or $normalizedChangedPath.EndsWith("/$normalizedTarget"))) { return $true }
        if (-not [string]::IsNullOrWhiteSpace($targetLeaf) -and $changedLeaf -eq $targetLeaf) { return $true }
    }

    $entryTokens = @(Get-PRReferenceMatchToken -Values @(
            Get-PRObjectValue -InputObject $Entry -Name 'name'
            Get-PRObjectValue -InputObject $Entry -Name 'description'
            Get-PRObjectValue -InputObject $Entry -Name 'load-when'
            $targetPath
            $targetLeaf
            $targetStem
        ))
    if ($entryTokens.Count -eq 0) { return $false }

    $entryTokenSet = @{}
    foreach ($token in $entryTokens) { $entryTokenSet[$token] = $true }
    foreach ($token in @(Get-PRReferenceMatchToken -Values @($IssueText))) {
        if ($entryTokenSet.ContainsKey($token)) { return $true }
    }
    return $false
}

function Get-PRJsonEntryList {
    param([Parameter(Mandatory)] $Index)
    if ($Index -is [array]) { return @($Index) }
    if ($Index.PSObject.Properties.Name -contains 'entries') { return @($Index.entries) }
    return @($Index)
}

function Read-PRReferenceState {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    $text = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    if ([System.IO.Path]::GetExtension($Path) -eq '.json') { return ($text | ConvertFrom-Json) }

    $state = [ordered]@{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -match '^\s*([A-Za-z0-9_-]+)\s*:\s*(.+?)\s*$') {
            $state[$Matches[1]] = ConvertFrom-PRScalar $Matches[2]
        }
    }
    return [pscustomobject]$state
}

function Write-PRReferenceState {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $State
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($property in $State.PSObject.Properties) {
        $value = if ($property.Value -is [bool]) { ([string]$property.Value).ToLowerInvariant() } else { [string]$property.Value }
        $lines.Add("$($property.Name): $value")
    }
    Write-PRTextFile -Path $Path -Content (($lines.ToArray() -join "`n") + "`n")
}

function Get-PRUntrustedFence {
    param([AllowNull()][string] $Body)
    $maxRun = 0
    foreach ($match in [regex]::Matches([string]$Body, '`+')) {
        if ($match.Value.Length -gt $maxRun) { $maxRun = $match.Value.Length }
    }
    $fenceLength = [Math]::Max(3, $maxRun + 1)
    return ('`' * $fenceLength)
}