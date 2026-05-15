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
        # Copilot command_to_file(cmd) = ".github/prompts/" + cmd.TrimStart('/') + ".prompt.md"
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
        $script:TestSource | Should -Match ([regex]::Escape('Copilot command_to_file(cmd) = ".github/prompts/" + cmd.TrimStart(''/'') + ".prompt.md"'))

        $claudeRelativePath = & $script:ResolveClaudeCommandRelativePath '/orchestra:spine'
        $copilotRelativePath = & $script:ResolveCopilotCommandRelativePath '/review-github'

        $claudeRelativePath | Should -Be 'commands/orchestra-spine.md'
        (Test-Path -LiteralPath (& $script:ResolveWorkspacePath $claudeRelativePath) -PathType Leaf) | Should -BeTrue -Because '/orchestra:spine must resolve to the Claude command shell commands/orchestra-spine.md'

        $copilotRelativePath | Should -Be '.github/prompts/review-github.prompt.md'
        (Test-Path -LiteralPath (& $script:ResolveWorkspacePath $copilotRelativePath) -PathType Leaf) | Should -BeTrue -Because '/review-github must resolve to the Copilot prompt file .github/prompts/review-github.prompt.md'
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

    It 'matches review-local natural-language phrases through the Pattern lookup' {
        $lowercaseResult = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value 'review this code'
        $surroundingPhraseResult = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value 'please review this code'
        $uppercaseResult = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value 'REVIEW THIS CODE'

        $lowercaseResult | Should -Not -BeNullOrEmpty
        (& $script:GetIntentValue $lowercaseResult 'intent_key') | Should -Be 'review-local'
        (& $script:GetIntentValue $lowercaseResult 'claude_command') | Should -Be '/orchestra:review'
        (& $script:GetIntentValue $lowercaseResult 'copilot_command') | Should -Be '/review'

        $surroundingPhraseResult | Should -Not -BeNullOrEmpty
        (& $script:GetIntentValue $surroundingPhraseResult 'intent_key') | Should -Be 'review-local'

        $uppercaseResult | Should -Not -BeNullOrEmpty
        (& $script:GetIntentValue $uppercaseResult 'intent_key') | Should -Be 'review-local'
    }

    It 'routes common plan, polish, and GitHub-review natural-language phrases through Pattern lookup' -ForEach @(
        @{ Phrase = 'plan implementation for issue 567'; IntentKey = 'plan'; ClaudeCommand = '/plan'; CopilotCommand = '/plan' },
        @{ Phrase = 'polish this UI component'; IntentKey = 'polish'; ClaudeCommand = '/polish'; CopilotCommand = '/polish' },
        @{ Phrase = 'review my PR'; IntentKey = 'review-pr-github'; ClaudeCommand = '/review-github'; CopilotCommand = '/review-github' }
    ) {
        $result = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value $Phrase

        $result | Should -Not -BeNullOrEmpty
        (& $script:GetIntentValue $result 'intent_key') | Should -Be $IntentKey
        (& $script:GetIntentValue $result 'claude_command') | Should -Be $ClaudeCommand
        (& $script:GetIntentValue $result 'copilot_command') | Should -Be $CopilotCommand
    }

    It 'does not route natural-language pattern substrings inside longer words: <Phrase>' -ForEach @(
        @{ Phrase = 'review this codebase' },
        @{ Phrase = 'review this codex' },
        @{ Phrase = 'polish the uiux' },
        @{ Phrase = "don't run the pipelines" }
    ) {
        $firstMatch = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value $Phrase
        $allMatches = @(Invoke-RoutingLookupAll -Table nl_intent_routing -Key Pattern -Value $Phrase)

        $firstMatch | Should -BeNullOrEmpty -Because "'$Phrase' contains only a substring of a configured intent phrase"
        $allMatches.Count | Should -Be 0 -Because "all-match lookup must not collect substring false positives for '$Phrase'"
    }

    It 'routes canonical PR phrase <Phrase> only to GitHub review intake through all-match and first-match lookups' -ForEach @(
        @{ Phrase = 'review my PR' },
        @{ Phrase = 'review this PR' }
    ) {
        $routingMatches = @(Invoke-RoutingLookupAll -Table nl_intent_routing -Key Pattern -Value $Phrase)
        $intentKeys = @($routingMatches | ForEach-Object { & $script:GetIntentValue $_ 'intent_key' })

        $routingMatches.Count | Should -Be 1 -Because 'canonical PR review phrasing should not be ambiguous with local workspace review'
        $intentKeys | Should -Be @('review-pr-github')
        (& $script:GetIntentValue $routingMatches[0] 'copilot_command') | Should -Be '/review-github'

        $firstMatch = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value $Phrase
        (& $script:GetIntentValue $firstMatch 'intent_key') | Should -Be 'review-pr-github'
        (& $script:GetIntentValue $firstMatch 'copilot_command') | Should -Be '/review-github'
    }

    It 'can observe every intent matched by an ambiguous natural-language phrase' {
        $script:SyntheticRoutingConfig = @{
            nl_intent_routing = @{
                entries = @(
                    @{
                        intent_key = 'review-pr-github'
                        patterns = @('ambiguous review request')
                        claude_command = '/review-github'
                        copilot_command = '/review-github'
                    },
                    @{
                        intent_key = 'review-local'
                        patterns = @('ambiguous review request')
                        claude_command = '/orchestra:review'
                        copilot_command = '/review'
                    }
                )
            }
        }

        Mock -CommandName Read-RTJsonFile -MockWith {
            return $script:SyntheticRoutingConfig
        }

        $routingMatches = @(Invoke-RoutingLookupAll -Table nl_intent_routing -Key Pattern -Value 'ambiguous review request')
        $intentKeys = @($routingMatches | ForEach-Object { & $script:GetIntentValue $_ 'intent_key' })

        $routingMatches.Count | Should -BeGreaterThan 1 -Because 'ambiguous-match handling needs all candidate rows, not only the first match'
        $intentKeys | Should -Contain 'review-pr-github'
        $intentKeys | Should -Contain 'review-local'

        $firstMatch = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value 'ambiguous review request'
        (& $script:GetIntentValue $firstMatch 'intent_key') | Should -Be $intentKeys[0] -Because 'Invoke-RoutingLookup must preserve first-match behavior for existing callers'
    }

    It 'returns no route for raw-mode natural-language signal <Value>' -ForEach @(
        @{ Value = 'just answer normally' },
        @{ Value = "don't run the pipeline" },
        @{ Value = 'raw mode' },
        @{ Value = 'skip routing' }
    ) {
        $result = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value $Value

        $result | Should -BeNullOrEmpty -Because "raw-mode signal '$Value' must bypass normal Pattern routing"
    }

    It 'keeps checked-in nl_intent_routing patterns valid regular expressions' {
        $entries = @(& $script:GetIntentEntries)
        $entries | Should -Not -BeNullOrEmpty -Because 'nl_intent_routing must contain entries before pattern validity can be checked'

        foreach ($entry in $entries) {
            $intentKey = & $script:GetIntentValue $entry 'intent_key'
            $patterns = @(& $script:GetIntentValue $entry 'patterns')

            foreach ($pattern in $patterns) {
                { [void][regex]::new([string]$pattern) } | Should -Not -Throw -Because "pattern '$pattern' for intent '$intentKey' should be parseable"
            }
        }
    }

    It 'skips malformed Pattern regexes and continues scanning later entries' {
        $script:SyntheticRoutingConfig = @{
            nl_intent_routing = @{
                entries = @(
                    @{
                        intent_key = 'malformed-first'
                        patterns = @('review (')
                        claude_command = '/orchestra:review-lite'
                        copilot_command = '/review'
                    },
                    @{
                        intent_key = 'review-local'
                        patterns = @('review (this|the) (code|diff|changes)')
                        claude_command = '/orchestra:review'
                        copilot_command = '/review'
                    }
                )
            }
        }

        Mock -CommandName Read-RTJsonFile -MockWith {
            return $script:SyntheticRoutingConfig
        }

        $script:MalformedLookupResult = $null
        { $script:MalformedLookupResult = Invoke-RoutingLookup -Table nl_intent_routing -Key Pattern -Value 'review this code' } | Should -Not -Throw

        $script:MalformedLookupResult | Should -Not -BeNullOrEmpty
        (& $script:GetIntentValue $script:MalformedLookupResult 'intent_key') | Should -Be 'review-local'
    }

    It 'skips malformed Pattern regexes while collecting all later matches' {
        $script:SyntheticRoutingConfig = @{
            nl_intent_routing = @{
                entries = @(
                    @{
                        intent_key = 'malformed-first'
                        patterns = @('review (')
                        claude_command = '/orchestra:review-lite'
                        copilot_command = '/review'
                    },
                    @{
                        intent_key = 'review-pr-github'
                        patterns = @('review this PR')
                        claude_command = '/review-github'
                        copilot_command = '/review-github'
                    },
                    @{
                        intent_key = 'review-local'
                        patterns = @('review this PR')
                        claude_command = '/orchestra:review'
                        copilot_command = '/review'
                    }
                )
            }
        }

        Mock -CommandName Read-RTJsonFile -MockWith {
            return $script:SyntheticRoutingConfig
        }

        $script:MalformedLookupResults = @()
        { $script:MalformedLookupResults = @(Invoke-RoutingLookupAll -Table nl_intent_routing -Key Pattern -Value 'review this PR') } | Should -Not -Throw

        $intentKeys = @($script:MalformedLookupResults | ForEach-Object { & $script:GetIntentValue $_ 'intent_key' })
        $intentKeys | Should -Be @('review-pr-github', 'review-local')
    }
}
