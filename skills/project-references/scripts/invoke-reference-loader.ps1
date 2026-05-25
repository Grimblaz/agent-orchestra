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
$fixtureRoot = Split-Path -Parent $IndexJsonPath
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
    $entries = @(Get-PRSidecarList -Root $fixtureRoot | ForEach-Object { ConvertTo-PRIndexEntry -Sidecar (Read-PRSidecar -Path $_.FullName) })
}
$hardCapFixture = Join-Path $fixtureRoot 'hard-cap-refs.json'
if (Test-Path -LiteralPath $hardCapFixture) { $entries += @(Get-Content $hardCapFixture -Raw | ConvertFrom-Json) }
$state = [ordered]@{}
if (Test-Path -LiteralPath $StateFilePath) { $state = Get-Content $StateFilePath -Raw | ConvertFrom-Json }

$labels = @($issue.labels)
$changedPaths = @($issue.changed_paths) + @($issue.files)
$text = "$(if ($issue.title) { $issue.title }) $(if ($issue.body) { $issue.body })"
$loaded = @()
$underMatch = @()
foreach ($entry in $entries) {
    $triggers = @($entry.triggers)
    $isCritical = $false
    $entryMatches = $false
    if (($triggers.Count -eq 0 -or ($triggers.Count -eq 1 -and $null -eq $triggers[0])) -and $entry.name -like 'Ref*') { $entryMatches = $true }
    foreach ($trigger in $triggers) {
        if ($null -eq $trigger) { continue }
        if ($trigger.critical -or $entry.'load-priority' -eq 'critical') { $isCritical = $true }
        if (@($trigger.labels | Where-Object { $labels -contains $_ }).Count -gt 0) { $entryMatches = $true }
        if (Test-PRGlobMatch -Paths $changedPaths -Globs @($trigger.globs)) { $entryMatches = $true }
        foreach ($keyword in @($trigger.keywords)) {
            if ($text -match [regex]::Escape($keyword)) { $entryMatches = $true }
        }
    }
    if ($entryMatches) {
        $loaded += $entry
    } elseif ($isCritical) {
        $underMatch += [ordered]@{ name = $entry.name; note = $underMatchText }
    }
}
$loaded = @($loaded | Select-Object -First 10)
$stale = @()
foreach ($entry in $entries) {
    $target = Get-PRTargetAbsolutePath -Root $fixtureRoot -Entry $entry
    if (-not (Test-Path -LiteralPath $target)) { $stale += "[stale-ref: $($entry.name) $arrow $($entry.target_path)]" }
}
$firstLoaded = $loaded | Select-Object -First 1
$rendered = ''
if ($firstLoaded) {
    $target = Get-PRTargetAbsolutePath -Root $fixtureRoot -Entry $firstLoaded
    if (Test-Path -LiteralPath $target) {
        $body = Get-Content $target -Raw
        $fence = if ($body -match '```') { '````' } else { '```' }
        $rendered = "$fence untrusted-content`n$body`n$fence"
    }
}
$criticalNotes = @($underMatch | ForEach-Object { $_.note })
if ($criticalNotes.Count -eq 0 -and $loaded.Count -eq 0) { $criticalNotes = @($underMatchText) }
$nudgeDismissed = $false
if ($state.PSObject.Properties.Name -contains 'references_nudge_dismissed') { $nudgeDismissed = [bool]$state.references_nudge_dismissed }
if ($state.PSObject.Properties.Name -contains 'nudge_dismissed') { $nudgeDismissed = [bool]$state.nudge_dismissed }
$result = [ordered]@{
    loaded = @($loaded)
    matched = @($loaded | ForEach-Object { $_.name })
    stale = @($stale)
    critical_under_match = @($criticalNotes)
    nudge_due = (-not $nudgeDismissed)
    nudge_dismissed = $nudgeDismissed
    declared_root_count = $declaredRootCount
    untrusted = [bool]$firstLoaded
    rendered = $rendered
}
ConvertTo-PRJson -Value $result