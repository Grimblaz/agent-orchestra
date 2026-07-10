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
    It 'extracts YAML content from a valid phase-containment block as a single-element array' {
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
        $result.Count | Should -Be 1
        $result[0] | Should -Match 'finding_key'
        $result[0] | Should -Match 'introduced_phase'
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
        $result | Should -Not -BeNullOrEmpty
        $result[0] | Should -Not -Match '```'
        $result[0] | Should -Match 'finding_key'
    }

    It 'returns all blocks when multiple blocks appear in one comment body' {
        $text = @"
<!-- phase-containment-762 -->
finding_key: code-review:gh-1111
severity: high
<!-- /phase-containment-762 -->
<!-- phase-containment-762 -->
finding_key: code-review:gh-2222
severity: medium
<!-- /phase-containment-762 -->
"@
        $result = Get-PhaseContainmentBlock -Text $text -Id '762'
        $result | Should -Not -BeNullOrEmpty
        $result.Count | Should -Be 2
        $result[0] | Should -Match 'gh-1111'
        $result[1] | Should -Match 'gh-2222'
    }

    It 'skips an unclosed block when a later open tag precedes the next close tag, and warns (D6 pair-matching: open1 open2 close1 close2)' {
        $text = @"
<!-- phase-containment-772 -->
finding_key: code-review:gh-1111
<!-- phase-containment-772 -->
finding_key: code-review:gh-2222
<!-- /phase-containment-772 -->
<!-- /phase-containment-772 -->
"@
        $warnMsgs = $null
        $result = Get-PhaseContainmentBlock -Text $text -Id '772' -WarningVariable warnMsgs -WarningAction SilentlyContinue
        $result | Should -Not -BeNullOrEmpty
        $result.Count | Should -Be 1
        $result[0] | Should -Match 'gh-2222'
        $result[0] | Should -Not -Match 'gh-1111'
        $warnMsgs.Count | Should -BeGreaterThan 0
        ($warnMsgs -join ' ') | Should -Match 'malformed'
    }

    It 'returns $null when a close tag appears with no preceding open tag (close-before-open)' {
        $text = @"
<!-- /phase-containment-772 -->
finding_key: code-review:gh-5555
"@
        $result = Get-PhaseContainmentBlock -Text $text -Id '772'
        $result | Should -BeNullOrEmpty
    }

    It 'parses back-to-back well-formed blocks unchanged (D6 regression guard: open1 close1 open2 close2)' {
        $text = @"
<!-- phase-containment-772 -->
finding_key: code-review:gh-6666
<!-- /phase-containment-772 -->
<!-- phase-containment-772 -->
finding_key: code-review:gh-7777
<!-- /phase-containment-772 -->
"@
        $result = Get-PhaseContainmentBlock -Text $text -Id '772'
        $result | Should -Not -BeNullOrEmpty
        $result.Count | Should -Be 2
        $result[0] | Should -Match 'gh-6666'
        $result[1] | Should -Match 'gh-7777'
    }

    It 'increments the optional -SkippedCount [ref] once per pair-match skip (issue #772/#831 M4)' {
        $text = @"
<!-- phase-containment-772 -->
finding_key: code-review:gh-1111
<!-- phase-containment-772 -->
finding_key: code-review:gh-2222
<!-- /phase-containment-772 -->
<!-- /phase-containment-772 -->
"@
        $skipped = 0
        $result = Get-PhaseContainmentBlock -Text $text -Id '772' -SkippedCount ([ref]$skipped) -WarningAction SilentlyContinue
        $result | Should -Not -BeNullOrEmpty
        $skipped | Should -Be 1 -Because 'exactly one malformed/unclosed block (gh-1111) was skipped by the D6 pair-match'
    }

    It 'does not increment -SkippedCount when no pair-match skip occurs' {
        $text = @"
<!-- phase-containment-772 -->
finding_key: code-review:gh-6666
<!-- /phase-containment-772 -->
"@
        $skipped = 0
        $result = Get-PhaseContainmentBlock -Text $text -Id '772' -SkippedCount ([ref]$skipped)
        $result | Should -Not -BeNullOrEmpty
        $skipped | Should -Be 0
    }

    It 'does not throw when -SkippedCount is omitted, even when a pair-match skip occurs (back-compat)' {
        $text = @"
<!-- phase-containment-772 -->
finding_key: code-review:gh-1111
<!-- phase-containment-772 -->
finding_key: code-review:gh-2222
<!-- /phase-containment-772 -->
<!-- /phase-containment-772 -->
"@
        { Get-PhaseContainmentBlock -Text $text -Id '772' -WarningAction SilentlyContinue } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-PhaseContainmentYaml - non-recursion guard' {
    It 'returns a parsed result without hanging (CR1 regression guard)' {
        # If the public wrapper self-recurses it hangs; this test verifies it completes.
        $yaml = "severity: high`nfinding_key: code-review:gh-1"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result | Should -Not -BeNullOrEmpty
        $result['severity'] | Should -Be 'high'
    }
}

