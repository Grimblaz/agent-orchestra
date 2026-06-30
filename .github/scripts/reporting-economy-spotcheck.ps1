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
    [string]$SlugDirOverride,
    # When set, functions are dot-sourced into the caller scope and the main
    # execution block is skipped. Used by the Pester test suite.
    [switch]$ImportMode
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
    <#
    .SYNOPSIS
        Parse the last assistant event from a subagent JSONL file and return metrics.
    .DESCRIPTION
        Real subagent JSONL schema (issue #471 s4 verified):
          { "type": "assistant", "attributionAgent": "...", "message": { "role": "assistant",
            "content": [ { "type": "text", "text": "..." } ] }, ... }
        Discriminates by top-level "type" (not "role"). Content is at message.content[].
    #>
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
            # -AsHashtable avoids StrictMode PropertyNotFoundException on unknown fields
            $obj = $line | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        } catch {
            continue
        }
        if ($obj['type'] -eq 'assistant') {
            $lastAssistant = $obj
        }
    }

    if ($null -eq $lastAssistant) { return $null }

    $agent = [string]$lastAssistant['attributionAgent']
    if ([string]::IsNullOrWhiteSpace($agent)) { return $null }
    if ($agent -notin $InScope) { return $null }

    $text = ''
    $msgContent = $lastAssistant['message']?['content']
    if ($null -ne $msgContent) {
        foreach ($item in $msgContent) {
            $itemText = [string]$item['text']
            if ($item['type'] -eq 'text' -and -not [string]::IsNullOrEmpty($itemText)) {
                $text += ($itemText + ' ')
            }
        }
    }

    $text         = $text.Trim()
    $wordCount    = @($text -split '\s+' | Where-Object { $_ -ne '' }).Count
    $echoDetected = $text -match '\[Tool:'
    # Match active override invocations; exclude agents quoting the directive's own carve-out
    # ("may always request full detail") by anchoring on provide/providing, not request.
    $overrideFlag = $text -imatch '\bprovid(?:e|ing)\s+(?:the\s+)?full\s+detail\b|\bfull\s+detail\s+(?:as\s+)?requested\b'

    return [PSCustomObject]@{
        Agent         = $agent
        ToolUseId     = $toolUseId
        WordCount     = $wordCount
        EchoDetected  = $echoDetected
        OverrideFlag  = $overrideFlag
    }
}

function Invoke-ReportingEconomySpotcheck {
    <#
    .SYNOPSIS
        Resolve the slug dir, collect spot-check records, and return a result object.
    .DESCRIPTION
        Returns a PSCustomObject with:
          Message — a "Baseline unavailable ..." string when no usable transcripts
                    are found, otherwise $null.
          Records — the collected per-dispatch records (empty when Message is set).
        Designed for in-process invocation by both the CLI main block and the
        Pester suite (script-safety contract #257: no child-pwsh spawn per test).
    #>
    [CmdletBinding()]
    param(
        [string]$SlugDirOverride,
        [Parameter(Mandatory)][string[]]$InScope
    )

    if ($SlugDirOverride) {
        $slugDir = $SlugDirOverride
    } else {
        $cwd          = (Get-Location).Path
        $slug         = Get-SpotcheckSlug -CwdPath $cwd
        $projectsRoot = Join-Path $HOME '.claude' 'projects'
        $slugDir      = Join-Path $projectsRoot $slug

        # Case-insensitive fallback — slug is lowercased but real dir may differ in casing
        if (-not (Test-Path -LiteralPath $slugDir)) {
            $ci = Get-ChildItem -Path $projectsRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { [string]::Equals($_.Name, $slug, [System.StringComparison]::OrdinalIgnoreCase) } |
                Select-Object -First 1
            if ($null -ne $ci) { $slugDir = $ci.FullName }
        }
    }

    if (-not (Test-Path -LiteralPath $slugDir)) {
        return [PSCustomObject]@{
            Message = "Baseline unavailable -- slug directory not found: $slugDir"
            Records = @()
        }
    }

    # Real layout: {slug}/{session-uuid}/subagents/agent-*.jsonl
    $jsonlFiles = @(
        Get-ChildItem -LiteralPath $slugDir -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $sessionSubagents = Join-Path $_.FullName 'subagents'
            if (Test-Path -LiteralPath $sessionSubagents) {
                Get-ChildItem -LiteralPath $sessionSubagents -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue
            }
        }
    )

    if ($jsonlFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Message = "Baseline unavailable -- no subagent transcripts found at $slugDir"
            Records = @()
        }
    }

    $records = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($file in $jsonlFiles) {
        $record = Get-SpotcheckRecord -JsonlPath $file.FullName -InScope $InScope
        if ($null -ne $record) {
            $records.Add($record)
        }
    }

    if ($records.Count -eq 0) {
        return [PSCustomObject]@{
            Message = "Baseline unavailable -- no in-scope agent transcripts found at $slugDir"
            Records = @()
        }
    }

    return [PSCustomObject]@{ Message = $null; Records = $records }
}

if (-not $ImportMode) {
    $result = Invoke-ReportingEconomySpotcheck -SlugDirOverride $SlugDirOverride -InScope $InScopeAgents
    if ($null -ne $result.Message) {
        Write-Output $result.Message
        exit 0
    }
    $result.Records | Format-Table -AutoSize
}
