#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED contract tests for natural-language intent routing configuration.

.DESCRIPTION
    Locks issue #567 Step 1 before GREEN implementation exists:
      - nl_intent_routing table presence in routing-config.json
      - command-to-file resolution for Claude and Copilot command surfaces
      - documentation citations back to the routing-config.json source of truth
      - Invoke-RoutingLookup wiring for the review-local intent
#>

Describe 'Natural-language intent routing table contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:RoutingTablesCore = Join-Path $script:RepoRoot 'skills\routing-tables\scripts\routing-tables-core.ps1'

        . $script:RoutingTablesCore

        $script:RoutingConfig = Read-RTJsonFile -Path (Get-RTConfigPath)
        $script:TestSource = Get-Content -Path $PSCommandPath -Raw

        # Slash command file resolution rules under test:
        # Claude command_to_file(cmd) = "commands/" + cmd.TrimStart('/').Replace(':','-') + ".md"
        # Copilot command_to_file(cmd) = ".github/prompts/" + "/" + cmd.TrimStart('/') + ".prompt.md"
        $script:ResolveClaudeCommandRelativePath = {
            param([Parameter(Mandatory)][string]$Command)

            return 'commands/' + $Command.TrimStart('/').Replace(':', '-') + '.md'
        }

        $script:ResolveCopilotCommandRelativePath = {
            param([Parameter(Mandatory)][string]$Command)

            return '.github/prompts/' + $Command.TrimStart('/') + '.prompt.md'
        }

        $script:ResolveWorkspacePath = {
            param([Parameter(Mandatory)][string]$RelativePath)

            return Join-Path $script:RepoRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        }

        $script:GetIntentEntries = {
            if (-not $script:RoutingConfig.ContainsKey('nl_intent_routing')) {
                return @()
            }

            $table = $script:RoutingConfig['nl_intent_routing']
            if (-not ($table -is [System.Collections.IDictionary]) -or -not $table.Contains('entries')) {
                return @()
            }

            return @($table['entries'])
        }

        $script:GetIntentValue = {
            param(
                [Parameter(Mandatory)][object]$Entry,
                [Parameter(Mandatory)][string]$Name
            )

            if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Name)) {
                return $Entry[$Name]
            }

            $property = $Entry.PSObject.Properties[$Name]
            if ($property) {
                return $property.Value
            }

            return $null
        }
    }

    It 'defines a top-level nl_intent_routing table in routing-config.json' {
        $script:RoutingConfig.ContainsKey('nl_intent_routing') | Should -BeTrue -Because 'natural-language routing must be data-driven from routing-config.json'
    }

    It 'documents and implements slash command file resolution for both plugin surfaces' {
        $script:TestSource | Should -Match ([regex]::Escape('Claude command_to_file(cmd) = "commands/" + cmd.TrimStart(''/'').Replace('':'',''-'') + ".md"'))
        $script:TestSource | Should -Match ([regex]::Escape('Copilot command_to_file(cmd) = ".github/prompts/" + "/" + cmd.TrimStart(''/'') + ".prompt.md"'))

        $claudeRelativePath = & $script:ResolveClaudeCommandRelativePath '/orchestra:spine'
        $copilotRelativePath = & $script:ResolveCopilotCommandRelativePath '/review'

        $claudeRelativePath | Should -Be 'commands/orchestra-spine.md'
        (Test-Path -LiteralPath (& $script:ResolveWorkspacePath $claudeRelativePath) -PathType Leaf) | Should -BeTrue -Because '/orchestra:spine must resolve to the Claude command shell commands/orchestra-spine.md'

        $copilotRelativePath | Should -Be '.github/prompts/review.prompt.md'
        (Test-Path -LiteralPath (& $script:ResolveWorkspacePath $copilotRelativePath) -PathType Leaf) | Should -BeTrue -Because '/review must resolve to the Copilot prompt file .github/prompts/review.prompt.md'
    }

    It 'resolves every configured Claude and Copilot slash command to an existing file' {
        $entries = @(& $script:GetIntentEntries)
        $entries | Should -Not -BeNullOrEmpty -Because 'nl_intent_routing must contain command mappings before command-file parity can be checked'

        foreach ($entry in $entries) {
            $intentKey = & $script:GetIntentValue $entry 'intent_key'
            $claudeCommand = & $script:GetIntentValue $entry 'claude_command'
            $copilotCommand = & $script:GetIntentValue $entry 'copilot_command'

            $claudeCommand | Should -Not -BeNullOrEmpty -Because "intent '$intentKey' must declare a Claude command"
            $claudeRelativePath = & $script:ResolveClaudeCommandRelativePath $claudeCommand
            (Test-Path -LiteralPath (& $script:ResolveWorkspacePath $claudeRelativePath) -PathType Leaf) | Should -BeTrue -Because "Claude command '$claudeCommand' for intent '$intentKey' should resolve to an existing file"

            if ($null -ne $copilotCommand) {
                $copilotRelativePath = & $script:ResolveCopilotCommandRelativePath $copilotCommand
                (Test-Path -LiteralPath (& $script:ResolveWorkspacePath $copilotRelativePath) -PathType Leaf) | Should -BeTrue -Because "Copilot command '$copilotCommand' for intent '$intentKey' should resolve to an existing file; null is the only allowed no-Copilot-command value"
            }
        }
    }

    It 'keeps Claude and Copilot docs anchored to nl_intent_routing in routing-config.json' {
        $docPaths = @(
            'CLAUDE.md',
            '.github/copilot-instructions.md'
        )

        foreach ($relativePath in $docPaths) {
            $content = Get-Content -Path (& $script:ResolveWorkspacePath $relativePath) -Raw

            $content | Should -Match '(?s)(routing-config\.json.*nl_intent_routing|nl_intent_routing.*routing-config\.json)' -Because "$relativePath must cite nl_intent_routing in routing-config.json as the source of truth"
        }
    }

    It 'returns the review-local row through Invoke-RoutingLookup' {
        $result = Invoke-RoutingLookup -Table nl_intent_routing -Key IntentKey -Value 'review-local'

        $result | Should -Not -BeNullOrEmpty
        (& $script:GetIntentValue $result 'intent_key') | Should -Be 'review-local'
        (& $script:GetIntentValue $result 'claude_command') | Should -Be '/orchestra:review'
        (& $script:GetIntentValue $result 'copilot_command') | Should -Be '/review'
    }
}
