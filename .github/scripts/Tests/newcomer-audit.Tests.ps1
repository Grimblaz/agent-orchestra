#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for skills/naming-register-policy/scripts/newcomer-audit-core.ps1.

.DESCRIPTION
    Covers the AC9 fixture matrix from plan-issue-751 (s2): the core's
    read/normalize, machine-citation-zone stripping, register-driven match-set
    construction (tokenized compound terms, instance patterns, literal terms),
    split-by-surface known-term escape hatch, and the digit/underscore/bracket
    unknown-token pass.

    Loads the real production register.json (not a synthetic subset) so these
    tests exercise the actual match-set the detector will run against.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreFile = Join-Path $script:RepoRoot 'skills/naming-register-policy/scripts/newcomer-audit-core.ps1'
    . $script:CoreFile

    $script:RegisterPath = Join-Path $script:RepoRoot 'skills/naming-register-policy/assets/register.json'
    $script:Register = Get-Content -Path $script:RegisterPath -Raw | ConvertFrom-Json
}

Describe 'newcomer-audit-core: unexpanded stable-code term in issue-body surface' {
    It 'flags the term (issue-body offers no other escape hatch)' {
        $content = 'The CE Gate must pass before the PR is created.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'issue-body' -Register $script:Register

        $findings | Should -Not -BeNullOrEmpty
        ($findings | Where-Object { $_.token -eq 'CE Gate' }).register_state | Should -Be 'stable-code'
    }
}

Describe 'newcomer-audit-core: expanded stable-code term (loose parenthetical)' {
    It 'does not flag when the first use is immediately followed by a parenthetical' {
        $content = 'The CE Gate (the final validation step) must pass before the PR is created.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'issue-body' -Register $script:Register

        ($findings | Where-Object { $_.token -eq 'CE Gate' }) | Should -BeNullOrEmpty
    }
}

Describe 'newcomer-audit-core: compound sub-token resolves as a known registered term' {
    Context 'the specific false-positive the adversarial review caught (MF1)' {
        It 'a naive full-term-literal match never recognizes the bare sub-token as known' {
            # This is not the production code path -- it proves the defect this
            # slice fixes is real, not a strawman. The register's 'term' field for
            # this row is the full compound string "credits[] / pipeline-metrics
            # block"; a naive matcher that escapes and matches that string
            # verbatim will never match the bare "credits[]" substring that
            # actually appears in prose.
            $row = $script:Register | Where-Object { $_.term -like 'credits*' }
            $row | Should -Not -BeNullOrEmpty -Because "the credits[] family row must exist in the live register"

            $content = 'The credits[] array holds pipeline credits.'
            $naivePattern = [regex]::Escape($row.term)
            [regex]::IsMatch($content, $naivePattern) | Should -BeFalse -Because 'a literal full-term match never finds the bare sub-token -- this is the real defect, not a strawman'
        }

        It 'the fixed core resolves the bare credits[] sub-token as stable-code, not unknown' {
            $content = 'The credits[] array holds pipeline credits.'
            $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

            $creditsFindings = @($findings | Where-Object { $_.token -eq 'credits[]' })
            $creditsFindings | Should -Not -BeNullOrEmpty -Because 'credits[] is an unsuppressed stable-code component and must be recognized'
            $creditsFindings[0].register_state | Should -Be 'stable-code' -Because 'it must resolve via the register component tokenizer, never fall through to the unknown-token pass'
        }

        It 'suppresses the same sub-token when the file carries the vocab-pointer link' {
            $content = 'See HOW-IT-WORKS.md#vocab for background. The credits[] array holds pipeline credits.'
            $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

            ($findings | Where-Object { $_.token -eq 'credits[]' }) | Should -BeNullOrEmpty
        }
    }
}

