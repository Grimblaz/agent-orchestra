#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Existence and well-formedness guard for the goal-run harness schema
    files (issue #874, plan step 1, AC2).
#>

Describe 'goal-run schema files' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HaltReportSchemaPath = Join-Path $script:RepoRoot 'skills/goal-run/schemas/goal-halt-report.schema.json'
        $script:RunLogSchemaPath = Join-Path $script:RepoRoot 'skills/goal-run/schemas/goal-run-log.schema.json'
    }

    It 'resolves the goal-halt-report schema file via Test-Path' {
        Test-Path -LiteralPath $script:HaltReportSchemaPath | Should -Be $true
    }

    It 'resolves the goal-run-log schema file via Test-Path' {
        Test-Path -LiteralPath $script:RunLogSchemaPath | Should -Be $true
    }

    It 'parses the goal-halt-report schema as well-formed JSON' {
        { Get-Content -LiteralPath $script:HaltReportSchemaPath -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'parses the goal-run-log schema as well-formed JSON' {
        { Get-Content -LiteralPath $script:RunLogSchemaPath -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'declares additionalProperties:false (closed schema) on the halt-report schema' {
        $parsed = Get-Content -LiteralPath $script:HaltReportSchemaPath -Raw | ConvertFrom-Json
        $parsed.additionalProperties | Should -Be $false
    }

    It 'declares additionalProperties:false (closed schema) on the run-log schema' {
        $parsed = Get-Content -LiteralPath $script:RunLogSchemaPath -Raw | ConvertFrom-Json
        $parsed.additionalProperties | Should -Be $false
    }
}
