#Requires -Version 7.0
<#
.SYNOPSIS
    Core library for Antigravity bootstrapping and subagent schema resolution.
#>

function Convert-ToPascalCaseWithHyphens {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    $parts = $Name -split '-'
    $capitalized = foreach ($part in $parts) {
        if ($part.Length -gt 0) {
            $part[0].ToString().ToUpper() + $part.Substring(1)
        }
        else {
            $part
        }
    }
    return $capitalized -join '-'
}

function Get-AntigravitySubagents {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]
    [CmdletBinding()]
    param(
        [string]$RootPath
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    if (-not $RootPath) {
        $RootPath = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }

    $pluginJsonPath = Join-Path -Path $RootPath -ChildPath '.claude-plugin/plugin.json'
    $agentsDir = Join-Path -Path $RootPath -ChildPath 'agents'

    $agentShellPaths = [System.Collections.Generic.List[string]]::new()

    # Attempt to load from .claude-plugin/plugin.json manifest array
    if (Test-Path $pluginJsonPath) {
        try {
            $manifest = Get-Content -Path $pluginJsonPath -Raw | ConvertFrom-Json
            if ($manifest.agents) {
                $canonicalRoot = [System.IO.Path]::GetFullPath($RootPath)
                $separator = [System.IO.Path]::DirectorySeparatorChar
                $canonicalRootWithSeparator = $canonicalRoot
                if (-not $canonicalRoot.EndsWith($separator)) {
                    $canonicalRootWithSeparator = $canonicalRoot + $separator
                }

                foreach ($relativeAgentPath in $manifest.agents) {
                    $combinedPath = Join-Path -Path $RootPath -ChildPath $relativeAgentPath
                    $canonicalAgentPath = [System.IO.Path]::GetFullPath($combinedPath)
                    if (-not $canonicalAgentPath.StartsWith($canonicalRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
                        throw "Path traversal detected in manifest agents list! Agent path must reside inside the repository root."
                    }
                    $absPath = Resolve-Path -LiteralPath $canonicalAgentPath -ErrorAction SilentlyContinue
                    if ($absPath) {
                        $agentShellPaths.Add($absPath.Path)
                    }
                }
            }
        }
        catch {
            if ($_.ToString() -match "Path traversal detected") {
                throw $_
            }
            Write-Warning "Failed to parse plugin.json: $_. Falling back to directory scan."
        }
    }

    # Fallback to scanning agents/ directory for lowercase .md shell files
    if ($agentShellPaths.Count -eq 0) {
        if (Test-Path $agentsDir) {
            $shells = Get-ChildItem -Path $agentsDir -Filter '*.md' -File
            foreach ($shell in $shells) {
                # Shell files are lowercase (e.g. code-smith.md)
                # Paired bodies are PascalCase with .agent.md extension (e.g. Code-Smith.agent.md)
                if ($shell.Name -notlike '*.agent.md' -and $shell.Name -match '^[a-z]') {
                    # Verify that the lowercase .md file is actually a valid agent shell by reading its first 20 lines
                    $firstLines = Get-Content -Path $shell.FullName -TotalCount 20 -ErrorAction SilentlyContinue
                    if ($firstLines -and $firstLines.Count -gt 0 -and $firstLines[0].Trim() -eq '---') {
                        $hasNameField = $false
                        for ($i = 1; $i -lt $firstLines.Count; $i++) {
                            $trimmedLine = $firstLines[$i].Trim()
                            if ($trimmedLine -eq '---') {
                                # Closing delimiter reached
                                break
                            }
                            # Check if line contains a name: field
                            if ($trimmedLine -match '^\s*name\s*:') {
                                $hasNameField = $true
                            }
                        }
                        if ($hasNameField) {
                            $agentShellPaths.Add($shell.FullName)
                        }
                    }
                }
            }
        }
    }

    $subagents = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($shellPath in $agentShellPaths) {
        $shellContent = Get-Content -Path $shellPath -Raw

        # Simple YAML Frontmatter parsing
        $frontmatter = @{}
        $lines = $shellContent -split '\r?\n'
        $inFrontmatter = $false
        $frontmatterDelimiterCount = 0
        $bodyLines = [System.Collections.Generic.List[string]]::new()

        foreach ($line in $lines) {
            if ($line -eq '---') {
                $frontmatterDelimiterCount++
                if ($frontmatterDelimiterCount -eq 1) {
                    $inFrontmatter = $true
                    continue
                }
                elseif ($frontmatterDelimiterCount -eq 2) {
                    $inFrontmatter = $false
                    continue
                }
            }
            if ($inFrontmatter) {
                $trimmedLine = $line.Trim()
                if ($trimmedLine.StartsWith('#')) {
                    continue
                }
                # Strip inline comments
                $lineToParse = $line
                if ($line -match '^(.*?)\s+#.*$') {
                    $lineToParse = $Matches[1]
                }

                if ($lineToParse -match '^\s*([^:]+)\s*:\s*(.*)\s*$') {
                    $key = $Matches[1].Trim()
                    $val = $Matches[2].Trim()

                    # Correct quote stripping: check if the value starts and ends with double quotes, OR starts and ends with single quotes, and strip them only if they match (prevent mismatched quote bugs).
                    if (($val.StartsWith('"') -and $val.EndsWith('"') -and $val.Length -ge 2) -or
                        ($val.StartsWith("'") -and $val.EndsWith("'") -and $val.Length -ge 2)) {
                        $val = $val.Substring(1, $val.Length - 2)
                    }

                    # Also strip surrounding brackets [...] for inline arrays
                    if ($val.StartsWith('[') -and $val.EndsWith(']') -and $val.Length -ge 2) {
                        $val = $val.Substring(1, $val.Length - 2).Trim()
                    }

                    $frontmatter[$key] = $val
                }
            }
            else {
                $bodyLines.Add($line)
            }
        }

        $shellBody = $bodyLines -join "`n"

        # Resolve properties
        $name = $frontmatter['name']
        if (-not $name) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($shellPath)
        }
        $description = $frontmatter['description']
        if (-not $description) {
            $description = "Specialist role for $name"
        }

        # Resolve matching PascalCase .agent.md body
        $pascalName = Convert-ToPascalCaseWithHyphens -Name $name
        $bodyFileName = "$pascalName.agent.md"

        $bodyPath = $null
        if (Test-Path $agentsDir) {
            $bodyFiles = Get-ChildItem -Path $agentsDir -Filter '*.agent.md' -File
            foreach ($file in $bodyFiles) {
                if ($file.Name.Equals($bodyFileName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $bodyPath = $file.FullName
                    break
                }
            }
        }

        $bodyContent = ""
        if ($bodyPath) {
            $bodyContent = Get-Content -Path $bodyPath -Raw
        }
        else {
            Write-Warning "Could not find canonical agent body at: $(Join-Path -Path $agentsDir -ChildPath $bodyFileName)"
        }

        # Build unified system prompt
        $unifiedPromptBuilder = [System.Text.StringBuilder]::new()
        [void]$unifiedPromptBuilder.AppendLine("# Thin-Shell Instructions ($name)")
        [void]$unifiedPromptBuilder.AppendLine()
        [void]$unifiedPromptBuilder.AppendLine($shellBody.Trim())
        if ($bodyContent) {
            [void]$unifiedPromptBuilder.AppendLine()
            [void]$unifiedPromptBuilder.AppendLine("# Canonical Shared Agent Body ($bodyFileName)")
            [void]$unifiedPromptBuilder.AppendLine()
            [void]$unifiedPromptBuilder.AppendLine($bodyContent.Trim())
        }
        $combinedPrompt = $unifiedPromptBuilder.ToString().Trim()

        # Parse tools to extract capability flags
        $toolsList = @()
        if ($frontmatter.ContainsKey('tools')) {
            $toolsList = @($frontmatter['tools'] -split ',' | ForEach-Object {
                $t = $_.Trim()
                if (($t.StartsWith('"') -and $t.EndsWith('"') -and $t.Length -ge 2) -or
                    ($t.StartsWith("'") -and $t.EndsWith("'") -and $t.Length -ge 2)) {
                    $t = $t.Substring(1, $t.Length - 2)
                }
                $t.Trim()
            })
        }

        # Determine capabilities
        $enableWriteTools = $null
        if ($frontmatter.ContainsKey('enable-write-tools')) {
            $rawVal = $frontmatter['enable-write-tools']
            $enableWriteTools = ($rawVal -eq 'true' -or $rawVal -eq $true)
        }
        elseif ($frontmatter.ContainsKey('enable_write_tools')) {
            $rawVal = $frontmatter['enable_write_tools']
            $enableWriteTools = ($rawVal -eq 'true' -or $rawVal -eq $true)
        }

        if ($null -eq $enableWriteTools) {
            # Fallback logic: do NOT auto-elevate based on Bash
            $enableWriteTools = ($toolsList -contains 'Write' -or $toolsList -contains 'Edit')
        }

        $enableSubagentTools = $null
        if ($frontmatter.ContainsKey('enable-subagent-tools')) {
            $rawVal = $frontmatter['enable-subagent-tools']
            $enableSubagentTools = ($rawVal -eq 'true' -or $rawVal -eq $true)
        }
        elseif ($frontmatter.ContainsKey('enable_subagent_tools')) {
            $rawVal = $frontmatter['enable_subagent_tools']
            $enableSubagentTools = ($rawVal -eq 'true' -or $rawVal -eq $true)
        }

        if ($null -eq $enableSubagentTools) {
            # Fallback logic
            $enableSubagentTools = ($toolsList -contains 'Agent')
        }

        $subagents.Add([PSCustomObject]@{
            name                  = $name
            description           = $description
            system_prompt         = $combinedPrompt
            enable_write_tools    = $enableWriteTools
            enable_subagent_tools = $enableSubagentTools
        })
    }

    return $subagents
}
