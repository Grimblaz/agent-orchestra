#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for Invoke-PluginPreflight.
#>

Describe 'Invoke-PluginPreflight' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github\scripts\lib\validate-plugin-preflight-core.ps1'
        . $script:LibFile

        # Helper: build a minimal valid fixture with plugin.json, agents dir, skills dirs, and command files.
        $script:NewFixture = {
            param(
                [string]$Root = "TestDrive:\pf-$([System.Guid]::NewGuid().ToString('N'))",
                [int]$AgentCount = 14,
                [int]$SkillCount = 39,
                [int]$CommandCount = 9,
                [switch]$Placeholders
            )

            $pluginDir = Join-Path $Root '.github\plugin'
            $agentsDir = Join-Path $Root '.github\agents'
            $skillsRoot = Join-Path $Root '.github\skills'
            $promptsDir = Join-Path $Root '.github\prompts'

            New-Item -ItemType Directory -Path $pluginDir  -Force | Out-Null
            New-Item -ItemType Directory -Path $agentsDir  -Force | Out-Null
            New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $promptsDir -Force | Out-Null

            # Create agent files
            for ($i = 1; $i -le $AgentCount; $i++) {
                Set-Content -Path (Join-Path $agentsDir "agent-$i.agent.md") -Value "# Agent $i" -Encoding UTF8
            }

            # Create skill directories. Paths in plugin.json are relative to the manifest's
            # directory (.github/plugin/), so we use ../skills/... not ./.github/skills/...
            $skillEntries = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -le $SkillCount; $i++) {
                $skillName = "skill-$i"
                New-Item -ItemType Directory -Path (Join-Path $skillsRoot $skillName) -Force | Out-Null
                $skillEntries.Add("  `"../skills/$skillName/`"")
            }

            # Create command files
            $commandEntries = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -le $CommandCount; $i++) {
                $promptName = "cmd-$i.prompt.md"
                Set-Content -Path (Join-Path $promptsDir $promptName) -Value "# Prompt $i" -Encoding UTF8
                $commandEntries.Add("  `"../prompts/$promptName`"")
            }

            $authorName = if ($Placeholders) { 'YOUR-ORG' } else { 'Grimblaz' }
            $repoUrl = if ($Placeholders) { 'https://github.com/YOUR-ORG/YOUR-REPO' } else { 'https://github.com/Grimblaz/copilot-orchestra' }

            $pluginJson = @"
{
  "name": "copilot-orchestra",
  "version": "1.12.0",
  "author": { "name": "$authorName" },
  "repository": "$repoUrl",
  "agents": ["../agents/"],
  "skills": [
$($skillEntries -join ",`n")
  ],
  "commands": [
$($commandEntries -join ",`n")
  ]
}
"@
            Set-Content -Path (Join-Path $pluginDir 'plugin.json') -Value $pluginJson -Encoding UTF8

            return $Root
        }
    }

    # ==================================================================
    # plugin.json exists / parses
    # ==================================================================
    Context 'plugin.json discovery' {

        It 'reports PASS when plugin.json exists and parses' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'PluginJsonExists' }
            $check.Passed | Should -BeTrue
        }

        It 'reports FAIL when plugin.json is missing' {
            $root = & $script:NewFixture
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath (Join-Path $root 'missing.json')
            $check = $result.Results | Where-Object { $_.Name -eq 'PluginJsonExists' }
            $check.Passed | Should -BeFalse
        }

        It 'reports FAIL with parse error detail when plugin.json is malformed JSON' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            Set-Content -Path $pjPath -Value '{ "name": "broken"' -Encoding UTF8
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'PluginJsonExists' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match 'Parse error'
            $result.Results.Count | Should -Be 1
            $result.ExitCode | Should -Be 1
        }
    }

    # ==================================================================
    # Placeholder check
    # ==================================================================
    Context 'placeholder replacement' {

        It 'reports PASS when author and repository have real values' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'PlaceholdersReplaced' }
            $check.Passed | Should -BeTrue
        }

        It 'reports FAIL when placeholder YOUR-ORG remains' {
            $root = & $script:NewFixture -Placeholders
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'PlaceholdersReplaced' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match 'YOUR'
        }
    }

    # ==================================================================
    # Agent path and count
    # ==================================================================
    Context 'agent validation' {

        It 'reports PASS when agent directory exists and has 14 agents' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            ($result.Results | Where-Object { $_.Name -eq 'AgentPathsExist' }).Passed | Should -BeTrue
            ($result.Results | Where-Object { $_.Name -eq 'AgentCount' }).Passed | Should -BeTrue
        }

        It 'reports FAIL AgentCount when fewer than 14 agents on disk' {
            $root = & $script:NewFixture -AgentCount 12
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'AgentCount' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match '12'
        }
    }

    # ==================================================================
    # Skill path and count
    # ==================================================================
    Context 'skill validation' {

        It 'reports PASS when all 39 skill paths exist and counts match' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            ($result.Results | Where-Object { $_.Name -eq 'SkillPathsExist' }).Passed | Should -BeTrue
            ($result.Results | Where-Object { $_.Name -eq 'SkillCountMatch' }).Passed | Should -BeTrue
        }

        It 'reports FAIL SkillCountMatch when filesystem has more skills than plugin.json' {
            $root = & $script:NewFixture -SkillCount 39
            # Add an extra skill directory not in plugin.json
            New-Item -ItemType Directory -Path (Join-Path $root '.github\skills\extra-skill') -Force | Out-Null
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'SkillCountMatch' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match '40'
        }

        It 'reports FAIL SkillPathsExist when a declared skill directory is missing' {
            $root = & $script:NewFixture
            # Remove one skill directory that plugin.json references
            Remove-Item -Path (Join-Path $root '.github\skills\skill-5') -Recurse -Force
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'SkillPathsExist' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match 'skill-5'
        }
    }

    # ==================================================================
    # Command path and count
    # ==================================================================
    Context 'command validation' {

        It 'reports PASS when all 9 command paths exist and count is 9' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            ($result.Results | Where-Object { $_.Name -eq 'CommandPathsExist' }).Passed | Should -BeTrue
            ($result.Results | Where-Object { $_.Name -eq 'CommandCount' }).Passed | Should -BeTrue
        }

        It 'reports FAIL CommandCount when plugin.json declares more than 9 commands' {
            $root = & $script:NewFixture -CommandCount 10
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'CommandCount' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match '10'
        }

        It 'reports FAIL CommandPathsExist when a declared command file is missing' {
            $root = & $script:NewFixture
            Remove-Item -Path (Join-Path $root '.github\prompts\cmd-3.prompt.md') -Force
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'CommandPathsExist' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match 'cmd-3'
        }
    }

    # ==================================================================
    # Exit code and summary
    # ==================================================================
    Context 'exit code and return structure' {

        It 'returns ExitCode 0 when all checks pass' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $result.ExitCode | Should -Be 0
        }

        It 'returns ExitCode 1 when any check fails' {
            $root = & $script:NewFixture -Placeholders
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $result.ExitCode | Should -Be 1
        }

        It 'returns structured Results with Name, Passed, Detail on every entry' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root '.github\plugin\plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $result.Results | ForEach-Object {
                $_.PSObject.Properties.Name | Should -Contain 'Name'
                $_.PSObject.Properties.Name | Should -Contain 'Passed'
                $_.PSObject.Properties.Name | Should -Contain 'Detail'
            }
        }
    }
}
