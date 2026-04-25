#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'plugin hooks config contract' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CopilotHooksConfig = Join-Path $script:RepoRoot 'hooks.json'
        $script:ClaudeHooksConfig = Join-Path $script:RepoRoot 'hooks\hooks.json'
        $script:RootPluginManifest = Join-Path $script:RepoRoot 'plugin.json'
        $script:ClaudePluginManifest = Join-Path $script:RepoRoot '.claude-plugin\plugin.json'
        $script:CopilotMarketplaceManifest = Join-Path $script:RepoRoot '.github\plugin\marketplace.json'
        $script:ClaudeMarketplaceManifest = Join-Path $script:RepoRoot '.claude-plugin\marketplace.json'
        $script:SessionStartScript = 'skills/session-startup/scripts/session-cleanup-detector.ps1'
        $script:ReleaseHygieneScript = 'skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1'
        $script:SessionStartMatcher = 'startup'
        $script:PostToolUseMatcher = '^(Edit|Write|MultiEdit)$'
        $script:SupportedProductDirs = @('Code', 'Code - Insiders', 'VSCodium', 'Cursor')

        function Get-JsonFile {
            param(
                [Parameter(Mandatory)]
                [string]$Path
            )

            Test-Path $Path | Should -BeTrue -Because "$Path must exist"
            return Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }

        function Get-HookEntries {
            param(
                [Parameter(Mandatory)]
                [object]$HooksConfig,

                [Parameter(Mandatory)]
                [string]$EventName
            )

            $entries = $HooksConfig.hooks.$EventName
            @($entries)
        }

        function Get-CopilotCacheLocator {
            param(
                [Parameter(Mandatory)]
                [object]$Manifest
            )

            $repositoryUri = [Uri]$Manifest.repository
            $repositorySegments = $repositoryUri.AbsolutePath.Trim('/') -split '/'
            return 'agentPlugins/github.com/{0}/{1}' -f $repositorySegments[0], $Manifest.name
        }
    }

    It 'declares both Claude and Copilot hook configs' {
        Test-Path $script:ClaudeHooksConfig | Should -BeTrue
        Test-Path $script:CopilotHooksConfig | Should -BeTrue
    }

    It 'declares a Claude SessionStart hook for the cleanup detector' {
        $config = Get-JsonFile -Path $script:ClaudeHooksConfig
        $entries = Get-HookEntries -HooksConfig $config -EventName 'SessionStart'

        $entries.Count | Should -Be 1
        $entries[0].matcher | Should -Be $script:SessionStartMatcher
        @($entries[0].hooks).Count | Should -Be 1
        $entries[0].hooks[0].type | Should -Be 'command'
        $entries[0].hooks[0].command | Should -Match ([regex]::Escape('pwsh -NoProfile -NonInteractive -File '))
        $entries[0].hooks[0].command | Should -Match ([regex]::Escape('"${CLAUDE_PLUGIN_ROOT}'))
        $entries[0].hooks[0].command | Should -Match ([regex]::Escape($script:SessionStartScript))
    }

    It 'declares a Claude PostToolUse hook for plugin release hygiene' {
        $config = Get-JsonFile -Path $script:ClaudeHooksConfig
        $entries = Get-HookEntries -HooksConfig $config -EventName 'PostToolUse'

        $entries.Count | Should -Be 1
        $entries[0].matcher | Should -Be $script:PostToolUseMatcher
        @($entries[0].hooks).Count | Should -Be 1
        $entries[0].hooks[0].type | Should -Be 'command'
        $entries[0].hooks[0].command | Should -Match ([regex]::Escape('pwsh -NoProfile -NonInteractive -File '))
        $entries[0].hooks[0].command | Should -Match ([regex]::Escape('"${CLAUDE_PLUGIN_ROOT}'))
        $entries[0].hooks[0].command | Should -Match ([regex]::Escape($script:ReleaseHygieneScript))
    }

    It 'declares Copilot hook commands that resolve the installed plugin cache path' {
        $config = Get-JsonFile -Path $script:CopilotHooksConfig
        $rootManifest = Get-JsonFile -Path $script:RootPluginManifest
        $sessionEntries = Get-HookEntries -HooksConfig $config -EventName 'SessionStart'
        $postToolEntries = Get-HookEntries -HooksConfig $config -EventName 'PostToolUse'
        $cacheLocator = Get-CopilotCacheLocator -Manifest $rootManifest
        $requiredEscapedTokens = @(
            '`$productDirs',
            '`$pluginSuffix',
            '`$paths',
            '`$env:APPDATA',
            '`$env:XDG_CONFIG_HOME',
            '`$HOME',
            '`$productDir',
            '`$pluginRoot',
            '`$_'
        )

        $sessionEntries.Count | Should -Be 1
        $postToolEntries.Count | Should -Be 1
        $sessionEntries[0].matcher | Should -Be $script:SessionStartMatcher
        $postToolEntries[0].matcher | Should -Be $script:PostToolUseMatcher
        foreach ($productDir in $script:SupportedProductDirs) {
            $sessionEntries[0].hooks[0].command | Should -Match ([regex]::Escape("'$productDir'"))
            $postToolEntries[0].hooks[0].command | Should -Match ([regex]::Escape("'$productDir'"))
        }
        $sessionEntries[0].hooks[0].command | Should -Match ([regex]::Escape("`$pluginSuffix = '$cacheLocator'"))
        $postToolEntries[0].hooks[0].command | Should -Match ([regex]::Escape("`$pluginSuffix = '$cacheLocator'"))
        $sessionEntries[0].hooks[0].command | Should -Match ([regex]::Escape($script:SessionStartScript))
        $postToolEntries[0].hooks[0].command | Should -Match ([regex]::Escape($script:ReleaseHygieneScript))
        foreach ($token in $requiredEscapedTokens) {
            $sessionEntries[0].hooks[0].command | Should -Match ([regex]::Escape($token))
            $postToolEntries[0].hooks[0].command | Should -Match ([regex]::Escape($token))
        }
    }

    It 'declares format-appropriate hooks in both plugin manifests' {
        $rootManifest = Get-JsonFile -Path $script:RootPluginManifest
        $claudeManifest = Get-JsonFile -Path $script:ClaudePluginManifest

        $rootManifest.hooks | Should -Be 'hooks.json'
        $claudeManifest.hooks | Should -Be './hooks/hooks.json'
    }

    It 'keeps both marketplace manifests valid JSON' {
        { Get-JsonFile -Path $script:CopilotMarketplaceManifest } | Should -Not -Throw
        { Get-JsonFile -Path $script:ClaudeMarketplaceManifest } | Should -Not -Throw
    }
}
