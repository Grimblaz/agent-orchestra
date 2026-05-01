#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'cost-rate-table.json' {
    BeforeAll {
        $script:TablePath = Join-Path $PSScriptRoot '..\lib\cost-rate-table.json'
        $script:Table = $null
        if (Test-Path $script:TablePath) {
            $script:Table = Get-Content $script:TablePath -Raw | ConvertFrom-Json
        }
    }

    It 'file exists' { Test-Path $script:TablePath | Should -BeTrue }
    It 'parses without error' { $script:Table | Should -Not -BeNullOrEmpty }
    It 'has version 1' { $script:Table.version | Should -Be '1' }
    It 'has rates_as_of set' { $script:Table.rates_as_of | Should -Not -BeNullOrEmpty }
    It 'has fallback_behavior warn-and-null' { $script:Table.fallback_behavior | Should -Be 'warn-and-null' }
    It 'contains claude-opus-4-7' { $script:Table.rates.'claude-opus-4-7' | Should -Not -BeNullOrEmpty }
    It 'contains claude-sonnet-4-x' { $script:Table.rates.'claude-sonnet-4-x' | Should -Not -BeNullOrEmpty }
    It 'contains claude-haiku-4-x' { $script:Table.rates.'claude-haiku-4-x' | Should -Not -BeNullOrEmpty }
    It 'all rate values are positive' {
        foreach ($model in $script:Table.rates.PSObject.Properties) {
            foreach ($field in @('input_per_mtok','output_per_mtok','cache_creation_per_mtok','cache_read_per_mtok')) {
                $val = $model.Value.$field
                $val | Should -BeGreaterThan 0 -Because "$($model.Name).$field must be positive"
            }
        }
    }
    It 'all rate values are in plausible range $0.01-$200 per Mtok' {
        foreach ($model in $script:Table.rates.PSObject.Properties) {
            foreach ($field in @('input_per_mtok','output_per_mtok','cache_creation_per_mtok','cache_read_per_mtok')) {
                $val = [double]$model.Value.$field
                $val | Should -BeGreaterOrEqual 0.01 -Because "$($model.Name).$field below $0.01/Mtok is implausible"
                $val | Should -BeLessOrEqual 200   -Because "$($model.Name).$field above $200/Mtok is implausible"
            }
        }
    }
}
