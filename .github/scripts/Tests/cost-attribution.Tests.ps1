#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-CostAttribution' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-attribution.ps1'
        $script:RateTablePath = Join-Path $PSScriptRoot '..\lib\cost-rate-table.json'

        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }

        # Helper: build a minimal parent assistant event (has cwd to distinguish from subagent events)
        function script:New-AssistantEvent {
            param(
                [string]$Uuid = [System.Guid]::NewGuid().ToString(),
                [string]$Timestamp = '2026-01-01T00:00:00Z',
                [string]$Model = 'claude-sonnet-4-x',
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
                [string]$Model = 'claude-sonnet-4-x',
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

        # Sonnet-4-x rates for cost calculation verification
        $script:SonnetRates = @{
            input_per_mtok          = 3.00
            output_per_mtok         = 15.00
            cache_creation_per_mtok = 3.75
            cache_read_per_mtok     = 0.30
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
            $parentEvent = script:New-AssistantEvent -Content @($dispatch) -Model 'claude-sonnet-4-x' -InputTokens 1000 -OutputTokens 500

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
        It 'counts all 3 parallel prosecution dispatches in dispatch_count' {
            # Three Agent dispatches to Code-Critic in one parent turn (parallel pass)
            $ts = '2026-01-01T00:00:00Z'
            $dispatch1 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch2 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch3 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $parentEvent = script:New-AssistantEvent -Content @($dispatch1, $dispatch2, $dispatch3) -InputTokens 150 -OutputTokens 60

            $result = Get-CostAttribution -Events @($parentEvent) -RateTablePath $script:RateTablePath

            $result.ports['review'].dispatch_count | Should -Be 3
        }

        It 'sets mixed_regime: true for review port' {
            $ts = '2026-01-01T00:00:00Z'
            $dispatch1 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch2 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $dispatch3 = script:New-AgentDispatch -SubagentType 'agent-orchestra:Code-Critic' -Timestamp $ts
            $parentEvent = script:New-AssistantEvent -Content @($dispatch1, $dispatch2, $dispatch3)

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
}
