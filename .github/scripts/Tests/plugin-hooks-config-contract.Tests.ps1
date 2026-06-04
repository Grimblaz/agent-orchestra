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

    It 'keeps both standalone hook config files available' {
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

    # UserPromptSubmit is a Claude-only hook event with no Copilot analog.
    # hooks/hooks.json (Claude) must declare it; the root hooks.json (Copilot) must not.
    It 'declares a Claude UserPromptSubmit hook for the project-references preflight' {
        $config = Get-JsonFile -Path $script:ClaudeHooksConfig
        # JSON key-presence check: parse the object and inspect property names
        $config.hooks.PSObject.Properties.Name | Should -Contain 'UserPromptSubmit' `
            -Because 'hooks/hooks.json must register UserPromptSubmit for Claude reference preflight'

        $entries = Get-HookEntries -HooksConfig $config -EventName 'UserPromptSubmit'
        $entries.Count | Should -Be 1
        $entries[0].matcher | Should -Be '' -Because 'UserPromptSubmit fires on every prompt; matcher should be empty string'
        @($entries[0].hooks).Count | Should -Be 1
        $entries[0].hooks[0].type | Should -Be 'command'
        $entries[0].hooks[0].command | Should -Match ([regex]::Escape('reference-preflight-hook.ps1'))
    }

    It 'does not declare UserPromptSubmit in the Copilot root hooks.json (intentional Claude-only asymmetry)' {
        $config = Get-JsonFile -Path $script:CopilotHooksConfig
        # JSON key-absence check: parse the object and verify UserPromptSubmit is not present
        $config.hooks.PSObject.Properties.Name | Should -Not -Contain 'UserPromptSubmit' `
            -Because 'root hooks.json is the Copilot hooks file; UserPromptSubmit has no Copilot analog'
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

    It 'declares the Copilot hook config from the root plugin manifest' {
        $rootManifest = Get-JsonFile -Path $script:RootPluginManifest

        $rootManifest.hooks | Should -Be 'hooks.json'
    }

    It 'omits hooks from the Claude plugin manifest because Claude loads hooks from hooks/hooks.json' {
        $claudeManifest = Get-JsonFile -Path $script:ClaudePluginManifest

        $claudeManifest.PSObject.Properties.Name | Should -Not -Contain 'hooks'
    }

    It 'keeps both marketplace manifests valid JSON' {
        { Get-JsonFile -Path $script:CopilotMarketplaceManifest } | Should -Not -Throw
        { Get-JsonFile -Path $script:ClaudeMarketplaceManifest } | Should -Not -Throw
    }
}
