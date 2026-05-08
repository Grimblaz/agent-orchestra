#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'cost-rate-table.json' {
    BeforeAll {
        $script:TablePath = Join-Path $PSScriptRoot '..\lib\cost-rate-table.json'
        $script:AttributionLibPath = Join-Path $PSScriptRoot '..\lib\cost-attribution.ps1'
        $script:Table = $null
        if (Test-Path $script:TablePath) {
            $script:Table = Get-Content $script:TablePath -Raw | ConvertFrom-Json
        }
        if (Test-Path $script:AttributionLibPath) {
            . $script:AttributionLibPath
        }

        function script:Get-RateEntryProvider {
            param([object]$Entry)
            if ($null -ne $Entry.provider -and [string]$Entry.provider -ne '') { return [string]$Entry.provider }
            return 'claude'
        }

        function script:New-RateTableAssistantEvent {
            param(
                [string]$Provider = 'claude',
                [string]$Model = 'shared-model',
                [int]$InputTokens = 1000000,
                [int]$OutputTokens = 0,
                [int]$CacheCreation = 0,
                [int]$CacheRead = 0
            )

            return @{
                type      = 'assistant'
                provider  = $Provider
                agentType = if ($Provider -eq 'copilot') { 'GitHub Copilot Chat' } else { 'agent-orchestra:Code-Conductor' }
                cwd       = if ($Provider -eq 'copilot') { 'copilot-otel://test-workspace' } else { '/c/test/repo' }
                gitBranch = 'feature/test-rate-table'
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

    It 'file exists' { Test-Path $script:TablePath | Should -BeTrue }
    It 'parses without error' { $script:Table | Should -Not -BeNullOrEmpty }
    It 'has version 1' { $script:Table.version | Should -Be '1' }
    It 'has rates_as_of set' { $script:Table.rates_as_of | Should -Not -BeNullOrEmpty }
    It 'has rate_source_url set' { $script:Table.rate_source_url | Should -Not -BeNullOrEmpty }
    It 'has fallback_behavior warn-and-null' { $script:Table.fallback_behavior | Should -Be 'warn-and-null' }
    It 'contains claude-opus-4-7' { $script:Table.rates.'claude-opus-4-7' | Should -Not -BeNullOrEmpty }
    It 'contains claude-sonnet-4-x' { $script:Table.rates.'claude-sonnet-4-x' | Should -Not -BeNullOrEmpty }
    It 'contains claude-haiku-4-x' { $script:Table.rates.'claude-haiku-4-x' | Should -Not -BeNullOrEmpty }
    It 'all rate values are positive' {
        foreach ($model in $script:Table.rates.PSObject.Properties) {
            $provider = script:Get-RateEntryProvider -Entry $model.Value
            if ($provider -eq 'copilot') { continue }
            foreach ($field in @('input_per_mtok', 'output_per_mtok', 'cache_creation_per_mtok', 'cache_read_per_mtok')) {
                $val = $model.Value.$field
                $val | Should -BeGreaterThan 0 -Because "$($model.Name).$field must be positive"
            }
        }
    }
    It 'all rate values are in plausible range $0.01-$200 per Mtok' {
        foreach ($model in $script:Table.rates.PSObject.Properties) {
            $provider = script:Get-RateEntryProvider -Entry $model.Value
            if ($provider -eq 'copilot') { continue }
            foreach ($field in @('input_per_mtok', 'output_per_mtok', 'cache_creation_per_mtok', 'cache_read_per_mtok')) {
                $val = [double]$model.Value.$field
                $val | Should -BeGreaterOrEqual 0.01 -Because "$($model.Name).$field below $0.01/Mtok is implausible"
                $val | Should -BeLessOrEqual 200   -Because "$($model.Name).$field above $200/Mtok is implausible"
            }
        }
    }

        Context 'provider-aware lookup' {
                It 'defaults legacy entries without provider to claude' {
                        foreach ($model in @('claude-opus-4-7', 'claude-sonnet-4-x', 'claude-haiku-4-x')) {
                                script:Get-RateEntryProvider -Entry $script:Table.rates.$model | Should -Be 'claude'
                        }
                }

                It 'matches rates by model and provider so the same model name can have distinct Claude and Copilot rows' {
                        if (-not (Get-Command Get-CostAttribution -ErrorAction SilentlyContinue)) {
                                Set-ItResult -Skipped -Because 'Get-CostAttribution not loaded'
                                return
                        }

                        $tmpRateTable = Join-Path $TestDrive "provider-rate-table-$([System.Guid]::NewGuid().ToString('N')).json"
                        @'
{
    "version": "1",
    "rates_as_of": "2026-05-07",
    "rate_source_url": "https://example.test/rates",
    "fallback_behavior": "warn-and-null",
    "rates": {
        "shared-model-claude": {
            "model": "shared-model",
            "provider": "claude",
            "input_per_mtok": 2.00,
            "output_per_mtok": 4.00,
            "cache_creation_per_mtok": 1.00,
            "cache_read_per_mtok": 0.10,
            "rate_source_url": "https://example.test/claude"
        },
        "shared-model-copilot": {
            "model": "shared-model",
            "provider": "copilot",
            "input_per_mtok": null,
            "output_per_mtok": null,
            "cache_creation_per_mtok": null,
            "cache_read_per_mtok": null,
            "rate_source_url": "https://example.test/copilot"
        }
    }
}
'@ | Set-Content -Path $tmpRateTable -Encoding UTF8

                        $claudeEvent = script:New-RateTableAssistantEvent -Provider 'claude' -Model 'shared-model' -InputTokens 1000000

                        $result = Get-CostAttribution -Events @($claudeEvent) -RateTablePath $tmpRateTable

                        $result.orchestrator_overhead.cost_estimate_usd | Should -Be 2.00 `
                                -Because 'the claude provider row should be selected for a legacy/Claude event with the shared model name'
                        $result.orchestrator_overhead.null_cost_events | Should -Be 0
                }

                It 'treats Copilot null rates as null cost without throwing or using zero-dollar rates' {
                        if (-not (Get-Command Get-CostAttribution -ErrorAction SilentlyContinue)) {
                                Set-ItResult -Skipped -Because 'Get-CostAttribution not loaded'
                                return
                        }

                        $tmpRateTable = Join-Path $TestDrive "null-rate-table-$([System.Guid]::NewGuid().ToString('N')).json"
                        @'
{
    "version": "1",
    "rates_as_of": "2026-05-07",
    "rate_source_url": "https://example.test/rates",
    "fallback_behavior": "warn-and-null",
    "rates": {
        "gpt-5.5-2026-04-23": {
            "provider": "copilot",
            "input_per_mtok": null,
            "output_per_mtok": null,
            "cache_creation_per_mtok": null,
            "cache_read_per_mtok": null,
            "rate_source_url": "https://example.test/copilot"
        }
    }
}
'@ | Set-Content -Path $tmpRateTable -Encoding UTF8

                        $copilotEvent = script:New-RateTableAssistantEvent -Provider 'copilot' -Model 'gpt-5.5-2026-04-23' -InputTokens 1000000 -OutputTokens 500000

                        { $script:result = Get-CostAttribution -Events @($copilotEvent) -RateTablePath $tmpRateTable -WarningVariable warnings } | Should -Not -Throw

                        $script:result.orchestrator_overhead.cost_estimate_usd | Should -BeNullOrEmpty `
                                -Because 'Copilot rows with unpublished per-token rates should produce null/blank cost, not 0.0 dollars'
                        $script:result.orchestrator_overhead.null_cost_events | Should -Be 1
                        ($warnings | Where-Object { $_ -match 'rate.*unavailable|unpublished|null rate' }) | Should -Not -BeNullOrEmpty
                        ($warnings | Where-Object { $_ -match 'unknown model' }) | Should -BeNullOrEmpty
                }
        }

        Context 'rate freshness' {
                It 'uses a 30-day stale threshold for Copilot provider rows while preserving Claude freshness behavior' {
                        $freshnessHelper = Get-Command Get-CostRateTableFreshness -ErrorAction SilentlyContinue
                        $freshnessHelper | Should -Not -BeNullOrEmpty `
                                -Because 'Step 7 needs a rate-table freshness helper that can apply provider-specific stale thresholds'

                        $oldCopilot = Get-CostRateTableFreshness -RatesAsOf '2026-04-01' -Provider 'copilot' -Now '2026-05-07T00:00:00Z'
                        $oldCopilot.is_stale | Should -BeTrue
                        $oldCopilot.stale_after_days | Should -Be 30

                        $oldClaude = Get-CostRateTableFreshness -RatesAsOf '2026-04-01' -Provider 'claude' -Now '2026-05-07T00:00:00Z'
                        $oldClaude.stale_after_days | Should -Not -Be 30 -Because 'Claude should keep the pre-existing threshold behavior'
                }
        }
}
