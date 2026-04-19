#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for deterministic routing table lookups and gate evaluation.

.DESCRIPTION
    Locks issue #346 Step 4 before production implementation exists:
      - specialist dispatch lookup contract
      - review mode routing lookup contract
      - CE surface identification lookup contract
      - scope classification gate contract
      - express lane gate contract
      - safe fallback for unknown lookups and omitted AND-gate criteria
      - config re-read behavior for single-source-of-truth edits
      - taxonomy category parity with script-safety-contract.Tests.ps1

#>

Describe 'routing tables deterministic contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:RoutingTablesCore = Join-Path $script:RepoRoot 'skills\routing-tables\scripts\routing-tables-core.ps1'
        $script:RoutingConfigPath = Join-Path $script:RepoRoot 'skills\routing-tables\assets\routing-config.json'

        . $script:RoutingTablesCore
    }

    It 'routes src/app/foo.tsx to Code-Smith for specialist dispatch' {
        $result = Invoke-RoutingLookup -Table specialist_dispatch -Key FilePattern -Value 'src/app/foo.tsx'

        $result | Should -Be 'Code-Smith'
    }

    It 'routes src/foo.ts to Code-Smith for specialist dispatch' {
        $result = Invoke-RoutingLookup -Table specialist_dispatch -Key FilePattern -Value 'src/foo.ts'

        $result | Should -Be 'Code-Smith'
    }

    It 'routes FilePattern *.ps1 to Code-Smith for specialist dispatch' {
        $result = Invoke-RoutingLookup -Table specialist_dispatch -Key FilePattern -Value '*.ps1'

        $result | Should -Be 'Code-Smith' -Because 'the specialist dispatch asset now owns explicit file-pattern routing for PowerShell files'
    }

    It 'maps the CE review marker to ce_prosecution mode' {
        $result = Invoke-RoutingLookup -Table review_mode_routing -Key Marker -Value 'Use CE review perspectives'

        $result | Should -Be 'ce_prosecution'
    }

    It 'maps the Web UI surface to the browser-tools routing' {
        $result = Invoke-RoutingLookup -Table surface_identification -Key Surface -Value 'Web UI'

        $result | Should -Be 'Native browser tools (openBrowserPage + screenshotPage)'
    }

    It 'returns the documented CE Gate status marker for no customer surface exactly' {
        $result = Invoke-RoutingLookup -Table surface_identification -Key Surface -Value 'No customer surface'

        $result | Should -Be '⏭️ CE Gate not applicable — {reason}'
    }

    It 'returns abbreviated when all scope-classification criteria are true' {
        $criteria = @{
            acceptance_criteria_clear                     = $true
            touches_three_or_fewer_files_in_single_domain = $true
            no_new_user_facing_behavior                   = $true
            no_cross_cutting_architectural_changes        = $true
            no_ce_gate_scenarios_needed                   = $true
        }

        $result = Test-GateCriteria -Gate scope_classification -Criteria $criteria

        $result | Should -Be 'abbreviated'
    }

    It 'returns qualifies when all express-lane criteria are true' {
        $criteria = @{
            severity_low                 = $true
            strictly_mechanical_fix_type = $true
            no_logic_changes             = $true
            no_test_file_cascade         = $true
            no_stored_id_or_schema_risk  = $true
            scope_one_file_or_less       = $true
        }

        $result = Test-GateCriteria -Gate express_lane -Criteria $criteria

        $result | Should -Be 'qualifies' -Because 'the Step 5 script contract should expose whether the AND gate qualifies, rather than leaking the asset''s internal outcome label'
    }

    It 'returns null for an unknown lookup value' {
        $result = Invoke-RoutingLookup -Table surface_identification -Key Surface -Value 'Firmware console'

        $result | Should -Be $null
    }

    It 're-reads routing-config.json on each invocation so asset edits take effect immediately' {
        $originalJson = Get-Content -Path $script:RoutingConfigPath -Raw

        try {
            $initial = Invoke-RoutingLookup -Table specialist_dispatch -Key FilePattern -Value '*.ps1'
            $initial | Should -Be 'Code-Smith'

            $updatedConfig = $originalJson | ConvertFrom-Json -AsHashtable
            $ps1Entry = $updatedConfig.specialist_dispatch.entries |
                Where-Object { @($_.file_patterns) -contains '*.ps1' } |
                Select-Object -First 1

            $ps1Entry | Should -Not -BeNullOrEmpty -Because 'the routing asset must explicitly carry the *.ps1 mapping for this contract to stay data-driven'

            $ps1Entry.agent = 'Doc-Keeper'
            $updatedJson = $updatedConfig | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($script:RoutingConfigPath, $updatedJson, [System.Text.UTF8Encoding]::new($false))

            $updated = Invoke-RoutingLookup -Table specialist_dispatch -Key FilePattern -Value '*.ps1'

            $updated | Should -Be 'Doc-Keeper' -Because 'Invoke-RoutingLookup must re-read the routing asset instead of using a hardcoded PowerShell override'
        }
        finally {
            [System.IO.File]::WriteAllText($script:RoutingConfigPath, $originalJson, [System.Text.UTF8Encoding]::new($false))
        }
    }

    It 'throws when table name is missing' {
        { Invoke-RoutingLookup -Table '' -Key FilePattern -Value '*.ps1' } | Should -Throw
    }

    It 'treats omitted express-lane criteria as false and does not qualify' {
        $criteria = @{
            severity_low                 = $true
            strictly_mechanical_fix_type = $true
            no_logic_changes             = $true
            no_test_file_cascade         = $true
            no_stored_id_or_schema_risk  = $true
        }

        $result = Test-GateCriteria -Gate express_lane -Criteria $criteria

        $result | Should -Not -Be 'qualifies'
    }
}

Describe 'routing tables asset parity contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:RoutingConfigPath = Join-Path $script:RepoRoot 'skills\routing-tables\assets\routing-config.json'
        $script:ScriptSafetyContract = Join-Path $script:RepoRoot '.github\scripts\Tests\script-safety-contract.Tests.ps1'
    }

    It 'keeps routing-config category enums aligned with the script safety contract taxonomy' {
        $routingConfig = Get-Content -Path $script:RoutingConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $contractContent = Get-Content -Path $script:ScriptSafetyContract -Raw

        $mandatedCategoryMatch = [regex]::Match($contractContent, '(?s)\$script:MandatedCategories\s*=\s*@\((.*?)\)')
        $mandatedCategoryMatch.Success | Should -BeTrue -Because 'the routing-tables enum parity test must compare against the same mandated taxonomy source used by the script safety contract'

        $mandatedCategories = [regex]::Matches($mandatedCategoryMatch.Groups[1].Value, "'([a-z-]+)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object

        $configuredCategories = @($routingConfig.enums.category) | Sort-Object

        ($configuredCategories -join ',') | Should -Be ($mandatedCategories -join ',')
    }
}
