#Requires -Version 7.0
<#
.SYNOPSIS
    Behavioral spot-check analyzer for the reporting-economy directive.

.DESCRIPTION
    Scans subagent JSONL transcripts from the Claude projects slug directory for
    the current working directory, identifies final-report events (last assistant
    event) belonging to in-scope attribution agents, and emits a word-count /
    echo-detection table per dispatch.

    In-scope agents are the 11 dispatched specialists tracked under issue #471.

.OUTPUTS
    Formatted table: Agent, ToolUseId, WordCount, EchoDetected, OverrideFlag
    Or a baseline-unavailable message when no transcripts are found.
#>

[CmdletBinding()]
param(
    [string]$SlugDirOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InScopeAgents = @(
    'agent-orchestra:code-critic'
    'agent-orchestra:code-review-response'
    'agent-orchestra:code-smith'
    'agent-orchestra:doc-keeper'
    'agent-orchestra:process-review'
    'agent-orchestra:refactor-specialist'
    'agent-orchestra:research-agent'
    'agent-orchestra:senior-engineer'
    'agent-orchestra:specification'
    'agent-orchestra:test-writer'
    'agent-orchestra:ui-iterator'
)

function Get-SpotcheckSlug {
    param([Parameter(Mandatory)][string]$CwdPath)

    $p = $CwdPath.Replace('\', '/')
    $p = $p.TrimStart('/')

    if ($p -match '^([A-Za-z]):(.*)$') {
        $driveLetter = $Matches[1].ToLowerInvariant()
        $afterColon  = $Matches[2].TrimStart('/')
        $p = if ($afterColon) { "$driveLetter/$afterColon" } else { $driveLetter }
    }

    $segments  = @($p.Split('/') | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) { return '' }

    $processed = @($segments | ForEach-Object { $_.Replace(' ', '-') })

    if ($processed.Count -eq 1) { return $processed[0] }

    $drive     = $processed[0]
    $remaining = $processed[1..($processed.Count - 1)] -join '-'
    return "$drive--$remaining"
}

function Get-SpotcheckRecord {
    param(
        [Parameter(Mandatory)][string]$JsonlPath,
        [Parameter(Mandatory)][string[]]$InScope
    )

    $fileName  = [System.IO.Path]::GetFileNameWithoutExtension($JsonlPath)
    $toolUseId = $fileName -replace '^agent-', ''

    $lines = Get-Content -LiteralPath $JsonlPath -ErrorAction SilentlyContinue
    if (-not $lines) { return $null }

    $lastAssistant = $null
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if ($obj.role -eq 'assistant') {
            $lastAssistant = $obj
        }
    }

    if ($null -eq $lastAssistant) { return $null }

    $agent = $lastAssistant.attributionAgent
    if ([string]::IsNullOrWhiteSpace($agent)) { return $null }
    if ($agent -notin $InScope) { return $null }

    $text = ''
    if ($null -ne $lastAssistant.content) {
        foreach ($item in $lastAssistant.content) {
            if ($item.type -eq 'text' -and -not [string]::IsNullOrEmpty($item.text)) {
                $text += $item.text
            }
        }
    }

    $wordCount    = ($text -split '\s+' | Where-Object { $_ -ne '' }).Count
    $echoDetected = $text -match '\[Tool:'
    $overrideFlag = $text -imatch 'full detail'

    return [PSCustomObject]@{
        Agent         = $agent
        ToolUseId     = $toolUseId
        WordCount     = $wordCount
        EchoDetected  = $echoDetected
        OverrideFlag  = $overrideFlag
    }
}

if ($SlugDirOverride) {
    $slugDir = $SlugDirOverride
} else {
    $cwd     = (Get-Location).Path
    $slug    = Get-SpotcheckSlug -CwdPath $cwd
    $slugDir = Join-Path (Join-Path $HOME '.claude' 'projects') $slug
}

$subagentsDir = Join-Path $slugDir 'subagents'

if (-not (Test-Path -LiteralPath $slugDir)) {
    Write-Output "Baseline unavailable -- no subagent transcripts found at $subagentsDir"
    exit 0
}

$jsonlFiles = @(Get-ChildItem -LiteralPath $subagentsDir -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue)

if ($jsonlFiles.Count -eq 0) {
    Write-Output "Baseline unavailable -- no subagent transcripts found at $subagentsDir"
    exit 0
}

$records = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($file in $jsonlFiles) {
    $record = Get-SpotcheckRecord -JsonlPath $file.FullName -InScope $InScopeAgents
    if ($null -ne $record) {
        $records.Add($record)
    }
}

if ($records.Count -eq 0) {
    Write-Output "Baseline unavailable -- no subagent transcripts found at $subagentsDir"
    exit 0
}

$records | Format-Table -AutoSize