Describe 'ConvertFrom-PhaseContainmentYaml - inline YAML comment stripping' {
    It 'strips trailing inline YAML comment from string field' {
        $yaml = "severity: high # this is a comment"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result['severity'] | Should -Be 'high'
    }

    It 'strips trailing inline YAML comment from enum field' {
        $yaml = "caught_stage: code-review # added by judge"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result['caught_stage'] | Should -Be 'code-review'
    }

    It 'does not strip hash that is part of a value (no leading space before hash)' {
        $yaml = "finding_key: code-review:gh-1234#suffix"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result['finding_key'] | Should -Be 'code-review:gh-1234#suffix'
    }

    It 'normalises apparatus_meta: True (title-case) to $true' {
        $yaml = "apparatus_meta: True"
        $result = ConvertFrom-PhaseContainmentYaml -Yaml $yaml
        $result['apparatus_meta'] | Should -Be $true
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

Describe 'Test-PhaseContainmentEntry - finding_key format (Rule 12, issue #772 D4)' {
    It 'returns IsValid=$false when finding_key has no recognized surface prefix' {
        $entry = @{
            finding_key       = 'foo:bar'
            introduced_phase  = 'experience'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 2
            severity          = 'medium'
            systemic_fix_type = 'skill'
            category          = 'pattern'
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $false
        $result.Errors  | Should -Match 'finding_key'
    }

    It 'returns IsValid=$false for a bare key with no surface prefix at all' {
        $entry = @{
            finding_key       = 'gh-1234'
            introduced_phase  = 'experience'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 2
            severity          = 'medium'
            systemic_fix_type = 'skill'
            category          = 'pattern'
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $false
        $result.Errors  | Should -Match 'finding_key'
    }

    It 'returns IsValid=$false when the surface prefix has the wrong case (case-sensitive -cmatch)' {
        $entry = @{
            finding_key       = 'Code-Review:x'
            introduced_phase  = 'experience'
            catchable_phase   = 'design'
            caught_stage      = 'code-review'
            escape_distance   = 2
            severity          = 'medium'
            systemic_fix_type = 'skill'
            category          = 'pattern'
        }
        $result = Test-PhaseContainmentEntry -Entry $entry
        $result.IsValid | Should -Be $false
        $result.Errors  | Should -Match 'finding_key'
    }

    It 'returns IsValid=$true for a well-formed lowercase code-review finding_key' {
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

Describe 'finding_key pattern drift guard (issue #772 D4)' {
    It 'schema "pattern" literal for finding_key equals the validator regex constant (Get-PhaseContainmentEnumDriftStatus precedent)' {
        $schemaPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/schemas/phase-containment.schema.json'
        $schema     = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        $schemaPattern = $schema.properties.finding_key.pattern
        $schemaPattern | Should -Be $script:FindingKeyPattern
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
