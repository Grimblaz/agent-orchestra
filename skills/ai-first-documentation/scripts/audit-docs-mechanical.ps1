#!/usr/bin/env pwsh
# audit-docs-mechanical.ps1
# Mechanical-check script for ai-first-documentation skill. Consumer-mode audit tool.
# Line counting uses (Get-Content -Path $f).Count semantics — deterministic on Windows and ubuntu-latest CI.
# Additive schema policy: new fields added to JSON output are backward-compatible.
# warn is a reserved status enum value; no v1 code path emits it.

#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Root,
    [string]$DecisionRecordPath,
    [ValidateSet('fail')]
    [string]$FailOn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve root to absolute path
# ---------------------------------------------------------------------------
try {
    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
} catch {
    @{ error = "Cannot resolve root path '$Root': $_" } | ConvertTo-Json -Compress
    exit 1
}

# Ensure root exists and is a directory
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    @{ error = "Root path '$resolvedRoot' is not a directory or does not exist." } | ConvertTo-Json -Compress
    exit 1
}

# ---------------------------------------------------------------------------
# Resolve decision record path
# ---------------------------------------------------------------------------
if ($DecisionRecordPath) {
    # Resolve relative paths against the audited root, not the caller's CWD
    if ([System.IO.Path]::IsPathRooted($DecisionRecordPath)) {
        $resolvedDecisionPath = $DecisionRecordPath
    } else {
        $resolvedDecisionPath = Join-Path $resolvedRoot $DecisionRecordPath
    }
} else {
    $resolvedDecisionPath = Join-Path $resolvedRoot '.claude' 'documentation-decisions.md'
}

# ---------------------------------------------------------------------------
# Parse waiver decision record
# ---------------------------------------------------------------------------
function Get-WaiverMap {
    param([string]$DecisionFilePath)
    $map = @{}
    if (-not (Test-Path -LiteralPath $DecisionFilePath)) {
        return $map
    }
    try {
        $raw = Get-Content -LiteralPath $DecisionFilePath -Raw -ErrorAction Stop
        # CRLF-normalize
        $raw = $raw -replace '\r\n', "`n" -replace '\r', "`n"
        # Find all H3 headings of form "### {check-id}: {relative-path}"
        $pattern = '(?m)^### ([^\n]+)'
        $regexMatches = [regex]::Matches($raw, $pattern)
        foreach ($m in $regexMatches) {
            $headingText = $m.Groups[1].Value.Trim()
            # heading format: "A2: CLAUDE.md" — split on first ": "
            if ($headingText -match '^([A-Z][0-9]+):\s+(.+)$') {
                $checkId = $Matches[1]
                $filePath = $Matches[2].Trim()
                # Normalize separators for key matching
                $normalizedPath = $filePath -replace '\\', '/'
                $key = "${checkId}:${normalizedPath}"
                $map[$key] = $headingText
            }
        }
    } catch {
        # If decision record can't be read, skip waiver logic (proceed with mechanical verdict)
    }
    return $map
}

function Get-WaiverRef {
    param([hashtable]$WaiverMap, [string]$CheckId, [string]$RelativePath)
    $normalizedRel = $RelativePath -replace '\\', '/'
    $key = "${CheckId}:${normalizedRel}"
    if ($WaiverMap.ContainsKey($key)) {
        return $WaiverMap[$key]
    }
    return $null
}

