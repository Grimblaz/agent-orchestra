#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'plugin release hygiene hook contract' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HookScript = Join-Path $script:RepoRoot '.claude\hooks\plugin-release-hygiene-hook.ps1'
        $script:SkillFile = Join-Path $script:RepoRoot 'skills\plugin-release-hygiene\SKILL.md'
        $script:ClaudeGuide = Join-Path $script:RepoRoot 'CLAUDE.md'
        $script:Readme = Join-Path $script:RepoRoot 'README.md'
        $script:FixtureRoots = [System.Collections.Generic.List[string]]::new()
        $script:CliCommands = @(
            'claude plugin list',
            'claude plugin marketplace list',
            'claude plugin marketplace update',
            'claude plugin marketplace add <source>',
            'claude plugin marketplace remove <name>',
            'claude plugin update <plugin@marketplace>',
            'claude plugin install <plugin@marketplace>',
            'claude plugin uninstall <plugin@marketplace>'
        )

        function New-PluginReleaseHygieneFixture {
            param(
                [string]$Name = "prh-$([guid]::NewGuid().ToString('N'))"
            )

            $root = Join-Path ([System.IO.Path]::GetTempPath()) $Name
            $agentsDir = Join-Path $root 'agents'
            $scriptsDir = Join-Path $root '.github\scripts'

            New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
            Set-Content -Path (Join-Path $scriptsDir 'bump-version.ps1') -Value '# fixture gate' -Encoding UTF8
            $script:FixtureRoots.Add($root)

            Push-Location $root
            try {
                git init --initial-branch main --quiet | Out-Null
                git checkout -b feature/issue-389-plugin-release-hygiene --quiet | Out-Null
            }
            finally {
                Pop-Location
            }

            return $root
        }

        function Invoke-HookInFixture {
            param(
                [Parameter(Mandatory)]
                [string]$FixtureRoot,

                [string]$FilePath,

                [object[]]$Files
            )

            $toolInput = [ordered]@{}
            if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
                $toolInput.file_path = $FilePath
            }
            if ($null -ne $Files) {
                $toolInput.files = $Files
            }

            $payload = [PSCustomObject]@{ tool_input = [PSCustomObject]$toolInput } | ConvertTo-Json -Depth 10 -Compress

            Push-Location $FixtureRoot
            try {
                return ($payload | & pwsh -NoProfile -NonInteractive -File $script:HookScript)
            }
            finally {
                Pop-Location
            }
        }
    }

    AfterAll {
        foreach ($root in $script:FixtureRoots) {
            if (Test-Path $root) {
                Remove-Item -Path $root -Recurse -Force
            }
        }
    }

    It 'emits the hook JSON contract for the first entry-point edit' {
        $fixture = New-PluginReleaseHygieneFixture
        $target = Join-Path $fixture 'agents\Example.agent.md'
        Set-Content -Path $target -Value '# Example' -Encoding UTF8

        $raw = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $target
        $result = $raw | ConvertFrom-Json

        $result.hookSpecificOutput.hookEventName | Should -Be 'PostToolUse'
        $result.hookSpecificOutput.additionalContext | Should -Match 'Entry-point edit detected:'
        $result.hookSpecificOutput.additionalContext | Should -Match 'plugin-release-hygiene skill'
    }

    It 'stays silent for non-entry-point edits' {
        $fixture = New-PluginReleaseHygieneFixture
        $docsDir = Join-Path $fixture 'Documents'
        New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
        $target = Join-Path $docsDir 'notes.md'
        Set-Content -Path $target -Value '# Notes' -Encoding UTF8

        $raw = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $target

        [string]::IsNullOrWhiteSpace($raw) | Should -BeTrue
    }

    It 'coalesces repeated entry-point edits into one state file' {
        $fixture = New-PluginReleaseHygieneFixture
        $first = Join-Path $fixture 'agents\First.agent.md'
        $second = Join-Path $fixture 'commands\design.md'
        New-Item -ItemType Directory -Path (Split-Path $second) -Force | Out-Null
        Set-Content -Path $first -Value '# First' -Encoding UTF8
        Set-Content -Path $second -Value '# Design' -Encoding UTF8

        $firstResult = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $first
        $secondResult = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $second
        $statePath = Join-Path $fixture '.claude\.state\release-hygiene-389.json'
        $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json

        [string]::IsNullOrWhiteSpace($firstResult) | Should -BeFalse
        [string]::IsNullOrWhiteSpace($secondResult) | Should -BeTrue
        $state.proposed_level | Should -Be 'patch'
        @($state.touched_files) | Should -Contain 'agents/First.agent.md'
        @($state.touched_files) | Should -Contain 'commands/design.md'
    }

    It 'detects entry-point edits from MultiEdit payload files' {
        $fixture = New-PluginReleaseHygieneFixture
        $commandsDir = Join-Path $fixture 'commands'
        $docsDir = Join-Path $fixture 'Documents'
        New-Item -ItemType Directory -Path $commandsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $docsDir -Force | Out-Null
        $entryPoint = Join-Path $commandsDir 'review.md'
        $nonEntry = Join-Path $docsDir 'notes.md'
        Set-Content -Path $entryPoint -Value '# Review' -Encoding UTF8
        Set-Content -Path $nonEntry -Value '# Notes' -Encoding UTF8

        $raw = Invoke-HookInFixture -FixtureRoot $fixture -Files @(
            [PSCustomObject]@{ filePath = $nonEntry },
            [PSCustomObject]@{ filePath = $entryPoint }
        )
        $result = $raw | ConvertFrom-Json

        $result.hookSpecificOutput.additionalContext | Should -Match 'commands/review.md'
    }

    It 'preserves leading-dot entry-point paths during normalization' {
        $fixture = New-PluginReleaseHygieneFixture
        $pluginDir = Join-Path $fixture '.claude-plugin'
        New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null
        $target = Join-Path $pluginDir 'plugin.json'
        Set-Content -Path $target -Value '{ }' -Encoding UTF8

        $raw = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $target
        $result = $raw | ConvertFrom-Json

        $result.hookSpecificOutput.additionalContext | Should -Match '.claude-plugin/plugin.json'
    }

    It 'fails open when the state path cannot be created' {
        $fixture = New-PluginReleaseHygieneFixture
        $target = Join-Path $fixture 'agents\Example.agent.md'
        Set-Content -Path $target -Value '# Example' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $fixture '.claude') -Force | Out-Null
        Set-Content -Path (Join-Path $fixture '.claude\.state') -Value 'blocked' -Encoding UTF8

        $raw = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $target
        $result = $raw | ConvertFrom-Json

        $result.hookSpecificOutput.hookEventName | Should -Be 'PostToolUse'
        Test-Path (Join-Path $fixture '.claude\.state\release-hygiene-389.json') | Should -BeFalse
    }

    It 'documents the full Claude plugin CLI surface in the three required files' {
        $files = @($script:SkillFile, $script:ClaudeGuide, $script:Readme)

        foreach ($file in $files) {
            $content = Get-Content -Path $file -Raw
            foreach ($command in $script:CliCommands) {
                $content | Should -Match ([regex]::Escape($command))
            }
        }
    }
}