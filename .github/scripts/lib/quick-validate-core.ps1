#Requires -Version 7.0
<#
.SYNOPSIS
    Library for quick-validate logic. Dot-source this file and call Invoke-QuickValidate.
#>

function Test-QVLegacyReference {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Pattern,
        [string[]]$ExtraExcludeNames = @()
    )

    $githubPath = Join-Path $RootPath '.github'
    if (-not (Test-Path $githubPath)) {
        return [PSCustomObject]@{ Name = $Name; Passed = $true; Detail = '' }
    }

    $excludePattern = 'copilot-instructions|architecture-rules'
    if ($ExtraExcludeNames.Count -gt 0) {
        $excludePattern += '|' + (($ExtraExcludeNames | ForEach-Object { [regex]::Escape($_) }) -join '|')
    }

    $mdFiles = Get-ChildItem -Path $githubPath -Recurse -Filter '*.md' |
        Where-Object { $_.Name -notmatch $excludePattern }

    $hits = @($mdFiles | Select-String -Pattern $Pattern -SimpleMatch)
    if ($hits.Count -eq 0) {
        return [PSCustomObject]@{ Name = $Name; Passed = $true; Detail = '' }
    }

    $fileList = ($hits | ForEach-Object { $_.RelativePath($githubPath) ?? $_.Path }) -join ', '
    return [PSCustomObject]@{ Name = $Name; Passed = $false; Detail = "$($hits.Count) reference(s) found: $fileList" }
}

function Test-QVSkillFrontmatter {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,
        [Parameter(Mandatory)]
        [string]$CheckName,
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    $skillsPath = Join-Path -Path $RootPath -ChildPath '.github' -AdditionalChildPath 'skills'
    if (-not (Test-Path $skillsPath)) {
        return [PSCustomObject]@{ Name = $CheckName; Passed = $true; Detail = '' }
    }

    $skillFiles = @(Get-ChildItem -Path $skillsPath -Directory |
            ForEach-Object { Join-Path -Path $_.FullName -ChildPath 'SKILL.md' } |
            Where-Object { Test-Path $_ })

    if ($skillFiles.Count -eq 0) {
        return [PSCustomObject]@{ Name = $CheckName; Passed = $true; Detail = '' }
    }

    $failing = @()
    foreach ($file in $skillFiles) {
        $match = Select-String -Path $file -Pattern $Pattern
        if (-not $match) {
            $failing += [System.IO.Path]::GetFileName(
                [System.IO.Path]::GetDirectoryName($file)
            ) + '/SKILL.md'
        }
    }

    if ($failing.Count -eq 0) {
        return [PSCustomObject]@{ Name = $CheckName; Passed = $true; Detail = '' }
    }

    return [PSCustomObject]@{
        Name   = $CheckName
        Passed = $false
        Detail = "$($failing.Count) SKILL.md file(s) missing pattern: $($failing -join ', ')"
    }
}

function Test-QVGuidanceComplexity {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath
    )

    $resolvedScript = (Resolve-Path $ScriptPath).Path
    $output = & $resolvedScript
    $json = $output | ConvertFrom-Json

    if ($json.agents_over_ceiling.Count -eq 0) {
        return [PSCustomObject]@{ Name = 'GuidanceComplexity'; Passed = $true; Detail = '' }
    }

    $names = ($json.agents_over_ceiling | ForEach-Object { $_.name }) -join ', '
    return [PSCustomObject]@{
        Name   = 'GuidanceComplexity'
        Passed = $false
        Detail = "$($json.agents_over_ceiling.Count) agent(s) over ceiling: $names"
    }
}

function Get-QVExistingPSScriptAnalyzerPaths {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,
        [string]$ScriptsPath
    )

    $paths = [System.Collections.Generic.List[string]]::new()

    if ($ScriptsPath -and (Test-Path $ScriptsPath)) {
        $paths.Add((Resolve-Path $ScriptsPath).Path)
    }

    $skillScriptsPath = Join-Path -Path $RootPath -ChildPath '.github' -AdditionalChildPath 'skills'
    if (Test-Path $skillScriptsPath) {
        $skillScriptFiles = @(Get-ChildItem -Path $skillScriptsPath -Filter '*.ps1' -File -Recurse |
                Where-Object { $_.DirectoryName -match '[\\/]scripts$' })
        foreach ($file in $skillScriptFiles) {
            $paths.Add($file.FullName)
        }
    }

    return $paths.ToArray()
}

