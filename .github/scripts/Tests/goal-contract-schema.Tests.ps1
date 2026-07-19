#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED tests for the goal-contract JSON Schema (issue #872, frame-slice s1).

.DESCRIPTION
    Contract under test:
      skills/plan-authoring/schemas/goal-contract.schema.json is a draft-07
      JSON Schema, closed (additionalProperties: false) at every object
      level, encoding the 872-D2 field set. These tests are RED until the
      schema file lands in frame-slice s2; they must fail because the
      artifact is absent, not because of a syntax error in this file.

      Schema tests: valid JSON; declares draft-07; additionalProperties
      false at every object level; a positive fixture with a populated
      evidence_obligations.experience_obligations[] entry (the only
      >=3-deep path) and an optional falsifier; twelve negative fixtures
      (missing targets, targets: [], category outside enum, unknown halt
      literal, three-of-five halt_conditions, duplicated halt literal,
      missing a required budget field, extra root key, schema_version: 2,
      and contract_hash absent / empty / 12-char).
#>

Describe 'goal-contract.schema.json' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SchemaPath = Join-Path $script:RepoRoot 'skills/plan-authoring/schemas/goal-contract.schema.json'
        $script:SchemaRaw  = if (Test-Path -LiteralPath $script:SchemaPath) { Get-Content -LiteralPath $script:SchemaPath -Raw } else { $null }
        $script:Schema     = if ($null -ne $script:SchemaRaw) { $script:SchemaRaw | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $null }

        # Recursive walker: every subschema that describes an object (declares
        # "type": "object" or carries a "properties" map) must set
        # additionalProperties: false explicitly. Returns a list of JSON-pointer-ish
        # paths that are missing that closure.
        function script:Get-GCSchemaObjectViolations {
            param(
                [Parameter(Mandatory)][AllowNull()]$Node,
                [string]$Path = '#'
            )

            $violations = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $Node) { return $violations }

            $isObjectSchema = $false
            if ($Node.PSObject.Properties.Match('type').Count -gt 0 -and $Node.type -eq 'object') { $isObjectSchema = $true }
            if ($Node.PSObject.Properties.Match('properties').Count -gt 0) { $isObjectSchema = $true }

            if ($isObjectSchema) {
                $hasClosedAdditionalProperties = ($Node.PSObject.Properties.Match('additionalProperties').Count -gt 0) -and ($Node.additionalProperties -eq $false)
                if (-not $hasClosedAdditionalProperties) {
                    $violations.Add($Path) | Out-Null
                }
            }

            if ($Node.PSObject.Properties.Match('properties').Count -gt 0) {
                foreach ($propertyName in $Node.properties.PSObject.Properties.Name) {
                    foreach ($childViolation in (script:Get-GCSchemaObjectViolations -Node $Node.properties.$propertyName -Path "$Path/properties/$propertyName")) {
                        $violations.Add($childViolation) | Out-Null
                    }
                }
            }

            if ($Node.PSObject.Properties.Match('items').Count -gt 0) {
                foreach ($childViolation in (script:Get-GCSchemaObjectViolations -Node $Node.items -Path "$Path/items")) {
                    $violations.Add($childViolation) | Out-Null
                }
            }

            return $violations
        }

        # Fresh 872-D2-shaped fixture builder. Each call returns brand-new nested
        # collections so per-test mutation never bleeds into another test.
        function script:New-GCFixtureContract {
            return [ordered]@{
                schema_version = 1
                issue          = 872
                contract_hash  = ('0' * 64)
                targets        = @(
                    [ordered]@{
                        id        = 'T1'
                        ac_ref    = 'AC1'
                        category  = 'structure-presence'
                        check     = 'pwsh -NoProfile -File .github/scripts/example-check.ps1'
                        expected  = 'exit 0; example check passes'
                        falsifier = 'A vacuous pass would look like an accumulator silently resetting null to zero; this check asserts the raw pre-accumulation value.'
                        source    = $null
                    }
                )
                invariants = @(
                    'full-pester-suite-no-new-failures',
                    'test-diff-integrity'
                )
                evidence_obligations = [ordered]@{
                    checkpoint_commits      = 'per-target-green'
                    run_log                 = 'deviation entries + experience observations per checkpoint'
                    experience_obligations  = @(
                        [ordered]@{
                            scenario = 'S2'
                            surface  = 'cli'
                        }
                    )
                    required_markers        = @('pipeline-metrics-credits', 'goal-run-class')
                }
                general_experience_standard = 'Canonical clause and four guardrails, verbatim from #848 D8.'
                halt_conditions = @(
                    'unachievable-target',
                    'invariant-conflict',
                    'budget-exhausted',
                    'gate-input-needed',
                    'chain-stage-failure'
                )
                budget = [ordered]@{
                    tokens            = 100000
                    wall_clock        = '4h'
                    chain_sub_ceiling = 2
                    non_convergence   = 'halt-report'
                }
            }
        }

        function script:ConvertTo-GCFixtureJson {
            param([Parameter(Mandatory)]$Contract)
            return ($Contract | ConvertTo-Json -Depth 20)
        }
    }

    Context 'File and shape' {
        It 'schema file exists' {
            $script:SchemaPath | Should -Exist -Because 'skills/plan-authoring/schemas/goal-contract.schema.json is the frame-slice s2 deliverable this test pins'
        }

        It 'parses as valid JSON' {
            $script:SchemaPath | Should -Exist -Because 'the schema file must exist before it can be parsed'
            { $script:SchemaRaw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
        }

        It 'declares JSON Schema draft-07' {
            $script:Schema | Should -Not -BeNullOrEmpty -Because 'the schema file must exist and parse before its $schema declaration can be checked'
            $script:Schema.'$schema' | Should -Be 'http://json-schema.org/draft-07/schema#'
        }

        It 'declares additionalProperties: false at every object-typed schema level' {
            $script:Schema | Should -Not -BeNullOrEmpty -Because 'the schema file must exist and parse before structural closure can be checked'
            $violations = script:Get-GCSchemaObjectViolations -Node $script:Schema
            $violations | Should -BeNullOrEmpty -Because "these schema paths allow additional properties: $($violations -join ', ')"
        }
    }

    Context 'Positive fixture' {
        It 'validates a fixture with a populated evidence_obligations.experience_obligations[] entry and a falsifier' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeTrue
        }
    }

    Context 'Negative fixtures' {
        It 'rejects a contract missing targets' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.Remove('targets')
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a contract with targets: []' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.targets = @()
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a target category outside the five-value enum' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.targets[0].category = 'invalid-category'
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects an unknown halt_conditions literal' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.halt_conditions[0] = 'not-a-real-halt-condition'
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects halt_conditions with only three of the five required literals' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.halt_conditions = @('unachievable-target', 'invariant-conflict', 'budget-exhausted')
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a duplicated halt_conditions literal' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.halt_conditions = @('unachievable-target', 'unachievable-target', 'budget-exhausted', 'gate-input-needed', 'chain-stage-failure')
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a contract missing a required budget field' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.budget.Remove('wall_clock')
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects an extra root key' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract['extra_root_key'] = $true
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects schema_version: 2' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.schema_version = 2
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a contract with contract_hash absent' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.Remove('contract_hash')
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a contract with contract_hash: ""' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.contract_hash = ''
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a 12-char contract_hash' {
            $script:SchemaRaw | Should -Not -BeNullOrEmpty -Because 'schema file must exist before validation can run'
            $contract = script:New-GCFixtureContract
            $contract.contract_hash = 'abcdef012345'
            $json = script:ConvertTo-GCFixtureJson -Contract $contract
            Test-Json -Json $json -Schema $script:SchemaRaw -ErrorAction SilentlyContinue | Should -BeFalse
        }
    }
}
