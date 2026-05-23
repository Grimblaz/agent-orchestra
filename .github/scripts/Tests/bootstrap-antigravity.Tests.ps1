#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Automated Pester tests for bootstrap-antigravity.ps1 and its core library.
#>

Describe 'Antigravity Compatibility Bootstrap Runner Contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CoreLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/bootstrap-antigravity-core.ps1'
        $script:WrapperScriptPath = Join-Path $script:RepoRoot '.github/scripts/bootstrap-antigravity.ps1'

        # Dot-source the library
        . $script:CoreLibPath
    }

    It 'bootstrap core library loads successfully' {
        Get-Command -Name Get-AntigravitySubagents -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'Get-AntigravitySubagents function must be exposed'
        Get-Command -Name Convert-ToPascalCaseWithHyphens -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'Convert-ToPascalCaseWithHyphens function must be exposed'
    }

    Context 'Convert-ToPascalCaseWithHyphens' {
        It 'converts lowercase hyphenated names to PascalCase' {
            (Convert-ToPascalCaseWithHyphens -Name 'code-smith') | Should -Be 'Code-Smith'
            (Convert-ToPascalCaseWithHyphens -Name 'code-review-response') | Should -Be 'Code-Review-Response'
            (Convert-ToPascalCaseWithHyphens -Name 'spine-runner') | Should -Be 'Spine-Runner'
        }
    }

    Context 'Get-AntigravitySubagents' {
        BeforeAll {
            $script:Subagents = Get-AntigravitySubagents -RootPath $script:RepoRoot
        }

        It 'resolves exactly 16 subagents' {
            $script:Subagents.Count | Should -Be 16 -Because 'there are exactly 16 specialist roles declared in the plugin configuration'
        }

        It 'all subagents carry the required schema properties' {
            foreach ($subagent in $script:Subagents) {
                $subagent.name | Should -Not -BeNullOrEmpty -Because 'each subagent must have a name'
                $subagent.description | Should -Not -BeNullOrEmpty -Because 'each subagent must have a description'
                $subagent.system_prompt | Should -Not -BeNullOrEmpty -Because 'each subagent must resolve to a valid system prompt'
                $subagent.enable_write_tools.GetType().FullName | Should -Be 'System.Boolean' -Because 'enable_write_tools must be a boolean'
                $subagent.enable_subagent_tools.GetType().FullName | Should -Be 'System.Boolean' -Because 'enable_subagent_tools must be a boolean'
            }
        }

        It 'conductors have enable_subagent_tools set to true' {
            $conductors = @($script:Subagents | Where-Object { $_.name -in @('code-conductor', 'spine-runner', 'process-review') })
            foreach ($conductor in $conductors) {
                $conductor.enable_subagent_tools | Should -BeTrue -Because "conductor '$($conductor.name)' must be equipped to dispatch subagents"
            }
        }

        It 'executors have enable_write_tools set to true' {
            $executors = @($script:Subagents | Where-Object { $_.name -in @('senior-engineer', 'code-smith', 'test-writer', 'ui-iterator', 'refactor-specialist') })
            foreach ($executor in $executors) {
                $executor.enable_write_tools | Should -BeTrue -Because "executor '$($executor.name)' must be equipped to write files and run commands"
            }
        }

        It 'system prompts contain thin-shell and canonical body sections' {
            foreach ($subagent in $script:Subagents) {
                $subagent.system_prompt | Should -Match '# Thin-Shell Instructions' -Because 'system prompt must contain thin-shell instructions'
                $subagent.system_prompt | Should -Match '# Canonical Shared Agent Body' -Because 'system prompt must contain canonical shared agent body'
            }
        }
    }

    Context 'CLI Wrapper Execution' {
        It 'wrapper executes cleanly and outputs valid JSON' {
            $tempOutput = Join-Path $script:RepoRoot '.tmp/test-antigravity-subagents.json'
            if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force }

            $process = Start-Process -FilePath 'pwsh' -ArgumentList "-NoProfile", "-File", "$script:WrapperScriptPath", "-OutputPath", "$tempOutput" -NoNewWindow -PassThru -Wait
            $process.ExitCode | Should -Be 0 -Because 'the bootstrap script should execute with exit code 0'

            Test-Path $tempOutput | Should -BeTrue -Because 'the script should have generated the output JSON file'

            $parsedJson = Get-Content -Path $tempOutput -Raw | ConvertFrom-Json
            $parsedJson.Count | Should -Be 16 -Because 'the output JSON file should parse to exactly 16 objects'

            if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force }
        }
    }

    Context 'Extended Safety and Robustness Tests (F1, F2, F5, F6, F7, F8)' {
        It 'throws a terminating error when path traversal is attempted in manifest agents list' {
            $tempRoot = Join-Path $script:RepoRoot '.tmp/mock-repo'
            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
            $manifestDir = Join-Path $tempRoot '.claude-plugin'
            New-Item -Path $manifestDir -ItemType Directory -Force | Out-Null

            $manifest = @{ agents = @("../../../outside-repo") }
            ConvertTo-Json $manifest | Set-Content (Join-Path $manifestDir "plugin.json")

            { Get-AntigravitySubagents -RootPath $tempRoot } | Should -Throw "*Path traversal detected in manifest agents list!*"

            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
        }

        It 'exits with non-zero code on OutputPath path traversal attempt' {
            $outsidePath = "../../../outside.json"
            $process = Start-Process -FilePath 'pwsh' -ArgumentList "-NoProfile", "-File", "$script:WrapperScriptPath", "-OutputPath", "$outsidePath" -NoNewWindow -PassThru -Wait
            $process.ExitCode | Should -Be 1 -Because 'path traversal in OutputPath must fail the execution'
        }

        It 'resolves matching body file case-insensitively' {
            $tempRoot = Join-Path $script:RepoRoot '.tmp/mock-case-repo'
            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
            $agentsDir = Join-Path $tempRoot 'agents'
            New-Item -Path $agentsDir -ItemType Directory -Force | Out-Null

            # lowercase shell
            "---`nname: my-specialist`ndescription: Test role`ntools: Read`n---`n" | Set-Content (Join-Path $agentsDir "my-specialist.md")
            # lowercase agent body file (different case than PascalCase My-Specialist.agent.md)
            "This is my lowercase body content" | Set-Content (Join-Path $agentsDir "my-specialist.agent.md")

            $res = Get-AntigravitySubagents -RootPath $tempRoot
            $res.Count | Should -Be 1
            $res[0].system_prompt | Should -Match "This is my lowercase body content" -Because 'case-insensitive resolution must match my-specialist.agent.md'

            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
        }

        It 'ignores comments and handles quotes and brackets correctly' {
            $tempRoot = Join-Path $script:RepoRoot '.tmp/mock-parser-repo'
            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
            $agentsDir = Join-Path $tempRoot 'agents'
            New-Item -Path $agentsDir -ItemType Directory -Force | Out-Null

            $shellText = @"
---
name: parser-test
# This is a full comment line
description: "Standard description" # Inline comment here
tools: ["Read", 'Write', Edit]
enable_write_tools: 'true'
enable_subagent_tools: "false' # mismatched quotes should not be stripped
---
"@
            $shellText | Set-Content (Join-Path $agentsDir "parser-test.md")

            $res = Get-AntigravitySubagents -RootPath $tempRoot
            $res.Count | Should -Be 1
            $res[0].description | Should -Be "Standard description"
            $res[0].enable_write_tools | Should -BeTrue
            $res[0].enable_subagent_tools | Should -BeFalse

            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
        }

        It 'parses horizontal rules in thin-shell body correctly (F1)' {
            $tempRoot = Join-Path $script:RepoRoot '.tmp/mock-f1-repo'
            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
            $agentsDir = Join-Path $tempRoot 'agents'
            New-Item -Path $agentsDir -ItemType Directory -Force | Out-Null

            $shellText = @"
---
name: f1-test
description: "F1 test role"
---
# Some Title
This is body paragraph 1.
---
This is body paragraph 2 after horizontal rule.
"@
            $shellText | Set-Content (Join-Path $agentsDir "f1-test.md")

            $res = Get-AntigravitySubagents -RootPath $tempRoot
            $res.Count | Should -Be 1
            $res[0].system_prompt | Should -Match "This is body paragraph 1"
            $res[0].system_prompt | Should -Match "---"
            $res[0].system_prompt | Should -Match "This is body paragraph 2 after horizontal rule"

            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
        }

        It 'preserves hashes in URLs during comment stripping (F4)' {
            $tempRoot = Join-Path $script:RepoRoot '.tmp/mock-f4-repo'
            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
            $agentsDir = Join-Path $tempRoot 'agents'
            New-Item -Path $agentsDir -ItemType Directory -Force | Out-Null

            $shellText = @"
---
name: f4-test
description: "https://example.com/page#section"
tools: [Read] # inline comment with tools
---
"@
            $shellText | Set-Content (Join-Path $agentsDir "f4-test.md")

            $res = Get-AntigravitySubagents -RootPath $tempRoot
            $res.Count | Should -Be 1
            $res[0].description | Should -Be "https://example.com/page#section"

            if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
        }

        It 'exits with non-zero code when OutputPath equals repository root exactly (F3)' {
            $process = Start-Process -FilePath 'pwsh' -ArgumentList "-NoProfile", "-File", "$script:WrapperScriptPath", "-OutputPath", "$script:RepoRoot" -NoNewWindow -PassThru -Wait
            $process.ExitCode | Should -Be 1 -Because 'OutputPath matching repository root exactly must trigger path traversal exception and exit code 1'
        }

        It 'throws a terminating error when no subagents are resolved' {
            $tempWorkspace = Join-Path $script:RepoRoot '.tmp/temp-empty-workspace'
            if (Test-Path $tempWorkspace) { Remove-Item $tempWorkspace -Recurse -Force }
            $tempLibDir = Join-Path $tempWorkspace '.github/scripts/lib'
            New-Item -Path $tempLibDir -ItemType Directory -Force | Out-Null

            Copy-Item -Path $script:WrapperScriptPath -Destination (Join-Path $tempWorkspace '.github/scripts/bootstrap-antigravity.ps1') -Force
            Copy-Item -Path $script:CoreLibPath -Destination (Join-Path $tempLibDir 'bootstrap-antigravity-core.ps1') -Force

            $tempWrapper = Join-Path $tempWorkspace '.github/scripts/bootstrap-antigravity.ps1'
            $process = Start-Process -FilePath 'pwsh' -ArgumentList "-NoProfile", "-File", "$tempWrapper" -NoNewWindow -PassThru -Wait
            $process.ExitCode | Should -Be 1 -Because 'zero subagents must trigger a terminating error'

            if (Test-Path $tempWorkspace) { Remove-Item $tempWorkspace -Recurse -Force }
        }
    }
}