# ---------------------------------------------------------------------------
# Helper: get relative path from root (forward slashes)
# ---------------------------------------------------------------------------
function Get-RelativePath {
    param([string]$FullPath, [string]$BasePath)
    if (-not $BasePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $BasePath = $BasePath + [System.IO.Path]::DirectorySeparatorChar
    }
    if ($FullPath.StartsWith($BasePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $FullPath.Substring($BasePath.Length)
    } else {
        $rel = $FullPath
    }
    # Normalize to forward slashes
    return $rel -replace '\\', '/'
}

# ---------------------------------------------------------------------------
# Helper: check if a path is under a plugin-cache-shaped dir
# ---------------------------------------------------------------------------
function Test-IsPluginCachePath {
    param([string]$Path)
    $normalized = $Path -replace '\\', '/'
    return ($normalized -match '/\.claude/plugins/' -or $normalized -match '/cache/agent-orchestra/')
}

# ---------------------------------------------------------------------------
# Inventory (D3 rule)
# ---------------------------------------------------------------------------
function Get-Inventoried {
    param([string]$RootPath)
    $items = [System.Collections.Generic.List[string]]::new()

    # Root-level context files
    foreach ($name in @('CLAUDE.md', 'AGENTS.md', 'CLAUDE.local.md')) {
        $fp = Join-Path $RootPath $name
        if (Test-Path -LiteralPath $fp -PathType Leaf) {
            $items.Add((Get-RelativePath $fp $RootPath))
        }
    }

    # .claude/rules/ files
    $rulesDir = Join-Path $RootPath '.claude' 'rules'
    if (Test-Path -LiteralPath $rulesDir -PathType Container) {
        Get-ChildItem -LiteralPath $rulesDir -Recurse -File | ForEach-Object {
            if (-not (Test-IsPluginCachePath $_.FullName)) {
                $items.Add((Get-RelativePath $_.FullName $RootPath))
            }
        }
    }

    # Local skills/ directory
    $skillsDir = Join-Path $RootPath 'skills'
    if (Test-Path -LiteralPath $skillsDir -PathType Container) {
        Get-ChildItem -LiteralPath $skillsDir -Recurse -File | ForEach-Object {
            if (-not (Test-IsPluginCachePath $_.FullName)) {
                $items.Add((Get-RelativePath $_.FullName $RootPath))
            }
        }
    }

    # .claude/agents/ directory
    $agentsDir = Join-Path $RootPath '.claude' 'agents'
    if (Test-Path -LiteralPath $agentsDir -PathType Container) {
        Get-ChildItem -LiteralPath $agentsDir -Recurse -File | ForEach-Object {
            if (-not (Test-IsPluginCachePath $_.FullName)) {
                $items.Add((Get-RelativePath $_.FullName $RootPath))
            }
        }
    }

    # Project doc tree — Documents/ (if present)
    $docsDir = Join-Path $RootPath 'Documents'
    if (Test-Path -LiteralPath $docsDir -PathType Container) {
        Get-ChildItem -LiteralPath $docsDir -Recurse -File | ForEach-Object {
            if (-not (Test-IsPluginCachePath $_.FullName)) {
                $items.Add((Get-RelativePath $_.FullName $RootPath))
            }
        }
    }

    # Nested CLAUDE.md in subdirectories (not already covered above, excluding cache paths)
    Get-ChildItem -LiteralPath $RootPath -Recurse -Filter 'CLAUDE.md' -File |
        Where-Object {
            $rel = Get-RelativePath $_.FullName $RootPath
            # Skip root CLAUDE.md (already added above)
            $rel -ne 'CLAUDE.md' -and
            # Skip plugin cache paths
            (-not (Test-IsPluginCachePath $_.FullName)) -and
            # Skip node_modules and .git
            ($rel -notmatch '(?i)(^|/)node_modules/') -and
            ($rel -notmatch '(?i)(^|/)\.git/')
        } | ForEach-Object {
            $rel = Get-RelativePath $_.FullName $RootPath
            if ($items -notcontains $rel) {
                $items.Add($rel)
            }
        }

    return $items
}

# ---------------------------------------------------------------------------
# Parse SKILL.md frontmatter (YAML between --- delimiters)
# ---------------------------------------------------------------------------
function Get-SkillFrontmatter {
    param([string]$FilePath)
    try {
        $lines = @(Get-Content -LiteralPath $FilePath -ErrorAction Stop)
        $inFm = $false
        $fmLines = [System.Collections.Generic.List[string]]::new()
        $fmCount = 0
        foreach ($line in $lines) {
            if ($line.Trim() -eq '---') {
                $fmCount++
                if ($fmCount -eq 1) { $inFm = $true; continue }
                if ($fmCount -eq 2) { break }
            }
            if ($inFm) { $fmLines.Add($line) }
        }
        return $fmLines
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Check A2: file line count <= 200 for .md files
# ---------------------------------------------------------------------------
function Invoke-CheckA2 {
    param([System.Collections.Generic.List[string]]$Inventoried, [string]$RootPath, [hashtable]$WaiverMap)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in $Inventoried) {
        # A2 applies only to always-loaded context files (Section A: root context, .claude/rules/, nested CLAUDE.md)
        if (-not ($rel -match '(^|/)CLAUDE\.md$' -or
                  $rel -match '(^|/)AGENTS\.md$' -or
                  $rel -match '(^|/)CLAUDE\.local\.md$' -or
                  $rel -match '(^|/)\.claude/rules/')) { continue }
        if (-not $rel.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $fullPath = Join-Path $RootPath $rel
        $row = [ordered]@{
            check_id = 'A2'
            file     = $rel
            status   = 'pass'
            detail   = ''
        }
        try {
            $lineCount = @(Get-Content -LiteralPath $fullPath -ErrorAction Stop).Count
            if ($lineCount -gt 200) {
                # Check for waiver
                $waiverRef = Get-WaiverRef -WaiverMap $WaiverMap -CheckId 'A2' -RelativePath $rel
                if ($waiverRef) {
                    $row.status     = 'waived'
                    $row.detail     = "File has $lineCount lines (> 200); covered by decision record."
                    $row.waiver_ref = $waiverRef
                } else {
                    $row.status = 'fail'
                    $row.detail = "File has $lineCount lines (limit: 200)."
                }
            } else {
                $row.status = 'pass'
                $row.detail = "File has $lineCount lines."
            }
        } catch {
            $row.status = 'error'
            $row.detail = "Could not read file: $_"
        }
        $rows.Add([pscustomobject]$row)
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Check B2: SKILL.md <= 500 lines
# ---------------------------------------------------------------------------
function Invoke-CheckB2 {
    param([System.Collections.Generic.List[string]]$Inventoried, [string]$RootPath, [hashtable]$WaiverMap)
    $rows = [System.Collections.Generic.List[object]]::new()

    $skillFiles = $Inventoried | Where-Object { $_ -match '(^|/)SKILL\.md$' }

    if (-not $skillFiles) {
        $rows.Add([pscustomobject][ordered]@{
            check_id = 'B2'
            file     = ''
            status   = 'skip'
            detail   = 'no SKILL.md files found in inventoried paths'
        })
        return $rows
    }

    foreach ($rel in $skillFiles) {
        $fullPath = Join-Path $RootPath $rel
        $row = [ordered]@{
            check_id = 'B2'
            file     = $rel
            status   = 'pass'
            detail   = ''
        }
        try {
            $lineCount = @(Get-Content -LiteralPath $fullPath -ErrorAction Stop).Count
            if ($lineCount -gt 500) {
                $waiverRef = Get-WaiverRef -WaiverMap $WaiverMap -CheckId 'B2' -RelativePath $rel
                if ($waiverRef) {
                    $row.status     = 'waived'
                    $row.detail     = "SKILL.md has $lineCount lines (> 500); covered by decision record."
                    $row.waiver_ref = $waiverRef
                } else {
                    $row.status = 'fail'
                    $row.detail = "SKILL.md has $lineCount lines (limit: 500)."
                }
            } else {
                $row.status = 'pass'
                $row.detail = "SKILL.md has $lineCount lines."
            }
        } catch {
            $row.status = 'error'
            $row.detail = "Could not read file: $_"
        }
        $rows.Add([pscustomobject]$row)
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Check B3: skill frontmatter limits
# ---------------------------------------------------------------------------
function Invoke-CheckB3 {
    param([System.Collections.Generic.List[string]]$Inventoried, [string]$RootPath, [hashtable]$WaiverMap)
    $rows = [System.Collections.Generic.List[object]]::new()

    $skillFiles = $Inventoried | Where-Object { $_ -match '(^|/)SKILL\.md$' }
    if (-not $skillFiles) { return $rows }

    foreach ($rel in $skillFiles) {
        $fullPath = Join-Path $RootPath $rel
        $row = [ordered]@{
            check_id = 'B3'
            file     = $rel
            status   = 'pass'
            detail   = ''
        }
        try {
            $fmLines = Get-SkillFrontmatter -FilePath $fullPath
            if ($null -eq $fmLines) {
                $row.status = 'error'
                $row.detail = 'Could not read file.'
                $rows.Add([pscustomobject]$row)
                continue
            }

            $violations = [System.Collections.Generic.List[string]]::new()

            # Extract name and description from frontmatter
            $nameValue = $null
            $descValue = $null
            foreach ($line in $fmLines) {
                if ($line -match '^name:\s*(.*)$') {
                    $nameValue = $Matches[1].Trim()
                    if ($nameValue -match '^"') {
                        $nameValue = $nameValue -replace '^"(.*)"$', '$1'
                    } else {
                        # Strip inline YAML comment (unquoted values only)
                        $nameValue = ($nameValue -split '\s+#')[0].Trim()
                    }
                }
                if ($line -match '^description:\s*(.*)$') {
                    $descValue = $Matches[1].Trim()
                    if ($descValue -match '^"') {
                        $descValue = $descValue -replace '^"(.*)"$', '$1'
                    } else {
                        # Strip inline YAML comment (unquoted values only)
                        $descValue = ($descValue -split '\s+#')[0].Trim()
                    }
                }
            }

            # Check name: must be non-empty and lowercase (no uppercase characters)
            if ($null -eq $nameValue -or $nameValue -eq '') {
                $violations.Add('name field is empty or missing')
            } elseif ($nameValue -cmatch '[A-Z]') {
                $violations.Add("name field contains uppercase characters ('$nameValue')")
            }

            # Check description: must be non-empty
            if ($null -eq $descValue -or $descValue -eq '') {
                $violations.Add('description field is empty or missing')
            }

            if ($violations.Count -gt 0) {
                $row.status = 'fail'
                $row.detail = $violations -join '; '
            } else {
                $row.status = 'pass'
                $row.detail = 'Frontmatter name and description are valid.'
            }
        } catch {
            $row.status = 'error'
            $row.detail = "Could not check frontmatter: $_"
        }
        $rows.Add([pscustomobject]$row)
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Check B5: ToC required in files > 100 lines
# ---------------------------------------------------------------------------
function Invoke-CheckB5 {
    param([System.Collections.Generic.List[string]]$Inventoried, [string]$RootPath, [hashtable]$WaiverMap)
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($rel in $Inventoried) {
        # B5 applies only to skill reference files (Section B: files under skills/)
        if (-not ($rel -match '(^|/)skills/')) { continue }
        if (-not $rel.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $fullPath = Join-Path $RootPath $rel
        $row = [ordered]@{
            check_id = 'B5'
            file     = $rel
            status   = 'pass'
            detail   = ''
        }
        try {
            $lines = @(Get-Content -LiteralPath $fullPath -ErrorAction Stop)
            $lineCount = $lines.Count
            if ($lineCount -le 100) {
                $row.status = 'pass'
                $row.detail = "File has $lineCount lines (ToC not required for <= 100 lines)."
                $rows.Add([pscustomobject]$row)
                continue
            }
            # Check for a ToC: a markdown link to a # anchor, e.g. [something](#anchor)
            $content = $lines -join "`n"
            $hasToc = ($content -match '\[.+\]\(#[^)]+\)') -or ($content -match 'href="#[^"]+')
            if (-not $hasToc) {
                $waiverRef = Get-WaiverRef -WaiverMap $WaiverMap -CheckId 'B5' -RelativePath $rel
                if ($waiverRef) {
                    $row.status     = 'waived'
                    $row.detail     = "File has $lineCount lines but no ToC; covered by decision record."
                    $row.waiver_ref = $waiverRef
                } else {
                    $row.status = 'fail'
                    $row.detail = "File has $lineCount lines but no table of contents (no [text](#anchor) link found)."
                }
            } else {
                $row.status = 'pass'
                $row.detail = "File has $lineCount lines and contains a ToC."
            }
        } catch {
            $row.status = 'error'
            $row.detail = "Could not read file: $_"
        }
        $rows.Add([pscustomobject]$row)
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Check A9: rules files path-scoped
# ---------------------------------------------------------------------------
function Invoke-CheckA9 {
    param([System.Collections.Generic.List[string]]$Inventoried, [string]$RootPath, [hashtable]$WaiverMap)
    $rows = [System.Collections.Generic.List[object]]::new()

    # Find rules files: under .claude/rules/
    $rulesFiles = $Inventoried | Where-Object { $_ -match '(^|/)\.claude/rules/' }

    if (-not $rulesFiles) {
        $rows.Add([pscustomobject][ordered]@{
            check_id = 'A9'
            file     = ''
            status   = 'skip'
            detail   = 'No rules files found in inventoried paths.'
        })
        return $rows
    }

    foreach ($rel in $rulesFiles) {
        $fullPath = Join-Path $RootPath $rel
        $row = [ordered]@{
            check_id = 'A9'
            file     = $rel
            status   = 'pass'
            detail   = ''
        }
        try {
            $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
            # Check for path-scoping indicators: globs: frontmatter field or applyWhen: directive
            $hasScope = ($content -match '(?m)^globs:') -or ($content -match '(?m)^applyWhen:')
            if (-not $hasScope) {
                $waiverRef = Get-WaiverRef -WaiverMap $WaiverMap -CheckId 'A9' -RelativePath $rel
                if ($waiverRef) {
                    $row.status     = 'waived'
                    $row.detail     = "Rules file has no path-scoping directive; covered by decision record."
                    $row.waiver_ref = $waiverRef
                } else {
                    $row.status = 'fail'
                    $row.detail = "Rules file has no globs: or applyWhen: path-scoping directive (loads every session)."
                }
            } else {
                $row.status = 'pass'
                $row.detail = 'Rules file carries a path-scoping directive.'
            }
        } catch {
            $row.status = 'error'
            $row.detail = "Could not read file: $_"
        }
        $rows.Add([pscustomobject]$row)
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

$waiverMap = Get-WaiverMap -DecisionFilePath $resolvedDecisionPath
$inventoried = Get-Inventoried -RootPath $resolvedRoot

# Helper: null-safe append of check rows to the master list
function Add-CheckRows {
    param(
        [System.Collections.Generic.List[object]]$Target,
        [object[]]$Rows
    )
    if ($null -ne $Rows -and $Rows.Count -gt 0) {
        foreach ($r in $Rows) {
            if ($null -ne $r) { $Target.Add($r) }
        }
    }
}

$checks = [System.Collections.Generic.List[object]]::new()
Add-CheckRows -Target $checks -Rows @(Invoke-CheckA2 -Inventoried $inventoried -RootPath $resolvedRoot -WaiverMap $waiverMap)
Add-CheckRows -Target $checks -Rows @(Invoke-CheckB2 -Inventoried $inventoried -RootPath $resolvedRoot -WaiverMap $waiverMap)
Add-CheckRows -Target $checks -Rows @(Invoke-CheckB3 -Inventoried $inventoried -RootPath $resolvedRoot -WaiverMap $waiverMap)
Add-CheckRows -Target $checks -Rows @(Invoke-CheckB5 -Inventoried $inventoried -RootPath $resolvedRoot -WaiverMap $waiverMap)
Add-CheckRows -Target $checks -Rows @(Invoke-CheckA9 -Inventoried $inventoried -RootPath $resolvedRoot -WaiverMap $waiverMap)

$inventoriedArray = @($inventoried)
$checksArray = @($checks)

$output = [ordered]@{
    schema_version  = 1
    scope           = [ordered]@{
        root        = $resolvedRoot
        inventoried = $inventoriedArray
    }
    checks          = $checksArray
    judgment_inputs = [ordered]@{
        b4_link_graph = [ordered]@{}
    }
}

# Output single JSON object to stdout as one pipeline item
# Use -Compress:$false for human-readable output; join ensures single pipeline item
$json = $output | ConvertTo-Json -Depth 10
Write-Output $json

# Handle -FailOn fail exit code
if ($FailOn -eq 'fail') {
    $hasFails = $checks | Where-Object { $_.status -eq 'fail' }
    if ($hasFails) {
        exit 1
    }
}
exit 0