function Test-QVPSScriptAnalyzer {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,
        [Parameter(Mandatory)]
        [string]$ScriptsPath,
        [Parameter(Mandatory)]
        [string]$SettingsPath
    )

    $installed = Get-Module -Name PSScriptAnalyzer -ListAvailable
    if (-not $installed) {
        return [PSCustomObject]@{ Name = 'PSScriptAnalyzer'; Passed = 'SKIP'; Detail = 'PSScriptAnalyzer not installed — skipping' }
    }

    $resolvedPaths = @(Get-QVExistingPSScriptAnalyzerPaths -RootPath $RootPath -ScriptsPath $ScriptsPath)
    if ($resolvedPaths.Count -eq 0) {
        return [PSCustomObject]@{ Name = 'PSScriptAnalyzer'; Passed = $true; Detail = '' }
    }

    $resolvedSettingsPath = $null
    if (Test-Path $SettingsPath) {
        $resolvedSettingsPath = (Resolve-Path $SettingsPath).Path
    }

    $issues = foreach ($path in $resolvedPaths) {
        $analyzerParams = @{ Path = $path }
        if ((Get-Item $path).PSIsContainer) {
            $null = $analyzerParams.Add('Recurse', $true)
        }
        if ($resolvedSettingsPath) {
            $null = $analyzerParams.Add('Settings', $resolvedSettingsPath)
        }

        Invoke-ScriptAnalyzer @analyzerParams
    }
    $issues = @($issues)
    if ($issues.Count -eq 0) {
        return [PSCustomObject]@{ Name = 'PSScriptAnalyzer'; Passed = $true; Detail = '' }
    }

    return [PSCustomObject]@{
        Name   = 'PSScriptAnalyzer'
        Passed = $false
        Detail = "$($issues.Count) issue(s) found"
    }
}

function Test-QVSkillAssetJsonParse {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath
    )

    $skillsPath = Join-Path -Path $RootPath -ChildPath '.github' -AdditionalChildPath 'skills'
    if (-not (Test-Path $skillsPath)) {
        return [PSCustomObject]@{ Name = 'SkillAssetJsonParse'; Passed = $true; Detail = '' }
    }

    $jsonFiles = @(Get-ChildItem -Path $skillsPath -Filter '*.json' -File -Recurse |
            Where-Object { $_.DirectoryName -match '[\\/]assets$' })
    if ($jsonFiles.Count -eq 0) {
        return [PSCustomObject]@{ Name = 'SkillAssetJsonParse'; Passed = $true; Detail = '' }
    }

    $invalidFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $jsonFiles) {
        try {
            Get-Content -Path $file.FullName -Raw | ConvertFrom-Json | Out-Null
        }
        catch {
            $invalidFiles.Add($file.FullName)
        }
    }

    if ($invalidFiles.Count -eq 0) {
        return [PSCustomObject]@{ Name = 'SkillAssetJsonParse'; Passed = $true; Detail = '' }
    }

    $relativePaths = $invalidFiles | ForEach-Object {
        [System.IO.Path]::GetRelativePath($RootPath, $_)
    }

    return [PSCustomObject]@{
        Name   = 'SkillAssetJsonParse'
        Passed = $false
        Detail = "$($invalidFiles.Count) JSON file(s) failed to parse: $($relativePaths -join ', ')"
    }
}

