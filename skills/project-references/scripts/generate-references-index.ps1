param([Parameter(Mandatory)][string] $Root)

. "$PSScriptRoot/references-core.ps1"

$referencesDir = Join-Path $Root '.references'
$documentsDir = Join-Path $Root 'Documents'
New-Item -ItemType Directory -Path $referencesDir -Force | Out-Null
New-Item -ItemType Directory -Path $documentsDir -Force | Out-Null

$entries = @(Get-PRSidecarList -Root $Root | ForEach-Object {
    ConvertTo-PRIndexEntry -Sidecar (Read-PRSidecar -Path $_.FullName)
} | Sort-Object { $_.name })

$indexJson = ConvertTo-PRJson -Value $entries
Write-PRTextFile -Path (Join-Path $referencesDir 'index.json') -Content ($indexJson + "`n")

$markdownLines = @('# Project Reference Index', '')
$markdownLines += $entries | ForEach-Object { "- [$($_.name)]($($_.target_path))" }
Write-PRTextFile -Path (Join-Path $documentsDir 'INDEX.md') -Content (($markdownLines -join "`n") + "`n")

ConvertTo-PRJson -Value ([ordered]@{ count = $entries.Count; index_path = (Join-Path $referencesDir 'index.json') })