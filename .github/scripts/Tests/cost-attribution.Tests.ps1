#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-CostAttribution' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-attribution.ps1'
        $script:RendererPath = Join-Path $PSScriptRoot '../lib/cost-pattern-renderer.ps1'
        $script:RateTablePath = Join-Path $PSScriptRoot '../lib/cost-rate-table.json'
        $script:RollingHistoryLibPath = Join-Path $PSScriptRoot '../lib/cost-rolling-history.ps1'

        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }
        if (Test-Path $script:RendererPath) {
            . $script:RendererPath
        }
        if (Test-Path $script:RollingHistoryLibPath) {
            . $script:RollingHistoryLibPath
        }

        # Helper: build a minimal parent assistant event (has cwd to distinguish from subagent events)
        function script:New-AssistantEvent {
            param(
                [string]$Uuid = [System.Guid]::NewGuid().ToString(),
                [string]$Timestamp = '2026-01-01T00:00:00Z',
                [string]$Model = 'claude-sonnet-4-6',
                [int]$InputTokens = 100,
                [int]$OutputTokens = 50,
                [int]$CacheCreation = 0,
                [int]$CacheRead = 0,
                [object[]]$Content = @()
            )
            # Parent events have a cwd field; subagent events do not.
            # Attribution logic uses cwd presence to distinguish parent turns from subagent turns.
            return @{
                type      = 'assistant'
                uuid      = $Uuid
                timestamp = $Timestamp
                cwd       = '/c/test/repo'
                gitBranch = 'feature/test-branch'
                message   = @{
                    model   = $Model
                    usage   = @{
                        input_tokens                = $InputTokens
                        output_tokens               = $OutputTokens
                        cache_creation_input_tokens = $CacheCreation
                        cache_read_input_tokens     = $CacheRead
                    }
                    content = $Content
                }
            }
        }

        function script:New-CopilotAssistantEvent {
            param(
                [string]$Uuid = [System.Guid]::NewGuid().ToString(),
                [string]$Timestamp = '2026-01-01T00:02:00Z',
                [string]$Model = 'gpt-4o-mini-2024-07-18',
                [int]$InputTokens = 300,
                [int]$OutputTokens = 90,
                [object[]]$Content = @()
            )

            return @{
                type      = 'assistant'
                provider  = 'copilot'
                agentType = 'GitHub Copilot Chat'
                uuid      = $Uuid
                timestamp = $Timestamp
                cwd       = 'copilot-otel://copilot-orchestra'
                gitBranch = 'feature/test-branch'
                message   = @{
                    model   = $Model
                    usage   = @{
                        input_tokens                = $InputTokens
                        output_tokens               = $OutputTokens
                        cache_creation_input_tokens = $null
                        cache_read_input_tokens     = $null
                    }
                    content = $Content
                }
            }
        }

        # Helper: build an Agent tool_use content item
        function script:New-AgentDispatch {
            param(
                [string]$SubagentType,
                [string]$Id = [System.Guid]::NewGuid().ToString(),
                [string]$Timestamp = '2026-01-01T00:00:00Z'
            )
            return @{
                type      = 'tool_use'
                id        = $Id
                name      = 'Agent'
                timestamp = $Timestamp
                input     = @{ subagent_type = $SubagentType; prompt = 'do something' }
            }
        }

        # Helper: build a subagent assistant event (no cwd/gitBranch — loaded from subagent transcript)
        function script:New-SubagentEvent {
            param(
                [string]$Uuid = [System.Guid]::NewGuid().ToString(),
                [string]$Timestamp = '2026-01-01T00:01:00Z',
                [string]$Model = 'claude-sonnet-4-6',
                [int]$InputTokens = 200,
                [int]$OutputTokens = 80,
                [int]$CacheCreation = 0,
                [int]$CacheRead = 0
            )
            return @{
                type      = 'assistant'
                uuid      = $Uuid
                timestamp = $Timestamp
                message   = @{
                    model   = $Model
                    usage   = @{
                        input_tokens                = $InputTokens
                        output_tokens               = $OutputTokens
                        cache_creation_input_tokens = $CacheCreation
                        cache_read_input_tokens     = $CacheRead
                    }
                    content = @()
                }
            }
        }
    }

    Context 'agentType mapping' {
        It 'maps agent-orchestra:Experience-Owner to experience port' {
            $dispatch = script:New-AgentDispatch -SubagentType 'agent-orchestra:Experience-Owner'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -InputTokens 100 -OutputTokens 50
            $subEvent = script:New-SubagentEvent -InputTokens 200 -OutputTokens 80

            $events = @($parentEvent, $subEvent)
            $result = Get-CostAttribution -Events $events -RateTablePath $script:RateTablePath

            $result.ports.ContainsKey('experience') | Should -BeTrue
            $result.ports['experience'].dispatch_count | Should -Be 1
        }

        It 'maps experience-owner (lowercase shell) to experience port' {
            $dispatch = script:New-AgentDispatch -SubagentType 'experience-owner'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports.ContainsKey('experience') | Should -BeTrue
            $result.ports['experience'].dispatch_count | Should -Be 1
        }

        It 'maps code-smith to implement-code port' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports.ContainsKey('implement-code') | Should -BeTrue
            $result.ports['implement-code'].dispatch_count | Should -Be 1
        }

        It 'maps agent-orchestra:Code-Critic to review port' {
            $dispatch = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports.ContainsKey('review') | Should -BeTrue
            $result.ports['review'].dispatch_count | Should -Be 1
        }

        It 'maps code-review-response to review port' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-review-response'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports.ContainsKey('review') | Should -BeTrue
        }

        It 'maps Explore to orchestrator-overhead' {
            $dispatch = script:New-AgentDispatch -SubagentType 'Explore'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            # Explore maps to orchestrator-overhead, so no new port entry;
            # parent turn counts as orchestrator-overhead
            $result.orchestrator_overhead.tokens.input | Should -BeGreaterThan 0
        }

        It 'maps general-purpose to dispatches.general_purpose' {
            $dispatch = script:New-AgentDispatch -SubagentType 'general-purpose'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -InputTokens 100 -OutputTokens 50

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.dispatches.general_purpose_count | Should -Be 1
        }

        It 'maps unknown agentType to unattributed-dispatch' {
            $dispatch = script:New-AgentDispatch -SubagentType 'some-future-unknown-agent'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.dispatches.unattributed_count | Should -Be 1
        }

        It 'agentType matching is case-insensitive' {
            $dispatch = script:New-AgentDispatch -SubagentType 'EXPERIENCE-OWNER'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports.ContainsKey('experience') | Should -BeTrue
        }

        It 'maps observed Copilot chat agent name to orchestrator-overhead case-insensitively' -TestCases @(
            @{ AgentType = 'GitHub Copilot Chat' }
            @{ AgentType = 'github copilot chat' }
            @{ AgentType = 'GITHUB COPILOT CHAT' }
        ) {
            param([string]$AgentType)

            Get-AgentTypePort -AgentType $AgentType | Should -Be 'orchestrator-overhead'
        }

        It 'maps unknown Copilot agent names to unattributed-dispatch without changing existing Claude mappings' {
            Get-AgentTypePort -AgentType 'GitHub Copilot Future Specialist' | Should -Be 'unattributed-dispatch'
            Get-AgentTypePort -AgentType 'code-smith' | Should -Be 'implement-code'
            Get-AgentTypePort -AgentType 'Explore' | Should -Be 'orchestrator-overhead'
        }
    }

    Context 'token aggregation' {
        It 'aggregates input/output/cache tokens per port' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -InputTokens 100 -OutputTokens 50 -CacheCreation 20 -CacheRead 30

            $subEvent = script:New-SubagentEvent -InputTokens 200 -OutputTokens 80 -CacheCreation 10 -CacheRead 15

            $events = @($parentEvent, $subEvent)
            $result = Get-CostAttribution -Events $events -RateTablePath $script:RateTablePath

            $port = $result.ports['implement-code']
            # Parent turn attributed to this port + subagent tokens
            $port.tokens.input | Should -Be 300    # 100 + 200
            $port.tokens.output | Should -Be 130   # 50 + 80
            $port.tokens.cache_creation | Should -Be 30  # 20 + 10
            $port.tokens.cache_read | Should -Be 45      # 30 + 15
        }

        It 'computes cost_estimate_usd from rate table' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            # 1000 input, 500 output, 0 cache — easy math with sonnet rates
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -Model 'claude-sonnet-4-6' -InputTokens 1000 -OutputTokens 500

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            # cost = (1000 * 3.00 + 500 * 15.00) / 1_000_000 = (3000 + 7500) / 1_000_000 = 0.0105
            $expected = (1000 * 3.00 + 500 * 15.00) / 1000000
            $actual = $result.ports['implement-code'].cost_estimate_usd
            $actual | Should -BeGreaterOrEqual ($expected - 0.000001)
            $actual | Should -BeLessOrEqual    ($expected + 0.000001)
        }

        It 'records null_cost_events for unknown model' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -Model 'claude-unknown-future-model' -InputTokens 100 -OutputTokens 50

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.ports['implement-code'].null_cost_events | Should -Be 1
            ($wv | Where-Object { $_ -match 'unknown' -or $_ -match 'null' -or $_ -match 'model' }) | Should -Not -BeNullOrEmpty
        }

        It 'computes cache_read_hit_ratio correctly (excludes output from denominator)' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            # input=100, output=50, cache_creation=200, cache_read=300
            # ratio = cache_read / (cache_read + cache_creation + input) = 300 / (300+200+100) = 300/600 = 0.5
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) `
                -InputTokens 100 -OutputTokens 50 -CacheCreation 200 -CacheRead 300

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $ratio = $result.ports['implement-code'].cache_read_hit_ratio
            $ratio | Should -BeGreaterOrEqual 0.4999
            $ratio | Should -BeLessOrEqual    0.5001
        }

        It 'totals row sums all port tokens plus overhead' {
            $dispatch1 = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent1 = script:New-AssistantEvent -Content @($dispatch1) -InputTokens 100 -OutputTokens 50

            # Pre-dispatch overhead event (no Agent dispatch)
            $overheadEvent = script:New-AssistantEvent -Content @() -InputTokens 30 -OutputTokens 10

            $events = @($overheadEvent, $parentEvent1)
            $result = Get-CostAttribution -Events $events -RateTablePath $script:RateTablePath

            # Total input = 100 (code-smith) + 30 (overhead) = 130
            $result.totals.tokens.input | Should -Be 130
            $result.totals.tokens.output | Should -Be 60  # 50 + 10
        }
    }

    Context 'orchestrator-overhead' {
        It 'attributes pre-dispatch parent turns to orchestrator-overhead' {
            # An assistant turn with no Agent tool_use — should go to orchestrator-overhead
            $noDispatchEvent = script:New-AssistantEvent -Content @() -InputTokens 50 -OutputTokens 20

            $result = Get-CostAttribution -Events @($noDispatchEvent) -RateTablePath $script:RateTablePath

            $result.orchestrator_overhead.tokens.input | Should -Be 50
            $result.orchestrator_overhead.tokens.output | Should -Be 20
        }

        It 'routes inline no-dispatch phase-marker <MarkerPort> tokens to the <ExpectedPort> port' -TestCases @(
            @{ MarkerPort = 'experience'; ExpectedPort = 'experience' }
            @{ MarkerPort = 'design'; ExpectedPort = 'design' }
            @{ MarkerPort = 'plan'; ExpectedPort = 'plan' }
        ) {
            param([string]$MarkerPort, [string]$ExpectedPort)

            $noDispatchEvent = script:New-AssistantEvent -Content @() -InputTokens 50 -OutputTokens 20
            $noDispatchEvent['_phase_marker_port'] = $MarkerPort

            $result = Get-CostAttribution -Events @($noDispatchEvent) -RateTablePath $script:RateTablePath

            $result.ports.ContainsKey($ExpectedPort) | Should -BeTrue
            $result.ports[$ExpectedPort].tokens.input | Should -Be 50
            $result.ports[$ExpectedPort].tokens.output | Should -Be 20
            $result.orchestrator_overhead.tokens.input | Should -Be 0
        }

        It 'routes inline no-dispatch phase-marker <MarkerPort> tokens to orchestrator-overhead' -TestCases @(
            @{ MarkerPort = 'orchestrate' }
            @{ MarkerPort = 'code-conductor' }
        ) {
            param([string]$MarkerPort)

            $noDispatchEvent = script:New-AssistantEvent -Content @() -InputTokens 40 -OutputTokens 15
            $noDispatchEvent['_phase_marker_port'] = $MarkerPort

            $result = Get-CostAttribution -Events @($noDispatchEvent) -RateTablePath $script:RateTablePath

            $result.orchestrator_overhead.tokens.input | Should -Be 40
            $result.orchestrator_overhead.tokens.output | Should -Be 15
            $result.ports.ContainsKey('orchestrator-overhead') | Should -BeFalse
        }

        It 'lets Agent dispatch attribution win over phase-marker <MarkerPort> defaults' -TestCases @(
            @{ MarkerPort = 'experience' }
            @{ MarkerPort = 'design' }
            @{ MarkerPort = 'plan' }
        ) {
            param([string]$MarkerPort)

            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -InputTokens 70 -OutputTokens 25
            $parentEvent['_phase_marker_port'] = $MarkerPort

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports.ContainsKey($MarkerPort) | Should -BeFalse
            $result.ports['implement-code'].dispatch_count | Should -Be 1
            $result.ports['implement-code'].tokens.input | Should -Be 70
            $result.ports['implement-code'].tokens.output | Should -Be 25
            $result.orchestrator_overhead.tokens.input | Should -Be 0
        }

        It 'keeps unmarked no-dispatch parent turns as orchestrator-overhead' {
            $noDispatchEvent = script:New-AssistantEvent -Content @() -InputTokens 35 -OutputTokens 12

            $result = Get-CostAttribution -Events @($noDispatchEvent) -RateTablePath $script:RateTablePath

            $result.orchestrator_overhead.tokens.input | Should -Be 35
            $result.orchestrator_overhead.tokens.output | Should -Be 12
            $result.ports.Count | Should -Be 0
        }

        It 'attributes parent turn tokens to dispatched port, not overhead' {
            $dispatch = script:New-AgentDispatch -SubagentType 'issue-planner'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -InputTokens 80 -OutputTokens 30

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            # Parent dispatches to issue-planner -> plan port
            $result.ports['plan'].tokens.input | Should -BeGreaterOrEqual 80
            # overhead should not include these tokens
            $result.orchestrator_overhead.tokens.input | Should -Be 0
        }
    }

    Context 'review port parallel-pass aggregation (D13)' {
        It 'counts all 5 parallel prosecution dispatches in dispatch_count' {
            # Five Agent dispatches to Code-Critic in one parent turn (five-pass two-layer panel)
            $ts = '2026-01-01T00:00:00Z'
            $dispatch1 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch2 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch3 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch4 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch5 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $parentEvent = script:New-AssistantEvent -Content @($dispatch1, $dispatch2, $dispatch3, $dispatch4, $dispatch5) -InputTokens 150 -OutputTokens 60

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports['review'].dispatch_count | Should -Be 5
        }

        It 'sets mixed_regime: true for review port' {
            $ts = '2026-01-01T00:00:00Z'
            $dispatch1 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch2 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch3 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch4 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch5 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $parentEvent = script:New-AssistantEvent -Content @($dispatch1, $dispatch2, $dispatch3, $dispatch4, $dispatch5)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports['review'].mixed_regime | Should -BeTrue
        }
    }

    Context 'empty input' {
        It 'returns zero-valued result for empty events array' {
            $result = Get-CostAttribution -Events @() -RateTablePath $script:RateTablePath

            $result | Should -Not -BeNullOrEmpty
            $result.totals.tokens.input | Should -Be 0
            $result.totals.tokens.output | Should -Be 0
            $result.totals.cost_estimate_usd | Should -Be 0.0
            $result.orchestrator_overhead.tokens.input | Should -Be 0
            $result.dispatches.general_purpose_count | Should -Be 0
            $result.dispatches.unattributed_count | Should -Be 0
        }
    }

    Context 'prompt_size_chars accumulation (Pass2-F2 D4 metric)' {
        It 'accumulates prompt_size_chars from Agent tool_use input.prompt for the dispatched port' {
            # 'do something' is 12 chars — matches New-AgentDispatch default
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports['implement-code'].prompt_size_chars | Should -Be 12  # 'do something'.Length
        }

        It 'sums prompt_size_chars across multiple dispatches to the same port' {
            # Two dispatches to implement-code, each with 12-char prompt
            $dispatch1 = script:New-AgentDispatch -SubagentType 'code-smith'
            $dispatch2 = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch1, $dispatch2)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            # 2 × 12 = 24
            $result.ports['implement-code'].prompt_size_chars | Should -Be 24
        }

        It 'prompt_size_chars defaults to 0 for orchestrator-overhead (no-dispatch parent turns)' {
            $noDispatch = script:New-AssistantEvent -Content @()

            $result = Get-CostAttribution -Events @($noDispatch) -RateTablePath $script:RateTablePath

            # Overhead bucket has no prompt_size_chars field (it's a PortBucket-only metric)
            $result.orchestrator_overhead.ContainsKey('prompt_size_chars') | Should -BeFalse
        }

        It 'New-PortBucket initialises prompt_size_chars to 0' {
            $dispatch = script:New-AgentDispatch -SubagentType 'issue-planner'
            # Override input to omit prompt so chars = 0
            $dispatch['input'] = @{ subagent_type = 'issue-planner' }
            $parentEvent = script:New-AssistantEvent -Content @($dispatch)

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports['plan'].prompt_size_chars | Should -Be 0
        }
    }

    Context 'provider provenance aggregation (#488 CE-F1)' {
        It 'renders mixed Claude and Copilot contributions to the same port as merged with provider YAML' {
            $claudeDispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $claudeEvent = script:New-AssistantEvent `
                -Content @($claudeDispatch) `
                -Model 'claude-sonnet-4-6' `
                -InputTokens 1000 `
                -OutputTokens 200 `
                -CacheCreation 50 `
                -CacheRead 150

            $copilotDispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $copilotEvent = script:New-CopilotAssistantEvent `
                -Content @($copilotDispatch) `
                -Model 'gpt-4o-mini-2024-07-18' `
                -InputTokens 400 `
                -OutputTokens 100

            $result = Get-CostAttribution -Events @($claudeEvent, $copilotEvent) -RateTablePath $script:RateTablePath -WarningVariable costWarnings
            $result['coverage'] = 'claude+copilot'
            $result['install_status'] = 'ok'
            $result['unmapped_session_count'] = 0
            $result['provider_support'] = @('claude', 'copilot')

            $portBucket = $result.ports['implement-code']
            $portBucket.provider_support | Should -Be @('claude', 'copilot')
            $portBucket.providers.ContainsKey('claude') | Should -BeTrue
            $portBucket.providers.ContainsKey('copilot') | Should -BeTrue
            $portBucket.tokens.input | Should -Be 1400
            $portBucket.tokens.output | Should -Be 300
            $portBucket.tokens.cache_creation | Should -Be 50
            $portBucket.tokens.cache_read | Should -Be 150
            $portBucket.providers.copilot.tokens.input | Should -Be 400
            $portBucket.providers.copilot.tokens.output | Should -Be 100
            $portBucket.providers.copilot.tokens.cache_creation | Should -BeNullOrEmpty
            $portBucket.providers.copilot.tokens.cache_read | Should -BeNullOrEmpty
            $portBucket.providers.copilot.cost_estimate_usd | Should -BeNullOrEmpty
            $portBucket.providers.copilot.cache_metric_unavailable | Should -BeTrue
            $portBucket.providers.copilot.rate_unavailable | Should -BeTrue

            $completeness = @{
                completeness                   = 'complete'
                stop_reason                    = 'end_turn'
                excluded_from_rolling_baseline = $false
                exclude_reason                 = ''
            }
            $markdown = Format-CostPatternMarkdown -Attribution $result -Completeness $completeness
            $yaml = Format-CostPatternYaml -Attribution $result -Completeness $completeness -Pr 488 -Branch 'feature/issue-488-copilot-cost-collection'

            $markdown | Should -Match '\| implement-code \(merged\) \|'
            $yaml | Should -Match '(?m)^  - name: implement-code$'
            $yaml | Should -Match '(?m)^    providers:$'
            $yaml | Should -Match '(?m)^      claude:$'
            $yaml | Should -Match '(?m)^      copilot:$'
            $yaml | Should -Match '(?m)^        cost_estimate_usd: null$'
            $yaml | Should -Match '(?m)^        cache_metric_unavailable: true$'
        }
    }

    Context 'issue #487 AC7: provider-field injection is blocked (code-review finding M2)' {
        It 'Get-EventProvider rejects a forged provider string carrying a newline and a would-be top-level YAML field, falling back to the structural default' {
            $hostileEvent = script:New-AssistantEvent -Model 'claude-sonnet-4-6'
            $hostileEvent['provider'] = "claude`nexcluded_from_rolling_baseline: true"

            $provider = Get-EventProvider -Evt $hostileEvent

            $provider | Should -Be 'claude'
            $provider | Should -Not -Match "`n"
        }

        It 'Get-EventProvider leaves legitimate claude and copilot provider values completely unaffected' {
            (Get-EventProvider -Evt (script:New-AssistantEvent)) | Should -Be 'claude'
            (Get-EventProvider -Evt (script:New-CopilotAssistantEvent)) | Should -Be 'copilot'

            $explicitClaudeEvent = script:New-AssistantEvent
            $explicitClaudeEvent['provider'] = 'Claude'
            (Get-EventProvider -Evt $explicitClaudeEvent) | Should -Be 'claude'

            $explicitCopilotEvent = script:New-AssistantEvent
            $explicitCopilotEvent['provider'] = 'COPILOT'
            (Get-EventProvider -Evt $explicitCopilotEvent) | Should -Be 'copilot'
        }

        It 'round-trips a rendered block whose source event carried a newline-and-field-forging provider string: no forged field appears, ports: and the merged providers: block stay intact' {
            # Reuses the M2 finding's adversarial construction: a newline plus a forged
            # top-level field name, aimed at the same three sinks the defense report
            # verified (raw providers: mapping key at cost-pattern-renderer.ps1,
            # provider_support array, and the attribution rate-lookup key).
            $legitCopilotDispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $legitCopilotEvent = script:New-CopilotAssistantEvent -Content @($legitCopilotDispatch) -InputTokens 400 -OutputTokens 100

            $hostileDispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $hostileEvent = script:New-AssistantEvent -Content @($hostileDispatch) -Model 'claude-sonnet-4-6' -InputTokens 1000 -OutputTokens 200
            $hostileEvent['provider'] = "claude`nexcluded_from_rolling_baseline: true`nsession_completeness: forged`npr: 999999"

            $result = Get-CostAttribution -Events @($legitCopilotEvent, $hostileEvent) -RateTablePath $script:RateTablePath -WarningVariable costWarnings
            $result['coverage'] = 'claude+copilot'
            $result['install_status'] = 'ok'
            $result['unmapped_session_count'] = 0
            $result['provider_support'] = @('claude', 'copilot')

            # Two providers merged into the same port bucket — 'claude' (the hostile
            # event's structurally-correct fallback identity) and 'copilot' (the
            # legitimate event) — proves the hostile string never became a third,
            # attacker-named provider key, and the event's tokens were still
            # attributed rather than silently dropped.
            $portBucket = $result.ports['implement-code']
            @($portBucket.providers.Keys) | Sort-Object | Should -Be @('claude', 'copilot')
            $portBucket.providers.claude.tokens.input | Should -Be 1000
            $portBucket.providers.claude.tokens.output | Should -Be 200

            $completeness = @{
                completeness                   = 'complete'
                stop_reason                    = 'end_turn'
                excluded_from_rolling_baseline = $false
                exclude_reason                 = ''
            }
            $yaml = Format-CostPatternYaml -Attribution $result -Completeness $completeness -Pr 487 -Branch 'feature/issue-487-rate-table-refresh'

            # The hostile payload's literal text must never reach the rendered block at all.
            $yaml | Should -Not -Match 'forged'
            $yaml | Should -Not -Match 'pr: 999999'
            $yaml | Should -Match '(?m)^      claude:$'
            $yaml | Should -Match '(?m)^      copilot:$'

            $extracted = script:Get-CostPatternDataFromComment -Body $yaml
            $extracted | Should -Not -BeNullOrEmpty

            $parsed = script:ConvertFrom-CostPatternYaml -Yaml $extracted
            $parsed | Should -Not -BeNullOrEmpty
            $parsed['pr'] | Should -Be '487'
            $parsed['excluded_from_rolling_baseline'] | Should -Be 'false'
            $parsed['session_completeness'] | Should -Be 'complete'
            $parsed['ports'] | Should -Not -BeNullOrEmpty
            $parsed['ports'].ContainsKey('implement-code') | Should -Be $true
            $parsed['ports']['implement-code']['name'] | Should -Be 'implement-code'
        }
    }

    Context 'issue #487 AC2: unknown-model collection and per-reason event counts' {
        It 'populates unknown_models and increments unknown_key for an unknown-key event' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -Model 'claude-unknown-future-model' -InputTokens 100 -OutputTokens 50

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -Be @('claude/claude-unknown-future-model')
            $result.null_cost_events_by_reason.unknown_key | Should -Be 1
            $result.null_cost_events_by_reason.rate_unavailable | Should -Be 0
            $result.null_cost_events_by_reason.empty_model | Should -Be 0
        }

        It 'never names the <synthetic> marker as an addable unknown model (issue #487 post-render fix)' {
            # '<synthetic>' is what Claude Code puts in message.model for assistant
            # messages it injects itself (API-error notices, "No response requested."
            # status lines). Verified against the real transcript history: every such
            # event carries all-zero usage, so its true cost is exactly 0.00. Before
            # this fix it landed in unknown_models and the rendered Note instructed
            # maintainers to add a cost-rate-table.json row for it — a false-actionable
            # instruction for a non-model that can never resolve.
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $syntheticEvent = script:New-AssistantEvent -Content @($dispatch) -Model '<synthetic>' `
                -InputTokens 0 -OutputTokens 0 -CacheCreation 0 -CacheRead 0

            $result = Get-CostAttribution -Events @($syntheticEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -BeNullOrEmpty -Because 'a synthetic marker is not an unknown model at any layer — it must never enter the set'
            $result.null_cost_events_by_reason.unknown_key | Should -Be 0
            $result.null_cost_events_by_reason.empty_model | Should -Be 0
            $result.null_cost_events_by_reason.rate_unavailable | Should -Be 0
            $result.ports['implement-code'].null_cost_events | Should -Be 0 -Because 'zero tokens times any rate is exactly 0.00 — the cost is known, not null'
            $result.ports['implement-code'].cost_estimate_usd | Should -Be 0.0 -Because 'counting the marker as a null-cost event would rewrite a genuinely-0.00 bucket cost to $null, which is the misleading-null class issue #487 exists to eliminate'
        }

        It 'renders no add-a-rate-row Note clause for a <synthetic>-only session (issue #487 post-render fix)' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $syntheticEvent = script:New-AssistantEvent -Content @($dispatch) -Model '<synthetic>' `
                -InputTokens 0 -OutputTokens 0 -CacheCreation 0 -CacheRead 0

            $result = Get-CostAttribution -Events @($syntheticEvent) -RateTablePath $script:RateTablePath -WarningVariable wv
            $completeness = @{
                completeness                   = 'complete'
                stop_reason                    = 'end_turn'
                excluded_from_rolling_baseline = $false
                exclude_reason                 = ''
            }

            $markdown = Format-CostPatternMarkdown -Attribution $result -Completeness $completeness

            $markdown | Should -Not -Match 'add rows to' -Because 'the Note must never tell a maintainer to add a rate row for a marker that is not a model'
            $markdown | Should -Not -Match ([regex]::Escape('<synthetic>')) -Because 'the marker must not be named anywhere in the rendered Note'
        }

        It 'still surfaces <synthetic> loudly if it ever carries real tokens (guard is narrow by design)' {
            # The suppression is scoped to the proven case (all-zero usage). If a future
            # Claude Code release ever emits this marker with real tokens, the event must
            # NOT be silently dropped — it falls through to the normal unknown-model path
            # so the cost surfaces instead of vanishing.
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $tokenBearingSynthetic = script:New-AssistantEvent -Content @($dispatch) -Model '<synthetic>' `
                -InputTokens 500 -OutputTokens 120

            $result = Get-CostAttribution -Events @($tokenBearingSynthetic) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.null_cost_events_by_reason.unknown_key | Should -Be 1 -Because 'real tokens attributed to a non-model is a genuine anomaly that must fail loud, not be silently suppressed'
            $result.unknown_models | Should -Be @('claude/<synthetic>')
        }

        It 'leaves unknown_models empty while incrementing rate_unavailable for a Copilot known-key event' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $copilotEvent = script:New-CopilotAssistantEvent -Content @($dispatch) -Model 'gpt-4o-mini-2024-07-18' -InputTokens 300 -OutputTokens 90

            $result = Get-CostAttribution -Events @($copilotEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -BeNullOrEmpty -Because 'gpt-4o-mini-2024-07-18/copilot is a known key with an intentionally-null rate, not an unknown key'
            $result.null_cost_events_by_reason.rate_unavailable | Should -Be 1
            $result.null_cost_events_by_reason.unknown_key | Should -Be 0
        }

        It 'increments empty_model and names nothing in unknown_models for a null/empty-model event' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -Model '' -InputTokens 100 -OutputTokens 50

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -BeNullOrEmpty
            $result.null_cost_events_by_reason.empty_model | Should -Be 1
            $result.null_cost_events_by_reason.unknown_key | Should -Be 0
            $result.null_cost_events_by_reason.rate_unavailable | Should -Be 0
        }

        It 'threads the tracker through the orchestrator-overhead branch (no-dispatch parent turn)' {
            $noDispatchEvent = script:New-AssistantEvent -Content @() -Model 'claude-unknown-future-model' -InputTokens 40 -OutputTokens 15

            $result = Get-CostAttribution -Events @($noDispatchEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -Be @('claude/claude-unknown-future-model')
            $result.null_cost_events_by_reason.unknown_key | Should -Be 1
            $result.orchestrator_overhead.null_cost_events | Should -Be 1
        }

        It 'threads the tracker through the phase-marker branch (inline no-dispatch phase-marker turn)' {
            $noDispatchEvent = script:New-AssistantEvent -Content @() -Model 'claude-unknown-future-model' -InputTokens 40 -OutputTokens 15
            $noDispatchEvent['_phase_marker_port'] = 'design'

            $result = Get-CostAttribution -Events @($noDispatchEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -Be @('claude/claude-unknown-future-model')
            $result.null_cost_events_by_reason.unknown_key | Should -Be 1
            $result.ports['design'].null_cost_events | Should -Be 1
        }

        It 'threads the tracker through the general-purpose dispatch branch' {
            $dispatch = script:New-AgentDispatch -SubagentType 'general-purpose'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -Model 'claude-unknown-future-model' -InputTokens 100 -OutputTokens 50

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -Be @('claude/claude-unknown-future-model')
            $result.null_cost_events_by_reason.unknown_key | Should -Be 1
            $result.ports['dispatches.general_purpose'].null_cost_events | Should -Be 1
        }

        It 'threads the tracker through the subagent-inherited branch' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -Model 'claude-sonnet-4-6' -InputTokens 100 -OutputTokens 50
            $subEvent = script:New-SubagentEvent -Model 'claude-unknown-future-model' -InputTokens 200 -OutputTokens 80

            $result = Get-CostAttribution -Events @($parentEvent, $subEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -Be @('claude/claude-unknown-future-model')
            $result.null_cost_events_by_reason.unknown_key | Should -Be 1
            $result.ports['implement-code'].null_cost_events | Should -Be 1
        }

        It 'dedups unknown_models by (provider, model) across multiple events' {
            $dispatch1 = script:New-AgentDispatch -SubagentType 'code-smith'
            $event1 = script:New-AssistantEvent -Content @($dispatch1) -Model 'claude-unknown-future-model' -InputTokens 100 -OutputTokens 50
            $dispatch2 = script:New-AgentDispatch -SubagentType 'code-smith'
            $event2 = script:New-AssistantEvent -Content @($dispatch2) -Model 'claude-unknown-future-model' -InputTokens 60 -OutputTokens 20

            $result = Get-CostAttribution -Events @($event1, $event2) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.unknown_models | Should -Be @('claude/claude-unknown-future-model')
            $result.null_cost_events_by_reason.unknown_key | Should -Be 2
        }
    }

    Context 'issue #487 CE-F2: rate_unavailable_malformed vs by-design classification' {
        It 'does not increment rate_unavailable_malformed and leaves malformed_rate_models empty for a fully-null (by-design) Copilot row' {
            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $copilotEvent = script:New-CopilotAssistantEvent -Content @($dispatch) -Model 'gpt-4o-mini-2024-07-18' -InputTokens 300 -OutputTokens 90

            $result = Get-CostAttribution -Events @($copilotEvent) -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.null_cost_events_by_reason.rate_unavailable | Should -Be 1
            $result.null_cost_events_by_reason.rate_unavailable_malformed | Should -Be 0
            $result.malformed_rate_models | Should -BeNullOrEmpty
        }

        It 'increments rate_unavailable_malformed and names the model for a partially-null rate-table row' {
            $tmpRateTable = Join-Path $TestDrive "malformed-rate-table-$([System.Guid]::NewGuid().ToString('N')).json"
            @'
{
    "version": "1",
    "rates_as_of": "2026-07-14",
    "rate_source_url": "https://example.test/rates",
    "fallback_behavior": "warn-and-null",
    "rates": {
        "claude-fatfingered-model": {
            "input_per_mtok": 3.00,
            "output_per_mtok": 15.00,
            "cache_creation_per_mtok": 6.00,
            "cache_read_per_mtok": null
        }
    }
}
'@ | Set-Content -Path $tmpRateTable -Encoding UTF8

            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -Model 'claude-fatfingered-model' -InputTokens 100 -OutputTokens 50

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $tmpRateTable -WarningVariable wv

            $result.null_cost_events_by_reason.rate_unavailable | Should -Be 1 -Because 'rate_unavailable stays the union total for pre-CE-F2 readers'
            $result.null_cost_events_by_reason.rate_unavailable_malformed | Should -Be 1
            $result.malformed_rate_models | Should -Be @('claude/claude-fatfingered-model')
            $result.unknown_models | Should -BeNullOrEmpty -Because 'the model resolved a known rate-table row; this is not an unknown-key event'
        }

        It 'keeps rate_unavailable as the union total across one by-design and one malformed event in the same run' {
            $tmpRateTable = Join-Path $TestDrive "mixed-rate-table-$([System.Guid]::NewGuid().ToString('N')).json"
            @'
{
    "version": "1",
    "rates_as_of": "2026-07-14",
    "rate_source_url": "https://example.test/rates",
    "fallback_behavior": "warn-and-null",
    "rates": {
        "claude-fatfingered-model": {
            "input_per_mtok": 3.00,
            "output_per_mtok": 15.00,
            "cache_creation_per_mtok": 6.00,
            "cache_read_per_mtok": null
        },
        "copilot-model-x": {
            "model": "model-x",
            "provider": "copilot",
            "input_per_mtok": null,
            "output_per_mtok": null,
            "cache_creation_per_mtok": null,
            "cache_read_per_mtok": null
        }
    }
}
'@ | Set-Content -Path $tmpRateTable -Encoding UTF8

            $dispatch = script:New-AgentDispatch -SubagentType 'code-smith'
            $malformedEvent = script:New-AssistantEvent -Content @($dispatch) -Model 'claude-fatfingered-model' -InputTokens 100 -OutputTokens 50
            $byDesignEvent = script:New-CopilotAssistantEvent -Model 'model-x' -InputTokens 300 -OutputTokens 90

            $result = Get-CostAttribution -Events @($malformedEvent, $byDesignEvent) -RateTablePath $tmpRateTable -WarningVariable wv

            $result.null_cost_events_by_reason.rate_unavailable | Should -Be 2
            $result.null_cost_events_by_reason.rate_unavailable_malformed | Should -Be 1
            $result.malformed_rate_models | Should -Be @('claude/claude-fatfingered-model')
        }
    }

    Context 'issue #487 AC1: #813-shaped fixture' {
        It 'produces null_cost_events == 0 across every bucket for a #813-shaped mix of the six new rate-table keys' {
            # Cache-read-heavy events attributed to orchestrator_overhead (no Agent dispatch —
            # mirrors #813's recorded mix, where ~97% of cache reads landed on orchestrator-overhead turns).
            $overheadEvents = @(
                script:New-AssistantEvent -Model 'claude-fable-5' -InputTokens 200 -OutputTokens 20 -CacheCreation 500 -CacheRead 40000
                script:New-AssistantEvent -Model 'claude-opus-4-8' -InputTokens 200 -OutputTokens 20 -CacheCreation 500 -CacheRead 35000
                script:New-AssistantEvent -Model 'claude-sonnet-5' -InputTokens 200 -OutputTokens 20 -CacheCreation 500 -CacheRead 30000
            )

            # Output-heavy events attributed to a review-style dispatch (agent-orchestra:Code-Critic maps to the 'review' port).
            $reviewModels = @('claude-sonnet-4-6', 'claude-haiku-4-5', 'claude-haiku-4-5-20251001')
            $reviewEvents = foreach ($model in $reviewModels) {
                $dispatch = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic'
                script:New-AssistantEvent -Content @($dispatch) -Model $model -InputTokens 300 -OutputTokens 6000 -CacheCreation 0 -CacheRead 0
            }

            $events = @($overheadEvents) + @($reviewEvents)
            $result = Get-CostAttribution -Events $events -RateTablePath $script:RateTablePath -WarningVariable wv

            $result.orchestrator_overhead.null_cost_events | Should -Be 0 -Because 'all three cache-read-heavy models (claude-fable-5, claude-opus-4-8, claude-sonnet-5) must resolve against the refreshed rate table'
            $result.ports.ContainsKey('review') | Should -BeTrue
            $result.ports['review'].null_cost_events | Should -Be 0 -Because 'all three output-heavy models (claude-sonnet-4-6, claude-haiku-4-5, claude-haiku-4-5-20251001) must resolve against the refreshed rate table'

            foreach ($portName in $result.ports.Keys) {
                $result.ports[$portName].null_cost_events | Should -Be 0 -Because "port '$portName' should have zero null-cost events once all six new rate-table keys are present"
            }

            $wv | Should -BeNullOrEmpty -Because 'no unknown-model or rate-unavailable warnings should fire once the rate table covers every model in the fixture'
        }
    }
}
