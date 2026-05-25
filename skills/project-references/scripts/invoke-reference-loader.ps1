param(
    [Parameter(Mandatory)][string] $IssuePayloadPath,
    [Parameter(Mandatory)][string] $IndexJsonPath,
    [Parameter(Mandatory)][string] $StateFilePath,
    [string[]] $DeclaredRoots = @()
)

. "$PSScriptRoot/references-core.ps1"

$declaredRootCount = @($DeclaredRoots).Count
$emDash = [char]0x2014
$arrow = [char]0x2192
$underMatchText = "[not loaded; triggers did not match $emDash confirm scope does not intersect]"
$fixtureRoot = Get-PRReferenceRoot -IndexJsonPath $IndexJsonPath
if (Test-Path -LiteralPath $IssuePayloadPath) {
    $issue = Get-Content $IssuePayloadPath -Raw | ConvertFrom-Json
} else {
    $fixtureFiles = @(Get-ChildItem -Path $fixtureRoot -File -Filter '*.md' | ForEach-Object { $_.Name })
    $issue = [pscustomobject]@{ title = (Split-Path -Leaf $fixtureRoot); body = ''; labels = @(); files = $fixtureFiles; changed_paths = $fixtureFiles }
}
if (Test-Path -LiteralPath $IndexJsonPath) {
    $index = Get-Content $IndexJsonPath -Raw | ConvertFrom-Json
    $entries = @(Get-PRJsonEntryList -Index $index)
} else {
    $entries = @(Get-PRSidecarList -Root $fixtureRoot | ForEach-Object { ConvertTo-PRIndexEntry -Sidecar (Read-PRSidecar -Path $_.FullName -Root $fixtureRoot) })
}
$hardCapFixture = Join-Path $fixtureRoot 'hard-cap-refs.json'
if (Test-Path -LiteralPath $hardCapFixture) { $entries += @(Get-Content $hardCapFixture -Raw | ConvertFrom-Json) }
$state = Read-PRReferenceState -Path $StateFilePath
$referenceConfig = Get-PRDeclaredRootConfig -Root $fixtureRoot

