param(
    [Parameter(Mandatory)][string] $Root,
    [switch] $Undo,
    [Parameter(ValueFromRemainingArguments = $true)][string[]] $RemainingArgs
)

. "$PSScriptRoot/references-core.ps1"

$manifestPath = Join-Path $Root 'manifest.json'
$trackingDir = Join-Path $Root '.copilot-tracking'
$trackingManifestPath = Join-Path $trackingDir 'references-init.manifest'
if ($RemainingArgs -contains '--undo') { $Undo = $true }

if ($Undo) {
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        foreach ($created in @($manifest.created)) {
            if (Test-Path -LiteralPath $created) { Remove-Item -LiteralPath $created -Force }
        }
    }
    ConvertTo-PRJson -Value ([ordered]@{ undone = $true })
    return
}

$configPath = Join-Path $Root '.agent-orchestra.yml'
if (Test-Path -LiteralPath $configPath) {
    $configText = Get-Content $configPath -Raw
    if ($configText -match 'declared_roots\s*:\s*\[\s*\]') {
        ConvertTo-PRJson -Value ([ordered]@{ created = @(); no_op = $true })
        return
    }
}

$documentsIndex = Join-Path $Root 'Documents/index.md'
if (Test-Path -LiteralPath $documentsIndex) {
    Copy-Item -LiteralPath $documentsIndex -Destination (Join-Path $Root 'Documents/INDEX.md.pre-references-bak') -Force
}

$created = @()
$docs = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.md' | Where-Object { $_.Name -notin @('INDEX.md', 'index.md') })
foreach ($doc in $docs) {
    $sidecarPath = "$($doc.FullName).ref.yml"
    if (Test-Path -LiteralPath $sidecarPath) {
        $content = Get-Content $sidecarPath -Raw
        if ($content -match 'generated_by\s*:\s*manual' -or $content.Trim() -eq 'manual: true') { continue }
    }
    $name = $doc.BaseName -replace '-', ' '
    $yaml = @(
        'schema_version: 1'
        "name: $name"
        "target_path: $($doc.Name)"
        'load-priority: optional'
        'generated_by: init-references'
    ) -join "`n"
    Write-PRTextFile -Path $sidecarPath -Content ($yaml + "`n")
    $created += $sidecarPath
}

New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
$manifest = [ordered]@{ created = @($created) }
Write-PRTextFile -Path $manifestPath -Content ((ConvertTo-PRJson -Value $manifest) + "`n")
Write-PRTextFile -Path $trackingManifestPath -Content ((ConvertTo-PRJson -Value $manifest) + "`n")
ConvertTo-PRJson -Value $manifest