Describe 'newcomer-audit-core: repo-file surface full-file suppression context' {
    It 'suppresses a stable-code flag when the vocab-pointer link line is present elsewhere in the file' {
        $content = @'
# Some Doc

Spine-Runner walks the plan step by step.

---

See [vocab reference](HOW-IT-WORKS.md#vocab) for term definitions.
'@
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

        ($findings | Where-Object { $_.token -eq 'Spine-Runner' }) | Should -BeNullOrEmpty
    }
}

Describe 'newcomer-audit-core: machine-context code inside stripped zones' {
    It 'does not flag a stable code that only appears in a fenced block, an HTML comment, or YAML frontmatter' {
        $content = @'
---
marker: SMC-08
---

<!-- SMC-08 also mentioned here in a machine comment -->

Some ordinary prose with no codes at all.

```text
SMC-08 appears only inside this fenced code block.
```
'@
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

        $findings | Should -BeNullOrEmpty -Because 'every SMC-08 occurrence is inside a stripped machine-citation zone'
    }
}

Describe 'newcomer-audit-core: non-jargon digit-bearing allowlist' {
    It 'does not flag ISO-8601, UTF-8, or draft-07' {
        $content = 'Dates in this repo use ISO-8601 formatting; UTF-8 encoding is required; see draft-07 of the schema.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

        $findings | Should -BeNullOrEmpty
    }
}

Describe 'newcomer-audit-core: unknown-token pass' {
    It 'flags an unregistered snake_case coinage' {
        $content = 'We are introducing a new some_random_flag_v2 config option this release.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

        $match = $findings | Where-Object { $_.token -eq 'some_random_flag_v2' }
        $match | Should -Not -BeNullOrEmpty
        $match.register_state | Should -Be 'unknown'
    }

    It 'does not flag a bare ALL-CAPS acronym with no digit, underscore, or bracket (out of scope for v1)' {
        $content = 'The PR must pass CI before merge.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

        $findings | Should -BeNullOrEmpty
    }
}

Describe 'newcomer-audit-core: instance_pattern family rows' {
    It 'flags SMC-20 and plan-issue-732 as known stable-code needing expansion' {
        $content = 'See SMC-20 and plan-issue-732 for details.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'issue-body' -Register $script:Register

        ($findings | Where-Object { $_.token -eq 'SMC-20' }).register_state | Should -Be 'stable-code'
        ($findings | Where-Object { $_.token -eq 'plan-issue-732' }).register_state | Should -Be 'stable-code'
    }
}

Describe 'newcomer-audit-core: rename-candidate rows' {
    It 'flags the term and emits the replacement field as the suggestion' {
        $content = 'We should retire the Value Reflex framing.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

        $row = $script:Register | Where-Object { $_.term -eq 'Value Reflex' }
        $match = $findings | Where-Object { $_.token -eq 'Value Reflex' }
        $match | Should -Not -BeNullOrEmpty
        $match.register_state | Should -Be 'rename-candidate'
        $match.suggestion | Should -Be $row.replacement
    }
}

Describe 'newcomer-audit-core: self-describing compound rows' {
    It 'never flags a self-describing compound term' {
        $content = 'The pipeline runs prosecution then defense then judge stages.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'issue-body' -Register $script:Register

        ($findings | Where-Object { $_.token -in @('prosecution', 'defense', 'judge') }) | Should -BeNullOrEmpty
    }
}

Describe 'newcomer-audit-core: non-ASCII round trip' {
    It 'preserves a non-ASCII character in the suggestion text intact' {
        $syntheticRegister = @(
            [pscustomobject]@{
                term        = 'widget-max'
                register    = 'rename-candidate'
                kind        = 'atomic'
                replacement = ('friendly widget (limit LEQ10 per page, marked LEQ in source)' -replace 'LEQ', [string][char]0x2264)
            }
        )

        $content = 'Please avoid using widget-max going forward.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $syntheticRegister

        $match = $findings | Where-Object { $_.token -eq 'widget-max' }
        $match | Should -Not -BeNullOrEmpty
        $match.suggestion | Should -Be $syntheticRegister[0].replacement
        $match.suggestion | Should -Match ([regex]::Escape([char]0x2264)) -Because 'the non-ASCII replacement character must survive intact'
    }
}

Describe 'newcomer-audit-core: file-based entry point' {
    It 'reads a UTF-8 file with explicit encoding and normalizes CRLF to LF before matching' {
        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "newcomer-audit-fixture-$([guid]::NewGuid()).md"
        try {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($tempPath, "The CE Gate`r`nmust pass.", $utf8NoBom)

            $findings = Get-NewcomerAuditFindingsFromFile -Path $tempPath -Surface 'issue-body' -Register $script:Register

            ($findings | Where-Object { $_.token -eq 'CE Gate' }).register_state | Should -Be 'stable-code'
        }
        finally {
            Remove-Item -Path $tempPath -ErrorAction SilentlyContinue
        }
    }
}

Describe 'newcomer-audit-core: -AllOccurrences multi-occurrence behavior (CR-D)' {
    It 'without -AllOccurrences, a later occurrence of the same term is suppressed by an earlier occurrence' {
        $content = @'
# Doc

The CE Gate must pass here.

Unrelated line.

The CE Gate must pass again here on a later line.
'@
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

        $ceGateFindings = @($findings | Where-Object { $_.token -eq 'CE Gate' })
        $ceGateFindings | Should -HaveCount 1 -Because 'default behavior is first-occurrence-only'
        $ceGateFindings[0].line | Should -Be 3
        ($ceGateFindings | Where-Object { $_.line -eq 7 }) | Should -BeNullOrEmpty -Because 'the later occurrence must not surface without -AllOccurrences'
    }

    It 'with -AllOccurrences, a genuinely new occurrence on a later line is not suppressed by an earlier occurrence' {
        $content = @'
# Doc

The CE Gate must pass here.

Unrelated line.

The CE Gate must pass again here on a later line.
'@
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register -AllOccurrences

        $ceGateFindings = @($findings | Where-Object { $_.token -eq 'CE Gate' })
        ($ceGateFindings | Where-Object { $_.line -eq 3 }) | Should -Not -BeNullOrEmpty -Because 'the earlier occurrence must still surface'
        ($ceGateFindings | Where-Object { $_.line -eq 7 }) | Should -Not -BeNullOrEmpty -Because 'the later occurrence must not be suppressed by the earlier one'
    }

    It 'with -AllOccurrences, the same term repeated twice on the SAME line produces exactly one finding for that (token, line) pair' {
        $content = 'The CE Gate and the CE Gate again must both pass.'
        $findings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register -AllOccurrences

        $ceGateFindings = @($findings | Where-Object { $_.token -eq 'CE Gate' })
        $ceGateFindings | Should -HaveCount 1 -Because 'a term repeated on the same line is the same finding, not new information -- no duplicate (token, line) rows'
        $ceGateFindings[0].line | Should -Be 1
    }
}

Describe 'newcomer-audit-core: determinism' {
    It 'returns the same findings for the same input across repeated calls' {
        $content = 'See SMC-20 and the credits[] array. We should retire Value Reflex.'
        $first = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register
        $second = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $script:Register

        ($first | ConvertTo-Json -Depth 5) | Should -Be ($second | ConvertTo-Json -Depth 5)
    }
}
