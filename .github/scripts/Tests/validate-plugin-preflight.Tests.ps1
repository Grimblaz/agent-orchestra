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

        # Helper: build a minimal valid fixture with plugin.json at the repo root,
        # an agents directory, and a set of skill directories. Paths in the manifest
        # are relative to the manifest's directory (repo root), so fixtures use ./X.
        $script:NewFixture = {
            param(
                [string]$Root = "TestDrive:\pf-$([System.Guid]::NewGuid().ToString('N'))",
                [int]$AgentCount = 14,
                [int]$SkillCount = 39,
                [switch]$Placeholders,
                [switch]$IncludeUnsupportedCommandsField
            )

            $agentsDir = Join-Path $Root 'agents'
            $skillsRoot = Join-Path $Root 'skills'

            New-Item -ItemType Directory -Path $Root        -Force | Out-Null
            New-Item -ItemType Directory -Path $agentsDir   -Force | Out-Null
            New-Item -ItemType Directory -Path $skillsRoot  -Force | Out-Null

            for ($i = 1; $i -le $AgentCount; $i++) {
                Set-Content -Path (Join-Path $agentsDir "agent-$i.agent.md") -Value "# Agent $i" -Encoding UTF8
            }

            $skillEntries = [System.Collections.Generic.List[string]]::new()
            for ($i = 1; $i -le $SkillCount; $i++) {
                $skillName = "skill-$i"
                New-Item -ItemType Directory -Path (Join-Path $skillsRoot $skillName) -Force | Out-Null
                $skillEntries.Add("  `"./skills/$skillName/`"")
            }

            $authorName = if ($Placeholders) { 'YOUR-ORG' } else { 'Grimblaz' }
            $repoUrl = if ($Placeholders) { 'https://github.com/YOUR-ORG/YOUR-REPO' } else { 'https://github.com/Grimblaz/agent-orchestra' }

            $commandsBlock = if ($IncludeUnsupportedCommandsField) {
                ",`n  `"commands`": [`"./prompts/example.prompt.md`"]"
            }
            else { '' }

            $pluginJson = @"
{
  "name": "agent-orchestra",
  "version": "1.13.0",
  "author": { "name": "$authorName" },
  "repository": "$repoUrl",
  "agents": ["./agents/"],
  "skills": [
$($skillEntries -join ",`n")
  ]$commandsBlock
}
"@
            Set-Content -Path (Join-Path $Root 'plugin.json') -Value $pluginJson -Encoding UTF8

            return $Root
        }
    }

    # ==================================================================
    # plugin.json exists / parses
    # ==================================================================
    Context 'plugin.json discovery' {

        It 'reports PASS when plugin.json exists and parses' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root 'plugin.json'
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
            $pjPath = Join-Path $root 'plugin.json'
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
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'PlaceholdersReplaced' }
            $check.Passed | Should -BeTrue
        }

        It 'reports FAIL when placeholder YOUR-ORG remains' {
            $root = & $script:NewFixture -Placeholders
            $pjPath = Join-Path $root 'plugin.json'
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
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            ($result.Results | Where-Object { $_.Name -eq 'AgentPathsExist' }).Passed | Should -BeTrue
            ($result.Results | Where-Object { $_.Name -eq 'AgentCount' }).Passed | Should -BeTrue
        }

        It 'reports FAIL AgentCount when fewer than 14 agents on disk' {
            $root = & $script:NewFixture -AgentCount 12
            $pjPath = Join-Path $root 'plugin.json'
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
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            ($result.Results | Where-Object { $_.Name -eq 'SkillPathsExist' }).Passed | Should -BeTrue
            ($result.Results | Where-Object { $_.Name -eq 'SkillCountMatch' }).Passed | Should -BeTrue
        }

        It 'reports FAIL SkillCountMatch when filesystem has more skills than plugin.json' {
            $root = & $script:NewFixture -SkillCount 39
            New-Item -ItemType Directory -Path (Join-Path $root 'skills\extra-skill') -Force | Out-Null
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'SkillCountMatch' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match '40'
        }

        It 'reports FAIL SkillPathsExist when a declared skill directory is missing' {
            $root = & $script:NewFixture
            Remove-Item -Path (Join-Path $root 'skills\skill-5') -Recurse -Force
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'SkillPathsExist' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match 'skill-5'
        }
    }

    # ==================================================================
    # Unsupported-field guard
    # ==================================================================
    Context 'NoUnsupportedFields guard' {

        It 'reports PASS when no unsupported fields are declared' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'NoUnsupportedFields' }
            $check.Passed | Should -BeTrue
        }

        It 'reports FAIL when manifest declares the silently-ignored `commands` field' {
            $root = & $script:NewFixture -IncludeUnsupportedCommandsField
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $check = $result.Results | Where-Object { $_.Name -eq 'NoUnsupportedFields' }
            $check.Passed | Should -BeFalse
            $check.Detail | Should -Match 'commands'
        }
    }

    # ==================================================================
    # Exit code and summary
    # ==================================================================
    Context 'exit code and return structure' {

        It 'returns ExitCode 0 when all checks pass' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $result.ExitCode | Should -Be 0
        }

        It 'returns ExitCode 1 when any check fails' {
            $root = & $script:NewFixture -Placeholders
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $result.ExitCode | Should -Be 1
        }

        It 'returns structured Results with Name, Passed, Detail on every entry' {
            $root = & $script:NewFixture
            $pjPath = Join-Path $root 'plugin.json'
            $result = Invoke-PluginPreflight -RootPath $root -PluginJsonPath $pjPath
            $result.Results | ForEach-Object {
                $_.PSObject.Properties.Name | Should -Contain 'Name'
                $_.PSObject.Properties.Name | Should -Contain 'Passed'
                $_.PSObject.Properties.Name | Should -Contain 'Detail'
            }
        }
    }
}
