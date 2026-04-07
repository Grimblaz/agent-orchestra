#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 RED-phase tests for Invoke-QuickValidate.

.DESCRIPTION
    Contract under test:
      Invoke-QuickValidate consolidates the 9 structural checks from the
      quick-validate section of copilot-instructions.md into a single
      callable function.

      Checks:
        1. Plan-Architect legacy reference
        2. Janitor legacy reference
        3. Issue-Designer legacy reference
        4. workflow-template legacy reference
        5. SKILL.md 'Use when/before' in description
        6. SKILL.md 'DO NOT USE FOR:' in description
        7. SKILL.md '## Gotchas' heading
        8. measure-guidance-complexity agents_over_ceiling
        9. PSScriptAnalyzer

      Return value:
        .Results    — array of per-check objects with Name, Passed, Detail
        .PassCount  — count of passed checks
        .FailCount  — count of failed checks
        .TotalCount — total checks run
        .ExitCode   — 0 if all passed, 1 if any failed

    Isolation: all tests use TestDrive:\ fixture directories. No real
    .github files are scanned.
#>

Describe 'Invoke-QuickValidate' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot '.github\scripts\lib\quick-validate-core.ps1'
        . $script:LibFile

        # ---------------------------------------------------------------
        # Helper: build a minimal valid fixture tree under TestDrive:\
        # Includes .github\agents, .github\skills\test-skill, .github\scripts
        # All files pass every check by default.
        # ---------------------------------------------------------------
        $script:NewFixture = {
            param([string]$Root = "TestDrive:\qv-$([System.Guid]::NewGuid().ToString('N'))")

            $agentsDir = Join-Path $Root '.github\agents'
            $skillDir = Join-Path $Root '.github\skills\test-skill'
            $scriptsDir = Join-Path $Root '.github\scripts'

            New-Item -ItemType Directory -Path $agentsDir  -Force | Out-Null
            New-Item -ItemType Directory -Path $skillDir   -Force | Out-Null
            New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

            # Clean agent file (no legacy references)
            Set-Content -Path (Join-Path $agentsDir 'clean-agent.agent.md') -Value @'
---
name: clean-agent
description: A clean agent with no legacy terms.
---

# Clean Agent

This agent does nothing special.
'@ -Encoding UTF8

            # Valid SKILL.md with all required frontmatter and section
            Set-Content -Path (Join-Path $skillDir 'SKILL.md') -Value @'
---
name: test-skill
description: Test skill. Use when testing fixtures. DO NOT USE FOR: production.
---

# Test Skill

Content here.

## Gotchas

None.
'@ -Encoding UTF8

            # Trivial script for PSScriptAnalyzer scanning
            Set-Content -Path (Join-Path $scriptsDir 'placeholder.ps1') -Value @'
# Empty placeholder
Write-Output 'ok'
'@ -Encoding UTF8

            return $Root
        }

        # ---------------------------------------------------------------
        # Helper: create mock guidance-complexity script that returns
        # a specified agents_over_ceiling array.
        # ---------------------------------------------------------------
        $script:NewMockComplexityScript = {
            param(
                [string]$Dir,
                [string[]]$AgentsOverCeiling = @()
            )
            $path = Join-Path $Dir 'mock-measure-guidance-complexity.ps1'
            $jsonAgents = ($AgentsOverCeiling | ForEach-Object { "{`"name`":`"$_`"}" }) -join ','
            $jsonBody = "{`"agents_over_ceiling`":[$jsonAgents]}"
            Set-Content -Path $path -Value "Write-Output '$jsonBody'" -Encoding UTF8
            return $path
        }

        # ---------------------------------------------------------------
        # Helper: create a PSScriptAnalyzer settings file placeholder.
        # ---------------------------------------------------------------
        $script:NewMockPSASettings = {
            param([string]$Dir)
            $path = Join-Path $Dir 'PSScriptAnalyzerSettings.psd1'
            Set-Content -Path $path -Value "@{ IncludeRules = @() }" -Encoding UTF8
            return $path
        }
    }

    # ==================================================================
    # Legacy reference checks (1-4)
    # ==================================================================
    Context 'legacy reference checks' {

        It 'reports PASS when no legacy references exist' {
            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()
            $mockSettings = & $script:NewMockPSASettings -Dir $root

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -PSScriptAnalyzerSettingsPath $mockSettings `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $legacyChecks = $result.Results | Where-Object {
                $_.Name -in @('Plan-Architect', 'Janitor', 'Issue-Designer', 'workflow-template')
            }
            $legacyChecks | ForEach-Object {
                $_.Passed | Should -BeTrue -Because "$($_.Name) check should pass with clean fixture"
            }
        }

        It 'reports FAIL when Plan-Architect reference found' {
            $root = & $script:NewFixture
            $agentFile = Join-Path $root '.github\agents\tainted.agent.md'
            Set-Content -Path $agentFile -Value 'Delegate to Plan-Architect for planning.' -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'Plan-Architect' }
            $check.Passed | Should -BeFalse -Because 'fixture contains a Plan-Architect reference'
            $check.Detail | Should -Match 'tainted\.agent\.md' -Because 'detail should identify the offending file'
        }

        It 'reports FAIL when Janitor reference found' {
            $root = & $script:NewFixture
            $skillFile = Join-Path $root '.github\skills\test-skill\SKILL.md'
            # Overwrite with content that still passes SKILL frontmatter checks but has Janitor
            Set-Content -Path $skillFile -Value @'
---
name: test-skill
description: Test skill. Use when testing. DO NOT USE FOR: nothing.
---

# Test Skill

Hand off to Janitor.

## Gotchas

None.
'@ -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'Janitor' }
            $check.Passed | Should -BeFalse -Because 'fixture contains a Janitor reference'
        }

        It 'reports FAIL when Issue-Designer reference found' {
            $root = & $script:NewFixture
            $agentFile = Join-Path $root '.github\agents\bad.agent.md'
            Set-Content -Path $agentFile -Value 'Route to Issue-Designer.' -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'Issue-Designer' }
            $check.Passed | Should -BeFalse -Because 'fixture contains an Issue-Designer reference'
        }

        It 'reports FAIL when workflow-template reference found' {
            $root = & $script:NewFixture
            $agentFile = Join-Path $root '.github\agents\bad.agent.md'
            Set-Content -Path $agentFile -Value 'Uses the workflow-template pattern.' -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'workflow-template' }
            $check.Passed | Should -BeFalse -Because 'fixture contains a workflow-template reference'
        }

        It 'excludes copilot-instructions.md from legacy reference checks' {
            $root = & $script:NewFixture
            $ciFile = Join-Path $root '.github\copilot-instructions.md'
            Set-Content -Path $ciFile -Value 'Plan-Architect is mentioned here for documentation.' -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'Plan-Architect' }
            $check.Passed | Should -BeTrue -Because 'copilot-instructions.md is excluded from legacy reference scanning'
        }

        It 'excludes architecture-rules.md from legacy reference checks' {
            $root = & $script:NewFixture
            $arFile = Join-Path $root '.github\architecture-rules.md'
            Set-Content -Path $arFile -Value 'Plan-Architect mentioned in architecture rules.' -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'Plan-Architect' }
            $check.Passed | Should -BeTrue -Because 'architecture-rules.md is excluded from legacy reference scanning'
        }

        It 'excludes setup.prompt.md from workflow-template check' {
            $root = & $script:NewFixture
            $promptFile = Join-Path $root '.github\prompts\setup.prompt.md'
            New-Item -ItemType Directory -Path (Split-Path $promptFile) -Force | Out-Null
            Set-Content -Path $promptFile -Value 'Clone the workflow-template repo.' -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'workflow-template' }
            $check.Passed | Should -BeTrue -Because 'setup.prompt is excluded from workflow-template scanning'
        }
    }

    # ==================================================================
    # SKILL.md frontmatter checks (5-7)
    # ==================================================================
    Context 'SKILL.md frontmatter checks' {

        It 'reports PASS when all SKILL.md files have required frontmatter' {
            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $skillChecks = $result.Results | Where-Object {
                $_.Name -in @('SKILL-UseWhen', 'SKILL-DoNotUseFor', 'SKILL-Gotchas')
            }
            $skillChecks | ForEach-Object {
                $_.Passed | Should -BeTrue -Because "$($_.Name) should pass with valid SKILL.md fixture"
            }
        }

        It 'reports FAIL when SKILL.md missing Use when/before in description' {
            $root = & $script:NewFixture
            $skillFile = Join-Path $root '.github\skills\test-skill\SKILL.md'
            Set-Content -Path $skillFile -Value @'
---
name: test-skill
description: Test skill that does stuff. DO NOT USE FOR: production.
---

# Test Skill

## Gotchas

None.
'@ -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'SKILL-UseWhen' }
            $check.Passed | Should -BeFalse -Because 'SKILL.md is missing Use when/before in description'
            $check.Detail | Should -Match 'SKILL\.md' -Because 'detail should identify the offending file'
        }

        It 'reports FAIL when SKILL.md missing DO NOT USE FOR: in description' {
            $root = & $script:NewFixture
            $skillFile = Join-Path $root '.github\skills\test-skill\SKILL.md'
            Set-Content -Path $skillFile -Value @'
---
name: test-skill
description: Test skill. Use when testing.
---

# Test Skill

## Gotchas

None.
'@ -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'SKILL-DoNotUseFor' }
            $check.Passed | Should -BeFalse -Because 'SKILL.md is missing DO NOT USE FOR: in description'
        }

        It 'reports FAIL when SKILL.md missing ## Gotchas heading' {
            $root = & $script:NewFixture
            $skillFile = Join-Path $root '.github\skills\test-skill\SKILL.md'
            Set-Content -Path $skillFile -Value @'
---
name: test-skill
description: Test skill. Use when testing. DO NOT USE FOR: prod.
---

# Test Skill

No gotchas section here.
'@ -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'SKILL-Gotchas' }
            $check.Passed | Should -BeFalse -Because 'SKILL.md is missing ## Gotchas heading'
        }
    }

    # ==================================================================
    # Guidance complexity check (8)
    # ==================================================================
    Context 'guidance complexity check' {

        It 'reports PASS when no agents over ceiling' {
            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'GuidanceComplexity' }
            $check.Passed | Should -BeTrue -Because 'mock returns empty agents_over_ceiling'
        }

        It 'reports FAIL when agents over ceiling' {
            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @('Over-Agent')

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'GuidanceComplexity' }
            $check.Passed | Should -BeFalse -Because 'mock returns a non-empty agents_over_ceiling array'
            $check.Detail | Should -Match 'Over-Agent' -Because 'detail should name the offending agent'
        }

        It 'reports FAIL with Error detail when script outputs invalid JSON and subsequent checks still run' {
            $root = & $script:NewFixture
            $badScript = Join-Path $root 'mock-bad-complexity.ps1'
            Set-Content -Path $badScript -Value "Write-Output 'not json'" -Encoding UTF8

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $badScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            # 1. GuidanceComplexity should FAIL
            $check = $result.Results | Where-Object { $_.Name -eq 'GuidanceComplexity' }
            $check.Passed | Should -BeFalse -Because 'invalid JSON output should cause the check to fail'
            # 2. Detail should contain Error: from the catch block
            $check.Detail | Should -Match 'Error:' -Because 'catch block prefixes error message with Error:'
            # 3. Subsequent checks still ran (PSScriptAnalyzer result exists)
            $psaCheck = $result.Results | Where-Object { $_.Name -eq 'PSScriptAnalyzer' }
            $psaCheck | Should -Not -BeNullOrEmpty -Because 'checks after GuidanceComplexity should still execute'
        }
    }

    # ==================================================================
    # PSScriptAnalyzer check (9)
    # ==================================================================
    Context 'PSScriptAnalyzer check' {

        It 'reports SKIP when PSScriptAnalyzer not installed' {
            # Mock Get-Module to simulate PSScriptAnalyzer not being available
            Mock Get-Module { return $null } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' -and $ListAvailable }

            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'PSScriptAnalyzer' }
            $check.Passed | Should -Be 'SKIP' -Because 'PSScriptAnalyzer is not installed; check should be skipped, not passed or failed'
            $result.ExitCode | Should -Be 0 -Because 'SKIP should not poison the exit code when all other checks pass'
            $result.SkipCount | Should -Be 1 -Because 'exactly one check (PSScriptAnalyzer) is skipped'
        }

        It 'reports PASS when PSScriptAnalyzer finds no issues' {
            # Mock Get-Module to simulate PSScriptAnalyzer being available
            Mock Get-Module { return @{ Name = 'PSScriptAnalyzer'; Version = '1.22.0' } } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' -and $ListAvailable }
            Mock Invoke-ScriptAnalyzer { return @() }

            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()
            $mockSettings = & $script:NewMockPSASettings -Dir $root

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -PSScriptAnalyzerSettingsPath $mockSettings `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'PSScriptAnalyzer' }
            $check.Passed | Should -BeTrue -Because 'PSScriptAnalyzer found no issues'
        }

        It 'reports FAIL when PSScriptAnalyzer finds issues' {
            # Mock Get-Module to simulate PSScriptAnalyzer being available
            Mock Get-Module { return @{ Name = 'PSScriptAnalyzer'; Version = '1.22.0' } } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' -and $ListAvailable }
            Mock Invoke-ScriptAnalyzer {
                return @(
                    [PSCustomObject]@{ RuleName = 'PSAvoidUsingCmdletAliases'; ScriptName = 'bad.ps1'; Line = 5 },
                    [PSCustomObject]@{ RuleName = 'PSUseDeclaredVarsMoreThanAssignments'; ScriptName = 'bad.ps1'; Line = 12 }
                )
            }

            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()
            $mockSettings = & $script:NewMockPSASettings -Dir $root

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -PSScriptAnalyzerSettingsPath $mockSettings `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $check = $result.Results | Where-Object { $_.Name -eq 'PSScriptAnalyzer' }
            $check.Passed | Should -BeFalse -Because 'PSScriptAnalyzer found 2 issues'
            $check.Detail | Should -Match '2' -Because 'detail should indicate the number of issues found'
        }
    }

    # ==================================================================
    # Summary / overall behavior
    # ==================================================================
    Context 'summary and return structure' {

        It 'returns ExitCode 0 when all checks pass' {
            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            # Mock PSScriptAnalyzer as installed with no issues
            Mock Get-Module { return @{ Name = 'PSScriptAnalyzer'; Version = '1.22.0' } } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' -and $ListAvailable }
            Mock Invoke-ScriptAnalyzer { return @() }

            $mockSettings = & $script:NewMockPSASettings -Dir $root

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -PSScriptAnalyzerSettingsPath $mockSettings `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $result.ExitCode | Should -Be 0 -Because 'all checks pass in a clean fixture'
        }

        It 'returns ExitCode 1 when any check fails' {
            $root = & $script:NewFixture
            # Inject a single legacy reference to cause one failure
            $agentFile = Join-Path $root '.github\agents\tainted.agent.md'
            Set-Content -Path $agentFile -Value 'See Plan-Architect for details.' -Encoding UTF8

            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $result.ExitCode | Should -Be 1 -Because 'at least one check failed (Plan-Architect reference)'
        }

        It 'writes summary line Quick-validate: N/M checks passed to output' {
            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            # Capture Write-Host output via -InformationVariable
            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts') `
                -InformationVariable infoOutput

            $summaryLine = ($infoOutput | Out-String) + ($result | Out-String)
            # The function should write exactly one summary line matching this pattern
            $summaryLine | Should -Match 'Quick-validate: \d+/\d+ checks passed' `
                -Because 'function must write a summary line indicating pass/total counts'
        }

        It 'returns structured Results array with per-check details' {
            $root = & $script:NewFixture
            $mockScript = & $script:NewMockComplexityScript -Dir $root -AgentsOverCeiling @()

            $result = Invoke-QuickValidate `
                -RootPath $root `
                -GuidanceComplexityScriptPath $mockScript `
                -ScriptsPath (Join-Path $root '.github\scripts')

            $result.Results | Should -Not -BeNullOrEmpty -Because 'Results array must be populated'
            $result.TotalCount | Should -BeGreaterOrEqual 9 -Because 'there are at least 9 structural checks'
            $result.PassCount | Should -BeOfType [int]
            $result.FailCount | Should -BeOfType [int]
            ($result.PassCount + $result.FailCount) | Should -BeLessOrEqual $result.TotalCount `
                -Because 'pass + fail should not exceed total (SKIP results are neither)'

            # Each result should have the expected shape
            $result.Results | ForEach-Object {
                $_ | Should -Not -BeNullOrEmpty
                $_.Name | Should -Not -BeNullOrEmpty -Because 'every check result must have a Name'
                # Passed should be $true, $false, or 'SKIP'
                $_.PSObject.Properties.Name | Should -Contain 'Passed' -Because 'every check result must have a Passed property'
                $_.PSObject.Properties.Name | Should -Contain 'Detail' -Because 'every check result must have a Detail property'
            }
        }
    }
}
