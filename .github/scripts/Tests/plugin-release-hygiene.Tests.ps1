#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'plugin release hygiene hook contract' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HookScript = Join-Path $script:RepoRoot 'skills\plugin-release-hygiene\scripts\plugin-release-hygiene-hook.ps1'
        $script:SkillFile = Join-Path $script:RepoRoot 'skills\plugin-release-hygiene\SKILL.md'
        $script:ClaudeGuide = Join-Path $script:RepoRoot 'CLAUDE.md'
        $script:Readme = Join-Path $script:RepoRoot 'README.md'
        $script:FixtureRoots = [System.Collections.Generic.List[string]]::new()
        . $script:HookScript
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
                Set-Content -Path (Join-Path $root '.gitkeep') -Value 'fixture' -Encoding UTF8
                git add .gitkeep .github/scripts/bump-version.ps1 | Out-Null
                git commit -m 'fixture init' --quiet | Out-Null
                git checkout -b feature/issue-389-plugin-release-hygiene --quiet | Out-Null
            }
            finally {
                Pop-Location
            }

            return $root
        }

        function Set-PRHManagedVersionFiles {
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [Parameter(Mandatory)]
                [string]$Version
            )

            New-Item -ItemType Directory -Path (Join-Path $Root '.claude-plugin') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $Root '.github\plugin') -Force | Out-Null

            Set-Content -Path (Join-Path $Root 'plugin.json') -Value "{`"version`":`"$Version`"}" -Encoding UTF8
            Set-Content -Path (Join-Path $Root '.claude-plugin\plugin.json') -Value "{`"version`":`"$Version`"}" -Encoding UTF8
            Set-Content -Path (Join-Path $Root '.claude-plugin\marketplace.json') -Value "{`"metadata`":{`"version`":`"$Version`"},`"plugins`": [{`"version`":`"$Version`"}]}" -Encoding UTF8
            Set-Content -Path (Join-Path $Root '.github\plugin\marketplace.json') -Value "{`"metadata`":{`"version`":`"$Version`"},`"plugins`": [{`"version`":`"$Version`"}]}" -Encoding UTF8
            Set-Content -Path (Join-Path $Root 'README.md') -Value "[![Version](https://img.shields.io/badge/version-v$Version-blue.svg)](../../releases)" -Encoding UTF8
        }

        function Invoke-HookInFixture {
            param(
                [Parameter(Mandatory)]
                [string]$FixtureRoot,

                [string]$FilePath,

                [object[]]$Files,

                [string]$SessionId
            )

            $toolInput = [ordered]@{}
            if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
                $toolInput.file_path = $FilePath
            }
            if ($null -ne $Files) {
                $toolInput.files = $Files
            }

            $payloadObject = [ordered]@{
                tool_input = [PSCustomObject]$toolInput
            }
            if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
                $payloadObject.session_id = $SessionId
            }

            $payload = [PSCustomObject]$payloadObject | ConvertTo-Json -Depth 10 -Compress

            Push-Location $FixtureRoot
            try {
                return (Invoke-PRHHook -PayloadJson $payload)
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

    It 'emits hook JSON through the production entrypoint using stdin payload' {
        $fixture = New-PluginReleaseHygieneFixture
        $target = Join-Path $fixture 'agents\Entrypoint.agent.md'
        Set-Content -Path $target -Value '# Entrypoint' -Encoding UTF8
        $payload = [PSCustomObject]@{
            hook_event_name = 'PostToolUse'
            tool_name       = 'Edit'
            session_id      = 'entrypoint-session'
            tool_input      = [PSCustomObject]@{
                file_path = $target
            }
        } | ConvertTo-Json -Depth 10 -Compress

        $originalInput = [Console]::In
        Push-Location $fixture
        try {
            [Console]::SetIn([System.IO.StringReader]::new($payload))
            $raw = Invoke-PRHHookEntrypoint
        }
        finally {
            [Console]::SetIn($originalInput)
            Pop-Location
        }

        $result = $raw | ConvertFrom-Json

        $result.hookSpecificOutput.hookEventName | Should -Be 'PostToolUse'
        $result.hookSpecificOutput.additionalContext | Should -Match 'Entry-point edit detected:'
        $result.hookSpecificOutput.additionalContext | Should -Match 'agents/Entrypoint.agent.md'
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
        $state.keying_strategy | Should -Be 'branch_slug'
        @($state.touched_files) | Should -Contain 'agents/First.agent.md'
        @($state.touched_files) | Should -Contain 'commands/design.md'
    }

    It 'coalesces repeated entry-point edits by session_id and records the strategy' {
        $fixture = New-PluginReleaseHygieneFixture
        $first = Join-Path $fixture 'agents\First.agent.md'
        $second = Join-Path $fixture 'commands\design.md'
        $sessionId = 'session-422'
        New-Item -ItemType Directory -Path (Split-Path $second) -Force | Out-Null
        Set-Content -Path $first -Value '# First' -Encoding UTF8
        Set-Content -Path $second -Value '# Design' -Encoding UTF8

        $firstResult = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $first -SessionId $sessionId
        $secondResult = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $second -SessionId $sessionId
        $statePath = Join-Path $fixture '.claude\.state\release-hygiene-session-422.json'
        $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json

        [string]::IsNullOrWhiteSpace($firstResult) | Should -BeFalse
        [string]::IsNullOrWhiteSpace($secondResult) | Should -BeTrue
        $state.keying_strategy | Should -Be 'session_id'
        @($state.touched_files) | Should -Contain 'agents/First.agent.md'
        @($state.touched_files) | Should -Contain 'commands/design.md'
    }

    It 'updates keying_strategy when a later invocation uses a session_id for the same slug' {
        $fixture = New-PluginReleaseHygieneFixture
        $first = Join-Path $fixture 'agents\First.agent.md'
        $second = Join-Path $fixture 'commands\design.md'
        New-Item -ItemType Directory -Path (Split-Path $second) -Force | Out-Null
        Set-Content -Path $first -Value '# First' -Encoding UTF8
        Set-Content -Path $second -Value '# Design' -Encoding UTF8

        Push-Location $fixture
        try {
            git checkout -B feature/issue-422-plugin-release-hygiene --quiet | Out-Null
        }
        finally {
            Pop-Location
        }

        $firstResult = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $first
        $secondResult = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $second -SessionId '422'
        $statePath = Join-Path $fixture '.claude\.state\release-hygiene-422.json'
        $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json

        [string]::IsNullOrWhiteSpace($firstResult) | Should -BeFalse
        [string]::IsNullOrWhiteSpace($secondResult) | Should -BeTrue
        $state.keying_strategy | Should -Be 'session_id'
    }

    It 'stays silent when plugin.json is already ahead of main' {
        $fixture = New-PluginReleaseHygieneFixture
        $target = Join-Path $fixture 'agents\Example.agent.md'
        Set-Content -Path $target -Value '# Example' -Encoding UTF8

        Push-Location $fixture
        try {
            git checkout main --quiet | Out-Null
            Set-PRHManagedVersionFiles -Root $fixture -Version '1.0.0'
            git add plugin.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .github/plugin/marketplace.json README.md | Out-Null
            git commit -m 'seed main plugin version' --quiet | Out-Null
            git checkout feature/issue-389-plugin-release-hygiene --quiet | Out-Null
            Set-PRHManagedVersionFiles -Root $fixture -Version '1.0.1'
        }
        finally {
            Pop-Location
        }

        $raw = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $target -SessionId 'session-422-bumped'

        [string]::IsNullOrWhiteSpace($raw) | Should -BeTrue
        Test-Path (Join-Path $fixture '.claude\.state\release-hygiene-session-422-bumped.json') | Should -BeFalse
    }

    It 'does not stay silent when only part of the version set is bumped' {
        $fixture = New-PluginReleaseHygieneFixture
        $target = Join-Path $fixture 'agents\Example.agent.md'
        Set-Content -Path $target -Value '# Example' -Encoding UTF8

        Push-Location $fixture
        try {
            git checkout main --quiet | Out-Null
            Set-PRHManagedVersionFiles -Root $fixture -Version '1.0.0'
            git add plugin.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .github/plugin/marketplace.json README.md | Out-Null
            git commit -m 'seed main plugin version' --quiet | Out-Null
            git checkout feature/issue-389-plugin-release-hygiene --quiet | Out-Null
            Set-PRHManagedVersionFiles -Root $fixture -Version '1.0.1'
            Set-Content -Path (Join-Path $fixture 'plugin.json') -Value '{"version":"1.0.0"}' -Encoding UTF8
        }
        finally {
            Pop-Location
        }

        $raw = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $target -SessionId 'session-422-partial'

        [string]::IsNullOrWhiteSpace($raw) | Should -BeFalse
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

    It 'reuses the same state file across linked worktrees for the same session_id' {
        $fixture = New-PluginReleaseHygieneFixture
        $first = Join-Path $fixture 'agents\First.agent.md'
        $worktreeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("prh-worktree-$([guid]::NewGuid().ToString('N'))")
        $second = Join-Path $worktreeRoot 'commands\design.md'
        New-Item -ItemType Directory -Path (Split-Path $first) -Force | Out-Null
        Set-Content -Path $first -Value '# First' -Encoding UTF8
        $script:FixtureRoots.Add($worktreeRoot)

        Push-Location $fixture
        try {
            git worktree add --quiet -b feature/issue-389-plugin-release-hygiene-wt $worktreeRoot HEAD | Out-Null
        }
        finally {
            Pop-Location
        }

        New-Item -ItemType Directory -Path (Split-Path $second) -Force | Out-Null
        Set-Content -Path $second -Value '# Design' -Encoding UTF8

        $firstResult = Invoke-HookInFixture -FixtureRoot $fixture -FilePath $first -SessionId 'shared-worktree-session'
        $secondResult = Invoke-HookInFixture -FixtureRoot $worktreeRoot -FilePath $second -SessionId 'shared-worktree-session'
        $state = Get-Content -Path (Join-Path $fixture '.claude\.state\release-hygiene-shared-worktree-session.json') -Raw | ConvertFrom-Json

        [string]::IsNullOrWhiteSpace($firstResult) | Should -BeFalse
        [string]::IsNullOrWhiteSpace($secondResult) | Should -BeTrue
        @($state.touched_files) | Should -Contain 'agents/First.agent.md'
        @($state.touched_files) | Should -Contain 'commands/design.md'
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
