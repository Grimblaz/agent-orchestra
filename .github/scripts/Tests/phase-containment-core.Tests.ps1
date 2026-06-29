#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for phase-containment-core.ps1 (issue #762, TDD red-green).
#
# File under test: .github/scripts/lib/phase-containment-core.ps1
#
# At RED phase the lib does NOT exist yet, so all It-blocks fail with a
# canonical RED signal: "script not found" or "function not found".
#
# GREEN lands the lib and turns these RED signals green.
#
# NOTE: Do NOT import powershell-yaml or use ConvertFrom-Yaml here.
# The hand-rolled parser functions from phase-containment-core.ps1 are used directly.

BeforeAll {
    $script:LibRoot = Join-Path $PSScriptRoot '..' 'lib'
    . (Join-Path $script:LibRoot 'phase-containment-core.ps1')
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

Describe 'Get-PhaseContainmentBlock' {
    It 'extracts YAML content from a valid phase-containment block' {
        $text = @"
Some preamble text.

<!-- phase-containment-762 -->
finding_key: code-review:gh-1234
introduced_phase: experience
<!-- /phase-containment-762 -->

Some epilogue.
"@
        $result = Get-PhaseContainmentBlock -Text $text -Id '762'
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match 'finding_key'
        $result | Should -Match 'introduced_phase'
    }

    It 'returns $null when block is not found' {
        $text = 'No containment block here.'
        $result = Get-PhaseContainmentBlock -Text $text -Id '999'
        $result | Should -BeNullOrEmpty
    }

    It 'strips code fences from extracted content' {
        $text = @"
<!-- phase-containment-100 -->
``` yaml
finding_key: code-review:gh-9999
catchable_phase: design
```
<!-- /phase-containment-100 -->
"@
        $result = Get-PhaseContainmentBlock -Text $text -Id '100'
        $result | Should -Not -Match '```'
        $result | Should -Match 'finding_key'
    }
}

Describe 'ConvertFrom-PhaseContainmentYaml' {
    It 'parses all 9 required fields' {
        $yaml = @"
finding_key: code-review:gh-4829001234
introduced_phase: experience
catchable_phase: design
caught_stage: code-review
escape_distance: 2
severity: high
systemic_fix_type: instruction
category: architecture
apparatus_meta: false
seed: false
"@
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result | Should -Not -BeNullOrEmpty
        $result['finding_key']       | Should -Be 'code-review:gh-4829001234'
        $result['introduced_phase']  | Should -Be 'experience'
        $result['catchable_phase']   | Should -Be 'design'
        $result['caught_stage']      | Should -Be 'code-review'
        $result['escape_distance']   | Should -Be 2
        $result['severity']          | Should -Be 'high'
        $result['systemic_fix_type'] | Should -Be 'instruction'
        $result['category']          | Should -Be 'architecture'
        $result['apparatus_meta']    | Should -Be $false
        $result['seed']              | Should -Be $false
    }

    It 'parses escape_distance as an integer' {
        $yaml = "escape_distance: 3"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result['escape_distance'] | Should -BeOfType [int]
        $result['escape_distance'] | Should -Be 3
    }

    It 'parses apparatus_meta "true" as $true' {
        $yaml = "apparatus_meta: true"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result['apparatus_meta'] | Should -Be $true
    }

    It 'defaults apparatus_meta to $false when absent' {
        $yaml = "finding_key: code-review:gh-1"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result['apparatus_meta'] | Should -Be $false
    }

    It 'parses seed boolean correctly' {
        $yaml = "seed: true"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result['seed'] | Should -Be $true

        $yaml2 = "seed: false"
        $result2 = ConvertFrom-PhaseContainmentYaml -Yaml $yaml2
        $result2['seed'] | Should -Be $false
    }
}

Describe 'Test-PhaseContainmentEntry - valid entry' {
    It 'passes a well-formed entry: introduced=experience, catchable=design, caught=code-review, escape_distance=2' {
        # escape_distance = projection(code-review=3) - ordinal(design=1) = 2
        $entry = @{
            finding_key       = 'code-review:gh-5555'
            introduced_phase  = 'experience'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 2
            severity          = 'medium'
            systemic_fix_type = 'skill'
            category          = 'pattern'
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $true
        $result.Errors  | Should -BeNullOrEmpty
    }
}

Describe 'Test-PhaseContainmentEntry - missing required field' {
    It 'returns IsValid=$false and error mentioning "severity" when severity is absent' {
        $entry = @{
            finding_key       = 'code-review:gh-1111'
            introduced_phase  = 'experience'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 2
            systemic_fix_type = 'instruction'
            category          = 'architecture'
            # severity is intentionally omitted
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $false
        $result.Errors  | Should -Match 'severity'
    }
}

Describe 'Test-PhaseContainmentEntry - introduced > catchable' {
    It 'returns IsValid=$false with ordering error when introduced_phase ordinal > catchable_phase ordinal' {
        # introduced=plan (ordinal 2), catchable=design (ordinal 1) — invalid
        $entry = @{
            finding_key       = 'design-challenge:762:design-phase-complete-762:F1'
            introduced_phase  = 'plan'
            catchable_phase   = 'design'
            caught_stage      = 'plan-stress-test'
            escape_distance   = 1
            severity          = 'high'
            systemic_fix_type = 'none'
            category          = 'architecture'
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $false
        $result.Errors  | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-PhaseContainmentEntry - catchable > caught projection' {
    It 'returns IsValid=$false when catchable=implementation (ordinal 3) but caught_stage=design-challenge (projection 1)' {
        $entry = @{
            finding_key       = 'code-review:gh-7777'
            introduced_phase  = 'experience'
            catchable_phase   = 'implementation'
            caught_stage      = 'design-challenge'
            escape_distance   = 0
            severity          = 'low'
            systemic_fix_type = 'none'
            category          = 'pattern'
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $false
        $result.Errors  | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-PhaseContainmentEntry - escape_distance stored vs recomputed mismatch' {
    It 'returns IsValid=$false with mismatch error when escape_distance=99 but recomputed=2' {
        # introduced=experience, catchable=design, caught=code-review -> escape = 3-1 = 2; stored=99 -> mismatch
        $entry = @{
            finding_key       = 'code-review:gh-8888'
            introduced_phase  = 'experience'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 99
            severity          = 'high'
            systemic_fix_type = 'instruction'
            category          = 'architecture'
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $false
        $result.Errors  | Should -Match 'mismatch'
    }
}

Describe 'Get-PhaseContainmentFindingKey - code-review surface' {
    It 'returns code-review:gh-{id} for a GitHub comment ID' {
        $result = Get-PhaseContainmentFindingKey -Surface 'code-review' -StableFindingKey 'gh-4829001234'
        $result | Should -Be 'code-review:gh-4829001234'
    }
}

Describe 'Get-PhaseContainmentFindingKey - design surface' {
    It 'returns design-challenge:{issue}:{marker}:{finding_id} for design surface' {
        $result = Get-PhaseContainmentFindingKey -Surface 'design-challenge' -StableFindingKey '762:design-phase-complete-762:F1'
        $result | Should -Be 'design-challenge:762:design-phase-complete-762:F1'
    }
}

Describe 'Get-PhaseContainmentFindingKey - plan surface' {
    It 'returns plan-stress-test:{issue}:{marker}:{finding_id} for plan surface' {
        $result = Get-PhaseContainmentFindingKey -Surface 'plan-stress-test' -StableFindingKey '762:plan-issue-762:P1'
        $result | Should -Be 'plan-stress-test:762:plan-issue-762:P1'
    }
}

Describe 'Enum drift test' {
    It 'Get-PhaseContainmentEnumDriftStatus returns HasDrift=$false (schema enums match routing-config.json)' {
        $result = Get-PhaseContainmentEnumDriftStatus -RepoRoot $script:RepoRoot
        $result.HasDrift    | Should -Be $false
        $result.DriftDetails | Should -BeNullOrEmpty
    }
}

Describe 'apparatus_meta: true entry' {
    It 'validates successfully when apparatus_meta is $true' {
        $entry = @{
            finding_key       = 'code-review:gh-3333'
            introduced_phase  = 'plan'
            catchable_phase   = 'plan'
            caught_stage      = 'plan-stress-test'
            escape_distance   = 0
            severity          = 'low'
            systemic_fix_type = 'none'
            category          = 'documentation-audit'
            apparatus_meta    = $true
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $true
    }
}

Describe 'Invalid enum value' {
    It 'returns IsValid=$false when severity is an unknown value "ultra"' {
        $entry = @{
            finding_key       = 'code-review:gh-4444'
            introduced_phase  = 'experience'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 2
            severity          = 'ultra'
            systemic_fix_type = 'instruction'
            category          = 'architecture'
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $false
        $result.Errors  | Should -Not -BeNullOrEmpty
    }
}
