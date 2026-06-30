#Requires -Version 7.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 unit tests for reporting-economy-spotcheck.ps1 parser logic.
.DESCRIPTION
    Dot-sources the production script with -ImportMode so Get-SpotcheckRecord and
    Get-SpotcheckSlug are imported into the test scope without running the main block.
    Fixtures use the real subagent JSONL schema verified in issue #471 s4:
      { "type": "assistant", "attributionAgent": "...",
        "message": { "role": "assistant", "content": [{ "type": "text", "text": "..." }] } }
#>

Describe 'reporting-economy-spotcheck parser logic' {

    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptPath = Join-Path $script:RepoRoot '.github/scripts/reporting-economy-spotcheck.ps1'

        # Import functions without running main block
        . $script:ScriptPath -ImportMode

        $script:InScopeAgents = @(
            'agent-orchestra:code-critic'
            'agent-orchestra:code-review-response'
            'agent-orchestra:code-smith'
            'agent-orchestra:doc-keeper'
            'agent-orchestra:process-review'
            'agent-orchestra:refactor-specialist'
            'agent-orchestra:research-agent'
            'agent-orchestra:senior-engineer'
            'agent-orchestra:specification'
            'agent-orchestra:test-writer'
            'agent-orchestra:ui-iterator'
        )

        # Build a JSONL event line using the real subagent transcript schema
        function script:New-AssistantEventLine {
            param(
                [string]$AttributionAgent,
                [object[]]$ContentBlocks = @(@{ type = 'text'; text = 'Hello world.' })
            )
            $e = @{
                type             = 'assistant'
                attributionAgent = $AttributionAgent
                message          = @{
                    role    = 'assistant'
                    content = $ContentBlocks
                }
            }
            return ($e | ConvertTo-Json -Compress -Depth 10)
        }

        function script:Write-JsonlFile {
            param([string]$Path, [string[]]$Lines)
            Set-Content -LiteralPath $Path -Value ($Lines -join "`n") -NoNewline
        }
    }

    Context 'attributionAgent parsing' {

        It 'reads attributionAgent from the last assistant event' {
            $tmpFile = Join-Path $TestDrive 'agent-abc123.jsonl'
            $line = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:senior-engineer' `
                -ContentBlocks @(@{ type = 'text'; text = 'Work done.' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result                | Should -Not -BeNullOrEmpty
            $result.Agent          | Should -Be 'agent-orchestra:senior-engineer'
            $result.ToolUseId      | Should -Be 'abc123'
        }

        It 'uses the LAST assistant event when multiple events are present' {
            $tmpFile = Join-Path $TestDrive 'agent-xyz.jsonl'
            $first  = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:senior-engineer' `
                -ContentBlocks @(@{ type = 'text'; text = 'First.' })
            $second = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:code-smith' `
                -ContentBlocks @(@{ type = 'text'; text = 'Second.' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($first, $second)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result       | Should -Not -BeNullOrEmpty
            $result.Agent | Should -Be 'agent-orchestra:code-smith'
        }
    }

    Context 'out-of-scope agent exclusion' {

        It 'excludes events where attributionAgent is not in the in-scope set' {
            $tmpFile = Join-Path $TestDrive 'agent-oos1.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:code-conductor'
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result | Should -BeNullOrEmpty
        }

        It 'excludes an unknown agent value' {
            $tmpFile = Join-Path $TestDrive 'agent-oos2.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:unknown-agent'
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result | Should -BeNullOrEmpty
        }
    }

    Context 'word counting' {

        It 'counts words correctly for simple text' {
            $tmpFile = Join-Path $TestDrive 'agent-wc1.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:doc-keeper' `
                -ContentBlocks @(@{ type = 'text'; text = 'one two three four five' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.WordCount | Should -Be 5
        }

        It 'counts zero words for empty text' {
            $tmpFile = Join-Path $TestDrive 'agent-wc2.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:doc-keeper' `
                -ContentBlocks @(@{ type = 'text'; text = '' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.WordCount | Should -Be 0
        }

        It 'handles extra whitespace between words' {
            $tmpFile = Join-Path $TestDrive 'agent-wc3.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:doc-keeper' `
                -ContentBlocks @(@{ type = 'text'; text = "alpha   beta`ngamma" })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.WordCount | Should -Be 3
        }

        It 'correctly counts words across multiple text content blocks' {
            $tmpFile = Join-Path $TestDrive 'agent-wc4.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:doc-keeper' `
                -ContentBlocks @(
                    @{ type = 'text'; text = 'end' },
                    @{ type = 'text'; text = 'start' }
                )
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            # Without separator, "end"+"start" -> "endstart" = 1 word (the bug this test guards)
            $result.WordCount | Should -Be 2
        }
    }

    Context 'echo detection' {

        It 'sets EchoDetected to true when text contains [Tool:' {
            $tmpFile = Join-Path $TestDrive 'agent-echo1.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:test-writer' `
                -ContentBlocks @(@{ type = 'text'; text = 'Output includes [Tool: read] call.' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.EchoDetected | Should -Be $true
        }

        It 'sets EchoDetected to false when text does not contain [Tool:' {
            $tmpFile = Join-Path $TestDrive 'agent-echo2.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:test-writer' `
                -ContentBlocks @(@{ type = 'text'; text = 'Clean output.' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.EchoDetected | Should -Be $false
        }
    }

    Context 'override flag' {

        It 'sets OverrideFlag to true when parent explicitly requested full detail' {
            $tmpFile = Join-Path $TestDrive 'agent-ovr1.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:research-agent' `
                -ContentBlocks @(@{ type = 'text'; text = 'Providing full detail as requested.' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.OverrideFlag | Should -Be $true
        }

        It 'sets OverrideFlag to false for a response that does not claim override' {
            $tmpFile = Join-Path $TestDrive 'agent-ovr2.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:research-agent' `
                -ContentBlocks @(@{ type = 'text'; text = 'Concise summary only.' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.OverrideFlag | Should -Be $false
        }

        It 'does not false-positive when agent quotes the directive carve-out text' {
            # "The parent may always request full detail" is the canonical carve-out;
            # an agent quoting it should NOT trigger the override flag
            $tmpFile = Join-Path $TestDrive 'agent-ovr3.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:research-agent' `
                -ContentBlocks @(@{ type = 'text'; text = 'The parent may always request full detail.' })
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.OverrideFlag | Should -Be $false
        }
    }

    Context 'missing attributionAgent field' {

        It 'skips event when attributionAgent is absent' {
            $tmpFile = Join-Path $TestDrive 'agent-noattr.jsonl'
            $e = @{
                type    = 'assistant'
                message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = 'Some output.' }) }
            }
            script:Write-JsonlFile -Path $tmpFile -Lines @(($e | ConvertTo-Json -Compress -Depth 10))

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result | Should -BeNullOrEmpty
        }

        It 'skips event when attributionAgent is null' {
            $tmpFile = Join-Path $TestDrive 'agent-nullattr.jsonl'
            $e = @{
                type             = 'assistant'
                attributionAgent = $null
                message          = @{ role = 'assistant'; content = @(@{ type = 'text'; text = 'Out.' }) }
            }
            script:Write-JsonlFile -Path $tmpFile -Lines @(($e | ConvertTo-Json -Compress -Depth 10))

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result | Should -BeNullOrEmpty
        }
    }

    Context 'ToolUseId derivation' {

        It 'strips the agent- prefix from the filename to produce the ToolUseId' {
            $tmpFile = Join-Path $TestDrive 'agent-deadbeef1234.jsonl'
            $line    = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:code-smith'
            script:Write-JsonlFile -Path $tmpFile -Lines @($line)

            $result = Get-SpotcheckRecord -JsonlPath $tmpFile -InScope $script:InScopeAgents

            $result.ToolUseId | Should -Be 'deadbeef1234'
        }
    }

    Context 'baseline-unavailable behavior' {

        # In-process invocation per script-safety contract (#257): no child-pwsh spawn.

        It 'returns the baseline-unavailable message for a non-existent slug dir' {
            $nonExistentDir = Join-Path $TestDrive 'no-such-slug-dir'

            $result = Invoke-ReportingEconomySpotcheck -SlugDirOverride $nonExistentDir -InScope $script:InScopeAgents

            $result.Message       | Should -Match 'Baseline unavailable'
            @($result.Records).Count | Should -Be 0
        }

        It 'returns baseline-unavailable when slug dir exists but has no session subdirs with agent JSONL files' {
            $emptySlugDir = Join-Path $TestDrive 'empty-slug'
            New-Item -ItemType Directory -Path $emptySlugDir -Force | Out-Null

            $result = Invoke-ReportingEconomySpotcheck -SlugDirOverride $emptySlugDir -InScope $script:InScopeAgents

            $result.Message       | Should -Match 'Baseline unavailable'
            @($result.Records).Count | Should -Be 0
        }

        It 'returns collected records when in-scope transcripts exist under the session subdir' {
            # {slug}/{session-uuid}/subagents/agent-*.jsonl — the real nested layout
            $slugDir    = Join-Path $TestDrive 'populated-slug'
            $subagents  = Join-Path (Join-Path $slugDir 'session-uuid-1') 'subagents'
            New-Item -ItemType Directory -Path $subagents -Force | Out-Null
            $line = script:New-AssistantEventLine -AttributionAgent 'agent-orchestra:code-smith' `
                -ContentBlocks @(@{ type = 'text'; text = 'done' })
            script:Write-JsonlFile -Path (Join-Path $subagents 'agent-deadbeef.jsonl') -Lines @($line)

            $result = Invoke-ReportingEconomySpotcheck -SlugDirOverride $slugDir -InScope $script:InScopeAgents

            $result.Message            | Should -BeNullOrEmpty
            @($result.Records).Count   | Should -Be 1
            $result.Records[0].Agent   | Should -Be 'agent-orchestra:code-smith'
        }
    }
}
