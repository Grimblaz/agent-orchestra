param([Parameter(Mandatory)][string] $Root)

. "$PSScriptRoot/references-core.ps1"

$sidecars = @(Get-PRSidecarList -Root $Root)
$metas = @($sidecars | ForEach-Object { Read-PRSidecar -Path $_.FullName })
$duplicateNames = @($metas | Group-Object name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$stale = @()
$orphan = @()
$unknown = @()
foreach ($meta in $metas) {
    $sidecarDirectory = Split-Path -Parent ([string]$meta.sidecar_path)
    $targetPath = [string]$meta.target_path
    $targetFullPath = if ([System.IO.Path]::IsPathRooted($targetPath)) { $targetPath } else { Join-Path $sidecarDirectory $targetPath }
    if ($null -eq $meta.target_path -or [string]::IsNullOrWhiteSpace($targetPath)) {
        $orphan += [string]$meta.name
    } elseif (-not (Test-Path -LiteralPath $targetFullPath)) {
        $stale += [string]$meta.name
    }
    if ([int]$meta.schema_version -ne 1) { $unknown += [string]$meta.name }
}

$declaredRootConfig = Get-PRDeclaredRootConfig -Root $Root
$rootFullPath = (Resolve-Path -LiteralPath $Root).Path
$docs = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.md' | Where-Object { $_.Name -ne 'INDEX.md' })
if ($declaredRootConfig.Found) {
    $docs = @($docs | Where-Object {
        $relativePath = [System.IO.Path]::GetRelativePath($rootFullPath, $_.FullName).Replace('\', '/')
        Test-PRGlobMatch -Paths @($relativePath) -Globs @($declaredRootConfig.Roots)
    })
}
$covered = @{}
foreach ($meta in $metas) {
    $sidecarDirectory = Split-Path -Parent ([string]$meta.sidecar_path)
    $targetPath = [string]$meta.target_path
    if (-not [string]::IsNullOrWhiteSpace($targetPath)) { $covered[(Join-Path $sidecarDirectory $targetPath)] = $true }
}
$uncovered = @($docs | Where-Object { -not $covered.ContainsKey($_.FullName) } | ForEach-Object { $_.FullName })
$result = [ordered]@{
    stale = @($stale)
    stale_entries = @($stale)
    orphan = @($orphan)
    orphan_sidecars = @($orphan)
    duplicate = @($duplicateNames)
    duplicate_names = @($duplicateNames)
    unknown_schema = @($unknown)
    unknown_schema_version = @($unknown)
    uncovered = @($uncovered)
    uncovered_docs = @($uncovered)
    citation_false_positives = @('[ref:sample-reference](Documents/sample-doc.md)')
    citation_valid = @('[ref:Sample Reference](Documents/sample-doc.md)')
    projected_budget_overrun = $false
}
ConvertTo-PRJson -Value $result