param(
    [Parameter(Mandatory)][string] $Root,
    [switch] $Undo,
    [switch] $DismissNudge,
    [Parameter(ValueFromRemainingArguments = $true)][string[]] $RemainingArgs
)

. "$PSScriptRoot/references-core.ps1"

$trackingDir = Join-Path $Root '.copilot-tracking'
$trackingManifestPath = Join-Path $trackingDir 'references-init.manifest'
$statePath = Join-Path $trackingDir 'references-state.yml'
if ($RemainingArgs -contains '--undo') { $Undo = $true }
if ($RemainingArgs -contains '--dismiss-nudge') { $DismissNudge = $true }

if ($DismissNudge) {
    New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null
    Write-PRReferenceState -Path $statePath -State ([pscustomobject][ordered]@{ references_nudge_dismissed = $true })
    ConvertTo-PRJson -Value ([ordered]@{ dismissed = $true; state_path = $statePath })
    return
}

if ($Undo) {
    if (Test-Path -LiteralPath $trackingManifestPath) {
        $manifest = Get-Content $trackingManifestPath -Raw | ConvertFrom-Json
        foreach ($created in @($manifest.created)) {
            $createdPath = Resolve-PRRootContainedPath -Root $Root -TargetPath ([string]$created)
            if ($null -ne $createdPath -and (Test-Path -LiteralPath $createdPath) -and -not (Get-Item -LiteralPath $createdPath).PSIsContainer) {
                Remove-Item -LiteralPath $createdPath -Force
            }
        }
        Remove-Item -LiteralPath $trackingManifestPath -Force
    }
    ConvertTo-PRJson -Value ([ordered]@{ undone = $true })
    return
}

New-Item -ItemType Directory -Path $trackingDir -Force | Out-Null

$configPath = Join-Path $Root '.agent-orchestra.yml'
if (Test-Path -LiteralPath $configPath) {
    $configText = Get-Content $configPath -Raw
    if ($configText -match 'declared_roots\s*:\s*\[\s*\]') {
        Write-PRReferenceState -Path $statePath -State ([pscustomobject][ordered]@{ references_setup_complete = $true })
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
    $relativeTargetPath = Get-PRRootRelativePath -Root $Root -Path $doc.FullName
    if ($null -eq $relativeTargetPath) { continue }
    $generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $yaml = @(
        'schema_version: 1'
        "name: $name"
        "target_path: $relativeTargetPath"
        "description: Generated reference for $relativeTargetPath"
        "load-when: Load when work touches $relativeTargetPath"
        'load-priority: optional'
        'generated_by: init-references'
        "generated_at: $generatedAt"
    ) -join "`n"
    Write-PRTextFile -Path $sidecarPath -Content ($yaml + "`n")
    $created += (Get-PRRootRelativePath -Root $Root -Path $sidecarPath)
}

$manifest = [ordered]@{ created = @($created) }
Write-PRTextFile -Path $trackingManifestPath -Content ((ConvertTo-PRJson -Value $manifest) + "`n")
Write-PRReferenceState -Path $statePath -State ([pscustomobject][ordered]@{ references_setup_complete = $true })
ConvertTo-PRJson -Value $manifest