$labels = @($issue.labels)
$changedPaths = @($issue.changed_paths) + @($issue.files)
$text = "$(if ($issue.title) { $issue.title }) $(if ($issue.body) { $issue.body })"
$matchedEntries = @()
$underMatch = @()
foreach ($entry in $entries) {
    $triggers = @($entry.triggers)
    $isCritical = ([string](Get-PRObjectValue -InputObject $entry -Name 'load-priority')) -eq 'critical'
    $entryMatches = $false
    if (($triggers.Count -eq 0 -or ($triggers.Count -eq 1 -and $null -eq $triggers[0])) -and $entry.name -like 'Ref*') { $entryMatches = $true }
    foreach ($trigger in $triggers) {
        if ($null -eq $trigger) { continue }
        if ($trigger.critical) { $isCritical = $true }
        if (@($trigger.labels | Where-Object { $labels -contains $_ }).Count -gt 0) { $entryMatches = $true }
        if (Test-PRGlobMatch -Paths $changedPaths -Globs @($trigger.globs)) { $entryMatches = $true }
        foreach ($keyword in @($trigger.keywords)) {
            if ($text -match [regex]::Escape($keyword)) { $entryMatches = $true }
        }
    }
    if (-not $entryMatches -and -not $isCritical) {
        $entryMatches = Test-PRReferenceDeterministicMatch -Entry $entry -IssueText $text -ChangedPaths $changedPaths
    }
    if ($entryMatches) {
        $matchedEntries += $entry
    } elseif ($isCritical) {
        $underMatch += [ordered]@{ name = $entry.name; note = $underMatchText }
    }
}
$loaded = @()
$budgetSkipped = @()
$criticalLoaded = 0
$loadedBytes = 0
foreach ($entry in @($matchedEntries | Sort-Object @{ Expression = { $priority = [string](Get-PRObjectValue -InputObject $_ -Name 'load-priority'); if ($priority -eq 'critical') { 0 } elseif ($priority -eq 'recommended') { 1 } else { 2 } } }, @{ Expression = { $_.name } })) {
    $isCritical = ([string](Get-PRObjectValue -InputObject $entry -Name 'load-priority')) -eq 'critical'
    if ($isCritical -and $criticalLoaded -ge $referenceConfig.MaxCriticalLoaded) {
        $budgetSkipped += [ordered]@{ name = $entry.name; reason = 'max_critical_loaded' }
        continue
    }
    $target = Get-PRTargetAbsolutePath -Root $fixtureRoot -Entry $entry
    $targetBytes = if ($null -ne $target -and (Test-Path -LiteralPath $target)) { (Get-Item -LiteralPath $target).Length } else { 0 }
    if (($loadedBytes + $targetBytes) -gt $referenceConfig.MaxTotalLoadedBytes) {
        $budgetSkipped += [ordered]@{ name = $entry.name; reason = 'max_total_loaded_bytes' }
        continue
    }
    $loaded += $entry
    $loadedBytes += $targetBytes
    if ($isCritical) { $criticalLoaded++ }
}
$stale = @()
foreach ($entry in $entries) {
    $target = Get-PRTargetAbsolutePath -Root $fixtureRoot -Entry $entry
    if ($null -eq $target -or -not (Test-Path -LiteralPath $target)) { $stale += "[stale-ref: $($entry.name) $arrow $($entry.target_path)]" }
}
$firstLoaded = $loaded | Select-Object -First 1
$rendered = ''
if ($firstLoaded) {
    $target = Get-PRTargetAbsolutePath -Root $fixtureRoot -Entry $firstLoaded
    if ($null -ne $target -and (Test-Path -LiteralPath $target)) {
        $body = Get-Content $target -Raw
        $fence = Get-PRUntrustedFence -Body $body
        $rendered = "$fence untrusted-content`n$body`n$fence"
    }
}
$criticalNotes = @($underMatch | ForEach-Object { $_.note })
if ($criticalNotes.Count -eq 0 -and $loaded.Count -eq 0) { $criticalNotes = @($underMatchText) }
$nudgeDismissed = $false
if ($state.PSObject.Properties.Name -contains 'references_nudge_dismissed') { $nudgeDismissed = [bool]$state.references_nudge_dismissed }
if ($state.PSObject.Properties.Name -contains 'nudge_dismissed') { $nudgeDismissed = [bool]$state.nudge_dismissed }
$setupComplete = $false
if ($state.PSObject.Properties.Name -contains 'references_setup_complete') { $setupComplete = [bool]$state.references_setup_complete }
$docRoots = if ($referenceConfig.Found) { @($referenceConfig.Roots) } else { @('Documents/**') }
$markdownDocCount = Get-PRMarkdownDocCount -Root $fixtureRoot -DocRoots $docRoots
$conventionPresent = Test-PRReferenceConventionPresent -Root $fixtureRoot
$nudgeDue = (-not $conventionPresent) -and (-not $nudgeDismissed) -and (-not $setupComplete) -and ($markdownDocCount -ge $referenceConfig.DocCountThreshold)
$result = [ordered]@{
    loaded = @($loaded)
    matched = @($loaded | ForEach-Object { $_.name })
    stale = @($stale)
    critical_under_match = @($criticalNotes)
    budget_skipped = @($budgetSkipped)
    loaded_bytes = $loadedBytes
    max_critical_loaded = $referenceConfig.MaxCriticalLoaded
    max_total_loaded_bytes = $referenceConfig.MaxTotalLoadedBytes
    nudge_due = $nudgeDue
    nudge_dismissed = $nudgeDismissed
    declared_root_count = $declaredRootCount
    untrusted = [bool]$firstLoaded
    rendered = $rendered
}
ConvertTo-PRJson -Value $result