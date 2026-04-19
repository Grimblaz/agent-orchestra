#Requires -Version 7.0
<#
.SYNOPSIS
    Library for measure-guidance-complexity logic. Dot-source this file and call Invoke-MeasureGuidanceComplexity.
#>

# ── Module-level $Script: variables ──────────────────────────────────────────────
# Must be defined at module level so helper functions can access them via $Script: scope
# when this file is dot-sourced. The constants are static; ConfigData/ConfigSource are
# reset at the start of each Invoke-MeasureGuidanceComplexity call.

# Intentionally more lenient than default config ceiling (128) to prevent false positives on config load failure
$Script:DefaultCeiling = 150
$Script:KeywordPattern = '\b(MUST|NEVER|ALWAYS|REQUIRED|MANDATORY)\b'
$Script:ChecklistPattern = '^\s*-\s\[[ xX]\]'
$Script:FencePattern = '^\s*(`{3,}|~{3,})'
$Script:OverridePattern = '<!--\s*complexity-override:'
$Script:HeadingPattern = '^(#{2,})\s'

# Config state — reset on each Invoke-MeasureGuidanceComplexity call
$Script:ConfigData = $null
$Script:ConfigSource = 'default'

# ── Helpers ──────────────────────────────────────────────────────────────────────
function Get-CeilingForFile {
    param([string]$FileName)

    if ($null -ne $Script:ConfigData) {
        # Per-agent ceiling takes priority over default_ceiling
        $ceilings = $Script:ConfigData.ceilings
        if ($null -ne $ceilings -and $null -ne $ceilings.PSObject.Properties[$FileName]) {
            $perAgentCeiling = $ceilings.PSObject.Properties[$FileName].Value.max_directives
            if ($null -ne $perAgentCeiling) {
                return [int]$perAgentCeiling
            }
            # Fall through to default_ceiling — per-agent entry exists but max_directives is absent
        }
        # Fall back to default_ceiling from config
        $dc = $Script:ConfigData.PSObject.Properties['default_ceiling']
        if ($null -ne $dc) {
            $dcMaxDirectives = $dc.Value.max_directives
            if ($null -ne $dcMaxDirectives) {
                return [int]$dcMaxDirectives
            }
            # Fall through to $Script:DefaultCeiling — default_ceiling exists but max_directives is absent
        }
    }

    return $Script:DefaultCeiling
}

function Measure-AgentFile {
    param([string]$FilePath)

    $lines = Get-Content -LiteralPath $FilePath
    $fenceChar = $null   # backtick or tilde; $null means not inside a fence
    $fenceLen = 0        # minimum delimiter length to close the current fence
    $totalDirectives = 0
    $checklistItems = 0
    $sectionCount = 0
    $maxNestingDepth = 0

    $sectionsList = [System.Collections.Generic.List[hashtable]]::new()
    $currentSection = @{ heading = '(preamble)'; directives = 0 }

    foreach ($line in $lines) {
        # ── Fenced code block toggle (skip block contents and delimiters) ──────
        # Track the opening delimiter character (` or ~) and length so that only
        # a matching close (same char, same or greater length) ends the fence.
        # This prevents a nested ``` inside a ```` fence from toggling state.
        if ($null -ne $fenceChar) {
            # Inside a fence — look for a matching close delimiter
            if ($line -match $Script:FencePattern) {
                $delimiter = $Matches[1]
                if ($delimiter[0] -eq $fenceChar -and $delimiter.Length -ge $fenceLen) {
                    $fenceChar = $null
                    $fenceLen = 0
                }
                # Non-matching delimiter inside fence is treated as regular fenced content
            }
            continue
        }
        if ($line -match $Script:FencePattern) {
            # Opening a fence — record the delimiter character and minimum close length
            $delimiter = $Matches[1]
            $fenceChar = $delimiter[0]
            $fenceLen = $delimiter.Length
            continue
        }

        # ── Override comment — skip entire line ────────────────────────────────
        if ($line -match $Script:OverridePattern) { continue }

        # ── Heading (## and deeper) — flush section and start a new one ────────
        if ($line -match $Script:HeadingPattern) {
            $hashes = $Matches[1]
            $relDepth = $hashes.Length - 1   # ##=1, ###=2, ####=3

            $sectionCount++
            if ($relDepth -gt $maxNestingDepth) { $maxNestingDepth = $relDepth }

            # Flush current section into the list
            $sectionsList.Add(@{ heading = $currentSection.heading; directives = $currentSection.directives })

            $headingText = $line -replace '^#{2,}\s+', ''
            $currentSection = @{ heading = $headingText; directives = 0 }
            continue
        }

        # ── Checklist items ────────────────────────────────────────────────────
        if ($line -match $Script:ChecklistPattern) {
            $checklistItems++
            $totalDirectives++
            $currentSection.directives++
        }

        # ── Directive keywords (case-insensitive, whole-word) ──────────────────
        $kwCount = ([regex]::Matches(
                $line,
                $Script:KeywordPattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )).Count

        if ($kwCount -gt 0) {
            $totalDirectives += $kwCount
            $currentSection.directives += $kwCount
        }
    }

    # Flush the final section (last heading or preamble if no headings)
    $sectionsList.Add(@{ heading = $currentSection.heading; directives = $currentSection.directives })

    $sectionsOut = @(
        $sectionsList | ForEach-Object {
            [ordered]@{ heading = $_.heading; directives = $_.directives }
        }
    )

    return @{
        total_directives  = $totalDirectives
        checklist_items   = $checklistItems
        section_count     = $sectionCount
        max_nesting_depth = $maxNestingDepth
        sections          = $sectionsOut
    }
}

# ── Public function ───────────────────────────────────────────────────────────────
function Invoke-MeasureGuidanceComplexity {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$ConfigPath = 'skills/calibration-pipeline/assets/guidance-complexity.json',
        [string]$AgentsPath = 'agents/*.agent.md'
    )

    $ErrorActionPreference = 'Stop'

    try {
        # Reset config state for each invocation
        $Script:ConfigData = $null
        $Script:ConfigSource = 'default'

        if (Test-Path -LiteralPath $ConfigPath) {
            try {
                $Script:ConfigData = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
                $Script:ConfigSource = 'loaded'
            }
            catch {
                $Script:ConfigSource = 'load-error'  # file found but failed to parse; falls back to built-in default
            }
        }

        $agentFiles = @(Get-Item -Path $AgentsPath -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer })
        $agentsData = [System.Collections.Generic.List[object]]::new()
        $overCeiling = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $agentFiles) {
            $fileResult = Measure-AgentFile -FilePath $file.FullName
            $ceiling = Get-CeilingForFile -FileName $file.Name

            $agentsData.Add([ordered]@{
                    file              = $file.Name
                    total_directives  = $fileResult.total_directives
                    checklist_items   = $fileResult.checklist_items
                    section_count     = $fileResult.section_count
                    max_nesting_depth = $fileResult.max_nesting_depth
                    sections          = $fileResult.sections
                })

            if ($fileResult.total_directives -gt $ceiling) {
                $overCeiling.Add($file.Name)
            }
        }

        $outputData = [ordered]@{
            config_source       = $Script:ConfigSource
            agents_over_ceiling = @($overCeiling)
            agents              = @($agentsData)
        }

        $json = $outputData | ConvertTo-Json -Depth 10
        return @{ ExitCode = 0; Output = $json; Error = '' }
    }
    catch {
        return @{ ExitCode = 0; Output = '{"config_source":"error","agents_over_ceiling":[],"agents":[]}'; Error = $_.Exception.Message }
    }
}