function Invoke-QuickValidate {
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [string]$GuidanceComplexityScriptPath,
        [string]$PSScriptAnalyzerSettingsPath,
        [string]$ScriptsPath
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    try {
        if (-not $RootPath) {
            $RootPath = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        }
        if (-not $GuidanceComplexityScriptPath) {
            $GuidanceComplexityScriptPath = Join-Path -Path $RootPath -ChildPath '.github' -AdditionalChildPath 'scripts', 'measure-guidance-complexity.ps1'
        }
        if (-not $PSScriptAnalyzerSettingsPath) {
            $PSScriptAnalyzerSettingsPath = Join-Path -Path $RootPath -ChildPath '.github' -AdditionalChildPath 'config', 'PSScriptAnalyzerSettings.psd1'
        }
        if (-not $ScriptsPath) {
            $ScriptsPath = Join-Path -Path $RootPath -ChildPath '.github' -AdditionalChildPath 'scripts'
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        # 1. Plan-Architect
        try { $results.Add((Test-QVLegacyReference -RootPath $RootPath -Name 'Plan-Architect' -Pattern 'Plan-Architect')) }
        catch { $results.Add([PSCustomObject]@{ Name = 'Plan-Architect'; Passed = $false; Detail = "Error: $_" }) }
        # 2. Janitor
        try { $results.Add((Test-QVLegacyReference -RootPath $RootPath -Name 'Janitor' -Pattern 'Janitor')) }
        catch { $results.Add([PSCustomObject]@{ Name = 'Janitor'; Passed = $false; Detail = "Error: $_" }) }
        # 3. Issue-Designer
        try { $results.Add((Test-QVLegacyReference -RootPath $RootPath -Name 'Issue-Designer' -Pattern 'Issue-Designer')) }
        catch { $results.Add([PSCustomObject]@{ Name = 'Issue-Designer'; Passed = $false; Detail = "Error: $_" }) }
        # 4. workflow-template (also exclude setup.prompt)
        try { $results.Add((Test-QVLegacyReference -RootPath $RootPath -Name 'workflow-template' -Pattern 'workflow-template' -ExtraExcludeNames @('setup.prompt'))) }
        catch { $results.Add([PSCustomObject]@{ Name = 'workflow-template'; Passed = $false; Detail = "Error: $_" }) }
        # 5. SKILL-UseWhen
        try { $results.Add((Test-QVSkillFrontmatter -RootPath $RootPath -CheckName 'SKILL-UseWhen' -Pattern '^description:.*Use (when|before)')) }
        catch { $results.Add([PSCustomObject]@{ Name = 'SKILL-UseWhen'; Passed = $false; Detail = "Error: $_" }) }
        # 6. SKILL-DoNotUseFor
        try { $results.Add((Test-QVSkillFrontmatter -RootPath $RootPath -CheckName 'SKILL-DoNotUseFor' -Pattern '^description:.*DO NOT USE FOR:')) }
        catch { $results.Add([PSCustomObject]@{ Name = 'SKILL-DoNotUseFor'; Passed = $false; Detail = "Error: $_" }) }
        # 7. SKILL-Gotchas
        try { $results.Add((Test-QVSkillFrontmatter -RootPath $RootPath -CheckName 'SKILL-Gotchas' -Pattern '^## Gotchas')) }
        catch { $results.Add([PSCustomObject]@{ Name = 'SKILL-Gotchas'; Passed = $false; Detail = "Error: $_" }) }
        # 8. GuidanceComplexity
        try { $results.Add((Test-QVGuidanceComplexity -ScriptPath $GuidanceComplexityScriptPath)) }
        catch { $results.Add([PSCustomObject]@{ Name = 'GuidanceComplexity'; Passed = $false; Detail = "Error: $_" }) }
        # 9. PSScriptAnalyzer
        try { $results.Add((Test-QVPSScriptAnalyzer -RootPath $RootPath -ScriptsPath $ScriptsPath -SettingsPath $PSScriptAnalyzerSettingsPath)) }
        catch { $results.Add([PSCustomObject]@{ Name = 'PSScriptAnalyzer'; Passed = $false; Detail = "Error: $_" }) }
        # 10. SkillAssetJsonParse
        try { $results.Add((Test-QVSkillAssetJsonParse -RootPath $RootPath)) }
        catch { $results.Add([PSCustomObject]@{ Name = 'SkillAssetJsonParse'; Passed = $false; Detail = "Error: $_" }) }

        $passCount = @($results | Where-Object { $_.Passed -eq $true }).Count
        $failCount = @($results | Where-Object { $_.Passed -eq $false }).Count
        $skipCount = @($results | Where-Object { $_.Passed -is [string] -and $_.Passed -eq 'SKIP' }).Count
        $totalCount = $results.Count
        $effectiveTotal = $totalCount - $skipCount

        foreach ($r in $results) {
            if ($r.Passed -eq $true) {
                Write-Host "[PASS] $($r.Name)"
            }
            elseif ($r.Passed -eq 'SKIP') {
                Write-Host "[SKIP] $($r.Name) — $($r.Detail)"
            }
            else {
                Write-Host "[FAIL] $($r.Name) — $($r.Detail)"
            }
        }

        $summary = "Quick-validate: $passCount/$effectiveTotal checks passed"
        if ($skipCount -gt 0) { $summary += " ($skipCount skipped)" }
        Write-Host $summary

        $exitCode = if ($failCount -gt 0) { 1 } else { 0 }

        return [PSCustomObject]@{
            Results    = $results.ToArray()
            PassCount  = [int]$passCount
            FailCount  = [int]$failCount
            SkipCount  = [int]$skipCount
            TotalCount = [int]$totalCount
            ExitCode   = $exitCode
        }
    }
    catch {
        Write-Host "[FATAL] Quick-validate encountered a catastrophic error: $_"
        return [PSCustomObject]@{
            Results    = @()
            PassCount  = 0
            FailCount  = 1
            SkipCount  = 0
            TotalCount = 1
            ExitCode   = 1
        }
    }
}
