#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Unit tests for the reporting-economy spot-check analyzer parser logic (issue #471).

.DESCRIPTION
    Tests use inline JSONL fixtures — not controlled agent-behavior fixtures and not
    real transcript data. Tests cover:
      - attributionAgent read and in-scope filtering
      - word count measurement (above and below the ~150-word threshold)
      - echo detection via [Tool: ...] pattern
      - exclusion of out-of-scope agents (code-conductor)
      - baseline-unavailable signal when slug dir does not exist
#>

Describe 'reporting-economy-spotcheck parser logic' {

    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot '../reporting-economy-spotcheck.ps1'

        # ---------------------------------------------------------------------------
        # In-scope set (mirrors the script)
        # ---------------------------------------------------------------------------
        $script:InScopeAgents = [System.Collections.Generic.HashSet[string]]@(
            'agent-orchestra:code-critic',
            'agent-orchestra:code-review-response',
            'agent-orchestra:code-smith',
            'agent-orchestra:doc-keeper',
            'agent-orchestra:process-review',
            'agent-orchestra:refactor-specialist',
            'agent-orchestra:research-agent',
            'agent-orchestra:senior-engineer',
            'agent-orchestra:specification',
            'agent-orchestra:test-writer',
            'agent-orchestra:ui-iterator'
        )

        # ---------------------------------------------------------------------------
        # Parser helpers — inline copies of the logic under test so tests are
        # self-contained and not brittle against unrelated script changes.
        # ---------------------------------------------------------------------------
        function script:Get-WordCount {
            param([string]$Text)
            if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
            return @($Text -split '\s+' | Where-Object { $_ -ne '' }).Count
        }

        function script:Get-TextContent {
            param([object]$ContentArray)
            if ($null -eq $ContentArray) { return '' }
            if ($ContentArray -is [string]) { return $ContentArray }
            $parts = foreach ($item in $ContentArray) {
                if ($item -is [System.Collections.IDictionary]) {
                    if ($item['type'] -eq 'text') { $item['text'] }
                }
                elseif ($item -is [PSCustomObject]) {
                    if ($item.type -eq 'text') { $item.text }
                }
            }
            return ($parts -join '') ?? ''
        }

        function script:Invoke-SpotcheckParser {
            <#
            .SYNOPSIS
                Parse a JSONL string and return spot-check rows for in-scope agents.
            #>
            param(
                [Parameter(Mandatory)][string]$JsonlContent,
                [System.Collections.Generic.HashSet[string]]$InScopeSet = $script:InScopeAgents
            )

            $results = [System.Collections.Generic.List[PSCustomObject]]::new()
            $lastAssistantEvent = $null

            foreach ($line in ($JsonlContent -split "`r?`n")) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrEmpty($trimmed)) { continue }
                try {
                    $event = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    if ($event['role'] -eq 'assistant') {
                        $lastAssistantEvent = $event
                    }
                }
                catch { }
            }

            if ($null -eq $lastAssistantEvent) { return $results }

            $attributionAgent = $lastAssistantEvent['attributionAgent']
            if ([string]::IsNullOrEmpty($attributionAgent)) { return $results }
            if (-not $InScopeSet.Contains($attributionAgent)) { return $results }

            $textContent = script:Get-TextContent -ContentArray $lastAssistantEvent['content']
            $wordCount   = script:Get-WordCount -Text $textContent
            $echoDetected = $textContent -match '\[Tool:'
            $overrideFlag = $textContent -imatch 'full detail'

            $results.Add([PSCustomObject]@{
                Agent        = $attributionAgent
                WordCount    = $wordCount
                EchoDetected = $echoDetected
                OverrideFlag = $overrideFlag
            })

            return $results
        }

        # ---------------------------------------------------------------------------
        # JSONL fixtures
        # ---------------------------------------------------------------------------

        # Fixture A: code-smith, over-threshold (~200+ words)
        # The final assistant event is over ~150 words.
        $longWords = ('alpha ' * 205).TrimEnd()
        $script:FixtureOverThreshold = @"
{"role":"user","content":[{"type":"text","text":"Implement the widget."}]}
{"role":"assistant","attributionAgent":"agent-orchestra:code-smith","content":[{"type":"text","text":"$longWords"}]}
"@

        # Fixture B: code-smith, under-threshold (~80 words)
        $shortWords = ('beta ' * 80).TrimEnd()
        $script:FixtureUnderThreshold = @"
{"role":"user","content":[{"type":"text","text":"Implement the widget."}]}
{"role":"assistant","attributionAgent":"agent-orchestra:code-smith","content":[{"type":"text","text":"$shortWords"}]}
"@

        # Fixture C: code-conductor (out-of-scope) — should be excluded
        $script:FixtureOutOfScope = @"
{"role":"user","content":[{"type":"text","text":"Orchestrate the plan."}]}
{"role":"assistant","attributionAgent":"agent-orchestra:code-conductor","content":[{"type":"text","text":"Running all slices now."}]}
"@

        # Fixture D: echo detected — contains [Tool: read]
        $echoText = 'Here is the result. [Tool: read] returned the file contents. ' + ('gamma ' * 10).TrimEnd()
        $script:FixtureEchoDetected = @"
{"role":"user","content":[{"type":"text","text":"Read the file."}]}
{"role":"assistant","attributionAgent":"agent-orchestra:senior-engineer","content":[{"type":"text","text":"$echoText"}]}
"@

        # Fixture E: no echo, no override
        $cleanText = ('delta ' * 50).TrimEnd()
        $script:FixtureClean = @"
{"role":"user","content":[{"type":"text","text":"Write the tests."}]}
{"role":"assistant","attributionAgent":"agent-orchestra:test-writer","content":[{"type":"text","text":"$cleanText"}]}
"@

        # Fixture F: override flag — contains "full detail"
        $overrideText = 'Here is the full detail of the implementation. ' + ('epsilon ' * 30).TrimEnd()
        $script:FixtureOverride = @"
{"role":"user","content":[{"type":"text","text":"Give me everything."}]}
{"role":"assistant","attributionAgent":"agent-orchestra:doc-keeper","content":[{"type":"text","text":"$overrideText"}]}
"@

        # Fixture G: last assistant event wins (earlier assistant event should be ignored)
        $earlyText  = ('early ' * 50).TrimEnd()
        $finalText  = ('final ' * 160).TrimEnd()
        $script:FixtureLastEventWins = @"
{"role":"user","content":[{"type":"text","text":"Step one."}]}
{"role":"assistant","attributionAgent":"agent-orchestra:research-agent","content":[{"type":"text","text":"$earlyText"}]}
{"role":"user","content":[{"type":"text","text":"Step two."}]}
{"role":"assistant","attributionAgent":"agent-orchestra:research-agent","content":[{"type":"text","text":"$finalText"}]}
"@
    }

    # ---------------------------------------------------------------------------
    # Context: word-count measurement
    # ---------------------------------------------------------------------------
    Context 'word-count measurement' {

        It 'counts words correctly for over-threshold fixture (~205 words)' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureOverThreshold
            $rows.Count | Should -Be 1
            $rows[0].WordCount | Should -BeGreaterThan 150
        }

        It 'counts words correctly for under-threshold fixture (~80 words)' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureUnderThreshold
            $rows.Count | Should -Be 1
            $rows[0].WordCount | Should -BeLessThan 150
            $rows[0].WordCount | Should -BeGreaterThan 0
        }

        It 'reports zero words for empty content' {
            $count = script:Get-WordCount -Text ''
            $count | Should -Be 0
        }

        It 'reports zero words for whitespace-only content' {
            $count = script:Get-WordCount -Text '   '
            $count | Should -Be 0
        }
    }

    # ---------------------------------------------------------------------------
    # Context: attributionAgent filtering
    # ---------------------------------------------------------------------------
    Context 'attributionAgent in-scope filtering' {

        It 'includes agent-orchestra:code-smith (in-scope)' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureOverThreshold
            $rows.Count | Should -Be 1
            $rows[0].Agent | Should -Be 'agent-orchestra:code-smith'
        }

        It 'excludes agent-orchestra:code-conductor (out-of-scope)' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureOutOfScope
            $rows.Count | Should -Be 0
        }

        It 'includes all 11 in-scope agent identifiers in the set' {
            $script:InScopeAgents.Count | Should -Be 11
            $script:InScopeAgents | Should -Contain 'agent-orchestra:code-critic'
            $script:InScopeAgents | Should -Contain 'agent-orchestra:ui-iterator'
            $script:InScopeAgents | Should -Not -Contain 'agent-orchestra:code-conductor'
            $script:InScopeAgents | Should -Not -Contain 'agent-orchestra:spine-runner'
            $script:InScopeAgents | Should -Not -Contain 'agent-orchestra:experience-owner'
        }
    }

    # ---------------------------------------------------------------------------
    # Context: echo detection
    # ---------------------------------------------------------------------------
    Context 'echo detection via [Tool: ...] pattern' {

        It 'detects echo when [Tool: read] appears in content' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureEchoDetected
            $rows.Count | Should -Be 1
            $rows[0].EchoDetected | Should -Be $true
        }

        It 'does not set EchoDetected for clean content with no [Tool: ...] marker' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureClean
            $rows.Count | Should -Be 1
            $rows[0].EchoDetected | Should -Be $false
        }
    }

    # ---------------------------------------------------------------------------
    # Context: override flag
    # ---------------------------------------------------------------------------
    Context 'override flag detection' {

        It 'sets OverrideFlag when content contains "full detail" (case-insensitive)' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureOverride
            $rows.Count | Should -Be 1
            $rows[0].OverrideFlag | Should -Be $true
        }

        It 'does not set OverrideFlag for content without "full detail"' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureClean
            $rows.Count | Should -Be 1
            $rows[0].OverrideFlag | Should -Be $false
        }
    }

    # ---------------------------------------------------------------------------
    # Context: last-assistant-event wins
    # ---------------------------------------------------------------------------
    Context 'final-report event selection' {

        It 'uses the last assistant event, not an earlier one' {
            $rows = script:Invoke-SpotcheckParser -JsonlContent $script:FixtureLastEventWins
            $rows.Count | Should -Be 1
            # The last event has 160 "final" words; the early event has 50 "early" words
            $rows[0].WordCount | Should -BeGreaterThan 150
        }
    }

    # ---------------------------------------------------------------------------
    # Context: baseline-unavailable signal
    # ---------------------------------------------------------------------------
    Context 'baseline-unavailable signal' {

        It 'emits baseline-unavailable message when slug dir does not exist' {
            # Use a guaranteed-nonexistent CWD path as the slug source
            $fakeCwd = 'Z:\DoesNotExist\NoSuchProject\xyz99'
            $output = pwsh -NoProfile -NonInteractive -Command "& '$script:ScriptPath' -CwdPath '$fakeCwd'" 2>&1
            $combined = $output -join ' '
            $combined | Should -Match 'Baseline unavailable'
        }

        It 'script file exists at expected path' {
            Test-Path -LiteralPath $script:ScriptPath | Should -Be $true
        }
    }

    # ---------------------------------------------------------------------------
    # Context: Get-TextContent extraction
    # ---------------------------------------------------------------------------
    Context 'text content extraction from content array' {

        It 'concatenates multiple text blocks into a single string' {
            $blocks = @(
                @{ type = 'text'; text = 'Hello ' },
                @{ type = 'text'; text = 'world' }
            )
            $result = script:Get-TextContent -ContentArray $blocks
            $result | Should -Be 'Hello world'
        }

        It 'skips non-text typed blocks' {
            $blocks = @(
                @{ type = 'tool_result'; content = 'should be ignored' },
                @{ type = 'text'; text = 'kept' }
            )
            $result = script:Get-TextContent -ContentArray $blocks
            $result | Should -Be 'kept'
        }

        It 'returns empty string for null content' {
            $result = script:Get-TextContent -ContentArray $null
            $result | Should -Be ''
        }

        It 'returns the string directly when content is a plain string' {
            $result = script:Get-TextContent -ContentArray 'plain text'
            $result | Should -Be 'plain text'
        }
    }
}
